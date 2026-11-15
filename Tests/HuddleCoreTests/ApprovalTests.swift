import Testing
import Foundation
@testable import HuddleCore
import FakeT3

/// Inline Allow / Deny (opt-in). Frames and error texts mirror what the real T3 returned.
@Suite("Inline approvals (opt-in, /ws)")
struct ApprovalTests {
    static let code = "fake-pairing-code"
    static let rid = Scenario.permissionRequestId
    static let thread = Scenario.permissionThread

    @MainActor func enabledModel(_ s: FakeT3Server, log: HuddleLog = HuddleLog(sink: { _ in }), prefs: PreferencesStore? = nil) async throws -> HuddleModel {
        let m = makeModel(s, log: log, prefs: prefs)
        try await m.enableInlineApprovals(pairingCode: Self.code)
        await m.refresh()
        return m
    }

    // MARK: Off by default

    @Test @MainActor func offByDefaultNoSocketNoExchangeNoButtons() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh(); m.openDetail(Self.thread); await m.refresh()
        let session = try #require(m.state.sessions[Self.thread])
        #expect(session.permission?.summary == "Bash: gh issue edit 142 --add-label needs-info")
        #expect(!m.inlineApprovals)
        #expect(!m.canDecideInline(session))
        #expect(s.wsUpgrades == 0 && s.exchangeRequests.isEmpty)
        await m.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: session.permission?.summary, decision: .accept)
        #expect(s.wsUpgrades == 0 && s.decisions.isEmpty)
    }

    @Test @MainActor func onOnlyWhileTheCredentialExists() async throws {
        let s = try await startFake(); defer { s.stop() }
        let store = MemoryTokenStore(token: "saved")
        let m = HuddleModel(config: HuddleConfig(source: .fixed(s.url), tokenStore: MemoryTokenStore(token: s.token), approvalStore: store))
        #expect(m.inlineApprovals)
        m.disableInlineApprovals()
        #expect(!m.inlineApprovals && store.load() == nil)
    }

    // MARK: Enrollment

    @Test @MainActor func enrollmentRequestsLeastScopeAndKeepsOnlyThatSession() async throws {
        let s = try await startFake(); defer { s.stop() }
        let cap = LogCapture()
        let store = MemoryTokenStore()
        let m = makeModel(s, log: cap.log, approvals: store)
        try await m.enableInlineApprovals(pairingCode: "  \(Self.code)\n")
        let form = try #require(s.exchangeRequests.first)
        #expect(form["scope"] == "orchestration:read orchestration:operate")
        #expect(form["client_label"] == "Agent Huddle approvals")
        #expect(form["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange")
        let token = try #require(store.load())
        #expect(s.approvalTokenList == [token])
        #expect(m.inlineApprovals)
        // The code carried access:write and filesystem:write; the saved session must not.
        #expect(ApprovalEnrollment.scopes == ["orchestration:read", "orchestration:operate"])
        await m.refresh()
        for l in cap.lines { #expect(!l.contains(token) && !l.contains(Self.code)) }
    }

    @Test @MainActor func aPairingCodeIsSingleUseAndAWrongOneIsRefused() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await #expect(throws: HuddleError.self) { try await m.enableInlineApprovals(pairingCode: "wrong") }
        #expect(!m.inlineApprovals)
        try await m.enableInlineApprovals(pairingCode: Self.code)
        await #expect(throws: HuddleError.self) { try await m.enableInlineApprovals(pairingCode: Self.code) }
    }

    @Test @MainActor func aCodeWithoutOperateScopeIsRefusedAndNothingIsSaved() async throws {
        var o = FakeT3Server.Options(); o.pairingScopes = ["orchestration:read"]
        let s = try await startFake(o); defer { s.stop() }
        let store = MemoryTokenStore()
        let m = makeModel(s, approvals: store)
        await #expect(throws: HuddleError.self) { try await m.enableInlineApprovals(pairingCode: Self.code) }
        #expect(store.load() == nil && !m.inlineApprovals)
    }

    @Test func pastedPairingLinkYieldsTheBareCredential() {
        #expect(ApprovalEnrollment.clean("https://x.example/pair#token=abc123") == "abc123")
        #expect(ApprovalEnrollment.clean(" abc123 \n") == "abc123")
        #expect(ApprovalEnrollment.pairingCommand.contains("--label \"Agent Huddle approvals\""))
        #expect(!ApprovalEnrollment.pairingCommand.contains("access:write"))
    }

    // MARK: Decisions

    @Test @MainActor func allowSendsExactlyOneRespondFrameAndT3MovesOn() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = try await enabledModel(s)
        let session = try #require(m.state.sessions[Self.thread])
        let prompt = try #require(session.permission)
        #expect(prompt.requestId == Self.rid)                    // decoded once from the item id
        #expect(m.canDecideInline(session))
        await m.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        #expect(s.decisions.map(\.decision) == ["accept"])
        #expect(s.decisions.first?.requestId == Self.rid && s.decisions.first?.threadId == Self.thread)
        #expect(s.thread(Self.thread)?.permissionPending == false)
        let frames = s.wsFrames.filter { $0["_tag"].string == "Request" }
        #expect(frames.count == 1)
        let f = try #require(frames.first)
        #expect(f["tag"].string == "orchestration.dispatchCommand" && f["id"].string == "1")
        #expect(Set(f["payload"].object?.keys.map { $0 } ?? []) == ["type", "commandId", "threadId", "requestId", "decision"])
        #expect(f["payload"]["type"].string == "runtime-request.respond" && f["payload"]["decision"].string == "accept")
        #expect(m.approvalStates[Self.thread] == nil)
        await m.refresh()
        #expect(m.state.sessions[Self.thread]?.permission == nil)
    }

    @Test @MainActor func denySendsDecline() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = try await enabledModel(s)
        let prompt = try #require(m.state.sessions[Self.thread]?.permission)
        await m.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .decline)
        #expect(s.decisions.map(\.decision) == ["decline"])
    }

    @Test @MainActor func readOnlyModeBlocksDecisions() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = try await enabledModel(s)
        m.setReadOnly(true)
        let prompt = try #require(m.state.sessions[Self.thread]?.permission)
        await m.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        #expect(s.decisions.isEmpty && s.wsUpgrades == 0)
        if case .error = m.approvalStates[Self.thread] {} else { Issue.record("expected an error") }
    }

    @Test @MainActor func aRequestThatChangedSinceItWasShownIsNotSent() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = try await enabledModel(s)
        let shown = try #require(m.state.sessions[Self.thread]?.permission)
        s.update(Self.thread) { t in   // T3 now asks about a different command under the same request id
            if let i = t.items.firstIndex(where: { $0.type == "approval_request" }) { t.items[i].text = "{\"command\": \"rm -rf /tmp/x\"}" }
        }
        await m.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: shown.summary, decision: .accept)
        #expect(s.decisions.isEmpty && s.wsUpgrades == 0)
        if case .error(let msg) = m.approvalStates[Self.thread] { #expect(msg.contains("changed")) } else { Issue.record("expected an error") }
    }

    @Test @MainActor func aRequestAlreadyDecidedInT3ShowsT3sSentenceNotTheLongId() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = try await enabledModel(s)
        let prompt = try #require(m.state.sessions[Self.thread]?.permission)
        // Decided in T3 itself between the click's re-read and the send: simulate by resolving at the server first.
        let token = try #require(s.approvalTokenList.first)
        let sock = try ApprovalSocket(origin: s.url, token: token)
        try await sock.respond(threadId: Self.thread, requestId: Self.rid, decision: .accept)
        await #expect(throws: HuddleError.approval("Runtime request this request is resolved.")) {
            try await sock.respond(threadId: Self.thread, requestId: Self.rid, decision: .decline)
        }
        await #expect(throws: HuddleError.approval("Runtime request this request was not found.")) {
            try await sock.respond(threadId: Self.thread, requestId: "bogus", decision: .accept)
        }
        _ = prompt
    }

    @Test @MainActor func aRevokedCredentialTurnsTheFeatureOffAndFallsBack() async throws {
        let s = try await startFake(); defer { s.stop() }
        let store = MemoryTokenStore()
        let m = makeModel(s, approvals: store)
        try await m.enableInlineApprovals(pairingCode: Self.code); await m.refresh()
        let prompt = try #require(m.state.sessions[Self.thread]?.permission)
        s.revokeApprovalTokens()                                  // `t3 auth session revoke`
        await m.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        #expect(s.decisions.isEmpty)
        #expect(!m.inlineApprovals && store.load() == nil)
        #expect(m.toast?.contains("rejected") == true)
        #expect(m.state.sessions[Self.thread]?.permission != nil)  // still shown, "In T3 Code" remains
    }

    @Test @MainActor func onlyThisMacsThreadsAreOffered() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = try await enabledModel(s)
        #expect(m.canDecideInline(try #require(m.state.sessions[Self.thread])))
        m.state.sessions[Self.thread]?.environmentId = "env_remote"
        #expect(!m.canDecideInline(try #require(m.state.sessions[Self.thread])))
        let before = s.wsUpgrades
        await m.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: nil, decision: .accept)
        #expect(s.wsUpgrades == before && s.decisions.isEmpty)
    }

    @Test @MainActor func theMCPClientStillNeverCallsForbiddenTools() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = try await enabledModel(s)
        let prompt = try #require(m.state.sessions[Self.thread]?.permission)
        await m.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        let allowed: Set = ["t3_thread_list", "t3_thread_read", "t3_pending_request", "t3_project_read", "t3_environment_read"]
        #expect(Set(s.calls.map(\.tool)).isSubset(of: allowed))
    }

    // MARK: Request id and item rules (pure)

    @Test func requestIdIsDecodedExactlyOnce() {
        let id = "runtime-request:provider:pi:turn%3Aabc:native-request:0c19"
        let item = "turn-item:runtime-request:" + FakeT3Server.encodeURIComponent(id)
        #expect(ApprovalWire.requestId(fromItemId: item) == id)         // the `%3A` inside the id survives
        #expect(ApprovalWire.requestId(fromItemId: "turn-item:message:abc") == nil)
        #expect(ApprovalWire.requestId(fromItemId: "turn-item:runtime-request:") == nil)
        #expect(ApprovalWire.requestId(fromItemId: "other:runtime-request:abc") == nil)
    }

    @Test func onlyAWaitingCompleteApprovalOffersARequestId() {
        func session(_ status: String, truncated: Bool, id: String = "turn-item:runtime-request:rid") -> Session? {
            var s = HuddleState()
            s.applyActive([ThreadSummary(threadId: "t", status: .waiting)])
            s.applyRead(ThreadRead(threadId: "t", status: .waiting, pendingRequestCount: 1, items: [
                ActivityItem(position: 0, itemId: id, type: "approval_request", status: status, title: "Allow bash?",
                             text: "{\"command\": \"pwd\"}", textTruncated: truncated)]))
            s.applyPending(threadId: "t", questions: [])
            return s.sessions["t"]
        }
        #expect(session("waiting", truncated: false)?.permission?.requestId == "rid")
        #expect(session("waiting", truncated: true)?.permission?.requestId == nil)          // a cut-off command is never approvable
        #expect(session("completed", truncated: false)?.permission?.requestId == nil)
        #expect(session("pending", truncated: false)?.permission?.requestId == nil)
        #expect(session("waiting", truncated: false, id: "turn-item:other:rid")?.permission?.requestId == nil)
        #expect(session("waiting", truncated: false)?.permission?.summary == "Bash: pwd")
    }

    @Test func onlyAFullyShownRequestIsApprovable() {
        func rid(_ text: String, status: String = "waiting", title: String = "Allow write?") -> String? {
            var s = HuddleState()
            s.applyActive([ThreadSummary(threadId: "t", status: .waiting)])
            s.applyRead(ThreadRead(threadId: "t", status: .waiting, pendingRequestCount: 1, items: [
                ActivityItem(position: 0, itemId: "turn-item:runtime-request:rid", type: "approval_request", status: status,
                             title: title, text: text)]))
            s.applyPending(threadId: "t", questions: [])
            return s.sessions["t"]?.permission?.requestId
        }
        #expect(rid("{\"command\": \"pwd\"}") == "rid")
        #expect(rid("{\"command\": \"pwd\", \"description\": \"print dir\", \"timeout\": 5}", title: "Allow bash?") == "rid")   // informational keys, for a shell command only
        #expect(rid("{\"command\": \"pwd\", \"description\": \"print dir\", \"timeout\": 5}") == nil)                          // other tools: every field is a payload
        #expect(rid("{\"path\": \"/a/b.txt\", \"content\": \"rm everything\"}") == nil)                   // the panel shows only the path
        #expect(rid("{\"command\": \"pwd\", \"path\": \"/etc\"}") == nil)                                  // two material fields, one shown
        #expect(rid("{\"command\": \"\"}") == nil)
        #expect(rid("plain text request") == "rid")
        #expect(rid(String(repeating: "x", count: 401)) == nil)                                               // summary would cut it at 400
        #expect(rid("") == nil)
    }

    @Test func aNewRunForgetsTheOldRunsRequest() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .waiting)])
        _ = s.noteRun(threadId: "t", latestRunId: "run1")
        s.applyRead(ThreadRead(threadId: "t", status: .waiting, pendingRequestCount: 1, items: [
            ActivityItem(position: 0, itemId: "turn-item:runtime-request:rid", type: "approval_request", status: "waiting", text: "{\"command\": \"pwd\"}")]))
        #expect(s.sessions["t"]?.approvalRequestId == "rid")
        let restarted = s.noteRun(threadId: "t", latestRunId: "run2")
        #expect(restarted)
        #expect(s.sessions["t"]?.approvalRequestId == nil && s.sessions["t"]?.approvalText == nil)
    }

    @Test @MainActor func theCheckBeforeSendingReadsTheItemEvenFarBehindTheNewestPositions() async throws {
        let s = try await startFake(); defer { s.stop() }
        s.update(Self.thread) { t in   // many newer items, so an incremental re-read (last three positions) would never reach the approval
            for i in 3..<20 { t.items.append(Scenario.tool(i, "Read f\(i).md")) }
        }
        let m = try await enabledModel(s)
        let shown = try #require(m.state.sessions[Self.thread]?.permission)
        #expect(shown.requestId == Self.rid)
        s.update(Self.thread) { t in
            if let i = t.items.firstIndex(where: { $0.type == "approval_request" }) { t.items[i].text = "{\"command\": \"rm -rf /tmp/x\"}" }
        }
        await m.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: shown.summary, decision: .accept)
        #expect(s.decisions.isEmpty && s.wsUpgrades == 0)
    }

    @Test @MainActor func aRefusedPairingCodeSaysWhy() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        do { try await m.enableInlineApprovals(pairingCode: "wrong"); Issue.record("expected an error") }
        catch let e as HuddleError { #expect(e.description.contains("HTTP 401") && e.description.contains("invalid_credential")) }
    }

    @Test func itemIdAndRequestIdAreInverse() {
        let id = "runtime-request:provider:pi:turn%3Aabc:native-request:0c19 x!'()~"
        #expect(ApprovalWire.requestId(fromItemId: ApprovalWire.itemId(forRequestId: id)) == id)
        #expect(ApprovalWire.itemId(forRequestId: id) == "turn-item:runtime-request:" + FakeT3Server.encodeURIComponent(id))
    }

    // MARK: The client can only ever send one command

    @Test func everyFrameTheClientCanBuildIsRuntimeRequestRespondWithAcceptOrDecline() throws {
        #expect(Set(ApprovalDecision.allCases.map(\.rawValue)) == ["accept", "decline"])
        for d in ApprovalDecision.allCases {
            let j = try JSON.parse(ApprovalWire.respondFrame(rpcId: "1", commandId: "c", threadId: "t", requestId: "r", decision: d))
            #expect(j["_tag"].string == "Request" && j["tag"].string == "orchestration.dispatchCommand")
            #expect(j["payload"]["type"].string == "runtime-request.respond")
            #expect(["accept", "decline"].contains(j["payload"]["decision"].string ?? ""))
            #expect(j["payload"]["feedback"].isNull && j["payload"]["answers"].isNull)
        }
    }

    @Test func socketSourceMentionsOnlyTheOneCommand() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        func code(_ f: URL) throws -> String {   // comments stripped: they may name what is NOT sent
            try String(contentsOf: f, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        let socket = try #require(files.first { $0.lastPathComponent == "ApprovalSocket.swift" })
        let text = try code(socket)
        #expect(text.components(separatedBy: "\"orchestration.").count - 1 == 1)            // one RPC tag
        #expect(text.components(separatedBy: "\"runtime-request.respond\"").count - 1 == 1)  // one command type
        #expect(text.components(separatedBy: "\"Request\"").count - 1 == 1)                  // one frame builder
        for forbidden in ["acceptForSession", "acceptAlways", "\"cancel\"", "feedback", "answers", "subscribe", "launchThread",
                          "stopWorkflow", "forceStop", "dispatchCommand\"," + "\n", "thread.", "turn.", "send(.data"] {
            #expect(!text.contains(forbidden), "ApprovalSocket.swift mentions \(forbidden)")
        }
        #expect(text.components(separatedBy: ".send(").count - 1 == 1)                      // one send, of the one frame
        // Nothing else in the app talks WebSocket or names the RPC.
        // (PeerLinkDiscovery.swift is the one other WebSocket client: read-only `peerLinks.list`, checked in RemoteApprovalTests.)
        for f in files where !["ApprovalSocket.swift", "PeerLinkDiscovery.swift", "FakeApprovals.swift", "LoopbackHTTPServer.swift"].contains(f.lastPathComponent) {
            let t = try code(f)
            #expect(!t.contains("webSocketTask") && !t.contains("URLSessionWebSocketTask"), "\(f.lastPathComponent) opens a WebSocket")
            #expect(!t.contains("orchestration.dispatchCommand"), "\(f.lastPathComponent) names the RPC")
        }
    }

    @Test func theSocketRefusesNonLoopbackOrigins() {
        for bad in ["http://localhost:3773", "http://example.com", "http://10.0.0.5:3773", "ws://127.0.0.1:3773", "https://127.0.0.1:3773",
                    "https://mac-mini.tail1234.ts.net", "https://mac-mini.tail1234.ts.net:443"] {
            #expect(throws: HuddleError.self) { _ = try ApprovalSocket(origin: URL(string: bad)!, token: "t") }
        }
        #expect(throws: Never.self) { _ = try ApprovalSocket(origin: URL(string: "http://127.0.0.1:3773/mcp")!, token: "t") }
    }

    @Test func protocolVersionIsPartOfTheUpgradeURL() async throws {
        let s = try await startFake(); defer { s.stop() }
        var c = URLComponents(url: s.url, resolvingAgainstBaseURL: false)!; c.scheme = "ws"; c.path = "/ws"
        let session = LoopbackSession.make(timeout: 5); defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: URLRequest(url: c.url!))   // no orchestrationProtocol, no bearer
        task.resume()
        await #expect(throws: (any Error).self) { _ = try await task.receive() }
        #expect((task.response as? HTTPURLResponse)?.statusCode == 426)
    }

    @Test func theFakeKeepsTheMCPSurfaceUnchanged() async throws {
        let s = try await startFake(); defer { s.stop() }
        let c = try MCPClient(endpoint: s.url, token: s.token)
        let tools = try await c.toolsList()
        #expect(ContractCheck.verify(toolsList: tools) == nil)
        let names = (tools["tools"].array ?? []).compactMap { $0["name"].string }
        #expect(!names.contains { $0.contains("approv") || $0.contains("decision") })
    }
}
