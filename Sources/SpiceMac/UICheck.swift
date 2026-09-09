// SPDX-License-Identifier: MIT
import AppKit
import PVEClient

/// Frames worth asserting on, measured after a forced layout pass.
struct PVEPanelLayout {
    var content: NSRect
    var root: NSRect
    var grid: NSRect
    var list: NSRect
    var filter: NSRect

    static let zero = PVEPanelLayout(content: .zero, root: .zero, grid: .zero, list: .zero, filter: .zero)
}

/// Layout checks for the windows the package runners cannot reach.
///
/// `vvcheck`/`pvecheck`/`inputcheck`/`scalecheck` cover everything portable, but the
/// window layout lives in AppKit and had no bar at all — which is how a panel that
/// collapsed to a sliver on sign-in survived a whole review. These run against the real
/// controller rather than a copy, so they cannot drift from what ships, and the views
/// render themselves with `cacheDisplay(in:to:)`, so nothing here needs Screen Recording
/// or Accessibility and it runs unattended.
///
/// Invoked as `SpiceMac --ui-check [snapshot-dir]`; `make uicheck` is the front door.
@MainActor
enum UICheck {
    private static var passed = 0
    private static var failures: [String] = []

    static func run(snapshotDirectory: String?) -> Never {
        NSApp.setActivationPolicy(.accessory)
        isolateFromStoredFleet()
        print("SpiceMac UI checks")
        checkConnectPanel(snapshotDirectory: snapshotDirectory)
        checkGuestOverlay(snapshotDirectory: snapshotDirectory)
        checkActionBar(snapshotDirectory: snapshotDirectory)
        checkServerForm()
        print("")
        for failure in failures { print("  FAIL \(failure)") }
        print("\(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Checks

    /// The panel is a fixed-width column pinned to the top-left of whatever window it
    /// finds itself in, and it must stay that way in *both* credential states. Signing
    /// in hides every row of the credentials grid; a collapsed grid used to drag the
    /// whole panel down with it, taking the filter field and the guest tree along.
    private static func checkConnectPanel(snapshotDirectory: String?) {
        let controller = PVEConnectWindowController()
        let widths: [CGFloat] = [652, 1024, 1400, 1632]

        for signedIn in [false, true] {
            let state = signedIn ? "signed in" : "signed out"
            for width in widths {
                let layout = controller.probePanelLayout(signedIn: signedIn, contentWidth: width)
                expect(layout.root.width == 620,
                       "\(state) at \(Int(width))pt: panel is \(Int(layout.root.width))pt wide, expected 620")
                expect(layout.list.width == layout.root.width,
                       "\(state) at \(Int(width))pt: guest list is \(Int(layout.list.width))pt, expected to fill the \(Int(layout.root.width))pt panel")
                expect(layout.filter.width > 400,
                       "\(state) at \(Int(width))pt: filter field collapsed to \(Int(layout.filter.width))pt")
                expect(layout.root.minX == 16 && layout.content.height - layout.root.maxY == 16,
                       "\(state) at \(Int(width))pt: panel is not inset 16pt from the top-left, root=\(NSStringFromRect(layout.root))")
            }

            // The credentials form is the only part that folds away; the tree must not.
            let folded = controller.probePanelLayout(signedIn: signedIn, contentWidth: 1400)
            if signedIn {
                expect(folded.grid.height == 0,
                       "signed in: credentials grid is still \(Int(folded.grid.height))pt tall, expected to fold away")
            } else {
                expect(folded.grid.height > 0,
                       "signed out: credentials grid collapsed to \(Int(folded.grid.height))pt")
                expect(folded.grid.width == folded.root.width,
                       "signed out: credentials grid is \(Int(folded.grid.width))pt, expected to fill the \(Int(folded.root.width))pt panel")
            }
        }

        // A Manage Servers save reloads this form. Reloading re-applies the auth-kind
        // rule, which unhides credential rows — and an edit that leaves the server signed
        // in (a rename, say) gets no fleet change to fold them back. The credentials must
        // not pop open over a live session.
        _ = controller.probePanelLayout(signedIn: true, contentWidth: 1400)
        controller.probeReloadForm()
        // As-is: asking the probe to re-assert "signed in" would re-hide the rows itself
        // and the check would pass whatever the reload actually did.
        let afterReload = controller.probePanelLayoutAsIs(contentWidth: 1400)
        expect(afterReload.grid.height == 0,
               "reloading the form while signed in re-opened the credentials rows (\(Int(afterReload.grid.height))pt)")
        expect(afterReload.root.width == 620,
               "reloading the form while signed in collapsed the panel to \(Int(afterReload.root.width))pt")

        guard let directory = snapshotDirectory else { return }
        for signedIn in [false, true] {
            _ = controller.probePanelLayout(signedIn: signedIn, contentWidth: 1400)
            let name = signedIn ? "connect-signed-in-1400.png" : "connect-signed-out-1400.png"
            if let path = controller.writePanelSnapshot(to: directory, named: name) {
                print("  wrote \(path)")
            }
        }
    }

    // MARK: - The console overlay

    /// The picker is the only route to a guest from inside a console, so an empty or
    /// mis-filtered list is a dead end. Driven through a session whose guests arrive
    /// without a server.
    private static func checkGuestOverlay(snapshotDirectory: String?) {
        let home = server(label: "Home", host: "10.0.0.1")
        let rack = server(label: "Rack B", host: "10.0.0.2")
        let guests: [String: [PVEGuest]] = [
            home.host: [guest(100, "Netbird-router", "virtual1", "running"),
                        guest(102, "OpnSense", "virtual1", "running"),
                        guest(103, "KubuntuDev", "virtual1", "stopped")],
            rack.host: [guest(200, "build-agent", "rack-1", "running")],
        ]
        let coordinator = PVEFleetCoordinator(trustDelegate: nil,
                                              secretProvider: { _ in "secret" },
                                              loadGuests: { client in guests[client.server.host] ?? [] })
        let session = PVEFleetSession(coordinator: coordinator)
        session.setProfiles([home, rack])
        coordinator.signInAll()

        let overlay = PVEGuestOverlay(session: session)
        overlay.frame = NSRect(x: 0, y: 0, width: PVEGuestOverlay.width, height: 600)

        // The sign-ins resolve on the main queue; give them a turn before asserting.
        settle(until: { overlay.visibleMatches.count == 4 })
        overlay.layoutSubtreeIfNeeded()

        expect(overlay.visibleMatches.count == 4,
               "picker shows \(overlay.visibleMatches.count) guests, expected all 4 across both servers")
        expect(overlay.isEmptyStateVisible == false,
               "picker shows the empty state with 4 guests in the fleet: “\(overlay.emptyStateText)”")

        // A stopped guest has no console to open; it is listed, but not pickable.
        let stopped = overlay.visibleMatches.firstIndex { $0.guest.status == "stopped" }
        if let stopped {
            expect(overlay.canSelectRow(stopped) == false,
                   "a stopped guest must not be selectable — there is no console to open")
        } else {
            expect(false, "the stopped guest fixture is missing, so selectability asserts nothing")
        }
        if let running = overlay.visibleMatches.firstIndex(where: { $0.guest.status == "running" }) {
            expect(overlay.canSelectRow(running), "a running guest must be selectable")
        }

        overlay.setFilter("opn")
        expect(overlay.visibleMatches.count == 1 && overlay.visibleMatches.first?.guest.name == "OpnSense",
               "filtering by name matched \(overlay.visibleMatches.map(\.guest.name))")
        overlay.setFilter("200")
        expect(overlay.visibleMatches.first?.guest.vmid == 200, "filtering by VMID failed")
        overlay.setFilter("rack b")
        expect(overlay.visibleMatches.count == 1,
               "filtering by server label matched \(overlay.visibleMatches.count), expected Rack B's one guest")
        overlay.setFilter("zzz")
        expect(overlay.visibleMatches.isEmpty && overlay.isEmptyStateVisible,
               "a query matching nothing must say so rather than show a blank list")
        overlay.setFilter("")
        expect(overlay.visibleMatches.count == 4, "clearing the filter must restore the whole fleet")

        guard let directory = snapshotDirectory else { return }
        overlay.layoutSubtreeIfNeeded()
        if let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let path = (directory as NSString).appendingPathComponent("guest-overlay.png")
                try? data.write(to: URL(fileURLWithPath: path))
                print("  wrote \(path)")
            }
        }
    }

