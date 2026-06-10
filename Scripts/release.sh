#!/usr/bin/env bash
# Build, sign, notarize, staple, and DMG a Release build of ManyAgents
# ready for download from a website. See Scripts/README.md for one-time
# setup (cert + notarytool keychain profile + create-dmg install).
#
# Usage:
#   Scripts/release.sh                       # version from git describe
#   Scripts/release.sh 0.3.1                 # explicit version
#   Scripts/release.sh 0.3.1 --publish       # also upload to GitHub Releases
#
# Output: dist/ManyAgents-<version>.dmg
# Publish: creates tag v<version> + GitHub Release with the DMG attached.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────
DEVELOPER_ID="Developer ID Application: AILOGY LLC (44KY89SZJD)"
TEAM_ID="44KY89SZJD"
BUNDLE_ID="app.manyagents"
NOTARY_PROFILE="manyagents-notary-key"  # App Store Connect API key — see Scripts/README.md
SCHEME="ManyAgents"
CONFIG="Release"

# ── Paths ─────────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION=""
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        -*)        echo "unknown flag: $arg" >&2; exit 2 ;;
        *)         VERSION="$arg" ;;
    esac
done
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")}"
VERSION="${VERSION#v}"  # strip leading v if tag was v0.3.1

BUILD_DIR="$ROOT/build/release"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$SCHEME.app"
DIST_DIR="$ROOT/dist"
DMG_PATH="$DIST_DIR/$SCHEME-$VERSION.dmg"
ZIP_PATH="$BUILD_DIR/$SCHEME-$VERSION.zip"

mkdir -p "$DIST_DIR"

