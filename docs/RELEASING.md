# Releasing

How a version of AdbFiles reaches users: a DMG on GitHub Releases, linked from the GitHub Pages site.

- Repository: https://github.com/oleg3505/adb-files
- Site: https://oleg3505.github.io/adb-files/ (source in `site/`)
- Stable download link: https://github.com/oleg3505/adb-files/releases/latest/download/AdbFiles.dmg — it always
  resolves to the `AdbFiles.dmg` asset of the newest release, so the site and README never need a version bump.

## Checklist

1. On a branch, bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`. Merge to `main`.
2. Check: `swift build --build-tests` with 0 warnings and `swift test` all green.
3. `scripts/make-dmg.sh` → `build/AdbFiles.dmg`. The script runs `build-app.sh` (release build, ad-hoc signing),
   packs the app plus an `Applications` shortcut with `hdiutil`, and verifies the image.
4. Optional smoke test: mount the DMG, `codesign --verify --deep --strict` the app inside it, and launch it.
5. A human publishes the release (the apiko hooks block agents from doing it):
   ```sh
   gh release create vX.Y.Z build/AdbFiles.dmg --target main --title "AdbFiles X.Y.Z" --notes "…"
   ```
   The asset **must** be named `AdbFiles.dmg`, or the stable link breaks.
6. Check that the stable link returns 200 and that the downloaded size matches the local file:
   ```sh
   curl -sL -o /dev/null -w "%{http_code} %{size_download}\n" \
     https://github.com/oleg3505/adb-files/releases/latest/download/AdbFiles.dmg
   ```

## Website

- `site/index.html` is a single static page with no build step and no external requests.
- `.github/workflows/pages.yml` deploys `site/` on every push to `main` that touches `site/**` or the workflow, and on
  manual dispatch. Pages is set to the "GitHub Actions" source.
- When the app gains a user-visible feature or a shortcut, update the Features and Shortcuts sections there and in
  `README.md` in the same PR.

## Builds

- **Architecture:** Apple silicon only (`arm64`, the host architecture of `swift build`). Intel Macs would need a
  universal build (`swift build --arch arm64 --arch x86_64`), which is not set up.
- **Minimum macOS:** 14 (`LSMinimumSystemVersion`).
- **Signing:** ad-hoc (`codesign -s -`), not notarized.

## Gatekeeper: why users see a warning

A file downloaded by a browser gets the `com.apple.quarantine` extended attribute. On first launch, Gatekeeper checks
a quarantined app for a Developer ID signature and an Apple notarization ticket. An ad-hoc signed app has neither, so
macOS shows:

> "AdbFiles" Not Opened — Apple could not verify "AdbFiles" is free of malware that may harm your Mac or compromise
> your privacy. [Done] [Move to Bin]

How users open it, as also documented on the site and in the README:

| macOS | Steps |
|---|---|
| 15 Sequoia and later | Done → System Settings → Privacy & Security → Security → **Open Anyway** → password / Touch ID. Right-click → Open no longer bypasses the check. |
| 14 Sonoma | Right-click the app → Open → Open. |
| Any | `xattr -dr com.apple.quarantine /Applications/AdbFiles.app` |

Builds made locally (`scripts/run.sh`, `scripts/build-app.sh`) are not quarantined, so they open without a warning.

## Removing the warning (not done)

This requires a paid Apple Developer Program membership ($99/year). Then:

1. Create a **Developer ID Application** certificate and install it in the login keychain.
2. Sign with the hardened runtime instead of ad-hoc:
   `codesign --force --options runtime --timestamp -s "Developer ID Application: <Name> (<TEAMID>)" build/AdbFiles.app`
   and sign the DMG the same way.
3. Notarize and staple:
   ```sh
   xcrun notarytool store-credentials adbfiles --apple-id <id> --team-id <TEAMID>   # once
   xcrun notarytool submit build/AdbFiles.dmg --keychain-profile adbfiles --wait
   xcrun stapler staple build/AdbFiles.dmg
   ```
4. Check: `spctl -a -vv -t install build/AdbFiles.dmg` → "source=Notarized Developer ID".

Steps 2–3 would go into `scripts/make-dmg.sh` behind an environment variable (for example `ADBFILES_SIGN_ID`), so that
local ad-hoc builds keep working. The hardened runtime may need entitlements if something breaks. The app does not
use the sandbox, but it opens TCP connections to `127.0.0.1:5037` and launches `adb`, and both should be retested.
