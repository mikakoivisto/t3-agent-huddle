import Foundation

/// How a written message reaches a thread (spec 13): `queue` = a new turn after the current one (or now, if none runs);
/// `steer` = into the running turn. T3's other modes (`auto`, `restart`) are deliberately not representable.
public enum SendMode: String, Sendable, Equatable { case queue, steer }
import os

/// Refuse every redirect: a token must never follow a 3xx off the loopback server.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Minimal MCP client: `initialize`, `tools/list`, `tools/call` over streamable HTTP.
/// Accepts plain JSON and `text/event-stream` replies (live framing unverified, SPEC §5.6).
public final class MCPClient: @unchecked Sendable {
    public let endpoint: URL
    private let token: String
    private let session: URLSession
    private let log: HuddleLog
    private struct State { var sessionId: String?; var initialized = false; var nextId = 1; var calledTools: [String] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Every tool name this client has called — for tests and the "never writes" assertions.
    public var calledTools: [String] { state.withLock { $0.calledTools } }

    public init(endpoint: URL, token: String, log: HuddleLog = HuddleLog(), timeout: TimeInterval = 5) throws {
        self.endpoint = try LoopbackGuard.validate(endpoint)
        self.token = token
        self.log = log
        log.register(secret: token)
        self.session = LoopbackSession.make(timeout: timeout)
    }

    /// Another machine's T3 MCP over https (spec 15): only a verified origin, the system's certificate trust, no redirects,
    /// no proxy, no cookies. The token goes only to this one origin.
    public init(remote: VerifiedRemoteOrigin, token: String, log: HuddleLog = HuddleLog(), timeout: TimeInterval = 10) throws {
        guard let mcp = remote.origin.httpURL(path: "/mcp") else { throw HuddleError.badResponse("bad machine address") }
        self.endpoint = mcp
        self.token = token
        self.log = log
        log.register(secret: token)
        self.session = RemoteSession.make(timeout: timeout)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Public API

    public func initializeIfNeeded() async throws {
        if state.withLock({ $0.initialized }) { return }
        _ = try await rpc("initialize", params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [:],
            "clientInfo": ["name": "Agent Huddle", "version": "0.1.0"],
        ], expectSession: true)
        try await notify("notifications/initialized")
        state.withLock { $0.initialized = true }
    }

    public func toolsList() async throws -> JSON {
        try await initializeIfNeeded()
        return try await rpc("tools/list", params: [:])
    }

    /// Calls a tool and unwraps `structuredContent` or the first text block (parsed as JSON when possible).
    public func callTool(_ name: String, _ arguments: JSON) async throws -> JSON {
        try await initializeIfNeeded()
        state.withLock { $0.calledTools.append(name); if $0.calledTools.count > 500 { $0.calledTools.removeFirst($0.calledTools.count - 500) } }
        let result = try await rpc("tools/call", params: ["name": .string(name), "arguments": arguments])
        let text = (result["content"].array ?? []).compactMap { $0["text"].string }.joined(separator: "\n")
        if result["isError"].bool == true {
            throw HuddleError.toolFailed(text.isEmpty ? "tool error" : String(text.prefix(300)))
        }
        if !result["structuredContent"].isNull { return result["structuredContent"] }
        if let parsed = try? JSON.parse(text) { return parsed }
        return .string(text)
    }

    // MARK: Typed helpers (SPEC §7.2) — `environment` is nil for this machine, else a linked environment's id

    private func withEnv(_ args: [String: JSON], _ env: String?) -> JSON {
        var a = args
        if let env { a["environmentId"] = .string(env) }
        return .object(a)
    }

    public func listThreads(statuses: [String], settled: Bool? = nil, limit: Int = 100, environment: String? = nil) async throws -> [ThreadSummary] {
        var all: [ThreadSummary] = []
        var cursor: JSON?
        var seenCursors = Set<String>()
        for _ in 0..<5 {   // bounded paging
            var args: [String: JSON] = ["allProjects": true,
                                        "statuses": .array(statuses.map { .string($0) }),
                                        "limit": .number(Double(min(limit, 100)))]
            if let settled { args["settled"] = .bool(settled) }
            if let cursor { args["cursor"] = cursor }
            let page = ThreadListPage(json: try await callTool("t3_thread_list", withEnv(args, environment)))
            all += page.threads
            guard !page.isLast, let next = page.nextCursor, !page.threads.isEmpty else { break }
            guard seenCursors.insert(next.text()).inserted else { break }   // a cursor that repeats makes no progress
            cursor = next
        }
        return all
    }

    /// One page only (SPEC §7.2 finished-refresh: `limit: 25`, no cursor chasing). `nextCursor == nil` ⇒ exhaustive.
    public func listThreadsPage(statuses: [String], settled: Bool? = nil, limit: Int, environment: String? = nil) async throws -> ThreadListPage {
        var args: [String: JSON] = ["allProjects": true, "statuses": .array(statuses.map { .string($0) }),
                                    "limit": .number(Double(min(limit, 100)))]
        if let settled { args["settled"] = .bool(settled) }
        return ThreadListPage(json: try await callTool("t3_thread_list", withEnv(args, environment)))
    }

