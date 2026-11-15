import Testing
import Foundation
@testable import HuddleCore
import FakeT3

@MainActor
@Suite("HuddleModel end-to-end against the fake")
struct ModelTests {
    @Test func fourRowsCountAndNoiseExcluded() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        #expect(m.state.connection == .connected)
        #expect(m.sessions.count == 4)
        #expect(m.state.count == 4)
        let ids = Set(m.sessions.map(\.threadId))
        #expect(!ids.contains("thr_idle") && !ids.contains("thr_done_settled") && !ids.contains("thr_child"))
        // Never read a subagent thread (reading marks it delivered, §5.3).
        #expect(!s.calls.contains { $0.args["threadId"].string == "thr_child" })
    }

    @Test func questionAndPermissionDetected() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        let q = try #require(m.state.sessions[Scenario.questionThread])
        #expect(q.statusLine == "asks a question"); #expect(q.question?.prompt == "Which tone should the changelog use?")
        let p = try #require(m.state.sessions[Scenario.permissionThread])
        #expect(p.statusLine == "needs permission")
        #expect(p.permission?.summary == "Bash: gh issue edit 142 --add-label needs-info")
        let firstTwo = m.sessions.prefix(2).map(\.needsAttention)
        #expect(firstTwo == [true, true])    // attention first
    }

    @Test func sendAnswerSucceedsAndPanelCloses() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        let q = try #require(m.state.sessions[Scenario.questionThread]?.question)
        m.select(option: "Concise", for: q)
        await m.sendAnswer(threadId: Scenario.questionThread)
        #expect(s.answers.count == 1)
        #expect(m.state.sessions[Scenario.questionThread]?.question == nil)
        #expect(m.state.sessions[Scenario.questionThread]?.statusLine != "needs permission")
    }

    @Test func sendFailureKeepsPanelAndSelection() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        let q = try #require(m.state.sessions[Scenario.questionThread]?.question)
        m.select(option: "The number one", for: q)
        s.update(Scenario.questionThread) { $0.questions = [] }   // answered elsewhere → respond fails
        await m.sendAnswer(threadId: Scenario.questionThread)
        if case .error = m.questionStates[q.requestId] {} else { Issue.record("expected error state") }
        #expect(m.selections[q.requestId] == "The number one")
        #expect(m.state.sessions[Scenario.questionThread]?.question != nil)
        await m.refresh()   // next poll notices it was answered elsewhere → panel closes
        #expect(m.state.sessions[Scenario.questionThread]?.question == nil)
    }

    @Test func permissionResolvedElsewhereClearsFlag() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        #expect(m.state.sessions[Scenario.permissionThread]?.permission != nil)
        s.update(Scenario.permissionThread) { $0.permissionPending = false; $0.status = "running" }   // approved in T3
        await m.refresh()
        #expect(m.state.sessions[Scenario.permissionThread]?.permission == nil)
        #expect(m.state.sessions[Scenario.permissionThread]?.statusLine != "needs permission")
    }

    @Test func detailViewShowsLiveTerminalOutput() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        m.openDetail(Scenario.renderThread)
        await m.refresh()
        #expect(m.selected?.terminal?.tail.last == "rendering page 95/139…")
        Scenario.advanceRender(s)
        await m.refresh()
        #expect(m.selected?.terminal?.tail.last == "rendering page 99/139…")
        #expect(m.selected?.steps.count == 4)
    }

    @Test func closeNeedsTwoTapsHidesAndNeverCallsT3WriteTools() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        m.closeTapped(Scenario.draftThread)
        #expect(m.armedCloseID == Scenario.draftThread); #expect(m.state.count == 4)
        m.closeTapped(Scenario.draftThread)
        #expect(m.state.count == 3); #expect(m.armedCloseID == nil)
        await m.refresh()
        #expect(m.state.count == 3)     // stays hidden on later polls
        #expect(s.thread(Scenario.draftThread)?.status == "running")   // nothing changed in T3
    }

    @Test func closeNeverSettlesUnlessSettingOnAndFinished() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        m.setCloseSettles(true)
        await m.refresh()
        m.closeTapped(Scenario.draftThread); m.closeTapped(Scenario.draftThread)   // active → never settled
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!s.calls.contains { $0.tool == "t3_thread_organize" })
    }

    @Test func clientNeverCallsForbiddenToolsOrIncludeSubagents() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        m.openDetail(Scenario.renderThread); await m.refresh()
        let q = try #require(m.state.sessions[Scenario.questionThread]?.question)
        m.select(option: "Concise", for: q); await m.sendAnswer(threadId: Scenario.questionThread)
        await m.jump(Scenario.renderThread)
        let forbidden: Set = ["t3_thread_send", "t3_thread_launch", "t3_thread_interrupt", "t3_thread_organize"]
        #expect(Set(s.calls.map(\.tool)).isDisjoint(with: forbidden))
        #expect(!s.calls.contains { !$0.args["includeSubagents"].isNull })
        let allowed: Set = ["t3_thread_list", "t3_thread_read", "t3_pending_request", "t3_project_read", "t3_environment_read"]
        #expect(Set(s.calls.map(\.tool)).isSubset(of: allowed))
    }

    @Test func readOnlyModeBlocksSend() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s); m.setReadOnly(true)
        await m.refresh()
        let q = try #require(m.state.sessions[Scenario.questionThread]?.question)
        m.select(option: "Concise", for: q)
        await m.sendAnswer(threadId: Scenario.questionThread)
        #expect(s.answers.isEmpty)
        if case .error = m.questionStates[q.requestId] {} else { Issue.record("expected error") }
    }

    @Test func jumpBuildsTheThreadDeepLinkAndShowsNoToastWhenDelivered() async throws {
        let s = try await startFake(); defer { s.stop() }
        let j = RecordingJumper()
        let m = makeModel(s, jumper: j)
        await m.refresh()
        let before = s.calls.count
        await m.jump(Scenario.permissionThread)
        #expect(j.targets.first?.threadId == Scenario.permissionThread)
        #expect(j.targets.first?.deepLink?.absoluteString == "t3code://threads/env_local/\(Scenario.permissionThread)")
        #expect(m.toast == nil)                                       // delivered: no "Open … in T3 Code" button
        #expect(s.calls.count == before)                              // jumping needs no T3 call at all
    }

    @Test func jumpFallsBackToAHintOnlyWhenDeliveryFails() async throws {
        let s = try await startFake(); defer { s.stop() }
        let j = RecordingJumper(); j.succeeds = false
        let m = makeModel(s, jumper: j)
        await m.refresh(); await m.jump(Scenario.permissionThread)
        #expect(m.toast?.contains("Triage open issues") == true)
    }

    @Test func unauthorizedDropsTokenAndAsksToConnect() async throws {
        let s = try await startFake(); defer { s.stop() }
        let store = MemoryTokenStore(token: "stale-token")
        let m = makeModel(s, store: store)
        await m.refresh()
        #expect(m.state.connection == .unauthorized)
        #expect(store.load() == nil)                                    // dropped on 401 (§7.1)
        #expect(m.connectNote?.contains("HTTP 401") == true)            // the user is told why
        await m.submitToken(s.token)                                    // paste path
        #expect(m.state.connection == .connected); #expect(store.load() == s.token); #expect(m.connectNote == nil)
    }

    @Test func noTokenMeansConnectStateWithoutAnyRequest() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = HuddleModel(config: HuddleConfig(source: .fixed(s.url), tokenStore: MemoryTokenStore()))
        await m.refresh()
        #expect(m.state.connection == .unauthorized); #expect(s.requestCount == 0)
    }

    @Test func serverGoneThenBackRecovers() async throws {
        let s = try await startFake()
        let m = makeModel(s)
        await m.refresh(); #expect(m.state.connection == .connected)
        let port = s.port
        s.stop(); try await Task.sleep(nanoseconds: 150_000_000)
        await m.refresh()
        #expect(m.state.connection == .notRunning); #expect(m.consecutiveFailures == 1)
        #expect(m.state.connection.headline == "T3 Code not running")
        // Re-bind the same port. Other tests run in parallel and may briefly hold it, so retry for a moment.
        var s2: FakeT3Server!
        for attempt in 0..<30 {
            let candidate = FakeT3Server(); Scenario.populate(candidate)
            if (try? await candidate.start(port: port)) != nil { s2 = candidate; break }
            if attempt == 29 { Issue.record("could not re-bind port \(port)"); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        defer { s2.stop() }
        await m.refresh()
        #expect(m.state.connection == .connected); #expect(m.consecutiveFailures == 0)
    }

    @Test func contractDriftShowsUnsupportedVersion() async throws {
        var o = FakeT3Server.Options(); o.omitTools = ["t3_pending_request"]
        let s = try await startFake(o); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        #expect(m.state.connection == .unsupported("missing tool t3_pending_request"))
        #expect(m.state.connection.headline?.hasPrefix("Unsupported T3 Code version") == true)
        #expect(!s.calls.contains { $0.tool == "t3_thread_list" })        // no data calls on drift
    }

    @Test func contractDriftDetectsLostArgument() async throws {
        var o = FakeT3Server.Options(); o.dropArguments = ["t3_thread_read": "afterPosition"]
        let s = try await startFake(o); defer { s.stop() }
        let m = makeModel(s); await m.refresh()
        #expect(m.state.connection == .unsupported("t3_thread_read lost argument afterPosition"))
    }

    @Test func hiddenIdsAndTogglesPersistUnderInjectedPrefsDir() async throws {
        let s = try await startFake(); defer { s.stop() }
        let dir = tempDir()
        let m = makeModel(s, prefs: PreferencesStore(directory: dir))
        await m.refresh()
        m.closeTapped(Scenario.draftThread); m.closeTapped(Scenario.draftThread)
        m.toggleMute(); m.toggleCollapsed()
        let m2 = makeModel(s, prefs: PreferencesStore(directory: dir))
        #expect(m2.state.hiddenIDs == [Scenario.draftThread]); #expect(m2.muted); #expect(m2.collapsed)
    }

    @Test func soundPlaysOncePerNewAttentionAndNotWhenMuted() async throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let s = try await startFake(); defer { s.stop() }
        let c = Counter()
        let m = HuddleModel(config: HuddleConfig(source: .fixed(s.url), tokenStore: MemoryTokenStore(token: s.token),
                                                 playSound: { c.n += 1 }))
        await m.refresh(); #expect(c.n == 1)
        await m.refresh(); #expect(c.n == 1)                      // no repeat while still needing attention
        m.toggleMute()
        s.update(Scenario.draftThread) { $0.status = "waiting"; $0.permissionPending = true }
        await m.refresh(); #expect(c.n == 1)                      // muted
    }
}

