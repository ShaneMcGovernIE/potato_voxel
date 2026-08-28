-- Overworld battles: one frame of the arena, as geometry.
--
-- The same world the free-roam mode draws, from a placed camera instead of
-- the orbit, at the WINDOW's own pixel resolution -- not the GB's. The
-- backdrop reaches the screen through Renderer's worldOverride, the seam a
-- render pipeline's finished world image already composites through, which
-- is drawn one canvas pixel to one screen pixel; the 160x144 battle screen
-- then blits over it in the classic letterbox. So the world is as crisp as
-- the free-roam diorama and the pics, HUDs and text box stay exactly the
-- chunky GB art they are.
--
-- Rendering the whole window rather than just the letterbox means the
-- framing has to be split in two. The RIG frames the GB's 160x144 (see
-- BattleCam, which is solved against coordinates in that frame); this
-- module widens the lens by exactly the ratio the window bears to the
-- letterbox, so the letterbox sub-rectangle of what gets rendered is
-- bit-for-bit the framing the rig asked for, and everything outside it is
-- extra picture. That is what lets the two mons be PINNED: their cells
-- project to the same GB coordinates at any window size or zoom.
--
-- Characters are deliberately absent. The overworld cast is culled for the
-- length of the battle (see OverworldBattle), so this pass has terrain,
-- grass and flowers and nothing that walks -- the arena is empty, which is
-- what makes it an arena.
--
-- Everything expensive is shared with the free-roam mode rather than
-- duplicated: the same chunk meshes out of ChunkMesher, the same palette
-- atlas out of TerrainAtlas, the same sun out of ShadowMap. A battle on a
-- map already meshed for walking around costs the frame it draws and
-- nothing else.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")
local ShadowMap = V.require("ShadowMap")
local ShadowCast = V.require("ShadowCast")
local SpriteBillboards = V.require("SpriteBillboards")
local ChunkMesher = V.require("ChunkMesher")
local TerrainAtlas = V.require("TerrainAtlas")
local VoxAssets = V.require("VoxAssets")
local VoxelScene = V.require("VoxelScene")
local BattleCam = V.require("BattleCam")
local BattleBillboard = V.require("BattleBillboard")
local VoxelState = V.require("VoxelState")
local DayNight = V.require("DayNight")
local BrickProfile = V.require("BrickProfile")
local AntiAlias = V.require("AntiAlias")
local ShadowSettings = V.require("ShadowSettings")
local Upscale = V.require("Upscale")
local PaletteFX = require("src.render.PaletteFX")
local RuntimeHooks = V.require("RuntimeHooks")
local Stereoscopic3D = V.require("Stereoscopic3D")

local BattleScene = {}

-- The classic frame the battle screen is drawn in.  BattleState may expose a
-- wider native surface while a WIDE battle is active; all consumers go
-- through layoutMetrics() below rather than assuming these dimensions.
BattleScene.GB_W = 160
BattleScene.GB_H = 144
BattleScene.WIDE_W = 304
BattleScene.WIDE_H = 144

-- A map cell in world pixels: the overworld square a mon stands on, which is
-- both what the arena is measured in and what a mon is sized to.
BattleScene.CELL = 16

-- How far into black a shadow goes in the arena, against the free-roam
-- mode's own lighter setting.
--
-- Darker on purpose, and only here. Walking around, a shadow is scenery and
-- wants to stay out of the way of reading the map. In a battle it is doing
-- one specific job: the two mons are flat cards, and the ONLY thing telling
-- the eye they are standing on that floor rather than hanging in front of it
-- is the shadow they put on it. A faint one leaves them floating.
BattleScene.SHADOW_ALPHA = 0.68

-- Which rung of the sky ramp an indoor void is painted with. A room has no
-- sky, but it does have somewhere the geometry stops, and leaving that
-- transparent would show the letterbox clear through the gaps.
local INDOOR_SHADE = 4

-- The window in FRAMEBUFFER pixels, which is what the override blit works
-- in. love.graphics.getDimensions is in LOVE units and differs from this by
-- the display density on mobile.
function BattleScene.pixelSize()
  if love.graphics.getPixelDimensions then
    local pw, ph = love.graphics.getPixelDimensions()
    if pw and ph and pw > 0 and ph > 0 then return pw, ph end
  end
  return love.graphics.getDimensions()
end

local function number(value, fallback)
  return type(value) == "number" and value or fallback
end

local function pair(value)
  if type(value) ~= "table" then return nil end
  local x = value.x
  if x == nil then x = value[1] end
  local y = value.y
  if y == nil then y = value[2] end
  if type(x) ~= "number" or type(y) ~= "number" then return nil end
  return x, y
end

local function methodValue(owner, name, ...)
  if not (owner and type(owner[name]) == "function") then return nil end
  local ok, value, second = pcall(owner[name], owner, ...)
  if not ok then return nil end
  return value, second
end

local function methodTable(owner, name, ...)
  if not (owner and type(owner[name]) == "function") then return nil end
  local ok, value = pcall(owner[name], owner, ...)
  return ok and value or nil
end

local function battleOptions(battle)
  local game = battle and battle.game
  return game and game.save and game.save.options or nil
end

