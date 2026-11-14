# Architecture

The authoritative project layout and constraints are in [CLAUDE.md](../CLAUDE.md) (§ Project layout,
§ Tech stack). This file records what actually exists.

## Targets (`Package.swift`)

| Target | Kind | Purpose | May import |
|--------|------|---------|------------|
| `AdbKit` | library | ADB protocol client (host, sync, shell) | Foundation, Network, os — **never SwiftUI/AppKit** |
| `AdbFiles` | executable | The macOS app | AdbKit, SwiftUI, AppKit, QuickLook |
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
| `AdbSyncClient.swift` | `actor`, one persistent `sync:` connection per device; `list` (LIS2/LIST by feature), `lstat`, `disconnect`; operations serialized; signpost "list" |
| `AdbShell.swift` | `quote(_:)` — the only shell-escaping helper; `accessCheck(_:)`; `run(_:serial:)` over `shell:` |
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
- `AppKitBridges/FileTableView` — `NSViewRepresentable` over a view-based `NSTableView`; reloads only
  when `rowsVersion` changes; Return opens, type-select by name, icons cached per extension.
- `Services/` — `AppServices` (one `AdbSyncClient` per device + the shared `ListingCache`, injected via
  `.environment`), `ListingCache` (actor, in-memory, keyed by serial + path), `Log.swift`
  (`Logger.ui` / `Logger.transfer`, subsystem `dev.local.AdbFiles`, same as `Logger.adb`).

Filter logs with `log stream --level info --predicate 'subsystem == "dev.local.AdbFiles"'`
(use `/usr/bin/log` in zsh, where `log` is a builtin).

## Packaging

`scripts/build-app.sh` assembles `build/AdbFiles.app` from the SwiftPM binary, `Resources/Info.plist`
and a generated placeholder icon (`scripts/make-icon.sh`), then ad-hoc signs it. `build/` is gitignored.
