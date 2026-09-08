// SPDX-License-Identifier: MIT
import Foundation

/// Drives the fleet: one client per instance, signing in concurrently, funnelling
/// anything that prompts through a single queue, and folding results into the reducer.
@MainActor
public final class PVEFleetCoordinator {
    public private(set) var state = PVEFleetState() {
        didSet { if state != oldValue { onChange?(state) } }
    }
    public var onChange: ((PVEFleetState) -> Void)?

    private var clients: [UUID: PVEClient] = [:]
    private let prompts = PVEPromptQueue()
    private let trustDelegate: PVETrustDelegate?
    /// Reads the secret for a profile. Injected because the keychain is a platform
    /// framework and this package must stay portable. `@Sendable` because it crosses
    /// into the prompt queue's actor isolation.
    private let secretProvider: @Sendable (PVEServerProfile) -> String?

    public init(trustDelegate: PVETrustDelegate?,
                secretProvider: @escaping @Sendable (PVEServerProfile) -> String?) {
        self.trustDelegate = trustDelegate
        self.secretProvider = secretProvider
    }

    public func client(for id: UUID) -> PVEClient? { clients[id] }

    public func setProfiles(_ profiles: [PVEServerProfile]) {
        let removed = Set(clients.keys).subtracting(profiles.map(\.id))
        for id in removed { clients[id] = nil }
        apply(.profilesChanged(profiles))
    }

    public func signInAll() {
        for instance in state.instances where instance.state == .signedOut {
            signIn(instance.id)
        }
    }

    public func signIn(_ id: UUID) {
        guard let instance = state.instance(id), instance.profile.isComplete else { return }
        apply(.signInStarted(id))

        Task { [weak self] in
            guard let self else { return }
            // The secret read can prompt, so it queues; the request that follows does not.
            let profile = instance.profile
            let secret = await self.prompts.run { [secretProvider = self.secretProvider] in
                secretProvider(profile)
            }
            guard let secret, secret.isEmpty == false else {
                self.apply(.signInFailed(id, .unauthorized))
                return
            }
            let client = PVEClient(server: profile.server,
                                   credentials: profile.credentials(secret: secret),
                                   trustDelegate: self.trustDelegate)
            self.clients[id] = client
            do {
                let guests = try await client.listGuests()
                self.apply(.guestsLoaded(id, guests))
            } catch let error as PVEError {
                self.apply(.signInFailed(id, error))
            } catch {
                self.apply(.signInFailed(id, .transport(error.localizedDescription)))
            }
        }
    }

    public func signOut(_ id: UUID) {
        clients[id] = nil
        apply(.signedOut(id))
    }

    /// Re-read one instance's guests. Called when the browser is revealed, so it costs
    /// one request rather than polling the whole fleet on a timer.
    public func refresh(_ id: UUID) {
        guard let client = clients[id] else { return signIn(id) }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.apply(.guestsLoaded(id, try await client.listGuests()))
            } catch let error as PVEError {
                self.apply(.signInFailed(id, error))
            } catch {
                self.apply(.signInFailed(id, .transport(error.localizedDescription)))
            }
        }
    }

    private func apply(_ event: PVEFleetEvent) {
        state = PVEFleetState.reduce(state, event)
    }
}
