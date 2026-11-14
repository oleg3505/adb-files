# ADB-5 — Milestone 5: File operations

## Problem
The user can browse and copy files but cannot rename, delete, create folders, move items on the device,
or copy a path.

## Goal / business value
Goal 2 (native: Finder-like inline rename, ⌘⌫ with confirmation, ⌘⇧N new folder, drag to move with ⌥ to copy,
context menu), goal 3 (reliable: never overwrite silently, clear error messages, refresh after every change).

## Verified facts (2026-11-14, Pixel 4, read-only `--help`)
- toybox 0.8.6: `mv [-finTv]`, `cp [-adfHiLlnPpRrsTv]` (`-a` = `-dpr`, `-n` no clobber, `-T` dest is a file),
  `rm [-fiRrv]`, `mkdir [-vp]`.
- `-n` skips silently and still exits 0, and `shell:` (v1) returns no exit status anyway → every operation
  pre-checks the target with `LST2` and verifies the result with `LST2` afterwards; command output is
  captured with `2>&1` plus an echoed marker for the error message.
- Quoting does not stop a name like `-rf` from being read as an option → every command puts `--` before paths.

## Scope
- in:
  - AdbKit `AdbFileOperations`: `rename`, `move(into:)`, `copy(into:)`, `delete`, `makeDirectory`; commands built
    only via `AdbShell` with `--`; marker parsing; `LST2` pre-check (target exists → `AdbError.alreadyExists`)
    and post-check; long timeout for `rm -r`/`cp -a` (120 s) since big trees take time.
  - App: `BrowserStore` operations with name validation (empty, `/`, `.`/`..`, > 255 bytes), a busy indicator,
    cache invalidation + refresh of every affected folder, selection of the new/renamed item; errors in an alert.
  - UI: context menu on rows/background (Open, Quick Look — disabled until M6, Download To…, Rename, Delete,
    New Folder, Copy Path); inline rename in the Name cell (context menu, File › Rename, or clicking the name of
    an already selected row); ⌘⌫ Delete with a confirmation sheet ("can't be undone"); ⌘⇧N New Folder (`untitled folder`,
    keep-both numbering, then inline rename); ⌥⌘C Copy Path (one path per line); dragging rows onto a folder row
    moves them, ⌥-drag copies; moving a folder into itself is refused.
- **out (explicit):**
  - Undo, Trash (Android has none — deletions are permanent and the dialog says so).
  - Replace / Keep both / Stop dialogs for move/copy conflicts (refused with a message instead).
  - Cut/paste (⌘C / ⌥⌘V) moves, dragging onto breadcrumb segments, batch rename.
  - Quick Look itself (M6).

## Acceptance criteria
- [ ] AC1 Rename via context menu edits the name inline; Return commits, Esc cancels; the row stays selected
      under its new name; an existing name, empty name or a name with `/` is refused with a message.
- [ ] AC2 ⌘⌫ (or context menu Delete) asks for confirmation naming the item(s); confirming removes files and
      folders recursively; the listing refreshes; cancel does nothing.
- [ ] AC3 ⌘⇧N creates `untitled folder` (`untitled folder 2`, … if taken) in the current folder and starts
      inline rename on it.
- [ ] AC4 Dragging rows onto a folder row moves them there; with ⌥ it copies (`cp -a`, timestamps kept); both
      folders' listings refresh; a name clash in the destination is refused, nothing is overwritten.
- [ ] AC5 Copy Path puts the selected remote path(s) on the pasteboard, one per line.
- [ ] AC6 Every operation's failure (e.g. permission denied in `/system`) shows the device's message; the UI never
      freezes; operations run off the main thread with a busy indicator.
- [ ] AC7 Names with spaces, quotes, Cyrillic, emoji, and a leading `-` work for every operation.
- [ ] AC8 Clean build 0 warnings; tests green; `AdbKit` imports no SwiftUI/AppKit.

## Edge cases
| Case | Expected behaviour | Decided by |
|------|--------------------|-----------|
| Rename to the same name | No-op | assumption |
| Rename changing only case (`a.txt` → `A.txt`) | `/sdcard` on this device is FUSE and **case-insensitive** (gate: `ls -d /sdcard/download` resolves): done as two `mv -T` via a unique temp name; the exact name is verified with `LIST` of the parent | gate (live read-only check) |
| Name clash checks, `untitled folder N` numbering | Case-insensitive | gate |
| `cp -a` fails partway (disk full, timeout) | The partial destination is kept and the message says so (never deleted silently) | gate |
| Another window shows an affected folder | Refreshes on its next navigation/⌘R (known limit; the shared cache entry is invalidated) | gate |
| Item vanished before the operation | Source `LST2` first → `notFound` message, listing refreshes | assumption |
| Navigating away while an operation runs | The operation is not cancelled; its failure alert still shows and every affected folder is invalidated | gate |
| A second operation while one runs | Not allowed: commands, context menu, drops and rename are disabled while busy | gate |
| Move a folder into itself or its descendant | Refused before any command runs | Finder |
| Delete while a transfer uses the item | Allowed; the transfer then fails with Retry (no locking) | assumption |
| Huge folder delete (thousands of files) | Runs up to 120 s with busy indicator; timeout → error, listing refreshes | assumption |
| Multiple selection delete/move/copy | One confirmation / one batch; result per item (`[path: Result]`); the alert lists the failed items | assumption |
| Symlink rows | Rename/delete/move act on the link itself, never its target | POSIX |

## Open questions
| # | Question | My assumed answer | Needs a human? |
|---|----------|-------------------|----------------|
| 1 | May verification write to `/sdcard/Download/AdbFilesTest/` again (deleted afterwards)? | Yes, same rules as M4 | answered: yes, same rules as M4 |
| 2 | Return key: Finder uses Return = rename; CLAUDE.md says Enter opens | Keep Enter = open (CLAUDE.md); rename via context/File menu and click-on-selected-name | no |
