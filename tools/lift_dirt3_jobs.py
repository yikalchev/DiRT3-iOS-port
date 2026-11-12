#!/usr/bin/env python3
"""Lift DiRT 3's raw (non-ELF) SPU code that tools/analyze_dirt3.sh cannot find.

build_spu_workloads.py only discovers SPU programs embedded as ELF images. DiRT 3
also embeds raw SPURS policy modules in EBOOT.elf's data and hands them to
cellSpursAddWorkloadWithAttribute directly. The runtime matches a policy module
by FNV-1a-64 over its exact bytes, loads it at LS 0xA00 and enters at 0xA00
(runtime/spu/spurs_policy.c), so each one is lifted at base 0xA00 and
registered under that fingerprint.

Every entry is keyed by the guest address and size the device log printed
("[cellSpurs] AddWorkloadWA: pm=... size=...") and is checked against the
fingerprint the runtime reported ("PM NOT LIFTED (fp=...)"), so a different disc
build fails loudly here instead of registering the wrong code.

Outputs: port/spu/<name>/spu_recomp.{c,h} (picked up by port/CMakeLists.txt's
*/spu_recomp.c glob) and port/spu/dirt3_jobs_register.c.

Usage: python3 tools/lift_dirt3_jobs.py [--elf game/PS3_GAME/USRDIR/EBOOT.elf] [--out port/spu]
"""
import argparse
import os
import struct
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SDK = os.path.join(ROOT, "vendor", "ps3recomp", "tools")
sys.path.insert(0, SDK)
from wrap_spu_elf import wrap  # noqa: E402

PM_BASE = 0xA00

# name, guest EA, size, expected fingerprint (from the BLES01548 v01.01 device
# log), LS address where code ends (0 = whole image). RSXHelper's last 0x270
# bytes, from LS 0x1810, are its neDmaGet/neDmaPut error strings.
POLICY_MODULES = [
    ("dirt3_pm_rsxhelper", 0x013ABB00, 4224, 0x75E4AADEC909F331, 0x1810),
    ("dirt3_pm_wid1", 0x013BA580, 14736, 0x87CC03697F3D8DC3, 0),
    ("dirt3_pm_wid2", 0x013BDF80, 4064, 0x3C7EB3E780321429, 0),
]

# Image ids for these lifts: clear of build_spu_workloads.py's hash-derived ids.
IMAGE_ID_BASE = 0x3D1A3000


def fnv1a64(data):
    h = 1469598103934665603
    for b in data:
        h ^= b
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h


def read_guest(elf_bytes, ea, size):
    """Read `size` bytes at guest EA from a big-endian ELF64 (PPU) image."""
    if elf_bytes[:4] != b"\x7fELF" or elf_bytes[4] != 2 or elf_bytes[5] != 2:
        sys.exit("error: expected a big-endian ELF64 PPU executable")
    phoff, = struct.unpack_from(">Q", elf_bytes, 0x20)
    phentsize, phnum = struct.unpack_from(">HH", elf_bytes, 0x36)
    for i in range(phnum):
        p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz, _memsz = struct.unpack_from(
            ">IIQQQQQ", elf_bytes, phoff + i * phentsize)
        if p_type == 1 and p_vaddr <= ea and ea + size <= p_vaddr + p_filesz:
            off = p_offset + (ea - p_vaddr)
            return elf_bytes[off:off + size]
    sys.exit(f"error: EA 0x{ea:08X}+0x{size:X} is not inside any file-backed PT_LOAD segment")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--elf", default=os.path.join(ROOT, "game/PS3_GAME/USRDIR/EBOOT.elf"))
    ap.add_argument("--out", default=os.path.join(ROOT, "port/spu"))
    args = ap.parse_args()

    elf_bytes = open(args.elf, "rb").read()
    lifter = os.path.join(SDK, "spu_lifter.py")
    entries = []
    for index, (name, ea, size, expected, code_end) in enumerate(POLICY_MODULES):
        raw = read_guest(elf_bytes, ea, size)
        fp = fnv1a64(raw)
        if fp != expected:
            sys.exit(f"error: {name}: fingerprint 0x{fp:016X} != expected 0x{expected:016X} "
                     f"(different game build?)")
        outdir = os.path.join(args.out, name)
        os.makedirs(outdir, exist_ok=True)
        open(os.path.join(outdir, "code.bin"), "wb").write(raw)
        elf_path = os.path.join(outdir, "image.elf")
        open(elf_path, "wb").write(wrap(raw, base=PM_BASE, entry=PM_BASE))
        prefix = f"{name}_"
        cmd = [sys.executable, lifter, "--auto-functions", elf_path,
               "--base", hex(PM_BASE), "--symbol-prefix", prefix,
               "--extra-funcs", hex(PM_BASE),
               "--report", os.path.join(outdir, "lift.json"),
               "-o", outdir, "--source-name", "spu_recomp.c", "--header-name", "spu_recomp.h"]
        if code_end:
            cmd += ["--code-end", hex(code_end)]
        result = subprocess.run(cmd, capture_output=True, text=True)
        open(os.path.join(outdir, "lift.log"), "w").write(result.stdout + result.stderr)
        if result.returncode != 0:
            sys.exit(f"error: lifting {name} failed; see {outdir}/lift.log\n{result.stderr[-2000:]}")
        source = open(os.path.join(outdir, "spu_recomp.c")).read()
        entry_fn = f"{prefix}spu_func_{PM_BASE:08x}"
        if entry_fn not in source:
            entry_fn = f"{prefix}spu_func_{PM_BASE:08X}"
        if entry_fn not in source:
            sys.exit(f"error: {name}: lifted code has no entry function at LS 0x{PM_BASE:X}")
        register_fn = f"{prefix}spu_recomp_register"
        if register_fn not in source:
            sys.exit(f"error: {name}: lifted code has no {register_fn}()")
        summary = [line.strip() for line in result.stdout.splitlines()
                   if "lifted" in line or "unsupported" in line]
        print(f"  {name}: EA 0x{ea:08X} size {size} fp 0x{fp:016X}; " + "; ".join(summary))
        entries.append((name, IMAGE_ID_BASE + index, fp, entry_fn, register_fn))

    lines = [
        "/* dirt3_jobs_register.c -- GENERATED by tools/lift_dirt3_jobs.py.",
        " * Raw SPURS policy modules embedded in DiRT 3's EBOOT (not SPU ELFs, so",
        " * analyze_dirt3.sh does not see them). Registered by FNV-1a-64 over the",
        " * exact bytes the title passes to cellSpursAddWorkload; run at LS 0xA00. */",
        '#include "spu_workload.h"',
        "",
        "extern void spu_begin_image(int image_id);",
    ]
    for name, _image_id, _fp, entry_fn, register_fn in entries:
        lines.append(f"extern void {entry_fn}(spu_context*);")
        lines.append(f"extern void {register_fn}(void);")
    lines += ["", "__attribute__((constructor(200))) static void dirt3_jobs_register(void)", "{"]
    for name, image_id, fp, entry_fn, register_fn in entries:
        lines.append(f"    spu_begin_image({image_id}); {register_fn}();")
        lines.append(f'    spu_workload_register_img(0x{fp:016X}ULL, {entry_fn}, {image_id}, "{name}");')
    lines += ["    spu_begin_image(0);", "}", ""]
    out_c = os.path.join(args.out, "dirt3_jobs_register.c")
    open(out_c, "w").write("\n".join(lines))
    print(f"Wrote {out_c} ({len(entries)} policy module(s))")


if __name__ == "__main__":
    main()
