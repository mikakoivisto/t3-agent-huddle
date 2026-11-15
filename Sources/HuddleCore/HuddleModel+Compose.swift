import Foundation
import Combine

/// Drafts of written messages and answers (spec 13). Its own observable, so a keystroke re-renders the editor only, and a poll
/// does not re-render the editor. Memory only: never written to disk, never logged, gone when the app quits.
@MainActor
public final class ComposerStore: ObservableObject {
    @Published public var drafts: [String: String] = [:]
    public init() {}

    public static func messageKey(_ threadId: String) -> String { "t|\(threadId)" }
    public static func answerKey(_ requestId: String) -> String { "a|\(requestId)" }
    public func text(_ key: String) -> String { drafts[key] ?? "" }
}

/// Write an answer, send a message, steer a run (spec 13). Everything is sent on an explicit click, with text the user typed.
extension HuddleModel {
    public static let maxMessageLength = 20_000

    // MARK: Availability

    /// T3 offers `t3_thread_send` with a `mode` argument. Without it the Message button is hidden.
    public var canSendMessages: Bool {
        toolNames.contains("t3_thread_send") && (toolArguments["t3_thread_send"]?.contains("mode") ?? false)
    }

    /// A thread that asks for something gets that first (answer, permission, secret); a message would only queue behind it.
    /// A thread on a linked machine has no composer: live T3 refuses sends to it through this Mac (`capability_denied`).
    public func canMessage(_ s: Session) -> Bool {
        canSendMessages && s.question == nil && s.permission == nil && s.secretPrompt == nil && env(s.threadId) == nil
    }

    /// Steering needs a turn in progress, as T3 reports it (not the panel's inferred "working").
    public func canSteer(_ s: Session) -> Bool { s.t3Status == .running }

    public func sendMode(_ s: Session) -> SendMode { canSteer(s) ? (sendModes[s.threadId] ?? .queue) : .queue }

    /// What the button says: Send when T3 does not report the thread active, Queue when it does, Steer when flipped.
    public func sendLabel(_ s: Session) -> String {
        if case .error = composeStates[s.threadId] { return "Retry" }
        if composeStates[s.threadId] == .sending { return "Sending…" }
        if !s.t3Status.isActive { return "Send" }
        return sendMode(s) == .steer ? "Steer" : "Queue"
    }

    public func sendHint(_ s: Session) -> String {
        if !s.t3Status.isActive { return "Starts a new turn." }
        return sendMode(s) == .steer ? "Reaches the agent now, during this turn." : "Sent after the current turn finishes."
    }

    // MARK: Composer

    public func openComposer(_ threadId: String) {
        guard let s = state.sessions[threadId], canMessage(s) else { return }
        if writingAnswerFor != nil { stopWritingAnswer() }       // one editor at a time, so ⌘↩ and Esc are never ambiguous
        composingThreadId = threadId
        composeTargets[threadId] = s.environmentId ?? ""
        composeNotices[threadId] = nil
    }

    /// Closes the small composer. The draft is kept unless it is empty.
    public func closeComposer(_ threadId: String) {
        if composer.text(ComposerStore.messageKey(threadId)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composer.drafts[ComposerStore.messageKey(threadId)] = nil
        }
        if composingThreadId == threadId { composingThreadId = nil }
        composeNotices[threadId] = nil
        if case .error = composeStates[threadId] { composeStates[threadId] = nil }
    }

    public func toggleSendMode(_ threadId: String) {
        guard let s = state.sessions[threadId], canSteer(s) else { return }
        sendModes[threadId] = sendMode(s) == .steer ? .queue : .steer
        composeNotices[threadId] = nil
        if case .error = composeStates[threadId] { composeStates[threadId] = nil }
    }

    /// Send what the composer holds. `steer: true` is ⌥⌘↩: steer this once, whatever the toggle says.
    public func sendMessage(threadId: String, steer: Bool = false) async {
        guard composeStates[threadId] != .sending, let s = state.sessions[threadId] else { return }
        guard !readOnly else { composeStates[threadId] = .error("Read-only mode. Turn it off in the menu to send."); return }
        let key = ComposerStore.messageKey(threadId)
        let text = composer.text(key)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= Self.maxMessageLength else { return }
        // The composer belongs to the thread and machine it was opened for.
        if let target = composeTargets[threadId], target != (s.environmentId ?? "") {
            composeStates[threadId] = .error("This thread is now reported by another machine. Nothing was sent."); return
        }
        guard !state.collidingThreadIds.contains(threadId) else {
            composeStates[threadId] = .error("Two machines report this thread id. Nothing was sent."); return
        }
        guard canMessage(s) else { return }
        composeStates[threadId] = .sending           // before the first await, so a double click cannot pass the guard twice
        guard let client = try? await ensureClient() else {
            composeStates[threadId] = .error("Couldn’t reach T3 Code. Nothing was sent."); return
        }
        let environment = env(threadId)
        var mode: SendMode = s.t3Status.isActive && (steer || sendMode(s) == .steer) ? .steer : .queue
        if mode == .steer && !canSteer(s) { mode = .queue }
        if mode == .steer {
            // The list can be a poll old: steer only a turn T3 says is running now. Otherwise send nothing and say so.
            let now = try? await client.threadStatus(threadId: threadId, environment: environment)
            guard now == .running else {
                sendModes[threadId] = .queue
                composeStates[threadId] = nil
                composeNotices[threadId] = "The run finished. Send as a new turn?"
                await refresh(force: true)          // so the button shows what a click would do now (Send)
                return
            }
        }
        // One id per exact message: a retry of the same text and mode reuses it; an edit or a flipped mode gets a new one.
        let fingerprint = [threadId, environment ?? "", mode.rawValue, text].joined(separator: "\u{1F}")
        let requestId = pendingSends[threadId].flatMap { $0.fingerprint == fingerprint ? $0.id : nil } ?? UUID().uuidString
        pendingSends[threadId] = (fingerprint, requestId)
        do {
            try await client.sendMessage(threadId: threadId, message: text, mode: mode, clientRequestId: requestId, environment: environment)
            pendingSends[threadId] = nil
            composer.drafts[key] = nil
            composeStates[threadId] = nil
            composeNotices[threadId] = nil
            sendModes[threadId] = nil
            if composingThreadId == threadId { composingThreadId = nil }
            showRowToast(threadId, mode == .steer ? "Steered" : (s.t3Status.isActive ? "Queued" : "Sent"))
            await refresh(force: true)
        } catch {
            composeStates[threadId] = .error(Self.oneLine(error))
        }
    }

