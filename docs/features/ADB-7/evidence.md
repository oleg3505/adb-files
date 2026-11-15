# ADB-7 — evidence

There is no remote, so no PR: work happens on a local branch and is merged when the user says so.

How results were collected:
- App lines come from `/usr/bin/log stream --level info --predicate 'subsystem == "dev.local.AdbFiles"'`, filtered
  to the `AdbFiles` process. The test binary logs to the same subsystem.
- `log show` lost info lines once during R3, so later runs were streamed to a file instead.
- Device: Pixel 4, adb 37.0.0 (protocol 41).
- Device writes happened only in `/sdcard/Download/AdbFilesTest` (user-approved). The folder was removed at the end
  (`ls` → "No such file or directory").

### Verification
- **Build:** clean `swift build --build-tests` → 0 warnings after every requirement.
- **Tests:** 300 passed (was 252); the full suite ran 20× with 0 failures.
- **Live suites:** `ADB_TEST_SERVER=1 ADB_TEST_SERIAL=9A251FFAZ0073G ADB_TEST_WRITE=1 swift test --filter Live` →
  22 passed, 0 skipped. This includes the write round trips, hostile names, a cancelled upload, a file over 4 GB
  plus a folder, and the new `connectAndDisconnectReportAdbsMessages`.
- **`AdbKit` imports:** `grep -rnE "^import (SwiftUI|AppKit|Quartz)" Sources/AdbKit` → 0.
- **Mutation checks** (each restored afterwards):

  | Requirement | Removed | Test that failed |
  |---|---|---|
  | R1 | inactivity limit (total `withTimeout` put back) | `slowButSteadyListingIsNotATimeout` |
  | R3 | folder-replace guard | `foldersAreNeverReplacedAndAskedSeparately` |
  | R3 | owner guard | `replaceOfANameAnotherItemIsWritingFallsBackToKeepBoth` |
  | R5 | 10 s freshness skip | `openingAPrefetchedFolder…WithoutASecondListing` |
  | R5 | prefetch reuse | `openingTheFolderWhileItsPrefetchRunsReusesIt` |
  | R5 | cancel-in-take | `openingAnotherFolderCancelsThePrefetchFirst` |

### Executed (per requirement)

**R1 — listing inactivity timeout**
- Tests: a listing in 20 chunks, 60 ms apart, against a 300 ms limit succeeds; a 600 ms stall times out.
- AdbKit, live: during two `adb push -Z` of 1 GB of random data each (12.7 and 13.2 MB/s), `DCIM/Camera`
  (7,948 entries) listed 4× in 4547, 1618, 1635 and 1588 ms, with no failures.
- App: during two app uploads of 1 GB each (10.8 MB/s), opening Camera gave `list … entries=7948 ms=6972`. In ADB-6
  this timed out 4×.
- ADR-002 added; the CLAUDE.md rule was updated with the user's approval.

**R2 — multi-selection**
- Spike option (b) worked: an event monitor plus a nil pasteboard writer, with no table override. Fallback (a) was
  not needed.
- User run:
  - drag-select → `selection count=4` and `5`;
  - ⌘A → `selection count=7948`;
  - a drag by the name → `promise drag began rows=5`, and `promise write` ×2 to Finder;
  - regression: `drop op=move` → sub, `via=breadcrumb`, `drop op=copy`, opening sub, `rename commit "a e.txt"`.

**R3 — conflict prompt**
- Uploads (checked on the device afterwards):
  - Replace → `a.txt` became the new 21-byte file;
  - Keep Both → `a 2.txt`;
  - Apply to all → one sheet → `a 3.txt` + `b 2.txt`;
  - folder `sub` → Skip, and no Replace button was offered;
  - Stop → `conflict ask … choice=stop`, `enqueued=0`.
