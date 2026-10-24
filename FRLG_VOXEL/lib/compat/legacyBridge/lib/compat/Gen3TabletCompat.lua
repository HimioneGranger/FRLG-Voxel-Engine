-- Gen3-only tablet ownership. The official Gear Canvas/touch dispatcher stays
-- authoritative; this adapter prevents its pointer from also driving game keys.
local V = ...
local function bridgeAvailable(bridge)
  if type(bridge.isAvailable) == 'function' then return bridge:isAvailable() end
  return bridge:status().available
end

local NativeDialogue=V.require('compat/NativeDialogue')
local M = {}
local state = { active=false, presented=false, sticky={} }
-- battle-ui (2026-10-01): the Gear surface bridge the component was installed with, for available()
local bound = { bridge=nil }
-- Gen3 dex scanner (2026-10-02): other Gen3 modules that also need the Gear
-- surface bridge this component adopts (Gen3DexScannerCompat.installBridge).
M.extensions = {}
function M.extend(fn)
  M.extensions[#M.extensions+1]=fn
  if bound.bridge then pcall(fn,nil,nil,bound.bridge) end
end
local function clear() state.active=false;state.presented=false;state.candidate=false;state.renderFailed=false end
local function hasFrame(scene)
  local surface=scene and scene.surface
  if not(surface and type(surface.frame)=='function')then return false end
  local ok,frame=pcall(surface.frame)
  return ok and frame~=nil
end
function M.active() return state.active end
function M.presented() return state.active and state.presented end
-- battle-ui (2026-10-01): true while the Kanto Gear tablet can show the game (its surface bridge is adopted),
-- held or not. FRLG_VOXEL's 3D battle presenter then leaves the battle UI to the tablet (no floating command
-- card): the tablet's battle page shows the engine's messages and menus. Plain read; never raises.
function M.available()
  local b=bound.bridge
  if not(b and type(b.status)=='function')then return false end
  local ok,st=pcall(b.status,b)
  return ok and type(st)=='table' and st.available==true
end
-- battle-ui item 6 (2026-10-01, outside tester: "The PokeTablet does not register touches. I keep poking it with my
-- finger, but nothing happens."). Cause: near the tablet the free left hand is DRAWN pointing (TabletAutoPoint:
-- pointing, grip .65, trigger 0, no thumb rest), but the touch test (QuestWearableInteraction.touchPointer ->
-- VRHandAssets.indexTip) measured the fingertip of the hand's RAW controller pose. The two fingertips are
-- centimetres apart while a press must land within 12 mm of the glass, so the finger the player sees touching
-- the screen never counted (only the trigger ray worked). Fix (Gen3 only): interaction:update reads a copy of
-- the left hand model posed exactly as TabletAutoPoint draws it, so the touch fingertip is the drawn one. The
-- raw model is never changed. TOUCH_POSE = "raw" restores the old behaviour.
M.TOUCH_POSE = "drawn"
-- The drawn pose, under TabletAutoPoint's own conditions (a free hand: not holding, no cradle, no prop grip,
-- not combined, not a fist). Returns a posed copy, or the model itself when it keeps its own pose.
function M.touchModel(model)
  if type(model)~='table' or model.holding or model.miniCradle or model.gripStyle or model.combined
      or model.closedFist then return model end
  local posed={};for k,v in pairs(model)do posed[k]=v end
  posed.pointing=true;posed.grip=.65;posed.trigger=0;posed.thumbRest=false
  return posed
