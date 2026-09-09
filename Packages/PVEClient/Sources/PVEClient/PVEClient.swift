// SPDX-License-Identifier: MIT
import Foundation

/// A minimal Proxmox VE API client: enough to list guests and mint a SPICE ticket.
///
/// Deliberately not a general PVE binding — it covers exactly what the connect sheet
/// needs, using only Foundation so the package stays dependency-free and its wire
/// format stays unit-testable (see `PVEProtocol`).
public final class PVEClient {
    public let server: PVEServer
    private let credentials: PVECredentials
    private let session: URLSession

    /// Cached login ticket for password auth. API tokens need no session state, which
    /// is the main reason to prefer them: a reconnect hours later still works.
    private var ticket: PVETicket?

    private let connectivity: PVEConnectivitySignal
    /// How long a request may sit with no network path before giving up. Seconds, not
    /// the resource timeout's minutes: nothing here is waiting on a person, and the case
    /// `waitsForConnectivity` exists for — a path still coming up at launch — resolves
    /// well inside this.
    private static let connectivityGrace: TimeInterval = 6

    public init(server: PVEServer, credentials: PVECredentials, trustDelegate: PVETrustDelegate?) {
        self.server = server
        self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        // A freshly launched process can fire its first request before the system has
        // finished establishing a network path, which fails instantly as
        // notConnectedToInternet even though the network is fine. Wait for the path
        // instead of failing. That wait is bounded in `fetch` rather than here: left to
        // `timeoutIntervalForResource` it parks a path that is never coming for three
        // silent minutes.
        configuration.waitsForConnectivity = true
        // Generous because a TLS challenge can be waiting on a human: the first
        // connection to a self-signed node shows a fingerprint to confirm, and the
        // request's clock is running the whole time it is on screen.
        configuration.timeoutIntervalForRequest = 120
        // Upper bound on the whole operation, including any connectivity wait above.
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let evaluator = PVETrustEvaluator(delegate: trustDelegate)
        self.connectivity = evaluator.connectivity
        self.session = URLSession(configuration: configuration,
                                  delegate: evaluator,
                                  delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: - Public API

    /// Round-trip the credentials so the connect sheet can report a problem before it
    /// shows an empty VM list.
    @discardableResult
    public func verifyCredentials() async throws -> String {
        _ = try await listGuests()
        return credentials.displayUser
    }

    public func listGuests() async throws -> [PVEGuest] {
        let (data, _) = try await perform(path: PVEProtocol.guestListPath(), method: "GET", body: nil)
        return try PVEProtocol.decodeGuests(data)
    }

    /// Fetch a fresh `.vv` for `guest`. The ticket inside is single-use and valid for
    /// roughly 30 seconds, so call this immediately before connecting — never cache it.
    public func spiceConfigText(for guest: PVEGuest) async throws -> String {
        let path = PVEProtocol.spiceProxyPath(node: guest.node, vmid: guest.vmid, kind: guest.kind)
        // `proxy` tells Proxmox which host to put in the client-facing proxy URL. Without
        // it the node returns its own configured name, which may not resolve from here.
        let body = PVEProtocol.formBody(["proxy": server.host])
        let data: Data
        do {
            (data, _) = try await perform(path: path, method: "POST", body: body)
        } catch let error as PVEError {
            // A bare status code tells the user nothing, and the overwhelmingly common
            // cause is a guest with no SPICE display device at all.
            guard case .http(_, let reason) = error else { throw error }
            throw PVEError.spiceUnavailable(guest: "\(guest.name) (\(guest.vmid))",
                                            reason: reason.isEmpty ? "Proxmox reported an internal error." : reason)
        }
        let text = String(decoding: data, as: UTF8.self)
        try PVEProtocol.validateSpiceConfig(text)
        return text
    }

    /// Explain an empty guest list. Returns nil when the token can see guests and the
    /// cluster genuinely has none.
    public func diagnoseEmptyGuestList() async -> String? {
        let permissions: [String: [String: Int]]
        do {
            let (data, _) = try await perform(path: PVEProtocol.permissionsPath(), method: "GET", body: nil)
            permissions = try PVEProtocol.decodePermissions(data)
        } catch {
            return nil
        }

        if permissions.isEmpty {
            return """
                The credentials are valid but have no permissions on this cluster.

                An API token with Privilege Separation enabled (the default) starts with \
                no rights even when its user is root — it needs its own ACL entry.
                """
        }
        if PVEProtocol.grantsGuestVisibility(permissions) == false {
            let paths = permissions.keys.sorted().prefix(4).joined(separator: ", ")
            return """
                The credentials have permissions on \(paths), but none of them include \
                VM.Audit, which is what makes guests visible in the cluster listing.
                """
        }
        return nil
    }

    // MARK: - Privileges

    /// The token's visible ACL, cached for the life of the client. Permissions change
    /// rarely and a fresh fetch per menu open would cost a request every time.
    private var cachedPermissions: [String: [String: Int]]?

    public func permissions() async throws -> [String: [String: Int]] {
        if let cachedPermissions { return cachedPermissions }
        let (data, _) = try await perform(path: PVEProtocol.permissionsPath(), method: "GET", body: nil)
        let decoded = try PVEProtocol.decodePermissions(data)
        cachedPermissions = decoded
        return decoded
    }

    /// Whether this token may change `guest`'s CD-ROM.
    ///
    /// Worth asking before offering the action: `VM.Config.CDROM` is **not** in
    /// `PVEVMUser`, so the common token signs in, lists guests and drives consoles
    /// perfectly, and only fails when an ISO is attached. Offering a control that
    /// cannot work and explaining why beats a 403 after the fact.
    public func canConfigureCDROM(for guest: PVEGuest) async -> Bool {
        guard let permissions = try? await permissions() else { return false }
        return PVEProtocol.grants("VM.Config.CDROM", forVMID: guest.vmid, in: permissions)
    }

    // MARK: - ISO images

    /// The storages on `node` that can hold content of the given type.
    public func storages(advertising content: String, on node: String) async throws -> [String] {
        let (data, _) = try await perform(path: PVEProtocol.storageListPath(node: node),
                                          method: "GET", body: nil)
        return try PVEProtocol.decodeStorages(advertising: content, from: data)
    }

    /// Every ISO image on `node`, across the storages that advertise `iso` content —
    /// or why there are none.
    ///
    /// A storage that errors is skipped rather than failing the list: one unreachable
    /// NAS should not hide the images on local storage.
    public func listISOImages(node: String) async throws -> PVEISOAvailability {
        let (data, _) = try await perform(path: PVEProtocol.storageListPath(node: node),
                                          method: "GET", body: nil)
        // Empty before filtering by content type, not after: a node with storages that
        // simply hold no ISOs is a different answer from a node whose storages the token
        // cannot see at all.
        if try PVEProtocol.decodeStorageNames(data).isEmpty { return .noStorageVisible }

        let storages = try PVEProtocol.decodeStorages(advertising: "iso", from: data)
        var images: [PVEISOImage] = []
        for storage in storages {
            let path = PVEProtocol.storageContentPath(node: node, storage: storage, content: "iso")
            guard let (payload, _) = try? await perform(path: path, method: "GET", body: nil),
                  let volumes = try? PVEProtocol.decodeISOVolumeIDs(payload) else { continue }
            images.append(contentsOf: volumes.map { PVEISOImage(volumeID: $0, storage: storage) })
        }
        if images.isEmpty { return .noImages }
        return .images(images.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
    }

    @discardableResult
    public func attachISO(_ volumeID: String, to guest: PVEGuest) async throws -> String {
        try await writeCDROM(PVEProtocol.cdromAttachValue(volumeID: volumeID), to: guest)
    }

    @discardableResult
    public func detachISO(from guest: PVEGuest) async throws -> String {
        try await writeCDROM(PVEProtocol.cdromDetachValue(), to: guest)
    }

    private func writeCDROM(_ value: String, to guest: PVEGuest) async throws -> String {
        let path = PVEProtocol.configPath(node: guest.node, vmid: guest.vmid, kind: guest.kind)
        let body = PVEProtocol.formBody(["ide2": value])
        let (data, _) = try await perform(path: path, method: "POST", body: body)
        // An asynchronous config write returns a UPID; a synchronous one returns null.
        // Both are success, so a missing UPID is not an error — there is just nothing
        // for the caller to poll.
        return (try? PVEProtocol.decodeUPID(data)) ?? ""
    }

    // MARK: - Power management

    /// Ask Proxmox to perform `action` on `guest`. Returns the task id (UPID) — the
    /// call returns as soon as the task is *queued*, not when the guest has finished
    /// changing state, so follow it with `awaitTask`.
    @discardableResult
    public func performPower(_ action: PVEPowerAction, on guest: PVEGuest) async throws -> String {
        let path = PVEProtocol.powerPath(node: guest.node, vmid: guest.vmid,
                                         kind: guest.kind, action: action)
        let (data, _) = try await perform(path: path, method: "POST", body: Data())
        return try PVEProtocol.decodeUPID(data)
    }

    public func taskStatus(node: String, upid: String) async throws -> PVETaskStatus {
        let (data, _) = try await perform(path: PVEProtocol.taskStatusPath(node: node, upid: upid),
                                          method: "GET", body: nil)
        return try PVEProtocol.decodeTaskStatus(data)
    }

    /// Poll until the task finishes, then throw if it failed.
    ///
    /// A graceful shutdown waits on the guest OS, which can legitimately take a while
    /// (or never finish, if the guest ignores ACPI), so this gives up after `timeout`
    /// rather than hanging — the caller re-reads real state from the guest list anyway.
    public func awaitTask(node: String, upid: String, timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = try await taskStatus(node: node, upid: upid)
            if status.isRunning == false {
                if status.failed {
                    throw PVEError.http(status: 500, body: status.exitStatus ?? "task failed")
                }
                return
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        throw PVEError.transport("The task is still running on \(node) after \(Int(timeout))s. Check Proxmox for its progress.")
    }

    // MARK: - Request plumbing

    /// Whether a 401 is worth one more attempt. Proxmox login tickets last about two
    /// hours, so a fleet left open past that gets a 401 on a perfectly good password —
    /// the only case where retrying can help. A token 401 means a bad token, and a 403
    /// is a permissions problem; neither is fixed by trying again.
    public static func shouldRetryAfterExpiredTicket(status: Int,
                                                     credentials: PVECredentials,
                                                     hasTicket: Bool) -> Bool {
        guard status == 401, hasTicket else { return false }
        if case .password = credentials { return true }
        return false
    }

    private func perform(path: String, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        var (data, http) = try await send(path: path, method: method, body: body)
        if Self.shouldRetryAfterExpiredTicket(status: http.statusCode,
                                              credentials: credentials,
                                              hasTicket: ticket != nil) {
            ticket = nil
            (data, http) = try await send(path: path, method: method, body: body)
        }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401, 403:
            throw PVEError.unauthorized
        default:
            throw PVEError.http(status: http.statusCode, body: PVEProtocol.errorMessage(from: data))
        }
    }

    private func send(path: String, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        guard let baseURL = server.baseURL, let url = URL(string: path, relativeTo: baseURL) else {
            throw PVEError.invalidServer
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        try await applyAuthentication(to: &request, method: method)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch let error as PVEError {
            throw error                      // already phrased for a person; do not re-wrap
        } catch let error as URLError {
            throw PVEError.transport(describe(error))
        } catch {
            throw PVEError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PVEError.decoding("not an HTTP response")
        }
        return (data, http)
    }

    private func applyAuthentication(to request: inout URLRequest, method: String) async throws {
        switch credentials {
        case .apiToken(let id, let secret):
            request.setValue(try PVEProtocol.authorizationHeader(tokenID: id, secret: secret),
                             forHTTPHeaderField: "Authorization")
        case .password:
            let ticket = try await currentTicket()
            request.setValue("PVEAuthCookie=\(ticket.ticket)", forHTTPHeaderField: "Cookie")
            if method != "GET" {
                request.setValue(ticket.csrfToken, forHTTPHeaderField: "CSRFPreventionToken")
            }
        }
    }

    private func currentTicket() async throws -> PVETicket {
        if let ticket { return ticket }
        guard case .password(let username, let realm, let password) = credentials else {
            throw PVEError.unauthorized
        }
        guard let baseURL = server.baseURL,
              let url = URL(string: PVEProtocol.ticketPath(), relativeTo: baseURL) else {
            throw PVEError.invalidServer
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = PVEProtocol.formBody([
            "username": "\(username)@\(realm)",
            "password": password,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch let error as PVEError {
            throw error
        } catch let error as URLError {
            throw PVEError.transport(describe(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw PVEError.decoding("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 401 || http.statusCode == 403
                ? PVEError.unauthorized
                : PVEError.http(status: http.statusCode, body: PVEProtocol.errorMessage(from: data))
        }

        let fresh = try PVEProtocol.decodeTicket(data)
        ticket = fresh
        return fresh
    }

    /// `session.data(for:)`, with the connectivity wait bounded separately from the
    /// resource timeout. See `PVEConnectivitySignal` for why the two cannot share one
    /// deadline.
    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        connectivity.reset()
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { [session] in try await session.data(for: request) }
            group.addTask { [connectivity, server] in
                while Task.isCancelled == false {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    if connectivity.hasWaitedWithoutPath(longerThan: Self.connectivityGrace) {
                        throw PVEError.transport(
                            "No network path to \(server.host):\(server.port). "
                            + "Check the connection, VPN, or this app's local network access.")
                    }
                }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PVEError.transport("no response") }
            return first
        }
    }

    /// URLError codes users actually hit here, phrased as something actionable.
    private func describe(_ error: URLError) -> String {
        switch error.code {
        case .cancelled:
            return "The connection was cancelled because the server's TLS certificate was not trusted."
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "The server's TLS certificate was rejected."
        case .cannotFindHost:
            return "Could not resolve \(server.host)."
        case .cannotConnectToHost:
            return "Could not connect to \(server.host):\(server.port). Is Proxmox reachable from here?"
        case .timedOut:
            return "Timed out talking to \(server.host):\(server.port)."
        case .notConnectedToInternet:
            return "No network connection."
        default:
            return error.localizedDescription
        }
    }
}
