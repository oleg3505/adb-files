import AppKit

/// The text next to the cursor while dragging: "Move to “X”", "Copy to “X”", "Upload to “X”".
enum DragHintText {
    enum Kind: Equatable { case move, copy, upload }

    static func make(_ kind: Kind, folder: String) -> String {
        let name = folder == "/" ? "/" : (folder as NSString).lastPathComponent
        switch kind {
        case .move: return "Move to “\(name)”"
        case .copy: return "Copy to “\(name)”"
        case .upload: return "Upload to “\(name)”"
        }
    }
}

/// A small label that follows the cursor during a drag.
///
/// Driven only by drop destinations (the table's `validateDrop`, path-bar segments): nothing here touches the
/// drag source, whose overrides broke drag & drop in ADB-5. The label is a borderless panel that ignores the mouse
/// and never becomes key. It hides when no destination has refreshed it for a moment, when the mouse button is up,
/// or when a destination says so.
@MainActor
final class DragHint {
    static let shared = DragHint()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var source: String?
    private var text: (() -> String?)?
    private var sticky = false
    private var lastPing = Date.distantPast

    /// Shows or refreshes the hint for `source`. Non-sticky sources (the table) must call this repeatedly while
    /// the drag is over them; sticky ones (a path segment) until they call `hide(from:)`.
    func show(from source: String, sticky: Bool = false, text: @escaping () -> String?) {
        self.source = source
        self.sticky = sticky
        self.text = text
        lastPing = Date()
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated { DragHint.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common) // also runs in the drag's event-tracking mode
            self.timer = timer
        }
        tick()
    }

    /// Hides the hint if `source` (or any source when nil) is showing it.
    func hide(from source: String? = nil) {
        guard source == nil || source == self.source else { return }
        timer?.invalidate()
        timer = nil
        self.source = nil
        text = nil
        panel?.orderOut(nil)
    }

    private func tick() {
        let stale = !sticky && Date().timeIntervalSince(lastPing) > 0.25
        guard !stale, NSEvent.pressedMouseButtons & 1 == 1, let value = text?() else {
            hide()
            return
        }
        let panel = self.panel ?? makePanel()
        label?.stringValue = value
        label?.sizeToFit()
        let size = NSSize(width: (label?.frame.width ?? 0) + 16, height: (label?.frame.height ?? 0) + 8)
        let mouse = NSEvent.mouseLocation
        panel.setFrame(NSRect(x: mouse.x + 18, y: mouse.y - size.height - 14, width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 24), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background
        panel.setAccessibilityElement(false) // VoiceOver users get the destination's own highlight
        self.panel = panel
        self.label = label
        return panel
    }
}
