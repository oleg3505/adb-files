# ADB-3 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-14

Pattern followed: AdbKit protocol code as in ADB-2 (`HostProtocol.swift` incremental decoder + fixtures,
`AdbConnection` actor, fake-server tests in `Tests/AdbKitTests/FakeAdbServer.swift`); app state as in
`Sources/AdbFiles/Features/Devices/DeviceStore.swift` (`@Observable @MainActor`, logged phases). New:
first `NSViewRepresentable` (`AppKitBridges/`) and first app test target — both prescribed by CLAUDE.md /
the user's answer, so no ADR.

## Contract changes
- boundary: new public AdbKit API (`RemoteFile`, `SyncProtocol`, `SyncListDecoder`, `AdbShell`,
  `AdbSyncClient`, `AdbHostClient.features(serial:)`); `AdbConnection` gains `sendRaw` / `readExactly`.
  Additive; only consumer is the app.
- package: new test target `AdbFilesTests` depending on `AdbFiles` + `AdbKit`.
- data: none (cache is in memory).

## Requirements (ordered, each independently verifiable)

### R1 — `AdbFilesTests` target + `DeviceStore` loop tests (M)
- files: `Package.swift` (add test target), `Sources/AdbFiles/Features/Devices/DeviceStore.swift` (change:
  inject `DeviceTracking` / `ServerStarting` protocols and a `sleep` closure; defaults are the real
  `AdbHostClient` / `AdbServerLauncher`), `Tests/AdbFilesTests/DeviceStoreTests.swift` (new)
- test: scripted fakes — server not running → start once → ready; start fails → `.failed` keeps adb's
  message; adbNotFound → `.adbMissing` and loop stops; stream ends → reconnect, backoff 0.5→1→2 s reset
  on success; `retry()` during backoff doesn't let the old loop write state; selection auto-picks first usable
- executed how: `swift test --filter AdbFilesTests` → pass; app still runs (launch + `adb kill-server` log, as ADB-2 (c))
- risk: `@testable import` of an executable target — first thing done; if it fails, stop and ask (F2)

### R2 — Sync framing, `RemoteFile`, features, shell quoting (M)
- files: `Sources/AdbKit/RemoteFile.swift` (new: name, path, mode, size `UInt64`, mtime, error;
  isDirectory/isSymlink/isHidden), `Sources/AdbKit/SyncProtocol.swift` (new: request encoding with
  1024-byte limit; `SyncListDecoder` for DENT/DNT2/DONE/FAIL; `LST2`/`STAT` reply decoding),
  `Sources/AdbKit/AdbShell.swift` (new: `quote(_:)` per CLAUDE.md, `command(_:args:)` builder),
  `Sources/AdbKit/AdbHostClient.swift` (change: `features(serial:)`)
- test: `Tests/AdbKitTests/SyncProtocolTests.swift` — the live `DNT2` capture (`Android`, mode 040770,
  size 3488, mtime 1628903696) byte-for-byte; DENT v1; DONE v1/v2 tails; FAIL + message; entries split
  across chunks; Cyrillic/emoji names; size > 4 GB; path > 1024 → error. `Tests/AdbKitTests/AdbShellTests.swift`
  — spaces, `'`, Cyrillic, emoji, newline, `$()`, empty string
- executed how: `swift test`; Python probe output above is the cross-check

### R3 — `AdbSyncClient` actor (L)
- files: `Sources/AdbKit/AdbConnection.swift` (change: `sendRaw`, `readExactly`, `openTransport(serial:service:)`),
  `Sources/AdbKit/AdbSyncClient.swift` (new: one persistent listing connection per device, lazily opened,
  dropped on error and reopened on next call; `list(_:)` picks LIS2/LIST from features; `lstat(_:)`;
  empty-result disambiguation → `AdbError.notFound` / `.permissionDenied`; 10 s timeout; cancellation
  closes the connection; `os_signpost` interval "list"), `Sources/AdbKit/AdbError.swift` (change: new cases)
- test: `Tests/AdbKitTests/AdbSyncClientTests.swift` on `FakeAdbServer` — transport+sync handshake, LIS2
  stream of 3 entries, chunked delivery, FAIL, empty→LST2 error 2→notFound, empty→denied via shell reply,
  reconnect after server closes, timeout. `Tests/AdbKitTests/LiveDeviceTests.swift` — `/sdcard/` and
  `/data/` against a real device, skipped unless `ADB_TEST_SERIAL` is set
- executed how: `ADB_TEST_SERIAL=9A251FFAZ0073G swift test --filter LiveDevice` → pass, with timing of
  `/sdcard/DCIM/Camera/` logged

