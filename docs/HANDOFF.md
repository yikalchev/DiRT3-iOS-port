# Hand-off: state of the DiRT 3 port (12 Nov 2026)

Read this first when continuing in a new session.

## Done

- Repository converted from the MotorStorm/WRC scaffold to a single DiRT 3 iOS
  target (`DIRT3/`, scheme `DIRT3`, bundle `com.anubissoft.dirt3`, display name
  "[AS] DiRT 3"). App icon = `icon/` DiRT 3 artwork + AnubiSSoft label
  (`DIRT3/DIRT3/Assets.xcassets/AppIcon.appiconset`).
- Game: `game/` = DiRT 3 EU `BLES01548` v01.01. `EBOOT.BIN` was decrypted with
  RPCS3 (Utilities > Decrypt PS3 Binaries) to `game/PS3_GAME/USRDIR/EBOOT.elf`
  (21,633,080 bytes, valid PPC64 ELF).
- Runtime restored: `python3 tools/bootstrap_runtime.py` (pinned commit +
  `patches/ps3recomp-local.patch`, which carries every WRC 5 runtime fix).
- `tools/analyze_dirt3.sh` finished: PPU lift 85,180 functions in 97 files
  (`port/recompiled`), SPU registry 71/71 programs, complete
  (`port/spu/inventory.json`). WRC-only steps removed (JOBCRT job lifter, WRC
  SPU extra entry points).
- Runtime SPU pipeline (`vendor/ps3recomp/tools/spu_program_pipeline.py`, in
  the patch) now accepts `.word` data in SPU text (lifted as a trap; 6 DiRT 3
  images have float/shuffle tables there), re-lifts with missed branch targets
  as extra entries, and accepts out-of-range targets that the lifter stubs
  through `spu_indirect_branch`. If the SPU step is ever re-run alone:
  `python3 tools/build_spu_workloads_text_data.py --input game/PS3_GAME/USRDIR/EBOOT.elf --lifted port/spu --out port/spu/spu_workloads.c --constructor --title "DiRT 3"`
- iOS dependency sources are downloaded (`vendor/ios-deps`: sdl2, glslang,
  spirv-cross, ffmpeg; `tools/build_ios_dependencies.py` fixed for archives with
  a stray top-level file).
- The user runs the IPA build in their own terminal (13:1x, 12 Nov):
  `./scripts/build-dirt3-ios.sh`, log in `logs/dirt3-ipa-<time>.log`, IPA at
  `output/DIRT3-AnubisSoft.ipa`. Ask for the result or read the newest log.
- App icon: `icon/` DiRT 3 art (512 px, upscaled) + AnubiSSoft label, in all
  three AppIcon slots.

- 13:30, 12 Nov: the 13:23 IPA built fine (icon + "[AS] DiRT 3" verified in
  the bundle) but was zipped with `ditto --sequesterRsrc`, which put a
  `__MACOSX/` folder and `._*` files in it; SideStore/AltStore can reject that.
  `scripts/build-dirt3-ios.sh` now packs with `zip -X` (no resource forks) and
  fails if any metadata entry slips in. `SPU_POLLTRACE` removed from
  `port/ios/dirt3-runtime-options.json` (shared counters on hot SPU paths).
  Still nothing verified on device.

- 14:40, 12 Nov, device runs 1-3 (logs/device-run-1, ~/Downloads/performance):
  black screen, no audio, no crash. Boot reached SPURS setup then stalled:
  1. `_cellSpursWorkloadFlagReceiver` (NID 0xA73BF47E) was unregistered; the
     faked error made DiRT 3 drop its SPURS instance, so every
     CreateTaskset got spurs=NULL and the main thread polled forever
     (timer_usleep 30 ms, lr 0x00394168). Implemented in
     `libs/spurs/cellSpurs.c` (RPCS3 semantics) and the instance init now sets
     the real wklFlag (0x6C) = ~0 and wklFlagReceiver (0x77) = 0xFF.
  2. RSXHelper policy module (EA 0x013ABB00, 4224 B, fp 0x75E4AADEC909F331) is
     raw code, not an SPU ELF, so it was never lifted ("PM NOT LIFTED").
     New `tools/lift_dirt3_jobs.py` lifts it at LS 0xA00 (code ends 0x1810;
     the rest is strings) -> `port/spu/dirt3_pm_rsxhelper/` +
     `port/spu/dirt3_jobs_register.c`; analyze_dirt3.sh now runs it.
  Both compile (gcc -fsyntax-only); patch re-exported. Not yet run on device.

