# ADB-4 — Milestone 4: Transfers

## Problem
The user can browse the phone but cannot copy anything between the phone and the Mac.

## Goal / business value
Goal 2 (native: drag & drop both ways like Finder, a transfers popover), goal 1 (instant feedback: the
transfer appears at once, progress is smooth but throttled), goal 3 (reliable: cancel, retry, unplug
mid-transfer, no partial files left behind).

## Verified protocol facts (2026-11-14, Pixel 4, Python probe; folder removed afterwards)
- `RECV <path>` → `DATA` + LE u32 size + bytes (≤ 65,536 per chunk), …, then `DONE` + 4 bytes; a missing
  file → `FAIL` + LE u32 length + "open failed: No such file or directory". 26 MB in 402 chunks; SHA-1
  matches `sha1sum` on the device. `adb pull` of the same file: 34 MB/s.
- `SEND <path>,<mode decimal>` → `DATA` chunks → `DONE` + LE u32 mtime → reply `OKAY` + 4 bytes, or `FAIL`
  + length + message ("couldn't create file: Read-only file system" for `/system`).
- adbd creates missing parent directories, keeps the mtime sent in `DONE`, and deletes the partial file
  when the client disconnects mid-`SEND`. Cyrillic + emoji paths round-trip.

## Scope
- in:
  - AdbKit: `SEND`/`RECV`/`DONE` framing and an incremental `RECV` decoder; transfer methods on
    `AdbSyncClient` using up to 2 dedicated transfer connections per device (the listing connection stays
    separate); download to a temp `*.adbfiles-part` file then rename, set local mtime; upload preserves
    mtime and mode; byte progress callback; 15 s inactivity timeout (no total timeout); cancellation;
    recursive folder walk for both directions.
  - App: `TransferQueue` (`@Observable`): FIFO per device, ≤ 2 running per device, per-item state
    (queued/preparing/running/done/failed/cancelled), bytes, speed, ETA, current file for folders;
    progress published ≤ 10×/s; cancel, retry, clear finished; device gone → its running/queued items fail
    with Retry; "keep both" naming (`name 2.ext`) on name conflicts in both directions; refresh the folder
    after uploads.
  - UI: toolbar Transfers button with an active-count badge and a popover (progress, speed, ETA, cancel,
    retry, reveal in Finder); File menu "Download To…" (⇧⌘D) and "Upload…" (⌘U); drag rows out to Finder
    via `NSFilePromiseProvider` (download starts on drop); drop files/folders from Finder onto the table
    (current folder) or onto a folder row (into that folder).
- **out (explicit):**
  - Compression / `SND2`/`RCV2`; resuming partial transfers; persisting the queue across launches.
  - Replace/Skip prompts on conflicts (keep-both only); transfers between two devices.
  - Context menu, rename/delete/new folder (M5); Quick Look/thumbnails (M6).

## Acceptance criteria
- [ ] AC1 "Download To…" on a selection (files and folders) copies them to the chosen Mac folder;
      contents byte-identical (SHA-1), mtimes preserved, folders recreated recursively.
- [ ] AC2 "Upload…" and dropping Finder items onto the table copy them into the current folder (onto a
      folder row: into that folder); the listing refreshes; byte-identical, mtime preserved.
- [x] AC3 Dragging rows to Finder starts the download only on drop and places the items there.
- [x] AC4 The popover shows each transfer with progress, speed and ETA; the toolbar badge shows active count.
- [x] AC5 At most 2 transfers run per device at once; others wait in order.
- [x] AC6 Progress is published at most 10 times per second per transfer.
- [x] AC7 Cancel stops a transfer within 1 s and leaves no partial file on either side.
- [ ] AC8 Unplugging the device mid-transfer marks its transfers failed (no hang, no crash); Retry after
      replugging completes them.
- [x] AC9 A stalled transfer fails after 15 s without data; a long healthy transfer never times out.
- [x] AC10 Name conflicts keep both (`name 2.ext`), never overwrite silently.
- [x] AC11 Cyrillic/emoji names transfer correctly; a transfer of ~200 MB runs at ≥ 20 MB/s (release build).
- [x] AC12 Clean build 0 warnings; tests green; `AdbKit` imports no SwiftUI/AppKit.

## Edge cases
| Case | Expected behaviour | Decided by |
|------|--------------------|-----------|
| Download target exists | `name 2.ext`, `name 3.ext`, … | user (keep both) / assumption on format |
| Remote upload target exists | Same, checked with `LST2` before sending | assumption |
| Unreadable remote file inside a folder | That file fails, the rest is copied; the item ends failed listing the count | assumption |
| Retry of a half-done folder | Same target folder (no `Photos 2/`); files already there with equal size+mtime are skipped | gate |
| Two same-named items at once | `a.txt` and `a 2.txt`: names reserved on both sides before start; temp file derived from the reserved name | gate |
| Unreadable local file inside an uploaded folder | That file fails, the rest is uploaded | gate |
| Remote folder mtimes | Not preserved (SEND has no directory mtime; adbd creates parents); local folder mtimes are | AOSP |
| Symlink in a folder being downloaded | Skipped (not followed) | assumption |
| Empty folder | Created on the other side | assumption |
| App quits during a transfer | No resume; a stale `name.adbfiles-part` is deleted before the next download of that name | assumption |
| Upload of a file > 4 GB | Allowed (SEND streams; no 32-bit size field) | AOSP |
| Device switched in the sidebar | Transfers keep running (they are per device, not per window) | assumption |

## Open questions
| # | Question | My assumed answer | Needs a human? |
|---|----------|-------------------|----------------|
| 1 | May verification write to the phone? | Yes: `/sdcard/Download/AdbFilesTest/`, deleted afterwards | answered |
| 2 | Folders in M4? | Yes, recursive both ways | answered |
| 3 | Shortcuts | ⇧⌘D Download To…, ⌘U Upload… (Finder has no equivalents) | no |

## Verification notes (2026-11-14)
- AC1 partial: downloads of files and recursive folders are verified byte-identical with preserved mtimes by
  the live queue test and by a Finder drag-out; the File › Download To… menu path itself was not exercised.
- AC2 partial: Finder drops onto the table and onto an empty folder are verified live (folder + two 300 MB
  files); a drop onto a folder row and the File › Upload… menu were not exercised.
- AC8 not verified live (no unplug during a transfer in any log); covered by `TransferQueueTests`
  (`deviceGoneFailsQueuedAndRunningAsRetryable`) and `disconnectEndsTransferPromptly`.
- AC9 verified with the fake device (fixed margins), not on hardware.
- User feedback during verification: progress was not visible enough → bottom status bar + toolbar ring added.