@MainActor
@Suite("Review-driven hardening")
struct HardeningTests {
    @Test func unreadableQuestionIsAQuestionNotAPermission() async throws {
        var o = FakeT3Server.Options(); o.questionReadShape = .garbled
        let s = try await startFake(o); defer { s.stop() }
        let m = makeModel(s); await m.refresh()
        let q = try #require(m.state.sessions[Scenario.questionThread])
        #expect(q.statusLine == "asks a question")
        #expect(q.permission == nil)
        #expect(q.question?.answerableInWidget == false)          // "Type in T3 Code" only
        await m.sendAnswer(threadId: Scenario.questionThread)     // must be a no-op
        #expect(s.answers.isEmpty)
    }

    @Test func alternateQuestionShapeStillDecodesAndAnswers() async throws {
        var o = FakeT3Server.Options(); o.questionReadShape = .flat
        let s = try await startFake(o); defer { s.stop() }
        let m = makeModel(s); await m.refresh()
        let q = try #require(m.state.sessions[Scenario.questionThread]?.question)
        #expect(q.options.count == 3); #expect(q.answerableInWidget)
        m.select(option: "The question one", for: q); await m.sendAnswer(threadId: Scenario.questionThread)
        #expect(s.answers.count == 1)
    }

    @Test func multiSelectFallsBackToTypeInT3() async throws {
        let s = try await startFake(); defer { s.stop() }
        s.update(Scenario.questionThread) { $0.questions[0].multiSelect = true }
        let m = makeModel(s); await m.refresh()
        #expect(m.state.sessions[Scenario.questionThread]?.question?.answerableInWidget == false)
    }

