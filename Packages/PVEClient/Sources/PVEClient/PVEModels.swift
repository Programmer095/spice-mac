// SPDX-License-Identifier: MIT
import Foundation

/// A Proxmox VE API endpoint. `host` is the node (or cluster VIP) the web UI runs on;
/// it is also what gets sent as the `proxy=` parameter when requesting a SPICE ticket,
/// because Proxmox builds the client-facing proxy URL from it.
public struct PVEServer: Equatable, Sendable, Codable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 8006) {
        self.host = host
        self.port = port
    }

    /// `https://host:port` — nil when `host` is empty or unrepresentable in a URL.
    public var baseURL: URL? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = trimmed
        components.port = port
        return components.url
    }
}

/// How to authenticate. API tokens are preferred: they can be scoped to `VM.Console`
/// alone and revoked independently, and unlike a login ticket they never expire, so a
/// reconnect hours later still works without re-prompting.
public enum PVECredentials: Equatable, Sendable {
    /// `id` is the full token identifier, e.g. `root@pam!spicemac`.
    case apiToken(id: String, secret: String)
    case password(username: String, realm: String, password: String)

    /// The `user@realm` this credential authenticates as, for display.
    public var displayUser: String {
        switch self {
        case .apiToken(let id, _): return id
        case .password(let username, let realm, _): return "\(username)@\(realm)"
        }
    }
}

/// A login ticket from `/access/ticket`. Valid ~2h; the CSRF token is required for
/// any non-GET request made with cookie auth.
public struct PVETicket: Equatable, Sendable {
    public var ticket: String
    public var csrfToken: String
    public var username: String

    public init(ticket: String, csrfToken: String, username: String) {
        self.ticket = ticket
        self.csrfToken = csrfToken
        self.username = username
    }
}

/// A guest returned by `/cluster/resources?type=vm`.
public struct PVEGuest: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case qemu
        case lxc
    }

    public var vmid: Int
    public var name: String
    public var node: String
    public var status: String
    public var kind: Kind

    public var id: String { "\(node)/\(kind.rawValue)/\(vmid)" }
    public var isRunning: Bool { status.lowercased() == "running" }

    public init(vmid: Int, name: String, node: String, status: String, kind: Kind) {
        self.vmid = vmid
        self.name = name
        self.node = node
        self.status = status
        self.kind = kind
    }
}

public enum PVEError: LocalizedError, Equatable, CustomStringConvertible {
    case invalidServer
    case malformedTokenID(String)
    case http(status: Int, body: String)
    case unauthorized
    /// No secret could be obtained for a server — nothing stored, and either nothing
    /// asked the user for one or they declined.
    case secretUnavailable(server: String)
    case decoding(String)
    case notSpiceConfig(String)
    case spiceUnavailable(guest: String, reason: String)
    case certificateRejected(host: String, fingerprint: String)
    case transport(String)

    public var description: String {
        switch self {
        case .invalidServer:
            return "The server address is not a valid host name."
        case .malformedTokenID(let id):
            return """
                “\(id)” is not a valid API token ID. \
                Expected the full identifier, e.g. root@pam!spicemac.
                """
        case .http(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Proxmox returned HTTP \(status)."
                                  : "Proxmox returned HTTP \(status): \(detail)"
        case .unauthorized:
            return "Proxmox rejected the credentials. Check the token ID and secret, or the username, realm and password."
        case .secretUnavailable(let server):
            return """
                No secret is stored for \(server), and none was entered. \
                Turn on “Remember in Keychain” for it in Manage Servers, or enter the \
                secret when asked.
                """
        case .decoding(let what):
            return "Could not read the Proxmox response: \(what)"
        case .notSpiceConfig(let head):
            return "Proxmox did not return a SPICE connection file. It replied: \(head)"
        case .spiceUnavailable(let guest, let reason):
            return """
                Proxmox would not open a SPICE console for \(guest).

                \(reason)

                The usual cause is the guest's Display not being set to SPICE. A VM \
                created with the default “Standard VGA” has no SPICE console — only \
                noVNC. On the Proxmox node:

                    qm set <vmid> --vga qxl

                then fully stop and start the VM (a reboot from inside the guest does \
                not re-create the display device).
                """
        case .certificateRejected(let host, let fingerprint):
            return "The TLS certificate for \(host) was not trusted (SHA-256 \(fingerprint))."
        case .transport(let message):
            return message
        }
    }

    /// Without this, `localizedDescription` on a `PVEError` is Foundation's generic
    /// "The operation couldn't be completed. (… error N.)" — which is what reaches any
    /// presenter that does not know to reach for `description` first.
    public var errorDescription: String? { description }
}
