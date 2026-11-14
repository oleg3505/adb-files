# ADB-6 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-14 (v2, after analyze BLOCK #1)

Pattern followed: AdbKit sessions as in ADB-4 (`AdbTransferSession`, `AsyncLimiter`, fake-device tests with gates),
an actor service with a protocol seam as `ListingCache`/`TransferEngine`, token-guarded async results as in
`BrowserStore`, AppKit integration in `AppKitBridges/FileTableView.swift`. New decision (extra interactive
connection) → `docs/decisions/ADR-001`, landed with the code that introduces it (R1).

## Contract changes
- boundary: additive AdbKit API `readPrefix`, `openInteractiveSession(priority:)`, `AsyncLimiter.acquire(priority:)`.
  CLAUDE.md connection rule (user decision): 1 listing + up to 2 transfers + 1 interactive per device.
- `AdbFiles` may also import ImageIO, CryptoKit and Quartz (QLPreviewPanel) — `docs/ARCHITECTURE.md` updated in R1.

## Requirements (ordered, each independently verifiable)

### R1 — Prefix reads, prioritised interactive session, ADR (S)
- spike first (not committed): `QLPreviewPanel` driven from the table with one hard-coded local file — proves the
  responder chain inside SwiftUI before anything else is built; outcome noted in evidence.
- files: `Sources/AdbKit/AdbTransferSession.swift` (change: `readPrefix(_:maxBytes:)` — RECV, stop after N bytes,
  close the connection so the next call reopens), `Sources/AdbKit/AsyncLimiter.swift` (change: `acquire(priority:)`
  — `.high` waiters go before `.normal` ones, FIFO within a priority), `Sources/AdbKit/AdbSyncClient.swift`
  (change: `openInteractiveSession(priority:)` on its own limiter of 1; `disconnect()` covers it),
  `docs/decisions/ADR-001-interactive-connection.md` (new), `CLAUDE.md` (connection rule), `docs/ARCHITECTURE.md`
  (imports)
- test: prefix of a 1 MB file returns exactly N bytes and the next call on the same session works; prefix larger
  than the file returns it all; interactive session opens while 2 transfer sessions are held at a gate (peak 3);
  **limiter: a `.high` acquire queued after three `.normal` ones gets the slot next** (gated, deterministic)
- executed how: live (read-only) — 64 KB of a `DCIM/Camera` JPEG → EXIF thumbnail extracted

### R2 — `ThumbnailService` (M)
- files: `Sources/AdbFiles/Services/ThumbnailService.swift` (new, actor), `Services/ThumbnailSource.swift` (new:
  seam for device reads; adapter over the interactive session at `.normal` priority),
  `Services/ThumbnailStrategy.swift` (new)
- behaviour: key = SHA-256 of `path|size|mtime`; disk cache `~/Library/Caches/AdbFiles/thumbs/<serial>/<key>.png`
  (atomic writes off the main thread) plus an in-memory cache; strategy by extension and size (`.jpg/.jpeg/.heic/
  .heif` → 64 KB prefix → embedded thumbnail, else full read if ≤ 10 MB; `.png/.webp/.gif/.bmp` ≤ 10 MB → full read;
  else none). **Device reads go one at a time over the single interactive connection; "at most 2" is decode/scale
  concurrency.** Duplicate requests share one task; each request has a token: a cancelled or superseded request's
  result is dropped — never cached as empty/failure, never reported as an error; `cancelAll(serial)` when the device
  leaves, the browser closes or the folder changes. Logs: `thumb source=disk|memory|device bytes=N ms=N`,
  `thumb cancel path=…`, `thumb drop stale path=…`; `os_signpost` "thumbnail"
- test: `Tests/AdbFilesTests/ThumbnailServiceTests.swift` (scripted source, temp cache dir): key stable and changes
  with size/mtime; strategy table; EXIF from a 64 KB prefix of a JPEG generated in the test; no-EXIF JPEG ≤ 10 MB →
  full read; > 10 MB → nil; disk hit → no device read (also with a fresh service = relaunch); duplicates share one
  read; at most 2 decodes at once (gated, peak counter); **cancelled request → nothing cached, no error, slot freed;
  late completion after cancel → dropped**; `cancelAll` stops pending reads

### R3 — Quick Look (M)
- files: `Sources/AdbFiles/Features/Preview/PreviewController.swift` (new: QLPreviewPanel data source/delegate;
  downloads via the interactive session at **`.high` priority**, so Space never waits behind thumbnail reads;
  token per request; `previewPanel(_:handle:)` forwards ↑/↓ key-downs to the table), `Features/Preview/
  PreviewCache.swift` (new: `~/Library/Caches/AdbFiles/preview/<serial>/<key>/<name>`, reuse when size+mtime match,
  cleared at launch), `AppKitBridges/FileTableView.swift` (change: **only** Space in `keyDown` and the three
  `QLPreviewPanelController` methods on the table subclass — no dragging-source overrides), `ContextMenu.swift`
  (Quick Look enabled)
