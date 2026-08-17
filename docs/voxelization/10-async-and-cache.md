# 10 — The Async Build System and the Mesh Cache

A frame never blocks on meshing. Builds run as **coroutine jobs sliced
into per-frame millisecond budgets**; meshes are cached in memory per
map, and serialized to the mod's scoped storage so revisits skip the
analysis entirely.

## The job queue (ChunkMesher.lua:988-1425)

- `request(map, bodyOnly, masks, urgent, force)` queues a build unless
  the slot is already cached or queued. Two slots per map: **full**
  (body + border ring) and **body** (neighbours' contribution).
- `pump(covered)` runs each frame from the pipeline's update hook
  (main.lua:404): urgent jobs first, larger slice. Budgets
  (BrickProfile.lua:192-194):

  | slice | ms | when |
  |---|---|---|
  | URGENT_SLICE | 10 | current map's mesh |
  | IDLE_SLICE | 4 | neighbours, prebuilds |
  | COVERED_SLICE | 40 | the world is hidden (a warp fade, a menu) — a door fade swallows most of a destination build |

- `Budget.begin/check/tick/finish` (lib/BuildBudget.lua) suspends the
  job's coroutine mid-loop when the slice is spent; the job resumes next
  frame where it left off. `check()` is clock-based and called every
  cell in the heaviest loops; `tick()` is a sampled counter elsewhere.
  Outside the build coroutine `check()` is a no-op (synchronous probes
  run whole).
- **Generation counters cancel in-flight work**: `invalidate`/`evict`/
  `refresh` bump `gen[mapId]`; a job whose generation no longer matches
  discards its result. Stale meshes keep drawing while replacements cook
  (`refresh` — a one-block edit never blinks the world to 2D).
- `runJob` order: fill aux slots (grass/flowers/figures) from cache or
  fresh → terrain slot from cache or fresh → sliced upload
  (`uploadTableMesh`, 8192 vertices per slice — a one-shot newMesh on a
  500k-vertex map is a 100-500 ms hitch).

## Memory bounds

- **setLive**: only the current map + rendered neighbours (+ the
  previous set, so a round trip through a door is free) keep meshes,
  Structures analysis, and per-map atlases. Everything else is released
  — GPU buffer and LOVE's CPU copy (ChunkMesher.lua:1588-1627).
- Round-hull templates dedupe GLOBALLY per art signature (see 05).
- `prevLive` history keeps the budget at two neighbourhoods.

## The disk cache (lib/MeshCache.lua)

Lives in the mod sandbox's **scoped byte storage** (engine-owned:
crash-safe writes, keys scoped per game version × playthrough × mod).
Key layout (MeshCache.lua:6-17):

```
maps/<mapId>/<slot>/<kind>     payload bytes
meta/<mapId>/<slot>/<kind>     small table: fingerprint + format + lengths
                               + codec — the boot-time READY check reads
                               summaries, not whole payloads
manifest                       PVMC1 manifest
buildinfo                      build identity
```

Payload format (unchanged since v18): `"DSM"` magic + format byte +
fingerprint + optional codec/lengths, then a **quantized** (terrain/
water) or float (aux) **indexed** vertex payload — 6-float rows plus a
u32 vertex map. love.data compress/decompress do the entropy codec
(lz4/zstd).

- `GEOMETRY_VERSION = 18` must be bumped whenever geometry output
  changes; the mod version alone is not enough (a settings-only release
  changes no geometry).
- **Fingerprint identity**: the cache is keyed to the ROM/tileset
  identity + void-fill + geometry version, so real asset changes
  invalidate while restarts stay warm.
- Availability is **fail-open**: no playthrough yet (title screen) →
  every cache call no-ops, callers proceed as if empty; resolution is
  re-probed after failure.
- `CachePrebuild` (lib/CachePrebuild.lua) cooperatively builds every
  map's body + full + water + aux meshes in the background from the
  OPTIONS menu, resumable, cancellable; boot checks the complete cache
  and offers BUILD NOW otherwise. The save write is what binds the cache
  to that save file.
- The cache is per save file: each playthrough builds once and asks
  once.

## What is cached vs. dynamic

- Cached: terrain meshes (body/full + lifted water), grass, flowers,
  figures — everything derived from the static block layer.
- Dynamic (never cached): characters, battle cards and effects, shadows,
  water reflections, the sky — they follow live state per frame.

## Invalidation wiring (`lib/WorldFeature.lua`)

- `world.block_replaced` → `refresh` (keeps stale mesh visible).
- `Map.setBlock` is wrapped — Cut, card-key doors and regrowth all write
  the block layer directly without announcing; setBlock is the one
  choke point (`WorldFeature.installMapHooks`).
- `map.reloaded` → `invalidate`, EXCEPT reason == "colors": a palette
  switch reloads the map only to rebuild its atlas; geometry is
  colour-independent and the texture is keyed by palette, so dropping
  the mesh would flash the flat 2D world on every palette toggle
  (`WorldFeature.installMapHooks`).
- VOID FILL changes invalidate every ring (it's baked into the mesh)
  (main.lua:227-236).
