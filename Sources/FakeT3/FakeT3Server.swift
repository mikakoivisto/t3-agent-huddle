import Foundation
import HuddleCore
import CryptoKit

/// Fake T3 MCP server speaking the *spec-described* tool shapes (SPEC §5, §7.2).
/// Everything about question/`answers` shape and permission visibility is ASSUMED (Q2, Q5).
/// Synthetic data only: no fixture here was captured from a real T3 thread.
public final class FakeT3Server: @unchecked Sendable {

    public struct FakeItem: Sendable {
        public var position: Int
        public var itemId: String
        public var type: String          // command_execution | dynamic_tool | reasoning | assistant_message
        public var status: String        // completed | running
        public var title: String?
        public var text: String
        public var runId = "run_1"
        public init(position: Int, itemId: String, type: String, status: String, title: String? = nil, text: String, runId: String = "run_1") {
            self.position = position; self.itemId = itemId; self.type = type; self.status = status
            self.title = title; self.text = text; self.runId = runId
        }
    }
    public struct FakeQuestion: Sendable {
        public var requestId: String
        public var header: String
        public var question: String
        public var options: [String]
        public var multiSelect = false
        /// More questions in the same request (T3 asks up to four at once), after the first ("q0").
        public var more: [Part] = []
        public struct Part: Sendable {
            public var id: String, header: String, question: String, options: [(label: String, description: String)]
            public init(id: String, header: String, question: String, options: [(label: String, description: String)]) {
                self.id = id; self.header = header; self.question = question; self.options = options
            }
        }
        public init(requestId: String, header: String, question: String, options: [String], multiSelect: Bool = false, more: [Part] = []) {
            self.requestId = requestId; self.header = header; self.question = question; self.options = options; self.multiSelect = multiSelect
            self.more = more
        }
    }
    public struct FakeThread: Sendable {
        public var id: String
        public var projectId = "proj_demo"
        public var title: String
        public var status: String
        public var parentThreadId: String?
        public var settled = false
        public var items: [FakeItem] = []
        public var questions: [FakeQuestion] = []
        /// An approval: counts in `pendingRequestCount`, is NOT listed by `t3_pending_request list` (§5.4).
        public var permissionPending = false
        /// Ids of background tasks the agent waits on (T3 0.1.11's `pendingBackgroundTasks`, all `awaited`). T3 then reports
        /// the thread as `waiting` with no active run. `nil` omits the field, like T3 before 0.1.11.
        public var awaitedTasks: [String]? = []
        public var updatedAt = FakeT3Server.iso(Date())
        public var environmentId = "env_local"
        public var latestRunId = "run_1"
        public var providerInstanceId = "claudeAgent"
        public var model = "claude-sonnet-5-5"
        /// `nil` like the live pi threads: the executing model is unknown.
        public var executedModel: String?
        public var branch: String?
        public var runningFor: TimeInterval = 60
        /// Fixed when the thread is added (now − `runningFor`), so the run time keeps counting across reads instead of resetting.
        public var runStart: Date?
    }
    public struct Call: Sendable { public var tool: String; public var args: JSON }

