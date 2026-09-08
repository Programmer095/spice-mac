// SPDX-License-Identifier: MIT
import AppKit

/// The trust-on-first-use dialog. Shown once per server; afterwards only that exact
/// certificate is accepted, so a swapped certificate resurfaces this — loudly.
@MainActor
enum PVECertificatePrompt {
    static func ask(host: String, fingerprint: String, isChange: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = isChange ? .critical : .warning

        if isChange {
            alert.messageText = "The certificate for “\(host)” has changed"
            alert.informativeText = """
                This server previously presented a different certificate. That happens \
                after a legitimate certificate renewal — but it is also what an \
                interception attack looks like.

                New SHA-256 fingerprint:
                \(fingerprint)

                Only continue if you changed the certificate yourself. You can compare \
                this against the Proxmox web UI under Datacenter ▸ Certificates.
                """
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Trust New Certificate")
            // Cancel is first, so it takes Return. The dangerous button needs a deliberate click.
            return alert.runModal() == .alertSecondButtonReturn
        }

        alert.messageText = "Trust the certificate for “\(host)”?"
        alert.informativeText = """
            Proxmox VE uses a self-signed certificate unless you have installed your own, \
            so this cannot be verified automatically.

            SHA-256 fingerprint:
            \(fingerprint)

            Compare it with Datacenter ▸ Certificates in the Proxmox web UI. If it \
            matches, SpiceMac will remember it and refuse any other certificate for \
            this server from now on.
            """
        alert.addButton(withTitle: "Trust")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
