-- Capability and environment collection for DebugOverlay.
--
-- This module is data-only: it reads engine capability APIs and returns plain
-- tables. Logging, persistence, transport, and HUD rendering stay outside so
-- platform probes cannot accidentally depend on presentation state.
local V = ...

local DiagnosticsEnvironment = {}

function DiagnosticsEnvironment.new(ctx)
  local health = ctx.health
  local copy = ctx.dataCopy
  local environment = {}

  local function platformName()
    local ok, Platform = pcall(require, "src.core.Platform")
    if not ok or type(Platform) ~= "table" then return "?" end
    local okP, info = pcall(Platform.detect)
    if not okP or type(info) ~= "table" then return "?" end
    local osName = tostring(info.os or "?")
    if osName == "?" or osName == "" then return "?" end
    local kind = info.console and "console" or info.mobile and "mobile" or nil
    return kind and (osName .. " (" .. kind .. ")") or osName
  end

  local function tegraRenderer()
    local ri = health.renderer and health.renderer.renderer
    if not ri then return false end
    local text = ("%s %s %s %s"):format(tostring(ri.name or ""),
      tostring(ri.vendor or ""), tostring(ri.device or ""),
      tostring(ri.version or "")):lower()
    return text:find("tegra", 1, true) ~= nil
        or text:find("nv13", 1, true) ~= nil
        or text:find("gm20", 1, true) ~= nil
  end

  function environment.platformName()
    return platformName()
  end

  function environment.platformSlug()
    local p = tostring(health.platform or platformName()):lower()
    if p:find("switch") or p:find("nx") then return "switch" end
    if p:find("ios") or p:find("iphone") or p:find("ipad") then return "ios" end
    if p:find("android") then return "android" end
    if p:find("linux") then
      return tegraRenderer() and "switch" or "linux"
    end
    if p:find("windows") or p:find("win") then return "windows" end
    if p:find("mac") or p:find("os x") or p:find("osx")
       or p:find("darwin") then return "macos" end
    if p:find("web") or p:find("browser") then return "web" end
    return "unknown"
  end

  function environment.identityFields()
    local mod = V.mod
    local manifest = mod and mod.manifest
    local storageContext = health.storage.context or {}
    local loveVersion = health.renderer and health.renderer.love
    local loveText = loveVersion
      and (tostring(loveVersion.codename) .. " "
           .. tostring(loveVersion.major) .. "."
           .. tostring(loveVersion.minor)) or "?"
    local renderer = health.renderer and health.renderer.renderer
    local gpu = renderer
      and ((tostring(renderer.name or "") .. " "
            .. tostring(renderer.device or "")):gsub("%s+$", "")) or "?"
    return {
      platform = environment.platformSlug(),
      engine = tostring(storageContext.engineVersion or "?"),
      mod = tostring(manifest and manifest.version or "?"),
      love = loveText,
      gpu = gpu,
    }
  end

  function environment.capture()
    local g = love and love.graphics
    local out = {}
    health.platform = platformName()
    if love and love.getVersion then
      local ok, major, minor, revision, codename = pcall(love.getVersion)
      if ok then
        out.love = { major = major, minor = minor, revision = revision,
                     codename = codename }
      end
    end
    if g then
      if g.getRendererInfo then
        local ok, a, b, c, d = pcall(g.getRendererInfo)
        if ok and type(a) == "table" then
          out.renderer = copy(a)
        elseif ok and a then
          out.renderer = { name = tostring(a), version = tostring(b or ""),
                           vendor = tostring(c or ""), device = tostring(d or "") }
        end
      end
      if g.getDimensions then
        local ok, w, h = pcall(g.getDimensions)
        if ok then out.dimensions = { w = w, h = h } end
      end
      if g.getPixelDimensions then
        local ok, w, h = pcall(g.getPixelDimensions)
        if ok then out.pixelDimensions = { w = w, h = h } end
      end
      if g.getSupported then
        local ok, caps = pcall(g.getSupported)
        if ok then out.supported = copy(caps) end
      end
      if g.getSystemLimits then
        local ok, limits = pcall(g.getSystemLimits)
        if ok then out.systemLimits = copy(limits) end
      end
    end
    health.renderer = out
    return copy(out)
  end

  return environment
end

return DiagnosticsEnvironment
