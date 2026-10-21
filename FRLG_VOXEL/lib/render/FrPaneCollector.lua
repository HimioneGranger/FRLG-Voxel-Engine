-- FireRed positions are cells; the shared Emerald light batch consumes pixels.
local M={REVISION='fr-pane-clip-1'}
local function clip(poly,axis,bound,above)
 local out={};local a=poly[#poly];if not a then return out end
 local ain=above and a[axis]>=bound or not above and a[axis]<=bound
 for _,b in ipairs(poly)do
  local bin=above and b[axis]>=bound or not above and b[axis]<=bound
  if ain~=bin then local t=(bound-a[axis])/(b[axis]-a[axis]);local v={};for k=1,5 do v[k]=a[k]+(b[k]-a[k])*t end;out[#out+1]=v end
  if bin then out[#out+1]=b end;a,ain=b,bin
 end
 return out
end
function M.clip(tri,r)
 local p={tri[1],tri[2],tri[3]}
 p=clip(p,4,r[1],true);p=clip(p,4,r[3],false);p=clip(p,5,r[2],true);return clip(p,5,r[4],false)
end
function M.append(record,tri,rects)
 local a,b,c=tri[1],tri[2],tri[3]
 local ux,uy,uz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
 local vx,vy,vz=c[1]-a[1],c[2]-a[2],c[3]-a[3]
 local nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx
 local len=math.sqrt(nx*nx+ny*ny+nz*nz)
 if len<1e-9 or math.abs(ny)/len>.1 then return 0 end
 -- Source vertex normal is authoritative for winding-independent offset.
 if a[6] and nx*a[6]+ny*a[7]+nz*a[8]<0 then nx,ny,nz=-nx,-ny,-nz end
 nx,ny,nz=nx/len,ny/len,nz/len
 local count=0
 for _,r in ipairs(rects or{})do
  local p=M.clip(tri,r)
  for j=2,#p-1 do
   local aa,bb,cc=p[1],p[j],p[j+1]
   local area=math.abs((bb[4]-aa[4])*(cc[5]-aa[5])-(bb[5]-aa[5])*(cc[4]-aa[4]))
   if area>1e-13 then
    local t={};for i,v in ipairs{aa,bb,cc}do t[i]={(v[1]+nx*.001)*16,(v[2]+ny*.001)*16,(v[3]+nz*.001)*16}end
    record.triangles[#record.triangles+1]=t;count=count+1
   end
  end
 end
 return count
end
-- Merge adjacent texels into horizontal rectangles; preserve holes exactly.
function M.texelRects(indices,w,h)
 local sorted={};for _,n in ipairs(indices or{})do sorted[#sorted+1]=n end;table.sort(sorted)
 local out={};local first,last
 local function flush()if first then local y=math.floor(first/w);out[#out+1]={first%w/w,y/h,(last%w+1)/w,(y+1)/h}end end
 for _,n in ipairs(sorted)do
  if n~=last then
   if last and n==last+1 and math.floor(n/w)==math.floor(last/w)then last=n
   else flush();first,last=n,n end
  end
 end
 flush();return out
end
return M
