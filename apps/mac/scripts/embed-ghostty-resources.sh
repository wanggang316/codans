#!/usr/bin/env bash
set -euo pipefail

# Same SRCROOT/TARGET_BUILD_DIR guards as embed-git-wt.sh / embed-codans.sh:
# a stray run outside the Xcode build driver would expand unset paths
# to "/" and the rm -rf below would clobber it. Hard-fail instead.
: "${SRCROOT:?SRCROOT must be set (run this from the Xcode build driver)}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set (run this from the Xcode build driver)}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH must be set}"

destination_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
ghostty_source="${SRCROOT}/.build/ghostty/share/ghostty"
terminfo_source="${SRCROOT}/.build/ghostty/share/terminfo"
ghostty_destination="${destination_root}/ghostty"
terminfo_destination="${destination_root}/terminfo"

if [ ! -d "${ghostty_source}" ]; then
  echo "error: missing ${ghostty_source}. Run scripts/build-ghostty.sh first." >&2
  exit 1
fi
if [ ! -d "${terminfo_source}" ]; then
  echo "error: missing ${terminfo_source}. Run scripts/build-ghostty.sh first." >&2
  exit 1
fi

rm -rf "${ghostty_destination}" "${terminfo_destination}"
mkdir -p "${ghostty_destination}" "${terminfo_destination}"
rsync -a --delete "${ghostty_source}/" "${ghostty_destination}/"
rsync -a --delete "${terminfo_source}/" "${terminfo_destination}/"