- 14:45, 12 Nov, device-run-2: both fixes confirmed (WorkloadFlagReceiver set,
  RSXHelper "PM resolved", tasksets created, SPU tasks run, ~20 game threads up).
  The game reached its first-boot install (copies install.nfs, 4.0 GB, to
  /dev_hdd0/game/BLES01548INSTALL/USRDIR/_temp/) and failed on two more
  unregistered NIDs: cellFsAioWrite (0x4CEF342E; now in runtime/ppu/ppu_fs.cpp,
  positional + synchronous like AioRead) and cellSpursGetWorkloadFlag
  (0xC765B995; returns spurs+0x60). The SPURS scheduler now also kicks the
  flag-receiver workload when wklFlag.flag (0x6C) == 0 and re-arms it to ~0
  (RPCS3 kernel1 select). wid 1/2 policy modules (fp 0x87CC03697F3D8DC3 size
  14736 @0x13BA580, fp 0x3C7EB3E780321429 size 4064 @0x13BDF80) are still
  unlifted. Open question: the title calls cellGameContentErrorDialog
  (BROKEN_EXIT_GAMEDATA, dir BLES01548INSTALL) at install start; stub returns OK.

- 14:55, 12 Nov: audited all 380 EBOOT imports against the runtime's NID
  table: 79 had no handler. Added the ones a local boot needs: save data
  (cellSaveDataUserListAutoLoad/Save, UserFixedLoad/Save, EnableOverlay;
  ctx handlers reading arg9/arg10 from the caller's save area),
  sys_mempool_* (ppu_sysprx.cpp) and cellSpursTaskExitCodeGet /
  TaskAttributeSetExitCodeContainer. 68 remain, all network/PSN/USB/voice/
  HTTP/SSL/keyboard/Ldd-pad plus cellGamePatchCheck, cellSaveDataUserGetListItem,
  0x7048A9BA (cellSaveData), 0xE7DD87E1 (cellSpurs), _cellGcmFunc15 and four
  unnamed cellSysutil NIDs; they fail with CELL_ERROR_ERROR, which offline
  titles normally tolerate. Re-run the audit after any lift (see the python
  snippet idea: compare research/dirt3/imports-named.json with gen_hle_nids
  --all + ps3_hle_register_ctx calls).

- 15:05, 12 Nov, device-run-3: first-boot install COMPLETED (install.nfs copied,
  _temp renamed to install), then NP/audio/save threads came up and the game
  crashed in its trophy-list builder (vm_write8 fault, r29=0x20000000):
  sceNpTrophyGetGameInfo wrote host-LE counts (32 -> 0x20000000). Fixed: all
  trophy integers now written BE; the real set is parsed from the title's
  TROPHY.TRP (TROPCONF.SFM grades/hidden, TROP.SFM names; DiRT 3 = 67:
  P1 G2 S12 B52); SCE_NP_TROPHY_DESC_MAX_SIZE corrected 256 -> 1024 (SDK).
  App: semi-transparent "Copying game files" panel with percentage, fed by
  ps3_msgdialog_progress() (cellMsgDialog.c) polled every 0.25 s in main.mm.

- 15:20, 12 Nov, device-run-5 (new build confirmed: "trophy set NPWR01143: 67
  trophies"): trophy crash gone. Boot reached shader-pack decryption, more
  tasksets, FFB threads. Two problems: (1) cellUsbdRegisterExtraLdd(2),
  UnregisterExtraLdd, Set/GetPrivateData missing -> added to cellUsbd.c (no
  device ever attaches, so registering just succeeds). (2) HANG: thread
  "Data Set Monitor (Processing)" spins in func_007C9E60, a std::map find in a
  djb2-keyed string registry (singleton: guard TOC-0x7AB8, object TOC-0x7AB4,
  ctor func_007B0AC8). The map head node (allocator->vtbl[2](0x18)) is later
  found ZEROED (no [null-write], so the ctor ran fine) -> memory corruption.
  Diagnostic armed: runtime ps3_dyn_watch_arm()/dyn_watch_hit() in
  ppu_loader.cpp (PPU stores) + ps3_dyn_watch_host_write() from spu_dma.h
  (SPU DMA PUT); TEMPORARY edit in port/recompiled/ppu_recomp_042.cpp
  func_007B0AC8 arms it on the head node ([dirt3-diag]/[dyn-watch] lines).
  Vector stores (vm_raw_st16) and host memsets are NOT covered.

- 15:30, 12 Nov, device-run-6: ROOT CAUSE of the Data Set Monitor hang found.
  The string registry's map lives at 0x20000050.. (start of DiRT 3's heap).
  The runtime's GCM inject window (ppu_hle_inject_base, default 0x20000000:
  labels +0, control reg +0x2000, offset tables +0x3000..+0x7000) overlaps it;
  host-side RSX label writes (label 5 = 0x20000050) zeroed map nodes. The PPU
  store watch saw only legitimate inserts, which is what proved the writer was
  host-side. Fix: port/main.cpp sets ppu_hle_inject_base = 0x3F000000 first
  thing in port_game_main (DiRT 3 uses 0x20000000..~0x66000000; runtime SPU LS
  0x30000000..0x30200000, lv2 memory 0x40000000..). Remove the temporary
  func_007B0AC8 diagnostic in port/recompiled/ppu_recomp_042.cpp once the
  next run confirms the hang is gone.

