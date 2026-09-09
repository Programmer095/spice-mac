// SPDX-License-Identifier: MIT
import Foundation
import PVEClient

let t = TestRunner()

/// A holder so a value produced inside a `Task` can be asserted on once the test has
/// waited for it.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// A finished profile, handed over as a `let`.
///
/// A `var` captured by a `Task` is an error on the Swift 5.10 toolchain CI builds with,
/// even though 6.x accepts it — so these read fine locally and did not compile there.
/// None of these tests mutates the profile after building it, so there was never a reason
/// for it to be a `var`.
func signInProfile(host: String, port: Int = 8006, rememberSecret: Bool = true) -> PVEServerProfile {
    PVEServerProfile(label: "Home", host: host, port: port,
                     tokenID: "root@pam!spicemac", rememberSecret: rememberSecret)
}

/// Waits for `@MainActor` work by draining the main run loop rather than blocking on
/// it. `DispatchSemaphore.wait` on the main thread occupies the very executor the work
/// is queued on, so the work never starts and the assertion that follows passes
/// vacuously against an untouched value.
func waitOnMain(_ timeout: TimeInterval = 20, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while condition() == false, Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}


// MARK: - Server

t.test("baseURL builds https://host:port") {
    let server = PVEServer(host: "pve.lan", port: 8006)
    t.expectEqual(server.baseURL?.absoluteString, "https://pve.lan:8006")
}

t.test("baseURL tolerates surrounding whitespace") {
    t.expectEqual(PVEServer(host: "  pve.lan  ").baseURL?.absoluteString, "https://pve.lan:8006")
}

t.test("baseURL is nil for an empty host") {
    t.expectNil(PVEServer(host: "   ").baseURL)
}

t.test("baseURL honours a non-default port") {
    t.expectEqual(PVEServer(host: "pve.lan", port: 443).baseURL?.absoluteString, "https://pve.lan:443")
}

// MARK: - Authorization

t.test("authorization header has the PVEAPIToken shape") {
    let header = try PVEProtocol.authorizationHeader(tokenID: "root@pam!spicemac", secret: "abc-123")
    t.expectEqual(header, "PVEAPIToken=root@pam!spicemac=abc-123")
}

t.test("authorization header trims whitespace around id and secret") {
    let header = try PVEProtocol.authorizationHeader(tokenID: " root@pam!spicemac ", secret: " abc-123 ")
    t.expectEqual(header, "PVEAPIToken=root@pam!spicemac=abc-123")
}

t.test("token id without a realm is rejected") {
    t.expectThrows(PVEError.malformedTokenID("root!spicemac")) {
        _ = try PVEProtocol.authorizationHeader(tokenID: "root!spicemac", secret: "x")
    }
}

t.test("token id without a token name is rejected") {
    t.expectThrows(PVEError.malformedTokenID("root@pam")) {
        _ = try PVEProtocol.authorizationHeader(tokenID: "root@pam", secret: "x")
    }
}

t.test("token id with a trailing bang is rejected") {
    t.expectThrows(PVEError.malformedTokenID("root@pam!")) {
        _ = try PVEProtocol.authorizationHeader(tokenID: "root@pam!", secret: "x")
    }
}

// MARK: - Paths

t.test("spiceproxy path uses /api2/spiceconfig, not /api2/json") {
    let path = PVEProtocol.spiceProxyPath(node: "pve1", vmid: 101, kind: .qemu)
    t.expectEqual(path, "/api2/spiceconfig/nodes/pve1/qemu/101/spiceproxy")
}

t.test("spiceproxy path handles lxc guests") {
    let path = PVEProtocol.spiceProxyPath(node: "pve1", vmid: 200, kind: .lxc)
    t.expectEqual(path, "/api2/spiceconfig/nodes/pve1/lxc/200/spiceproxy")
}

t.test("spiceproxy path percent-encodes an awkward node name") {
    let path = PVEProtocol.spiceProxyPath(node: "node one", vmid: 7, kind: .qemu)
    t.expectEqual(path, "/api2/spiceconfig/nodes/node%20one/qemu/7/spiceproxy")
}

// MARK: - Form encoding

t.test("form body encodes and sorts deterministically") {
    let body = PVEProtocol.formBody(["b": "2", "a": "1"])
    t.expectEqual(String(decoding: body, as: UTF8.self), "a=1&b=2")
}

t.test("form body percent-encodes reserved characters in a password") {
    let body = PVEProtocol.formBody(["password": "p@ss w&rd=+/"])
    t.expectEqual(String(decoding: body, as: UTF8.self), "password=p%40ss%20w%26rd%3D%2B%2F")
}

// MARK: - Guest decoding

let resourcesJSON = """
{"data":[
  {"vmid":102,"name":"kubuntu-dev","node":"pve1","status":"running","type":"qemu"},
  {"vmid":101,"name":"win11","node":"pve1","status":"stopped","type":"qemu"},
  {"vmid":200,"name":"docker","node":"pve2","status":"running","type":"lxc"},
  {"vmid":300,"node":"pve1","status":"running","type":"qemu"},
  {"name":"storage-thing","node":"pve1","type":"storage"},
  {"vmid":400,"name":"orphan","status":"running","type":"qemu"}
]}
"""

t.test("guests decode, drop unmodelled rows, and sort by vmid") {
    let guests = try PVEProtocol.decodeGuests(Data(resourcesJSON.utf8))
    t.expectEqual(guests.count, 4)
    t.expectEqual(guests.map(\.vmid), [101, 102, 200, 300])
}

t.test("a guest with no name falls back to vm-<vmid>") {
    let guests = try PVEProtocol.decodeGuests(Data(resourcesJSON.utf8))
    t.expectEqual(guests.first { $0.vmid == 300 }?.name, "vm-300")
}

t.test("lxc guests keep their kind so the spice path is right") {
    let guests = try PVEProtocol.decodeGuests(Data(resourcesJSON.utf8))
    t.expectEqual(guests.first { $0.vmid == 200 }?.kind, .lxc)
}

t.test("running status is recognised") {
    let guests = try PVEProtocol.decodeGuests(Data(resourcesJSON.utf8))
    t.expectEqual(guests.first { $0.vmid == 102 }?.isRunning, true)
    t.expectEqual(guests.first { $0.vmid == 101 }?.isRunning, false)
}