    /// Activity of the **latest run only** (`runLimit: 1`; live T3 numbers positions inside that window and
    /// `afterPosition` must be ≥ 0). Pass `afterPosition: nil` to start from the top of the run.
    public func readActivity(threadId: String, afterPosition: Int?, limit: Int = 50,
                             maxChars: Int = 400, environment: String? = nil) async throws -> ThreadRead {
        var args: [String: JSON] = ["threadId": .string(threadId), "view": "activity", "runLimit": 1,
                                    "limit": .number(Double(limit)), "maxCharsPerItem": .number(Double(maxChars))]
        if let afterPosition { args["afterPosition"] = .number(Double(max(afterPosition, 0))) }
        return ThreadRead(json: try await callTool("t3_thread_read", withEnv(args, environment)))
    }

    /// One timeline item by id, with its current `status` and complete text (up to 4000 chars): the pre-decision check for inline approvals.
    public func readItem(threadId: String, itemId: String, environment: String? = nil) async throws -> ActivityItem? {
        let r = try await callTool("t3_thread_read", withEnv([
            "threadId": .string(threadId), "view": "activity", "itemId": .string(itemId),
            "textOffset": 0, "maxCharsPerItem": 4000], environment))
        return (r["items"].array ?? []).compactMap(ActivityItem.init(json:)).first(where: { $0.itemId == itemId })
    }

    /// Rest of a long command output (`itemId` + `textOffset`), capped so a runaway log cannot flood memory.
    public func readItemText(threadId: String, itemId: String, offset: Int, maxTotal: Int = 200_000,
                             environment: String? = nil) async throws -> String {
        var text = ""
        var off = offset
        for _ in 0..<60 {
            let r = try await callTool("t3_thread_read", withEnv([
                "threadId": .string(threadId), "view": "activity", "itemId": .string(itemId),
                "textOffset": .number(Double(off)), "maxCharsPerItem": 4000], environment))
            guard let item = (r["items"].array ?? []).compactMap(ActivityItem.init(json:)).first(where: { $0.itemId == itemId }),
                  let chunk = item.text else { break }
            text += String(chunk.prefix(max(0, maxTotal - text.count)))   // never past the cap, whatever one chunk holds
            guard item.textTruncated, let next = item.nextTextOffset, next > off, text.count < maxTotal else { break }   // the offset must advance
            off = next
        }
        return text
    }

    public func pendingRequestIds(threadId: String, environment: String? = nil) async throws -> [String] {
        QuestionCodec.requestIds(fromList: try await callTool(
            "t3_pending_request", withEnv(["action": "list", "threadId": .string(threadId)], environment)))
    }

    public func readQuestion(threadId: String, requestId: String, environment: String? = nil) async throws -> Question? {
        QuestionCodec.question(fromRead: try await callTool(
            "t3_pending_request", withEnv(["action": "read", "threadId": .string(threadId), "requestId": .string(requestId)], environment)),
            threadId: threadId)
    }

    public func respond(question: Question, selection: String, environment: String? = nil) async throws {
        var args = QuestionCodec.respondArguments(question: question, selection: selection).object ?? [:]
        if let environment { args["environmentId"] = .string(environment) }
        _ = try await callTool("t3_pending_request", .object(args))
    }

    /// A message the user wrote, to a thread (spec 13). The only `t3_thread_send` call in the app: `mode` is one of two cases,
    /// so `restart`, `auto` and `freshContext` cannot be sent. `clientRequestId` lets T3 drop a repeat of the same message.
    public func sendMessage(threadId: String, message: String, mode: SendMode, clientRequestId: String,
                            environment: String? = nil) async throws {
        _ = try await callTool("t3_thread_send", withEnv([
            "threadId": .string(threadId), "message": .string(message), "mode": .string(mode.rawValue),
            "clientRequestId": .string(clientRequestId)], environment))
    }

    /// The thread's status as T3 reports it now: one small read, used right before a steer.
    public func threadStatus(threadId: String, environment: String? = nil) async throws -> T3Status {
        try await readActivity(threadId: threadId, afterPosition: nil, limit: 1, maxChars: 40, environment: environment).status
    }

    /// The project's display name; a thread with no project (scratch) reports "No project".
    public func projectTitle(projectId: String, environment: String? = nil) async throws -> String? {
        let r = try await callTool("t3_project_read", withEnv(["projectId": .string(projectId)], environment))
        let p = r["project"].isNull ? r : r["project"]
        return p["title"].string ?? p["name"].string
    }

    public func projectPath(projectId: String, environment: String? = nil) async throws -> String? {
        let r = try await callTool("t3_project_read", withEnv(["projectId": .string(projectId)], environment))
        let p = r["project"].isNull ? r : r["project"]
        return p["path"].string ?? p["workspaceRoot"].string ?? p["cwd"].string
    }

    public func settle(threadId: String, environment: String? = nil) async throws {
        _ = try await callTool("t3_thread_organize", withEnv(["action": "settle", "threadId": .string(threadId)], environment))
    }

