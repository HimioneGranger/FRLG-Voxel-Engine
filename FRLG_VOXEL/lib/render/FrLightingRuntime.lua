-- Rendering-only contract. Clock/context/policy and native placement are supplied
-- by their authoritative owners; no calendar or classification heuristics here.
local V=...
local Pass=V.require('render/NativeLightPass')
local M={REVISION='fr-light-runtime-1',CACHE_SCHEMA=1};M.__index=M
function M:isBlocked(mr,dark,battle,seated)
 local f=mr and mr.f
 return (dark and dark.enabled==true)or(battle~=nil and battle~=false)or seated==true
  or(f and(f.portalFrame==true or(f.portal and f.portal.enabled==true)))or false
end
function M.new(policy)
 return setmetatable({policy=policy,pass=Pass.new{policy=policy},records={},lastRecords={},lastVisible={},stats={updates=0}},M)
end
-- payload is plain cacheable geometry: triangles/bodyTriangles in native pixels;
-- pools in cells, building descriptors retain destinations and stable identity.
function M:build(payload,project,admit,checkpoint,onResource)
 assert(payload.schema==M.CACHE_SCHEMA,'lighting cache schema')
 local records={}
 for _,src in ipairs(payload.records or{})do
  local b=src.kind=='streetlamp'and src.building or self.policy:register(src.building)
  records[#records+1]={building=b,kind=src.kind,triangles=src.triangles,bodyTriangles=src.bodyTriangles,pools=src.pools}
 end
 local r=self.pass:build(records,project,admit,checkpoint,onResource)
 r.payload={records={}}
 for i,src in ipairs(payload.records)do r.payload.records[i]={building=src.building}end
 return r
end
-- Cache consumers serialize this plain tree, never GPU objects or policy state.
function M.serialize(r)
 if not r then return end
 local data={schema=M.CACHE_SCHEMA,buffers=r.buffers,groups={}}
 for i,g in ipairs(r.groups)do
  local item={};for k,v in pairs(g)do if k~='lastStamp'and k~='building'then item[k]=v end end
  item.building=r.payload.records[i].building;data.groups[i]=item
 end
 for _,k in ipairs{'vertexCount','bodyTriangles','paneTriangles','poolTriangles','poolCount','truncated'}do data[k]=r[k]end
 return data
end
function M:restore(data,onResource)
 local policy=self.policy
 local r=self.pass:restore(data,function(d)return policy:register(d)end,onResource)
 r.payload={records={}}
 for i,g in ipairs(data.groups)do r.payload.records[i]={building=g.building}end
 return r
end
local function order(a,b)
 if a._lightingRoot~=b._lightingRoot then return a._lightingRoot end
 return tostring(a.key)<tostring(b.key)
end
function M:prepare(visible,rootId,frame,enabled)
 local records=self.records
 local changed=self.rootId~=rootId;local n=0
 for _,rec in ipairs(visible or{})do if rec.lightRecord and not rec.lightRecord.released then
  n=n+1;if self.lastVisible[n]~=rec.lightRecord then changed=true end
 end end
 if n~=#self.lastVisible then changed=true end
 if changed then
  for i=#records,1,-1 do records[i]=nil end
  for i=#self.lastVisible,1,-1 do self.lastVisible[i]=nil end
  for _,rec in ipairs(visible or{})do if rec.lightRecord and not rec.lightRecord.released then
   rec._lightingRoot=rec.key==rootId;records[#records+1]=rec;self.lastVisible[#self.lastVisible+1]=rec.lightRecord
  end end
  table.sort(records,order)
  for i,rec in ipairs(records)do records[i]=rec.lightRecord end
  self.rootId=rootId
 end
 local minute=frame.available and math.floor(frame.hour*60+1e-7)or'unavailable'
 if changed or self.minute~=minute or self.days~=frame.days or self.seed~=frame.seed or self.enabled~=enabled or self.generation~=self.policy.generation then
  self.pass:prepare(records,frame,enabled)
  for i=#self.lastRecords,1,-1 do self.lastRecords[i]=nil end
  for i,r in ipairs(records)do self.lastRecords[i]=r end
  self.minute,self.days,self.seed,self.enabled,self.generation=minute,frame.days,frame.seed,enabled,self.policy.generation
  self.stats.updates=self.stats.updates+1
 end
end
function M:draw(rec,env)return self.pass:draw(rec.lightRecord,env,rec.ox,rec.oz,rec.mvp)end
function M:release()self.pass:release();self.records={};self.lastRecords={}end
return M
