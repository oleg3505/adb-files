# ADB-3 — evidence

No remote exists, so there is no PR (user-approved: local branch, one commit per requirement, merge on the
user's word). App lines come from `/usr/bin/log show --info --predicate 'subsystem == "dev.local.AdbFiles"'`.
Device: Pixel 4 (Android 13) over USB. No files were created on the phone (user's decision).

### Verification
- build: `swift package clean && swift build --build-tests` → exit 0, `grep -c 'warning:'` → 0 (after R1, R3, R4, R5)
- tests: `swift test` → "Test run with 119 tests in 16 suites passed"; network and store suites repeated 5× → 5/5
- live: `ADB_TEST_SERVER=1 ADB_TEST_SERIAL=9A251FFAZ0073G swift test --filter Live` → pass, incl. `/data` and
  `/storage/emulated` → `.permissionDenied`, empty `/sdcard/Android/media/com.google.android.gms` → `[]`,
  missing path → `.notFound`, `DCIM/Camera` 7,948 entries < 5 s
- AdbKit: `grep -rnE '^import (SwiftUI|AppKit)' Sources/AdbKit` → empty
- R1: `@testable import AdbFiles` works with the executable target; mutation check — disabling the
  "keep the failed message" branch makes `startFailureKeepsAdbOutputOnScreen` fail; restored
- protocol: Python probe of `LIS2`/`LST2`/`LIST`; the first `DNT2` entry of `/sdcard/` is a byte-for-byte fixture
- executed (app, `ADBFILES_START_PATH`, no clicks):
  - `/sdcard`: `list … entries=55 ms=18`, `navigate … source=device ms=30`, `apply rows=54 mainMs=0` (AC1)
  - `/sdcard/DCIM/Camera`: `list entries=7948 ms=1428`, `apply rows=7948 mainMs=2` (AC6)
  - `/data`: `browser phase=denied`; empty gms folder: `browser phase=empty` (AC7)
  - `/sdcard/Download`: `entries=369 ms=252`
- executed (user, round 1): open DCIM → Camera `ms=1806`, `apply rows=7948 mainMs=2`; `/` → `data` → denied;
  revisits `source=cache ms=0–3` followed by `refresh … changed=false` and no reload (AC5); hidden toggled 6×
  (`apply … mainMs=3–6`); sort date/kind asc/desc; real unplug at `/sdcard` and replug → cached `/sdcard` at once
- sort latency (click → rows): first build 300 ms (strings rebuilt per sort) → rows built once per listing,
  name/kind ranks precomputed, index sort: **release 11–17 ms, debug 58–74 ms** for 7,948 rows, main thread
  4–6 ms (self-driven diagnostic, removed before commit)
- executed (user, round 2): sort size/date in Camera, two Back steps `action=back … source=cache ms=1–3`
- executed (AC8): `adb reconnect` 0.9 s into the Camera listing → `listing failed … connection closed`,
  `browser cancel reason=device-gone`, app alive; real unplug (round 3) → `browser cancel reason=device-gone
  inFlight=false`, replug → `navigate action=start … source=cache ms=3`
- user visual check: the user reported steps 1–8 of round 1 working, including Cyrillic names in Download

### Not verified
- Forward (⌘]), breadcrumb clicks, Return/⌘↓, ⌘R as a user action: not present in any captured log
  (round 3's log contains only an unplug at `/sdcard`). Logic covered by `BrowserStoreTests`.
- Multi-selection and type-select: no `selection count` > 1 logged; user-reported only.
- Unplugging during a listing with a real cable (simulated with `adb reconnect` instead).
- A > 4 GB file and 10,000+ items on a device (fixtures only: `keepsSizesAbove4GiB`, `decodesManyEntriesInOneChunk`);
  largest real folder: 7,948 items.
- Two devices browsing at once (only one phone available during this milestone).

### Found during verification and fixed
- `test -r -a -x` access check: wrong syntax (gate) and later wrong on SELinux-protected `/storage/emulated`
  (live) → real `ls -a` check; live test `selinuxProtectedFolderIsPermissionDenied`.
- `refresh()` cleared the selection (AC5) → only a path change clears it.
- Resort took ~300 ms → see sort latency above.
- Close of the browser was not logged when no listing was in flight → `browser cancel reason=… inFlight=…`.

### Self-review
- `code-reviewer` on `main..HEAD`: 1 blocking, 2 should-fix, 4 nits — all fixed:
  - Blocking: a slow row build and a header click could publish out of order (table in name order under a
    Date header; or stale rows reappearing). Fix: `arrangeEpoch` drops stale arranges; `show()` re-arranges
    if the sort/hidden setting changed meanwhile. New `RowPipeline` seam; deterministic tests
    `headerClickDuringSlowRowBuildIsNotLost` and `staleReArrangeDoesNotOverwriteFresherRows`. Mutation
    checks: removing the re-arrange fails the first, removing the epoch check fails the second; both restored.
    (A first, timing-based test passed even without the fix, so it was replaced.)
  - `disconnect()` surfaced as a silent `CancellationError` → `AdbSyncClient` reports `connectionClosed`
    when the caller was not cancelled, and the store treats a current-load `CancellationError` as a failure.
    Tests: `disconnectEndsListingPromptly` now expects `.connectionClosed`;
    `cancellationErrorFromListingIsAFailureNotASilentSpinner`.
  - EACCES from `LST2` → `.permissionDenied` (test `untraversableParentIsPermissionDenied`).
  - Nits: history stacks are observed (toolbar/menu enablement), table scrolls to top on folder change,
    `disconnect()` doc corrected, date sort key clamped.
- After fixes: clean build 0 warnings; `swift test` → 123 passed, 5/5 repeats; live suites 12 passed;
  app smoke: Camera `entries=7948`, `apply rows=7948 mainMs=3`.
