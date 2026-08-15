# The mesh cache lives in scoped storage, not raw files

The sandbox removed `love.filesystem`/`io`, so the raw `mod-derived/`
cache folder had to go. It moved to `mod.storage:writeBytes`/`readBytes`
(PR #1304) with hierarchical keys: payload bytes under
`maps/<mapId>/<slot>/<kind>` plus one small table meta record per payload
under `meta/...`, a `manifest` table, and a `buildinfo` table. The meta
records exist because whole-key reads make partial payload reads
impossible — the boot-time READY check reads summaries only, which keeps
the 1.3.5 bounded-boot-scan property. Storage is scoped per playthrough,
so a fresh playthrough rebuilds its own cache once; the engine's
crash-safe writes replace the old tmp+rename dance. The float↔bytes
pipeline moved from `ffi` to `love.data.newByteData` with the wire format
unchanged.

Update (same day): the installed engine's storage has no
`writeBytes`/`readBytes` yet (the docs' PR #1304 surface). Payloads fall
back to TABLE storage with `{ bytes = <string> }` as the value, and the
reader accepts both shapes — so the cache works on engines with and
without the byte surface, keeping one storage type per key.
