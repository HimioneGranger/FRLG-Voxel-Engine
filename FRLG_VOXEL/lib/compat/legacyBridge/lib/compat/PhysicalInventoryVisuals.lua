-- Metre-scale physical storage. Shared meshes; no resource creation per eye.
local M={}
local function part(c)return {vertices={},indices={},material={color=c,surface={.7,.08}}}end
local function tri(p,a,b,c)
 local u,v={b[1]-a[1],b[2]-a[2],b[3]-a[3]},{c[1]-a[1],c[2]-a[2],c[3]-a[3]}
 local n={u[2]*v[3]-u[3]*v[2],u[3]*v[1]-u[1]*v[3],u[1]*v[2]-u[2]*v[1]}
 local l=math.sqrt(n[1]^2+n[2]^2+n[3]^2);if l<1e-10 then return end
 for _,vtx in ipairs({a,b,c})do
  p.vertices[#p.vertices+1]={vtx[1],vtx[2],vtx[3],vtx[4]or 0,vtx[5]or 0,1,n[1]/l,n[2]/l,n[3]/l}
  p.indices[#p.indices+1]=#p.vertices
 end
end
local function quad(p,a,b,c,d)tri(p,a,b,c);tri(p,a,c,d)end
local function box(p,x,y,z,w,h,d)
 local a={x-w/2,y-h/2,z+d/2};local b={x+w/2,y-h/2,z+d/2}
 local c={x+w/2,y+h/2,z+d/2};local e={x-w/2,y+h/2,z+d/2}
 local f={x-w/2,y-h/2,z-d/2};local g={x+w/2,y-h/2,z-d/2}
 local k={x+w/2,y+h/2,z-d/2};local l={x-w/2,y+h/2,z-d/2}
 quad(p,a,b,c,e);quad(p,g,f,l,k);quad(p,f,a,e,l);quad(p,b,g,k,c);quad(p,e,c,k,l);quad(p,f,g,b,a)
end
local function lathe(p,rings,n)
 for j=1,#rings-1 do for i=0,n-1 do
  local function v(k,r)return {math.cos(k/n*math.pi*2)*r[2],r[1],math.sin(k/n*math.pi*2)*r[2]}end
  quad(p,v(i,rings[j]),v(i,rings[j+1]),v(i+1,rings[j+1]),v(i+1,rings[j]))
 end end
end
function M.build(kind,open)
 local parts={};local function add(c)local p=part(c);parts[#parts+1]=p;return p end
 if kind=='tm_case' then
  local shell=add({.14,.27,.46,1});box(shell,0,0,0,.19,.025,.14)
  local lining=add({.025,.038,.055,1});box(lining,0,.016,0,.173,.009,.123)
  local lid=add({.20,.39,.64,1});box(lid,0,open and .083 or .026,open and -.061 or 0,.19,open and .14 or .012,open and .012 or .14)
  local latch=add({.75,.78,.80,1});box(latch,0,.021,.072,.027,.017,.008)
  if open then
   local slots=add({.48,.57,.64,1})
   for i=-2,2 do box(slots,i*.029,.023,-.022,.023,.003,.050)end
  end
 elseif kind=='berry_pouch' then
  local fabric=add({.65,.29,.12,1})
  lathe(fabric,{{-.065,0},{-.063,.038},{-.05,.057},{0,.066},{.038,.047},{.046,.038}},24)
  local seam=add({.24,.11,.05,1});lathe(seam,{{.041,.037},{.049,.043},{.054,.037},{.054,.030},{.043,.030}},24)
  local cord=add({.90,.70,.32,1});box(cord,0,.038,.050,.036,.006,.008)
 elseif kind=='sd' then
  local card=add({.06,.08,.12,1});box(card,0,0,0,.048,.004,.063)
  local sticker=add({.16,.56,.82,1});box(sticker,0,.0028,.006,.038,.001,.035)
  local pins=add({.91,.68,.20,1});for i=-3,3 do box(pins,i*.005,.0027,-.024,.003,.001,.012)end
 elseif kind=='usb' then
  local drive=add({.14,.34,.59,1});box(drive,0,0,.010,.033,.013,.052)
  local plug=add({.68,.72,.74,1});box(plug,0,0,-.026,.026,.009,.020)
  local holes=add({.035,.045,.05,1});for _,x in ipairs({-.007,.007})do box(holes,x,.005,-.027,.005,.001,.007)end
 elseif kind=='ports' then
  local panel=add({.16,.20,.23,1});box(panel,0,0,0,.010,.013,.114)
  local rim=add({.40,.62,.73,1});box(rim,-.006,0,-.035,.002,.008,.052);box(rim,-.006,0,.035,.002,.010,.030)
  local slot=add({.008,.012,.016,1});box(slot,-.0072,0,-.035,.001,.004,.049);box(slot,-.0072,0,.035,.001,.006,.027)
 elseif kind=='mist' then
  local p=add({.76,.88,1,.28});p.material.surface=nil
  lathe(p,{{-.5,0},{-.35,.35},{0,.5},{.35,.35},{.5,0}},8)
 end
 return {parts=parts,grip={left={0,-.018,-.055},right={0,-.018,-.055}}}
end
return M
