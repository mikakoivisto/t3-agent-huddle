import Foundation

// Finds a linked machine's https address so the user does not have to type it. READ-ONLY, THIS MAC'S T3 ONLY.
//
// T3's MCP does not expose the addresses of linked machines; its internal `/ws` does, through the RPC `peerLinks.list`,
// which needs the scope `access:read` (checked against the T3 0.1.9 bundle: `access:read` gates exactly `peerLinks.list` and
// `subscribeAuthAccess`, no HTTP route; both return metadata only — no pairing credential, no session token; creating or
// revoking credentials needs `access:write`, which is never requested). The session is used for this one call and discarded.
//
// This is NOT the decision socket (ApprovalSocket.swift): it never sends a command, only the one read `peerLinks.list`.
// The address it returns is a convenience, not a trust root: the setup still checks that the address answers as the linked
// machine (`RemoteIdentity`) before a pairing code is sent there.

public struct PeerLinkInfo: Equatable, Sendable {
    public var environmentId: String
    public var label: String
    public var urls: [String]
    public init(environmentId: String, label: String, urls: [String]) { self.environmentId = environmentId; self.label = label; self.urls = urls }
}

public enum PeerLinkDiscovery {
    /// `orchestration:read` is what the upgrade needs besides `access:read` (live: access:read alone is refused).
    public static let scopes = ["orchestration:read", "access:read"]
    public static let label = "Agent Huddle discovery"
    public static var pairingCommand: String {
        "t3 auth pairing create " + scopes.map { "--scope \($0)" }.joined(separator: " ") + " --label \"\(label)\" --ttl 10m"
    }
    static let rpcTag = "peerLinks.list"

    /// The one frame this file sends.
    static func listFrame(rpcId: String) -> String {
        let frame: JSON = ["_tag": "Request", "id": .string(rpcId), "tag": .string(rpcTag), "headers": [], "payload": [:]]
        return frame.text()
    }

    /// `[PeerLinkInfo]` from the `Exit` frame of our request; nil for any other frame (Pong, Chunk, …).
    static func parseReply(_ text: String, rpcId: String) -> Result<[PeerLinkInfo], HuddleError>? {
        guard let j = try? JSON.parse(text), j["_tag"].string == "Exit", j["requestId"].string == rpcId else { return nil }
        let exit = j["exit"]
        guard exit["_tag"].string == "Success" else {
            var message = "T3 Code refused the address lookup."
            for c in exit["cause"].array ?? [] {
                if let m = c["error"]["message"].string ?? c["error"]["detail"].string ?? c["defect"].string ?? c["message"].string { message = m; break }
            }
            return .failure(.approval(String(message.prefix(160))))
        }
        let links: [PeerLinkInfo] = (exit["value"]["links"].array ?? []).compactMap { l in
            guard let id = l["environmentId"].string else { return nil }
            return PeerLinkInfo(environmentId: id, label: l["label"].string ?? id, urls: (l["urls"].array ?? []).compactMap(\.string))
        }
        return .success(links)
    }

    /// Exchanges a pairing code made on THIS Mac (`pairingCommand`), asks `peerLinks.list`, and drops the session.
    /// `origin` is this Mac's T3 and goes through `LoopbackGuard`.
    public static func discover(pairingCode: String, origin: URL, log: HuddleLog, timeout: TimeInterval = 15) async throws -> [PeerLinkInfo] {
        try LoopbackGuard.validate(origin)
        let token = try await ApprovalEnrollment.performExchange(
            pairingCode: pairingCode, base: origin, session: LoopbackSession.make(timeout: 10), scopes: scopes, label: label,
            mustInclude: "access:read",
            lacking: "That pairing code cannot read linked machines (no access:read). Create a new one with the command shown.",
            unreachable: .notRunning, log: log)
        var c = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        c.scheme = "ws"; c.path = "/ws"; c.query = nil
        c.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        guard let url = c.url else { throw HuddleError.nonLoopback(origin.absoluteString) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = LoopbackSession.make(timeout: timeout)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 256 * 1024   // frames here are tiny; refuse anything big instead of buffering it
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let rpcId = "1", frame = listFrame(rpcId: rpcId)
        do {
            return try await withThrowingTaskGroup(of: [PeerLinkInfo].self) { group in
                group.addTask {
                    try await task.send(.string(frame))
                    while true {
                        guard case .string(let text) = try await task.receive() else { continue }
                        switch parseReply(text, rpcId: rpcId) {
                        case .success(let links)?: return links
                        case .failure(let e)?: throw e
                        case nil: continue
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    task.cancel(with: .goingAway, reason: nil)
                    throw HuddleError.approval("T3 Code did not answer in time.")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw HuddleError.approval("No answer from T3 Code.") }
                return first
            }
        } catch let e as HuddleError { throw e }
        catch { throw HuddleError.approval("Couldn’t read the linked machines from T3 Code.") }
    }
}
