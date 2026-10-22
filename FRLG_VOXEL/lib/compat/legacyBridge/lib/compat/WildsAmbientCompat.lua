-- Wilds 1.10.1 native ambient bodies and travelling wild Pokemon.
-- Capture actual upstream draw closures once in prepare, reuse for both eyes.
-- Native non-passer effects stay owned by Wilds. Ambient passers alone use
-- sharp native artwork at physical sky height in the voxel view (not 2D blur).
-- Decorative particles never become catchable Pokemon.
local M = {}
M.MAX_CARDS = 32
M.SIZE = 256
-- Camera.METRES_PER_CELL. Ambient h is normalized 2D depth, not metres.
M.METRES_PER_CELL = 1.6
M.MIN_PASSER_METRES, M.MAX_PASSER_METRES = 6, 10
-- Approach follows the native flight clock, never head pose or render frame rate.
M.APPROACH_DROP_METRES, M.APPROACH_FRACTION = 8, 0.55
function M.approachDrop(b)
  local plan=b.plan
  local phase=type(plan)=='table' and type(plan.phases)=='table' and plan.phases[1]
  if not phase or phase.type~='fly' or type(phase.n)~='number' or phase.n<=0 then return 0 end
  local t=(tonumber(plan.i)or 1)>1 and 1 or math.max(0,math.min(1,(tonumber(plan.t)or 0)/phase.n))
  local u=math.min(1,t/M.APPROACH_FRACTION)
  return M.APPROACH_DROP_METRES*(1-u*u*(3-2*u))
end
-- Native action cards are separately capped; health bars take priority.
M.MAX_ACTION_CARDS=4
local ACTION_Y={ow_health_bar=80,ow_hit_effect=90,ow_finisher_fx=96,
  ow_hit_spark=95,ow_move_fx=94,ow_ko_mark=-0.5,ow_partner_fx=93,follower_popup=64}
function M.actionAnchor(a)
  local offset=ACTION_Y[a.kind]
  if not(offset and type(a.x)=='number' and type(a.y)=='number' and type(a.sortY)=='number')then return nil end
  local groundZ=a.sortY-offset+8
  return a.x/16,groundZ/16,groundZ-a.y
end
local function captureAction(g,slot,a,camX,camY)
  g.setCanvas(slot.image);g.origin();g.setShader();g.setScissor();g.setDepthMode()
  g.setColor(1,1,1,1);g.setBlendMode('alpha','alphamultiply');g.clear(0,0,0,0)
  g.translate(M.SIZE/2-(a.x-camX),M.SIZE/2-(a.y-camY))
  a:draw(camX,camY)
end
-- Recover the native screen-to-world scale from the position collectActors
-- just produced. This avoids duplicating Wilds' parallax configuration. Its
-- passer ground path is anchored at cam0 and is independent of head pose.
function M.flightBounds(b,vw,vh)
  local p=b.plan;local ph=p and p.phases and p.phases[1]
  local c=b.cam0
  if not (b.screenSpace and c and ph and ph.type=='fly' and ph.from and ph.to
    and type(b.sx)=='number' and type(b.sy)=='number')then return nil end
  local dx,dy=b.x-c.x-vw/2,b.y-c.y-vh/2
  local scale
  if math.abs(dx)>math.abs(dy) and math.abs(dx)>1e-6 then scale=(b.sx-8-vw/2)/dx
  elseif math.abs(dy)>1e-6 then scale=(b.sy-16-vh/2)/dy end
  if not(scale and scale==scale and scale>0 and scale<math.huge)then return nil end
  local a,z=ph.from,ph.to
  if not(type(a.x)=='number' and type(a.y)=='number' and type(z.x)=='number' and type(z.y)=='number')then return nil end
  local bend=math.abs(tonumber(ph.curve)or 0)
  local function wx(x)return(c.x+vw/2+(x-8-vw/2)/scale+8)/16 end
  local function wz(y)return(c.y+vh/2+(y-16-vh/2)/scale+8)/16 end
  local pad=.75 -- native sprite envelope beyond its ground path
  return {x0=wx(math.min(a.x,z.x)-bend)-pad,x1=wx(math.max(a.x,z.x)+bend)+pad,
    z0=wz(math.min(a.y,z.y)-bend)-pad,z1=wz(math.max(a.y,z.y)+bend)+pad}
