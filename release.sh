#!/usr/bin/env bash
set -Eeuo pipefail

# Automated release builder for macOS Accessibility Client.
#
# Default behavior:
#   - bumps patch version (MARKETING_VERSION) and build number (CURRENT_PROJECT_VERSION)
#   - builds Release app with xcodebuild
#   - creates a polished drag-to-Applications DMG
#   - commits version bump, tags it, pushes to GitHub, creates/verifies GitHub release
#
# Examples:
#   ./release.sh                         # 1.0.0 -> 1.0.1, build 1 -> 2, publish
#   ./release.sh --version 1.1.0         # manual minor/major override, build still increments
#   ./release.sh --dry-run               # build + DMG only, no version edit/git/GitHub changes
#   ./release.sh --skip-github           # bump/build/DMG only, no commit/tag/push/release
#   ./release.sh --yes                   # skip confirmation prompt before publishing

APP_NAME="MacOSAccessibilityClient"
DISPLAY_NAME="MacOS Accessibility Client"
REPO_SLUG="drewster99/macos-accessibility-client"
PROJECT_REL="MacOSAccessibilityClient/MacOSAccessibilityClient.xcodeproj"
PROJECT_FILE="${PROJECT_REL}/project.pbxproj"
SCHEME="MacOSAccessibilityClient"
CONFIGURATION="Release"
DMG_ICON_SIZE=128
DMG_WINDOW_WIDTH=640
DMG_WINDOW_HEIGHT=420

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

OVERRIDE_VERSION=""
SKIP_GITHUB=0
DRY_RUN=0
YES=0
KEEP_WORK=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --version X.Y.Z   Manually set release version instead of auto-incrementing patch.
                    Useful for minor/major bumps; build number still increments.
  --skip-github     Build DMG after bumping version, but do not commit/tag/push/create release.
  --dry-run         Build and create a DMG using the current project version without modifying
                    project files or touching git/GitHub.
  --yes             Do not prompt for confirmation before publishing to GitHub.
  --keep-work       Keep temporary DMG staging files for inspection/debugging.
  -h, --help        Show this help.

Default publishes a GitHub release. Use --dry-run for local testing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { echo "ERROR: --version requires X.Y.Z" >&2; exit 2; }
      OVERRIDE_VERSION="$2"
      shift 2
      ;;
    --skip-github)
      SKIP_GITHUB=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      SKIP_GITHUB=1
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    --keep-work)
      KEEP_WORK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
success() { printf '\033[1;32mSUCCESS:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  echo >&2
  echo "ERROR: release.sh failed at line ${line_no} with exit code ${exit_code}." >&2
  echo "Last command: ${BASH_COMMAND}" >&2
  echo >&2
  echo "Useful checks:" >&2
  echo "  - xcodebuild errors are in build/release/logs/xcodebuild-*.log" >&2
  echo "  - GitHub CLI auth: gh auth status" >&2
  echo "  - Existing releases/tags: gh release list --repo ${REPO_SLUG}" >&2
  echo "  - Working tree: git status --short" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_file() {
  [[ -e "$1" ]] || fail "Required file/path not found: $1"
}

validate_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must be semantic patch form X.Y.Z, got: $1"
}

current_setting() {
  local key="$1"
  local value
  value="$(grep -E "^[[:space:]]*${key} = " "$PROJECT_FILE" | head -n 1 | sed -E "s/.*${key} = ([^;]+);/\1/")"
  [[ -n "$value" ]] || fail "Could not read ${key} from ${PROJECT_FILE}"
  printf '%s' "$value"
}

