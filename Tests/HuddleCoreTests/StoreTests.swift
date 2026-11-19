import Testing
import Foundation
@testable import HuddleCore

enum HuddleStateTestClock {
    static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d) }
}

@Suite("Store / reducer")
struct StoreTests {
    func summaries() throws -> [ThreadSummary] { ThreadListPage(json: try fixture("thread_list_active")).threads }

    @Test func membershipExcludesIdleAndSubagents() throws {
        var s = HuddleState()
        s.applyActive(try summaries())
        #expect(Set(s.sessions.keys) == ["thr_a", "thr_b"])
        #expect(s.count == 2)
    }

    @Test func statusLinePriority() throws {
        var s = HuddleState()
        s.applyActive(try summaries())
        s.applyRead(ThreadRead(json: try fixture("thread_read_activity")))
        // Running step label wins over the T3 status words.
        #expect(s.sessions["thr_a"]?.statusLine == "node scripts/render-notes.js --format pdf")
        // asks a question beats the running step; needs permission beats both.
        let q = Question(requestId: "r", threadId: "thr_a", prompt: "?", options: [.init(label: "x")])
        s.applyPending(threadId: "thr_a", questions: [q])
        #expect(s.sessions["thr_a"]?.statusLine == "asks a question")
        s.applyPending(threadId: "thr_a", questions: [])
        s.sessions["thr_a"]?.permission = PermissionPrompt(summary: nil)
        #expect(s.sessions["thr_a"]?.statusLine == "needs permission")
    }

    @Test func reasoningItemsAreNotSteps() throws {
        var s = HuddleState()
        s.applyActive(try summaries())
        s.applyRead(ThreadRead(json: try fixture("thread_read_activity")))
        let steps = s.sessions["thr_a"]!.steps
        #expect(steps.count == 4)
        #expect(!steps.contains { $0.label.contains("secret") })
        #expect(steps.map(\.kind) == [.terminal, .edit, .tool, .terminal])
        #expect(steps.last?.state == .running)
        #expect(s.sessions["thr_a"]?.doneStepCount == 3)
    }

    @Test func terminalPaneTailsOutputAndStripsPrompt() throws {
        var s = HuddleState()
        s.applyActive(try summaries())
        s.applyRead(ThreadRead(json: try fixture("thread_read_activity")))
        let term = s.sessions["thr_a"]!.terminal!
        #expect(term.command == "node scripts/render-notes.js --format pdf")
        #expect(term.tail == ["rendering page 95/139…"])
        #expect(term.running)
        let long = (1...50).map { "line \($0)" }.joined(separator: "\n")
        s.setOutput(threadId: "thr_a", itemId: "i4", output: long)
        #expect(s.sessions["thr_a"]!.terminal!.tail.count == 20)
        #expect(s.sessions["thr_a"]!.terminal!.tail.last == "line 50")
    }

    @Test func orderingAttentionFirstThenRecent() throws {
        var s = HuddleState()
        s.applyActive(try summaries())
        #expect(s.visible.map(\.threadId) == ["thr_a", "thr_b"])   // a is newer
        let q = Question(requestId: "r", threadId: "thr_b", prompt: "?", options: [.init(label: "x")])
        s.applyPending(threadId: "thr_b", questions: [q])
        #expect(s.visible.map(\.threadId) == ["thr_b", "thr_a"])   // attention first
    }

    @Test func permissionInferredWhenWaitingWithNoListedQuestion() throws {
        var s = HuddleState()
        s.applyActive(try summaries())
        s.applyRead(ThreadRead(threadId: "thr_b", status: .waiting, pendingRequestCount: 1,
                               items: [ActivityItem(position: 0, itemId: "c", type: "command_execution",
                                                    status: "running", text: "$ rm -rf build")]))
        s.applyPending(threadId: "thr_b", questions: [])
        #expect(s.sessions["thr_b"]?.attention == .needsPermission)
        #expect(s.sessions["thr_b"]?.permission?.summary == "Bash: rm -rf build")
        s.clearPending(threadId: "thr_b")
        #expect(s.sessions["thr_b"]?.attention == Attention.none)
    }

    @Test func closeHidesAndReappearsOnNewAttention() throws {
        var s = HuddleState()
        s.applyActive(try summaries())
        s.hide("thr_a")
        #expect(s.count == 1)
        #expect(s.sessions["thr_a"] != nil)               // hidden, not forgotten
        s.applyActive(try summaries())                    // still hidden after another poll
        #expect(s.count == 1)
        let q = Question(requestId: "r", threadId: "thr_a", prompt: "?", options: [.init(label: "x")])
        s.applyPending(threadId: "thr_a", questions: [q]) // starts needing attention → comes back
        #expect(s.count == 2)
    }

    @Test func finishedSessionsStayUntilSettledThenLeave() throws {
        var s = HuddleState()
        s.applyActive(try summaries())
        // thr_a finishes: no longer in the active list, shows in the finished refresh.
        s.applyActive(try summaries().filter { $0.threadId != "thr_a" && $0.parentThreadId != "thr_a" })   // its subagent finished too
        var done = ThreadSummary(threadId: "thr_a", title: "Render release notes", status: .completed)
        s.applyFinished([done], exhaustive: true)
        #expect(s.sessions["thr_a"]?.statusLine == "Done")
        #expect(s.sessions["thr_a"]?.attention == .done)
        #expect(s.count == 2)
        // Settled in T3 → leaves the huddle.
        done.settled = true
        s.applyFinished([done], exhaustive: true)
        #expect(s.sessions["thr_a"] == nil)
    }

    @Test func finishedRowsAreNeverNewlyAdmitted() {
        var s = HuddleState()
        s.applyFinished([ThreadSummary(threadId: "old", status: .completed)], exhaustive: false)
        #expect(s.count == 0)
    }