- Space behaviour: always toggles Quick Look, like Finder (type-select keeps working for the part before a space).
- logging (`ui`): `preview open count=N`, `preview ready path=… source=cache|device ms=…`, `preview cancelled path=…`,
  `preview failed path=… reason=…`, `preview close`, `preview wait ms=…` (time from Space to download start)
- test: `PreviewCacheTests` — name/extension kept, reuse when unchanged, re-download when size/mtime differ, cleared
  at launch; `PreviewControllerTests` (fake downloader, tokens): folders skipped; multi-selection → N items;
  selection change cancels the previous download; **cancelled → no alert, no `failed`, panel items unchanged;
  late completion of A after B started → ignored**; failure → alert; cached → no download; device gone → spinner
  stops + alert
- executed how (user-assisted, read-only on the device): Space on a photo, a PDF/text file and a video; ↑/↓ follow;
  second open logs `source=cache`; **Space while `DCIM/Camera` thumbnails are still loading → `preview wait ms` small**;
  multi-selection → `preview open count=3`

### R4 — Thumbnails in the table + row size (M)
- files: `AppKitBridges/ThumbnailBinder.swift` (new, `@MainActor`: request when a row shows a path, cancel when it is
  removed, apply only when the row still shows that path and token, reset a reused cell to the system icon at once),
  `AppKitBridges/FileTableView.swift` (change: uses the binder from `viewFor` / `didRemove rowView`; row height and
  icon size from the setting), `App/ViewCommands.swift` (new: View › Small Rows / Large Rows, `@AppStorage`),
  `Features/Browser/RowSize.swift` (new: size → row height, icon pt, thumbnail px), `Services/AppServices.swift`
  (change: one `ThumbnailService` per serial; `cancelAll` on device gone / browser close / folder change)
- logging: `rowSize=small|large` at launch and on change; `apply thumbs n=… mainMs=…` per batch
- test: `ThumbnailBinderTests` (fake cells): reuse resets to the icon; late result for a recycled row is dropped
  (`thumb drop stale`); removal cancels; `RowSizeTests` mapping
- executed how (read-only device): Large rows in `DCIM/Camera` → thumbnails for visible rows, `bytes=65536` per JPEG,
  first screen ≲ 2 s; fast scroll → `thumb cancel` / `thumb drop stale` counted, batches < 16 ms; relaunch →
  `source=disk`, no device reads; Small rows + relaunch → `rowSize=small`, 16 pt thumbnails; AC5: two big uploads in
  `/sdcard/Download/AdbFilesTest/` while browsing thumbnails and pressing Space (folder removed afterwards)
- **regression (user-assisted, each matched to an existing log line):** drag a row to Finder (`promise write`),
  Finder → table (`drop upload`), row → folder row and ⌥ (`drop op=move|copy`), path-bar drop (`via=breadcrumb`),
  Return opens (`open path=`), type-select (user-observed; no log line), inline rename with a space in the name (`rename commit`)

### R5 — Docs (S)
- `docs/ARCHITECTURE.md`, `README.md` (Space, View menu), spec ticks, `evidence.md`

## Final verification
Clean build 0 warnings; `swift test` 20×; live suites; AdbKit import grep; test folder removed.

## Risks
| Risk | Impact | Cheapest way to find out early |
|------|--------|-------------------------------|
| QLPreviewPanel responder chain from an NSTableView inside SwiftUI | Space does nothing | Spike at the start of R1 |
| Table subclass changes break drag & drop again (ADB-5) | Regression | Only keyDown + QLPreviewPanelController methods; regression checklist in R4 |
| Previews queued behind thumbnail reads | Slow Space | `.high` priority acquire; test + `preview wait ms` live |
| Recycled rows show wrong thumbnails | Wrong images | `ThumbnailBinder` path+token check, unit-tested |
| 8k-row folders flood requests | Pointless device reads | Visible rows only; cancel on removal and folder change; counted in logs |

## Not verified by design
- AC4's "changed file gets a new thumbnail" on hardware (unit test only; no writes allowed outside AC5's uploads).

## Assumptions
- Thumbnail pixel size 160 px; preview cache cleared at each launch.
- Branch `feat/ADB-6-quicklook-thumbnails`, one commit per requirement, merge on the user's word.