increment_patch() {
  local version="$1"
  validate_semver "$version"
  IFS=. read -r major minor patch <<< "$version"
  printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

increment_build() {
  local build="$1"
  [[ "$build" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION must be an integer, got: $build"
  printf '%s' "$((build + 1))"
}

replace_project_setting() {
  local key="$1"
  local value="$2"
  local count
  count="$(grep -cE "^[[:space:]]*${key} = " "$PROJECT_FILE" || true)"
  [[ "$count" -gt 0 ]] || fail "No ${key} entries found in ${PROJECT_FILE}"
  /usr/bin/perl -0pi -e "s/${key} = [^;]+;/${key} = ${value};/g" "$PROJECT_FILE"
  local new_count
  new_count="$(grep -cE "^[[:space:]]*${key} = ${value};" "$PROJECT_FILE" || true)"
  [[ "$new_count" -eq "$count" ]] || fail "Expected to update ${count} ${key} entries to ${value}, updated ${new_count}"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

create_background_png() {
  local output="$1"
  /usr/bin/swift - "$output" <<'SWIFT'
import AppKit
import Foundation

let output = CommandLine.arguments[1]
let size = NSSize(width: 640, height: 420)
let image = NSImage(size: size)
image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
let bg = NSGradient(starting: NSColor(calibratedRed: 0.075, green: 0.083, blue: 0.105, alpha: 1),
                    ending: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.23, alpha: 1))!
bg.draw(in: rect, angle: 90)

let accent = NSColor(calibratedRed: 0.33, green: 0.75, blue: 1.0, alpha: 1)
let muted = NSColor(calibratedWhite: 1.0, alpha: 0.72)
let white = NSColor.white

let title = "MacOS Accessibility Client"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
    .foregroundColor: white
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (size.width - titleSize.width) / 2, y: 350), withAttributes: titleAttrs)

let subtitle = "Drag the app to Applications"
let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: muted
]
let subtitleSize = subtitle.size(withAttributes: subtitleAttrs)
subtitle.draw(at: NSPoint(x: (size.width - subtitleSize.width) / 2, y: 322), withAttributes: subtitleAttrs)

let path = NSBezierPath()
path.move(to: NSPoint(x: 250, y: 205))
path.curve(to: NSPoint(x: 390, y: 205), controlPoint1: NSPoint(x: 292, y: 245), controlPoint2: NSPoint(x: 348, y: 245))
accent.setStroke()
path.lineWidth = 7
path.lineCapStyle = .round
path.stroke()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 390, y: 205))
arrow.line(to: NSPoint(x: 366, y: 225))
arrow.move(to: NSPoint(x: 390, y: 205))
arrow.line(to: NSPoint(x: 366, y: 185))
arrow.lineWidth = 7
arrow.lineCapStyle = .round
accent.setStroke()
arrow.stroke()

let appLabel = "App"
let appsLabel = "Applications"
let labelAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: muted
]
appLabel.draw(at: NSPoint(x: 171, y: 88), withAttributes: labelAttrs)
appsLabel.draw(at: NSPoint(x: 405, y: 88), withAttributes: labelAttrs)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Could not render DMG background PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
SWIFT
  [[ -s "$output" ]] || fail "Failed to create DMG background image at $output"
}

run_finder_layout() {
  local volume_name="$1"
  local mount_dir="$2"
  local background_path="$3"
  /usr/bin/osascript <<APPLESCRIPT
try
  set mountedFolder to POSIX file "${mount_dir}" as alias
  tell application "Finder"
    open mountedFolder
    delay 1
    set dmgWindow to Finder window 1
    set current view of dmgWindow to icon view
    set toolbar visible of dmgWindow to false
    set statusbar visible of dmgWindow to false
    set the bounds of dmgWindow to {100, 100, 740, 520}
    set viewOptions to the icon view options of dmgWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to ${DMG_ICON_SIZE}
    set background picture of viewOptions to POSIX file "${background_path}"
    set position of item "${APP_NAME}.app" of mountedFolder to {180, 215}
    set position of item "Applications" of mountedFolder to {460, 215}
    update mountedFolder without registering applications
    delay 1
    close dmgWindow
  end tell
  return "Finder DMG layout applied successfully for ${volume_name}"
on error errMsg number errNum
  return "ERROR applying Finder DMG layout (" & errNum & "): " & errMsg
end try
APPLESCRIPT
}

