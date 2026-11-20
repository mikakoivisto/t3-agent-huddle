import Testing
import Foundation
@testable import HuddleCore
import FakeT3

/// Written answers, messages to a thread, steer or queue (spec 13). Against the fake: what it records is what T3 would get.
@Suite("Write and send (spec 13)")
@MainActor
struct SendTests {
    static let running = Scenario.renderThread          // T3 status `running`
    static let finished = "thr_finished_recent"

    func setUp(_ options: FakeT3Server.Options = .init()) async throws -> (FakeT3Server, HuddleModel) {
        let s = try await startFake(options)
        s.add(.init(id: Self.finished, title: "Refactor the config loader", status: "completed",
                    items: [Scenario.cmd(0, "swift test", output: "ok")]))
        let m = makeModel(s)
        await m.refresh()
        return (s, m)
    }

    func type(_ m: HuddleModel, _ thread: String, _ text: String) { m.composer.drafts[ComposerStore.messageKey(thread)] = text }

    // SND-01
    @Test func aRunningThreadQueuesByDefaultAndSteersOnlyWhenFlipped() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        let r = try #require(m.state.sessions[Self.running])
        #expect(m.canMessage(r) && m.canSteer(r))
        #expect(m.sendLabel(r) == "Queue")
        m.openComposer(Self.running); type(m, Self.running, "also update the changelog")
        await m.sendMessage(threadId: Self.running)
        #expect(s.sends.last?.mode == "queue")
        #expect(m.rowToasts[Self.running] == "Queued" && m.composingThreadId == nil)
        #expect(m.composer.drafts[ComposerStore.messageKey(Self.running)] == nil)

