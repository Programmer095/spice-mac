// SPDX-License-Identifier: MIT
import AppKit
import PVEClient

/// Asks for a server's secret when nothing is stored for it.
///
/// Turning off "Remember in Keychain" has to mean "ask me each time"; without this it
/// would mean "this server can never be signed in again", reported as a credentials
/// failure that is not one. Raised through the fleet's prompt queue, so several
/// servers signing in at once cannot stack these.
@MainActor
enum PVESecretPrompt {
    static func ask(for profile: PVEServerProfile) -> String? {
        let usingToken = profile.authKind == .apiToken

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enter the \(usingToken ? "token secret" : "password") for “\(profile.displayName)”"
        alert.informativeText = """
            SpiceMac has no stored secret for this server, so it is asking once for \
            this sign-in. Signing in as \(profile.credentials(secret: "").displayUser).

            To stop being asked, turn on “Remember in Keychain” for it in Manage Servers.
            """

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = usingToken ? "token secret (UUID)" : "password"
        alert.accessoryView = field

        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let entered = field.stringValue
        return entered.isEmpty ? nil : entered
    }
}
