# ADB-2 — Milestone 2: ADB host

## Problem
The app shows a static "No devices" sidebar. It cannot find or start the ADB server, list devices, or
react when a device is plugged in, unplugged, or waiting for USB-debugging authorization.

## Goal / business value
Goal 1 (instant: live device list via push, no polling) and goal 3 (reliable: server restarts, missing
adb, unauthorized/offline devices handled without freezing). Foundation for browsing (milestone 3).

## Verified protocol facts (2026-11-14)
Probed the local adb server (1.0.41) with `nc`, and read AOSP `transport.cpp` / `adb.cpp` (main):
- Request: 4 lowercase-hex length + payload. `host:version` → `OKAY` + `0004` + `0029`.
- Error: `FAIL` + 4-hex length + message, e.g. `FAIL001cunknown host service 'bogus'`.
- `host:devices-l` → `OKAY` + 4-hex length + text (`OKAY0000` with no devices).
- `host:track-devices-l` → `OKAY`, then **immediately** one framed list, then a framed list on every
  change (`device_tracker_send`: `%04x` + text).
- Long line: `printf("%-22s %s", serial, state)`, then for each non-empty value ` <key><value>` in
  order: devpath (empty key, e.g. `usb:1-1`), `product:`, `model:` (non-alphanumerics → `_`), `device:`,
  then always ` transport_id:<n>`. Line ends with `\n`. Empty serial prints `(no serial number)`.
- States: `offline bootloader device host recovery rescue sideload unauthorized authorizing connecting
  detached`, plus the no-permissions help text (contains spaces; exact text not verified).

## Scope
- in:
  - `AdbKit`: typed `AdbError`; host-protocol framing; an `actor AdbConnection` over `NWConnection` with
    per-operation timeouts and `Task` cancellation; `AdbHostClient` with `version()`, `devices()`,
    `trackDevices()` (an `AsyncThrowingStream<[Device], Error>`); `devices-l` parser;
    `AdbServerLauncher` (locate adb binary, run `adb start-server`); `Logger.adb`.
  - App: `@Observable DeviceStore` that connects, starts the server if needed, tracks devices, and
    reconnects with backoff when the server dies; sidebar listing devices with state; detail states:
    adb missing (with `brew install android-platform-tools`), server error with Retry, unauthorized
    ("Confirm USB debugging on your phone"), offline, device selected (placeholder for milestone 3).
- **out (explicit):**
  - Sync protocol, `host:transport:`, features query, file listing — milestone 3.
  - Bookmarks in the sidebar — milestone 7.
  - Wi-Fi pairing / `adb connect` UI — milestone 7.
  - Cancelling per-device operations on disconnect (there are none yet) — milestone 3/4.
  - Settings UI for a custom adb path.

## Acceptance criteria
- [x] AC1 Given the adb server is running, when the app starts, then the sidebar shows the current
      devices (or "No devices") within 1 s, without any process spawn.
- [x] AC2 Given the server is not running and adb is installed, when the app starts, then it runs
      `adb start-server` once and shows the device list.
- [x] AC3 Given the server is not running and no adb binary is found, then the detail area shows the
      "adb not found" screen with the brew command and a Retry button.
- [x] AC4 Given the app is running, when a device appears, changes state or disappears, then the
      sidebar updates within 1 s without polling (track-devices push).
- [x] AC5 Given the server is killed while the app runs (`adb kill-server`), then the app restarts it
      and resumes tracking, with no freeze and no crash.
- [ ] AC6 Devices in `unauthorized` state show "Confirm USB debugging on your phone"; `offline` and other
      non-`device` states are shown dimmed with their state; only `device` is selectable for browsing.
- [x] AC7 Unit tests cover framing, `FAIL` handling, `devices-l` parsing from byte fixtures (incl. the
      edge cases below), adb path lookup, and the host client against an in-process fake server.
- [x] AC8 `swift build` (clean) has zero warnings; `AdbKit` still imports no SwiftUI/AppKit.

## Edge cases
| Case | Expected behaviour | Decided by |
|------|--------------------|-----------|
| Serial longer than 22 chars (mDNS `adb-XXXX._adb-tls-connect._tcp`) | Parsed correctly (no padding) | AOSP `%-22s` |
| `(no serial number)` serial (contains spaces) | Parsed as that serial | AOSP |
| No-permissions state with spaces | State `.noPermissions`, raw text kept | AOSP |
| Unknown future state word | `.unknown(raw)`, shown with raw text | assumption |
| Line without `model:`/`product:` | Display name falls back to serial | assumption |
| Model `Pixel_8` (sanitized) | Display as `Pixel 8` (underscores → spaces) | assumption |
| Empty payload (`0000`) | Empty list | probe |
| Track update split across TCP reads / several updates in one read | Framing decoder buffers correctly | assumption |
| Server closes the track connection | Store reconnects with backoff 0.5 s → 1 s → 2 s … max 5 s | assumption |
| Connect refused vs timeout | Refused → try to start server; timeout (2 s) → error state with Retry | assumption |

## Open questions
| # | Question | My assumed answer | Needs a human? |
|---|----------|-------------------|----------------|
| 1 | Do you have a physical phone to verify the `unauthorized` state? | Answered: a phone is connected; used for live `unauthorized`/`device` checks alongside the emulator | answered |
| 2 | How to simulate "adb missing" for verification? | Env var `ADBFILES_ADB_PATH` overrides lookup (debug aid, documented in README); set to a non-existent path with the server killed | no |
| 3 | Which adb path wins if several exist? | Order from CLAUDE.md: Homebrew arm64, `/usr/local`, Android SDK, then `$PATH` | no |

## Verification notes (2026-11-14)
- AC6 partially verified live: `offline`/`authorizing` → `device` transitions on the emulator and on the
  Pixel 4 replug were logged and rendered; `unauthorized` could not be produced (revoking authorizations on
  the phone did not trigger the prompt) and the user chose to skip it. Covered by parser fixtures only;
  the "selection refused" path was not exercised live.
- Found during verification and fixed in R4: each window created its own `DeviceStore` (two ADB
  connections, duplicated updates). The store is now owned by `AdbFilesApp` and shared by all windows;
  tracking starts in `App.init`, which also brought first-list latency from up to 1098 ms to 319–487 ms.
