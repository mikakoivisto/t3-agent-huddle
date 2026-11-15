import Foundation

/// Opt-in inline approvals. Off unless the user pastes a pairing code from the menu.
/// Everything about the credential lives here; the MCP client is untouched.
extension HuddleModel {
    /// The thread's T3 is this Mac's own.
    public func isOnThisMac(_ s: Session) -> Bool { isLocalThread(s.threadId) }
    func isLocalThread(_ id: String) -> Bool {
        guard let local = environments.first(where: \.isLocal)?.id, let e = state.sessions[id]?.environmentId else { return false }
        return e == local
    }

    /// Allow / Deny may be shown: the feature is on for this thread's machine and T3 gave a complete `waiting` request.
    public func canDecideInline(_ s: Session) -> Bool {
        s.permission?.requestId != nil && approvalRoute(for: s) != nil
    }

    /// Menu: "Set up inline approvals…". Exchanges the pasted pairing code and keeps only the resulting session token.
    public func enableInlineApprovals(pairingCode: String) async throws {
        let origin = try resolveEndpoint()
        let token = try await ApprovalEnrollment.exchange(pairingCode: pairingCode, origin: origin, log: config.log)
        do { try config.approvalStore.save(token) }
        catch { throw HuddleError.approval("Could not save the credential to the Keychain: \((error as? HuddleError)?.description ?? error.localizedDescription)") }
        inlineApprovals = true
        approvalStates = [:]
    }

    /// Menu: "Turn off inline approvals". Forgets the credential here. T3 does not let a client revoke its own session
    /// (`revokeClientSession` refuses the current one), so the session itself is revoked in T3 (README).
    @discardableResult
    public func disableInlineApprovals() -> Bool {
        let gone = config.approvalStore.delete()
        inlineApprovals = !gone          // a credential that could not be removed keeps the feature visibly on: it is still there
        approvalStates = [:]
        return gone
    }

    /// One explicit click. `requestId` and `summary` are what the user saw; that item is re-read first and must still be
    /// the same `waiting` request with the same command text, or nothing is sent.
    public func decideApproval(threadId: String, requestId: String, summary: String?, decision: ApprovalDecision) async {
        guard approvalsOptedIn, approvalStates[threadId] != .sending else { return }
        guard !readOnly else { approvalStates[threadId] = .error("Read-only mode — decide in T3 Code"); return }
        approvalStates[threadId] = .sending
        var machine: String?   // the other machine this click is for, if any (its credential is the one dropped on rejection)
        do {
            guard let session = state.sessions[threadId], let route = approvalRoute(for: session) else {
                throw HuddleError.approval(noApprovalRouteMessage(threadId))
            }
            // Everything this decision uses is captured here, at the click: the machine, the credential and the request. A refresh
            // that replaces the row while the awaits below run cannot move the read or the decision to another machine.
            let environment = env(threadId)
            let clickedEnvironmentId = session.environmentId
            let target: DecisionTarget
            switch route {
            case .thisMac:
                guard let token = config.approvalStore.load() else { throw HuddleError.approvalAuth }
                target = .thisMac(token: token)
            case .machine(let environmentId):
                machine = environmentId
                guard let credential = config.remoteApprovalStore.load(environmentId: environmentId) else { throw HuddleError.approvalAuth }
                target = .machine(credential)
            }
            let client = try await ensureClient()
            // Read that very item (not just the newest positions): still waiting, complete, and the same command text as shown.
            guard let item = try await client.readItem(threadId: threadId, itemId: ApprovalWire.itemId(forRequestId: requestId), environment: environment),
                  HuddleState.isApprovable(item), ApprovalWire.requestId(fromItemId: item.itemId) == requestId,
                  HuddleState.approvalSummary(item) == summary else {
                throw HuddleError.approval("The request changed. Check it in T3 Code.")
            }
            // Still the same row, on the same machine, showing the same request, after everything that was awaited.
            guard ApprovalGate.requestUnchanged(clickedEnvironmentId: clickedEnvironmentId, requestId: requestId, current: state.sessions[threadId]) else {
                throw HuddleError.approval("The request changed. Check it in T3 Code.")
            }
            let socket: ApprovalSocket
            switch target {
            case .thisMac(let token):
                socket = try ApprovalSocket(origin: resolveEndpoint(), token: token, log: config.log)
            case .machine(let credential):
                // The stored origin is re-validated, then it must still answer as the linked machine, right before the bearer is sent.
                let origin = try config.remotePolicy.validate(credential.origin)
                let verified = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: credential.environmentId)
                socket = try ApprovalSocket(remote: verified, token: credential.token, log: config.log)
            }
            try await socket.respond(threadId: threadId, requestId: requestId, decision: decision)
            justAnswered[threadId] = Date()
            approvalStates[threadId] = nil
            state.clearPending(threadId: threadId)
            await refresh(force: true)
        } catch HuddleError.approvalAuth {
            if let machine {   // revoked or expired on that machine: only that machine falls back to "In T3 Code"
                let name = environmentLabel(machine)
                disableRemoteApprovals(environmentId: machine)
                rejectedRemoteApprovals.insert(machine)
                showToast("\(name) rejected the approvals credential. Inline approvals for it are off; set them up again.")
            } else {
                disableInlineApprovals()   // revoked or expired (the session lasts about 30 days): fall back to "In T3 Code"
                showToast(HuddleError.approvalAuth.description)
            }
        } catch {
            let msg = (error as? HuddleError)?.description ?? error.localizedDescription
            approvalStates[threadId] = .error(String(msg.prefix(160)))
        }
    }

    private enum DecisionTarget { case thisMac(token: String), machine(RemoteApprovalCredential) }
}
