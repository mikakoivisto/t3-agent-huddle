import Foundation

// MARK: - View-state types (SPEC §8)

public enum Attention: Equatable, Sendable { case none, needsPermission, asksQuestion, needsSecret, failed, done }

public enum StepKind: Equatable, Sendable { case terminal, tool, edit, message }
public enum StepState: Equatable, Sendable { case done, running, pending, failed }

public struct Step: Equatable, Sendable, Identifiable {
    public var id: String          // itemId
    public var position: Int
    public var kind: StepKind
    public var label: String
    public var state: StepState
    public var output: String?     // command_execution only, in memory only
    public var command: String?    // command_execution only: the `$ ` line
    public var outputIsFull = false // true once the detail view fetched the real tail (not the 400-char head)
    public var detail: String?     // other steps: the start of the item's text (tool input, file path, message), in memory only
}

public struct PermissionPrompt: Equatable, Sendable {
    /// e.g. `Bash: gh issue edit 142 --add-label needs-info`. Source is an inference (SPEC Q2).
    public var summary: String?

    /// `Bash: pwd` → tool "Bash", detail "pwd". A summary without a short leading tool name has no tool.
    public var tool: String? {
        guard let s = summary, let r = s.range(of: ": ") else { return nil }
        let head = String(s[..<r.lowerBound])
        return head.count <= 24 && !head.contains(where: { " {}\"\n".contains($0) }) ? head : nil
    }
    public var detail: String? {
        guard let s = summary else { return nil }
        guard tool != nil, let r = s.range(of: ": ") else { return s }
        return String(s[r.upperBound...])
    }
    /// Set only for a `waiting`, untruncated `approval_request` item with T3's own id form: the one case inline Allow / Deny may act on.
    public var requestId: String? = nil
}

public struct SecretPrompt: Equatable, Sendable {
    /// What the agent says it needs (T3's own item title), cleaned for display.
    public var label: String
}

public struct TerminalPane: Equatable, Sendable {
    public var command: String
    public var tail: [String]
    public var running: Bool
}

public struct Session: Equatable, Sendable, Identifiable {
    public var id: String { threadId }
    public var threadId: String
    public var projectId: String
    public var title: String
    public var link: String?
    public var t3Status: T3Status
    public var updatedAt: String
    public var itemCount: Int
    public var pendingRequestCount: Int = 0
    public var activeRunId: String?
    public var lastPosition: Int = -1
    public var steps: [Step] = []
    public var question: Question?
    public var permission: PermissionPrompt?
    public var buddy: Int
    public var environmentId: String?
    public var latestRunId: String?
    /// The agent ended its turn but is waiting on a background task (`t3_background_wait`). T3 reports such a thread as
    /// `completed` with no active run, so this is inferred from the run's items.
    public var backgroundWait = false
    /// When the newest wait was registered: the 2-hour cap counts from it, not from `updatedAt` (settling bumps that).
    public var backgroundWaitAt: String?
    /// The run the newest wait was registered in: only work in that same run can end it (see `applyRead`).
    public var backgroundWaitRun: String?
    /// T3's own count of background tasks the agent waits on (0.1.11+, `nil` before). When present it decides the wait and
    /// the stream heuristic above is not used. T3 then reports such a thread as `waiting`, which is not an approval.
    public var awaitedBackgroundTasks: Int?
    /// Subagent (delegated task) threads of this thread that are still working. T3 reports the parent as `completed`
    /// while it waits for them, like it does for a background task.
    public var activeChildren = 0
    /// The newest `approval_request` item's text, e.g. `Bash: pwd`. Preferred over inferring the command from steps.
    public var approvalText: String?
    /// The agent asked the user for a secret (T3's `request_secret`) and no answer has come yet. Only T3 can take the value:
    /// Agent Huddle shows that it is waiting and jumps there, and never asks for or holds a secret.
    public var secretPrompt: SecretPrompt?
    /// The request id of that same item, only while it is `waiting` and its text is complete (inline approvals, opt-in).
    public var approvalRequestId: String?
    public var providerInstanceId: String?
    public var model: String?
    public var branch: String?
    public var runCount: Int?
    public var runStartedAt: String?
    public var runCompletedAt: String?
    public var executedModel: String?