end
-- tablet-touch (2026-10-02, Lab 10 headset: "The tablet touchscreen is still broken"). TOUCH_POSE="drawn" above
-- fixed the pose flags but still measured the HOST skeleton's fingertip. The player sees the skinned GLOVE, turned
-- about the grip point by the saved glove fit (default tilt -70): its fingertip is ~129 mm from the host joint,
-- so the finger on the glass was never where the touch test looked. Gen3 only (this adapter is only installed on
-- Gen3): interaction.gen3Touch gives QuestWearableInteraction (a) the drawn glove fingertip, fit included
-- (DrawnFingertip), and (b) a hover/press state machine with hysteresis (TabletTouch). TOUCH_MODE = "legacy"
-- restores the old 12 mm window on the host fingertip. The kit is passed in by KantoGearComponent (it owns V).
M.TOUCH_MODE = "drawn"
-- READABILITY (tablet-touch, separate change; stage-readability): a 3x presentation Canvas with mipmaps and the
-- tablet leaned toward the head. READABILITY=false restores today's look. TILT sign: +X tips the screen normal
-- toward the wrist (the wearer); if the tablet leans away on the headset, negate TABLET_TILT_DEG.
M.READABILITY = true
M.PRESENTATION_SCALE = 3
M.TABLET_TILT_DEG = 15
-- v2: the holding hand turns with the readability tilt (its flat-support grip pitch gets the same degrees), so the fingers
-- under the tablet keep the calibrated relation to it: with only the tablet leaning, the little / ring fingertips came out
-- of the front face at the bottom of the side panel. false = the Lab 58 behaviour (tablet leans, hand does not).
M.HOLDER_FOLLOWS_TILT = true
M.TOUCH_PARAMS = nil   -- optional overrides of TabletTouch.DEFAULTS (metres / frames / seconds)
local touchStats = { hoverFrames = 0, presses = 0, lastU = nil, lastV = nil, rayPresses = 0, rayU = nil, rayV = nil }
function M.touchStats() return touchStats end
-- tablet-input58 (2026-10-10): manual pointing + finger collision (Gen3TabletPointer). POINTER=false restores
-- Lab 56/50 exactly (no pointer object, no renderer hook). POINTER_PARAMS overrides Gen3TabletPointer.DEFAULTS.
M.POINTER = true
M.POINTER_PARAMS = nil
local pointerBound = nil   -- the live pointer instance (nil when none), for status and tests
function M.pointer() return pointerBound end
local function newPointer(kit)
  if M.POINTER ~= true or type(V) ~= "table" or type(V.require) ~= "function" then return nil end
  local okMod, Pointer = pcall(V.require, "compat/Gen3TabletPointer")
  if not (okMod and type(Pointer) == "table" and type(Pointer.new) == "function") then return nil end
  -- the wrist offset of the drawn pointing pose (DrawnFingertip.POINT, repeated here: this host loader cannot
  -- reach VR_INTERACTIONS_BACKPACK_LAB/lib). VRHandAssets is the host's own lib.
  local POINT = { pointing = true, grip = 0.65, trigger = 0, thumbRest = false }
  local function gripToWrist(side)
    local okH, Hands = pcall(V.require, "VRHandAssets")
    if okH and type(Hands) == "table" and type(Hands.gripToWrist) == "function" then
      return Hands.gripToWrist(POINT, side)
    end
  end
  -- hand offset and scale for the collision samples (the style row does not depend on the pose: one answer for both hands)
  local function gripScale(side)
    local okH, Hands = pcall(V.require, "VRHandAssets")
    if okH and type(Hands) == "table" and type(Hands.gripToWrist) == "function" and type(Hands.visualScale) == "function" then
      local g = Hands.gripToWrist(POINT, side)
      if type(g) == "table" then return g[1], g[2], g[3], Hands.visualScale(POINT, side) end
    end
  end
  local ok, ptr = pcall(Pointer.new, { tip = kit.tip, side = "left", gripToWrist = gripToWrist, gripScale = gripScale, params = M.POINTER_PARAMS })
  if not (ok and type(ptr) == "table") then return nil end
  return ptr
end
-- The render-only finger clamp reaches the hand model through QuestHandsRenderer.adjustModel (one-line seam in
-- that host file). A throw in the hook would hide both hands, so it is wrapped and disables itself.
local function hookRenderer(ptr)
  if type(V) ~= "table" or type(V.require) ~= "function" then return nil end
  local okR, Renderer = pcall(V.require, "QuestHandsRenderer")
  if not (okR and type(Renderer) == "table") then return nil end
  local broken = false
  local function hook(model, world, side, semantic)
    if broken then return model end
    local ok, out = pcall(ptr.adjustModel, ptr, model, world, side, semantic)
    if ok then return out end
    broken = true
    return model
  end
  Renderer.adjustModel = hook
  return function() if Renderer.adjustModel == hook then Renderer.adjustModel = nil end end
end
local function installGen3Touch(interaction, kit)
  if M.TOUCH_MODE ~= "drawn" or type(interaction) ~= "table" or type(kit) ~= "table"
      or type(kit.tip) ~= "function" or type(kit.touch) ~= "table" or type(kit.touch.new) ~= "function" then return nil end
  local machine = kit.touch.new(M.TOUCH_PARAMS)
  local ptr = newPointer(kit)
  local unhook = ptr and hookRenderer(ptr) or nil
  pointerBound = ptr
  rawset(interaction, "gen3Touch", { tip = kit.tip, machine = machine, params = machine.p, pointer = ptr })
  return function()
    rawset(interaction, "gen3Touch", nil)
    if unhook then pcall(unhook) end
    if pointerBound == ptr then pointerBound = nil end
  end, ptr
