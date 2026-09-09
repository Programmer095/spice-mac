// SPDX-License-Identifier: MIT
import Foundation

/// Wraps a trust delegate so the certificate dialog takes its turn on the prompt
/// queue. `shouldTrustCertificate` is the other step that blocks on a person, and the
/// modal it opens spins a nested run loop — so without this a second challenge resumes
/// *inside* the first alert and stacks another one on top of it. The two non-blocking
/// members pass straight through.
public final class PVEQueuedTrustDelegate: PVETrustDelegate {
    private let wrapped: PVETrustDelegate
    private let prompts: PVEPromptQueue

    public init(wrapping wrapped: PVETrustDelegate, prompts: PVEPromptQueue) {
        self.wrapped = wrapped
        self.prompts = prompts
    }

    public func pinnedFingerprint(forHost host: String) -> String? {
        wrapped.pinnedFingerprint(forHost: host)
    }

    public func pinCertificate(fingerprint: String, forHost host: String) {
        wrapped.pinCertificate(fingerprint: fingerprint, forHost: host)
    }

    public func shouldTrustCertificate(host: String, fingerprint: String, isChange: Bool) async -> Bool {
        let wrapped = self.wrapped
        return await prompts.run {
            await wrapped.shouldTrustCertificate(host: host, fingerprint: fingerprint, isChange: isChange)
        }
    }
}

/// Drives the fleet: one client per instance, signing in concurrently, funnelling
/// anything that prompts through a single queue, and folding results into the reducer.
@MainActor
public final class PVEFleetCoordinator {
    public private(set) var state = PVEFleetState() {
        didSet { if state != oldValue { onChange?(state) } }
    }
    public var onChange: ((PVEFleetState) -> Void)?

    private var clients: [UUID: PVEClient] = [:]
    private let prompts: PVEPromptQueue
    private let trustDelegate: PVETrustDelegate?
    /// Reads the secret for a profile. Injected because the keychain is a platform
    /// framework and this package must stay portable. `@Sendable` because it crosses
    /// into the prompt queue's actor isolation.
    private let secretProvider: @Sendable (PVEServerProfile) -> String?
    /// Asks the user for a secret when none is stored — the "Remember in Keychain off"
    /// case, which would otherwise be a server that can never be signed in again.
    /// Injected for the same portability reason as `secretProvider`.
    private let secretPrompt: (@Sendable (PVEServerProfile) async -> String?)?
    /// How a signed-in client's guests are fetched. The only I/O the coordinator does,
    /// so injecting it is what makes the sign-in edge — not just the reducer — coverable
    /// without a server. `PVEClient.init` opens no connection, so the real client is
    /// still built either way.
    private let loadGuests: @Sendable (PVEClient) async throws -> [PVEGuest]

    public init(trustDelegate: PVETrustDelegate?,
                secretProvider: @escaping @Sendable (PVEServerProfile) -> String?,
                secretPrompt: (@Sendable (PVEServerProfile) async -> String?)? = nil,
                loadGuests: @escaping @Sendable (PVEClient) async throws -> [PVEGuest] = { try await $0.listGuests() }) {
        let prompts = PVEPromptQueue()
        self.prompts = prompts
        self.trustDelegate = trustDelegate.map { PVEQueuedTrustDelegate(wrapping: $0, prompts: prompts) }
        self.secretProvider = secretProvider
        self.secretPrompt = secretPrompt
        self.loadGuests = loadGuests
    }

    public func client(for id: UUID) -> PVEClient? { clients[id] }

    public func setProfiles(_ profiles: [PVEServerProfile]) {
        let removed = Set(clients.keys).subtracting(profiles.map(\.id))
        for id in removed { clients[id] = nil }

        // The reducer preserves state by id, so an edited profile would otherwise keep
        // a live client pointed at the old server — refresh, and every console opened
        // from that row, would silently keep talking to it.
        let restarted = profiles.filter { profile in
            guard let previous = state.instance(profile.id)?.profile else { return false }
            return previous.connectsIdentically(to: profile) == false
        }
        for profile in restarted {
            clients[profile.id] = nil
            apply(.signedOut(profile.id))
        }

        apply(.profilesChanged(profiles))
    }

    public func signInAll() {
        for instance in state.instances where instance.state == .signedOut {
            signIn(instance.id)
        }
    }

    /// Signs in an instance. With `secret` nil (the default), the secret comes from
    /// `secretProvider` — and, failing that, from `secretPrompt` — by way of the prompt
    /// queue. This is the path `signInAll()` and the tree's per-instance Sign In use, so
    /// several servers can't stack Keychain or secret prompts at launch.
    ///
    /// With `secret` non-nil, it is used as-is and both providers and the prompt queue
    /// are skipped: the caller just typed this, nobody needs prompting for it, and
    /// queuing it would serialize it behind other servers' prompts for no reason.
    public func signIn(_ id: UUID, usingSecret secret: String? = nil) {
        guard let instance = state.instance(id), instance.profile.isComplete else { return }
        // An automatic sign-in must not stack on one already running — the browser's
        // reveal and `signInAll` can both reach here for the same instance, and two
        // flows would each mint a client and race to install it. An explicit secret is
        // a deliberate action (the user just typed it and pressed Sign In) and always
        // goes through, otherwise fixing a bad credential would be swallowed.
        if secret == nil, instance.state == .signingIn { return }
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
            // Both the keychain read and the fallback prompt can block on a person, so
            // they share one turn on the queue; the request that follows does not queue.
            let secret = await self.prompts.run { [secretProvider = self.secretProvider,
                                                   secretPrompt = self.secretPrompt] () async -> String? in
                if let stored = secretProvider(profile), stored.isEmpty == false { return stored }
                return await secretPrompt?(profile)
            }
            guard let secret, secret.isEmpty == false else {
                self.apply(.signInFailed(id, .secretUnavailable(server: profile.displayName)))
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
            let guests = try await loadGuests(client)
            apply(.guestsLoaded(id, guests))
        } catch let error as PVEError {
            discard(client, for: id)
            apply(.signInFailed(id, error))
        } catch {
            discard(client, for: id)
            apply(.signInFailed(id, .transport(error.localizedDescription)))
        }
    }

    /// Drops a client that failed to sign in, so `refresh` falls back to a fresh sign-in
    /// instead of retrying with the credentials that were just rejected. Identity-checked
    /// because a later attempt may already have installed its own client here.
    private func discard(_ client: PVEClient, for id: UUID) {
        if clients[id] === client { clients[id] = nil }
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
                self.apply(.guestsLoaded(id, try await self.loadGuests(client)))
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