    /// The bar offers exactly what the token can actually do. VM.Config.CDROM is not in
    /// PVEVMUser, so an ungated ISO control would 403 long after sign-in looked fine.
    private static func checkActionBar(snapshotDirectory: String?) {
        let running = guest(100, "Netbird-router", "virtual1", "running")
        let client = PVEClient(server: PVEServer(host: "10.0.0.1", port: 8006),
                               credentials: .apiToken(id: "root@pam!spicemac", secret: "s"),
                               trustDelegate: nil)

        let bar = PVEActionBar(guest: running, client: client)
        bar.frame = NSRect(x: 0, y: 0, width: 460, height: PVEActionBar.height)

        // Before the ACL has been read, nothing is claimed either way.
        bar.applyCDROMAvailability(nil, availability: .noImages)
        expect(bar.isISOControlEnabled == false,
               "the CD-ROM control must stay disabled until the privilege is known")

        // Denied: disabled, and the explanation has to name the privilege — "permission
        // denied" alone sends people to the wrong place, since sign-in and the console work.
        bar.applyCDROMAvailability(false, availability: .noImages)
        expect(bar.isISOControlEnabled == false, "a token without VM.Config.CDROM must not be offered ISO actions")
        let explanation = bar.isoControlExplanation ?? ""
        expect(explanation.contains("VM.Config.CDROM"), "the explanation must name the missing privilege, got: “\(explanation)”")
        expect(explanation.contains("PVEVMUser"), "the explanation must say the stock role does not include it")

        // Granted: enabled, images listed by filename, and always a way to eject.
        let images = [PVEISOImage(volumeID: "local:iso/debian-12.iso", storage: "local"),
                      PVEISOImage(volumeID: "nas:iso/ubuntu-24.04.iso", storage: "nas")]
        bar.applyCDROMAvailability(true, availability: .images(images))
        expect(bar.isISOControlEnabled, "a token holding VM.Config.CDROM must be offered ISO actions")
        expect(bar.isoMenuTitles.contains("debian-12.iso") && bar.isoMenuTitles.contains("ubuntu-24.04.iso"),
               "ISO images must be listed by filename, got \(bar.isoMenuTitles)")
        expect(bar.isoMenuTitles.contains("Nothing to eject"),
               "with an empty drive there is nothing to eject, got \(bar.isoMenuTitles)")
        expect(bar.tickedISOTitles.isEmpty, "nothing is mounted, so nothing should be ticked")

        // With a disc in the drive: it is ticked, and Eject becomes a real action. The
        // mounted value is what Proxmox reports, which carries a size= the app never wrote.
        bar.applyCDROMAvailability(true, availability: .images(images),
                                   mounted: "local:iso/debian-12.iso")
        expect(bar.tickedISOTitles == ["debian-12.iso"],
               "the mounted image must be ticked, got \(bar.tickedISOTitles)")
        expect(bar.isoMenuTitles.contains("Eject"), "a mounted disc must be ejectable, got \(bar.isoMenuTitles)")

        bar.applyCDROMAvailability(true, availability: .noImages)
        expect(bar.isoMenuTitles.contains(where: { $0.hasPrefix("No ISO images on") }),
               "a storage holding no ISOs must say so rather than show a bare menu, got \(bar.isoMenuTitles)")

        // The trap this distinction exists for: Proxmox filters the storage list by
        // Datastore.Audit and returns [] rather than 403, so "no images" and "cannot see
        // any storage" arrive looking identical. Confirmed live against 10.168.1.249,
        // whose token holds VM.Config.CDROM but sees no storages at all.
        bar.applyCDROMAvailability(true, availability: .noStorageVisible)
        let hidden = bar.isoMenuTitles.joined(separator: " | ")
        expect(hidden.contains("No storage visible"),
               "an empty storage list must not be reported as an empty image list, got \(hidden)")
        expect(hidden.contains("Datastore.Audit"),
               "the menu must name the privilege that hides the storages, got \(hidden)")
        expect(hidden.contains("No ISO images") == false,
               "a privilege filter must not be phrased as missing files, got \(hidden)")

        // Power is offered against the guest's actual state.
        expect(bar.powerActionTitles.contains("Shut Down"), "a running guest must offer a graceful shutdown, got \(bar.powerActionTitles)")
        expect(bar.powerActionTitles.contains("Start") == false, "a running guest must not offer Start, got \(bar.powerActionTitles)")

        let stoppedBar = PVEActionBar(guest: guest(103, "KubuntuDev", "virtual1", "stopped"), client: client)
        expect(stoppedBar.powerActionTitles.contains("Start"), "a stopped guest must offer Start, got \(stoppedBar.powerActionTitles)")
        expect(stoppedBar.powerActionTitles.contains("Shut Down") == false,
               "a stopped guest must not offer Shut Down, got \(stoppedBar.powerActionTitles)")

        guard let directory = snapshotDirectory else { return }
        bar.applyCDROMAvailability(true, availability: .images(images))
        bar.layoutSubtreeIfNeeded()
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let path = (directory as NSString).appendingPathComponent("action-bar.png")
                try? data.write(to: URL(fileURLWithPath: path))
                print("  wrote \(path)")
            }
        }
    }

    /// The form both surfaces share. It exists because the connect window and the
    /// Manage Servers sheet had grown two copies that drifted — so the round trip and
    /// the auth-kind rule are checked here, once, rather than trusted twice.
    private static func checkServerForm() {
        let sheetForm = PVEServerForm(includesLabel: true)
        let connectForm = PVEServerForm(includesLabel: false)

        expect(sheetForm.grid.numberOfRows == 8,
               "the sheet's form should have 8 rows, has \(sheetForm.grid.numberOfRows)")
        expect(connectForm.grid.numberOfRows == 7,
               "the connect form has no Label row, so 7, has \(connectForm.grid.numberOfRows)")

        // Row indices shift when the label row is present. Hand-maintained index lists
        // in two files is precisely what drifted, so check both shapes.
        // Asserted against the rows the *fields* actually sit in, not against the index
        // lists the form computed. Checking `form.tokenRows` would only prove those rows
        // behave like whatever the form decided they were — a mis-numbered list would
        // stay self-consistent and pass.
        func rowHidden(_ form: PVEServerForm, holding view: NSView) -> Bool? {
            form.grid.cell(for: view)?.row?.isHidden
        }

        for (name, form) in [("sheet", sheetForm), ("connect", connectForm)] {
            form.authSelector.selectedSegment = 0
            form.refreshAuthKindRows()
            expect(rowHidden(form, holding: form.tokenIDField) == false,
                   "\(name): the Token ID row must be visible for token auth")
            expect(rowHidden(form, holding: form.tokenSecretField) == false,
                   "\(name): the Secret row must be visible for token auth")
            expect(rowHidden(form, holding: form.passwordField) == true,
                   "\(name): the Password row must be hidden for token auth")

            form.authSelector.selectedSegment = 1
            form.refreshAuthKindRows()
            expect(rowHidden(form, holding: form.tokenIDField) == true,
                   "\(name): the Token ID row must be hidden for password auth")
            expect(rowHidden(form, holding: form.passwordField) == false,
                   "\(name): the Password row must be visible for password auth")
            expect(rowHidden(form, holding: form.usernameField) == false,
                   "\(name): the Username row must be visible for password auth")
            // The rows every auth kind needs stay put either way.
            expect(rowHidden(form, holding: form.hostField) == false,
                   "\(name): the Server row must never be hidden by an auth-kind switch")

            // Unfolding must reapply the rule, not reveal both credential styles at once.
            form.setRowsHidden(true)
            expect(form.allRows.allSatisfy(\.isHidden), "\(name): every row must fold away")
            expect(rowHidden(form, holding: form.hostField) == true,
                   "\(name): folding away must hide the Server row too")
            form.setRowsHidden(false)
            expect(rowHidden(form, holding: form.tokenIDField) == true,
                   "\(name): unfolding revealed the Token ID row while password auth is selected")
            expect(rowHidden(form, holding: form.passwordField) == false,
                   "\(name): unfolding left the Password row hidden under password auth")
        }

        // The sheet builds a window around this form. Constructing it exercises that
        // layout, which nothing else here reaches.
        let sheet = PVEManageServersController()
        expect(sheet.probeFormGrid.numberOfRows == 8,
               "the sheet's window did not build the labelled form, got \(sheet.probeFormGrid.numberOfRows) rows")

        // A profile survives the trip through the fields unchanged.
        var profile = PVEServerProfile(label: "Rack B", host: "10.0.0.2", port: 8007)
        profile.tokenID = "root@pam!spicemac"
        profile.rememberSecret = false
        sheetForm.apply(profile, secret: "s3cret")
        let round = sheetForm.profile(basedOn: PVEServerProfile(label: "wrong", host: "wrong"))
        expect(round.label == "Rack B" && round.host == "10.0.0.2" && round.port == 8007,
               "the sheet's form lost a field in the round trip: \(round.label)/\(round.host)/\(round.port)")
        expect(round.tokenID == "root@pam!spicemac", "token ID lost in the round trip")
        expect(round.rememberSecret == false, "the Remember toggle lost its off state")
        expect(sheetForm.secret == "s3cret", "the typed secret is not readable back")

        // The connect form has no label field, so the label must come from the base —
        // otherwise editing the first server would blank the name given in the sheet.
        connectForm.apply(profile, secret: "s3cret")
        var base = profile
        base.label = "Kept From Storage"
        expect(connectForm.profile(basedOn: base).label == "Kept From Storage",
               "the connect form overwrote a label it has no field for")

        // Switching auth kind must not carry a secret into the field it does not belong
        // to — that is how one server's credentials get saved against another.
        var passwordProfile = profile
        passwordProfile.authKind = .password
        passwordProfile.username = "root"
        sheetForm.apply(passwordProfile, secret: "pw")
        expect(sheetForm.tokenSecretField.stringValue.isEmpty,
               "the token secret field kept a value after switching to password auth")
        expect(sheetForm.secret == "pw", "password auth must read the password field")
    }

    private static func server(label: String, host: String) -> PVEServerProfile {
        var profile = PVEServerProfile(label: label, host: host, port: 8006)
        profile.tokenID = "root@pam!spicemac"
        return profile
    }

    private static func guest(_ vmid: Int, _ name: String, _ node: String, _ status: String) -> PVEGuest {
        PVEGuest(vmid: vmid, name: name, node: node, status: status, kind: .qemu)
    }

    /// Spins the run loop until `condition` holds, so work hopped to the main queue has
    /// landed before anything is asserted about it.
    private static func settle(timeout: TimeInterval = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Harness

    /// Hide the user's configured fleet behind an empty argument domain, which outranks
    /// the persistent one and writes nothing. Two reasons: the checks then measure the
    /// same layout on every machine, and the controller never reaches
    /// `loadProfile`'s Keychain read — which would otherwise put an authorization prompt
    /// in front of an unattended `make test` on any build the Keychain does not know.
    private static func isolateFromStoredFleet() {
        let defaults = UserDefaults.standard
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        // Not Data, so `data(forKey:)` misses and the fleet reads as empty.
        defaults.setVolatileDomain(["ProxmoxProfiles": "", "ProxmoxProfile": ""],
                                   forName: UserDefaults.argumentDomain)
    }

    private static func expect(_ condition: Bool, _ description: String) {
        if condition {
            passed += 1
        } else {
            failures.append(description)
        }
    }
}