    @Test func recentlyFinishedThreadIsAdmittedButOldOnesAreNot() {
        let now = Date()
        func iso(_ ago: TimeInterval) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: now.addingTimeInterval(-ago)) }
        var s = HuddleState()
        s.applyFinished([ThreadSummary(threadId: "fresh", status: .completed, updatedAt: iso(60)),
                         ThreadSummary(threadId: "stale", status: .completed, updatedAt: iso(3 * 3600)),
                         ThreadSummary(threadId: "settled", status: .completed, settled: true, updatedAt: iso(60))], exhaustive: true, now: now)
        #expect(s.sessions.keys.sorted() == ["fresh"])
        #expect(s.sessions["fresh"]?.statusLine == "Done")
    }

    @Test func closedThreadComesBackWhenItIsActiveAgain() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        s.hide("t")
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        #expect(s.count == 0)                               // still running, stays closed
        s.applyActive([]); s.applyFinished([ThreadSummary(threadId: "t", status: .completed)], exhaustive: true)
        #expect(s.count == 0)                               // finished, stays closed
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        #expect(s.count == 1)                               // working again: back
        // A persisted closed id shows again after a restart if the thread is working.
        var fresh = HuddleState(); fresh.hiddenIDs = ["t"]
        fresh.applyActive([ThreadSummary(threadId: "t", status: .running)])
        #expect(fresh.count == 1)
    }

    @Test func newRunBringsBackAClosedThread() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        _ = s.noteRun(threadId: "t", latestRunId: "run_1")
        s.hide("t")
        let changed = s.noteRun(threadId: "t", latestRunId: "run_2")
        #expect(changed)
        #expect(s.count == 1)
    }

    @Test func waitingOnABackgroundTaskCountsAsWorkingEvenThoughT3SaysCompleted() {
        let now = Date()
        var s = HuddleState()
        s.applyFinished([ThreadSummary(threadId: "t", status: .completed, updatedAt: HuddleStateTestClock.iso(now))], exhaustive: true, now: now)
        s.applyRead(ThreadRead(threadId: "t", status: .completed, items: [
            ActivityItem(position: 0, itemId: "a", type: "command_execution", status: "completed", text: "$ sleep 180 && echo done\nCommand running in background"),
            ActivityItem(position: 1, itemId: "b", type: "dynamic_tool", status: "completed",
                         text: "{\n  \"toolName\": \"mcp__t3-code__t3_background_wait\",\n  \"input\": {}\n}"),
            ActivityItem(position: 2, itemId: "c", type: "assistant_message", status: "completed", text: "Waiting on the timer.")]))
        #expect(s.sessions["t"]?.isWorking == true)
        #expect(s.sessions["t"]?.statusLine == "Waiting on a background task")
        #expect(s.sessions["t"]?.attention == Attention.none)
        // The task finishes: T3's notice starts the next run and the wait ends.
        s.applyRead(ThreadRead(threadId: "t", status: .completed, items: [
            ActivityItem(position: 3, itemId: "turn-item:message:message%3Athread%3At%3Aordinal%3A1%3An1", type: "notification",
                         status: "completed", text: "Command \"sleep 180 && echo done\" finished")]))
        #expect(s.sessions["t"]?.isWorking == false)
        #expect(s.sessions["t"]?.statusLine == "Done")
    }

    @Test func aWaitFollowedByMoreShellWorkIsTakenAsDone() {
        // Seen live: the agent waited on a build, the task finished inside the turn (no notification), the agent kept
        // running commands, merged and finished.
        let now = Date()
        var s = HuddleState()
        s.applyFinished([ThreadSummary(threadId: "t", status: .completed, updatedAt: HuddleStateTestClock.iso(now))], exhaustive: true, now: now)
        let iso = { (minutes: Double) in HuddleStateTestClock.iso(now.addingTimeInterval(minutes * 60)) }
        s.applyRead(ThreadRead(threadId: "t", status: .completed, items: [
            ActivityItem(position: 0, itemId: "a", type: "dynamic_tool", status: "completed",
                         text: "{\"toolName\":\"mcp__t3-code__t3_background_wait\",\"input\":{\"taskIds\":[\"b1\"]}}",
                         updatedAt: iso(-30), runId: "r1"),
            ActivityItem(position: 1, itemId: "b", type: "command_execution", status: "completed", text: "$ gh pr merge 7 --merge\n",
                         updatedAt: iso(-20), runId: "r1"),
            ActivityItem(position: 2, itemId: "c", type: "assistant_message", status: "completed", text: "Merged.", updatedAt: iso(-20), runId: "r1")]))
        #expect(s.sessions["t"]?.isWorking == false)
        #expect(s.sessions["t"]?.statusLine == "Done")
    }

    /// Seen live: the agent started two builds in the background, waited on them, peeked at the log 26 s later and ended
    /// its turn. A watched PR's notice then started another run, which ran commands and ended too. T3 kept the thread in
    /// Working all along (the builds were still running); the panel said Done.
    static func waitThenPeekThenAnotherRun(_ now: Date) -> [ActivityItem] {
        let iso = { (seconds: Double) in HuddleStateTestClock.iso(now.addingTimeInterval(seconds)) }
        let wait = "{\n  \"toolName\": \"mcp__t3-code__t3_background_wait\",\n  \"input\": {\n    \"taskIds\": [\n      \"b2\"\n    ]\n  },\n"
            + "  \"output\": {\n    \"content\": \"{\\\"matched\\\":[\\\"b2\\\"],\\\"unmatched\\\":[]}\",\n"
            + "    \"structuredContent\": {\n      \"matched\": [\n        \"b2\"\n      ],\n      \"unmatched\": []\n    }\n  }\n}"
        let stale = wait.replacingOccurrences(of: "b2", with: "b1").replacingOccurrences(of: "\"matched\": [\n        \"b1\"\n      ]", with: "\"matched\": []")
            .replacingOccurrences(of: "\\\"matched\\\":[\\\"b1\\\"],\\\"unmatched\\\":[]", with: "\\\"matched\\\":[],\\\"unmatched\\\":[\\\"b1\\\"]")
        return [
            ActivityItem(position: 0, itemId: "u1", type: "user_message", status: "completed", text: "Time both builds.", updatedAt: iso(-60), runId: "r1"),
            ActivityItem(position: 1, itemId: "c1", type: "command_execution", status: "completed",
                         text: "$ bash run.sh\nCommand running in background with ID: b2.", updatedAt: iso(-15), runId: "r1"),
            ActivityItem(position: 2, itemId: "w0", type: "dynamic_tool", status: "completed", text: stale, updatedAt: iso(-15), runId: "r1"),
            ActivityItem(position: 3, itemId: "w1", type: "dynamic_tool", status: "completed", text: wait, updatedAt: iso(0), runId: "r1"),
            ActivityItem(position: 4, itemId: "c2", type: "command_execution", status: "completed",
                         text: "$ sleep 20; grep -m1 Builder baseline.log", updatedAt: iso(26), runId: "r1"),
            ActivityItem(position: 5, itemId: "m1", type: "assistant_message", status: "completed", text: "Both builds are running.",
                         updatedAt: iso(30), runId: "r1"),
            ActivityItem(position: 6, itemId: "turn-item:message:message%3Apr-watch%3Ap1", type: "notification", status: "completed",
                         text: "#12: checks failed", updatedAt: iso(410), runId: "r2"),
            ActivityItem(position: 7, itemId: "c3", type: "command_execution", status: "completed", text: "$ gh run rerun 99 --failed",
                         updatedAt: iso(430), runId: "r2"),
            ActivityItem(position: 8, itemId: "m2", type: "assistant_message", status: "completed", text: "Re-ran the flaky job.",
                         updatedAt: iso(460), runId: "r2"),
        ]
    }

    @Test func aWaitOutlivesAQuickPeekAPRNoticeAndALaterRun() {
        let now = Date().addingTimeInterval(-600)
        let items = Self.waitThenPeekThenAnotherRun(now)
        // One cold read of the whole thread (what a restart does).
        var cold = HuddleState()
        cold.applyFinished([ThreadSummary(threadId: "t", status: .completed, updatedAt: HuddleStateTestClock.iso(now))], exhaustive: true, now: now)
        cold.applyRead(ThreadRead(threadId: "t", status: .completed, items: items, latestRunId: "r2"))
        #expect(cold.sessions["t"]?.statusLine == "Waiting on a background task")
        // Polling: run r1 read as it ended, then run r2 appears and the panel re-reads from the top.
        var live = HuddleState()
        live.applyFinished([ThreadSummary(threadId: "t", status: .completed, updatedAt: HuddleStateTestClock.iso(now))], exhaustive: true, now: now)
        _ = live.noteRun(threadId: "t", latestRunId: "r1")
        live.applyRead(ThreadRead(threadId: "t", status: .completed, items: Array(items[0...5]), latestRunId: "r1"))
        #expect(live.sessions["t"]?.statusLine == "Waiting on a background task")
        let restarted = live.noteRun(threadId: "t", latestRunId: "r2")
        #expect(restarted)
        live.applyRead(ThreadRead(threadId: "t", status: .completed, items: items, latestRunId: "r2"))
        #expect(live.sessions["t"]?.statusLine == "Waiting on a background task")
        // The builds finish: T3's own notice wakes the agent and ends the wait.
        let done = ActivityItem(position: 9, itemId: "turn-item:message:message%3Athread%3At%3Aordinal%3A1%3An2", type: "notification",
                                status: "completed", text: "Command \"bash run.sh\" finished", runId: "r3")
        for var s in [cold, live] {
            s.applyRead(ThreadRead(threadId: "t", status: .completed, items: [done], latestRunId: "r2"))
            #expect(s.sessions["t"]?.isWorking == false)
        }
    }

    @Test func aWaitThatMatchedNoTaskNeitherStartsNorEndsAWait() {
        let items = Self.waitThenPeekThenAnotherRun(Date())
        let stale = items[2]
        #expect(HuddleState.backgroundWaitMatchedNothing(stale))
        #expect(!HuddleState.backgroundWaitMatchedNothing(items[3]), "\"unmatched\":[] must not read as nothing matched")
        var s = HuddleState()
        s.applyFinished([ThreadSummary(threadId: "t", status: .completed, updatedAt: HuddleStateTestClock.iso(Date()))], exhaustive: true)
        s.applyRead(ThreadRead(threadId: "t", status: .completed, items: [stale]))
        #expect(s.sessions["t"]?.isWorking == false)
        s.applyRead(ThreadRead(threadId: "t", status: .completed, items: [items[3], stale]))
        #expect(s.sessions["t"]?.isWorking == true)
    }

    @Test func onlyT3sCommandNoticeEndsAWait() {
        #expect(HuddleState.isTaskFinishedNotice(ActivityItem(position: 0, itemId: "turn-item:message:message%3Athread%3At%3Aordinal%3A1%3Ax",
                                                              type: "notification", status: "completed", text: "Command \"make\" finished")))
        #expect(HuddleState.isTaskFinishedNotice(ActivityItem(position: 0, itemId: "n", type: "notification", status: "completed",
                                                              text: "Command \"make\" finished")))
        #expect(!HuddleState.isTaskFinishedNotice(ActivityItem(position: 0, itemId: "turn-item:message:message%3Apr-watch%3Ax",
                                                               type: "notification", status: "completed", text: "#8: checks passed")))
    }

    @Test func otherToolCallsAfterTheWaitDoNotEndIt() {
        let now = Date()
        var s = HuddleState()
        s.applyFinished([ThreadSummary(threadId: "t", status: .completed, updatedAt: HuddleStateTestClock.iso(now))], exhaustive: true, now: now)
        s.applyRead(ThreadRead(threadId: "t", status: .completed, items: [
            ActivityItem(position: 0, itemId: "a", type: "dynamic_tool", status: "completed",
                         text: "{\"toolName\":\"mcp__t3-code__t3_background_wait\",\"input\":{\"taskIds\":[\"b1\"]}}",
                         updatedAt: HuddleStateTestClock.iso(now)),
            ActivityItem(position: 1, itemId: "b", type: "dynamic_tool", status: "completed",
                         text: "{\"toolName\":\"mcp__t3-code__link_pull_request\",\"input\":{}}"),
            ActivityItem(position: 2, itemId: "c", type: "assistant_message", status: "completed", text: "Waiting on CI.")]))
        #expect(s.sessions["t"]?.statusLine == "Waiting on a background task")
        // The agent clears it explicitly.
        s.applyRead(ThreadRead(threadId: "t", status: .completed, items: [
            ActivityItem(position: 3, itemId: "d", type: "dynamic_tool", status: "completed",
                         text: "{\"toolName\":\"mcp__t3-code__t3_background_wait\",\"input\":{\"taskIds\":[\"b1\"],\"waiting\":false}}")]))
        #expect(s.sessions["t"]?.isWorking == false)
    }

    @Test func theWaitCapCountsFromTheWaitNotFromASettle() {
        let now = Date()
        var s = HuddleState()
        s.applyFinished([ThreadSummary(threadId: "t", status: .completed, updatedAt: HuddleStateTestClock.iso(now))], exhaustive: true, now: now)
        s.applyRead(ThreadRead(threadId: "t", status: .completed, items: [
            ActivityItem(position: 0, itemId: "a", type: "dynamic_tool", status: "completed",
                         text: "{\"toolName\":\"t3_background_wait\",\"input\":{\"taskIds\":[\"b1\"]}}",
                         updatedAt: HuddleStateTestClock.iso(now.addingTimeInterval(-3 * 3600)))]))
        #expect(s.sessions["t"]?.isWorking == false, "registered 3 hours ago, although the thread was touched just now")
    }

    @Test func aSettledThreadLeavesWhenItsReadSaysSo() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        var read = ThreadRead(threadId: "t", status: .completed)
        read.putAway = true
        s.applyRead(read)
        #expect(s.sessions["t"] == nil)
        // A settled thread that works again is listed as active and comes back.
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        var again = ThreadRead(threadId: "t", status: .running)
        again.putAway = true
        s.applyRead(again)
        #expect(s.sessions["t"] != nil)
    }

    @Test func aToolSearchMentioningBackgroundWaitIsNotAWait() {
        let item = ActivityItem(position: 0, itemId: "a", type: "dynamic_tool", status: "completed",
                                text: "{\"toolName\": \"ToolSearch\", \"input\": {\"query\": \"select:mcp__t3-code__t3_background_wait\"}}")
        #expect(HuddleState.isBackgroundWait(item) == false)
    }

    @Test func staleBackgroundWaitStopsCountingAsWorking() {
        var s = HuddleState()
        let old = HuddleStateTestClock.iso(Date().addingTimeInterval(-3 * 3600))
        s.applyActive([ThreadSummary(threadId: "t", status: .running, updatedAt: old)])
        s.sessions["t"]?.t3Status = .completed; s.sessions["t"]?.backgroundWait = true
        #expect(s.sessions["t"]?.isWorking == false)
    }

    @Test func failedStatusLine() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        s.applyFinished([ThreadSummary(threadId: "t", status: .failed)], exhaustive: true)
        #expect(s.sessions["t"]?.statusLine == "Failed")
        #expect(s.sessions["t"]?.attention == .failed)
    }

    @Test func buddyColorIsStableAndInPalette() {
        #expect(Buddy.index(for: "thr_a") == Buddy.index(for: "thr_a"))
        for id in ["a", "b", "thr_x", "thr_longer_id_123"] { #expect((0..<Buddy.paletteSize).contains(Buddy.index(for: id))) }
    }

    @Test func needsReadOnlyWhenChanged() {
        let sum = ThreadSummary(threadId: "t", status: .running, itemCount: 3, updatedAt: "u1")
        var s = HuddleState(); s.applyActive([sum])
        #expect(!HuddleState.needsRead(previous: s.sessions["t"], summary: sum))
        var changed = sum; changed.itemCount = 4
        #expect(HuddleState.needsRead(previous: s.sessions["t"], summary: changed))
        #expect(HuddleState.needsRead(previous: nil, summary: sum))
    }

    @Test func pollScheduleAndBackoff() {
        #expect(PollSchedule.listInterval(expanded: true, consecutiveFailures: 0) == 2)
        #expect(PollSchedule.listInterval(expanded: false, consecutiveFailures: 0) == 5)
        #expect(PollSchedule.listInterval(expanded: true, consecutiveFailures: 1) >= 5)
        #expect(PollSchedule.listInterval(expanded: true, consecutiveFailures: 3) == 15)
        #expect(PollSchedule.detailInterval == 1)
    }

    @Test func preferencesRoundTripUnderInjectedDirectory() {
        let dir = tempDir()
        let store = PreferencesStore(directory: dir)
        var p = Preferences(); p.hiddenIDs = ["a"]; p.muted = true; p.panelX = 10
        store.save(p)
        #expect(store.load() == p)
        // Only ids and toggles are persisted — never thread content.
        let raw = try? String(contentsOf: dir.appendingPathComponent("preferences.json"), encoding: .utf8)
        #expect(raw?.contains("title") == false)
    }
}

