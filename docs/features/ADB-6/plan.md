# ADB-6 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-14

Pattern followed: AdbKit sessions as in ADB-4 (`AdbTransferSession`, `AsyncLimiter`, fake-device tests with gates),
an actor service with a protocol seam as `ListingCache`/`TransferEngine`, AppKit integration in
`AppKitBridges/FileTableView.swift`. New decision (extra interactive connection) → `docs/decisions/ADR-001`.

## Contract changes
- boundary: additive AdbKit API `readPrefix`, `openInteractiveSession`. CLAUDE.md connection rule updated
  (user decision): 1 listing + up to 2 transfers + 1 interactive per device.

## Requirements (ordered, each independently verifiable)

### R1 — Prefix reads and the interactive session (S)
- files: `Sources/AdbKit/AdbTransferSession.swift` (change: `readPrefix(_:maxBytes:)` — RECV, stop after N bytes,
  close the connection so the next call reopens), `Sources/AdbKit/AdbSyncClient.swift` (change:
  `openInteractiveSession()` with an `AsyncLimiter(limit: 1)`, independent of the transfer limiter; `disconnect()`
  covers it)
- test: `Tests/AdbKitTests/AdbSyncTransferTests.swift` — prefix of a 1 MB file returns exactly N bytes and the next
  call on the same session works; prefix larger than the file returns the whole file; interactive session opens
  while 2 transfer sessions are held at a gate (peak sync connections 3)
- executed how: live test reading 64 KB of a `DCIM/Camera` JPEG (read-only) and extracting the EXIF thumbnail

### R2 — `ThumbnailService` (M)
- files: `Sources/AdbFiles/Services/ThumbnailService.swift` (new, actor), `Services/ThumbnailSource.swift` (new:
  protocol seam for device reads; adapter over the interactive session), `Services/ThumbnailStrategy.swift` (new)
- behaviour: key = SHA-256 of `path|size|mtime`; disk cache `~/Library/Caches/AdbFiles/thumbs/<serial>/<key>.png`
  (writes off the main thread, atomic), in-memory cache of recent images; strategy by extension and size
  (`.jpg/.jpeg/.heic/.heif` → prefix 64 KB → embedded thumbnail, else full read if ≤ 10 MB; `.png/.webp/.gif/.bmp`
  ≤ 10 MB → full read; else none); generation limited to 2 at once; duplicate requests share one task;
  `cancel(path)` cancels a request nobody else waits for; `os_signpost` "thumbnail"; logs `thumb source=disk|memory|
  device bytes=N ms=N`
- test: `Tests/AdbFilesTests/ThumbnailServiceTests.swift` with a scripted source and a temp cache dir — key stable
  and changes with size/mtime; strategy table; EXIF from a 64 KB prefix of a JPEG generated in the test with an
  embedded thumbnail; no-EXIF JPEG ≤ 10 MB falls back to full read; > 10 MB → nil; disk hit makes no device read
  (also after a fresh service = relaunch); duplicates share one read; at most 2 concurrent (gated source, peak
  counter); cancelled request's result is dropped and frees the slot
- executed how: live in R4

### R3 — Quick Look (M)
- files: `Sources/AdbFiles/Features/Preview/PreviewController.swift` (new: QLPreviewPanel data source/delegate,
  download-to-cache via the interactive session, spinner state, cancellation on selection change),
  `Features/Preview/PreviewCache.swift` (new: paths under `~/Library/Caches/AdbFiles/preview/<serial>/<key>/<name>`,
  reuse when size+mtime match, cleared at launch), `AppKitBridges/FileTableView.swift` (change: Space toggles the
  panel; `acceptsPreviewPanelControl`/`begin`/`end` on the table subclass; selection changes update the panel),
  `Features/Browser/ContextMenu.swift` (change: Quick Look enabled)
- logging (`ui`): `preview open count=N`, `preview ready path=… source=cache|device ms=…`, `preview failed …`,
  `preview close`
- test: `Tests/AdbFilesTests/PreviewCacheTests.swift` — path keeps the file name/extension, reuse when unchanged,
  new download when size/mtime differ, clearing at launch; `PreviewControllerTests` with a fake downloader —
  folders skipped, selection change cancels the previous download, failure → alert, cached item → no download
- executed how (user-assisted, read-only on the device): Space on a photo, a PDF or text file, and a video in
  `DCIM/Camera` or `Download`; ↑/↓ follow; second open logs `source=cache`

### R4 — Thumbnails in the table + row size (M)
- files: `AppKitBridges/FileTableView.swift` (change: request thumbnails in `viewFor` for visible rows, cancel in
  `didRemove rowView`, apply on the main thread only to the row still showing that path; row height and icon size
  from the setting), `App/ViewCommands.swift` (new: View › Small Rows / Large Rows, `@AppStorage`),
  `Services/AppServices.swift` (change: owns `ThumbnailService` per serial)
- logging: `thumb …` as in R2, `apply thumbs n=… mainMs=…` per batch
- executed how: live, read-only: open `DCIM/Camera` with Large rows → log shows thumbnails for visible rows,
  `bytes=65536` per JPEG, first screen < ~2 s; scroll fast → cancellations logged, main-thread batches < 16 ms;
  relaunch → `source=disk` and no device reads; with two big uploads running (test folder), thumbnails and Quick
  Look still work (AC5)

### R5 — Docs (S)
- `docs/decisions/ADR-001-interactive-connection.md`, CLAUDE.md connection rule, `docs/ARCHITECTURE.md`,
  `README.md` (Space, View menu), spec ticks, `evidence.md`

## Final verification
Clean build 0 warnings; `swift test` 20×; live suites; AdbKit import grep; test folder (only used for AC5's uploads)
removed.

## Risks
| Risk | Impact | Cheapest way to find out early |
|------|--------|-------------------------------|
| QLPreviewPanel responder-chain control from an NSTableView inside SwiftUI | Space does nothing | Spike first in R3 with one hard-coded local file |
| Thumbnail callbacks applied to recycled rows | Wrong image on a row | Apply only if the row's current path matches; test with a fast scroll in R4 |
| 8k-row folders flood requests | Device reads for off-screen rows | Requests only from `viewFor`, cancelled on row removal; counted in the log |
| HEIC/other JPEGs without EXIF thumbnails | Many full downloads | ≤ 10 MB cap; logged `source=device bytes=` shows it |

## Assumptions
- Thumbnail pixel size 160 px (40 pt @2x × 2); preview cache cleared at each launch.
- Branch `feat/ADB-6-quicklook-thumbnails`, one commit per requirement, merge on the user's word.
