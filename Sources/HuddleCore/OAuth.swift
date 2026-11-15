import Foundation
import CryptoKit
import Security

public struct OAuthResult: Sendable {
    public var accessToken: String
    public var clientId: String
    public var port: UInt16
    public var expiresIn: Int?
}

/// MCP OAuth for a public native client (SPEC §7.1): discovery → dynamic client registration →
/// authorization code + PKCE S256 with a one-shot loopback redirect → token exchange.
/// Every URL it touches must be a loopback URL on the MCP server's own origin.
public final class OAuthClient: @unchecked Sendable {
    public typealias Opener = @Sendable (URL) -> Void
    private let origin: URL
    private let mcpURL: URL
    private let log: HuddleLog
    private let opener: Opener
    private let session: URLSession
    private let timeout: TimeInterval
    /// nil = this Mac (every endpoint must pass `LoopbackGuard`); otherwise the verified https origin of another machine
    /// (spec 15): every endpoint must be on exactly that origin. The redirect always comes back to this Mac's loopback.
    private let remote: VerifiedRemoteOrigin?

    public init(mcpEndpoint: URL, log: HuddleLog, opener: @escaping Opener, timeout: TimeInterval = 180) throws {
        try LoopbackGuard.validate(mcpEndpoint)
        mcpURL = mcpEndpoint
        var c = URLComponents(url: mcpEndpoint, resolvingAgainstBaseURL: false)!
        c.path = ""; c.query = nil
        origin = c.url!
        self.log = log; self.opener = opener; self.timeout = timeout
        session = LoopbackSession.make(timeout: 10)
        remote = nil
    }

    /// Another machine's T3 (spec 15). Only a `VerifiedRemoteOrigin` gets here, so the identity check has run.
    public init(remote: VerifiedRemoteOrigin, log: HuddleLog, opener: @escaping Opener, timeout: TimeInterval = 180) throws {
        guard let mcp = remote.origin.httpURL(path: "/mcp"), let base = remote.origin.httpURL(path: "") else {
            throw HuddleError.oauth("bad machine address")
        }
        mcpURL = mcp; origin = base
        self.log = log; self.opener = opener; self.timeout = timeout
        session = RemoteSession.make(timeout: 10)
        self.remote = remote
    }

    public static let scopes = ["orchestration:read", "orchestration:operate"]

    // MARK: PKCE

    static func randomURLSafe(bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    // MARK: Flow

    public func authorize(scopes: [String] = OAuthClient.scopes,
                          previous: (clientId: String, port: UInt16)? = nil) async throws -> OAuthResult {
        let meta = try await discover()

        // 1. One-shot loopback listener for the redirect (prefer the previously registered port).
        let state = Self.randomURLSafe(bytes: 16)
        let box = CallbackBox(expectedState: state)
        let server = LoopbackHTTPServer { req in box.handle(req) }
        var port: UInt16 = 0
        // The previous port may take a moment to be released after the last sign-in's listener was cancelled: retry briefly
        // before giving up on reusing the registered client.
        var reused: UInt16?
        if let prev = previous {
            for attempt in 0..<5 {
                if let p = try? await server.start(port: prev.port) { reused = p; break }
                if attempt < 4 { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
        }
        if let p = reused { port = p } else { port = try await server.start() }
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(port)/callback"

        // 2. Client: reuse the registered one when the redirect URI is unchanged, else register.
        let clientId: String
        if let prev = previous, prev.port == port { clientId = prev.clientId }
        else { clientId = try await register(meta, redirect: redirect, scopes: scopes) }

        // 3. Authorize in the browser.
        let verifier = Self.randomURLSafe(bytes: 48)
        var c = URLComponents(url: meta.authorize, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirect), .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "resource", value: mcpURL.absoluteString),
        ]
        log.log("oauth: opening authorization page")
        opener(c.url!)

        // 4. Wait for the single redirect.
        let params = try await box.wait(timeout: timeout)
        if let err = params["error"] { throw HuddleError.oauth(params["error_description"] ?? err) }
        guard params["state"] == state else { throw HuddleError.oauth("state mismatch") }
        if let iss = params["iss"], iss != meta.issuer { throw HuddleError.oauth("unexpected issuer") }
        guard let code = params["code"] else { throw HuddleError.oauth("no authorization code") }

        // 5. Token exchange.
        let tok = try await post(meta.token, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "client_id": clientId, "code_verifier": verifier, "resource": mcpURL.absoluteString])
        guard let access = tok["access_token"].string else { throw HuddleError.oauth("no access_token in response") }
        log.register(secret: access)
        log.log("oauth: token received")
        return OAuthResult(accessToken: access, clientId: clientId, port: port, expiresIn: tok["expires_in"].int)
    }

