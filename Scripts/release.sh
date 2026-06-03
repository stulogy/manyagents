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
NOTARY_PROFILE="manyagents-notary"  # see Scripts/README.md to create
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
command -v create-dmg >/dev/null || die "create-dmg missing — \`brew install create-dmg\`"
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
    MARKETING_VERSION="$VERSION" \
    clean build \
    | xcbeautify 2>/dev/null || true
test -d "$APP_PATH" || die "build did not produce $APP_PATH"
ok "built $APP_PATH"

# ── Verify signature ──────────────────────────────────────────────────
b "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier" || true
ok "signature valid"

# ── Notarize ──────────────────────────────────────────────────────────
b "Notarizing (zipping → submitting → waiting)"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
ok "notarization accepted"

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
create-dmg \
    --volname "ManyAgents $VERSION" \
    --window-pos 200 120 \
    --window-size 600 360 \
    --icon-size 96 \
    --icon "$SCHEME.app" 160 180 \
    --hide-extension "$SCHEME.app" \
    --app-drop-link 440 180 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGE" >/dev/null
ok "DMG: $DMG_PATH"

# ── Sign + staple the DMG itself ──────────────────────────────────────
# Notarizing the DMG (separate from the .app) means Gatekeeper trusts
# it on download without needing to unmount-and-restaple.
b "Signing + notarizing DMG"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
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
fi

# ── Summary ───────────────────────────────────────────────────────────
b "Done"
ls -lh "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
if [[ "$PUBLISH" != "1" ]]; then
    echo
    echo "To publish:  Scripts/release.sh $VERSION --publish"
fi
