#!/usr/bin/env python3
"""Build a discovered SPU registry with verified embedded-data boundaries.

Some SPU ELFs (first seen in WRC 5) have printable strings inside their executable PT_LOAD.
The upstream boundary finder can extend a function range through those strings,
where the lifter reports data words as unsupported SPU instructions. This
adapter bounds printable strings and hash-verified per-title data ranges. The
workload generator still rejects any unsupported code or unresolved direct
branch/call target.
"""
from pathlib import Path
import hashlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SDK = ROOT / "vendor/ps3recomp/tools"
if not (SDK / "build_spu_workloads.py").is_file():
    raise SystemExit(f"missing ps3recomp tools at {SDK}")
sys.path.insert(0, str(SDK))

import find_spu_functions

_find_end = find_spu_functions.find_end
_disassemble_spu = find_spu_functions.disassemble_spu
_current_embedded_data_range = None

# Exact image fingerprints gate these per-title data ranges (WRC 5 images below). The first
# six share a metadata/string block after a resumable stop. One image has a
# rodata tail after a real `bi $r0` return, and one has a single table word.
# None of the excluded addresses is a direct call/branch target; stripping the
# decoded data instructions also prevents their bytes from seeding fake code.
EMBEDDED_DATA = {
    "6eff733b005560d0d9979d14e955a7ce382c96da87702e14140f56c51751d627": [(0x15324, 0x15370)],
    "29bab0d25a21b2c08bb0f1286298775a257a4f90064e0b75b13ec9e6c430b4ee": [(0x1C364, 0x1C3B0)],
    "3656cfe75479930c412aee82861a274faa8cb1534e0dfe8ef269981edd06a3f6": [(0x1B984, 0x1B9E8)],
    "7e654a39b90389ff40029114d903eaa9f4c36fdc3e00d81d1d6a1995baaee616": [(0x19D94, 0x19DF8)],
    "c86b01483781d80fe19bd418686010e40b371e5d145da91e9bb1e56f7ca78339": [(0x205B4, 0x20600)],
    "1eb0168a44eb8eaf0056edbc54cd0e8384cb7eb13caac6e0e1e1c591c615fc68": [
        (0x23774, 0x237D8), (0x23830, 0x23834)],
    "0b4b704930e5ea8ca2d0228a5f8bd5515561bf05c2b06498a613b1a883fa7a33": [(0x19CA0, 0x1A9B0)],
}


def _disassemble_without_embedded_ascii(buf, base_addr=0):
    """Keep text bytes out of instruction discovery as well as lifting.

    SPU ELFs in this title put strings in executable PT_LOAD ranges. Filtering
    the decoded instructions here prevents their accidental branch-looking
    words from becoming false function seeds.
    """
    text_runs = []
    for match in re.finditer(rb"[\x20-\x7e]{8,}", buf):
        start = (match.start() // 4) * 4
        end = ((match.end() + 3) // 4) * 4
        text_runs.append((base_addr + start, base_addr + end))
    global _current_embedded_data_range
    insns = _disassemble_spu(buf, base_addr=base_addr)
    data_ranges = EMBEDDED_DATA.get(hashlib.sha256(buf).hexdigest(), [])
    _current_embedded_data_range = data_ranges
    for data_start, data_end in data_ranges:
        if not (base_addr <= data_start < data_end <= base_addr + len(buf)):
            raise ValueError("verified DiRT 3 data range is outside its executable segment")
    if data_ranges:
        insns = [insn for insn in insns
                 if not any(start <= insn.addr < end for start, end in data_ranges)]
    return [insn for insn in insns
            if not any(start <= insn.addr < end for start, end in text_runs)]


def _printable_unknown(insn):
    if insn is None or insn.mnemonic != ".word":
        return False
    raw = int(insn.raw).to_bytes(4, "big")
    return sum(0x20 <= byte <= 0x7e for byte in raw) >= 3


def _find_end_with_text_data(start, insns_by_addr, sorted_starts, code_end):
    natural_end = _find_end(start, insns_by_addr, sorted_starts, code_end)
    for data_start, data_end in _current_embedded_data_range or []:
        if start < data_start < natural_end:
            return data_start
    for address in range(start, natural_end, 4):
        if _printable_unknown(insns_by_addr.get(address)):
            return address
    return natural_end


find_spu_functions.find_end = _find_end_with_text_data
find_spu_functions.disassemble_spu = _disassemble_without_embedded_ascii

import build_spu_workloads

if __name__ == "__main__":
    build_spu_workloads.main()
