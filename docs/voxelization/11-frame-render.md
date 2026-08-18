# 11 — One Frame: The Render Pipeline

`lib/VoxelScene.lua` assembles a frame; `lib/Voxel3D.lua` owns the 3D
pass (shader, depth buffer, camera); `lib/ShadowMap.lua` the sun's pass.
The pipeline's `drawWorld` hook (main.lua:414-548) drives it.

## Draw order (VoxelScene.render → drawScene)

```
1. prefetch:      request meshes for current map + neighbours, evict far
                  maps, resolve the loading cover (VoxelLoading)
2. per-frame      DayNight rig → tint uniform; glass mask; glint phase
3. castShadows:   the sun's pass (below) — BEFORE beginScene, because
                  canvases do not nest
4. beginScene:    bind colour + readable depth canvas, clear to sky,
                  set depth mode lequal, bind the scene shader + uniforms
5. terrain:       current map's full mesh + neighbour bodies (translated
                  by (ox, 0, oy))
6. fallback       flat contact/blob decals for characters, ONLY when the
   decals:        shadow map is unavailable or the actor layer is off
7. water:         mirror copy + cast painted into the reflection only,
                  then the reflective water pass (or flat fallback)
8. ghost:         the player's inverted-depth silhouette
9. cast:          characters as leaning cards, then authored figures
10. battle:       staged fight cards/discs on the map (VR frames)
11. grass:        tuft rows, pulled camera-ward like the characters
12. flowers:      cutouts, pull minus 8·sin(angle)
13. overlays:     field FX as ordinary 2D draws anchored via
                  Voxel3D.project
```

There is **no y-sort anywhere** — the depth buffer resolves occlusion,
which is the whole point of the mode (VoxelScene.lua:7-10).

## The scene shader (Voxel3D.lua:72-322)

Vertex stage: world position → sun's view (shadow lookup) → fog → world
curve drop → camera-ward pull → project. Pixel stage: sample atlas,
discard alpha < 0.5, multiply by `vShade · sunlight() · dayTint`,
apply voxel seams, window glass, fog, ghost flatten.

Key uniforms:

- `vShade`: per-vertex baked shading (face direction + AO).
- `sunVP`/`sunModel`/`sunMap`/`sunMap2`: two-layer shadow lookup with a
  2x2 box filter and frustum-rim fade.
- `curve`: the world bend (WorldCurve) — every vertex drops by the
  square of its distance from the camera focus, along Y only, so columns
  move as one piece and buildings stay upright (Voxel3D.lua:133-136).
- `pull`: camera-ward depth bias along each vertex's own eye ray.
- `dayTint`: the hour's light (noon 1,1,1).
- `ghost`/`ghostColor`: flatten to a silhouette (player ghost, hit
  flash).
- `glassMask`/`glassNight`/`glassPhase`/`glassGlint`/`glassOn`: window
  glass (glint anchored in the PANE's texels, driven by camera travel;
  lit lamps at night; gated off for sprite-sheet draws).
- `gridDark`/`gridWidth`: the voxel wireframe (below).

**Two compilations**: the plain scene and the wireframe variant
(`#define VOXEL_GRID`) — fwidth (derivatives) is the one piece a driver
can refuse, so it's a second build; a refusal costs the wireframe and
nothing else (Voxel3D.lua:340-353).

### The voxel wireframe (VoxelGrid.lua)

The wireframe is not geometry — the shader measures each fragment's
distance to the nearest **integer plane of model space**, in display
pixels (via fwidth), and darkens within half a pixel of it. It only
works because every mesh is built one unit per voxel in its own model
space (terrain in world pixels, a character card in the sprite's own
pixels) — which is also why character cards carry no wireframe: a grid
over a 16x16 sprite lands a line every couple of display pixels and
turns a face into a mesh (VoxelScene.lua:621-626). Lines fade out where
a voxel is smaller than ~2 px (survey zoom) or the mesh is off the grid
(`Voxel3D.seams(false)` for sheets).

## The camera (Voxel3D.lua:565-736)

- Orbit: distance = `FOCAL (1.0) × view height`, FOV = the angle that
  makes a straight-down camera frame exactly `vh` world pixels — the
  framing the flat view already has. Pitch from the rung (35° on every
  on-rung in the shipped build). Clip-space Y is flipped (LOVE canvas
  Y-down vs textbook GL).
- Placed cameras (first/third person, battle, VR eyes) hand over
  eye/focus/fov or raw view+proj matrices.
- `horizonY` finds the ground plane's vanishing line by projecting a
  direction at infinity through the same matrix — the sky meets the
  horizon at any pitch/fov/zoom.
- `project(wx, wy, wz)` is what lets the 2D field-FX closures draw
  anchored to world points under the same camera, unchanged.

## The sun's pass (ShadowMap.lua, VoxelScene.lua:824-966)

