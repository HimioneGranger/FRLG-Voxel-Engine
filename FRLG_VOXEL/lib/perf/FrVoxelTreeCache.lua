-- Persist the mesher's immutable CPU tree stamps and placements, never GPU
-- instance buffers. Hits use the existing batched live renderer unchanged.
local M={VERSION=1,MAX_STAMPS=64,MAX_TREES=65536,MAX_VERTICES=262144,SEGMENT_VERTICES=192}
M.STRIDE=13*8 -- preserve the original CPU numbers exactly; GPU upload stays float32
local FORMAT='<ddddddddddddd'
local unpack_=unpack or table.unpack
local function fail(s)error('frpc: voxel trees '..s,0)end
local function need(v,s)if not v then fail(s)end end
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<math.huge end
local function integer(v,lo,hi)return finite(v)and v%1==0 and v>=lo and v<=hi end
local function plain(t)need(type(t)=='table'and getmetatable(t)==nil,'plain table');return t end
local function keys(t,allowed)
 plain(t);for k in pairs(t)do need(allowed[k], 'unexpected field '..tostring(k))end
end
local function dense(t,maxCount)
 plain(t);local n=#t;need(n<=maxCount,'array limit');local count=0
 for k in pairs(t)do need(integer(k,1,n),'array index');count=count+1 end
 need(count==n,'sparse array');return n
end
local function name(s)need(type(s)=='string'and #s>0 and #s<=160,'name');return s end
local TOP={pair=true,stamps=true,trees=true}
local STAMP={under=true,over=true,tris=true,radius=true,height=true}
local TREE={x=true,y=true,z=true,near=true,far=true}
local STORED={version=true,pair=true,stamps=true,trees=true}
local STREAM={count=true,refs=true}
local REF={part=true,off=true,len=true}
local function placements(out,stamps,tick)
 local used={};local count=dense(out.trees,M.MAX_TREES)
 for i,t in ipairs(out.trees)do
  keys(t,TREE)
  for _,k in ipairs{'x','y','z'}do need(finite(t[k])and math.abs(t[k])<=1048576,'placement coordinate')end
  name(t.near);name(t.far);need(stamps[t.near]and stamps[t.far],'missing template')
  used[t.near],used[t.far]=true,true
  if i%256==0 then tick()end
 end
 for k in pairs(stamps)do need(used[k],'unreferenced template')end
 return count
end
local function stampList(out)
 plain(out.stamps);local names={}
 for k in pairs(out.stamps)do name(k);names[#names+1]=k end
 need(#names<=M.MAX_STAMPS,'template limit');table.sort(names);return names
end
local function dimensions(s)
 need(integer(s.tris,0,M.MAX_VERTICES/3),'triangle count')
 need(finite(s.radius)and s.radius>0 and s.radius<=4096,'radius')
 need(finite(s.height)and s.height>0 and s.height<=4096,'height')
end
function M.validate(out,pair,tick)
 tick=tick or function()end;keys(out,TOP);name(out.pair);need(out.pair==pair,'atlas pair')
 local names=stampList(out);local total=0
 for _,k in ipairs(names)do
  local s=out.stamps[k];keys(s,STAMP);dimensions(s);local count=0
  for _,layer in ipairs{'under','over'}do
   local n=dense(s[layer],M.MAX_VERTICES);need(n%3==0,'triangle stream');count=count+n
   total=total+n;need(total<=M.MAX_VERTICES,'vertex budget')
   for i,v in ipairs(s[layer])do
    need(dense(v,13)==13,'vertex width')
    for j=1,13 do need(finite(v[j])and math.abs(v[j])<=1048576,'vertex number')end
    if i%M.SEGMENT_VERTICES==0 then tick()end
   end
  end
  need(count==s.tris*3,'triangle total')
 end
 placements(out,out.stamps,tick);return total
end
local function copyTrees(trees)
 local out={};for i,t in ipairs(trees)do out[i]={x=t.x,y=t.y,z=t.z,near=t.near,far=t.far}end;return out
end
function M.capture(out,pair,addBlob,tick)
 tick=tick or function()end;M.validate(out,pair,tick)
 local stored={version=M.VERSION,pair=out.pair,stamps={},trees=copyTrees(out.trees)}
 for _,k in ipairs(stampList(out))do
  local s=out.stamps[k];local d={tris=s.tris,radius=s.radius,height=s.height};stored.stamps[k]=d
  for _,layer in ipairs{'under','over'}do
   local list=s[layer];local stream={count=#list,refs={}};d[layer]=stream
   for first=1,#list,M.SEGMENT_VERTICES do
    local chunks={}
    for i=first,math.min(#list,first+M.SEGMENT_VERTICES-1)do chunks[#chunks+1]=love.data.pack('string',FORMAT,unpack_(list[i]))end
    stream.refs[#stream.refs+1]=addBlob(table.concat(chunks));tick()
   end
  end
 end
 return stored
end
function M.validateStored(out,pair,parts,tick)
 tick=tick or function()end;keys(out,STORED);need(out.version==M.VERSION,'version');name(out.pair);need(out.pair==pair,'atlas pair')
 local total=0
 for _,k in ipairs(stampList(out))do
  local s=out.stamps[k];keys(s,STAMP);dimensions(s);local count=0
  for _,layer in ipairs{'under','over'}do
   local stream=s[layer];keys(stream,STREAM);need(integer(stream.count,0,M.MAX_VERTICES)and stream.count%3==0,'stored vertex count')
   total=total+stream.count;count=count+stream.count;need(total<=M.MAX_VERTICES,'vertex budget')
   local n=dense(stream.refs,math.ceil(stream.count/M.SEGMENT_VERTICES));local bytes=0
   need(n==math.ceil(stream.count/M.SEGMENT_VERTICES),'segment count')
   for _,ref in ipairs(stream.refs)do
    keys(ref,REF);need(integer(ref.part,1,#parts)and integer(ref.off,0,67108864)and integer(ref.len,1,M.SEGMENT_VERTICES*M.STRIDE),'blob reference')
    need(ref.len%M.STRIDE==0,'blob stride');local p=parts[ref.part]
    need(p and finite(p.raw)and ref.off+ref.len<=p.raw,'blob range');bytes=bytes+ref.len;tick()
   end
   need(bytes==stream.count*M.STRIDE,'stream length')
  end
  need(count==s.tris*3,'triangle total')
 end
 placements(out,out.stamps,tick);return total
end
function M.restore(stored,pair,parts,readBlob,tick)
 tick=tick or function()end;M.validateStored(stored,pair,parts,tick)
 local out={pair=stored.pair,stamps={},trees=copyTrees(stored.trees)}
 for _,k in ipairs(stampList(stored))do
  local d=stored.stamps[k];local s={tris=d.tris,radius=d.radius,height=d.height};out.stamps[k]=s
  for _,layer in ipairs{'under','over'}do
   local list={};s[layer]=list
   for _,ref in ipairs(d[layer].refs)do
    local bytes=readBlob(ref);need(type(bytes)=='string'and #bytes==ref.len,'blob bytes')
    for pos=1,#bytes,M.STRIDE do
     local v={love.data.unpack(FORMAT,bytes,pos)};v[14]=nil;list[#list+1]=v
    end
    tick()
   end
  end
 end
 M.validate(out,pair,tick);return out
end
return M