end
local function wrapInteraction(interaction)
  if type(interaction)~='table' or rawget(interaction,'_gen3TouchWrapped') then return nil end
  local original=interaction.update
  local rawOriginal=rawget(interaction,'update')
  if type(original)~='function' then return nil end
  local wrapped=function(self,controls,hands,reservedHands,dt)
    local left=type(hands)=='table' and hands.left or nil
    local model=type(left)=='table' and left.model or nil
    local swapped=false
    if M.TOUCH_POSE=='drawn' and self.mode=='tablet' and type(model)=='table' and not rawget(self,'gen3Touch')
        and (tonumber(type(controls)=='table' and controls.gripL) or 0)<.35 then
      local posed=M.touchModel(model)
      if posed~=model then left.model=posed;swapped=true end
    end
    local ok,a=pcall(original,self,controls,hands,reservedHands,dt)
    if swapped then left.model=model end
    if not ok then error(a,0) end
    return a
  end
  rawset(interaction,'update',wrapped)
  rawset(interaction,'_gen3TouchWrapped',true)
  return function()
    if rawget(interaction,'update')==wrapped then rawset(interaction,'update',rawOriginal) end
    rawset(interaction,'_gen3TouchWrapped',nil)
  end
end
-- A tablet gesture belongs to the hold/phase on which it began. Keep its
-- capture through disappearance so the release never reaches the page below.
function M.newSkipOverlay(belt)
  local self={}
  local key, pressed, pointerDown
  local enabled=true
  local function current()
    if not enabled then return nil end
    local h=type(belt)=='table' and type(belt.active)=='function' and belt.active() or nil
    if not h or h.finished or h.skip or h.fallback then return nil end
    if h.phase=='recall' and not h.recallAt and h.physicalW==nil
        or h.phase=='throw' and not h.throwAt then
      return tostring(h.serial)..':'..h.phase
    end
  end
  local function bounds(w,h) return w*(160/240),h*(120/160),w*(72/240),h*(32/160) end
  local function inside(x,y,w,h)
    local bx,by,bw,bh=bounds(w,h)
    return x>=bx and x<=bx+bw and y>=by and y<=by+bh
  end
  function self:sync()
    local nextKey=current();local changed=nextKey~=key;key=nextKey
    return changed
  end
  function self:setEnabled(value)
    value=value==true
    if enabled~=value then
      enabled=value
      if not enabled and pressed then pressed='cancelled' end
    end
  end
  function self:pointer(action,x,y,w,h)
    self:sync()
    if pressed then
      local same=pressed==key
      if action=='up' then
        pressed=nil;pointerDown=nil
        if same and inside(x,y,w,h) then belt.skip('tablet');self:sync() end
      elseif action=='cancel' then pressed=nil;pointerDown=nil end
      return true
    end
    if action=='down' then
      local fresh=not pointerDown;pointerDown=true
      if fresh and key and inside(x,y,w,h) then pressed=key;return true end
    elseif action=='up' or action=='cancel' then pointerDown=nil
    elseif action=='tap' and key and inside(x,y,w,h) then
      -- The physical routes send down/up. A lone tap has no fresh press.
      return true
    end
    return false
  end
  function self:draw(graphics,w,h)
    self:sync();if not key then return false end
    graphics.push('all')
    local ok,done=pcall(function()
      graphics.scale(w/240,h/160)
      return NativeDialogue.button(graphics,160,120,72,32,'SKIP')
    end)
    graphics.pop()
    return ok and done==true
  end
  function self:reset() key=nil;pressed=nil;pointerDown=nil end
  return self
