-- Staged-battle integration owned by one feature boundary.
--
-- Core battle staging, battle sprite/event hooks, and the exit transition
-- are installed at separate call sites by main.lua so their original hook
-- order remains visible. Their implementation and dependencies live here,
-- away from settings, input, cache, and world rendering composition.
local V = ...

local BattleFeature = {}

function BattleFeature.new(ctx)
  local mod = ctx.mod
  local OverworldBattle = ctx.OverworldBattle
  local BattleExit = ctx.BattleExit
  local DebugOverlay = ctx.DebugOverlay

  local feature = {}

  function feature.installCore()
    OverworldBattle.install()
  end

  function feature.installEvents()
    mod.events:on("battle.started", function(payload)
      DebugOverlay.trace("event battle.started")
      OverworldBattle.ensure(payload and payload.battle)
    end)

    mod.hooks:wrap("pokemon.sprite", function(next, path, spriteCtx)
      if not (spriteCtx and spriteCtx.kind == "battle"
              and spriteCtx.side == "back") then
        return next(path, spriteCtx)
      end
      -- `battles` is a ladder value, not a boolean. Only staged-map battles
      -- need front art; normal battles keep the engine's canonical back pic.
      if not OverworldBattle.wantsFront() then
        return next(path, spriteCtx)
      end
      local def = spriteCtx.data and spriteCtx.data.pokemon
                and spriteCtx.data.pokemon[spriteCtx.species]
      local front = {}
      for key, value in pairs(spriteCtx) do front[key] = value end
      front.side = "front"
      local out = next((def and def.spriteFront) or path, front)
      spriteCtx.trueColor = front.trueColor
      return out
    end, 1000)

    mod.events:on("battle.ended", function()
      DebugOverlay.trace("event battle.ended")
      OverworldBattle.finish()
    end)
  end

  function feature.installExit()
    mod.content.transitions:register(BattleExit.ID, {
      frames = BattleExit.FRAMES,
    })
    BattleExit.install()
  end

  return feature
end

return BattleFeature
