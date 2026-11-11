# PS3 Ports — reusable starting point

This local repository collects reusable PS3 native-port tooling, the pinned
ps3recomp runtime integration, the Xcode app shell, and notes from the
MotorStorm and WRC 5 investigations. It contains no game dump, decrypted ELF,
firmware, save, generated game code, or build output.

## Starting a new title

1. Read `AGENTS.md` and `docs/PORTING_WORKFLOW.md`.
2. Put only your own decrypted game executable in the ignored `game/` folder.
3. Make new title-specific output and build folders; never reuse another title's PPU/SPU lift, title ID, input manifest, or optimization profile.
4. Start with the generic ps3recomp lift and a baseline runtime. Keep the copied
   MotorStorm optimizations disabled until each one is proven to match the new
   title.
5. Update app metadata, bundle identifier, launcher file checks, and icon for
   the new title. Build and validate each target separately.

The Xcode project and runtime sources here are a **reference scaffold**, not a
ready-to-run generic emulator. The current `tools/analyze_wrc5.sh` is a WRC 5
example: its PPU lift completed, while the SPU inventory is incomplete because
the current lifter treats some embedded data words as unsupported code. It
does not create an IPA.

`vendor/ps3recomp` is intentionally not copied. `tools/bootstrap_runtime.py`
restores the pinned open-source checkout and applies the tracked patch in
`patches/ps3recomp-local.patch`; network access and the required build tools
are needed for that step.
