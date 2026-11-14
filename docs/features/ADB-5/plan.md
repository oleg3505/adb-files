# ADB-5 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-14 (v2, after analyze BLOCK #1)

Pattern followed: AdbKit commands via `AdbShell` with an echoed marker (as `AdbShell.accessCheck` and the
`mkdir -p` batches in `AdbTransferSession`), fake-device tests in `Tests/AdbKitTests/AdbSyncClientTests.swift`
(`FakeDevice` shell replies + `LST2` scripting), gated live write tests (`LiveWriteTests`, per-suite subfolder);
app state in `BrowserStore`; AppKit in `AppKitBridges/FileTableView.swift`; menus as `BrowserCommands`/
`TransferCommands`. No new pattern → no ADR.

## Contract changes
- boundary: additive AdbKit API `AdbFileOperations` + `AdbError.alreadyExists`, `.operationFailed(String)`.
- data: none.

## Requirements (ordered, each independently verifiable)

### R1 — `AdbFileOperations` in AdbKit (M)
- files: `Sources/AdbKit/AdbFileOperations.swift` (new), `Sources/AdbKit/AdbShell.swift` (change: helper that
  appends `2>&1 && echo __ADBFILES_OK || echo __ADBFILES_FAIL` and parses output → success or the device's
  message), `Sources/AdbKit/AdbError.swift` (change)
- behaviour (every op): `LST2` the source first (missing → `.notFound`); target clash checks compare names
  case-insensitively (`/sdcard` is FUSE, case-insensitive on this device) by listing the target folder;
  the marker is parsed from the **last output line only**.
  - `rename(_:to:)`: clash → `.alreadyExists`; a case-only rename runs `mv -T -- a <tmp>` then `mv -T -- <tmp> A`
    (unique temp name); otherwise `mv -n -T -- src dst`. Post-check: the exact new name is in `LIST` of the parent
    and the old exact name is not.
  - `move(_:into:)` / `copy(_:into:)` take N items and return `[path: Result]`; per item: clash → `.alreadyExists`,
    else `mv -n -T` / `cp -a -n -T`. Post-check: move → src gone, dst present; copy → dst present with the source's
    type and src still present. A partial `cp -a` destination is kept and reported, never deleted.
  - `delete(_:)` takes N paths → `rm -r -- …` batched (≤ 8 KB per command); returns `[path: Result]` (post-check: gone).
  - `makeDirectory(_:)` → `mkdir -- p` (no `-p`) + post-check.
  - Refuse moving/copying a folder into itself or a descendant (compare on a `/` boundary: `/a/b` vs `/a/bc`) and
    onto a symlink row, before any command. Shell timeout 120 s for `rm`/`cp`, 10 s otherwise. Stats/lists run on
    the client's listing connection; shell commands on their own connection.
- test: `Tests/AdbKitTests/AdbFileOperationsTests.swift` on `FakeDevice` (extended with a scripted shell
  responder and mutable `LST2` state): exact command strings incl. `--` and quoting for `-rf`, `it's`, Cyrillic,
  emoji, newline; target exists (incl. different case) → `.alreadyExists` and no `mv` sent; source missing →
  `.notFound`; case-only rename → two `mv` via a temp name and `LIST` post-check; marker FAIL →
  `.operationFailed(message)`; marker only on the last line (a file name containing the marker in an error line
  is not success); "OK but source still there" (the silent `-n` case) → `.operationFailed`; copy post-check (src
  stays); 3-item move/delete with 1 failure → per-item results; delete batches; into-itself/descendant/`/a/bc`
  boundary/symlink target refused; `AdbShellTests` for the marker parser
- executed how: `ADB_TEST_SERIAL=… ADB_TEST_WRITE=1 swift test --filter LiveFileOps` in
  `/sdcard/Download/AdbFilesTest/fileops` only (rename incl. case-only, move/copy/delete/mkdir round trip with
  names `-rf`, `it's`, Cyrillic, emoji; clash refused; copy keeps mtime); teardown removes the subfolder.
  **No command ever targets a path outside the test folder**; permission-denied messages are covered by the
  fake device only

### R2 — Browser operations (M)
- files: `Sources/AdbFiles/Features/Browser/BrowserStore.swift` (change: `rename`, `delete`, `newFolder`,
  `move`/`copy`(rows, into folder), `copyPaths`, `busy: String?`, `alert: OperationAlert?`, `editingPath`),
  `Features/Browser/FileOperating.swift` (new: protocol seam; `AdbFileOperations` adapter),
  `Features/Browser/NameValidation.swift` (new)
