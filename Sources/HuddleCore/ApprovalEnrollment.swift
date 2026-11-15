import Foundation

/// Opt-in setup for inline approvals: trade a pairing code the user created in T3 for a bearer session.
/// The code is single use; only the resulting session token is kept (Keychain, its own account).
public enum ApprovalEnrollment {
    /// The least scope set that was verified live. Always requested explicitly, so a code that carries
    /// more (a bare `t3 auth pairing create` carries all 16 scopes) still yields a session limited to these.
    public static let scopes = ["orchestration:read", "orchestration:operate"]
    /// The label the user gives the pairing code; T3 shows it on the session, which is how it is found again to revoke.
    public static let label = "Agent Huddle approvals"
    public static var pairingCommand: String {
        "t3 auth pairing create " + scopes.map { "--scope \($0)" }.joined(separator: " ") + " --label \"\(label)\" --ttl 10m"
    }

    /// A pasted value may be the bare credential or a `…/pair#token=<credential>` link.
    public static func clean(_ pasted: String) -> String {
        var t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "token=") { t = String(t[r.upperBound...]) }
        if let amp = t.firstIndex(of: "&") { t = String(t[..<amp]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the bearer token. Refuses to hand one back unless it carries `orchestration:operate` and nothing beyond `scopes`.
    public static func exchange(pairingCode: String, origin: URL, log: HuddleLog) async throws -> String {
        try LoopbackGuard.validate(origin)
        return try await performExchange(pairingCode: pairingCode, base: origin, session: LoopbackSession.make(timeout: 10),
                                         scopes: scopes, label: label, mustInclude: "orchestration:operate",
                                         lacking: "That pairing code cannot approve requests (no orchestration:operate). Create a new one with the command shown.",
                                         unreachable: .notRunning, log: log)
    }

    /// The token exchange itself, shared by the local enrollment, the remote one and discovery. The caller has already
    /// decided which origin is allowed (`LoopbackGuard` or a `VerifiedRemoteOrigin`) and hands in the matching session.
    static func performExchange(pairingCode: String, base: URL, session: URLSession, scopes: [String], label: String,
                                mustInclude: String, lacking: String, unreachable: HuddleError, log: HuddleLog) async throws -> String {
        defer { session.invalidateAndCancel() }
        let code = clean(pairingCode)
        guard !code.isEmpty else { throw HuddleError.approval("Paste the pairing code first.") }
        log.register(secret: code)
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = "/oauth/token"; c.query = nil
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.asciiAlphanumerics; allowed.insert(charactersIn: "-._~")
        let form: [(String, String)] = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", code),
            ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
            ("scope", scopes.joined(separator: " ")),
            ("client_label", label),
        ]
        req.httpBody = Data(form.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await BoundedHTTP.data(for: req, session: session, limit: BoundedHTTP.smallLimit) } catch { throw unreachable }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let j = try? JSON.parse(data), let token = j["access_token"].string, !token.isEmpty else {
            let why = [(try? JSON.parse(data))?["code"].string, (try? JSON.parse(data))?["reason"].string, (try? JSON.parse(data))?["error"].string]
                .compactMap { $0 }.joined(separator: " ")
            throw HuddleError.approval("T3 Code did not accept that pairing code (HTTP \(status)\(why.isEmpty ? "" : ", " + why)). It is single use and expires; create a new one.")
        }
        log.register(secret: token)
        let granted = Set((j["scope"].string ?? "").split(separator: " ").map(String.init))
        guard granted.contains(mustInclude) else { throw HuddleError.approval(lacking) }
        guard granted.isSubset(of: Set(scopes)) else {
            throw HuddleError.approval("T3 Code granted more than requested (\(granted.sorted().joined(separator: ", "))). Nothing was saved; revoke the session “\(label)” in T3 Code.")
        }
        return token
    }
}
