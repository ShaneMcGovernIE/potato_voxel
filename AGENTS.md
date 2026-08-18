# PotatoVoxel — AGENTS.md

PotatoVoxel is a LÖVE mod for the **Gen1Recomp** engine (Pokémon Red/Blue/Yellow recompiled): the overworld rendered as a 3D voxel diorama through the engine's `render_pipelines` registry, with optional staged 3D battles. It is a fork of Dramatic Shape Voxel Mod retuned for low-end handhelds, and it is **strictly presentational** — gameplay, collision, warps, and scripts remain owned by the engine.

Full reference: `docs/CODEBASE.md` (architecture, module map, sandbox requirements, testing). Deep pipeline internals: `docs/voxelization/`. Engine API ground truth: `docs/Gen1Recomp-Modding-API/`.

## Hard rules

1. **Sandbox.** The mod runs inside the engine's mod sandbox: no raw file I/O, no native interop, no OS queries. Persist with `mod.storage` / `mod.save` / `mod.options`; read own files with `mod:read`; load assets through `mod.assets` or engine `src.*` services. Full requirement list with each sanctioned replacement: `docs/CODEBASE.md` → Sandbox. Gate: `luajit tests/sandbox_api_test.lua` must stay clean.
2. **One build.** The potato tuning is unconditional on every device; there is no desktop/environment switch. New tuning belongs behind existing knobs (QualityMode presets) or new `potato_voxel:*` option rows.
3. **Presentational only.** Change what the world looks like, never what it is. The two exceptions — the 1ST/3RD free walk — route every step through the engine's own collision and step machinery (main.lua header).
4. **Load modules through `V`.** Sibling modules: `V.require("Name")`; shipped data: `V.data("name")`; engine: `require("src.*")`. Never plain relative `require` for lib/ or data/, never write to `_G`.
5. **Bump `MeshCache.GEOMETRY_VERSION`** (currently 27) whenever meshing output changes, with a comment — otherwise stale cached payloads render wrong geometry.

## Working on this repo

1. Read the relevant `docs/CODEBASE.md` section (Module map / Engine seams) before editing an unfamiliar system.
2. Hook/event/registry facts come from `docs/Gen1Recomp-Modding-API/` (engine checkout of 2026-08-14). The engine PotatoVoxel targets adds `mod.postLog`/`mod.fetch` (log service) and the `compute` permission → `love.thread` grant — see CODEBASE.md Sandbox.
3. After a change: run the gates below, log it in CHANGELOG.md under the next unreleased version, and keep mod.card / the manifest description in sync when behavior changes.

## Test & verify

Engine suites run from the engine checkout root with this repo mounted at `mods/potato_voxel/`; the engine-independent scans run from this repo. `.github/workflows/ci.yml` is the exact CI order.

```sh
# in the engine root
POKEPORT_DATA_DIR="$PWD/tests/fixture_data" luajit mods/potato_voxel/tests/potato_voxel_test.lua        # main suite
POKEPORT_DATA_DIR="$PWD/tests/fixture_data" luajit mods/potato_voxel/tests/potato_voxel_cache_test.lua  # cache suite

# in this repo
luajit tests/sandbox_api_test.lua           # sandbox scan — never regress
luajit tests/cache_stream_contract_test.lua
luajit tests/voxel_loading_test.lua
luajit tests/shadow_cadence_probe.lua
luajit tests/shadow_golden.lua              # --bless only for a deliberate change
```

Packaging gates (engine root): `python3 tools/modkit.py lint mods/potato_voxel` · `validate mods/potato_voxel --base auto` · `pack mods/potato_voxel`. The threaded worker path runs only under a real LÖVE binary: `love tools/thread_smoke`.

## Repository map

| Path | What |
|---|---|
| main.lua | Composition root — pipeline record, engine seams, update order. Read it first. |
| lib/ | ~80 modules, one concern each; full map in docs/CODEBASE.md. |
| data/ | Authored profiles: voxel_heights.lua (shape classes/buildings), battle_arenas.lua, voxel_atmos.lua, voxel_weather.lua. |
| workers/ | geometry_worker.lua (threaded prebuild), cache_decode_worker.lua (mobile LZ4 decode). |
| tests/ | Headless suites, shadow golden, sandbox scan. |
| docs/ | voxelization/ (pipeline), Gen1Recomp-Modding-API/ (engine API), adr/ (decisions), CODEBASE.md (this reference). |
| manifest.json / mod.card / README.md / CHANGELOG.md | Identity, claims, history. |
