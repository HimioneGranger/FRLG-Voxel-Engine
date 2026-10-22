-- Gen3 field presentation. The copied card outlives native ENTER_POKEBALL;
-- the actor and encounter mod still own gameplay. No Gen1/2 renderer hooks.
-- fx-sendout-catch (2026-10-01): send-out and recall draw the game's own
-- ball-open presentation (compat/NativeBallFX: ROM particles, the ball's fade
-- colour, the native emerge/shrink timing) instead of the shared VRITK energy
-- plume (catching/release_energy), which Gen1/Gen2 keep using unchanged.
-- User correction (2026-10-01): "use my own send out animations combined with
-- the games effects". Default M.MODE = 'combined': the VRITK energy beam
-- (release_energy pose + capture_plasma volume + capture_material, unchanged
-- look/colours/timing) drawn together with the native presentation
-- (NativeBallFX.newCombined). 'native' = native only, 'energy' = the pre-fix
-- energy effect alone; the energy effect is also the fallback when the native
-- module cannot load.
-- vr-doubles (2026-10-01): a battle-opening belt throw names its battler on the command (c.openingBattler: 0 for
-- a FireRed/Emerald single, set by Gen3ChooseYouCompat.commit; 0 or 2 for an Emerald two-slot double, set by
-- EmeraldChooseYouCompat, which also keeps c.rseBattler) and draws the user's beam to that battler spot
-- (compat/OpeningBeamFX). One beam per battler, kept beside the field event: a second hand's throw never
-- supersedes the first. Openings without a battler (the overworld-encounter preselection) draw no beam.
-- battle-ui (2026-10-01, user rule: own visuals only): the engine's opening release is physical now (no native
-- ball/burst/emerge ball sounds), the beam runs on its own clock, and M.battleVisuals() hands FRLG_VOXEL the live
-- beams so it draws the battler growing in as the user's silhouette from the beam's start.
-- belt-switch (2026-10-02, Lab 10 headset: "the send-out animation timing is off"):
--   * a field send-out hides the follower's own card from the moment the throw is accepted (it used to be hidden
--     only after this effect's first draw, which could only start once the encounter mod's EXIT_POKEBALL had
--     played: the game's ball, a white flash and the Pokemon, all before the user's beam). FRLG_CATCH's
--     FollowerSendOut now places the Pokemon without that action; the hide is cleared when the effect ends,
--     fails or is superseded, exactly like the old first-draw mask;
--   * BELT SWITCH (compat/Gen3BeltSwitch): an accepted battle recall (c.switchRecall) draws the user's red recall
--     beam from the battler into the held ball (OpeningBeamFX.startRecall), following the ball (FX.mouth);
--   * the recall aim reticle (compat/Gen3RecallAim): a red ring at the feet of whatever the held ball is aimed
--     at, brighter and filling while the trigger is held, returned as ordinary belt render packets.
local Host = ...
local M = {}
M.MODE = 'original' -- user 2026-10-01: own visuals only (energy beam); no native ball-open blend
M.HANDOFF_SEC = 0.05 -- belt-switch: s of overlap between the user's coloured picture and the follower's own card
M.OPENING_BEAMS = true -- vr-doubles: false = battle openings (singles and doubles) play the native send-out only
local stats={started=0,acquired=0,draws=0,completed=0,failed=0}
local liveEvent
local audioOwners=setmetatable({},{__mode='k'})
local function stopSound(owner,release)
  for _,source in pairs(owner._gen3PartyAudio or {})do
    pcall(source.stop,source);if release then pcall(source.release,source)end
  end
  if release then owner._gen3PartyAudio=nil;audioOwners[owner]=nil end
