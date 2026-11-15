import Foundation

/// When may the panel offer to approve? One place, so it can be tested without a window.
public enum ApprovalGate {
    /// A request that has just appeared, or just changed under an open row, is not approvable for this long: a click aimed at
    /// whatever was there a moment ago cannot land on a different request.
    public static let armDelay: TimeInterval = 1.0

    /// Allow needs the whole command on screen, a settled request, and no read-only mode or decision in flight.
    public static func allowEnabled(readOnly: Bool, sending: Bool, commandVisibleInFull: Bool, armed: Bool) -> Bool {
        !readOnly && !sending && commandVisibleInFull && armed
    }
    /// After everything a decision awaited, the row must still be on the machine that was clicked and still show the same request.
    public static func requestUnchanged(clickedEnvironmentId: String?, requestId: String, current: Session?) -> Bool {
        guard let current else { return false }
        return current.environmentId == clickedEnvironmentId && current.permission?.requestId == requestId
    }

    /// Deny never needs the command in full (declining is always safe) but still waits for a settled row.
    public static func denyEnabled(readOnly: Bool, sending: Bool, armed: Bool) -> Bool {
        !readOnly && !sending && armed
    }
}
