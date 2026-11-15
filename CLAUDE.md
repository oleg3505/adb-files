# CLAUDE.md — AdbFiles

Native macOS app for browsing and managing files on Android devices over ADB.
Working name: **AdbFiles** (can be renamed later).

## Communication

- Talk to the user in **Ukrainian**. Code, comments, commit messages and docs are in **English**.
- The user is an experienced React / React Native developer who is **new to Swift**. When you introduce a non-obvious Swift, SwiftUI or AppKit concept, explain it in one or two sentences, using React analogies where they help.
- Ask before making large architectural changes or adding any third-party dependency.

## Goals (in priority order)

1. **Feels instant.** Every interaction gives feedback in under 100 ms. The UI never freezes.
2. **Feels native.** It behaves like Finder: keyboard navigation, drag & drop, Quick Look, context menus, dark mode, standard shortcuts.
3. **Reliable.** It handles device unplugging, timeouts and huge folders gracefully.

Non-goals: Windows/Linux support, Mac App Store distribution, MTP support, distribution to other users.

## Tech stack and constraints

- **Swift 6** with strict concurrency checking. **SwiftUI** for the app shell. **AppKit** where SwiftUI is slow or lacks features, embedded via `NSViewRepresentable`.
- **Minimum macOS 14** (needed for the `@Observable` macro).
- **No third-party dependencies** unless approved by the user. Use Foundation, Network.framework, AppKit, QuickLook and QuickLookThumbnailing.
- **No App Sandbox.** This is a personal tool, distributed outside the App Store.
- **Editor-agnostic:** the project is a **Swift Package**, not an `.xcodeproj`, so it builds from the terminal and works in VS Code.

## Project layout

```
Package.swift
Sources/
  AdbKit/              # library: ADB protocol client, no UI imports
    AdbConnection.swift    # socket + length-prefixed messages
    AdbHostClient.swift    # host:* services (devices, track-devices)
    AdbSyncClient.swift    # sync: LIST / STAT / RECV / SEND
    AdbShell.swift         # shell: service, argument escaping
    Models.swift           # Device, RemoteFile, errors
  AdbFiles/            # executable: the app
    App/                   # @main App, AppDelegate, menus, commands
    Features/
      Devices/             # sidebar, device list
      Browser/             # file table, breadcrumbs, navigation
      Transfers/           # queue, progress UI
      Preview/             # Quick Look integration
    AppKitBridges/         # NSViewRepresentable wrappers
    Services/              # caches, thumbnail service
Tests/
  AdbKitTests/         # protocol parsing tests with byte fixtures
scripts/
  build-app.sh         # builds a .app bundle
  run.sh               # build + launch
Resources/
  Info.plist
```

Keep `AdbKit` free of SwiftUI and AppKit, so it stays testable and reusable.

## Build and run

- `swift build` — compile
- `swift test` — run unit tests
- `scripts/build-app.sh` — runs `swift build -c release`, assembles `build/AdbFiles.app` (binary in `Contents/MacOS`, `Info.plist` in `Contents/`, icon in `Contents/Resources`), then ad-hoc signs with `codesign --force --deep -s - build/AdbFiles.app`
- `scripts/run.sh` — builds a debug bundle and opens it with `open`

When the app is launched as a bare executable, call `NSApp.setActivationPolicy(.regular)` and `NSApp.activate()` at startup, so it gets a Dock icon and a menu bar.

**After every meaningful change:** run `swift build` and `swift test`, and fix all errors and warnings before moving on. Never leave the project in a non-compiling state.

## ADB integration

### Approach

Talk to the **ADB server directly over TCP** at `127.0.0.1:5037`, using Network.framework (`NWConnection`). Do **not** spawn an `adb` process for each operation: process startup costs tens of milliseconds and forces text parsing.

The `adb` binary is used only to start the server if it is not running. Look for it at `/opt/homebrew/bin/adb`, `/usr/local/bin/adb`, `~/Library/Android/sdk/platform-tools/adb`, then on `$PATH`, and call `adb start-server`. If adb is not found, show a friendly screen explaining `brew install android-platform-tools`.

> The protocol details below are written from memory. **Verify them** against the AOSP sources (`packages/modules/adb`: `SERVICES.TXT`, `SYNC.TXT`, `file_sync_protocol.h`) before relying on exact byte layouts, and write tests from the verified spec.

### Host protocol basics

- Request: 4 ASCII hex digits giving the payload length, then the payload. Example: `000chost:version`.
- Response: `OKAY`, or `FAIL` followed by a 4-hex length and an error message.
- `host:devices-l` returns the device list.
- `host:track-devices-l` opens a long-lived connection that pushes an update on every change. Use it for live device detection instead of polling.
- `host:transport:<serial>` switches the connection to a specific device. After `OKAY`, send the service request (`sync:` or `shell:...`).

### Sync protocol (after `sync:`)

- Each request is a 4-byte ID plus a little-endian `UInt32` length, followed by data.
- `LIST <path>` returns `DENT` entries (mode, size, mtime, name length, name), terminated by `DONE`.
- `STAT <path>` returns mode, size and mtime.
- `RECV <path>` returns `DATA` chunks (at most 64 KB each), then `DONE`. Count the bytes to report progress.
- `SEND <path>,<mode>` sends `DATA` chunks, then `DONE` with the mtime, then waits for `OKAY` or `FAIL`.
- `QUIT` closes the session.
- v1 sizes are 32-bit, so files over 4 GB break. If the device advertises the `stat_v2` / `ls_v2` features (from `host:features` or `host-serial:<serial>:features`), use `STA2` / `LIS2`.
- All paths are UTF-8. Test with Cyrillic and emoji file names.

