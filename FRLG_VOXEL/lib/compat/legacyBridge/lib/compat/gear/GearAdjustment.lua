-- Room-space handle editing only. No inventory, real-ball, or throw ownership.
local V=...;local Hip=V.require('HipRig');local M={};M.__index=M
local FILE='hip-gear-placement.json'
local LEGACY='floating-gear-placement.json'
local function copy(v)
 if type(v)~='table' then return v end
 local out={};for k,x in pairs(v)do out[k]=copy(x)end;return out
end
local function finite(v)return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
local function clamp(v,a,b)return math.max(a,math.min(b,v))end
local function placement(value)
 return Hip.normalize(value)
end
local function validRoot(r)
 if type(r)~='table' then return false end
 for _,i in ipairs({1,3,4,8,9,11,12})do if not finite(r[i])then return false end end
 return r[3]^2+r[11]^2>.5
end
local function world(root,p)
 local yaw=math.atan2(root[3],root[11]);local c,s=math.cos(yaw),math.sin(yaw)
 return {root[4]+c*p[1]+s*p[3],root[8]+p[2],root[12]-s*p[1]+c*p[3]}
end
local function localPoint(root,p)
 local yaw=math.atan2(root[3],root[11]);local c,s=math.cos(yaw),math.sin(yaw)
 local x,z=p[1]-root[4],p[3]-root[12]
 return {c*x-s*z,p[2]-root[8],s*x+c*z}
end
local function handPoint(h)
 local p=h and h.tracked and h.pose and h.pose.position
 if type(p)=='table' and finite(p[1])and finite(p[2])and finite(p[3])then return p end
end
function M.new(fs,json)
 return setmetatable({fs=fs,json=json,loaded=false,previous={left=1,right=1},confirmHeld=true},M)
end
function M:load()
 if self.loaded then return end;self.loaded=true
 if not(self.fs and self.fs.read and self.json and self.json.decode)then return end
 for _,file in ipairs({FILE,LEGACY})do
  local ok,bytes=pcall(self.fs.read,file)
  if ok and type(bytes)=='string' and #bytes<4096 then
   local decoded,value=pcall(self.json.decode,bytes)
   if decoded and type(value)=='table'then
    if file==FILE and value.version==2 then self.committed=placement(value)
    elseif file==LEGACY and value.version==1 then self.committed=Hip.migrate(value)end
    if self.committed then return end
   end
  end
 end
end
function M:get()self:load();return copy(self.committed)end
function M:active()return self.kind~=nil end
function M:begin(kind,defaults)
 if kind~='hip'then return false,'invalid adjustment kind'end
 self:load();local value=placement(self.committed or defaults)
 if not value then return false,'invalid gear defaults'end
 self.kind=kind;self.draft=value;self.grab=nil;self.error=nil
 self.previous={left=1,right=1};self.confirmHeld=true
 return true
end
function M:cancel()
 self.kind=nil;self.draft=nil;self.grab=nil;self.error=nil
 self.previous={left=1,right=1};self.confirmHeld=true
end
function M:handles(root)
 local out={};if not self.kind or not validRoot(root)then return out end
 local p=self.draft;local h=p.hip
 local function add(id,localPosition)
  out[#out+1]={id=id,position=world(root,localPosition),localPosition=localPosition}
 end
 add('center',{h.x,h.y+.16,h.z-h.rz})
 add('width',{h.x-h.rx,h.y+.12,h.z})
 add('depth',{h.x,h.y+.12,h.z+h.rz})
 add('party',Hip.party(p,0));add('partyLeft',Hip.party(p,-1));add('partyRight',Hip.party(p,1))
 add('pouch',Hip.point(p,p.pouch.angle))
 return out
end
function M:snapshot(root,confirmed)
 return {editing=self:active(),kind=self.kind,draft=copy(self.draft),handles=self:handles(root),
  grabbing=self.grab and self.grab.side,error=self.error,confirmed=confirmed==true}
end
function M:save()
 local value=placement(self.draft)
 if not value or not(self.fs and self.fs.write and self.json and self.json.encode)then
  self.error='gear placement storage unavailable';return false
 end
 local payload=copy(value);payload.version=2
 local encoded,bytes=pcall(self.json.encode,payload)
 if not encoded or type(bytes)~='string'then self.error='could not encode gear placement';return false end
 local ok,yes=pcall(self.fs.write,FILE,bytes)
 if not ok or not yes then self.error='could not save gear placement';return false end
 self.committed=value;self:cancel();return true
end
function M:update(root,hands,controls,confirm,blocked)
 if blocked then self:cancel();return self:snapshot(root)end
 if not self:active()then return self:snapshot(root)end
 hands=hands or {};controls=controls or {}
 local edge=confirm==true and not self.confirmHeld;self.confirmHeld=confirm==true
 if not validRoot(root)then
  self.grab=nil;self.previous={left=1,right=1};return self:snapshot(root)
 end
 local handles=self:handles(root)
 for _,side in ipairs({'left','right'})do
  local pos=handPoint(hands[side]);local grip=controls[side=='left' and 'gripL' or 'gripR']
  grip=finite(grip)and clamp(grip,0,1)or 0
  local pressed=pos and grip>=.65 and self.previous[side]<.65
  if self.grab and self.grab.side==side then
   if not pos or grip<=.35 then self.grab=nil
   else
    local q=localPoint(root,pos);local g=self.grab;local p=self.draft;local h=p.hip
    for i=1,3 do q[i]=q[i]+g.offset[i]end
    if g.id=='center'then
     h.x=q[1];h.y=q[2]-.16;h.z=q[3]+h.rz
    elseif g.id=='width'then h.rx=h.x-q[1]
    elseif g.id=='depth'then h.rz=q[3]-h.z
    elseif g.id=='party'then p.party.angle=Hip.angle(p,q)
    elseif g.id=='pouch'then p.pouch.angle=Hip.angle(p,q)
    else
     local d=Hip.angle(p,q)-p.party.angle;d=math.atan2(math.sin(d),math.cos(d))
     p.party.spread=2*(g.id=='partyLeft'and -d or d)
    end
    self.draft=placement(self.draft)
   end
  elseif not self.grab and pressed then
   local best=.10;local chosen
   for _,h in ipairs(handles)do
    local p=h.position;local d=math.sqrt((p[1]-pos[1])^2+(p[2]-pos[2])^2+(p[3]-pos[3])^2)
    if d<best then best=d;chosen=h end
   end
   if chosen then
    local q=localPoint(root,pos);local p=chosen.localPosition
    self.grab={side=side,id=chosen.id,offset={p[1]-q[1],p[2]-q[2],p[3]-q[3]}}
   end
  end
  -- Missing tracking requires a fresh release before another grip edge.
  self.previous[side]=not pos and 1 or (grip<=.35 and 0 or (grip>=.65 and 1 or self.previous[side]))
 end
 if edge and self:save()then return self:snapshot(root,true)end
 return self:snapshot(root)
end
return M