    public var modelFamily: ModelFamily { ModelInfo.family(provider: providerInstanceId, model: model) }
    public var modelHover: String { ModelInfo.hover(provider: providerInstanceId, model: model, executedModel: executedModel) }
    /// Shown in the detail view only when the run executed on a different model than the thread's.
    public var ranOnDifferentModel: Bool { executedModel != nil && executedModel != model }

    /// Latest run's length: still counting while the thread works, fixed once it ended.
    public func elapsed(now: Date = Date()) -> TimeInterval? {
        guard let s = runStartedAt else { return nil }
        let start = HuddleState.date(s)
        guard start != .distantPast else { return nil }
        let end = isWorking ? now : (runCompletedAt.map(HuddleState.date) ?? now)
        return max(0, end.timeIntervalSince(start))
    }
    public static func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 { return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m" }
        if s >= 60 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s)s"
    }

    /// Working now: T3 says active, or the agent is waiting on a background task it started (capped, so a task that was
    /// killed without a notification does not show as working forever).
    public var isWorking: Bool { t3Status.isActive || activeChildren > 0 || waitsOnBackgroundTask }

    /// T3's `pendingBackgroundTasks` when it sends it, else the heuristic from the run's items (capped).
    public var waitsOnBackgroundTask: Bool {
        if let n = awaitedBackgroundTasks { return n > 0 }
        return backgroundWait && Date().timeIntervalSince(HuddleState.date(backgroundWaitAt ?? updatedAt)) < HuddleState.backgroundWaitCap
    }

    /// `waiting` only because of an awaited background task: T3 says so, and there is no sign of an approval
    /// (no `approval_request` item, no pending request in the count). Only T3's field can say this, never the heuristic.
    public var waitingOnlyOnBackgroundTask: Bool {
        (awaitedBackgroundTasks ?? 0) > 0 && approvalText == nil && pendingRequestCount == 0
    }

    public var attention: Attention {
        if permission != nil { return .needsPermission }
        if question != nil { return .asksQuestion }
        if secretPrompt != nil { return .needsSecret }
        if t3Status == .failed { return .failed }
        if t3Status.isFinished && !isWorking { return .done }
        return .none
    }
    public var needsAttention: Bool { attention == .needsPermission || attention == .asksQuestion || attention == .needsSecret }

    /// SPEC §8: first match wins.
    public var statusLine: String {
        if permission != nil { return "needs permission" }
        if let q = question { return q.parts.count > 1 ? "asks \(q.parts.count) questions" : "asks a question" }
        if secretPrompt != nil { return "asks for a secret" }
        if t3Status.isActive, let running = steps.last(where: { $0.state == .running }) { return running.label }   // a finished thread never shows a stale step
        if !t3Status.isActive && activeChildren > 0 { return activeChildren == 1 ? "Waiting on a subagent" : "Waiting on \(activeChildren) subagents" }
        if waitsOnBackgroundTask && (!t3Status.isActive || t3Status == .waiting) { return "Waiting on a background task" }
        return t3Status.words
    }
    public var doneStepCount: Int { steps.filter { $0.state == .done }.count }
    public var progressText: String { "\(doneStepCount) step\(doneStepCount == 1 ? "" : "s")" }

    public var terminal: TerminalPane? {
        guard let step = steps.last(where: { $0.kind == .terminal }) else { return nil }
        let lines = (step.output ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var trimmed = lines
        while trimmed.last == "" { trimmed.removeLast() }
        return TerminalPane(command: step.command ?? step.label, tail: Array(trimmed.suffix(20)), running: step.state == .running)
    }
}

public enum ConnectionState: Equatable, Sendable {
    case connecting, connected, notRunning, unauthorized, unsupported(String), error(String)
    public var isConnected: Bool { self == .connected }
    public var headline: String? {
        switch self {
        case .connecting: return "Connecting…"
        case .connected: return nil
        case .notRunning: return "T3 Code not running"
        case .unauthorized: return "Connect to T3 Code"
        case .unsupported(let m): return "Unsupported T3 Code version: \(m)"
        case .error(let m): return m
        }
    }
}

