# ADB-4 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-14 (v2, after analyze BLOCK #1)

Pattern followed: protocol code as in ADB-3 (`SyncProtocol.swift` incremental decoder + byte fixtures,
`AdbSyncClient` actor, `FakeDevice` in `Tests/AdbKitTests/AdbSyncClientTests.swift`); app state as
`BrowserStore` (`@Observable @MainActor`, protocol seam for tests, generation-style guards); AppKit
bridging as `AppKitBridges/FileTableView.swift`. No new pattern → no ADR.

## Contract changes
- boundary: additive AdbKit API — `SyncProtocol` SEND/RECV/DONE encoding, `SyncRecvDecoder`,
  `AdbSyncClient.download/upload/walk`, `TransferProgress`. Only consumer: the app.
- data: none (queue in memory).

## Requirements (ordered, each independently verifiable)

### R1 — SEND/RECV framing + `SyncRecvDecoder` (S)
- files: `Sources/AdbKit/SyncProtocol.swift` (change), `Tests/AdbKitTests/SyncTransferProtocolTests.swift` (new)
- test: SEND spec `path,mode` (decimal), DATA chunking ≤ 65,536, DONE + mtime; RECV decoder on the live
  header `44415441 00000100` (64 KiB chunk), DONE + 4 bytes, FAIL message, byte-by-byte delivery; SEND
  reply OKAY/FAIL
- executed how: `swift test`; fixtures match the Python probe above

### R2 — Transfers in `AdbSyncClient` (L)
- files: `Sources/AdbKit/AdbSyncClient.swift` (change: `download(_:to:progress:)`, `upload(_:to:progress:)`,
  `walk(_:)` remote recursive listing; transfer-connection limiter = 2, independent of the listing
  connection), `Sources/AdbKit/TransferIO.swift` (new: temp `*.adbfiles-part`, rename, set mtime, local
  walk), `Sources/AdbKit/AdbConnection.swift` (change: per-read inactivity timeout helper)
- behaviour: every read/write uses a 15 s inactivity timeout **per read/write** (injectable for tests),
  none overall; cancellation closes the connection; download failure/cancel deletes the temp file; a
  stale `name.adbfiles-part` from a previous run is deleted before writing; final rename is a
  no-overwrite move (`FileManager.moveItem`, fails if the target exists → caller picks the next name;
  never `replaceItemAt`); directory mtimes set post-order (after their contents); upload cancel relies
  on adbd deleting the partial (verified) and is asserted by `LST2` live; `walk` runs on a transfer
  connection (never the listing one, so browsing is not blocked); folder transfers skip a file that
  already exists at the target with the same size and mtime (folder Retry); an unreadable file inside
  a folder is recorded as a per-file failure and the walk continues; `disconnect()` closes the listing
  **and** transfer connections; `os_signpost` interval "transfer"
- test: `Tests/AdbKitTests/AdbSyncTransferTests.swift` on `FakeDevice` extended with RECV/SEND, a
  **chunk gate** (pause after N chunks until released) and a **peak open transfer connections**
  counter — no sleeps decide outcomes: bytes identical, temp renamed, mtime set; FAIL →
  `AdbError.serverFailure`; cancel at the gate → no temp/target file; inactivity with fixed margins
  (limit 300 ms; steady chunk every 100 ms for 1.5 s must succeed; stall 700 ms must fail — fails if
  the limit were applied once overall); 3 downloads held at the gate → peak connections == 2; folder
  walk both ways (nested, empty folder, symlink skipped, unreadable file → per-file failure + rest
  copied); folder retry skips completed files; stale `.adbfiles-part` removed; target-exists move fails
  instead of overwriting. `LiveDeviceTests`: download
  `/system/fonts/NotoSerifCJK-Regular.ttc`, SHA-1 vs device; write tests gated by `ADB_TEST_WRITE=1`:
  upload/download round trip in `/sdcard/Download/AdbFilesTest/`, cancel leaves nothing, folder removed at the end
- executed how: `ADB_TEST_SERIAL=… ADB_TEST_WRITE=1 swift test --filter LiveDevice`; MB/s logged

### R3 — `TransferQueue` (M)
- files: `Sources/AdbFiles/Features/Transfers/TransferQueue.swift` (new), `TransferItem.swift` (new),
  `TransferEngine.swift` (new: protocol seam; `AdbSyncClient` adapter), `ConflictNaming.swift` (new)
