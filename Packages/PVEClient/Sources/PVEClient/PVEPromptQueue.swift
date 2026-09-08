// SPDX-License-Identifier: MIT
import Foundation

/// Serialises work that blocks on a human.
///
/// Signing in to a fleet is concurrent, but certificate approval and keychain access
/// both put a dialog in front of the user. Without this, N servers means N modals
/// racing each other at launch.
public actor PVEPromptQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ work: @Sendable @escaping () async -> T) async -> T {
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}