    @Test func failedPendingListIsNotInferredAsPermission() async throws {
        var o = FakeT3Server.Options(); o.pendingListFails = true
        let s = try await startFake(o); defer { s.stop() }
        let m = makeModel(s); await m.refresh()
        #expect(m.state.sessions[Scenario.permissionThread]?.permission == nil)
        #expect(m.state.sessions[Scenario.permissionThread]?.statusLine != "needs permission")
    }

    @Test func longOutputKeepsTheTailAndFetchesOnlyNewText() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        let big = (0..<3000).map { "line \($0)" }.joined(separator: "\n")      // ~27k chars > old 20k cap
        s.add(.init(id: "t", title: "T", status: "running", items: [Scenario.cmd(0, "make", output: big, status: "running")]))
        let m = makeModel(s); await m.refresh()
        m.openDetail("t"); await m.refresh()
        #expect(m.selected?.terminal?.tail.last == "line 2999")
        #expect(m.selected?.terminal?.tail.count == 20)
        // More output arrives; a list-level read (400-char head) must not clobber the full tail.
        s.update("t") { $0.items[0].text += "\nline 3000\nline 3001" }
        let before = s.calls.count
        await m.refresh()
        #expect(m.selected?.terminal?.tail.last == "line 3001")
        let textCalls = s.calls[before...].filter { $0.tool == "t3_thread_read" && !$0.args["itemId"].isNull }
        #expect(textCalls.allSatisfy { ($0.args["textOffset"].int ?? 0) > 20_000 })   // incremental, not from 0
        await m.refresh()
        #expect(m.selected?.terminal?.tail.last == "line 3001")                      // stable: no flicker to the head
    }

    @Test func threadThatResolvesToIdleLeavesTheHuddle() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s); await m.refresh()
        #expect(m.state.sessions[Scenario.draftThread] != nil)
        s.update(Scenario.draftThread) { $0.status = "idle" }
        await m.refresh()
        #expect(m.state.sessions[Scenario.draftThread] == nil)
    }

    @Test func finishedRefreshIsOnePageWithNoCursorChasing() async throws {
        let s = try await startFake(); defer { s.stop() }
        let longAgo = FakeT3Server.iso(Date().addingTimeInterval(-3 * 3600))
        for i in 0..<60 { var t = FakeT3Server.FakeThread(id: "old\(i)", title: "old", status: "completed"); t.updatedAt = longAgo; s.add(t) }   // backlog of unsettled finished
        let m = makeModel(s); await m.refresh()
        s.update(Scenario.draftThread) { $0.status = "completed" }    // one known session finishes → refresh is needed
        let before = s.calls.count
        await m.refresh()
        #expect(m.state.sessions[Scenario.draftThread]?.statusLine == "Done")
        let finishedCalls = s.calls[before...].filter {
            $0.tool == "t3_thread_list" && $0.args["settled"].bool == false }
        #expect(finishedCalls.count == 1)
        #expect(finishedCalls.allSatisfy { $0.args["cursor"].isNull && $0.args["limit"].int == 25 })
        #expect(m.state.sessions.keys.contains { $0.hasPrefix("old") } == false)   // backlog older than the recent window is never admitted
    }

    @Test func retryNeverFasterThanBackoffEvenWithDetailOpen() {
        #expect(PollSchedule.loopInterval(detailOpen: true, expanded: true, consecutiveFailures: 0) == 1)
        #expect(PollSchedule.loopInterval(detailOpen: true, expanded: true, consecutiveFailures: 1) >= 5)
        #expect(PollSchedule.loopInterval(detailOpen: true, expanded: true, consecutiveFailures: 3) == 15)
        #expect(PollSchedule.loopInterval(detailOpen: false, expanded: false, consecutiveFailures: 0) == 5)
    }

    struct Reject: PeerVerifier { func verify(pid: Int?, port: Int) -> Bool { false } }
    struct Accept: PeerVerifier { func verify(pid: Int?, port: Int) -> Bool { pid == 4242 } }

    @Test func peerRefusalSendsNothingToTheServer() async throws {
        let s = try await startFake(); defer { s.stop() }
        let f = tempDir().appendingPathComponent("server-runtime.json")
        try #"{"host":"127.0.0.1","port":\#(s.port),"pid":4242}"#.write(to: f, atomically: true, encoding: .utf8)
        let rejecting = HuddleModel(config: HuddleConfig(source: .runtimeFile(Discovery(runtimeFile: f)),
            tokenStore: MemoryTokenStore(token: s.token), peerVerifier: Reject(), log: HuddleLog(sink: { _ in })))
        await rejecting.refresh()
        #expect(rejecting.state.connection == .error("Listener on the T3 port is not T3 Code"))
        #expect(s.requestCount == 0)                       // the token was never sent anywhere

        let accepting = HuddleModel(config: HuddleConfig(source: .runtimeFile(Discovery(runtimeFile: f)),
            tokenStore: MemoryTokenStore(token: s.token), peerVerifier: Accept(), log: HuddleLog(sink: { _ in })))
        await accepting.refresh()
        #expect(accepting.state.connection == .connected)
    }

    @Test func missingRuntimeFileMeansNotRunningWithoutNetwork() async {
        let f = tempDir().appendingPathComponent("absent.json")
        let m = HuddleModel(config: HuddleConfig(source: .runtimeFile(Discovery(runtimeFile: f)),
                                                 tokenStore: MemoryTokenStore(token: "x"), log: HuddleLog(sink: { _ in })))
        await m.refresh()
        #expect(m.state.connection == .notRunning)
    }
}

