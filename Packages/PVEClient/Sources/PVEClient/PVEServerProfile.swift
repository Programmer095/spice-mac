// SPDX-License-Identifier: MIT
import Foundation

/// One configured Proxmox server. Carries the non-secret half only: the matching
/// secret lives in the host platform's keychain under `keychainAccount`, so this type
/// stays free of any platform framework.
public struct PVEServerProfile: Codable, Equatable, Identifiable, Sendable {
    public enum AuthKind: String, Codable, Equatable, Sendable {
        case apiToken
        case password
    }

    public var id: UUID
    public var label: String
    public var host: String
    public var port: Int
    public var authKind: AuthKind
    /// Full token identifier, e.g. `root@pam!spicemac`.
    public var tokenID: String
    public var username: String
    public var realm: String
    public var rememberSecret: Bool

    public init(id: UUID = UUID(),
                label: String = "",
                host: String = "",
                port: Int = 8006,
                authKind: AuthKind = .apiToken,
                tokenID: String = "",
                username: String = "root",
                realm: String = "pam",
                rememberSecret: Bool = true) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.authKind = authKind
        self.tokenID = tokenID
        self.username = username
        self.realm = realm
        self.rememberSecret = rememberSecret
    }

    public var server: PVEServer { PVEServer(host: host, port: port) }

    public var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }

    /// Scoped by server and user so one cluster can hold several tokens, and several
    /// clusters can hold identically-named ones, without colliding.
    public var keychainAccount: String {
        let user = authKind == .apiToken ? tokenID : "\(username)@\(realm)"
        return "\(host):\(port)|\(user)"
    }

    public var isComplete: Bool {
        guard host.trimmingCharacters(in: .whitespaces).isEmpty == false else { return false }
        switch authKind {
        case .apiToken: return tokenID.contains("@") && tokenID.contains("!")
        case .password: return username.trimmingCharacters(in: .whitespaces).isEmpty == false
        }
    }

    public func credentials(secret: String) -> PVECredentials {
        switch authKind {
        case .apiToken: return .apiToken(id: tokenID, secret: secret)
        case .password: return .password(username: username, realm: realm, password: secret)
        }
    }
}

extension PVEServerProfile {
    /// Decode the pre-fleet single-profile record into a one-element fleet.
    ///
    /// The legacy record had no `id` or `label`, and its keychain account was derived
    /// from host/port/user exactly as `keychainAccount` still does — so a migrated
    /// profile finds the existing secret without the user re-entering it.
    public static func migratingLegacy(_ data: Data?) -> [PVEServerProfile] {
        struct Legacy: Decodable {
            let host: String?
            let port: Int?
            let authKind: AuthKind?
            let tokenID: String?
            let username: String?
            let realm: String?
            let rememberSecret: Bool?
        }
        guard let data, let old = try? JSONDecoder().decode(Legacy.self, from: data) else {
            return []
        }
        let profile = PVEServerProfile(label: "",
                                       host: old.host ?? "",
                                       port: old.port ?? 8006,
                                       authKind: old.authKind ?? .apiToken,
                                       tokenID: old.tokenID ?? "",
                                       username: old.username ?? "root",
                                       realm: old.realm ?? "pam",
                                       rememberSecret: old.rememberSecret ?? true)
        return profile.isComplete ? [profile] : []
    }
}