@Suite("Store / reducer — finished threads")
struct FinishedStatusTests {
    @Test func finishedThreadIgnoresAStaleRunningStep() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        s.applyRead(ThreadRead(threadId: "t", status: .running, items: [
            ActivityItem(position: 0, itemId: "a", type: "command_execution", status: "running", text: "$ sleep 9")]))
        #expect(s.sessions["t"]?.statusLine == "sleep 9")
        s.applyActive([]); s.applyFinished([ThreadSummary(threadId: "t", status: .completed)], exhaustive: true)
        #expect(s.sessions["t"]?.statusLine == "Done")
    }
}

@Suite("Question codec shapes")
struct CodecTests {
    @Test func listDecodesLiveAndFallbackShapes() throws {
        #expect(QuestionCodec.requestIds(fromList: try JSON.parse(#"{"requestIds":["a","b"]}"#)) == ["a", "b"])   // live
        #expect(QuestionCodec.requestIds(fromList: try JSON.parse(#"{"requests":[{"requestId":"c"}]}"#)) == ["c"])
        #expect(QuestionCodec.requestIds(fromList: try JSON.parse(#"{"requestIds":[]}"#)).isEmpty)
    }
}

@Suite("Model info, run timing and step details")
struct RunInfoTests {
    @Test func familyFollowsTheModelThenTheProvider() {
        #expect(ModelInfo.family(provider: "claudeAgent", model: "claude-sonnet-5-5") == .claude)
        #expect(ModelInfo.family(provider: "pi", model: "ollama/qwen3.8-pi:latest") == .qwen)      // pi runs any model
        #expect(ModelInfo.family(provider: "codex", model: "gpt-6.1-sol") == .openai)
        #expect(ModelInfo.family(provider: "opencode", model: "z-ai/glm-5") == .glm)
        #expect(ModelInfo.family(provider: "pi", model: "mystery-1") == .pi)
        #expect(ModelInfo.family(provider: "who", model: "mystery-1") == .other)
        #expect(ModelInfo.family(provider: nil, model: nil) == .other)
    }

