# [AS] DiRT 3 — native PS3 port for iOS

A native iOS build of **DiRT 3** (PS3, EU disc
`BLES01548`, version 01.01). The game's PPU and SPU code is recompiled ahead of
time with [ps3recomp](https://github.com/sp00nznet/ps3recomp) and rendered with
Metal. The project began from the MotorStorm port
(<https://github.com/nossramo/motorstorm-ps3>), which remains the reference for
the shared runtime; everything MotorStorm-specific has been removed here.

This project does not include the game, firmware or generated game code. Use
your own legally obtained copy.

## Status

New port, set up on 12 Nov 2026 from the WRC 5 port's iOS shell and runtime
(which includes the fixes found there: real lwcond waits, SPU event-queue
binding, SPURS LF queue / Task2 / urgent commands, cellFsSt*, callback TLS).
Nothing has been verified on a device yet. The game is known to run in RPCS3
on macOS and iOS, so RPCS3 is the reference when the port diverges. The app
writes a session log you can pull from the device (see *Diagnostics*).

## Repository layout

| Path | Contents |
| --- | --- |
| `DIRT3/` | Xcode project, single iOS target/scheme `DIRT3` (UIKit host, touch/Xbox controls, diagnostics) |
| `port/` | Game runner `main.cpp`, CMake build, `ios/dirt3-runtime-options.json` launch environment, dependency pins |
| `port/recompiled/`, `port/spu/` | Lifted DiRT 3 PPU/SPU code — generated, not in Git |
| `vendor/ps3recomp/` | Runtime checkout — restored, not in Git |
| `patches/ps3recomp-local.patch` | All local runtime changes on top of the pinned ps3recomp commit |
| `game/` | Your DiRT 3 files — not in Git |
| `scripts/build-dirt3-ios.sh` | One-command IPA build |
| `tools/` | Runtime bootstrap, lifting, iOS dependency and Xcode build helpers, diagnostics collector |

## Game files

Place the extracted disc in `game/` so these exist:

```
game/PS3_GAME/PARAM.SFO              (TITLE_ID BLES01548)
game/PS3_GAME/USRDIR/EBOOT.BIN
game/PS3_GAME/USRDIR/EBOOT.elf       (decrypted executable, see below)
game/PS3_GAME/USRDIR/install.nfs, ps3_000.nfs, shaders.nfs.sdat, video/
```

`EBOOT.BIN` on the disc is encrypted. Decrypt it with RPCS3: *Utilities ›
Decrypt PS3 Binaries*, pick `game/PS3_GAME/USRDIR/EBOOT.BIN`; it writes
`EBOOT.elf` beside it. A disc copy keeps the folders read-only, so make
`USRDIR` writable first (`chmod u+w game/PS3_GAME/USRDIR`).

`PS3_UPDATE/` (firmware updater) is not needed. The game data is about 6.7 GB.

## Build the IPA

Requirements: macOS with Xcode (iOS SDK and Metal toolchain), `python3`,
`cmake`, `ninja` (Homebrew).

```sh
python3 tools/bootstrap_runtime.py      # once: vendor/ps3recomp at the pinned commit + local patch
sh tools/analyze_dirt3.sh                # once: lift EBOOT.elf into port/recompiled and port/spu (slow)
./scripts/build-dirt3-ios.sh             # builds iOS deps on first run, then the app and the IPA
```

Result: `output/DIRT3-AnubisSoft.ipa` (unsigned). A full first build takes
roughly an hour; later builds only recompile what changed. Logs go to `logs/`.

To sign during the build instead, open `DIRT3/DIRT3.xcodeproj`, set your team on
the `DIRT3` target, and run the script with `CODE_SIGNING_ALLOWED=YES`.

## Install and run

1. Sideload `DIRT3-AnubisSoft.ipa` with SideStore, AltStore or LiveContainer
   (they re-sign it).
2. Copy the repo's `game` folder into the app's Documents so that
   `Documents/game/PS3_GAME/USRDIR/EBOOT.elf` exists. Use the Files app
   (*On My iPhone › [AS] DiRT 3*) or Finder's file sharing; for LiveContainer,
   the app's Documents live under LiveContainer's data folder.
3. Launch **[AS] DiRT 3**. The app checks that every file in `PS3_GAME` is
   present with the right size; if not, it offers a folder picker.

Controls: on-screen Xbox-style layout (toggle at the top centre; "3D" shows
analog sticks and L3/R3), or any MFi/Xbox/PlayStation controller.

## Diagnostics

Each launch writes `Documents/logs/performance/session-*/` (`native.log`,
samples, metadata). With the phone connected:

```sh
python3 tools/collect_ios_diagnostics.py --device <UDID> --out logs/device-run-1
```

For an app running inside LiveContainer, pass
`--bundle-id <LiveContainer bundle id> --container-path Documents/Data/Application/<UUID>`.

Launch options live in `port/ios/dirt3-runtime-options.json`. The current
profile keeps two low-cost boot traces (`PS3_SPU_PCWATCH`, thread-local, and
`PS3_EVT_RECV_TRACE`, capped at 60 lines); `SPU_POLLTRACE` was dropped because
its shared counters sit on the hottest SPU channel paths. Remove the rest once
the game boots.

## Changing the runtime

Edit `vendor/ps3recomp`, then run `python3 tools/export_runtime_patch.py` to
update `patches/ps3recomp-local.patch`.
# DiRT3-iOS-port