    // MARK: Written answers

    public func startWritingAnswer(_ requestId: String) {
        if let open = composingThreadId { closeComposer(open) }
        writingAnswerFor = requestId
        if case .error = questionStates[requestId] { questionStates[requestId] = .pending }
    }

    public func stopWritingAnswer() {
        if let rid = writingAnswerFor,
           composer.text(ComposerStore.answerKey(rid)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composer.drafts[ComposerStore.answerKey(rid)] = nil
        }
        writingAnswerFor = nil
    }

    public func sendWrittenAnswer(threadId: String) async {
        guard let q = state.sessions[threadId]?.question, q.freeTextAnswerable, questionStates[q.requestId] != .sending else { return }
        guard !readOnly else { questionStates[q.requestId] = .error("Read-only mode. Turn it off in the menu to send."); return }
        let key = ComposerStore.answerKey(q.requestId)
        let text = composer.text(key)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= Self.maxMessageLength else { return }
        questionStates[q.requestId] = .sending
        guard let client = try? await ensureClient() else {
            questionStates[q.requestId] = .error("Couldn’t reach T3 Code. Nothing was sent."); return
        }
        do {
            try await client.respond(question: q, selection: text, environment: env(threadId))
            justAnswered[threadId] = Date()
            questionStates[q.requestId] = nil
            selections[q.requestId] = nil
            composer.drafts[key] = nil
            if writingAnswerFor == q.requestId { writingAnswerFor = nil }
            state.clearPending(threadId: threadId)
            showRowToast(threadId, "Answer sent")
            await refresh(force: true)
        } catch {
            questionStates[q.requestId] = .error(Self.oneLine(error))
        }
    }

    // MARK: Helpers

    func showRowToast(_ threadId: String, _ text: String) {
        rowToasts[threadId] = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.rowToasts[threadId] == text { self?.rowToasts[threadId] = nil }
        }
    }

    /// Live T3: a thread running in a broader mode (auto, full access) than Agent Huddle's sign-in refuses sends and answers.
    public static let modeDeniedMessage = "T3 won’t take this from Agent Huddle: the thread runs in a broader mode than Agent Huddle’s sign-in allows. Answer or send it in T3 Code."

    /// Live T3: a send to a thread on a linked machine, through this Mac's T3, is refused (`capability_denied`).
    public static let otherMachineDeniedMessage = "T3 won’t take this from Agent Huddle for a thread on another machine. Open it with ↗ and send it in T3 Code there."

    static func oneLine(_ error: Error) -> String {
        let msg = (error as? HuddleError)?.description ?? error.localizedDescription
        if msg.contains("runtime_mode_escalation_denied") { return modeDeniedMessage }
        if msg.contains("capability_denied") { return otherMachineDeniedMessage }
        return String(DisplayText.clean(msg).prefix(120))
    }

    /// Server-keyed state for threads that are gone is dropped (a hostile server cannot grow it). Drafts are not: they exist only
    /// because the user typed them, so a thread that drops out of the list and comes back still has its text. Empty ones go.
    func pruneComposeState(liveThreads: Set<String>, liveRequests: Set<String>) {
        if composer.drafts.values.contains(where: { $0.isEmpty }) { composer.drafts = composer.drafts.filter { !$0.value.isEmpty } }
        sendModes = sendModes.filter { liveThreads.contains($0.key) }
        composeStates = composeStates.filter { liveThreads.contains($0.key) }
        composeNotices = composeNotices.filter { liveThreads.contains($0.key) }
        composeTargets = composeTargets.filter { liveThreads.contains($0.key) }
        pendingSends = pendingSends.filter { liveThreads.contains($0.key) }
        if let id = composingThreadId, !liveThreads.contains(id) { composingThreadId = nil }
        if let rid = writingAnswerFor, !liveRequests.contains(rid) { writingAnswerFor = nil }
    }
}
