// SPDX-License-Identifier: MIT
import AppKit

/// The hairline at the window's left edge that reveals the guest picker on hover.
///
/// An accelerator, never the only route — the menu command does the real work. It is
/// four points wide on purpose: this sits over a live console, and anything a person
/// could brush past while working in the guest would fire constantly.
final class PVEOverlayEdgeTrigger: NSView {
    var onEnter: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    /// Transparent to clicks. The guest owns the pixels underneath, and swallowing a
    /// click at the edge of a VM's screen would be its own bug.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