end
-- Own cues only for accepted custom effects; never layer native OPEN/TRADE.
function M.playSound(kind,owner,V,game)
  if kind~='deploy'and kind~='recall'then return false end
  local ok,played=pcall(function()
    owner._gen3PartyAudio=owner._gen3PartyAudio or {};audioOwners[owner]=true
    local source=owner._gen3PartyAudio[kind]
    if not source then
      local mod=kind=='recall'and Host and Host.mod or V and V.mod
      local path=kind=='recall'and 'assets/party/recall.mp3'or 'assets/party/sendout.ogg'
      local bytes=assert(mod and mod:read(path),'custom '..kind..' audio missing')
      local file=love.filesystem.newFileData(bytes,kind=='recall'and 'recall.mp3'or 'sendout.ogg')
      local loaded,result=pcall(love.audio.newSource,file,'static');file:release()
      assert(loaded,result);source=result;owner._gen3PartyAudio[kind]=source
    end
    local volume=tonumber(game and game.save and game.save.options and game.save.options.sfxVol)or 7
    if volume~=volume then volume=7 end
    source:stop();source:setLooping(false);source:setVolume(.58*math.max(0,math.min(7,volume))/7)
    return source:play()~=false
  end)
  if not(ok and played)then stats.soundFailures=(stats.soundFailures or 0)+1;return false end
  stats.sounds=(stats.sounds or 0)+1;return true
end
function M.status()
  local out={};for k,v in pairs(stats) do out[k]=v end
  if liveEvent then
    out.live={kind=liveEvent.kind,age=liveEvent.age,ballId=liveEvent.ballId,native=liveEvent.native,
      mode=liveEvent.mode,beamOk=liveEvent.renderer and liveEvent.renderer.beamOk}
  end
  out.mode=M.MODE
  out.openingBeams=M._beamStatus and M._beamStatus() or nil
  return out
end
-- battle-ui: the user's opening beams for FRLG_VOXEL (plain data; nil before install). See OpeningBeamFX.visuals.
function M.battleVisuals()
  return M._beamVisuals and M._beamVisuals() or nil
