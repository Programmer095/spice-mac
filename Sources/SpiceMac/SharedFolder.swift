// SPDX-License-Identifier: MIT
import AppKit

/// The host directory offered to guests over SPICE's WebDAV channel.
///
/// Stored as a security-scoped bookmark rather than a path so the choice survives a
/// move or rename, and so it still works if the app is later built sandboxed.
enum SharedFolder {
    private static let bookmarkKey = "SharedFolderBookmark"
    private static let readOnlyKey = "SharedFolderReadOnly"

    /// Read-only by default: a writable share lets a compromised guest write onto
    /// the Mac, which is the reason upstream's automatic share was disabled.
    static var isReadOnly: Bool {
        get { (UserDefaults.standard.object(forKey: readOnlyKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: readOnlyKey) }
    }

    static var url: URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data,
                                      options: [.withSecurityScope],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &stale) else { return nil }
        if stale { store(resolved) }
        return resolved
    }

    static func store(_ url: URL?) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return
        }
        let data = try? url.bookmarkData(options: [.withSecurityScope],
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    /// Path to hand to `SpiceClient.sharedDirectory`, having taken access.
    ///
    /// The returned access token must be released when the session ends, so callers
    /// hold it for the lifetime of the connection. Outside the sandbox
    /// `startAccessingSecurityScopedResource` returns false and the path still works.
    static func currentPath() -> (path: String, readOnly: Bool, accessed: URL?)? {
        guard let url else { return nil }
        let accessed = url.startAccessingSecurityScopedResource() ? url : nil
        return (url.path, isReadOnly, accessed)
    }

    static func choose(relativeTo window: NSWindow?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Share"
        panel.message = "Choose a folder to share with guests. It appears in the guest as a network drive (the guest must run spice-webdavd)."
        panel.directoryURL = url
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        store(chosen)
        return chosen
    }
}
