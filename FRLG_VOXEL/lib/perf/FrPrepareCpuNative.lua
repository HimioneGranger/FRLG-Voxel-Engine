-- Read-only native CPU adapter. Actual ImageData, never fake Image/Mesh/graphics.
-- Requires WorldSource atlasFor CPU seam supplied in WorldSource.cpu.patch.
local M={VERSION=1}
function M.new(o)
 assert(o.read and o.NativePack and o.Palette and o.LayoutNative and o.WorldSource,'CPU native dependencies')
 local root=o.nativeRoot or 'data/generated/gba/native'
 local function lua(rel)local s=assert(o.read(rel),'missing '..rel);return assert(loadstring(s,'@'..rel))()end
 local manifest=lua(root..'/manifest.lua')
 local pairsByName={};local NT={}
 function NT.ready(pair)return manifest.pairs[pair]~=nil end
 function NT.get(pair)
  if pairsByName[pair]then return pairsByName[pair]end
  local folder=root..'/'..pair..'/'
  local idxBlob=assert(o.read(folder..'mids.idx'));local palBlob=assert(o.read(folder..'palettes.bin'))
  local idx=assert(o.NativePack.decodeIdx(idxBlob));local rgb,bgr=o.Palette.load(palBlob);assert(rgb,bgr)
  local function image(blob,transparent)
   local decoded=assert(o.NativePack.decodeIdx(blob))
   local rgba,w,h=o.NativePack.bakeRgba(decoded,rgb,{transparentZero=transparent})
   assert(type(rgba)=='string'and #rgba==w*h*4,'native RGBA')
   return love.image.newImageData(w,h,'rgba8',rgba)
  end
  local ts={pair=pair,cpuAtlas=true,imageData=image(idxBlob,false),idxBlob=idxBlob,bgr=bgr,
   cols=idx.atlasCols or 16,rows=idx.atlasRows or 1,midCount=idx.midCount or 0,midToSlot={},layered=false}
  for i,mid in ipairs(idx.midIds or {})do ts.midToSlot[mid]=i-1 end
  local over=o.read(folder..'mids_over.idx')
  if over then ts.overBlob=over;ts.overImageData=image(over,true);ts.layered=true end
  local animation=o.read(folder..'anim_manifest.lua')
  if animation then
   local man=assert(loadstring(animation,'@cpu-native-animation'))()
   assert(man.family~='rse','FR-only native CPU animation')
   for _,kind in ipairs{'water','sand','flower'}do local bank=man[kind]
    if bank and bank.mids and #bank.mids>0 then
     local rgba=o.read(folder..'anim_'..kind..'.rgba')
     if rgba and (bank.frames or 0)>=1 and #rgba>=#bank.mids*(bank.frames or 0)*1024 then
      for i,mid in ipairs(bank.mids)do local slot=ts.midToSlot[mid]
       if slot then local piece=love.image.newImageData(16,16,'rgba8',rgba:sub((i-1)*1024+1,i*1024))
        ts.imageData:paste(piece,(slot%ts.cols)*16,math.floor(slot/ts.cols)*16,0,0,16,16);piece:release()
       end
      end
     end
    end
   end
  end
  -- Native extraction's base indexed image is canonical before RTC paint.
  -- Animation frame-zero override banks are injected separately by caller.
  pairsByName[pair]=ts
  return ts
 end
 local maps=o.maps
 local function ensure(id,def)
  def=def or maps[id];if not def then return nil end
  if def.midLayout then return def.midLayout end
  local info=manifest.layouts[id];if not info then return nil end
  local decoded=assert(o.NativePack.decodeMidLayout(assert(o.read(root..'/'..info.file))))
  def.midLayout=o.LayoutNative.fromDecoded(decoded,id,info.pair or def.pair)
  def.width=decoded.trueWidth or decoded.width;def.height=decoded.trueHeight or decoded.height
  def.pair=info.pair or def.pair;return def.midLayout
 end
 local source=setmetatable({NativeTileset=NT,atlases=setmetatable({},{__mode='k'}),maps=maps,
  Connections=o.Connections,Interaction={behaviors=o.behaviors},CollPermissions=o.CollPermissions,
  ScriptCollision=o.ScriptCollision,yieldPoint=o.checkpoint,yieldSafe=o.checkpoint,
  signGate=o.signGate,paintFree=function()return true end},o.WorldSource)
 source.Map={ensureMidLayout=function(_,id,def)return ensure(id,def)end}
 source.game={data={maps=maps}}
 -- Prebind lightweight layout handles in the CPU worker, not on the frame
 -- thread. This preserves connected-source guards/neighbor water traversal.
 local ids={};for id in pairs(maps)do ids[#ids+1]=id end;table.sort(ids)
 for _,id in ipairs(ids)do ensure(id,maps[id]);if o.checkpoint then o.checkpoint()end end
 return {source=source,maps=maps,ensure=ensure,tilesets=pairsByName,manifest=manifest}
end
return M