end
local BODY = { sky_mon=true, sky_mon_far=true, ow_water_life=true, ow_local_scene=true }
local function capturePasser(g,slot,b)
  g.setCanvas(slot.image);g.origin();g.setShader();g.setScissor();g.setDepthMode()
  g.setColor(1,1,1,1);g.setBlendMode('alpha','alphamultiply');g.clear(0,0,0,0)
  -- Original live renderer and flap pose, without SkyDraw's screen-depth scale,
  -- parallax, crossfade or blur. Never change a shared sprite sheet's filter.
  local r=b.renderer
  local act,alpha,silhouette=r.act,r.alpha,r.silhouette
  r.act,r.alpha=nil,nil
  if b.silhouette~=nil then r.silhouette=b.silhouette end
  local ok,err=pcall(r.draw,r,M.SIZE/2-8,M.SIZE/2-16,0,0,b.facing or 'down',b.pose)
  r.act,r.alpha,r.silhouette=act,alpha,silhouette
  if not ok then error(err)end
end
local function capture(g,slot,a,camX,camY)
  g.setCanvas(slot.image);g.origin();g.setShader();g.setScissor();g.setDepthMode()
  g.setColor(1,1,1,1);g.setBlendMode('alpha','alphamultiply');g.clear(0,0,0,0)
  g.translate(M.SIZE/2-(a.x+8-camX),M.SIZE/2-(a.y-camY))
  a:draw(camX,camY)
