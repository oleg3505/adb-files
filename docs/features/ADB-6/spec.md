# ADB-6 — Milestone 6: Quick Look and thumbnails

## Problem
The user can't see what a photo or document is without copying it to the Mac first, and the file list shows
only generic icons.

## Goal / business value
Goal 2 (native: Space opens Quick Look like Finder; thumbnails), goal 1 (instant: thumbnails from a tiny
prefix of each file, cached on disk; preview never queued behind big transfers).

## Verified facts (2026-11-14, Pixel 4, read-only)
- `/sdcard/DCIM/Camera`: 7,657 `.jpg` (≈1.8 MB each) and 291 `.mp4` (≈300 MB each).
- Reading only the first **16 KB** of a 1.8 MB camera JPEG (sync `RECV`, connection closed early) yields its
  embedded EXIF thumbnail (144×256) via `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceCreateThumbnailFromImageIfAbsent = false` — ~100× less data than the full file.

## Decisions (user, 2026-11-14)
- Row height switch: View › Small / Large rows (22 pt with 16 pt icons, or 48 pt with 40 pt thumbnails), remembered.
- Thumbnails: JPEG/HEIC from the first 64 KB (EXIF); PNG/WebP/GIF/BMP by full download when ≤ 10 MB; videos and
  everything else keep the system icon.
- One extra "interactive" sync connection per device for Quick Look and thumbnails (4 per device in total), so
  previews are never queued behind transfers. Recorded in ADR-001 and the CLAUDE.md connection rule.

## Scope
- in:
  - AdbKit: `AdbTransferSession.readPrefix(_:maxBytes:)` (RECV that stops early and reopens next time);
    `AdbSyncClient.openInteractiveSession()` with its own limit of 1.
  - App: `ThumbnailService` (actor): disk cache `~/Library/Caches/AdbFiles/thumbs/<serial>/` keyed by path, size and
    mtime; in-memory cache; at most 2 generations at once; requests only for visible rows, cancelled when rows
    scroll away; `os_signpost` "thumbnail".
  - `PreviewController`: Space toggles `QLPreviewPanel` for the selection; files are downloaded first to
    `~/Library/Caches/AdbFiles/preview/<serial>/` (reused while size+mtime match; cleared at launch); a spinner
    shows while loading; arrow keys move the selection and the panel follows; folders are skipped.
  - Table: thumbnails in the Name column; row height switch; context menu Quick Look enabled.
- **out (explicit):** video thumbnails; icon/grid view; Quick Look of folders; editing in Quick Look; a cache
  size limit UI (the thumbnail cache can be deleted by macOS as any Caches folder).

## Acceptance criteria
- [ ] AC1 Space on a selected file downloads it (spinner) and opens Quick Look; Space or Esc closes it; ↑/↓ in the
      table update the panel to the newly selected file.
- [ ] AC2 Quick Look works for a photo, a PDF/text file and a video; a second open of an unchanged file reuses the
      cached copy without downloading.
- [ ] AC3 With Large rows, `DCIM/Camera` shows photo thumbnails for the visible rows within ~2 s, reading ≤ 64 KB per
      JPEG; scrolling stays smooth (main thread < 16 ms per batch); off-screen requests are cancelled.
- [ ] AC4 Thumbnails come from the disk cache on the next visit / app launch (no device reads); a changed file
      (size or mtime) gets a new thumbnail.
- [ ] AC5 At most 2 thumbnail generations run at once; Quick Look and thumbnails keep working while 2 transfers run.
- [ ] AC6 The row size choice persists across launches; Small rows show 16 pt thumbnails.
- [ ] AC7 Clean build 0 warnings; tests green; `AdbKit` imports no SwiftUI/AppKit.

## Edge cases
| Case | Expected behaviour | Decided by |
|------|--------------------|-----------|
| JPEG without an EXIF thumbnail | Full download if ≤ 10 MB, else icon | user |
| File changed on the device | New key (size/mtime) → regenerated; old entry left for macOS to purge | assumption |
| Device gone during a preview download | Spinner stops, an alert says the preview couldn't be loaded | assumption |
| Quick Look on a 300 MB video | Downloads with the spinner (≈ 9 s); moving the selection cancels it | assumption |
| Multiple selected files | Quick Look shows them as a set (← → in the panel) | Finder |
| Unreadable file | Thumbnail: icon; Quick Look: alert with the device message | assumption |

## Open questions
None left (answered above).

Writes for AC5 only in `/sdcard/Download/AdbFilesTest/`, removed afterwards (user, 2026-11-14).
