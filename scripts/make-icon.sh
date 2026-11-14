#!/usr/bin/env bash
# Generates a placeholder app icon at build/AppIcon.icns (rounded square with "ADB").
# Skipped when the .icns is newer than this script.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="build/AppIcon.icns"

if [[ -f "$OUT" && "$OUT" -nt "$0" ]]; then
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p build "$WORK/AppIcon.iconset"

cat > "$WORK/draw.swift" <<'EOF'
import AppKit

let size = 1024.0
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.current = context
let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
NSGradient(
    starting: NSColor(calibratedRed: 0.20, green: 0.70, blue: 0.40, alpha: 1),
    ending: NSColor(calibratedRed: 0.05, green: 0.40, blue: 0.25, alpha: 1)
)?.draw(in: path, angle: -90)

let text = "ADB" as NSString
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: size * 0.26, weight: .heavy),
    .foregroundColor: NSColor.white,
]
let textSize = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2), withAttributes: attrs)
NSGraphicsContext.current = nil

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF

swift "$WORK/draw.swift" "$WORK/icon_1024.png"

for px in 16 32 128 256 512; do
    sips -z "$px" "$px" "$WORK/icon_1024.png" --out "$WORK/AppIcon.iconset/icon_${px}x${px}.png" >/dev/null
    double=$((px * 2))
    sips -z "$double" "$double" "$WORK/icon_1024.png" --out "$WORK/AppIcon.iconset/icon_${px}x${px}@2x.png" >/dev/null
done

iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT"
echo "Icon: $OUT"