    public struct Options: Sendable {
        public var token = "fake-token"
        public var omitTools: Set<String> = []
        public var dropArguments: [String: String] = [:]   // tool → argument removed from its schema
        public var sse = false
        public var structured = false
        public var failFirstToolsList = false
        public enum QuestionReadShape: Sendable { case standard, flat, garbled }
        public var questionReadShape = QuestionReadShape.standard
        public var pendingListFails = false
        /// The real T3 rejected a CLI-issued bearer on /mcp (Q4). `false` mimics that: only OAuth-issued tokens work.
        public var acceptStaticToken = true
        /// Settings → Labs → "Linked environments". Off (default) = any `environmentId` is `capability_denied`, as on the real machine.
        public var linkedEnvironments = false
        public var linkedEnvironmentLabels: [String: String] = ["env_remote": "Studio Mac"]
        /// What `t3_environment_read` calls this machine (the demo plays "Mika’s MacBook Pro" here).
        public var localEnvironmentLabel = "Mika’s Mac mini"
        /// `t3_project_read` titles by project id; anything else is "Demo project".
        public var projectTitles: [String: String] = [:]
        /// Machines already linked to this MCP client. Live T3 starts with none (`links: []`, "not linked yet").
        public var preLinked = true
        /// Simulates the user approving the card T3 shows after `t3_environment_link`.
        public var approveLinkRequests = true
        /// Inline approvals (opt-in): the pairing code the fake's `POST /oauth/token` accepts (single use), and the scopes that code carries.
        /// Broad on purpose, like a bare `t3 auth pairing create`: the client must down-scope with `scope=`.
        public var pairingCode = "fake-pairing-code"
        public var pairingScopes = ["orchestration:read", "orchestration:operate", "access:read", "access:write", "filesystem:write"]
        /// What `GET /.well-known/t3/environment` answers: the id of the machine this fake plays (a second fake plays "the other machine").
        public var environmentId = "env_local"
        public var environmentLabel = "Fake machine"
        /// The linked machines' addresses `peerLinks.list` returns (environment id → urls), like T3's `PeerLink.urls`.
        public var peerLinkURLs: [String: [String]] = [:]
        /// `t3_thread_send` fails with a tool error (spec 13 failure path).
        public var failSends = false
        /// Live T3 (2026-11-15): a thread whose runtime mode is broader than the client's sign-in refuses sends and answers with
        /// `runtime_mode_escalation_denied`. On here, every send and respond is refused that way.
        public var modeEscalationDenied = false
        /// Live T3 (2026-11-15): a send to a thread on a LINKED machine, through this Mac's MCP, is refused with `capability_denied`.
        public var linkedSendDenied = false
        public init() {}
    }

    let lock = NSLock()
    var threads: [String: FakeThread] = [:]
    private var order: [String] = []
    private var _calls: [Call] = []
    private var _answers: [(requestId: String, answers: JSON)] = []
    public struct Send: Sendable, Equatable { public var threadId: String; public var message: String; public var mode: String?
        public var clientRequestId: String?; public var environmentId: String?; public var freshContext: Bool? }
    private var _sends: [Send] = []
    private var deliveredRequestIds: Set<String> = []
    /// Messages T3 accepted (a repeat of a `clientRequestId` is dropped, as T3's own dedupe would).
    public var sends: [Send] { lock.lock(); defer { lock.unlock() }; return _sends }
    public struct Launch: Sendable { public var args: JSON; public var threadId: String }
    private var _launches: [Launch] = []
    private var launchedIds: [String: String] = [:]
    /// Threads started through `t3_thread_launch` (a repeat of a `clientRequestId` returns the first thread, as T3 would).
    public var launches: [Launch] { lock.lock(); defer { lock.unlock() }; return _launches }
    private var _requestCount = 0
    private var issuedTokens: Set<String> = []
    private var linkedIds: Set<String>?
    private var clients: [String: [String]] = [:]            // client_id → redirect_uris
    private var codes: [String: (client: String, redirect: String, challenge: String)] = [:]
    /// Inline approvals bookkeeping (see FakeApprovals.swift).
    var approvalTokens: [String: Set<String>] = [:]          // bearer → scopes
    var pairingUsed = false
    var _wsUpgrades = 0
    var _wsFrames: [JSON] = []
    var _decisions: [(threadId: String, requestId: String, decision: String)] = []
    var _exchangeRequests: [[String: String]] = []
    /// Called (with the lock held) after a decision over `/ws` resolved a request. The demo mirrors it to the other fake,
    /// the one that plays this machine's thread list.
    public var decisionObserver: (@Sendable (_ threadId: String, _ requestId: String, _ decision: String) -> Void)?
    public private(set) var registrations = 0
    public private(set) var tokenRequests: [[String: String]] = []
    public var issuedTokenList: [String] { lock.lock(); defer { lock.unlock() }; return Array(issuedTokens) }
    var options: Options
    private var server: LoopbackHTTPServer?
    private var ticker: Task<Void, Never>?
    public private(set) var port: UInt16 = 0

    public init(options: Options = Options()) { self.options = options }

    public var url: URL { URL(string: "http://127.0.0.1:\(port)/mcp")! }
    public var token: String { options.token }

    public func start(port: UInt16 = 0) async throws {
        let s = LoopbackHTTPServer(handler: { [weak self] req in self?.handle(req) ?? HTTPResponse(status: 500) },
                                   webSocket: { [weak self] req in self?.webSocket(req) ?? .reject(HTTPResponse(status: 500)) })
        self.port = try await s.start(port: port)
        server = s
    }
    public func stop() { ticker?.cancel(); ticker = nil; server?.stop(); server = nil }

