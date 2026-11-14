# ADB-2 — evidence

No remote exists, so there is no PR; this file holds the evidence block that would go into the PR body.
All app lines come from `/usr/bin/log stream|show --info --predicate 'subsystem == "dev.local.AdbFiles"'`.

### Verification
- build: `swift package clean && swift build --build-tests` → exit 0, `grep -c 'warning:'` → 0 (after R2, R3 and final)
- lint: none configured (no third-party tools by design)
- tests: `swift test` → "Test run with 45 tests in 6 suites passed" (44 new); fake-server suite repeated 5× → 5/5 passed
- live server: `ADB_TEST_SERVER=1 swift test --filter LiveServer` → 2 passed (`version()`, `devices()` == first `trackDevices()` update)
- AC8: `grep -rnE '^import (SwiftUI|AppKit)' Sources/AdbKit` → empty
- protocol facts: `nc` probes of adb 1.0.41 (`OKAY00040029`, `FAIL001cunknown host service 'bogus'`, `OKAY0000`) and
  the live `host:devices-l` capture `OKAY005f9A251FFAZ0073G         device usb:1-1 product:flame model:Pixel_4 device:flame transport_id:63\n`
  (used verbatim as a test fixture); AOSP `transport.cpp`/`adb.cpp` for padding, field order and state words
- executed (a) AC1, server running, Pixel 4 attached, bare executable: `firstList ms=126`, `devices count=1 [9A251FFAZ0073G:device]`,
  `phase=ready`, no `start-server` line. Bundle launches after the App-init change: `firstList ms=` 487, 319, 467, 339, 334
- executed (b)/(f) AC4, emulator `Pixel_4_API_33` boot then `adb -s emulator-5554 emu kill`, app log vs a 0.25 s `adb devices` poll:
  offline 14:29:08.265 (poll .261), device 14:29:16.043 (poll .064), removed 14:29:19.845 (poll .878); the app also
  saw a transient `authorizing` the poll missed
- executed (c) AC5, `adb kill-server` at 14:28:16 while running: `tracking ended … closed` 16.985 → `phase=connecting` →
  `start-server via /opt/homebrew/bin/adb` 17.500 → `devices count=1` + `phase=ready` 20.559; process alive
- executed (d) AC2, cold launch with the server down: exactly one `start-server` line, list at `firstList ms=3184`
  (adb's own startup ≈3 s; UI showed "Connecting…"); `start-server` did not hang on the inherited pipe
- executed (e) AC3, server down + `ADBFILES_ADB_PATH=/nonexistent`: `server not running, starting it` → `phase=adbMissing`; process alive
- executed (g) AC6, Pixel 4 replug: `offline` → removed → `offline` → `authorizing` → `device`, `select … accepted state=device`
- user visual check: the user confirmed the UI looks right in light and dark mode

### Not verified
- `unauthorized` live: revoking USB-debugging authorizations on the phone did not bring up the prompt; the user chose to
  skip. Covered by parser fixtures (`parsesUnauthorizedWithoutModel`); the "Confirm USB debugging on your phone" view
  and `select … refused` were not exercised live.
- Multi-window sharing after the fix: opening a second window via `osascript` keystroke failed (no Accessibility
  permission). The fix is structural (store owned by `App`, `start()` idempotent); the pre-fix log of pid 36675 showed
  duplicated updates, which is what the fix removes.
- Two physical devices at once (only one phone + emulator were used together, which did work: `count=2`).
- The no-permissions state (Linux-only in practice) — parser fixture only.

### Found during verification and fixed
- Each window owned its own `DeviceStore` → two tracker connections and duplicated updates (pid 36675 log).
  Moved the store to `AdbFilesApp`.
- First-list latency up to 1098 ms when launched as a bundle because tracking began on view appear. Tracking now
  starts in `App.init`: 319–487 ms over 5 launches.
