#!/bin/zsh
# Publish a notarized GaugeZ.app as a GitHub release: one DMG and the Sparkle appcast.
#
#   scripts/release.sh /path/to/GaugeZ.app [release-notes.md]
#
# Requirements: gh (logged in), the Sparkle private key in the login Keychain
# under the GaugeZ account, a Developer ID signed + notarized + stapled app, and the
# `GaugeZ` notarytool keychain profile (the DMG is notarized here).
set -euo pipefail

REPO="${GAUGEZ_REPO:-vzandli/GaugeZ}"
APP="${1:?usage: release.sh /path/to/GaugeZ.app [release-notes.md]}"
NOTES="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/releases"
NOTARY_PROFILE="${GAUGEZ_NOTARY_PROFILE:-GaugeZ}"

# Sparkle's tools ship inside the SwiftPM artifact that Xcode downloaded.
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d -print -quit 2>/dev/null)"
[[ -n "$SPARKLE_BIN" ]] || { echo "Sparkle tools not found. Build GaugeZ in Xcode once."; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
TAG="v$VERSION"
ARCHIVE="GaugeZ-$VERSION.dmg"

echo "==> Verifying $APP ($VERSION, build $BUILD)"
codesign --verify --deep --strict "$APP"
SIGNING_INFO="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNING_INFO" == *'Authority=Developer ID Application'* ]] || { echo "App is not signed with Developer ID."; exit 1; }
IDENTITY="$(print -r -- "$SIGNING_INFO" | sed -n 's/^Authority=\(Developer ID Application.*\)$/\1/p' | head -1)"
xcrun stapler validate "$APP" >/dev/null || { echo "App is not stapled. Notarize and run: xcrun stapler staple \"$APP\""; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists on $REPO."; exit 1
fi

# The appcast is generated in a folder holding this version alone: no older archives means
# no delta files, and the release carries just the DMG and the feed.
echo "==> Packaging $ARCHIVE"
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gaugez-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/dmg" "$WORK/feed"
ditto "$APP" "$WORK/dmg/GaugeZ.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "GaugeZ $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$WORK/feed/$ARCHIVE" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$WORK/feed/$ARCHIVE"

echo "==> Notarizing the DMG"
xcrun notarytool submit "$WORK/feed/$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$WORK/feed/$ARCHIVE"
spctl --assess --type open --context context:primary-signature "$WORK/feed/$ARCHIVE"

[[ -n "$NOTES" ]] && cp "$NOTES" "$WORK/feed/GaugeZ-$VERSION.md"

echo "==> Generating appcast"
"$SPARKLE_BIN/generate_appcast" \
  --account GaugeZ \
  --versions "$BUILD" \
  --maximum-deltas 0 \
  --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO/releases" \
  --full-release-notes-url "https://github.com/$REPO/releases/tag/$TAG" \
  "$WORK/feed"
grep -q "sparkle:edSignature" "$WORK/feed/appcast.xml" || { echo "The appcast entry is not signed."; exit 1; }

rm -f "$OUT"/*.dmg(N) "$OUT"/*.delta(N) "$OUT/appcast.xml"
cp "$WORK/feed/$ARCHIVE" "$WORK/feed/appcast.xml" "$OUT/"
[[ -n "$NOTES" ]] && cp "$NOTES" "$OUT/GaugeZ-$VERSION.md"

echo "==> Creating GitHub release $TAG"
NOTES_ARGS=(--generate-notes)
[[ -n "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "$TAG" "$OUT/$ARCHIVE" "$OUT/appcast.xml" --repo "$REPO" --title "GaugeZ $VERSION" "${NOTES_ARGS[@]}"

echo "==> Done. Feed: https://github.com/$REPO/releases/latest/download/appcast.xml"