    @Test func displayNamesAreReadable() {
        #expect(ModelInfo.displayName(model: "claude-sonnet-5-5") == "Claude Sonnet 5.5")
        #expect(ModelInfo.displayName(model: "ollama/qwen3.8-pi:latest") == "Qwen3.8 Pi")
        #expect(ModelInfo.displayName(model: "gpt-6.1-sol") == "GPT 6.1 Sol")
        #expect(ModelInfo.displayName(model: nil) == "Unknown model")
    }

    @Test func hoverMentionsTheExecutedModelOnlyWhenItDiffers() {
        #expect(ModelInfo.hover(provider: "claudeAgent", model: "claude-opus-5-5", executedModel: nil) == "Claude Opus 5.5\nClaude")
        #expect(ModelInfo.hover(provider: "claudeAgent", model: "claude-opus-5-5", executedModel: "claude-opus-5-5") == "Claude Opus 5.5\nClaude")
        #expect(ModelInfo.hover(provider: "claudeAgent", model: "claude-opus-5-5", executedModel: "claude-sonnet-5-5").hasSuffix("Ran on Claude Sonnet 5.5"))
    }

    @Test func runInfoComesFromTheNewestRunAndDrivesTheClock() {
        let j: JSON = ["thread": ["threadId": "t", "status": "running", "model": "claude-sonnet-5-5", "providerInstanceId": "claudeAgent",
                                  "branch": "main", "runCount": 3],
                       "recentRuns": [["ordinal": 2, "runId": "r2", "startedAt": "2026-01-01T00:00:00.000Z", "completedAt": "2026-01-01T00:00:10.000Z"],
                                      ["ordinal": 3, "runId": "r3", "startedAt": "2026-01-01T00:10:00.000Z", "completedAt": .null, "executedModel": .null]]]
        let read = ThreadRead(json: j)
        #expect(read.run?.ordinal == 3 && read.run?.completedAt == nil && read.runCount == 3)
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        s.applyRead(read)
        let start = HuddleState.date("2026-01-01T00:10:00.000Z")
        #expect(s.sessions["t"]?.elapsed(now: start.addingTimeInterval(252)) == 252)           // still counting
        #expect(Session.formatDuration(252) == "4m 12s" && Session.formatDuration(42) == "42s" && Session.formatDuration(3720) == "1h 02m")
        #expect(s.sessions["t"]?.ranOnDifferentModel == false)                                  // unknown executed model is not "different"
    }

