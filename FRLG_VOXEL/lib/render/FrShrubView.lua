-- Native FireRed shrubs. Emerald rig-facing semantics, one frame for both eyes.
local V=...
local M={TRACK_HEAD=false}
local rows={"0000001111000000","0000111111110000","0001111111111000","0011111111111100","0011111111111100","0111111111111110","0111111111111110","0111111111111110","0111111111111110","0111111111111110","0111111111111110","0011111111111100","0001111111111000"}
local mask,shader
local fallbackFace={0,0,0,1}
function M.basis(cam,out)
 out=out or {}
 if cam.mode=='overview' and not cam.seat then local y=cam.yaw or 0;out[1],out[2],out[3],out[4]=0,0,math.sin(y),math.cos(y);return out end
 local x,z=cam.x or 0,cam.z or 0
 if cam.eyeWorld then local ex,ey,ez=cam:eyeWorld(nil);x,z=ex,ez end
 out[1],out[2],out[3],out[4]=x,z,0,0;return out
end
function M.place(f,ax,az,x,z)
 local fx,fz=f[3],f[4]
 if fx*fx+fz*fz<=.5 then local dx,dz=f[1]-ax,f[2]-az;local d=dx*dx+dz*dz;if d>1e-6 then local q=1/math.sqrt(d);fx,fz=dx*q,dz*q else fx,fz=0,1 end end
 return ax+fz*(x-ax)+fx*(z-az),az-fx*(x-ax)+fz*(z-az)
end
function M.get(S)
 if not S.frShrubReleaseHook then
  local old=S.release;S.release=function(...)if mask then mask:release();mask=nil end;shader=nil;return old(...)end;S.frShrubReleaseHook=true
 end
 if shader then return shader end
 if not mask then local d=love.image.newImageData(16,16);for y,row in ipairs(rows)do for x=1,16 do if row:sub(x,x)=='1'then d:setPixel(x-1,y,1,1,1,1)end end end;mask=love.graphics.newImage(d,{linear=true,mipmaps=false});d:release();mask:setFilter('nearest','nearest')end
 local src,n=S.CUTOUT:gsub('attribute vec3 VertexNormal;',[[attribute vec3 VertexNormal;
attribute highp vec3 VertexShrub;
attribute highp vec2 VertexShrubUV;
uniform highp vec4 u_frShrubFace;
varying highp vec3 v_frShrubUV;]])
 assert(n==1,'shrub declaration')
 src,n=src:gsub('  v_uv = VertexTexCoord.xy;',[[  highp vec2 f=u_frShrubFace.zw;
  if(dot(f,f)<=0.5){highp vec2 d=u_frShrubFace.xy-VertexShrub.xy;highp float q=dot(d,d);f=q>0.000001?d*inversesqrt(q):vec2(0.0,1.0);}
  if(VertexShrub.z<1.5)vertex_position.xz=VertexShrub.xy+vec2(f.y,-f.x)*(vertex_position.x-VertexShrub.x);
  v_frShrubUV=vec3(VertexShrubUV,VertexShrub.z);
  v_uv = VertexTexCoord.xy;]])
 assert(n==1,'shrub rotation')
 src,n=src:gsub('mediump vec3 n = grassNormal / len;', 'mediump vec3 n = VertexShrub.z<1.5?vec3(f.x,0.0,f.y):vec3(0.0,1.0,0.0);');assert(n==1,'shrub facingnormal')
 src,n=src:gsub('uniform mediump float u_alphaCut;',[[uniform mediump float u_alphaCut;
uniform Image u_frShrubMask;
varying highp vec3 v_frShrubUV;]])
 assert(n==1,'shrub maskuniform')
 src,n=src:gsub('  mediump vec4 c = TEX_HI%(tex, v_uv%) %* color;',[[  highp vec2 pixel=clamp(floor(v_frShrubUV.xy*16.0),vec2(0.0),vec2(15.0));
  highp float leaf=TEX_HI(u_frShrubMask,(pixel+vec2(0.5))/16.0).a;
  if(v_frShrubUV.z<1.5 && leaf<0.5)discard;
  if(v_frShrubUV.z>1.5 && leaf>0.5)pixel=vec2(0.0);
  highp vec2 origin=floor(v_uv*u_texSize/16.0)*16.0;
  highp vec2 nativeUV=(origin+pixel+vec2(0.5))/u_texSize;
  mediump vec4 c = TEX_HI(tex,nativeUV)*color;]])
 assert(n==1,'shrub nativepixels')
 S.FR_SHRUB_CUTOUT=src;shader=assert(S.get('FR_SHRUB_CUTOUT'));S.send(shader,'u_frShrubMask',mask);return shader
