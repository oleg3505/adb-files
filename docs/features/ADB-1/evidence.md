# ADB-1 — evidence

No remote exists, so there is no PR; this file holds the evidence block that would go into the PR body.

### Verification
- typecheck/build: `swift package clean && swift build` → exit 0, `grep -c 'warning:'` → 0 (clean build, after R1, R2 and R3)
- lint: none configured for this repo (Swift; no SwiftLint by design — no third-party deps)
- tests: `swift test` → "Test run with 1 test in 1 suite passed" (1 new)
- strict concurrency: temp file `var probeCounter = 0` in AdbKit → `error: var 'probeCounter' is not concurrency-safe because it is nonisolated global shared mutable state` (file removed afterwards)
- AC7: `grep -rnE '^import (SwiftUI|AppKit)' Sources/AdbKit` → no output
- executed (bundle): `(cd /tmp && <repo>/scripts/build-app.sh)` twice → exit 0 both times; stale marker file in the old bundle gone after run 2;
  bundle contains `Contents/Info.plist`, `Contents/MacOS/AdbFiles`, `Contents/Resources/AppIcon.icns`, `Contents/_CodeSignature/CodeResources`;
  `codesign --verify --deep --strict build/AdbFiles.app` → OK; `codesign -dv` → `Identifier=dev.local.AdbFiles`, `Signature=adhoc`
- executed (UI, bundle): `scripts/run.sh` and `open build/AdbFiles.app` → CGWindowList shows an on-screen layer-0 window owned by AdbFiles;
  `NSWorkspace.frontmostApplication` → `AdbFiles`; `activationPolicy` → 0 (`.regular`)
- executed (UI, bare executable): `.build/debug/AdbFiles` and `.build/debug/AdbFiles -AppleInterfaceStyle Dark` → window 900×472 on screen,
  `activationPolicy` → 0 (`.regular`)

### Not verified
- AC5 "comes to front" for the bare executable: frontmost stayed Google Chrome. macOS 14+ cooperative activation does not let a
  terminal-launched background process steal focus. Via `open` it is frontmost.
- AC6 light/dark rendering: `screencapture -l<id>` → "could not create image from window" (terminal lacks Screen Recording
  permission). Needs a human visual check.
- `Logger.ui.info("App launched")` reaching the unified log: info-level messages are not persisted, so `log show` returns nothing;
  would need `log stream --level info` while launching.
- Dock icon appearance (icon file is in the bundle and referenced by `CFBundleIconFile`; not visually checked).

### Self-review
- `code-reviewer` on `9f513f4..HEAD`: 0 blocking, 0 should-fix, 1 nit (make-icon.sh freshness check used a cwd-relative `$0`
  after `cd`). Fixed; executed `(cd scripts && ./make-icon.sh)` after touching the script → icon regenerated ("Icon: build/AppIcon.icns"),
  second run skipped; `scripts/build-app.sh` → built and verified.
- Manual scan of added Swift lines for `try!`, `as!`, force unwraps, `print(`, lint disables, `nonisolated(unsafe)`: none. No secrets.