    @Test func aFinishedRunStopsTheClockAtItsEnd() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        s.applyRead(ThreadRead(threadId: "t", status: .completed, model: "m", run: RunInfo(ordinal: 1, startedAt: "2026-01-01T00:00:00.000Z",
                                                                                       completedAt: "2026-01-01T00:01:05.000Z", model: "m", executedModel: "other")))
        #expect(s.sessions["t"]?.elapsed(now: Date()) == 65)
        #expect(s.sessions["t"]?.ranOnDifferentModel == true)
    }

    @Test func theApprovalItemGivesTheExactCommandAndIsNotAStep() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .waiting)])
        s.applyRead(ThreadRead(threadId: "t", status: .waiting, pendingRequestCount: 1, items: [
            ActivityItem(position: 0, itemId: "c", type: "command_execution", status: "running", text: "$ echo old"),
            ActivityItem(position: 1, itemId: "a", type: "approval_request", status: "pending", title: "Allow bash?",
                         text: "{\n  \"command\": \"echo \\\"cwd:\\\"; pwd\"\n}")]))
        s.applyPending(threadId: "t", questions: [])
        #expect(s.sessions["t"]?.permission?.summary == "Bash: echo \"cwd:\"; pwd")        // not the unfinished `echo old`
        #expect(s.sessions["t"]?.steps.count == 1)                                          // the approval is a prompt, not a step
    }

    @Test func permissionPromptSplitsToolAndDetail() {
        #expect(PermissionPrompt(summary: "Bash: gh issue edit 142 --add-label needs-info").tool == "Bash")
        #expect(PermissionPrompt(summary: "Bash: gh issue edit 142 --add-label needs-info").detail == "gh issue edit 142 --add-label needs-info")
        #expect(PermissionPrompt(summary: "Bash: a: b").detail == "a: b")                        // only the first separator splits
        #expect(PermissionPrompt(summary: "{\"x\": 1}").tool == nil)                              // raw JSON has no tool name
        #expect(PermissionPrompt(summary: "{\"x\": 1}").detail == "{\"x\": 1}")
        #expect(PermissionPrompt(summary: nil).detail == nil)
    }

    @Test func aWorkingSubagentKeepsACompletedParentWorking() {
        let now = Date()
        var s = HuddleState()
        s.applyFinished([ThreadSummary(threadId: "p", status: .completed, updatedAt: HuddleStateTestClock.iso(now))], exhaustive: true, now: now)
        #expect(s.sessions["p"]?.isWorking == false && s.sessions["p"]?.statusLine == "Done")
        s.applyActive([ThreadSummary(threadId: "child", status: .running, parentThreadId: "p")])
        #expect(s.sessions["p"]?.isWorking == true)
        #expect(s.sessions["p"]?.statusLine == "Waiting on a subagent")
        #expect(s.sessions["p"]?.attention == Attention.none)
        #expect(s.sessions["child"] == nil)                                                    // the child itself is still not a row
        s.applyActive([ThreadSummary(threadId: "c1", status: .running, parentThreadId: "p"),
                       ThreadSummary(threadId: "c2", status: .waiting, parentThreadId: "p")])
        #expect(s.sessions["p"]?.statusLine == "Waiting on 2 subagents")
        s.applyActive([])                                                                      // children finished
        #expect(s.sessions["p"]?.isWorking == false && s.sessions["p"]?.statusLine == "Done")
    }

    @Test func stepsKeepADetailAndErrorsFail() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .running)])
        s.applyRead(ThreadRead(threadId: "t", status: .running, items: [
            ActivityItem(position: 0, itemId: "a", type: "dynamic_tool", status: "completed", title: "Read /x/y/SPEC.md", text: "{\n \"path\": \"/x/y/SPEC.md\"\n}"),
            ActivityItem(position: 1, itemId: "b", type: "error", status: "completed", text: "Request timed out."),
            ActivityItem(position: 2, itemId: "c", type: "command_execution", status: "completed", text: "$ ls\nfile")]))
        let steps = s.sessions["t"]!.steps
        #expect(steps[0].detail?.contains("SPEC.md") == true)
        #expect(steps[1].state == .failed && steps[1].label == "Request timed out.")
        #expect(steps[2].detail == nil)                                                         // commands use output, not detail
    }
}