### Shell operations

- Use `shell:<command>` for `mkdir -p`, `mv`, `rm -r`, `cp -r` and `df`.
- **Always escape arguments** with single quotes, replacing each `'` with `'\''`. Put this in one well-tested helper, and never build shell strings any other way.
- Prefer sync-protocol operations whenever one exists.

### Concurrency and reliability

- `AdbSyncClient` is an `actor`. Keep a small pool of sync connections per device: 1 for listing, plus up to 2 for transfers, plus 1 interactive connection for Quick Look and thumbnails (`docs/decisions/ADR-001-interactive-connection.md`).
- Every operation takes a timeout: listing allows at most 10 s of inactivity, i.e. without any data from the device (no total limit, `docs/decisions/ADR-002-listing-inactivity-timeout.md`); transfers have no total timeout but an inactivity timeout of 15 s.
- On device disconnect: cancel its operations, mark its transfers as failed with a retry option, and keep the UI responsive.
- Support cancellation through Swift `Task` cancellation.

## Performance rules

- **Never block the main thread.** All ADB and disk I/O runs off the main actor.
- **Stale-while-revalidate:** show the cached listing for a folder immediately, refresh in the background, and apply a diff.
- **Prefetch:** when a folder row is selected or hovered for more than 150 ms, fetch its listing in the background, with low priority and cancellable.
- **Large folders** (DCIM can hold 10,000+ items): use `NSTableView` via `NSViewRepresentable` for the file list, not SwiftUI `List`. Sort and filter off the main thread.
- **Thumbnails:** generated lazily for visible rows only, with at most 2 concurrent fetches, cached on disk in `~/Library/Caches/AdbFiles/thumbs/<serial>/`, and keyed by path, size and mtime.
- **Transfers:** at most 2–3 concurrent per device. Report progress at most 10 times per second to avoid UI churn.
- Measure, don't guess: add `os_signpost` intervals around listing, transfers and thumbnail generation, so the user can profile with Instruments.

## UI and UX requirements

- **Layout:** `NavigationSplitView` with a sidebar (devices, plus bookmarks: Internal storage, DCIM, Download, Documents, Pictures, Music) and a detail area holding the file table.
- **File table:** sortable columns (Name, Date Modified, Size, Kind), folders first, a toggle for hidden files, and multi-selection.
- **Navigation:** breadcrumbs, Back/Forward (⌘[ / ⌘]), ⌘↑ for the parent folder, Enter or ⌘↓ to open, type-to-select.
- **Drag & drop:**
  - Out to Finder: use `NSFilePromiseProvider`, so the download starts only when dropped.
  - In from Finder: upload to the current folder.
- **Quick Look:** Space opens `QLPreviewPanel`. Download to a temp cache first and show a spinner while loading.
- **Context menu:** Open, Quick Look, Download to…, Rename, Delete, New Folder, Copy Path.
- **Shortcuts:** ⌘⌫ to delete (with confirmation), ⌘⇧N for a new folder, ⌘R to refresh, ⌘⇧. to toggle hidden files.
- **Transfers panel:** a toolbar button with a badge, and a popover listing each transfer with progress, speed, ETA, cancel and retry.
- **Empty and error states:** no device, unauthorized device ("Confirm USB debugging on your phone"), adb missing, permission denied for a folder.
- Use system colors and SF Symbols throughout. Support dark mode and VoiceOver labels.

## Milestones

Complete them in order. Each must build, pass its tests, and be demo-able before you start the next.

1. **Skeleton:** Package.swift, the app launches as a `.app` via the script, and an empty split view is shown.
2. **ADB host:** server discovery and start, the device list, and live updates via `track-devices`, including unauthorized/offline states.
3. **Browsing:** sync `LIST`, the file table, navigation, breadcrumbs, sorting, hidden files, and the listing cache with background refresh.
4. **Transfers:** download and upload with a queue, progress, cancel and retry, plus drag & drop in both directions.
5. **File operations:** rename, delete, new folder, move, copy path.
6. **Quick Look and thumbnails.**
7. **Polish:** prefetch, keyboard shortcuts, bookmarks, signposts, and Wi-Fi debugging (`adb pair` / `adb connect` UI).
8. **Stretch goal (discuss with the user first):** a Finder sidebar integration via a File Provider extension.

## Code conventions

- No force unwraps (`!`) or `try!` outside tests.
- Errors are typed (`enum AdbError: Error`) with user-readable messages.
- One type per file where reasonable. Keep views small and move logic into `@Observable` models.
- Use `Logger` (os.log) with categories `adb`, `transfer` and `ui` — never `print`.
- Public APIs in `AdbKit` get doc comments.

## Testing

- **Unit tests in `AdbKitTests`** run without a device: message framing, `DENT`/`STAT` parsing from byte fixtures, `FAIL` handling, shell escaping (spaces, quotes, Cyrillic, emoji, newlines), and devices-list parsing.
- **Integration tests** that need a real device are skipped unless the `ADB_TEST_SERIAL` environment variable is set.
- **Manual checklist for each milestone:** a folder with 10,000+ files, a file over 4 GB, Cyrillic names, unplugging the cable mid-transfer, two devices connected at once.

## Reference

- DroidDock (Tauri + React, MIT) is an existing ADB file browser for macOS. You may read it for ideas, but do not copy code.
- AOSP adb docs: `packages/modules/adb` (`SERVICES.TXT`, `SYNC.TXT`, `protocol.txt`).
