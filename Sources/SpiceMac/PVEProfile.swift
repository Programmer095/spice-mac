// SPDX-License-Identifier: MIT
import Foundation
import OSLog
import PVEClient

/// Persistence for the configured fleet and the trust-on-first-use certificate pins.
///
/// Also the app's `PVETrustDelegate`: it answers with the pinned fingerprint, and
/// escalates anything unknown to a modal so the user makes the call, rather than the
/// app silently accepting whatever certificate it is handed.
final class PVEProfileStore: PVETrustDelegate {
    static let shared = PVEProfileStore()

    private let pinsKey = "ProxmoxCertificatePins"

    private init() {}

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

extension PVEProfileStore {
    private var profilesKey: String { "ProxmoxProfiles" }
    private var legacyKey: String { "ProxmoxProfile" }

    /// The configured fleet. On first read after upgrading, the pre-fleet single
    /// profile is migrated in; the old key is left untouched so a downgrade still finds it.
    var profiles: [PVEServerProfile] {
        get {
            if let data = UserDefaults.standard.data(forKey: profilesKey),
               let decoded = try? JSONDecoder().decode([PVEServerProfile].self, from: data) {
                return decoded
            }
            let migrated = PVEServerProfile.migratingLegacy(
                UserDefaults.standard.data(forKey: legacyKey))
            if migrated.isEmpty == false { self.profiles = migrated }
            return migrated
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    func secret(for profile: PVEServerProfile) -> String? {
        guard profile.rememberSecret else { return nil }
        return PVEKeychain.secret(account: profile.keychainAccount)
    }

    func setSecret(_ secret: String, for profile: PVEServerProfile) {
        guard profile.rememberSecret, secret.isEmpty == false else {
            PVEKeychain.delete(account: profile.keychainAccount)
            return
        }
        PVEKeychain.save(secret: secret, account: profile.keychainAccount)
    }
}
