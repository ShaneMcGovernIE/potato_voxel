# PotatoVoxel

PotatoVoxel turns the Pokémon Gen 1 overworld into a 3D voxel diorama while
keeping the game playable on handhelds, phones, and lower-powered computers.

This release focuses on the things players notice most: faster and safer cache
building, smoother route changes, lower memory use, and reliable sprite-stacked
trees and grey bollards.

## What you get

- A 3D voxel overworld with terrain depth, billboard characters, and shadows.
- Quality presets from **HIGH** to **POTATO**, so you can trade visual detail
  for smoother performance.
- A persistent terrain cache so maps do not need to be rebuilt every time they
  are visited.
- Safer cache recovery when a build is interrupted or a device runs low on
  memory.
- Authored sprite-stacked trees and grey bollards instead of unwanted voxel
  replacements.

PotatoVoxel is performance-focused. Your results depend on the device, game
version, resolution, and other enabled mods, so no fixed FPS is promised.

## Install

1. Download the PotatoVoxel `.zip` for your Gen1Recomp version.
2. In Gen1Recomp, open **MODS → Import mod .zip**.
3. Restart the game if requested.
4. Enable **VOXEL** in the game options.

Only run one voxel world mod at a time. Disable DramaticShape, Dramaless Shape,
Battle Art Voxel, and other voxel forks before testing PotatoVoxel. Running two
voxel mods together can cause missing models, overwritten settings, crashes, or
poor performance.

## First launch: build the cache

The cache stores prepared terrain, water, and decoration meshes. Building it
before playing gives the smoothest route transitions.

1. Load a save or start a new game.
2. Open **OPTIONS → VOXEL SETTINGS**.
3. Choose your **VOXEL** quality mode.
4. Select **PREBUILD CACHE** and confirm.
5. Leave the game open until the build finishes and the status becomes
   **READY**.

If the game says **MAP CACHE NOT READY. BUILD NOW?** after **CONTINUE** or
**NEW GAME**, choose **YES** to start the same process. Choosing **NO** lets you
play normally, but the first visits to uncached maps may stutter while they are
built.

On Android and other handhelds, keep the device connected to power during a
large build. A first complete build can still take time. You can cancel and resume later; do
not force-close the game while it is writing a cache entry if you can avoid it.

## Cache management

### Rebuild the cache

You do **not** normally need to rebuild on every launch. Rebuild when the game
asks, after a major PotatoVoxel update, after changing settings that affect the
cache, or when a cache-related visual or loading problem persists.

1. Open **OPTIONS → VOXEL SETTINGS** while in a save.
2. Select **PREBUILD CACHE**.
3. Confirm **REBUILD CACHE?**.
4. Wait for **READY**.

The cache identity includes the geometry and relevant settings, so stale data is
rejected instead of silently being used. A matching cache is reused
automatically after restarting the game.

### Delete the cache

Use the in-game option rather than hunting for files on your device:

1. Open **OPTIONS → VOXEL SETTINGS**.
2. Select **WIPE CACHE**.
3. Confirm **WIPE CACHE?**.
4. Build it again with **PREBUILD CACHE** when ready.

If a build is still running, cancel it first. Wiping removes the prepared mesh
data and the completion marker; it does not delete your save or the game.
PotatoVoxel stores the cache in the mod's private scoped storage, so the path
can differ between desktop, Android, and console builds.

**CACHE STATUS** shows whether the cache is **READY**, its geometry version, and
the compression mode used by the device.

## Quality modes

Choose a named mode to apply a complete set of tuned defaults:

| Mode | Best for | Render scale |
| --- | --- | ---: |
| **OFF** | Normal 2D overworld | — |
| **HIGH** | Strong desktop or handheld hardware | 100% |
| **MEDIUM** | Balanced quality and performance | 75% |
| **LOW** | Lower-powered devices | 50% |
| **POTATO** | The lowest GPU workload | 33% |
| **CUSTOM** | Your own combination of settings | Your choice |