end
function M.install(V)
  local FX = V.require('PartyActionFX')
  local headingUndo
  local okHeading,Heading=pcall(function()return Host.require('compat/Gen3BallHeadingCompat')end)
  if okHeading and Heading then
    local ok,undo=pcall(Heading.install,V)
    if ok and type(undo)=='function'then headingUndo=undo end
  end
  local subjectUndo
  local okSubject,Subject=pcall(function()return Host.require('compat/Gen3PartySubjectCompat')end)
  if okSubject and Subject then
    local ok,undo=pcall(Subject.install,V)
    if ok and type(undo)=='function'then subjectUndo=undo end
  end
  stats.subjectAdapterInstalled=subjectUndo~=nil
  stats.headingAdapterInstalled=headingUndo~=nil
  local Energy = V.require('catching/release_energy')
  local okN, Native = pcall(function() return Host and Host.require and Host.require('compat/NativeBallFX') end)
  if not (okN and type(Native) == 'table') then Native = nil end
  local okP, Plasma = pcall(V.require, 'catching/capture_plasma')
  local okM, Material = pcall(V.require, 'catching/capture_material')
  local combinedDeps = (okP and type(Plasma) == 'table' and okM and type(Material) == 'table'
    and type(Energy) == 'table' and type(Energy.pose) == 'function') and {
      pose = Energy.pose, Plasma = Plasma, Material = Material, growSec = Energy.GROW_SEC,
      settleSec = Energy.SETTLE_SEC, recallDuration = Energy.RECALL_DURATION,
      duration = Energy.DURATION, recallDuration = Energy.RECALL_DURATION } or nil
  local function modeFor()
    if not Native then return 'energy' end
    if M.MODE == 'combined' and not (combinedDeps and Native.newCombined) then return 'native' end
    -- 'original' (the name the catch switch uses, FRLG_CATCH CaptureTiming.MODE) = 'energy'
    if M.MODE == 'original' or (M.MODE ~= 'combined' and M.MODE ~= 'native') then return 'energy' end
    return M.MODE
  end
  local okB, Beams = pcall(function() return Host and Host.require and Host.require('compat/OpeningBeamFX') end)
  if not (okB and type(Beams) == 'table') then Beams = nil end
  local beamLists = setmetatable({}, {__mode='k'})
  local lastBeamList
  local function beamList(self)
    local list = beamLists[self]
    if not list and Beams then list = Beams.newList(); beamLists[self] = list end
    lastBeamList = list or lastBeamList
    return list
  end
  M._beamStatus = function() return Beams and lastBeamList and Beams.status(lastBeamList) or nil end
  M._beamVisuals = function()
    if not (Beams and Beams.visuals) then return nil end
    local out = {}
    for _, list in pairs(beamLists) do Beams.visuals(list, combinedDeps, out) end
    return out
  end
  local function beamVoxel()
    local ok, voxel = pcall(function() return Host and Host.require and Host.require('Voxel3D') end)
    return ok and voxel or nil
  end
  local original = {}
  for _, name in ipairs({'play','packets','draw','mouth','reset','dispose'}) do original[name] = FX[name] end
  local owners = setmetatable({}, {__mode='k'})
  local function clear(self, reason, complete)
    local e = self._gen3Event
    self._gen3Event = nil
    owners[self] = nil
    if not e then return end
    if liveEvent == e then liveEvent = nil end
    local maskKey = e.maskKey or (e.subject and e.subject.key)
    if e.masked and maskKey then pcall(e.prop._gen3PartyMask, e.prop, maskKey, false) end
    if e.renderer then pcall(e.renderer.clear, e.renderer) end
    if e.subject and e.subject.release then pcall(e.subject.release, e.subject) end
    e.cancelled = reason
    if complete then stats.completed=stats.completed+1 end
    stats.last={kind=e.kind,reason=reason or 'complete',draws=e.draws or 0,age=e.age,wait=e.wait}
    if V.mod and V.mod.log then
      pcall(V.mod.log.info,V.mod.log,'Gen3 party %s: %s, card=%s, draws=%d, age=%.3f',
        tostring(e.kind),tostring(reason or 'complete'),tostring(e.subject~=nil),e.draws or 0,e.age)
    end
    if complete and e.kind == 'recall' and self.onRecallComplete then pcall(self.onRecallComplete,e) end
  end
  local function acquire(e, entity)
    local ok, subject = pcall(e.prop._gen3PartySubject, e.prop, entity, e.kind, e.mon)
    if not (ok and subject) then return false end
    e.subject = subject
    -- review fix 7: PartySubject only takes the follower ('follower:1'); should its key ever differ, move the hide
    if e.masked and e.maskKey and subject.key and subject.key ~= e.maskKey then
      pcall(e.prop._gen3PartyMask, e.prop, e.maskKey, false)
      local hidden, on = pcall(e.prop._gen3PartyMask, e.prop, subject.key, true)
      e.maskKey, e.masked = subject.key, hidden and on == true
    end
    if e.mode == 'combined' then
      e.renderer = Native.newCombined(e.prop.Voxel3D,e.prop.Mat4,e.kind,e.ballId,combinedDeps)
      e.native = true
    elseif e.mode == 'native' then
      e.renderer = Native.newParty(e.prop.Voxel3D,e.prop.Mat4,e.kind,e.ballId)
      e.native = true
    else
      e.renderer = Energy.new(e.prop.Voxel3D,e.prop.Mat4)
    end
    stats.acquired=stats.acquired+1
    if not e.soundPlayed then e.soundPlayed=M.playSound(e.kind,e.owner,V,e.game)end
    return true
  end
  FX.reset = function(self, reason)
    stopSound(self,false)
    if Beams and beamLists[self] then Beams.clear(beamLists[self], reason or 'reset') end
    clear(self, reason or 'reset')
    return original.reset(self, reason)
  end
  FX.play = function(self,c,target,game,entity,prop)
    -- belt-switch: a battle switch's recall draws the user's recall beam into the held ball
    if c and c.switchRecall and c.recallBattler ~= nil then
      if not (Beams and combinedDeps and Beams.startRecall) then return false end
      local ok = Beams.startRecall(beamList(self), c, combinedDeps, V)
      if ok==true then M.playSound('recall',self,V,game)end
      return ok == true
    end
    -- vr-doubles: a two-slot opening throw adds its own beam and leaves every other effect running
    if c and c.opening and (c.openingBattler ~= nil or c.rseBattler ~= nil) then
      if not (M.OPENING_BEAMS and Beams and combinedDeps) then return false end
      local ok = Beams.start(beamList(self), c, combinedDeps, V)
      if ok==true then M.playSound('deploy',self,V,game)end
      return ok == true
    end
    self:reset('superseded')
    -- Gen3 battle openings retain native ball presentation and native audio.
    if c.opening then return false end
    if not (prop and prop._gen3PartySubject) then return original.play(self,c,target,game,entity,prop) end
    local origin = c.target and (c.target.mouth or c.target.origin or (c.target.ray and c.target.ray.origin))
    if not (origin and game and game.overworld) then return false end
    local mode = modeFor()
    local duration
    if mode == 'combined' then
      local _, d = Native.combinedTiming(c.kind == 'recall' and 'recall' or 'deploy', combinedDeps)
      duration = d
    elseif mode == 'native' then
      duration = c.kind=='recall' and Native.RECALL_DURATION or Native.DEPLOY_DURATION
    else
      duration = c.kind=='recall' and Energy.RECALL_DURATION or Energy.DURATION
    end
    local e = {kind=c.kind,index=c.index,mon=c.mon,origin=origin,prop=prop,age=0,wait=0,owner=self,
      game=game,save=game.save,map=game.overworld.map,mode=mode,
      ballId=Native and Native.ballIdForItem(c.mon and c.mon.pokeball) or 0,
      duration=duration}
    self._gen3Event=e;owners[self]=true;liveEvent=e
    stats.started=stats.started+1
    -- belt-switch: hide the follower's card now (the Gen3 subject is always the follower), not at the first draw
    -- (recall too, review fix 7: FollowerSendOut drops its own send-out hide when a recall starts)
    if (c.kind=='deploy' or c.kind=='recall') and prop._gen3PartyMask then
      local hidden,on=pcall(prop._gen3PartyMask,prop,'follower:1',true)
      e.maskKey='follower:1'
      e.masked=hidden and on==true
    end
    acquire(e,entity)
    if c.kind=='recall' and not e.subject then clear(self,'no recall card');return false end
    return true
  end
  -- belt-switch: the recall aim reticle (Gen3RecallAim.liveAims) as belt render packets (world px, like the belt's)
  local okA, Aim = pcall(function() return Host and Host.require and Host.require('compat/Gen3RecallAim') end)
  if not (okA and type(Aim) == 'table') then Aim = nil end
  local okR, Ring = pcall(V.require, 'ChooseRing')
  if not (okR and type(Ring) == 'table') then Ring = nil end
  local okMat, Mat = pcall(V.require, 'Mat4')
  if not (okMat and type(Mat) == 'table' and Mat.rotateX) then Mat = nil end
  local rings = setmetatable({}, {__mode='k'})
  M.RETICLE = false -- user: no ground recall circle in Emerald or FireRed
  local function reticle(self, out)
    if not (M.RETICLE and Aim and Ring and Mat and self.backend and self.backend.mesh) then return out end
    local aims = Aim.liveAims()
    if #aims == 0 then return out end
    local mesh = rings[self]
    if not mesh then
      local okM, m = pcall(function() local v, idx = Ring.mesh(); return self.backend.mesh(v, idx) end)
      if not okM then return out end
      mesh = m; rings[self] = m
    end
    local t = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
    for _, a in ipairs(aims) do
      local p = a.point
      if p and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) then
        local w = math.max(8, math.min(64, tonumber(p.w) or 16))
        local hgt = tonumber(p.h) or w
        local hold = a.hold or 0
        -- ChooseRing: radius ~0.036 m in its XY plane; lay it on the ground under the card, ~0.6 card wide
        local k = (0.55 + 0.25 * hold) * w / 0.036
        local model = Mat.mul(Mat.translate(p.x, p.y - hgt / 2 + 0.4, p.z), Mat.mul(Mat.rotateX(-math.pi / 2), Mat.scale(k, k, k)))
        local b = a.hold and (0.85 + 0.15 * hold) or (0.55 + 0.20 * math.sin(t * 8))
        out[#out + 1] = { mesh = mesh, material = { color = { b, .005, .002, 1 } }, model = model }
      end
    end
    return out
  end

  FX.packets = function(self,dt,authority)
    if Beams and beamLists[self] then Beams.step(beamLists[self], dt, V) end
    local e=self._gen3Event
    if not e then return reticle(self, original.packets(self,dt,authority) or {}) end
    local game=authority.game
    if game~=e.game or game.save~=e.save or not game.overworld or game.overworld.map~=e.map
        or (game.save.party and game.save.party[e.index]~=e.mon) then
      clear(self,'context changed');return {}
    end
    dt=math.max(0,tonumber(dt) or 0)
    if not e.subject then
      -- fix57 (bug 1): while OUR Wilds swap scene runs (Gen3ChooseYouCompat.swapHold, 6 s at most) the follower card
      -- cannot exist yet (it is the old / not yet the new Pokemon); that time does not count toward the 2 s timeout
      local okH, CY = pcall(function() return Host and Host.require and Host.require('compat/Gen3ChooseYouCompat') end)
      local holding = okH and type(CY) == 'table' and type(CY.swapHold) == 'function' and CY.swapHold() ~= false
      if not holding then e.wait=e.wait+dt end
      acquire(e,authority:entity(game,e.mon))
      if e.wait>2 then clear(self,'card timeout') end
    else
      e.age=e.age+dt
      -- belt-switch: the follower's own card comes back a few frames before the user's effect stops drawing (the
      -- card shows a frame after the unmask), so the hand-over from the coloured picture has no blank frame
      if e.kind=='deploy' and not e.native and e.masked and e.age>=e.duration-M.HANDOFF_SEC then
        pcall(e.prop._gen3PartyMask,e.prop,e.maskKey or e.subject.key,false)
        e.masked=false; e.handedOff=true
      end
      if e.age>=e.duration then
        if e.kind=='deploy' and e.native then
          -- Hand the Pokemon back to its own card without a blank frame: the
          -- unmask shows up a frame later, so keep drawing our (now identical,
          -- unblended full-size) card for two more frames before clearing.
          if not e.handoff then
            if e.masked then pcall(e.prop._gen3PartyMask,e.prop,e.subject.key,false) end
            e.handoff=2
          else
            e.handoff=e.handoff-1
            if e.handoff<=0 then clear(self,nil,true) end
          end
        else
          clear(self,nil,true)
        end
      end
    end
    return reticle(self, {})
  end
  FX.draw = function(self,...)
    if Beams and beamLists[self] and #beamLists[self].beams > 0 then
      local voxel = beamVoxel()
      if voxel then Beams.draw(beamLists[self], voxel, combinedDeps) end
    end
    local e=self._gen3Event
    if not e then return original.draw(self,...) end
    if not e.subject then return end
    local ok,drawn=pcall(function()
      if e.subject.update and e.subject:update()==false then return false end
      return e.renderer:draw(e.age,e.subject,e.origin,e.kind=='recall' and 'recall' or 'follow')
    end)
    if not (ok and drawn) then
      self.lastError=tostring(ok and 'Gen3 energy renderer unavailable' or drawn)
      stats.failed=stats.failed+1
      clear(self,'draw failed');return
    end
    e.draws=(e.draws or 0)+1;stats.draws=stats.draws+1
    if not e.masked and not e.handoff and not e.handedOff then
      local hidden,on=pcall(e.prop._gen3PartyMask,e.prop,e.subject.key,true)
      e.masked=hidden and on==true
    end
  end
  FX.mouth = function(self,index,point)
    if Beams and Beams.mouth and beamLists[self] then Beams.mouth(beamLists[self], index, point) end
    local e=self._gen3Event
    if e and e.kind=='recall' and e.index==index then e.origin=point end
    return original.mouth(self,index,point)
  end
  FX.dispose = function(self)
    stopSound(self,true)
    if Beams and beamLists[self] then Beams.clear(beamLists[self], 'disposed') end
    if rings[self] and self.backend and self.backend.release then pcall(self.backend.release, rings[self]) end
    rings[self] = nil
    clear(self,'disposed');return original.dispose(self)
  end
  return function()
    if headingUndo then headingUndo()end
    if subjectUndo then subjectUndo()end
    for owner in pairs(audioOwners)do stopSound(owner,true)end
    for owner in pairs(owners) do clear(owner,'uninstalled') end
    if Beams then for _, list in pairs(beamLists) do Beams.clear(list, 'uninstalled') end end
    M._beamStatus = nil
    M._beamVisuals = nil
    for name,fn in pairs(original) do FX[name]=fn end
  end
end
return M
