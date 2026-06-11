#!/usr/bin/env bash
#
# make-dmg.sh — package a signed Codans.app into a Developer-ID-
# signed DMG using only hdiutil + codesign + iconutil (no brew dep).
#
# The DMG ships with a custom volume icon (derived from the app icon
# source PNG) and a side-by-side Finder layout: Codans.app on the
# left, /Applications symlink on the right. We stage as UDRW, mount,
# script Finder, then convert to UDZO.
#
# Usage:
#   ./scripts/make-dmg.sh <path-to-app> <output-dmg> <signing-identity>
#
set -euo pipefail

app_path="${1:?usage: make-dmg.sh <app> <out-dmg> <signing-identity>}"
dmg_path="${2:?usage: make-dmg.sh <app> <out-dmg> <signing-identity>}"
identity="${3:?usage: make-dmg.sh <app> <out-dmg> <signing-identity>}"

[ -d "${app_path}" ] || { echo "error: ${app_path} is not a directory" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
icon_src="${script_dir}/../codans/App/AppIcon.icon/Assets/2.png"
[ -f "${icon_src}" ] || { echo "error: source icon ${icon_src} missing" >&2; exit 1; }

vol_name="Codans"

# Refuse to wrap an unsigned (or improperly-signed) .app in a signed
# DMG. codesign --strict --deep walks the entire bundle and catches
# unsigned helpers (e.g., a stale codans) that would otherwise sail through
# to a notarization failure 30 minutes from now.
echo "==> verifying ${app_path} signature before staging"
codesign --verify --deep --strict --verbose=2 "${app_path}"

work_dir="$(mktemp -d -t codans-dmg)"
stage_dir="${work_dir}/stage"
rw_dmg="${work_dir}/build.dmg"
mkdir -p "${stage_dir}"

mounted_dev=""
cleanup() {
  if [ -n "${mounted_dev}" ]; then
    hdiutil detach "${mounted_dev}" -force >/dev/null 2>&1 || true
  fi
  rm -rf "${work_dir}"
}
trap cleanup EXIT

echo "==> staging DMG contents"
/bin/cp -R "${app_path}" "${stage_dir}/"
ln -s /Applications "${stage_dir}/Applications"

# Background image with a chevron "›" between the two icons, mirroring
# the macOS install-DMG convention (see Apple/ChatGPT/etc.). Rendered
# fresh each build via Swift/AppKit so we don't track a binary asset.
# Geometry mirrors the Finder layout below: icons at (170,180) and
# (490,180) inside a 660×400 window, so the chevron sits centered at
# x≈330 at the vertical midpoint.
echo "==> generating DMG background image"
mkdir -p "${stage_dir}/.background"
bg_image="${stage_dir}/.background/background.png"
swift - "${bg_image}" <<'SWIFT'
import AppKit
import Foundation

let outputPath = CommandLine.arguments[1]
let width: CGFloat = 660
let height: CGFloat = 400

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

NSColor(white: 0.96, alpha: 1.0).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let centerX: CGFloat = width / 2
let centerY: CGFloat = height / 2
let halfWidth: CGFloat = 14
let halfHeight: CGFloat = 24

let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: centerX - halfWidth, y: centerY + halfHeight))
chevron.line(to: NSPoint(x: centerX + halfWidth, y: centerY))
chevron.line(to: NSPoint(x: centerX - halfWidth, y: centerY - halfHeight))
chevron.lineWidth = 8
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round

NSColor(white: 0.2, alpha: 1.0).setStroke()
chevron.stroke()

image.unlockFocus()

guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
else {
  FileHandle.standardError.write(Data("failed to render DMG background\n".utf8))
  exit(1)
}
try data.write(to: URL(fileURLWithPath: outputPath))
SWIFT

# Stage the volume icon outside the source tree. We add it to the
# mounted volume *after* the Finder AppleScript runs — Finder
# silently removes any .VolumeIcon.icns from a window it has just
# arranged via `update without registering applications`, so adding
# it pre-mount loses the file before convert.
echo "==> generating volume icon from ${icon_src}"
volume_icon="${work_dir}/VolumeIcon.icns"
iconset="${work_dir}/codans.iconset"
mkdir -p "${iconset}"
# The source PNG is opaque RGB, so a plain sips downscale produces a
# square-cornered volume icon on the desktop. Mask each iconset entry
# with a macOS-style squircle (corner radius ≈ 22.37% of icon size) and
# write transparent PNGs so Finder renders the rounded shape.
swift - "${icon_src}" "${iconset}" <<'SWIFT'
import AppKit
import Foundation

