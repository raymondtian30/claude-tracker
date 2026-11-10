#!/usr/bin/env bash
# Build "Claude Tracker.app" so the app shows up in Finder's Applications.
#
# Compiles the Swift sources in this folder with Apple's compiler (from
# Xcode's Command Line Tools), then puts the bundle together: the app
# itself, its icon, an Info.plist that points back at this folder (where
# state.json and the logs stay), and an ad hoc signature.
#
# Usage:
#     ./build.sh [--dest DIR]
#
# DIR defaults to /Applications if you can write to it, else
# ~/Applications. The new bundle is built in a temporary folder next to
# DIR and only swapped in once everything worked, so a failed build leaves
# the old app as it was.
#
# Progress goes to stderr. The last line on stdout is the path of the
# bundle's executable (install.sh points the start-at-login LaunchAgent at
# it).
set -euo pipefail

APP_NAME="Claude Tracker"
BUNDLE_ID="com.raymondtian.claudetracker"
EXECUTABLE_NAME="claude-tracker"
ICON_NAME="AppIcon"
PRODUCT="ClaudeTracker"
MIN_SWIFT_MAJOR=5
MIN_SWIFT_MINOR=9
MIN_MACOS_MAJOR=13

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

fail() {
    echo "$*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 [--dest DIR]" >&2
    exit 2
}

DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)
            [ $# -ge 2 ] || usage
            DEST="$2"
            shift 2
            ;;
        --dest=*)
            DEST="${1#--dest=}"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [ -z "$DEST" ]; then
    if [ -w /Applications ]; then
        DEST="/Applications"
    else
        DEST="$HOME/Applications"
    fi
fi

# --- Can this Mac build it? ---------------------------------------------

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]; then
    fail "Claude Tracker needs macOS ${MIN_MACOS_MAJOR} or newer; this Mac has macOS $(sw_vers -productVersion)."
fi

# Without the Command Line Tools, /usr/bin/swift still exists but only
# prints an xcrun error, so run it rather than just looking for it.
if ! command -v swift >/dev/null 2>&1 || ! SWIFT_VERSION_TEXT="$(swift --version 2>&1)"; then
    fail "Swift not found: run xcode-select --install in Terminal to get Xcode's Command Line Tools, then try again."
fi
SWIFT_VERSION="$(printf '%s\n' "$SWIFT_VERSION_TEXT" \
    | sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p' | head -n 1)"
if [ -z "$SWIFT_VERSION" ]; then
    fail "Couldn't tell which Swift version this Mac has (swift --version printed: ${SWIFT_VERSION_TEXT})."
fi
SWIFT_MAJOR="${SWIFT_VERSION%%.*}"
SWIFT_MINOR="${SWIFT_VERSION#*.}"
if [ "$SWIFT_MAJOR" -lt "$MIN_SWIFT_MAJOR" ] \
    || { [ "$SWIFT_MAJOR" -eq "$MIN_SWIFT_MAJOR" ] && [ "$SWIFT_MINOR" -lt "$MIN_SWIFT_MINOR" ]; }; then
    fail "Claude Tracker needs Swift ${MIN_SWIFT_MAJOR}.${MIN_SWIFT_MINOR} or newer, but this Mac has Swift ${SWIFT_VERSION}. Update Xcode's Command Line Tools in Software Update (or run xcode-select --install), then try again."
fi

# --- Version and credits, from the Swift sources -------------------------

version_field() {
    sed -n "s/.*static let $1 = \"\(.*\)\".*/\1/p" "$PROJECT_DIR/Sources/TrackerCore/Version.swift" | head -n 1
}
VERSION="$(version_field version)"
ORIGINAL_AUTHOR="$(version_field originalAuthor)"
FORK_AUTHOR="$(version_field forkAuthor)"
[ -n "$VERSION" ] || fail "Couldn't read the version from Sources/TrackerCore/Version.swift."

# --- Compile -------------------------------------------------------------

