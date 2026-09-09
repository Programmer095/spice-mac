// SPDX-License-Identifier: MIT
import AppKit
import OSLog
import PVEClient

/// A stable identity for an outline row wrapping a value type. `PVEInstanceSnapshot`
/// and `PVEGuest` are structs, so handing them straight to `NSOutlineViewDataSource`
/// loses the object identity that `reloadItem`/expansion tracking rely on: a snapshot
/// whose state just changed is a different value than the one the outline view last
/// saw, so it stops being recognised as "the same row" and its disclosure state is
/// lost. Reusing one wrapper object per instance across state updates (mutating its
/// `snapshot` in place instead of replacing the object) keeps that identity stable.
private final class PVEFleetInstanceRow: NSObject {
    let id: UUID
    var snapshot: PVEInstanceSnapshot

    init(snapshot: PVEInstanceSnapshot) {
        self.id = snapshot.id
        self.snapshot = snapshot
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? PVEFleetInstanceRow)?.id == id
    }

    override var hash: Int { id.hashValue }
}

/// Keyed by instance id *and* guest id: two different clusters can easily share node
/// names and VMIDs, and `PVEGuest.id` alone does not disambiguate them.
private final class PVEFleetGuestRow: NSObject {
    let instanceID: UUID
    var guest: PVEGuest

    init(instanceID: UUID, guest: PVEGuest) {
        self.instanceID = instanceID
        self.guest = guest
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PVEFleetGuestRow else { return false }
        return other.instanceID == instanceID && other.guest.id == guest.id
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(instanceID)
        hasher.combine(guest.id)
        return hasher.finalize()
    }
}

