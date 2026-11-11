# Reusable PS3 port scaffold instructions

- Treat each game as a separate port. Keep decrypted input, profiles, generated
  PPU/SPU sources, build caches, and release artifacts in ignored title-specific
  folders. Never commit game files, firmware, keys, saves, or generated game
  code.
- The checked-in Xcode project, CMake options, lifted-code helpers, and runtime
  patches include MotorStorm-specific assumptions. Do not enable or reuse those
  assumptions for another title until their input hashes, addresses, modules,
  and behavior have been verified against that title.
- Generate a fresh PPU lift, SPU inventory, and title input manifest from the
  selected game's own executable. An incomplete decoder/lift must stop
  packaging; do not manufacture a complete registry from partial coverage.
- Keep macOS and iOS generated sources, build outputs, and platform-specific
  launch settings separate. Preserve an existing game's working baseline.
- When a future PS3 build adds or changes reusable scripts, runtime fixes, or
  porting notes, copy the reviewed changes into this repository and update its
  README. Keep title-specific content labeled as examples.
