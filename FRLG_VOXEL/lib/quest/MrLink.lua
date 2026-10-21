-- FRLG_VOXEL: the link to PORTAL_MR, the optional mixed-reality portal mod
-- (P1: a window onto the field over Quest passthrough, the floor pulled out
-- into the room, the terrain between the viewer and the window clipped).
--
-- PORTAL_MR is a separate mod. It is found lazily with mod.find (only an
-- active, loaded mod answers) and used through its exports; this mod never
-- depends on it. Absent, disabled, failed, or speaking another API, Mr.s
-- stays nil and every seam -- main.lua (questFrame), quest/XRSession.lua
-- (frame), render/View.lua (renderBody), render/Camera.lua (rig) -- skips:
-- the game runs exactly as without it. PORTAL_MR never owns XR, input or the
-- frame: this file hands it the renderer's closures (mrHost, exported as
-- mod.exports.mrHost) and keeps the session it builds from them.
local V = ...
local _ = V

local Mr = { s = nil, ID = "PORTAL_MR", API = 1, ADAPTER = "gen3" }
-- While PORTAL_MR is not there, look again every RETRY questFrames (mod.find
-- is a table lookup; the mod set does not change inside a session).
Mr.RETRY = 120
local nextTry, failed = 0, nil

-- The closures PORTAL_MR's gen3 adapter reads (adapters/gen3.lua there).
-- o = { R = function() -> the renderer objects or nil, FreeMove, opt, PerfEm,
--       Mods = { Camera, Mat4, Shaders, XRSession } }
function Mr.host(o)
  local Camera, Mat4, Shaders = o.Mods.Camera, o.Mods.Mat4, o.Mods.Shaders
  local XRSession = o.Mods.XRSession
  local function R() return o.R() end
  return {
    api = 1,
    Camera = Camera, Shaders = Shaders,
    quad = { w = XRSession and XRSession.QUAD_W or 960, h = XRSession and XRSession.QUAD_H or 640 },
    log = function(message) print(tostring(message)) end,
    xr = function()
      local r = R()
      local h = r and r.xr and r.xr:handle()
      return h and h.XR or nil
    end,
    camera = function() local r = R(); return r and r.camera or nil end,
    rig = function()
      local r = R()
      if not (r and r.camera) then return nil end
      local ax, ay, az, px, py, pz, m = r.camera:rig()
      return ax, ay, az, px, py, pz, m, r.camera.yaw
    end,
    -- Camera:rig() adds this to the first-person pivot's LOCAL height.
    setLift = function(y) local r = R(); if r and r.camera then r.camera.mrLift = y end end,
    -- The exact projection View.lua's renderBody draws an eye with.
    projection = function(eye)
      local f = eye.fov
      return Mat4.flipY(Mat4.fovProjection(f.angleLeft, f.angleRight, f.angleUp, f.angleDown,
        Camera.NEAR, Camera.FAR))
    end,
    -- FREE walking (and with it room-scale walking) off while a portal is
    -- enabled; back to the VOXEL MOVEMENT option afterwards.
    -- While frozen the world must not turn to the trainer's facing either:
    -- main.lua's applyTurning (start of every questFrame) turns FOLLOW FACING
    -- on once FREE walking is off, so it is put back off here (this runs later
    -- in the same frame, before the camera updates). Exit hands it back.
    freeze = function(on)
      local FM = o.FreeMove
      if FM then FM.setEnabled(not on and o.opt("movement") ~= "grid") end
      local r = R()
      if on and r and r.camera then r.camera.follow = false end
    end,
    -- FOLLOW FACING as the player's options make it, whatever the portal did
    -- to FREE walking (applyTurning: android, "follow", and grid movement).
    followOption = function()
      return o.opt("turning") == "follow" and o.opt("movement") == "grid"
    end,
    -- Emerald's PREPARING 3D WORLD screen (lib/perf/PrebakeScreen.lua) is up.
    prebake = function()
      local gate = o.PerfEm and o.PerfEm._gate
      if not gate then return false end
      local ok, visible = pcall(gate.visible, gate)
      return ok and visible == true
    end,
  }
end

-- Once per questFrame. true when the session exists (Mr.s).
function Mr.find(mod, frame)
  if Mr.s then return true end
  if failed or (tonumber(frame) or 0) < nextTry then return false end
  nextTry = (tonumber(frame) or 0) + Mr.RETRY
  if type(mod) ~= "table" or type(mod.find) ~= "function" then return false end
  local ok, found = pcall(mod.find, Mr.ID)
  local ex = ok and type(found) == "table" and found.exports or nil
  if not (type(ex) == "table" and ex.api == Mr.API and type(ex.session) == "function") then return false end
  local okS, s = pcall(ex.session, Mr.ADAPTER, mod.exports and mod.exports.mrHost)
  if okS and type(s) == "table" then
    Mr.s = s
    print("[FRLG_VOXEL] PORTAL_MR " .. tostring(found.version) .. " found: portal available (LEFT thumbrest + A)")
    return true
  end
  failed = tostring(s)
  print("[FRLG_VOXEL] PORTAL_MR is active but its gen3 session failed, portal off: " .. failed:sub(1, 240))
  return false
end

return Mr
