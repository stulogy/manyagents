#!/usr/bin/env bash
# deploy.sh — build the ManyAgents phone app and put it somewhere useful.
#
#   ./ios/deploy.sh                 # connected iPhone if there is one, else a simulator
#   ./ios/deploy.sh simulator       # force the simulator
#   ./ios/deploy.sh <device-udid>   # a specific device
#
# Device builds need an Apple Development signing identity, which means
# Xcode → Settings → Accounts signed in with your Apple ID at least once.
# Simulator builds need no signing at all, which is why that's the fallback.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
SCHEME=ManyAgentsPhone
BUNDLE_ID=co.ailogy.manyagents.phone
TARGET="${1:-auto}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

b() { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
ok() { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

command -v xcodegen >/dev/null || die "xcodegen missing — brew install xcodegen"
b "xcodegen"
xcodegen generate >/dev/null
ok "project regenerated"

# ── Pick a destination ────────────────────────────────────────────────
DEVICE_UDID=""
if [[ "$TARGET" != "simulator" ]]; then
    if [[ "$TARGET" != "auto" ]]; then
        DEVICE_UDID="$TARGET"
    else
        DEVICE_UDID="$(xcrun devicectl list devices 2>/dev/null \
            | awk '/connected/ && /iPhone|iPad/ {print $(NF-1); exit}')" || true
    fi
fi

if [[ -n "$DEVICE_UDID" ]]; then
    b "Building for device $DEVICE_UDID"
    xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" \
        -destination "id=$DEVICE_UDID" -configuration Debug \
        -derivedDataPath build/device build | tail -3
    APP="build/device/Build/Products/Debug-iphoneos/ManyAgents.app"
    [[ -d "$APP" ]] || die "build produced no app at $APP"
    b "Installing"
    xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" >/dev/null
    ok "installed on device — launch it from the home screen"
    exit 0
fi

# ── Simulator ─────────────────────────────────────────────────────────
b "No device; using a simulator"
RUNTIME_COUNT="$(xcrun simctl list runtimes 2>/dev/null | grep -c iOS || true)"
[[ "$RUNTIME_COUNT" -gt 0 ]] || die "no iOS simulator runtimes installed — run: xcodebuild -downloadPlatform iOS"

SIM_UDID="$(xcrun simctl list devices available \
    | awk '/iPhone/ {match($0, /\(([0-9A-F-]{36})\)/, m); if (m[1]) {print m[1]; exit}}')" || true
if [[ -z "$SIM_UDID" ]]; then
    SIM_UDID="$(xcrun simctl list devices available | grep -oE '[0-9A-F-]{36}' | head -1)"
fi
[[ -n "$SIM_UDID" ]] || die "no available simulator to boot"

xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
open -a Simulator
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" \
    -destination "id=$SIM_UDID" -configuration Debug \
    -derivedDataPath build/sim build | tail -3
APP="build/sim/Build/Products/Debug-iphonesimulator/ManyAgents.app"
[[ -d "$APP" ]] || die "build produced no app at $APP"
xcrun simctl install "$SIM_UDID" "$APP"
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >/dev/null
ok "running in the simulator ($SIM_UDID)"
echo
echo "Pair it without a camera by opening the pairing link:"
echo "  xcrun simctl openurl booted \"\$(pbpaste)\"   # after copying the code from the Mac"