@MainActor
@Suite("Live-shape fixes (found by the first real T3 run)")
struct LiveShapeTests {
    @Test func numericNextCursorIsKeptAndSentBackAsANumber() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        for i in 0..<7 { s.add(.init(id: "t\(i)", title: "T", status: "running")) }
        let c = try MCPClient(endpoint: s.url, token: s.token)
        let page = try await c.listThreadsPage(statuses: ["running"], limit: 3)
        #expect(page.nextCursor == .number(3))              // live T3: `"nextCursor": 5`
        #expect(page.threads.count == 3)
        let all = try await c.listThreads(statuses: ["running"], limit: 3)
        #expect(Set(all.map(\.threadId)).count == 7)        // every page fetched, no duplicates
        #expect(s.calls.contains { $0.args["cursor"] == .number(3) })
    }

    @Test func activityReadsOnlyTheLatestRunAndNeverSendsNegativeAfterPosition() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        s.add(.init(id: "t", title: "T", status: "running", items: [
            .init(position: 0, itemId: "old", type: "command_execution", status: "completed", title: nil, text: "$ old run", runId: "run_1"),
            .init(position: 1, itemId: "new", type: "command_execution", status: "running", title: nil, text: "$ new run", runId: "run_2")]))
        s.update("t") { $0.latestRunId = "run_2" }
        let m = makeModel(s); await m.refresh(); await m.refresh()
        #expect(m.state.sessions["t"]?.steps.map(\.label) == ["new run"])
        for c in s.calls where c.tool == "t3_thread_read" { #expect((c.args["afterPosition"].int ?? 0) >= 0) }
        #expect(s.calls.filter { $0.tool == "t3_thread_read" }.allSatisfy { $0.args["runLimit"] == .number(1) })
    }

    @Test func newRunRestartsStepsFromTheTop() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        s.add(.init(id: "t", title: "T", status: "running", items: (0..<5).map {
            .init(position: $0, itemId: "a\($0)", type: "dynamic_tool", status: "completed", title: "Read a\($0)", text: "", runId: "run_1") }))
        let m = makeModel(s); await m.refresh()
        #expect(m.state.sessions["t"]?.steps.count == 5)
        s.update("t") { t in   // a new run begins: positions restart at 0 inside the latest-run window
            t.latestRunId = "run_2"
            t.items = [.init(position: 0, itemId: "b0", type: "dynamic_tool", status: "running", title: "Write b", text: "", runId: "run_2")]
        }
        await m.refresh()
        #expect(m.state.sessions["t"]?.steps.map(\.id) == ["b0"])
    }

    @Test func userMessagesAreNotStepsAndPathsAreShortened() throws {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        s.applyRead(ThreadRead(threadId: "t", status: .running, items: [
            ActivityItem(position: 0, itemId: "u", type: "user_message", status: "completed", text: "please do things"),
            ActivityItem(position: 1, itemId: "r", type: "dynamic_tool", status: "completed", title: "Read /Users/x/proj/docs/SPEC.md"),
            ActivityItem(position: 2, itemId: "w", type: "dynamic_tool", status: "running", title: "Write /tmp/a/b/style-sheet.md")]))
        #expect(s.sessions["t"]?.steps.map(\.label) == ["Read SPEC.md", "Write style-sheet.md"])
        #expect(s.sessions["t"]?.steps.map(\.kind) == [.tool, .edit])
    }

    @Test func environmentIdParsedFromBothLinkFormats() {
        #expect(ThreadSummary.environment(fromLink: "https://app.t3.codes/threads/ENV1/mcp%3Aabc") == "ENV1")
        #expect(ThreadSummary.environment(fromLink: "t3-thread://v2/ENV2/thr") == "ENV2")
        #expect(ThreadSummary.environment(fromLink: nil) == nil)
    }

    @Test func linkedEnvironmentsOffMeansLocalOnlyAndNoErrorBanner() async throws {
        let s = try await startFake(); defer { s.stop() }          // default: capability_denied for any environmentId
        s.add(.init(id: "remote1", title: "On the studio Mac", status: "running", environmentId: "env_remote"))
        let m = makeModel(s); await m.refresh()
        #expect(m.state.connection == .connected)
        #expect(m.environments.map(\.id) == ["env_local"])
        #expect(m.state.sessions["remote1"] == nil)
        #expect(m.groups.count == 1)                                 // single environment ⇒ no group headers
        #expect(!s.calls.contains { !$0.args["environmentId"].isNull })
    }

    @Test func threadsGroupedByEnvironmentWhenLinkedEnvironmentsAreOn() async throws {
        var o = FakeT3Server.Options(); o.linkedEnvironments = true
        let s = try await startFake(o); defer { s.stop() }
        s.add(.init(id: "remote1", title: "On the studio Mac", status: "waiting", questions: [
            .init(requestId: "rq", header: "PICK", question: "Which?", options: ["A", "B"])], environmentId: "env_remote"))
        s.add(.init(id: "remote2", title: "Remote render", status: "running", environmentId: "env_remote"))
        let m = makeModel(s); await m.refresh()
        #expect(m.environments.map(\.label) == ["Mika’s Mac mini", "Studio Mac"])
        let g = m.groups
        #expect(g.map(\.label) == ["Mika’s Mac mini", "Studio Mac"])
        #expect(g[0].sessions.count == 4); #expect(g[1].sessions.map(\.threadId).sorted() == ["remote1", "remote2"])
        #expect(m.state.count == 6)
        // Remote calls carry the environment; local calls don't.
        #expect(s.calls.contains { $0.tool == "t3_pending_request" && $0.args["environmentId"].string == "env_remote" })
        #expect(!s.calls.contains { $0.args["threadId"].string == "thr_changelog" && !$0.args["environmentId"].isNull })
        // A machine shown only through the link is read-only: live T3 refuses answers sent that way (spec 15 connects it directly).
        let remote1 = try #require(m.state.sessions["remote1"])
        #expect(m.isLinkedOnly(remote1) && !m.canAnswer(remote1) && !m.canMessage(remote1))
        let q = try #require(remote1.question)
        m.select(option: "B", for: q); await m.sendAnswer(threadId: "remote1")
        #expect(s.answers.isEmpty, "nothing is sent through the link")
    }
}

