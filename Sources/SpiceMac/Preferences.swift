// SPDX-License-Identifier: MIT
import Foundation
import DisplayScale

/// App preferences, backed by `UserDefaults`.
enum Preferences {
    private static let hideHostCursorKey = "HideHostCursor"

    /// When true, the macOS cursor is hidden over the display so only the guest
    /// cursor shows. Default off. Changing it posts `.hideHostCursorChanged`.
    static var hideHostCursor: Bool {
        get { UserDefaults.standard.bool(forKey: hideHostCursorKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: hideHostCursorKey)
            NotificationCenter.default.post(name: .hideHostCursorChanged, object: nil)
        }
    }

    private static let shareClipboardKey = "ShareClipboard"

    /// Whether to share the clipboard with the guest (both directions). Default
    /// ON (matches virt-viewer and the working behavior). Disable it when
    /// connecting to an untrusted VM — while on, anything you copy on the Mac is
    /// sent to the guest. Takes effect on the next connection.
    static var shareClipboard: Bool {
        get { (UserDefaults.standard.object(forKey: shareClipboardKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: shareClipboardKey) }
    }

    private static let trashAfterUseKey = "TrashConnectionFileAfterUse"

    /// Whether to move a `.vv` connection file to the Trash after using it to
    /// connect. Proxmox SPICE tickets are single-use and the file also carries the
    /// cluster CA, so keeping it around is pointless and a mild secret-hygiene risk.
    /// Default ON. It goes to the Trash (recoverable), not a permanent delete.
    static var trashConnectionFileAfterUse: Bool {
        get { (UserDefaults.standard.object(forKey: trashAfterUseKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: trashAfterUseKey) }
    }

    private static let displayZoomKey = "DisplayZoom"

    /// The zoom level a NEWLY opened window starts at: host physical pixels per
    /// guest pixel. A seed, NOT a live global — zoom belongs to the window (see
    /// `SpiceWindowController.displayZoom`), so writing this notifies nobody.
    /// Default `.automatic` (zoom = backingScaleFactor), and raw 0 == `.automatic`,
    /// so a missing key reads as automatic.
    static var displayZoom: DisplayZoom {
        get { DisplayZoom(rawValue: UserDefaults.standard.integer(forKey: displayZoomKey)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: displayZoomKey) }
    }
}

extension Notification.Name {
    static let hideHostCursorChanged = Notification.Name("SpiceMac.hideHostCursorChanged")
}
