# ADB-5 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-14

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
- behaviour: `rename(_:to:)` and `move(_:into:)` → pre-check target with `LST2` (exists → `.alreadyExists`),
  `mv -n -T -- src dst`, then post-check (`src` gone and `dst` present, else `.operationFailed`); `copy(_:into:)`
  → same with `cp -a -n -T -- src dst`; `delete(_:)` → `rm -r -- p1 p2 …` batched (≤ 8 KB per command) and
  post-check each path gone; `makeDirectory(_:)` → `mkdir -- p` (no `-p`, so an existing name fails) + check.
  Refuse moving/copying a folder into itself or a descendant before running anything. Shell timeout 120 s for
  `rm`/`cp`, 10 s otherwise. Statting runs on the client's listing connection (`AdbSyncClient.lstat`).
- test: `Tests/AdbKitTests/AdbFileOperationsTests.swift` on `FakeDevice` (extended with a scripted shell
  responder and mutable `LST2` state): exact command strings incl. `--` and quoting for `-rf`, `it's`, Cyrillic,
  emoji, newline; target exists → `.alreadyExists` and no `mv` sent; marker FAIL → `.operationFailed(message)`;
  "OK but source still there" (the silent `-n` case) → `.operationFailed`; delete batches; into-itself refused;
  `AdbShellTests` for the marker parser
- executed how: `ADB_TEST_SERIAL=… ADB_TEST_WRITE=1 swift test --filter LiveFileOps` in
  `/sdcard/Download/AdbFilesTest/fileops` (rename/move/copy/delete/mkdir round trip with weird names; delete in
  `/system` → message); teardown removes the subfolder

### R2 — Browser operations (M)
- files: `Sources/AdbFiles/Features/Browser/BrowserStore.swift` (change: `rename`, `delete`, `newFolder`,
  `move`/`copy`(rows, into folder), `copyPaths`, `busy: String?`, `alert: OperationAlert?`, `editingPath`),
  `Features/Browser/FileOperating.swift` (new: protocol seam; `AdbFileOperations` adapter),
  `Features/Browser/NameValidation.swift` (new)
- behaviour: validate names; run operations off the main actor; invalidate cache for the current folder and
  the destination; refresh; select the new/renamed item; `newFolder` picks `untitled folder` / `… 2` from the
  current rows and sets `editingPath`; errors become an alert (title + device message); stale results after
  navigating away do not write state (generation pattern)
- test: `Tests/AdbFilesTests/FileOperationsStoreTests.swift` with a fake — validation cases, rename selects the new
  path, new folder numbering, delete/move refresh both folders, error → alert, busy cleared on every path, result
  after navigating away ignored, copy paths text
- executed how: tests; live in R3

### R3 — UI: context menu, inline rename, confirmation, shortcuts, internal drag (L)
- files: `AppKitBridges/FileTableView.swift` (change: `menu(for:)` context menu, inline editing of the Name cell
  driven by `editingPath` — Return commits, Esc cancels; internal drag: `validateDrop` accepts own rows onto a
  folder row as `.move`, ⌥ → `.copy`), `Features/Browser/BrowserView.swift` (change: confirmation
  `.confirmationDialog`, alert, busy indicator in the status bar), `App/BrowserCommands.swift` (change: File menu
  Rename, Delete ⌘⌫, New Folder ⌘⇧N, Copy Path ⌥⌘C)
- logging (`ui`): `op rename|delete|mkdir|move|copy count=N ok|fail ms=…`, `confirm delete count=N`
- executed how (log-asserted; user-assisted for mouse/keyboard; test folder only): (a) ⌘⇧N twice →
  `untitled folder`, `untitled folder 2`, inline rename to a Cyrillic/emoji name; (b) rename a file to an existing
  name → alert, nothing changed (`ls`); (c) drag a file onto a folder → moved; ⌥-drag → copied (`ls -la` shows
  kept mtime); (d) ⌘⌫ on 2 items → dialog → confirm → gone; cancel path leaves them; (e) Copy Path → `pbpaste`
  shows the paths; (f) delete in `/system` (via ADBFILES_START_PATH=/system/etc) → device message, no change;
  (g) remove `/sdcard/Download/AdbFilesTest` and confirm gone

### R4 — Docs (S)
- `docs/ARCHITECTURE.md`, `README.md` (shortcuts), spec ticks, `evidence.md`

## Final verification
Clean build 0 warnings; `swift test` 20×; live suites incl. writes; import grep; test folder removed.

## Risks
| Risk | Impact | Cheapest way to find out early |
|------|--------|-------------------------------|
| `-n` silently skips; shell has no exit code | Reported success without effect | Post-check with `LST2` is part of R1 and has its own test |
| Inline editing in a view-based NSTableView fights the Coordinator's reloads | Edits lost mid-typing | No reload while `editingPath` is set; spike first in R3 |
| Long `rm -r` blocks the shared listing connection | Browsing freezes | Shell commands use their own connection; only stats use the listing one |
| Internal drag conflicts with promise drags to Finder | Wrong operation | `validateDrop` checks `draggingSource === tableView`; Finder path unchanged |

## Assumptions
- Enter keeps opening (CLAUDE.md); rename starts from the context menu, File › Rename, or clicking the name of an
  already selected row (Finder's slow click).
- Move/copy conflicts are refused (no dialogs); deletions are permanent and the dialog says so.
- Branch `feat/ADB-5-file-ops`, one commit per requirement, merge on the user's word.
