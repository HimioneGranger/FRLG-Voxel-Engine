-- VRITK boundary for the unmodified gen3-hd-sprites 0.4.2 source.
-- Loaded by the host before this mod's entry chunk. No species-size multiplier
-- is added here: WildsSnapshotCompat owns the single voxel sizing operation.
local M = {}
local unpack = unpack or table.unpack
local function pack(...) return { n = select('#', ...), ... } end

function M.install(api, env, ctx)
  if type(api) ~= 'table' or type(env) ~= 'table' or type(api.read) ~= 'function'
      or type(ctx) ~= 'table' or type(ctx.voxelActive) ~= 'function' then
    return nil, 'HD compat requires read, sandbox and voxelActive'
  end
  local read, factory = api.read, env.VRITK_HD_FACTORY
  local state = { hd = nil, engine = nil, graphics = {}, engineHooks = {}, active = true }
  local function voxel()
    local ok, active = pcall(ctx.voxelActive)
    -- A broken ownership query must not capture a stereo render target.
    return not state.active or not ok or active == true
  end
  local function flush(hd)
    -- Run only on a mode transition, never once per graphic primitive.
    local canvas = hd.real.getCanvas and hd.real.getCanvas()
    if hd.cur then hd.flatten(hd.cur) end
    for _, pass in pairs(hd.done or {}) do hd.flatten(pass) end
    hd.done = {}
    if hd.real.setCanvas then hd.real.setCanvas(canvas) end
  end
  local previous
  local function sync(hd)
    local active = voxel()
    if active and previous ~= true then flush(hd) end
    previous = active
    return active
  end
  local function decorateHD(HD)
    local new = HD.new
    HD.new = function(G, opts)
      local hd = new(G, opts)
      state.hd = hd
      local install, begin = hd.install, hd.beginPass
      hd.install = function(...)
        local result = pack(install(...))
        if result[1] then
          for name, raw in pairs(hd.real) do
            local hooked = G[name]
            if type(raw) == 'function' and type(hooked) == 'function' and hooked ~= raw
                and not state.graphics[name] then
              local gate = function(...)
                if sync(hd) then return raw(...) end
                return hooked(...)
              end
              state.graphics[name] = { raw = raw, hooked = hooked, gate = gate }
              G[name] = gate
            end
          end
        end
        return unpack(result, 1, result.n)
      end
      hd.uninstall = function(...)
        local ok, err = pcall(flush, hd)
        -- HD.uninstall writes all its captured originals, which could remove
        -- a later renderer wrapper. Retire only functions we still own.
        for name, rec in pairs(state.graphics) do
          if G[name] == rec.gate then G[name] = rec.raw end
        end
        state.graphics = {}
        hd.installed = false
        return ok, err
      end
      hd.beginPass = function(...)
        if sync(hd) then return false end
        return begin(...)
      end
      return hd
    end
    return HD
  end
  local function decorateEngine(Engine)
    state.engine = Engine
    local seams = {
      { 'src.render.Renderer', 'blitCanvas', 'endFrame', 'beginWorldPass', 'endWorldPass', 'exchangeWorldCanvas' },
      { 'src.core.game3.battle', 'draw' },
      { 'src.ui.game3.battle_chrome', 'drawTerrain', 'drawEntry' },
      { 'src.core.game3.battle.ball_open', 'draw' },
      { 'src.core.game3.battle.anim', 'drawParticles' },
      { 'src.core.game3.battle.pokedude', 'sendOutOrigin' },
      { 'src.core.game3.trainer_pic', 'front', 'back' },
      { 'src.ui.game3.rse.pokedex', 'draw' }, { 'src.ui.game3.pokedex', 'draw' },
    }
    local function snapshot(first, last)
      local out = {}
      for index = first or 1, last or #seams do
        local row = seams[index]
        local ok, target = pcall(env.require, row[1])
        if ok and type(target) == 'table' then
          for i = 2, #row do
            local key = row[i]
            out[#out + 1] = { target = target, key = key, old = target[key] }
            if key == 'draw' and type(target.Host) == 'table' then
              out[#out + 1] = { target = target.Host, key = key, old = target.Host[key] }
            end
          end
        end
      end
      return out
    end
    local function remember(before)
      for _, rec in ipairs(before) do
        if rec.target[rec.key] ~= rec.old then
          rec.ours = rec.target[rec.key]
          state.engineHooks[#state.engineHooks + 1] = rec
        end
      end
    end
    local wrapDex = Engine.wrapDex
    Engine.wrapDex = function(...)
      if state.hd and voxel() then return end
      local before = snapshot(#seams - 1, #seams)
      local result = pack(wrapDex(...))
      remember(before)
      return unpack(result, 1, result.n)
    end
    local install = Engine.install
    Engine.install = function(hd, ...)
      local before = snapshot()
      local attempted = pack(pcall(install, hd, ...))
      remember(before)
      if not attempted[1] then
        state.uninstall()
        error(attempted[2], 0)
      end
      local result = { n = attempted.n - 1 }
      for i = 2, attempted.n do result[i - 1] = attempted[i] end
      if not result[1] then
        state.uninstall()
        return unpack(result, 1, result.n)
      end
      if result[1] and type(Engine.shiftCoords) == 'function' then
        local shift = Engine.shiftCoords
        Engine.shiftCoords = function(...)
          if not sync(hd) then return shift(...) end
          -- Shift runs BEFORE beginPass. Reset native animation coordinates
          -- using upstream's own disabled-fit branch, then restore the option.
          local enabled = hd.fit.enabled
          hd.fit.enabled = false
          local values = pack(pcall(shift, ...))
          hd.fit.enabled = enabled
          if not values[1] then error(values[2], 0) end
          return unpack(values, 2, values.n)
        end
      end
      return unpack(result, 1, result.n)
    end
    return Engine
  end
  local function decorateApi(Api)
    return function(mod, hd, active)
      Api(mod, hd, active)
      local ex = mod.exports
      for _, key in ipairs({ 'enabled', 'fitEnabled', 'fillEnabled' }) do
        local fn = ex[key]
        if type(fn) == 'function' then
          ex[key] = function(...)
            if voxel() then return false end
            return fn(...)
          end
        end
      end
      local zoom = ex.sceneZoom
      ex.sceneZoom = function(...) if voxel() then return 1 end return zoom(...) end
      -- Keep tag/isActive available: VR source images and species metadata stay
      -- intact even though the flat compositor is dormant in voxel mode.
    end
  end
  env.VRITK_HD_FACTORY = function(path, value)
    if path == 'src/hd.lua' then return decorateHD(value) end
    if path == 'src/engine.lua' then return decorateEngine(value) end
    if path == 'src/api.lua' then return decorateApi(value) end
    return value
  end
  local guardedRead
  guardedRead = function(self, path, ...)
    local source, err = read(self, path, ...)
    if type(source) == 'string' and (path == 'src/hd.lua' or path == 'src/engine.lua'
        or path == 'src/api.lua') then
      return 'return VRITK_HD_FACTORY(' .. string.format('%q', path)
          .. ', (function()\n' .. source .. '\nend)())', err
    end
    return source, err
  end
  api.read = guardedRead
  function state.status()
    return { installed = state.active, voxel = voxel(), hd = state.hd ~= nil }
  end
  function state.uninstall()
    if state.retired then return end
    state.retired = true
    -- Retire our engine and sandbox wrappers even if HD flush/uninstall fails.
    if state.hd then pcall(state.hd.uninstall) end
    for i = #state.engineHooks, 1, -1 do
      local rec = state.engineHooks[i]
      if rec.target[rec.key] == rec.ours then rec.target[rec.key] = rec.old end
    end
    state.engineHooks = {}
    if api.read == guardedRead then api.read = read end
    if env.VRITK_HD_FACTORY ~= factory then env.VRITK_HD_FACTORY = factory end
    state.active = false
  end
  return state
end
return M