-- Screen-position support is deliberately kept at this boundary.  Newer
-- engine builds expose it on BattleState, while older compatible builds only
-- carry the value in save options.  The battle renderer should not need to
-- know which generation supplied the position.
local function positionFor(battle, frame, surfaceW, surfaceH, scale, pw, ph)
  local raw = frame and frame.position
  local directX = frame and frame.viewportX
  local directY = frame and frame.viewportY

  if raw == nil then
    local owners = {}
    if battle then
      owners[#owners + 1] = battle
      if battle.game then
        owners[#owners + 1] = battle.game
        if battle.game.renderer then
          owners[#owners + 1] = battle.game.renderer
        end
      end
    end
    for _, owner in ipairs(owners) do
      for _, name in ipairs({ "screenPosition", "layoutPosition", "uiPosition" }) do
        local value, second = methodValue(owner, name)
        local x, y = pair(value)
        if x ~= nil then raw = { x = x, y = y }; break end
        if type(value) == "number" and type(second) == "number" then
          raw = { x = value, y = second }; break
        end
        if type(value) == "string" then raw = value; break end
      end
      if raw ~= nil then break end
    end
  end

  local options = battleOptions(battle)
  if raw == nil and options then
    for _, name in ipairs({ "battleScreenPosition", "battleScreenPos",
                            "battlePosition", "screenPosition", "screenPos" }) do
      if options[name] ~= nil then raw = options[name]; break end
    end
    if raw == nil then
      local x = options.battleScreenX or options.battlePosX
                or options.battleOffsetX
      local y = options.battleScreenY or options.battlePosY
                or options.battleOffsetY
      if type(x) == "number" and type(y) == "number" then
        raw = { x = x, y = y }
      end
    end
  end

  local offsetX, offsetY = pair(raw)
  if offsetX == nil and type(raw) == "string" then
    local name = raw:lower():gsub("_", "-")
    local horizontal = name:find("left", 1, true) and -1
                       or name:find("right", 1, true) and 1 or 0
    local vertical = name:find("top", 1, true) and -1
                     or name:find("bottom", 1, true) and 1 or 0
    local spareX = math.max(0, pw - surfaceW * scale) / scale
    local spareY = math.max(0, ph - surfaceH * scale) / scale
    offsetX, offsetY = horizontal * spareX / 2, vertical * spareY / 2
  end
  offsetX, offsetY = offsetX or 0, offsetY or 0

  local centeredX = math.floor((pw - surfaceW * scale) / 2)
  local centeredY = math.floor((ph - surfaceH * scale) / 2)
  local viewportX = directX or centeredX + math.floor(offsetX * scale + 0.5)
  local viewportY = directY or centeredY + math.floor(offsetY * scale + 0.5)
  if directX ~= nil then offsetX = (viewportX - centeredX) / scale end
  if directY ~= nil then offsetY = (viewportY - centeredY) / scale end
  return viewportX, viewportY, offsetX, offsetY
end

local function anchorsFor(battle, surfaceW, surfaceH)
  local custom = methodTable(battle, "layoutAnchors", surfaceW, surfaceH)
  if type(custom) == "table" and custom.player and custom.enemy then
    return custom
  end

  -- WideBattle keeps the original 160px pic regions but translates the player
  -- region by (20, 8) and the enemy region by (136, 0).  Keep those offsets in
  -- the same layout boundary as the surface dimensions so the world cards,
  -- effects and HUD all use one composition.
  local okVersion, GameVersion = pcall(require, "src.core.GameVersion")
  local generation = okVersion and GameVersion
                   and type(GameVersion.generation) == "function"
                   and tonumber(GameVersion.generation()) or nil
  local playerX, playerY = generation == 2 and 40 or 26, 96
  local enemyX, enemyY = 124, 56
  if surfaceW > BattleScene.GB_W then
    playerX, playerY = playerX + 20, playerY + 8
    enemyX, enemyY = enemyX + 136, enemyY
  end
  return {
    player = { playerX, playerY },
    enemy = { enemyX, enemyY },
  }
end

local function hudFor(surfaceW)
  if surfaceW > BattleScene.GB_W then
    return {
      enemy = { 0, 0, 128, 32 },
      player = { 184, 56, 120, 40 },
    }
  end
  return {
    enemy = { 8, 0, 80, 32 },
    player = { 72, 56, 88, 40 },
  }
end

local function shiftedCamera(camera, metrics, vw, vh)
  if not (camera and camera.eye and camera.focus) then return camera end
  local centerX = metrics.viewportX + metrics.viewportW / 2
  local centerY = metrics.viewportY + metrics.viewportH / 2
  local deltaX = centerX - metrics.pw / 2
  local deltaY = centerY - metrics.ph / 2
  if math.abs(deltaX) < 0.01 and math.abs(deltaY) < 0.01 then
    return camera
  end

  local eye, focus = camera.eye, camera.focus
  local fx, fy, fz = focus[1] - eye[1], focus[2] - eye[2], focus[3] - eye[3]
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  if fl < 1e-6 then return camera end
  fx, fy, fz = fx / fl, fy / fl, fz / fl
  local up = camera.up or { 0, 1, 0 }
  local rx = fy * up[3] - fz * up[2]
  local ry = fz * up[1] - fx * up[3]
  local rz = fx * up[2] - fy * up[1]
  local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
  if rl < 1e-6 then return camera end
  rx, ry, rz = rx / rl, ry / rl, rz / rl
  local ux = ry * fz - rz * fy
  local uy = rz * fx - rx * fz
  local uz = rx * fy - ry * fx

  -- `vw`/`vh` are the world span of the full render canvas at the focus
  -- plane. Move the camera, rather than merely changing the post-projection
  -- conversion, so the rendered world and the battle UI share the same
  -- off-centre viewport.
  local worldX = deltaX * vw / metrics.pw
  local worldY = deltaY * vh / metrics.ph
  local sx = -rx * worldX + ux * worldY
  local sy = -ry * worldX + uy * worldY
  local sz = -rz * worldX + uz * worldY

  local out = {}
  for key, value in pairs(camera) do out[key] = value end
  out.eye = { eye[1] + sx, eye[2] + sy, eye[3] + sz }
  out.focus = { focus[1] + sx, focus[2] + sy, focus[3] + sz }
  if camera.up then out.up = { camera.up[1], camera.up[2], camera.up[3] } end
  return out
end

-- The one layout boundary for staged battles.  Coordinates returned here are
-- physical framebuffer pixels for the viewport, with logical battle pixels
-- retained for the camera pins and HUD anchors.
function BattleScene.layoutMetrics(battle, frame)
  frame = frame or {}
  local surfaceW, surfaceH = BattleScene.GB_W, BattleScene.GB_H
  if battle and type(battle.uiSize) == "function" then
    local ok, w, h = pcall(battle.uiSize, battle)
    if ok and type(w) == "number" and type(h) == "number"
       and w >= BattleScene.GB_W and h >= BattleScene.GB_H then
      surfaceW, surfaceH = math.floor(w), math.floor(h)
    end
  elseif battle and type(battle.wideLayout) == "function" then
    local ok, wide = pcall(battle.wideLayout, battle)
    if ok and wide then surfaceW, surfaceH = BattleScene.WIDE_W, BattleScene.WIDE_H end
  end

  local pw = number(frame.pw, nil)
  local ph = number(frame.ph, nil)
  local dpiX = number(frame.dpiX, nil)
  local dpiY = number(frame.dpiY, nil)
  if not (pw and ph) then pw, ph = BattleScene.pixelSize() end
  if not dpiX or not dpiY then
    local ww, wh = love.graphics.getDimensions()
    dpiX = dpiX or ((ww and ww > 0) and pw / ww or 1)
    dpiY = dpiY or ((wh and wh > 0) and ph / wh or 1)
  end
  dpiX, dpiY = math.max(1e-6, dpiX), math.max(1e-6, dpiY)

  local fill = frame.fill
  if fill == nil and battle and type(battle.wantsFillScale) == "function" then
    local ok, value = pcall(battle.wantsFillScale, battle)
    fill = ok and value == true or false
  end
  fill = fill == true

  local fitScale = math.min(pw / surfaceW, ph / surfaceH)
  local fixedScale = math.max(1, math.floor(fitScale))
  local fillScale = fitScale
  local scale = number(frame.scale, nil)
  if not scale and not frame.pw and not frame.ph then
    local Renderer = require("src.render.Renderer")
    local ok, currentW, currentH = pcall(Renderer.uiSize, Renderer)
    if ok and currentW == surfaceW and currentH == surfaceH
       and type(Renderer.fitScale) == "function" and not fill then
      local okScale, fit = pcall(Renderer.fitScale, Renderer)
      if okScale and type(fit) == "number" and fit > 0 then
        scale, fixedScale = fit, fit
      end
    end
  end
  if not scale then
    scale = fill and fillScale or fixedScale
  end

  local viewportX, viewportY, offsetX, offsetY =
    positionFor(battle, frame, surfaceW, surfaceH, scale, pw, ph)
  local anchors = anchorsFor(battle, surfaceW, surfaceH)
  local dx = anchors.enemy[1] - anchors.player[1]
  local dy = anchors.enemy[2] - anchors.player[2]

  return {
    surfaceW = surfaceW, surfaceH = surfaceH,
    viewportX = viewportX, viewportY = viewportY,
    viewportW = surfaceW * scale, viewportH = surfaceH * scale,
    offsetX = offsetX, offsetY = offsetY,
    scale = scale, fill = fill,
    scaleMode = fill and "fill" or "fixed",
    fitScale = fitScale, fixedScale = fixedScale, fillScale = fillScale,
    dpiX = dpiX, dpiY = dpiY,
    drawScaleX = scale / dpiX, drawScaleY = scale / dpiY,
    pw = pw, ph = ph,
    -- Side-pic captures remain a classic 160x144 logical frame even when
    -- the composed battle surface is WIDE.  Animation captures use the full
    -- surface; keeping both dimensions here prevents either caller from
    -- baking that distinction into another layout assumption.
    captureW = BattleScene.GB_W, captureH = BattleScene.GB_H,
    anchors = anchors,
    hud = hudFor(surfaceW),
    anchorSpan = math.sqrt(dx * dx + dy * dy),
  }
end

function BattleScene.animationOffset(battle, metrics)
  if not (battle and metrics and metrics.surfaceW > BattleScene.GB_W) then
    return 0, 0
  end
  local player = battle.animPlayer
  local sprites
  if battle.animPlaying and player then
    local step = player.steps and player.steps[player.stepIndex]
    sprites = step and step.sprites
  elseif battle.lockedBall and player then
    sprites = battle.lockedBall
  end
  if not sprites then return 0, 0 end
  local ok, WideBattle = pcall(require, "src.battle.WideBattle")
  if not (ok and WideBattle and type(WideBattle.animationOffset) == "function") then
    return 0, 0
  end
  local okOffset, x, y = pcall(WideBattle.animationOffset, sprites)
  if okOffset and type(x) == "number" and type(y) == "number" then
    return x, y
  end
  return 0, 0
end

-- Renderer blits worldOverride one canvas pixel to one screen pixel and then
-- blits the battle surface into the viewport described above.  Keep this
-- compatibility helper for callers that only need the classic tuple.
function BattleScene.letterbox(battle, frame)
  local m = BattleScene.layoutMetrics(battle, frame)
  return m.viewportX, m.viewportY, m.scale, m.pw, m.ph, m
end

function BattleScene.renderScale(level)
  return BrickProfile.battleRenderScale(level)
end

-- Widen the rig's vertical field of view from the GB frame to the whole
-- window, so the letterbox rows show exactly what the rig framed.
--
-- The horizontal falls out of it: at aspect pw/ph the window's half-width is
-- tan(fov/2) * pw/ph, and the letterbox is 160*s of those pw pixels, which
-- works back out to the GB frame's own 160/144. So one scale on the vertical
-- pins both axes.
function BattleScene.letterboxFov(fovGB, ph, s, surfaceH)
  local span = (surfaceH or BattleScene.GB_H) * s
  if span <= 0 then return fovGB end
  return 2 * math.atan(math.tan(fovGB / 2) * ph / span)
end

-- ------- palette
--
-- The world palette a map draws under, in the shape VoxelScene's colour
-- helpers take. Rebuilt per frame from the overworld state, which is where
-- the engine's own pipeline context gets it too (OverworldController's
-- ctx.paletteFor).
local function paletteFor(state, home)
  local okVersion, GameVersion = pcall(require, "src.core.GameVersion")
  local generation = okVersion and GameVersion
                   and type(GameVersion.generation) == "function"
                   and tonumber(GameVersion.generation()) or nil
  if generation == 2 then
    local okPalettes, Palettes = pcall(require, "src.world.gen2.Palettes")
    if okPalettes and Palettes then
      return function(map)
        local game = RuntimeHooks.gameOwner()
        local data = game and game.data
        local def = (map or home) and (map or home).def
        local palettes = state.palettes or (data and data.gen2Palettes)
        local daytime = state.daytime or state.tod
        if not daytime and type(state.hour) == "function" then
          local okHour, hour = pcall(state.hour, state)
          if okHour then
            daytime = Palettes.daytimeFor(def, hour, state.flashUsed)
          end
        end
        daytime = daytime or "DAY"
        local okSet, set = pcall(Palettes.bgSet, palettes, def, daytime)
        return okSet and set and set[1] or nil
      end
    end
  end
  return function(map)
    return PaletteFX.pal(require("src.core.Game").data,
                         state:paletteNameFor(map or home))
  end
end

-- Kept as a small seam because Gen2 resolves a palette from the live World
-- clock while Gen1 resolves a name from its map state.
BattleScene.paletteFor = paletteFor

-- ------- the map the fight is staged on
--
-- Normally the one the player is standing on. An authored arena may name
-- another floor of the same cave or building (see BattleArena), and then the
-- scene is THAT map: its terrain, its palette, its sky. Nothing else in the
-- battle changes -- the fight, the party, the player's own position are all
-- exactly where they were.
--
-- A foreign floor is meshed alone, with no connected neighbours: connections
-- are the player's neighbourhood, and the map the camera has gone to visit is
-- not standing in it. Both maps are kept live so neither the arena's mesh nor
-- the one waiting to be walked back onto is evicted mid-battle.
local function prefetchArena(state, host)
  if host == state.map then return VoxelScene.prefetch(state) end
  local live = { [host.id] = true, [state.map.id] = true }
  for _, nb in ipairs(state.neighbors or {}) do live[nb.map.id] = true end
  ChunkMesher.setLive(live)
  TerrainAtlas.setLive(live)
  ChunkMesher.request(host, "body", nil, true)
  ChunkMesher.request(host, "ring", nil, true)
  local terrain, water = ChunkMesher.pair(host, "body")
  local ring, ringWater = ChunkMesher.pair(host, "ring")
  return terrain, {}, water, {}, ring, ringWater
end

-- ------- the sun
--
-- Only has to be drawn once per battle: the arena does not move, and neither
-- does the light. So the signature is the map, the arena and the meshes --
-- not the camera, which is the one thing that IS moving and the one thing
-- the sun does not care about.
-- ------- the two mons, hung on their cells
--
-- The billboard texture is the battle screen's own 160x144 pics layer with
-- one side rendered into it (see OverworldBattle.sideTexture), so the quad is
-- that whole frame stood up on the map -- which is what carries every pic
-- effect the engine applies without any of them being reimplemented here.
--
-- Its size follows from one number: a full 7x7-tile mon covers one overworld
-- square, so a canvas pixel is FULL_W / FULL_PIC world pixels and the card is
-- the canvas at that scale. Its placement follows from the anchor the
-- texture reports -- the column the pic was centred on and the row its feet
-- were put on -- which is translated onto the cell before the card is stood
-- up, so a mon of any size in any pose has its feet on the ground.
-- `mirror` flips the card about its own anchor column. Both mons wear their
-- FRONT pic, which is drawn facing out of the screen -- so dropped into the
-- world unaltered the pair stand back to back, both looking the same way past
-- each other. Mirroring the near one turns it to face the far one, which is
-- what a fight looks like; and because it is a flip about the pic's own
-- centre the feet do not move off the tile.
--
-- The player's TRAINER pic is the exception, and it is exempted below. That
-- one is a BACK view -- the player seen from behind, already turned to face
-- up the field -- so it arrives pointing the right way and mirroring it would
-- turn it around to face the camera it is standing in front of.
local function monMatrix(tex, x, groundY, z, mirror)
  local k = BattleBillboard.FULL_W / BattleBillboard.FULL_PIC
  local captureW = tex.captureW or BattleScene.GB_W
  local captureH = tex.captureH or BattleScene.GB_H
  local w = captureW * k
  local h = captureH * k
  local ox = -((tex.ax / captureW) - 0.5) * w
  local oy = -((captureH - tex.ay) / captureH) * h
  local yaw = BattleBillboard.yawToward(x, z, Voxel3D.eye)
  local card = Mat4.mul(Mat4.translate(ox, oy, 0), Mat4.scale(w, h, 1))
  if mirror then card = Mat4.mul(Mat4.scale(-1, 1, 1), card) end
  return Mat4.mul(Mat4.mul(Mat4.translate(x, groundY, z), Mat4.rotateY(yaw)),
                  card)
end

-- Every mon that has something to show this frame, as (texture, matrix).
local function monCards(arena, groundY, textures)
  local out = {}
  if not textures then return out end
  for _, side in ipairs({ "enemy", "player" }) do
    local tex = textures[side]
    local cell = (side == "player") and arena.player or arena.enemy
    if tex and tex.canvas and cell then
      local mirror = (side == "player") and tex.mirror ~= false
                    and not tex.trainer
      out[#out + 1] = { tex = tex.canvas,
                        model = monMatrix(tex, cell[1], groundY, cell[2],
                                          mirror) }
    end
  end
  return out
end

BattleScene.monCards = monCards

-- The MOVE-ANIMATION layer's place in the world: a BILLBOARD facing the
-- eye, for the GB-frame effects texture OverworldBattle.animTexture
-- renders (the engine's own drawAnimLayer, caught on a canvas).
--
-- Effects are 2D drawings like the pics, and the pics' answer holds for
-- them too: a drawing must FACE the eye that is looking (the mon cards
-- yaw toward it per eye -- see monMatrix). So the frame stands on the
-- arena's midpoint, yawed at the eye like the cards are, and the classic
-- layout's two slot marks are pinned where each CELL lands on that plane
-- along this very eye's own ray -- so from the eye that is looking, a
-- burst authored at a slot sits exactly over the mon standing in for it,
-- and a projectile crossing the frame crosses the arena. The vertical
-- scale is the mon cards' own (FULL_W / FULL_PIC), so an effect is sized
-- like the pics it plays over.
--
-- An eye standing (nearly) ON the arena's axis sees the two cells in
-- line and the pinning degenerates; the frame then falls back to the
-- fixed plane through both cells, which that eye views edge-on anyway.
--
-- Reads Voxel3D.eye at CALL time, like the cards -- call it per eye.
-- Returns the model matrix for BattleBillboard's unit card (x -0.5..0.5,
-- y 0..1 up, v flipped), or nil where the anchors are degenerate.
function BattleScene.fxCard(arena, groundY, anchors, metrics)
  local p, e = anchors.player, anchors.enemy
  local dgb = e[1] - p[1]
  if math.abs(dgb) < 1 then return nil end
  local GW = metrics and metrics.surfaceW or BattleScene.GB_W
  local GH = metrics and metrics.surfaceH or BattleScene.GB_H
  local Px, Py, Pz = arena.player[1], groundY, arena.player[2]
  local Ex, Ey, Ez = arena.enemy[1], groundY, arena.enemy[2]
  local s = BattleBillboard.FULL_W / BattleBillboard.FULL_PIC
  local Mx, My, Mz = (Px + Ex) / 2, groundY, (Pz + Ez) / 2

  local eye = Voxel3D.eye
  local yaw = BattleBillboard.yawToward(Mx, Mz, eye)
  local nx, nz = math.sin(yaw), math.cos(yaw)     -- out of the frame, at the eye
  local rx, rz = math.cos(yaw), -math.sin(yaw)    -- the frame's own right

  -- where a world point sits ON the billboard, as (right, up) coordinates
  -- about the midpoint: slid along the eye's ray onto the plane, so the
  -- mark and the mon line up from exactly the seat that is looking
  local function inPlane(qx_, qy_, qz_)
    if eye then
      local dqx, dqy, dqz = qx_ - eye[1], qy_ - eye[2], qz_ - eye[3]
      local denom = dqx * nx + dqz * nz
      if math.abs(denom) > 1e-6 then
        local t = ((Mx - eye[1]) * nx + (Mz - eye[3]) * nz) / denom
        qx_ = eye[1] + dqx * t
        qy_ = eye[2] + dqy * t
        qz_ = eye[3] + dqz * t
      end
    end
    return (qx_ - Mx) * rx + (qz_ - Mz) * rz, qy_ - My
  end
  local pax, pay = inPlane(Px, Py, Pz)
  local eax, eay = inPlane(Ex, Ey, Ez)

  if math.abs(eax - pax) < 4 then
    -- edge-on: the fixed plane through both cells, world-axis mapping
    local ux = (Ex - Px) / dgb
    local uy = (Ey - Py - s * (p[2] - e[2])) / dgb
    local uz = (Ez - Pz) / dgb
    local cx = Px + ux * (0.5 * GW - p[1])
    local cy = Py + uy * (0.5 * GW - p[1]) + s * (p[2] - GH)
    local cz = Pz + uz * (0.5 * GW - p[1])
    local nl = math.sqrt(ux * ux + uz * uz)
    local fx, fz = 0, 1
    if nl > 1e-9 then fx, fz = uz / nl, -ux / nl end
    return { ux * GW, 0, fx, cx,
             uy * GW, s * GH, 0, cy,
             uz * GW, 0, fz, cz,
             0, 0, 0, 1 }
  end

  -- in-plane travel per GB pixel of frame x, solved so both marks land:
  -- inPlane(gb) = (pax, pay) + U * (gbx - p.x) + (0, s) * (p.y - gby)
  local ux = (eax - pax) / dgb
  local uy = (eay - pay - s * (p[2] - e[2])) / dgb
  local cxp = pax + ux * (0.5 * GW - p[1])
  local cyp = pay + uy * (0.5 * GW - p[1]) + s * (p[2] - GH)
  return { rx * ux * GW, 0, nx, Mx + rx * cxp,
           uy * GW, s * GH, 0, My + cyp,
           rz * ux * GW, 0, nz, Mz + rz * cxp,
           0, 0, 0, 1 }
end

-- The sun has to see the mons too, or they stand on the ground without
-- putting anything on it. They are the one thing in this scene that MOVES,
-- so `token` -- a counter the caller bumps whenever a pic could have changed
-- -- goes in the signature; the terrain half of the answer would otherwise
-- keep a stale pass alive and freeze the shadows in whatever pose they were
-- first drawn in.
local function shadowSignature(state, arena, terrain, ring, nbMesh, token)
  local host = arena.map or state.map
  -- `turn` is in the signature with the corner and the shape: the same corner
  -- turned a quarter is a different footprint standing on different ground,
  -- and a cast kept from the other one freezes the shadows across it
  local parts = { "battle", host.id, arena.x, arena.y, arena.shape,
                  tostring(arena.turn or 0),
                  tostring(terrain), tostring(ring), tostring(token or 0),
                  -- the cycle keeps running through a fight, and an arena lit
                  -- from somewhere new must be re-cast from there
                  math.floor(ShadowMap.KX * 128),
                  math.floor(ShadowMap.KZ * 128) }
  for i = 1, #nbMesh do parts[#parts + 1] = tostring(nbMesh[i]) end
  return table.concat(parts, ",")
end

local function castShadows(state, arena, terrain, ring, nbMesh, cx, cy, vw, vh,
                           atlasFor, voxTextureFor, cards, token, host, neighbors,
                           water, ringWater, nbWater, groundY, actorShadows)
  if not ShadowMap.available() then return end
  local worldSig = shadowSignature(state, arena, terrain, ring, nbMesh)
  local spriteSig = shadowSignature(state, arena, terrain, ring, nbMesh, token)
  local worldStale = ShadowMap.stale(worldSig, false)
  local spriteStale = actorShadows and ShadowMap.stale(spriteSig, true) or false
  if not worldStale and not spriteStale then return end

  if worldStale then
    if not ShadowMap.begin(cx, cy, vw, vh, false) then return end
    -- A DISC RUNG: the two discs are the only ground there is, so they are the
    -- only thing the sun has to see besides the Pokemon themselves.
    if arena.discs then
      pcall(function()
        V.require("DiscArena").cast(ShadowMap, arena, groundY or 0)
      end)
    else
      -- the one shared world-layer run (lib/ShadowCast.lua)
      ShadowCast.terrainAndWater(ShadowMap, ChunkMesher, {
        map = host, atlasFor = atlasFor,
        voxTextureFor = voxTextureFor,
        terrain = terrain, ring = ring,
        water = water, ringWater = ringWater,
        neighbors = neighbors,
        nbMesh = nbMesh, nbWater = nbWater,
      })
    end
    ShadowMap.finish(worldSig, false)
  end

  if actorShadows and (worldStale or spriteStale) then
    if not ShadowMap.begin(cx, cy, vw, vh, true) then return end
    -- Battle cards belong in the actor layer, never in the terrain layer.
    -- This prevents a card from self-shadowing its own two triangles.
    ShadowMap.sprites(true)
    for _, card in ipairs(cards or {}) do
      ShadowMap.draw(BattleBillboard.mesh(), card.tex,
                     ShadowMap.snug(card.model))
    end
    ShadowMap.sprites(false)
    ShadowMap.finish(spriteSig, true)
  end
end

local function drawContactShadows(arena, groundY)
  local mesh, texture = SpriteBillboards.shadowBlob()
  if not mesh then return end
  Voxel3D.beginShadows()
  for _, cell in ipairs({ arena.player, arena.enemy }) do
    if cell then
      Voxel3D.draw(mesh, texture,
                   Voxel3D.shadowBlobMatrix(cell[1], cell[2], groundY),
                   Voxel3D.SHADOW_PULL)
    end
  end
  Voxel3D.endShadows()
end

-- The height of the arena floor: the ground the two mons stand on. Both
-- cells are open, so they are normally the same; take the player's, which is
-- the one nearer the camera and therefore the one a mismatch would show up
-- against.
function BattleScene.groundY(map, arena)
  -- A disc rung's discs are carried, not found: their tops ARE the ground
  -- plane, so there is no terrain height to read and reading one would put
  -- the stage at whatever elevation the map happens to have at a spot the
  -- fight is not actually happening on
  if arena and arena.discs then return 0 end
  local ok, h = pcall(VoxelScene.groundAt, map,
                      arena.playerCell[1], arena.playerCell[2])
  return (ok and h) or 0
end

-- Where a world point lands in the active battle surface under `vp`, or nil
-- when it is behind the camera. The metrics argument keeps the conversion
-- aligned with OG/WIDE, FIXED/FILL, DPI and screen-position choices.
function BattleScene.toGB(vp, wx, wy, wz, metricsOrX, ly, s, pw, ph)
  local cx = vp[1] * wx + vp[2] * wy + vp[3] * wz + vp[4]
  local cy = vp[5] * wx + vp[6] * wy + vp[7] * wz + vp[8]
  local cw = vp[13] * wx + vp[14] * wy + vp[15] * wz + vp[16]
  if cw <= 1e-6 then return nil end
  local metrics
  if type(metricsOrX) == "table" then
    metrics = metricsOrX
  else
    metrics = { viewportX = metricsOrX, viewportY = ly, scale = s,
                pw = pw, ph = ph }
  end
  -- viewProjection already flipped clip Y into LOVE's Y-down convention
  local px = (cx / cw * 0.5 + 0.5) * metrics.pw
  local py = (cy / cw * 0.5 + 0.5) * metrics.ph
  return (px - metrics.viewportX) / metrics.scale,
         (py - metrics.viewportY) / metrics.scale
end

-- Render the arena and hand back { canvas, player = {x,y}, enemy = {x,y} },
-- the two marks in GB coordinates -- or nil when there is nothing to draw
-- yet (the terrain mesh is still building, the driver has no depth support).
-- nil is not a failure: the caller simply leaves the battle screen as the
-- engine drew it for that frame.
-- White, for the hit flash, and how far toward it the card goes.
--
-- The shader replaces the card's colour rather than multiplying it, so at
-- full strength this is the sprite turned into a solid white silhouette --
-- which is what the effect is on a flat GB screen and far too much on a
-- sprite standing in a lit world. Held well short of 1, the mon's own
-- shading still reads through the flash: it looks struck rather than
-- deleted.
BattleScene.FLASH_COLOR = { 1, 1, 1 }
BattleScene.FLASH_STRENGTH = 0.5

-- ------- the tile clock, while the overworld is not the one drawing
--
-- Water and flowers animate off TileRenderer's 60Hz counter, and the ENGINE
-- only advances it from OverworldState:drawWorld -- which runs under dialogs
-- and menus, but not under a battle, because a battle draws instead of the
-- overworld rather than over it. So for the length of a staged fight the
-- counter stood still: the water tiles stopped rotating their pixels and the
-- wave field, which is driven off the same number so the two cannot drift
-- (see Water), stopped with them. A lake in the background of a battle was a
-- photograph.
--
-- Ticked HERE rather than from the mod's update hook, because here is the
-- one place that means "a staged battle is drawing this frame, and the
-- overworld is not". From the update hook the condition would have to be
-- guessed at, and a frame where both ran would double the rate.
local function tickTiles()
  local Game = RuntimeHooks.gameOwner()
  local ow = Game and (Game.overworld or Game.world)
  local top = Game and Game.stack and Game.stack:top()
  -- during the wipe INTO a battle the overworld can still be the one
  -- drawing, and it is ticking the clock itself; two ticks in a frame would
  -- run the water at double speed
  if top and ow and top == ow then return end
  pcall(require("src.render.TileRenderer").tick)
end

function BattleScene.render(state, arena, textures, token, battle)
  if not (state and state.map and arena) then return nil end
  if not Voxel3D.available() then return nil end
  tickTiles()

  -- The battle state owns the active composition. Passing it explicitly keeps
  -- the 3D pass in step with the UI when the stack is wide, filled or offset.
  local metrics = BattleScene.layoutMetrics(battle)

  -- the floor the fight is staged on: normally the player's own, sometimes
  -- another floor of the same cave or building (see BattleArena)
  local host = arena.map or state.map
  local neighbors = (host == state.map) and (state.neighbors or {}) or {}

  -- the hour's light reaches the arena exactly as it reaches free-roam: the
  -- shared rig follows the clock on an outdoor floor and stays at noon on an
  -- indoor one, and the same tint multiplies the staged shot -- with the
  -- same window glass on whatever buildings stand in the background
  local outdoor = host.def and RuntimeHooks.isOutdoor(host.def) or false
  DayNight.applyRig(outdoor)
  -- a canopy floor (Viridian Forest) fights under the hour's tint too,
  -- with the rig and the void exactly as they were
  Voxel3D.tint = DayNight.tint(outdoor or DayNight.isCanopy(host))
  local GlassMask = V.require("GlassMask")
  Voxel3D.glassMask = outdoor and GlassMask.texture(host.tileset) or nil
  Voxel3D.glassNight = outdoor and DayNight.windowLight() or 0
  -- no glint in the arena: the drift is the shot breathing, not the player
  -- moving, and a shimmer on background windows would fight the mons
  Voxel3D.glassGlint = 0
  -- The FOREST FX atmosphere is gone (see the removals ADR): the staged
  -- shot draws under the same clear air as every other map now, so there
  -- is no fog to hand the shader.
  Voxel3D.fog = nil

  -- A B RUNG stands the fight on two carried discs against the sky, with no
  -- map in the shot at all (see StadiumStage). Everything below still runs --
  -- the letterbox, the camera solve, the sun, the pins, the tint, the depth
  -- of field -- because none of it is about the terrain; what changes is
  -- which geometry the two passes draw.
  local discs = arena.discs and true or false

  -- shares the free-roam mode's request/evict bookkeeping, so a battle warms
  -- exactly the meshes walking around would have and nothing extra
  local terrain, nbMesh, water, nbWater, ring, ringWater
  if discs then
    -- and nothing is meshed for a disc fight, which is the other half of why
    -- the rung works everywhere: there is no waiting for a chunk to build, so
    -- the first frame of the first battle on a cold map is the finished shot
    nbMesh, water, nbWater, ring, ringWater = {}, nil, {}, nil, nil
  else
    terrain, nbMesh, water, nbWater, ring, ringWater =
      prefetchArena(state, host)
    if not terrain then return nil end
  end

  local lx, ly, s, pw, ph = metrics.viewportX, metrics.viewportY,
                             metrics.scale, metrics.pw, metrics.ph
  if not (pw > 0 and ph > 0 and s > 0) then return nil end

  local palette = paletteFor(state, host)
  local function atlasFor(map)
    return TerrainAtlas.forMap(map, VoxelScene._modeColors(palette, map))
  end
  local function voxTextureFor(map)
    return VoxAssets.texture(VoxelScene._modeColors(palette, map))
  end

  local groundY = BattleScene.groundY(host, arena)
  local cam, pitch = BattleCam.rig(arena, groundY)
  cam.fov = BattleScene.letterboxFov(cam.fov, ph, s, metrics.surfaceH)

  local cx, cy = arena.mid[1], arena.mid[2]
  -- the world extents the sun frustum is fitted to; the camera itself is
  -- framed by cam.fov, so these only have to describe the ground in shot
  -- the player's zoom is part of this: the sun's box is fitted to what the
  -- frame holds, so a shot pulled wide has to light the ground it just
  -- brought into view rather than the ground the rig alone would have
  local vh = BattleCam.frameH(arena) * ph / (metrics.surfaceH * s)
  local vw = vh * pw / ph
  cam = shiftedCamera(cam, metrics, vw, vh)

  -- the cards need the camera's eye to face it, so the rig has to be live
  -- before they are built; Voxel3D.eye is set by viewProjection, which
  -- beginScene calls -- so a provisional one is taken here for the sun pass
  -- and the real one is rebuilt inside the scene below.
  Voxel3D.camera = cam
  Voxel3D.viewProjection(cx, cy, vw, vh)
  local cards = monCards(arena, groundY, textures)
  Voxel3D.camera = nil
  local actorShadows = BrickProfile.battleActorShadowMap(VoxelState.level)
  ShadowMap.setSpriteLayerActive(actorShadows)
  -- The SHADOWS row is the last word over the arena too: OFF skips the sun
  -- pass and the contact blobs alike (ShadowMap.off() drops both layers, so
  -- the main pass sends sunDark=0 and the mons stand flat-lit).
  local battleShadows = ShadowSettings.enabled()
  if battleShadows then
    castShadows(state, arena, terrain, ring, nbMesh, cx, cy, vw, vh,
                atlasFor, voxTextureFor, cards, token, host, neighbors,
                water, ringWater, nbWater, groundY, actorShadows)
  else
    ShadowMap.off()
  end

  -- An opaque void either way. Outdoors the camera is low enough that the
  -- horizon is genuinely in frame, so it is sky; indoors it is the dark end
  -- of the same ramp, which is a room's "past the wall". Transparent -- the
  -- free-roam default -- would let the letterbox clear through wherever the
  -- geometry stops.
  local sky = VoxelScene.skyColor(host, 1)
             or VoxelScene.skyShade(INDOOR_SHADE, 1)
  -- On a disc rung the void is not a backdrop behind the scenery -- it IS the
  -- scenery, because the map is not drawn. So outdoors it gets the full
  -- treatment the free-roam camera gets: the banded gradient and the hour's
  -- own sun or moon hanging in it (Voxel3D.beginScene paints those when the
  -- sky it is handed carries bands). Indoors there is nothing to dress: a
  -- room's void is one flat shade, which is what a room looks like past the
  -- wall, and the disc fight in a cave is lit and coloured as that cave.
  if discs and VoxelScene.skyColor(host, 1) then
    local Sky = V.require("Sky")
    local okDress, dressed = pcall(Sky.dress, sky)
    if okDress and dressed then sky = dressed end
  end

  Voxel3D.camera = cam
  -- the sun is turned up for the arena and put back afterwards, so the
  -- free-roam world it shares this module with keeps its own weight -- and
  -- the hour still has the last word: a sunset fades the arena's shadows
  -- out and the moon presses more softly, exactly as it does outside
  local sunWas = Voxel3D.SHADOW_ALPHA
  Voxel3D.SHADOW_ALPHA = BattleScene.SHADOW_ALPHA
                         * DayNight.shadowScale(outdoor)
  -- The wireframe follows the V-GRID row in a battle too: the arena is the
  -- same voxel geometry the free-roam pass draws, so the player's own
  -- setting decides whether it wears the seams (beginScene picks the
  -- wireframe variant from VoxelGrid.enabled, the row and nothing else).
  local out = nil
  local ok, err = pcall(function()
    -- its own canvas slot: this renders at the window's pixel size and the
    -- free-roam pass does too, but the two are alive at different moments
    -- and a shared slot would reallocate on every battle entry and exit
    --
    -- AA, if the row asks for it, renders it larger still and folds it back
    -- to pw x ph below (see AntiAlias). The framing is untouched by that:
    -- the lens was widened by the window's RATIO to the letterbox and the
    -- rig solved in the GB's own frame, so a bigger canvas is more samples
    -- of the identical shot -- which is why the pins below still measure in
    -- pw and ph, and why the HUDs and the depth of field, drawn onto the
    -- folded canvas afterwards, stay the chunky GB art they are.
    local renderScale = BattleScene.renderScale(VoxelState.level)
    local sceneW = math.max(1, math.floor(pw * renderScale + 0.5))
    local sceneH = math.max(1, math.floor(ph * renderScale + 0.5))
    local rw, rh = AntiAlias.expand(sceneW, sceneH)
    local stereo = Stereoscopic3D.anaglyphEnabled()
    local chromadepth = Stereoscopic3D.chromadepthEnabled()
    local eyeRecords = stereo
      and Stereoscopic3D.buildEyes(cam, rw, rh, "battle")
      or { { camera = cam, w = rw, h = rh, slot = "battle" } }
    if not eyeRecords then return end
    local eyeCanvases = {}
    local canvas
    for eyeIndex, eye in ipairs(eyeRecords) do
      Voxel3D.camera = eye.camera
      if not Voxel3D.beginScene(rw, rh, cx, cy, vw, vh, sky,
                                eye.slot) then
        return
      end
    if discs then
      -- discs: the two platforms, and nothing else. No terrain, no
      -- neighbouring maps, no water, no grass and no flowers -- see the
      -- matching skips further down. What is behind them is the sky the
      -- clear painted.
      V.require("DiscArena").draw(arena, groundY)
    else
    Voxel3D.draw(terrain, atlasFor(host), nil)
    Voxel3D.draw(ring, atlasFor(host), nil)
    for i, nb in ipairs(neighbors) do
      Voxel3D.draw(nbMesh[i], atlasFor(nb.map),
                   Mat4.translate(nb.ox, 0, nb.oy))
    end
    -- and the water over it -- PLAIN, always: the flat animated tiles, never
    -- the reflective pass, whatever the WATER row says. The reflection is
    -- tuned for the overworld's ladder of cameras; this shot's is PLACED --
    -- low, tilted and framed like a picture -- and under it the pass reads
    -- wrong: Fresnel opens all the way up, the leaned sky lands on bands the
    -- framing never shows, and a lake-sized arena comes out as murk wearing
    -- the tile art. The battle is a stage set, and stage water is painted.
    -- (No mirror also means the mons need no second draw into one -- they
    -- just composite over the water below, like everything else on the set.)
    if water then Voxel3D.draw(water, atlasFor(host)) end
    if ringWater then Voxel3D.draw(ringWater, atlasFor(host)) end
    for i, nb in ipairs(neighbors) do
      if nbWater and nbWater[i] then
        Voxel3D.draw(nbWater[i], atlasFor(nb.map),
                     Mat4.translate(nb.ox, 0, nb.oy))
      end
    end
    end
    if battleShadows and not discs and not actorShadows then
      drawContactShadows(arena, groundY)
    end
    -- The mons, standing on their tiles. Depth-tested like everything else,
    -- so a ledge or a tree between the camera and a Pokemon really is in
    -- front of it, and the alpha discard cuts the sprite's own outline out of
    -- the card. A small camera-ward pull keeps a card rooted to the ground
    -- plane from z-fighting the tile it is standing on.
    -- The engine's hit flash is a full-screen white rectangle, which on a
    -- white battle field is a flash and over a world is a whiteout of the
    -- map, the HUD and the text box alike. It is dropped on the way past
    -- (see OverworldBattle) and put back HERE, on the two things it was ever
    -- about: the mons themselves go solid white for those frames.
    local flashing = textures and textures.flash
    if flashing then
      Voxel3D.flatten(BattleScene.FLASH_COLOR, BattleScene.FLASH_STRENGTH)
    end
    -- and no voxel wireframe on the pair. Everything else in this frame is
    -- built a unit per voxel and wears the seams that fall out of that; a
    -- mon's card is one quad wearing the battle screen (see
    -- BattleBillboard), so it is off the grid and has no seams to draw.
    Voxel3D.seams(false)
    -- and no glass either: the cards wear the battle screen, not the
    -- tileset atlas, so the mask's coordinates mean nothing on them
    Voxel3D.glass(false)
    for _, card in ipairs(monCards(arena, groundY, textures)) do
      -- the sun stored this card snugged (castShadows), so its own shadow
      -- lookup must read the same snugged transform -- see ShadowMap.snug
      Voxel3D.draw(BattleBillboard.mesh(), card.tex, card.model,
                   BattleBillboard.PULL, ShadowMap.snug(card.model), false)
    end
    Voxel3D.glass(true)
    Voxel3D.seams(true)
    if flashing then Voxel3D.flatten(nil) end
    -- grass and flowers ride the same camera-ward pull the free-roam pass
    -- gives them, measured against THIS camera's pitch rather than the
    -- orbit's -- there is no character here for them to overdraw, but the
    -- pull is also what keeps a tuft from z-fighting the floor it stands on
    local pull = VoxelScene.pull(math.max(pitch, 0.05))
    if not discs then
      Voxel3D.draw(ChunkMesher.grass(host), atlasFor(host), nil, pull)
      for _, nb in ipairs(neighbors) do
        Voxel3D.draw(ChunkMesher.grass(nb.map), atlasFor(nb.map),
                     Mat4.translate(nb.ox, 0, nb.oy), pull)
      end
      local fpull = math.max(0, pull - 8 * math.sin(math.max(pitch, 0.05)))
      Voxel3D.draw(ChunkMesher.flowers(host), atlasFor(host), nil, fpull,
                   ShadowMap.snug(nil))
      for _, nb in ipairs(neighbors) do
        Voxel3D.draw(ChunkMesher.flowers(nb.map), atlasFor(nb.map),
                     Mat4.translate(nb.ox, 0, nb.oy), fpull,
                     ShadowMap.snug(Mat4.translate(nb.ox, 0, nb.oy)))
      end
    end
      local sceneCanvas = Voxel3D.endScene()
      if chromadepth then
        local near, far, focus = Voxel3D.depthRange()
        sceneCanvas = Stereoscopic3D.chromadepth(
          sceneCanvas, Voxel3D.depthTexture(), rw, rh, near, far, focus)
          or sceneCanvas
      end
      local eyeCanvas = AntiAlias.resolve(
        sceneCanvas, sceneW, sceneH,
        stereo and ("stereo-battle-" .. eyeIndex) or "battle")
      if renderScale < 1 then
        eyeCanvas = Upscale.apply(
          eyeCanvas, pw, ph,
          stereo and ("stereo-battle-" .. eyeIndex) or "battle")
      end
      if not eyeCanvas then return end
      eyeCanvases[eyeIndex] = eyeCanvas
    end
    if stereo and eyeCanvases[1] and eyeCanvases[2] then
      canvas = Stereoscopic3D.composite(eyeCanvases[1], eyeCanvases[2],
                                        pw, ph) or eyeCanvases[1]
    else
      canvas = eyeCanvases[1]
    end
    if not canvas then return end

    Voxel3D.camera = cam
    Voxel3D.viewProjection(cx, cy, vw, vh)

    local vp = Voxel3D.vp
    local pmx, pmy = BattleScene.toGB(vp, arena.player[1], groundY,
                                      arena.player[2], metrics)
    local emx, emy = BattleScene.toGB(vp, arena.enemy[1], groundY,
                                      arena.enemy[2], metrics)
    if not (pmx and emx) then return end
    -- How wide one overworld square is on screen where each mon stands, in
    -- GB pixels. This is what the pics are scaled to: a mon covers its own
    -- square and no more, at whatever the drift has done to the distance.
    local half = BattleScene.CELL / 2
    local pl = BattleScene.toGB(vp, arena.player[1] - half, groundY,
                                arena.player[2], metrics)
    local pr = BattleScene.toGB(vp, arena.player[1] + half, groundY,
                                arena.player[2], metrics)
    local el = BattleScene.toGB(vp, arena.enemy[1] - half, groundY,
                                arena.enemy[2], metrics)
    local er = BattleScene.toGB(vp, arena.enemy[1] + half, groundY,
                                arena.enemy[2], metrics)
    if not (pl and pr and el and er) then return end
    out = {
      canvas = canvas,
      player = { pmx, pmy },
      enemy = { emx, emy },
      playerSpan = math.abs(pr - pl),
      enemySpan = math.abs(er - el),
      -- the letterbox, so the depth-of-field pass can put its sharp band on
      -- the two marks rather than on a fraction of the window
      lx = lx, ly = ly, scale = s, pw = pw, ph = ph,
      viewportX = metrics.viewportX, viewportY = metrics.viewportY,
      surfaceW = metrics.surfaceW, surfaceH = metrics.surfaceH,
      offsetX = metrics.offsetX, offsetY = metrics.offsetY,
      dpiX = metrics.dpiX, dpiY = metrics.dpiY,
      anchors = metrics.anchors, anchorSpan = metrics.anchorSpan,
      layout = metrics,
      -- and the hour's light, for anything drawn over this shot that is NOT
      -- geometry and so never went past the shader that applied it -- the back
      -- pic pinned to the menu (see OverworldBattle.backPinned). Neutral
      -- indoors, which is what DayNight.tint answers for a room.
      tint = Voxel3D.tint,
    }
  end)
  -- the placed camera is ours for exactly this pass; anything else that
  -- renders (the free-roam pipeline, next frame) must find the orbit back
  Voxel3D.camera = nil
  Voxel3D.SHADOW_ALPHA = sunWas
  if not ok then
    -- endScene never ran, so the canvas is still bound and the shader still
    -- set; put the frame back the way it was found before rethrowing
    pcall(love.graphics.setShader)
    pcall(love.graphics.setDepthMode)
    pcall(love.graphics.setCanvas)
    error(err, 0)
  end
  return out
end

return BattleScene
