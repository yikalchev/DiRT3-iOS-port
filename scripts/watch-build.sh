#!/bin/bash
# Live view of a running scripts/build-dirt3-ios.sh (or `watch-build.sh mac` for
# scripts/build-dirt3-mac.sh). Ctrl-C stops only this view.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NINJA_LOG="$ROOT/build/ios/iphoneos/.ninja_log"
[ "${1:-}" = mac ] && NINJA_LOG="$ROOT/build/mac/.ninja_log"
IPA="$ROOT/output/DIRT3-AnubisSoft.ipa"
TOTAL=$(ls "$ROOT"/port/recompiled/ppu_recomp_[0-9]*.cpp 2>/dev/null | wc -l | tr -d ' ')
START=$(date +%s)

while true; do
    done_ppu=0; done_all=0
    if [ -f "$NINJA_LOG" ]; then
        done_ppu=$(grep -c 'ppu_recomp_[0-9]*\.cpp\.o' "$NINJA_LOG")
        done_all=$(grep -vc '^#' "$NINJA_LOG")
    fi
    pct=$(( TOTAL > 0 ? done_ppu * 100 / TOTAL : 0 ))
    filled=$(( pct / 2 ))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((50 - filled)) '' | tr ' ' '.')

    clear
    printf 'DiRT 3 IPA build  -  %s  (watching %dm)\n\n' "$(date '+%H:%M:%S')" $(( ($(date +%s) - START) / 60 ))
    printf 'Game code  [%s] %3d%%  (%d / %d files)\n' "$bar" "$pct" "$done_ppu" "$TOTAL"
    printf 'All build steps finished: %d\n\n' "$done_all"

    printf 'Compiling now:\n'
    # Compiler driver processes (not clang -cc1); the object path has no spaces.
    active=$(ps -Ao etime=,command= | grep -E 'usr/bin/(c\+\+|cc|clang|clang\+\+) ' | grep -v ' -cc1 ' |
        grep -- ' -o ' | sed -E 's#^ *([0-9:-]+) .* -o ([^ ]*/)?([^/ ]+)\.o( .*)?$#\1  \3#' | sort -k2 -u)
    if [ -n "$active" ]; then printf '%s\n' "$active" | sed 's/^/  /'; else printf '  (nothing)\n'; fi

    printf '\nStage: '
    if [ -f "$IPA" ] && [ "$IPA" -nt "$NINJA_LOG" ]; then
        printf 'DONE - IPA ready: %s (%s, %s)\n' "$IPA" "$(du -h "$IPA" | cut -f1)" "$(date -r "$IPA" '+%H:%M')"
    elif pgrep -q xcodebuild || pgrep -qx ninja; then
        if [ -n "$active" ]; then printf 'compiling\n'; else printf 'linking / packaging the app\n'; fi
    else
        printf 'no build running (check logs/ for the latest dirt3-ipa-*.log)\n'
    fi
    sleep 2
done
