import Foundation

// Inline approvals for a thread on ANOTHER machine.
//
// This is the one place the "loopback only" rule has an exception, and it is narrow: the user sets it up per machine, the
// address is an https origin that came from discovery or from what the user typed in the setup dialog (it is stored with
// the credential, never read from thread content), and nothing is sent to it until it proved to be the linked machine.
// The local code path (`LoopbackGuard`, `LoopbackSession`) is untouched and stays strictly loopback.

/// An https origin that passed `RemoteOriginPolicy`. The only way to get one is `RemoteOriginPolicy.validate`.
public struct ValidatedRemoteOrigin: Equatable, Sendable {
    /// `https://host[:port]`, nothing else (no path, query, userinfo or fragment).
    public let url: URL
    public var host: String { url.host ?? "" }
    public var isHTTPS: Bool { url.scheme == "https" }
    fileprivate init(url: URL) { self.url = url }

    /// `wss://host[:port]/ws?orchestrationProtocol=2` (`ws://` only for the loopback test fixture).
    func webSocketURL() -> URL? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.scheme = isHTTPS ? "wss" : "ws"; c?.path = "/ws"; c?.query = nil
        c?.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        return c?.url
    }

    func httpURL(path: String) -> URL? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.path = path; c?.query = nil
        return c?.url
    }
}

/// The origin rules for a non-local machine. Pure, so the policy is unit-tested without a network.
public struct RemoteOriginPolicy: Sendable {
    private let allowsLoopbackFixture: Bool
    private init(allowsLoopbackFixture: Bool) { self.allowsLoopbackFixture = allowsLoopbackFixture }

    /// What the app uses: https only, and never a loopback host (loopback is the local credential's business).
    public static let production = RemoteOriginPolicy(allowsLoopbackFixture: false)
    /// Tests, snapshots and the demo only: the fake "remote" machine listens on `http://127.0.0.1`. Not reachable from the
    /// production wiring (`SecurityTests` scans for it).
    package static let loopbackFixture = RemoteOriginPolicy(allowsLoopbackFixture: true)

    public func validate(_ text: String) throws -> ValidatedRemoteOrigin {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw Self.refuse("Enter the machine’s https address.") }
        if !t.contains("://") { t = "https://" + t }   // “mac-mini.tail1234.ts.net” is fine; anything else must say https itself
        guard let url = URL(string: t) else { throw Self.refuse("That is not a valid address.") }
        return try validate(url)
    }

    public func validate(_ url: URL) throws -> ValidatedRemoteOrigin {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let rawHost = c.host, !rawHost.isEmpty else {
            throw Self.refuse("That is not a valid address.")
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let scheme = (c.scheme ?? "").lowercased()
        let loopback = Self.isLoopbackName(host)
        if loopback {
            // Loopback is never a remote machine. The test fixture alone may reach its fake over plain http.
            guard allowsLoopbackFixture, scheme == "http", LoopbackGuard.isLoopbackHost(host) else {
                throw Self.refuse("Another machine cannot be at a loopback address (\(host)). Use its https address.")
            }
        } else {
            // A certificate vouches for a name, not for an IP address: an IP literal (any spelling, v4 or v6, with or without a
            // zone) cannot be a machine this app talks to, and refusing the whole class avoids a table of odd spellings.
            guard !Self.isIPLiteral(host) else { throw Self.refuse("Use the machine’s name (like machine.tailnet.ts.net), not an IP address.") }
            guard scheme == "https" else { throw Self.refuse("Use an https address. Agent Huddle never sends a credential over plain http to another machine.") }
        }
        guard c.user == nil, c.password == nil else { throw Self.refuse("The address must not contain a user name or password.") }
        guard c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else {
            throw Self.refuse("Use just the machine’s address, like https://machine.tailnet.ts.net.")
        }
        if let p = c.port, !(1...65535).contains(p) { throw Self.refuse("That port is not valid.") }
        var out = URLComponents()
        out.scheme = scheme; out.host = host.contains(":") ? "[\(host)]" : host; out.port = c.port
        guard let normalized = out.url else { throw Self.refuse("That is not a valid address.") }
        return ValidatedRemoteOrigin(url: normalized)
    }

    /// The first address in `urls` the policy accepts (discovery lists several, in the order T3 tries them).
    public func firstAcceptable(_ urls: [String]) -> ValidatedRemoteOrigin? {
        for u in urls { if let o = try? validate(u) { return o } }
        return nil
    }

    static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        var v4 = in_addr()
        return inet_aton(host, &v4) != 0
    }

    /// localhost names and every spelling of a loopback / unspecified address (127/8, 0/8, ::1 and ::, long forms, v4-mapped).
    static func isLoopbackName(_ host: String) -> Bool {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" || h.hasSuffix(".localhost") || h == "0" { return true }
        var v4 = in_addr()
        if inet_aton(h, &v4) != 0 { let a = UInt32(bigEndian: v4.s_addr) >> 24; return a == 127 || a == 0 }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, h, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        let zeros = b[0..<10].allSatisfy { $0 == 0 }
        if zeros && b[10] == 0 && b[11] == 0 && b[12..<15].allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) { return true }   // :: and ::1
        if zeros && b[10] == 0xff && b[11] == 0xff && (b[12] == 127 || b[12] == 0) { return true }                                  // ::ffff:127.x.y.z
        return false
    }

    static func refuse(_ message: String) -> HuddleError { .approval(message) }
}