    // MARK: Environments

    /// This machine, via `t3_environment_read {}` → `{environmentId, label}` (live-verified).
    public func localEnvironment() async throws -> HuddleEnvironment {
        let r = try await callTool("t3_environment_read", [:])
        return HuddleEnvironment(id: r["environmentId"].string ?? "local", label: DisplayText.clean(r["label"].string ?? "This Mac"), isLocal: true)
    }

    /// Asks T3 to show its "link another machine" card (the user picks the machine and access there).
    /// Returns T3's reply text (`pending`); the link only exists once the user approves in T3 Code.
    public func requestEnvironmentLink() async throws -> String {
        let r = try await callTool("t3_environment_link", [
            "reason": "Show that machine's running threads in Agent Huddle",
            "requestedAccess": "approval-required"])   // read + operate; never full-access
        return r["status"].string ?? r["message"].string ?? (r.string ?? "pending")
    }

    /// Other linked environments. Live T3 refuses these unless Settings → Labs → "Linked environments" is on
    /// (`capability_denied`), and the listing tool's shape is unverified — so this is best-effort and never fatal.
    public func linkedEnvironments(toolNames: Set<String>) async -> [HuddleEnvironment] {
        guard toolNames.contains("t3_environment_links"),
              let r = try? await callTool("t3_environment_links", [:]) else { return [] }
        let rows = r.array ?? r["environments"].array ?? r["links"].array ?? r["items"].array ?? []
        return rows.compactMap { row in
            guard let id = row["environmentId"].string ?? row["id"].string else { return nil }
            if row["isLocal"].bool == true || row["local"].bool == true { return nil }
            return HuddleEnvironment(id: id, label: DisplayText.clean(row["label"].string ?? row["name"].string ?? row["displayName"].string ?? id), isLocal: false)
        }
    }

    // MARK: Transport

    private func notify(_ method: String) async throws {
        _ = try await send(body: ["jsonrpc": "2.0", "method": .string(method)], wantsResponse: false, expectSession: false)
    }

    private func rpc(_ method: String, params: JSON, expectSession: Bool = false) async throws -> JSON {
        let id = state.withLock { s -> Int in defer { s.nextId += 1 }; return s.nextId }
        let body: JSON = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let reply = try await send(body: body, wantsResponse: true, expectSession: expectSession)
        if !reply["error"].isNull {
            throw HuddleError.rpc(code: reply["error"]["code"].int ?? -1, message: reply["error"]["message"].string ?? "error")
        }
        return reply["result"]
    }

    private func send(body: JSON, wantsResponse: Bool, expectSession: Bool) async throws -> JSON {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = body.data()
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let sid = state.withLock { $0.sessionId }
        if let sid { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }

        let method = body["method"].string ?? "?"
        let data: Data, response: URLResponse
        do { (data, response) = try await BoundedHTTP.data(for: req, session: session, limit: BoundedHTTP.mcpLimit) }
        catch let e as URLError where [.cannotConnectToHost, .networkConnectionLost, .timedOut,
                                       .cannotFindHost, .notConnectedToInternet].contains(e.code) {
            log.log("mcp \(method) unreachable (\(e.code.rawValue))")
            throw HuddleError.notRunning
        }
        guard let http = response as? HTTPURLResponse else { throw HuddleError.badResponse("no HTTP response") }
        log.log("mcp \(method) -> \(http.statusCode)")
        if http.statusCode == 401 || http.statusCode == 403 { throw HuddleError.unauthorized }
        if http.statusCode == 404, sid != nil {
            state.withLock { $0.sessionId = nil; $0.initialized = false }
            throw HuddleError.badResponse("session expired")
        }
        guard (200..<300).contains(http.statusCode) else { throw HuddleError.badResponse("HTTP \(http.statusCode)") }
        if expectSession, let s = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            state.withLock { $0.sessionId = s }
        }
        guard wantsResponse else { return .null }
        return try Self.decodeReply(data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    /// Plain JSON, or SSE: take the last `data:` event that parses as a JSON-RPC message.
    static func decodeReply(_ data: Data, contentType: String) throws -> JSON {
        if contentType.contains("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            var best: JSON?
            var buffer: [String] = []
            func flush() {
                if !buffer.isEmpty, let j = try? JSON.parse(buffer.joined(separator: "\n")),
                   !j["result"].isNull || !j["error"].isNull { best = j }
                buffer = []
            }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
                if line.hasPrefix("data:") { buffer.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                else if line.isEmpty { flush() }
            }
            flush()
            guard let best else { throw HuddleError.badResponse("empty event stream") }
            return best
        }
        do { return try JSON.parse(data) } catch { throw HuddleError.badResponse("not JSON") }
    }
}


public enum LoopbackSession {
    /// Public for the live probe: same hardened session (no proxy, cookies, redirects).
    public static func probe() -> URLSession { make(timeout: 15) }
    /// Ephemeral, proxy-free, cookie-free, redirect-refusing session for all loopback traffic.
    public static func make(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [:]
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
    }
}