make_dmg() {
  local app_path="$1"
  local version="$2"
  local dist_dir="$ROOT_DIR/build/release/dist"
  local work_dir="$ROOT_DIR/build/release/dmg-work"
  local volume_name="${DISPLAY_NAME} ${version}"
  local dmg_name="${APP_NAME}-${version}.dmg"
  local rw_dmg="$work_dir/${APP_NAME}-${version}-rw.dmg"
  local final_dmg="$dist_dir/$dmg_name"

  rm -rf "$work_dir"
  mkdir -p "$work_dir/staging/.background" "$dist_dir"
  rm -f "$final_dmg" "$rw_dmg"

  log "Preparing DMG staging area"
  cp -R "$app_path" "$work_dir/staging/${APP_NAME}.app"
  ln -s /Applications "$work_dir/staging/Applications"
  create_background_png "$work_dir/staging/.background/background.png"

  local size_mb
  size_mb="$(( $(du -sm "$work_dir/staging" | awk '{print $1}') + 80 ))"

  log "Creating writable DMG (${size_mb} MB)"
  hdiutil create -volname "$volume_name" -srcfolder "$work_dir/staging" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${size_mb}m" "$rw_dmg" >/dev/null

  log "Mounting DMG to apply Finder presentation"
  local attach_output mount_dir device
  attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "$rw_dmg")"
  mount_dir="$(printf '%s\n' "$attach_output" | awk '/\/Volumes\// {print substr($0, index($0,"/Volumes/")); exit}')"
  device="$(printf '%s\n' "$attach_output" | awk '/^\/dev\// {print $1; exit}')"
  [[ -n "$mount_dir" && -d "$mount_dir" ]] || fail "Could not determine DMG mount point. hdiutil output: $attach_output"
  [[ -n "$device" ]] || fail "Could not determine DMG device. hdiutil output: $attach_output"

  local layout_output
  set +e
  layout_output="$(run_finder_layout "$volume_name" "$mount_dir" "$mount_dir/.background/background.png")"
  local layout_status=$?
  echo "$layout_output" >&2
  sync
  hdiutil detach "$device" >/dev/null
  local detach_status=$?
  set -e
  [[ "$detach_status" -eq 0 ]] || fail "Could not detach temporary DMG device ${device}; hdiutil detach exited ${detach_status}"
  [[ "$layout_status" -eq 0 ]] || fail "Finder DMG layout command failed with status ${layout_status}"
  [[ "$layout_output" != ERROR* ]] || fail "$layout_output"

  log "Converting DMG to compressed read-only image"
  hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$final_dmg" >/dev/null
  hdiutil verify "$final_dmg" >/dev/null

  if [[ "$KEEP_WORK" -eq 0 ]]; then
    rm -rf "$work_dir"
  else
    warn "Keeping DMG work directory: $work_dir"
  fi

  [[ -s "$final_dmg" ]] || fail "Final DMG was not created: $final_dmg"
  printf '%s' "$final_dmg"
}

confirm_publish() {
  [[ "$YES" -eq 1 ]] && return 0
  cat <<EOF

About to publish GitHub release:
  Repository: ${REPO_SLUG}
  Version:    ${NEW_VERSION}
  Tag:        ${TAG}
  DMG:        ${DMG_PATH}

This will commit the version bump, push main + tag, and create a public GitHub release.
EOF
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || fail "Publish cancelled by user. Local DMG remains at: ${DMG_PATH}"
}

release_notes() {
  local version="$1"
  local previous_tag
  previous_tag="$(git tag --list 'v*' --sort=-v:refname | grep -v "^v${version}$" | head -n 1 || true)"
  {
    echo "Release ${version} of ${DISPLAY_NAME}."
    echo
    echo "## Install"
    echo "1. Download the DMG asset below."
    echo "2. Open it and drag ${DISPLAY_NAME} to Applications."
    echo "3. Launch the app and grant Accessibility permission when prompted."
    echo
    echo "## Changes"
    if [[ -n "$previous_tag" ]]; then
      git log --pretty='- %s (%h)' "${previous_tag}..HEAD"
    else
      git log --pretty='- %s (%h)' --max-count=20
    fi
  } > "$ROOT_DIR/build/release/RELEASE_NOTES_${version}.md"
  printf '%s' "$ROOT_DIR/build/release/RELEASE_NOTES_${version}.md"
}

log "Checking prerequisites"
require_cmd git
require_cmd xcodebuild
require_cmd hdiutil
require_cmd osascript
require_cmd swift
require_cmd perl
require_cmd awk
require_file "$PROJECT_FILE"

if [[ "$SKIP_GITHUB" -eq 0 ]]; then
  require_cmd gh
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -z "$(git status --porcelain)" ]] || fail "Working tree is not clean. Commit/stash changes first, or use --dry-run.\n$(git status --short)"
fi

OLD_VERSION="$(current_setting MARKETING_VERSION)"
OLD_BUILD="$(current_setting CURRENT_PROJECT_VERSION)"
validate_semver "$OLD_VERSION"

if [[ -n "$OVERRIDE_VERSION" ]]; then
  validate_semver "$OVERRIDE_VERSION"
  NEW_VERSION="$OVERRIDE_VERSION"
else
  NEW_VERSION="$(increment_patch "$OLD_VERSION")"
fi
NEW_BUILD="$(increment_build "$OLD_BUILD")"
TAG="v${NEW_VERSION}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  NEW_VERSION="$OLD_VERSION"
  NEW_BUILD="$OLD_BUILD"
  TAG="v${NEW_VERSION}-dry-run"
  log "Dry run: using existing version ${NEW_VERSION} (${NEW_BUILD}); project files will not be modified"
