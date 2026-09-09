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