t.test("an empty cluster decodes to an empty list, not an error") {
    let guests = try PVEProtocol.decodeGuests(Data(#"{"data":[]}"#.utf8))
    t.expectEqual(guests.count, 0)
}

t.test("garbage instead of JSON is a decoding error") {
    t.expectThrows(PVEError.decoding("unexpected /cluster/resources payload")) {
        _ = try PVEProtocol.decodeGuests(Data("<html>login</html>".utf8))
    }
}

// MARK: - Ticket decoding

t.test("ticket and CSRF token decode") {
    let json = #"{"data":{"ticket":"PVE:root@pam:AAAA","CSRFPreventionToken":"CSRF1","username":"root@pam"}}"#
    let ticket = try PVEProtocol.decodeTicket(Data(json.utf8))
    t.expectEqual(ticket.ticket, "PVE:root@pam:AAAA")
    t.expectEqual(ticket.csrfToken, "CSRF1")
    t.expectEqual(ticket.username, "root@pam")
}

t.test("a ticket response missing the CSRF token is an error") {
    t.expectThrows(PVEError.decoding("no ticket in the /access/ticket response")) {
        _ = try PVEProtocol.decodeTicket(Data(#"{"data":{"ticket":"x"}}"#.utf8))
    }
}

// MARK: - SPICE config validation

t.test("a real spiceproxy body validates") {
    let body = """
    [virt-viewer]
    type=spice
    proxy=http://pve1:3128
    host=pvespiceproxy:1700000000:101:pve1::deadbeef==
    """
    try PVEProtocol.validateSpiceConfig(body)
}

t.test("leading blank lines do not defeat validation") {
    try PVEProtocol.validateSpiceConfig("\n\n[virt-viewer]\ntype=spice\n")
}

t.test("an HTML error page is rejected with its opening text") {
    t.expectThrows(PVEError.notSpiceConfig("<!DOCTYPE html><title>401 Unauthorized</title>")) {
        try PVEProtocol.validateSpiceConfig("<!DOCTYPE html><title>401 Unauthorized</title>")
    }
}

// MARK: - Error extraction

t.test("a PVE errors object is flattened into a message") {
    let json = #"{"errors":{"vmid":"invalid format"},"data":null}"#
    t.expectEqual(PVEProtocol.errorMessage(from: Data(json.utf8)), "vmid: invalid format")
}

t.test("a PVE message field is surfaced") {
    let json = #"{"message":"permission denied","data":null}"#
    t.expectEqual(PVEProtocol.errorMessage(from: Data(json.utf8)), "permission denied")
}

// MARK: - Power actions

let running = PVEGuest(vmid: 102, name: "kubuntu-dev", node: "pve1", status: "running", kind: .qemu)
let stopped = PVEGuest(vmid: 101, name: "win11", node: "pve1", status: "stopped", kind: .qemu)
let paused  = PVEGuest(vmid: 103, name: "paused-vm", node: "pve1", status: "paused", kind: .qemu)
let ct      = PVEGuest(vmid: 200, name: "docker", node: "pve2", status: "running", kind: .lxc)

t.test("power path targets the status endpoint") {
    t.expectEqual(PVEProtocol.powerPath(node: "pve1", vmid: 102, kind: .qemu, action: .shutdown),
                  "/api2/json/nodes/pve1/qemu/102/status/shutdown")
}

t.test("power path works for containers") {
    t.expectEqual(PVEProtocol.powerPath(node: "pve2", vmid: 200, kind: .lxc, action: .start),
                  "/api2/json/nodes/pve2/lxc/200/status/start")
}

t.test("task status path percent-encodes the colons in a UPID") {
    let upid = "UPID:pve1:0000ABCD:00112233:66D0:qmshutdown:102:root@pam:"
    let path = PVEProtocol.taskStatusPath(node: "pve1", upid: upid)
    t.expect(path.hasPrefix("/api2/json/nodes/pve1/tasks/UPID%3A"), "UPID colons must be encoded: \(path)")
    t.expect(path.hasSuffix("/status"), "path ends at /status")
    t.expect(path.contains("root%40pam"), "the @ in the user is encoded too")
}

t.test("a UPID decodes from the bare data string") {
    let json = #"{"data":"UPID:pve1:0000ABCD:00112233:66D0:qmstart:102:root@pam:"}"#
    t.expectEqual(try PVEProtocol.decodeUPID(Data(json.utf8)),
                  "UPID:pve1:0000ABCD:00112233:66D0:qmstart:102:root@pam:")
}

t.test("a response that is not a UPID is rejected") {
    t.expectThrows(PVEError.decoding("no task id (UPID) in the response")) {
        _ = try PVEProtocol.decodeUPID(Data(#"{"data":"sure thing"}"#.utf8))
    }
}

t.test("a running task reports running and not failed") {
    let status = try PVEProtocol.decodeTaskStatus(Data(#"{"data":{"status":"running"}}"#.utf8))
    t.expectEqual(status.isRunning, true)
    t.expectEqual(status.failed, false)
}

t.test("a finished task with exitstatus OK is a success") {
    let status = try PVEProtocol.decodeTaskStatus(Data(#"{"data":{"status":"stopped","exitstatus":"OK"}}"#.utf8))
    t.expectEqual(status.isRunning, false)
    t.expectEqual(status.failed, false)
}

t.test("a finished task with any other exitstatus is a failure") {
    let json = #"{"data":{"status":"stopped","exitstatus":"VM 102 not running"}}"#
    let status = try PVEProtocol.decodeTaskStatus(Data(json.utf8))
    t.expectEqual(status.failed, true)
    t.expectEqual(status.exitStatus, "VM 102 not running")
}

t.test("start is offered only when the guest is not running") {
    t.expectEqual(PVEPowerAction.start.isAvailable(for: stopped), true)
    t.expectEqual(PVEPowerAction.start.isAvailable(for: running), false)
    t.expectEqual(PVEPowerAction.start.isAvailable(for: paused), false)
}

t.test("shutdown, restart and force stop need a running guest") {
    for action in [PVEPowerAction.shutdown, .reboot, .stop] {
        t.expectEqual(action.isAvailable(for: running), true)
        t.expectEqual(action.isAvailable(for: stopped), false)
    }
}

t.test("reset is QEMU-only — containers have no equivalent") {
    t.expectEqual(PVEPowerAction.reset.isAvailable(for: running), true)
    t.expectEqual(PVEPowerAction.reset.isAvailable(for: ct), false)
}

t.test("resume is offered for a paused guest, not a stopped one") {
    t.expectEqual(PVEPowerAction.resume.isAvailable(for: paused), true)
    t.expectEqual(PVEPowerAction.resume.isAvailable(for: stopped), false)
}

t.test("only the power-cutting actions are marked destructive") {
    let destructive = PVEPowerAction.allCases.filter(\.isDestructive)
    t.expectEqual(Set(destructive), Set([PVEPowerAction.stop, .reset]))
}

t.test("every destructive action carries a confirmation explaining the risk") {
    for action in PVEPowerAction.allCases where action.isDestructive {
        let detail = try t.unwrap(action.confirmationDetail)
        t.expect(detail.isEmpty == false, "\(action.rawValue) needs confirmation text")
    }
    t.expectNil(PVEPowerAction.shutdown.confirmationDetail)
}

// MARK: - Permission diagnosis

t.test("permissions decode with integer privilege values") {
    let json = #"{"data":{"/vms":{"VM.Audit":1,"VM.Console":1}}}"#
    let perms = try PVEProtocol.decodePermissions(Data(json.utf8))
    t.expectEqual(perms["/vms"]?["VM.Audit"], 1)
}

t.test("permissions decode when Proxmox sends booleans instead of ints") {
    let json = #"{"data":{"/vms":{"VM.Audit":true,"VM.Console":false}}}"#
    let perms = try PVEProtocol.decodePermissions(Data(json.utf8))
    t.expectEqual(perms["/vms"]?["VM.Audit"], 1)
    t.expectEqual(perms["/vms"]?["VM.Console"], 0)
}

t.test("a token with no ACL decodes to no permissions at all") {
    let perms = try PVEProtocol.decodePermissions(Data(#"{"data":{}}"#.utf8))
    t.expectEqual(perms.isEmpty, true)
    t.expectEqual(PVEProtocol.grantsGuestVisibility(perms), false)
}

t.test("VM.Audit anywhere means guests should be visible") {
    t.expectEqual(PVEProtocol.grantsGuestVisibility(["/vms": ["VM.Audit": 1]]), true)
    t.expectEqual(PVEProtocol.grantsGuestVisibility(["/": ["VM.Audit": 1, "Sys.Audit": 1]]), true)
}

t.test("console rights without VM.Audit explains an empty list") {
    // The exact trap: the guest can be opened but never appears in the listing.
    t.expectEqual(PVEProtocol.grantsGuestVisibility(["/vms": ["VM.Console": 1]]), false)
}

t.test("VM.Audit present but zero does not count as visibility") {
    t.expectEqual(PVEProtocol.grantsGuestVisibility(["/vms": ["VM.Audit": 0]]), false)
}

t.test("permissions endpoint is the access path, not a cluster path") {
    t.expectEqual(PVEProtocol.permissionsPath(), "/api2/json/access/permissions")
}

// MARK: - SPICE availability

t.test("a failed spiceproxy names the guest and keeps Proxmox's reason") {
    let error = PVEError.spiceUnavailable(guest: "kubuntu-dev (102)", reason: "no spice device configured")
    t.expect(error.description.contains("kubuntu-dev (102)"), "names the guest")
    t.expect(error.description.contains("no spice device configured"), "keeps the server's reason")
}

t.test("the spice failure explains the display-type cause and the fix") {
    let error = PVEError.spiceUnavailable(guest: "win11 (101)", reason: "internal error")
    t.expect(error.description.contains("qm set"), "offers the qm command")
    t.expect(error.description.contains("--vga qxl"), "names the display type to set")
    t.expect(error.description.lowercased().contains("standard vga"), "names the default that does not work")
}

// MARK: - Server profiles

t.test("keychain account is scoped per server and user so several can coexist") {
    var a = PVEServerProfile(label: "Home", host: "10.0.0.1")
    a.tokenID = "root@pam!spicemac"
    var b = PVEServerProfile(label: "Site B", host: "10.0.0.2")
    b.tokenID = "root@pam!spicemac"
    t.expectEqual(a.keychainAccount, "10.0.0.1:8006|root@pam!spicemac")
    t.expect(a.keychainAccount != b.keychainAccount, "different hosts must not share an item")
}

t.test("password profiles key their keychain item on user@realm") {
    var p = PVEServerProfile(label: "Home", host: "pve.lan")
    p.authKind = .password
    p.username = "cory"
    p.realm = "pve"
    t.expectEqual(p.keychainAccount, "pve.lan:8006|cory@pve")
}

t.test("a token profile is incomplete without a full token id") {
    var p = PVEServerProfile(label: "Home", host: "pve.lan")
    p.tokenID = "root@pam"
    t.expectEqual(p.isComplete, false)
    p.tokenID = "root@pam!spicemac"
    t.expectEqual(p.isComplete, true)
}

t.test("a profile with no host is incomplete whatever else is set") {
    var p = PVEServerProfile(label: "Home", host: "   ")
    p.tokenID = "root@pam!spicemac"
    t.expectEqual(p.isComplete, false)
}

t.test("display name falls back to the host when unlabelled") {
    t.expectEqual(PVEServerProfile(label: "", host: "pve.lan").displayName, "pve.lan")
    t.expectEqual(PVEServerProfile(label: "Home", host: "pve.lan").displayName, "Home")
}

t.test("profiles round-trip through Codable so they can be persisted") {
    var p = PVEServerProfile(label: "Home", host: "pve.lan")
    p.tokenID = "root@pam!spicemac"
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(PVEServerProfile.self, from: data)
    t.expectEqual(back, p)
}

// MARK: - Migration

let legacyProfileJSON = """
{"host":"10.168.1.249","port":8006,"authKind":"apiToken",
 "tokenID":"root@pam!spicemac","username":"root","realm":"pam","rememberSecret":true}
"""

t.test("a legacy profile migrates to a one-element fleet") {
    let profiles = PVEServerProfile.migratingLegacy(Data(legacyProfileJSON.utf8))
    t.expectEqual(profiles.count, 1)
    t.expectEqual(profiles.first?.host, "10.168.1.249")
    t.expectEqual(profiles.first?.tokenID, "root@pam!spicemac")
}

t.test("migration preserves the keychain account so no secret is re-entered") {
    let migrated = try t.unwrap(PVEServerProfile.migratingLegacy(Data(legacyProfileJSON.utf8)).first)
    t.expectEqual(migrated.keychainAccount, "10.168.1.249:8006|root@pam!spicemac")
}

t.test("a migrated profile is labelled by its host, having had no label before") {
    let migrated = try t.unwrap(PVEServerProfile.migratingLegacy(Data(legacyProfileJSON.utf8)).first)
    t.expectEqual(migrated.displayName, "10.168.1.249")
}

t.test("no legacy profile migrates to an empty fleet, not a broken one") {
    t.expectEqual(PVEServerProfile.migratingLegacy(nil).count, 0)
    t.expectEqual(PVEServerProfile.migratingLegacy(Data("not json".utf8)).count, 0)
}

t.test("an incomplete legacy profile is dropped rather than carried forward broken") {
    let partial = Data(#"{"host":"","port":8006,"authKind":"apiToken","tokenID":""}"#.utf8)
    t.expectEqual(PVEServerProfile.migratingLegacy(partial).count, 0)
}

// MARK: - Fleet reducer

func fleetFixture() -> (PVEFleetState, UUID, UUID) {
    var home = PVEServerProfile(label: "Home", host: "10.0.0.1")
    home.tokenID = "root@pam!spicemac"
    var siteB = PVEServerProfile(label: "Site B", host: "10.0.0.2")
    siteB.tokenID = "root@pam!spicemac"
    let state = PVEFleetState.reduce(PVEFleetState(), .profilesChanged([home, siteB]))
    return (state, home.id, siteB.id)
}

let vm = PVEGuest(vmid: 101, name: "win11", node: "pve1", status: "running", kind: .qemu)

t.test("profiles seed one signed-out instance each") {
    let (state, _, _) = fleetFixture()
    t.expectEqual(state.instances.count, 2)
    t.expectEqual(state.instances.allSatisfy { $0.state == .signedOut }, true)
}

t.test("sign-in moves only its own instance") {
    let (seeded, home, siteB) = fleetFixture()
    let state = PVEFleetState.reduce(seeded, .signInStarted(home))
    t.expectEqual(state.instance(home)?.state, .signingIn)
    t.expectEqual(state.instance(siteB)?.state, .signedOut)
}

t.test("loaded guests land on the right instance") {
    let (seeded, home, _) = fleetFixture()
    let state = PVEFleetState.reduce(PVEFleetState.reduce(seeded, .signInStarted(home)),
                                     .guestsLoaded(home, [vm]))
    t.expectEqual(state.instance(home)?.state, .signedIn([vm]))
}

t.test("one instance failing leaves the others untouched") {
    let (seeded, home, siteB) = fleetFixture()
    var state = PVEFleetState.reduce(seeded, .guestsLoaded(home, [vm]))
    state = PVEFleetState.reduce(state, .signInFailed(siteB, .unauthorized))
    t.expectEqual(state.instance(home)?.state, .signedIn([vm]))
    t.expectEqual(state.instance(siteB)?.state, .failed(.unauthorized))
}

t.test("signing out clears that instance's guests") {
    let (seeded, home, _) = fleetFixture()
    var state = PVEFleetState.reduce(seeded, .guestsLoaded(home, [vm]))
    state = PVEFleetState.reduce(state, .signedOut(home))
    t.expectEqual(state.instance(home)?.state, .signedOut)
}

t.test("an event for an unknown instance is ignored, not a crash") {
    let (seeded, _, _) = fleetFixture()
    let state = PVEFleetState.reduce(seeded, .guestsLoaded(UUID(), [vm]))
    t.expectEqual(state.instances.count, 2)
    t.expectEqual(state.instances.allSatisfy { $0.state == .signedOut }, true)
}

t.test("removing a profile drops its instance and keeps the rest signed in") {
    let (seeded, home, siteB) = fleetFixture()
    let signedIn = PVEFleetState.reduce(seeded, .guestsLoaded(home, [vm]))
    let remaining = try t.unwrap(signedIn.instance(home)?.profile)
    let state = PVEFleetState.reduce(signedIn, .profilesChanged([remaining]))
    t.expectEqual(state.instances.count, 1)
    t.expectEqual(state.instance(home)?.state, .signedIn([vm]))
    t.expectNil(state.instance(siteB))
}

t.test("every guest across the fleet is reachable in one list") {
    let (seeded, home, siteB) = fleetFixture()
    var state = PVEFleetState.reduce(seeded, .guestsLoaded(home, [vm]))
    let other = PVEGuest(vmid: 200, name: "docker", node: "pve2", status: "running", kind: .lxc)
    state = PVEFleetState.reduce(state, .guestsLoaded(siteB, [other]))
    t.expectEqual(state.allGuests.count, 2)
}

// MARK: - Fleet coordinator

t.test("signIn(usingSecret:) never touches the secret provider") {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); value = true; lock.unlock() }
        var wasCalled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    let providerCalled = Flag()
    // A host that cannot form a URL: the sign-in settles on .invalidServer without
    // ever touching the network, which keeps the check deterministic and instant.
    let profile = signInProfile(host: "pve lan")
    let id = profile.id
    let settled = Box<PVEInstanceState?>(nil)
    // signIn's async half holds the coordinator weakly, so a local would be gone
    // before the sign-in it started ever runs.
    let live = Box<AnyObject?>(nil)

    Task { @MainActor in
        let coordinator = PVEFleetCoordinator(trustDelegate: nil) { _ in
            providerCalled.mark()
            return "provider-secret"
        }
        coordinator.setProfiles([profile])
        coordinator.onChange = { state in
            // Skip the transient .signingIn step; only the eventual outcome matters.
            guard let current = state.instance(id)?.state, current != .signingIn else { return }
            settled.value = current
        }
        live.value = coordinator
        coordinator.signIn(id, usingSecret: "typed-secret")
    }
    waitOnMain { settled.value != nil }
    t.expect(settled.value != nil, "the sign-in never settled")
    t.expect(providerCalled.wasCalled == false,
             "an explicit secret must bypass secretProvider entirely")
}

// MARK: - Prompt queue

t.test("prompts run one at a time even when requested concurrently") {
    final class Tracker: @unchecked Sendable {
        var active = 0
        var peak = 0
        let lock = NSLock()
        func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
    }
    let tracker = Tracker()
    let queue = PVEPromptQueue()
    let done = DispatchSemaphore(value: 0)

    Task {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await queue.run {
                        tracker.enter()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        tracker.leave()
                    }
                }
            }
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 10)
    t.expectEqual(tracker.peak, 1)
}

// MARK: - Connection identity

t.test("connection identity ignores label and remember-secret") {
    var a = PVEServerProfile(label: "Home", host: "pve.lan", tokenID: "root@pam!a")
    var b = a
    b.label = "Rack B"
    b.rememberSecret = !a.rememberSecret
    t.expect(a.connectsIdentically(to: b), "cosmetic fields must not invalidate a live client")
    a.label = "x"
    t.expect(b.connectsIdentically(to: a), "the comparison must be symmetric")
}

t.test("connection identity notices host, port, kind, token, username and realm") {
    let base = PVEServerProfile(label: "Home", host: "pve.lan", port: 8006,
                                tokenID: "root@pam!a", username: "root", realm: "pam")
    var host = base;     host.host = "other.lan"
    var port = base;     port.port = 443
    var kind = base;     kind.authKind = .password
    var token = base;    token.tokenID = "root@pam!b"
    var user = base;     user.username = "admin"
    var realm = base;    realm.realm = "pve"
    for changed in [host, port, kind, token, user, realm] {
        t.expect(base.connectsIdentically(to: changed) == false,
                 "a changed connection field must invalidate the client")
    }
}

// MARK: - Expired ticket retry

t.test("a 401 with a cached password ticket is retried once") {
    t.expect(PVEClient.shouldRetryAfterExpiredTicket(
        status: 401,
        credentials: .password(username: "root", realm: "pam", password: "pw"),
        hasTicket: true), "an expired ticket is exactly what one retry fixes")
}

t.test("a 401 without a cached ticket is a bad password, not an expiry") {
    t.expect(PVEClient.shouldRetryAfterExpiredTicket(
        status: 401,
        credentials: .password(username: "root", realm: "pam", password: "pw"),
        hasTicket: false) == false, "retrying a fresh login loops on a wrong password")
}

t.test("a token 401 is never retried") {
    t.expect(PVEClient.shouldRetryAfterExpiredTicket(
        status: 401,
        credentials: .apiToken(id: "root@pam!a", secret: "s"),
        hasTicket: true) == false, "API tokens carry no session state to refresh")
}

t.test("a 403 is a permissions problem and is never retried") {
    t.expect(PVEClient.shouldRetryAfterExpiredTicket(
        status: 403,
        credentials: .password(username: "root", realm: "pam", password: "pw"),
        hasTicket: true) == false, "a permissions failure does not improve on a second try")
}

// MARK: - Serialised trust prompts

t.test("the certificate dialog shares the prompt queue with keychain reads") {
    final class Tracker: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0
        func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
    }
    final class BlockingTrust: PVETrustDelegate, @unchecked Sendable {
        let tracker: Tracker
        init(tracker: Tracker) { self.tracker = tracker }
        func pinnedFingerprint(forHost host: String) -> String? { nil }
        func pinCertificate(fingerprint: String, forHost host: String) {}
        func shouldTrustCertificate(host: String, fingerprint: String, isChange: Bool) async -> Bool {
            tracker.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            tracker.leave()
            return true
        }
    }

    let tracker = Tracker()
    let queue = PVEPromptQueue()
    let delegate = PVEQueuedTrustDelegate(wrapping: BlockingTrust(tracker: tracker), prompts: queue)
    let done = DispatchSemaphore(value: 0)

    Task {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    _ = await delegate.shouldTrustCertificate(host: "node\(index)", fingerprint: "AA", isChange: false)
                }
                // A keychain read on the same queue must not overlap a dialog either.
                group.addTask {
                    await queue.run {
                        tracker.enter()
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        tracker.leave()
                    }
                }
            }
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 20)
    t.expectEqual(tracker.peak, 1)
}

t.test("pinning and pin lookup pass through the queue wrapper unblocked") {
    final class Recording: PVETrustDelegate, @unchecked Sendable {
        var pinned: [String: String] = [:]
        func pinnedFingerprint(forHost host: String) -> String? { pinned[host] }
        func pinCertificate(fingerprint: String, forHost host: String) { pinned[host] = fingerprint }
        func shouldTrustCertificate(host: String, fingerprint: String, isChange: Bool) async -> Bool { false }
    }
    let inner = Recording()
    let delegate = PVEQueuedTrustDelegate(wrapping: inner, prompts: PVEPromptQueue())
    t.expectNil(delegate.pinnedFingerprint(forHost: "pve.lan"))
    delegate.pinCertificate(fingerprint: "AA:BB", forHost: "pve.lan")
    t.expectEqual(delegate.pinnedFingerprint(forHost: "pve.lan"), "AA:BB")
}

// MARK: - Missing secrets

t.test("no stored secret and no prompt reports the server, not rejected credentials") {
    let profile = signInProfile(host: "127.0.0.1", port: 1, rememberSecret: false)
    let id = profile.id
    let box = Box<PVEInstanceState?>(nil)
    let live = Box<AnyObject?>(nil)

    Task { @MainActor in
        let coordinator = PVEFleetCoordinator(trustDelegate: nil, secretProvider: { _ in nil })
        coordinator.setProfiles([profile])
        coordinator.onChange = { state in
            guard let current = state.instance(id)?.state, current != .signingIn else { return }
            box.value = current
        }
        live.value = coordinator
        coordinator.signIn(id)
    }
    waitOnMain { box.value != nil }
    t.expectEqual(box.value, .failed(.secretUnavailable(server: "Home")))
}

t.test("a server with no stored secret is offered to the prompt instead of failing") {
    let profile = signInProfile(host: "127.0.0.1", port: 1, rememberSecret: false)
    let id = profile.id
    let asked = Box<Bool>(false)
    let live = Box<AnyObject?>(nil)

    Task { @MainActor in
        let coordinator = PVEFleetCoordinator(trustDelegate: nil,
                                              secretProvider: { _ in nil },
                                              secretPrompt: { _ in asked.value = true; return "typed" })
        coordinator.setProfiles([profile])
        live.value = coordinator
        coordinator.signIn(id)
    }
    waitOnMain { asked.value }
    t.expect(asked.value, "the prompt must be the fallback when nothing is stored")
}

t.test("a stored secret is used without troubling the prompt") {
    // Unusable as a URL on purpose — the sign-in settles on .invalidServer rather than
    // waiting on a socket, and the secret decision has already been made by then.
    let profile = signInProfile(host: "pve lan")
    let id = profile.id
    let asked = Box<Bool>(false)
    let settled = Box<PVEInstanceState?>(nil)
    let live = Box<AnyObject?>(nil)

    Task { @MainActor in
        let coordinator = PVEFleetCoordinator(trustDelegate: nil,
                                              secretProvider: { _ in "stored" },
                                              secretPrompt: { _ in asked.value = true; return "typed" })
        coordinator.setProfiles([profile])
        coordinator.onChange = { state in
            guard let current = state.instance(id)?.state, current != .signingIn else { return }
            settled.value = current
        }
        live.value = coordinator
        coordinator.signIn(id)
    }
    waitOnMain { settled.value != nil }
    t.expect(settled.value != nil, "the sign-in never settled")
    t.expect(asked.value == false, "a stored secret must not raise a dialog")
}

// MARK: - Editing a signed-in profile

/// A coordinator whose guests arrive without a server, so the tests below can reach
/// states that only exist *after* a successful sign-in. `signedInCoordinator` returns
/// one already holding a live client for `profile`.
@MainActor
func signedInCoordinator(_ profile: PVEServerProfile,
                         guests: [PVEGuest] = [],
                         onChange: ((PVEFleetState) -> Void)? = nil) -> PVEFleetCoordinator {
    let coordinator = PVEFleetCoordinator(trustDelegate: nil,
                                          secretProvider: { _ in "s" },
                                          loadGuests: { _ in guests })
    coordinator.setProfiles([profile])
    coordinator.onChange = onChange
    coordinator.signIn(profile.id)
    return coordinator
}

/// A port nothing is listening on, so a test that does reach the network fails at once.
func sampleProfile(host: String = "127.0.0.1") -> PVEServerProfile {
    signInProfile(host: host, port: 1)
}

let sampleGuest = PVEGuest(vmid: 100, name: "vm", node: "n1", status: "running", kind: .qemu)

t.test("editing where a signed-in server points signs it out") {
    let profile = sampleProfile()
    let id = profile.id
    let live = Box<AnyObject?>(nil)
    let signedIn = Box<Bool>(false)
    let after = Box<PVEInstanceState?>(nil)
    let host = Box<String?>(nil)
    let hasClient = Box<Bool?>(nil)

    Task { @MainActor in
        let coordinator = signedInCoordinator(profile, guests: [sampleGuest]) { state in
            if case .signedIn = state.instance(id)?.state { signedIn.value = true }
        }
        live.value = coordinator
    }
    waitOnMain { signedIn.value }
    t.expect(signedIn.value, "the instance never reached .signedIn, so the rest asserts nothing")

    Task { @MainActor in
        guard let coordinator = live.value as? PVEFleetCoordinator else { return }
        var moved = profile
        moved.host = "192.0.2.1"
        coordinator.setProfiles([moved])
        host.value = coordinator.state.instance(id)?.profile.host
        hasClient.value = coordinator.client(for: id) != nil
        after.value = coordinator.state.instance(id)?.state
    }
    waitOnMain { after.value != nil }
    t.expectEqual(after.value, .signedOut)
    t.expectEqual(host.value, "192.0.2.1")
    t.expectEqual(hasClient.value, false)
}

t.test("a cosmetic edit leaves a signed-in server alone") {
    let profile = sampleProfile()
    let id = profile.id
    let live = Box<AnyObject?>(nil)
    let signedIn = Box<Bool>(false)
    let after = Box<PVEInstanceState?>(nil)
    let label = Box<String?>(nil)
    let hasClient = Box<Bool?>(nil)

    Task { @MainActor in
        let coordinator = signedInCoordinator(profile, guests: [sampleGuest]) { state in
            if case .signedIn = state.instance(id)?.state { signedIn.value = true }
        }
        live.value = coordinator
    }
    waitOnMain { signedIn.value }
    t.expect(signedIn.value, "the instance never reached .signedIn, so the rest asserts nothing")

    Task { @MainActor in
        guard let coordinator = live.value as? PVEFleetCoordinator else { return }
        var renamed = profile
        renamed.label = "Rack B"
        coordinator.setProfiles([renamed])
        label.value = coordinator.state.instance(id)?.profile.label
        hasClient.value = coordinator.client(for: id) != nil
        after.value = coordinator.state.instance(id)?.state
    }
    waitOnMain { after.value != nil }
    t.expectEqual(label.value, "Rack B")
    t.expectEqual(after.value, .signedIn([sampleGuest]))
    t.expectEqual(hasClient.value, true)
}

// MARK: - Recovering from a failed sign-in

t.test("a failed sign-in leaves no client behind, so Refresh cannot reuse bad credentials") {
    let profile = sampleProfile()
    let id = profile.id
    let live = Box<AnyObject?>(nil)
    let settled = Box<PVEInstanceState?>(nil)
    let hasClient = Box<Bool?>(nil)

    Task { @MainActor in
        let coordinator = PVEFleetCoordinator(trustDelegate: nil,
                                              secretProvider: { _ in "s" },
                                              loadGuests: { _ in throw PVEError.unauthorized })
        coordinator.setProfiles([profile])
        coordinator.onChange = { state in
            guard let current = state.instance(id)?.state, current != .signingIn else { return }
            if case .failed = current { settled.value = current }
        }
        live.value = coordinator
        coordinator.signIn(id)
    }
    waitOnMain { settled.value != nil }

    Task { @MainActor in
        hasClient.value = (live.value as? PVEFleetCoordinator)?.client(for: id) != nil
    }
    waitOnMain { hasClient.value != nil }
    t.expectEqual(hasClient.value, false)
}

// MARK: - Re-entrancy

t.test("signing in twice does not start the work twice") {
    let profile = sampleProfile()
    let id = profile.id
    let live = Box<AnyObject?>(nil)
    let attempts = Box<Int>(0)
    let settled = Box<Bool>(false)

    Task { @MainActor in
        let coordinator = PVEFleetCoordinator(trustDelegate: nil,
                                              secretProvider: { _ in "s" },
                                              loadGuests: { _ in
                                                  attempts.value += 1
                                                  try? await Task.sleep(nanoseconds: 200_000_000)
                                                  return [sampleGuest]
                                              })
        coordinator.setProfiles([profile])
        coordinator.onChange = { state in
            if case .signedIn = state.instance(id)?.state { settled.value = true }
        }
        live.value = coordinator
        coordinator.signIn(id)
        coordinator.signIn(id)   // the auto sign-in racing the user's button
    }
    waitOnMain { settled.value }
    t.expectEqual(attempts.value, 1)
}

t.test("an explicitly typed secret still gets through while a sign-in is in flight") {
    let profile = sampleProfile()
    let id = profile.id
    let live = Box<AnyObject?>(nil)
    let attempts = Box<Int>(0)
    let settled = Box<Bool>(false)

    Task { @MainActor in
        let coordinator = PVEFleetCoordinator(trustDelegate: nil,
                                              secretProvider: { _ in "stored" },
                                              loadGuests: { _ in
                                                  attempts.value += 1
                                                  return [sampleGuest]
                                              })
        coordinator.setProfiles([profile])
        coordinator.onChange = { state in
            if case .signedIn = state.instance(id)?.state { settled.value = true }
        }
        live.value = coordinator
        coordinator.signIn(id)
        coordinator.signIn(id, usingSecret: "typed")
    }
    // Wait on the attempt count, not on `.signedIn` — whichever attempt lands first
    // settles the state, and stopping there would pass without the second ever running.
    waitOnMain { attempts.value >= 2 }
    _ = settled.value
    t.expect(attempts.value >= 2, "a deliberate Sign In must not be swallowed by an automatic one, saw \(attempts.value)")
}

// MARK: - Bounding the wait for a network path

t.test("a path that is still coming up is given its grace") {
    let signal = PVEConnectivitySignal()
    let start = Date()
    signal.beganWaitingForPath()
    t.expect(signal.hasWaitedWithoutPath(longerThan: 6, now: start.addingTimeInterval(2)) == false,
             "two seconds without a path must not fail the request")
}

t.test("a path that never arrives stops the request instead of waiting out the resource timeout") {
    let signal = PVEConnectivitySignal()
    let start = Date()
    signal.beganWaitingForPath()
    t.expect(signal.hasWaitedWithoutPath(longerThan: 6, now: start.addingTimeInterval(7)),
             "past the grace with no path, the request must give up")
}

t.test("reaching the server retires the short deadline, so a fingerprint dialog keeps the long one") {
    let signal = PVEConnectivitySignal()
    let start = Date()
    signal.beganWaitingForPath()
    signal.reachedServer()
    t.expect(signal.hasWaitedWithoutPath(longerThan: 6, now: start.addingTimeInterval(600)) == false,
             "a human at the trust prompt must not be cut off by the connectivity bound")
}

t.test("a request that never waited for a path is never failed for one") {
    let signal = PVEConnectivitySignal()
    t.expect(signal.hasWaitedWithoutPath(longerThan: 0, now: Date().addingTimeInterval(600)) == false,
             "no wait was ever recorded, so there is nothing to give up on")
}

t.test("the verdict does not carry from one request into the next") {
    let signal = PVEConnectivitySignal()
    let start = Date()
    signal.beganWaitingForPath()
    signal.reset()
    t.expect(signal.hasWaitedWithoutPath(longerThan: 6, now: start.addingTimeInterval(600)) == false,
             "a reset signal must start the next request with a clean slate")
}

t.test("an error reads the same however it is presented") {
    // `presentError` reaches for `description`, but the console window and any
    // NSAlert built elsewhere use `localizedDescription`. They must not disagree.
    let errors: [PVEError] = [
        .unauthorized,
        .invalidServer,
        .transport("No network path to pve.example.com:8006."),
        .spiceUnavailable(guest: "vm", reason: "no display"),
    ]
    for error in errors {
        t.expectEqual(error.localizedDescription, error.description)
        t.expect(error.localizedDescription.contains("couldn\u{2019}t be completed") == false,
                 "\(error) still falls back to Foundation's generic wording")
    }
}

// MARK: - Privileges that sign-in cannot tell you about

t.test("a privilege granted on the guest itself counts") {
    let payload = ["/vms/100": ["VM.Config.CDROM": 1]]
    t.expect(PVEProtocol.grants("VM.Config.CDROM", forVMID: 100, in: payload),
             "a grant on the guest's own ACL path must count")
}

t.test("a privilege granted on /vms or / covers the guest") {
    t.expect(PVEProtocol.grants("VM.Config.CDROM", forVMID: 100, in: ["/vms": ["VM.Config.CDROM": 1]]),
             "a grant on /vms must cover every guest")
    t.expect(PVEProtocol.grants("VM.Config.CDROM", forVMID: 100, in: ["/": ["VM.Config.CDROM": 1]]),
             "a grant on / must cover every guest")
}

t.test("a privilege on a different guest does not count") {
    let payload = ["/vms/101": ["VM.Config.CDROM": 1]]
    t.expect(PVEProtocol.grants("VM.Config.CDROM", forVMID: 100, in: payload) == false,
             "a grant on VM 101 must not authorise VM 100")
}

t.test("a privilege present but zero is not granted") {
    // Proxmox reports the whole privilege set, granted or not; a 0 is a denial.
    let payload = ["/vms/100": ["VM.Config.CDROM": 0, "VM.Audit": 1]]
    t.expect(PVEProtocol.grants("VM.Config.CDROM", forVMID: 100, in: payload) == false,
             "a privilege reported as 0 is a denial, not a grant")
}

t.test("PVEVMUser does not include VM.Config.CDROM") {
    // The trap this check exists for: a token with the stock role signs in, lists
    // guests, and looks healthy right up to the point an ISO attach 403s.
    let pveVMUser = ["/vms/100": ["VM.Audit": 1, "VM.Config.Disk": 1, "VM.Config.CDROM": 0,
                                  "VM.Console": 1, "VM.PowerMgmt": 1]]
    t.expect(PVEProtocol.grants("VM.PowerMgmt", forVMID: 100, in: pveVMUser),
             "power actions are in the role and must stay offered")
    t.expect(PVEProtocol.grants("VM.Config.CDROM", forVMID: 100, in: pveVMUser) == false,
             "ISO must not be offered to a stock PVEVMUser token")
}

// MARK: - ISO attach and detach

t.test("attaching an ISO writes the volume as a cdrom") {
    t.expectEqual(PVEProtocol.cdromAttachValue(volumeID: "local:iso/debian-12.iso"),
                  "local:iso/debian-12.iso,media=cdrom")
}

t.test("detaching leaves the drive present and empty") {
    // Not a device deletion: a guest expects an empty drive after an eject.
    t.expectEqual(PVEProtocol.cdromDetachValue(), "none,media=cdrom")
}

t.test("ISO volume IDs are read out of a storage content listing") {
    let json = Data("""
        {"data":[{"volid":"local:iso/ubuntu.iso","size":1},
                 {"volid":"local:iso/debian-12.iso","size":2},
                 {"size":3}]}
        """.utf8)
    t.expectEqual(try PVEProtocol.decodeISOVolumeIDs(json),
                  ["local:iso/debian-12.iso", "local:iso/ubuntu.iso"])
}

t.test("only storages advertising iso content are searched") {
    let json = Data("""
        {"data":[{"storage":"local","content":"iso,vztmpl,backup"},
                 {"storage":"local-lvm","content":"images,rootdir"},
                 {"storage":"nas","content":"backup,iso"}]}
        """.utf8)
    t.expectEqual(try PVEProtocol.decodeStorages(advertising: "iso", from: json), ["local", "nas"])
}

t.test("a content type is matched whole, not as a substring") {
    let json = Data(#"{"data":[{"storage":"s","content":"isos,images"}]}"#.utf8)
    t.expect(try PVEProtocol.decodeStorages(advertising: "iso", from: json).isEmpty,
             "“isos” is not “iso” and must not be searched for ISO images")
}

t.test("a volume ID reads as its filename in a menu") {
    t.expectEqual(PVEProtocol.isoDisplayName(forVolumeID: "local:iso/debian-12.7-amd64.iso"),
                  "debian-12.7-amd64.iso")
    t.expectEqual(PVEProtocol.isoDisplayName(forVolumeID: "bare"), "bare")
}

t.test("storage and config paths encode a node name with a space") {
    t.expectEqual(PVEProtocol.storageContentPath(node: "pve node", storage: "local", content: "iso"),
                  "/api2/json/nodes/pve%20node/storage/local/content?content=iso")
    t.expectEqual(PVEProtocol.configPath(node: "pve node", vmid: 100, kind: .qemu),
                  "/api2/json/nodes/pve%20node/qemu/100/config")
}

t.test("an empty storage list is a privilege filter, not an empty node") {
    // Proxmox filters /nodes/{node}/storage by Datastore.Audit and returns [] rather
    // than 403. A real node always has at least one storage, so [] means "cannot see".
    let json = Data(#"{"data":[]}"#.utf8)
    t.expect(try PVEProtocol.decodeStorageNames(json).isEmpty,
             "an empty payload must decode to no storages at all")
    t.expect(try PVEProtocol.decodeStorages(advertising: "iso", from: json).isEmpty,
             "and to no iso-capable storages either")
}

t.test("storages holding no ISOs are distinguishable from storages you cannot see") {
    let json = Data(#"{"data":[{"storage":"local-lvm","content":"images,rootdir"}]}"#.utf8)
    t.expectEqual(try PVEProtocol.decodeStorageNames(json), ["local-lvm"])
    t.expect(try PVEProtocol.decodeStorages(advertising: "iso", from: json).isEmpty,
             "a visible storage that holds no ISOs is still visible")
}

t.test("a guest's current CD-ROM is read back out of its config") {
    let json = Data(#"{"data":{"ide2":"local:iso/debian-12.iso,media=cdrom","memory":2048,"name":"vm"}}"#.utf8)
    t.expectEqual(try PVEProtocol.decodeConfigValue(json, key: "ide2"),
                  "local:iso/debian-12.iso,media=cdrom")
    t.expectEqual(try PVEProtocol.decodeConfigValue(json, key: "memory"), "2048")
}

t.test("a config key that is absent reads as nothing, not as an error") {
    // A guest with no CD-ROM device simply has no ide2 key.
    let json = Data(#"{"data":{"name":"vm"}}"#.utf8)
    t.expectEqual(try PVEProtocol.decodeConfigValue(json, key: "ide2"), nil)
}

t.test("the mounted ISO is read out of what Proxmox writes back, not what was sent") {
    // Confirmed live: attaching local:iso/x.iso,media=cdrom comes back with a size= the
    // caller never wrote, so an equality check against the sent value would never match.
    t.expectEqual(PVEProtocol.attachedISOVolumeID(
        fromCDROMValue: "local:iso/en_windows_xp.iso,media=cdrom,size=632640K"),
        "local:iso/en_windows_xp.iso")
    t.expectEqual(PVEProtocol.attachedISOVolumeID(
        fromCDROMValue: "local:iso/x.iso,media=cdrom"), "local:iso/x.iso")
}

t.test("an empty drive is not a mounted volume") {
    t.expectEqual(PVEProtocol.attachedISOVolumeID(fromCDROMValue: "none,media=cdrom"), nil)
    t.expectEqual(PVEProtocol.attachedISOVolumeID(fromCDROMValue: nil), nil)
    t.expectEqual(PVEProtocol.attachedISOVolumeID(fromCDROMValue: ""), nil)
}

// MARK: - One definition of "ready to sign in"

t.test("a complete profile has no problem to report") {
    var profile = PVEServerProfile(label: "Home", host: "10.0.0.1", port: 8006)
    profile.tokenID = "root@pam!spicemac"
    t.expectEqual(profile.completenessProblem, nil)
    t.expect(profile.isComplete, "a token profile with host and token ID is ready")
}

t.test("a missing host is named as the missing host") {
    var profile = PVEServerProfile(label: "Home", host: "   ")
    profile.tokenID = "root@pam!spicemac"
    t.expectEqual(profile.completenessProblem, "Enter the Proxmox server address.")
}

t.test("a token ID missing its realm or token name is named as such") {
    // The trap: "root" looks like a username and is accepted by every field check.
    var profile = PVEServerProfile(label: "Home", host: "10.0.0.1")
    profile.tokenID = "root"
    t.expectEqual(profile.completenessProblem, "Enter a full API token ID, e.g. root@pam!spicemac.")
    profile.tokenID = "root@pam"
    t.expectEqual(profile.completenessProblem, "Enter a full API token ID, e.g. root@pam!spicemac.")
}

t.test("password auth wants a username, not a token ID") {
    var profile = PVEServerProfile(label: "Home", host: "10.0.0.1")
    profile.authKind = .password
    profile.username = "  "
    t.expectEqual(profile.completenessProblem, "Enter a username.")
    profile.username = "root"
    t.expectEqual(profile.completenessProblem, nil)
}

t.test("isComplete and the reported problem cannot disagree") {
    // isComplete is derived from the message, so a future edit to one carries the other.
    var profile = PVEServerProfile(label: "Home", host: "")
    for (host, tokenID) in [("", "root@pam!x"), ("h", "root"), ("h", "root@pam!x")] {
        profile.host = host
        profile.tokenID = tokenID
        t.expectEqual(profile.isComplete, profile.completenessProblem == nil)
    }
}

// MARK: - Bringing a whole fleet online

t.test("signing in the fleet retries a server that failed, not just untouched ones") {
    // A node that was briefly down, or a password fixed since, leaves the instance in
    // .failed. Skipping those means the fleet stays permanently half-connected: nothing
    // short of a manual per-row Sign In ever brings it back.
    let a = sampleProfile(host: "10.0.0.1")
    let b = sampleProfile(host: "10.0.0.2")
    let live = Box<AnyObject?>(nil)
    let attempts = Box<Int>(0)
    let aState = Box<String?>(nil)

    Task { @MainActor in
        let coordinator = PVEFleetCoordinator(trustDelegate: nil,
                                              secretProvider: { _ in "s" },
                                              loadGuests: { client in
                                                  attempts.value += 1
                                                  // 10.0.0.1 fails on the first pass, then works.
                                                  if client.server.host == "10.0.0.1", attempts.value <= 2 {
                                                      throw PVEError.unauthorized
                                                  }
                                                  return [sampleGuest]
                                              })
        coordinator.setProfiles([a, b])
        coordinator.onChange = { state in
            switch state.instance(a.id)?.state {
            case .signedIn: aState.value = "signedIn"
            case .failed: aState.value = "failed"
            default: break
            }
        }
        live.value = coordinator
        coordinator.signInAll()
    }
    waitOnMain { aState.value == "failed" }
    t.expectEqual(aState.value, "failed")

    Task { @MainActor in (live.value as? PVEFleetCoordinator)?.signInAll() }
    waitOnMain { aState.value == "signedIn" }
    t.expectEqual(aState.value, "signedIn")
}

t.test("signing in the fleet leaves an already signed-in server alone") {
    // Retrying a healthy server would cost a needless request and, worse, a Keychain
    // prompt on a build the Keychain does not know.
    let a = sampleProfile(host: "10.0.0.1")
    let live = Box<AnyObject?>(nil)
    let attempts = Box<Int>(0)
    let signedIn = Box<Bool>(false)

    Task { @MainActor in
        let coordinator = PVEFleetCoordinator(trustDelegate: nil,
                                              secretProvider: { _ in "s" },
                                              loadGuests: { _ in
                                                  attempts.value += 1
                                                  return [sampleGuest]
                                              })
        coordinator.setProfiles([a])
        coordinator.onChange = { state in
            if case .signedIn = state.instance(a.id)?.state { signedIn.value = true }
        }
        live.value = coordinator
        coordinator.signInAll()
    }
    waitOnMain { signedIn.value }

    let after = Box<Int?>(nil)
    Task { @MainActor in
        (live.value as? PVEFleetCoordinator)?.signInAll()
        after.value = attempts.value
    }
    waitOnMain { after.value != nil }
    t.expectEqual(after.value, 1)
}

t.finishAndExit()