public enum Buddy {
    /// blue, pink, orange, purple, then more (SPEC §8). Stable FNV-1a — never `hashValue` (randomised per launch).
    public static let paletteSize = 6
    public static func index(for threadId: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in threadId.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int(h % UInt64(paletteSize))
    }
}

// MARK: - Reducer

/// Pure state: fetched JSON in, view state out. No I/O, so it is testable without a server (SPEC §6.4).
public struct HuddleState: Equatable, Sendable {
    public var sessions: [String: Session] = [:]
    public var hiddenIDs: Set<String> = []
    /// Thread ids two different machines both reported. The first machine seen keeps the row; the other is ignored.
    public var collidingThreadIds: Set<String> = []
    /// A finished, unsettled thread is admitted to the huddle when it finished this recently.
    public static let recentlyFinishedWindow: TimeInterval = 30 * 60
    /// A background wait older than this is treated as stale.
    public static let backgroundWaitCap: TimeInterval = 2 * 60 * 60
    public var connection: ConnectionState = .connecting
    public init() {}

    // MARK: Derived

    public var visible: [Session] {
        sessions.values
            .filter { !hiddenIDs.contains($0.threadId) }
            .sorted { a, b in
                if a.needsAttention != b.needsAttention { return a.needsAttention }
                let da = Self.date(a.updatedAt), db = Self.date(b.updatedAt)
                if da != db { return da > db }
                return a.threadId < b.threadId
            }
    }
    public var count: Int { visible.count }

