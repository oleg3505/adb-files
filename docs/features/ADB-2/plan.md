# ADB-2 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-14 (v2, after analyze BLOCK #1)

Pattern followed: `Sources/AdbKit/AdbKit.swift` + `Tests/AdbKitTests/AdbKitTests.swift` (library type with
doc comments, Swift Testing suites) and `Sources/AdbFiles/Features/<Feature>/` from ADB-1; layering per
`docs/ARCHITECTURE.md` (AdbKit has no UI imports). First stateful model in the app → `@Observable`
`@MainActor` store, as CLAUDE.md prescribes. No ADR: every choice here is already in CLAUDE.md.

## Contract changes
- boundary: new public AdbKit API (`AdbError`, `Device`, `DeviceState`, `AdbConnection`, `AdbHostClient`,
  `AdbServerLauncher`). Only consumer: the app target. Additive.
- data: none. generated output: none.

## Requirements (ordered, each independently verifiable)

### R1 — Models, errors, framing and `devices-l` parser (M)
- files: `Sources/AdbKit/Models.swift` (new: `Device`, `DeviceState` incl. `.noPermissions(String)`,
  `.unknown(String)`), `Sources/AdbKit/AdbError.swift` (new: typed errors with user-readable messages),
  `Sources/AdbKit/HostProtocol.swift` (new: request encoding, incremental `HostMessageDecoder` for
  OKAY/FAIL + length-prefixed payloads), `Sources/AdbKit/DeviceListParser.swift` (new),
  `Sources/AdbKit/Log.swift` (new: `Logger.adb`, subsystem `dev.local.AdbFiles`)
- layer: AdbKit, pure functions (no I/O)
- test: `Tests/AdbKitTests/HostProtocolTests.swift` — encode `host:version` → `000chost:version`,
  multibyte UTF-8 length counts bytes; decode OKAY, FAIL+message, payload split across chunks, two
  payloads in one chunk, invalid hex → error. `Tests/AdbKitTests/DeviceListParserTests.swift` — fixtures:
  USB device line, emulator line, unauthorized (no product/model), offline, 22+ char mDNS serial,
  `(no serial number)`, no-permissions text with spaces, unknown state, empty payload, trailing newline.
- executed how: `swift test` → all pass; fixtures cross-checked against a live `nc` capture of
  `host:devices-l` with an emulator running (captured bytes pasted into one fixture)
- risk: no-permissions text unknown → parser treats anything after the serial up to the first ` usb:`/
  ` product:`/` transport_id:` token as the state; covered by a fixture

### R2 — `AdbConnection` + `AdbHostClient` over NWConnection (L)
- files: `Sources/AdbKit/AdbConnection.swift` (new: `actor`, connect/send/receive(exactly:) with timeout,
  cancellation via `withTaskCancellationHandler`, maps `ECONNREFUSED` → `AdbError.serverNotRunning`),
  `Sources/AdbKit/AdbHostClient.swift` (new: `version()`, `devices()`, `trackDevices()`)
- layer: AdbKit, I/O
- test: `Tests/AdbKitTests/AdbHostClientTests.swift` — in-process fake server on `NWListener`
  (127.0.0.1, ephemeral port): version round-trip, FAIL → `AdbError.serverFailure(msg)`, track stream
  yields 3 updates then server close → stream throws `connectionClosed`, client-side cancel ends the
  stream, connect to a closed port → `serverNotRunning`, silent server → `timeout` within budget.
  `Tests/AdbKitTests/LiveServerTests.swift` — `host:version` + `devices()` against the real server,
  skipped unless `ADB_TEST_SERVER=1`
- executed how: `swift test`; `ADB_TEST_SERVER=1 swift test --filter LiveServer` against the running server
- risk: NWConnection callback → async bridging under Swift 6 strict concurrency (Sendable closures);
  fake-server test proves it before any UI work

### R3 — Server discovery and start (S)
- files: `Sources/AdbKit/AdbServerLauncher.swift` (new: candidate paths per CLAUDE.md + `$PATH`, env
  override `ADBFILES_ADB_PATH`, `startServer()` runs `adb start-server` via `Process` off the main actor,
  returns `AdbError.adbNotFound` / `.serverStartFailed(output)`)
- layer: AdbKit
- test: `Tests/AdbKitTests/AdbServerLauncherTests.swift` — lookup order with an injected
  `isExecutable` closure and fake `PATH`; override wins; nothing found → `adbNotFound`
