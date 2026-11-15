import Testing
import Foundation
@testable import HuddleCore
import FakeT3

@Suite("MCP client vs fake server (loopback, ephemeral port)")
struct MCPClientTests {
    @Test func handshakeListsToolsAndPassesContractCheck() async throws {
        let s = try await startFake(); defer { s.stop() }
        let c = try MCPClient(endpoint: s.url, token: s.token)
        let tools = try await c.toolsList()
        #expect(ContractCheck.verify(toolsList: tools) == nil)
        #expect(tools["tools"].array?.contains { $0["name"].string == "t3_pending_request" } == true)
    }

    @Test func listThreadsPagesWithCursorAndReturnsSubagentsForClientSideFiltering() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        for i in 0..<7 { s.add(.init(id: "t\(i)", title: "T\(i)", status: "running")) }
        s.add(.init(id: "child", title: "kid", status: "running", parentThreadId: "t0"))
        let c = try MCPClient(endpoint: s.url, token: s.token)
        // limit 3 forces several pages (8 rows).
        let rows = try await c.listThreads(statuses: ["running"], limit: 3)
        #expect(rows.count == 8)
        #expect(rows.contains { $0.parentThreadId == "t0" })   // the real quirk (§5.3)
        var st = HuddleState(); st.applyActive(rows)
        #expect(st.count == 7)                                  // filtered client-side
    }

    @Test func activityPagingByPositionAndLongTextContinuation() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        let long = (0..<300).map { "line \($0)" }.joined(separator: "\n")
        s.add(.init(id: "t", title: "T", status: "running", items:
            (0..<5).map { Scenario.tool($0, "Read f\($0)") } + [Scenario.cmd(5, "make", output: long)]))
        let c = try MCPClient(endpoint: s.url, token: s.token)
        let first = try await c.readActivity(threadId: "t", afterPosition: nil, limit: 3)
        #expect(first.items.map(\.position) == [0, 1, 2]); #expect(first.hasMore)
        let rest = try await c.readActivity(threadId: "t", afterPosition: 2, limit: 30, maxChars: 50)
        #expect(rest.items.map(\.position) == [3, 4, 5])
        let cmd = rest.items.last!
        #expect(cmd.textTruncated && cmd.nextTextOffset == 50)
        let full = try await c.readItemText(threadId: "t", itemId: cmd.itemId, offset: 0)
        #expect(full.contains("line 299"))
        #expect(full.hasPrefix("$ make"))
    }

    @Test func unauthorizedWithWrongTokenMapsTo401Error() async throws {
        let s = try await startFake(); defer { s.stop() }
        let c = try MCPClient(endpoint: s.url, token: "wrong-token")
        await #expect(throws: HuddleError.unauthorized) { try await c.toolsList() }
    }

    @Test func unreachableServerMapsToNotRunning() async throws {
        let s = try await startFake(); let url = s.url; s.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let c = try MCPClient(endpoint: url, token: "x", timeout: 1)
        await #expect(throws: HuddleError.notRunning) { try await c.toolsList() }
    }

    @Test func sseAndStructuredContentFramingBothWork() async throws {
        var o = FakeT3Server.Options(); o.sse = true; o.structured = true
        let s = try await startFake(o); defer { s.stop() }
        let c = try MCPClient(endpoint: s.url, token: s.token)
        let rows = try await c.listThreads(statuses: T3Status.activeStatuses)
        #expect(rows.count >= 4)
    }

    @Test func questionReadAndRespondRoundTrip() async throws {
        let s = try await startFake(); defer { s.stop() }
        let c = try MCPClient(endpoint: s.url, token: s.token)
        let ids = try await c.pendingRequestIds(threadId: Scenario.questionThread)
        #expect(ids == ["req_tone"])
        let q = try #require(try await c.readQuestion(threadId: Scenario.questionThread, requestId: "req_tone"))
        #expect(q.tag == "TONE"); #expect(q.options.map(\.label) == ["Concise", "Friendly", "Formal"])
        #expect(q.answerableInWidget)
        try await c.respond(question: q, selection: "The number one")
        #expect(s.answers.first?.requestId == "req_tone")
        #expect(s.answers.first?.answers["q0"].string == "The number one")
        #expect(s.thread(Scenario.questionThread)?.questions.isEmpty == true)
    }

    @Test func approvalsAreNotListedAndCannotBeAnswered() async throws {
        let s = try await startFake(); defer { s.stop() }
        let c = try MCPClient(endpoint: s.url, token: s.token)
        #expect(try await c.pendingRequestIds(threadId: Scenario.permissionThread).isEmpty)
        let read = try await c.readActivity(threadId: Scenario.permissionThread, afterPosition: nil)
        #expect(read.pendingRequestCount == 1)
    }

    @Test func toolErrorsSurfaceAsToolFailed() async throws {
        let s = try await startFake(); defer { s.stop() }
        let c = try MCPClient(endpoint: s.url, token: s.token)
        await #expect(throws: HuddleError.self) { try await c.readActivity(threadId: "nope", afterPosition: nil) }
    }

    @Test func sseReplyDecoderPicksJsonRpcEvent() throws {
        let body = "event: ping\ndata: {\"x\":1}\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\n"
        let j = try MCPClient.decodeReply(Data(body.utf8), contentType: "text/event-stream")
        #expect(j["result"]["ok"].bool == true)
    }

    @Test func clientRefusesNonLoopbackEndpoint() {
        #expect(throws: HuddleError.self) { try MCPClient(endpoint: URL(string: "http://192.168.1.5:3773/mcp")!, token: "x") }
        #expect(throws: HuddleError.self) { try MCPClient(endpoint: URL(string: "http://example.com/mcp")!, token: "x") }
        #expect(throws: HuddleError.self) { try MCPClient(endpoint: URL(string: "https://127.0.0.1:3773/mcp")!, token: "x") }
        #expect(throws: HuddleError.self) { try MCPClient(endpoint: URL(string: "http://localhost:3773/mcp")!, token: "x") }
    }
}
