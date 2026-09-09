// SPDX-License-Identifier: MIT
import AppKit
import PVEClient

/// The credentials form for one Proxmox server.
///
/// Two surfaces edit a server — the connect window's inline form for the first one, and
/// the Manage Servers sheet for the rest — and they had grown two copies of the same
/// fields, the same port formatter, the same auth-kind row hiding and the same
/// field↔profile mapping. The copies had already drifted: the sheet never validated what
/// it saved, so a half-filled row went into the fleet and then sat signed-out, because
/// `signIn` returns silently on an incomplete profile.
///
/// One definition here, parameterised by the one real difference: the sheet names its
/// servers, the connect form does not (it only ever edits the first slot, whose label is
/// preserved from what is stored).
@MainActor
final class PVEServerForm {

    /// Called when the user switches between token and password auth, after the rows
    /// have been re-hidden — owners use it to react without duplicating the rule.
    var onAuthKindChanged: (() -> Void)?

    let grid = NSGridView()

    let labelField = NSTextField()
    let hostField = NSTextField()
    let portField = NSTextField()
    let authSelector = NSSegmentedControl(labels: ["API Token", "Username & Password"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    let tokenIDField = NSTextField()
    let tokenSecretField = NSSecureTextField()
    let usernameField = NSTextField()
    let realmPopUp = NSPopUpButton()
    let passwordField = NSSecureTextField()
    let rememberCheckbox = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)

    /// Rows are looked up from the grid as it is built rather than by hard-coded index —
    /// the label row shifts everything below it, and two hand-maintained index lists is
    /// precisely the drift this type exists to remove.
    private(set) var tokenRows: [NSGridRow] = []
    private(set) var passwordRows: [NSGridRow] = []
    private(set) var allRows: [NSGridRow] = []

    private let includesLabel: Bool
    private let actionProxy = ActionProxy()

    init(includesLabel: Bool) {
        self.includesLabel = includesLabel
        buildFields()
        buildGrid()
        authKindChanged()
    }

    // MARK: - Construction

    private func buildFields() {
        for field in [labelField, hostField, portField, tokenIDField, usernameField] {
            field.isEditable = true
            field.isBordered = true
            field.bezelStyle = .roundedBezel
        }
        labelField.placeholderString = "Nickname (e.g. Home, Rack B)"
        hostField.placeholderString = "proxmox.example.com"
        portField.placeholderString = "8006"
        portField.formatter = Self.portFormatter()
        tokenIDField.placeholderString = "root@pam!spicemac"
        tokenSecretField.placeholderString = "token secret (UUID)"
        usernameField.placeholderString = "root"
        passwordField.placeholderString = "password"
        realmPopUp.addItems(withTitles: ["pam", "pve"])

        actionProxy.onAuthKindChanged = { [weak self] in self?.authKindChanged() }
        authSelector.target = actionProxy
        authSelector.action = #selector(ActionProxy.authKindChanged)
        authSelector.selectedSegment = 0
        rememberCheckbox.state = .on
    }

    private func buildGrid() {
        var rows: [[NSView]] = []
        if includesLabel {
            rows.append([NSTextField(labelWithString: "Label:"), labelField])
        }
        rows.append([NSTextField(labelWithString: "Server:"), hostField,
                     NSTextField(labelWithString: "Port:"), portField])
        rows.append([NSTextField(labelWithString: "Sign in with:"), authSelector])
        rows.append([NSTextField(labelWithString: "Token ID:"), tokenIDField])
        rows.append([NSTextField(labelWithString: "Secret:"), tokenSecretField])
        rows.append([NSTextField(labelWithString: "Username:"), usernameField,
                     NSTextField(labelWithString: "Realm:"), realmPopUp])
        rows.append([NSTextField(labelWithString: "Password:"), passwordField])
        rows.append([NSGridCell.emptyContentView, rememberCheckbox])

        for row in rows { grid.addRow(with: row) }
        // NSGridView(views:) seeds a leading empty row when built empty, so drop it.
        if grid.numberOfRows > rows.count { grid.removeRow(at: 0) }

        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        for field in [labelField, hostField, tokenIDField, tokenSecretField, usernameField, passwordField] {
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // High, never lower: dropping this collapses the window to a sliver, since
            // nothing else in the row resists being squeezed.
            field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        // Single-control rows span the whole width instead of sitting in column 1.
        let offset = includesLabel ? 1 : 0
        if includesLabel { merge(row: 0) }
        for row in [1, 2, 3, 5] { merge(row: row + offset) }

        tokenRows = [grid.row(at: 2 + offset), grid.row(at: 3 + offset)]
        passwordRows = [grid.row(at: 4 + offset), grid.row(at: 5 + offset)]
        allRows = (0..<grid.numberOfRows).map { grid.row(at: $0) }
    }

    private func merge(row: Int) {
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3),
                        verticalRange: NSRange(location: row, length: 1))
    }

