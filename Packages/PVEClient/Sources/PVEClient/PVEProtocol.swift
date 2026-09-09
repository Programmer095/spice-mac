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

    /// Storage contents of one type on a node, e.g. the ISO images available to attach.
    public static func storageContentPath(node: String, storage: String, content: String) -> String {
        let encodedNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        let encodedStorage = storage.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? storage
        return "/api2/json/nodes/\(encodedNode)/storage/\(encodedStorage)/content?content=\(content)"
    }

    /// The storages visible to a node.
    public static func storageListPath(node: String) -> String {
        let encodedNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        return "/api2/json/nodes/\(encodedNode)/storage"
    }

    /// A guest's config endpoint — the same path attaches and detaches a CD-ROM.
    public static func configPath(node: String, vmid: Int, kind: PVEGuest.Kind) -> String {
        let encodedNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        return "/api2/json/nodes/\(encodedNode)/\(kind.rawValue)/\(vmid)/config"
    }

    // MARK: - Permissions

    /// The ACL paths that govern `guest`, most general first. Proxmox applies the most
    /// specific matching ACL, but for "may I do this at all" any of them granting the
    /// privilege is enough.
    public static func aclPaths(forVMID vmid: Int) -> [String] {
        ["/", "/vms", "/vms/\(vmid)"]
    }

    /// Whether the token holds `privilege` over `vmid`.
    ///
    /// Checked before offering an action rather than after attempting one: a token
    /// without the privilege signs in, lists guests and looks entirely healthy right up
    /// to the point the write 403s.
    public static func grants(_ privilege: String,
                              forVMID vmid: Int,
                              in payload: [String: [String: Int]]) -> Bool {
        let governing = Set(aclPaths(forVMID: vmid))
        return payload.contains { path, privileges in
            governing.contains(path) && privileges[privilege].map { $0 != 0 } == true
        }
    }

    // MARK: - ISO images

    /// The `ide2` value that attaches `volumeID` as a CD-ROM.
    public static func cdromAttachValue(volumeID: String) -> String {
        "\(volumeID),media=cdrom"
    }

    /// The `ide2` value that leaves the drive present but empty. Proxmox distinguishes
    /// this from deleting the device, and an empty drive is what a guest expects to see
    /// after an eject.
    public static func cdromDetachValue() -> String { "none,media=cdrom" }

    /// Volume IDs of the ISO images in a storage-content payload.
    public static func decodeISOVolumeIDs(_ data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw PVEError.decoding("unexpected storage content payload")
        }
        return rows.compactMap { $0["volid"] as? String }.sorted()
    }

    /// Every storage name in the payload, whatever it holds.
    public static func decodeStorageNames(_ data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw PVEError.decoding("unexpected storage list payload")
        }
        return rows.compactMap { $0["storage"] as? String }.sorted()
    }

    /// Names of the storages on a node that advertise `content`, e.g. `iso`.
    public static func decodeStorages(advertising content: String, from data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw PVEError.decoding("unexpected storage list payload")
        }
        return rows.compactMap { row -> String? in
            guard let name = row["storage"] as? String,
                  let advertised = row["content"] as? String,
                  advertised.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == content })
            else { return nil }
            return name
        }.sorted()
    }

    /// The filename a volume ID ends in — `local:iso/debian-12.iso` reads as
    /// `debian-12.iso` in a menu.
    public static func isoDisplayName(forVolumeID volumeID: String) -> String {
        volumeID.split(separator: "/").last.map(String.init) ?? volumeID
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