end
function M.install(component, interaction, bridge, kit)
  clear()
  state.sticky={}
  bound.bridge=bridge
  local skip=type(kit)=='table' and type(kit.beltSwitch)=='table' and M.newSkipOverlay(kit.beltSwitch) or nil
  if skip then bridge:setTabletOverlay(skip) end
  touchStats.hoverFrames, touchStats.presses, touchStats.lastU, touchStats.lastV = 0, 0, nil, nil
  touchStats.rayPresses, touchStats.rayU, touchStats.rayV = 0, nil, nil
  local log=type(kit)=='table' and type(kit.log)=='function' and kit.log or nil
  local unwrapGen3,ptr=installGen3Touch(interaction, kit)
  local restoreTilt
  if M.READABILITY then
    if type(bridge)=='table' then bridge.presentationScale=M.PRESENTATION_SCALE end
    local class=getmetatable(interaction)
    local I=type(class)=='table' and type(class.__index)=='table' and class.__index or nil
    if I and type(rawget(I,'TABLET_ROTATION_X'))=='number' then
      if rawget(I,'_tiltBase')==nil then rawset(I,'_tiltBase',I.TABLET_ROTATION_X) end
      rawset(I,'TABLET_ROTATION_X',I._tiltBase+math.rad(M.TABLET_TILT_DEG))
      restoreTilt=function() rawset(I,'TABLET_ROTATION_X',I._tiltBase) end
    end
    if M.HOLDER_FOLLOWS_TILT and I and type(rawget(I,'TABLET_GRIP_PITCH'))=='number' then
      if rawget(I,'_gripPitchBase')==nil then rawset(I,'_gripPitchBase',I.TABLET_GRIP_PITCH) end
      rawset(I,'TABLET_GRIP_PITCH',I._gripPitchBase+math.rad(M.TABLET_TILT_DEG))
      local restoreTilt0=restoreTilt
      restoreTilt=function() if restoreTilt0 then restoreTilt0() end;rawset(I,'TABLET_GRIP_PITCH',I._gripPitchBase) end
    end
  end
  local unwrapTouch=wrapInteraction(interaction)
  for _,ext in ipairs(M.extensions) do pcall(ext,component,interaction,bridge) end
  local lastTouch=nil
  local lastRayDown=false
  local update,draw,owns,invalidate,dispose=component.update,component.draw,component.ownsHand,component.invalidate,component.dispose
  function component:update(context)
    local result=update(self,context)
    if ptr then ptr:endFrame(context and context.dt) end
    local holder=context and context.hands and context.hands.right
    local scene=result and result.interaction
    state.candidate=scene~=nil and scene.mode=='tablet' and holder~=nil and holder.tracked==true
      and bridgeAvailable(bridge)==true and hasFrame(scene)
    state.active=state.candidate and not state.renderFailed
    if not state.active then state.presented=false end
    -- touch diagnostics: counts, plus one log line on the first hover and on every press (headset evidence)
    local ts=scene and scene.mode=='tablet' and interaction.touchState or nil
    if ts=='hover' or ts=='press' then touchStats.hoverFrames=touchStats.hoverFrames+1 end
    if ts~=lastTouch then
      local p=scene and scene.pointer
      if ts=='press' then
        touchStats.presses=touchStats.presses+1
        if p then touchStats.lastU,touchStats.lastV=p.u,p.v end
        if log then pcall(log,('Tablet touch press #%d at u=%.3f v=%.3f'):format(touchStats.presses,tonumber(p and p.u) or -1,tonumber(p and p.v) or -1)) end
      elseif ts=='hover' and lastTouch==nil and touchStats.hoverFrames<=1 and log then
        pcall(log,'Tablet touch: fingertip hover seen')
      end
      lastTouch=ts
    end
    -- tablet-input58: one log line per trigger/pinch press made with the pointer ray (edge, not per frame)
    if ptr then
      local rayDown=scene~=nil and scene.mode=='tablet' and interaction.pointerDown==true and interaction.pointerInput=='trigger'
        and scene.pointer~=nil and scene.pointer.kind=='ray'
      if rayDown and not lastRayDown then
        touchStats.rayPresses=touchStats.rayPresses+1
        touchStats.rayU,touchStats.rayV=scene.pointer.u,scene.pointer.v
        if log then pcall(log,('Tablet pointer press #%d at u=%.3f v=%.3f via %s'):format(touchStats.rayPresses,tonumber(scene.pointer.u) or -1,tonumber(scene.pointer.v) or -1,tostring(ptr.src))) end
      end
      lastRayDown=rayDown==true
    end
    return result
  end
  function component:draw(scene)
    local ok=draw(self,scene)
    if state.candidate then
      state.renderFailed=ok~=true
      state.active=not state.renderFailed
      state.presented=state.active
    end
    return ok
  end
  function component:ownsHand(side)
    return owns(self,side) or (side=='left' and state.active)
  end
  function component:invalidate(...) clear();if skip then skip:reset() end;if ptr then ptr:reset() end;return invalidate(self,...) end
  function component:dispose(...)
    clear();if bound.bridge==bridge then bound.bridge=nil end
    if skip then skip:reset();bridge:setTabletOverlay(nil);skip=nil end
    if unwrapTouch then pcall(unwrapTouch);unwrapTouch=nil end
    if unwrapGen3 then pcall(unwrapGen3);unwrapGen3=nil end
    if restoreTilt then pcall(restoreTilt);restoreTilt=nil end
    if type(bridge)=='table' then bridge.presentationScale=nil end
    return dispose(self,...)
  end
end
-- This runs after the ordinary menu gate, before wearable update, and only
-- restores the tablet pointer trigger. Pouch grabs/editor controls stay gated.
function M.prepareFrame(frame,raw)
  if not state.active or type(frame.controls)~='table' or type(raw)~='table' then return end
  local controls={};for k,v in pairs(frame.controls)do controls[k]=v end
  controls.triggerL=raw.triggerL
  controls.gripR=raw.gripR
  frame.controls=controls
end
function M.suppress(mask,controls)
  for key,off in pairs({triggerL=.35,gripR=.45})do
    if controls~=nil and (tonumber(controls[key]) or 0)<=off then state.sticky[key]=nil end
    if state.active or state.sticky[key] then
      mask[key]=true
      if controls and (tonumber(controls[key]) or 0)>off then state.sticky[key]=true end
    end
  end
  return mask
end
function M.reset() clear() end
return M
