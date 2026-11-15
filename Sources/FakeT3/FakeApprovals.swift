import Foundation
import HuddleCore

/// The fake's side of inline approvals: `POST /oauth/token` (token exchange) and `/ws` (Effect RPC over JSON text frames),
/// both on the same port as `/mcp`, with the same shapes as observed on the real T3.
/// Not byte for byte: for one, the Failure frame omits `commandId`.
extension FakeT3Server {
    // Inspection for tests.
    public var wsUpgrades: Int { lock.lock(); defer { lock.unlock() }; return _wsUpgrades }
    public var wsFrames: [JSON] { lock.lock(); defer { lock.unlock() }; return _wsFrames }
    public var decisions: [(threadId: String, requestId: String, decision: String)] { lock.lock(); defer { lock.unlock() }; return _decisions }
    /// Token-exchange form fields, without the pairing code.
    public var exchangeRequests: [[String: String]] { lock.lock(); defer { lock.unlock() }; return _exchangeRequests }
    public var approvalTokenList: [String] { lock.lock(); defer { lock.unlock() }; return Array(approvalTokens.keys) }
    /// Simulates `t3 auth session revoke`.
    public func revokeApprovalTokens() { lock.lock(); approvalTokens = [:]; lock.unlock() }

    public static func encodeURIComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: POST /oauth/token

    func tokenExchange(_ req: HTTPRequest) -> HTTPResponse {
        let f = Self.form(req.body)
        lock.lock(); defer { lock.unlock() }
        _exchangeRequests.append(f.filter { $0.key != "subject_token" })
        guard f["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange",
              f["subject_token_type"] == "urn:t3:params:oauth:token-type:environment-bootstrap",
              f["requested_token_type"] == "urn:ietf:params:oauth:token-type:access_token",
              f["subject_token"] == options.pairingCode, !pairingUsed else {
            return HTTPResponse(status: 401, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"invalid_credential"}"#.utf8))
        }
        pairingUsed = true
        // Like T3: the session gets requested ∩ granted; no `scope` param means everything the code carries.
        let requested = f["scope"].map { Set($0.split(separator: " ").map(String.init)) }
        let granted = options.pairingScopes.filter { requested?.contains($0) ?? true }
        guard !granted.isEmpty else { return HTTPResponse(status: 400, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"invalid_scope"}"#.utf8)) }
        let tok = "ws-access-\(UUID().uuidString)"
        approvalTokens[tok] = Set(granted)
        let body: JSON = ["access_token": .string(tok), "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
                          "token_type": "Bearer", "expires_in": 2591999, "scope": .string(granted.joined(separator: " "))]
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body.data())
    }

    // MARK: GET /ws

    func webSocket(_ req: HTTPRequest) -> LoopbackHTTPServer.WebSocketDecision {
        lock.lock(); _wsUpgrades += 1; lock.unlock()
        let json = { (status: Int, body: String) in HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8)) }
        guard req.path.hasPrefix("/ws") else { return .reject(HTTPResponse(status: 404)) }
        guard Self.query(req.path)["orchestrationProtocol"] == "2" else {
            return .reject(json(426, #"{"code":"orchestration_protocol_incompatible","message":"Update this client to one that supports orchestration protocol 2.","orchestrationProtocolVersion":2}"#))
        }
        lock.lock(); let scopes = req.headers["authorization"].flatMap { h in h.hasPrefix("Bearer ") ? approvalTokens[String(h.dropFirst(7))] : nil }; lock.unlock()
        guard let scopes else { return .reject(json(401, #"{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"invalid_credential"}"#)) }
        return .accept(onText: { [weak self] text in self?.wsMessage(text, scopes: scopes) ?? [] })
    }

    /// What a decision does to the thread: the request resolves, the blocked command runs (accept) or fails (decline), the thread works on.
    static func applyDecision(_ t: inout FakeThread, itemIndex i: Int, decision: String) {
        t.items[i].status = "completed"
        t.permissionPending = false
        t.status = "running"
        if let c = t.items.lastIndex(where: { $0.type == "command_execution" && $0.status == "running" }) {
            t.items[c].status = decision == "accept" ? "completed" : "failed"
        }
        t.updatedAt = iso(Date())
    }

    /// For a second fake that only lists the thread (the demo's "this Mac" listing a linked machine's thread): same outcome, by request id.
    public func mirrorDecision(threadId: String, requestId: String, decision: String) {
        lock.lock(); defer { lock.unlock() }
        guard var t = threads[threadId],
              let i = t.items.firstIndex(where: { $0.type == "approval_request" && HuddleCore.ApprovalWire.requestId(fromItemId: $0.itemId) == requestId }) else { return }
        Self.applyDecision(&t, itemIndex: i, decision: decision)
        threads[threadId] = t
    }

    private func wsMessage(_ text: String, scopes: Set<String>) -> [String] {
        guard let m = try? JSON.parse(text) else { return [] }
        lock.lock(); _wsFrames.append(m); lock.unlock()
        if m["_tag"].string == "Ping" { return [#"{"_tag":"Pong"}"#] }
        guard m["_tag"].string == "Request", let id = m["id"].string else { return [] }
        func failure(_ message: String) -> [String] {
            [(["_tag": "Exit", "requestId": .string(id), "exit": ["_tag": "Failure", "cause": [["_tag": "Fail", "error": [
                "_tag": "OrchestrationV2DispatchCommandError", "commandType": "runtime-request.respond", "message": .string(message)]]]]] as JSON).text()]
        }
        if m["tag"].string == "peerLinks.list" {   // read-only; needs access:read like the real RPC
            guard scopes.contains("access:read") else { return failure("The authenticated token is missing required scope: access:read.") }
            lock.lock(); let urls = options.peerLinkURLs; lock.unlock()
            let links: [JSON] = urls.sorted { $0.key < $1.key }.map { id, u in
                ["environmentId": .string(id), "label": .string(options.environmentLabel + " peer"), "urls": .array(u.map { .string($0) }),
                 "status": "reachable", "access": "approval-required"]
            }
            return [(["_tag": "Exit", "requestId": .string(id), "exit": ["_tag": "Success", "value": ["links": .array(links)]]] as JSON).text()]
        }
        guard m["tag"].string == "orchestration.dispatchCommand", m["payload"]["type"].string == "runtime-request.respond",
              let threadId = m["payload"]["threadId"].string, let rid = m["payload"]["requestId"].string,
              let decision = m["payload"]["decision"].string, ["accept", "decline"].contains(decision) else {
            return failure("The fake only implements runtime-request.respond with accept or decline.")
        }
        guard scopes.contains("orchestration:operate") else { return failure("The authenticated token is missing required scope: orchestration:operate.") }
        lock.lock(); defer { lock.unlock() }
        guard var t = threads[threadId],
              let i = t.items.firstIndex(where: { $0.type == "approval_request" && HuddleCore.ApprovalWire.requestId(fromItemId: $0.itemId) == rid }) else {
            return failure("Runtime request \(rid) was not found.")
        }
        guard t.items[i].status == "waiting" else { return failure("Runtime request \(rid) is resolved.") }
        Self.applyDecision(&t, itemIndex: i, decision: decision)
        threads[threadId] = t
        _decisions.append((threadId, rid, decision))
        decisionObserver?(threadId, rid, decision)
        let seq = 842_000 + _decisions.count
        return [(["_tag": "Exit", "requestId": .string(id), "exit": ["_tag": "Success", "value": ["sequence": .number(Double(seq))]]] as JSON).text()]
    }
}
