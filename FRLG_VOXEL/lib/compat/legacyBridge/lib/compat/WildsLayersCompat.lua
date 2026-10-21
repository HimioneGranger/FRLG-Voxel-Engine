-- VRITK-only adapter for Wilds171's second (foam) draw. No canvas or shadow pass.
-- Body records keep capture ownership. A pooled decorative record draws the foam.
local M={}
local installed
local function snapshot(body,scratch,facing)
 local e=body._e
 local a=body.nativeActor
 local r,x,y,walk
 if a then r,x,y,walk=a.renderer,a.x,a.y,a.walkPhase
 elseif e then r,x,y,walk=e.renderer,e.px,e.py,body._walk
 else r,x,y,walk=body._r,body._px,body._py,0 end
 if not(r and type(r.vrSnapshotInto)=='function')then return nil end
 return r:vrSnapshotInto(scratch,x or 0,y or 0,0,0,facing or body.facing,walk or 0,false)
end
local function layerPose(st,record,facing)
 local b=st.body
 -- The original guard controls hiding, provider switches and retired identities.
 if not b.pose(b,facing)then return nil end
 local p=b._snap or b._wildsSnap or snapshot(b,st.snap,facing)
 if not p or p.extraLayerCount~=1 then return nil end
 local q=p and p.extraLayers and p.extraLayers[1]
 if not(q and q.image and q.quad)or(q.rotation or 0)~=0 then return nil end
 local u,v,w,h=q.quad:getViewport();local iw,ih=q.image:getDimensions()
 local sx,sy=q.sx or 1,q.sy or q.sx or 1
 if iw<=0 or ih<=0 or sx==0 or sy==0 then return nil end
 local bottom=math.max(q.y-(q.oy or 0)*sy,q.y-(q.oy or 0)*sy+h*sy)
 local width,height=math.abs(w*sx),math.abs(h*sy)
 local lift=(q.groundY or p.groundY or q.y+h*sy)-bottom
 local sc=1
 local gi=st.adapter and st.adapter.GrowIn
 if gi and b._e then sc=gi.scale(b._e)end
 record=record or st.rec
 local _,_,_,bh=p.quad:getViewport()
 local bsy=p.sy or p.sx or 1
 local by=p.y-(p.oy or 0)*bsy
 local bodyLift=(p.groundY or p.y+bh*bsy)-math.max(by,by+bh*bsy)
 -- Reuse the body's bob/grow-in displacement so the foam cannot detach.
 record.liftPx=lift*sc+((b.liftPx or bodyLift*sc)-bodyLift*sc)
 local c=st.color;local qc=q.color
 c[1],c[2],c[3],c[4]=qc and qc[1]or q.r or 1,qc and qc[2]or q.g or 1,qc and qc[3]or q.b or 1,qc and qc[4]or q.a or 1
 return q.image,(sx<0 and u+w or u)/iw,(sy<0 and v+h or v)/ih,
  (sx<0 and u or u+w)/iw,(sy<0 and v or v+h)/ih,width*sc,height*sc,height*sc-1,1,c
end
local function append(pool,out,adapter)
 pool.frame=pool.frame+1
 local cards,frame=pool.cards,pool.frame
 local count=#out
 -- Native host caps eight wilds plus follower; foam never becomes a target.
 for i=1,math.min(count,9)do
  local b=out[i]
  local st=cards[b]
  if not st then
   st={body=b,snap={},color={1,1,1,1},adapter=adapter}
   local rec={provider='wilds_of_hoenn',kind='wilds_foam',shadow=false,catchable=false,
    nativePixelScale=b.nativePixelScale,liftScaled=b.liftScaled}
   st.rec=rec;rec.pose=function(record,facing)return layerPose(st,record,facing)end
   cards[b]=st
  end
  st.seen=frame
  local p=b._snap or b._wildsSnap or snapshot(b,st.snap,b.facing)
  if p and p.extraLayerCount==1 and p.extraLayers and p.extraLayers[1]then
   local rec=st.rec
   rec.x,rec.z,rec.facing,rec.nativeOffsetX=b.x,b.z,b.facing,b.nativeOffsetX
   out[#out+1]=rec
  end
 end
 for b,st in pairs(cards)do if st.seen~=frame then cards[b]=nil end end
 return out
end
function M.install(ctx)
 if installed then return true end
 local s={};installed=s
 local adapter=ctx and ctx.adapter
 if adapter and type(adapter.new)=='function'then
  s.adapter,s.prevNew=adapter,adapter.new
  s.new=function(...)
   local a=s.prevNew(...);local collect=a.collect
   local pool={cards={},frame=0}
   a.collect=function(self,...)
    local out=collect(self,...)
    if installed==s then return append(pool,out,adapter)end
    return out
   end
   return a
  end
  adapter.new=s.new
 end
 local visuals=ctx and ctx.visuals
 if visuals and type(visuals.collectPooled)=='function'then
  s.visuals,s.prevCollect=visuals,visuals.collectPooled
  local pools=setmetatable({},{__mode='k'})
  s.collect=function(pool,out,...)
   local result=s.prevCollect(pool,out,...)
   if installed~=s then return result end
   local layers=pools[pool]
   if not layers then layers={cards={},frame=0};pools[pool]=layers end
   return append(layers,result,nil)
  end
  visuals.collectPooled=s.collect
 end
 return true
end
function M.uninstall()
 local s=installed;if not s then return end
 if s.adapter and s.adapter.new==s.new then s.adapter.new=s.prevNew end
 if s.visuals and s.visuals.collectPooled==s.collect then s.visuals.collectPooled=s.prevCollect end
 installed=nil
end
return M