- 15:45, 12 Nov, device-run-6b: inject-base fix WORKS: DiRT 3 logo + loading
  spinner render (avg 2.8 guest fps), audio output running (silent), 356 MB.
  The "Initial loading screen" thread exits, then the next task (EBOOT ELF
  0x013BEF80, SPU image 2757a0f4..., taskset 0x015F1380) DMA'd to EA 0
  ([mfc] REJECTED ... ea=0x00000000): its queue EA comes from the TASKSET
  argument, and _cellSpursTasksetAttributeInitialize discarded argTaskset/
  priority/maxContention while CreateTasksetWithAttribute passed args=0.
  Fixed: the host attr keeps args/priority/maxContention (new maxContention
  field) and CreateTasksetWithAttribute forwards them. Temporary func_007B0AC8
  diagnostic removed from ppu_recomp_042.cpp (dyn-watch runtime hooks stay,
  disarmed, for future use). cellSpursTaskAttributeSetExitCodeContainer is
  still a no-op (container not delivered) -- revisit if task exit codes matter.

- 15:55, 12 Nov, device-run-7: taskset-args fix WORKS. Logo, loading screen,
  Codemasters logo with SOUND, ~30 fps for 18 s; then at ~19 s everything
  stops: 0 SPU dispatches, main_game 0 CPU, one core spinning outside the
  attributed roles; last log lines are a ShutdownTaskset/JoinTaskset cycle on
  taskset 0x68E5E880 (216 such cycles). Note cellSpursJoinTaskset does not
  wait for tasks at all (returns OK). Added a stall dump:
  ps3_dump_all_threads() in sys_ppu_thread.c (guest threads: name, host CPU,
  run state, cia/lr/sp, GSTACK; host threads via task_threads with CPU time),
  driven by PORT_STALL_DUMP_AT="35,60" (port/main.cpp watchdog, set in
  dirt3-runtime-options.json). .gitignore: added /icon/.

- 16:10, 12 Nov, device-run-9 (stall dump): MAIN is in func_0105565C polling
  `while (cellGcmGetFlipStatus() != DONE) sys_timer_usleep(100)`, so the RSX
  FIFO drain stopped before reaching the flip (~19 s, right after
  SetFlipMode(1)). All 38 other PPU threads are blocked normally. MultiStream
  SPU thread (image 342301998) sits at pc 0x004D4 (constant over 16 samples).
  The profile has GCM_SEMA_ACQUIRE=1 (blocking acquires) with no bound, so an
  acquire on a label nobody writes wedges the drain forever. Set
  GCM_SEMA_ACQUIRE_MS=250: bounded wait that logs "[SEMA] acquire off=..
  gave up" naming the label/value -- both a workaround and the diagnosis.

