#!/bin/sh
set -eu

# Generate WRC 5's PPU and SPU sources into an isolated build tree. This deliberately
# does not run any MotorStorm-specific policy, job, wait, or audio lift scripts.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GAME_DIR=${WRC5_GAME_DIR:-"$ROOT/game"}
ELF="$GAME_DIR/PS3_GAME/USRDIR/EBOOT.elf"
OUT=${WRC5_ANALYSIS_DIR:-"$ROOT/build/wrc5-analysis"}
SDK="$ROOT/vendor/ps3recomp/tools"

if [ ! -f "$ELF" ]; then
    printf 'error: WRC 5 ELF not found: %s\n' "$ELF" >&2
    exit 1
fi
for tool in ppu_loader.py gen_imports.py find_functions.py ppu_lifter.py build_spu_workloads.py; do
    if [ ! -f "$SDK/$tool" ]; then
        printf 'error: missing ps3recomp tool: %s\n' "$SDK/$tool" >&2
        exit 1
    fi
done

mkdir -p "$OUT/research/ppu" "$OUT/recompiled" "$OUT/spu"

python3 "$SDK/ppu_loader.py" "$ELF" -o "$OUT/research/ppu"
python3 "$SDK/gen_imports.py" "$ELF" -o "$OUT/research/imports-named.json"
python3 "$SDK/find_functions.py" "$ELF" \
    --seed-json "$OUT/research/ppu/EBOOT.functions.json" \
    -o "$OUT/research/functions.json"

# Bound the lift at the end of the executable ELF sections. The MotorStorm
# pipeline used a title-specific literal here; the WRC 5 value comes from its ELF.
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
    --functions "$OUT/research/functions.json" \
    --hle-stubs "$OUT/research/ppu/EBOOT.imports.json" \
    --code-end "$CODE_END" --chunks 96 --jobs 4 \
    -o "$OUT/recompiled"

python3 "$SDK/build_spu_workloads.py" --input "$ELF" \
    --lifted "$OUT/spu" --out "$OUT/spu/spu_workloads.c" \
    --constructor --title "WRC 5"

printf 'WRC 5 analysis sources generated under %s\n' "$OUT"
printf 'ELF: %s\nExecutable code end: %s\n' "$ELF" "$CODE_END"
