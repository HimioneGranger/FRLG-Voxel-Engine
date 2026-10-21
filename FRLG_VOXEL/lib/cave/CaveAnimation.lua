-- Refresh only admitted animated cave donors from live CPU native atlases.
-- Runs once in prepareFrame after the native animation step, never per eye.
-- No pixels are distributed; no GPU readback or retained staging textures.
local M={VERSION='compiled-cave-native-animation/1'}
local floor=math.floor
local function byte(v)return floor(v*255+.5)end
local function sha(s)return love.data.encode('string','hex',love.data.hash('sha256',s))end
local function tile(ts,mid)
 local slot=ts.midToSlot and ts.midToSlot[mid]
 if not slot or not ts.imageData then return nil,'missing native animation donor'end
 local cols=ts.cols or 16;local x0,y0=slot%cols*16,floor(slot/cols)*16
 local out={}
 for y=0,15 do for x=0,15 do
  local r,g,b,a=ts.imageData:getPixel(x0+x,y0+y)
  if ts.overImageData then
   local rr,gg,bb,aa=ts.overImageData:getPixel(x0+x,y0+y)
   if aa>=.5 then r,g,b,a=rr,gg,bb,aa end
  end
  if a<.5 then return nil,'transparent native animation donor'end
  out[#out+1]=string.char(byte(r),byte(g),byte(b),255)
 end end
 return table.concat(out)
end
local function token(ts,entry)
 local frames=entry and entry.frames or {}
 return table.concat({tostring(ts.imageData),tostring(ts.overImageData),tostring(ts.midToSlot),
  tostring(ts.version),tostring(entry),tostring(frames.water),tostring(frames.sand),tostring(frames.flower)},'|')
end
function M.refresh(rec,ts,entry,frame)
 local state=rec.compiledCaveAnimation
 if not state or not rec.compiledCaveImage or not ts then return false end
 if frame~=nil and state.lastFrame==frame then return false end
 state.lastFrame=frame
 if not state.animated then
  state.animated={}
  for _,d in ipairs(state.donors or {})do
   if d.required and type(d.allowedSHA256)=='table'and #d.allowedSHA256>1 then
    local allowed={[d.sha256]=true};for _,v in ipairs(d.allowedSHA256)do allowed[v]=true end
    state.animated[#state.animated+1]={mid=d.mid,x=d.x,y=d.y,allowed=allowed}
   end
  end
 end
 if #state.animated==0 then return false end
 local revision=token(ts,entry)
 if state.lastToken==revision then return false end
 state.lastToken=revision
 -- Validate the entire update before touching any GPU pixel. A changed late
 -- donor must not leave earlier donors showing a new partial native frame.
 local pending={}
 for _,d in ipairs(state.animated)do
  local rgba,why=tile(ts,d.mid)
  if not rgba then state.lastError=why;return false,why end
  local digest=sha(rgba)
  if not d.allowed[digest]then
   state.lastError='unadmitted native animation frame '..tostring(d.mid)
   return false,state.lastError
  end
  if digest~=d.lastDigest then
   pending[#pending+1]={donor=d,rgba=rgba,digest=digest}
  end
 end
 local changed=0
 for _,p in ipairs(pending)do
   local d=p.donor
   local data=love.image.newImageData(16,16,'rgba8',p.rgba)
   local ok,err=pcall(rec.compiledCaveImage.replacePixels,rec.compiledCaveImage,data,1,1,d.x,d.y,false)
   data:release()
   if not ok then state.lastError=tostring(err);return changed>0,state.lastError end
   d.lastDigest=p.digest;changed=changed+1
 end
 state.lastError=nil;state.updates=(state.updates or 0)+changed
 return changed>0
end
return M
