# ADR-001 — One extra "interactive" sync connection per device

- Status: accepted (user decision, 2026-11-14, milestone 6)
- Supersedes part of the CLAUDE.md rule "1 for listing, plus up to 2 for transfers"

## Context
Quick Look downloads and thumbnail reads need a sync connection. Sharing the two transfer slots would make
pressing Space wait behind big copies (a 300 MB video transfer takes ~9 s), which breaks goal 1 ("feels instant").

## Decision
Each device gets one more sync connection, used only for interactive work (Quick Look and thumbnails):
1 listing + up to 2 transfers + 1 interactive. `AdbSyncClient.openInteractiveSession(priority:)` hands it out
through its own `AsyncLimiter(limit: 1)`; Quick Look asks with `.high` priority so it goes before queued
thumbnail reads (`.normal`). Thumbnail *decoding* may run 2 at a time; device reads on this connection are serial.

## Consequences
- Up to 4 sync connections per device. adbd handles many more; the cost is negligible.
- While a large preview downloads, thumbnail reads wait for it (accepted: the preview is what the user asked for).
- `disconnect()` closes this connection with the others when the device goes away.
