#!/bin/zsh
# Publish a notarized GaugeZ.app as a GitHub release with a Sparkle appcast.
#
#   scripts/release.sh /path/to/GaugeZ.app [release-notes.md]
#
# Requirements: gh (logged in), the Sparkle private key in the login Keychain
# under the GaugeZ account, and a Developer ID signed + notarized + stapled app.
set -euo pipefail

REPO="${GAUGEZ_REPO:-vzandli/GaugeZ}"
APP="${1:?usage: release.sh /path/to/GaugeZ.app [release-notes.md]}"
NOTES="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/releases"

# Sparkle's tools ship inside the SwiftPM artifact that Xcode downloaded.
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)"
[[ -n "$SPARKLE_BIN" ]] || { echo "Sparkle tools not found. Build GaugeZ in Xcode once."; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
TAG="v$VERSION"
ARCHIVE="GaugeZ-$VERSION.zip"

echo "==> Verifying $APP ($VERSION, build $BUILD)"
codesign --verify --deep --strict "$APP"
SIGNING_INFO="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNING_INFO" == *'Authority=Developer ID Application'* ]] || { echo "App is not signed with Developer ID."; exit 1; }
xcrun stapler validate "$APP" >/dev/null || { echo "App is not stapled. Notarize and run: xcrun stapler staple \"$APP\""; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists on $REPO."; exit 1
fi

echo "==> Packaging"
mkdir -p "$OUT"
rm -f "$OUT/$ARCHIVE" "$OUT"/*.delta(N)
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ARCHIVE"
[[ -n "$NOTES" ]] && cp "$NOTES" "$OUT/GaugeZ-$VERSION.md"

echo "==> Fetching previous releases (for appcast history and delta updates)"
for tag in $(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 3 --json tagName -q '.[].tagName'); do
  gh release download "$tag" --repo "$REPO" --pattern '*.zip' --dir "$OUT" --clobber || true
done
LATEST="$(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' || true)"
if [[ -n "$LATEST" ]]; then
  gh release download "$LATEST" --repo "$REPO" --pattern appcast.xml --dir "$OUT" --clobber || true
fi

echo "==> Generating appcast"
"$SPARKLE_BIN/generate_appcast" \
  --account GaugeZ \
  --versions "$BUILD" \
  --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO/releases" \
  --full-release-notes-url "https://github.com/$REPO/releases/tag/$TAG" \
  "$OUT"

# generate_appcast rewrites every enclosure with the new release's download prefix, but older
# archives live on their own releases. Point each older item back at its own vX.Y.Z tag.
echo "==> Restoring download URLs for previous versions"
VERSION="$VERSION" TAG="$TAG" perl -0pi -e '
  s{<item>.*?</item>}{
    my $item = $&;
    if ($item =~ m{<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>} && $1 ne $ENV{VERSION}) {
      my $own = "v$1";
      $item =~ s{/releases/download/\Q$ENV{TAG}\E/}{/releases/download/$own/}g;
    }
    $item
  }gse' "$OUT/appcast.xml"

echo "==> Creating GitHub release $TAG"
ASSETS=("$OUT/$ARCHIVE" "$OUT/appcast.xml" "$OUT"/*.delta(N))
NOTES_ARGS=(--generate-notes)
[[ -n "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --title "GaugeZ $VERSION" "${NOTES_ARGS[@]}"

echo "==> Done. Feed: https://github.com/$REPO/releases/latest/download/appcast.xml"
