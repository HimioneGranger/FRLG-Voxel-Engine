-- Reusable, code-drawn VR guide. Presentation only: never advances loading or gameplay.
local M={SECONDS=8}
M.pages={
 {title='Your controllers',lines={'LEFT STICK  Move / navigate','RIGHT STICK  Turn','A / X  Confirm     B / Y  Back','LEFT MENU  Game menu','LEFT STICK CLICK  3D / panel'}},
 {title='Grab a ball',lines={'Reach to a ball on your belt.','Squeeze the side grip to take it.','Keep holding the grip while aiming.','Release the grip to throw.','Toss upward, then grip again to recatch.'}},
 {title='Watch and equipment',lines={'Raise your left wrist to see the watch.','Aim your free hand at its screen.','Tap it, or press the index trigger.','Reach over a shoulder for your bag.','Squeeze the side grip to take it.'}},
 {title='Battle send-out and recall',lines={'Throw your party ball toward the pale ring.','It marks where YOUR Pokemon will appear.','For recall, aim its held ball at your Pokemon','and squeeze the index trigger.','Reopen controls: idle side grip (L / R).'}},
 {title='Juggle for spin',lines={'Toss a pouch ball upward and recatch it.','Successful recatches build spin charge.','At full charge, a higher recatch sparkles.','A centered, fully charged curve hit','earns the existing 10% catch-rate bonus.'}},
 {title='Medicine and berries',lines={'Put the bag away; your item stays held.','Bring medicine close; squeeze its trigger.','Pouch stick left / right selects a berry.','Grip the berry with your other hand.','Bring the berry to your partner to feed.'}},
 {title='Physical TMs and HMs',lines={'Hold the TM case in your right hand.','Trigger opens it; its stick browses.','Left grip takes the selected card / drive.','Put the case away; take out the tablet.','Insert at SD / USB; choose your Pokemon.'}},
}
function M.page(now)return math.floor(math.max(0,tonumber(now)or 0)/M.SECONDS)%#M.pages+1 end
local fonts={}
local function font(size)
 size=math.max(6,math.floor(size))
 if not fonts[size] then fonts[size]=love.graphics.newFont(size)end
 return fonts[size]
end
function M.draw(x,y,w,h,page,footer)
 local g=love.graphics;local p=M.pages[math.max(1,math.min(#M.pages,page or 1))]
 g.push('all');g.setShader();g.setScissor();g.setDepthMode();g.setColor(.08,.12,.16,1);g.rectangle('fill',x,y,w,h,8)
 g.setColor(.9,.96,1,1);g.setFont(font(h*.075));g.printf(p.title,x,y+h*.04,w,'center')
 local function controller(cx,left)
  local cy=y+h*.42;local r=h*.105
  g.setColor(.6,.72,.8,1);g.setLineWidth(math.max(1,h*.006));g.circle('line',cx,cy,r)
  g.rectangle('line',cx-r*.45,cy+r*.25,r*.9,r*1.7,r*.35)
  -- Index trigger at the front, side grip beside the handle.
  g.setColor(.48,.72,1,1);g.rectangle('fill',cx-r*.28,cy-r*1.05,r*.56,r*.14,r*.06)
  g.rectangle('fill',cx+(left and -r*.57 or r*.43),cy+r*.72,r*.14,r*.65,r*.05)
  if left then
   g.setColor(.7,.8,.86,1)
   for j=0,2 do g.rectangle('fill',cx-r*.43,cy+r*(.40+j*.08),r*.18,math.max(1,r*.025))end
  end
  local sx=left and -.33 or .33;local bx=left and .32 or -.32
  g.setColor(.35,.85,.6,1);g.circle('fill',cx+r*sx,cy-r*.18,r*.21)
  g.setColor(1,.8,.35,1);g.circle('fill',cx+r*bx,cy,r*.19);g.circle('fill',cx+r*bx,cy+r*.43,r*.19)
  g.setFont(font(h*.035));g.setColor(.06,.09,.12,1)
  g.printf(left and 'Y' or 'B',cx+r*bx-r*.2,cy-h*.02,r*.4,'center')
  g.printf(left and 'X' or 'A',cx+r*bx-r*.2,cy+r*.43-h*.02,r*.4,'center')
  g.setFont(font(h*.05));g.setColor(.85,.91,.96,1)
  g.printf(left and 'LEFT' or 'RIGHT',cx-r*1.4,cy-r*1.65,r*2.8,'center')
  g.printf('Stick',cx-r*1.4,cy+r*2.2,r*2.8,'center')
  g.setColor(.65,.8,1,1);g.printf('Trigger: index\nGrip: side',cx-r*1.8,cy+r*2.8,r*3.6,'center')
 end
 controller(x+w*.13,true);controller(x+w*.87,false)
 g.setColor(.95,.96,.94,1);g.setFont(font(math.min(h*.054,w*.0215)))
 local tx,tw=x+w*.25,w*.50
 for i,line in ipairs(p.lines)do g.printf(line,tx,y+h*(.25+(i-1)*.115),tw,'left')end
 g.setFont(font(h*.045));g.setColor(.62,.72,.8,1)
 g.printf(footer or ('CONTROLS %d / %d'):format(page or 1,#M.pages),x,y+h*.91,w,'center');g.pop()
end
function M.loading(w,h,prog,now,title,eta)
 local g=love.graphics;g.origin();g.setShader();g.setScissor();g.setStencilTest();g.setDepthMode();g.setMeshCullMode('none')
 g.setColorMask(true,true,true,true);g.setWireframe(false);g.setBlendMode('alpha')
 g.setColor(.015,.025,.035,1);g.rectangle('fill',0,0,w,h)
 g.setFont(font(h*.045));g.setColor(1,1,1,1);g.printf(title,0,h*.035,w,'center')
 M.draw(w*.035,h*.15,w*.93,h*.61,M.page(now))
 local bx,by,bw,bh=w*.1,h*.81,w*.8,h*.022
 g.setColor(.13,.18,.21,1);g.rectangle('fill',bx,by,bw,bh)
 local frac=math.max(0,math.min(1,prog.frac or 0));g.setColor(.38,.82,.5,1)
 if (prog.total or 0)>0 then g.rectangle('fill',bx,by,bw*frac,bh)
 else local pulse=.5+.5*math.sin(now or 0);g.rectangle('fill',bx+bw*.82*pulse,by,bw*.18,bh)end
 g.setFont(font(h*.026));g.setColor(.83,.89,.92,1)
 local progress=(prog.total or 0)>0 and ('Map %d of %d'):format(prog.done or 0,prog.total) or 'Preparing your game'
 g.printf(progress..(eta and '  |  '..eta or ''),0,h*.855,w,'center')
 local hint=prog.canSkip and 'B / Y: skip for now' or prog.continueHint or 'The game continues as soon as preparation finishes.'
 g.printf(hint,0,h*.93,w,'center')
end
function M.release()
 for _,f in pairs(fonts)do f:release()end;fonts={}
end
return M