@Suite("Display text: what the user reads is what is there")
struct DisplayTextTests {
    @Test func hiddenAndDirectionCharactersBecomeVisibleEscapes() {
        #expect(DisplayText.clean("rm \u{202E}fdp.txt") == "rm ⟦U+202E⟧fdp.txt")
        #expect(DisplayText.clean("a\u{200B}b") == "a⟦U+200B⟧b")
        #expect(DisplayText.clean("esc\u{1B}[31m") == "esc⟦U+001B⟧[31m")
        #expect(DisplayText.clean("plain text · ünïcode ✓") == "plain text · ünïcode ✓")      // normal text is untouched
        #expect(DisplayText.clean("a\nb") == "a⟦U+000A⟧b")                                    // single-line fields show a newline as an escape
        #expect(DisplayText.clean("a\nb", allowNewlines: true) == "a\nb")
        #expect(DisplayText.clean("a\tb", allowNewlines: true) == "a\tb")
    }

    @Test func aCommandThatCouldBeClippedMustBeExpandedFirst() {
        #expect(!DisplayText.commandNeedsExpansion("pwd"))
        #expect(!DisplayText.commandNeedsExpansion(String(repeating: "a", count: 80)))
        #expect(DisplayText.commandNeedsExpansion(String(repeating: "a", count: 81)))
        #expect(DisplayText.commandNeedsExpansion("echo one\necho two\nrm -rf ~/Documents"))       // consequential line below the fold
        #expect(DisplayText.commandNeedsExpansion("ls \u{202E}gpj.txt"))                          // hidden characters
        #expect(!DisplayText.commandNeedsExpansion("echo one\necho two"))
    }

    @Test func titlesStepLabelsAndMachineNamesAreCleanedOnTheWayIn() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", title: "Deploy \u{202E}live", status: .running)])
        #expect(s.sessions["t"]?.title == "Deploy ⟦U+202E⟧live")
        s.applyRead(ThreadRead(threadId: "t", status: .running, items: [
            ActivityItem(position: 0, itemId: "a", type: "dynamic_tool", status: "completed", title: "Read \u{200F}x")]))
        #expect(s.sessions["t"]?.steps.first?.label == "Read ⟦U+200F⟧x")
    }
}

@Suite("Display text: invisible characters that change what is approved")
struct InvisibleTextTests {
    @Test func fillersTagsVariationSelectorsAndSoftHyphensAreShown() {
        for u in [0x00AD, 0x3164, 0xFFA0, 0x115F, 0x2800, 0xE0041, 0xFE0F, 0xE0100, 0x034F, 0x2060] {
            let s = "rm ./build" + String(Unicode.Scalar(UInt32(u))!)
            #expect(DisplayText.clean(s) != s, "U+\(String(u, radix: 16)) must be visible")
            #expect(DisplayText.commandNeedsExpansion(s), "U+\(String(u, radix: 16)) must force expansion")
        }
    }
    @Test func stackedCombiningMarksAreEscapedAndCountedAsLength() {
        let smear = "a" + String(repeating: "\u{0301}", count: 50)
        #expect(DisplayText.clean(smear).contains("⟦U+0301⟧"))
        let manyMarks = String(repeating: "a\u{0301}\u{0302}\u{0303}\u{0304}", count: 30)              // 30 characters, 150 scalars
        #expect(DisplayText.commandNeedsExpansion(manyMarks))
        #expect(DisplayText.clean("e\u{0301}") == "e\u{0301}")                                         // one accent is normal text
    }
}

@Suite("Approval text the user can trust")
struct ApprovalTextTests {
    func item(_ text: String, title: String? = "Allow bash?", status: String = "waiting") -> ActivityItem {
        ActivityItem(position: 1, itemId: "turn-item:runtime-request:rq", type: "approval_request", status: status, title: title, text: text)
    }
    @Test func repeatedJsonKeysAreNeverApprovable() {
        #expect(HuddleState.isApprovable(item("{\"command\":\"ls\"}")))
        #expect(!HuddleState.isApprovable(item("{\"command\":\"ls\",\"command\":\"rm -rf ~\"}")))
        #expect(!HuddleState.isApprovable(item("{\"command\":\"ls\", \"command\" : \"x\"}")))
        #expect(JSONDuplicateKeys.hasDuplicate("{\"a\":{\"b\":1,\"b\":2}}"))                          // nested
        #expect(!JSONDuplicateKeys.hasDuplicate("{\"a\":{\"b\":1},\"c\":{\"b\":2}}"))                // same key in different objects is fine
        #expect(JSONDuplicateKeys.hasDuplicate("{\"a\":1,\"\\u0061\":2}"))                           // escaped spelling of the same key
        #expect(JSONDuplicateKeys.hasDuplicate("not json"))
    }
    @Test func extraFieldsAreOnlyHarmlessForBash() {
        #expect(HuddleState.isApprovable(item("{\"command\":\"ls\",\"description\":\"list\",\"timeout\":5}")))
        #expect(!HuddleState.isApprovable(item("{\"url\":\"https://x.example\",\"description\":\"sends the whole repo\"}", title: "Allow fetch?")))
        #expect(!HuddleState.isApprovable(item("{\"path\":\"a.txt\",\"timeout\":5}", title: "Allow write?")))
    }
    @Test func theToolBadgeComesFromTheTitleNotFromTheText() {
        let raw = HuddleState.approvalSummary(item("Read: nothing to see here", title: "Allow bash?"))
        #expect(raw == "Bash: Read: nothing to see here")                                              // our prefix first
        #expect(PermissionPrompt(summary: raw).tool == "Bash")
        #expect(HuddleState.approvalSummary(item("{\"command\":\"ls\"}", title: nil)) == "Tool: ls")   // no title, no invented tool
        #expect(HuddleState.toolName(fromTitle: "Allow \u{202E}bash?") == "⟦U+202E⟧bash" || HuddleState.toolName(fromTitle: "Allow \u{202E}bash?") == nil)
    }
    @Test func twoMachinesReportingTheSameThreadIdDoNotMerge() {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", title: "On the Mac mini", status: .running, environmentId: "env_a")])
        s.applyActive([ThreadSummary(threadId: "t", title: "On the MacBook", status: .running, environmentId: "env_b"),
                       ThreadSummary(threadId: "t", title: "On the Mac mini", status: .running, environmentId: "env_a")])
        #expect(s.sessions["t"]?.environmentId == "env_a" && s.sessions["t"]?.title == "On the Mac mini")   // the first machine keeps it
        #expect(s.collidingThreadIds == ["t"])
    }
}

