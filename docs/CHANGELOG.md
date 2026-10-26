# Beta 8

- Native round shrubs retain their dark leaf borders, with leftover shrub art
  removed from the ground. Matching approved artwork uses the compiled profile;
  mixed gatehouse tiles remain excluded.
- Saffron's thin blue railings no longer receive duplicate solid walls or
  missing ground. Ordinary silver fences remain a separate family. Route 15's
  shared gatehouse/fence issue is still pending and its experiment is excluded.
- Watch-map redraw scheduling avoids unnecessary native frames, and memory
  cleanup begins with more headroom. These are engine-side changes; the separate
  host/VRITK readback fix is not bundled in this engine-only download.
- Send-out presentation waits for full-size follower art. Wilds receives the
  saved roamer identity for supported overworld capture, including Suicune.
- Party-belt presentation can be allowed independently of Catch availability.
  Input/catching still requires the separately supplied compatible gameplay mod.
- Includes the previously prepared beta 7 tree modes, controls guide, belt lock,
  throw options, juggling, physical-item adapters and native battle text.

Existing buildings, caves, foliage artwork, compatibility adapters, private-use
beta license and third-party notices are retained. ROMs, saves, the game host,
optional mod stack, title/Oak scenes, APK/Steam launcher and the embedded Gen 5
sprite provider are not included. External sprite-provider support remains.

This is a prerelease. Saffron was reviewed in isolated GPU previews; the latest
combined beta still needs headset testing. No fixed FPS guarantee is made.

---

# Beta 7

- One **Trees: Cards / Voxel / Voxel Low Res** choice. Low Res uses the existing
  coarse native-art meshes nearby too: General7518 to498 triangles/tree and
  Forest11456 to888. These are geometry counts, not measured FPS improvements.
  Detailed meshes, placements and culling are preserved. The voxel modes switch
  live without rebuilding map records; Cards retains its own geometry identity.
- Exact vertex indexing reduces tree-template storage while preserving every
  triangle, material and winding. Existing valid tree records remain reusable
  through narrowly verified producer aliases.
- Engine-side controls guide during preparation and from native Help, belt yaw
  lock, optional throw assistance, a battle send-out destination cue for your
  own Pokemon, and the original qualifying juggling-spin bonus/visuals.
- Optional VRITK/Catch/Gear adapters for persistent held backpack items,
  forgiving follower medicine with spray mist, physical TM/HM case and tablet
  ports, berry pouch selection/feeding and existing happy cry/emote hooks.
  These need the separately supplied supported gameplay mods and device tests.
- Added battle prompts use native fonts/borders. Post-battle result text remains
  visible in the world when the tablet is holstered.
- Includes the lab3257 first-pass mainland Kanto horizon assets and lifecycle.
  Coverage remains limited; Sevii, Saffron, Viridian Forest and Safari keep native
  backgrounds. Full-region geography or headset acceptance is not claimed.

Source, isolated renderer and controlled interaction checks pass. The new tree
mode and interaction additions have not yet been tested together on a headset.
The separately reported Steam Frame3255 missing party belt remains unresolved;
this release does not claim to fix it or update the host/launcher/native bridge.

This is the engine and internal adapters only. ROMs, saves, host, optional mods,
custom title/Oak scene, tester APK/Steam bundle and embedded Gen5 sprite provider
are not included. The external sprite-provider adapter, existing license,
third-party notices and contributor history are retained.

---

# Beta 6

Engine fixes from the tested FireRed lab 3255 packages:

- Distance fog blends the world into the sky backdrop and hides far silhouettes.
- Tree visibility and near/far transitions reduce abrupt popping, with lighter
  distant geometry. The Forest canopy sits lower to reduce exposed trunk.
- Wilds land spawns favor actual travel direction while retaining nearby limits,
  gradual departures and protected encounters. Head turns do not relocate them.
- Sign backs remain readable and reverse every navigation arrow, including
  Viridian's Route 1, Route 2 and Route 22 directions.
- A sign texture correction can reuse a completed matching geometry cache;
  changes to trees, meshes or other producers still invalidate their records.

Upgrading from public beta 5 may prepare new records because the Forest geometry
changed. Do not clear app data or valid caches. This engine-only ZIP retains
the existing external Gen 5 provider adapter, original artwork, building/cave
outputs and private-use license. The host, optional mods, Steam Frame launcher
and separate Windows PCVR host trial remain external. No headset FPS guarantee.

---

# Beta 5

Engine foliage and preparation work from FireRed lab3253:

