// SPDX-License-Identifier: MIT
import AppKit

// SwiftPM executable entry point for an AppKit app (no storyboard/nib).
let app = NSApplication.shared

// Layout checks: build the windows, measure them, exit. No delegate, so nothing signs
// in, opens a console or touches the Keychain. See UICheck and `make uicheck`.
if CommandLine.arguments.contains("--ui-check") {
    let snapshotDirectory = CommandLine.arguments.last.flatMap { $0 == "--ui-check" ? nil : $0 }
    MainActor.assumeIsolated { UICheck.run(snapshotDirectory: snapshotDirectory) }
}

app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
