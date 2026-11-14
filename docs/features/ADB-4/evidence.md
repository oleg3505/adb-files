# ADB-4 — evidence

No remote, so no PR (user-approved: local branch, one commit per requirement, merge on the user's word).
App lines come from `/usr/bin/log show --info --predicate 'subsystem == "dev.local.AdbFiles"'`. Device: Pixel 4.
All writes went to `/sdcard/Download/AdbFilesTest` (user-approved) and the folder was removed afterwards:
`ls -d /sdcard/Download/AdbFilesTest` → "No such file or directory" / "device-folder-gone".

### Verification
- build: `swift package clean && swift build --build-tests` → 0 warnings (after R1–R4 and the fixes)
- tests: `swift test` → 172 passed; full suite 40× after the ENODATA fix → 0 failures (3/40 before it)
- live: `ADB_TEST_SERIAL=9A251FFAZ0073G ADB_TEST_WRITE=1 swift test --filter "Live"` → pass:
  - `downloadsSystemFontByteIdentical`: 26 MB `/system/fonts/NotoSerifCJK-Regular.ttc`, SHA-1 = device `sha1sum`,
    **34 MB/s in a debug build** (`adb pull`: 34.2 MB/s)
  - `uploadAndDownloadRoundTrip` (Cyrillic + emoji name, mtime 1_700_000_000 kept), `cancelledUploadLeavesNoPartialFile`
  - `LiveTransferQueueTests` (real queue + engine, no UI): 200 MB + folder tree with Cyrillic/emoji names, nested
    and empty folders → up **32.5 MB/s**, down **37.6 MB/s**, SHA-1 identical, mtimes kept, empty folder created;
    `a.jpg` twice → `a.jpg` + `a 2.jpg`; four 40 MB uploads → peak running = 2, ~19 MB/s each; cancelled upload →
    no `part3.bin` on the device; cancelled download → nothing on the Mac; 56 publishes in 6.2 s
- protocol: Python probe of RECV/SEND before coding (see spec); fixtures from it
- mutation checks (each restored): removing the final-state guard fails `progressAfterDoneIsIgnored` and
  `cancelRacingCompletionStaysCancelled`; removing reservations fails both same-name tests; making cancel not
  decide the state fails `cancelWhileRunningIsImmediateAndFreesTheSlot`
- executed (user, release bundle `scripts/build-app.sh`):
  - Finder → empty test folder: `drop upload items=1` → `done(copied: 2)`; files and mtimes on the device
  - Finder → table, `Велике відео 🎬.bin` (300 MB) twice → `done` at 29.4 and 28.6 MB/s (in parallel); device has
    `Велике відео 🎬.bin` and `Велике відео 🎬 2.bin` (keep both)
  - table → Finder: `promise drag began` → `promise write url=…/Downloads here/Велике відео 🎬.bin` →
    `done bytes=300000000 MBps=38.1`; SHA-1 equals the source; mtime 16:08:47 kept (download starts only on drop)
  - user confirmed progress is visible (bottom bar / toolbar ring) after the change below

### Not verified
- File › Download To… and File › Upload… menu commands; a drop onto a folder row; dragging a folder out to Finder —
  not present in any captured log (the user reported the steps done; the logs show only the actions listed above).
- Unplugging during a transfer and Retry after replugging (AC8): covered by unit tests only.
- Inactivity timeout on hardware (fake-device tests only).
- Two devices transferring at once.

### Found during verification and fixed
- Progress was not visible without opening the popover (user feedback) → `TransferStatusBar` + progress ring.
- Drops on an empty folder relied on a small SwiftUI drop zone → empty folders keep the empty table (AppKit drop).
- File promises re-resolved the name Finder had already chosen → write to Finder's exact URL (`fixedName`).
- Flaky shell reads: Network.framework reported a peer close as `ENODATA` → mapped to `connectionClosed`.
- A queue test asserted start order within a pair (not defined by FIFO) → checks slot assignment instead.
- Process note: commit 3972d04 was made after that flaky test had failed once; fixed in ad33976.
