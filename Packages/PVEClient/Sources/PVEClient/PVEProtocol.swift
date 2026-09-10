// SPDX-License-Identifier: MIT
import Foundation

/// The pure, network-free half of the Proxmox API binding: URL construction, header
/// and form encoding, and response decoding. Kept separate from `PVEClient` so the
/// wire format is unit-testable without a server (see `swift run pvecheck`).
public enum PVEProtocol {

    // MARK: - Authorization

    /// The `Authorization` value for API-token auth: `PVEAPIToken=<id>=<secret>`.
    /// Proxmox token IDs are `user@realm!tokenname`; anything else is rejected here
    /// rather than producing a confusing 401 from the server.
    public static func authorizationHeader(tokenID: String, secret: String) throws -> String {
        let id = tokenID.trimmingCharacters(in: .whitespaces)
        guard id.contains("@"), let bang = id.firstIndex(of: "!"),
              bang != id.startIndex, id.index(after: bang) != id.endIndex else {
            throw PVEError.malformedTokenID(tokenID)
        }
        return "PVEAPIToken=\(id)=\(secret.trimmingCharacters(in: .whitespaces))"
    }

    // MARK: - Paths

    public static func ticketPath() -> String { "/api2/json/access/ticket" }

    public static func guestListPath() -> String { "/api2/json/cluster/resources?type=vm" }

    public static func permissionsPath() -> String { "/api2/json/access/permissions" }

    /// The SPICE endpoint. NB: `/api2/spiceconfig/` (not `/api2/json/`) is what makes
    /// Proxmox emit a ready-to-use `[virt-viewer]` INI file rather than JSON.
    public static func spiceProxyPath(node: String, vmid: Int, kind: PVEGuest.Kind) -> String {
        let encodedNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        return "/api2/spiceconfig/nodes/\(encodedNode)/\(kind.rawValue)/\(vmid)/spiceproxy"
    }

    // MARK: - Encoding

    /// `application/x-www-form-urlencoded` body. Sorted for deterministic tests.
    public static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.keys.sorted().map { key -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = (fields[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(k)=\(v)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }

    // MARK: - Decoding

    private struct Envelope<T: Decodable>: Decodable { let data: T? }

    private struct TicketPayload: Decodable {
        let ticket: String?
        let CSRFPreventionToken: String?
        let username: String?
    }

    public static func decodeTicket(_ data: Data) throws -> PVETicket {
        guard let payload = try? JSONDecoder().decode(Envelope<TicketPayload>.self, from: data).data,
              let ticket = payload.ticket, let csrf = payload.CSRFPreventionToken else {
            throw PVEError.decoding("no ticket in the /access/ticket response")
        }
        return PVETicket(ticket: ticket, csrfToken: csrf, username: payload.username ?? "")
    }

    private struct ResourcePayload: Decodable {
        let vmid: Int?
        let name: String?
        let node: String?
        let status: String?
        let type: String?
    }

    /// Decode `/cluster/resources?type=vm`, keeping only qemu/lxc guests, sorted by
    /// vmid. Entries missing a vmid/node (or of an unexpected type) are skipped rather
    /// than failing the whole listing — a cluster can contain resources we don't model.
    public static func decodeGuests(_ data: Data) throws -> [PVEGuest] {
        guard let rows = try? JSONDecoder().decode(Envelope<[ResourcePayload]>.self, from: data).data else {
            throw PVEError.decoding("unexpected /cluster/resources payload")
        }
        return rows.compactMap { row -> PVEGuest? in
            guard let vmid = row.vmid, let node = row.node,
                  let kind = row.type.flatMap(PVEGuest.Kind.init(rawValue:)) else { return nil }
            return PVEGuest(vmid: vmid,
                            name: row.name ?? "vm-\(vmid)",
                            node: node,
                            status: row.status ?? "unknown",
                            kind: kind)
        }
        .sorted { $0.vmid < $1.vmid }
    }

    /// The ACL paths the current token can see, from `/access/permissions`.
    ///
    /// An empty result is the signature of a privilege-separated token with no ACL:
    /// Proxmox filters `/cluster/resources` by permission and returns an empty array
    /// rather than a 403, so without this the caller cannot tell "no rights" from
    /// "no VMs".
    /// Whether any visible ACL path grants a privilege allowing guests to be listed.
    public static func grantsGuestVisibility(_ payload: [String: [String: Int]]) -> Bool {
        payload.values.contains { privileges in
            privileges.contains { $0.key == "VM.Audit" && $0.value != 0 }
        }
    }

    public static func decodePermissions(_ data: Data) throws -> [String: [String: Int]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any] else {
            throw PVEError.decoding("unexpected /access/permissions payload")
        }
        var result: [String: [String: Int]] = [:]
        for (path, value) in payload {
            if let privileges = value as? [String: Int] {
                result[path] = privileges
            } else if let privileges = value as? [String: Bool] {
                result[path] = privileges.mapValues { $0 ? 1 : 0 }
            }
        }
        return result
    }

    /// Proxmox reports API errors as JSON even on some 2xx paths; surface the message.
    public static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(200), as: UTF8.self)
        }
        if let errors = object["errors"] as? [String: Any], errors.isEmpty == false {
            return errors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
        }
        if let message = object["message"] as? String { return message }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    /// Sanity-check that a spiceproxy response really is a `.vv` before handing it to
    /// the parser, so an HTML error page produces a clear message instead of a parse error.
    public static func validateSpiceConfig(_ text: String) throws {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("[virt-viewer]") else {
            throw PVEError.notSpiceConfig(String(head.prefix(120)))
        }
    }
}
