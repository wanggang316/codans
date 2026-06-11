#!/usr/bin/env bash
#
# bump-version.sh — set MARKETING_VERSION + CURRENT_PROJECT_VERSION in
# apps/mac/Configurations/Project.xcconfig.
#
# This is the single source of truth the release CI checks against
# (.github/workflows/release.yml verifies tag vX.Y.Z matches
# MARKETING_VERSION before building). After this file is updated,
# sync-product-version.sh projects MARKETING_VERSION into the co-versioned
# CLI and Agent Skill metadata.
#
# Build-number scheme: YYYYMMDD + 3-digit sequence (e.g. 20260510001),
# shared by both stable and tip releases.  Each release queries the
# published appcast for the highest existing build number, then
# increments by 1.  A new calendar day resets the sequence to 001.
#   20260510001  (stable)
#   20260510002  (tip)
#   20260510003  (tip)
#   20260511001  (stable — new day, sequence resets)
#
# Usage:
#   bump-version.sh <X.Y.Z>          # marketing version; build = today (or todayN if same day)
#   bump-version.sh <X.Y.Z> <BUILD>  # set both explicitly (BUILD must be > current)
#   bump-version.sh --print          # show current values + suggested next bump
#   bump-version.sh --help
#
# Examples:
#   bump-version.sh 0.1.6               # build becomes e.g. 20260511001
#   bump-version.sh 0.1.7               # later same day → build becomes 20260511002
#   bump-version.sh 0.2.0 20260601001   # explicit override
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"
xcconfig="${srcroot}/Configurations/Project.xcconfig"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

print_usage() {
  cat <<'EOF'
bump-version.sh — bump MARKETING_VERSION + CURRENT_PROJECT_VERSION.

Usage:
  bump-version.sh <X.Y.Z>          set marketing version, increment build by 1
  bump-version.sh <X.Y.Z> <BUILD>  set both explicitly
  bump-version.sh --print          show current values + suggested patch bump
  bump-version.sh --help
EOF
}

read_field() {
  local key="$1"
  awk -F'=' -v k="$key" '
    $0 ~ "^"k"[[:space:]]*=" {
      gsub(/[ \t\r]/, "", $2); print $2; exit
    }' "$xcconfig"
}

semver_check() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version '$1' must match X.Y.Z (digits only)"
}

# Returns 0 (true) if $1 is strictly greater than $2 (both X.Y.Z).
semver_gt() {
  local a="$1" b="$2"
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  (( a1 != b1 )) && { (( a1 > b1 )); return; }
  (( a2 != b2 )) && { (( a2 > b2 )); return; }
  (( a3 >  b3 ))
}

next_patch() {
  local v="$1"
  IFS=. read -r x y z <<<"$v"
  echo "$x.$y.$((z + 1))"
}

# Query the published appcast for the highest build number across all
# channels (stable + tip).  Returns empty if unreachable.
max_published_build() {
  curl -fsSL --max-time 10 \
    "https://github.com/wanggang316/codans/releases/latest/download/appcast.xml" 2>/dev/null \
    | grep -oE '<sparkle:version>[^<]+' \
    | sed 's/<sparkle:version>//' \
    | sort -n \
    | tail -1 || true
}

# Compute the next YYYYMMDDNNN build number.  Takes the current xcconfig
# value as a floor, queries the published appcast for the highest build
# across both channels, and increments.  A new calendar day starts at NNN=001.
next_build() {
  local cur="$1"
  local today
  today="$(date +%Y%m%d)"
  local today_base="${today}000"

  local max_pub
  max_pub="$(max_published_build)"

  local base="$cur"
  if [[ -n "$max_pub" ]] && (( max_pub > base )); then
    base="$max_pub"
  fi

  if (( base >= today_base )); then
    # Same day (or TZ-skewed future): increment from base
    printf '%d\n' $((base + 1))
  else
    # New day: start at today + 001
    printf '%s001\n' "$today"
  fi
}

cmd_print() {
  local mv pv next_mv next_pv max_pub
  mv="$(read_field MARKETING_VERSION)"
  pv="$(read_field CURRENT_PROJECT_VERSION)"
  next_mv="$(next_patch "$mv")"
  max_pub="$(max_published_build)"
  next_pv="$(next_build "$pv")"
  cat <<EOF
xcconfig: $xcconfig

  MARKETING_VERSION       = $mv
  CURRENT_PROJECT_VERSION = $pv
  Published max build     = ${max_pub:-<none>}

next patch: $next_mv (build $next_pv)
EOF
}

cmd_bump() {
  local new_mv="$1" new_pv="${2:-}"
  semver_check "$new_mv"

  [[ -f "$xcconfig" ]] || die "$xcconfig not found"

  local cur_mv cur_pv
  cur_mv="$(read_field MARKETING_VERSION)"
  cur_pv="$(read_field CURRENT_PROJECT_VERSION)"
  [[ -n "$cur_mv" ]] || die "MARKETING_VERSION not found in $xcconfig"
  [[ -n "$cur_pv" ]] || die "CURRENT_PROJECT_VERSION not found in $xcconfig"

  if [[ "$new_mv" == "$cur_mv" ]]; then
    die "new MARKETING_VERSION ($new_mv) == current; nothing to bump"
  fi
  if ! semver_gt "$new_mv" "$cur_mv"; then
    die "new MARKETING_VERSION ($new_mv) is not greater than current ($cur_mv); use a forward-rolling version"
  fi

  if [[ -z "$new_pv" ]]; then
    new_pv="$(next_build "$cur_pv")"
    if (( new_pv <= cur_pv )); then
      die "computed date-based build ($new_pv) is not > current ($cur_pv); pass an explicit BUILD= override"
    fi
  else
    [[ "$new_pv" =~ ^[0-9]+$ ]] || die "build number '$new_pv' must be a positive integer"
    (( new_pv > cur_pv )) || die "new build ($new_pv) must be > current ($cur_pv)"
  fi

  log "MARKETING_VERSION:       $cur_mv -> $new_mv"
  log "CURRENT_PROJECT_VERSION: $cur_pv -> $new_pv"

  # Two anchored substitutions — use a tmpfile so we never half-write.
  local tmp
  tmp="$(mktemp "${xcconfig}.bump.XXXXXX")"
  awk -v mv="$new_mv" -v pv="$new_pv" '
    BEGIN { OFS="=" }
    /^MARKETING_VERSION[[:space:]]*=/       { print "MARKETING_VERSION = " mv; next }
    /^CURRENT_PROJECT_VERSION[[:space:]]*=/ { print "CURRENT_PROJECT_VERSION = " pv; next }
    { print }
  ' "$xcconfig" >"$tmp"

  # Sanity: post-condition matches what we asked for.
  local check_mv check_pv
  check_mv="$(awk -F'=' '/^MARKETING_VERSION/ {gsub(/[ \t\r]/,"",$2); print $2}' "$tmp")"
  check_pv="$(awk -F'=' '/^CURRENT_PROJECT_VERSION/ {gsub(/[ \t\r]/,"",$2); print $2}' "$tmp")"
  if [[ "$check_mv" != "$new_mv" || "$check_pv" != "$new_pv" ]]; then
    rm -f "$tmp"
    die "post-write verification failed (mv=$check_mv, pv=$check_pv); xcconfig left unchanged"
  fi

  mv "$tmp" "$xcconfig"
  log "wrote $xcconfig"
  "${script_dir}/sync-product-version.sh"
}

main() {
  case "${1-}" in
    ""|-h|--help)
      print_usage
      ;;
    --print)
      cmd_print
      ;;
    *)
      cmd_bump "$@"
      ;;
  esac
}

main "$@"