    // MARK: Steps

    struct Metadata { var issuer: String; var authorize: URL; var token: URL; var register: URL }

    func discover() async throws -> Metadata {
        let url = origin.appendingPathComponent(".well-known/oauth-authorization-server")
        let (data, resp) = try await fetch(URLRequest(url: url))
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try? JSON.parse(data) else {
            throw HuddleError.oauth("authorization server metadata unavailable")
        }
        func ep(_ key: String) throws -> URL {
            guard let s = j[key].string, let u = URL(string: s) else { throw HuddleError.oauth("metadata missing \(key)") }
            if let remote {
                // Exactly the machine's own origin: same scheme, host and port. A server pointing elsewhere is refused.
                guard u.scheme == remote.origin.url.scheme, u.host?.lowercased() == remote.origin.url.host?.lowercased(),
                      u.port == remote.origin.url.port, u.user == nil, u.password == nil else { throw HuddleError.oauth("sign-in endpoint is not on \(remote.origin.host)") }
            } else {
                try LoopbackGuard.validate(u)
                guard u.port == origin.port, u.host == origin.host else { throw HuddleError.nonLoopback(u.host ?? s) }
            }
            return u
        }
        return Metadata(issuer: j["issuer"].string ?? origin.absoluteString, authorize: try ep("authorization_endpoint"),
                        token: try ep("token_endpoint"), register: try ep("registration_endpoint"))
    }

    func register(_ m: Metadata, redirect: String, scopes: [String]) async throws -> String {
        var req = URLRequest(url: m.register)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = ([
            "client_name": "Agent Huddle", "redirect_uris": [.string(redirect)], "grant_types": ["authorization_code"],
            "response_types": ["code"], "token_endpoint_auth_method": "none", "scope": .string(scopes.joined(separator: " ")),
        ] as JSON).data()
        let (data, resp) = try await fetch(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let j = try? JSON.parse(data), let id = j["client_id"].string else {
            throw HuddleError.oauth("client registration failed (HTTP \(status))")
        }
        log.log("oauth: registered client")
        return id
    }

    func post(_ url: URL, form: [String: String]) async throws -> JSON {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.asciiAlphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        let (data, resp) = try await fetch(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let j = try? JSON.parse(data) else {
            let msg = (try? JSON.parse(data))?["error"].string ?? "HTTP \(status)"
            throw HuddleError.oauth("token request failed (\(msg))")
        }
        return j
    }

    private func fetch(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await BoundedHTTP.data(for: req, session: session, limit: BoundedHTTP.smallLimit) }
        catch { throw HuddleError.notRunning }
    }
}

/// Receives exactly one redirect and answers it with a tiny page.
final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedState: String
    private var params: [String: String]?
    init(expectedState: String) { self.expectedState = expectedState }
    private var waiter: CheckedContinuation<[String: String], Error>?

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard let comps = URLComponents(string: "http://127.0.0.1" + req.path), comps.path == "/callback" else {
            return HTTPResponse(status: 404)
        }
        var p: [String: String] = [:]
        for q in comps.queryItems ?? [] { p[q.name] = q.value ?? "" }
        // Only the redirect that carries our own state may end the sign-in: a stray local request cannot use up the attempt.
        guard p["state"] == expectedState else { return HTTPResponse(status: 400) }
        lock.lock()
        if params == nil { params = p; waiter?.resume(returning: p); waiter = nil }
        lock.unlock()
        let html = "<!doctype html><meta charset=utf-8><title>Agent Huddle</title><body style='font-family:-apple-system;background:#16171a;color:#fff;padding:3em'><h2>Agent Huddle is connected</h2><p>You can close this tab.</p>"
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    /// Resolves with the redirect's query, or throws on timeout / task cancellation (Cancel button).
    func wait(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                lock.lock()
                if let p = params { lock.unlock(); cont.resume(returning: p); return }
                if cancelled { lock.unlock(); cont.resume(throwing: CancellationError()); return }
                waiter = cont
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    fail(HuddleError.oauth("timed out waiting for approval"))
                }
            }
        } onCancel: { [self] in
            lock.lock(); cancelled = true; lock.unlock()
            fail(CancellationError())
        }
    }

    private var cancelled = false
    private func fail(_ error: Error) {
        lock.lock(); let w = waiter; waiter = nil; lock.unlock()
        w?.resume(throwing: error)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
