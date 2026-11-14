# ADB-4 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-14

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
- behaviour: every read/write uses a 15 s inactivity timeout, none overall; cancellation closes the
  connection; download failure/cancel deletes the temp file; upload cancel relies on adbd deleting the
  partial (verified) and is asserted by `LST2` in the live test; `os_signpost` interval "transfer"
- test: `Tests/AdbKitTests/AdbSyncTransferTests.swift` on `FakeDevice` (extended with RECV/SEND):
  bytes identical, temp renamed, mtime set; FAIL → `AdbError.serverFailure`; cancel mid-download →
  no temp/target file; stalled device → `.timeout` after the (test-shortened) inactivity limit while a
  slow-but-steady stream does not time out; 3 concurrent downloads → max 2 open transfer connections;
  folder walk both ways (nested, empty folder, symlink skipped). `LiveDeviceTests`: download
  `/system/fonts/NotoSerifCJK-Regular.ttc`, SHA-1 vs device; write tests gated by `ADB_TEST_WRITE=1`:
  upload/download round trip in `/sdcard/Download/AdbFilesTest/`, cancel leaves nothing, folder removed at the end
- executed how: `ADB_TEST_SERIAL=… ADB_TEST_WRITE=1 swift test --filter LiveDevice`; MB/s logged

### R3 — `TransferQueue` (M)
- files: `Sources/AdbFiles/Features/Transfers/TransferQueue.swift` (new), `TransferItem.swift` (new),
  `TransferEngine.swift` (new: protocol seam; `AdbSyncClient` adapter), `ConflictNaming.swift` (new)
- behaviour: per-device FIFO, ≤ 2 running per device; states queued/preparing/running/done/failed/
  cancelled; progress coalesced to ≤ 10 publishes/s per item; speed = bytes over a sliding 3 s window,
  ETA = remaining / speed; cancel/retry/clearFinished; `deviceGone(serial)` fails its items (retryable);
  after an upload completes, notifies the browser to refresh that folder (cache invalidated)
- test: `Tests/AdbFilesTests/TransferQueueTests.swift` with a scripted fake engine — concurrency cap and
  order, throttle (1,000 progress callbacks in 1 s → ≤ 11 publishes), cancel while queued/running,
  retry, device gone, speed/ETA math, conflict names (`a.txt` → `a 2.txt`, `a 2.txt` → `a 3.txt`,
  no extension, dot-files, folders)
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
  `failed … reason`, `cancelled`, `publishes=N` per item on finish (AC6 evidence)
- executed how (log-asserted; user-assisted where marked): (a) generate on the Mac a 200 MB file and a
  folder tree with Cyrillic/emoji names; Upload… into the test folder → SHA-1/`diff -r` after
  Download To… back (AC1, AC2, AC10 via a second upload, AC11 MB/s); (b) queue 4 downloads → log shows
  ≤ 2 running (AC5); (c) cancel a 200 MB upload and a download mid-way → `LST2`/`ls` show no partials
  (AC7); (d) unplug mid-transfer → failed; replug → Retry completes (AC8, user); (e) drag rows to Finder
  and Finder items onto the table and a folder row (AC2, AC3, user); (f) popover/badge visual (AC4, user);
  (g) delete `/sdcard/Download/AdbFilesTest/` and confirm it is gone

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
