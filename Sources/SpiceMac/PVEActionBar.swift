// SPDX-License-Identifier: MIT
import AppKit
import OSLog
import PVEClient

/// A strip of actions for the guest in the console it sits over.
///
/// An accelerator, never the only route: power also lives on the connect tab's context
/// menu, because a stopped guest has no console to act from and starting one is exactly
/// the case that would otherwise be unreachable.
///
/// Separate from the guest picker because the two are shaped differently — a list of
/// many guests wants height, a row of actions on one guest wants width — and because
/// this one is about the guest you are already looking at.
///
/// Solid background, no `NSVisualEffectView`: the console underneath is an `MTKView`
/// rendering asynchronously, and blur over it lags and shows artifacts.
@MainActor
final class PVEActionBar: NSView {

    /// Run a power action. The controller confirms destructive ones and follows the task.
    var onPowerAction: ((PVEPowerAction) -> Void)?
    /// Attach the given volume, or detach when nil.
    var onSetISO: ((String?) -> Void)?

    static let height: CGFloat = 44

    private let guest: PVEGuest
    private let client: PVEClient

    private let powerButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let isoButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let titleLabel = NSTextField(labelWithString: "")

    /// nil until the ACL has been read. The ISO control stays disabled and says it is
    /// still checking rather than claiming a grant it has not confirmed.
    private var canConfigureCDROM: Bool?
    private var availability: PVEISOAvailability = .noImages

    init(guest: PVEGuest, client: PVEClient) {
        self.guest = guest
        self.client = client
        super.init(frame: .zero)
        buildUI()
    }

    /// Starts the permission probe. Separate from `init` so constructing the bar does no
    /// I/O — which is what lets `UICheck` drive its states directly.
    func begin() {
        Task { await loadCDROMAvailability() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - UI

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 10

        titleLabel.stringValue = guest.name
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingTail

        powerButton.bezelStyle = .rounded
        powerButton.addItem(withTitle: "Power")
        for action in PVEPowerAction.allCases where action.isAvailable(for: guest) {
            let item = NSMenuItem(title: action.title, action: #selector(powerSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            powerButton.menu?.addItem(item)
        }
        powerButton.isEnabled = (powerButton.menu?.numberOfItems ?? 0) > 1

        isoButton.bezelStyle = .rounded
        isoButton.addItem(withTitle: "CD-ROM")
        isoButton.isEnabled = false

        let stack = NSStackView(views: [titleLabel, powerButton, isoButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - CD-ROM

    private func loadCDROMAvailability() async {
        let granted = await client.canConfigureCDROM(for: guest)
        canConfigureCDROM = granted
        if granted {
            availability = (try? await client.listISOImages(node: guest.node)) ?? .noStorageVisible
        }
        // On the record: a greyed-out CD-ROM is the kind of thing people ask about, and
        // the answer is either the privilege or an empty storage.
        Self.log.info("cdrom for \(self.guest.name, privacy: .public): granted=\(granted, privacy: .public) \(String(describing: self.availability), privacy: .public)")
        rebuildISOMenu()
    }

    private static let log = Logger(subsystem: "org.spicemac.SpiceMac", category: "proxmox")

    private func rebuildISOMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "CD-ROM", action: nil, keyEquivalent: "")

        switch canConfigureCDROM {
        case nil:
            isoButton.isEnabled = false
        case false:
            // Say which privilege and where it comes from. "Permission denied" after the
            // fact sends people looking at the wrong thing — sign-in worked, the console
            // works, and the role looks right until you know CDROM is not in it.
            isoButton.isEnabled = false
            isoButton.toolTip = """
                This token cannot change the CD-ROM. VM.Config.CDROM is not part of the \
                PVEVMUser role and has to be granted to the token explicitly, on / , /vms \
                or /vms/\(guest.vmid).
                """
        case true?:
            isoButton.isEnabled = true
            isoButton.toolTip = nil
            switch availability {
            case .images(let images):
                for image in images {
                    let item = NSMenuItem(title: image.displayName, action: #selector(isoSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = image.volumeID
                    menu.addItem(item)
                }
            case .noImages:
                menu.addItem(disabled("No ISO images on \(guest.node)"))
            case .noStorageVisible:
                // Not "no images": the node reported no storage at all, which a real node
                // never has. The token cannot see them, and saying "none found" would
                // send someone hunting for missing files instead of a missing privilege.
                menu.addItem(disabled("No storage visible on \(guest.node)"))
                menu.addItem(disabled("The token needs Datastore.Audit to list ISO images."))
            }
            menu.addItem(.separator())
            let eject = NSMenuItem(title: "Eject", action: #selector(isoSelected(_:)), keyEquivalent: "")
            eject.target = self
            eject.representedObject = nil        // nil means detach
            menu.addItem(eject)
        }
        isoButton.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func powerSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = PVEPowerAction(rawValue: raw) else { return }
        onPowerAction?(action)
    }

    @objc private func isoSelected(_ sender: NSMenuItem) {
        onSetISO?(sender.representedObject as? String)
    }

    // MARK: - Probes for UICheck

    var isISOControlEnabled: Bool { isoButton.isEnabled }
    var isoControlExplanation: String? { isoButton.toolTip }
    var powerActionTitles: [String] {
        (powerButton.menu?.items.dropFirst().map(\.title)) ?? []
    }
    var isoMenuTitles: [String] {
        (isoButton.menu?.items.dropFirst().map(\.title)) ?? []
    }

    /// Drives the states the checks assert on without a server behind them.
    func applyCDROMAvailability(_ granted: Bool?, availability: PVEISOAvailability) {
        canConfigureCDROM = granted
        self.availability = availability
        rebuildISOMenu()
    }
}
