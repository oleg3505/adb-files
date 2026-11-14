# ADB-1 — Milestone 1: Skeleton

## Problem
There is no project yet. Nothing builds, nothing launches, and later milestones (ADB host, browsing,
transfers) have no place to land.

## Goal / business value
Foundation for all three ranked goals in `CLAUDE.md` (instant, native, reliable). Specifically it fixes
the toolchain decisions — Swift 6 strict concurrency, macOS 14, SwiftPM instead of `.xcodeproj`, `.app`
bundle via scripts — so every later milestone builds on a verified base.

## Scope
- in:
  - `Package.swift` with three targets: `AdbKit` (library), `AdbFiles` (executable), `AdbKitTests` (tests).
  - Swift 6 language mode (strict concurrency on by default), platform `.macOS(.v14)`.
  - Minimal `AdbKit` placeholder (one public type with doc comment) so the library and test target compile.
  - One Swift Testing test in `AdbKitTests` so `swift test` runs green.
  - `AdbFiles` app: `@main` SwiftUI `App`, an `NSApplicationDelegate` that sets `.regular` activation
    policy and activates the app, one `WindowGroup` with an empty `NavigationSplitView`
    (sidebar placeholder "No devices", detail placeholder via `ContentUnavailableView`).
  - `Logger` with categories `ui` and `transfer` (`adb` is added inside `AdbKit` in milestone 2).
  - `Resources/Info.plist` (bundle id, name, version, `LSMinimumSystemVersion` 14.0, `NSHighResolutionCapable`).
  - `scripts/build-app.sh` (release build → `build/AdbFiles.app` → ad-hoc codesign) and `scripts/run.sh`
    (debug bundle → `open`).
  - A placeholder app icon generated at build time (no binary asset checked in).
  - `.gitignore`, `README.md` with build/run instructions, `docs/ARCHITECTURE.md` stub.
- **out (explicit):**
  - Any ADB code (server discovery, sockets, protocol) — milestone 2.
  - Device list, file table, bookmarks, real sidebar content — milestones 2–3/7.
  - Menus/commands beyond the SwiftUI defaults, keyboard shortcuts — milestone 7.
  - A designed app icon (placeholder only).
  - Notarization, Developer ID signing, DMG packaging.
  - CI pipeline.

## Acceptance criteria
- [ ] AC1 Given a clean checkout, when `swift build` runs, then it succeeds with **zero warnings**.
- [ ] AC2 Given a clean checkout, when `swift test` runs, then at least one test runs and passes.
- [ ] AC3 When `scripts/build-app.sh` runs, then `build/AdbFiles.app` exists with
      `Contents/MacOS/AdbFiles`, `Contents/Info.plist`, `Contents/Resources/AppIcon.icns`, and
      `codesign --verify --deep --strict build/AdbFiles.app` passes.
- [ ] AC4 When `scripts/run.sh` runs, then the app opens with a Dock icon, a menu bar, and one window
      showing a two-column split view (sidebar + detail placeholder).
- [ ] AC5 When the bare executable is run directly (`.build/debug/AdbFiles`), then it still gets a Dock
      icon, menu bar and comes to front.
- [ ] AC6 The window renders correctly in both light and dark mode (system colors only).
- [ ] AC7 `AdbKit` imports neither SwiftUI nor AppKit.

## Edge cases
| Case | Expected behaviour | Decided by |
|------|--------------------|-----------|
| `build/` already contains an old `.app` | Script removes and recreates it | assumption |
| Script run from a different cwd | Script `cd`s to the repo root itself | assumption |
| Closing the last window | App quits (`applicationShouldTerminateAfterLastWindowClosed` = true) | assumption, Finder-like single-window tool |
| `swift build` produces a warning | Treated as failure for this milestone | CLAUDE.md "fix all errors and warnings" |

## Open questions
| # | Question | My assumed answer | Needs a human? |
|---|----------|-------------------|----------------|
| 1 | Bundle identifier? | `dev.local.AdbFiles` (personal tool, never published) | no — easy to change |
| 2 | Test framework: XCTest or Swift Testing? | Swift Testing (`import Testing`), ships with Xcode 26 | no |
| 3 | No git repo and no remote exist — how does the "draft PR" stage work? | `git init` locally, work on branch `feat/ADB-1-skeleton`, commit; skip the PR because there is no remote | answered: local git, no PR |
| 4 | Quit on last window close? | Yes | no |
