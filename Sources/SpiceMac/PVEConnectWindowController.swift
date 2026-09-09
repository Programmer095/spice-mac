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

    private let form = PVEServerForm(includesLabel: false)

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

    private var formGrid: NSGridView { form.grid }
    private var isSignedIn = false

    private static let log = Logger(subsystem: "org.spicemac.SpiceMac", category: "proxmox")

    /// The secret last read from the Keychain, per server. Rewriting an unchanged secret
    /// costs a second authorization prompt for no benefit, so persist only real changes.
    private var loadedSecrets: [UUID: String] = [:]
    /// The stored profile the fields were last populated from, so a fleet change can
    /// be told apart from one this form already reflects.
    private var formProfile: PVEServerProfile?
    /// The server the credentials form edits: whichever the tree has selected, falling
    /// back to the first configured one. The form used to be nailed to slot zero, which
    /// left every other server in a fleet with no way to type its credentials at all.
    private var formInstanceID: UUID?
    /// Unsaved edits, per server, so moving the selection does not throw away what was
    /// typed. Nothing here reaches disk: the Keychain is only written once a sign-in
    /// with these credentials actually succeeds.
    private var formDrafts: [UUID: PVEServerProfile] = [:]
    private var formDraftSecrets: [UUID: String] = [:]
    /// Set by `connect()` while a form-driven sign-in is in flight, so the coordinator's
    /// eventual success/failure can decide whether to persist — a mistyped secret must
    /// never overwrite a working one in the Keychain.
    private var pendingFormPersist: (id: UUID, profile: PVEServerProfile, secret: String)?

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
    private let session: PVEFleetSession
    private var coordinator: PVEFleetCoordinator { session.coordinator }
    private var fleetObservation: PVEFleetSession.Token?

    // MARK: - Lifecycle

    /// The session is a parameter so `UICheck` can drive a fleet whose guests arrive
    /// without a server. Everything in the app passes `.shared`.
    init(session: PVEFleetSession) {
        self.session = session
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
        // Start on the first configured server; the tree's selection moves it from there.
        formInstanceID = PVEProfileStore.shared.profiles.first?.id
        loadProfile()
        fleetObservation = session.observe { [weak self] state in self?.handleFleetStateChanged(state) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Forwarded from the Manage Servers sheet.
    func setProfiles(_ profiles: [PVEServerProfile]) {
        session.setProfiles(profiles)
        // Drop drafts for servers the sheet removed, or they would be re-applied to
        // whatever later reuses the id.
        let live = Set(profiles.map(\.id))
        formDrafts = formDrafts.filter { live.contains($0.key) }
        formDraftSecrets = formDraftSecrets.filter { live.contains($0.key) }
        loadedSecrets = loadedSecrets.filter { live.contains($0.key) }
        // Keep editing the same server when it survived the edit. The fields still hold
        // pre-sheet values, so reload them or the next Sign In writes them back over
        // whatever the sheet just changed.
        let target = formInstanceID.flatMap { live.contains($0) ? $0 : nil } ?? profiles.first?.id
        retargetForm(to: target, bankingCurrentEdits: false)
    }

    /// Show the window, then bring the tree up to date: refresh the instance behind
    /// whatever is selected, or sign in everywhere if nothing is signed in yet. No
    /// timer — this is the one point a reveal costs a request.
    func present(autoConnect: Bool = true) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard autoConnect else { return }
        connectOnReveal()
    }

    /// What a reveal costs: one refresh for the server being looked at, and a sign-in
    /// for every server that is not connected.
    ///
    /// These are two different jobs and it used to do only one of them. A selection meant
    /// refresh-and-nothing-else, and without one it signed in the fleet *only while
    /// nothing was signed in yet* — so the moment one server came up, the rest could
    /// never join it. With several servers configured that left the fleet permanently
    /// part-connected, and the tree showed no reason why.
    ///
    /// Split out from `present` so it can be checked without putting a window on screen.
    func connectOnReveal() {
        if let id = currentSelectionInstanceID(), coordinator.state.instance(id)?.state.isSignedIn == true {
            coordinator.refresh(id)
        }
        coordinator.signInAll()
    }

    // MARK: - Building

    private func buildUI() {
        let grid = form.grid

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

    // MARK: - Profile

    private func loadProfile() {
        let stored = fleetProfile(formInstanceID)
        formProfile = stored
        let profile = formDrafts[formInstanceID ?? UUID()] ?? stored ?? PVEServerProfile()

        // Read before the fields are populated: `apply` clears whichever secret field the
        // auth kind does not use, so a server with nothing stored cannot inherit the last
        // one's secret.
        let secret: String
        if let id = formInstanceID, let draft = formDraftSecrets[id] {
            secret = draft
        } else if let stored, stored.rememberSecret, stored.isComplete,
                  let keychain = PVEProfileStore.shared.secret(for: stored) {
            if let id = formInstanceID { loadedSecrets[id] = keychain }
            secret = keychain
        } else {
            secret = ""
        }
        form.apply(profile, secret: secret)
        // `apply` re-runs the auth-kind rule, which unhides the credential rows. Editing
        // servers in the sheet reloads this form, and that must not pop the credentials
        // back open over a signed-in session.
        form.setRowsHidden(isSignedIn)
    }

    /// The fleet's view of a server, not the store's. The coordinator is what the tree
    /// renders and what a Manage Servers save updates first, so reading it keeps the
    /// form and the row beside it describing the same thing.
    private func fleetProfile(_ id: UUID?) -> PVEServerProfile? {
        guard let id else { return nil }
        return coordinator.state.instance(id)?.profile
    }

    /// Banks whatever is on screen against the server it belongs to, so moving the
    /// selection mid-edit does not silently discard it — the same problem the Manage
    /// Servers sheet solves when its shared fields move between rows.
    private func bankFormEdits() {
        guard let id = formInstanceID else { return }
        formDrafts[id] = form.profile(basedOn: fleetProfile(id) ?? PVEServerProfile())
        formDraftSecrets[id] = form.secret
    }

    /// Points the form at another server. `bankingCurrentEdits` is false only when the
    /// fields no longer describe the server they were loaded from — after a Manage
    /// Servers save, where banking would resurrect pre-sheet values.
    private func retargetForm(to id: UUID?, bankingCurrentEdits: Bool = true) {
        guard id != formInstanceID || bankingCurrentEdits == false else { return }
        if bankingCurrentEdits { bankFormEdits() }
        formInstanceID = id
        loadProfile()
        updateFormState()
    }

    /// Starts from the stored first profile (if any) so its `id` and `label` survive
    /// a save — this form only edits that one slot, it must not fork a new identity
    /// for it on every Sign In.
    private func currentProfile() -> PVEServerProfile {
        form.profile(basedOn: fleetProfile(formInstanceID) ?? PVEServerProfile())
    }

    /// Once signed in the credentials are just clutter above the thing the user came
    /// for, so fold them away and give the space to the guest tree.
    private func setSignedIn(_ signedIn: Bool) {
        isSignedIn = signedIn
        form.setRowsHidden(signedIn)
        connectButton.title = signedIn ? "Sign Out" : "Sign In"
        openVVButton.isHidden = signedIn
    }

    /// Reflects the primary profile's fleet state onto the credentials form. A
    /// sign-in failure shows on the form (this is the one server the user is looking
    /// straight at) — every other server's failure shows on its own tree row instead.
    private func updateFormState() {
        guard let id = formInstanceID, let instance = coordinator.state.instance(id) else {
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
            setBusy(true, message: "Signing in to \(instance.profile.displayName)…")
        case .signedIn:
            setBusy(false, message: nil)
            setSignedIn(true)
            showStatus("Signed in to \(instance.profile.displayName) as \(instance.profile.credentials(secret: "").displayUser).",
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
            if let id = formInstanceID { coordinator.signOut(id) }
            return
        }
        let profile = currentProfile()
        let secret = form.secret

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

        formInstanceID = profile.id
        pendingFormPersist = (id: profile.id, profile: profile, secret: secret)
        coordinator.setProfiles(updatedProfiles(with: profile))
        coordinator.signIn(profile.id, usingSecret: secret)
    }

    /// The stored profile list with `profile` in its own slot, without writing it to
    /// disk — used to tell the coordinator about an edit before it's confirmed to work.
    /// Matched by id: the form no longer always edits the first server, and writing to
    /// slot zero would overwrite a different one.
    private func updatedProfiles(with profile: PVEServerProfile) -> [PVEServerProfile] {
        var profiles = PVEProfileStore.shared.profiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        return profiles
    }

    private func persist(profile: PVEServerProfile, secret: String) {
        let previous = PVEProfileStore.shared.profiles.first { $0.id == profile.id }
        let updated = updatedProfiles(with: profile)
        PVEProfileStore.shared.profiles = updated
        formProfile = updated.first { $0.id == profile.id }
        // The draft is now what is stored, so stop shadowing it.
        formDrafts[profile.id] = nil
        formDraftSecrets[profile.id] = nil

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
            loadedSecrets[profile.id] = nil
            return
        }
        // Rewriting an unchanged secret costs a second Keychain authorization prompt —
        // but a moved account has nothing stored under its new name yet.
        guard accountMoved || secret != loadedSecrets[profile.id] else { return }
        PVEProfileStore.shared.setSecret(secret, for: profile)
        loadedSecrets[profile.id] = secret
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
        setSignedIn(signedIn)
        return probePanelLayoutAsIs(contentWidth: contentWidth)
    }

    /// Test seams for `UICheck`: point the form at a server and read back what it shows.
    func probeRetargetForm(to id: UUID?) { retargetForm(to: id) }
    var probeFormInstanceID: UUID? { formInstanceID }
    var probeFormHost: String { form.hostField.stringValue }
    var probeFormSecret: String { form.secret }
    func probeTypeIntoForm(host: String, secret: String) {
        form.hostField.stringValue = host
        form.tokenSecretField.stringValue = secret
    }

    /// Test seam: reload the form from what is stored, the way a Manage Servers save
    /// does. On its own, without the fleet change that would also re-evaluate whether
    /// the server is still signed in.
    func probeReloadForm() { loadProfile() }

    /// Measures without touching the credential state — so a check can assert on what
    /// some *other* call left behind, rather than on state the probe just re-imposed.
    func probePanelLayoutAsIs(contentWidth: CGFloat) -> PVEPanelLayout {
        guard let window, let contentView = window.contentView else { return .zero }
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
            Self.log.info("fleet \(instance.profile.displayName, privacy: .public) -> \(Self.describe(instance.state), privacy: .public)")
        }
        refreshTree()
        resolvePendingPrimaryPersist(state)
        updateFormState()
        diagnoseEmptyInstancesIfNeeded(state)
    }

    /// Commits the form's typed secret to the Keychain only once the coordinator
    /// confirms it actually works; a failure leaves whatever was already stored alone.
    private func resolvePendingPrimaryPersist(_ state: PVEFleetState) {
        guard let pending = pendingFormPersist, let instance = state.instance(pending.id) else { return }
        switch instance.state {
        case .signedIn:
            persist(profile: pending.profile, secret: pending.secret)
            pendingFormPersist = nil
        case .failed:
            pendingFormPersist = nil
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
        // Selecting anything under a server points the form at it, so the credentials
        // above always belong to the row being looked at. Nothing selected keeps the
        // current target rather than blanking a form mid-edit.
        if let id = currentSelectionInstanceID() { retargetForm(to: id) }
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
