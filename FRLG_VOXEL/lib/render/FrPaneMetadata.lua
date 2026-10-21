-- Reviewed native pane masks. These are positions and art identities, not a
-- palette-wide guess: beige house blue foundations must never become glass.
local M={REVISION='fr-native-panes-2'}
local specs={
 [694]={2126451128,1384987556,10,'house'},[695]={1332670795,1384987556,10,'house'},
 [701]={1336214877,1384987556,10,'house'},[703]={902050519,1384987556,10,'house'},
 [704]={1997564155,1384987556,10,'house'},
 [88]={1159435318,1735860555,16,'center'},[89]={1893611761,1384987556,16,'center'},
 [91]={1501019904,1384987556,16,'center'},[407]={1159435318,679114622,16,'center'},
 -- Complete native PC door glass; exact MID98 art, excluding its dark frame.
 [98]={280254180,1384987556,13,'center'},
 -- Lavender purple houses: glass is dark slate, also used by trim elsewhere.
 -- Reviewed local rectangles isolate the pane, including its one-row top.
 [664]={110595419,1108708088,16,'house',{9,15,13,16}},
 [665]={917194690,1384987556,16,'house',{3,15,7,16}},
 [667]={385131693,1384987556,16,'house',{9,15,13,16}},
 [668]={110595419,1386268169,16,'house',{3,15,7,16}},
 [672]={302677267,1384987556,6,'house',{9,0,13,6}},
 [673]={383222722,1384987556,6,'house',{3,0,7,6}},
 [675]={1059580598,1384987556,6,'house',{9,0,13,6}},
 [676]={573641762,1384987556,6,'house',{3,0,7,6}},
}
local function hash(t)
 local h=17;for i=1,256 do h=(h*131+(t and t[i] or -1)+1)%2147483647 end;return h
end
local function glass(v)
 if not v or v<0 then return false end
 local r,g,b=math.floor(v/65536)%256,math.floor(v/256)%256,v%256
 return b>=170 and b-r>=60 and g>=r
end
local function masks(atlas)
 local out={}
 for mid,s in pairs(specs)do
  local under,over=atlas.texels(mid,'under'),atlas.texels(mid,'over')
  if hash(under)==s[1] and hash(over)==s[2] then
   local byLayer={kind=s[4]};out[mid]=byLayer
   for _,layer in ipairs{'under','over'}do
    local fn=layer=='under' and atlas.underRect or atlas.overRect
    local u0,v0=fn(mid)
    local tex=layer=='under' and under or over
    if u0 and tex then
     local bx,bz=math.floor(u0*atlas.w/16)*16,math.floor(v0*atlas.h/16)*16
     local rects={}
     for y=0,s[3]-1 do
      local x=0
      while x<16 do
       local function on(col)
        local i=y*16+col+1
        local r=s[5]
        local pane=r and col>=r[1] and col<r[3] and y>=r[2] and y<r[4] and tex[i]==0x424a6b
        return (r and pane or not r and glass(tex[i])) and not(layer=='under' and over and over[i] and over[i]>=0)
       end
       if on(x)then local a=x;x=x+1;while x<16 and on(x)do x=x+1 end
        rects[#rects+1]={(bx+a)/atlas.w,(bz+y)/atlas.h,(bx+x)/atlas.w,(bz+y+1)/atlas.h}
       else x=x+1 end
      end
     end
     byLayer[layer]=rects
    end
   end
  end
 end
 return out
end
function M.apply(geom,input)
 local atlas=input and input.atlas
 if not(atlas and atlas.texels and atlas.underRect and atlas.overRect and atlas.w and atlas.h and input.cellAt)then return 0 end
 local reviewed=masks(atlas);local owners={}
 for _,b in ipairs(geom.stats and geom.stats.buildingInfo or{})do
  local ids={};local kind
  for y=b.minY,b.maxY do for x=b.minX,b.maxX do
   local c=input.cellAt(x,y);local match=c and reviewed[c.mid]
   if match then ids[c.mid]=match;kind=kind or match.kind end
  end end
  if kind then
   -- Even a pane family with no surviving vertical triangle must suppress
   -- the legacy broad blue-foundation detector; do not fabricate a pane.
   b.nativeLightPanes={};b.lightingPaneOverride=true
   owners[#owners+1]={b=b,ids=ids}
  end
 end
 local count=0
 for _,name in ipairs{'opaque','cutoutUnder','cutoutOver','cutoutKeyed'}do
  local layer=name=='cutoutOver' and 'over' or 'under'
  local vs=geom[name]or{}
  for i=1,#vs-2,3 do
   local a,b,c=vs[i],vs[i+1],vs[i+2]
   local ny=math.abs((a[7]or 0)+(b[7]or 0)+(c[7]or 0))
   local nx,nz=(a[6]or 0)+(b[6]or 0)+(c[6]or 0),(a[8]or 0)+(b[8]or 0)+(c[8]or 0)
   if nx*nx+nz*nz>1e-8 and ny<.25*math.sqrt(nx*nx+nz*nz) then
    local x,y,z=(a[1]+b[1]+c[1])/3,(a[2]+b[2]+c[2])/3,(a[3]+b[3]+c[3])/3
    local u0,u1=math.min(a[4],b[4],c[4]),math.max(a[4],b[4],c[4])
    local v0,v1=math.min(a[5],b[5],c[5]),math.max(a[5],b[5],c[5])
    for _,owner in ipairs(owners)do local building=owner.b
     if x>=building.minX-.15 and x<=building.maxX+1.15 and z>=building.minY-.15 and z<=building.maxY+1.15 and y>building.groundY then
      local rects={}
      for _,mask in pairs(owner.ids)do for _,r in ipairs(mask[layer]or{})do
       if u1>=r[1] and u0<=r[3] and v1>=r[2] and v0<=r[4]then rects[#rects+1]=r end
      end end
      if #rects>0 then
       building.nativeLightPanes[#building.nativeLightPanes+1]={vertices={a,b,c},layer=layer,rects=rects,maskUnits='uv'}
       count=count+1
      end
     end
    end
   end
  end
 end
 return count
end
M._masks=masks
return M
