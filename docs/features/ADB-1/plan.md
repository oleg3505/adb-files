# ADB-1 — implementation plan

<!-- A human writes this line to approve. Until it is here, guard-plan-approval blocks writes to code. -->
Approved-by: olehkondratiuk · 2026-11-14 (v2, after analyze BLOCK #1)

Pattern followed: none — greenfield repo. Structure comes from `CLAUDE.md` § Project layout, which acts as
the architecture decision for now. `docs/ARCHITECTURE.md` is created as a stub that points to it.

## Contract changes
- boundary: none (no public API yet beyond a placeholder `AdbKit` type).
- data: none.
- generated output: `build/AdbFiles.app` and `build/AppIcon.icns` from scripts; both gitignored.

## Requirements (ordered, each independently verifiable)

### R1 — Swift package with three targets, builds and tests green (S)
- files: `Package.swift` (new, `swift-tools-version: 6.0`, `.macOS(.v14)`),
  `Sources/AdbKit/AdbKit.swift` (new: `public enum AdbKit { public static let version }` with doc comment),
  `Sources/AdbFiles/App/AdbFilesApp.swift` (new: minimal `@main` stub so the executable links),
  `Tests/AdbKitTests/AdbKitTests.swift` (new), `.gitignore` (new: `.build/`, `build/`, `.swiftpm/`, `.DS_Store`)
- layer: package manifest / library / tests
- test: `Tests/AdbKitTests/AdbKitTests.swift` — asserts `AdbKit.version` is non-empty (smoke test proving
  the test target links against the library)
- executed how: `swift package clean && swift build 2>&1 | grep -c 'warning:'` → 0; `swift test` → 1 passed;
  `grep -rnE '^import (SwiftUI|AppKit)' Sources/AdbKit` → no output (AC7)
- risk: tools-version 6.0 implies Swift 6 language mode; verify strict concurrency is actually on by
  compiling a deliberate data-race snippet once locally (not committed)

### R2 — App shell: delegate, activation, empty split view, logger (S)
- files: `Sources/AdbFiles/App/AdbFilesApp.swift` (change: `WindowGroup` + `@NSApplicationDelegateAdaptor`),
  `Sources/AdbFiles/App/AppDelegate.swift` (new: `setActivationPolicy(.regular)`, `activate()`,
  quit on last window closed),
  `Sources/AdbFiles/App/RootView.swift` (new: `NavigationSplitView` with sidebar + detail),
  `Sources/AdbFiles/Features/Devices/DeviceSidebarView.swift` (new: placeholder list, "No devices"),
  `Sources/AdbFiles/Features/Browser/BrowserPlaceholderView.swift` (new: `ContentUnavailableView`),
  `Sources/AdbFiles/Services/Log.swift` (new: `Logger` extensions for `ui` and `transfer`, constant
  subsystem string `dev.local.AdbFiles` — no `Bundle.main` lookup, no force unwrap; the `adb` logger is
  added inside `AdbKit` in milestone 2, because `AdbKit` cannot import the app target)
- layer: app / features (UI only, no models yet — nothing to hold state)
- test: none automatable without UI testing infra; covered by execution below
- executed how: `swift package clean && swift build 2>&1 | grep -c 'warning:'` → 0; run `.build/debug/AdbFiles`
  → window appears with Dock icon and menu bar (AC5). AC6: launch `.build/debug/AdbFiles` (light) and
  `.build/debug/AdbFiles -AppleInterfaceStyle Dark` (dark, per-process, does not change system setting);
  window id found via a `swift -e` CGWindowListCopyWindowInfo one-liner filtered by owner "AdbFiles",
  captured with `screencapture -l<id>`; fallback `screencapture -w` (interactive) if Screen Recording is denied
- risk: SwiftUI `@main` inside an SPM executable without a bundle — window may not come to front;
  delegate `activate()` handles it (cheap to check on first run)

### R3 — `.app` bundle scripts, Info.plist, placeholder icon (M)
- files: `Resources/Info.plist` (new), `scripts/build-app.sh` (new), `scripts/run.sh` (new),
  `scripts/make-icon.sh` (new: renders an SF Symbol-free placeholder — a rounded square with "ADB"
  text via a tiny Swift script + `sips`/`iconutil` into `build/AppIcon.icns`)
- layer: build tooling
- test: the script itself asserts bundle layout and runs `codesign --verify --deep --strict`; non-zero exit on failure
- edge cases handled: script `cd`s to the repo root (`dirname "$0"/..`) so it works from any cwd;
  removes an existing `build/AdbFiles.app` before assembling
- executed how: `(cd /tmp && <repo>/scripts/build-app.sh)` (run from another cwd) twice in a row (stale bundle
  replaced) `&& ls -R build/AdbFiles.app && codesign --verify --deep --strict build/AdbFiles.app`;
  `scripts/run.sh` → app opens from bundle with icon in Dock (AC3, AC4)
- final verification after R3 (AC1, AC2, AC7): `swift package clean && swift build 2>&1 | grep -c 'warning:'` → 0,
  `swift test` → pass, `grep -rnE '^import (SwiftUI|AppKit)' Sources/AdbKit` → empty
- commits: one commit per requirement (no PR, no remote)
- risk: `swift build -c release` binary path differs per arch → use `swift build --show-bin-path`

### R4 — Docs (S)
- files: `README.md` (new: prerequisites, build/run/test commands), `docs/ARCHITECTURE.md` (new stub:
  targets, layering rule "AdbKit has no UI imports", pointer to CLAUDE.md)
- layer: docs
- test: n/a
- executed how: commands in README copy-pasted and run from a clean `.build`-less state
- risk: none

## Docs to update in this PR
- [ ] docs/features/ADB-1/spec.md (acceptance criteria checked off)
- [ ] docs/ARCHITECTURE.md — created
- [ ] README.md — created
- [ ] docs/decisions/ — none (decisions are already in CLAUDE.md)

## Risks
| Risk | Impact | Cheapest way to find out early |
|------|--------|-------------------------------|
| Bare SPM executable doesn't get a menu bar / focus | AC5 fails, poor dev loop | Run `.build/debug/AdbFiles` right after R2 |
| Ad-hoc signed bundle blocked by Gatekeeper / quarantine on `open` | AC4 fails | Locally built files carry no quarantine xattr; verify with `xattr build/AdbFiles.app` |
| Swift 6.3 / Xcode 26 introduces warnings in default SwiftUI templates (e.g. `NSApp` main-actor isolation in delegate) | AC1 fails | Compile R2 and fix with `@MainActor` annotations, not by lowering language mode |

## Assumptions
- Bundle id `dev.local.AdbFiles`, version `0.1.0`.
- Swift Testing for tests.
- Placeholder icon generated at build time; real icon is out of scope.
- Git: local repo, branch `feat/ADB-1-skeleton`, no PR because there is no remote (confirmed by user).