- Native-art voxel trees from flixtkc's PR #1, with the current General and
  Forest canopy refinements. Existing leaf rows and groups continue around
  their lower surfaces. Near/far geometry and instance batching are retained.
- Upright flowers preserve the original single-artwork treatment.
- Voxel-tree templates and placements now persist in world-cache format6.
  Sheet and voxel modes have separate cache/preparation identities; mode
  changes cannot consume the other mode's unfinished work.
- Bounded CPU preparation, safe cache writes and cooperative GPU completion
  replace the skipped voxel-tree preparation path. Android background/wake
  services require the matching host; those native services are not in this ZIP.
- Cache dependency filtering excludes supported audio and explicit
  presentation-only modules. New or unknown producers remain included;
  geometry and format changes still require fresh records.
- Current engine-side follower placement, physical healing and capture
  presentation adapters, warmer sunrise/golden-hour colors, and saved 3D-view
  capture hooks are also included. Their optional gameplay mods, host services
  and title/portal UI remain separate.

**Try it:** select **VOXEL TREES → VOXEL** in the engine settings. The default
remains **SHEETS**. Do not clear valid caches routinely.

Reviewed building/cave outputs and original artwork remain protected. The host,
optional gameplay mods, separate custom title/Oak scene and Steam Frame launcher
are not part of this engine package. Other lab changes are not implied by the
lab3253 reference. The lab's embedded Gen 5 sprite provider is omitted; the
beta 4 external-provider adapter and native-art fallback are retained.
See [technical notes](TECHNICAL_NOTES.md) for host services
and verification limits. The standalone engine still needs testing with the
chosen host and mod versions; dense forests have no guaranteed VR frame budget.

Thanks to [flixtkc](https://github.com/flixtkc) for the original voxel-tree
contribution in [PR #1](https://github.com/HimioneGranger/FRLG-Voxel-Engine/pull/1).
The interim private-use license and third-party rights remain unchanged.

---

# Beta 4

Engine-only changes from the FireRed lab 3232 runtime:

- A world-preparation screen distinguishes checking, precaching and rebuilding;
  preparation begins after New Game or Continue on a host with the matching hooks.
- Optional PC mouse/keyboard controls and free look. Quest keeps its VR controls.
- Battle terrain visibility no longer depends on the original fixed battle view.
- Single native flower artwork replaces the crossed flower treatment.
- Wilds of Hoenn 1.10.1 integration, native sharp ambient bird artwork and
  high entrances that descend into a 6–10 metre cruise. Clearance considers
  the flight corridor rather than the tallest object anywhere loaded.
- Ordinary distant ground Pokémon retire gradually beyond 16 cells and refill
  within the existing nearby 3–12 cell band. Native departure/arrival effects
  and the live cap remain in charge. Captures, shinies, roamers and active
  interactions are protected; no refresh occurs without a free local spawn cell.
- Party send-out/recall, custom audio, complete sprite cropping and ground
  anchoring fixes; thrown balls keep their incoming heading when they settle.
- VR stairs/escalators fade black while the simulated rig is held, then snap
  to the destination under cover. Headset tracking stays live.
- Pokédex speech can play before a catch while the uncaught tablet entry stays
  hidden. The low-health cue waits for the active battle Pokémon.

All compatibility remains inside `FRLG_VOXEL`. Accepted building/cave outputs,
original artwork, the consumer lookup updater and the interim license remain
unchanged. Optional mods and the host are not bundled.

## Verification and remaining work

Package integrity, Lua syntax and portable loading are checked. Lab tests also
exercise native spawn/FX and warp sequences, a continuous-walk fixture, a full
mod-stack population refresh and original Route 1 bird captures. These tests
do not establish physical headset acceptance. The corresponding lab APK was
installed on Quest 3; this standalone engine ZIP still needs user testing with
the chosen host and optional mod versions.

- The overly broad cache invalidation rule is **not fixed**. Compatibility or
  sound changes can still cause a world-cache rebuild.
- Native ambient frequency is unchanged. Pallet/Viridian had empty native
  bird pools in the tested setup; this update does not add birds to those pools.
- Flight clearance uses loaded, sometimes coarse chunk bounds, not exact
  collision against unloaded scenery.
- Moving population refresh targets ordinary land encounters, not water
  populations or special scripted encounters.
- Nonwarping terrain stairs are outside the stair-transition guard.
- Mt. Moon B2F retains its polish note; large cold cave loads can still hitch.

See [technical notes](TECHNICAL_NOTES.md) and the existing screenshots in the
[README](../README.md). The separate custom title/Oak mod is not in this ZIP.
