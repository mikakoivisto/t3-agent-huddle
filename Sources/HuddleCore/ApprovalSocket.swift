import Foundation

// Inline Allow / Deny for tool approvals — OPT-IN.
//
// T3's MCP cannot decide an approval. The first-party apps use T3's internal WebSocket RPC, which accepts a normal
// (non-MCP) session. This file is the ONLY place that speaks it, and it can send exactly one command:
// `runtime-request.respond` with `decision` accept | decline. Nothing here subscribes, reads or lists.

/// The only two decisions Agent Huddle ever sends. `acceptForSession`, `acceptAlways`, `cancel` and `feedback` are never built.
public enum ApprovalDecision: String, Sendable, CaseIterable {
    case accept, decline
}

/// Wire facts (all observed live). Pure functions so tests can pin the exact bytes.
public enum ApprovalWire {
    public static let rpcTag = "orchestration.dispatchCommand"
    public static let commandType = "runtime-request.respond"
    public static let itemPrefix = "turn-item:runtime-request:"

    /// `turn-item:runtime-request:<encodeURIComponent(requestId)>` → the exact request id (decoded once, never twice).
    public static func requestId(fromItemId itemId: String) -> String? {
        guard itemId.hasPrefix(itemPrefix) else { return nil }
        let tail = String(itemId.dropFirst(itemPrefix.count))
        guard !tail.isEmpty, let decoded = tail.removingPercentEncoding, !decoded.isEmpty else { return nil }
        return decoded
    }

    /// The item id T3 gives the approval of `requestId` (the inverse of `requestId(fromItemId:)`; `encodeURIComponent`'s unreserved set).
    public static func itemId(forRequestId requestId: String) -> String {
        var allowed = CharacterSet.asciiAlphanumerics; allowed.insert(charactersIn: "-_.!~*'()")
        return itemPrefix + (requestId.addingPercentEncoding(withAllowedCharacters: allowed) ?? requestId)
    }

    /// The one client frame. There is deliberately no other builder in this module.
    public static func respondFrame(rpcId: String, commandId: String, threadId: String, requestId: String,
                                    decision: ApprovalDecision) -> String {
        let frame: JSON = [
            "_tag": "Request", "id": .string(rpcId), "tag": .string(rpcTag), "headers": [],
            "payload": [
                "type": .string(commandType), "commandId": .string(commandId),
                "threadId": .string(threadId), "requestId": .string(requestId),
                "decision": .string(decision.rawValue),
            ],
        ]
        return frame.text()
    }

    public enum Reply: Equatable { case success(sequence: Int?), failure(String), other }

    /// Reads one server frame for our request id. Anything that is not our `Exit` is `.other` (Pong, Chunk, …).
    public static func parseReply(_ text: String, rpcId: String, requestId: String) -> Reply {
        guard let j = try? JSON.parse(text), j["_tag"].string == "Exit", j["requestId"].string == rpcId else { return .other }
        let exit = j["exit"]
        if exit["_tag"].string == "Success" { return .success(sequence: exit["value"]["sequence"].int) }
        var message = "T3 Code refused the decision."
        for c in exit["cause"].array ?? [] {
            if let m = c["error"]["message"].string ?? c["error"]["detail"].string ?? c["defect"].string ?? c["message"].string { message = m; break }
        }
        // The request id is long and meaningless to a person; keep the sentence ("… is resolved.", "… was not found.").
        message = message.replacingOccurrences(of: requestId, with: "this request")
        return .failure(String(message.prefix(160)))
    }
}

/// One connection per click: connect, send the single frame, wait for the matching `Exit`, close.
public final class ApprovalSocket: @unchecked Sendable {
    private let wsURL: URL
    private let token: String
    private let timeout: TimeInterval
    private let isRemote: Bool

    /// `origin` is T3's http origin (the MCP URL works too). It goes through `LoopbackGuard`; only then is the `ws://` URL derived.
    public init(origin: URL, token: String, log: HuddleLog = HuddleLog(sink: { _ in }), timeout: TimeInterval = 15) throws {
        try LoopbackGuard.validate(origin)
        var c = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        c.scheme = "ws"; c.path = "/ws"; c.query = nil
        c.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        guard let url = c.url else { throw HuddleError.nonLoopback(origin.absoluteString) }
        wsURL = url; self.token = token; self.timeout = timeout; isRemote = false
        log.register(secret: token)
    }

    /// Another machine. Takes a `VerifiedRemoteOrigin`, so it cannot be built for an address
    /// that was not first checked against the linked machine; the origin policy already made it https. wss, system trust, no redirects.
    public init(remote verified: VerifiedRemoteOrigin, token: String, log: HuddleLog = HuddleLog(sink: { _ in }), timeout: TimeInterval = 15) throws {
        guard let url = verified.origin.webSocketURL() else { throw HuddleError.approval("That address is not valid.") }
        wsURL = url; self.token = token; self.timeout = timeout; isRemote = true
        log.register(secret: token)
    }

    /// The URL the socket connects to (tests pin the scheme and host).
    public var connectURL: URL { wsURL }

    /// Returns T3's command sequence number on success. Throws `.approvalAuth` when the credential is rejected.
    @discardableResult
    public func respond(threadId: String, requestId: String, decision: ApprovalDecision) async throws -> Int? {
        let rpcId = "1"
        let frame = ApprovalWire.respondFrame(rpcId: rpcId, commandId: UUID().uuidString.lowercased(),
                                              threadId: threadId, requestId: requestId, decision: decision)
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = isRemote ? RemoteSession.make(timeout: timeout) : LoopbackSession.make(timeout: timeout)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 256 * 1024   // frames here are tiny; refuse anything big instead of buffering it
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let timeout = self.timeout
        do {
            return try await withThrowingTaskGroup(of: Int?.self) { group in
                group.addTask {
                    try await task.send(.string(frame))
                    while true {
                        let message = try await task.receive()
                        guard case .string(let text) = message else { continue }
                        switch ApprovalWire.parseReply(text, rpcId: rpcId, requestId: requestId) {
                        case .success(let sequence): return sequence
                        case .failure(let m): throw HuddleError.approval(Self.isAuthFailure(m) ? "T3 Code rejected the approvals credential: \(m)" : m)
                        case .other: continue
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    task.cancel(with: .goingAway, reason: nil)
                    throw HuddleError.approval("T3 Code did not answer in time. Check it in T3 Code.")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw HuddleError.approval("No answer from T3 Code.") }
                task.cancel(with: .normalClosure, reason: nil)
                return first
            }
        } catch let e as HuddleError {
            if case .approval(let m) = e, m.hasPrefix("T3 Code rejected the approvals credential") { throw HuddleError.approvalAuth }
            throw e
        } catch {
            switch (task.response as? HTTPURLResponse)?.statusCode {
            case 401?, 403?: throw HuddleError.approvalAuth
            case 426?: throw HuddleError.approval("This T3 Code version speaks a different approval protocol. Use “In T3 Code”.")
            default: throw HuddleError.approval("Couldn’t reach T3 Code to send the decision.")
            }
        }
    }

    private static func isAuthFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("missing required scope") || m.contains("not authenticated") || m.contains("invalid credential")
    }
}
