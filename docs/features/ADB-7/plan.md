# ADB-7 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-15 (v2, after analyze BLOCK #1)

Patterns followed:
- AdbKit host services as `AdbHostClient.version/features` (`oneShot`), tested on `FakeAdbServer`.
- Listing as `AdbSyncClient.performList`.
- Token-guarded `@MainActor` stores as `BrowserStore`, tested with `FakeListing`, `ManualClock` and `Gate`.
- Queue decisions as `TransferQueue.resolveDestination`.
- AppKit only through delegates / `FileTableView` coordinator — no `FileNSTableView` dragging-source overrides (ADB-5).

One rule change → `docs/decisions/ADR-002-listing-inactivity-timeout.md`, landed with the code and the CLAUDE.md
edit in R1 (as ADR-001 in ADB-6; user-approved 2026-11-15). Wi-Fi uses the same adb server — no ADR.

## Contract changes
- AdbKit, additive:
  - `AdbHostClient.pair(host:code:)`, `connect(host:)`, `disconnect(host:)`;
  - listing timeout semantics change: `listTimeout` becomes an inactivity limit (ADR-002; doc comment + CLAUDE.md
    wording "10 s of inactivity for listing", both in R1);
  - `AdbTransferSession.download(overwrite:)` doc: overwrite also allowed when the user chose Replace (R3).
- `TransferRequest.conflict: ConflictChoice` (`.keepBoth` default, `.replace`, `.skip` never enqueued).

## Requirements (ordered, each independently verifiable)

### R1 — Listing inactivity timeout (S)
- files:
  - `Sources/AdbKit/AdbSyncClient.swift`: `list`/`lstat` drop the total `withTimeout`; every `readAvailable` /
    `readExactly` / `sendRaw` gets `listTimeout`; the access-check shell keeps its own limit.
  - `Tests/AdbKitTests/AdbSyncClientTests.swift`: `FakeDevice.listChunkDelay`.
  - `docs/decisions/ADR-002-listing-inactivity-timeout.md` (new: context AC1, decision, consequence: no total cap);
    `CLAUDE.md` §Concurrency wording (references ADR-002).
- test (fake device, `listTimeout` 0.3 s):
  - a listing delivered in chunks 0.1 s apart that takes 1 s in total succeeds;
  - a device that stalls 0.5 s mid-listing → `.timeout`;
  - an existing silent-device test still times out.
- executed how: two 1 GB uploads into the test folder, then open `DCIM/Camera` → `list … entries=7948`, no
  `listing failed`.