private extension PVEInstanceState {
    var isSignedIn: Bool { if case .signedIn = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

/// The Proxmox browser: sign in to one or more nodes, then pick a guest and open its
/// console.
///
/// One window: credentials for the primary server on top, the whole fleet's guests
/// below as a tree — every configured server as a parent row, its guests nested
/// beneath. The tree stays live after connecting so several consoles can be opened
/// without signing in again, and a server that fails or comes back down reports that
/// on its own row rather than as a modal over the whole app.
final class PVEConnectWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSWindowDelegate {

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
    private let outlineView = NSOutlineView()

    private var formGrid: NSGridView!
    private var tokenRows: [NSGridRow] = []
    private var passwordRows: [NSGridRow] = []
    private var allFormRows: [NSGridRow] = []
    private var isSignedIn = false

    private static let log = Logger(subsystem: "org.spicemac.SpiceMac", category: "proxmox")

    /// The secret as loaded from the Keychain. Rewriting an unchanged secret costs a
    /// second authorization prompt for no benefit, so persist only real changes.
    private var loadedSecret: String?
    /// The stored profile the fields were last populated from, so a fleet change can
    /// be told apart from one this form already reflects.
    private var formProfile: PVEServerProfile?
    /// The profile the credentials form above edits — always the fleet's first slot.
    /// Everything else in the window (the tree, sign-in-all-on-reveal) is driven by
    /// the coordinator across every configured server, not just this one.
    private var primaryProfileID: UUID?
    /// Set by `connect()` while a form-driven sign-in is in flight, so the coordinator's
    /// eventual success/failure can decide whether to persist — a mistyped secret must
    /// never overwrite a working one in the Keychain.
    private var pendingPrimaryPersist: (id: UUID, profile: PVEServerProfile, secret: String)?

    /// Row wrappers, reused across reloads by id so `NSOutlineView` keeps expansion
    /// and selection state stable even though the coordinator hands us fresh struct
    /// values on every change. Pruned in `refreshTree()` to drop servers/guests that
    /// no longer exist.
    private var instanceRowCache: [UUID: PVEFleetInstanceRow] = [:]
    private var guestRowCache: [String: PVEFleetGuestRow] = [:]
    private var visibleInstanceRows: [PVEFleetInstanceRow] = []
    private var visibleGuestRowsByInstance: [UUID: [PVEFleetGuestRow]] = [:]
    /// Instances seen in a previous `refreshTree()` — a newly-appeared one is
    /// auto-expanded once so a freshly signed-in server doesn't look collapsed shut.
    private var knownInstanceIDs: Set<UUID> = []

    /// The empty-guest-list diagnosis, per instance. Rendered as that row's subtitle
    /// instead of an alert — see `diagnoseIfEmpty`.
    private var emptyListHints: [UUID: String] = [:]
    private var diagnosedInstances: Set<UUID> = []

    /// Drives sign-in across the whole fleet: one client per configured server,
    /// folded into a tree instead of this window showing only the first one. Shared with
    /// the console overlays, so signing in here lights those up too.
    private let session = PVEFleetSession.shared
    private var coordinator: PVEFleetCoordinator { session.coordinator }
    private var fleetObservation: PVEFleetSession.Token?

    // MARK: - Lifecycle

    init() {
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
        fleetObservation = session.observe { [weak self] state in self?.handleFleetStateChanged(state) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Forwarded from the Manage Servers sheet.
    func setProfiles(_ profiles: [PVEServerProfile]) {
        session.setProfiles(profiles)
        // The credentials form is a view onto the fleet's first slot. If the sheet
        // changed that slot, the fields — and `loadedSecret` — still hold pre-sheet
        // values, and the next Sign In would write them straight back over the edit.
        if profiles.first != formProfile { loadProfile() }
        primaryProfileID = profiles.first?.id
    }

    /// Show the window, then bring the tree up to date: refresh the instance behind
    /// whatever is selected, or sign in everywhere if nothing is signed in yet. No
    /// timer — this is the one point a reveal costs a request.
    func present(autoConnect: Bool = true) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard autoConnect else { return }
        if let id = currentSelectionInstanceID() {
            coordinator.refresh(id)
        } else if coordinator.state.instances.contains(where: { $0.state.isSignedIn }) == false {
            coordinator.signInAll()
        }
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

        configureOutline()
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
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
        outlineView.menu = contextMenu

        let footer = NSStackView(views: [powerButton, NSView(), openButton])
        footer.orientation = .horizontal

        // Everything except the tree hugs its content, so spare vertical space goes to
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
        for view in [actionRow as NSView, separator, listHeader, scrollView, footer] {
            constraints.append(view.widthAnchor.constraint(equalTo: root.widthAnchor))
        }
        // The grid is the one row whose own width legitimately falls to zero: signing in
        // hides every credentials row, and an all-rows-hidden NSGridView has no content
        // left to be wide. Tying that to the panel at required priority lets the collapse
        // propagate outwards — it outranks `panelWidth`'s 999 and drags the panel down to
        // a sliver, taking the filter field and the guest tree with it. Nothing is
        // unsatisfiable, so Auto Layout never reports it. Below 999 the grid still
        // stretches to fill the panel but can no longer shrink it.
        let gridWidth = grid.widthAnchor.constraint(equalTo: root.widthAnchor)
        gridWidth.priority = .defaultHigh
        constraints.append(gridWidth)
        let listFloor = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        listFloor.priority = .defaultHigh               // shrinks rather than forcing the window taller
        constraints.append(listFloor)
        NSLayoutConstraint.activate(constraints)

        authKindChanged()
    }

    private func configureOutline() {
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
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        // Only the name column should grow; ID/Node/Status are narrow facts and were
        // being pushed off the right edge when the name column absorbed the width.
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if let name = outlineView.tableColumns.first {
            name.resizingMask = [.autoresizingMask, .userResizingMask]
            name.minWidth = 160
        }
        for column in outlineView.tableColumns.dropFirst() {
            column.resizingMask = [.userResizingMask]
            column.minWidth = 50
        }
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = false
        outlineView.rowHeight = 22
        outlineView.style = .sourceList
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineDoubleClicked(_:))
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
        formProfile = PVEProfileStore.shared.profiles.first
        let profile = formProfile ?? PVEServerProfile()
        primaryProfileID = formProfile?.id
        loadedSecret = nil
        // Cleared unconditionally: reloading onto a server with nothing stored would
        // otherwise leave the previous server's secret sitting in the field.
        tokenSecretField.stringValue = ""
        passwordField.stringValue = ""
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
    /// a save — this form only edits that one slot, it must not fork a new identity
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
    /// for, so fold them away and give the space to the guest tree.
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

    /// Reflects the primary profile's fleet state onto the credentials form. A
    /// sign-in failure shows on the form (this is the one server the user is looking
    /// straight at) — every other server's failure shows on its own tree row instead.
    private func updatePrimaryFormState() {
        guard let id = primaryProfileID, let instance = coordinator.state.instance(id) else {
            setBusy(false, message: nil)
            setSignedIn(false)
            return
        }
        switch instance.state {
        case .signedOut:
            setBusy(false, message: nil)
            setSignedIn(false)
            showStatus("", isError: false)
        case .signingIn:
            setBusy(true, message: "Signing in to \(instance.profile.host)…")
        case .signedIn:
            setBusy(false, message: nil)
            setSignedIn(true)
            showStatus("Signed in to \(instance.profile.host) as \(instance.profile.credentials(secret: "").displayUser).",
                       isError: false)
        case .failed(let error):
            setBusy(false, message: nil)
            setSignedIn(false)
            showStatus("Sign-in failed: \(error.description)", isError: true)
        }
    }

    // MARK: - Actions

    @objc private func openVVFile(_ sender: Any?) {
        onOpenVVFile?()
    }

    @objc private func connect(_ sender: Any?) {
        if isSignedIn {
            if let id = primaryProfileID { coordinator.signOut(id) }
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

        primaryProfileID = profile.id
        pendingPrimaryPersist = (id: profile.id, profile: profile, secret: secret)
        coordinator.setProfiles(updatedProfiles(with: profile))
        coordinator.signIn(profile.id, usingSecret: secret)
    }

    /// The stored profile list with `profile` in the first slot, without writing it to
    /// disk — used to tell the coordinator about an edit before it's confirmed to work.
    private func updatedProfiles(with profile: PVEServerProfile) -> [PVEServerProfile] {
        var profiles = PVEProfileStore.shared.profiles
        if profiles.isEmpty {
            profiles = [profile]
        } else {
            profiles[0] = profile
        }
        return profiles
    }

    private func persist(profile: PVEServerProfile, secret: String) {
        let previous = PVEProfileStore.shared.profiles.first
        let updated = updatedProfiles(with: profile)
        PVEProfileStore.shared.profiles = updated
        formProfile = updated.first

        // Editing the host, port or token moves the Keychain account and the pinned
        // certificate along with it. Left behind, the old item is an orphan nothing can
        // reach, and the old pin keeps a host we no longer use auto-trusted.
        var accountMoved = false
        if let previous, previous.id == profile.id {
            accountMoved = previous.keychainAccount != profile.keychainAccount
            if accountMoved,
               updated.contains(where: { $0.keychainAccount == previous.keychainAccount }) == false {
                PVEKeychain.delete(account: previous.keychainAccount)
            }
            if previous.host.isEmpty == false,
               previous.host.caseInsensitiveCompare(profile.host) != .orderedSame,
               updated.contains(where: { $0.host.caseInsensitiveCompare(previous.host) == .orderedSame }) == false {
                PVEProfileStore.shared.forgetPin(forHost: previous.host)
            }
        }

        guard profile.rememberSecret else {
            PVEKeychain.delete(account: profile.keychainAccount)
            loadedSecret = nil
            return
        }
        // Rewriting an unchanged secret costs a second Keychain authorization prompt —
        // but a moved account has nothing stored under its new name yet.
        guard accountMoved || secret != loadedSecret else { return }
        PVEProfileStore.shared.setSecret(secret, for: profile)
        loadedSecret = secret
    }

    @objc private func refresh(_ sender: Any?) {
        guard let id = currentSelectionInstanceID() else { return }
        coordinator.refresh(id)
    }

    @objc private func openSelectedConsole(_ sender: Any?) {
        guard let guestRow = selectedGuestRow(), let client = coordinator.client(for: guestRow.instanceID) else { return }
        let guest = guestRow.guest
        guard guest.isRunning else {
            offerToStart(guest, client: client, instanceID: guestRow.instanceID)
            return
        }
        onOpenConsole?(guest, client)
    }

    /// A stopped guest has no console to attach to. Rather than refuse, offer the one
    /// thing the user obviously wants — start it, then connect once it is up.
    private func offerToStart(_ guest: PVEGuest, client: PVEClient, instanceID: UUID) {
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
                self.coordinator.refresh(instanceID)
                // The task finishing means QEMU is up; SPICE is ready at that point.
                self.onOpenConsole?(guest, client)
            } catch {
                guard let self else { return }
                self.setBusy(false, message: nil)
                self.presentError(error, title: "Could not start \(guest.name)")
                self.coordinator.refresh(instanceID)
            }
        }
    }

    private static func describe(_ state: PVEInstanceState) -> String {
        switch state {
        case .signedOut: return "signedOut"
        case .signingIn: return "signingIn"
        case .signedIn(let guests): return "signedIn(\(guests.count) guests)"
        case .failed(let error): return "failed(\(error))"
        }
    }

    // MARK: - Layout probe

    /// Test seam for `UICheck`. Puts the panel in one of its two credential states at a
    /// given window width and reports the frames the checks assert on. Drives layout
    /// only — nothing here reaches the network, so it runs without a server.
    func probePanelLayout(signedIn: Bool, contentWidth: CGFloat) -> PVEPanelLayout {
        guard let window, let contentView = window.contentView else { return .zero }
        setSignedIn(signedIn)
        window.setContentSize(NSSize(width: contentWidth, height: 580))
        contentView.layoutSubtreeIfNeeded()
        return PVEPanelLayout(content: contentView.bounds,
                              root: formGrid.superview?.frame ?? .zero,
                              grid: formGrid.frame,
                              list: outlineView.enclosingScrollView?.frame ?? .zero,
                              filter: searchField.frame)
    }

    /// Renders the window's own content offscreen. `cacheDisplay` draws through the view
    /// tree rather than reading the screen, so this needs no Screen Recording grant and
    /// works on a window that was never ordered front.
    func writePanelSnapshot(to directory: String, named name: String) -> String? {
        guard let contentView = window?.contentView else { return nil }
        contentView.layoutSubtreeIfNeeded()
        guard let representation = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { return nil }
        contentView.cacheDisplay(in: contentView.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return nil }
        let path = (directory as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    // MARK: - Window

    func windowDidResize(_ notification: Notification) {
        Self.log.info("connect resized to \(NSStringFromRect(self.window?.frame ?? .zero), privacy: .public)")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Self.log.info("connect activated at \(NSStringFromRect(self.window?.frame ?? .zero), privacy: .public)")
    }

    // MARK: - Fleet state

    private func handleFleetStateChanged(_ state: PVEFleetState) {
        // Every sign-in transition, on the record. A stuck sign-in shows nothing but a
        // spinner, and `log show --info --predicate 'subsystem == "org.spicemac.SpiceMac"'`
        // is the difference between diagnosing one and guessing at it.
        for instance in state.instances {
            Self.log.info("fleet \(instance.profile.host, privacy: .public) -> \(Self.describe(instance.state), privacy: .public)")
        }
        refreshTree()
        resolvePendingPrimaryPersist(state)
        updatePrimaryFormState()
        diagnoseEmptyInstancesIfNeeded(state)
    }

    /// Commits the form's typed secret to the Keychain only once the coordinator
    /// confirms it actually works; a failure leaves whatever was already stored alone.
    private func resolvePendingPrimaryPersist(_ state: PVEFleetState) {
        guard let pending = pendingPrimaryPersist, let instance = state.instance(pending.id) else { return }
        switch instance.state {
        case .signedIn:
            persist(profile: pending.profile, secret: pending.secret)
            pendingPrimaryPersist = nil
        case .failed:
            pendingPrimaryPersist = nil
        case .signedOut, .signingIn:
            break
        }
    }

    /// An instance that lists zero guests is ambiguous — Proxmox filters the listing
    /// by permission and returns an empty array rather than a 403 — so ask what the
    /// token can actually see, and report it on that row rather than over the whole
    /// app. Clears the hint once the instance stops being signed-in-and-empty, so a
    /// stale diagnosis from a previous sign-in doesn't linger.
    private func diagnoseEmptyInstancesIfNeeded(_ state: PVEFleetState) {
        for instance in state.instances {
            if case .signedIn(let guests) = instance.state, guests.isEmpty {
                diagnoseIfEmpty(instance)
            } else {
                emptyListHints[instance.id] = nil
                diagnosedInstances.remove(instance.id)
            }
        }
    }

    private func diagnoseIfEmpty(_ instance: PVEInstanceSnapshot) {
        guard case .signedIn(let guests) = instance.state, guests.isEmpty,
              let client = coordinator.client(for: instance.id),
              diagnosedInstances.contains(instance.id) == false else { return }
        diagnosedInstances.insert(instance.id)
        Task { @MainActor [weak self] in
            guard let self, let hint = await client.diagnoseEmptyGuestList() else { return }
            self.emptyListHints[instance.id] = hint
            if let row = self.instanceRowCache[instance.id] {
                // reloadItem does not re-query heightOfRowByItem, so the row would stay
                // 22pt tall and clip the two-line stack the hint is rendered into.
                let index = self.outlineView.row(forItem: row)
                if index >= 0 {
                    self.outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
                }
                self.outlineView.reloadItem(row)
            }
        }
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

    private func rebuildFooterPowerMenu() {
        let guest = selectedGuest()
        let pullDown = NSMenu()
        // Item 0 of a pull-down is its label, never selected.
        pullDown.addItem(NSMenuItem(title: "Power", action: nil, keyEquivalent: ""))
        for item in powerMenuItems(for: guest) { pullDown.addItem(item) }
        powerButton.menu = pullDown
        powerButton.isEnabled = guest != nil
    }

    /// A server has no power state of its own, so its context menu offers the
    /// operations that make sense for a *connection* instead: Sign In, Sign Out,
    /// Refresh, and — only while its guest list is unexplained — Copy Command.
    private func instanceMenuItems(for row: PVEFleetInstanceRow) -> [NSMenuItem] {
        let state = row.snapshot.state

        let signIn = NSMenuItem(title: "Sign In", action: #selector(instanceSignIn(_:)), keyEquivalent: "")
        signIn.target = self
        signIn.isEnabled = state == .signedOut || state.isFailed

        let signOut = NSMenuItem(title: "Sign Out", action: #selector(instanceSignOut(_:)), keyEquivalent: "")
        signOut.target = self
        signOut.isEnabled = state != .signedOut

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(instanceRefresh(_:)), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = state.isSignedIn

        var items = [signIn, signOut, refreshItem]
        if emptyListHints[row.id] != nil {
            items.append(.separator())
            let copy = NSMenuItem(title: "Copy Command", action: #selector(copyACLCommand(_:)), keyEquivalent: "")
            copy.target = self
            items.append(copy)
        }
        return items
    }

    /// Right-clicking a row acts on that row, which means selecting it first —
    /// otherwise the menu would apply to whatever was selected before. The menu itself
    /// differs by row kind: guest rows get Open Console + power actions, instance rows
    /// get Sign In / Sign Out / Refresh — power has no meaning for a server.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = outlineView.clickedRow
        if clicked >= 0, outlineView.selectedRow != clicked {
            outlineView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }

        contextMenu.removeAllItems()
        if let guestRow = selectedGuestRow() {
            let guest = guestRow.guest
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
        } else if let instanceRow = selectedInstanceRow() {
            for item in instanceMenuItems(for: instanceRow) { contextMenu.addItem(item) }
        }
        rebuildFooterPowerMenu()
    }

    private func selectedItem() -> Any? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row)
    }

    private func selectedGuestRow() -> PVEFleetGuestRow? { selectedItem() as? PVEFleetGuestRow }
    private func selectedInstanceRow() -> PVEFleetInstanceRow? { selectedItem() as? PVEFleetInstanceRow }
    private func selectedGuest() -> PVEGuest? { selectedGuestRow()?.guest }

    /// The instance behind whatever is selected — a guest row's parent, or an
    /// instance row itself. Drives "refresh on reveal" and the header Refresh button.
    private func currentSelectionInstanceID() -> UUID? {
        if let guestRow = selectedGuestRow() { return guestRow.instanceID }
        if let instanceRow = selectedInstanceRow() { return instanceRow.id }
        return nil
    }

    @objc private func instanceSignIn(_ sender: Any?) {
        guard let row = selectedInstanceRow() else { return }
        coordinator.signIn(row.id)
    }

    @objc private func instanceSignOut(_ sender: Any?) {
        guard let row = selectedInstanceRow() else { return }
        coordinator.signOut(row.id)
    }

    @objc private func instanceRefresh(_ sender: Any?) {
        guard let row = selectedInstanceRow() else { return }
        coordinator.refresh(row.id)
    }

    @objc private func copyACLCommand(_ sender: Any?) {
        guard let row = selectedInstanceRow() else { return }
        let profile = row.snapshot.profile
        let token = profile.authKind == .apiToken ? profile.tokenID : profile.credentials(secret: "").displayUser
        let command = "pveum acl modify /vms --tokens '\(token)' --roles PVEVMUser"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        showStatus("ACL command copied to clipboard.", isError: false)
    }

    @objc private func outlineDoubleClicked(_ sender: Any?) {
        if let row = selectedInstanceRow() {
            if outlineView.isItemExpanded(row) {
                outlineView.collapseItem(row)
            } else {
                outlineView.expandItem(row)
            }
            return
        }
        openSelectedConsole(sender)
    }

    @objc private func powerActionSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = PVEPowerAction(rawValue: raw),
              let guestRow = selectedGuestRow(),
              let client = coordinator.client(for: guestRow.instanceID) else { return }
        let guest = guestRow.guest
        guard confirm(action, on: guest) else { return }

        let instanceID = guestRow.instanceID
        setBusy(true, message: "\(action.title) \(guest.name)…")
        Task { @MainActor [weak self] in
            do {
                let upid = try await client.performPower(action, on: guest)
                try await client.awaitTask(node: guest.node, upid: upid)
                guard let self else { return }
                self.setBusy(false, message: "\(guest.name): \(action.title.lowercased()) completed.")
                self.coordinator.refresh(instanceID)
            } catch {
                guard let self else { return }
                self.setBusy(false, message: nil)
                self.showStatus("\(action.title) failed.", isError: true)
                self.presentError(error, title: "Could not \(action.title.lowercased()) \(guest.name)")
                // State may still have moved even on failure — re-read rather than guess.
                self.coordinator.refresh(instanceID)
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
        if obj.object as AnyObject === searchField { refreshTree() }
    }

    private func guestRowKey(instanceID: UUID, guest: PVEGuest) -> String { "\(instanceID)|\(guest.id)" }

    private func instanceRow(for instance: PVEInstanceSnapshot) -> PVEFleetInstanceRow {
        if let existing = instanceRowCache[instance.id] {
            existing.snapshot = instance
            return existing
        }
        let row = PVEFleetInstanceRow(snapshot: instance)
        instanceRowCache[instance.id] = row
        return row
    }

    private func guestRow(for guest: PVEGuest, instanceID: UUID) -> PVEFleetGuestRow {
        let key = guestRowKey(instanceID: instanceID, guest: guest)
        if let existing = guestRowCache[key] {
            existing.guest = guest
            return existing
        }
        let row = PVEFleetGuestRow(instanceID: instanceID, guest: guest)
        guestRowCache[key] = row
        return row
    }

    private func guestMatches(_ guest: PVEGuest, _ needle: String) -> Bool {
        guest.name.lowercased().contains(needle)
            || String(guest.vmid).contains(needle)
            || guest.node.lowercased().contains(needle)
    }

    /// Rebuilds the visible rows from `coordinator.state`, filtered by the search
    /// field. An instance is kept when its own name matches or any guest of its does;
    /// a kept instance shows only its matching guests, and is auto-expanded so the
    /// match isn't hidden under a collapsed disclosure triangle.
    private func refreshTree() {
        let needle = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var newVisibleInstances: [PVEFleetInstanceRow] = []
        var newVisibleGuestRows: [UUID: [PVEFleetGuestRow]] = [:]
        var liveInstanceIDs: Set<UUID> = []
        var liveGuestKeys: Set<String> = []

        for instance in coordinator.state.instances {
            liveInstanceIDs.insert(instance.id)
            let row = instanceRow(for: instance)
            let allGuestRows = instance.state.guests.map { guest -> PVEFleetGuestRow in
                liveGuestKeys.insert(guestRowKey(instanceID: instance.id, guest: guest))
                return guestRow(for: guest, instanceID: instance.id)
            }

            if needle.isEmpty {
                newVisibleInstances.append(row)
                newVisibleGuestRows[instance.id] = allGuestRows
                continue
            }

            let nameMatches = instance.profile.displayName.lowercased().contains(needle)
            let matchingGuestRows = allGuestRows.filter { guestMatches($0.guest, needle) }
            guard nameMatches || matchingGuestRows.isEmpty == false else { continue }
            newVisibleInstances.append(row)
            newVisibleGuestRows[instance.id] = matchingGuestRows
        }

        // Drop cache entries for servers/guests no longer in the fleet so a later id
        // reusing the same UUID (or vmid, on another node) can't inherit a stale row.
        instanceRowCache = instanceRowCache.filter { liveInstanceIDs.contains($0.key) }
        guestRowCache = guestRowCache.filter { liveGuestKeys.contains($0.key) }
        // Same reason: a removed server's diagnosis would otherwise be rendered as the
        // subtitle of whatever later takes its id, and its `diagnosedInstances` entry
        // would suppress the new server's own diagnosis.
        emptyListHints = emptyListHints.filter { liveInstanceIDs.contains($0.key) }
        diagnosedInstances = diagnosedInstances.intersection(liveInstanceIDs)

        let previouslyKnown = knownInstanceIDs
        knownInstanceIDs = liveInstanceIDs
        visibleInstanceRows = newVisibleInstances
        visibleGuestRowsByInstance = newVisibleGuestRows

        outlineView.reloadData()

        for row in newVisibleInstances where needle.isEmpty == false || previouslyKnown.contains(row.id) == false {
            outlineView.expandItem(row)
        }

        updateActionAvailability()
        rebuildFooterPowerMenu()
    }

    private func updateActionAvailability() {
        refreshButton.isEnabled = coordinator.state.instances.isEmpty == false
        updateOpenButton()
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return visibleInstanceRows.count }
        guard let row = item as? PVEFleetInstanceRow else { return 0 }
        return visibleGuestRowsByInstance[row.id]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return visibleInstanceRows[index] }
        guard let row = item as? PVEFleetInstanceRow else { return NSNull() }
        return visibleGuestRowsByInstance[row.id]?[index] ?? NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is PVEFleetInstanceRow
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let instanceRow = item as? PVEFleetInstanceRow, emptyListHints[instanceRow.id] != nil {
            return 38
        }
        return 22
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        if let instanceRow = item as? PVEFleetInstanceRow {
            guard identifier == "name" else { return nil }
            return instanceCellView(for: instanceRow)
        }
        guard let guestRow = item as? PVEFleetGuestRow else { return nil }
        return guestCellView(for: guestRow, columnIdentifier: identifier)
    }

    private func stateSuffix(_ state: PVEInstanceState) -> String? {
        switch state {
        case .signedOut:
            return nil
        case .signingIn:
            return "signing in…"
        case .failed(let error):
            return truncated(sanitized(error.description))
        case .signedIn(let guests):
            return "\(guests.count) guest\(guests.count == 1 ? "" : "s")"
        }
    }

    private func instanceCellView(for row: PVEFleetInstanceRow) -> NSView {
        let state = row.snapshot.state
        let title = stateSuffix(state).map { "\(row.snapshot.profile.displayName) — \($0)" } ?? row.snapshot.profile.displayName

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = state.isFailed ? .systemRed : .labelColor
        stack.addArrangedSubview(titleField)

        if let hint = emptyListHints[row.id] {
            let subtitleField = NSTextField(labelWithString: truncated(sanitized(hint)))
            subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitleField.textColor = .secondaryLabelColor
            subtitleField.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(subtitleField)
        }
        return stack
    }

    private func guestCellView(for row: PVEFleetGuestRow, columnIdentifier: String) -> NSView {
        let guest = row.guest
        let text: String
        switch columnIdentifier {
        case "name":   text = guest.name
        case "vmid":   text = String(guest.vmid)
        case "node":   text = guest.node
        default:       text = guest.status
        }

        let identifier = NSUserInterfaceItemIdentifier(columnIdentifier)
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byTruncatingTail
                return field
            }()
        cell.stringValue = text
        // Stopped guests have no SPICE console to open; dim the whole row so that is
        // obvious before the user double-clicks one.
        cell.textColor = guest.isRunning ? .labelColor : .tertiaryLabelColor
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateActionAvailability()
        rebuildFooterPowerMenu()
    }

    private func updateOpenButton() {
        openButton.isEnabled = selectedGuest()?.isRunning ?? false
    }

    private func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncated(_ text: String, limit: Int = 100) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit) + "…"
    }

    // MARK: - Status

    private func setBusy(_ busy: Bool, message: String?) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        connectButton.isEnabled = !busy
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
