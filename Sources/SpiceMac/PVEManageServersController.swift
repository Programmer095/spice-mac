// SPDX-License-Identifier: MIT
import AppKit
import PVEClient

/// Edits the whole fleet in one sheet: a server list on the left, the credential form
/// on the right. Several servers cannot be edited in the single inline form the
/// connect window used, so this is where that editing now happens.
final class PVEManageServersController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    /// Called with the saved fleet once the sheet is dismissed via Done.
    var onProfilesChanged: (([PVEServerProfile]) -> Void)?

    private let window: NSWindow
    private let tableView = NSTableView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    // Same field construction as PVEConnectWindowController.buildUI(): same
    // placeholders, same realm popup, same Remember in Keychain checkbox, so the two
    // surfaces cannot validate a profile differently. The label field has no
    // counterpart there — the connect window only ever edits a single unlabeled slot.
    private let labelField = NSTextField()
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

    private var tokenRows: [NSGridRow] = []
    private var passwordRows: [NSGridRow] = []

    private var profiles: [PVEServerProfile] = []
    /// The secret in each field, keyed by profile id, kept in step with `profiles` as
    /// the selection moves between rows.
    private var editedSecrets: [UUID: String] = [:]
    /// What was actually in the Keychain when the sheet opened. Only a real change
    /// from this is worth a write — rewriting an identical secret costs a second
    /// Keychain authorization prompt for no benefit.
    private var loadedSecrets: [UUID: String] = [:]
    /// Rows whose secret has actually been read. Reading is deferred to the moment a
    /// row is selected: with an ad-hoc signed build every read is its own system
    /// authorization dialog, and reading the whole fleet up front is N of them before
    /// the sheet even draws, none of them queued or labelled.
    private var secretsLoadedFor: Set<UUID> = []
    /// Each profile exactly as the sheet opened it. Editing the host, port or token ID
    /// moves the Keychain account and the certificate pin, so both have to be located
    /// and migrated from what the profile *was*, not from what the fields now say.
    private var originalProfiles: [UUID: PVEServerProfile] = [:]
    /// Profiles removed from `profiles` during this sheet session. Their Keychain
    /// items are only deleted on Done — never on Cancel, and never for a profile that
    /// merely had its remember-secret toggle flipped.
    private var removedProfiles: [PVEServerProfile] = []
    private var selectedIndex: Int?

    // MARK: - Lifecycle

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                          styleMask: [.titled, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Manage Servers"
        window.minSize = NSSize(width: 560, height: 360)
        super.init()
        window.delegate = self
        buildUI()
    }

    func present(over parent: NSWindow?) {
        profiles = PVEProfileStore.shared.profiles
        removedProfiles = []
        loadedSecrets = [:]
        editedSecrets = [:]
        secretsLoadedFor = []
        originalProfiles = [:]
        for profile in profiles { originalProfiles[profile.id] = profile }
        // The fields still show the last session's row; without this the first
        // selectRow banks them into whatever profile now sits at that index.
        selectedIndex = nil

        tableView.reloadData()
        selectRow(profiles.isEmpty ? nil : 0)

        if let parent, parent.isVisible {
            parent.beginSheet(window, completionHandler: nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Building

    private func buildUI() {
        for field in [labelField, hostField, portField, tokenIDField, usernameField] {
            field.isEditable = true
            field.isBordered = true
            field.bezelStyle = .roundedBezel
        }
        labelField.placeholderString = "Nickname (e.g. Home, Rack B)"
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

        rememberCheckbox.state = .on

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Label:"), labelField],
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
        for field in [labelField, hostField, tokenIDField, tokenSecretField, usernameField, passwordField] {
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 0, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 2, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 3, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 4, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 6, length: 1))
        tokenRows = [grid.row(at: 3), grid.row(at: 4)]
        passwordRows = [grid.row(at: 5), grid.row(at: 6)]

        configureTable()
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        addButton.target = self
        addButton.action = #selector(addServer(_:))
        addButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeServer(_:))
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false

        let listButtons = NSStackView(views: [addButton, removeButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 8

        let leftColumn = NSStackView(views: [scrollView, listButtons])
        leftColumn.orientation = .vertical
        leftColumn.spacing = 8
        leftColumn.alignment = .leading
        scrollView.widthAnchor.constraint(equalToConstant: 200).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded

        let footer = NSStackView(views: [NSView(), cancelButton, doneButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        let form = NSStackView(views: [grid, NSView()])
        form.orientation = .vertical
        form.alignment = .leading
        form.setHuggingPriority(.defaultLow, for: .vertical)

        let body = NSStackView(views: [leftColumn, form])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 16
        form.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

        let root = NSStackView(views: [body, footer])
        root.orientation = .vertical
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        guard let contentView = window.contentView else { return }
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])

        authKindChanged()
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        column.title = "Server"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
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

    // MARK: - Row selection

    /// Fields are shared across rows, so switching rows must bank whatever is on
    /// screen into `profiles`/`editedSecrets` before the newly selected row overwrites
    /// them — otherwise an edit is silently lost the moment focus moves elsewhere.
    private func captureFieldsIntoSelection() {
        guard let index = selectedIndex, profiles.indices.contains(index) else { return }
        var profile = profiles[index]
        profile.label = labelField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.port = Int(portField.stringValue) ?? 8006
        profile.authKind = authSelector.selectedSegment == 0 ? .apiToken : .password
        profile.tokenID = tokenIDField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.realm = realmPopUp.titleOfSelectedItem ?? "pam"
        profile.rememberSecret = rememberCheckbox.state == .on
        profiles[index] = profile
        editedSecrets[profile.id] = authSelector.selectedSegment == 0
            ? tokenSecretField.stringValue : passwordField.stringValue
    }

    private func loadSelectionIntoFields() {
        guard let index = selectedIndex, profiles.indices.contains(index) else {
            labelField.stringValue = ""
            hostField.stringValue = ""
            portField.stringValue = ""
            tokenIDField.stringValue = ""
            tokenSecretField.stringValue = ""
            usernameField.stringValue = ""
            passwordField.stringValue = ""
            realmPopUp.selectItem(withTitle: "pam")
            rememberCheckbox.state = .on
            authSelector.selectedSegment = 0
            authKindChanged()
            setFieldsEnabled(false)
            return
        }
        setFieldsEnabled(true)
        let profile = profiles[index]
        loadSecretIfNeeded(profile.id)
        labelField.stringValue = profile.label
        hostField.stringValue = profile.host
        portField.stringValue = String(profile.port)
        tokenIDField.stringValue = profile.tokenID
        usernameField.stringValue = profile.username
        realmPopUp.selectItem(withTitle: profile.realm)
        rememberCheckbox.state = profile.rememberSecret ? .on : .off
        authSelector.selectedSegment = profile.authKind == .apiToken ? 0 : 1
        let secret = editedSecrets[profile.id] ?? ""
        tokenSecretField.stringValue = profile.authKind == .apiToken ? secret : ""
        passwordField.stringValue = profile.authKind == .password ? secret : ""
        authKindChanged()
    }

    /// Reads one row's stored secret, once. Looked up under the account the profile had
    /// when the sheet opened, so an unsaved edit to the host or token ID cannot send the
    /// lookup somewhere else. A row added in this session has nothing to read.
    private func loadSecretIfNeeded(_ id: UUID) {
        guard secretsLoadedFor.contains(id) == false else { return }
        secretsLoadedFor.insert(id)
        guard let original = originalProfiles[id] else { return }
        let stored = PVEProfileStore.shared.secret(for: original)
        loadedSecrets[id] = stored
        editedSecrets[id] = stored ?? ""
    }

    private func setFieldsEnabled(_ enabled: Bool) {
        for field in [labelField, hostField, portField, tokenIDField, tokenSecretField,
                      usernameField, passwordField] as [NSControl] {
            field.isEnabled = enabled
        }
        authSelector.isEnabled = enabled
        realmPopUp.isEnabled = enabled
        rememberCheckbox.isEnabled = enabled
    }

    private func selectRow(_ index: Int?) {
        captureFieldsIntoSelection()
        selectedIndex = index
        if let index {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        loadSelectionIntoFields()
        removeButton.isEnabled = index != nil
    }

    @objc private func authKindChanged() {
        let usingToken = authSelector.selectedSegment == 0
        for row in tokenRows { row.isHidden = !usingToken }
        for row in passwordRows { row.isHidden = usingToken }
    }

    // MARK: - Actions

    @objc private func addServer(_ sender: Any?) {
        captureFieldsIntoSelection()
        let profile = PVEServerProfile()
        profiles.append(profile)
        editedSecrets[profile.id] = ""
        tableView.reloadData()
        selectRow(profiles.count - 1)
        window.makeFirstResponder(hostField)
    }

    @objc private func removeServer(_ sender: Any?) {
        guard let index = selectedIndex, profiles.indices.contains(index) else { return }
        let removed = profiles.remove(at: index)
        removedProfiles.append(removed)
        editedSecrets.removeValue(forKey: removed.id)
        tableView.reloadData()
        let next = profiles.isEmpty ? nil : min(index, profiles.count - 1)
        selectedIndex = nil // avoid banking the just-removed row's fields
        selectRow(next)
    }

    /// An Add nobody typed into. Stored, it becomes a permanent tree row that `signIn`
    /// refuses and that does nothing but take up space. Anything actually entered —
    /// even a lone host, or just the secret — makes the row differ from the blank
    /// template and keeps it, so a half-finished real server is never discarded.
    private func isUntouchedNewServer(_ profile: PVEServerProfile) -> Bool {
        var blank = PVEServerProfile()
        blank.id = profile.id
        return profile == blank && (editedSecrets[profile.id] ?? "").isEmpty
    }

    @objc private func done(_ sender: Any?) {
        captureFieldsIntoSelection()

        let saved = profiles.filter { isUntouchedNewServer($0) == false }
        let discarded = profiles.filter { isUntouchedNewServer($0) }
        // What the fleet still claims after the edit. Every delete below is checked
        // against these: removing a server and re-adding the same credentials in one
        // session must not delete the item that re-add just earned.
        let survivingAccounts = Set(saved.map(\.keychainAccount))
        let survivingHosts = Set(saved.map { $0.host.lowercased() })

        // Deletions run before any write, so an account or host that leaves and comes
        // back in the same session ends up written rather than written-then-deleted.
        for gone in removedProfiles + discarded {
            if survivingAccounts.contains(gone.keychainAccount) == false {
                PVEKeychain.delete(account: gone.keychainAccount)
            }
            if gone.host.isEmpty == false, survivingHosts.contains(gone.host.lowercased()) == false {
                PVEProfileStore.shared.forgetPin(forHost: gone.host)
            }
        }

        for profile in saved {
            let original = originalProfiles[profile.id]
            // An untouched row cannot have moved its account, changed its secret or
            // flipped its toggle, so it needs no Keychain traffic at all.
            if let original, original == profile, secretsLoadedFor.contains(profile.id) == false { continue }

            let accountMoved = original != nil && original?.keychainAccount != profile.keychainAccount
            if let previousAccount = original?.keychainAccount, accountMoved,
               survivingAccounts.contains(previousAccount) == false {
                PVEKeychain.delete(account: previousAccount)
            }
            if let previousHost = original?.host, previousHost.isEmpty == false,
               previousHost.caseInsensitiveCompare(profile.host) != .orderedSame,
               survivingHosts.contains(previousHost.lowercased()) == false {
                PVEProfileStore.shared.forgetPin(forHost: previousHost)
            }

            guard profile.rememberSecret else {
                PVEKeychain.delete(account: profile.keychainAccount)
                continue
            }
            let current = editedSecrets[profile.id] ?? ""
            // Rewriting an identical secret costs a second Keychain authorization
            // prompt — but a moved account has nothing stored under its new name yet,
            // so it must be written even when the text has not changed.
            guard accountMoved || current != (loadedSecrets[profile.id] ?? "") else { continue }
            PVEProfileStore.shared.setSecret(current, for: profile)
        }

        removedProfiles = []
        profiles = saved

        PVEProfileStore.shared.profiles = saved
        onProfilesChanged?(saved)

        dismiss()
    }

    /// Discards whatever is on screen and in `profiles`/`removedProfiles` — no write to
    /// `PVEProfileStore` and no Keychain access, so an accidental Add or a mistyped
    /// edit costs nothing.
    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    private func dismiss() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < profiles.count else { return nil }
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("server"), owner: self) as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = NSUserInterfaceItemIdentifier("server")
                field.lineBreakMode = .byTruncatingTail
                return field
            }()
        let profile = profiles[row]
        cell.stringValue = profile.displayName.isEmpty ? "New Server" : profile.displayName
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row != selectedIndex else { return }
        captureFieldsIntoSelection()
        selectedIndex = row >= 0 ? row : nil
        loadSelectionIntoFields()
        removeButton.isEnabled = selectedIndex != nil
    }
}
