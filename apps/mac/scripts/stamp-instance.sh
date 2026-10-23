#!/usr/bin/env bash
set -euo pipefail

# Stamps the data instance into a Debug app's Info.plist (see AppInstance in
# CodansCore). A build made in a linked git worktree gets the worktree's
# directory name, so its app keeps its own ~/.codans-dev-<name>, cache,
# daemons, and socket; the main checkout and Release builds carry no name and
# use the channel's shared instance.
: "${SRCROOT:?SRCROOT must be set (run this from the Xcode build driver)}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set (run this from the Xcode build driver)}"
: "${INFOPLIST_PATH:?INFOPLIST_PATH must be set (run this from the Xcode build driver)}"

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
key="CodansInstance"
buddy=/usr/libexec/PlistBuddy

[ -f "${plist}" ] || { echo "error: missing ${plist}" >&2; exit 1; }
"${buddy}" -c "Delete :${key}" "${plist}" >/dev/null 2>&1 || true

[ "${CONFIGURATION:-}" = "Debug" ] || exit 0

git_dir="$(git -C "${SRCROOT}" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
common_dir="$(cd "$(git -C "${SRCROOT}" rev-parse --git-common-dir)" && pwd -P)"
[ "$(cd "${git_dir}" && pwd -P)" != "${common_dir}" ] || exit 0

# Same rule as AppInstance.isValid: lowercase letters, digits, and inner
# hyphens, at most 24 characters.
top="$(git -C "${SRCROOT}" rev-parse --show-toplevel)"
name="$(basename "${top}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//' | cut -c1-24 | sed -E 's/-$//')"
if [ -z "${name}" ]; then
  echo "warning: worktree ${top} gives no usable instance name; using the shared instance" >&2
  exit 0
fi
"${buddy}" -c "Add :${key} string ${name}" "${plist}"
echo "Codans instance: ${name}"