end
function M.upload(rec,cards,S)
 rec.shrubCards=cards
 if not cards or #cards==0 then return end
 M.get(S) -- Compile/upload during loading, never first gameplay draw.
 local verts,attrs={},{}
 local order={1,2,3,1,3,4}
 for _,c in ipairs(cards)do
  assert(#c==7,'shrub descriptor')
  local x,z,h=c[1],c[2],c[3]
  local points={{x-.5,h+14/16,z,c[4],c[5],0,0},{x+.5,h+14/16,z,c[6],c[5],1,0},{x+.5,h-2/16,z,c[6],c[7],1,1},{x-.5,h-2/16,z,c[4],c[7],0,1}}
  for _,k in ipairs(order)do local a=points[k];verts[#verts+1]={a[1],a[2],a[3],a[4],a[5],0,0,1};attrs[#attrs+1]={x,z,1,a[6],a[7]}end
  local ground={{x-.5,h,z-.5,c[4],c[5],0,0},{x+.5,h,z-.5,c[6],c[5],1,0},{x+.5,h,z+.5,c[6],c[7],1,1},{x-.5,h,z+.5,c[4],c[7],0,1}}
  for _,k in ipairs(order)do local a=ground[k];verts[#verts+1]={a[1],a[2],a[3],a[4],a[5],0,1,0};attrs[#attrs+1]={x,z,2,a[6],a[7]}end
 end
 local mesh=love.graphics.newMesh(S.FORMAT,verts,'triangles','static');rec.shrubMesh=mesh
 local ok,attr=pcall(love.graphics.newMesh,{{'VertexShrub','float',3},{'VertexShrubUV','float',2}},attrs,'triangles','static');if not ok then M.release(rec);error(attr)end;rec.shrubAttr=attr
 local attached,err=pcall(function()mesh:attachAttribute('VertexShrub',attr);mesh:attachAttribute('VertexShrubUV',attr)end);if not attached then M.release(rec);error(err)end
end
function M.release(rec)
 if rec.shrubMesh then rec.shrubMesh:release();rec.shrubMesh=nil end
 if rec.shrubAttr then rec.shrubAttr:release();rec.shrubAttr=nil end
end
local facebuf={0,0,0,0}
function M.draw(scene,S,env,counters,bind)
 local active=false;for _,r in ipairs(scene.visible or{})do if r.shrubMesh then active=true;break end end;if not active then return end
 local sh=M.get(S);love.graphics.setShader(sh);S.frame(sh,env,.5)
 local f=scene.shrubFace or fallbackFace
 for _,r in ipairs(scene.visible or{})do if r.shrubMesh then
  bind(scene,sh,r,env);S.ao(sh,false);S.emissive(sh,nil)
  facebuf[1],facebuf[2],facebuf[3],facebuf[4]=f[1]-r.ox,f[2]-r.oz,f[3],f[4];S.send(sh,'u_frShrubFace',facebuf)
  local tex=r.liveTex;if tex then if r.shrubMesh:getTexture()~=tex then r.shrubMesh:setTexture(tex)end;S.texSize(sh,tex);love.graphics.draw(r.shrubMesh);counters.calls=counters.calls+1;counters.tris=counters.tris+#r.shrubCards*4 end
 end end
end
return M