- behaviour: per-device FIFO, ≤ 2 running per device; states queued/preparing/running/done/failed/
  cancelled; injected clock (`now`) and sleep seams; progress coalesced to ≤ 10 publishes/s per item;
  speed = bytes over a sliding 3 s window, ETA = remaining / speed; cancel/retry/clearFinished.
  **Final state is decided by a stop reason recorded on the item before its task is cancelled**
  (user → `cancelled`, `deviceGone(serial)` → `failed(retryable)`); a thrown `CancellationError` never
  decides the state by itself. Every progress/completion write carries an attempt token and is dropped
  once the item is final or retried. Remote conflict names: `LST2` check **plus** a per-(serial, parent)
  reservation of target names held until the item finishes; local names: no-overwrite move with next
  suffix on collision. The resolved root target is stored on the item at the first attempt and reused by
  Retry. After an upload completes, the browser folder refreshes (cache invalidated)
- test: `Tests/AdbFilesTests/TransferQueueTests.swift` with a scripted fake engine and a manual clock —
  concurrency cap and order; throttle (1,000 callbacks over 1.0 s of manual time → exactly 10 publishes
  + final); speed/ETA with the manual clock; cancel while queued/running; **cancel racing completion**;
  **deviceGone while queued and while running → failed + retryable, not cancelled**; **progress after
  cancel/done → no change**; retry reuses the stored target; **two same-named uploads at once → `a.txt` and
  `a 2.txt`**; conflict names (`a.txt` → `a 2.txt`, `a 2.txt` → `a 3.txt`, no extension, dot-files, folders)
- executed how: tests; live in R4

### R4 — UI: transfers popover, menu commands, drag & drop (L)
- files: `Features/Transfers/TransfersButton.swift` (new: toolbar button + badge), `TransfersPopover.swift`
  (new), `TransferRow.swift` (new), `App/TransferCommands.swift` (new: Download To… ⌥⌘D, Upload… ⌘U via
  `NSOpenPanel`), `AppKitBridges/FileTableView.swift` (change: `pasteboardWriterForRow` →
  `NSFilePromiseProvider`; `registerForDraggedTypes([.fileURL])`, validate/accept drop on table or folder
  row), `AppKitBridges/FilePromiseDelegate.swift` (new), `Services/AppServices.swift` (change: owns the
  queue), `Features/Browser/BrowserView.swift` (change: toolbar button, drop on empty states),
  `Features/Devices/DeviceStore.swift` (change: notify queue when a device leaves)
- logging (`transfer`): `transfer start id=… dir=… files=N bytes=…`, `transfer done id=… ms=… MBps=…`,
  `failed … reason`, `cancelled`, `publishes=N` per item on finish (AC6 evidence); `FilePromiseDelegate`
  logs `promise drag began` and `promise write url=…` so their order proves download-on-drop (AC3)
- executed how (log-asserted; user-assisted where marked; MB/s from the **release** bundle built by
  `scripts/build-app.sh`): (a) generate on the Mac (scratchpad) a 200 MB file and a
  folder tree with Cyrillic/emoji names; Upload… into the test folder → SHA-1/`diff -r` after
  Download To… back (AC1, AC2, AC10 via a second upload, AC11 MB/s); (b) queue 4 downloads → log shows
  ≤ 2 running (AC5); (c) cancel a 200 MB upload and a download mid-way → `LST2`/`ls` show no partials
  (AC7); (d) unplug mid-transfer → failed; replug → Retry completes (AC8, user); (e) drag rows to Finder
  and Finder items onto the table and a folder row (AC2, AC3, user); (f) popover/badge visual (AC4, user);
  (g) delete `/sdcard/Download/AdbFilesTest/` and confirm it is gone; delete the scratchpad fixtures.
  Live write tests remove exactly `/sdcard/Download/AdbFilesTest` in a teardown that runs on failure too

### R5 — Docs (S)
- `docs/ARCHITECTURE.md` (transfers, pool, queue), `README.md` (`ADB_TEST_WRITE`), spec ticks, `evidence.md`

## Final verification
Clean build 0 warnings; `swift test` 5×; live suites incl. `ADB_TEST_WRITE=1`; AdbKit import grep;
test folder removed from the phone.

## Risks
| Risk | Impact | Cheapest way to find out early |
|------|--------|-------------------------------|
| Throughput below target (actor hops per 64 KiB chunk, FileHandle writes) | Slow transfers | R2 live 26 MB font download timed vs `adb pull` (34 MB/s) before any UI |
| `NSFilePromiseProvider` delegate threading under Swift 6 (called off main) | Crashes/warnings | Spike the delegate first in R4 with one file |
| Progress UI churn with many items | Janky popover | Throttle in R3 is tested; popover shows only aggregate + rows |
| adbd partial-file cleanup differs across Android versions | Leftover files | Live `LST2` check after cancel (R2) |

## Assumptions
- Keep-both naming `name 2.ext`; downloads go where the user drops or chooses (no default folder).
- One queue per app, shared by all windows; transfers survive switching devices in the sidebar.
- Branch `feat/ADB-4-transfers`, one commit per requirement, merge on the user's word.
