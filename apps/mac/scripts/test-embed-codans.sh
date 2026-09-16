#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codans-embed-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

export SRCROOT="${script_dir}/.."
export TARGET_BUILD_DIR="${test_root}/products"
export UNLOCALIZED_RESOURCES_FOLDER_PATH="Codans.app/Contents/Resources"
export CONFIGURATION_BUILD_DIR="${test_root}/cli"
export CODANS_CLI_NAME="codans-dev"

test_bin="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
mkdir -p "${test_bin}" "${CONFIGURATION_BUILD_DIR}"
printf 'zmx fixture\n' > "${test_root}/expected-zmx"
cp "${test_root}/expected-zmx" "${test_bin}/zmx"
chmod +x "${test_bin}/zmx"

for revision in first second; do
  printf 'cli %s\n' "${revision}" > "${CONFIGURATION_BUILD_DIR}/codans"
  bash "${script_dir}/embed-codans.sh"
  cmp "${CONFIGURATION_BUILD_DIR}/codans" "${test_bin}/${CODANS_CLI_NAME}"
  cmp "${test_root}/expected-zmx" "${test_bin}/zmx"
  test -x "${test_bin}/${CODANS_CLI_NAME}"
  test -x "${test_bin}/zmx"
done

printf 'PASS: repeated CLI embedding preserves zmx and updates only the CLI\n'
