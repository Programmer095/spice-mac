// SPDX-License-Identifier: MIT
import Foundation
import OSLog
import PVEClient

/// The non-secret half of a saved Proxmox connection. The matching secret lives in
/// the Keychain (see `PVEKeychain`) and is never written here.
struct PVEProfile: Codable, Equatable {
    enum AuthKind: String, Codable {
        case apiToken
        case password
    }

    var host: String = ""
    var port: Int = 8006
    var authKind: AuthKind = .apiToken
    /// Full token identifier, e.g. `root@pam!spicemac`.
    var tokenID: String = ""
    var username: String = "root"
    var realm: String = "pam"
    var rememberSecret: Bool = true

    var server: PVEServer { PVEServer(host: host, port: port) }

    /// The account name used for the Keychain item.
    var keychainAccount: String {
        let user = authKind == .apiToken ? tokenID : "\(username)@\(realm)"
        return PVEKeychain.account(host: host, port: port, user: user)
    }

    func credentials(secret: String) -> PVECredentials {
        switch authKind {
        case .apiToken:
            return .apiToken(id: tokenID, secret: secret)
        case .password:
            return .password(username: username, realm: realm, password: secret)
        }
    }

    var isComplete: Bool {
        guard host.trimmingCharacters(in: .whitespaces).isEmpty == false else { return false }
        switch authKind {
        case .apiToken: return tokenID.contains("!") && tokenID.contains("@")
        case .password: return username.isEmpty == false
        }
    }
}

/// Persistence for the saved profile and the trust-on-first-use certificate pins.
///
/// Also the app's `PVETrustDelegate`: it answers with the pinned fingerprint, and
/// escalates anything unknown to a modal so the user makes the call, rather than the
/// app silently accepting whatever certificate it is handed.
final class PVEProfileStore: PVETrustDelegate {
    static let shared = PVEProfileStore()

    private let profileKey = "ProxmoxProfile"
    private let pinsKey = "ProxmoxCertificatePins"

    private init() {}

    var profile: PVEProfile? {
        get {
            guard let data = UserDefaults.standard.data(forKey: profileKey) else { return nil }
            return try? JSONDecoder().decode(PVEProfile.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: profileKey)
                return
            }
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    // MARK: - PVETrustDelegate

    private var pins: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: pinsKey) }
    }

    private static let log = Logger(subsystem: "org.spicemac.SpiceMac", category: "trust")

    func pinnedFingerprint(forHost host: String) -> String? {
        let pin = pins[host.lowercased()]
        Self.log.info("trust check for \(host, privacy: .public): \(pin == nil ? "no pin stored" : "pin found", privacy: .public)")
        return pin
    }

    func pinCertificate(fingerprint: String, forHost host: String) {
        Self.log.info("pinning certificate for \(host, privacy: .public)")
        var updated = pins
        updated[host.lowercased()] = fingerprint
        pins = updated
    }

    func forgetPin(forHost host: String) {
        var updated = pins
        updated.removeValue(forKey: host.lowercased())
        pins = updated
    }

    @MainActor
    func shouldTrustCertificate(host: String, fingerprint: String, isChange: Bool) async -> Bool {
        PVECertificatePrompt.ask(host: host, fingerprint: fingerprint, isChange: isChange)
    }
}
