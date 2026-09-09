// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Security

/// Decides whether to trust a Proxmox node's TLS certificate.
///
/// Proxmox ships a self-signed cluster CA by default, so a stock install fails normal
/// chain validation. Rather than a blanket "allow insecure" switch — which silently
/// accepts *any* certificate forever, including an attacker's — this uses
/// trust-on-first-use: the certificate's SHA-256 is shown once, and once the user
/// accepts it, only that exact certificate is accepted afterwards. A later change is
/// surfaced as a warning instead of being waved through.
public protocol PVETrustDelegate: AnyObject {
    /// The pinned fingerprint for `host`, if the user has accepted one before.
    func pinnedFingerprint(forHost host: String) -> String?

    /// Ask the user about a certificate that isn't CA-valid and isn't pinned.
    /// `isChange` is true when a *different* certificate was pinned before — that is
    /// the case worth alarming about. Return true to accept and pin it.
    func shouldTrustCertificate(host: String, fingerprint: String, isChange: Bool) async -> Bool

    func pinCertificate(fingerprint: String, forHost host: String)
}

/// SHA-256 of the DER encoding, formatted like the fingerprint Proxmox shows in its UI
/// (uppercase hex, colon-separated) so the two can be compared by eye.
public func pveFingerprint(of certificate: SecCertificate) -> String {
    let der = SecCertificateCopyData(certificate) as Data
    return SHA256.hash(data: der)
        .map { String(format: "%02X", $0) }
        .joined(separator: ":")
}

/// URLSession delegate implementing the policy above.
final class PVETrustEvaluator: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private weak var delegate: PVETrustDelegate?
    let connectivity: PVEConnectivitySignal

    init(delegate: PVETrustDelegate?, connectivity: PVEConnectivitySignal = PVEConnectivitySignal()) {
        self.delegate = delegate
        self.connectivity = connectivity
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        connectivity.beganWaitingForPath()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // A challenge means bytes have crossed to the node, so any remaining wait is on
        // a person, not on the network.
        connectivity.reachedServer()
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // A properly CA-signed certificate (reverse proxy, ACME, an imported cluster CA)
        // needs no prompting — take the normal path.
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let fingerprint = pveFingerprint(of: leaf)

        guard let delegate else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let pinned = delegate.pinnedFingerprint(forHost: host)
        if let pinned, pinned.caseInsensitiveCompare(fingerprint) == .orderedSame {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        let isChange = (pinned != nil)
        Task { @MainActor in
            let accepted = await delegate.shouldTrustCertificate(host: host,
                                                                 fingerprint: fingerprint,
                                                                 isChange: isChange)
            if accepted {
                delegate.pinCertificate(fingerprint: fingerprint, forHost: host)
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
