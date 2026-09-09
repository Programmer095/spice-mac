// SPDX-License-Identifier: MIT
import AppKit
import Combine
import OSLog
import CocoaSpice
import SpiceController
import DisplayScale
import PVEClient

/// Owns one SPICE session window: hosts the `SpiceDisplayView`, reflects
/// connection state, resizes to the guest, and exposes the Connection/USB menu
/// actions via the responder chain.
final class SpiceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    private let client: SpiceClient
    private let origin: SpiceSessionOrigin
    private let displayView = SpiceDisplayView()
    private let containerView = NSView()
    private let overlay = PVEGuestOverlay(session: .shared)
    private let overlayEdgeTrigger = PVEOverlayEdgeTrigger()
    /// Only for a Proxmox session — a `.vv` file has no API behind it to act through.
    private var actionBar: PVEActionBar?

    /// Picked a guest in the overlay. `AppDelegate` opens it as another tab.
    var onOpenGuest: ((PVEGuest, PVEClient) -> Void)?
    private let statusLabel = NSTextField(labelWithString: "Connecting…")
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private var cancellables = Set<AnyCancellable>()

    /// Called when the window closes so the app can drop its reference.
    var onClose: (() -> Void)?

    /// Set for sessions that can mint a fresh ticket (Proxmox ones). A `.vv` opened
    /// from disk cannot: its ticket was spent on the first connect, so there is
    /// nothing to retry with and no button is offered.
    var onReconnect: (() -> Void)?

    /// The last guest size we asked for. Suppresses a redundant monitor-config,
    /// which costs a real mode switch; cleared when the display/agent state
    /// restarts.
    private var lastRequestedGuestSize: CGSize?

    /// Coalesces resolution requests: one drag across a screen boundary fires
    /// several.
    private var pendingResolutionRequest: DispatchWorkItem?

    /// Block-based NotificationCenter observers, removed on close.
    private var notificationObservers: [NSObjectProtocol] = []

    /// Backing scale of the screen this window was last seen on. Seeded at creation
    /// so a window that merely OPENS on a Retina screen is not mistaken for one
    /// that MOVED onto it, which would resize a window the user had deliberately
    /// sized.
    private var lastKnownBackingScale: CGFloat = 0

    /// The zoom THIS window is at. Per-window because each window is its own
    /// session on its own display: a level picked in one has no business
    /// reconfiguring another's guest. Seeded from `Preferences.displayZoom` (the
    /// last level picked anywhere) and changed only by the menu commands below.
    private var displayZoom: DisplayZoom = Preferences.displayZoom

    convenience init(client: SpiceClient, sourceURL: URL) {
        self.init(client: client, origin: .file(sourceURL))
    }

    /// All SpiceMac windows share one tab group, so consoles and the connect window
    /// live together and can be torn out individually.
    static let tabbingIdentifier = NSWindow.TabbingIdentifier("org.spicemac.session")


    init(client: SpiceClient, origin: SpiceSessionOrigin) {
        self.client = client
        self.origin = origin
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .preferred
        window.acceptsMouseMovedEvents = true
        window.title = baseTitle
        window.center()
        lastKnownBackingScale = window.backingScaleFactor
        setupViews()
        wireClient()
        wireNotifications()
    }

    deinit {
        pendingResolutionRequest?.cancel()
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var baseTitle: String {
        client.title ?? origin.displayName
    }

    // MARK: - Views

    private func setupViews() {
        guard let window else { return }
        containerView.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        displayView.autoresizingMask = [.width, .height]
        displayView.frame = containerView.bounds
        containerView.addSubview(displayView)
        // One of the signals for "this window is on a different display"; they all
        // funnel into screenChanged(), which is idempotent about the duplicates.
        displayView.onBackingScaleChange = { [weak self] _ in
            self?.screenChanged()
        }

        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, multiplier: 0.8),
        ])

        // Only offer the drop cursor when the session can actually take files.
        displayView.onFilesDropped = { [weak self] urls in self?.sendFiles(urls) }

        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectTapped)
        reconnectButton.bezelStyle = .rounded
        reconnectButton.keyEquivalent = "\r"
        reconnectButton.isHidden = true
        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(reconnectButton)
        NSLayoutConstraint.activate([
            reconnectButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            reconnectButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
        ])

        setupGuestOverlay()
        setupActionBar()

        window.contentView = containerView
        window.initialFirstResponder = displayView
    }

    // MARK: - Guest overlay

    /// The picker rides above the display, off the left edge until asked for. Autoresizing
    /// rather than Auto Layout to match `displayView`: the container is resized directly on
    /// every guest-resolution change, and mixing the two here would fight that path.
    private func setupGuestOverlay() {
        overlay.frame = NSRect(x: -PVEGuestOverlay.width, y: 0,
                               width: PVEGuestOverlay.width, height: containerView.bounds.height)
        overlay.autoresizingMask = [.height]
        overlay.isHidden = true
        overlay.onOpenGuest = { [weak self] guest, client in
            self?.setGuestOverlayRevealed(false)
            self?.onOpenGuest?(guest, client)
        }
        containerView.addSubview(overlay, positioned: .above, relativeTo: displayView)

        // A hairline strip, not a broad hover region: this sits over a live guest, and a
        // generous target would fire constantly while working inside the VM. The menu
        // command is the route that carries the load.
        overlayEdgeTrigger.frame = NSRect(x: 0, y: 0, width: 4, height: containerView.bounds.height)
        overlayEdgeTrigger.autoresizingMask = [.height]
        overlayEdgeTrigger.onEnter = { [weak self] in self?.setGuestOverlayRevealed(true) }
        containerView.addSubview(overlayEdgeTrigger, positioned: .above, relativeTo: displayView)
    }

    // MARK: - Action bar

    /// Top-centre, above the display, hidden until asked for. A `.vv` session gets no
    /// bar at all: there is no authenticated client behind it to power or eject with,
    /// and a row of controls that cannot work is worse than no row.
    private func setupActionBar() {
        guard case .proxmox(let source) = origin else { return }
        let bar = PVEActionBar(guest: source.guest, client: source.client)
        bar.onPowerAction = { [weak self] action in self?.runPowerAction(action, source: source) }
        bar.onSetISO = { [weak self] volumeID in self?.setISO(volumeID, source: source) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        containerView.addSubview(bar, positioned: .above, relativeTo: displayView)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            bar.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            bar.heightAnchor.constraint(equalToConstant: PVEActionBar.height),
        ])
        actionBar = bar
        bar.begin()
    }

    var isActionBarRevealed: Bool { actionBar.map { $0.isHidden == false } ?? false }

    func toggleActionBar() {
        guard let actionBar else { return }
        actionBar.isHidden = isActionBarRevealed
    }

    private func runPowerAction(_ action: PVEPowerAction, source: PVESessionSource) {
        if let detail = action.confirmationDetail {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(action.title) “\(source.guest.name)”?"
            alert.informativeText = detail
            alert.addButton(withTitle: action.title)
            alert.addButton(withTitle: "Cancel")
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.performPower(action, source: source)
            }
            return
        }
        performPower(action, source: source)
    }

    private func performPower(_ action: PVEPowerAction, source: PVESessionSource) {
        Task { [weak self] in
            do {
                let upid = try await source.client.performPower(action, on: source.guest)
                try await source.client.awaitTask(node: source.guest.node, upid: upid)
            } catch {
                self?.presentTransientError(error.localizedDescription)
            }
        }
    }

    private func setISO(_ volumeID: String?, source: PVESessionSource) {
        Task { [weak self] in
            do {
                let upid: String
                if let volumeID {
                    upid = try await source.client.attachISO(volumeID, to: source.guest)
                } else {
                    upid = try await source.client.detachISO(from: source.guest)
                }
                // A synchronous config write returns no UPID; there is nothing to follow.
                if upid.isEmpty == false {
                    try await source.client.awaitTask(node: source.guest.node, upid: upid)
                }
            } catch {
                self?.presentTransientError(error.localizedDescription)
            }
        }
    }

    var isGuestOverlayRevealed: Bool { overlay.isHidden == false }

    func toggleGuestOverlay() { setGuestOverlayRevealed(!isGuestOverlayRevealed) }

    func setGuestOverlayRevealed(_ revealed: Bool, animated: Bool = true) {
        guard revealed != isGuestOverlayRevealed else { return }
        let height = containerView.bounds.height
        let shown = NSRect(x: 0, y: 0, width: PVEGuestOverlay.width, height: height)
        let hidden = NSRect(x: -PVEGuestOverlay.width, y: 0, width: PVEGuestOverlay.width, height: height)

        if revealed {
            overlay.frame = hidden
            overlay.isHidden = false
            overlay.prepareForReveal()
        }
        let target = revealed ? shown : hidden
        guard animated else {
            overlay.frame = target
            overlay.isHidden = !revealed
            if !revealed { window?.makeFirstResponder(displayView) }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            overlay.animator().frame = target
        } completionHandler: { [weak self] in
            guard let self else { return }
            if revealed == false {
                self.overlay.isHidden = true
                // Hand the keyboard back to the guest, or the next keystroke lands in a
                // panel that is no longer on screen.
                self.window?.makeFirstResponder(self.displayView)
            }
        }
    }

    @objc private func reconnectTapped() {
        reconnectButton.isHidden = true
        showStatus("Reconnecting…")
        onReconnect?()
    }

    // MARK: - Client wiring

    private func wireClient() {
        client.onDisplayCreated = { [weak self] display in self?.attachDisplay(display) }
        // NB: do NOT resize the window when the guest resolution changes. The view
        // re-fits the viewport via its displaySize KVO, so the window stays the
        // user's size. Resizing here would chase the guest size and, combined with
        // requestResolution, oscillate (the guest reconfigures → window resizes →
        // we request a new resolution → …).
        client.onDisplayDestroyed = { [weak self] _ in self?.displayView.detach() }
        client.onInputAvailable = { [weak self] input in
            guard let self else { return }
            self.displayView.router.input = input
            self.displayView.router.requestMouseMode(server: false)
            self.window?.makeFirstResponder(self.displayView)
        }
        client.onInputUnavailable = { [weak self] _ in self?.displayView.router.input = nil }

        client.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update(for: $0) }
            .store(in: &cancellables)

        client.$agentConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                // A fresh agent means a fresh guest display stack, so forget what we
                // asked the previous one for.
                self.lastRequestedGuestSize = nil
                if connected { self.scheduleResolutionRequest(after: 0.15) }
            }
            .store(in: &cancellables)
    }

    private func wireNotifications() {
        let center = NotificationCenter.default
        // Hotplug/removal, sleep/wake, and Displays "scaled resolution" changes,
        // which resize the window WITHOUT a live resize. Longer delay: AppKit keeps
        // shuffling windows for a while after these.
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.screenChanged(after: 0.6)
        })
    }

    private func attachDisplay(_ display: CSDisplay) {
        displayView.attachDisplay(display)
        lastRequestedGuestSize = nil   // a re-attach means a fresh guest surface
        resizeToDisplay(display.displaySize, recenter: true)
        // The agent-connected and display-created edges race, and whichever loses
        // has to be the one that asks. Safe against the oscillation rule:
        // spiceDisplayCreated is a one-shot per display channel (later configs fire
        // spiceDisplayUpdated).
        scheduleResolutionRequest(after: 0.15)
        statusLabel.isHidden = true
        window?.makeFirstResponder(displayView)
        if client.prefersFullscreen, window?.styleMask.contains(.fullScreen) == false {
            window?.toggleFullScreen(nil)
        }
    }

    private func update(for status: SpiceClient.Status) {
        switch status {
        case .idle:
            displayView.isHidden = false
            statusLabel.stringValue = ""
        case .connecting:
            displayView.isHidden = false
            showStatus("Connecting…")
        case .connected:
            displayView.isHidden = false
            statusLabel.isHidden = true
            reconnectButton.isHidden = true
            client.usbManager?.delegate = self
            refreshUSBMenu()
        case .disconnected:
            // The SPICE ticket is single-use. A Proxmox session can ask the API for a
            // fresh one (see onReconnect); a `.vv` from disk has nothing left to retry
            // with, so that case still points at opening a new file.
            // Hide the (now static) display: detach() leaves the last guest frame
            // frozen on the opaque MTKView, so without this the stale screen stays
            // up and the message below is lost behind it. Hiding reveals the window
            // background so the centered message is readable.
            displayView.isHidden = true
            if canReconnect {
                showStatus("Disconnected.")
                reconnectButton.isHidden = false
            } else {
                showStatus("Disconnected.\nOpen a fresh .vv file to reconnect.")
            }
        case .failed(let message):
            displayView.isHidden = true
            showStatus("Connection failed.\n\(message)")
            reconnectButton.isHidden = !canReconnect
        }
        window?.title = title(for: status)
    }

    private func title(for status: SpiceClient.Status) -> String {
        switch status {
        case .connecting:   return "\(baseTitle) — Connecting…"
        case .disconnected: return "\(baseTitle) — Disconnected"
        case .failed:       return "\(baseTitle) — Failed"
        case .connected, .idle: return baseTitle
        }
    }

    // MARK: - Sending files to the guest

    private var transferSheet: NSAlert?
    private var transferProgress: NSProgressIndicator?

    var canSendFiles: Bool { client.canSendFiles }

    func sendFiles(_ urls: [URL]) {
        guard urls.isEmpty == false else { return }
        guard client.canSendFiles else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "This guest cannot receive files"
            alert.informativeText = """
                File transfer needs the SPICE guest agent. Install and start \
                spice-vdagent in the guest, then reconnect.
                """
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }

        let noun = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Sending \(noun) to the guest…"
        alert.informativeText = "The guest agent decides where they land — usually the desktop or downloads folder."
        alert.addButton(withTitle: "Cancel")

        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        alert.accessoryView = bar
        transferSheet = alert
        transferProgress = bar

        if let window {
            alert.beginSheetModal(for: window) { [weak self] _ in
                // The only button is Cancel, so any dismissal we did not initiate is one.
                if self?.transferSheet != nil { self?.client.cancelFileTransfers() }
            }
        }

        client.sendFiles(urls, progress: { [weak self] fraction in
            self?.transferProgress?.doubleValue = fraction
        }, completion: { [weak self] error in
            guard let self else { return }
            self.dismissTransferSheet()
            if let error {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "Could not send \(noun)"
                failure.informativeText = error.localizedDescription
                failure.addButton(withTitle: "OK")
                if let window = self.window { failure.beginSheetModal(for: window) } else { failure.runModal() }
            }
        })
    }

    private func dismissTransferSheet() {
        guard let sheet = transferSheet, let window else { transferSheet = nil; return }
        transferSheet = nil
        transferProgress = nil
        window.endSheet(sheet.window)
    }

    private var canReconnect: Bool { onReconnect != nil }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }

    // MARK: - Sizing

    /// Backing scale of the screen this window is currently on.
    private var currentBackingScale: CGFloat {
        window?.backingScaleFactor ?? displayView.backingScale
    }

    /// Size the window so `size` guest pixels occupy `guest × zoom / backingScale`
    /// points, clamped to what the screen can show. `recenter` only on attach; a
    /// later zoom change keeps the window's top-left where the user put it.
    /// Consoles sharing this window's frame, including this one.
    ///
    /// Counts consoles only: the connect window is chrome, and letting it count would
    /// pin the first console to the picker's small frame instead of sizing to the guest.
    private var consolesInGroup: [SpiceWindowController] {
        guard let group = window?.tabGroup else { return [self] }
        return group.windows.compactMap { $0.windowController as? SpiceWindowController }
    }

    /// True only when a second console shares the frame — at which point no single
    /// guest can own the size and the frame has to lead instead.
    private var isFrameShared: Bool { consolesInGroup.count > 1 }

    private func resizeToDisplay(_ size: CGSize, recenter: Bool) {
        guard size.width > 1, size.height > 1, let window,
              window.styleMask.contains(.fullScreen) == false else { return }
        // Resizing one tab resizes every tab, so a guest may only drive the frame
        // while it is the sole console in the group.
        guard isFrameShared == false else { return }
        // Clamp against the CONTENT rect the visible frame allows, not the frame
        // itself — the title bar takes ~28 pt off the top.
        let allowed = (window.screen ?? NSScreen.main)
            .map { window.contentRect(forFrameRect: $0.visibleFrame).size }
        let target = DisplayScale.windowContentPoints(guest: size,
                                                      zoom: displayZoom,
                                                      backingScale: window.backingScaleFactor,
                                                      maximum: allowed)
        if recenter {
            window.setContentSize(target)
            window.center()
        } else {
            // setContentSize keeps the frame's bottom-left; users expect the
            // top-left to stay put. Constrain afterwards so the title bar stays
            // reachable.
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(target)
            window.setFrameTopLeftPoint(topLeft)
            window.setFrame(window.constrainFrameRect(window.frame, to: window.screen),
                            display: true)
        }
    }

    /// Ask the guest for `windowPoints × backingScale / zoom` — exactly `zoom` host
    /// pixels per guest pixel once it reconfigures. `SpiceDisplayView`'s aspect-fit
    /// then derives the same factor, so the renderer and the input router follow
    /// for free.
    private func requestResolutionForCurrentSize() {
        requestResolution(forViewPoints: displayView.bounds.size)
    }

    /// Ask this window's guest to match `points`. Split out from the size lookup so a
    /// tab group can hand every member the shared frame's size — a background tab's
    /// own view bounds are not a reliable source for that.
    fileprivate func requestResolution(forViewPoints points: CGSize) {
        guard client.supportsDynamicResolution,
              let display = displayView.attachedDisplay else { return }
        let target = DisplayScale.targetGuestSize(viewPoints: points,
                                                  backingScale: currentBackingScale,
                                                  zoom: displayZoom)
        guard DisplayScale.needsRequest(target: target,
                                        current: display.displaySize,
                                        lastRequested: lastRequestedGuestSize) else { return }
        lastRequestedGuestSize = target
        display.requestResolution(CGRect(origin: .zero, size: target))
    }

    /// Coalesced entry point for a resolution request.
    ///
    /// NB: every caller is a HOST-side geometry event or the one-shot agent edge.
    /// Nothing guest-side may call it — a guest resolution change must only re-fit
    /// the viewport, or the resize↔request oscillation this app already fixed comes
    /// back.
    /// Every guest sharing this frame is asked to match it. Members already at the
    /// right size are filtered out by `needsRequest`, so this is a no-op once the
    /// group has settled — which is what makes switching tabs free.
    private func propagateResolutionToTabGroup() {
        guard let window, isFrameShared else {
            requestResolutionForCurrentSize()
            return
        }
        let shared = window.contentRect(forFrameRect: window.frame).size
        for console in consolesInGroup {
            console.requestResolution(forViewPoints: shared)
        }
    }

    private func scheduleResolutionRequest(after delay: TimeInterval = 0.3) {
        pendingResolutionRequest?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingResolutionRequest = nil
            // Never fire mid-drag; windowDidEndLiveResize will reschedule us.
            guard self.window?.inLiveResize != true else { return }
            self.propagateResolutionToTabGroup()
        }
        pendingResolutionRequest = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The user picked a new zoom.
    ///
    /// With a guest agent the window is the user's chosen viewport and must NOT
    /// change: only the guest's pixel density does, so we re-request. Without one
    /// the guest resolution is fixed, so the only way to honour the zoom is the
    /// other side of the equation — resize the window to `guest × zoom /
    /// backingScale` points. That cannot reopen the oscillation: a programmatic
    /// setContentSize is not a live resize.
    private func applyZoomChange() {
        if client.supportsDynamicResolution {
            scheduleResolutionRequest(after: 0.05)   // discrete user action: near-immediate
        } else if let size = displayView.attachedDisplay?.displaySize {
            resizeToDisplay(size, recenter: false)
        }
        // Disconnected: nothing to do; the level applies once a display attaches.
    }

    /// The window may now be on a different display, so re-apply the geometry: at a
    /// fixed level the target is `points × backingScale / Z` and the move just
    /// changed the backing scale. The zoom LEVEL is never touched — a level the
    /// user picked is a decision. Every request goes through
    /// `DisplayScale.needsRequest` and is coalesced, so the several events one drag
    /// produces cost at most one guest mode switch.
    private func screenChanged(after delay: TimeInterval = 0.3) {
        let scale = currentBackingScale
        let moved = lastKnownBackingScale > 0 && abs(scale - lastKnownBackingScale) > 0.001
        lastKnownBackingScale = scale

        if client.supportsDynamicResolution {
            // Run on every screen event, not just a scale change: two 1x monitors
            // differ in the clamp a later resize applies.
            scheduleResolutionRequest(after: delay)
        } else if moved, let size = displayView.attachedDisplay?.displaySize {
            // No agent: the guest resolution is fixed, so honour the zoom on the
            // other side of the equation. Gated on a REAL scale change, so a move
            // between two same-scale monitors cannot snap back a window the user
            // resized.
            resizeToDisplay(size, recenter: false)
        }
    }

    // Request a matching guest resolution only at DISCRETE moments — never on the
    // continuous windowDidResize, which (during a live drag, or when a programmatic
    // resize fires it) creates the resize↔request oscillation.
    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleResolutionRequest()
    }

    // The three ways AppKit reports a display change, all funnelled into the same
    // idempotent handler because one drag does not reliably produce all three.
    // windowDidChangeScreen is kept because it is the only one that also fires for a
    // move between two SAME-scale monitors.
    func windowDidChangeScreen(_ notification: Notification) {
        screenChanged()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        screenChanged()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        scheduleResolutionRequest()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        scheduleResolutionRequest()
    }

    // MARK: - Window lifecycle

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(displayView)
        client.usbManager?.delegate = self
        refreshUSBMenu()
        // Self-healing: a console that just joined the group adopts the shared frame's
        // resolution here. Settled members are filtered out, so switching tabs between
        // guests that already match costs nothing.
        if isFrameShared { scheduleResolutionRequest(after: 0.15) }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Release any held input so it does not stay latched in the guest when the
        // user switches away, and restore the macOS cursor — the window is no longer
        // key, so updateHostCursorVisibility() shows it (covers same-app window
        // switches / miniaturize that don't deactivate the app).
        displayView.router.releaseAll()
        displayView.updateHostCursorVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        pendingResolutionRequest?.cancel()
        pendingResolutionRequest = nil
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers.removeAll()
        displayView.router.releaseAll()
        client.disconnect()
        displayView.detach()
        onClose?()
    }

    // MARK: - Connection actions (responder chain targets)

    @objc func sendCtrlAltDel(_ sender: Any?) {
        guard let input = displayView.router.input else { return }
        // Left Ctrl (0x1D) + Left Alt (0x38) + Delete (extended 0xE053 → 0x153).
        let combo: [Int32] = [0x1D, 0x38, 0x153]
        for code in combo { input.send(.press, code: code) }
        for code in combo.reversed() { input.send(.release, code: code) }
    }

    @objc func releaseCursor(_ sender: Any?) {
        displayView.router.releaseAll()
    }

    // MARK: - Zoom menu (responder chain targets)
    //
    // Per-window, so these live here rather than on the app delegate. With no session
    // open nothing answers the selector and AppKit greys the submenu out.

    @objc func setDisplayZoom(_ sender: NSMenuItem) {
        guard let level = DisplayZoom(rawValue: sender.tag) else { return }
        apply(zoom: level)
    }

    @objc func zoomIn(_ sender: Any?) { apply(zoom: steppedZoom(by: 1)) }
    @objc func zoomOut(_ sender: Any?) { apply(zoom: steppedZoom(by: -1)) }

    /// The next rung for this window, resolved against its own screen — which is
    /// what turns `.automatic` into a percentage to step away from.
    private func steppedZoom(by direction: Int) -> DisplayZoom {
        DisplayScale.step(displayZoom, by: direction, backingScale: currentBackingScale)
    }

    private func apply(zoom: DisplayZoom) {
        displayZoom = zoom
        // Purely the seed for the next window; it does not reach any already open.
        Preferences.displayZoom = zoom
        applyZoomChange()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(sendCtrlAltDel(_:)), #selector(releaseCursor(_:)):
            return displayView.router.input != nil
        case #selector(setDisplayZoom(_:)):
            // Radio-style: exactly one level checked, recomputed on every menu open
            // so it tracks this window, including after ⌃⌘+ / ⌃⌘-.
            menuItem.state = (menuItem.tag == displayZoom.rawValue) ? .on : .off
            if menuItem.tag == DisplayZoom.automatic.rawValue {
                // Show what Automatic currently resolves to on this window's screen.
                let percent = Int((currentBackingScale * 100).rounded())
                menuItem.title = "\(DisplayZoom.automatic.title) (\(percent)%)"
            }
        case #selector(zoomIn(_:)):
            return steppedZoom(by: 1) != displayZoom
        case #selector(zoomOut(_:)):
            return steppedZoom(by: -1) != displayZoom
        default:
            break
        }
        return true
    }

    // MARK: - USB menu

    @objc func toggleUSBDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? CSUSBDevice,
              let usb = client.usbManager else { return }
        if usb.isUsbDeviceConnected(device) {
            usb.disconnectUsbDevice(device) { [weak self] error in self?.handleUSBResult(error) }
        } else {
            var message: NSString?
            guard usb.canRedirectUsbDevice(device, errorMessage: &message) else {
                presentTransientError((message as String?) ?? "This USB device cannot be redirected.")
                return
            }
            usb.connectUsbDevice(device) { [weak self] error in self?.handleUSBResult(error) }
        }
    }

    private func handleUSBResult(_ error: Error?) {
        DispatchQueue.main.async {
            if let error { self.presentTransientError(error.localizedDescription) }
            self.refreshUSBMenu()
        }
    }

    private func refreshUSBMenu() {
        // The USB submenu is shared app-wide; only the key window owns it, so
        // background windows' USB delegate callbacks don't retarget its items.
        guard window?.isKeyWindow == true, let menu = MainMenu.usbSubmenu else { return }
        menu.removeAllItems()
        guard let usb = client.usbManager else {
            menu.addItem(disabledItem("Not connected"))
            return
        }
        let devices = usb.usbDevices
        if devices.isEmpty {
            menu.addItem(disabledItem("No USB devices"))
            return
        }
        for device in devices {
            let item = NSMenuItem(title: label(for: device),
                                  action: #selector(toggleUSBDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = usb.isUsbDeviceConnected(device) ? .on : .off
            menu.addItem(item)
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func label(for device: CSUSBDevice) -> String {
        let name = device.name ?? device.usbProductName ?? "USB Device"
        return String(format: "%@ (%04lx:%04lx)", name, device.usbVendorId, device.usbProductId)
    }

    private func presentTransientError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "USB Redirection"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - CSUSBManagerDelegate

extension SpiceWindowController: CSUSBManagerDelegate {
    func spiceUsbManager(_ usbManager: CSUSBManager, deviceAttached device: CSUSBDevice) {
        DispatchQueue.main.async { self.refreshUSBMenu() }
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceRemoved device: CSUSBDevice) {
        DispatchQueue.main.async { self.refreshUSBMenu() }
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceError error: String, for device: CSUSBDevice) {
        DispatchQueue.main.async { self.presentTransientError(error) }
    }
}