end
function M.new()
  local self={ slots={}, records={}, raw={}, frame=0, count=0, errors=0 }
  function self:close()
    for _,s in ipairs(self.slots) do
      if s.image and s.image.release then pcall(s.image.release,s.image) end
      if s.quad and s.quad.release then pcall(s.quad.release,s.quad) end
    end
    self.slots,self.records,self.raw={},{},{}
    self.frame,self.count=-1,0
  end
  function self:append(out,ex,manager,frame)
    local g=love and love.graphics
    if not(g and g.newCanvas and g.push and g.translate)then return out end
    self.frame=frame;self.count=0
    local raw=self.raw;for i=#raw,1,-1 do raw[i]=nil end
    -- Use the actual engine view origin; collectActors hands the same view
    -- to SkyDraw's perspective and remembers it for spawning new creatures.
    local camX,camY=0,0
    local patch=ex.enginePatch
    local player=patch and patch.playerCell and patch.playerCell()
    local vw,vh=240,160
    if patch and patch.viewSize then local w,h=patch.viewSize();vw,vh=w or vw,h or vh end
    local px,py
    if patch and patch.playerPixel then px,py=patch.playerPixel() end
    if type(px)=='number' and type(py)=='number' then
      camX,camY=math.floor(px+8-vw/2),math.floor(py+8-vh/2)
    elseif player then camX,camY=player.x*16+8-vw/2,player.y*16+8-vh/2 end
    manager:collectActors(raw,camX,camY)
    for _,aux in ipairs({ex.skyFlyers,ex.waterLife,ex.localScenes})do
      if aux and aux.collectActors then aux:collectActors(raw,camX,camY)end
    end
    if ex.version=='1.10.1' and ex.followerAdapter and ex.followerAdapter.collectActors then
      ex.followerAdapter:collectActors(raw) -- native role HP, hits, readiness and EXP/status labels
    end
    -- collectActors above must still run: it advances no flight clocks, but
    -- resolves screen-space passer paths to stable world b.x/y and remembers
    -- the camera for spawning. Only replace this ambient manager's passers;
    -- real land/leave flights, perch/dive birds and water/local actors stay native.
    local passers,owned={},{}
    for _,b in ipairs(ex.skyFlyers and ex.skyFlyers.birds or {})do
      if b.kind=='passer' and b.renderer and type(b.renderer.draw)=='function' then
        local st=b._skyDraw
        if st then
          if st.sharp then owned[st.sharp]=true end
          if st.far then owned[st.far]=true end
        end
        if not b.hidden and type(b.x)=='number' and type(b.y)=='number' then passers[#passers+1]=b end
      end
    end
    local ordered={}
    for priority=1,4 do for _,a in ipairs(raw)do
      local action=ex.version=='1.10.1' and ACTION_Y[a.kind]~=nil
      local status=a.kind=='follower_popup' or a.kind=='ow_partner_fx'
      if (priority==1 and action and a.kind=='ow_health_bar')
        or (priority==2 and action and status)
        or (priority==3 and action and not status and a.kind~='ow_health_bar')
        or (priority==4 and BODY[a.kind])then ordered[#ordered+1]=a end
    end end
    local actionCount=0
    for _,a in ipairs(ordered)do
      local ax,az,lift
      if ex.version=='1.10.1' then ax,az,lift=M.actionAnchor(a)end
      local action=ax~=nil
      if not owned[a] and (BODY[a.kind] or (action and actionCount<M.MAX_ACTION_CARDS)) and type(a.draw)=='function' and self.count<M.MAX_CARDS then
        self.count=self.count+1
        local idx=self.count
        local slot=self.slots[idx]
        if not slot then
          local image=g.newCanvas(M.SIZE,M.SIZE,{dpiscale=1})
          image:setFilter('nearest','nearest')
          slot={image=image,quad=g.newQuad(0,0,M.SIZE,M.SIZE,M.SIZE,M.SIZE)}
          self.slots[idx]=slot
        end
        -- Slot canvases are reused across frames; there is no allocation or
        -- GPU readback per eye. Full native alpha is retained on the canvas.
        g.push('all')
        local ok,err=pcall(action and captureAction or capture,g,slot,a,camX,camY)
        g.pop()
        if ok then
          local key=a.kind..':'..tostring(a.i)
          local rec=self.records[key]
          if not rec then
            rec={provider='wilds_of_hoenn',kind='wilds_ambient',catchable=false,shadow=false,
              liftScaled=true,premultiplied=true}
            rec.pose=function(record)
              if rec.seen~=self.frame then return nil end
              return rec.image,0,0,1,1,M.SIZE,M.SIZE,rec.action and M.SIZE/2-1 or M.SIZE-1,1
            end
            self.records[key]=rec
          end
          rec.seen,rec.image=frame,slot.image
          rec.x,rec.z,rec.facing=(a.x+8)/16,(a.y+8)/16,a.facing
          rec.liftPx=16-M.SIZE/2
          rec.action,rec.sourceKind=action,a.kind
          if action then
            rec.x,rec.z,rec.liftPx=ax,az,lift
            actionCount=actionCount+1
          end
          out[#out+1]=rec
        else self.errors=self.errors+1;self.lastError=tostring(err)end
      end
    end
    for _,b in ipairs(passers)do
      if self.count<M.MAX_CARDS then
        self.count=self.count+1
        local idx=self.count;local slot=self.slots[idx]
        if not slot then
          local image=g.newCanvas(M.SIZE,M.SIZE,{dpiscale=1});image:setFilter('nearest','nearest')
          slot={image=image,quad=g.newQuad(0,0,M.SIZE,M.SIZE,M.SIZE,M.SIZE)};self.slots[idx]=slot
        end
        g.push('all');local ok,err=pcall(capturePasser,g,slot,b);g.pop()
        if ok then
          -- Object identity prevents reused numeric bird IDs from inheriting a
          -- retired record. Prepared once, pose is read-only for both eyes.
          local rec=self.records[b]
          if not rec then
            rec={provider='wilds_of_hoenn',kind='wilds_ambient',catchable=false,
              shadow=false,liftScaled=false,premultiplied=true,color={1,1,1,1},skyPasser=true}
            rec.pose=function(record)
              if record.seen~=self.frame then return nil end
              -- Padding compensation follows cardScale; altitude never does.
              return record.image,0,0,1,1,M.SIZE,M.SIZE,M.SIZE/2-1,1,record.color
            end
            self.records[b]=rec
          end
          local h=math.max(0,math.min(1,tonumber(b.h)or 0))
          rec.flightBounds=rec.flightBounds or M.flightBounds(b,vw,vh)
          rec.altitudeMetres=M.MIN_PASSER_METRES+(M.MAX_PASSER_METRES-M.MIN_PASSER_METRES)*h
          rec.approachExtraMetres=M.approachDrop(b)
          rec.altitudeMetres=rec.altitudeMetres+rec.approachExtraMetres
          rec.liftPx=rec.altitudeMetres/M.METRES_PER_CELL*16
          rec.x,rec.z,rec.facing=(b.x+8)/16,(b.y+8)/16,b.facing
          -- Captured Canvas pixels are premultiplied; fade RGB and alpha
          -- together so path fade-outs cannot leave a bright outline.
          local alpha=b.alpha or 1
          rec.color[1],rec.color[2],rec.color[3],rec.color[4]=alpha,alpha,alpha,alpha
          rec.seen,rec.image=frame,slot.image;out[#out+1]=rec
        else self.errors=self.errors+1;self.lastError=tostring(err)end
      end
    end
    for key,rec in pairs(self.records)do if rec.seen~=frame then self.records[key]=nil end end
    return out
  end
  return self
end
return M