    public struct EnvGroup: Equatable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var sessions: [Session]
    }

    /// Visible sessions grouped by environment: this machine first, then the other linked ones; empty groups dropped.
    public func groups(environments: [HuddleEnvironment]) -> [EnvGroup] {
        let local = environments.first(where: \.isLocal)
        var order: [HuddleEnvironment] = environments.sorted { ($0.isLocal ? 0 : 1, $0.label) < ($1.isLocal ? 0 : 1, $1.label) }
        let vis = visible
        for s in vis { if let e = s.environmentId, !order.contains(where: { $0.id == e }) { order.append(HuddleEnvironment(id: e, label: e, isLocal: false)) } }
        return order.compactMap { env in
            let rows = vis.filter { ($0.environmentId ?? local?.id) == env.id }
            return rows.isEmpty ? nil : EnvGroup(id: env.id, label: env.label, sessions: rows)
        }
    }
    public var attentionCount: Int { visible.filter(\.needsAttention).count }

    // MARK: Events

    /// Result of `t3_thread_list` with the active statuses. A row with a parent is a subagent: dropped (§5.3).
    public mutating func applyActive(_ threads: [ThreadSummary]) {
        let rows = Array(threads.filter { $0.parentThreadId == nil && $0.status.isActive && !$0.settled }.prefix(300))   // a hostile server cannot grow the list without limit
        let ids = Set(rows.map(\.threadId))
        var children: [String: Int] = [:]   // subagents are never rows, but a working one keeps its parent "working"
        for t in threads where t.status.isActive && !t.settled { if let p = t.parentThreadId { children[p, default: 0] += 1 } }
        for id in sessions.keys { sessions[id]?.activeChildren = children[id] ?? 0 }
        for t in rows { upsert(t) }
        // A known session that left the active set and was not reported finished is resolved by applyFinished.
        for (id, s) in sessions where s.t3Status.isActive && !ids.contains(id) {
            sessions[id]?.t3Status = .unknown
        }
    }

    /// Result of the finished-status refresh. Known sessions are refreshed; unsettled threads that finished within
    /// `recentlyFinishedWindow` are admitted too, so a thread that completed between two polls still shows.
    /// `exhaustive` = the page was not full, so absence means settled/archived/etc.
    public mutating func applyFinished(_ threads: [ThreadSummary], exhaustive: Bool, now: Date = Date()) {
        let byId = Dictionary(threads.map { ($0.threadId, $0) }, uniquingKeysWith: { $1 })
        for (id, s) in sessions {
            if let t = byId[id], t.parentThreadId == nil {
                if t.settled || t.snoozed { sessions[id] = nil } else { upsert(t) }
            } else if exhaustive && !s.t3Status.isActive {
                sessions[id] = nil
            }
        }
        for t in threads where sessions[t.threadId] == nil && t.parentThreadId == nil && !t.settled && !t.snoozed
            && now.timeIntervalSince(Self.date(t.updatedAt)) < Self.recentlyFinishedWindow {
            upsert(t)
        }
    }

    /// A row kept from an earlier app session (spec 02), read back by id. Never a subagent, a settled or snoozed thread.
    public mutating func restore(_ t: ThreadSummary) {
        guard sessions[t.threadId] == nil, t.parentThreadId == nil, !t.settled, !t.snoozed, t.status != .idle else { return }
        upsert(t)
    }

    /// Membership: seen active this app session. (see applyFinished)
    private mutating func upsert(_ t: ThreadSummary) {
        // Thread ids are only unique per machine. A second machine reporting an id that is already shown for another machine
        // must not overwrite that row, inherit its steps, hidden state or pending request, or be approved as that thread.
        if let existing = sessions[t.threadId], let a = existing.environmentId, let b = t.environmentId, a != b {
            collidingThreadIds.insert(t.threadId)
            return
        }
        // A closed thread comes back when it starts working again (also after a restart: closed IDs are persisted).
        if t.status.isActive && !(sessions[t.threadId]?.t3Status.isActive ?? false) { hiddenIDs.remove(t.threadId) }
        var s = sessions[t.threadId] ?? Session(
            threadId: t.threadId, projectId: t.projectId, title: DisplayText.clean(t.title), link: t.link,
            t3Status: t.status, updatedAt: t.updatedAt, itemCount: t.itemCount,
            buddy: Buddy.index(for: t.threadId), environmentId: t.environmentId)
        s.environmentId = t.environmentId ?? s.environmentId
        s.providerInstanceId = t.providerInstanceId ?? s.providerInstanceId; s.model = t.model ?? s.model; s.branch = t.branch ?? s.branch
        s.projectId = t.projectId; s.title = DisplayText.clean(t.title); s.link = t.link
        s.t3Status = t.status; s.updatedAt = t.updatedAt; s.itemCount = t.itemCount
        s.awaitedBackgroundTasks = t.awaitedBackgroundTasks ?? s.awaitedBackgroundTasks
        if t.status.isActive == false && s.permission != nil && t.status != .waiting { s.permission = nil }
        if s.waitingOnlyOnBackgroundTask { s.permission = nil }
        sessions[t.threadId] = s
    }

    /// Does this session need a fresh `t3_thread_read`? (status / updatedAt / itemCount changed — §7.3)
    public static func needsRead(previous: Session?, summary: ThreadSummary) -> Bool {
        guard let p = previous else { return true }
        return p.t3Status != summary.status || p.updatedAt != summary.updatedAt || p.itemCount != summary.itemCount
    }

    /// Returns true when the run changed: steps are dropped and the caller must re-read from the top.
    public mutating func noteRun(threadId: String, latestRunId: String?) -> Bool {
        guard var s = sessions[threadId], let run = latestRunId else { return false }
        defer { sessions[threadId] = s }
        guard let known = s.latestRunId else { s.latestRunId = run; return false }
        if known == run { return false }
        // The re-read starts from the thread's first item (T3 positions are thread-wide), so a wait from an earlier run
        // whose task still runs is found again.
        s.latestRunId = run; s.steps = []; s.lastPosition = -1; s.secretPrompt = nil
        s.backgroundWait = false; s.backgroundWaitAt = nil; s.backgroundWaitRun = nil
        s.approvalText = nil; s.approvalRequestId = nil   // the old run's request can no longer be decided
        hiddenIDs.remove(threadId)   // a new run: the thread is working again
        return true
    }

    /// Result of `t3_thread_read` (activity view). Pages forward: items replace by `itemId`.
    public mutating func applyRead(_ read: ThreadRead) {
        guard var s = sessions[read.threadId] else { return }
        s.pendingRequestCount = read.pendingRequestCount
        s.activeRunId = read.activeRunId
        // `idle` threads are never listed (§8): a session that resolves to idle leaves the huddle.
        if read.status == .idle { sessions[read.threadId] = nil; return }
        // Settled (or snoozed, archived) and finished: gone from the huddle, like `applyFinished` does for listed threads.
        if read.putAway && !read.status.isActive { sessions[read.threadId] = nil; return }
        if read.status != .unknown { s.t3Status = read.status }
        s.awaitedBackgroundTasks = read.awaitedBackgroundTasks ?? s.awaitedBackgroundTasks
        s.providerInstanceId = read.providerInstanceId ?? s.providerInstanceId; s.model = read.model ?? s.model
        s.branch = read.branch ?? s.branch; s.runCount = read.runCount ?? s.runCount
        if let r = read.run { s.runStartedAt = r.startedAt; s.runCompletedAt = r.completedAt; s.executedModel = r.executedModel }
        for item in read.items.sorted(by: { $0.position < $1.position }) where item.type == "secret_request" {
            s.secretPrompt = Self.isPending(item.status) ? SecretPrompt(label: DisplayText.clean(String((item.title ?? "a secret").prefix(120)))) : nil
        }
        for item in read.items.sorted(by: { $0.position < $1.position }) where item.type == "approval_request" {
            s.approvalText = Self.approvalSummary(item)
            s.approvalRequestId = Self.isApprovable(item) ? ApprovalWire.requestId(fromItemId: item.itemId) : nil
        }
        for item in read.items where item.type != "reasoning" && item.type != "user_message" && item.type != "approval_request" && item.type != "checkpoint" {
            var step = Self.step(from: item)
            if let i = s.steps.firstIndex(where: { $0.id == step.id }) {
                if s.steps[i].outputIsFull { step.output = s.steps[i].output; step.outputIsFull = true }   // no flicker back to the head
                s.steps[i] = step
            } else { s.steps.append(step) }
        }
        for item in read.items.sorted(by: { $0.position < $1.position }) { Self.applyWait(item, to: &s) }
        s.steps.sort { $0.position < $1.position }
        if s.steps.count > 200 { s.steps.removeFirst(s.steps.count - 200) }
        s.lastPosition = max(s.lastPosition, read.items.map(\.position).max() ?? -1)
        sessions[read.threadId] = s
    }

    /// Replace the full output of one command step (after paging long text).
    public mutating func setOutput(threadId: String, itemId: String, output: String) {
        guard let i = sessions[threadId]?.steps.firstIndex(where: { $0.id == itemId }) else { return }
        sessions[threadId]?.steps[i].output = output
        sessions[threadId]?.steps[i].outputIsFull = true
    }

    /// Pending-request check for a thread that is `waiting` or has `pendingRequestCount > 0`.
    /// Approvals are never listed (§5.4), so *waiting with no listed question* is inferred as a permission (Q2), unless T3
    /// says the thread waits only on a background task (`waitingOnlyOnBackgroundTask`).
    /// `listSucceeded == false` (tool error) means "unknown": never infer a permission from a failed list.
    public mutating func applyPending(threadId: String, questions: [Question], listSucceeded: Bool = true) {
        guard var s = sessions[threadId] else { return }
        let wasNeeding = s.needsAttention
        s.question = questions.first
        if listSucceeded && questions.isEmpty && s.secretPrompt == nil && !s.waitingOnlyOnBackgroundTask
            && (s.t3Status == .waiting || s.pendingRequestCount > 0) {
            s.permission = PermissionPrompt(summary: s.approvalText ?? Self.permissionSummary(steps: s.steps),
                                            requestId: s.approvalText != nil ? s.approvalRequestId : nil)
        } else {
            s.permission = nil
        }
        if !wasNeeding && s.needsAttention { hiddenIDs.remove(threadId) }   // "comes back by itself" (§9.7)
        sessions[threadId] = s
    }

    /// No pending request left (status left `waiting` and the count is zero).
    public mutating func clearPending(threadId: String) {
        sessions[threadId]?.question = nil
        sessions[threadId]?.permission = nil
    }

    public mutating func hide(_ threadId: String) { hiddenIDs.insert(threadId) }

    // MARK: Helpers

    /// The background-wait rule, a function of the item stream alone so a cold read of the whole thread and incremental
    /// polling agree. T3 keeps a thread in Working until the waited-on task exits, across later runs, and shows nothing
    /// else; the MCP gives no task state, so this is a heuristic:
    /// - A `t3_background_wait` call starts a wait, unless T3 matched none of its task ids. `"waiting": false` ends it.
    /// - A task that exits after the turn ended wakes the agent with T3's own notification (`Command "…" finished`), which
    ///   ends the wait. Other notifications (a watched PR's checks) start a run too, and do not end it.
    /// - A task that exits inside the turn leaves no item. Shell commands or edits in the same run, from `waitPeek` after
    ///   the wait on, are taken as the agent having moved on with the task done (seen live). Quicker ones are peeks at a
    ///   task still running (also seen live), and work in a later run says nothing about the task.
    static func applyWait(_ item: ActivityItem, to s: inout Session) {
        if isBackgroundWait(item) {
            if isBackgroundWaitCleared(item) { s.backgroundWait = false; s.backgroundWaitAt = nil; return }
            guard !backgroundWaitMatchedNothing(item) else { return }
            s.backgroundWait = true; s.backgroundWaitAt = item.updatedAt ?? s.backgroundWaitAt; s.backgroundWaitRun = item.runId
        } else if item.type == "notification" {
            if isTaskFinishedNotice(item) { s.backgroundWait = false }
        } else if s.backgroundWait && (item.type == "command_execution" || item.type == "file_change") {
            if let run = s.backgroundWaitRun, let other = item.runId, run != other { return }
            if let at = s.backgroundWaitAt, let done = item.updatedAt,
               HuddleState.date(done).timeIntervalSince(HuddleState.date(at)) < waitPeek { return }
            s.backgroundWait = false
        }
    }

    /// Work this soon after a wait is a peek at a task that is still running, not the agent moving on.
    static let waitPeek: TimeInterval = 120

    /// T3's answer `{"matched":[],"unmatched":[…]}`: none of the ids is a running task, so nothing is waited on. An answer
    /// cut off before the output counts as a wait.
    static func backgroundWaitMatchedNothing(_ item: ActivityItem) -> Bool {
        (item.text ?? "").filter { !$0.isWhitespace && $0 != "\\" }.contains("{\"matched\":[]")
    }

    /// T3's notification that a background command exited (`Command "…" finished`), as opposed to a watched PR's
    /// (`#420: checks failed`, item id `message:pr-watch:…`). Told apart by the item id, with the text as a fallback.
    static func isTaskFinishedNotice(_ item: ActivityItem) -> Bool {
        if item.itemId.contains("pr-watch") { return false }
        return item.itemId.contains("message%3Athread%3A") || (item.text ?? "").hasPrefix("Command \"")
    }

    /// `t3_background_wait` with `"waiting": false`: the agent cleared its wait.
    static func isBackgroundWaitCleared(_ item: ActivityItem) -> Bool {
        (item.text ?? "").filter { !$0.isWhitespace }.contains("\"waiting\":false")
    }

    /// The agent called `t3_background_wait`: its turn ends while a background task keeps running.
    static func isBackgroundWait(_ item: ActivityItem) -> Bool {
        guard item.type == "dynamic_tool" else { return false }
        let compact = (item.text ?? "").filter { !$0.isWhitespace }
        return compact.contains("\"toolName\":\"mcp__t3-code__t3_background_wait\"") || compact.contains("\"toolName\":\"t3_background_wait\"")
    }

    /// T3 gives a tool call as JSON text with no title: `{"toolName":"mcp__t3-code__request_secret","input":{…}}`. Read it as
    /// "request_secret: <the first useful input>" instead of showing its first line, which is just `{`.
    static func toolLabel(fromJSON text: String) -> String? {
        guard text.utf8.count < 64 * 1024, let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = obj["toolName"] as? String, !raw.isEmpty else { return nil }
        let name = raw.components(separatedBy: "__").last.flatMap { $0.isEmpty ? nil : $0 } ?? raw
        if let input = obj["input"] as? [String: Any] {
            for key in ["command", "path", "file_path", "url", "label", "query", "pattern", "description", "prompt", "name"] {
                if let v = input[key] as? String, !v.isEmpty {
                    let one = v.split(separator: "\n").first.map(String.init) ?? v
                    return "\(name): \(shortenPaths(String(one.prefix(80))))"
                }
            }
        }
        return name
    }

    /// An item that is still waiting for someone (not finished, cancelled or failed).
    static func isPending(_ status: String) -> Bool {
        !["completed", "complete", "done", "success", "cancelled", "canceled", "failed", "error", "expired", "timed_out", "declined", "rejected", "resolved"].contains(status.lowercased())
    }

    static func step(from item: ActivityItem) -> Step {
        let kind: StepKind
        let text = item.text ?? ""
        switch item.type {
        case "command_execution": kind = .terminal
        case "dynamic_tool":
            let t = (item.title ?? toolLabel(fromJSON: text)?.lowercased() ?? "").lowercased()
            kind = ["write", "edit", "multiedit", "update", "create", "apply", "patch"].contains(where: { t.hasPrefix($0) }) ? .edit : .tool
        case "file_change": kind = .edit
        default: kind = .message
        }
        var label = item.title ?? ""
        var output: String?
        var command: String?
        if kind == .terminal {
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            var cmd = lines.first ?? ""
            if cmd.hasPrefix("$ ") { cmd.removeFirst(2) }
            command = cmd
            if label.isEmpty { label = cmd }
            output = lines.count > 1 ? lines[1] : ""
        } else if label.isEmpty {
            if item.type == "dynamic_tool", let l = toolLabel(fromJSON: text) { label = l }
            else if item.type == "file_change" { label = "Edit " + shortenPaths(text.split(separator: "\n").first.map(String.init) ?? "") }
            else { label = text.split(separator: "\n").first.map(String.init) ?? item.type }
        } else {
            label = shortenPaths(label)   // "Read /a/b/c.md" → "Read c.md"
        }
        let state: StepState
        switch item.status.lowercased() {
        case "completed", "complete", "done", "success": state = .done
        case "running", "in_progress", "inprogress", "started": state = .running
        case "failed", "error", "declined": state = .failed
        default: state = .pending
        }
        let detailText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Step(id: item.itemId, position: item.position, kind: kind, label: DisplayText.clean(label),
                    state: item.type == "error" ? .failed : state, output: output, command: command,
                    detail: kind == .terminal || detailText.isEmpty ? nil : String(detailText.prefix(1500)))
    }

    /// "Read /Users/x/proj/docs/SPEC.md" → "Read SPEC.md" (the panel shows bare file names).
    static func shortenPaths(_ title: String) -> String {
        let words = title.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
            guard w.hasPrefix("/"), w.count > 1, let last = w.split(separator: "/").last else { return String(w) }
            return String(last)
        }
        return words.joined(separator: " ")
    }

    /// Best-effort `Bash: <command>` from the newest unfinished command (Q2 — unproven source).
    /// `{"command":"pwd"}` with title `Allow bash?` → `Bash: pwd`. Other shapes fall back to the item's own text.
    static func approvalSummary(_ item: ActivityItem) -> String? {
        let raw = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The tool name comes from T3's own title only, never from the agent's text, and is cleaned and capped.
        let tool = toolName(fromTitle: item.title) ?? "Tool"
        if let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["command", "path", "file_path", "url"] {
                if let v = obj[key] as? String, !v.isEmpty { return "\(tool): \(v)" }
            }
        }
        return raw.isEmpty ? (item.title.map { "\(tool): \(DisplayText.clean($0))" }) : "\(tool): \(String(raw.prefix(400)))"
    }

    /// `Allow bash?` → "Bash". Nil when the title does not have that shape.
    static func toolName(fromTitle title: String?) -> String? {
        guard let t = title, t.lowercased().hasPrefix("allow "), t.hasSuffix("?") else { return nil }
        let name = DisplayText.clean(String(t.dropFirst(6).dropLast()).trimmingCharacters(in: .whitespaces))
        guard !name.isEmpty, name.count <= 24, !name.contains(where: { " {}\"\n".contains($0) }) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Inline Allow / Deny is offered only when the panel shows the *whole* request: a `waiting` item, text not cut off, and either
    /// plain text of at most the summary's 400 characters or a JSON object whose only material key is the one displayed
    /// (`approvalSummary` prints a single field, so a Write with `path` + `content` is not approvable here).
    static func isApprovable(_ item: ActivityItem) -> Bool {
        guard item.status.lowercased() == "waiting", !item.textTruncated else { return false }
        let raw = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        guard let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw.count <= 400
        }
        guard !JSONDuplicateKeys.hasDuplicate(raw) else { return false }   // two parsers could read a repeated key differently
        guard let shown = ["command", "path", "file_path", "url"].first(where: { (obj[$0] as? String)?.isEmpty == false }) else { return false }
        // `description` and `timeout` are informational for a shell command only; for any other tool every field is a payload
        // the panel does not show, so such a request stays on "Review in T3 Code".
        let informational: Set<String> = toolName(fromTitle: item.title) == "Bash" ? ["description", "timeout"] : []
        return obj.keys.allSatisfy { $0 == shown || informational.contains($0) }
    }

    static func permissionSummary(steps: [Step]) -> String? {
        guard let s = steps.last(where: { $0.kind == .terminal && $0.state != .done && $0.state != .failed }) else { return nil }
        return "Bash: \(s.command ?? s.label)"
    }

    static func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? .distantPast
    }
}