    // MARK: Mutation / inspection (tests and the demo driver)

    public func mutate(_ f: (inout [String: FakeThread]) -> Void) {
        lock.lock(); f(&threads); lock.unlock()
    }
    public func add(_ t: FakeThread) {
        var t = t; if t.runStart == nil { t.runStart = Date().addingTimeInterval(-t.runningFor) }
        lock.lock(); threads[t.id] = t; if !order.contains(t.id) { order.append(t.id) }; lock.unlock()
    }
    public func update(_ id: String, _ f: (inout FakeThread) -> Void) {
        lock.lock()
        if var t = threads[id] { f(&t); t.updatedAt = Self.iso(Date()); threads[id] = t }
        lock.unlock()
    }
    public func thread(_ id: String) -> FakeThread? { lock.lock(); defer { lock.unlock() }; return threads[id] }
    public var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    public var answers: [(requestId: String, answers: JSON)] { lock.lock(); defer { lock.unlock() }; return _answers }
    public var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }
    public func setOptions(_ f: (inout Options) -> Void) { lock.lock(); f(&options); lock.unlock() }

    public func startTicker(interval: TimeInterval = 1, _ tick: @escaping @Sendable (FakeT3Server) -> Void) {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
                guard let self else { return }
                tick(self)
            }
        }
    }

    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    // MARK: HTTP

    private func handle(_ req: HTTPRequest) -> HTTPResponse {
        lock.lock(); _requestCount += 1; let opts = options; lock.unlock()
        let base = "http://127.0.0.1:\(port)"
        if req.method == "GET", req.path.hasPrefix("/.well-known/oauth-protected-resource") {
            return json(200, ["resource": .string(base + "/mcp"), "authorization_servers": [.string(base)],
                              "scopes_supported": ["orchestration:read", "orchestration:operate"],
                              "bearer_methods_supported": ["header"], "resource_name": "T3 Code (fake)"])
        }
        if req.method == "GET", req.path == "/.well-known/t3/environment" {   // unauthenticated, like the real descriptor
            return json(200, ["environmentId": .string(opts.environmentId), "label": .string(opts.environmentLabel), "serverVersion": "0.1.9",
                              "orchestrationProtocolVersion": 2])
        }
        if let r = oauth(req, base: base) { return r }
        guard req.path == "/mcp" else { return HTTPResponse(status: 404) }
        lock.lock(); let bearer = req.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: ""); let issued = issuedTokens; lock.unlock()
        guard let bearer, (opts.acceptStaticToken && bearer == opts.token) || issued.contains(bearer) else {
            return HTTPResponse(status: 401, headers: [
                "Content-Type": "application/json",
                "WWW-Authenticate": "Bearer resource_metadata=\"\(base)/.well-known/oauth-protected-resource/mcp\""],
                body: Data(#"{"error":"invalid_mcp_credential","message":"A valid T3 Code MCP credential is required."}"#.utf8))
        }
        guard req.method == "POST", let msg = try? JSON.parse(req.body) else { return HTTPResponse(status: 404) }
        let method = msg["method"].string ?? ""
        let id = msg["id"]
        if id.isNull { return HTTPResponse(status: 202) }   // notification
        let result: JSON
        var extra: [String: String] = [:]
        switch method {
        case "initialize":
            extra["Mcp-Session-Id"] = "fake-session-1"
            result = ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "t3-code-fake", "version": "0.0.0"]]
        case "tools/list":
            result = toolsList(opts)
        case "tools/call":
            result = callTool(msg["params"]["name"].string ?? "", msg["params"]["arguments"], opts)
        default:
            return json(200, ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]], extra: extra)
        }
        return rpc(id: id, result: result, sse: opts.sse, extra: extra)
    }

    // MARK: OAuth (fake authorization server, PKCE S256 verified)

    private func oauth(_ req: HTTPRequest, base: String) -> HTTPResponse? {
        let path = req.path.components(separatedBy: "?").first ?? req.path
        switch (req.method, path) {
        case ("GET", "/.well-known/oauth-authorization-server"):
            return json(200, ["issuer": .string(base), "authorization_endpoint": .string(base + "/oauth/mcp/authorize"),
                              "token_endpoint": .string(base + "/oauth/mcp/token"),
                              "registration_endpoint": .string(base + "/oauth/mcp/register"),
                              "response_types_supported": ["code"], "grant_types_supported": ["authorization_code"],
                              "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"],
                              "authorization_response_iss_parameter_supported": true])
        case ("POST", "/oauth/token"): return tokenExchange(req)
        case ("POST", "/oauth/mcp/register"):
            guard let j = try? JSON.parse(req.body), let uris = j["redirect_uris"].array?.compactMap(\.string), !uris.isEmpty else {
                return json(400, ["error": "invalid_client_metadata"]) }
            lock.lock(); registrations += 1; let id = "client-\(registrations)"; clients[id] = uris; lock.unlock()
            return json(201, ["client_id": .string(id), "redirect_uris": .array(uris.map { .string($0) }), "token_endpoint_auth_method": "none"])
        case ("GET", "/oauth/mcp/authorize"):
            let q = Self.query(req.path)
            guard let cid = q["client_id"], let redirect = q["redirect_uri"], let challenge = q["code_challenge"],
                  q["code_challenge_method"] == "S256", q["response_type"] == "code" else { return json(400, ["error": "invalid_request"]) }
            lock.lock(); let ok = clients[cid]?.contains(redirect) == true
            let code = "code-\(UUID().uuidString)"; if ok { codes[code] = (cid, redirect, challenge) }; lock.unlock()
            guard ok else { return json(400, ["error": "invalid_redirect_uri"]) }
            var loc = URLComponents(string: redirect)!
            loc.queryItems = [.init(name: "code", value: code), .init(name: "state", value: q["state"]), .init(name: "iss", value: base)]
            return HTTPResponse(status: 302, headers: ["Location": loc.url!.absoluteString])
        case ("POST", "/oauth/mcp/token"):
            let f = Self.form(req.body)
            lock.lock(); tokenRequests.append(f.filter { $0.key != "code_verifier" }); let entry = f["code"].flatMap { codes[$0] }
            if let c = f["code"] { codes[c] = nil }   // single use
            lock.unlock()
            guard let e = entry, f["grant_type"] == "authorization_code", f["client_id"] == e.client,
                  f["redirect_uri"] == e.redirect, let v = f["code_verifier"],
                  OAuthClient.challenge(for: v) == e.challenge else { return json(400, ["error": "invalid_grant"]) }
            let tok = "oauth-access-\(UUID().uuidString)"
            lock.lock(); issuedTokens.insert(tok); lock.unlock()
            return json(200, ["access_token": .string(tok), "token_type": "Bearer", "expires_in": 3600])
        default: return nil
        }
    }

    public static func query(_ path: String) -> [String: String] {
        var out: [String: String] = [:]
        for i in URLComponents(string: "http://x" + path)?.queryItems ?? [] { out[i.name] = i.value ?? "" }
        return out
    }
    public static func form(_ body: Data) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return out
    }

    private func rpc(id: JSON, result: JSON, sse: Bool, extra: [String: String]) -> HTTPResponse {
        let body: JSON = ["jsonrpc": "2.0", "id": id, "result": result]
        if sse {
            var h = extra; h["Content-Type"] = "text/event-stream"
            return HTTPResponse(status: 200, headers: h,
                                body: Data("event: message\ndata: \(body.text())\n\n".utf8))
        }
        return json(200, body, extra: extra)
    }

    private func json(_ status: Int, _ body: JSON, extra: [String: String] = [:]) -> HTTPResponse {
        var h = extra; h["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: h, body: body.data())
    }

    // MARK: Tools

    private static let schemas: [String: [String]] = [
        "t3_thread_list": ["allProjects", "statuses", "settled", "limit", "cursor", "includeSubagents", "projectId", "environmentId"],
        "t3_thread_read": ["threadId", "view", "afterPosition", "limit", "maxCharsPerItem", "itemId", "textOffset", "runLimit", "environmentId"],
        "t3_pending_request": ["action", "threadId", "requestId", "answers", "environmentId"],
        "t3_project_read": ["projectId", "environmentId"],
        "t3_thread_organize": ["action", "threadId"],
        "t3_environment_read": ["environmentId"],
        "t3_environment_links": [],
        "t3_environment_link": ["clientRequestId", "environmentId", "hint", "reason", "requestedAccess", "url"],
        // Written messages (spec 13): T3's published arguments. The client may send only queue or steer.
        "t3_thread_send": ["threadId", "message", "mode", "clientRequestId", "freshContext", "environmentId"],
        // Tools the huddle must never call (§7.2); present so a bug would be observable.
        // Spec 16: starting a thread, the project list and the model catalog.
        "t3_thread_launch": ["title", "message", "projectId", "scratch", "environmentId", "modelSelection", "runtimeMode", "interactionMode", "workspaceStrategy", "clientRequestId"],
        "t3_project_list": ["cursor", "environmentId", "limit"],
        "orchestrator_capabilities": ["environmentId", "search"],
        "t3_thread_interrupt": ["threadId"],
    ]

    private func toolsList(_ o: Options) -> JSON {
        let tools: [JSON] = Self.schemas.keys.sorted().filter { !o.omitTools.contains($0) && (!$0.hasPrefix("t3_environment_link") || o.linkedEnvironments) }.map { name in
            var props: [String: JSON] = [:]
            for a in Self.schemas[name]! where o.dropArguments[name] != a { props[a] = ["type": "string"] }
            return ["name": .string(name), "description": .string("fake \(name)"), "inputSchema": ["type": "object", "properties": .object(props)]]
        }
        return ["tools": .array(tools)]
    }

    private func callTool(_ name: String, _ args: JSON, _ o: Options) -> JSON {
        lock.lock(); _calls.append(Call(tool: name, args: args)); lock.unlock()
        do {
            let payload: JSON
            if !args["environmentId"].isNull && !o.linkedEnvironments {
                throw FakeToolError(#"{"_tag":"OrchestratorMcpFailure","code":"capability_denied","message":"Linked environments is off on this machine, so no tool can act on another machine. Leave out environmentId to work here; the user can turn it on in Settings → Labs."}"#)
            }
            if let e = args["environmentId"].string, name != "t3_environment_link" {
                lock.lock(); let linked = linkedIds ?? (o.preLinked ? Set(o.linkedEnvironmentLabels.keys) : []); lock.unlock()
                if e != o.environmentId && !linked.contains(e) {
                    throw FakeToolError(#"{"_tag":"OrchestratorMcpFailure","code":"not_linked","message":"That environment is not linked."}"#)
                }
            }
            switch name {
            case "t3_environment_link":
                lock.lock()
                if o.approveLinkRequests { linkedIds = (linkedIds ?? (o.preLinked ? Set(o.linkedEnvironmentLabels.keys) : [])).union(o.linkedEnvironmentLabels.keys) }
                lock.unlock()
                payload = ["status": "pending"]
            case "t3_environment_read":
                let e = args["environmentId"].string
                payload = ["environmentId": .string(e ?? o.environmentId), "label": .string(e.flatMap { o.linkedEnvironmentLabels[$0] } ?? o.localEnvironmentLabel), "serverVersion": "0.1.9"]
            case "t3_environment_links":
                lock.lock(); let linked = linkedIds ?? (o.preLinked ? Set(o.linkedEnvironmentLabels.keys) : []); lock.unlock()
                let rows: [JSON] = linked.sorted().map { ["environmentId": .string($0), "label": .string(o.linkedEnvironmentLabels[$0] ?? $0)] }
                var out: [String: JSON] = ["links": .array(rows), "environmentId": .string(o.environmentId)]   // live shape (L8)
                if rows.isEmpty { out["notListed"] = "Not listed: not linked yet. Call t3_environment_link with a hint from the user's words." }
                payload = .object(out)
            case "t3_thread_list": payload = threadList(args)
            case "t3_thread_read": payload = try threadRead(args)
            case "t3_pending_request": payload = try pending(args, o)
            case "t3_project_read":
                payload = ["project": ["projectId": args["projectId"], "title": .string(args["projectId"].string.flatMap { o.projectTitles[$0] } ?? "Demo project"), "path": "/tmp/fake-demo-project"]]
            case "t3_project_list":
                lock.lock()
                var ids = Set(threads.values.filter { $0.environmentId == (args["environmentId"].string ?? o.environmentId) }.map(\.projectId))
                ids.formUnion(o.projectTitles.keys)
                lock.unlock()
                let rows: [JSON] = ids.sorted().map { id in ["id": .string(id), "title": .string(o.projectTitles[id] ?? "Demo project"), "updatedAt": "2026-11-15T10:00:00.000Z", "archivedAt": .null, "deletedAt": .null] }
                payload = ["projects": .array(rows), "nextCursor": .null]
            case "orchestrator_capabilities":
                payload = ["providers": [
                    ["providerInstanceId": "claudeAgent", "displayName": "Claude", "constraints": [],
                     "models": [["id": "claude-opus-5-5", "label": "Claude Opus 5.5"], ["id": "claude-sonnet-5-5", "label": "Claude Sonnet 5.5"]]],
                    ["providerInstanceId": "codex", "displayName": "Codex", "constraints": [], "models": [["id": "gpt-6.1-sol"]]],
                    ["providerInstanceId": "pi", "displayName": "Pi", "constraints": [], "runtimeModes": ["approval-required", "auto-accept-edits", "full-access"],
                     "models": [["id": "ollama/qwen3.8-pi:latest", "label": "Qwen3.8-27B · Ollama"]]],
                    ["providerInstanceId": "opencode", "displayName": "OpenCode", "constraints": ["Provider instance is disabled."], "models": []],
                ]]
            case "t3_thread_launch":
                guard !o.modeEscalationDenied else { throw FakeToolError(#"{"_tag":"OrchestratorMcpFailure","code":"runtime_mode_escalation_denied","message":"Child runtime mode auto is broader than the caller's approval-required."}"#) }
                guard let title = args["title"].string, !title.isEmpty else { throw FakeToolError("title is required") }
                let rid = args["clientRequestId"].string
                lock.lock()
                if let rid, let existing = launchedIds[rid] { lock.unlock(); payload = ["threadId": .string(existing), "status": "preparing"]; break }
                let id = "thr_launched_\(_launches.count + 1)"
                if let rid { launchedIds[rid] = id }
                _launches.append(Launch(args: args, threadId: id))
                lock.unlock()
                add(FakeThread(id: id, title: title, status: "running", environmentId: args["environmentId"].string ?? o.environmentId,
                               providerInstanceId: args["modelSelection"]["instanceId"].string ?? "claudeAgent",
                               model: args["modelSelection"]["model"].string ?? "claude-sonnet-5-5",
                               projectId: args["projectId"].string ?? "proj_scratch"))
                payload = ["threadId": .string(id), "status": "preparing"]
            case "t3_thread_send":
                guard !o.failSends else { throw FakeToolError("fake send failure") }
                if o.linkedSendDenied, args["environmentId"].string != nil {
                    throw FakeToolError(#"{"_tag":"OrchestratorMcpFailure","code":"capability_denied","message":"This work was started from T3 Code - Fake machine."}"#)
                }
                guard !o.modeEscalationDenied else { throw FakeToolError(#"{"_tag":"OrchestratorMcpFailure","code":"runtime_mode_escalation_denied","message":"Child runtime mode auto is broader than the caller's approval-required."}"#) }
                guard let id = args["threadId"].string, let message = args["message"].string else { throw FakeToolError("threadId and message are required") }
                lock.lock(); let status = threads[id]?.status; lock.unlock()
                guard let status else { throw FakeToolError("thread not found") }
                let mode = args["mode"].string
                if mode == "steer" && status != "running" { throw FakeToolError("No active turn to steer.") }
                let rid = args["clientRequestId"].string
                lock.lock()
                let repeated = rid.map { deliveredRequestIds.contains($0) } ?? false
                if !repeated {
                    if let rid { deliveredRequestIds.insert(rid) }
                    _sends.append(Send(threadId: id, message: message, mode: mode, clientRequestId: rid,
                                       environmentId: args["environmentId"].string, freshContext: args["freshContext"].bool))
                }
                lock.unlock()
                if mode != "steer" && !["running", "waiting", "starting", "queued", "preparing"].contains(status) {
                    update(id) { $0.status = "running"; $0.updatedAt = FakeT3Server.iso(Date()) }   // a new turn starts
                }
                payload = ["threadId": .string(id), "mode": .string(mode ?? "auto"), "accepted": true, "duplicate": .bool(repeated)]
            case "t3_thread_organize":
                if args["action"].string == "settle", let id = args["threadId"].string { update(id) { $0.settled = true } }
                payload = ["ok": true]
            default:
                throw FakeToolError("tool \(name) is not available in the fake")
            }
            var r: [String: JSON] = ["content": [["type": "text", "text": .string(payload.text())]]]
            if o.structured { r["structuredContent"] = payload }
            return .object(r)
        } catch let e as FakeToolError {
            return ["isError": true, "content": [["type": "text", "text": .string(e.message)]]]
        } catch { return ["isError": true, "content": [["type": "text", "text": "error"]]] }
    }

    struct FakeToolError: Error { var message: String; init(_ m: String) { message = m } }

    private func pendingCount(_ t: FakeThread) -> Int { t.questions.count + (t.permissionPending ? 1 : 0) }

    private func summary(_ t: FakeThread) -> JSON {
        var o: [String: JSON] = [
            "threadId": .string(t.id), "projectId": .string(t.projectId), "title": .string(t.title),
            // live: this Mac's T3 returns a bare URL, a linked machine's returns a markdown link
            "link": .string(t.environmentId == options.environmentId ? "https://app.t3.codes/threads/\(t.environmentId)/\(t.id)"
                                      : "[\(t.title)](t3-thread://v2/\(t.environmentId)/\(t.id))"),
            "environmentId": .string(t.environmentId), "status": .string(t.status),
            "providerInstanceId": .string(t.providerInstanceId), "branch": t.branch.map { .string($0) } ?? .null,
            "model": .string(t.model), "settled": .bool(t.settled), "snoozed": false,
            "itemCount": .number(Double(t.items.count)), "updatedAt": .string(t.updatedAt),
        ]
        if let p = t.parentThreadId { o["parentThreadId"] = .string(p); o["relationshipToParent"] = "subagent" }
        if let tasks = t.awaitedTasks {
            o["pendingBackgroundTasks"] = .array(tasks.map { .object(["taskId": .string($0), "kind": "command", "description": "Background task", "awaited": true]) })
        }
        return .object(o)
    }

    private func threadList(_ args: JSON) -> JSON {
        lock.lock(); defer { lock.unlock() }
        let statuses = Set((args["statuses"].array ?? []).compactMap(\.string))
        let settled = args["settled"].bool
        let limit = min(args["limit"].int ?? 25, 100)
        let start = args["cursor"].int ?? 0
        // Mimic the real quirk: subagents come back even without includeSubagents (§5.3).
        let env = args["environmentId"].string ?? options.environmentId
        let rows = order.compactMap { threads[$0] }
            .filter { $0.environmentId == env }
            .filter { statuses.isEmpty || statuses.contains($0.status) }
            .filter { settled == nil || $0.settled == settled! }
            .sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }   // deterministic on timestamp ties
        let page = Array(rows.dropFirst(start).prefix(limit))
        var out: [String: JSON] = ["threads": .array(page.map(summary))]
        // live T3 sends a numeric cursor
        if start + limit < rows.count { out["nextCursor"] = .number(Double(start + limit)) }
        return .object(out)
    }

    private func threadRead(_ args: JSON) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        guard let id = args["threadId"].string, let t = threads[id] else { throw FakeToolError("thread not found") }
        let maxChars = args["maxCharsPerItem"].int ?? 400
        var thread = summary(t).object ?? [:]
        thread["pendingRequestCount"] = .number(Double(pendingCount(t)))
        let backgroundOnly = t.status == "waiting" && !(t.awaitedTasks ?? []).isEmpty && pendingCount(t) == 0
        thread["activeRunId"] = (t.status == "running" || t.status == "waiting") && !backgroundOnly ? "run_1" : .null
        thread["runCount"] = 1
        thread["latestRunId"] = .string(t.latestRunId)

        if let itemId = args["itemId"].string {   // long-text continuation
            guard let item = t.items.first(where: { $0.itemId == itemId }) else { throw FakeToolError("item not found") }
            let off = args["textOffset"].int ?? 0
            let chars = Array(item.text)
            let slice = String(chars.dropFirst(off).prefix(maxChars))
            let more = off + maxChars < chars.count
            var j = itemJSON(item, text: slice)
            j["truncated"] = .bool(more)
            if more { j["nextTextOffset"] = .number(Double(off + maxChars)) }
            return ["thread": .object(thread), "items": [.object(j)]]
        }
        if let a = args["afterPosition"].int, a < 0 {   // live T3: "Expected a value greater than or equal to 0 at [afterPosition]"
            throw FakeToolError("Invalid parameters for tool 't3_thread_read': Expected a value greater than or equal to 0\n  at [\"afterPosition\"]")
        }
        let after = args["afterPosition"].int ?? -1
        let limit = args["limit"].int ?? 30
        let items = t.items.filter { $0.position > after && (args["runLimit"].int != 1 || $0.runId == t.latestRunId) }
            .sorted { $0.position < $1.position }
        let page = items.prefix(limit)
        let jsonItems: [JSON] = page.map { it in
            let chars = Array(it.text)
            var j = itemJSON(it, text: String(chars.prefix(maxChars)))
            if chars.count > maxChars { j["truncated"] = true; j["nextTextOffset"] = .number(Double(maxChars)) }
            return .object(j)
        }
        let active = t.status == "running" || t.status == "waiting"
        let started = t.runStart ?? Date().addingTimeInterval(-t.runningFor)
        let run: [String: JSON] = ["ordinal": 1, "runId": .string(t.latestRunId), "status": .string(active ? "running" : t.status),
                                   "startedAt": .string(Self.iso(started)), "model": .string(t.model),
                                   "completedAt": active ? .null : .string(Self.iso(started.addingTimeInterval(min(t.runningFor, 90)))),
                                   "executedModel": t.executedModel.map { .string($0) } ?? .null]
        return ["thread": .object(thread), "items": .array(jsonItems), "hasMore": .bool(items.count > limit),
                "nextPosition": .number(Double(page.last?.position ?? after)), "recentRuns": [.object(run)]]
    }

    private func itemJSON(_ it: FakeItem, text: String) -> [String: JSON] {
        var j: [String: JSON] = ["position": .number(Double(it.position)), "itemId": .string(it.itemId),
                                 "type": .string(it.type), "status": .string(it.status),
                                 "text": .string(text), "runId": .string(it.runId), "updatedAt": .string(Self.iso(Date()))]
        if let t = it.title { j["title"] = .string(t) }
        return j
    }

    private func pending(_ args: JSON, _ o: Options) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        guard let id = args["threadId"].string, let t = threads[id] else { throw FakeToolError("thread not found") }
        switch args["action"].string {
        case "list":   // approvals are not listed (§5.4)
            if o.pendingListFails { throw FakeToolError("pending request listing unavailable") }
            return ["requestIds": .array(t.questions.map { .string($0.requestId) })]   // live shape (L6)
        case "read":
            guard let q = t.questions.first(where: { $0.requestId == args["requestId"].string }) else { throw FakeToolError("request not found") }
            switch o.questionReadShape {
            case .garbled: return ["unexpected": "shape"]
            case .flat:    // alternate shape: no `questions` array, plain-string options
                return ["requestId": .string(q.requestId), "header": .string(q.header), "question": .string(q.question),
                        "options": .array(q.options.map { .string($0) })]
            case .standard: break
            }
            let first: JSON = ["id": "q0", "header": .string(q.header), "question": .string(q.question),
                               "multiSelect": .bool(q.multiSelect), "options": .array(q.options.map { ["label": .string($0)] })]
            let rest: [JSON] = q.more.map { p in
                ["id": .string(p.id), "header": .string(p.header), "question": .string(p.question), "multiSelect": false,
                 "options": .array(p.options.map { ["label": .string($0.label), "description": .string($0.description)] })]
            }
            return ["requestId": .string(q.requestId), "questions": .array([first] + rest)]
        case "respond":
            if o.modeEscalationDenied { throw FakeToolError(#"{"_tag":"OrchestratorMcpFailure","code":"runtime_mode_escalation_denied","message":"Child runtime mode auto is broader than the caller's approval-required."}"#) }
            guard let rid = args["requestId"].string else { throw FakeToolError("requestId required") }
            guard t.questions.contains(where: { $0.requestId == rid }) else {
                throw FakeToolError("cannot approve a permission request; only user questions can be answered")
            }
            _answers.append((rid, args["answers"]))
            var nt = t; nt.questions.removeAll { $0.requestId == rid }
            nt.status = nt.permissionPending ? "waiting" : "running"; nt.updatedAt = Self.iso(Date())
            threads[id] = nt
            return ["ok": true]
        default: throw FakeToolError("unknown action")
        }
    }
}