Render the scene once from the sun: an orthographic camera down the sun
line stores, per texel, how far the light travelled before hitting
something. The main pass transforms each fragment into that space and
asks whether anything got there first — so shadows climb walls, drape
over roofs and slide across NPCs with no case in the code.

- Sun direction: shears KX = −0.85 (west), KZ = −0.55 (north) per pixel
  of height — southeast sun, ~45° elevation, shadows fall northwest,
  clearing the leaning card by design (ShadowMap.lua:38-57).
- Depth packed into an ORDINARY colour canvas, two 8-bit channels
  (~16 bits over the frustum) — a readable depth texture is the least
  portable corner of GLES; everything is pcall-guarded and falls back
  to flat decals.
- **Two layers**: the WORLD layer (terrain, water, figures) re-rasterises
  only when its signature moves (camera/sun/meshes); the SPRITE layer
  (posed characters) only when a sprite does. The main pass ANDs the two
  depth tests — exactly the single-map result — so a standing player
  doesn't redraw the whole world from the sun every frame
  (VoxelScene.lua:824-848, shadowSignature at 783-822).
- Casters: the terrain mesh itself (buildings, trees, ledges, props) +
  one upright card per character (`casterMatrix` — the leaning slab is a
  trick for the camera, not for the sun), snugged through `ShadowMap.snug`
  so the lookup transform matches the stored transform to the letter.
- Resolution: fitted to the view (TARGET 0.45 world px/texel, ladder
  512/768/1024 on the Brick; HIGH fixed 1536) (ShadowMap.lua:78-100,
  BrickProfile.lua:196-208).
- Signature-cached: standing still means the map from last frame is
  still exactly right.

## Water (Water.lua, Voxel3D.lua:1211-1330)

A mirror must read the frame it is drawn into: the colour copy goes to a
mirror canvas, the depth texture is detached and the water shader does
the test itself (with a ray march over the depth texture). The CAST is
painted into the reflection copy alone (Gen 1 draws people over the
world, and a reflection can only contain what was drawn before it) — the
same `drawCast` function, so the two can never disagree.

Under the world curve, a flat prepass draws the water first (with depth
writes) so far sheets can't paint over near ponds; with the curve off
the prepass is skipped (the pass's own test against terrain is exactly
right there, and comparing the surface against itself fails on mobile
GPUs) (VoxelScene.lua:701-733).

The WATER row is now OFF / SKY / HALF / FULL. SKY reflects the sky and
the sun only (no march); HALF and FULL run the screen-space march at two
ray budgets (RAY_STEPS/RAY_REFINE 16/4 vs 24/5, selected by shader
compilation — the same second-compilation pattern as the wireframe).
Wave motion is per-tileset: `Water.WAVE_PROFILES` (tileset id →
{trains, swell, bend}) sent as uniforms, with the phase rate derived
from the ACTIVE profile's dominant train. The water surface also reads
the map's haze (fogColor/fogInfo from `Voxel3D.fog`), so a lake on a
foggy map is the same air its banks are; the reflection already carried
it, being a copy of a fogged frame.

## Atmosphere and weather (MapAtmos.lua, Weather.lua, data/voxel_*.lua)

- **ATMOS** (row, OFF default): `data/voxel_atmos.lua` names per-map
  haze records ({color, density, start, heightK}) — forest haze and cave
  gloom ship. `VoxelScene.render` hands `Voxel3D.fog` the record; the
  shader path that computes it never went away (the 1.6.1 removals
  pinned the uniform to nil). The battle pass keeps its own nil — staged
  shots stay clear.
- **WEATHER** (row, OFF default): `data/voxel_weather.lua` names
  per-map rain/snow entries. Drops live in WORLD space, stepped on the
  wall clock, drawn as thin screen-space streak quads through ONE stream
  mesh in the FX overlay (the same `Voxel3D.project` seam the "!" bubble
  uses) — parallax against the terrain, in front of everything, no
  depth writes. Pool bounded 40-220, recycled in place, re-seeded on
  camera teleports.
- **F6** toggles the class-map debug view (ShapeDebug.lua): every tile
  tinted by its resolved shape class, volume runs toward white, claimed
  cells toward magenta — the authoring tool for the shape profile.

## Quality modes and resolution scale

The scene renders at the RENDER SCALE (100/75/50/33 %) of the window's
pixel dimensions, then is folded back up (main.lua:483-538). With AA on,
the whole pass renders BIGGER and folds down. Everything inside the
frame measures itself in the canvas it was handed, so the sky's dither,
the water's march and the camera all come out the same picture at a
different sample rate.

## Fallbacks (the mod's contract)

Every GPU object is pcall-guarded; `Voxel3D.available()` reports the
result and the engine keeps the vanilla 2D path — headless runs and
drivers without depth-canvas/shader support never error. Depth formats
are tried in preference order (depth24 → depth24stencil8 → depth32f →
depth16) (Voxel3D.lua:383-409). The shader is compiled with mediump
effect params, retried bare for compilers that reject the prototype
(Voxel3D.lua:324-336).