Changing an individual quality setting changes the mode to **CUSTOM**. The
biggest performance control is **RENDER SCALE**. Lower it if the game still
struggles after the cache has been built.

## What is not included

- **VR** and first-/third-person modes.
- The unused **Horde** minigame.
- Pokémon Stadium ROM importing or bundled Stadium ROM assets.
- Other high-cost features removed for performance and
  sandbox compatibility.

`3D-BTL` is an optional PotatoVoxel battle presentation setting. It is not a
promise of Stadium-style battles or imported N64 models.

PotatoVoxel does not ship a Pokémon ROM or ROM-derived asset bytes. It works
with the player's own Gen1Recomp installation and imported game data.

## Frequently asked questions

### Do I need to build the cache every time I open the game?

No. Once the cache says **READY**, it is reused across launches. Rebuild only
when prompted, after a relevant update or settings change, or when troubleshooting.

### Do I need a separate cache for every route?

No. **PREBUILD CACHE** works through the map set and stores the prepared data
for later visits. The cache may still fill individual maps on demand if you
cancel the build or start playing before it finishes.

### Why is the first build slower than normal gameplay?

It prepares many maps and their terrain, water, and decoration meshes. 1.8.0
streams the work in bounded pieces and avoids holding whole-map temporary data,
but the initial build is still more work than loading an already prepared map.

### The cache is stuck or reports errors. What should I do?

First check that no other voxel mod is enabled. Then use **WIPE CACHE**, restart
the game, and run **PREBUILD CACHE** again. If it still fails, report it with
the information in the issue section below.

### Trees or grey bollards look like chunky voxels. Is that expected?

No. Make sure you are running the current release, disable other voxel mods,
wipe the cache, and rebuild it. If the problem remains, include a screenshot
and the newest error-log block in a bug report.

### Why do I still see a short hitch when moving to a new map?

The cache reduces the expensive work but cannot remove device or driver limits
entirely. Confirm the cache is **READY**, try **MEDIUM**, **LOW**, or **POTATO**,
and report repeatable transition stutters with your device details and log.

### Can I use PotatoVoxel with another voxel mod for Stadium sprites?

No. Voxel forks replace the same overworld systems and are not designed to run
together. Choose one voxel mod for a test session; mixing them can make it
look as though one mod's settings or models are missing.

## Adding your own voxel models

MagicaVoxel `.vox` models can replace a map drawing outright -- the S.S. Anne
dock truck is one. See [VOX-PROPS.md](VOX-PROPS.md) for how to size,
orient, place, and ship one.

## Reporting a problem

Please use the [GitHub bug report form](https://github.com/ShaneMcGovernIE/potato_voxel/issues/new/choose)
for crashes, failed cache builds, visual problems, and performance issues.
The form is much easier to troubleshoot than a one-line “it does not work”
message.

Include:

- PotatoVoxel version and Gen1Recomp engine version.
- Platform and device model, including RAM when known.
- VOXEL mode and any settings you changed.
- Whether the cache was **READY**, building, wiped, or failing.
- Exact steps to reproduce the problem.
- The **newest** block from `lua-error.log` (or `switch.log` on Switch), not an
  old crash block.
- A screenshot or short video for visual issues when possible.

For cache and transition problems, mention the map or route and whether the
problem happens during **PREBUILD CACHE**, while loading a map, or while moving
between maps. You can also use **SEND LOGS** in **VOXEL SETTINGS** or the F8
diagnostic shortcut when the log option is enabled.

Diagnostics are intended to contain technical session information only. They
do not include your name, account, save data, or ROM files.


## Credits

- **DramaticShape** — the upstream Dramatic Shape Voxel Mod this project is
  forked from.
- **pret/pokered** — the original game data that Gen1Recomp users provide to
  their own installation.
- **Gen1Reconp** — for making this all possible.
