// SPDX-License-Identifier: MIT
import AppKit
import DisplayScale

/// Builds the application main menu programmatically (no nib). Connection-specific
/// actions (release cursor, send Ctrl-Alt-Del, USB) use `nil` targets so they
/// travel the responder chain to the front `SpiceWindowController`.
enum MainMenu {
    static func build() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        let trashAfterUse = NSMenuItem(title: "Move .vv to Trash After Connecting",
                                       action: #selector(AppDelegate.toggleTrashConnectionFile(_:)), keyEquivalent: "")
        trashAfterUse.state = Preferences.trashConnectionFileAfterUse ? .on : .off
        trashAfterUse.toolTip = "Proxmox SPICE tickets are single-use and the file also holds the "
            + "cluster CA, so move it to the Trash once it has been used to connect."
        fileMenu.addItem(trashAfterUse)

        // Edit menu (standard responder-chain selectors so clipboard works)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Connection menu (routed to SpiceWindowController via responder chain)
        let connItem = NSMenuItem()
        mainMenu.addItem(connItem)
        let connMenu = NSMenu(title: "Connection")
        connItem.submenu = connMenu
        connMenu.addItem(withTitle: "Send Ctrl-Alt-Del",
                         action: #selector(SpiceWindowController.sendCtrlAltDel(_:)), keyEquivalent: "")
        let release = NSMenuItem(title: "Release Cursor",
                                 action: #selector(SpiceWindowController.releaseCursor(_:)), keyEquivalent: "r")
        release.keyEquivalentModifierMask = [.control, .option]
        connMenu.addItem(release)
        connMenu.addItem(.separator())
        let shareClipboard = NSMenuItem(title: "Share Clipboard with VM",
                                        action: #selector(AppDelegate.toggleShareClipboard(_:)), keyEquivalent: "")
        shareClipboard.state = Preferences.shareClipboard ? .on : .off
        shareClipboard.toolTip = "Share the clipboard with the VM (both directions). "
            + "Takes effect on the next connection. Turn off for untrusted VMs."
        connMenu.addItem(shareClipboard)
        connMenu.addItem(.separator())
        // USB submenu, populated dynamically by the window controller.
        let usbItem = NSMenuItem(title: "USB Devices", action: nil, keyEquivalent: "")
        let usbMenu = NSMenu(title: "USB Devices")
        usbItem.submenu = usbMenu
        usbSubmenu = usbMenu
        connMenu.addItem(usbItem)

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(.separator())
        viewMenu.addItem(zoomMenuItem())
        viewMenu.addItem(.separator())
        let hideCursor = NSMenuItem(title: "Hide Mac Cursor",
                                    action: #selector(AppDelegate.toggleHideMacCursor(_:)), keyEquivalent: "")
        hideCursor.state = Preferences.hideHostCursor ? .on : .off
        viewMenu.addItem(hideCursor)

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    /// The USB submenu, populated dynamically by the front `SpiceWindowController`.
    static weak var usbSubmenu: NSMenu?

    /// View ▸ Zoom — how many host physical pixels each guest pixel occupies.
    ///
    /// Per-window, like the Connection menu: `nil` targets, so the items travel the
    /// responder chain to the front `SpiceWindowController`.
    ///
    /// Shortcuts use ⌃⌘ (matching ⌃⌘F and ⌃⌥R) rather than plain ⌘, so ⌘+ / ⌘- / ⌘0
    /// keep reaching the guest as Super-plus / Super-minus / Super-zero — AppKit
    /// offers key-downs to the main menu before the responder chain.
    private static func zoomMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Zoom")
        item.submenu = menu

        // "+" is a SHIFTED character on most layouts, so such an item only matches
        // while Shift is down. Ship the pretty ⌃⌘+ item for display plus a hidden
        // twin on "=" (allowsKeyEquivalentWhenHidden keeps its shortcut live).
        let zoomIn = NSMenuItem(title: "Zoom In",
                                action: #selector(SpiceWindowController.zoomIn(_:)), keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(zoomIn)
        let zoomInUnshifted = NSMenuItem(title: "Zoom In",
                                         action: #selector(SpiceWindowController.zoomIn(_:)), keyEquivalent: "=")
        zoomInUnshifted.keyEquivalentModifierMask = [.control, .command]
        zoomInUnshifted.isHidden = true
        zoomInUnshifted.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInUnshifted)

        // "-" and "0" are unshifted on every layout we care about: one item each.
        let zoomOut = NSMenuItem(title: "Zoom Out",
                                 action: #selector(SpiceWindowController.zoomOut(_:)), keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(zoomOut)
        menu.addItem(.separator())

        let automatic = NSMenuItem(title: DisplayZoom.automatic.title,
                                   action: #selector(SpiceWindowController.setDisplayZoom(_:)), keyEquivalent: "0")
        automatic.keyEquivalentModifierMask = [.control, .command]
        automatic.tag = DisplayZoom.automatic.rawValue
        automatic.toolTip = "Match the guest resolution to the window's point size — 2× on a "
            + "Retina display, 1× on a normal-DPI monitor — following whichever screen the "
            + "window is on."
        menu.addItem(automatic)
        menu.addItem(.separator())

        for level in DisplayZoom.ladder {
            let levelItem = NSMenuItem(title: level.title,
                                       action: #selector(SpiceWindowController.setDisplayZoom(_:)), keyEquivalent: "")
            levelItem.tag = level.rawValue
            menu.addItem(levelItem)
        }
        return item
    }
}