@Suite("Approval gate")
struct ApprovalGateTests {
    @Test func allowNeedsTheWholeCommandASettledRequestAndNoReadOnlyOrDecisionInFlight() {
        func allow(_ ro: Bool = false, _ sending: Bool = false, _ full: Bool = true, _ armed: Bool = true) -> Bool {
            ApprovalGate.allowEnabled(readOnly: ro, sending: sending, commandVisibleInFull: full, armed: armed)
        }
        #expect(allow())
        #expect(!allow(true)); #expect(!allow(false, true)); #expect(!allow(false, false, false)); #expect(!allow(false, false, true, false))
    }
    @Test func denyIsAlwaysAvailableOnceSettledExceptInReadOnlyOrWhileSending() {
        #expect(ApprovalGate.denyEnabled(readOnly: false, sending: false, armed: true))
        #expect(!ApprovalGate.denyEnabled(readOnly: true, sending: false, armed: true))
        #expect(!ApprovalGate.denyEnabled(readOnly: false, sending: true, armed: true))
        #expect(!ApprovalGate.denyEnabled(readOnly: false, sending: false, armed: false))
        #expect(ApprovalGate.armDelay >= 0.5)
    }
}

@Suite("Credential lifecycle, logging and persisted data")
struct CredentialLifecycleTests {
    /// A store whose delete fails and keeps the value, like a Keychain that refuses.
    final class StubbornStore: TokenStore, @unchecked Sendable {
        private let lock = NSLock(); private var token: String?
        init(_ t: String) { token = t }
        func load() -> String? { lock.lock(); defer { lock.unlock() }; return token }
        func save(_ t: String) throws { lock.lock(); token = t; lock.unlock() }
        @discardableResult func delete() -> Bool { false }
    }

    @MainActor @Test func aCredentialThatCannotBeDeletedKeepsTheFeatureVisiblyOn() {
        let store = StubbornStore("tok-1234")
        let m = HuddleModel(config: HuddleConfig(source: .fixed(URL(string: "http://127.0.0.1:1/mcp")!), tokenStore: MemoryTokenStore(), approvalStore: store))
        #expect(m.inlineApprovals)                         // a saved credential switches it on at start
        #expect(m.disableInlineApprovals() == false)       // the delete failed and is reported
        #expect(m.inlineApprovals)                         // so the app does not claim it is off while the credential survives
        #expect(store.load() == "tok-1234")
    }

    @MainActor @Test func aSuccessfulDeleteTurnsItOff() {
        let m = HuddleModel(config: HuddleConfig(source: .fixed(URL(string: "http://127.0.0.1:1/mcp")!), tokenStore: MemoryTokenStore(), approvalStore: MemoryTokenStore(token: "tok-1234")))
        #expect(m.disableInlineApprovals() && !m.inlineApprovals)
    }

    @Test func theScrubberKeepsABoundedDeduplicatedSetAndCanForget() {
        var lines: [String] = []; let lock = NSLock()
        let log = HuddleLog(sink: { lock.lock(); lines.append($0); lock.unlock() })
        for i in 0..<100 { log.register(secret: "secret-\(i)-xxxx") }
        log.register(secret: "secret-99-xxxx")
        log.log("secret-0-xxxx secret-99-xxxx")
        #expect(lines.last?.contains("secret-99-xxxx") == false)      // recent secrets are still scrubbed
        #expect(lines.last?.contains("secret-0-xxxx") == true)        // the oldest were dropped: the registry is bounded
        log.forget(secret: "secret-99-xxxx")
        log.log("secret-99-xxxx")
        #expect(lines.last == "secret-99-xxxx")                       // a forgotten secret is no longer held
    }

    @Test func logLinesCarryOnlyTheErrorCategoryNotServerText() {
        let e = HuddleError.toolFailed("rm -rf ~ was the command the agent ran")
        #expect(e.category == "toolFailed")
        #expect(!e.category.contains("rm -rf"))
        #expect(HuddleError.approval("x\u{202E}y").description == "x⟦U+202E⟧y")                 // shown text has hidden characters made visible
        #expect(HuddleError.toolFailed(String(repeating: "a", count: 1000)).description.count == 300)
    }

    @Test func preferencesNeverHoldThreadContentOrAddresses() throws {
        let dir = tempDir()
        let store = PreferencesStore(directory: dir)
        var p = Preferences(); p.hiddenIDs = ["thread-1"]; p.muted = true; p.panelMaxHeight = 640; p.oauthClientId = "client-1"; p.oauthPort = 1234
        store.save(p)
        let data = try Data(contentsOf: dir.appendingPathComponent("preferences.json"))
        let keys = Set((try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys)
        let allowed: Set<String> = ["hiddenIDs", "panelX", "panelY", "panelMaxHeight", "collapsed", "muted", "readOnly", "closeSettles", "oauthClientId", "oauthPort"]
        #expect(keys.isSubset(of: allowed), "unexpected keys: \(keys.subtracting(allowed))")
    }
}


@Suite("Decision target stays the clicked one")
struct RequestUnchangedTests {
    func session(env: String, request: String) -> Session? {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: .waiting, environmentId: env)])
        s.applyRead(ThreadRead(threadId: "t", status: .waiting, pendingRequestCount: 1, items: [
            ActivityItem(position: 0, itemId: "turn-item:runtime-request:\(request)", type: "approval_request", status: "waiting",
                         title: "Allow bash?", text: "{\"command\":\"pwd\"}")]))
        s.applyPending(threadId: "t", questions: [])
        return s.sessions["t"]
    }
    @Test func aSwappedMachineOrRequestOrRowBlocksTheDecision() {
        let clicked = session(env: "env_a", request: "rq1")
        #expect(clicked?.permission?.requestId == "rq1")
        #expect(ApprovalGate.requestUnchanged(clickedEnvironmentId: "env_a", requestId: "rq1", current: clicked))
        #expect(!ApprovalGate.requestUnchanged(clickedEnvironmentId: "env_a", requestId: "rq1", current: session(env: "env_b", request: "rq1")))   // another machine
        #expect(!ApprovalGate.requestUnchanged(clickedEnvironmentId: "env_a", requestId: "rq1", current: session(env: "env_a", request: "rq2")))   // another request
        #expect(!ApprovalGate.requestUnchanged(clickedEnvironmentId: "env_a", requestId: "rq1", current: nil))                                      // row gone
    }
}

