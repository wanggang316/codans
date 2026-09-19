#!/usr/bin/env bash
set -euo pipefail

# Mirrors the guards in embed-codans.sh: a stray run outside the Xcode build
# driver would expand unset paths to "/", and any file operations would
# resolve relative to that. Hard-fail instead. Neither script wipes the
# destination dir — codans and zmx both live in Resources/bin.
: "${SRCROOT:?SRCROOT must be set (run this from the Xcode build driver)}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set (run this from the Xcode build driver)}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH must be set (run this from the Xcode build driver)}"

zmx_source="${SRCROOT}/.build/zmx/bin/zmx"
zmx_destination_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
zmx_destination="${zmx_destination_dir}/zmx"

if [ ! -f "${zmx_source}" ]; then
  echo "error: missing ${zmx_source}. Run scripts/build-zmx.sh before embedding." >&2
  exit 1
fi

mkdir -p "${zmx_destination_dir}"
# Unlink before copying so the new zmx gets a fresh inode. `cp -f` onto an
# existing file rewrites that inode in place. Once the kernel has cached the
# inode's code signature (any earlier exec, e.g. a pane daemon that outlived
# the app), an in-place rewrite, even with identical bytes, gets every later
# exec of it SIGKILLed ("load code signature error 2"), so each new pane
# closes the moment it opens.
rm -f "${zmx_destination}"
/bin/cp -f "${zmx_source}" "${zmx_destination}"
chmod +x "${zmx_destination}"