@Suite("Thread deep links")
struct DeepLinkTests {
    func url(_ link: String?, env: String? = nil, id: String = "t") -> String? {
        JumpTarget(threadId: id, title: "T", environmentId: env, link: link).deepLink?.absoluteString
    }
    @Test func fromHostedLinkKeepsT3sEncoding() {
        #expect(url("https://app.t3.codes/threads/11111111-2222/mcp%3Aaaaaaaaa-bbbb", id: "mcp:aaaaaaaa-bbbb") == "t3code://threads/11111111-2222/mcp%3Aaaaaaaaa-bbbb")
        // a thread id that itself contains percent escapes (T3's nested ids) is encoded once more, exactly as T3's own link does
        #expect(url(nil, env: "E", id: "thread:a:b%3Ac") == "t3code://threads/E/thread%3Aa%3Ab%253Ac")
    }
    @Test func fromThreadLinkScheme() { #expect(url("t3-thread://v2/ENV/abc", id: "abc") == "t3code://threads/ENV/abc") }
    @Test func fromAMarkdownLinkAsLinkedMachinesReturnThem() {   // live shape from a linked machine's t3_thread_list
        #expect(url("[Simple Hello Test](t3-thread://v2/66666666-7777/cccccccc-dddd)", id: "cccccccc-dddd") == "t3code://threads/66666666-7777/cccccccc-dddd")
        #expect(url("[Fix (bug) now](t3-thread://v2/ENV/abc)", id: "abc") == "t3code://threads/ENV/abc")
        #expect(url("<t3-thread://v2/ENV/abc>", id: "abc") == "t3code://threads/ENV/abc")
    }
    @Test func threadSummaryStoresABareLinkAndEnvironmentFromAMarkdownLink() {
        let j: JSON = ["threadId": "f80e", "title": "T", "status": "completed",
                       "link": "[T](t3-thread://v2/ENV_REMOTE/f80e)"]
        let t = ThreadSummary(json: j)
        #expect(t?.link == "t3-thread://v2/ENV_REMOTE/f80e")
        #expect(t?.environmentId == "ENV_REMOTE")
    }
    @MainActor @Test func remoteSessionJumpsToACleanDeepLink() async throws {
        var o = FakeT3Server.Options(); o.linkedEnvironments = true; o.preLinked = true
        let s = try await startFake(o); defer { s.stop() }
        s.add(.init(id: "remote1", title: "On the studio Mac", status: "running", environmentId: "env_remote"))
        let m = makeModel(s); await m.refresh()
        #expect(m.state.sessions["remote1"]?.link == "t3-thread://v2/env_remote/remote1")
        let target = m.state.sessions["remote1"].map { JumpTarget(threadId: $0.threadId, title: $0.title, environmentId: $0.environmentId, link: $0.link) }
        #expect(target?.deepLink?.absoluteString == "t3code://threads/env_remote/remote1")
    }
    @Test func fallbackFromEnvironmentAndIdEncodesColons() { #expect(url(nil, env: "ENV", id: "mcp:abc") == "t3code://threads/ENV/mcp%3Aabc") }
    @Test func noLinkNoEnvironmentMeansNoDeepLink() { #expect(url(nil) == nil) }
}

@MainActor
@Suite("Linking other machines")
struct LinkingTests {
    func fake(preLinked: Bool, approve: Bool = true) async throws -> FakeT3Server {
        var o = FakeT3Server.Options(); o.linkedEnvironments = true; o.preLinked = preLinked; o.approveLinkRequests = approve
        let s = try await startFake(o)
        s.add(.init(id: "remote1", title: "On the studio Mac", status: "running", environmentId: "env_remote"))
        return s
    }

    @Test func nothingLinkedYetShowsThisMacOnlyAndNeverLinksOnItsOwn() async throws {
        let s = try await fake(preLinked: false); defer { s.stop() }       // live today: links: [] "not linked yet"
        let m = makeModel(s); await m.refresh(); await m.refresh()
        #expect(m.environments.map(\.id) == ["env_local"]); #expect(m.state.sessions["remote1"] == nil)
        #expect(m.state.connection == .connected)
        #expect(!s.calls.contains { $0.tool == "t3_environment_link" })     // only on an explicit user action
        #expect(m.canLinkEnvironments)
    }

    @Test func userActionAsksT3ForTheLinkCardThenTheMachineAppears() async throws {
        let s = try await fake(preLinked: false); defer { s.stop() }
        let m = makeModel(s); await m.refresh()
        await m.linkOtherEnvironments()
        let call = try #require(s.calls.last { $0.tool == "t3_environment_link" })
        #expect(call.args["requestedAccess"].string == "approval-required")  // never full-access
        #expect(m.toast?.contains("Approve") == true)
        await m.refresh()                                                    // user approved in T3 → link list now has it
        #expect(m.environments.map(\.label) == ["Mika’s Mac mini", "Studio Mac"])
        #expect(m.state.sessions["remote1"] != nil)
        #expect(m.groups.map(\.label) == ["Mika’s Mac mini", "Studio Mac"])
    }

    @Test func pendingApprovalKeepsLocalOnly() async throws {
        let s = try await fake(preLinked: false, approve: false); defer { s.stop() }
        let m = makeModel(s); await m.refresh(); await m.linkOtherEnvironments(); await m.refresh()
        #expect(m.environments.count == 1); #expect(m.state.count == 4)
    }

    @Test func withoutTheLabsSettingThereIsNoLinkToolAndAHintIsShown() async throws {
        let s = try await startFake(); defer { s.stop() }                    // linkedEnvironments off → tool absent
        let m = makeModel(s); await m.refresh()
        #expect(!m.canLinkEnvironments)
        await m.linkOtherEnvironments()
        #expect(m.toast?.contains("Labs") == true)
        #expect(!s.calls.contains { $0.tool == "t3_environment_link" })
    }

    @Test func preLinkedMachineListedByLiveShape() async throws {
        let s = try await fake(preLinked: true); defer { s.stop() }
        let m = makeModel(s); await m.refresh()
        #expect(m.environments.contains { $0.label == "Studio Mac" && !$0.isLocal })
        #expect(m.state.sessions["remote1"]?.environmentId == "env_remote")
    }
}

@MainActor
@Suite("Project names and expandable steps against the fake")
struct DetailModelTests {
    @Test func projectTitleIsFetchedOncePerProjectAndNoProjectIsHidden() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s); await m.refresh(); await m.refresh()
        let session = m.state.sessions[Scenario.renderThread]!
        #expect(m.projectName(for: session) == "Demo project")
        #expect(s.calls.filter { $0.tool == "t3_project_read" }.count == 1)    // all demo threads share one project
    }

    @Test func aRunningStepIsOpenByDefaultAndTheRestOpenOnTap() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s); await m.refresh(); m.openDetail(Scenario.renderThread); await m.refresh()
        let steps = m.state.sessions[Scenario.renderThread]!.steps
        let running = steps.first { $0.state == .running }!, done = steps.last { $0.state == .done && $0.kind == .terminal }!
        #expect(m.isExpanded(threadId: Scenario.renderThread, running)); #expect(!m.isExpanded(threadId: Scenario.renderThread, done))
        await m.toggleStep(threadId: Scenario.renderThread, stepId: done.id)
        #expect(m.isExpanded(threadId: Scenario.renderThread, done))
        #expect(m.state.sessions[Scenario.renderThread]!.steps.first { $0.id == done.id }?.output == "done")   // full output fetched on open
        await m.toggleStep(threadId: Scenario.renderThread, stepId: running.id)
        #expect(!m.isExpanded(threadId: Scenario.renderThread, running))                                                                       // a hand-closed running step stays closed
    }
}

