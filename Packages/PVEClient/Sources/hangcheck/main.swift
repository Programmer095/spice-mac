// SPDX-License-Identifier: MIT
import Foundation
import Network
import PVEClient

/// Checks that a server which does not answer fails in bounded time.
///
/// `pvecheck` covers everything decidable without a socket. This covers the part that is
/// not: what `URLSession` actually does when the other end misbehaves. A previous
/// integration harness lived outside the repository and was thrown away with the session
/// that made it, which is how a three-minute hang survived — nothing left behind could
/// find it again. This one lives in the tree and runs from `make test`.
///
/// The failure shapes, which fail through genuinely different paths:
///
///   * **refused** — nothing is listening. Not the instant `cannotConnectToHost` you
///     would expect: with `waitsForConnectivity` on, URLSession reports a refusal as
///     waiting for connectivity, so it arrives through the path bound and its message
///     has to name both causes.
///   * **silent** — something accepts the connection and then says nothing. The network
///     path is fine, so `waitsForConnectivity` never fires and the connectivity bound
///     cannot see it; before the first-contact bound this ran the full
///     `timeoutIntervalForResource`, measured at 180s.
///   * **unroutable** — an address with no route at all, which is the connectivity case.
///
/// The graces are short here on purpose, injected through `PVEClient`, so the checks
/// finish in seconds while the app keeps its generous production values.

var passed = 0
var failures: [String] = []

func expect(_ condition: Bool, _ description: @autoclosure () -> String) {
    if condition { passed += 1 } else { failures.append(description()) }
}

/// Accepts connections and never writes a byte back.
func startSilentListener(port: NWEndpoint.Port) -> NWListener {
    let listener = try! NWListener(using: .tcp, on: port)
    // Held so ARC does not tear the connections down, which would look like a refusal.
    let accepted = NSMutableArray()
    listener.newConnectionHandler = { connection in
        accepted.add(connection)
        connection.start(queue: .global())
    }
    listener.start(queue: .global())
    return listener
}

func client(host: String, port: Int, path: TimeInterval = 2, firstContact: TimeInterval = 3) -> PVEClient {
    PVEClient(server: PVEServer(host: host, port: port),
              credentials: .apiToken(id: "root@pam!hangcheck", secret: "s"),
              trustDelegate: nil,
              connectivityGrace: path,
              firstContactGrace: firstContact)
}

/// Runs `listGuests` and reports how long it took to fail.
func timeToFailure(_ client: PVEClient) async -> (seconds: TimeInterval, error: String)? {
    let started = Date()
    do {
        _ = try await client.listGuests()
        return nil
    } catch {
        return (Date().timeIntervalSince(started), String(describing: error))
    }
}

let semaphore = DispatchSemaphore(value: 0)

Task {
    // --- silent: accepts, then nothing ---------------------------------------------
    let silent = startSilentListener(port: 18099)
    defer { silent.cancel() }

    if let result = await timeToFailure(client(host: "127.0.0.1", port: 18099)) {
        expect(result.seconds < 15,
               "a silent server took \(Int(result.seconds))s to fail — the first-contact bound did not fire")
        expect(result.error.contains("did not respond"),
               "a silent server should say it did not respond, said: \(result.error)")
        print(String(format: "  silent server failed after %.1fs", result.seconds))
    } else {
        expect(false, "a silent server somehow returned a guest list")
    }

    // --- refused: nothing listening -------------------------------------------------
    // Measured: with `waitsForConnectivity` on, URLSession reports a refusal as waiting
    // for connectivity rather than returning cannotConnectToHost, so this arrives through
    // the path bound and not as an instant error. The message therefore has to name both
    // causes — blaming the network for a wrong port sends people to check a working VPN.
    if let result = await timeToFailure(client(host: "127.0.0.1", port: 18098)) {
        expect(result.seconds < 10,
               "a refused connection took \(Int(result.seconds))s to fail")
        expect(result.error.contains("Nothing may be listening"),
               "a refusal must offer “nothing listening” as a cause, said: \(result.error)")
        expect(result.error.contains("did not respond") == false,
               "a refused connection must not be reported as a silent server: \(result.error)")
        print(String(format: "  refused connection failed after %.1fs", result.seconds))
    } else {
        expect(false, "a refused connection somehow returned a guest list")
    }

    // --- unroutable: TEST-NET-1, reserved and not routed ----------------------------
    if let result = await timeToFailure(client(host: "192.0.2.1", port: 8006)) {
        expect(result.seconds < 20,
               "an unroutable address took \(Int(result.seconds))s to fail")
        print(String(format: "  unroutable address failed after %.1fs", result.seconds))
    } else {
        expect(false, "an unroutable address somehow returned a guest list")
    }

    semaphore.signal()
}

print("PVEClient reachability checks")
if semaphore.wait(timeout: .now() + 120) == .timedOut {
    print("  the checks themselves hung — something is not bounded at all")
    exit(1)
}
print("")
for failure in failures { print("  FAIL \(failure)") }
print("\(passed) passed, \(failures.count) failed")
exit(failures.isEmpty ? 0 : 1)
