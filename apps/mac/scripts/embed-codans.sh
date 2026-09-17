#!/usr/bin/env bash
set -euo pipefail

# Mirrors the guards in embed-git-wt.sh: a stray run outside the Xcode
# build driver would expand unset paths to "/" — and the rm -rf below
# would happily clobber whatever that resolved to. Hard-fail instead.
: "${SRCROOT:?SRCROOT must be set (run this from the Xcode build driver)}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set (run this from the Xcode build driver)}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH must be set (run this from the Xcode build driver)}"
: "${CONFIGURATION_BUILD_DIR:?CONFIGURATION_BUILD_DIR must be set (run this from the Xcode build driver)}"
# Per-configuration build setting from Project.swift (`codans-dev` in Debug,
# `codans` in Release). The product is always built as `codans`; the name
# it is embedded under is what a pane's PATH lookup and the installer see.
: "${CODANS_CLI_NAME:?CODANS_CLI_NAME must be set (defined per configuration in Project.swift)}"

tc_source="${CONFIGURATION_BUILD_DIR}/codans"
tc_destination_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
tc_destination="${tc_destination_dir}/${CODANS_CLI_NAME}"

if [ ! -f "${tc_source}" ]; then
  echo "error: missing ${tc_source}. codans target should be a dependency of the app target." >&2
  exit 1
fi

# Resources/bin is shared with "Embed zmx", which dependency analysis skips
# when zmx is unchanged, so wiping the directory here would ship a bundle
# with no zmx. Only clear the CLI names a previous build of this
# configuration may have left behind (the dev/release rename).
mkdir -p "${tc_destination_dir}"
rm -f "${tc_destination_dir}/codans" "${tc_destination_dir}/codans-dev"
/bin/cp -f "${tc_source}" "${tc_destination}"
chmod +x "${tc_destination}"