@MainActor
@Suite("Approval item that becomes waiting later")
struct LateApprovalTests {
    @Test func aPendingApprovalIsRereadUntilItIsWaiting() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        s.add(FakeT3Server.FakeThread(id: "t", title: "Needs approval", status: "running", items: [
            Scenario.cmd(0, "pwd", status: "running"),
            Scenario.approval(1, requestId: "rq_late", command: "pwd", status: "pending")], permissionPending: true))
        let m = makeModel(s); await m.refresh()
        #expect(m.state.sessions["t"]?.permission?.requestId == nil)            // not waiting yet: not approvable
        s.mutate { $0["t"]?.items[1].status = "waiting" }                       // flips WITHOUT a new updatedAt or item
        await m.refresh()
        #expect(m.state.sessions["t"]?.permission?.requestId == "rq_late")
    }
}

@Suite("Jump targets cannot be steered by a server-supplied link")
struct JumpTargetSafetyTests {
    func url(env: String?, id: String, link: String? = nil) -> String? {
        JumpTarget(threadId: id, title: "T", environmentId: env, link: link).deepLink?.absoluteString
    }
    @Test func theUrlIsAlwaysTheFixedSchemeAndHostWithExactlyTwoSegments() {
        #expect(url(env: "ENV", id: "abc") == "t3code://threads/ENV/abc")
        #expect(url(env: "ENV?x=y", id: "abc") == "t3code://threads/ENV%3Fx%3Dy/abc")                 // query characters are data, not structure
        #expect(url(env: "ENV/../other", id: "abc") == "t3code://threads/ENV%2F..%2Fother/abc")        // no extra segments
        #expect(url(env: "ENV", id: "a#b c\u{0}") == nil)                                               // control characters: refused
        #expect(url(env: "ENV", id: "..") == nil); #expect(url(env: "..", id: "abc") == nil)
        #expect(url(env: "ENV", id: "") == nil); #expect(url(env: "ENV", id: String(repeating: "a", count: 600)) == nil)
        #expect(url(env: "ENV", id: "a\u{202E}b") == nil)                                               // direction override: refused
    }
    @Test func aHostileLinkCannotChooseAnotherThread() {
        // The link names another environment and thread; the row's own identifiers decide.
        #expect(url(env: "ENV", id: "clicked", link: "https://untrusted.example/threads/OTHER_ENV/other") == "t3code://threads/ENV/clicked")
        // A link only supplies a missing environment id, and then still only through the fixed scheme and host.
        #expect(url(env: nil, id: "clicked", link: "https://untrusted.example/threads/OTHER_ENV/other") == "t3code://threads/OTHER_ENV/clicked")
        #expect(url(env: nil, id: "clicked", link: "javascript:alert(1)") == nil)
    }
}

@MainActor
@Suite("Nothing about a thread reaches disk")
struct PersistedDataTests {
    @Test func closingAThreadStoresItsIdOnlyNeverItsTitleOrCommands() async throws {
        let s = try await startFake(); defer { s.stop() }
        let dir = tempDir()
        let m = makeModel(s, prefs: PreferencesStore(directory: dir))
        await m.refresh()
        let title = try #require(m.state.sessions[Scenario.draftThread]?.title)
        m.closeTapped(Scenario.draftThread); m.closeTapped(Scenario.draftThread)         // two taps: arm, then confirm
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        let all = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(all.contains(Scenario.draftThread))                                          // the id is the persisted fact
        #expect(!all.contains(title))                                                         // the title is not
        #expect(!all.contains("npx") && !all.contains("render"))                              // no command text
    }
}
