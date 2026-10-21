-- Exact native draw snapshot -> external billboard. Never owns spawn/capture state.
local M={}
function M.snapshot(p)
 if not p or not p.image or not p.quad then return nil end
 if (p.rotation or 0)~=0 then return nil,'rotated native card requires render-to-texture' end
 local u,v,w,h=p.quad:getViewport();local iw,ih=p.image:getDimensions()
 local sx,sy=p.sx or 1,p.sy or 1
 if sx==0 or sy==0 then return nil end
 local x0=p.x-(p.ox or 0)*sx;local x1=x0+w*sx
 local y0=p.y-(p.oy or 0)*sy;local y1=y0+h*sy
 local c=p.color or{1,1,1,1}
 return {image=p.image,u0=(sx<0 and u+w or u)/iw,u1=(sx<0 and u or u+w)/iw,
 v0=(sy<0 and v+h or v)/ih,v1=(sy<0 and v or v+h)/ih,
 centerX=(x0+x1)/2,bottom=math.max(y0,y1),width=math.abs(w*sx),height=math.abs(h*sy),
 color={c[1]or 1,c[2]or 1,c[3]or 1,c[4]or 1}}
end
function M.card(a,opts)
 opts=opts or{};local renderer=a.renderer
 if not renderer or type(renderer.vrSnapshot)~='function'then return nil,'no native snapshot' end
 local first=renderer:vrSnapshot(a.x,a.y,0,0,a.facing,a.walkPhase or 0,false)
 local anchorX=first and first.groundX or a.x+8
 local anchorZ=first and first.groundZ or a.y+8
 local firstPose=M.snapshot(first)
 local r={key=opts.key,kind=opts.kind or a.kind,provider='wilds_of_hoenn',catchable=opts.catchable==true,
 x=anchorX/16,z=anchorZ/16,nativeOffsetX=firstPose and(firstPose.centerX-anchorX)/16 or 0,facing=a.facing,nativePixelScale=true,shadow=opts.shadow==nil and 1 or opts.shadow,nativeActor=a}
 r.pose=function(record,facing)
  if opts.alive and not opts.alive()then return nil end
  local raw=renderer:vrSnapshot(a.x,a.y,0,0,facing or a.facing,a.walkPhase or 0,false)
  local p=M.snapshot(raw);if not p then return nil end
  -- CleanScene passes a projected copy. Update that rendered record, not the
  -- captured logical source, so transparent frame padding cannot raise feet.
  record=record or r
  record.liftPx=(raw.groundY or a.y+16)-p.bottom;record.color=p.color
  return p.image,p.u0,p.v0,p.u1,p.v1,p.width,p.height,p.height-1,1,p.color
 end
 return r
end
function M.collect(raw,opts)
 opts=opts or{};local out,seen={},{}
 for _,a in ipairs(raw or{})do
  -- The provider's tile-snapped 2D feet cover is not an actor body. Turning
  -- it into an upright action card makes grass appear to travel with a mon.
  -- Native planted grass owns 3D cover/reaction; keep the source 2D effect.
  if a.kind~='field_effect_wild_grass'then
  -- Caller provides only this provider's native collector output, including
  -- Follower.actor() once. Companion roles share that body, not a second one.
  local identity=opts.identity and opts.identity(a)or a
  if not seen[identity]then
   seen[identity]=true
   local config={};if opts.options then config=opts.options(a) end
   if config~=false then
    local card,why
    if type(a.draw)=='function'and opts.actionCards then card,why=opts.actionCards:card(a,M,config)else card,why=M.card(a,config)end
    if card then out[#out+1]=card elseif opts.onUnsupported then opts.onUnsupported(a,why)end
   end
  end
 end
 end
 return out
end
return M


