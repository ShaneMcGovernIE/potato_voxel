# Feature removals in 1.6.1

The 1.6.1 sandbox release deletes five features wholesale:

- **FOREST FX** — its ladder was shaped by an Android OS probe (no depth
  read-back on phones) that the sandbox made impossible to ask. Rather
  than offer a rung that silently fails where it used to work, the whole
  feature went.
- **Frosted battle-HUD glass** — the snap-to-window composite and its
  frosted panels existed to work around a canvas limitation; the plain
  panel path (the old iOS fallback) became the only path.
- **STADIUM models** — building them requires reading a player-supplied
  Pokémon Stadium ROM, and the sandbox allows no reads outside the mod
  folder. The sandbox announcement says to open an engine issue for real
  gaps rather than work around them; the 3D-BTL ladder shrank to
  2D-3D A / 2D-3D B / OFF, and the STADIUM SPRITES / STADIUM ROM rows,
  import screen and model readers were deleted.
- **VR** — the OpenXR loader, GL interop and rigs rode `ffi` and raw
  filesystem access; the loader was already not shipped. `VR.supported()`
  now always answers false, so no VR row appears anywhere.
- **DEBUG panel + Perf** — instrumentation ran on environment variables
  and wrote report files; both surfaces are banned, and the panel was
  already invisible to players.

Deleting rather than stubbing matters: the sandbox's own gate greps the
mod folder for banned patterns, so unreachable code that mentioned them
would still fail the gate.

## Current diagnostics state

The 1.6.1 removal described above is historical. PotatoVoxel now has a
sandbox-safe diagnostics replacement: an optional overlay records bounded
state through scoped mod storage and can use the engine's declared log
service. It does not restore the removed raw-file, OS-query, native, VR, or
forest integrations, and the old environment-variable/`Perf` instrumentation
is not present.
