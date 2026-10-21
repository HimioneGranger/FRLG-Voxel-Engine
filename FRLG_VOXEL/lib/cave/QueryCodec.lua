-- Safe cooperative decoder for literal cave query data. Never evaluates code.
-- CBZ1: independently gzip-compressed 64KiB blocks containing one CBQ1 value.
local M={VERSION='cave-query-binary/1'}
local MAX_NODES,MAX_DEPTH,MAX_STRING=16000000,64,8388608
function M.decode(packed,deps)
 assert(type(packed)=='string'and packed:sub(1,4)=='CBZ1','invalid query container')
 local outer=5
 local function outer32()
  assert(outer+3<=#packed,'truncated query container')
  local v;v,outer=deps.unpack('<I4',packed,outer);return v
 end
 local blocks=outer32();assert(blocks>0 and blocks<=65536,'invalid query block count')
 local block,position,blockNumber='',1,0
 local nodes,bytes,budgetNodes,budgetBytes=0,0,0,0
 local function checkpoint(force)
  if force or budgetNodes>=256 or budgetBytes>=32768 then
   if deps.yieldSafe then deps.yieldSafe()end
   budgetNodes,budgetBytes=0,0
  end
 end
 local function nextBlock()
  assert(blockNumber<blocks,'truncated query data')
  local rawLength,length=outer32(),outer32()
  assert(rawLength>0 and rawLength<=65536 and length>0 and outer+length-1<=#packed,'invalid query block extent')
  checkpoint(true)
  block=deps.inflate(packed:sub(outer,outer+length-1));outer=outer+length
  assert(type(block)=='string'and #block==rawLength,'invalid query inflated extent')
  blockNumber,position=blockNumber+1,1
 end
 local function take(n)
  assert(n>=0 and n<=MAX_STRING,'invalid query read')
  local out={}
  while n>0 do
   if position>#block then nextBlock()end
   local count=math.min(n,#block-position+1)
   out[#out+1]=block:sub(position,position+count-1)
   n=n-count;position=position+count;bytes=bytes+count;budgetBytes=budgetBytes+count
  end
  return table.concat(out)
 end
 local function number(format,size)
  if position+size-1>#block then return(deps.unpack(format,take(size)))end
  local v;v,position=deps.unpack(format,block,position)
  bytes,budgetBytes=bytes+size,budgetBytes+size
  return v
 end
 assert(take(4)=='CBQ1','invalid query value schema')
 local strings={}
 local value
 value=function(depth)
  assert(depth<=MAX_DEPTH,'query nesting limit')
  nodes,budgetNodes=nodes+1,budgetNodes+1;assert(nodes<=MAX_NODES,'query node limit')
  checkpoint(false)
  local tag=number('<I1',1)
  if tag==0 then return nil
  elseif tag==1 then return false
  elseif tag==2 then return true
  elseif tag==3 then
   local v=number('<d',8);assert(v==v and math.abs(v)<math.huge,'invalid query number');return v
  elseif tag==4 then
   local n=number('<I4',4);assert(n<=MAX_STRING,'query string limit')
   local s=take(n);strings[#strings+1]=s;return s
  elseif tag==7 then
   return assert(strings[number('<I4',4)],'invalid query string reference')
  elseif tag==5 or tag==6 then
   local n=number('<I4',4);assert(n<=MAX_NODES-nodes,'query table limit')
   local t={}
   for i=1,n do
    if tag==5 then t[i]=value(depth+1)
    else
     local k=value(depth+1);assert(type(k)=='string'or type(k)=='number','invalid query key')
     assert(t[k]==nil,'duplicate query key');t[k]=value(depth+1)
    end
   end
   return t
  end
  error('invalid query tag')
 end
 local result=value(0)
 assert(blockNumber==blocks and position==#block+1 and outer==#packed+1,'extra query data')
 assert(type(result)=='table','query root must be a table')
 checkpoint(true)
 return result,{nodes=nodes,bytes=bytes,blocks=blocks}
end
return M
