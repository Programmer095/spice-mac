// SPDX-License-Identifier: MIT
import AppKit
import VVConfig
import SpiceController
import PVEClient

/// App entry: builds the menu and opens Proxmox SPICE sessions — either by signing
/// in to a node and picking a guest (File ▸ Connect to Proxmox…), or from a `.vv`
/// file (double-click, File ▸ Open, drag-and-drop) — spawning a window per session.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var windowControllers: [SpiceWindowController] = []
    private var didOpenAny = false
    /// The connect window's frame before consoles grew it. Consoles size the shared
    /// frame to their guest, so without this the picker would be left at console size
    /// after the last one closes.
    private var browserFrameBeforeConsoles: NSRect?

    /// Security-scoped URLs held open for the app's lifetime; released on quit.
    private var securityScopedShares: Set<URL> = []

    /// Created on first use, but never *forced* into existence — building it reads the
    /// Keychain, which must not happen just because someone opened a `.vv` file.
    private var createdBrowser: PVEConnectWindowController?

    private var proxmoxBrowser: PVEConnectWindowController {
        if let createdBrowser { return createdBrowser }
        let controller = PVEConnectWindowController()
        controller.onOpenConsole = { [weak self] guest, client in
            self?.openProxmoxConsole(guest: guest, client: client)
        }
        controller.onOpenVVFile = { [weak self] in
            self?.presentOpenPanelFromBrowser()
        }
        createdBrowser = controller
        return controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSApp.activate(ignoringOtherApps: true)

        // Allow opening a .vv passed on the command line (scripting / testing).
        for arg in CommandLine.arguments.dropFirst() where arg.hasSuffix(".vv") {
            openVV(at: URL(fileURLWithPath: arg))
        }

        // Launched without a document: open the Proxmox browser. With a saved server it
        // signs in and lists guests; without one it is the sign-in form, which is the
        // right first thing to show. A `.vv` is now the fallback route, reachable from
        // File ▸ Open, the button in the browser, or dropping a file on the app.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didOpenAny else { return }
            self.proxmoxBrowser.present()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Clicking the Dock icon with every window closed should bring the app back to
    /// something useful rather than nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { proxmoxBrowser.present() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for url in securityScopedShares { url.stopAccessingSecurityScopedResource() }
        securityScopedShares.removeAll()
    }

    // Modern multi-URL open (double-click / drag onto the app / `open file.vv`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openVV(at: url) }
    }

    // MARK: - Opening

    @objc func openDocument(_ sender: Any?) {
        presentOpenPanel()
    }

    // MARK: - Files and folder sharing

    /// Once the last console goes, the picker is alone in a console-sized window.
    /// Put it back to the size it had before, so opening another console repeats the
    /// small-window-grows-to-fit cycle rather than starting oversized.
    private func consolesInTabGroup(of window: NSWindow) -> [SpiceWindowController] {
        (window.tabGroup?.windows ?? [window])
            .compactMap { $0.windowController as? SpiceWindowController }
    }

    private func restoreBrowserFrameIfLastConsoleClosed() {
        guard let frame = browserFrameBeforeConsoles,
              let browser = createdBrowser?.window else { return }
        // Deferred because at windowWillClose the closing tab is still in the group —
        // and because only the group matters: a console torn out to its own window has
        // no bearing on what size the picker's window should be.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.consolesInTabGroup(of: browser).isEmpty else { return }
            self.browserFrameBeforeConsoles = nil
            // setFrame does not clamp to minSize the way a user resize does, so a bad
            // captured frame could otherwise restore the window to a sliver.
            var target = frame
            target.size.width = max(target.size.width, browser.minSize.width)
            target.size.height = max(target.size.height, browser.minSize.height)
            browser.setFrame(target, display: true, animate: false)
        }
    }

    /// A window already on screen to hang new tabs from, preferring one that is
    /// already a tab group so new consoles land where the others are.
    private func tabGroupAnchor() -> NSWindow? {
        let candidates = ([createdBrowser?.window] + windowControllers.map(\.window))
            .compactMap { $0 }
            .filter { $0.isVisible }
        return candidates.first { ($0.tabGroup?.windows.count ?? 0) > 1 } ?? candidates.first
    }

    /// The session the user is looking at, which is what file commands act on.
    private var activeSessionController: SpiceWindowController? {
        windowControllers.first { $0.window?.isKeyWindow == true } ?? windowControllers.last
    }

    private static func fileURLsOnPasteboard() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                options: options) as? [URL] ?? []
    }

    @objc func sendFilesToGuest(_ sender: Any?) {
        guard let controller = activeSessionController else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        panel.message = "Choose files to copy into the guest"
        guard panel.runModal() == .OK else { return }
        controller.sendFiles(panel.urls)
    }

    @objc func sendClipboardFilesToGuest(_ sender: Any?) {
        guard let controller = activeSessionController else { return }
        controller.sendFiles(Self.fileURLsOnPasteboard())
    }

    @objc func chooseSharedFolder(_ sender: Any?) {
        guard SharedFolder.choose(relativeTo: NSApp.keyWindow) != nil else { return }
        notifySharedFolderChanged()
    }

    @objc func clearSharedFolder(_ sender: Any?) {
        SharedFolder.store(nil)
        notifySharedFolderChanged()
    }

    @objc func toggleSharedFolderReadOnly(_ sender: NSMenuItem) {
        SharedFolder.isReadOnly.toggle()
        sender.state = SharedFolder.isReadOnly ? .on : .off
        notifySharedFolderChanged()
    }

    /// The WebDAV channel is negotiated during session setup, so a change only takes
    /// effect on the next connection — say so rather than let it look broken.
    private func notifySharedFolderChanged() {
        guard windowControllers.isEmpty == false else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "The shared folder changes on the next connection"
        alert.informativeText = "Open sessions keep the folder they started with. Reconnect to apply the change."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func connectToProxmox(_ sender: Any?) {
        didOpenAny = true
        proxmoxBrowser.present()
    }

    /// Reached from the browser's own button, so the `.vv` route stays discoverable
    /// now that it is no longer what the app opens with.
    fileprivate func presentOpenPanelFromBrowser() {
        presentOpenPanel()
    }

    // MARK: - Proxmox sessions

    /// Mint a fresh ticket for `guest` and open a session window for it. The client is
    /// retained by the window's reconnect hook, so a dropped session can come back
    /// without another trip through the browser.
    private func openProxmoxConsole(guest: PVEGuest, client: PVEClient) {
        didOpenAny = true
        let source = PVESessionSource(guest: guest, client: client)
        Task { @MainActor [weak self] in
            do {
                let text = try await source.freshConfigText()
                let config = try VVConfig.parse(text)
                try self?.startSession(config: config, origin: .proxmox(source))
            } catch {
                self?.presentError(error, title: "Could not open the console for \(source.displayName)")
            }
        }
    }

    /// Replace a window's session with a freshly ticketed one. The SPICE ticket is
    /// single-use, so a reconnect is a new connection: open the replacement first, then
    /// close the old window, so the user never stares at an empty screen.
    private func reconnect(_ old: SpiceWindowController, source: PVESessionSource) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await source.freshConfigText()
                let config = try VVConfig.parse(text)
                let frame = old.window?.frame
                let fresh = try self.startSession(config: config, origin: .proxmox(source))
                if let frame { fresh.window?.setFrame(frame, display: true) }
                old.close()
            } catch {
                self.presentError(error, title: "Could not reconnect to \(source.displayName)")
            }
        }
    }

    // MARK: - Preferences

    @objc func toggleHideMacCursor(_ sender: NSMenuItem) {
        Preferences.hideHostCursor.toggle()
        sender.state = Preferences.hideHostCursor ? .on : .off
    }

    @objc func toggleShareClipboard(_ sender: NSMenuItem) {
        Preferences.shareClipboard.toggle()
        sender.state = Preferences.shareClipboard ? .on : .off
    }

    @objc func toggleTrashConnectionFile(_ sender: NSMenuItem) {
        Preferences.trashConnectionFileAfterUse.toggle()
        sender.state = Preferences.trashConnectionFileAfterUse ? .on : .off
    }

    // View ▸ Zoom is per-window and lives on SpiceWindowController, reached down the
    // responder chain — see the Zoom menu section there.

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHideMacCursor(_:)):
            menuItem.state = Preferences.hideHostCursor ? .on : .off
        case #selector(toggleShareClipboard(_:)):
            menuItem.state = Preferences.shareClipboard ? .on : .off
        case #selector(toggleTrashConnectionFile(_:)):
            menuItem.state = Preferences.trashConnectionFileAfterUse ? .on : .off
        case #selector(toggleSharedFolderReadOnly(_:)):
            menuItem.state = SharedFolder.isReadOnly ? .on : .off
            return SharedFolder.url != nil
        case #selector(clearSharedFolder(_:)):
            return SharedFolder.url != nil
        case #selector(chooseSharedFolder(_:)):
            menuItem.title = SharedFolder.url.map { "Shared Folder: \($0.lastPathComponent)…" } ?? "Choose Shared Folder…"
        case #selector(sendFilesToGuest(_:)):
            return activeSessionController?.canSendFiles ?? false
        case #selector(sendClipboardFilesToGuest(_:)):
            let files = Self.fileURLsOnPasteboard()
            menuItem.title = files.count == 1
                ? "Send “\(files[0].lastPathComponent)” from Clipboard"
                : "Send \(files.count) Files from Clipboard"
            return files.isEmpty == false && (activeSessionController?.canSendFiles ?? false)
        default:
            break
        }
        return true
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let types = VVDocument.contentTypes
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = "Open"
        panel.message = "Open a Proxmox SPICE connection file (.vv)"
        if panel.runModal() == .OK, let url = panel.url {
            openVV(at: url)
        }
    }

    private func openVV(at url: URL) {
        didOpenAny = true
        do {
            let config = try VVConfig(contentsOf: url)
            try startSession(config: config, origin: .file(url))
            // The .vv has been read into the session parameters; its SPICE ticket is
            // single-use and it carries the cluster CA, so move it to the Trash once
            // we've used it to connect. The file content is already in memory, so this
            // can't affect the live connection. Only reached on a successful parse.
            if Preferences.trashConnectionFileAfterUse {
                trashConnectionFile(at: url)
            }
        } catch {
            presentError(error, title: "Could not open “\(url.lastPathComponent)”")
        }
    }

    /// Build the client, window and wiring for one session. Shared by both routes so a
    /// Proxmox session behaves identically to an opened `.vv` in every other respect.
    @discardableResult
    private func startSession(config: VVConfig, origin: SpiceSessionOrigin) throws -> SpiceWindowController {
        let params = try SpiceConnectionParameters(from: config)
        let client = SpiceClient(parameters: params)
        client.shareClipboard = Preferences.shareClipboard
        if let share = SharedFolder.currentPath() {
            client.sharedDirectory = (share.path, share.readOnly)
            if let accessed = share.accessed { securityScopedShares.insert(accessed) }
        }
        let controller = SpiceWindowController(client: client, origin: origin)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            self.windowControllers.removeAll { $0 === controller }
            self.restoreBrowserFrameIfLastConsoleClosed()
        }
        if case .proxmox(let source) = origin {
            controller.onReconnect = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.reconnect(controller, source: source)
            }
        }
        windowControllers.append(controller)
        // Join the existing group explicitly. `.preferred` alone leaves the grouping to
        // AppKit's heuristics, which do not reliably catch a window shown this way.
        if let existing = tabGroupAnchor(), let fresh = controller.window, existing !== fresh {
            if let browser = createdBrowser?.window, browser.isVisible,
               consolesInTabGroup(of: browser).isEmpty {
                browserFrameBeforeConsoles = browser.frame
            }
            existing.addTabbedWindow(fresh, ordered: .above)
        }
        controller.showWindow(nil)
        client.connect()
        return controller
    }

    /// Move a used `.vv` to the Trash (best-effort). Trash, not a hard delete, so it's
    /// recoverable; failures (e.g. a read-only volume) are logged, never fatal.
    private func trashConnectionFile(at url: URL) {
        guard url.isFileURL else { return }
        // When launched as root (scripts/run-as-root.sh, for USB capture), recycle
        // would move the file into ROOT's Trash (/var/root/.Trash), not the user's —
        // surprising and unhelpful. The single-use ticket is already spent, so just
        // leave the file where the user put it; they can remove it themselves.
        if getuid() == 0 { return }
        NSWorkspace.shared.recycle([url]) { _, error in
            if let error {
                NSLog("SpiceMac: could not move \(url.lastPathComponent) to Trash: \(error.localizedDescription)")
            }
        }
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        // PVEError phrases the actionable cases (bad token, unreachable host, rejected
        // certificate); anything else falls back to the raw description.
        alert.informativeText = (error as? PVEError)?.description ?? String(describing: error)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
