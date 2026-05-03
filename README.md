# Noizemaker

Noizemaker is a Lua/LOVE rewrite of the Space Channel 5 Part 2 rhythm editor and patcher.

## Running the app

Ideally, download the packaged `.zip` from the Releases page.

Tagged releases now also publish a Linux AppImage alongside the Windows package.

If you want to run it from source instead, from the repo root:

```powershell
love .
```

On first launch, Noizemaker looks for `config.ini`. If `game_root` is missing or invalid, it will prompt you for your Space Channel 5 Part 2 install folder.

On supported platforms, Noizemaker also registers the `noize:` URL scheme so GameBanana 1-click install links can reopen the app.

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
- open `noize:` GameBanana install links
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

That backup tree mirrors the game root relative file layout.

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

## Notes

- This tool does not support macOS. If you have it running there, you are on your own.
