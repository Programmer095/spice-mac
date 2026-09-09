// SPDX-License-Identifier: MIT
import Foundation
import PVEClient

/// Everything needed to mint a *fresh* SPICE ticket for one guest, on demand.
///
/// This is what makes reconnecting possible at all: a Proxmox SPICE ticket is
/// single-use and expires in about 30 seconds, so a window can only come back by
/// asking the API for a new one — which means holding on to the client and the guest.
final class PVESessionSource {
    let guest: PVEGuest
    /// Also what the console's action bar acts through — power and CD-ROM writes go to
    /// the same authenticated client that mints the tickets.
    let client: PVEClient

    init(guest: PVEGuest, client: PVEClient) {
        self.guest = guest
        self.client = client
    }

    var displayName: String { "\(guest.name) (\(guest.vmid))" }

    func freshConfigText() async throws -> String {
        try await client.spiceConfigText(for: guest)
    }
}

/// Where a session came from, so a window can title itself and know whether it is able
/// to reconnect.
enum SpiceSessionOrigin {
    case file(URL)
    case proxmox(PVESessionSource)

    var displayName: String {
        switch self {
        case .file(let url): return url.deletingPathExtension().lastPathComponent
        case .proxmox(let source): return source.displayName
        }
    }

    var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }
}
