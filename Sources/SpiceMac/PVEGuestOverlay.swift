// SPDX-License-Identifier: MIT
import AppKit
import PVEClient

/// A guest picker that slides in from the left edge of a console window.
///
/// Deliberately not the connect tab's tree. That tab is where a fleet is *set up* —
/// credentials, adding and editing servers, per-instance sign-in. This is only the
/// selection step: which guest do I want to look at now. So it is a flat list across
/// every signed-in server rather than a tree to expand, it has no route to Manage
/// Servers, and it closes the moment it has answered the question.
///
/// Solid background, no `NSVisualEffectView`: the console underneath is an `MTKView`
/// rendering asynchronously, and blur over it lags and shows artifacts.
@MainActor
final class PVEGuestOverlay: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    /// Picked a guest. The client comes from the fleet, so the caller does not have to
    /// work out which server the guest belongs to.
    var onOpenGuest: ((PVEGuest, PVEClient) -> Void)?

    static let width: CGFloat = 300

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private let session: PVEFleetSession
    private var observation: PVEFleetSession.Token?
    private var matches: [PVEFleetGuestMatch] = []

    init(session: PVEFleetSession) {
        self.session = session
        super.init(frame: .zero)
        buildUI()
        observation = session.observe { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - UI

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Guests")
        title.font = .preferredFont(forTextStyle: .headline)

        searchField.placeholderString = "Filter"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("guest"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 38
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.allowsEmptySelection = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3

        for view in [title, searchField, scrollView, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            searchField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
        ])
    }

    // MARK: - Content

    /// Called when the panel is revealed: refresh whatever the fleet is showing, and put
    /// the caret in the filter so typing narrows straight away.
    func prepareForReveal() {
        reload()
        window?.makeFirstResponder(searchField)
    }

    private func reload() {
        let selected = selectedMatch()?.id
        matches = session.state.guests(matching: searchField.stringValue)
        tableView.reloadData()
        if let selected, let row = matches.firstIndex(where: { $0.id == selected }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateEmptyState()
    }

    /// Says which of the several empty cases this is. "No guests" over a fleet that has
    /// not signed in yet reads as a broken picker rather than one that is still working.
    private func updateEmptyState() {
        emptyLabel.isHidden = matches.isEmpty == false
        scrollView.isHidden = matches.isEmpty
        guard matches.isEmpty else { return }

        let instances = session.state.instances
        if instances.isEmpty {
            emptyLabel.stringValue = "No servers configured.\nAdd one in the Connect tab."
        } else if instances.contains(where: { if case .signingIn = $0.state { return true }; return false }) {
            emptyLabel.stringValue = "Signing in…"
        } else if instances.allSatisfy({ if case .failed = $0.state { return true }; return false }) {
            emptyLabel.stringValue = "No server is reachable.\nSee the Connect tab."
        } else if searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty == false {
            emptyLabel.stringValue = "No guest matches “\(searchField.stringValue)”."
        } else {
            emptyLabel.stringValue = "No guests.\nSign in from the Connect tab."
        }
    }

    /// What the picker is currently showing, for `UICheck`.
    var visibleMatches: [PVEFleetGuestMatch] { matches }
    var isEmptyStateVisible: Bool { emptyLabel.isHidden == false }
    var emptyStateText: String { emptyLabel.stringValue }
    func canSelectRow(_ row: Int) -> Bool { tableView(tableView, shouldSelectRow: row) }
    func setFilter(_ text: String) {
        searchField.stringValue = text
        reload()
    }

    private func selectedMatch() -> PVEFleetGuestMatch? {
        let row = tableView.selectedRow
        guard row >= 0, row < matches.count else { return nil }
        return matches[row]
    }

    // MARK: - Actions

    @objc private func openSelected() {
        guard let match = selectedMatch(),
              let client = session.coordinator.client(for: match.instance.id) else { return }
        onOpenGuest?(match.guest, client)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        reload()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:                                  // Return, keypad Enter
            openSelected()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < matches.count else { return nil }
        let match = matches[row]
        let identifier = NSUserInterfaceItemIdentifier("guestCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? PVEGuestOverlayCell)
            ?? PVEGuestOverlayCell(identifier: identifier)
        cell.configure(with: match, showsServer: session.state.instances.count > 1)
        return cell
    }

    /// A stopped guest has no console to open, so it is visible but not selectable —
    /// starting one is a management action and belongs in the Connect tab.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < matches.count else { return false }
        return matches[row].guest.status.lowercased() == "running"
    }
}

/// Two lines: the guest, then where it lives.
private final class PVEGuestOverlayCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.font = .preferredFont(forTextStyle: .body)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with match: PVEFleetGuestMatch, showsServer: Bool) {
        let running = match.guest.status.lowercased() == "running"
        name.stringValue = match.guest.name
        name.textColor = running ? .labelColor : .tertiaryLabelColor

        var parts = ["\(match.guest.vmid)", match.guest.node]
        if showsServer { parts.append(match.instance.profile.displayName) }
        if running == false { parts.append(match.guest.status) }
        detail.stringValue = parts.joined(separator: " · ")
    }
}
