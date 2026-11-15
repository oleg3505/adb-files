# AdbFiles

Native macOS app for browsing and managing files on Android devices over ADB.
Personal tool; not distributed.

## Requirements

- macOS 14 or newer
- Xcode 16+ (Swift 6 toolchain; Swift Testing is used for tests)
- `adb` — `brew install android-platform-tools` (needed from milestone 2)

## Build and run

```sh
swift build            # compile
swift test             # unit tests
scripts/run.sh         # debug .app bundle, then launch it
scripts/build-app.sh   # release build → build/AdbFiles.app (ad-hoc signed)
```

`.build/debug/AdbFiles` can also be run directly; the app sets a regular activation policy, so it still
gets a Dock icon and a menu bar. macOS may not bring it to the front when launched from a terminal —
`scripts/run.sh` (via `open`) does.

## Shortcuts

| Keys | Action |
|------|--------|
| ⌘[ / ⌘] / ⌘↑ | Back / Forward / Enclosing folder |
| Return, ⌘↓ | Open |
| ⌘R, ⌘⇧. | Refresh, show hidden files |
| ⌘⇧N | New folder |
| ⌘⌫ | Delete (with confirmation; Android has no Trash) |
| ⌥⌘C | Copy path |
| ⇧⌘D, ⌘U | Download to…, Upload… |
| drag onto a folder row / path segment | Move (⌥ = copy) |
| Space, ⌘Y | Quick Look the selection (↑/↓ follow; Space or Esc closes) |
| ⇧⌘I, ⌥⌘L, ⇧⌘O | Internal Storage, Download, Documents (also in the sidebar's Locations) |
| drag from the icon or name | Drag files; dragging anywhere else on a row selects a range (⌘-click, ⇧-click, ⌘A too) |
| View › Small Rows / Large Rows | Row height; Large shows bigger photo thumbnails |

## Testing and debugging aids

| Variable                                    | Effect                                                                                                                                     |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `ADB_TEST_SERVER=1 swift test`              | Also runs `LiveServerTests` against the real ADB server on 127.0.0.1:5037                                                                  |
| `ADB_TEST_SERIAL=<serial> swift test`       | Also runs `LiveDeviceTests` against that device (read-only: lists `/sdcard`, `/data`, `/storage/emulated`, an empty folder, `DCIM/Camera`) |
| `ADB_TEST_WRITE=1` (with `ADB_TEST_SERIAL`) | Also runs `LiveWriteTests` / `LiveTransferQueueTests`, which write **only** to `/sdcard/Download/AdbFilesTest` and remove it afterwards    |
| `ADBFILES_ADB_PATH=/path/to/adb`            | Uses this adb binary instead of the lookup; a non-existent path simulates "adb not found" (with the server stopped)                        |
| `ADBFILES_START_PATH=/sdcard/DCIM`          | The browser opens this folder instead of `/sdcard`                                                                                         |

Name clashes ask first (Replace / Keep Both / Skip, "Apply to all"); folders offer Keep Both / Skip only.
File › Connect via Wi-Fi… pairs and connects a phone with Wireless debugging (Android 11+).

Profiling: signpost intervals `list`, `transfer`, `thumbnail`, `prefetch`, `preview` (subsystem
`dev.local.AdbFiles`). In Instruments add the os_signpost instrument (a Blank template) and filter by the subsystem,
or list them with `/usr/bin/log show --signpost --last 5m --predicate 'subsystem == "dev.local.AdbFiles"'`.

Caches: thumbnails in `~/Library/Caches/AdbFiles/thumbs/<serial>/` (safe to delete; trimmed to 400 MB at launch when over 500 MB), Quick Look copies in
`~/Library/Caches/AdbFiles/preview/` (cleared at every launch).

App logs: `/usr/bin/log stream --level info --predicate 'subsystem == "dev.local.AdbFiles"'`.

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Project rules and milestones live in [CLAUDE.md](CLAUDE.md).
