# ADB-5 — evidence

No remote, so no PR (user-approved local branch, merge on the user's word). App lines from
`/usr/bin/log show --info --predicate 'subsystem == "dev.local.AdbFiles"'`. Device: Pixel 4 (toybox 0.8.6).
Every device write in tests and verification was inside `/sdcard/Download/AdbFilesTest` (user-approved) and the
folder was removed afterwards (`ls -d …` → gone). No command targeted a path outside it.

### Verification
- build: `swift package clean && swift build --build-tests` → 0 warnings (after R1, R2, R3)
- tests: `swift test` → 206 passed; full suite 20× → 0 failures (after the fixes below)
- live: `ADB_TEST_SERIAL=PIXEL4SERIAL01 ADB_TEST_WRITE=1 swift test --filter LiveFileOps` → pass: mkdir `-rf` and
  `Папка 📁`; rename `it's a.txt` → `Звіт 🎉.txt`; **case-only rename `Звіт 🎉.txt` → `ЗВІТ 🎉.txt` on case-insensitive
  FUSE**; `папка 📁` refused (clash); copy keeps mtime; move removes source; move into a folder with the same name
  refused, nothing overwritten; recursive delete
- mutation checks (restored): showing alerts only in the starting folder fails
  `failureAfterNavigatingAwayStillAlertsAndInvalidates`; dropping the busy guard fails `aSecondOperationWhileBusyIsRefused`
- executed (user, release bundle, test folder):
  - `confirm delete count=1 result=confirm` → `op delete ok=1`
  - `rename begin/commit` `b.txt` → `апвпа.txt` → `op rename ok=1`
  - ⌘⇧N → `op mkdir ok=1` (`untitled folder`)
  - drag onto a folder row → `drop op=move` → `op move ok=1` (`a.txt` inside `untitled folder`)
  - ⌥-drag onto a folder row → `drop op=copy` → `op copy ok=1`; original kept, copy's mtime 19:17 kept
  - drag onto a path-bar segment (added by request) → `drop op=move … via=breadcrumb` ×2 → `op move ok=1`

### Not verified
- Esc-cancel of a rename, the clash/empty-name alerts, delete-cancel, Copy Path (⌥⌘C): unit-tested, not in UI logs.
- Permission-denied messages from a real device (fake device only, by design).
- A partial `cp -a` (disk full) on hardware.

### Found during verification and fixed
- Own rows could not be dropped on the table: rows drag as file promises and the table registered only `.fileURL`
  → registers the file-promise types too.
- A flash after every operation: the invalidated folder reloaded with a spinner → same-folder reloads keep rows visible
  (`refreshWithoutCacheKeepsRowsVisible`).
- ⌥-drag moved instead of copying: the key state at drop time was read → the negotiated drag operation decides.
- Test fakes: `rm` failed a whole batch where toybox fails per path; the new-folder test's refreshed listing lacked
  the new folder (timing-dependent failure 6/15 → 0/20).

### Self-review
- `code-reviewer` on `main..HEAD`: 1 blocking, 4 should-fix, 4 nits — fixed (nit 1 noted):
  - Blocking: starting a rename on another row (or ⌘⇧N) while editing renamed the wrong file / lost the edit. The
    table now commits only from the field it started editing and aborts a live edit before starting another; the
    store refuses `beginRename`/`newFolder` while editing and the menus disable them
    (`whileEditingNoOtherRenameOrNewFolderRetargetsTheEdit`; mutation check: removing the guard fails it).
  - Context menu ignored `isEnabled` (`autoenablesItems`) → disabled items now look and act disabled.
  - Slow-click rename keyed by row index → keyed by path, reset on reload, re-checks the selection before starting.
  - `cp -a`/`mv` had a 120 s total limit → 30 min, and any copy/move error now says a partial result may remain.
  - Path-bar drops ignored "one operation at a time" → refused while busy.
  - Nits: descendants' listings invalidated too (`removeTree`, test `removeTreeForgetsDescendantsOnly`); unreadable
    Finder items logged; v1-STAT caveat documented. Not changed: the path bar decides copy from the ⌥ key state at
    drop time (SwiftUI `onDrop` does not expose the negotiated operation) — an AppKit drop view would fix it later.
- After fixes: 208 tests, 20× → 0 failures; live file-op and device suites pass; test folder removed.

### Environment observation (not a code change)
- For ~15 minutes four unrelated network tests failed with `NWError 48 EADDRINUSE` in the full parallel suite, also
  on committed code that had passed 40/40 an hour earlier; isolated runs, `--no-parallel`, a minimal
  NWListener/NWConnection reproduction and 3,000 rapid connections were all clean, and the failures then stopped
  without any change (0/20). A connect retry was tried, did not help, and was reverted. Cause unknown; recorded here.
- An empty commit `18fa975` ("analyze round 2 passed") was created by mistake; harmless.

### Deferred: drag hint next to the cursor (user idea, 2026-11-14)
- Requested during verification: a small text near the cursor while dragging ("Move to “X”", "Copy to …",
  "Upload to …"). Two attempts (a floating panel, then an in-window overlay) both broke dragging *from* the table
  (drags began but never reached Finder or the table; drops *into* the app still worked). Both attempts overrode
  `FileNSTableView.draggingSession(_:movedTo:)`, the only part they shared — the likely cause. Reverted to 82eb784
  and confirmed live that dragging works again. Deferred to milestone 7 (polish) at the user's decision; next try
  should drive the hint only from drop destinations (`validateDrop`, path-bar segments) and not override the
  table's dragging-source methods.
