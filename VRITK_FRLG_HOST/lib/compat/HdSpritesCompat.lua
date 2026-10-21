-- Legacy host-loader path only. Implementation remains engine-owned.
return {install=function(api, env, options)
 local owner=api.find("FRLG_VOXEL")
 assert(owner and owner.exports and owner.exports.legacyBridgeModule,
  "FRLG Voxel Engine HD compatibility bootstrap unavailable")
 return owner.exports.legacyBridgeModule("compat/HdSpritesCompat").install(api,env,options)
end}
