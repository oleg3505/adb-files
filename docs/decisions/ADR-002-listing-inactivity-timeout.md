# ADR-002 — The listing timeout limits inactivity, not total time

- Status: accepted (user decision, 2026-11-15, milestone 7)
- Supersedes part of the CLAUDE.md rule "default 10 s for listing" (previously applied to the whole listing)

## Context
`AdbSyncClient.list` wrapped each listing in a 10 s total limit. During ADB-6 verification, two 1 GB uploads shared
the USB link and `DCIM/Camera` (7,948 entries) failed 4× with "The ADB server did not respond in time". An earlier run
under the same load needed 7.5 s. The device was sending data the whole time, so the error was false and the folder
could not be opened while transfers ran (goal 3, "reliable").

## Decision
`listTimeout` (default 10 s) is the longest wait for the device during a listing or stat: every write and every read
on the listing connection must finish within it. A listing that keeps delivering data may take as long as it needs.
The empty-folder access check uses the same limit. Connecting and the `host:transport` request keep their own
timeouts.

## Consequences
- A device that sends nothing for 10 s still fails with the same timeout message.
- There is no upper bound on a listing that trickles data. That is accepted: it can still be cancelled by navigating
  away, and `disconnect()` closes the connection when the device leaves.
- Same model as transfers (inactivity limit of 15 s, no total limit).