        m.openComposer(Self.running); type(m, Self.running, "skip lint.sh")
        m.toggleSendMode(Self.running)
        #expect(m.sendLabel(try #require(m.state.sessions[Self.running])) == "Steer")
        await m.sendMessage(threadId: Self.running)
        #expect(s.sends.map(\.mode) == ["queue", "steer"])
        #expect(m.rowToasts[Self.running] == "Steered")
        #expect(m.sendModes[Self.running] == nil, "the toggle goes back to Queue after a send")
    }

    @Test func optionCommandReturnSteersOnceWithoutTheToggle() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        type(m, Self.running, "now")
        await m.sendMessage(threadId: Self.running, steer: true)
        #expect(s.sends.last?.mode == "steer")
    }

    @Test func aFinishedThreadSaysSendAndStartsANewTurn() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        let f = try #require(m.state.sessions[Self.finished])
        #expect(m.sendLabel(f) == "Send" && !m.canSteer(f))
        m.toggleSendMode(Self.finished)                     // no effect: nothing to steer
        type(m, Self.finished, "add a test for the missing-file case")
        await m.sendMessage(threadId: Self.finished, steer: true)   // even ⌥⌘↩ cannot steer a finished thread
        #expect(s.sends.last?.mode == "queue")
        #expect(m.rowToasts[Self.finished] == "Sent")
    }

    @Test func aBackgroundWaitIsLabelledFromT3sStatusNotThePanels() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        var f = try #require(m.state.sessions[Self.finished])
        f.backgroundWait = true; f.updatedAt = FakeT3Server.iso(Date())
        f.awaitedBackgroundTasks = nil   // a T3 before 0.1.11: the wait comes from the heuristic, the status stays `completed`
        #expect(f.isWorking)
        #expect(m.sendLabel(f) == "Send" && !m.canSteer(f))
    }

    // SND-02
    @Test func aRunThatEndedWhileTypingSendsNothingAndOffersANewTurn() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        type(m, Self.running, "use the staging database")
        m.toggleSendMode(Self.running)
        s.update(Self.running) { $0.status = "completed" }     // the list has not noticed yet
        await m.sendMessage(threadId: Self.running)
        #expect(s.sends.isEmpty, "a stale steer must not turn into something else silently")
        #expect(m.composeNotices[Self.running] == "The run finished. Send as a new turn?")
        #expect(m.composer.text(ComposerStore.messageKey(Self.running)) == "use the staging database")
        await m.refresh()
        let now = try #require(m.state.sessions[Self.running])
        #expect(m.sendLabel(now) == "Send")
        await m.sendMessage(threadId: Self.running)
        #expect(s.sends.map(\.mode) == ["queue"])
    }

    // SND-03
    @Test func aRetryReusesTheRequestIdAndAnEditGetsANewOne() async throws {
        var o = FakeT3Server.Options(); o.failSends = true
        let (s, m) = try await setUp(o); defer { s.stop() }
        type(m, Self.running, "first")
        await m.sendMessage(threadId: Self.running)
        if case .error = m.composeStates[Self.running] {} else { Issue.record("expected an error") }
        #expect(m.sendLabel(try #require(m.state.sessions[Self.running])) == "Retry")
        #expect(m.composer.text(ComposerStore.messageKey(Self.running)) == "first", "the text survives a failure")
        let firstId = try #require(m.pendingSends[Self.running]?.id)
        await m.sendMessage(threadId: Self.running)
        #expect(m.pendingSends[Self.running]?.id == firstId, "the same message keeps its id")
        type(m, Self.running, "first, edited")
        await m.sendMessage(threadId: Self.running)
        #expect(m.pendingSends[Self.running]?.id != firstId, "an edited message is a new message")
        let editedId = try #require(m.pendingSends[Self.running]?.id)
        m.toggleSendMode(Self.running)
        await m.sendMessage(threadId: Self.running)
        #expect(m.pendingSends[Self.running]?.id != editedId, "a flipped mode is a new message")
    }

    @Test func aRepeatedRequestIdIsDeliveredOnce() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        type(m, Self.running, "once")
        async let a: Void = m.sendMessage(threadId: Self.running)
        async let b: Void = m.sendMessage(threadId: Self.running)   // a double click while the first is in flight
        _ = await (a, b)
        #expect(s.sends.count == 1)
    }

    // SND-12 (live finding 2026-11-15)
    @Test func aThreadInABroaderModeSaysSoInPlainWords() async throws {
        var o = FakeT3Server.Options(); o.modeEscalationDenied = true
        let (s, m) = try await setUp(o); defer { s.stop() }
        type(m, Self.running, "hello")
        await m.sendMessage(threadId: Self.running)
        #expect(m.composeStates[Self.running] == .error(HuddleModel.modeDeniedMessage))
        let q = try #require(m.state.sessions[Scenario.questionThread]?.question)
        m.select(option: "Concise", for: q)
        await m.sendAnswer(threadId: Scenario.questionThread)
        #expect(m.questionStates[q.requestId] == .error(HuddleModel.modeDeniedMessage), "picking an option hits the same wall")
        m.composer.drafts[ComposerStore.answerKey(q.requestId)] = "Concise"
        await m.sendWrittenAnswer(threadId: Scenario.questionThread)
        #expect(m.questionStates[q.requestId] == .error(HuddleModel.modeDeniedMessage))
    }

    // Sign out (spec 08)
    @Test func signingOutForgetsTheTokenAndSendsNothingMore() async throws {
        let s = try await startFake(); defer { s.stop() }
        let store = MemoryTokenStore(token: s.token)
        let m = makeModel(s, store: store)
        await m.refresh()
        #expect(m.isSignedIn && !m.sessions.isEmpty)
        let callsBefore = s.calls.count
        #expect(m.signOut())
        #expect(store.load() == nil && !m.isSignedIn)
        #expect(m.sessions.isEmpty && m.state.connection == .unauthorized)
        #expect(m.connectNote?.contains("t3 auth session revoke") == true)
        await m.refresh()
        #expect(s.calls.count == callsBefore, "no token, no calls")
    }

    final class RefusingStore: TokenStore, @unchecked Sendable {
        let token: String
        init(_ t: String) { token = t }
        func load() -> String? { token }
        func save(_ token: String) throws {}
        func delete() -> Bool { false }
    }

    @Test func aRefusedSignOutChangesNothingAndSaysSo() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s, store: RefusingStore(s.token))
        await m.refresh()
        let before = m.sessions.count
        #expect(!m.signOut())
        #expect(m.isSignedIn && m.sessions.count == before && m.state.connection == .connected)
        #expect(m.connectNote?.contains("Keychain") == true)
    }

    @Test func aThreadOnAnotherMachineSaysSoInPlainWords() async throws {
        var o = FakeT3Server.Options(); o.linkedEnvironments = true; o.linkedSendDenied = true
        let s = try await startFake(o); defer { s.stop() }
        Scenario.addRemoteApproval(s)
        s.add(.init(id: "thr_remote_running", title: "Remote work", status: "running", environmentId: "env_remote"))
        let m = makeModel(s)
        await m.refresh()
        let remote = try #require(m.state.sessions["thr_remote_running"])
        #expect(!m.canMessage(remote), "no composer for a thread T3 will not take messages for")
        m.composer.drafts[ComposerStore.messageKey("thr_remote_running")] = "hi"
        await m.sendMessage(threadId: "thr_remote_running")
        #expect(s.sends.isEmpty)
        #expect(HuddleModel.oneLine(HuddleError.toolFailed(#"{"code":"capability_denied"}"#)) == HuddleModel.otherMachineDeniedMessage,
                "an answer refused the same way reads in plain words")
    }

    // SND-04
    @Test func readOnlyModeSendsNothing() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        m.setReadOnly(true)
        type(m, Self.running, "hello")
        await m.sendMessage(threadId: Self.running)
        let q = try #require(m.state.sessions[Scenario.questionThread]?.question)
        m.composer.drafts[ComposerStore.answerKey(q.requestId)] = "Friendly"
        await m.sendWrittenAnswer(threadId: Scenario.questionThread)
        #expect(s.sends.isEmpty && s.answers.isEmpty)
        if case .error = m.composeStates[Self.running] {} else { Issue.record("expected the read-only error") }
    }

    // SND-05
    @Test func theTargetCannotChangeUnderTheComposer() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        m.openComposer(Self.running); type(m, Self.running, "hi")
        m.composeTargets[Self.running] = "env_somewhere_else"      // as if the row now came from another machine
        await m.sendMessage(threadId: Self.running)
        #expect(s.sends.isEmpty)
        m.composeTargets[Self.running] = ""
        m.state.collidingThreadIds.insert(Self.running)
        await m.sendMessage(threadId: Self.running)
        #expect(s.sends.isEmpty)
    }

    @Test func emptyOrOverlongTextIsNotSent() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        type(m, Self.running, "   \n ")
        await m.sendMessage(threadId: Self.running)
        type(m, Self.running, String(repeating: "x", count: HuddleModel.maxMessageLength + 1))
        await m.sendMessage(threadId: Self.running)
        #expect(s.sends.isEmpty)
    }

    @Test func threadsThatAskForSomethingGetThatFirst() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        #expect(!m.canMessage(try #require(m.state.sessions[Scenario.questionThread])))
        #expect(!m.canMessage(try #require(m.state.sessions[Scenario.permissionThread])))
    }

    // SND-06
    @Test func aWrittenAnswerIsSentAsTyped() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        let q = try #require(m.state.sessions[Scenario.questionThread]?.question)
        #expect(q.freeTextAnswerable)
        m.startWritingAnswer(q.requestId)
        m.composer.drafts[ComposerStore.answerKey(q.requestId)] = "Friendly, one line per entry"
        await m.sendWrittenAnswer(threadId: Scenario.questionThread)
        #expect(s.answers.last?.answers[q.questionId].string == "Friendly, one line per entry")
        #expect(m.writingAnswerFor == nil && m.rowToasts[Scenario.questionThread] == "Answer sent")
        #expect(m.state.sessions[Scenario.questionThread]?.question == nil)
    }

    @Test func aMultiSelectQuestionCanBeWrittenButNotAPartOfSeveral() {
        let multi = QuestionCodec.question(fromRead: ["requestId": "r", "questions": [["id": "q", "question": "Pick", "options": ["a", "b"], "multiSelect": true]]], threadId: "t")
        let several = QuestionCodec.question(fromRead: ["requestId": "r", "questions": [["id": "q1", "question": "A"], ["id": "q2", "question": "B"]]], threadId: "t")
        let open = QuestionCodec.question(fromRead: ["requestId": "r", "questions": [["id": "q", "question": "Why?"]]], threadId: "t")
        // Seen live: T3 took a written answer to a multi-select question as plain text. Several questions are written one
        // at a time in their own flow (spec 04), not through this single-answer editor.
        #expect(multi?.freeTextAnswerable == true && several?.freeTextAnswerable == false)
        #expect(open?.freeTextAnswerable == true && open?.answerableInWidget == false)
    }

    // SND-07
    @Test func messagesNeverReachTheLog() async throws {
        let cap = LogCapture()
        var o = FakeT3Server.Options(); o.failSends = true
        let s = try await startFake(o); defer { s.stop() }
        let m = makeModel(s, log: cap.log)
        await m.refresh()
        type(m, Self.running, "secret plan: ship on friday")
        await m.sendMessage(threadId: Self.running)
        #expect(!cap.lines.contains { $0.contains("secret plan") })
    }

    // SND-08
    @Test func onlyQueueAndSteerEverReachT3() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        type(m, Self.running, "a"); await m.sendMessage(threadId: Self.running)
        type(m, Self.running, "b"); await m.sendMessage(threadId: Self.running, steer: true)
        type(m, Self.finished, "c"); await m.sendMessage(threadId: Self.finished)
        let sendCalls = s.calls.filter { $0.tool == "t3_thread_send" }
        #expect(sendCalls.count == 3)
        for c in sendCalls {
            #expect(["queue", "steer"].contains(c.args["mode"].string ?? ""))
            #expect(c.args["freshContext"].isNull)
            #expect(c.args["clientRequestId"].string != nil)
        }
        let forbidden: Set = ["t3_thread_launch", "t3_thread_interrupt", "t3_queue"]
        #expect(Set(s.calls.map(\.tool)).isDisjoint(with: forbidden))
    }

    @Test func theOnlySendCallSiteIsTheTypedOne() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/FakeT3/") }
        var sites: [String] = []
        for f in files where try String(contentsOf: f, encoding: .utf8).contains("\"t3_thread_send\"") { sites.append(f.lastPathComponent) }
        #expect(sites.sorted() == ["HuddleModel+Compose.swift", "MCPClient.swift"].sorted() || sites == ["MCPClient.swift"])
        let compose = try String(contentsOf: root.appendingPathComponent("HuddleCore/HuddleModel+Compose.swift"), encoding: .utf8)
        #expect(!compose.contains("callTool"), "the model goes through MCPClient.sendMessage")
    }

    // SND-09
    @Test func withoutTheToolOrItsModeArgumentThereIsNoMessageButton() async throws {
        var o = FakeT3Server.Options(); o.omitTools = ["t3_thread_send"]
        let (s, m) = try await setUp(o); defer { s.stop() }
        #expect(!m.canSendMessages)
        var o2 = FakeT3Server.Options(); o2.dropArguments = ["t3_thread_send": "mode"]
        let (s2, m2) = try await setUp(o2); defer { s2.stop() }
        #expect(!m2.canSendMessages)
        type(m2, Self.running, "x"); await m2.sendMessage(threadId: Self.running)
        #expect(s2.sends.isEmpty)
    }

    @Test func pollingNeverSends() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        type(m, Self.running, "draft only")
        for _ in 0..<3 { await m.refresh() }
        #expect(!s.calls.contains { $0.tool == "t3_thread_send" })
        #expect(m.composer.text(ComposerStore.messageKey(Self.running)) == "draft only", "a draft survives polls")
    }

    @Test func aDraftSurvivesItsThreadLeavingTheList() async throws {
        let (s, m) = try await setUp(); defer { s.stop() }
        m.openComposer(Self.finished); type(m, Self.finished, "keep me")
        s.update(Self.finished) { $0.settled = true }          // settled: drops out of the list
        await m.refresh(); await m.refresh()
        #expect(m.state.sessions[Self.finished] == nil)
        #expect(m.composingThreadId == nil, "no composer for a thread that is gone")
        #expect(m.composer.text(ComposerStore.messageKey(Self.finished)) == "keep me", "typed text is never thrown away")
    }

    @Test func sendingWhenT3IsUnreachableSaysSo() async throws {
        let (s, m) = try await setUp()
        type(m, Self.running, "hello")
        s.stop()
        await m.refresh()                                     // the client is dropped once T3 is gone
        try #require(m.state.sessions[Self.running] != nil)
        await m.sendMessage(threadId: Self.running)
        if case .error = m.composeStates[Self.running] {} else { Issue.record("a send that cannot happen must say so, not do nothing") }
        #expect(m.composer.text(ComposerStore.messageKey(Self.running)) == "hello")
    }
}