- Drag to Finder (requested by the user during R3; spike passed):
  - Keep Both → `a 2.txt`;
  - Skip;
  - Replace → written to `r3/a.txt` ("LOCAL OLD" → new content), with no `a 3.txt`.
- Download To…: the prompt appeared (Skip) when the target already had `a.txt`. **Replace through Download To… was
  not run live.** It goes through the same engine `overwrite` path that the promise Replace exercised.
- Replace-upload safety (fake device): a cancelled upload leaves the original intact and `rm -f`s the part file.

**R4 — Locations bookmarks**
- The sidebar uses `@FocusedValue(\.browser)` instead of the planned `RootView` state; it is simpler and matches
  the Go menu.
- `navigate action=bookmark` was seen for all 6 entries (/sdcard ×5, DCIM ×3, Documents ×7, Download ×6, Music ×2,
  Pictures ×4).
- The "missing folder → not found" case is unit-tested; all six folders exist on this phone.

**R5 — prefetch**
- Documents: the pointer rested on it → `prefetch done` (7 ms) → opening it gave `source=cache`, with no second
  listing.
- Camera: opened while its prefetch was still running → `prefetch reused` → `navigate ms=478`; the prefetch listing
  itself took 1210 ms.
- DCIM was refreshed 11 s after its prefetch: the freshness window is 10 s, by design.

**R6 — Wi-Fi debugging**
- Request formats were recorded from the real server:
  - `host:connect:127.0.0.1:1` → `OKAY` + "failed to connect to '127.0.0.1:1': Connection refused";
  - `host:pair:…` → raw `OKAYFAIL0027Failed: Unable to start pairing client.`;
  - `host:disconnect:127.0.0.1:1` → `FAIL` "no such device '127.0.0.1:1'".
- Fake-server tests replay these replies; the live server test passes.

**R7 — connection reuse and cache limit**
- Opening a sync session costs p50 1.7 ms, p90 2.6 ms, max 9.8 ms (20 runs). Full reads were 6 of 155 DCIM
  thumbnails in ADB-6. By the plan's rule, connection reuse was **not built**.
- Cache trimmer: at launch the log showed `thumb cache size=8727863 files=279`.

**R8 — signposts and shortcuts**
- While the user browsed, `log show --signpost` showed balanced begin/end pairs for:
  - `list` 9/9;
  - `prefetch` 5/5;
  - `preview` 1/1;
  - `transfer` 2/2.
- `thumbnail` did not fire in that run, because every thumbnail came from the disk cache; the interval has existed
  since ADB-6.
- Instruments' "Logging" template recorded no AdbFiles rows in its interval table, so the README explains the
  os_signpost instrument and `log show --signpost`.
- Shortcut review: every CLAUDE.md shortcut is present; ⌘Y Quick Look was added.

**R9 — drag hint**
- The third attempt worked. The user saw the Move, Copy and Upload hints.
- The full regression checklist passed with the spike before the commit:
  - `drop op=copy` → sub;
  - `via=breadcrumb` (the move was refused because `b.txt` already existed in the parent — expected);
  - `drop upload` → sub with a conflict prompt;
  - `promise write` with a prompt via the promise delegate;
  - Return, type-select and rename.

### Not verified
- **AC6, Wi-Fi with the phone (deferred by the user).** All 9 Pair attempts failed within about 1 s with adb's
  "Failed: Unable to start pairing client." (ports 39483 and 37015). One Connect on the pairing port got "No route
  to host".
  - Network checks: Mac and phone are on the same /24 and ping works, but `adb mdns services` was empty.
  - Next step: run plain `adb pair` while the pairing dialog is open.
- Download To… with Replace (see R3).
- Locations disabled when no device is usable: the code disables them when there is no browser; this was not tried
  live.

### Incident
- During R3, Download To… was pointed at `~/Documents`, where there was no clash, so the test created
  `~/Documents/a.txt`. It was removed with the user's OK after its content was checked.

### Self-review
- (filled in after `/review-pr`)
