-- Plain CPU geometry only. Never marks a GPU world-cache record completed.
local Snapshot=...
local M={VERSION=3,MAX_BYTES=48*1024*1024,PART_BYTES=512*1024}
local STREAMS={opaque=true,cutoutUnder=true,cutoutOver=true,cutoutKeyed=true,southWalls=true,shadowOpaque=true}
local ROW_BYTES=64
local ANCHOR_BYTES=20
local META_RUN_BYTES=12
local META_MAX_DICT=4096
local META_MAX_BYTES=4*1024*1024
-- Current authored vertex metadata consists of scalar labels/ownership flags.
-- Keep it lossless and sparse; callable/resource/nested state fails closed.
local function metadata(v)
 local keys={}
 for k in pairs(v)do if type(k)~='number'and k~='frTree'then
  assert(type(k)=='string'and #k>0 and #k<=96,'CPU metadata key')
  keys[#keys+1]=k
 end end
 assert(#keys<=32,'CPU metadata width');table.sort(keys)
 local out,pieces={},{}
 for _,k in ipairs(keys)do
  local value=v[k];local kind=type(value);local body
  if kind=='boolean'then body=value and 'b1'or 'b0'
  elseif kind=='number'then assert(value==value and math.abs(value)~=math.huge,'CPU metadata finite');body='n'..love.data.pack('string','<d',value)
  elseif kind=='string'then assert(#value<=1024,'CPU metadata string');body='s'..love.data.pack('string','<I4',#value)..value
  else error('unsupported CPU vertex metadata '..kind,0)end
  pieces[#pieces+1]=love.data.pack('string','<I4',#k)..k..body;out[k]=value
 end
 return table.concat(pieces),out
end
local function finite(v)return type(v)=='number'and v==v and math.abs(v)~=math.huge end
local function dimensions(w,h)
 assert(finite(w)and finite(h)and w%1==0 and h%1==0 and w>0 and h>0 and w*h<=65536,'CPU geometry dimensions')
end
local function dense(t,n)
 local count=0
 for k in pairs(t)do assert(type(k)=='number'and k%1==0 and k>=1 and k<=n,'CPU stream density');count=count+1 end
 assert(count==n,'CPU stream density')
end
local function packStream(list,budget,tick)
 assert(type(list)=='table','CPU stream type')
 local n=#list;dense(list,n)
 assert(n%3==0 and n*ROW_BYTES<=M.MAX_BYTES-budget.used,'CPU vertex budget')
 budget.used=budget.used+n*ROW_BYTES
 local parts,rows,anchors,anchorParts={},{},{},{}
 local anchorCount=0
 local metaDict,metaIds,metaRuns,metaParts={},{},{},{}
 local metaBytes,metaRunCount=0,0
 local runFirst,runLast,runId
 local function flushRun()
  if not runId then return end
  assert(budget.used+META_RUN_BYTES<=M.MAX_BYTES,'CPU vertex budget')
  budget.used=budget.used+META_RUN_BYTES;metaRunCount=metaRunCount+1
  metaRuns[#metaRuns+1]=love.data.pack('string','<I4I4I4',runFirst,runLast,runId)
  if #metaRuns==math.floor(M.PART_BYTES/META_RUN_BYTES)then metaParts[#metaParts+1]=table.concat(metaRuns);metaRuns={};tick()end
  runId=nil
 end
 for i,v in ipairs(list)do
  assert(type(v)=='table','CPU vertex type')
  local numeric=0;for k in pairs(v)do if type(k)=='number'then assert(k%1==0 and k>=1 and k<=8,'CPU vertex width');numeric=numeric+1 end end
  assert(numeric==8,'CPU vertex width')
  for j=1,8 do assert(finite(v[j]),'CPU vertex finite')end
  local signature,extra=metadata(v)
  local id
  if #signature>0 then
   id=metaIds[signature]
   if not id then
    assert(#metaDict<META_MAX_DICT and metaBytes+#signature<=META_MAX_BYTES,'CPU metadata budget')
    assert(budget.used+#signature<=M.MAX_BYTES,'CPU vertex budget')
    budget.used=budget.used+#signature;metaBytes=metaBytes+#signature
    id=#metaDict+1;metaDict[id]=extra;metaIds[signature]=id
   end
  end
  if id~=runId then flushRun();if id then runFirst=i;runId=id end end
  if id then runLast=i end
  if v.frTree~=nil then
   assert(type(v.frTree)=='table','CPU tree anchor');dense(v.frTree,2)
   assert(finite(v.frTree[1])and finite(v.frTree[2]),'CPU tree anchor finite')
   assert(budget.used+ANCHOR_BYTES<=M.MAX_BYTES,'CPU vertex budget');budget.used=budget.used+ANCHOR_BYTES
   anchorCount=anchorCount+1;anchors[#anchors+1]=love.data.pack('string','<I4dd',i,v.frTree[1],v.frTree[2])
   if #anchors==math.floor(M.PART_BYTES/ANCHOR_BYTES)then anchorParts[#anchorParts+1]=table.concat(anchors);anchors={};tick()end
  end
  rows[#rows+1]=love.data.pack('string','<dddddddd',v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8])
  if #rows*ROW_BYTES==M.PART_BYTES then parts[#parts+1]=table.concat(rows);rows={};tick()end
 end
 flushRun()
 if #metaRuns>0 then metaParts[#metaParts+1]=table.concat(metaRuns)end
 if #rows>0 then parts[#parts+1]=table.concat(rows);tick()end
 if #anchors>0 then anchorParts[#anchorParts+1]=table.concat(anchors);tick()end
 return {count=n,parts=parts,anchorCount=anchorCount,anchors=anchorParts,metaDict=metaDict,metaRuns=metaParts,metaRunCount=metaRunCount}
end
local function restoreStream(s,budget,tick)
 assert(type(s)=='table'and finite(s.count)and s.count>=0 and s.count%3==0,'CPU stream count')
 assert(s.count*ROW_BYTES<=M.MAX_BYTES-budget.used,'CPU vertex budget')
 assert(type(s.parts)=='table','CPU stream parts');dense(s.parts,#s.parts)
 assert(#s.parts<=math.ceil(s.count*ROW_BYTES/M.PART_BYTES),'CPU part count')
 local list,bytes={},0
 for _,part in ipairs(s.parts)do
  tick()
  assert(type(part)=='string'and #part>0 and #part<=M.PART_BYTES and #part%ROW_BYTES==0,'CPU part size')
  bytes=bytes+#part;assert(bytes<=s.count*ROW_BYTES,'CPU stream length')
  local pos=1
  while pos<=#part do
   local a,b,c,d,e,f,g,h,nextPos=love.data.unpack('<dddddddd',part,pos)
   local v={a,b,c,d,e,f,g,h};for j=1,8 do assert(finite(v[j]),'CPU vertex finite')end
   list[#list+1]=v;pos=nextPos
   if #list%256==0 then tick()end
  end
 end
 assert(bytes==s.count*ROW_BYTES and #list==s.count,'CPU stream length')
 budget.used=budget.used+bytes
 assert(finite(s.anchorCount)and s.anchorCount>=0 and s.anchorCount%1==0 and s.anchorCount<=s.count,'CPU anchor count')
 assert(type(s.anchors)=='table','CPU anchors');dense(s.anchors,#s.anchors)
 assert(#s.anchors<=math.ceil(s.anchorCount/math.floor(M.PART_BYTES/ANCHOR_BYTES)),'CPU anchor parts')
 assert(budget.used+s.anchorCount*ANCHOR_BYTES<=M.MAX_BYTES,'CPU vertex budget')
 local seen,last=0,0
 for _,part in ipairs(s.anchors)do
  tick();assert(type(part)=='string'and #part>0 and #part<=M.PART_BYTES and #part%ANCHOR_BYTES==0,'CPU anchor part size')
  local pos=1
  while pos<=#part do
   local index,x,z,nextPos=love.data.unpack('<I4dd',part,pos)
   assert(index>last and index<=s.count and finite(x)and finite(z),'CPU anchor data')
   last=index;list[index].frTree={x,z};seen=seen+1;assert(seen<=s.anchorCount,'CPU anchor length');pos=nextPos
   if seen%256==0 then tick()end
  end
 end
 assert(seen==s.anchorCount,'CPU anchor length');budget.used=budget.used+seen*ANCHOR_BYTES
 assert(type(s.metaDict)=='table'and #s.metaDict<=META_MAX_DICT,'CPU metadata dictionary')
 dense(s.metaDict,#s.metaDict)
 local metaBytes=0
 for _,extra in ipairs(s.metaDict)do
  assert(type(extra)=='table'and not getmetatable(extra),'CPU metadata entry')
  for k in pairs(extra)do assert(type(k)=='string'and k~='frTree','CPU metadata key')end
  local signature=metadata(extra);assert(#signature>0,'CPU empty metadata')
  metaBytes=metaBytes+#signature
 end
 assert(metaBytes<=META_MAX_BYTES and budget.used+metaBytes<=M.MAX_BYTES,'CPU metadata budget')
 budget.used=budget.used+metaBytes
 assert(finite(s.metaRunCount)and s.metaRunCount>=0 and s.metaRunCount%1==0 and s.metaRunCount<=s.count,'CPU metadata run count')
 assert(type(s.metaRuns)=='table','CPU metadata runs');dense(s.metaRuns,#s.metaRuns)
 assert(#s.metaRuns<=math.ceil(s.metaRunCount/math.floor(M.PART_BYTES/META_RUN_BYTES)),'CPU metadata run parts')
 assert(budget.used+s.metaRunCount*META_RUN_BYTES<=M.MAX_BYTES,'CPU vertex budget')
 local runCount,lastIndex=0,0
 for _,part in ipairs(s.metaRuns)do
  assert(type(part)=='string'and #part>0 and #part<=M.PART_BYTES and #part%META_RUN_BYTES==0,'CPU metadata part')
  local pos=1
  while pos<=#part do
   local first,last,id,nextPos=love.data.unpack('<I4I4I4',part,pos);pos=nextPos
   assert(first>lastIndex and last>=first and last<=s.count and s.metaDict[id],'CPU metadata range')
   local extra=s.metaDict[id]
   for i=first,last do for k,value in pairs(extra)do list[i][k]=value end;if i%256==0 then tick()end end
   lastIndex=last;runCount=runCount+1;assert(runCount<=s.metaRunCount,'CPU metadata run length')
  end
 end
 assert(runCount==s.metaRunCount,'CPU metadata run length')
 budget.used=budget.used+runCount*META_RUN_BYTES
 return list
end
function M.capture(geom,w,h,tick)
 tick=tick or function()end
 dimensions(w,h)
 local out={version=M.VERSION,w=w,h=h,fields={},heights={},streams={}}
 assert(not geom.compiledCaveImage and not geom.compiledCaveQuery,'compiled cave resource')
 assert(type(geom.heightAt)=='function','missing height query')
 local budget={used=0}
 for k,v in pairs(geom)do
  if STREAMS[k]then out.streams[k]=packStream(v,budget,tick)
  elseif k~='heightAt'then out.fields[k]=Snapshot.plain(v)end
 end
 -- FrlgMesher's non-cave height query floors coordinates after checking
 -- supportRamps. Fractional ramp cases are restored verbatim below.
 for y=0,h-1 do for x=0,w-1 do local value=geom.heightAt(x,y);assert(value==nil or finite(value),'CPU height finite');out.heights[y*w+x+1]=value end;tick()end
 return out
end
function M.restore(s,tick)
 tick=tick or function()end
 assert(s.version==M.VERSION,'geometry version')
 dimensions(s.w,s.h)
 local geom=Snapshot.plain(s.fields)
 local budget={used=0}
 assert(type(s.streams)=='table','CPU streams')
 for name,stream in pairs(s.streams)do assert(STREAMS[name]and geom[name]==nil,'CPU stream name');geom[name]=restoreStream(stream,budget,tick)end
 for k,value in pairs(s.heights)do assert(type(k)=='number'and k%1==0 and k>=1 and k<=s.w*s.h and finite(value),'CPU height data')end
 geom.heightAt=function(cx,cy)
  for _,ci in ipairs(geom.supportRamps or {})do
   if cx>=ci.x and cx<ci.x+1 and cy>=ci.z and cy<ci.z+1 then
    if ci.northEdge then local q=ci.northEdge;local t=(cy-ci.z)/q.width;if t>=1 then return ci.south end;local f=t*4;local i=math.min(4,math.floor(f)+1);return q.samples[i]+(q.samples[i+1]-q.samples[i])*(f-i+1)end
    if ci.shore16 then local i=math.floor((cy-ci.z)*16)*16+math.floor((cx-ci.x)*16)+1;return ci.shore16:sub(i,i)=='1'and ci.north or ci.south end
    return ci.north+(ci.south-ci.north)*(cy-ci.z)
   end
  end
  cx,cy=math.floor(cx),math.floor(cy)
  if cx<0 or cy<0 or cx>=s.w or cy>=s.h then return nil end
  return s.heights[cy*s.w+cx+1]
 end
 return geom
end
return M
