function love.load()
 local ok,err=xpcall(function()
  assert(loadfile('tests/test_local_loader.lua'))()
  assert(loadfile('tests/test_field_transition.lua'))()
 end,debug.traceback)
 if not ok then print(err)else print('EXISTING_PUBLIC_TESTS_PASS')end
 love.event.quit(ok and 0 or 1)
end