/// Ephemeral, cookie-free, proxy-free, redirect-refusing session for the one non-loopback connection.
/// Certificate validation is the system default on purpose: no delegate answers a trust challenge, nothing is pinned or skipped.
public enum RemoteSession {
    public static func make(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [:]
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        return URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
    }
}

/// Proof that an origin answered as the machine the user linked. Only `RemoteIdentity.verify` makes one, so nothing that
/// takes a `VerifiedRemoteOrigin` (the enrollment, the decision socket) can run against an unchecked address.
public struct VerifiedRemoteOrigin: Equatable, Sendable {
    public let origin: ValidatedRemoteOrigin
    public let environmentId: String
    fileprivate init(origin: ValidatedRemoteOrigin, environmentId: String) { self.origin = origin; self.environmentId = environmentId }
}

/// What an address says it is, before the user has confirmed it (spec 15). Holds no proof and opens nothing.
public struct IdentifiedRemote: Equatable, Sendable {
    public let origin: ValidatedRemoteOrigin
    public let environmentId: String
    public let label: String?
}

/// "Is this address really that machine?" T3 publishes its environment id, unauthenticated, at `/.well-known/t3/environment`
/// (T3's own peer linking uses the same document: `expectedEnvironmentId`). Nothing secret is sent to find out.
/// The id is not a secret, so the proof is TLS (system trust, name = the address) plus the id; it is not a signature.
public enum RemoteIdentity {
    static let path = "/.well-known/t3/environment"

    /// A typed address with no linked machine to compare against (spec 15, adding a machine): what the machine says it is.
    /// This is NOT a `VerifiedRemoteOrigin`: the user confirms the name first, then `verify` runs against the reported id.
    public static func identify(origin: ValidatedRemoteOrigin, timeout: TimeInterval = 8) async throws -> IdentifiedRemote {
        guard let url = origin.httpURL(path: path) else { throw HuddleError.approval("No machine to check.") }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")   // no Authorization header, ever
        let session = RemoteSession.make(timeout: timeout)
        defer { session.invalidateAndCancel() }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await BoundedHTTP.data(for: req, session: session, limit: 256 * 1024) }
        catch { throw HuddleError.approval("Couldn’t reach \(origin.host). Check the address and that its T3 Code is reachable over https.") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let j = try? JSON.parse(data), let id = j["environmentId"].string, !id.isEmpty else {
            throw HuddleError.approval("\(origin.host) did not answer like T3 Code (HTTP \(status)). Nothing was sent.")
        }
        let label = (j["label"].string ?? j["name"].string ?? j["environmentLabel"].string).map { DisplayText.clean($0) }
        return IdentifiedRemote(origin: origin, environmentId: id, label: label)
    }

    public static func verify(origin: ValidatedRemoteOrigin, expectedEnvironmentId: String, timeout: TimeInterval = 8) async throws -> VerifiedRemoteOrigin {
        guard !expectedEnvironmentId.isEmpty, let url = origin.httpURL(path: path) else { throw HuddleError.approval("No machine to check.") }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")   // no Authorization header, ever
        let session = RemoteSession.make(timeout: timeout)
        defer { session.invalidateAndCancel() }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await BoundedHTTP.data(for: req, session: session, limit: 256 * 1024) }
        catch { throw HuddleError.approval("Couldn’t reach that machine at \(origin.host). Check the address and that its T3 Code is reachable over https.") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), data.count < 262_144, let j = try? JSON.parse(data), let id = j["environmentId"].string else {
            throw HuddleError.approval("\(origin.host) did not answer like T3 Code (HTTP \(status)). Nothing was sent.")
        }
        guard id == expectedEnvironmentId else {
            throw HuddleError.approval("\(origin.host) is a different machine from the one linked. Nothing was sent.")
        }
        return VerifiedRemoteOrigin(origin: origin, environmentId: id)
    }
}
