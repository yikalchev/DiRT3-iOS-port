#!/bin/sh
set -eu

# Lift DiRT 3's PPU and SPU code from game/PS3_GAME/USRDIR/EBOOT.elf.
# Outputs: port/recompiled (PPU C++), port/spu (SPU images + registry),
# research/dirt3 (function/import analysis). Takes a long time; run once.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GAME_DIR=${DIRT3_GAME_DIR:-"$ROOT/game"}
ELF="$GAME_DIR/PS3_GAME/USRDIR/EBOOT.elf"
RESEARCH="$ROOT/research/dirt3"
RECOMP="$ROOT/port/recompiled"
SPU="$ROOT/port/spu"
SDK="$ROOT/vendor/ps3recomp/tools"

if [ ! -f "$ELF" ]; then
    printf 'error: DiRT 3 ELF not found: %s\n' "$ELF" >&2
    exit 1
fi
for tool in ppu_loader.py gen_imports.py find_functions.py ppu_lifter.py build_spu_workloads.py; do
    if [ ! -f "$SDK/$tool" ]; then
        printf 'error: missing ps3recomp tool: %s\n' "$SDK/$tool" >&2
        exit 1
    fi
done

mkdir -p "$RESEARCH/ppu" "$RECOMP" "$SPU"

python3 "$SDK/ppu_loader.py" "$ELF" -o "$RESEARCH/ppu"
python3 "$SDK/gen_imports.py" "$ELF" -o "$RESEARCH/imports-named.json"
python3 "$SDK/find_functions.py" "$ELF" \
    --seed-json "$RESEARCH/ppu/EBOOT.functions.json" \
    -o "$RESEARCH/functions.json"

# Bound the lift at the end of the executable ELF sections (from the ELF itself).
CODE_END=$(python3 - "$ELF" "$SDK" <<'PY'
import sys
from pathlib import Path

elf_path, sdk_tools = sys.argv[1:]
sys.path.insert(0, sdk_tools)
from elf_parser import ELFFile

elf = ELFFile(elf_path)
elf.load()
ends = [section.sh_addr + section.sh_size
        for section in elf.section_headers
        if section.sh_flags & 0x4 and section.sh_size]
if not ends:
    raise SystemExit("error: ELF has no executable sections; refusing an unbounded PPU lift")
print(hex(max(ends)))
PY
)

python3 "$SDK/ppu_lifter.py" "$ELF" \
    --functions "$RESEARCH/functions.json" \
    --hle-stubs "$RESEARCH/ppu/EBOOT.imports.json" \
    --code-end "$CODE_END" --chunks 96 --jobs 4 \
    -o "$RECOMP"

python3 "$ROOT/tools/build_spu_workloads_text_data.py" --input "$ELF" \
    --lifted "$SPU" --out "$SPU/spu_workloads.c" \
    --constructor --title "DiRT 3"

# Raw SPURS policy modules embedded in the EBOOT (not SPU ELFs): RSXHelper.
python3 "$ROOT/tools/lift_dirt3_jobs.py" --elf "$ELF" --out "$SPU"

# SPURS job binaries (raw "JOBCRT" code, not embedded ELFs) are not lifted here.
# If the title runs SPURS job chains, find each job binary's EA and size from
# the "[cellSpurs] job[...] eaBinary=" log lines and lift it the way the WRC 5
# port did (see ps3-ports/titles/wrc5/tools/lift_wrc5_jobs.py).

printf 'DiRT 3 analysis sources generated under %s\n' "$ROOT/port"
printf 'ELF: %s\nExecutable code end: %s\n' "$ELF" "$CODE_END"
