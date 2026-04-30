# Noizemaker

DGSH parsing, rebuild, editor UI, and mod-management work for the Lua/LOVE port of Noizemaker.

## Run the app

From the repo root:

```powershell
love .
```

On first launch, the app reads `config.ini`. If `game_root` is missing or invalid, it will prompt for your Space Channel 5 Part 2 root directory.

## Edit a sequence

1. Use `Open` to load a DGSH `.bin` file.
2. Select an entry from the left panel.
3. Edit the working copy in the timeline or inspector:
   - click a node to inspect it
   - drag a node left or right to change its tick position
   - use `Place Move` to arm a move, then click the timeline to place it
   - use the inspector to change move type, RAW byte, gap, tick, timing, or start delay
4. Press `Apply` to commit the current entry into the pending mods table.
5. Press `Patch` or `Ctrl+S` to write a patched copy of the loaded file.

Modified entries are marked with `*` in the entry list. Invalid edits are blocked before apply or patch, and validation messages appear in the inspector and status line.

## Shortcuts

- `Delete` / `Backspace`: delete selected step
- `Ctrl+Z`: undo
- `Ctrl+Y` or `Ctrl+Shift+Z`: redo
- `Ctrl+S`: patch a copy
- `Escape`: clear step selection or cancel move placement

## Mods tab

Use the `Mods` button in the top-right corner to switch to the Mods view.

The Mods view supports:

- installing `.zip` Noizemaker mods
- drag-and-drop zip install while the Mods tab is open
- enabling and disabling installed mods
- uninstalling mods
- restoring original backed-up game files

Installed mods are unpacked into:

```text
mods/
  mod_name/
    noizemaker.yaml
    files/
      r11_sh.bin
      r11cap_e.bin
      R1.BIN
```

Backups are stored separately and are never deleted by uninstall:

```text
backups/
  original/
    r11_sh.bin
    r11cap_e.bin
```

The backup tree mirrors the game-root-relative file layout.

## noizemaker.yaml

Each mod zip must include `noizemaker.yaml` at the archive root, or inside a single top-level folder.

Minimal example:

```yaml
name: Example Mod Name
version: 1.0.0
description: Short description of the mod.
author: Example Author
game_version: Steam
homepage: https://example.com/noizemaker-mod
changed_files:
  - r11_sh.bin
  - r11cap_e.bin
```

Required fields:

- `name`
- `version`
- `description`
- `changed_files`

Supported optional fields:

- `author`
- `game_version`
- `homepage`

The v1 parser is intentionally simple:

- `key: value` fields
- `changed_files` as a `- item` list
- multiline YAML values are not supported yet

## Installing and enabling mods

1. Open the `Mods` tab.
2. Click `Install Mod...` or drag a `.zip` onto the window while the tab is open.
3. After install, select the mod and click `Enable`.

When enabling a mod, Noizemaker:

1. checks for file conflicts with already enabled mods
2. backs up original game files into `backups/original/` if they are not already backed up
3. copies the modded files from `mods/<mod_name>/files/` into the game root

If two mods change the same file, enabling the second mod is blocked until the conflicting mod is disabled.

## Disabling and restoring

- `Disable` restores each changed file from `backups/original/`
- `Restore Originals` restores every backed-up original file into the game root and clears the enabled-mod state

If a mod introduced a changed file that had no original backup, disabling or restoring removes that modded file.

## Notes

- Current mod-management support is Windows-first.
- Mod zip extraction uses PowerShell on Windows.
- Exporting the current editor state as a distributable mod zip is not implemented yet.
- `legacy_python/` contains the older Python implementation for reference.

## Run backend tests

From the repo root:

```powershell
lua .\tests\backend_tests.lua
```

If `lua` is not on `PATH`, use your full Lua executable path instead.

The backend test runner uses the binary fixtures in `fixtures/` and checks:

- vanilla DGSH parsing
- no-op rebuild byte identity
- a known simple edit against an expected patched fixture
- PS007-style Rescue Section expansion and local ID growth
- odd/even start-delay encoding
- timing-only rebuild edits
