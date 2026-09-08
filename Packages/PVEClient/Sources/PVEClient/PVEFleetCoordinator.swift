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

    /// Signs in an instance. With `secret` nil (the default), the secret comes from
    /// `secretProvider` by way of the prompt queue — this is the path `signInAll()` and
    /// the tree's per-instance Sign In use, so several servers can't stack Keychain
    /// prompts at launch.
    ///
    /// With `secret` non-nil, it is used as-is and both `secretProvider` and the prompt
    /// queue are skipped: the caller just typed this, nobody needs prompting for it, and
    /// queuing it would serialize it behind other servers' prompts for no reason. This is
    /// the only way to sign in with a secret that isn't in the Keychain (rememberSecret
    /// off, or not yet saved).
    public func signIn(_ id: UUID, usingSecret secret: String? = nil) {
        guard let instance = state.instance(id), instance.profile.isComplete else { return }
        apply(.signInStarted(id))
        let profile = instance.profile

        if let secret {
            guard secret.isEmpty == false else {
                apply(.signInFailed(id, .unauthorized))
                return
            }
            Task { [weak self] in await self?.performSignIn(id, profile: profile, secret: secret) }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            // The secret read can prompt, so it queues; the request that follows does not.
            let secret = await self.prompts.run { [secretProvider = self.secretProvider] in
                secretProvider(profile)
            }
            guard let secret, secret.isEmpty == false else {
                self.apply(.signInFailed(id, .unauthorized))
                return
            }
            await self.performSignIn(id, profile: profile, secret: secret)
        }
    }

    private func performSignIn(_ id: UUID, profile: PVEServerProfile, secret: String) async {
        let client = PVEClient(server: profile.server,
                               credentials: profile.credentials(secret: secret),
                               trustDelegate: trustDelegate)
        clients[id] = client
        do {
            let guests = try await client.listGuests()
            apply(.guestsLoaded(id, guests))
        } catch let error as PVEError {
            apply(.signInFailed(id, error))
        } catch {
            apply(.signInFailed(id, .transport(error.localizedDescription)))
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