echo "Compiling Claude Tracker ${VERSION} (Swift ${SWIFT_VERSION})..." >&2
cd "$PROJECT_DIR"
# The compiler's cache (.build) holds absolute paths, so after this folder was
# moved or renamed it can't be used and the build fails. .build/.built-in says
# where it was made: from anywhere else (or from before it said), start again.
if [ -d .build ] && [ "$(cat .build/.built-in 2>/dev/null)" != "$PROJECT_DIR" ]; then
    rm -rf .build
fi
swift build -c release --product "$PRODUCT" >&2 || fail "Compiling Claude Tracker failed (see above)."
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BIN_DIR/$PRODUCT"
[ -x "$BINARY" ] || fail "The compiler didn't produce $BINARY."
mkdir -p .build && printf '%s\n' "$PROJECT_DIR" > .build/.built-in

# --- Assemble the bundle in a temporary folder next to DEST ---------------

mkdir -p "$DEST" || fail "Couldn't create $DEST."
DEST="$(cd "$DEST" && pwd -P)"
BUNDLE="$DEST/$APP_NAME.app"
STAGING="$(mktemp -d "$DEST/.claude-tracker-build.XXXXXX")" || fail "Couldn't write to $DEST."
cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

NEW_BUNDLE="$STAGING/$APP_NAME.app"
mkdir -p "$NEW_BUNDLE/Contents/MacOS" "$NEW_BUNDLE/Contents/Resources"
cp "$BINARY" "$NEW_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
chmod 755 "$NEW_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp "$PROJECT_DIR/Resources/$ICON_NAME.icns" "$NEW_BUNDLE/Contents/Resources/$ICON_NAME.icns"

PLIST="$NEW_BUNDLE/Contents/Info.plist"
plutil -create xml1 "$PLIST"
set_string() { plutil -insert "$1" -string "$2" "$PLIST"; }
set_bool() { plutil -insert "$1" -bool "$2" "$PLIST"; }
set_string CFBundleName "$APP_NAME"
set_string CFBundleDisplayName "$APP_NAME"
set_string CFBundleIdentifier "$BUNDLE_ID"
set_string CFBundleExecutable "$EXECUTABLE_NAME"
set_string CFBundleIconFile "$ICON_NAME"
set_string CFBundlePackageType APPL
set_string CFBundleShortVersionString "$VERSION"
set_string CFBundleVersion "$VERSION"
set_string CFBundleInfoDictionaryVersion "6.0"
set_string LSMinimumSystemVersion "${MIN_MACOS_MAJOR}.0"
# Menu bar only: no Dock icon, no app menu.
set_bool LSUIElement YES
set_bool NSHighResolutionCapable YES
set_string NSHumanReadableCopyright "Original app by ${ORIGINAL_AUTHOR}. Redesign and new features by ${FORK_AUTHOR}."
# Where state.json, friends.json and the logs live: this git clone.
set_string ClaudeTrackerProjectDir "$PROJECT_DIR"

# Ad hoc signature, so it covers Info.plist. macOS only lets the app post
# notifications if the signature carries the bundle's identifier ("Allow
# notifications" in System Settings belongs to it).
codesign --force --sign - --identifier "$BUNDLE_ID" "$NEW_BUNDLE" >&2 \
    || fail "Signing the app failed."

# --- Swap it in ---------------------------------------------------------

# Move the old bundle aside first (mv onto an existing folder would put the
# new one inside it), and put it back if the new one can't go in.
if [ -e "$BUNDLE" ]; then
    mv "$BUNDLE" "$STAGING/old.app" || fail "Couldn't replace $BUNDLE."
fi
if ! mv "$NEW_BUNDLE" "$BUNDLE"; then
    [ -e "$STAGING/old.app" ] && mv "$STAGING/old.app" "$BUNDLE"
    fail "Couldn't move the new app to $BUNDLE."
fi

# Tell Finder/Launchpad about the new bundle and refresh its icon.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$BUNDLE" >/dev/null 2>&1 || true
fi

echo "Built $BUNDLE"
echo "$BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
