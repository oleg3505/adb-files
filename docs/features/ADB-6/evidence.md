# ADB-6 — evidence

No remote, so no PR (local branch, merge on the user's word). App lines come from
`/usr/bin/log show --info --predicate 'subsystem == "dev.local.AdbFiles"'`. Device: Pixel 4, `DCIM/Camera` holds
7,948 entries. The only device writes were for AC5, all inside `/sdcard/Download/AdbFilesTest` (user-approved). The
folder was removed afterwards (`ls` → "No such file or directory").

### Verification
- build: clean `swift build --build-tests` → 0 warnings, after every requirement.
- tests: 247 passed (was 208). The full suite ran 20× → 0 failures.
- live (read-only): `ADB_TEST_SERVER=1 ADB_TEST_SERIAL=PIXEL4SERIAL01 swift test --filter Live` → 21 passed. This
  includes `cameraJpegThumbnailFromA64KBPrefix`: a 64 KB prefix of a camera JPEG yields its EXIF thumbnail. Write
  suites were skipped by design (writes were approved for AC5 only).
- `AdbKit` imports: `grep -rnE "^import (SwiftUI|AppKit|Quartz)" Sources/AdbKit` → 0.
- mutation checks (each restored afterwards):
  - Removing the binder's path+token check fails 4 `ThumbnailBinderTests`, including
    `recycledCellDropsTheLateResultAndCancelsTheOldRequest`.
  - Removing the preview controller's token guards *and* its post-download cancellation check fails
    `lateCompletionOfASupersededRequestIsIgnored`. With only one of the two layers removed the test still passes:
    the other layer catches it.

### Executed (user-assisted; results checked against the logs)
- **R1 spike**: `QLPreviewPanel` driven from the table works when the app is launched as a bundle (`open`). A bare
  terminal executable never became active, so the responder chain failed. Spike code was reverted before R1.
- **R2**: a real Pixel JPEG gives a 283×504 embedded thumbnail (15,945 bytes) from 64 KB; 16 KB is not enough.
  ImageIO decodes a *truncated main image* even with `…FromImageIfAbsent = false`, so `ExifThumbnail` extracts
  the complete IFD1 JPEG itself.
- **R3 Quick Look** (AC1, AC2):
  - Space on a photo → `preview open count=1`, `preview wait ms=0`, `preview ready … source=device ms=183`.
  - Second open → `source=cache ms=0`.
  - Holding ↓ with the panel open → 32 photos followed; 15 superseded downloads logged as `preview cancelled`, with
    no alert.
  - Video → `….mp4 source=device ms=2892`.
  - PDF → `/sdcard/Download/1139695152479732.pdf source=device ms=50`.
  - 3 selected → `preview open count=3` (3 × `ready`).
  - Context menu → Quick Look (user-observed).
- **R4 thumbnails** (AC3, AC4, AC6):
  - First screen: listing done 22:30:04.719 → 16 thumbnails by 22:30:05.688 (≈ 1 s).
  - 149 of 155 device reads were `bytes=65536`. The PANO JPEG without an EXIF thumbnail took a full read
    (4,832,836 bytes); PNGs took full reads.
  - Per-thumbnail ms: p50 65, p95 347. Batches: max `apply thumbs … mainMs=1.49`. 29 `thumb cancel` while
    scrolling. No wrong thumbnails (user-observed).
  - Relaunch: Large rows kept (`rowSize=large`). None of the 10 device reads after relaunch was for a file read
    before; all repeats came from the disk cache (`thumb source=disk` ×14 in the later run).
  - Small rows: `rowSize=small`, 16 pt thumbnails (user-observed).
- **AC5** (two 1 GB uploads, `drop upload items=2`, 2 × `transfer start`, ≈ 10 MB/s each):
  - Space on a photo during both uploads → `preview wait ms=0`, `preview ready … ms=1036`.
  - Thumbnails kept appearing, but only from the disk cache (`thumb source=disk` ×14).
  - Device thumbnail reads during transfers were **not** observed live, because the `DCIM/Camera` listing itself
    timed out under that load (see Deferred). The interactive connection is independent of transfer slots by unit
    test (`interactiveSessionIsIndependentOfTransferSlots`, peak 3).
- **Regression checklist (ADB-5)**:
  - `promise write url=…/a.txt` (drag to Finder)
  - `drop upload items=2` (Finder → table)
  - `drop op=move … dest=…/sub` and `drop op=copy … dest=…/sub` (⌥)
  - `drop op=move … via=breadcrumb`
  - `open path=…/sub` (Return)
  - `rename commit` of a name typed with a space (`прп р .txt`): Space typed into the name, no Quick Look
  - type-select (user-observed)

### Found during verification and fixed
- Truncated JPEGs decoded as partial images: see R2 above (`ExifThumbnail`).
- Decoding ran on the `ThumbnailService` actor, so there was never more than 1 decode at a time
  (`atMostTwoDecodesAtOnce` peaked at 1) → decoding moved to a detached task after the decode gate.
- `PreviewController` hung the compiler (type inference in a large `Task` closure) → the loop moved into a method.

### Not verified
- AC4 "a changed file gets a new thumbnail" on hardware (unit test only; by design, no writes outside AC5).
- Device-gone during a preview download on hardware (unit test `deviceGoneMidDownloadStopsTheSpinnerWithAnAlert`).

### Notes
- A file dragged to Finder while both transfer slots were busy waited in the queue. Meanwhile it was moved into
  `sub`, so the download failed with "No such file or directory" and Retry. This is ADB-4 queue behaviour, not an
  ADB-6 change.
- Per-browser cancellation unbinds only that browser's requests (per-waiter cancel), not `cancelAll`. Another
  window may show the same device. `cancelAll` runs when the device leaves.

### Self-review
`code-reviewer` on `main..HEAD`: 1 blocking, 4 should-fix, 3 nits. The blocking finding and all four should-fix
findings are fixed; tests 247 → 252.
- **Blocking**: a result queued for the next batch could land on a cell reused in between, e.g. a photo on a folder
  row. Batches now re-check the cell's path, and rebinding or unbinding drops the cell's queued results.
  - Tests: `resultQueuedForABatchIsDroppedWhenTheCellIsReusedBeforeTheBatch`, `batchRechecksThePathWhenApplied`.
  - Mutation check: removing both checks fails both tests.
- Quick Look panel wiring:
  - The panel keeps its data source unretained; the table now clears it in `endPreviewPanelControl` even when the
    presenter is already gone.
  - A table accepts the panel only while its presenter wants it, so a second window never shows leftover items.
  - Items are cleared on end.
  - Quick Look from the context menu first makes the table first responder.
- Thumbnail cancellation was keyed by file and sent in a separate task, so it could be lost or hit the wrong
  request. It is now per waiter and per generation via `withTaskCancellationHandler`, and an already-cancelled
  caller starts no read.
  - Tests: `oneWaiterWithdrawingKeepsTheSharedReadForTheOther`, `alreadyCancelledCallerStartsNoRead`.
- Files with no thumbnail are remembered in memory by key, so a broken JPEG is not re-read on every scroll
  (`fileWithoutAThumbnailIsNotReadAgain`).
- Nits not changed, candidates for M7:
  - each thumbnail read opens a fresh interactive connection;
  - a file of exactly `maxBytes` drops a good connection;
  - nothing limits the thumbnail cache size.
- Executed after the fixes (user, read-only): fast scrolling in Large rows → 255 thumbnails, 10 `thumb cancel`, max
  `apply thumbs … mainMs=1.75`; Space + ↓ + Esc; Quick Look from the context menu with focus in the sidebar; ⌘W with
  the panel open → no crash, no diagnostic report.

### Environment observation (again, as in ADB-5)
- At 22:55–23:10 the same `NWError 48 EADDRINUSE` returned in the parallel suite. It hit 3–4 fake-server tests that
  reconnect after closing a connection (`readPrefixReturnsExactly…`, `cancelAtGateLeavesNoFiles`,
  `folderDownloadContinues…`, `closedPortIsServerNotRunning`).
- It happened on the committed HEAD without the review fixes too, which had passed 20/20 at 22:45.
- The same tests pass alone, and the whole suite passes with `--no-parallel` (252/252). `AdbFilesTests` passed
  5/5.
- The review fixes touch only app code. Not investigated further in ADB-6.
- After the fix commit the episode had ended: the parallel suite passed 10/10 (252 tests).

### Deferred to M7 (user decision, 2026-11-14)
- **Listing timeout under transfer load**: the 10 s *total* listing timeout made `DCIM/Camera` fail 4× during two
  1 GB uploads (an earlier run under the same load took 7.5 s). Proposed fix: a 10 s inactivity timeout.
- **Ask on upload name conflicts**: uploads silently keep both (`big 1 2.bin`, `big 3.bin`; ADB-4 AC10). The user
  wants names checked first, with Replace / Keep Both / Skip.
- The drag hint next to the cursor (from ADB-5).
