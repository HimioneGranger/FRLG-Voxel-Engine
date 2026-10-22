-- Run from repository root: luajit tests/test_field_transition.lua
local T=assert(loadfile('FRLG_VOXEL/lib/render/FieldTransition.lua'))()
local Camera=assert(loadfile('FRLG_VOXEL/lib/render/Camera.lua'))({require=function()return{}end})
local warp={busy=false}
function warp.isBusy()return warp.busy end
function warp.isEscalatorActive()return false end
function warp.startStairWarp()warp.busy=true;return true end
local original=warp.startStairWarp
T.install(warp)
local cam=Camera.new{vr=true}
cam:update(1/60,{x=3,z=4,ground=2,facing='up'})
local x,y,z,yaw=cam.x,cam.y,cam.z,cam.yaw
assert(warp.startStairWarp())
local state=T.new()
for frame=1,30 do
 if frame==15 then cam:reset()end
 assert(state:update(1/60,warp,cam))
 assert(cam.x==x and cam.y==y and cam.z==z and cam.yaw==yaw)
 local v=state:veil({1,1,1,.8})
 assert(v[1]==0 and v[2]==0 and v[3]==0 and v[4]>=.8)
end
warp.busy=false
assert(not state:update(1/60,warp,cam))
assert(state.alpha==1 and cam.x==nil)
cam:update(1/60,{x=30,z=40,ground=4,facing='down'})
assert(cam.x==30 and cam.z==40 and cam.y==4)
for frame=1,30 do state:update(1/60,warp,cam)end
local native={1,1,1,.4};assert(state:veil(native)==native)
T.uninstall(warp);assert(warp.startStairWarp==original)
print('PASS held VR rig, white-to-black veil, covered destination snap and observer cleanup')
