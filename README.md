# AdbFiles

Native macOS app for browsing and managing files on Android devices over ADB.
Personal tool; not distributed.

## Requirements

- macOS 14 or newer
- Xcode 16+ (Swift 6 toolchain; Swift Testing is used for tests)
- `adb` — `brew install android-platform-tools` (needed from milestone 2)

## Build and run

```sh
swift build            # compile
swift test             # unit tests
scripts/run.sh         # debug .app bundle, then launch it
scripts/build-app.sh   # release build → build/AdbFiles.app (ad-hoc signed)
```

`.build/debug/AdbFiles` can also be run directly; the app sets a regular activation policy, so it still
gets a Dock icon and a menu bar. macOS may not bring it to the front when launched from a terminal —
`scripts/run.sh` (via `open`) does.

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Project rules and milestones live in [CLAUDE.md](CLAUDE.md).