@Suite("Hostile JSON")
struct HostileJSONTests {
    @Test func absurdNestingIsRefusedNotACrash() {
        for depth in [600, 10_000, 200_000] {
            let deep = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
            #expect((try? JSON.parse(Data(deep.utf8))) == nil || depth <= 600, "depth \(depth)")      // either refused, or small enough to parse
        }
        let deepObjects = String(repeating: "{\"a\":", count: 50_000) + "1" + String(repeating: "}", count: 50_000)
        _ = try? JSON.parse(Data(deepObjects.utf8))                                                   // reaching this line means no stack overflow
        #expect(JSONDuplicateKeys.hasDuplicate(deepObjects))                                           // the duplicate scanner refuses it too (depth limit), no recursion blow-up
    }
    @Test func hugeNumbersAndOddStringsDoNotTrap() {
        for text in ["{\"n\":1e999999}", "{\"n\":-1e999999}", "{\"n\":123456789012345678901234567890}", "{\"s\":\"\\ud800\"}", "{\"k\":\"\u{0}\"}"] {
            let j = try? JSON.parse(Data(text.utf8))
            _ = j?["n"].int; _ = j?["n"].string                                                         // reading them must not trap
        }
    }
}

@Suite("Tool calls and secret requests read as what they are")
struct ToolAndSecretTests {
    func read(_ items: [ActivityItem], status: T3Status = .waiting, pending: Int = 0) -> HuddleState {
        var s = HuddleState()
        s.applyActive([ThreadSummary(threadId: "t", status: status)])
        s.applyRead(ThreadRead(threadId: "t", status: status, pendingRequestCount: pending, items: items))
        s.applyPending(threadId: "t", questions: [])
        return s
    }
    let toolCall = ActivityItem(position: 0, itemId: "call", type: "dynamic_tool", status: "completed", title: nil,
                                text: "{\n  \"toolName\": \"mcp__t3-code__request_secret\",\n  \"input\": {\n    \"label\": \"Staging deploy token\"\n  }\n}")

    @Test func aTitlelessToolCallIsNamedNotShownAsABrace() {
        let s = read([toolCall], status: .running)
        #expect(s.sessions["t"]?.steps.first?.label == "request_secret: Staging deploy token")      // never "{"
        #expect(HuddleState.toolLabel(fromJSON: "{\"toolName\":\"Read\",\"input\":{\"file_path\":\"/a/b/SPEC.md\"}}") == "Read: SPEC.md")
        #expect(HuddleState.toolLabel(fromJSON: "{\"toolName\":\"advisor\",\"input\":{}}") == "advisor")
        #expect(HuddleState.toolLabel(fromJSON: "not json") == nil)
        #expect(HuddleState.toolLabel(fromJSON: "{\"toolName\":\"mcp__a__b__c\",\"input\":{\"command\":\"ls\\nsecond line\"}}") == "c: ls")
    }
    @Test func checkpointsAreBookkeepingNotSteps() {
        let cp = ActivityItem(position: 1, itemId: "cp", type: "checkpoint", status: "completed", text: "[\n  {\"path\": \"a\"}\n]")
        #expect(read([toolCall, cp], status: .running).sessions["t"]?.steps.count == 1)
    }
    @Test func fileChangesAreEditsNamedByFile() {
        let fc = ActivityItem(position: 0, itemId: "fc", type: "file_change", status: "completed", text: "/Users/x/proj/docs/SPEC.md\n--- a\n+++ b")
        let step = read([fc], status: .running).sessions["t"]?.steps.first
        #expect(step?.kind == .edit && step?.label == "Edit SPEC.md")
    }
    @Test func aPendingSecretRequestIsShownAsAskingForASecretNotAsAPermission() {
        let req = ActivityItem(position: 1, itemId: "req", type: "secret_request", status: "pending", title: "Staging deploy token",
                               text: "Waiting for the user: Staging deploy token")
        let s = read([toolCall, req], status: .waiting, pending: 1)                     // waiting with a pending request and no listed question
        let session = s.sessions["t"]
        #expect(session?.secretPrompt?.label == "Staging deploy token")
        #expect(session?.statusLine == "asks for a secret")
        #expect(session?.attention == .needsSecret && session?.needsAttention == true)
        #expect(session?.permission == nil)                                              // not mistaken for a tool approval
    }
    @Test func aFinishedOrCancelledSecretRequestClearsThePrompt() {
        var s = read([ActivityItem(position: 1, itemId: "req", type: "secret_request", status: "pending", title: "Token", text: "")], status: .waiting, pending: 1)
        #expect(s.sessions["t"]?.secretPrompt != nil)
        for done in ["completed", "cancelled", "expired", "timed_out"] {
            s.applyRead(ThreadRead(threadId: "t", status: .running, items: [ActivityItem(position: 1, itemId: "req", type: "secret_request", status: done, title: "Token", text: "")]))
            #expect(s.sessions["t"]?.secretPrompt == nil, "\(done)")
            s.applyRead(ThreadRead(threadId: "t", status: .waiting, items: [ActivityItem(position: 1, itemId: "req", type: "secret_request", status: "pending", title: "Token", text: "")]))
        }
        _ = s.noteRun(threadId: "t", latestRunId: "run_1"); _ = s.noteRun(threadId: "t", latestRunId: "run_2")        // a new run: nothing is still pending
        #expect(s.sessions["t"]?.secretPrompt == nil)
    }
    @Test func theSecretLabelIsCleanedAndCapped() {
        let req = ActivityItem(position: 1, itemId: "req", type: "secret_request", status: "pending", title: "Token\u{202E}x" + String(repeating: "y", count: 400), text: "")
        let label = read([req], status: .waiting, pending: 1).sessions["t"]?.secretPrompt?.label ?? ""
        #expect(label.contains("⟦U+202E⟧") && label.count <= 130)
    }
}
