import Foundation

public enum HuddleError: Error, Equatable, CustomStringConvertible {
    case nonLoopback(String)
    case runtimeFileMissing
    case runtimeFileInvalid(String)
    case peerNotT3
    case notRunning
    case unauthorized
    case unsupportedServer(String)
    case rpc(code: Int, message: String)
    case toolFailed(String)
    case badResponse(String)
    case readOnly
    case oauth(String)
    /// Inline approvals (opt-in): a decision T3 refused or that could not be sent.
    case approval(String)
    /// The approvals credential was rejected (revoked or expired): it is dropped and the app falls back to "In T3 Code".
    case approvalAuth

    /// Server-supplied text is shown to the user, so it is capped and has hidden and direction characters made visible.
    private static func shown(_ m: String) -> String { DisplayText.clean(String(m.prefix(300)), allowNewlines: true) }

    /// The case name only, with no payload: what may go to the log (payloads can carry server-supplied text).
    public var category: String {
        switch self {
        case .nonLoopback: return "nonLoopback"
        case .runtimeFileMissing: return "runtimeFileMissing"
        case .runtimeFileInvalid: return "runtimeFileInvalid"
        case .peerNotT3: return "peerNotT3"
        case .notRunning: return "notRunning"
        case .unauthorized: return "unauthorized"
        case .unsupportedServer: return "unsupportedServer"
        case .rpc(let code, _): return "rpc(\(code))"
        case .toolFailed: return "toolFailed"
        case .badResponse: return "badResponse"
        case .readOnly: return "readOnly"
        case .oauth: return "oauth"
        case .approval: return "approval"
        case .approvalAuth: return "approvalAuth"
        }
    }

    public var description: String {
        switch self {
        case .nonLoopback(let h): return "Refusing non-loopback host: \(h)"
        case .runtimeFileMissing: return "T3 Code not running (no runtime file)"
        case .runtimeFileInvalid(let m): return "Runtime file invalid: \(Self.shown(m))"
        case .peerNotT3: return "Listener on the T3 port is not T3 Code"
        case .notRunning: return "T3 Code not running"
        case .unauthorized: return "Connect to T3 Code"
        case .unsupportedServer(let m): return "Unsupported T3 Code version: \(Self.shown(m))"
        case .rpc(let c, let m): return "RPC error \(c): \(Self.shown(m))"
        case .toolFailed(let m): return Self.shown(m)
        case .badResponse(let m): return "Bad response: \(Self.shown(m))"
        case .readOnly: return "Read-only mode"
        case .oauth(let m): return "Sign-in failed: \(Self.shown(m))"
        case .approval(let m): return Self.shown(m)
        case .approvalAuth: return "T3 Code rejected the approvals credential. Inline approvals are off; set them up again."
        }
    }
}

/// Loopback-only policy (SPEC §7.4, §10). IP literals only: no DNS name is trusted.
public enum LoopbackGuard {
    public static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return h == "127.0.0.1" || h == "::1"
    }

    @discardableResult
    public static func validate(_ url: URL) throws -> URL {
        guard url.scheme == "http", let host = url.host, isLoopbackHost(host) else {
            throw HuddleError.nonLoopback(url.host ?? url.absoluteString)
        }
        return url
    }
}

/// Logging that cannot leak a bearer token: every line is scrubbed before it reaches the sink.
public final class HuddleLog: @unchecked Sendable {
    public typealias Sink = @Sendable (String) -> Void
    private let lock = NSLock()
    private var secrets: [String] = []
    private let sink: Sink

    public init(sink: @escaping Sink = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.sink = sink
    }

    /// Secrets to scrub from every line. Kept in memory only, de-duplicated, and bounded (the oldest are dropped first).
    public func register(secret: String) {
        guard secret.count >= 4 else { return }
        lock.lock(); defer { lock.unlock() }
        secrets.removeAll { $0 == secret }
        secrets.append(secret)
        if secrets.count > 32 { secrets.removeFirst(secrets.count - 32) }
    }

    /// Stops holding a secret that was deleted (a turned-off credential, a used pairing code).
    public func forget(secret: String) {
        lock.lock(); secrets.removeAll { $0 == secret }; lock.unlock()
    }

    public func log(_ message: String) {
        sink(scrub(message))
    }

    public func scrub(_ message: String) -> String {
        lock.lock(); let known = secrets; lock.unlock()
        var out = message
        for s in known { out = out.replacingOccurrences(of: s, with: "‹token›") }
        // Belt and braces: anything that looks like a bearer credential.
        if let re = try? NSRegularExpression(pattern: "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+") {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: "Bearer ‹token›")
        }
        return out
    }
}

/// Token storage. The real implementation is the Keychain (SPEC §7.1); tests use memory.
public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String) throws
    /// True when the item is gone afterwards (deleted, or it was never there).
    @discardableResult func delete() -> Bool
}

public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func load() -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func save(_ token: String) throws { lock.lock(); self.token = token; lock.unlock() }
    @discardableResult public func delete() -> Bool { lock.lock(); token = nil; lock.unlock(); return true }
}

public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account: String
    /// `account` separates credentials: the MCP token is `bearer`; the opt-in approvals token is `approvals-bearer`.
    public init(service: String = "app.t3huddle.AgentHuddle", account: String = "bearer") { self.service = service; self.account = account }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    public func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    /// Updates an existing item in place (the old credential is never deleted before the new one is stored) or adds a new one.
    public func save(_ token: String) throws {
        let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = base
            for (k, v) in attrs { q[k] = v }
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw HuddleError.toolFailed("Keychain save failed (\(status))")
        }
    }
    @discardableResult public func delete() -> Bool {
        let status = SecItemDelete(base as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Contract drift (SPEC §11): the tools in §7.2 must still exist with the arguments we pass.
public enum ContractCheck {
    /// tool name → argument names the huddle sends.
    public static let required: [String: [String]] = [
        "t3_thread_list": ["allProjects", "statuses", "limit", "cursor", "settled"],
        "t3_thread_read": ["threadId", "view", "afterPosition", "limit", "maxCharsPerItem", "itemId", "textOffset"],
        "t3_pending_request": ["action", "threadId", "requestId", "answers"],
    ]   // `t3_project_read` (project names) and the environment tools are optional: gated on `toolNames`, never required

    /// Returns nil when compatible, else a one-line reason for "Unsupported T3 Code version".
    public static func verify(toolsList result: JSON) -> String? {
        let tools = result["tools"].array ?? []
        var byName: [String: JSON] = [:]
        for t in tools { if let n = t["name"].string { byName[n] = t } }
        for (name, args) in required.sorted(by: { $0.key < $1.key }) {
            guard let tool = byName[name] else { return "missing tool \(name)" }
            let props = tool["inputSchema"]["properties"].object ?? [:]
            if props.isEmpty { continue }   // schema not advertised: cannot judge, allow
            for a in args where props[a] == nil { return "\(name) lost argument \(a)" }
        }
        return nil
    }
}