else
  log "Bumping version: ${OLD_VERSION} (${OLD_BUILD}) -> ${NEW_VERSION} (${NEW_BUILD})"
  replace_project_setting MARKETING_VERSION "$NEW_VERSION"
  replace_project_setting CURRENT_PROJECT_VERSION "$NEW_BUILD"
fi

BUILD_ROOT="$ROOT_DIR/build/release"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
LOG_DIR="$BUILD_ROOT/logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
XCODE_LOG="$LOG_DIR/xcodebuild-${TIMESTAMP}.log"
mkdir -p "$LOG_DIR"

log "Building ${APP_NAME} Release with xcodebuild"
rm -rf "$DERIVED_DATA"
set +e
xcodebuild \
  -project "$PROJECT_REL" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'generic/platform=macOS' \
  clean build \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$XCODE_LOG"
XCODE_STATUS=${PIPESTATUS[0]}
set -e
[[ "$XCODE_STATUS" -eq 0 ]] || fail "xcodebuild failed with status ${XCODE_STATUS}. See log: $XCODE_LOG"

APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
require_file "$APP_PATH/Contents/Info.plist"
[[ -x "$APP_PATH/Contents/MacOS/${APP_NAME}" ]] || fail "Built app executable missing or not executable: $APP_PATH/Contents/MacOS/${APP_NAME}"

BUILT_VERSION="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)"
BUILT_BUILD="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleVersion)"
[[ "$BUILT_VERSION" == "$NEW_VERSION" ]] || fail "Built app version mismatch: expected ${NEW_VERSION}, got ${BUILT_VERSION}"
[[ "$BUILT_BUILD" == "$NEW_BUILD" ]] || fail "Built app build mismatch: expected ${NEW_BUILD}, got ${BUILT_BUILD}"
success "Built ${APP_NAME}.app version ${BUILT_VERSION} (${BUILT_BUILD})"

log "Creating professional drag-to-Applications DMG"
DMG_PATH="$(make_dmg "$APP_PATH" "$NEW_VERSION")"
success "Created DMG: $DMG_PATH"

if [[ "$SKIP_GITHUB" -eq 1 ]]; then
  success "Local release build complete (GitHub publishing skipped)."
  echo "DMG: $DMG_PATH"
  exit 0
fi

if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  fail "GitHub release ${TAG} already exists. Choose a new --version or delete the existing release."
fi
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  fail "Local tag ${TAG} already exists. Choose a new --version or delete the tag."
fi
if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  fail "Remote tag ${TAG} already exists on origin. Choose a new --version or delete the remote tag."
fi

confirm_publish

log "Committing version bump"
git add "$PROJECT_FILE"
git commit -m "Release ${NEW_VERSION}"

git tag -a "$TAG" -m "Release ${NEW_VERSION}"

log "Pushing main and tag to GitHub"
git push origin HEAD:main
git push origin "$TAG"

NOTES_FILE="$(release_notes "$NEW_VERSION")"

log "Creating GitHub release and uploading DMG asset"
gh release create "$TAG" "$DMG_PATH" \
  --repo "$REPO_SLUG" \
  --title "${DISPLAY_NAME} ${NEW_VERSION}" \
  --notes-file "$NOTES_FILE"

log "Verifying GitHub release and DMG asset"
RELEASE_JSON="$(gh release view "$TAG" --repo "$REPO_SLUG" --json tagName,url,assets)"
printf '%s' "$RELEASE_JSON" > "$BUILD_ROOT/release-${NEW_VERSION}.json"
printf '%s' "$RELEASE_JSON" | grep -q '"tagName":"'"$TAG"'"' || fail "GitHub release verification failed: tag ${TAG} not found in release JSON"
printf '%s' "$RELEASE_JSON" | grep -q "$(basename "$DMG_PATH")" || fail "GitHub release verification failed: DMG asset missing from release JSON"

ASSET_URL="$(gh release view "$TAG" --repo "$REPO_SLUG" --json assets --jq '.assets[] | select(.name == "'"$(basename "$DMG_PATH")"'") | .url' | head -n 1)"
[[ -n "$ASSET_URL" ]] || fail "GitHub release verification failed: could not read DMG asset URL"

success "Published and verified ${DISPLAY_NAME} ${NEW_VERSION}"
echo "Release: https://github.com/${REPO_SLUG}/releases/tag/${TAG}"
echo "DMG:     $DMG_PATH"
echo "Asset:   $ASSET_URL"
echo
echo "Note: For direct GitHub/public distribution, the numeric CFBundleVersion can increment with each release as done here. A perpetually increasing build number is required for App Store uploads and is also a safe convention outside the App Store."
