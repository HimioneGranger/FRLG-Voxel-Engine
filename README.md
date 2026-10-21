# FRLG Voxel Engine — beta

A 3D voxel/render engine for FireRed and LeafGreen, built for a compatible
Gen1Recomp Gen 3 host. This beta includes the latest reviewed buildings and
20 cave maps, plus foliage rendering and optional mod integrations.

**Engine only:** the host, game data and optional gameplay mods are supplied
separately. No ROMs or saves are included.

## What has been overhauled

- **Buildings:** shaped roofs, overhangs and trim, complete side/rear walls,
  and special building profiles using the original artwork.
- **Caves:** raised shelves, walls, stairs, ladders and height-aware surfaces
  across Mt. Moon, Rock Tunnel, Seafoam, Victory Road, Cerulean Cave and more.
- **Water and terrain:** native water animation and Seafoam waterfall drops.
- **Foliage:** grass, trees and native plant placement; ready for further work.

### Buildings

![Reviewed Saffron building roofs and exteriors](docs/screenshots/buildings.png)

### Mt. Moon B2F

![Mt. Moon B2F rendered by the beta engine](docs/screenshots/mt-moon.png)

### Seafoam Islands B3F

![Seafoam B3F shelves, water and waterfall elevation](docs/screenshots/seafoam.png)

These are development previews. The building image comes from the reviewed
exterior pass; cave images were captured through the beta runtime. Mt. Moon
B2F still has a polish note. Images do not establish headset acceptance.

## Install

1. Use a compatible Gen 3 host and your own game data.
2. Download the ZIP from **Releases**.
3. Extract both `FRLG_VOXEL` and `VRITK_FRLG_HOST` into the host's mods folder,
   replacing older copies. Keep only one copy of each mod ID.

`VRITK_FRLG_HOST` is a small compatibility lookup shim. Its implementation is
inside the engine; it does not include VRITK itself.

The tested integration baseline is Gen 3 Lab 62
(`0.3.33-gen3.lab.62-runtime-fixes-wilds171`), with mod API 2 and LÖVE graphics.
Quest also needs the host's OpenXR support. Other host releases are unverified.

## Mod compatibility

These optional integrations are included as adapters. **The mods themselves
are not bundled.** Use compatible versions from the existing Gen 3 lab stack;
this is not a claim of compatibility with every upstream version.

| Mod / integration | Support included in this beta |
| --- | --- |
| VRITK / VR Interactions Backpack Lab | Gen 3 host bridge, hands/backpack and interaction hooks |
| Wilds of Hoenn / Wilds followers | FireRed overworld provider, follower and rendering adapters |
| Untamed Advanced / FRLG overworld mons | Alternative overworld-provider adapter and selection |
| TWS / private weather build | Weather and rendering hooks |
| FRLG Catch | Capture-world and rendering hooks |
| Kanto Gear | Gen 3 belt, gear placement and party hooks |
| Portal MR | Optional mixed-reality rendering link |
| FRLG RTC / Emerald Clock bridge | Clock integration hooks |

The renderer/profile loader works without these optional mods. Adapter
discovery and lifecycle checks pass; full gameplay with every mod combination
and Quest headset testing remain pending. Large caves can hitch during cold
loading. See [technical notes](docs/TECHNICAL_NOTES.md) for verification details.

## Working on foliage

Start with `FRLG_VOXEL/lib/grass/`, `lib/mesh/FrlgNativeFoliage.lua` and
`lib/render/FrlgTreeView.lua` inside the engine. Keep accepted buildings and
cave layouts intact, and include before/after screenshots with changes.
Never submit ROMs, extracted game files or personal saves.

## License

Private, noncommercial beta use under [LICENSE.txt](LICENSE.txt). Public
releases of beta-derived forks require **HimioneGranger's explicit written
permission**, subject to GitHub-required viewing/forking and third-party rights.
The engine's original code will become open source at full release; that
release will name its license. See [third-party notices](THIRD_PARTY_NOTICES.md).
