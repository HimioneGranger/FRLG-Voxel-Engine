# FRLG Voxel Engine — beta

A 3D voxel/render engine for FireRed and LeafGreen: reviewed buildings,
20 cave maps, foliage and optional mod adapters.

**Engine only:** requires a compatible Gen1Recomp Gen 3 host and your own game
data. The host, ROMs, saves and optional gameplay mods are not included.

**Beta 7** adds **Trees: Cards / Voxel / Voxel Low Res**, lighter tree rendering,
VR controls guides, belt/throw controls and physical-item adapters. It retains
the current buildings, caves, fog and sign work. New interaction features still
need headset testing. Thanks to [flixtkc](https://github.com/flixtkc) for the
original trees in [PR #1](https://github.com/HimioneGranger/FRLG-Voxel-Engine/pull/1).
See the [change notes](docs/CHANGELOG.md) for details and limits.

## What has been overhauled

- **Buildings:** shaped roofs, trim and complete side/rear walls.
- **Caves:** shelves, walls, stairs and ladders across Mt. Moon, Rock Tunnel,
  Seafoam, Victory Road, Cerulean Cave and more.
- **Water:** native animation and Seafoam waterfall drops.
- **Foliage:** native-art canopies, near/far geometry, grass and upright flowers.

### Buildings

![Reviewed Saffron building roofs and exteriors](docs/screenshots/buildings.png)

### Mt. Moon B2F

![Mt. Moon B2F rendered by the beta engine](docs/screenshots/mt-moon.png)

### Seafoam Islands B3F

![Seafoam B3F shelves, water and waterfall elevation](docs/screenshots/seafoam.png)

Development previews; Mt. Moon B2F retains a polish note. These images do not
establish headset performance.

## Install and try the trees

1. Use a compatible Gen 3 host and your own game data.
2. Download the ZIP from **Releases**.
3. Extract **only `FRLG_VOXEL`** into the host's mods folder, replacing the old
   engine folder. No separate compatibility mod is required.
4. Under **OUTDOOR LOOK**, choose **Trees: Cards / Voxel / Voxel Low Res**.
   Cards keeps flat trees. Voxel uses detailed 3D trees. Voxel Low Res uses
   coarser 3D trees for slower systems. The default remains Cards.
   The two voxel modes switch immediately; switching to/from Cards rebuilds
   nearby maps.

Keep your saves. Remove beta 1's old `VRITK_FRLG_HOST` folder if present.
Changed geometry may prepare once; compatible completed caches are reused.

Reference host baseline: FireRed lab 3257, engine 0.3.33/mod API 2/LÖVE, with OpenXR on
Quest. Preparation and controls need matching host services. This ZIP does not
update the host, install the custom title/Oak mod or supply a Steam Frame launcher.
The separate Windows PCVR host trial is not bundled in this engine ZIP.

The lab's embedded Gen 5 provider is omitted. Beta 4's external-provider
adapter remains; without a compatible provider/pack, native battle art is used.

## Optional mod compatibility

**Mods are supplied separately.** These are reviewed lab versions; other
versions and combinations remain unverified.

| Mod / integration | Included adapter scope |
| --- | --- |
| VRITK 0.3.1-gen-compat.1 | Discovery, hands/backpack and interactions; use the lookup updater |
| Wilds of Hoenn 1.10.1 | Pokémon, followers, nearby population refresh and ambient birds |
| Untamed Advanced / FRLG overworld mons | Requires its separate Overworld Mons provider |
| Lightweight Weather & Skies 1.2.0 (lab build) | Weather/rendering hooks; earlier TWS paths retained |
| FRLG Catch 0.4.0-lab8.2 | Capture adapters and discovery; use the lookup updater |
| Kanto Gear 3.4.0 | Belt/party/naming adapters and discovery; use the lookup updater |
| Portal MR | Optional mixed-reality rendering link |
| FRLG RTC / Emerald Clock bridge | Clock integration hooks |

Earlier Wilds 1.5.0/1.7.1 adapter paths are retained.

For the pinned VRITK, Catch and Gear versions, close the game and run this
from its folder after installing the engine:

```sh
python mods/FRLG_VOXEL/tools/update_consumer_lookups.py --mods-dir mods --apply
```

Requires Python 3. Omit `--apply` for a dry run. The updater verifies supported
files and keeps backups; absent or unknown mods are untouched.
[Details](docs/CONSUMER_UPDATES.md).

The renderer works without optional mods. Dense forests and cold loads can
still hitch. See [host requirements and testing limits](docs/TECHNICAL_NOTES.md).

## Working on foliage

Start in `FRLG_VOXEL/lib/mesh/FrlgGeneralFoliage.lua`, `FrlgFoliageCompiler.lua`
and `FrlgTreeModels.lua`. Preserve native leaf groups, placement, buildings and
caves. Include multi-angle near/far comparisons. Never submit ROMs or saves.

## License

Private, noncommercial beta use under [LICENSE.txt](LICENSE.txt). Public
releases of beta-derived forks require **HimioneGranger's explicit written
permission**, subject to GitHub-required viewing/forking and third-party rights.
This is source-available beta code. The engine's original code will become
open source at full release, under the license named then.
See [third-party notices](THIRD_PARTY_NOTICES.md).
