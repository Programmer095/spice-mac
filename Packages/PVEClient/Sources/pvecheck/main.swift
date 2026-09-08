// SPDX-License-Identifier: MIT
import Foundation
import PVEClient

let t = TestRunner()

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

t.finishAndExit()
