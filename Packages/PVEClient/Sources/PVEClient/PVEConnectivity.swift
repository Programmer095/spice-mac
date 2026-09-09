// SPDX-License-Identifier: MIT
import Foundation

/// Tracks whether a request is parked waiting for a usable network path.
///
/// `waitsForConnectivity` is on because a freshly launched process can fire its first
/// request before the system has finished bringing a path up, and failing that instantly
/// is wrong. The cost is that a path which is *never* coming — no route to the subnet,
/// a denied local-network grant, a VPN that is down — parks the request for the whole
/// `timeoutIntervalForResource`, which the user reads as a hang: three minutes of
/// "Signing in…" and no explanation.
///
/// The two waits are distinguishable, and only one of them deserves patience. Waiting
/// for a path involves no human and should be given seconds. Waiting at the
/// trust-on-first-use fingerprint dialog *is* a human and must keep the long ceiling.
/// They are also ordered — the certificate challenge cannot arrive until a path exists —
/// so reaching the server closes the short window for good.
public final class PVEConnectivitySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var waitingSince: Date?
    private var reached = false

    public init() {}

    public func beganWaitingForPath() {
        lock.lock(); defer { lock.unlock() }
        guard reached == false, waitingSince == nil else { return }
        waitingSince = Date()
    }

    public func reachedServer() {
        lock.lock(); defer { lock.unlock() }
        reached = true
        waitingSince = nil
    }

    /// True once the request has been parked with no path for longer than `grace` and
    /// has still never reached the server.
    public func hasWaitedWithoutPath(longerThan grace: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard reached == false, let since = waitingSince else { return false }
        return now.timeIntervalSince(since) >= grace
    }

    /// Per-request state, so one request's verdict does not carry into the next.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        waitingSince = nil
        reached = false
    }
}
