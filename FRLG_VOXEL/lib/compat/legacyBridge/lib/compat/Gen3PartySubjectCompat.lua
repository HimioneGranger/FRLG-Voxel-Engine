-- Engine-owned adaptation: display dimensions are world pixels, UV extents are
-- texture pixels. PMD species scale must never crop the captured sprite sheet.
local M={}
function M.snapshot(deps,cand)
 local api=deps.api();local g=love and love.graphics
 if not(api and g and g.newCanvas)then return deps.snapshot(cand)end
 local image,u0,v0,u1,v1,fw,fh,_,bottom,lift=api.cardImage(cand.key,cand.relFacing or 'down')
 if not(image and u0 and v0 and u1 and v1 and fw and fh)then return nil end
 local iw,ih=image:getDimensions()
 local tw=math.floor(math.abs(u1-u0)*iw+.5)
 local th=math.floor(math.abs(v1-v0)*ih+.5)
 if tw<1 or th<1 then return nil end
 -- Old APIs may supply a last opaque texture row, whereas Wilds supplies the
 -- display height and a separate native support-line lift. Keep both contracts.
 if lift==nil and cand.rendered and bottom then
  th=math.max(1,math.min(th,math.floor((bottom+1)/fh*th+.5)))
 end
 local texture=g.newCanvas(tw,th,{dpiscale=1})
 local quad
 local ok,why=pcall(function()
  texture:setFilter('nearest','nearest')
  quad=g.newQuad(math.min(u0,u1)*iw,math.min(v0,v1)*ih,tw,th,iw,ih)
  g.push('all')
  local drawn,err=pcall(function()
   g.setCanvas(texture);g.origin();g.setScissor();g.setShader();g.setDepthMode()
   g.clear(0,0,0,0);g.setBlendMode('replace','premultiplied');g.setColor(1,1,1,1)
   g.draw(image,quad,u1<u0 and tw or 0,v1<v0 and th or 0,0,u1<u0 and -1 or 1,v1<v0 and -1 or 1)
  end)
  g.pop();if not drawn then error(err)end
 end)
 if quad then quad:release()end
 if not ok then texture:release();return nil,why end
 local viewer=deps.viewer();local groundLift=tonumber(lift)
 local y=cand.y
 if groundLift then y=deps.ground(cand.x,cand.z)+groundLift+.16+cand.h/2 end
 return {texture=texture,owned=true,w=cand.w,h=cand.h,
  center={cand.x,y,cand.z},yaw=viewer and math.atan2(viewer[1]-cand.x,viewer[3]-cand.z)or 0,
  groundLift=groundLift}
end
function M.install(V)
 local found=V.mod and V.mod.find and V.mod.find('FRLG_CATCH')
 local lib=found and found.exports and found.exports.lib
 if not(lib and type(lib.require)=='function')then return nil,'Catch subject API unavailable'end
 local Subject=lib.require('PartySubject');local original=Subject.new
 if type(original)~='function'then return nil,'Catch subject constructor unavailable'end
 local wrapped=function(deps,entity,kind,mon)
  local adapted={};for k,v in pairs(deps)do adapted[k]=v end
  adapted.snapshot=function(cand)return M.snapshot(deps,cand)end
  local sub=original(adapted,entity,kind,mon)
  if sub and sub.groundLift then
   local update=sub.update
   sub.update=function(self,...)
    if update(self,...)==false then return false end
    if kind=='deploy'then
     local p=self.center;p[2]=deps.ground(p[1],p[3])+self.groundLift+.16+self.height/2
     self.model=deps.mat.mul(deps.mat.translate(p[1],p[2],p[3]),deps.mat.rotateY(self.yaw or 0))
    end
    return true
   end
   sub:update()
  end
  return sub
 end
 Subject.new=wrapped
 return function()if Subject.new==wrapped then Subject.new=original end end
end
return M