### R2 — Finder-like multi-selection (S)
- spike first (not committed until the regression checklist passes):
  - (b) coordinator-only: record the mouse-down point (the table's `clickedRow`/`clickedColumn` and point via a
    local `NSEvent` monitor scoped to the table's window), and return `nil` from `pasteboardWriterForRow` outside
    the drag zone. The spike must prove that this gives drag-select and not a dead drag.
  - If (b) fails → (a) (user-approved fallback, 2026-11-15): override only `canDragRows(with:at:)` on
    `FileNSTableView`. It is a drag-initiation query, not an `NSDraggingSource` method. No other table override.
  - The chosen mechanism is recorded in evidence.
- files: `AppKitBridges/FileTableView.swift`:
  - the chosen mechanism allows a drag only when the mouse-down point lies in the Name cell's icon or the drawn text
    width;
  - a pure helper `DragZone.allowsDrag(point:iconFrame:textFrame:)`;
  - ⌘A checked (Edit › Select All reaches the table), fixed only if needed.
- test: `DragZoneTests` (inside icon, inside text, right of the text, other columns).
- executed how (user):
  - drag down from the Size column selects a range (`selection count=N`);
  - drag from a name still drags;
  - ⌘A / ⌘-click / ⇧-click;
  - regression checklist as ADB-6 R4: `promise write`, `drop upload`, `drop op=move|copy`, `via=breadcrumb`,
    `open path=`, `rename commit`.

### R3 — Conflict prompt before transfers (M)
- files:
  - `Features/Transfers/ConflictPlanner.swift` (new): grouping and questions on `@MainActor`; the existence check
    runs off the main actor, one call per target folder returning `Set<String>` (remote: a `list` of the folder;
    local: `FileManager.contentsOfDirectory` in a `nonisolated` async helper); asks through an injected
    `ask: (ConflictQuestion) async -> ConflictAnswer` (choice + apply-to-all); returns requests to enqueue.
  - `Features/Transfers/ConflictSheet.swift` (new: SwiftUI sheet; folders show only Keep Both / Skip).
  - `TransferItem.swift` (`conflict`).
  - `TransferQueue.swift`: `.replace` reserves the original name and sets overwrite. If the name is reserved by
    another item, it falls back to keep-both.
  - `TransferEngine.swift`: download `overwrite: true` (atomic via `.adbfiles-part`; doc comment of
    `AdbTransferSession.download` updated); upload passes `replace: true`.
  - `Sources/AdbKit/AdbTransferSession.swift`: `upload(_:to:replace:progress:)`. Replace never writes over the
    original: it uploads to `.<name>.adbfiles-part` in the same folder, then `mv -f -- part target` via `AdbShell` (a
    failed or cancelled upload leaves the original intact and removes the part).
  - Entry points: `TransferActions.swift`, `BrowserView.upload`, path-bar drop.
  - Drag to Finder (added by the user during R3): `AppKitBridges/FilePromiseDelegate.swift` — Finder hands over a
    URL it already renamed (`a 2.txt`); when the folder holds the original name, ask via `ConflictPrompt`. Replace
    writes the original name (download `overwrite`), Keep Both writes Finder's URL, Skip completes the promise with
    a user-cancelled error. Spike first: does Finder accept a write to a URL other than the one it promised?
- test: `ConflictPlannerTests` (fake listing, scripted answers):
  - no clash → no question;
  - file Replace / Keep Both / Skip;
  - apply-to-all asks once for N clashes;
  - folder never offered Replace;
  - one listing per target folder;
  - cancel → nothing enqueued.
- test: `TransferQueueTests`:
  - `.replace` overwrites (fake engine sees overwrite);
  - `AdbSyncTransferTests` (fake device + `FakeFileSystem`): a Replace upload cancelled mid-way leaves the original
    bytes and no part file; a completed one replaces them;
  - replace on a name reserved by another item → keep-both.
- executed how (test folder): upload `a.txt` twice → sheet → Replace (size changes, one file), Keep Both
  (`a 2.txt`), Skip (nothing); two clashes + apply-to-all → one sheet; Download To… a folder that has the file
  locally → sheet. Log `conflict ask n=… choice=… all=…`.

### R4 — Locations bookmarks (S)
- files:
  - `Features/Devices/Bookmarks.swift` (new: name, SF Symbol, path);
  - `DeviceSidebarView.swift` (Locations section; disabled without a usable device);
  - `App/RootView.swift`: per-window `@State` navigation request passed to the browser;
  - `BrowserView.swift` (`onChange` → `navigate(action: "bookmark")`);
  - `App/BrowserCommands.swift` (Go menu entries).
- test: `BookmarksTests` (paths); `BrowserStoreTests`: a bookmark request navigates and pushes Back history.
- executed how: click each entry → `navigate action=bookmark path=…`; Music absent → not-found state.

### R5 — Prefetch (M)
- files:
  - `Features/Browser/Prefetcher.swift` (new, `@MainActor`): 150 ms debounce on an injectable clock; skips
    cached folders; `Task(priority: .utility)`; exposes the in-flight path/task.
  - `BrowserStore.swift`: opening the prefetched folder awaits the prefetch; any other navigation cancels it first.
  - `FileTableView.swift`: hover through an `NSTrackingArea` owned by the coordinator (`mouseMoved`), plus
    selection; no table subclass changes.
  - signpost "prefetch".
- test: `PrefetcherTests` (ManualClock, FakeListing, Gate):
  - < 150 ms → no list;
  - > 150 ms → one list into the cache;
  - cached → none;
  - hover A then B quickly → only B;
  - open the prefetched folder → one listing total, `source=cache`;
  - open another folder during a gated prefetch → the prefetch is cancelled before the navigation lists.
- executed how: hover `Download` for ~0.5 s, then open → `prefetch done path=…`, `navigate … source=cache`.

### R6 — Wi-Fi debugging (M)
- spike first (not committed): confirm the `host:pair:<code>:<host:port>`, `host:connect:<host:port>` and
  `host:disconnect:<host:port>` request formats and their replies against AOSP `adb/client/commandline.cpp` and
  `adb_client.cpp`, and with the real server (`connect 127.0.0.1:1` → "failed to connect …" text).
- files:
  - `Sources/AdbKit/AdbHostClient.swift`: the three calls; they parse "connected to" / "already connected" /
    "Successfully paired" vs failure text into `AdbError.serverFailure(message)`.
  - `Features/Devices/WifiConnectSheet.swift` (new) and `WifiConnectModel.swift` (new, `@Observable`).
  - `App/FileCommands.swift` (File › Connect via Wi-Fi…).
  - `DeviceRow.swift` (Disconnect for `host:port` serials).
- test: `AdbHostClientTests` on `FakeAdbServer`: exact request strings; success and failure texts; FAIL replies.
  `WifiConnectModelTests`: validation of host:port and 6-digit code; busy state; error mapping.
- executed how (user, phone in Wireless debugging): pair with a code → `wifi pair ok`; connect → device appears
  (`devices count=2` while USB is attached too); browse `/sdcard`; disconnect → it leaves.

### R7 — Thumbnail connection reuse (measured) + cache limit (S)
- first: measure the open+close cost per read from the existing logs vs an instrumented run (`interactive open ms`).
  `readPrefix` (all JPEG/HEIC) drops its connection by design, so reuse can only help full reads (PNG/WebP/GIF/BMP,
  no-EXIF fallback) and Quick Look. Build reuse only if those are frequent in DCIM **and** p50 > 20 ms:
  `AdbSyncClient` then parks the interactive session's connection on a clean `close()` and reuses it on the next
  `openInteractiveSession`, dropped on `disconnect()`. In every other case record the numbers and change nothing.
- files: `Services/ThumbnailCacheTrimmer.swift` (new: at launch off the main thread, > 500 MB → 400 MB by oldest
  modification date); `AppServices.swift`.
- test: `ThumbnailCacheTrimmerTests` (temp dir, fake sizes/dates); reuse (if built):
  `interactiveSessionReusesTheParkedConnection` on the fake server (one `host:transport` for two reads).
- executed how: launch logs `thumb trim before=… after=…`; DCIM scroll `thumb source=device` ms before/after.

### R8 — Signposts and shortcuts review (S)
- files: `PreviewDownloader.swift` (signpost "preview"), `README.md` (Instruments: os_signpost, subsystem
  `dev.local.AdbFiles`), shortcut gaps found against CLAUDE.md fixed in `App/*Commands.swift`.
- test: none beyond build (no behaviour); a checklist table in evidence.
- executed how: `xctrace record --template 'Logging'` (or Instruments) while browsing → the five intervals listed.

### R9 — Drag hint (droppable) (M)
- spike first:
  - the hint is updated only from drop destinations (table `validateDrop`, path-bar segments `DropDelegate`);
  - it is shown in a borderless, mouse-transparent child window placed at `draggingLocation`;
  - it is hidden on exit / drop / drag end (from the coordinator's existing `endedAt`);
  - no `FileNSTableView` override.
  - Verify all regression drags before continuing. **Breaks anything → revert, mark AC9 dropped (user decision).**
- files: `AppKitBridges/DragHintWindow.swift` (new), `FileTableView.swift`, `BreadcrumbBar.swift`.
- test: `DragHintTextTests` (move/copy/upload text per target).
- executed how: drag over a folder row, ⌥, a path segment, from Finder → hint text; full regression checklist.

### R10 — Docs (S)
- `docs/ARCHITECTURE.md` (incl. the download overwrite row), `README.md` (Locations, Wi-Fi, conflicts, selection,
  Instruments), spec ticks, `evidence.md`.

## Final verification
Clean build 0 warnings; `swift test` 20×; live suites (read-only + write suites in the test folder); AdbKit
import grep; test folder removed.

## Risks
| Risk | Impact | Cheapest way to find out early |
|------|--------|-------------------------------|
| Refusing a row drag doesn't give drag-select in a view-based table | AC2 fails | R2 spike (b), then approved fallback (a) `canDragRows(with:at:)` |
| `host:pair` format differs between adb versions | Pairing fails | R6 spike against AOSP and the installed adb (`adb version`) |
| Prefetch occupies the single listing connection when the user navigates | Slower navigation | Cancel-before-navigate + reuse, gated test; `navigate ms` live |
| Conflict check listing slow under load | Sheet appears late | Reuses R1; check uses the cached listing when fresh |
| Drag hint breaks drag & drop a third time | Regression | Spike + checklist before any commit; drop per user decision |

## Not verified by design
- Two devices at once over USB (one phone); Wi-Fi + USB of the same phone shows two entries instead.

## Assumptions
- Prefetch only for folders (not symlinks); hover through a tracking area on the table.
- Cache limit 500 MB → 400 MB; not configurable.
- Branch `feat/ADB-7-polish`, one commit per requirement, merge on the user's word.