- behaviour: validate names (case-insensitive clash with current rows); **one operation at a time per store**
  (`busy != nil` disables commands, context menu, drops and rename start); run off the main actor; operations are
  **not** tied to the load generation and navigation never cancels them; on completion always invalidate every
  affected folder in `ListingCache` and always show an alert listing failures; only selection/`editingPath`
  writes check that the user is still in that folder; if an operation is cancelled anyway (window closed) report
  "result unknown" and invalidate; a `CancellationError` is never silence. `newFolder` picks `untitled folder` /
  `… 2` case-insensitively and sets `editingPath`
- test: `Tests/AdbFilesTests/FileOperationsStoreTests.swift` with a fake that suspends on a continuation (no
  sleeps) — validation cases; rename selects the new path; new folder numbering (case-insensitive); delete/move
  invalidate + refresh both folders; error → alert listing failed items; busy cleared on every path; **start an
  op, navigate away, resume with a failure → alert shown and both folders invalidated, selection untouched**
  (mutation check: removing the always-alert path fails it); **second op while busy is refused, final listing
  reflects the first**; copy paths text
- executed how: tests; live in R3

### R3 — UI: context menu, inline rename, confirmation, shortcuts, internal drag (L)
- files: `AppKitBridges/FileTableView.swift` (change: `menu(for:)` context menu, inline editing of the Name cell
  driven by `editingPath` — Return commits, Esc cancels; internal drag: `validateDrop` accepts own rows onto a
  folder row as `.move`, ⌥ → `.copy`), `Features/Browser/BrowserView.swift` (change: confirmation
  `.confirmationDialog`, alert, busy indicator in the status bar), `App/BrowserCommands.swift` (change: File menu
  Rename, Delete ⌘⌫, New Folder ⌘⇧N, Copy Path ⌥⌘C)
- logging (`ui`): `op rename|delete|mkdir|move|copy count=N ok=N fail=N ms=…`, `busy begin|end op=…`,
  `rename begin|commit|cancel path=…`, `confirm delete count=N result=confirm|cancel`, `alert op=… reason=…`,
  `drop op=move|copy count=N dest=…`, `copy path count=N`
- executed how (log-asserted; user-assisted for mouse/keyboard; test folder only): (a) ⌘⇧N twice →
  `untitled folder`, `untitled folder 2`, inline rename to a Cyrillic/emoji name with Return (`rename commit`);
  start another rename and press Esc (`rename cancel`, name unchanged); (b) rename to an existing name and to an
  empty name → `alert op=rename reason=…`, nothing changed (`ls`); (c) case-only rename `a.txt` → `A.txt` →
  `ls` shows `A.txt`; (d) drag a file onto a folder → `drop op=move`; ⌥-drag → `drop op=copy` (`ls -la` shows
  kept mtime); (e) ⌘⌫ on 2 items → `confirm delete result=cancel` (still there) then `result=confirm` (gone);
  (f) Copy Path → `copy path count=N` and `pbpaste` shows the paths; (g) remove `/sdcard/Download/AdbFilesTest`
  and confirm gone. All steps inside the test folder only

### R4 — Docs (S)
- `docs/ARCHITECTURE.md`, `README.md` (shortcuts), spec ticks, `evidence.md`

## Final verification
Clean build 0 warnings; `swift test` 20×; live suites incl. writes; import grep; test folder removed.

## Risks
| Risk | Impact | Cheapest way to find out early |
|------|--------|-------------------------------|
| `-n` silently skips; shell has no exit code | Reported success without effect | Post-check (`LST2`, or exact name via `LIST` for renames) is part of R1 and has its own test |
| Inline editing in a view-based NSTableView fights the Coordinator's reloads | Edits lost mid-typing | No reload while `editingPath` is set; spike first in R3 |
| Long `rm -r` blocks the shared listing connection | Browsing freezes | Shell commands use their own connection; only stats/lists use the listing one |
| Case-insensitive FUSE storage makes `LST2` clash/post-checks lie | Silent no-op or false refusal | Case-insensitive clash checks + `LIST` exact-name post-check; live case-only rename test |
| Internal drag conflicts with promise drags to Finder | Wrong operation | `validateDrop` checks `draggingSource === tableView`; Finder path unchanged |

## Assumptions
- Enter keeps opening (CLAUDE.md); rename starts from the context menu, File › Rename, or clicking the name of an
  already selected row (Finder's slow click).
- Move/copy conflicts are refused (no dialogs); deletions are permanent and the dialog says so.
- Branch `feat/ADB-5-file-ops`, one commit per requirement, merge on the user's word.