### R4 — Browser logic: `BrowserStore`, `ListingCache`, sorting (M)
- files: `Sources/AdbFiles/Features/Browser/BrowserStore.swift` (new: `@Observable @MainActor`; path,
  back/forward stacks, phase `.loading/.loaded/.empty/.denied/.notFound/.failed`, sort descriptor,
  showHidden, displayed rows computed off the main thread; cancels the in-flight listing on navigation),
  `Features/Browser/FileSorting.swift` (new: folders first, `localizedStandardCompare`, size/date/kind),
  `Services/ListingCache.swift` (new: actor keyed by serial+path; SWR; returns `changed: Bool` by name+size+mtime diff)
- test: `Tests/AdbFilesTests/BrowserStoreTests.swift`, `FileSortingTests.swift`, `ListingCacheTests.swift` —
  history semantics (Back after navigate, Forward cleared on new navigate, Up), cached listing shown before
  the fetch completes, unchanged refresh doesn't bump the rows version, hidden filter, sort orders, stale
  result after navigating away is discarded
- executed how: tests; live run in R5

### R5 — UI: table, breadcrumbs, toolbar, commands, states (L)
- files: `Sources/AdbFiles/AppKitBridges/FileTableView.swift` (new: `NSViewRepresentable` + Coordinator as
  data source/delegate; columns with sort descriptors; multi-selection; double-click and Enter → open;
  type-select string = name; icon/kind cache by extension), `Features/Browser/BrowserView.swift` (new),
  `Features/Browser/BreadcrumbBar.swift` (new), `Features/Browser/BrowserStateView.swift` (new: empty /
  denied / not found / failed + Retry), `App/BrowserCommands.swift` (new: `FocusedValue` + menu items
  with shortcuts), `Features/Browser/BrowserPlaceholderView.swift` (change → hosts `BrowserView` for a
  usable device), `App/AdbFilesApp.swift` (change: `.commands`)
- logging for evidence (`ui`): `navigate path=… source=cache|device entries=N ms=…`, `refresh changed=…`,
  `sort key=… asc=…`, `hidden=…`, `open path=…`, `selection count=N`, `phase=…`
- executed how (log-asserted; ⌨/🖱 steps user-assisted at the end): (a) select Pixel 4 → `/sdcard/` listed
  (AC1); (b) open DCIM → Camera, timing + UI responsive (AC6); (c) Back/Forward/Up/breadcrumb (AC2);
  (d) re-enter Camera → `source=cache` < 100 ms then `refresh changed=false` (AC5); (e) ⌘↑ from
  `/sdcard/` to `/`, open `data` (AC7 denied); an already-empty folder found with `adb shell find /sdcard
  -maxdepth 3 -type d -empty` (AC7 empty); not-found is covered by the live `lstat`/`list` test on a missing
  path and fake-server tests (no UI path reaches a missing folder without file operations); (f) **no files
  are created on the phone (user's decision)**: AC6 uses Camera (7,948); AC10 uses fixtures, plus any
  existing non-ASCII names found with `adb shell find /sdcard -maxdepth 4 -name '*[! -~]*'`;
  (g) unplug during Camera listing (AC8); (h) user: sort headers, ⌘⇧., ⌘R, multi-select, type-select (AC3, AC4, AC9)

### R6 — Docs (S)
- `docs/ARCHITECTURE.md` (AdbSyncClient, Browser, AppKitBridges, test targets), `README.md`
  (`ADB_TEST_SERIAL`), spec ticks + `evidence.md`; update the deferred-tests memory note

## Final verification (after R5)
`swift package clean && swift build --build-tests 2>&1 | grep -c 'warning:'` → 0; `swift test` → pass;
`ADB_TEST_SERVER=1 ADB_TEST_SERIAL=… swift test` → pass; `grep -rnE '^import (SwiftUI|AppKit)' Sources/AdbKit` → empty.

## Risks
| Risk | Impact | Cheapest way to find out early |
|------|--------|-------------------------------|
| `@testable import` of an executable target fails or links `main` twice | R1 blocked | Done first in R1 with one trivial test |
| NSTableView ↔ SwiftUI state sync (selection/sort loops, reload churn) | Janky table | Rows carry a version; Coordinator reloads only on version change; 10k-file folder run in R5 (f) |
| Listing 8–10k entries is slow (~1.2 s in the Python probe) | Slow first open | Bulk-buffer decoding; signpost + `ms=` log; cache makes revisits instant |
| Empty-vs-denied needs a `shell:` round-trip | Extra latency on empty folders | Only when 0 entries; measured in (e) |

## Assumptions
- Start folder `/sdcard/`; one browser per window; cache in memory per app session.
- Navigation/refresh/hidden shortcuts are part of M3 (they belong to these features); delete/new-folder shortcuts are not.
- Branch `feat/ADB-3-browsing`, one commit per requirement, merge to `main` on the user's word.