- 16:15, 12 Nov, device-run-10: bounded acquires let the drain move; they
  name the missing fences: labels at inject+0x7D0, 0x810, 0x820, 0x830, 0x840
  expected == 1, always 0. Screen unchanged (0 fps after ~19 s). MAIN now
  waits in func_00E7479C: usleep(50) until (target - *[0x015AE400]) < 0x40000
  (command-ring space; advances only as the RSX consumes). MultiStream SPU
  still at pc 0x4D4. Next run: PORT_DYN_WATCH=0x3F0007C0,0x100 (watch those
  labels: PPU stores + SPU DMA PUTs), SPURS_PM_TRACE=1 (policy-module runs),
  and a "[cellSpurs] workload flag kick" log -- to find who should write the
  fences (prime suspect: the RSXHelper workload, wid 0).

- 16:45, 12 Nov, device-run-11: label watch shows labels 0x810..0x840 are
  only ever INITIALISED to 0 (func_00EC8820); nothing writes 1. Label 0x7D0 is
  set to 1 by the VBLANK handler (opd 0x01469CD8 -> func_0105468C). RSXHelper
  (wid 0) and wid 1/2 policy modules all run (67/136/137 runs). GCM user
  commands (0xEB00) arrive; the HLE user handler (opd 0x01463B08 ->
  func_00E715C8) only calls cellSpursCreateTaskWithAttribute(attr 0x015F3C80)
  -> SPU task image 309688847 (ELF 0x013BEF80) runs and returns rc=0 each
  time, no rejected DMAs, but no fence write seen. Next run: SPU_DMA_IMAGE=
  309688847 (new: every DMA of that image + PUT payload words, spu_dma.h),
  SPU_DMA_RANGE=3F0007C0-3F0008C0, SPU_ATOMTRACE=200.

- 19:05, 12 Nov, device-run-12: the fence protocol is visible. SPU task image
  309688847 (spawned by the GCM user handler) is the RING CONSUMER of the
  control block at 0x015AE400 (the counter MAIN waits on). Per run it GETs
  label 0x80 (EA 0x3F000800) into LS 0x3FD30, patches fragment programs
  (GET 0x4Axxxxxx -> PUT RSX local 0xC58Fxxxx), then PUTF (cmd 0x22) the same
  LS word to labels 0x81..0x84 (0x3F000810..0x840). The RSX acquires 0x81..0x84
  == 1, so label 0x80 must already be 1 when the task runs; PPU init sets it to
  0xFFFFFFFF and the fences read 0 at every give-up. Next run logs: every RSX
  back-end / texture-read label write into 0x7C0..0x8C0 ("[fence]"), the LS
  word of every SPU DMA into the range ("[dma-range] ... ls-word="), labels
  0x80..0x84 at each SEMA give-up, and PORT_DYN_WATCH narrowed to 0x800..0x850.

- 19:30, 12 Nov, device-run-14: the RSX fence handshake WORKS: SPU task writes
  1 to 0x81..0x84 (PUTF), the RSX acquire passes, then texture-read releases
  set 0x80 = slot index and reset the slot to 0 -- round robin as designed.
  The game got further and then CRASHED (SIGBUS) in ppu_stwcx32 at guest EA
  0x68E5E7FF: func_00C78B4C @0x00C791E0 loads a pointer from [0x68E5E7F0] (the
  ARGUMENT BLOCK of the create/shutdown/join taskset 0x68E5E880) and atomically
  clears it. cellSpursJoinTaskset returned immediately, so the block was read
  while that taskset's tasks were still filling it (only visible now that tasks
  get the real taskset argument). Fix: per-taskset in-flight counter in
  spu_workload.c (inc at spu_workload_dispatch_async, dec when the job ends)
  and spu_taskset_join_wait() used by cellSpursJoinTaskset (3 s bound, logs a
  TIMEOUT with the count).

## Working preferences (from the user)

- Give long build commands for the user to run in their own terminal; do not
  run builds in the background.
