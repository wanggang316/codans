#!/usr/bin/env bash
#
# render-cask.sh — stamp version + sha256 into Casks/touch-code.rb.
#
# Source of truth lives at Casks/touch-code.rb; this script regex-replaces
# the `version "..."` and `sha256 "..."` lines and writes the rendered cask
# to stdout (or to an output path).
#
# Usage:
#   ./scripts/render-cask.sh <version> <sha256> [<output-path>]
#
#   <version>  MARKETING_VERSION style, X.Y.Z
#   <sha256>   lowercase 64-hex digest of the published DMG
#
# Examples:
#   ./scripts/render-cask.sh 0.3.0 "$(shasum -a 256 TouchCode-0.3.0.dmg | awk '{print $1}')"
#   ./scripts/render-cask.sh 0.3.0 abc...def /tmp/touch-code.rb
#
set -euo pipefail

version="${1:?usage: render-cask.sh <version> <sha256> [<output>]}"
sha256="${2:?usage: render-cask.sh <version> <sha256> [<output>]}"
output="${3:-/dev/stdout}"

# Strict validation — bad inputs here would otherwise produce a cask that
# Homebrew accepts but installs the wrong artifact.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "error: version must be X.Y.Z (got: $version)" >&2; exit 1; }
[[ "$sha256" =~ ^[a-f0-9]{64}$ ]] \
  || { echo "error: sha256 must be 64 lowercase hex chars (got: $sha256)" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="${script_dir}/../Casks/touch-code.rb"
[ -f "$template" ] || { echo "error: missing $template" >&2; exit 1; }

# Use Python for substitution: sed -i has different flags on BSD vs GNU,
# and Python's re.subn lets us assert exactly one replacement per field
# (catches future drift in the template format).
python3 - "$template" "$version" "$sha256" >"$output" <<'PYEOF'
import re, sys
path, version, sha256 = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    src = f.read()
src, n1 = re.subn(r'^(  version )"[^"]+"', rf'\g<1>"{version}"', src, count=1, flags=re.M)
if n1 != 1:
    sys.exit(f"render-cask: expected exactly 1 version line, replaced {n1}")
src, n2 = re.subn(r'^(  sha256 )"[a-f0-9]{64}"', rf'\g<1>"{sha256}"', src, count=1, flags=re.M)
if n2 != 1:
    sys.exit(f"render-cask: expected exactly 1 sha256 line, replaced {n2}")
sys.stdout.write(src)
PYEOF