let sourcePath = CommandLine.arguments[1]
let outputDir = CommandLine.arguments[2]

guard let source = NSImage(contentsOfFile: sourcePath) else {
  FileHandle.standardError.write(Data("failed to load \(sourcePath)\n".utf8))
  exit(1)
}

let variants: [(Int, Int)] = [16, 32, 128, 256, 512].flatMap { [($0, 1), ($0, 2)] }

for (size, scale) in variants {
  let pixel = size * scale
  let rect = NSRect(x: 0, y: 0, width: pixel, height: pixel)
  let canvas = NSImage(size: NSSize(width: pixel, height: pixel))
  canvas.lockFocus()
  let radius = CGFloat(pixel) * 0.2237
  NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
  source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
  canvas.unlockFocus()
  guard let cg = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
  else {
    FileHandle.standardError.write(Data("failed to encode icon \(pixel)\n".utf8))
    exit(1)
  }
  let suffix = scale == 2 ? "@2x" : ""
  let outURL = URL(fileURLWithPath: "\(outputDir)/icon_\(size)x\(size)\(suffix).png")
  try data.write(to: outURL)
}
SWIFT
iconutil --convert icns --output "${volume_icon}" "${iconset}"

echo "==> hdiutil create read-write ${rw_dmg}"
hdiutil create \
  -volname "${vol_name}" \
  -srcfolder "${stage_dir}" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "${rw_dmg}" \
  >/dev/null

echo "==> attaching read-write DMG"
attach_out="$(hdiutil attach -readwrite -noverify -noautoopen "${rw_dmg}")"
mounted_dev="$(printf '%s\n' "${attach_out}" | awk '/^\/dev\// {print $1; exit}')"
mount_point="/Volumes/${vol_name}"
[ -n "${mounted_dev}" ] || { echo "error: hdiutil attach produced no /dev node" >&2; exit 1; }

# Wait for the volume to fully appear; Finder occasionally lags hdiutil.
for _ in 1 2 3 4 5; do
  [ -d "${mount_point}" ] && break
  sleep 1
done
[ -d "${mount_point}" ] || { echo "error: ${mount_point} did not mount" >&2; exit 1; }

echo "==> arranging Finder window via AppleScript"
# Window bounds {left, top, right, bottom} = 660x400. Icon centers
# placed symmetrically across the 660-px content width: 170 and 490
# (both 160 px from center, 128 px wide icons w/ ~32 px gutter).
osascript <<APPLESCRIPT
tell application "Finder"
  activate
  tell disk "${vol_name}"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 200, 860, 600}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set label position of viewOptions to bottom
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Codans.app" of container window to {170, 180}
    set position of item "Applications" of container window to {490, 180}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

echo "==> installing volume icon and custom-icon attribute"
# Order matters: copy the .icns AFTER the Finder AppleScript closes,
# otherwise Finder strips it during `update without registering
# applications`. SetFile -a C sets kHasCustomIcon (0x0400) in the
# volume root's FinderInfo so Finder renders the custom icon at
# mount time.
/bin/cp "${volume_icon}" "${mount_point}/.VolumeIcon.icns"
SetFile -a C "${mount_point}"

sync

echo "==> detaching DMG"
hdiutil detach "${mounted_dev}" >/dev/null
mounted_dev=""

mkdir -p "$(dirname "${dmg_path}")"
rm -f "${dmg_path}"

echo "==> converting to compressed UDZO ${dmg_path}"
hdiutil convert "${rw_dmg}" -format UDZO -imagekey zlib-level=9 -o "${dmg_path}" >/dev/null

echo "==> signing DMG"
codesign --sign "${identity}" --timestamp "${dmg_path}"
codesign --verify --verbose=2 "${dmg_path}"

echo "==> writing checksum"
sha256_path="${dmg_path}.sha256"
( cd "$(dirname "${dmg_path}")" && shasum -a 256 "$(basename "${dmg_path}")" > "${sha256_path}" )
cat "${sha256_path}"

echo "==> ${dmg_path}"