# ── Coloured stage headers ────────────────────────────────────────────
b() { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
ok() { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────
b "Preflight"
command -v xcodegen >/dev/null   || die "xcodegen missing — \`brew install xcodegen\`"
command -v create-dmg >/dev/null || printf "\033[1;33m! create-dmg missing — will build a plain hdiutil DMG (\`brew install create-dmg\` for the styled one)\033[0m\n"
command -v xcrun >/dev/null      || die "xcrun missing — install Xcode CLT"
security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID" \
    || die "Cert not in keychain: $DEVELOPER_ID"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool profile '$NOTARY_PROFILE' missing — see Scripts/README.md"
ok "version $VERSION · team $TEAM_ID"

# ── Regenerate project ────────────────────────────────────────────────
b "xcodegen"
xcodegen generate >/dev/null
ok "ManyAgents.xcodeproj regenerated"

# ── Build + sign in one pass ──────────────────────────────────────────
b "xcodebuild ($CONFIG, hardened runtime, Developer ID)"
xcodebuild \
    -project ManyAgents.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    -destination "platform=macOS" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    MARKETING_VERSION="$VERSION" \
    clean build \
    | xcbeautify 2>/dev/null || true
test -d "$APP_PATH" || die "build did not produce $APP_PATH"
ok "built $APP_PATH"

# ── Re-sign Sparkle's nested helpers ──────────────────────────────────
# xcodebuild signs the app + Sparkle.framework, but NOT the helper
# executables buried inside it (Autoupdate, Updater.app, XPC services) with
# a secure timestamp + Developer ID — Apple's notary rejects those. Re-sign
# inside-out, then re-seal the framework and the app (with entitlements).
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    b "Re-signing Sparkle helpers (hardened runtime + timestamp)"
    SIGN=(codesign -f -o runtime --timestamp -s "$DEVELOPER_ID")
    V="$SPARKLE/Versions/Current"
    for xpc in "$V/XPCServices/"*.xpc; do
        [[ -e "$xpc" ]] && "${SIGN[@]}" "$xpc"
    done
    [[ -e "$V/Updater.app/Contents/MacOS/Updater" ]] && "${SIGN[@]}" "$V/Updater.app/Contents/MacOS/Updater"
    [[ -e "$V/Updater.app" ]] && "${SIGN[@]}" "$V/Updater.app"
    [[ -e "$V/Autoupdate" ]] && "${SIGN[@]}" "$V/Autoupdate"
    "${SIGN[@]}" "$SPARKLE"
    "${SIGN[@]}" --entitlements "$ROOT/Resources/ManyAgents.entitlements" "$APP_PATH"
    ok "Sparkle helpers re-signed"
fi

# ── Verify signature ──────────────────────────────────────────────────
b "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier" || true
ok "signature valid"

# ── Notarize ──────────────────────────────────────────────────────────
# notarytool exits 0 on `status: Invalid` (it succeeded at submitting,
# Apple just rejected the binary), so trusting the exit code is a bug.
# Parse the status line and bail with the submission id so the operator
# can pull the rejection log immediately.
b "Notarizing (zipping → submitting → waiting)"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1)"
echo "$SUBMIT_OUT"
NOTARY_STATUS="$(printf '%s\n' "$SUBMIT_OUT" \
    | awk -F: '/^[[:space:]]*status:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' \
    | tail -1)"
SUBMIT_ID="$(printf '%s\n' "$SUBMIT_OUT" \
    | awk '/^[[:space:]]*id:/ {gsub(/^[[:space:]]+id:[[:space:]]+|[[:space:]]+$/, ""); print; exit}')"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo
    echo "Pulling rejection log…"
    xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | head -60 || true
    die "notarization rejected — status: '$NOTARY_STATUS' · id: $SUBMIT_ID"
fi
ok "notarization accepted (id: $SUBMIT_ID)"

# ── Staple ────────────────────────────────────────────────────────────
b "Stapling ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
ok "stapled — app works offline"

# ── DMG ───────────────────────────────────────────────────────────────
b "Building DMG"
rm -f "$DMG_PATH"
# A staging dir keeps the DMG clean — only the .app, nothing from the
# build tree leaks in.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/"
# Preferred path: create-dmg gives a styled window (icon layout +
# Applications drop target). It styles the window by scripting Finder over
# AppleScript, which only works from an interactive GUI (Aqua) session — it
# fails (-10006) under SSH / CI / any shell not attached to the desktop.
# Fall back to a plain hdiutil image in that case so the release still
# completes unattended; the DMG is unstyled but functionally identical
# (drag the app onto the Applications symlink). Wrapped in `if` so
# create-dmg's non-zero exit doesn't trip `set -e`.
if command -v create-dmg >/dev/null && create-dmg \
    --volname "ManyAgents $VERSION" \
    --window-pos 200 120 \
    --window-size 600 360 \
    --icon-size 96 \
    --icon "$SCHEME.app" 160 180 \
    --hide-extension "$SCHEME.app" \
    --app-drop-link 440 180 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGE" >/dev/null 2>&1 && [[ -f "$DMG_PATH" ]]; then
    ok "DMG: $DMG_PATH (styled)"
else
    b "create-dmg styling unavailable (no Finder automation) — plain hdiutil DMG"
    rm -f "$DMG_PATH"
    # create-dmg may leave its temp image mounted after an AppleScript abort.
    hdiutil detach "/Volumes/ManyAgents $VERSION" >/dev/null 2>&1 || true
    ln -sf /Applications "$STAGE/Applications"
    hdiutil create \
        -volname "ManyAgents $VERSION" \
        -srcfolder "$STAGE" \
        -fs HFS+ \
        -format UDZO \
        -ov \
        "$DMG_PATH" >/dev/null
    ok "DMG: $DMG_PATH (plain)"
fi

# ── Sign + staple the DMG itself ──────────────────────────────────────
# Notarizing the DMG (separate from the .app) means Gatekeeper trusts
# it on download without needing to unmount-and-restaple.
b "Signing + notarizing DMG"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"
DMG_SUBMIT_OUT="$(xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1)"
echo "$DMG_SUBMIT_OUT"
DMG_STATUS="$(printf '%s\n' "$DMG_SUBMIT_OUT" \
    | awk -F: '/^[[:space:]]*status:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' \
    | tail -1)"
DMG_ID="$(printf '%s\n' "$DMG_SUBMIT_OUT" \
    | awk '/^[[:space:]]*id:/ {gsub(/^[[:space:]]+id:[[:space:]]+|[[:space:]]+$/, ""); print; exit}')"
if [[ "$DMG_STATUS" != "Accepted" ]]; then
    xcrun notarytool log "$DMG_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | head -60 || true
    die "DMG notarization rejected — status: '$DMG_STATUS' · id: $DMG_ID"
fi
xcrun stapler staple "$DMG_PATH"
ok "DMG signed, notarized, stapled"

# ── Publish to GitHub Releases ────────────────────────────────────────
if [[ "$PUBLISH" == "1" ]]; then
    b "Publishing GitHub Release v$VERSION"
    command -v gh >/dev/null || die "gh missing — \`brew install gh\` and \`gh auth login\`"
    [[ "$VERSION" == *-dirty* ]] && die "version is -dirty; commit + tag first"

    TAG="v$VERSION"
    # Create the tag locally if it doesn't exist yet.
    if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        git tag -a "$TAG" -m "ManyAgents $VERSION"
        git push origin "$TAG"
        ok "tagged $TAG and pushed"
    else
        ok "tag $TAG already exists"
    fi

    SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    NOTES_FILE="$(mktemp)"
    trap 'rm -rf "$STAGE" "$NOTES_FILE"' EXIT
    cat > "$NOTES_FILE" <<EOF
Download **ManyAgents-$VERSION.dmg** below. Open it, drag ManyAgents to
Applications, launch.

The build is signed with Apple Developer ID and notarized by Apple, so
Gatekeeper will let it open without ceremony.

\`\`\`
SHA-256  $SHA
\`\`\`

Source: this same commit (\`$TAG\`).
EOF

    gh release create "$TAG" "$DMG_PATH" \
        --title "ManyAgents $VERSION" \
        --notes-file "$NOTES_FILE"
    ok "released — https://github.com/stulogy/manyagents/releases/tag/$TAG"

    # ── Sparkle appcast ───────────────────────────────────────────────
    # EdDSA-sign the DMG and append an <item> to the GitHub-Pages appcast so
    # existing users auto-update. The enclosure points at the Release asset
    # we just uploaded; only the small XML lives on Pages.
    # NOTE: CFBundleVersion (sparkle:version) MUST increase every release for
    # Sparkle to detect the update — bump it in Resources/Info.plist.
    b "Updating Sparkle appcast"
    SIGN_UPDATE="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
    [[ -x "$SIGN_UPDATE" ]] || die "sign_update not found at $SIGN_UPDATE (build first)"
    SIG_ATTRS="$("$SIGN_UPDATE" "$DMG_PATH")"   # -> sparkle:edSignature="…" length="…"
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
    PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
    DL_URL="https://github.com/stulogy/manyagents/releases/download/$TAG/$SCHEME-$VERSION.dmg"
    APPCAST="$ROOT/docs/appcast.xml"
    ITEM="$(cat <<EOF
    <item>
      <title>$VERSION</title>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <link>https://github.com/stulogy/manyagents/releases/tag/$TAG</link>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$PUBDATE</pubDate>
      <enclosure url="$DL_URL" $SIG_ATTRS type="application/octet-stream"/>
    </item>
EOF
)"
    # Insert newest item just after the channel's <language> line. Read the
    # item from a temp file (not `awk -v`, which can't take a multi-line
    # value — it errors "newline in string").
    ITEM_FILE="$(mktemp)"
    printf '%s\n' "$ITEM" > "$ITEM_FILE"
    awk 'FNR==NR { buf = buf $0 ORS; next }
         { print }
         /<language>en<\/language>/ { printf "%s", buf }' \
        "$ITEM_FILE" "$APPCAST" > "$APPCAST.tmp" && mv "$APPCAST.tmp" "$APPCAST"
    rm -f "$ITEM_FILE"
    git add "$APPCAST"
    git commit -m "appcast: ManyAgents $VERSION" >/dev/null
    git push origin HEAD
    ok "appcast updated + pushed — https://stulogy.github.io/manyagents/appcast.xml"
fi

# ── Summary ───────────────────────────────────────────────────────────
b "Done"
ls -lh "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
if [[ "$PUBLISH" != "1" ]]; then
    echo
    echo "To publish:  Scripts/release.sh $VERSION --publish"
fi
