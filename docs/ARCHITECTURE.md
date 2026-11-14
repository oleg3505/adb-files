# Architecture

The authoritative project layout and constraints are in [CLAUDE.md](../CLAUDE.md) (§ Project layout,
§ Tech stack). This file records what actually exists.

## Targets (`Package.swift`)

| Target | Kind | Purpose | May import |
|--------|------|---------|------------|
| `AdbKit` | library | ADB protocol client (host, sync, shell) | Foundation, Network, os — **never SwiftUI/AppKit** |
| `AdbFiles` | executable | The macOS app | AdbKit, SwiftUI, AppKit, Quartz (QLPreviewPanel), ImageIO, CryptoKit |
| `AdbKitTests` | tests (Swift Testing) | Protocol tests without a device; fake ADB server; live suites behind env vars | AdbKit, Testing |
| `AdbFilesTests` | tests (Swift Testing) | App logic via `@testable import AdbFiles` (stores, sorting, cache) with scripted fakes | AdbFiles, AdbKit, Testing |

Swift 6 language mode (strict concurrency) and macOS 14 minimum for all targets.

## AdbKit (`Sources/AdbKit`)

| File | Role |
|------|------|
| `Models.swift` | `Device`, `DeviceState` (incl. `.noPermissions`, `.unknown`) |
| `AdbError.swift` | Typed errors with user-readable descriptions |
| `HostProtocol.swift` | Request encoding (`%04x` + payload) and the incremental `HostMessageDecoder` |
| `DeviceListParser.swift` | `host:devices-l` / `track-devices-l` lines (format from AOSP `transport.cpp`) |
| `AdbConnection.swift` | `actor` over `NWConnection`: connect / request / read with timeouts; Task cancellation cancels the socket |
| `AdbHostClient.swift` | `version()`, `devices()`, `trackDevices()` (`AsyncThrowingStream`) |
| `AdbServerLauncher.swift` | Finds `adb` (CLAUDE.md order, `ADBFILES_ADB_PATH` override) and runs `adb start-server` |
| `RemoteFile.swift` | `RemoteFile` (64-bit size, mode, mtime, per-entry errno) and `RemotePath` helpers |
| `SyncProtocol.swift` | Sync request encoding (≤ 1024-byte paths), incremental `SyncListDecoder` (`DENT`/`DNT2`/`DONE`/`FAIL`), stat replies |
| `AdbSyncClient.swift` | `actor`, one persistent `sync:` connection per device; `list` (LIS2/LIST by feature), `lstat`, `disconnect`; operations serialized; signpost "list". Sessions: `openTransferSession()` (two per device) and `openInteractiveSession(priority:)` (one per device, for Quick Look and thumbnails; `.high` for previews) — ADR-001 |
| `AdbShell.swift` | `quote(_:)` — the only shell-escaping helper; `accessCheck(_:)`; `run(_:serial:)` over `shell:` |
| `AdbTransferSession.swift` | `actor`, one transfer slot = one `sync:` connection: `readPrefix(_:maxBytes:)` (RECV that stops after N bytes and drops the connection, so the next call reopens), `download` (via `*.adbfiles-part` + no-overwrite move), `upload` (mode + mtime), `walk`, `downloadFolder`/`uploadFolder` (skip finished files on Retry, per-file failures continue, post-order folder mtimes); 15 s inactivity limit per read/write, no overall limit; reopens after `FAIL` |
| `AsyncLimiter.swift` | Cancellation-aware limiter, FIFO within a priority; `.high` waiters go before queued `.normal` ones |
| `TransferIO.swift` | Temp names, no-overwrite move, mtimes, local folder walk |
| `AdbFileOperations.swift` | `rename`, `move`/`copy` (N items → per-item results), `delete` (batched `rm -r`), `makeDirectory`; commands only via `AdbShell` with `--`; `AdbShell.runChecked` reads a last-line marker; source/target checked before and results verified after (toybox `-n` is silent); case-insensitive clash checks and a temp-name case-only rename, because `/sdcard` is case-insensitive FUSE |
| `Log.swift` | `Logger.adb` |

Empty listings are ambiguous (adbd returns only `DONE` for empty, missing and unreadable folders), so
`AdbSyncClient` follows an empty result with `LST2` (missing → `notFound`) and then
`ls -a P >/dev/null 2>&1 && echo ok || echo denied` (`test -r` is not enough: SELinux can deny what the
permission bits allow, e.g. `/storage/emulated`).

## App (`Sources/AdbFiles`)

- `App/` — `AdbFilesApp` (`@main`, scenes, **owns the single `DeviceStore`** and starts it in `init`),
  `AppDelegate` (activation policy, quit on last window), `RootView` (`NavigationSplitView`).