// MARK: - Polling schedule (SPEC §7.3)

public enum PollSchedule {
    public static func listInterval(expanded: Bool, consecutiveFailures: Int) -> TimeInterval {
        if consecutiveFailures >= 3 { return 15 }
        if consecutiveFailures > 0 { return 5 }   // no retries faster than 5 s when unreachable
        return expanded ? 2 : 5
    }
    public static let detailInterval: TimeInterval = 1
    /// Sleep between loop iterations. Failures always win: no retry faster than the back-off, detail open or not (§6.5).
    public static func loopInterval(detailOpen: Bool, expanded: Bool, consecutiveFailures: Int) -> TimeInterval {
        if consecutiveFailures > 0 { return listInterval(expanded: expanded, consecutiveFailures: consecutiveFailures) }
        return detailOpen ? detailInterval : listInterval(expanded: expanded, consecutiveFailures: 0)
    }
}

// MARK: - Local preferences (SPEC §8: no thread content, ever)

public struct Preferences: Codable, Equatable, Sendable {
    public var hiddenIDs: [String] = []
    public var panelX: Double?
    public var panelY: Double?
    /// Tallest the panel may grow (set by dragging its bottom edge); nil = as tall as the screen allows.
    public var panelMaxHeight: Double?
    public var collapsed = false
    public var muted = false
    public var readOnly = false
    public var closeSettles = false
    /// Public (non-secret) OAuth client registration, reused while the redirect port is unchanged.
    public var oauthClientId: String?
    public var oauthPort: UInt16?
    /// Spec 14. Optional so a preferences file from an earlier version still loads.
    public var showPanelOnAttention: Bool?
    public var settingsOnTop: Bool?
    /// Spec 16: defaults for new threads and what was used last.
    public var newThread: NewThreadDefaults?
    /// Spec 02: rows kept across restarts until closed or put away in T3. Thread id → machine id ("" = this Mac).
    /// Ids only, like `hiddenIDs`: no titles, no content.
    public var keptThreads: [String: String]?
    public init() {}
}

public struct PreferencesStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentHuddle")
    }
    var file: URL { directory.appendingPathComponent("preferences.json") }
    public func load() -> Preferences {
        guard let d = try? Data(contentsOf: file), let p = try? JSONDecoder().decode(Preferences.self, from: d) else { return Preferences() }
        return p
    }
    public func save(_ p: Preferences) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: file, options: .atomic) }
    }
}