    /// A port is a whole number in range; anything else is not worth sending.
    static func portFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }

    // MARK: - Auth kind

    var authKind: PVEServerProfile.AuthKind {
        authSelector.selectedSegment == 0 ? .apiToken : .password
    }

    @objc private func authKindChanged() {
        let usingToken = authKind == .apiToken
        for row in tokenRows { row.isHidden = !usingToken }
        for row in passwordRows { row.isHidden = usingToken }
        onAuthKindChanged?()
    }

    /// Re-applies the auth-kind rule. Owners call this after unhiding the form, since
    /// showing every row would otherwise reveal both credential styles at once.
    func refreshAuthKindRows() { authKindChanged() }

    // MARK: - Reading and writing

    /// The secret currently typed, from whichever field the auth kind is using.
    var secret: String {
        authKind == .apiToken ? tokenSecretField.stringValue : passwordField.stringValue
    }

    /// `base` carries forward everything the form does not edit — the profile's `id`,
    /// and its `label` when this form has no label field.
    func profile(basedOn base: PVEServerProfile) -> PVEServerProfile {
        var profile = base
        if includesLabel { profile.label = labelField.stringValue.trimmingCharacters(in: .whitespaces) }
        profile.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.port = Int(portField.stringValue) ?? 8006
        profile.authKind = authKind
        profile.tokenID = tokenIDField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        profile.realm = realmPopUp.titleOfSelectedItem ?? "pam"
        profile.rememberSecret = rememberCheckbox.state == .on
        return profile
    }

    /// Puts `profile` on screen. `secret` goes into whichever field its auth kind uses,
    /// and the other is cleared — leaving a previous server's secret in the field it no
    /// longer belongs to is how one server's credentials end up saved against another.
    func apply(_ profile: PVEServerProfile, secret: String) {
        labelField.stringValue = profile.label
        hostField.stringValue = profile.host
        portField.stringValue = String(profile.port)
        tokenIDField.stringValue = profile.tokenID
        usernameField.stringValue = profile.username
        realmPopUp.selectItem(withTitle: profile.realm)
        rememberCheckbox.state = profile.rememberSecret ? .on : .off
        authSelector.selectedSegment = profile.authKind == .apiToken ? 0 : 1
        tokenSecretField.stringValue = profile.authKind == .apiToken ? secret : ""
        passwordField.stringValue = profile.authKind == .password ? secret : ""
        authKindChanged()
    }

    /// Blanks every field — the sheet's "no row selected" state.
    func clear() {
        apply(PVEServerProfile(), secret: "")
    }

    func setEnabled(_ enabled: Bool) {
        for control in [labelField, hostField, portField, tokenIDField, tokenSecretField,
                        usernameField, passwordField, authSelector, realmPopUp,
                        rememberCheckbox] as [NSControl] {
            control.isEnabled = enabled
        }
    }

    /// Folds the whole form away, or brings it back with the auth-kind rule reapplied.
    func setRowsHidden(_ hidden: Bool) {
        for row in allRows { row.isHidden = hidden }
        if hidden == false { authKindChanged() }
    }
}

/// `NSSegmentedControl` needs an ObjC target, and `PVEServerForm` is not an `NSObject`.
private final class ActionProxy: NSObject {
    var onAuthKindChanged: (() -> Void)?
    @objc func authKindChanged() { onAuthKindChanged?() }
}
