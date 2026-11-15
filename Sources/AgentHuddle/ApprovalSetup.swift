import AppKit
import SwiftUI
import HuddleCore

// Opt-in inline approvals: the menu flow and the Allow / Deny row.
// Nothing here runs unless the user turned the feature on; with it off, PermissionPanel looks exactly as before.

/// Allow / Deny under the exact command. Neither is the default button; both are disabled in Read-only mode.
struct ApprovalButtons: View {
    @ObservedObject var model: HuddleModel
    var session: Session
    /// The whole command is on screen. Allow stays off until it is (Deny is harmless and stays available).
    var commandVisibleInFull = false
    /// The request has been on screen for `ApprovalGate.armDelay` (always true in snapshots).
    var armed = false

    var body: some View {
        if model.showsApprovalControls(for: session), let prompt = session.permission {
            let ui = model.approvalStates[session.threadId] ?? .pending
            VStack(alignment: .leading, spacing: 6) {
                if model.canDecideInline(session), let requestId = prompt.requestId {
                    let sending = ui == .sending
                    let allowOK = ApprovalGate.allowEnabled(readOnly: model.readOnly, sending: sending, commandVisibleInFull: commandVisibleInFull, armed: armed)
                    let denyOK = ApprovalGate.denyEnabled(readOnly: model.readOnly, sending: sending, armed: armed)
                    HStack(spacing: 8) {
                        Button { decide(.accept, requestId, prompt.summary) } label: { Pill(text: ui == .sending ? "Sending…" : "Allow", fill: .white) }
                            .buttonStyle(.plain)
                            .disabled(!allowOK).opacity(allowOK ? 1 : 0.4)
                        Button { decide(.decline, requestId, prompt.summary) } label: { Pill(text: "Deny", fill: Theme.red, fg: .white) }
                            .buttonStyle(.plain)
                            .disabled(!denyOK).opacity(denyOK ? 1 : 0.4)
                    }
                    if model.readOnly { note("Read-only mode — decide in T3 Code") }
                    else if !commandVisibleInFull { note("Show the full command to enable Allow.") }
                } else if !model.isOnThisMac(session) && model.approvalRoute(for: session) == nil {
                    note("Approving commands from the panel isn’t set up for \(model.machineName(for: session)). Settings → Machines, or decide in T3 Code.")
                } else {
                    note("This request can’t be approved here — decide in T3 Code")
                }
                if case .error(let msg) = ui {
                    Text(verbatim: msg).font(.system(size: 12)).foregroundStyle(Theme.red).lineLimit(3)
                }
            }
        }
    }

    private func decide(_ decision: ApprovalDecision, _ requestId: String, _ summary: String?) {
        Task { await model.decideApproval(threadId: session.threadId, requestId: requestId, summary: summary, decision: decision) }
    }
    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Theme.grey)
    }
}