- After sideloading, the user says "Done, pull the log"; pull with
  `python3 tools/collect_ios_diagnostics.py --device 00008130-001C1CE00A60001C
  --bundle-id com.kdt.livecontainer.C6S99A5XW3 --container-path
  Documents/Data/Application/<UUID> --out logs/device-run-<n>`. WRC 5 used
  container `C45D37AD-C982-4237-860C-C578F3102C6C`; DiRT 3 gets its own UUID:
  find it with `xcrun devicectl device info files --device <UDID>
  --domain-type appDataContainer --domain-identifier
  com.kdt.livecontainer.C6S99A5XW3 --subdirectory Documents/Data/Application`.
- The full previous conversation was exported to
  `~/Downloads/session-export-1794482089375.zip`.

## Next commands

```sh
sh tools/analyze_dirt3.sh > logs/analyze-dirt3.log 2>&1   # if port/recompiled is empty or incomplete
./scripts/build-dirt3-ios.sh                              # builds iOS deps (first time, downloads sources) + IPA
```

Output: `output/DIRT3-AnubisSoft.ipa`. Sideload (LiveContainer/SideStore),
copy the repo's `game` folder (with `EBOOT.elf`) into the app's Documents so
`Documents/game/PS3_GAME/USRDIR/EBOOT.elf` exists, launch, then pull logs with
`tools/collect_ios_diagnostics.py`.

For debugging, use the macOS runner first (`scripts/build-dirt3-mac.sh`,
`scripts/run-dirt3-mac.sh`; needs native Homebrew in /opt/homebrew: sdl2
glslang spirv-cross ffmpeg cmake ninja). The method and the runtime's
diagnostic switches are documented in
`../ps3-ports/docs/RUNTIME_DEBUGGING.md`; the WRC 5 port is preserved in
`../ps3-ports/titles/wrc5/` (its original folder was removed).

## Known open runtime issues (from WRC 5)

- `cellGcmSys` "park grace" fallback (50 ms) replays stale FIFO commands when a
  title parks the GPU on SPU-filled command blocks; try `GCM_PARK_GRACE_MS=0`.
- SPURS job chains: RESET_PC urgent commands should set the chain PC that the
  next RunJobChain resumes from (WRC 5 title-screen stall).
- DiRT 3 specifics to watch: `shaders.nfs.sdat` goes through cellFsSdataOpen
  (supported); SPURS job binaries, if any, need lifting like WRC's JOBCRT job.
- DiRT 3 runs in RPCS3 (macOS and iOS): use it as the reference.

## Run 15 → fix: taskset/task race in CreateTask dispatch
- Fence ring (labels 0x810..0x840) ran fine for many cycles, then stalled exactly when the loader thread
  started recycling its own taskset 0x68E5E880 (ShutdownTaskset/CreateTaskset/CreateTask) concurrently.
- The log showed a fence task (image 309688847) built against taskset **0x68E5E880**, then 0x015F1380
  task=1, task=2: the dispatcher picked up the taskset/slot from the shared `g_ydkj_real_*` globals, which
  the other PPU thread had just overwritten. The real slot was never released, so later fence tasks never
  ran → RSX SEMA give-ups → MAIN stuck in func_00E7479C waiting on ring space.
- Fix: `spu_workload_set_dispatch_task()` (thread-local hand-off) called by cellSpursCreateTask and
  spu_taskset_task_exited right before `spu_workload_dispatch_async`; dispatch uses it in preference to the globals.

## Run 16: game reaches "Press START" — input fixed
- Causes: (1) on iOS cellPad also polled SDL2; SDL reported the Xbox pad as connected with no data, which
  skipped the app's GameController/touch path entirely. (2) The app sent WRC keyboard codes through
  mac_keyboard_pad_state(), whose output depends on port_keyboard_context(); DiRT 3 returns UNKNOWN, so
  Start/Cross/Circle/menu up-down mapped to nothing.
- Fix: iOS skips SDL pad init/poll; new direct lane in cellPad (host keys 64..79 = PS3 button bits 0..15),
  analog L2/R2 on touch axes 4/5. main.mm maps Xbox A/B/X/Y→Cross/Circle/Square/Triangle, LB/RB→L1/R1,
  LT/RT→L2/R2 (analog), Menu→Start, View→Select, D-pad→D-pad, sticks→analog, L3/R3. Touch buttons use the same lane.

