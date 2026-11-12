#!/bin/bash
# Build a sideloadable (unsigned) DiRT 3 IPA: output/DIRT3-AnubisSoft.ipa
#
# Prerequisites (once): vendor/ps3recomp (tools/bootstrap_runtime.py), the game in
# game/ and lifted sources in port/ (tools/analyze_dirt3.sh). iOS dependencies are
# built automatically on first run. Sideload with SideStore/AltStore/LiveContainer,
# then copy the repo's game/ folder into the app's Documents (Files app:
# "On My iPhone > [AS] DiRT 3 > game").
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="$ROOT/logs"
OUTPUT_DIR="$ROOT/output"
LOG_FILE="$LOG_DIR/dirt3-ipa-$STAMP.log"
DERIVED_DATA="$ROOT/build/xcode/DerivedData"
INVENTORY="$ROOT/port/spu/inventory.json"
GAME_DIR="$ROOT/game"
IPA="$OUTPUT_DIR/DIRT3-AnubisSoft.ipa"

mkdir -p "$LOG_DIR" "$OUTPUT_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'status=$?; if [ "$status" -ne 0 ]; then printf "\nBuild stopped (exit %s). Log: %s\n" "$status" "$LOG_FILE"; fi' EXIT

printf 'DiRT 3 iOS build started: %s\n' "$(date)"
printf 'Log file: %s\n' "$LOG_FILE"

for tool in xcodebuild python3 cmake ninja ditto zip unzip; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'Missing required tool: %s\n' "$tool" >&2; exit 2; }
done
[ -f "$ROOT/vendor/ps3recomp/CMakeLists.txt" ] || { printf 'Missing vendor/ps3recomp. Run: python3 tools/bootstrap_runtime.py\n' >&2; exit 2; }
[ -f "$GAME_DIR/PS3_GAME/USRDIR/EBOOT.elf" ] || { printf 'Missing game/PS3_GAME/USRDIR/EBOOT.elf (decrypted DiRT 3 executable).\n' >&2; exit 2; }
[ -f "$ROOT/port/recompiled/ppu_recomp.h" ] || { printf 'Missing lifted PPU code. Run: sh tools/analyze_dirt3.sh\n' >&2; exit 2; }
[ -f "$ROOT/port/spu/spu_workloads.c" ] && [ -f "$INVENTORY" ] || { printf 'Missing lifted SPU code. Run: sh tools/analyze_dirt3.sh\n' >&2; exit 2; }
python3 - "$INVENTORY" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if not data.get('complete'):
    print('SPU coverage is incomplete; refusing to build an IPA from partial code.')
    for item in data.get('programs', []):
        if item.get('status') not in ('generated', 'registered'):
            print(f"  {item.get('name')}: {item.get('status')}")
    raise SystemExit(3)
print(f"SPU inventory is complete ({len(data.get('programs', []))} images).")
PY

if [ ! -f "$ROOT/build/ios-deps/iphoneos/ready.json" ]; then
    printf '\nBuilding iOS dependencies (SDL2, glslang, SPIRV-Cross, FFmpeg)...\n'
    python3 "$ROOT/tools/build_ios_dependencies.py" --sdk iphoneos
fi

printf '\nBuilding DIRT3 with Xcode...\n'
xcodebuild -project "$ROOT/DIRT3/DIRT3.xcodeproj" -scheme DIRT3 \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" build \
    DIRT3_DIAGNOSTICS="${DIRT3_DIAGNOSTICS:-1}" \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/DIRT3.app"
[ -d "$APP_PATH" ] || { printf 'Xcode completed without producing %s\n' "$APP_PATH" >&2; exit 4; }
[ -f "$APP_PATH/DIRT3Launch.json" ] || { printf 'App is missing DIRT3Launch.json\n' >&2; exit 4; }

PAYLOAD_ROOT="$ROOT/build/ipa"
rm -rf "$PAYLOAD_ROOT"
mkdir -p "$PAYLOAD_ROOT/Payload"
# Copy without resource forks/xattrs: AppleDouble (._*) files or a __MACOSX/
# folder inside the IPA make SideStore/AltStore signing fail ("invalid bundle").
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP_PATH" "$PAYLOAD_ROOT/Payload/DIRT3.app"
find "$PAYLOAD_ROOT/Payload" -name '._*' -exec rm -f {} +
rm -f "$IPA"
(cd "$PAYLOAD_ROOT" && COPYFILE_DISABLE=1 /usr/bin/zip -qry -X "$IPA" Payload)
if /usr/bin/unzip -Z1 "$IPA" | grep -Eq '(^__MACOSX/|/\._)'; then
    printf 'IPA contains macOS metadata entries; refusing to ship it.\n' >&2; exit 5
fi
/usr/bin/unzip -Z1 "$IPA" | grep -qx 'Payload/DIRT3.app/Info.plist' || { printf 'IPA layout is wrong (no Payload/DIRT3.app/Info.plist).\n' >&2; exit 5; }

printf '\nIPA created: %s (%s)\n' "$IPA" "$(du -h "$IPA" | cut -f1)"
printf 'Build log: %s\n' "$LOG_FILE"
printf 'Unsigned IPA: sideload with SideStore/AltStore/LiveContainer, then copy game/ into the app Documents.\n'
