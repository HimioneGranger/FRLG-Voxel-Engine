-- WildsAtlasWorker (Lab 60, item 3): the decode thread of WildsAtlasCompat.
--
-- This file runs in a love.thread state, not in the mod sandbox (a fresh Lua state with the full standard library; it
-- is our own source, shipped as source like every mod file, and it receives data only). WildsAtlasCompat reads the
-- source with mod:read and starts it with love.thread.newThread(<source>), which needs the "compute" permission in
-- manifest.json; without it the compat never gets here and keeps the synchronous path.
--
-- An error that escapes a thread reaches LOVE's default love.threaderror, which raises it in the main loop and ends
-- the game (a mod may not replace that callback). So NOTHING may escape here: the whole body runs under pcall and a
-- failure is reported to the main side as { fatal = "<message>" } before the thread ends normally; the main side then
-- switches to the synchronous path.
--
-- Protocol (plain data through two named channels, nothing else crosses):
--   in : { id = n, file = "<shard png path as love.image.newImageData takes it>", rects = { x1, y1, w1, h1, x2, ... } }
--        { quit = true }
--   out: { id = n, file = f, x = , y = , w = , h = , data = <ImageData of the rectangle> }   one per rectangle
--        { id = n, file = f, done = true, ms = <decode ms>, n = <rectangles cut> }           the shard is finished
--        { id = n, file = f, done = true, err = "<message>" }                                 decode failed
--        { fatal = "<message>" }                                                              the worker is leaving
-- The shard is decoded once per request and released as soon as the rectangles are cut, so the worker never holds
-- more than one ~6 MB shard. It exits by itself after idleSecs without work (the main side restarts it on demand),
-- so a thread blocked forever can never hold the game open at quit.
local inName, outName, idleSecs = ...

local function main()
  require("love.image")
  require("love.filesystem")
  require("love.timer")
  require("love.thread")

  local inCh = love.thread.getChannel(inName)
  local outCh = love.thread.getChannel(outName)
  idleSecs = tonumber(idleSecs) or 4
  local clock = love.timer.getTime

  local function process(msg)
    local file, rects = msg.file, msg.rects
    if type(file) ~= "string" or type(rects) ~= "table" then
      outCh:push({ id = msg.id, file = file, done = true, err = "bad request" })
      return
    end
    local t0 = clock()
    local okD, shard = pcall(love.image.newImageData, file)
    if not okD or not shard then
      outCh:push({ id = msg.id, file = file, done = true, err = tostring(shard) })
      return
    end
    local ms = (clock() - t0) * 1000
    local cut = 0
    for i = 1, #rects - 3, 4 do
      local x, y, w, h = rects[i], rects[i + 1], rects[i + 2], rects[i + 3]
      local okC, crop = pcall(love.image.newImageData, w, h)
      if okC and crop then
        local okP = pcall(crop.paste, crop, shard, 0, 0, x, y, w, h)
        if okP then
          cut = cut + 1
          outCh:push({ id = msg.id, file = file, x = x, y = y, w = w, h = h, data = crop })
        end
      end
    end
    pcall(shard.release, shard)
    outCh:push({ id = msg.id, file = file, done = true, ms = ms, n = cut })
  end

  local lastWork = clock()
  while true do
    local msg = inCh:pop()
    if msg == nil then
      if clock() - lastWork > idleSecs then break end
      love.timer.sleep(0.004)
    elseif type(msg) == "table" and msg.quit then
      break
    elseif type(msg) == "table" then
      process(msg)
      lastWork = clock()
    end
  end
end

local ok, err = pcall(main)
if not ok then
  pcall(function()
    require("love.thread")
    love.thread.getChannel(outName):push({ fatal = tostring(err) })
  end)
end
