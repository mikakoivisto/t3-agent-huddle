import Foundation

/// Another machine the user connected directly (spec 15): its MCP token, the one https origin it may be sent to, its name,
/// and the OAuth client registered on THAT machine (never this Mac's). One record, so the token cannot drift to another host.
public struct MachineCredential: Codable, Equatable, Sendable {
    public var environmentId: String
    public var origin: String
    public var token: String
    public var label: String?
    public var oauthClientId: String?
    public var oauthPort: UInt16?
    public init(environmentId: String, origin: String, token: String, label: String? = nil, oauthClientId: String? = nil, oauthPort: UInt16? = nil) {
        self.environmentId = environmentId; self.origin = origin; self.token = token; self.label = label
        self.oauthClientId = oauthClientId; self.oauthPort = oauthPort
    }
}

public protocol MachineCredentialStore: Sendable {
    func load(environmentId: String) -> MachineCredential?
    func save(_ credential: MachineCredential) throws
    @discardableResult func delete(environmentId: String) -> Bool
    func environmentIds() -> [String]
}

public final class MemoryMachineCredentialStore: MachineCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: MachineCredential]
    public var refuseDelete = false
    public init(_ items: [MachineCredential] = []) { self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.environmentId, $0) }) }
    public func load(environmentId: String) -> MachineCredential? { lock.lock(); defer { lock.unlock() }; return items[environmentId] }
    public func save(_ c: MachineCredential) throws { lock.lock(); items[c.environmentId] = c; lock.unlock() }
    @discardableResult public func delete(environmentId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if refuseDelete { return false }
        items[environmentId] = nil; return true
    }
    public func environmentIds() -> [String] { lock.lock(); defer { lock.unlock() }; return items.keys.sorted() }
}

/// How the panel reaches a machine right now.
public enum MachineStatus: Equatable, Sendable {
    case connected
    /// Signed in, but the address did not answer (or failed its identity check). Its last list stays for a short while.
    case offline(String)
    /// T3 refused the token (revoked or expired). The token was deleted; the machine needs a new sign-in.
    case signInExpired
    case unsupported(String)
}
