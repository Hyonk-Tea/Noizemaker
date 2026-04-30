# Noizemaker

Noizemaker is a Lua/LÖVE rewrite of the Space Channel 5 Part 2 rhythm editor and patcher.

## Running the app

Ideally, download the .zip from the Releases tab on the right.

Otherwise;

From the repo root:

```powershell
love .
```

On first launch, Noizemaker looks for `config.ini`. If `game_root` is missing or invalid, it will prompt you for your Space Channel 5 Part 2 install folder.

## Editing a sequence

The normal flow is:

1. Open a DGSH `.bin` file.
2. Pick an entry from the left panel.
3. Edit the working copy in the timeline or inspector.
4. Press `Apply` to store that entry in the pending patch set.
5. Press `Patch` or `Ctrl+S` to write a patched copy.

The editor supports:

- clicking a node to inspect it
- dragging steps left and right on the timeline
- placing new steps by arming a move and clicking the timeline
- editing move type, RAW byte, gap, tick, timing, and start delay
- undo / redo

Modified entries are marked in the entry list. Invalid edits are blocked before apply or patch, and the UI will show the validation reason.

## Shortcuts

- `Delete` / `Backspace`: delete selected step
- `Ctrl+Z`: undo
- `Ctrl+Y` or `Ctrl+Shift+Z`: redo
- `Ctrl+S`: patch a copy
- `Escape`: clear step selection or cancel move placement

## Mods

The `Mods` button opens the built-in mod manager. It can:

- install `.zip` Noizemaker mods
- accept drag-and-drop zip installs
- enable and disable installed mods
- uninstall mods
- restore backed-up original files

Installed mods unpack into:

```text
mods/
  mod_name/
    noizemaker.yaml
    files/
      r11_sh.bin
      r11cap_e.bin
      R1.BIN
```

Original files are backed up separately:

```text
backups/
  original/
    r11_sh.bin
    r11cap_e.bin
```

That backup tree mirrors the game-root-relative file layout.

## Mod manifest

Each mod zip needs a `noizemaker.yaml` at the archive root, or inside a single top-level folder.

Example:

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

Optional fields currently supported:

- `author`
- `game_version`
- `homepage`

The parser is intentionally simple for now:

- `key: value` fields
- `changed_files` as `- item` entries
- no multiline YAML values yet

## Backend tests

From the repo root:

```powershell
lua .\tests\backend_tests.lua
```

If `lua` is not on `PATH`, use the full path to your Lua executable instead.

The fixture suite checks:

- vanilla DGSH parsing
- no-op rebuild identity
- a known simple edit
- PS007-style Rescue Section expansion
- odd / even start-delay encoding
- timing-only rebuild edits

## Automatic Windows builds

This repo includes a GitHub Actions workflow that builds a Windows package automatically. Every run uploads a downloadable artifact containing:

- `noizemaker.exe`
- the required LÖVE runtime DLLs
- a packaged `.love` file
- the project README

The workflow lives at:

```text
.github/workflows/build-windows.yml
```

It calls:

```powershell
.\scripts\build_windows_package.ps1
```

So the same packaging process can be run locally if you want to reproduce the GitHub build.

If you push a tag like `v0.1.0`, the workflow will also create or update a GitHub Release for that tag and attach `noizemaker-windows.zip` as a release asset.

## Notes

- Mod-management is Windows-first right now.
- Mod zip extraction currently relies on PowerShell on Windows.
- Exporting the current editor state as a distributable mod zip is still not implemented.
