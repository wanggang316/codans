#!/usr/bin/env bash
set -euo pipefail

# Assert Xcode-provided environment variables are set before using them.
# Unset expansion under `set -u` + a stray run outside the Xcode driver
# would otherwise produce paths like `/git-wt` — and the `rm -rf` below
# would then happily clobber wherever that resolved. Hard-fail instead.
: "${SRCROOT:?SRCROOT must be set (run this from the Xcode build driver)}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set (run this from the Xcode build driver)}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH must be set (run this from the Xcode build driver)}"

destination_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
git_wt_source="${SRCROOT}/ThirdParty/git-wt/wt"
git_wt_destination_dir="${destination_root}/git-wt"

if [ ! -f "${git_wt_source}" ]; then
  echo "error: missing ${git_wt_source}" >&2
  exit 1
fi

rm -rf "${git_wt_destination_dir}"
mkdir -p "${git_wt_destination_dir}"
/bin/cp -f "${git_wt_source}" "${git_wt_destination_dir}/wt"
chmod +x "${git_wt_destination_dir}/wt"
