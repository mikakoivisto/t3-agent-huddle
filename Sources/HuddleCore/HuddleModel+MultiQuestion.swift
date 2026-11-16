import Foundation

// Several questions in one request (spec 04): one at a time, an option moves on to the next, any can be written instead,
// then a review and one Send for all of them. Answers stay in memory.

extension HuddleModel {
    public static func multiDraftKey(_ requestId: String, _ partId: String) -> String { "m|\(requestId)|\(partId)" }

    public func multiStep(_ q: Question) -> Int { min(multiSteps[q.requestId] ?? 0, q.parts.count) }
    public func multiAnswer(_ q: Question, _ part: QuestionPart) -> String? { multiAnswers[q.requestId]?[part.id] }
    public func multiAllAnswered(_ q: Question) -> Bool { q.parts.allSatisfy { multiAnswers[q.requestId]?[$0.id] != nil } }

    /// Show question `i` (`q.parts.count` = the review).
    public func goToMultiStep(_ q: Question, _ i: Int) {
        multiSteps[q.requestId] = max(0, min(i, q.parts.count))
        if multiWritingFor == q.requestId { multiWritingFor = nil }
        if case .error = questionStates[q.requestId] { questionStates[q.requestId] = .pending }
    }

    /// An option or a written answer for the shown question; moves to the next unanswered one, or to the review.
    public func chooseMultiAnswer(_ q: Question, _ value: String) {
        guard q.multiAnswerable, questionStates[q.requestId] != .sending else { return }
        let i = multiStep(q)
        guard q.parts.indices.contains(i) else { return }
        multiAnswers[q.requestId, default: [:]][q.parts[i].id] = value
        let next = q.parts.indices.first { $0 > i && multiAnswers[q.requestId]?[q.parts[$0].id] == nil }
            ?? q.parts.indices.first { multiAnswers[q.requestId]?[q.parts[$0].id] == nil }
            ?? q.parts.count
        goToMultiStep(q, next)
    }

    public func startWritingMultiAnswer(_ q: Question) {
        if let open = composingThreadId { closeComposer(open) }
        multiWritingFor = q.requestId
    }

    public func cancelWritingMultiAnswer() { multiWritingFor = nil }

    /// "Use this answer": the written text becomes the shown question's answer.
    public func useWrittenMultiAnswer(_ q: Question) {
        let i = multiStep(q)
        guard q.parts.indices.contains(i) else { return }
        let key = Self.multiDraftKey(q.requestId, q.parts[i].id)
        let text = composer.text(key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maxMessageLength else { return }
        multiWritingFor = nil
        chooseMultiAnswer(q, text)
    }

    /// One `respond` with every answer, only from the review's Send.
    public func sendMultiAnswers(threadId: String) async {
        guard let s = state.sessions[threadId], let q = s.question, q.multiAnswerable, multiStep(q) == q.parts.count,
              questionStates[q.requestId] != .sending, let answers = multiAnswers[q.requestId],
              q.parts.allSatisfy({ answers[$0.id] != nil }) else { return }
        guard !readOnly else { questionStates[q.requestId] = .error("Read-only mode. Turn it off in the menu to send."); return }
        guard canAnswer(s) else { return }
        let sent = Dictionary(uniqueKeysWithValues: q.parts.map { ($0.id, answers[$0.id]!) })
        questionStates[q.requestId] = .sending
        do {
            try await onMachine(threadId) { c, env in try await c.respond(question: q, answers: sent, environment: env) }
            justAnswered[threadId] = Date()
            questionStates[q.requestId] = nil
            multiAnswers[q.requestId] = nil; multiSteps[q.requestId] = nil
            for p in q.parts { composer.drafts[Self.multiDraftKey(q.requestId, p.id)] = nil }
            state.clearPending(threadId: threadId)
            showRowToast(threadId, "\(q.parts.count) answers sent")
            await refresh(force: true)
        } catch {
            questionStates[q.requestId] = .error(Self.oneLine(error))
        }
    }
}