## Run 16: menus + race reachable (input works) — slow, silent, black race, crash
- Perf: 472,296 SPU tasks each got a fresh pthread (256 MB stack). Added SPU_ASYNC_REUSE_ALL=1 (reuse cache for
  every returning image except 22; slots 4→16). Removed leftover diagnostic options (PCWATCH, EVT_RECV_TRACE,
  stall dump, dyn-watch, PM trace, DMA image/range, atomtrace).
- Audio: MultiStream SPU (342301998) interprets runtime-loaded overlays (LS 0x2D690/0x2DE68/0x2F178) and then
  jumps to LS 0 -> FAULT; every audio block afterwards silent. Added SPU_ZERO_TRACE=<img> (last 32 transfers
  before landing on LS 0) to find the bad caller.
- Black race screen and crash: native.log stopped being written before the race (no data); next run needed.

## Run 17: smooth start with sound, degrades; audio dies; race black
- Thread reuse works: 95% of 455k dispatches reused (21.9k threads vs 472k).
- Audio death: MultiStream SPU calls through LS[0x3AB80] (stored once at init at 0x484 from the plugin
  init routine at LS[0x3AAB0]=0x30780+off) from 0x19A8; it reads 0 later -> jump to LS 0 -> FAULT.
  Something clobbers 0x3AB80 after init. SPU_LS_WATCH=0x3AB80 added (logs every write/DMA-GET onto it).
- native.log hit its 2 MB cap before the race (per-task SPURS prints ~150/s). Capped those prints to 200
  each; kNativeLimit 2→16 MB.
- Shader compile wall 49.6 s in run 17 (synchronous newLibraryWithSource on new content) = stutters.
  Translation (HLSL→MSL) is disk-cached; Metal compile relies on the OS cache. Candidate: MTLBinaryArchive.
- Controller now polled at 250 Hz (GCController.controllers) instead of change handlers; logs "[gamepad]".

## Run 18
- Menu "30 s" lag = shader compiles: per-second samples show 8-34 builds/s at 0-1 fps (each 60-100 ms,
  41 s total). Added RSX_METAL_ASYNC_SHADERS=1: newLibraryWithSource:completionHandler:, pending functions
  make pipeline_create return 0 + rsx_backend_pipeline_pending_take()=1; draw engine drops the draw without
  caching the failure. Draws of brand-new shaders may be missing for a frame or two.
- 31 RSX SEMA give-ups on label 0x7D0 (never written, 250 ms each) in loading/race; armed PORT_DYN_WATCH
  0x3F0007C0+0x20 and SPU_DMA_RANGE 3F0007C0-3F0007E0 to find the producer.
- MultiStream dies at boot (line ~2200), before any game audio; LS[0x3AB80] is the output of the call at
  0x480 into the runtime-loaded plugin (LS[0x3AAB0]=0x30780+off, interpreted). The lifted-write watch is
  compiled out on iOS (SPU_LS_DIAGNOSTICS), so no writer was seen. Next: trace the interpreted plugin call.
- More spam capped (_TaskAttributeInitialize, TaskAttr R8-form: 178k lines).

## Run 19: race reached (car intro video, GO), race view black
- Race fragment programs failed HLSL parse: "array index out of range '58'/'55'/'54'" — FP decompiler declared
  r[48]/h[48]; NV40 temp index is 6 bits. Now r[64]/h[128] (h aliases r halves), alias guard widened.
- MSL translation disk cache keyed on __DATE__/__TIME__ → cold after every rebuild. Now RSX_MSL_CACHE_REV.
- Remaining slow seconds: sync HLSL→MSL translation (300-750 ms/s) + sync pipeline builds (up to ~670 ms/s).
- Label 0x7D0 is a PPU producer flag (guest fn 0x0105468C stores 1); RSX acquire gives up when the PPU is late.
- Fully async shader path (RSX_METAL_ASYNC_SHADERS=1): eng_function now does HLSL→MSL translation on a serial
  GCD queue + newLibraryWithSource:completionHandler:; eng_pipeline_create keys pipelines (vs/ps HLSL, rs,
  layout, stride, fmt, count) in a 16k open-addressed table, builds depth-stencil sync and the PSO with
  newRenderPipelineStateWithDescriptor:completionHandler: (not for native MSAA). Pending → draw skipped,
  not cached; render thread never blocks on shaders. Backup of the pre-change file: none in repo (patch history).
