#!/bin/bash
# Run DiRT 3 on the Mac with the same launch options as the IPA.
#   scripts/run-dirt3-mac.sh                 # window, log to logs/mac-run-*.log
#   VAR=value scripts/run-dirt3-mac.sh       # any option overrides the JSON
#   DIRT3_LLDB=1 scripts/run-dirt3-mac.sh     # under lldb (stops on the first crash)
#   DIRT3_SECONDS=90 scripts/run-dirt3-mac.sh # stop after 90 s
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/build/mac/dirt3_runner"
ELF="$ROOT/game/PS3_GAME/USRDIR/EBOOT.elf"
DATA="$ROOT/build/mac-run"
[ -x "$RUNNER" ] || { echo "No $RUNNER: run scripts/build-dirt3-mac.sh first"; exit 1; }

# Launch options from the IPA profile; variables already set win (like setenv(...,0) on iOS).
eval "$(python3 - "$ROOT/port/ios/dirt3-runtime-options.json" <<'EOF'
import json, os, shlex, sys
for k, v in json.load(open(sys.argv[1])).items():
    if k not in os.environ:
        print(f'export {k}={shlex.quote(str(v))}')
EOF
)"
mkdir -p "$DATA/dev_hdd0" "$DATA/dev_hdd1" "$DATA/msl" "$ROOT/logs"
export PS3_HDD0_ROOT="$DATA/dev_hdd0" PS3_HDD1_ROOT="$DATA/dev_hdd1" PS3RECOMP_MSL_CACHE="$DATA/msl"
export PS3_VFS_ROOT="$ROOT/game"
export DYLD_FALLBACK_LIBRARY_PATH="/opt/homebrew/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"   # FFmpeg (dlopen)
cd "$DATA"

LOG="$ROOT/logs/mac-run-$(date +%Y%m%d-%H%M%S).log"
echo "Log: $LOG"
if [ "${DIRT3_LLDB:-0}" = 1 ]; then
    exec lldb -o "process handle SIGUSR1 SIGUSR2 SIGPIPE -n true -p true -s false" \
              -o run -- "$RUNNER" "$ELF"
fi
if [ "${DIRT3_LLDB:-0}" = watch ]; then
    # Heap-corruption hunt: ASSERT_WATCH + hardware watchpoint (tools/lldb_assert_watch.py).
    export ASSERT_WATCH=1
    lldb --batch -o "process handle SIGUSR1 SIGUSR2 SIGPIPE -n true -p true -s false" \
         -o "command script import '$ROOT/tools/lldb_assert_watch.py'" -o run \
         -k "thread backtrace all" -k "kill" -- "$RUNNER" "$ELF" > "$LOG" 2>&1 &
else
    "$RUNNER" "$ELF" > "$LOG" 2>&1 &
fi
PID=$!
if [ -n "${DIRT3_SECONDS:-}" ]; then
    ( sleep "$DIRT3_SECONDS"; pkill -9 -x dirt3_runner; kill -9 "$PID" 2>/dev/null ) &
fi
wait "$PID"; RC=$?
echo "exit $RC"
exit $RC