- `Features/<Feature>/` — views and their `@Observable` models, one folder per feature.
  - `Devices/DeviceStore` — `@Observable @MainActor`. Loop: `trackDevices()` → on `serverNotRunning`
    start the server once per failure streak → on stream end reconnect with backoff 0.5 s → 5 s.
    Phases: `connecting`, `adbMissing`, `failed`, `ready`.
  - `Devices/DeviceSources` — `DeviceTracking` / `ServerStarting` protocols, the seams for tests.
  - `Browser/BrowserStore` — `@Observable @MainActor`, one per window and device: path, Back/Forward
    stacks, phase (`loading/loaded/empty/denied/notFound/failed`), sort, hidden toggle, selection.
    Shows the cached listing first, then refreshes; reloads only if the listing changed. A generation
    token plus `cancel()` guarantee no state write from a superseded or cancelled load.
  - `Browser/FileSorting` — `buildRows` once per listing (display strings, name/kind ranks; the only
    locale-aware sorts) and `arrange` per header click (index sort over integer keys, folders first).
  - `Browser/BrowserView` — owns the store in `.task(id: serial)`; on teardown cancels it and, if the
    device is gone, calls `AdbSyncClient.disconnect()`. `BrowserCommands` (Go menu, ⌘[ ⌘] ⌘↑ ⌘↓ ⌘R ⌘⇧.)
    reach the focused window's store through `@FocusedValue(\.browser)`.
  - `Browser/BrowserStore` file operations — one at a time (`busy`), not tied to navigation: affected folders are
    always invalidated and failures always alerted; inline rename state (`editingPath`), delete confirmation
    (`pendingDeletion`), dragged rows for path-bar drops (`draggingPaths`). `FileOperating` is the test seam.
  - `Browser/ContextMenu`, `App/FileCommands` — context menu; File › New Folder ⌘⇧N, Rename, Delete… ⌘⌫ (disabled
    while renaming), Copy Path ⌥⌘C. `BreadcrumbBar` segments accept drops (move, ⌥ copy; Finder items upload).
  - `Transfers/TransferQueue` — `@Observable @MainActor`, app-wide: per-device FIFO, two running per
    device. Final state comes from a stop reason recorded before cancelling (user → cancelled, device gone
    → failed + Retry); events carry an attempt number and are dropped once final. Keep-both names are
    reserved on both sides before a transfer starts (`ConflictNaming`); Retry reuses the name. Progress
    reaches the UI ≤ 10×/s through `ProgressThrottle` (lock + injectable clock). `TransferEngine` is the
    test seam; `AdbTransferEngine` runs one `AdbTransferSession` per item.
  - `Transfers/TransfersButton`, `TransfersPopover`, `TransferRow`, `TransferStatusBar` — toolbar ring +
    badge, list with cancel/retry/show in Finder, bottom bar with combined progress.
  - `Transfers/TransferActions`, `App/TransferCommands` — File › Download To… (⇧⌘D), Upload… (⌘U).
  - `Preview/PreviewController` — `@Observable @MainActor`, one per browser: Space toggles Quick Look for the
    selected files (folders and links skipped), downloads missing ones first (`loadingName` drives the spinner bar),
    follows selection changes while the panel is up. A token per request: a cancelled or superseded download never
    alerts and never reaches the panel. Seams: `PreviewDownloading` (production: `InteractivePreviewDownloader`,
    `.high` priority) and `PreviewPresenting` (production: `QuickLookPanelPresenter`, data source/delegate of the
    shared `QLPreviewPanel`; forwards ↑/↓ from the panel to the table).
  - `Preview/PreviewCache` — `~/Library/Caches/AdbFiles/preview/<serial>/<key>/<name>`, reused while complete
    (key = path + size + mtime), cleared at launch by `AppServices`.
  - `Browser/RowSize`, `App/ViewCommands` — View › Small Rows (22 pt, 16 pt icons) / Large Rows (48 pt, 40 pt),
    stored with `@AppStorage("rowSize")`.
- `AppKitBridges/FilePromiseDelegate` — `NSFilePromiseProvider` delegate: enqueues the download on drop,
  writes to Finder's exact URL, calls Finder's completion when the transfer ends.
- `AppKitBridges/FileTableView` — drag rows out (file promises) and accept Finder drops on the table or a
  folder row; empty folders keep the (empty) table so drops work everywhere.
- `AppKitBridges/FileTableView` — `NSViewRepresentable` over a view-based `NSTableView`; reloads only
  when `rowsVersion` (or the row size) changes; Return opens, type-select by name, icons cached per extension.
  `FileNSTableView` overrides only `keyDown` (Return, Space) and the `QLPreviewPanelController` methods —
  overriding its dragging-source methods broke drag & drop in ADB-5.
- `AppKitBridges/ThumbnailBinder` — `@MainActor`: the Name cell (`FileNameCellView`) requests its row's thumbnail
  in `viewFor`; reuse, `didRemove rowView` and folder changes cancel; a result is applied only if the cell still
  shows that path with the same token, in one batch per run-loop turn (`apply thumbs n=… mainMs=…`).
- `Services/` — `AppServices` (sync clients via `SyncClientRegistry`, the shared `ListingCache` and the
  `TransferQueue`, injected via `.environment`; one `ThumbnailService` per device; `devicesChanged` fails transfers
  and cancels thumbnails of devices that left), `ListingCache` (actor, in-memory, keyed by serial + path),
  `ThumbnailService` (actor: memory + disk cache `~/Library/Caches/AdbFiles/thumbs/<serial>/<sha256>.png` keyed by
  path, size and mtime; duplicate requests share one task; at most 2 decodes at once, off the actor; device reads
  one at a time on the interactive connection via `ThumbnailSource`; cancelled requests cache nothing),
  `ThumbnailStrategy` in `ThumbnailSource.swift` (JPEG/HEIC: 64 KB prefix → embedded EXIF thumbnail, else a full
  read ≤ 10 MB; PNG/WebP/GIF/BMP ≤ 10 MB: full read; anything else keeps its icon), `ExifThumbnail` (extracts the
  complete IFD1 JPEG and the orientation; ImageIO would decode a truncated main image instead), `Log.swift`
  (`Logger.ui` / `Logger.transfer`, subsystem `dev.local.AdbFiles`, same as `Logger.adb`).

Filter logs with `log stream --level info --predicate 'subsystem == "dev.local.AdbFiles"'`
(use `/usr/bin/log` in zsh, where `log` is a builtin).

## Packaging

`scripts/build-app.sh` assembles `build/AdbFiles.app` from the SwiftPM binary, `Resources/Info.plist`
and a generated placeholder icon (`scripts/make-icon.sh`), then ad-hoc signs it. `build/` is gitignored.
