-- Dedicated grass customization page, using the game's persisted mod options.
local M={GROUP={id='group.grass',label='GRASS OPTIONS'}}
local KEY='__frlgvoxel_grass_options'
local SPECS={
 {id='frlgvoxel:grass-shape',label='SHAPE',key='shapeKey',default='upright',
  choices={{'UPRIGHT','upright'},{'WIDE + LAYERED','layered'}}},

}
local function label(env,text)
 -- FireRed's native Options value column is narrower than Emerald's.
 if env.recache=='restart' then
  if text=='WIDE + LAYERED' then return 'WIDE LAYERS' end
 end
 return text
end
local function value(env,spec)
 local saved=env.get(env[spec.key])
 for i,c in ipairs(spec.choices)do if c[2]==saved then return c[2],i,label(env,c[1]) end end
 return spec.default,1,label(env,spec.choices[1][1])
end
local function row(env,spec)
 return {id=spec.id,label=spec.label,
  value=function()local _,_,label=value(env,spec);return label end,
  step=function(ctx,dir)
   local _,at=value(env,spec)
   local nextValue=spec.choices[(at-1+(dir and dir<0 and -1 or 1))%#spec.choices+1][2]
   local ok,Manager=pcall(require,'src.mods.ManagerState')
   if not(ok and Manager and Manager.new and ctx and ctx.game and ctx.game.mods)then return false end
   local wrote,result=pcall(function()return Manager.new(ctx.game):setOption(env.id,env[spec.key],nextValue)end)
   return wrote and result~=false
  end}
end
local function removeGroup(Rows)
 for i=#Rows.GROUPS,1,-1 do if Rows.GROUPS[i].id==M.GROUP.id then table.remove(Rows.GROUPS,i)end end
 for i=#Rows.ORDER,1,-1 do if Rows.ORDER[i]==M.GROUP.id then table.remove(Rows.ORDER,i)end end
end
function M.install(env)
 local Rows=env and env.Rows
 if not(Rows and type(Rows.build)=='function' and type(Rows.GROUPS)=='table' and type(Rows.ORDER)=='table'
   and type(env.get)=='function' and type(env.shapeKey)=='string')then
  return false,'grass option rows unavailable'
 end
 local state=Rows[KEY]
 if state then state.env=env;state.active=true
 else
  state={env=env,active=true,base=Rows.build};Rows[KEY]=state
  Rows.build=function(ctx)
   local rows=state.base(ctx);local e=state.env
   if not state.active or type(rows)~='table' then return rows end
   local have={};for _,r in ipairs(rows)do if r.id then have[r.id]=true end end
   for _,spec in ipairs(SPECS)do if not have[spec.id]then rows[#rows+1]=row(e,spec)end end
   return rows
  end
 end
 removeGroup(Rows)
 Rows.GROUPS[#Rows.GROUPS+1]={id=M.GROUP.id,label=M.GROUP.label,members={SPECS[1].id}}
 local at=#Rows.ORDER+1
 for i,id in ipairs(Rows.ORDER)do if id=='group.vrdisplay'then at=i+1;break end end
 table.insert(Rows.ORDER,at,M.GROUP.id)
 return true
end
function M.uninstall(Rows)
 local state=Rows and Rows[KEY]
 if not state then return end
 state.active=false;removeGroup(Rows)
end
return M
