# FRLG Voxel Engine — beta

A 3D voxel/render engine for FireRed and LeafGreen, built for a compatible
Gen1Recomp Gen 3 host. This beta includes the latest reviewed buildings and
20 cave maps, plus foliage rendering and optional mod integrations.

**Engine only:** the host, game data and optional gameplay mods are supplied
separately. No ROMs or saves are included.

**Beta 4** brings the engine changes used by FireRed lab build 3232: clearer
world preparation, PC mouse controls, updated Wilds compatibility, nearby
population refresh and black stair/escalator transitions. See the
[change notes](docs/CHANGELOG.md) for scope and known limits.

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
3. Extract **only `FRLG_VOXEL`** into the host's mods folder, replacing the old
   engine folder. No separate compatibility mod is required.

All engine compatibility code starts automatically from `FRLG_VOXEL`. When
upgrading from beta 1, remove its separate `VRITK_FRLG_HOST` folder. Keep your
save files; this update does not require a new game.

Beta 4 was checked against the FireRed lab 3232 host (engine 0.3.33, mod API 2,
LÖVE graphics). Quest also needs the host's OpenXR support. The new preparation
screen and PC controls need matching host hooks; older hosts are unverified
for these features. The host application is supplied separately.

## Mod compatibility

These optional integrations are included as adapters. **The mods themselves
are not bundled.** Use compatible versions from the existing Gen 3 lab stack;
this is not a claim of compatibility with every upstream version.

| Mod / integration | Support included in this beta |
| --- | --- |
| VRITK 0.3.1-gen-compat.1 | Engine discovery, hands/backpack and interaction adapters; apply the included lookup update |
| Wilds of Hoenn 1.10.1 | Current tested adapter: Pokémon, followers, nearby population refresh and ambient birds |
| Wilds of Hoenn 1.5.0 / 1.7.1 | Earlier adapter paths retained; newer features target 1.10.1 |
| Untamed Advanced / FRLG overworld mons | Provider adapter included; still requires its external Overworld Mons provider |
| TWS / private weather build | Weather and rendering hooks |
| FRLG Catch 0.4.0-lab8.2 | Capture adapters and engine discovery; apply the included lookup update |
| Kanto Gear 3.4.0 | Belt/party/naming adapters and engine discovery; apply the included lookup update |
| Portal MR | Optional mixed-reality rendering link |
| FRLG RTC / Emerald Clock bridge | Clock integration hooks |

### One-time update for VRITK, Catch and Gear

Install this engine first and close the game. From the game folder, run:

```sh
python mods/FRLG_VOXEL/tools/update_consumer_lookups.py --mods-dir mods --apply
```

Requires Python 3. Omit `--apply` to check without changing files. The updater
handles the three versions listed above, skips mods you do not have, verifies
all files before writing and saves original backups inside `FRLG_VOXEL`.
Unknown or locally edited versions are left untouched. The mods themselves
remain separate; all game-specific compatibility stays inside the engine.
See [consumer update details](docs/CONSUMER_UPDATES.md).

The old host's bridge-specific HD-sprites guard remains unverified in this
layout. These lookup tests do not establish full gameplay or headset acceptance.

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
