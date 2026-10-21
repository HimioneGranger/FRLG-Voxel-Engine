-- FRLG_VOXEL / interiors team: props/Healer.lua -- the Pokemon Center healing
-- machine (wave 1, 2026-10-01; scout INVENTORY "Healing machine", PLAN Q3).
--
-- Today the machine is a picture on the 2.0-tall back-wall block (metatiles
-- 682 683 / 690 691 of the Pokemon Center tileset, a 2 x 2 block in the back
-- wall's rows 1-2, the counter in front of it). This type takes the four wall
-- cells out of the wall run and stands the machine on the floor behind the
-- counter, on the art's own 2 x 2 footprint. Version 0.2 reconstructs the
-- six-pad tray horizontally with raised native casing and a rear console;
-- the shared relief builder supplies atlas clipping and winding (props/Relief.lua: method after pokeemerald-3Ds-dualscreen,
-- ZallaxDev, MIT -- the licence text is in Relief.lua's header). No code or
-- data of that project is copied here; every texel is the player's own
-- ROM-extracted art read through the atlas. The core closes the wall behind
-- the machine itself: the run left above the machine gets its own south face
-- in the room's wallpaper, and the wall cells beside the alcove get their
-- side faces (checked offline, see RESULTS.md).
-- Known side effect of taking cells out of a wall run (core, not this file):
-- the core's wallpaper pick counts wall-run bottoms, and the healer columns
-- were two of its candidates, so the room's wallpaper pick changes; the wall
-- caps above the machine and the shell's ceilY over its cells change too.
-- Reported to the coordinator (RESULTS.md, Requests).
--
-- User defaults (scout PLAN Q1 / Q3), one constant each:
--   H_MACHINE   real-life height of the machine (cells; 1 cell = 1.6 m)
--   PULL_OUT    false = leave the machine painted on the wall (type off)
-- No globals, no debug / package / io (mod sandbox); state lives on ts only.
local V = ...
local _ = V

local T = {
  id = "Healer", version = "healer 0.2 native FR docking tray (2026-10-04)",
  walkable = false,
  maxWalkH = 0.56,
  walls = true,        -- the machine's four cells are back-wall cells
  heightAt = false,
  supersedes = {},
  budget = 400,
  sourceMids = nil,
  stretchedAllowed = 0,
  windingExempt = 0,
}

-- ------------------------------------------------------------------ constants
T.H_MACHINE = 1.25      -- 2.0 m: the machine stands 0.6 cell over the 0.65 counter
                        -- (Zallax's art-row height would be 1.5 = 2.4 m; scout Q1)
T.PULL_OUT = true       -- user default Q3: out of the wall, wall closed behind it
T.PAIR = "network"      -- the Pokemon Center tileset (metatile ids >= 640 are per tileset)
T.NW, T.NE, T.SW, T.SE = 682, 683, 690, 691   -- the 2 x 2 art block
local function isBlock(ctx, x, y)
  local a, b, c, d = ctx:at(x, y), ctx:at(x + 1, y), ctx:at(x, y + 1), ctx:at(x + 1, y + 1)
  if a and b and c and d and a.mid == T.NW and b.mid == T.NE and c.mid == T.SW and d.mid == T.SE
    and a.role == "wall" and b.role == "wall" and c.role == "wall" and d.role == "wall" then
    return a, b, c, d
  end
  return nil
end

function T.applies(ctx, idx)
  return T.PULL_OUT and idx.pair == T.PAIR and idx.byMid[T.NW] ~= nil
end

-- PURE: every 2 x 2 healer block standing in a wall run, row-major per block
function T.match(ctx, idx)
  local out = {}
  for _, c in ipairs(idx.byMid[T.NW] or {}) do
    local a, b, s, e = isBlock(ctx, c.x, c.y)
    if a then
      out[#out + 1] = a; out[#out + 1] = b; out[#out + 1] = s; out[#out + 1] = e
    end
  end
  return out
end

-- the blocks whose four cells were all granted: { x, y } of the NW cell
local function blocks(ctx, ts)
  local out = {}
  for _, c in ipairs(ts.cells) do
    if c.mid == T.NW then
      local b, s, e = ctx:at(c.x + 1, c.y), ctx:at(c.x, c.y + 1), ctx:at(c.x + 1, c.y + 1)
      if ts.cellSet[b] and ts.cellSet[s] and ts.cellSet[e] then out[#out + 1] = { x = c.x, y = c.y } end
    end
  end
  return out
end

function T.classify(ctx, cells, ts)
  local list = blocks(ctx, ts)
  for _, k in ipairs(list) do
    -- each cell out of its wall run (role ext: the core draws the ground only)
    for dy = 0, 1 do
      for dx = 0, 1 do ctx:claim(k.x + dx, k.y + dy, nil, T.H_MACHINE) end
    end
  end
  ts.blocks = list
end

-- Native FR artwork reconstruction. Exact source anatomy/provenance is recorded
-- in gen3-healer-20261004/art-review/ART_REVIEW.md. No Emerald texture or mesh.
-- All coordinates below are local pixels (16 px/cell). R._face clips every
-- source polygon at atlas cell borders and preserves winding/over-layer rules.
local UP, DOWN = {0,1,0}, {0,-1,0}
local SOUTH, NORTH, EAST, WEST = {0,0,1}, {0,0,-1}, {1,0,0}, {-1,0,0}
local function jobFor(ctx, g, under, over)
  return { ctx=ctx, env=ctx.env, newV=ctx:newVfn(), g=g,
    under=under, over=over, isVoid=ctx.env.atlas and ctx.env.atlas.isVoid,
    hasOver=ctx.env.midHasOver, face="native-healer",
    stats={tris=0,under=0,over=0,skippedVoid=0,faces={},tag="healer"} }
end
local function emit(R, job, k, points, normal)
  local poly={}
  for i,p in ipairs(points) do
    poly[i]={k.x*16+p[1],p[2],k.y*16+p[3],k.x*16+p[4],k.y*16+p[5]}
  end
  R._face(job,poly,normal,0)
end
-- Rectangle UV is kept 1:1. Larger hidden casing faces repeat a bounded strip
-- from this machine's own grey/white flank, without repeating pads or monitors.
local function tiled(R,job,k,S,T,source,xyz,normal)
  local sw,sh=source[3]-source[1],source[4]-source[2]
  local s=0
  while s<S-1e-9 do
    local sn=math.min(S,s+sw);local t=0
    while t<T-1e-9 do
      local tn=math.min(T,t+sh);local p={}
      for _,q in ipairs({{s,t},{sn,t},{sn,tn},{s,tn}}) do
        local X,Y,Z=xyz(q[1],q[2])
        p[#p+1]={X,Y,Z,source[1]+q[1]-s,source[2]+q[2]-t}
      end
      emit(R,job,k,p,normal);t=tn
    end
    s=sn
  end
end
local function top(R,job,k,a,b,z0,z1,h,u,v)
  emit(R,job,k,{{a,h,z0,u,v},{b,h,z0,u+b-a,v},
    {b,h,z1,u+b-a,v+z1-z0},{a,h,z1,u,v+z1-z0}},UP)
end
local EDGE_SRC={1,23,9,28} -- own white/grey casing; no cross, floor or wallpaper
local function vertical(R,job,k,a,b,z0,z1,h0,h1,axis,normal)
  if axis=="x" then
    tiled(R,job,k,z1-z0,h1-h0,EDGE_SRC,function(s,t)return a,h1-t,z0+s end,normal)
  else
    tiled(R,job,k,b-a,h1-h0,EDGE_SRC,function(s,t)return a+s,h1-t,z0 end,normal)
  end
end
local function machine(R,job,k)
  local back,front,tray=9,26,14 -- back .5625, front1.625, tray .875
  -- Closed pedestal; source cross appears once on the upper front. Native
  -- row28 dark base stays at the floor; room coral rows29..31 are excluded.
  vertical(R,job,k,1,31,back,back,0,tray,"z",NORTH)
  vertical(R,job,k,1,1,back,front,0,tray,"x",WEST)
  vertical(R,job,k,31,31,back,front,0,tray,"x",EAST)
  tiled(R,job,k,30,17,EDGE_SRC,function(s,t)return 1+s,0,back+t end,DOWN)
  tiled(R,job,k,30,8,EDGE_SRC,function(s,t)return 1+s,9-t,front end,SOUTH)
  emit(R,job,k,{{1,14,front,1,23},{31,14,front,31,23},
    {31,9,front,31,28},{1,9,front,1,28}},SOUTH)
  emit(R,job,k,{{1,1,front,1,28},{31,1,front,31,28},
    {31,0,front,31,29},{1,0,front,1,29}},SOUTH)
  -- Tray rows9..23 become true horizontal depth12..26. Gold and white
  -- casing are one/two pixels above the purple bed, with closed step faces.
  local bands={{1,6,16},{6,9,15},{9,23,14},{23,26,15},{26,31,16}}
  -- Three-pixel rear shoulder between console's back and tray's drawn rear.
  tiled(R,job,k,30,3,EDGE_SRC,function(s,t)return 1+s,14,9+t end,UP)
  for _,b in ipairs(bands) do
    local a,c,h=b[1],b[2],b[3]
    top(R,job,k,a,c,12,26,h,a,9)
    if h>14 then
      vertical(R,job,k,a,c,12,12,14,h,"z",NORTH)
      vertical(R,job,k,a,c,26,26,14,h,"z",SOUTH)
    end
  end
  for i=1,#bands-1 do
    local a,b=bands[i],bands[i+1]
    if a[3]~=b[3] then
      vertical(R,job,k,a[2],a[2],12,26,math.min(a[3],b[3]),math.max(a[3],b[3]),
        "x",a[3]>b[3] and EAST or WEST)
    end
  end
  vertical(R,job,k,1,1,12,26,14,16,"x",WEST)
  vertical(R,job,k,31,31,12,26,14,16,"x",EAST)
  -- Rear console: front v3..9 is six pixels tall, with blue monitors once.
  -- Top v0..3 preserves its stepped native outline, not wallpaper corners.
  emit(R,job,k,{{7,20,12,7,3},{25,20,12,25,3},
    {25,14,12,25,9},{7,14,12,7,9}},SOUTH)
  local widths={{9,23},{8,24},{7,25}}
  for i,w in ipairs(widths) do
    local z=8+i
    top(R,job,k,w[1],w[2],z,z+1,20,w[1],i-1)
    vertical(R,job,k,w[1],w[1],z,z+1,14,20,"x",WEST)
    vertical(R,job,k,w[2],w[2],z,z+1,14,20,"x",EAST)
    if i==1 then vertical(R,job,k,w[1],w[2],z,z,14,20,"z",NORTH)
    else
      local prev=widths[i-1]
      vertical(R,job,k,w[1],prev[1],z,z,14,20,"z",NORTH)
      vertical(R,job,k,prev[2],w[2],z,z,14,20,"z",NORTH)
    end
  end
end
function T.props(ctx, ts)
  local R=ts.lib.Relief
  local under,over=ctx:buffer("opaque"),ctx:buffer("over")
  local anchors={}
  local startUnder=#under
  ts.healerFR=nil -- never publish stale/partial metadata
  for _,k in ipairs(ts.blocks or {}) do
    local foot=ctx:at(k.x,k.y+1);local g=foot.hgt or 0
    local job=jobFor(ctx,g,under,over)
    machine(R,job,k)
    assert(job.stats.skippedVoid==0,"native healer missing atlas art")
    assert(job.stats.tris<=T.budget,"native healer exceeds triangle budget")
    for _,v in ipairs({{13,12},{19,12},{13,16},{19,16},{13,20},{19,20}}) do
      local radius=2/16
      anchors[#anchors+1]={k.x+v[1]/16,g+14/16+radius+.002,
        k.y+(12+v[2]-9)/16,radius}
    end
  end
  -- One supported machine per native center. Multiple blocks fail closed for
  -- effects metadata while their source furniture remains drawn normally.
  if #anchors==6 and #under>startUnder then
    ts.healerFR={kind="frlg-native-healer-v1",anchors=anchors,released=false}
  end
end
return T