- executed how: unit tests here; executed live in R4 step (d) (real `adb start-server` after
  `adb kill-server`) and step (e) (`ADBFILES_ADB_PATH=/nonexistent` → `adbNotFound`)
- risk: none

### R4 — `DeviceStore` and UI states (M)
- files: `Sources/AdbFiles/Features/Devices/DeviceStore.swift` (new: `@Observable @MainActor`; phases
  `.connecting / .adbMissing / .failed(AdbError) / .ready`; flow: track → on `serverNotRunning` start
  server once → track; on stream end reconnect with backoff 0.5→5 s; `retry()`),
  `Features/Devices/DeviceSidebarView.swift` (change: device rows with SF Symbol + state text, dimmed
  when not `.device`, VoiceOver labels), `Features/Devices/DeviceRow.swift` (new),
  `Features/Browser/BrowserPlaceholderView.swift` (change: per selection/phase), `Features/Devices/
  AdbMissingView.swift` (new), `Features/Devices/DeviceStatusView.swift` (new: unauthorized/offline),
  `App/RootView.swift` (change: owns store via `@State`, selection binding), `App/AdbFilesApp.swift`
  (change if needed)
- layer: app features
- test: no UI test infra; store logic covered via R2/R3 tests; execution below is the proof
- logging for evidence: the store logs (info, `ui` category) every phase change (`phase=…`), every
  applied list update (`devices count=N [serial:state, …]`, os_log timestamps), app-start → first-list
  latency (`firstList ms=…`), every selection attempt (`select serial=… accepted|refused state=…`); the
  launcher logs (`adb` category) each `start-server` spawn
- executed how (each with `log stream --level info --predicate 'subsystem == "dev.local.AdbFiles"'`
  captured): (a) server running, Pixel 4 plugged in → log shows the phone as `device`, `firstList ms`
  < 1000, and **no** `start-server` line (AC1 incl. "no process spawn"); (b) boot `Pixel_4_API_33`
  emulator → update lines show it `offline`, then `device`; timestamps vs `adb devices` poll in a
  side loop < 1 s apart (AC4, AC6); (c) `adb kill-server` while running → restart logged, list returns
  (AC5); (d) quit app, `adb kill-server`, launch → exactly one `start-server` line (AC2, R3 live);
  (e) `adb kill-server` + `ADBFILES_ADB_PATH=/nonexistent .build/debug/AdbFiles` → `phase=adbMissing`
  (AC3, R3 live); (f) `adb -s emulator-5554 emu kill` → update line without the emulator, < 1 s (AC4);
  (g) **user-assisted, physical Pixel 4 (9A251FFAZ0073G)**: user revokes USB debugging authorizations in
  Developer options and replugs → update shows `unauthorized`; user clicks the row → `select … refused
  state=unauthorized`; detail shows "Confirm USB debugging on your phone"; user accepts the prompt on
  the phone → update shows `device`; clicking → `select … accepted` (AC6)
- risk: visual states can't be screenshotted (no Screen Recording permission) → phase changes are
  logged and asserted from the log; final visual check by the user

## Final verification (after R4)
`swift package clean && swift build 2>&1 | grep -c 'warning:'` → 0; `swift test` → pass;
`grep -rnE '^import (SwiftUI|AppKit)' Sources/AdbKit` → empty. One commit per requirement.

## Docs to update in this PR
- [ ] docs/features/ADB-2/spec.md (AC ticked, verification notes) + evidence.md
- [ ] docs/ARCHITECTURE.md — AdbKit files and the DeviceStore flow
- [ ] README.md — `ADBFILES_ADB_PATH` and `ADB_TEST_SERVER`
- [ ] docs/decisions/ — none

## Risks
| Risk | Impact | Cheapest way to find out early |
|------|--------|-------------------------------|
| NWConnection + Swift 6 Sendable friction | R2 balloons | Fake-server round-trip test is the first thing written in R2 |
| `devices-l` real format differs from AOSP reading (devpath, no-perm text) | Wrong names/states | Live `nc` capture with the emulator in R1 |
| Reconnect loop hammering the server / spawning `adb` repeatedly | CPU, log spam | Start server at most once per failure streak; backoff capped at 5 s; logged |

## Assumptions
- Emulator `Pixel_4_API_33` is used for live verification. Env override `ADBFILES_ADB_PATH` is a debug aid.
- Connect timeout 2 s, request timeout 10 s (CLAUDE.md default for listing).
- Git: branch `feat/ADB-2-adb-host`, local commits, no PR (no remote).
