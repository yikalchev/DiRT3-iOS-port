#!/usr/bin/env python3
"""Build a discovered SPU registry while bounding functions at embedded text data.

Some WRC 5 SPU ELFs have printable strings inside their executable PT_LOAD.
The upstream boundary finder can extend a function range through those strings,
where the lifter reports the data words as unsupported SPU instructions. This
adapter preserves the upstream boundaries everywhere except that it ends a
function immediately before a printable unknown word. The workload generator
still rejects any unsupported code or unresolved direct branch/call target.
"""
from pathlib import Path
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
    insns = _disassemble_spu(buf, base_addr=base_addr)
    return [insn for insn in insns
            if not any(start <= insn.addr < end for start, end in text_runs)]


def _printable_unknown(insn):
    if insn is None or insn.mnemonic != ".word":
        return False
    raw = int(insn.raw).to_bytes(4, "big")
    return sum(0x20 <= byte <= 0x7e for byte in raw) >= 3


def _find_end_with_text_data(start, insns_by_addr, sorted_starts, code_end):
    natural_end = _find_end(start, insns_by_addr, sorted_starts, code_end)
    for address in range(start, natural_end, 4):
        if _printable_unknown(insns_by_addr.get(address)):
            return address
    return natural_end


find_spu_functions.find_end = _find_end_with_text_data
find_spu_functions.disassemble_spu = _disassemble_without_embedded_ascii

import build_spu_workloads

if __name__ == "__main__":
    build_spu_workloads.main()
