# Optional mod lookup update

The engine and its adapters live in `FRLG_VOXEL` only. Existing VRITK, Catch and
Gear releases look for an old separate bridge, so their generic discovery code
also needs a small update. No FireRed gameplay adapter is moved into those mods.

Close the game, install beta 3's `FRLG_VOXEL`, then run from the game folder:

```sh
python mods/FRLG_VOXEL/tools/update_consumer_lookups.py --mods-dir mods
python mods/FRLG_VOXEL/tools/update_consumer_lookups.py --mods-dir mods --apply
```

Use Python 3; no extra Python packages are needed. `--mods-dir` can be the full
path to your actual unpacked mods folder. Linked/junction paths are refused.
The first command is a dry run. The second applies the update after all source
versions, hashes and patch results have passed. Restart the game afterward.

Supported inputs:

| Mod | Exact reviewed version | Changed files |
| --- | --- | --- |
| VR Interactions Backpack Lab | 0.3.1-gen-compat.1 | HostProvider.lua, Gen3HostCompat.lua, manifest.json |
| FRLG Catch | 0.4.0-lab8.2 | main.lua, manifest.json |
| Kanto Gear | 3.4.0 | main.lua, manifest.json |

The updater skips absent optional mods and does not install them. It rejects an
unknown version or file hash before changing any mod. Previously applied files
are recognized; rerunning is safe. Keep the same external mod versions: the
migration receipt records the lookup revision without breaking existing version
contracts. It does not support updating mods still packed inside ZIP files.

Original files and a checksum receipt are saved under
`FRLG_VOXEL/consumer-update-backups/`. Keep that backup. If a write fails, the
updater attempts to restore earlier writes and records any restoration failure.
For manual rollback, close the game and copy the backed-up paths into the mods
folder. Backups are private local files and are excluded from Git tracking.
No ROMs, saves, external art, host binaries or mod assets are read or changed.

Discovery prefers `FRLG_VOXEL.exports.getCompatibilityHost()` and retains the
legacy-host fallback. Catch can now load with its engine dependency alone.
Optional dependency ordering puts the engine before Gear/VRITK without requiring
it for unrelated game setups. The engine owns layout and API readiness checks.
No fake loader alias or public full-mod-stack redistribution is involved.

Verification covers actual lookup functions, module caching, Catch bind entry,
Gear naming, Gen1/Gen2/legacy fallback and the native loader's dependency order.
Updater tests cover dry runs, seven exact file changes, backups, repeat runs,
unknown inputs, path rejection and injected write/rollback failures. Full play
with controllers and physical Quest acceptance remain pending.
