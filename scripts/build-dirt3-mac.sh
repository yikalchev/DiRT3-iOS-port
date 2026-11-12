#!/bin/bash
# Build the macOS command-line debug runner (build/mac/dirt3_runner).
# Same runtime and lifted game code as the IPA, built natively for Apple
# Silicon with debug symbols, so crashes and memory corruption can be chased
# with lldb and watchpoints instead of one sideload per attempt.
#
# Needs native (arm64) Homebrew: sdl2 glslang spirv-cross ffmpeg cmake ninja.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BREW=/opt/homebrew
BUILD="$ROOT/build/mac"
mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/dirt3-mac-$(date +%Y%m%d-%H%M%S).log"
export PATH="$BREW/bin:$PATH"

{
    if [ ! -f "$BUILD/build.ninja" ]; then
        cmake -S "$ROOT/port" -B "$BUILD" -G Ninja \
            -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_PREFIX_PATH="$BREW" \
            -DPS3RECOMP_FFMPEG_RUNTIME=ON \
            -DPS3RECOMP_FFMPEG_INCLUDE_DIR="$BREW/include"
    fi
    cmake --build "$BUILD" --target dirt3_runner -- -j"$(sysctl -n hw.ncpu)"
    echo "Runner: $BUILD/dirt3_runner"
} 2>&1 | tee "$LOG"
