// SPDX-License-Identifier: MIT
import Foundation

/// A power operation on a guest.
///
/// Proxmox draws a hard line between graceful and forced actions, and so does this:
/// `shutdown`/`reboot` ask the guest OS via ACPI, while `stop`/`reset` are the
/// equivalent of pulling the power cable and can corrupt a guest filesystem. Callers
/// are expected to confirm anything `isDestructive`.
public enum PVEPowerAction: String, CaseIterable, Sendable {
    case start
    case shutdown
    case reboot
    case stop
    case reset
    case suspend
    case resume

    public var title: String {
        switch self {
        case .start:    return "Start"
        case .shutdown: return "Shut Down"
        case .reboot:   return "Restart"
        case .stop:     return "Force Stop"
        case .reset:    return "Force Reset"
        case .suspend:  return "Suspend"
        case .resume:   return "Resume"
        }
    }

    /// True for actions that cut power without telling the guest.
    public var isDestructive: Bool {
        self == .stop || self == .reset
    }

    /// The warning shown before a destructive action.
    public var confirmationDetail: String? {
        switch self {
        case .stop:
            return """
                This cuts power immediately without telling the guest operating system, \
                like holding down a physical power button. Unsaved work is lost and the \
                filesystem may need a repair on next boot.

                “Shut Down” asks the guest to power off cleanly instead.
                """
        case .reset:
            return """
                This reboots the machine instantly without telling the guest operating \
                system. Unsaved work is lost and the filesystem may need a repair on next \
                boot.

                “Restart” asks the guest to reboot cleanly instead.
                """
        default:
            return nil
        }
    }

    /// Whether this action makes sense for a guest in its current state. Drives menu
    /// enablement so the app never sends a request Proxmox would just reject.
    public func isAvailable(for guest: PVEGuest) -> Bool {
        let status = guest.status.lowercased()
        switch self {
        case .start:
            return status != "running" && status != "paused"
        case .shutdown, .reboot, .stop:
            return status == "running"
        case .reset:
            // Proxmox exposes reset for QEMU only; containers have no equivalent.
            return status == "running" && guest.kind == .qemu
        case .suspend:
            return status == "running"
        case .resume:
            return status == "paused" || status == "suspended"
        }
    }
}

/// The state of an asynchronous Proxmox task (power actions return a UPID, not a result).
public struct PVETaskStatus: Equatable, Sendable {
    public var isRunning: Bool
    public var exitStatus: String?

    public init(isRunning: Bool, exitStatus: String?) {
        self.isRunning = isRunning
        self.exitStatus = exitStatus
    }

    /// Proxmox signals success with the literal string "OK"; anything else is the
    /// failure reason. A still-running task has not failed yet.
    public var failed: Bool {
        guard isRunning == false else { return false }
        guard let exitStatus else { return false }
        return exitStatus != "OK"
    }
}

extension PVEProtocol {

    public static func powerPath(node: String, vmid: Int, kind: PVEGuest.Kind,
                                 action: PVEPowerAction) -> String {
        let encodedNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        return "/api2/json/nodes/\(encodedNode)/\(kind.rawValue)/\(vmid)/status/\(action.rawValue)"
    }

    /// A UPID contains colons, which are legal in a path segment but must not be taken
    /// for a scheme separator, so encode it.
    public static func taskStatusPath(node: String, upid: String) -> String {
        let encodedNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedUPID = upid.addingPercentEncoding(withAllowedCharacters: allowed) ?? upid
        return "/api2/json/nodes/\(encodedNode)/tasks/\(encodedUPID)/status"
    }

    private struct UPIDEnvelope: Decodable { let data: String? }

    /// Power endpoints return the task id as a bare string in `data`.
    public static func decodeUPID(_ data: Data) throws -> String {
        guard let upid = try? JSONDecoder().decode(UPIDEnvelope.self, from: data).data,
              upid.hasPrefix("UPID:") else {
            throw PVEError.decoding("no task id (UPID) in the response")
        }
        return upid
    }

    private struct TaskEnvelope: Decodable {
        struct Payload: Decodable {
            let status: String?
            let exitstatus: String?
        }
        let data: Payload?
    }

    public static func decodeTaskStatus(_ data: Data) throws -> PVETaskStatus {
        guard let payload = try? JSONDecoder().decode(TaskEnvelope.self, from: data).data else {
            throw PVEError.decoding("unexpected task status payload")
        }
        return PVETaskStatus(isRunning: (payload.status ?? "").lowercased() == "running",
                             exitStatus: payload.exitstatus)
    }
}
