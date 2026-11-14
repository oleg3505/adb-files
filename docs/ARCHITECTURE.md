# Architecture

The authoritative project layout and constraints are in [CLAUDE.md](../CLAUDE.md) (§ Project layout,
§ Tech stack). This file records what actually exists.

## Targets (`Package.swift`)

| Target | Kind | Purpose | May import |
|--------|------|---------|------------|
| `AdbKit` | library | ADB protocol client (host, sync, shell) | Foundation, Network, os — **never SwiftUI/AppKit** |
| `AdbFiles` | executable | The macOS app | AdbKit, SwiftUI, AppKit, QuickLook |
| `AdbKitTests` | tests (Swift Testing) | Protocol tests without a device | AdbKit, Testing |

Swift 6 language mode (strict concurrency) and macOS 14 minimum for all targets.

## App (`Sources/AdbFiles`)

- `App/` — `AdbFilesApp` (`@main`, scenes), `AppDelegate` (activation policy, quit on last window),
  `RootView` (`NavigationSplitView`).
- `Features/<Feature>/` — views and their `@Observable` models, one folder per feature.
- `Services/` — cross-cutting services; `Log.swift` holds `Logger.ui` / `Logger.transfer`
  (subsystem `dev.local.AdbFiles`). `Logger.adb` will live in `AdbKit`.

## Packaging

`scripts/build-app.sh` assembles `build/AdbFiles.app` from the SwiftPM binary, `Resources/Info.plist`
and a generated placeholder icon (`scripts/make-icon.sh`), then ad-hoc signs it. `build/` is gitignored.
