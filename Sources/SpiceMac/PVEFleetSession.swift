// SPDX-License-Identifier: MIT
import AppKit
import PVEClient

/// The app's one fleet, and the platform wiring it needs.
///
/// The connect tab and every console overlay are views onto the same servers: signing in
/// from one must light up the other, and neither should mint its own clients. The
/// coordinator used to belong to `PVEConnectWindowController`, which made it reachable
/// only from the window that happened to own it.
///
/// `PVEFleetCoordinator.onChange` is a single closure, so this multiplexes it — several
/// observers, each dropped when its token goes away.
@MainActor
final class PVEFleetSession {
    static let shared = PVEFleetSession(coordinator: PVEFleetCoordinator(
        trustDelegate: PVEProfileStore.shared,
        secretProvider: { PVEProfileStore.shared.secret(for: $0) },
        secretPrompt: { profile in await MainActor.run { PVESecretPrompt.ask(for: profile) } }))

    let coordinator: PVEFleetCoordinator

    /// Keeps an observer registered for as long as the caller holds it.
    final class Token {
        private let cancel: () -> Void
        fileprivate init(cancel: @escaping () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }

    private var observers: [UUID: (PVEFleetState) -> Void] = [:]

    /// The coordinator is a parameter so `UICheck` can drive a session whose guests
    /// arrive without a server. Everything else in the app uses `shared`.
    init(coordinator: PVEFleetCoordinator) {
        self.coordinator = coordinator
        coordinator.onChange = { [weak self] state in
            guard let self else { return }
            for observe in self.observers.values { observe(state) }
        }
        // Whatever is already on disk. Manage Servers only reports changes when the user
        // saves there, so without this the fleet stays empty until that sheet is opened.
        coordinator.setProfiles(PVEProfileStore.shared.profiles)
    }

    var state: PVEFleetState { coordinator.state }

    /// Registers `observe` and calls it once with the current state, so a surface that
    /// appears mid-session renders what is already known instead of an empty tree.
    func observe(_ observe: @escaping (PVEFleetState) -> Void) -> Token {
        let id = UUID()
        observers[id] = observe
        observe(coordinator.state)
        return Token { [weak self] in
            MainActor.assumeIsolated { self?.observers[id] = nil }
        }
    }

    func setProfiles(_ profiles: [PVEServerProfile]) { coordinator.setProfiles(profiles) }
}
