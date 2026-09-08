// SPDX-License-Identifier: MIT
import AppKit
import OSLog
import PVEClient

/// The Proxmox browser: sign in to a node, then pick a guest and open its console.
///
/// One window, two halves — credentials on top, the guest list below. The list stays
/// live after connecting so several consoles can be opened without signing in again.
final class PVEConnectWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSWindowDelegate {

    /// Called with a guest and the authenticated client that can mint tickets for it.
    var onOpenConsole: ((PVEGuest, PVEClient) -> Void)?

    /// Called to open a `.vv` file instead of signing in.
    var onOpenVVFile: (() -> Void)?

    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let authSelector = NSSegmentedControl(labels: ["API Token", "Username & Password"],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let tokenIDField = NSTextField()
    private let tokenSecretField = NSSecureTextField()
    private let usernameField = NSTextField()
    private let realmPopUp = NSPopUpButton()
    private let passwordField = NSSecureTextField()
    private let rememberCheckbox = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)

    private let connectButton = NSButton(title: "Sign In", target: nil, action: nil)
    private let openVVButton = NSButton(title: "Open .vv File…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private let searchField = NSSearchField()
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Console", target: nil, action: nil)
    private let powerButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let contextMenu = NSMenu()
    private let tableView = NSTableView()

    private var formGrid: NSGridView!
    private var tokenRows: [NSGridRow] = []
    private var passwordRows: [NSGridRow] = []
    private var allFormRows: [NSGridRow] = []
    private var isSignedIn = false

    private static let log = Logger(subsystem: "org.spicemac.SpiceMac", category: "proxmox")

    private var client: PVEClient?
    /// The secret as loaded from the Keychain. Rewriting an unchanged secret costs a
    /// second authorization prompt for no benefit, so persist only real changes.
    private var loadedSecret: String?
    private var guests: [PVEGuest] = []
    private var visibleGuests: [PVEGuest] = []

    /// Drives sign-in across the whole fleet. This window still only shows the first
    /// configured server; the tree that surfaces the rest is a later step.
    private let coordinator: PVEFleetCoordinator

    // MARK: - Lifecycle

    init() {
        coordinator = PVEFleetCoordinator(trustDelegate: PVEProfileStore.shared,
                                          secretProvider: { PVEProfileStore.shared.secret(for: $0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Connect to Proxmox VE"
        // Small floor, and deliberately NO frame autosave: in a tab group the picker
        // shares the frame with consoles sized to their guests, and an autosaved frame
        // reasserts itself when the tab is shown — dragging the whole group back down
        // to picker size. It adapts to whatever the group is instead. The explicit
        // restore when the last console closes lives in AppDelegate.
        window.minSize = NSSize(width: 420, height: 360)
        window.center()
        // Share the session tab group so the picker and its consoles live in one window.
        window.tabbingIdentifier = SpiceWindowController.tabbingIdentifier
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadProfile()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Forwarded from the Manage Servers sheet. This window still only drives the
    /// first configured server directly; the fleet as a whole is the coordinator's
    /// concern until the tree view replaces this single-server display.
    func setProfiles(_ profiles: [PVEServerProfile]) {
        coordinator.setProfiles(profiles)
    }

    /// Show the window; if a complete profile and a stored secret are already on hand,
    /// sign in straight away so the common case is "open app, see your VMs".
    func present(autoConnect: Bool = true) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard autoConnect else { return }
        guard client == nil else {
            Self.log.info("auto sign-in skipped: already signed in")
            return
        }
        guard let profile = PVEProfileStore.shared.profiles.first, profile.isComplete else {
            Self.log.info("auto sign-in skipped: no complete saved profile")
            return
        }
        guard currentSecret().isEmpty == false else {
            Self.log.info("auto sign-in skipped: no secret available (keychain read returned nothing)")
            return
        }
        Self.log.info("auto sign-in starting for \(profile.host, privacy: .public)")
        connect(self)
    }

    // MARK: - Building

    private func buildUI() {
        for field in [hostField, portField, tokenIDField, usernameField] {
            field.isEditable = true
            field.isBordered = true
            field.bezelStyle = .roundedBezel
        }
        hostField.placeholderString = "proxmox.example.com"
        portField.placeholderString = "8006"
        portField.formatter = onlyDigitsFormatter()
        tokenIDField.placeholderString = "root@pam!spicemac"
        tokenSecretField.placeholderString = "token secret (UUID)"
        usernameField.placeholderString = "root"
        passwordField.placeholderString = "password"
        realmPopUp.addItems(withTitles: ["pam", "pve"])

        authSelector.target = self
        authSelector.action = #selector(authKindChanged)
        authSelector.selectedSegment = 0

        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .rounded

        rememberCheckbox.state = .on
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Server:"), hostField,
             NSTextField(labelWithString: "Port:"), portField],
            [NSTextField(labelWithString: "Sign in with:"), authSelector],
            [NSTextField(labelWithString: "Token ID:"), tokenIDField],
            [NSTextField(labelWithString: "Secret:"), tokenSecretField],
            [NSTextField(labelWithString: "Username:"), usernameField,
             NSTextField(labelWithString: "Realm:"), realmPopUp],
            [NSTextField(labelWithString: "Password:"), passwordField],
            [NSGridCell.emptyContentView, rememberCheckbox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        // No fixed column width: this window shares a frame with consoles sized to their
        // guests, so its content must stretch to whatever it is given rather than
        // asserting a preferred width the frame then has to satisfy.
        // Low hugging so fields stretch with the window; compression resistance stays
        // HIGH so they cannot be squeezed away — lowering it collapses the window to a
        // sliver, since nothing else resists.
        for field in [hostField, tokenIDField, tokenSecretField, usernameField, passwordField] {
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 1, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 2, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 3, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 5, length: 1))
        formGrid = grid
        tokenRows = [grid.row(at: 2), grid.row(at: 3)]
        passwordRows = [grid.row(at: 4), grid.row(at: 5)]
        allFormRows = (0..<grid.numberOfRows).map { grid.row(at: $0) }

        openVVButton.target = self
        openVVButton.action = #selector(openVVFile(_:))
        openVVButton.bezelStyle = .rounded

        let actionRow = NSStackView(views: [statusLabel, NSView(), spinner, openVVButton, connectButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.setHuggingPriority(.defaultLow, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator

        searchField.delegate = self
        searchField.placeholderString = "Filter by name, ID or node"
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        refreshButton.bezelStyle = .rounded
        refreshButton.isEnabled = false

        let listHeader = NSStackView(views: [searchField, NSView(), refreshButton])
        listHeader.orientation = .horizontal
        listHeader.spacing = 8

        configureTable()
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        openButton.target = self
        openButton.action = #selector(openSelectedConsole(_:))
        openButton.bezelStyle = .rounded
        openButton.isEnabled = false

        powerButton.bezelStyle = .rounded
        powerButton.isEnabled = false
        contextMenu.delegate = self
        tableView.menu = contextMenu

        let footer = NSStackView(views: [powerButton, NSView(), openButton])
        footer.orientation = .horizontal

        // Everything except the table hugs its content, so spare vertical space goes to
        // the guest list. Without this the stack hands slack to the form, and hiding the
        // credentials rows on sign-in leaves a gap where they used to be.
        // NB: .defaultHigh, never .required. Required hugging is a hard constraint that
        // the view must not grow past its intrinsic height, and AppKit propagates that
        // to the window — `_changeWindowFrameFromConstraintsIfNecessary` then resizes
        // the frame to obey it, which is what was shrinking the tab group.
        for view in [grid as NSView, actionRow, separator, listHeader, footer] {
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
            view.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let root = NSStackView(views: [grid, actionRow, separator, listHeader, scrollView, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setHuggingPriority(.defaultLow, for: .vertical)

        guard let contentView = window?.contentView else { return }
        contentView.addSubview(root)

        // The content is a fixed-width panel anchored to the top-left of whatever
        // window it finds itself in — NOT stretched to the window's edges.
        //
        // Pinning it to all four edges couples the two sizes together, which is what
        // let the content's own layout drive the window frame (AppKit's
        // `_changeWindowFrameFromConstraintsIfNecessary`) and shrink the tab group
        // around the consoles sharing it. A panel cannot do that: it takes its natural
        // size, the window takes whatever size the group needs, and neither constrains
        // the other.
        // 999, not defaultHigh: NSStackView hugs horizontally at 750, and a tie lets
        // Auto Layout collapse the panel to its smallest satisfying width. Still below
        // required so `panelFits` wins on a narrow window.
        root.setHuggingPriority(.defaultLow, for: .horizontal)
        let panelWidth = root.widthAnchor.constraint(equalToConstant: 620)
        panelWidth.priority = NSLayoutConstraint.Priority(999)
        let panelFits = root.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor,
                                                    constant: -32)
        // Let the list stretch toward the bottom when there is room, but never require it.
        let panelStretch = root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor,
                                                        constant: -16)
        panelStretch.priority = .defaultLow

        var constraints: [NSLayoutConstraint] = [
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
            panelWidth,
            panelFits,
            panelStretch,
        ]
        // Rows follow the panel, not the window, so hiding the form cannot collapse them.
        for view in [grid as NSView, actionRow, separator, listHeader, scrollView, footer] {
            constraints.append(view.widthAnchor.constraint(equalTo: root.widthAnchor))
        }
        let listFloor = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        listFloor.priority = .defaultHigh               // shrinks rather than forcing the window taller
        constraints.append(listFloor)
        NSLayoutConstraint.activate(constraints)

        authKindChanged()
    }

    private func configureTable() {
        let columns: [(String, String, CGFloat)] = [
            ("name", "Name", 220),
            ("vmid", "ID", 60),
            ("node", "Node", 110),
            ("status", "Status", 90),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        // Only the name column should grow; ID/Node/Status are narrow facts and were
        // being pushed off the right edge when the name column absorbed the width.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if let name = tableView.tableColumns.first {
            name.resizingMask = [.autoresizingMask, .userResizingMask]
            name.minWidth = 120
        }
        for column in tableView.tableColumns.dropFirst() {
            column.resizingMask = [.userResizingMask]
            column.minWidth = 50
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedConsole(_:))
        if #available(macOS 11.0, *) { tableView.style = .inset }
    }

    private func onlyDigitsFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }

    // MARK: - Profile

    private func loadProfile() {
        let profile = PVEProfileStore.shared.profiles.first ?? PVEServerProfile()
        hostField.stringValue = profile.host
        portField.stringValue = String(profile.port)
        tokenIDField.stringValue = profile.tokenID
        usernameField.stringValue = profile.username
        realmPopUp.selectItem(withTitle: profile.realm)
        rememberCheckbox.state = profile.rememberSecret ? .on : .off
        authSelector.selectedSegment = profile.authKind == .apiToken ? 0 : 1
        authKindChanged()

        if profile.rememberSecret, profile.isComplete,
           let secret = PVEProfileStore.shared.secret(for: profile) {
            loadedSecret = secret
            if profile.authKind == .apiToken {
                tokenSecretField.stringValue = secret
            } else {
                passwordField.stringValue = secret
            }
        }
    }

    /// Starts from the stored first profile (if any) so its `id` and `label` survive
    /// a save — this window only edits that one slot, it must not fork a new identity
    /// for it on every Sign In.
    private func currentProfile() -> PVEServerProfile {
        var profile = PVEProfileStore.shared.profiles.first ?? PVEServerProfile()
        profile.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.port = Int(portField.stringValue) ?? 8006
        profile.authKind = authSelector.selectedSegment == 0 ? .apiToken : .password
        profile.tokenID = tokenIDField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.realm = realmPopUp.titleOfSelectedItem ?? "pam"
        profile.rememberSecret = rememberCheckbox.state == .on
        return profile
    }

    private func currentSecret() -> String {
        authSelector.selectedSegment == 0 ? tokenSecretField.stringValue : passwordField.stringValue
    }

    @objc private func authKindChanged() {
        guard isSignedIn == false else { return }
        let usingToken = authSelector.selectedSegment == 0
        for row in tokenRows { row.isHidden = !usingToken }
        for row in passwordRows { row.isHidden = usingToken }
    }

    /// Once signed in the credentials are just clutter above the thing the user came
    /// for, so fold them away and give the space to the guest list.
    private func setSignedIn(_ signedIn: Bool) {
        isSignedIn = signedIn
        if signedIn {
            for row in allFormRows { row.isHidden = true }
            connectButton.title = "Sign Out"
            openVVButton.isHidden = true
        } else {
            for row in allFormRows { row.isHidden = false }
            connectButton.title = "Sign In"
            openVVButton.isHidden = false
            authKindChanged()
        }
    }

    @objc private func signOut() {
        client = nil
        guests = []
        applyFilter()
        refreshButton.isEnabled = false
        setSignedIn(false)
        showStatus("", isError: false)
    }

    // MARK: - Actions

    @objc private func openVVFile(_ sender: Any?) {
        onOpenVVFile?()
    }

    @objc private func connect(_ sender: Any?) {
        if isSignedIn {
            signOut()
            return
        }
        let profile = currentProfile()
        let secret = currentSecret()

        guard profile.isComplete else {
            showStatus(profile.host.isEmpty
                       ? "Enter the Proxmox server address."
                       : "Enter a full API token ID, e.g. root@pam!spicemac.", isError: true)
            return
        }
        guard secret.isEmpty == false else {
            showStatus(profile.authKind == .apiToken ? "Enter the token secret." : "Enter the password.",
                       isError: true)
            return
        }

        setBusy(true, message: "Signing in to \(profile.host)…")
        let newClient = PVEClient(server: profile.server,
                                  credentials: profile.credentials(secret: secret),
                                  trustDelegate: PVEProfileStore.shared)

        Task { @MainActor [weak self] in
            do {
                let fetched = try await newClient.listGuests()
                guard let self else { return }
                self.client = newClient
                self.guests = fetched
                self.applyFilter()
                self.setSignedIn(true)
                self.setBusy(false, message: fetched.isEmpty
                             ? "Signed in — no virtual machines visible."
                             : "Signed in to \(profile.host) as \(profile.credentials(secret: "").displayUser).")
                if fetched.isEmpty { self.explainEmptyList(client: newClient, profile: profile) }
                self.refreshButton.isEnabled = true
                self.persist(profile: profile, secret: secret)
                if fetched.isEmpty == false, self.tableView.selectedRow < 0 {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
            } catch {
                guard let self else { return }
                self.setBusy(false, message: nil)
                Self.log.error("sign-in failed for \(profile.host, privacy: .public): \(String(describing: error), privacy: .public)")
                self.showStatus("Sign-in failed.", isError: true)
                self.presentError(error, title: "Could not sign in to \(profile.host)")
            }
        }
    }

    /// An empty guest list is ambiguous: Proxmox filters the cluster listing by
    /// permission and returns an empty array rather than a 403, so a token with no ACL
    /// looks exactly like a cluster with no VMs. Ask what the token can actually see.
    private func explainEmptyList(client: PVEClient, profile: PVEServerProfile) {
        Task { @MainActor [weak self] in
            guard let self, let hint = await client.diagnoseEmptyGuestList() else { return }
            self.showStatus("No guests visible — check the token's permissions.", isError: true)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "No virtual machines are visible to these credentials"
            let token = profile.authKind == .apiToken ? profile.tokenID : profile.credentials(secret: "").displayUser
            alert.informativeText = """
                \(hint)

                On the Proxmox node, granting console access to every VM looks like:

                pveum acl modify /vms --tokens '\(token)' --roles PVEVMUser

                PVEVMUser covers VM.Audit (see them), VM.Console (open them) and \
                VM.PowerMgmt (start and stop them). Then click Refresh.
                """
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                let command = "pveum acl modify /vms --tokens '\(token)' --roles PVEVMUser"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }

    private func persist(profile: PVEServerProfile, secret: String) {
        var profiles = PVEProfileStore.shared.profiles
        if profiles.isEmpty {
            profiles = [profile]
        } else {
            profiles[0] = profile
        }
        PVEProfileStore.shared.profiles = profiles

        guard profile.rememberSecret else {
            PVEKeychain.delete(account: profile.keychainAccount)
            loadedSecret = nil
            return
        }
        // Rewriting an unchanged secret costs a second Keychain authorization prompt.
        guard secret != loadedSecret else { return }
        PVEProfileStore.shared.setSecret(secret, for: profile)
        loadedSecret = secret
    }

    @objc private func refresh(_ sender: Any?) {
        guard let client else { return }
        setBusy(true, message: "Refreshing…")
        Task { @MainActor [weak self] in
            do {
                let fetched = try await client.listGuests()
                guard let self else { return }
                self.guests = fetched
                self.applyFilter()
                self.setBusy(false, message: "\(fetched.count) guest\(fetched.count == 1 ? "" : "s").")
                if fetched.isEmpty, let profile = PVEProfileStore.shared.profiles.first {
                    self.explainEmptyList(client: client, profile: profile)
                }
            } catch {
                guard let self else { return }
                self.setBusy(false, message: nil)
                self.presentError(error, title: "Could not refresh the guest list")
            }
        }
    }

    @objc private func openSelectedConsole(_ sender: Any?) {
        guard let guest = selectedGuest(), let client else { return }
        guard guest.isRunning else {
            offerToStart(guest, client: client)
            return
        }
        onOpenConsole?(guest, client)
    }

    /// A stopped guest has no console to attach to. Rather than refuse, offer the one
    /// thing the user obviously wants — start it, then connect once it is up.
    private func offerToStart(_ guest: PVEGuest, client: PVEClient) {
        guard PVEPowerAction.start.isAvailable(for: guest) else {
            showStatus("\(guest.name) is \(guest.status).", isError: true)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "“\(guest.name)” is \(guest.status)."
        alert.informativeText = "Start it and open the console once it is running?"
        alert.addButton(withTitle: "Start and Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setBusy(true, message: "Starting \(guest.name)…")
        Task { @MainActor [weak self] in
            do {
                let upid = try await client.performPower(.start, on: guest)
                try await client.awaitTask(node: guest.node, upid: upid)
                guard let self else { return }
                self.setBusy(false, message: "\(guest.name) started.")
                self.refresh(nil)
                // The task finishing means QEMU is up; SPICE is ready at that point.
                self.onOpenConsole?(guest, client)
            } catch {
                guard let self else { return }
                self.setBusy(false, message: nil)
                self.presentError(error, title: "Could not start \(guest.name)")
                self.refresh(nil)
            }
        }
    }

    // MARK: - Window

    func windowDidResize(_ notification: Notification) {
        Self.log.info("connect resized to \(NSStringFromRect(self.window?.frame ?? .zero), privacy: .public)")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Self.log.info("connect activated at \(NSStringFromRect(self.window?.frame ?? .zero), privacy: .public)")
    }

    // MARK: - Power

    /// Build the action list for `guest`. Actions that make no sense in its current
    /// state are shown disabled rather than hidden, so the menu doesn't reshuffle
    /// under the pointer as a VM changes state.
    private func powerMenuItems(for guest: PVEGuest?) -> [NSMenuItem] {
        PVEPowerAction.allCases.compactMap { action in
            // Suspend/resume are niche next to the power-cycle basics; show them only
            // when they actually apply.
            if (action == .suspend || action == .resume),
               let guest, action.isAvailable(for: guest) == false { return nil }
            let item = NSMenuItem(title: action.title, action: #selector(powerActionSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.isEnabled = guest.map { action.isAvailable(for: $0) } ?? false
            if action == .stop { item.title = "\(action.title)…" }
            if action == .reset { item.title = "\(action.title)…" }
            return item
        }
    }

    private func rebuildPowerMenus() {
        let guest = selectedGuest()

        let pullDown = NSMenu()
        // Item 0 of a pull-down is its label, never selected.
        pullDown.addItem(NSMenuItem(title: "Power", action: nil, keyEquivalent: ""))
        for item in powerMenuItems(for: guest) { pullDown.addItem(item) }
        powerButton.menu = pullDown
        powerButton.isEnabled = guest != nil

        contextMenu.removeAllItems()
        if let guest {
            let header = NSMenuItem(title: "\(guest.name) (\(guest.vmid))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            contextMenu.addItem(header)
            contextMenu.addItem(.separator())
            let open = NSMenuItem(title: "Open Console", action: #selector(openSelectedConsole(_:)), keyEquivalent: "")
            open.target = self
            open.isEnabled = guest.isRunning
            contextMenu.addItem(open)
            contextMenu.addItem(.separator())
            for item in powerMenuItems(for: guest) { contextMenu.addItem(item) }
        }
    }

    /// Right-clicking a row acts on that row, which means selecting it first —
    /// otherwise the menu would apply to whatever was selected before.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = tableView.clickedRow
        if clicked >= 0, clicked < visibleGuests.count, tableView.selectedRow != clicked {
            tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        rebuildPowerMenus()
    }

    private func selectedGuest() -> PVEGuest? {
        let row = tableView.selectedRow
        guard row >= 0, row < visibleGuests.count else { return nil }
        return visibleGuests[row]
    }

    @objc private func powerActionSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = PVEPowerAction(rawValue: raw),
              let guest = selectedGuest(), let client else { return }
        guard confirm(action, on: guest) else { return }

        setBusy(true, message: "\(action.title) \(guest.name)…")
        Task { @MainActor [weak self] in
            do {
                let upid = try await client.performPower(action, on: guest)
                try await client.awaitTask(node: guest.node, upid: upid)
                guard let self else { return }
                self.setBusy(false, message: "\(guest.name): \(action.title.lowercased()) completed.")
                self.refresh(nil)
            } catch {
                guard let self else { return }
                self.setBusy(false, message: nil)
                self.showStatus("\(action.title) failed.", isError: true)
                self.presentError(error, title: "Could not \(action.title.lowercased()) \(guest.name)")
                // State may still have moved even on failure — re-read rather than guess.
                self.refresh(nil)
            }
        }
    }

    /// Destructive actions cut power without telling the guest, so they ask first.
    private func confirm(_ action: PVEPowerAction, on guest: PVEGuest) -> Bool {
        guard let detail = action.confirmationDetail else { return true }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(action.title) “\(guest.name)”?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action.title)
        // Cancel takes Return; the destructive button needs a deliberate click.
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Filtering

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject === searchField { applyFilter() }
    }

    private func applyFilter() {
        let needle = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        visibleGuests = needle.isEmpty ? guests : guests.filter {
            $0.name.lowercased().contains(needle)
                || String($0.vmid).contains(needle)
                || $0.node.lowercased().contains(needle)
        }
        tableView.reloadData()
        updateOpenButton()
        rebuildPowerMenus()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { visibleGuests.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visibleGuests.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let guest = visibleGuests[row]
        let text: String
        switch identifier {
        case "name":   text = guest.name
        case "vmid":   text = String(guest.vmid)
        case "node":   text = guest.node
        default:       text = guest.status
        }

        let cell = tableView.makeView(withIdentifier: tableColumn!.identifier, owner: self) as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = tableColumn!.identifier
                field.lineBreakMode = .byTruncatingTail
                return field
            }()
        cell.stringValue = text
        // Stopped guests have no SPICE console to open; dim the whole row so that is
        // obvious before the user double-clicks one.
        cell.textColor = guest.isRunning ? .labelColor : .tertiaryLabelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateOpenButton()
        rebuildPowerMenus()
    }

    private func updateOpenButton() {
        openButton.isEnabled = selectedGuest()?.isRunning ?? false
    }

    // MARK: - Status

    private func setBusy(_ busy: Bool, message: String?) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        connectButton.isEnabled = !busy
        refreshButton.isEnabled = !busy && client != nil
        powerButton.isEnabled = !busy && selectedGuest() != nil
        if let message { showStatus(message, isError: false) }
    }

    private func showStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as? PVEError)?.description ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
