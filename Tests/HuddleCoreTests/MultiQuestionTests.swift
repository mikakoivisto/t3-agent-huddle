import Testing
import Foundation
@testable import HuddleCore
import FakeT3

/// Several questions in one request (spec 04), against the fake. The answer shape was seen live: one `answers` map keyed by
/// each question's id.
@Suite("Several questions in one request")
@MainActor
struct MultiQuestionTests {
    static let more: [FakeT3Server.FakeQuestion.Part] = [
        .init(id: "q1", header: "Scope", question: "Ship streaming now?", options: [("Later (Recommended)", "Nothing waits on it."), ("Now", "Bigger review.")]),
        .init(id: "q2", header: "Timeout", question: "Reset the exchange on timeout?", options: [("Reset", "Frees the connection."), ("Keep", "Exact parity.")]),
        .init(id: "q3", header: "Defaults", question: "Accept the defaults?", options: [("Accept", "As listed."), ("Tighter", "Say which.")]),
    ]

    func setUp() async throws -> (FakeT3Server, HuddleModel, Question) {
        let s = try await startFake()
        s.update(Scenario.questionThread) { $0.questions[0].more = Self.more }
        let m = makeModel(s); await m.refresh()
        let q = try #require(m.state.sessions[Scenario.questionThread]?.question)
        return (s, m, q)
    }

    @Test func fourQuestionsAreReadAndAnswerableInThePanel() async throws {
        let (s, m, q) = try await setUp(); defer { s.stop() }
        #expect(q.parts.map(\.id) == ["q0", "q1", "q2", "q3"])
        #expect(q.multiAnswerable && !q.answerableInWidget)
        #expect(q.parts[1].options[0].detail == "Nothing waits on it.")
        #expect(m.state.sessions[Scenario.questionThread]?.statusLine == "asks 4 questions")
    }

    @Test func anOptionMovesOnAndAllAreSentTogetherFromTheReview() async throws {
        let (s, m, q) = try await setUp(); defer { s.stop() }
        #expect(m.multiStep(q) == 0)
        m.chooseMultiAnswer(q, q.parts[0].options[0].label)
        #expect(m.multiStep(q) == 1, "an option moves to the next question")
        m.chooseMultiAnswer(q, "Later (Recommended)")
        // Written answer for the third question.
        m.startWritingMultiAnswer(q)
        m.composer.drafts[HuddleModel.multiDraftKey(q.requestId, "q2")] = "  Reset, but log it  "
        m.useWrittenMultiAnswer(q)
        #expect(m.multiStep(q) == 3 && m.multiWritingFor == nil)
        await m.sendMultiAnswers(threadId: Scenario.questionThread)
        #expect(s.answers.isEmpty, "nothing is sent before every question has an answer and the review is open")
        m.chooseMultiAnswer(q, "Accept")
        #expect(m.multiStep(q) == q.parts.count, "the last answer opens the review")
        await m.sendMultiAnswers(threadId: Scenario.questionThread)
        let a = try #require(s.answers.first)
        #expect(s.answers.count == 1)
        #expect(a.answers["q0"].string == q.parts[0].options[0].label)
        #expect(a.answers["q1"].string == "Later (Recommended)")
        #expect(a.answers["q2"].string == "Reset, but log it")
        #expect(a.answers["q3"].string == "Accept")
        #expect(m.rowToasts[Scenario.questionThread] == "4 answers sent")
        #expect(m.multiAnswers[q.requestId] == nil)
    }

    @Test func changingAnAnswerFromTheReviewReturnsToTheReview() async throws {
        let (s, m, q) = try await setUp(); defer { s.stop() }
        for p in q.parts { m.chooseMultiAnswer(q, p.options[0].label) }
        #expect(m.multiStep(q) == 4)
        m.goToMultiStep(q, 1)
        m.chooseMultiAnswer(q, "Now")
        #expect(m.multiStep(q) == 4 && m.multiAnswer(q, q.parts[1]) == "Now")
    }

    @Test func readOnlySendsNothing() async throws {
        let (s, m, q) = try await setUp(); defer { s.stop() }
        for p in q.parts { m.chooseMultiAnswer(q, p.options[0].label) }
        m.setReadOnly(true)
        await m.sendMultiAnswers(threadId: Scenario.questionThread)
        #expect(s.answers.isEmpty)
    }

    @Test func multiSelectOrRepeatedIdsStayInT3() {
        let base: JSON = ["requestId": "r", "questions": [
            ["id": "a", "question": "One?", "options": [["label": "x"]]],
            ["id": "a", "question": "Two?", "options": [["label": "y"]]]]]
        #expect(QuestionCodec.question(fromRead: base, threadId: "t")?.multiAnswerable == false, "repeated ids would collide in the answers map")
        let multi: JSON = ["requestId": "r", "questions": [
            ["id": "a", "question": "One?", "options": [["label": "x"]]],
            ["id": "b", "question": "Two?", "multiSelect": true, "options": [["label": "y"]]]]]
        #expect(QuestionCodec.question(fromRead: multi, threadId: "t")?.multiAnswerable == false)
    }
}
