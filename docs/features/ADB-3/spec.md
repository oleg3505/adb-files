# ADB-3 — Milestone 3: Browsing

## Problem
A connected device shows "File browsing arrives in the next milestone". The user cannot see, sort or
navigate the files on the phone.

## Goal / business value
Goal 1 (instant: cached listings shown immediately, 10k-item folders scroll smoothly via `NSTableView`),
goal 2 (native: Finder-like table, breadcrumbs, Back/Forward/Up, type-to-select, shortcuts), goal 3
(reliable: timeouts, permission-denied/not-found states, device unplugged mid-listing).

## Verified protocol facts (2026-11-14, Pixel 4 + AOSP `file_sync_protocol.h`, `daemon/file_sync_service.cpp`)
- `host-serial:<serial>:features` → comma list; the Pixel 4 has `ls_v2` and `stat_v2`.
- `host:transport:<serial>` → `OKAY`, then `sync:` → `OKAY` on the same socket.
- Request: 4-byte id + LE `UInt32` path length (≤ 1024) + UTF-8 path.
- `LIS2` → `DNT2` entries: id, error u32, dev u64, ino u64, mode u32, nlink u32, uid u32, gid u32,
  size u64, atime i64, mtime i64, ctime i64, namelen u32 (76 bytes) + name; terminated by `DONE` + 72
  zero bytes. `LIST` (v1) → `DENT` id, mode, size, mtime, namelen (20 bytes) + name; `DONE` + 16 zero bytes.
- `.` and `..` are **not** returned. A missing or unreadable directory returns just `DONE` — same as an
  empty one. `LST2` on a missing path → `error=2`; on `/data/` → `error=0`, mode `040771`.
- `/sdcard/DCIM/Camera/` on the Pixel 4: 7,948 entries.

## Scope
- in:
  - Test target `AdbFilesTests` (`@testable import AdbFiles`) incl. the deferred `DeviceStore` loop tests.
  - AdbKit: `RemoteFile`, sync framing + incremental `DENT`/`DNT2`/`DONE`/`FAIL` decoder, features query,
    `AdbShell` (single quoting helper + `shell:` runner), `actor AdbSyncClient` (one persistent listing
    connection per device, `list`, `lstat`, 10 s timeout, cancellation, reconnect), `os_signpost` around listing.
  - App: `BrowserStore` per window (path, Back/Forward history, phase, sort, hidden toggle), in-memory
    `ListingCache` with stale-while-revalidate and a name-based diff, `FileTableView` (`NSTableView`):
    Name/Date Modified/Size/Kind, sortable, folders first, multi-selection, double-click/Enter opens,
    type-to-select; breadcrumbs; toolbar Back/Forward/Up/Refresh/Hidden; menu commands ⌘[ ⌘] ⌘↑ ⌘↓ ⌘R ⌘⇧.;
    states: loading, empty folder, permission denied, not found, error with Retry, device gone.
- **out (explicit):**
  - Transfers, drag & drop, Quick Look, thumbnails, context menu, file operations — milestones 4–6.
  - Bookmarks sidebar section, prefetch on hover — milestone 7.
  - Disk-persisted listing cache (in-memory per app session only).
  - Following symlinks to show their target kind (shown as "Alias"; opening tries to list `path/`).
  - Column customisation/persistence, search/filter field.

## Acceptance criteria
- [ ] AC1 Selecting a usable device shows `/sdcard/` (Internal storage) in the table, folders first, sorted by name.
- [ ] AC2 Double-click / Enter / ⌘↓ on a folder opens it; ⌘↑ goes to the parent; ⌘[ / ⌘] go Back/Forward;
      breadcrumb segments navigate to that folder.
- [ ] AC3 Clicking a column header sorts by Name / Date Modified / Size / Kind, toggling direction; folders stay first.
- [ ] AC4 ⌘⇧. toggles dot-files; ⌘R refreshes.
- [ ] AC5 Re-entering a folder visited this session shows the cached listing within 100 ms, refreshes in
      the background, and only reloads the table if the listing changed (selection kept by name).
- [ ] AC6 `/sdcard/DCIM/Camera/` (7,948 items) lists without freezing the UI; sort/filter run off the main thread.
- [ ] AC7 `/data/` shows "Permission denied"; a missing path shows "Folder not found"; an empty folder shows "Empty folder".
- [ ] AC8 Unplugging the device during or after a listing shows the device status/disconnected state; no crash, no hang.
- [ ] AC9 Multi-selection (⇧/⌘-click) and type-to-select work.
- [ ] AC10 Names with Cyrillic and emoji display correctly; sizes over 4 GB display correctly (64-bit, fixture).
- [ ] AC11 Clean build 0 warnings; tests green; `AdbKit` imports no SwiftUI/AppKit.

## Edge cases
| Case | Expected behaviour | Decided by |
|------|--------------------|-----------|
| Device without `ls_v2` | Falls back to `LIST` (32-bit sizes) | AOSP |
| 0 entries returned | `LST2`: error≠0 → not found (2) / other errno; else `shell: test -r -a -x` → denied or empty | live probe |
| Path > 1024 bytes | `AdbError.invalidRequest`, no request sent | AOSP limit |
| Symlink entry (e.g. `/sdcard`) | Kind "Alias"; open lists `path/` | assumption |
| Listing connection dies (unplug, server restart) | Error state; next navigation reconnects | assumption |
| Navigate away while a listing is in flight | Previous listing cancelled, result discarded | CLAUDE.md cancellation |
| Device switched in sidebar | Browser resets to `/sdcard/` for that device; per-device cache keys | assumption |
| DNT2 entry with `error≠0` | Shown with name only (size/date "—") | AOSP raw errno |

## Open questions
| # | Question | My assumed answer | Needs a human? |
|---|----------|-------------------|----------------|
| 1 | Where are app-logic tests? | New `AdbFilesTests` target | answered |
| 2 | May I create temporary test folders on the phone? | Answered: no. Use existing folders (Camera 7,948 items), fixtures for Cyrillic/emoji and >4 GB | answered |
| 3 | Start folder | `/sdcard/` | no |
