// SPDX-License-Identifier: MIT
import Foundation

public enum PVEInstanceState: Equatable, Sendable {
    case signedOut
    case signingIn
    case signedIn([PVEGuest])
    case failed(PVEError)

    public var guests: [PVEGuest] {
        if case .signedIn(let guests) = self { return guests }
        return []
    }
}

public struct PVEInstanceSnapshot: Equatable, Identifiable, Sendable {
    public var profile: PVEServerProfile
    public var state: PVEInstanceState
    public var id: UUID { profile.id }
}

public enum PVEFleetEvent: Equatable, Sendable {
    case profilesChanged([PVEServerProfile])
    case signInStarted(UUID)
    case guestsLoaded(UUID, [PVEGuest])
    case signInFailed(UUID, PVEError)
    case signedOut(UUID)
}

/// The whole fleet as a value. Transitions are a pure function of the previous value
/// and one event, so behaviour is testable without a server; the async work that
/// produces events lives in `PVEFleetCoordinator`.
public struct PVEFleetState: Equatable, Sendable {
    public var instances: [PVEInstanceSnapshot]

    public init(instances: [PVEInstanceSnapshot] = []) {
        self.instances = instances
    }

    public func instance(_ id: UUID) -> PVEInstanceSnapshot? {
        instances.first { $0.id == id }
    }

    /// Every guest in the fleet, in instance order.
    public var allGuests: [PVEGuest] {
        instances.flatMap(\.state.guests)
    }

    public static func reduce(_ state: PVEFleetState, _ event: PVEFleetEvent) -> PVEFleetState {
        var next = state
        switch event {
        case .profilesChanged(let profiles):
            // Keep the live state of instances that survive the edit; a server the user
            // did not touch must not be signed out by someone else's rename.
            next.instances = profiles.map { profile in
                PVEInstanceSnapshot(profile: profile,
                                    state: state.instance(profile.id)?.state ?? .signedOut)
            }
        case .signInStarted(let id):
            next.setState(.signingIn, for: id)
        case .guestsLoaded(let id, let guests):
            next.setState(.signedIn(guests), for: id)
        case .signInFailed(let id, let error):
            next.setState(.failed(error), for: id)
        case .signedOut(let id):
            next.setState(.signedOut, for: id)
        }
        return next
    }

    private mutating func setState(_ newState: PVEInstanceState, for id: UUID) {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
        instances[index].state = newState
    }
}
