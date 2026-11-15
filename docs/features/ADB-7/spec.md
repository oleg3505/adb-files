# ADB-7 — Milestone 7: Polish

## Problem
- Big folders fail to open while transfers run: the 10 s listing limit counts total time.
- Uploads silently "keep both" on a name clash. The user wants to be asked before anything is copied.
- Selecting several rows with the mouse is not possible: every drag that starts on a row becomes a file drag.
- The rest of milestone 7 in CLAUDE.md is still missing: bookmarks, prefetch, Wi-Fi debugging, a signpost and
  shortcut review.

## Goal / business value
- Goal 1 (instant): prefetch; listings that survive load.
- Goal 2 (native): Finder-like selection, conflict prompt, bookmarks, shortcuts.
- Goal 3 (reliable): no false timeouts.

## Decisions (user, 2026-11-14/15)
- Name conflicts (uploads and Download To…):
  - files get Replace / Keep Both / Skip, with "Apply to all";
  - folders get only Keep Both / Skip, because replacing a whole folder is too risky without a Trash.
- Drag hint near the cursor: one more attempt, driven only by the drop destinations, starting with a spike. If the
  spike breaks dragging again, the hint is **dropped from M7**.
- Wi-Fi debugging is verified live by the user (Wireless debugging on the phone, same Wi-Fi).
- Device writes only in `/sdcard/Download/AdbFilesTest/`, removed afterwards.
- Drag to Finder also asks on a name clash (user, 2026-11-15, during R3 verification): Finder renames silently, so
  the promise delegate detects that the original name exists and asks Replace / Keep Both / Skip. A spike decides
  whether Finder accepts the Replace write; if not, the user is told and Finder's behaviour stays.
- Listing timeout rule changes from 10 s total to 10 s of inactivity (user, 2026-11-15) → ADR-002, CLAUDE.md updated.
- Multi-selection: first without table-subclass changes; if that fails, overriding only `canDragRows(with:at:)` on
  the table is allowed (user, 2026-11-15).

## Scope
- in:
  - Listing timeout = 10 s with no data from the device (inactivity), not 10 s total.
  - Multi-selection:
    - a row drag starts only from the icon or the name text;
    - pressing elsewhere on a row and moving drag-selects a range;
    - ⌘-click, ⇧-click and ⌘A work.
  - Conflict prompt before enqueueing uploads (drops, path bar, File › Upload…) and Download To…:
    - one existence check per target folder;
    - a sheet with the choices and "Apply to all";
    - Skip drops the item; Replace overwrites; Keep Both behaves as today;
    - a clash that appears after the check still falls back to keep-both (never a silent overwrite).
  - Sidebar "Locations": Internal storage, DCIM, Download, Documents, Pictures, Music, for the selected device. The
    same entries appear in the Go menu.
  - Prefetch: a folder row selected or hovered for > 150 ms is listed in the background into `ListingCache`.
    - low priority and cancellable;
    - skipped if already cached;
    - opening that folder reuses the in-flight prefetch, and opening another folder cancels it.
  - Wi-Fi debugging sheet (File › Connect via Wi-Fi…): Pair (host:port + 6-digit code), Connect (host:port),
    Disconnect for a network device.
    - Uses adb server host services (`host:pair:…`, `host:connect:…`, `host:disconnect:…`; exact formats verified
      against AOSP before use).
    - The device then appears through `track-devices` as usual.
  - Thumbnails:
    - consecutive thumbnail reads reuse one interactive connection, only if measured reconnect cost > 20 ms per
      read;
    - the thumbnail disk cache is trimmed at launch above 500 MB to 400 MB, oldest first.
  - Signposts: intervals for list, transfer, thumbnail, plus new preview and prefetch intervals; README explains
    Instruments.
  - Shortcuts: CLAUDE.md list checked; gaps fixed.
  - Drag hint (droppable, see decisions).
- **out (explicit):**
  - mDNS discovery of Wi-Fi devices (QR pairing);
  - user-editable bookmarks;
  - Merge for folder conflicts;
  - a cache-size setting;
  - the File Provider extension (M8).

## Acceptance criteria
- [ ] AC1 `DCIM/Camera` (7,948 entries) opens while two 1 GB uploads run. A device that sends nothing for 10 s still
      fails with the timeout message.
- [ ] AC2 Dragging from the date/size/kind area or the empty part of a row selects a range. Dragging from the icon or
      name still drags files. ⌘-click, ⇧-click and ⌘A select. Existing drag & drop regressions pass.
- [ ] AC3 Uploading or downloading onto existing names asks first. Replace, Keep Both and Skip do exactly that.
      "Apply to all" asks once. Folders offer Keep Both / Skip only. Nothing is copied before the answer.
- [ ] AC4 Each Locations entry opens its folder on the selected device. A missing folder shows the normal
      "not found" state. Disabled when no device is usable.
- [ ] AC5 Hovering or selecting a folder for > 150 ms prefetches it, so opening it shows `source=cache`. Moving away
      sooner starts no listing. Prefetch never delays opening another folder.
- [ ] AC6 Pairing with a code, connecting and disconnecting a phone over Wi-Fi work from the sheet. Errors from adb
      ("failed to connect", wrong code) are shown readably.
- [ ] AC7 Thumbnail cache stays ≤ 500 MB after launch. The interactive connection reuse is decided by measurement and
      recorded.
- [ ] AC8 Signposts visible in Instruments for list, transfer, thumbnail, preview, prefetch.
- [ ] AC9 Drag hint shows "Move to “X”" / "Copy to “X”" / "Upload to “X”" near the cursor. Or: recorded as dropped
      after a failed spike.
- [ ] AC10 Clean build 0 warnings; tests green; `AdbKit` imports no SwiftUI/AppKit.

## Edge cases
| Case | Expected behaviour | Decided by |
|------|--------------------|-----------|
| Conflict appears after the check (another app writes) | Keep-both fallback, never overwrite | assumption |
| Replace on a file that is in use / permission denied | Transfer fails with Retry; upload goes via a part file + `mv`, so the original stays intact | assumption |
| Bookmark folder missing (e.g. no Music) | Normal "not found" state | assumption |
| Prefetch target is the folder the user opens | Open awaits the prefetch, no second listing | assumption |
| Two devices connected | Bookmarks act on the selected device | assumption |
| Pair code wrong / phone not in pairing mode | adb's message shown in an alert | assumption |
| `adb connect` to an unreachable host | Error within adb's own timeout; UI stays responsive | assumption |

## Open questions
None left (answered above).
