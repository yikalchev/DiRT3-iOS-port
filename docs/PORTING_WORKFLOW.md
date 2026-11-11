# Reusable PS3 / Switch porting workflow notes

This is a working checklist for adapting a game-specific native-port repository
to another title. Keep each title's decrypted game data and generated source in
separate, ignored directories. Do not overwrite a working title's generated
files, build caches, or platform baseline.

Reusable PS3 tooling and improvements from this work are also kept in the local
`/Users/yosif/Documents/FreelanceProjects/ps3-ports` repository. When a later
build adds or changes something that is useful across PS3 titles, copy the
reviewed reusable files and update that repository's README/porting notes.
Keep title-specific code and data out of the template unless clearly labeled as
an example. A separate `switch-ports` template is deferred until the next Switch
port task.

## Before changing a project

1. Read the repository guidance and README. Check the working-tree status so
   existing local changes are preserved.
2. Identify the source format and exact game root. Record the title ID, version,
   executable path, and whether the executable is already decrypted. Keep keys,
   tickets, NSPs, ISOs, and decrypted executables out of Git.
3. Trace the full build chain from source data to app: extract/decrypt, survey,
   profile, PPU/SPU or shader generation, platform runtime, launcher settings,
   packaging, and final artifact location.
4. Split generic tooling from title-specific assumptions. Hashes, code addresses,
   module IDs, shader readers, instruction decoders, performance specializations,
   and guessed profiles must be checked before reusing them.
5. Give the new title its own generated-source and build directories. Change the
   app display name, bundle ID, and icon independently from internal engine
   names where renaming internal identifiers would expand the risk.
6. Build one platform at a time. Confirm the artifact's name, path, size, and
   timestamp, and report any provisional profile or incomplete coverage plainly.

## Dragon's Dogma: Dark Arisen case study

Known project and input locations from the prior work:

- Project: `/Users/yosif/Documents/FreelanceProjects/DragonDogma`
- Original Switch dump: `/Volumes/SD-512GB/NSwitch (MelonX)/Dragon Dogma - Dark Arisen`
- Local working copy used for faster reads / available disk space:
  `/Users/yosif/Desktop/Dragon Dogma - Dark Arisen`
- App name requested: `[AS] Dragon's Dogma - Dark Arisen`
- Bundle ID requested earlier: `com.anubissoft.dragonsdogma.darkarisen`
- Keys are supplied locally as `prod.keys`; never commit them.

The build script surveyed title ID `010032C00AC58000`, extracted its modules
and RomFS manifest, and wrote a provisional profile under the game's build
folder. The build log warned that profile values were guesses and that the game
might not boot. Shader splitting first failed on zlib decompression in an MT
Framework ARC archive; a later run reported that it found no shaders in the
main executable or RomFS. NSP/container inspection and a title-specific shader
reader were the investigation path discussed. Do not assume that those decoder
issues were resolved merely because packaging later completed.

An IPA was reported completed at:

`/Users/yosif/Desktop/Dragon Dogma - Dark Arisen/[AS] Dragon's Dogma - Dark Arisen.ipa`

Its reported size was about 1.2 GB, and it was built from a provisional profile.
A later `--platform mac` run built the Mac host/launch path; it did not replace
the IPA. The user reported that the game ran on the Mac, while the build output
continued to label the profile provisional. Preserve that distinction when
describing validation.

Build environment lessons from that project:

- If multiple Xcode installations exist, select the intended one explicitly
  with `DEVELOPER_DIR` for the build process.
- A missing Metal compiler toolchain was resolved by installing the Metal
  Toolchain component for the selected Xcode installation.
- When a build fails in survey, shader splitting, profile validation, or
  packaging, fix that specific stage before treating another successful target
  build as equivalent.
- Record whether the game data is read from an external volume, a local working
  copy, or app Documents. Do not silently change that storage model.

## Current WRC 5 work

- Project: `/Users/yosif/Documents/FreelanceProjects/WRC 5`
- Game root: `game/` inside the project.
- Executable: `game/PS3_GAME/USRDIR/EBOOT.elf`
- The dump identifies as WRC 5 FIA World Rally Championship, title ID
  `BLUS31549`, version `01.01`.
- `tools/analyze_wrc5.sh` was added to lift PPU and SPU code into the ignored
  `build/wrc5-analysis/` tree rather than overwrite MotorStorm's `port/` tree.
- The PPU stage generated 74,560 functions. The SPU workload scan found 57
  programs; 31 were rejected by the current lifter because `.word` data was
  emitted as unsupported instructions. The SPU inventory is incomplete, so
  there is not yet a WRC 5 IPA build path.
- The Xcode project and runtime build helper still contain MotorStorm-specific
  targets, IDs, generated-source paths, and optimizations. Do not run the
  existing MotorStorm IPA workflow against the WRC ELF until the WRC-generated
  sources are wired into a separate build configuration.

