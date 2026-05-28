#!/usr/bin/env bash
#
# notarize.sh — submit a signed .app or .dmg to Apple's notary service,
# wait for the verdict, and staple the ticket on success.
#
# Usage:
#   ./scripts/notarize.sh <path-to-app-or-dmg>
#
# Credentials (precedence: env > keychain):
#   AC_API_KEY_ID + AC_API_ISSUER_ID + AC_API_KEY_P8 (base64)
#                                — CI mode; the P8 is decoded to a
#                                  tempfile cleaned up via trap.
#   else: --keychain-profile "${KEYCHAIN_PROFILE:-touch-code-notary}"
#         (one-time setup: xcrun notarytool store-credentials).
#
set -euo pipefail

target="${1:-}"
[ -n "${target}" ] || {
  echo "usage: notarize.sh <path-to-app-or-dmg>" >&2
  exit 2
}
[ -e "${target}" ] || {
  echo "error: ${target} does not exist" >&2
  exit 1
}

cleanup_files=()
cleanup_dirs=()
cleanup() {
  # Guard the loops: bash 3.2 (default /bin/bash on macOS) errors on
  # "${arr[@]}" when arr is empty under `set -u`.
  if [ "${#cleanup_files[@]}" -gt 0 ]; then
    for f in "${cleanup_files[@]}"; do
      [ -n "${f}" ] && rm -f "${f}" || true
    done
  fi
  if [ "${#cleanup_dirs[@]}" -gt 0 ]; then
    for d in "${cleanup_dirs[@]}"; do
      [ -n "${d}" ] && rm -rf "${d}" || true
    done
  fi
}
trap cleanup EXIT

if [ -n "${AC_API_KEY_ID:-}" ]; then
  : "${AC_API_ISSUER_ID:?AC_API_ISSUER_ID must be set when AC_API_KEY_ID is set}"
  : "${AC_API_KEY_P8:?AC_API_KEY_P8 must be set when AC_API_KEY_ID is set}"
  key_path="$(mktemp -t touch-code-notary).p8"
  cleanup_files+=("${key_path}")
  # `tr -d` strips whitespace and CRs that creep in when secrets are
  # set via UI dashboards; `-D` (BSD base64) is what macOS ships.
  printf '%s' "${AC_API_KEY_P8}" | tr -d ' \n\r\t' | base64 -D > "${key_path}"
  notary_args=(--key "${key_path}" --key-id "${AC_API_KEY_ID}" --issuer "${AC_API_ISSUER_ID}")
else
  profile="${KEYCHAIN_PROFILE:-touch-code-notary}"
  notary_args=(--keychain-profile "${profile}")
fi

echo "==> submitting ${target} to Apple notary service"
submit_log="$(mktemp -t touch-code-notary-submit).json"
cleanup_files+=("${submit_log}")

# notarytool wants a zip when notarizing a .app; DMGs go in directly.
case "${target}" in
  *.app)
    zip_dir="$(mktemp -d -t touch-code-notary)"
    cleanup_dirs+=("${zip_dir}")
    zip_path="${zip_dir}/$(basename "${target}").zip"
    /usr/bin/ditto -c -k --keepParent "${target}" "${zip_path}"
    submission="${zip_path}"
    ;;
  *.dmg)
    submission="${target}"
    ;;
  *)
    echo "error: unsupported target type: ${target} (expected .app or .dmg)" >&2
    exit 1
    ;;
esac

xcrun notarytool submit "${submission}" \
  "${notary_args[@]}" \
  --wait \
  --output-format json \
  > "${submit_log}"

status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "${submit_log}")"
submission_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "${submit_log}")"

echo "==> notarization status: ${status} (id: ${submission_id})"
if [ "${status}" != "Accepted" ]; then
  echo "==> dumping notarytool log for failed submission" >&2
  xcrun notarytool log "${submission_id}" "${notary_args[@]}" >&2 || true
  exit 1
fi

echo "==> stapling ticket onto ${target}"
xcrun stapler staple "${target}"
xcrun stapler validate "${target}"

# Stapling mutates the file in place, so any sibling .sha256 emitted
# before this point (e.g. by make-dmg.sh during cmd_dmg) now refers
# to pre-staple bytes. Rewrite it here so every caller — including
# release.yml, which invokes notarize as a discrete step rather than
# via release.sh cmd_release — leaves a coherent (file, checksum) pair
# on disk. No-op when no sidecar exists.
sidecar="${target}.sha256"
if [ -f "${sidecar}" ]; then
  ( cd "$(dirname "${target}")" \
    && shasum -a 256 "$(basename "${target}")" > "$(basename "${sidecar}")" )
  echo "==> refreshed sidecar: $(cat "${sidecar}")"
fi

echo "==> ${target} notarized and stapled"