- Audio: SPU_NULLCALL_SKIP=342301998 makes the null-pointer call at 0x19A8 (LS[0x3AB80]) return r3=0 instead
  of halting the MultiStream SPU. SPU_ZERO_TRACE now also logs the first 48 transfers (init path) and, on the
  first call into high LS (>=0x30000), the plugin code, the descriptor at $80 and LS[0x3AAB0]/[0x306E0].

## Run 20: graphics broken (half white / half black), user: worst build
- Fully async shaders/pipelines skip draws while pending; one-shot passes are lost → broken frames.
  RSX_METAL_ASYNC_SHADERS set to 0 (code kept). MSL cache key fix + FP r[64]/h[128] fix stay.
- Audio: null-call skip works — silent blocks 98% → 58%. MultiStream's init (0x2C8 mailbox plugin load) never
  runs; entry 0xD0 goes straight to the mixer loop, so LS[0x3AB80] stays 0. zero-trace dumps capped to 2.
- Removed PORT_DYN_WATCH / SPU_DMA_RANGE (0x7D0 producer identified: PPU fn 0x0105468C).

## Run 21: shader compile wall 97.8 s (worse), buzzing audio, pixelated, race black/not starting
- r[64]/h[128] fixed files doubled every shader's compile cost. FP decompiler now rewrites the declaration to
  the highest r[]/h[] index actually used (post-pass before preamble insert).
- SPU_NULLCALL_SKIP produced a buzz ("fan") instead of silence → removed (and SPU_ZERO_TRACE).

## Run 22: pixelated, gray screens from start, car preview + rally black
- Run 19 was the best visual state. Reverted the FP register-file change (back to r[48]/h[48], alias r<24):
  shaders that used to fail (dropped) were now drawn wrongly → pixelated overlay / black car preview.
- RSX_METAL_ASYNC_SHADERS modes: 1 = run-19 behaviour (sync HLSL→MSL, async Metal compile, sync PSO) — now the
  default in options; 2 = fully async (translate + compile + PSO; run 20, broke one-shot passes).
- Warm second run still spent 33 s in shader builds (first: 44 s): the Metal compile itself dominates, the MSL
  translation cache only helps a little. Next candidate: persistent Metal binary archive for pipelines.

## Run 23: best build (async mode 1, FP fix reverted) — crash right before the rally starts
- Guest FATAL: "NeMemorySlot::allocateAligned/useAddressSpace(... m_slotSize=65552) failed. Out of physical
  memory or Virtual memory problem", then null-page writes and SIGBUS in func_01095900.
- Cause: sys_mmapper search_and_map (lv2 337) rounded every block to 1 MB, ignored which reserved region
  `start` belonged to after the first call, and unmap/free were no-ops (no reuse). Region exhausted on rally load.
- Fix: ps3_mm_* allocator in ppu_sysprx.cpp — regions from lv2 330, first-fit 64 KB-aligned placement within
  the region containing `start`, map_memory recorded + committed, unmap frees and writes *mem_id, ENOMEM
  (0x80010004) when full. id→size table 256 → 256K entries. All mmapper calls logged (first 300 each).

## Run 24: rally reached, no crash (mmapper allocator works), HUD visible, 3D scene black
- Shader wall 3.0 s, pipeline 0.6 s, max present gap 0.7 s (warm cache + async mode 1).
- 9 race FPs still fail "array index out of range" (temps > 47). FP decompiler now enlarges r/h files ONLY for
  programs that index past 47 (post-pass); every other program's text is unchanged (caches stay warm).
  Aliasing for high temps still skipped (as before).
- After ~190 s: CPU 400-450 %, thermal 2, fps 14-20 (CPU-bound + throttled). Memory flat ~940 MB.
