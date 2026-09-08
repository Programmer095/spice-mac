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
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    // Same field construction as PVEConnectWindowController.buildUI(): same
    // placeholders, same realm popup, same Remember in Keychain checkbox, so the two
    // surfaces cannot validate a profile differently.
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
        loadedSecrets = [:]
        for profile in profiles {
            loadedSecrets[profile.id] = PVEProfileStore.shared.secret(for: profile)
        }
        editedSecrets = loadedSecrets

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

        rememberCheckbox.state = .on

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
        for field in [hostField, tokenIDField, tokenSecretField, usernameField, passwordField] {
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 1, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 2, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 3, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 5, length: 1))
        tokenRows = [grid.row(at: 2), grid.row(at: 3)]
        passwordRows = [grid.row(at: 4), grid.row(at: 5)]

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

        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded

        let footer = NSStackView(views: [NSView(), doneButton])
        footer.orientation = .horizontal

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

    private func setFieldsEnabled(_ enabled: Bool) {
        for field in [hostField, portField, tokenIDField, tokenSecretField,
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
        editedSecrets.removeValue(forKey: removed.id)
        tableView.reloadData()
        let next = profiles.isEmpty ? nil : min(index, profiles.count - 1)
        selectedIndex = nil // avoid banking the just-removed row's fields
        selectRow(next)
    }

    @objc private func done(_ sender: Any?) {
        captureFieldsIntoSelection()

        for profile in profiles {
            let loaded = loadedSecrets[profile.id]
            let current = editedSecrets[profile.id] ?? ""
            if profile.rememberSecret {
                guard current != (loaded ?? "") else { continue }
                PVEProfileStore.shared.setSecret(current, for: profile)
            } else if loaded != nil {
                PVEProfileStore.shared.setSecret("", for: profile)
            }
        }
        PVEProfileStore.shared.profiles = profiles
        onProfilesChanged?(profiles)

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
