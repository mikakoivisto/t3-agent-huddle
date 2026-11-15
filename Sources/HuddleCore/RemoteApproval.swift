import Foundation

/// What is kept for one other machine: the bearer session, the machine it belongs to and the one origin it may be sent to.
/// They are stored together, so the credential can never be paired with a different host.
public struct RemoteApprovalCredential: Codable, Equatable, Sendable {
    public var environmentId: String
    public var origin: String
    public var token: String
    public init(environmentId: String, origin: String, token: String) { self.environmentId = environmentId; self.origin = origin; self.token = token }
}

/// One credential per linked environment. Separate from the MCP token (`bearer`) and from this Mac's approvals credential (`approvals-bearer`).
public protocol RemoteCredentialStore: Sendable {
    func load(environmentId: String) -> RemoteApprovalCredential?
    func save(_ credential: RemoteApprovalCredential) throws
    /// True when the item is gone afterwards.
    @discardableResult func delete(environmentId: String) -> Bool
    /// Environment ids that have a credential, linked or not (so a credential for an unlinked machine can still be removed).
    func environmentIds() -> [String]
}

public final class MemoryRemoteCredentialStore: RemoteCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: RemoteApprovalCredential]
    public init(_ items: [RemoteApprovalCredential] = []) { self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.environmentId, $0) }) }
    public func load(environmentId: String) -> RemoteApprovalCredential? { lock.lock(); defer { lock.unlock() }; return items[environmentId] }
    public func save(_ c: RemoteApprovalCredential) throws { lock.lock(); items[c.environmentId] = c; lock.unlock() }
    @discardableResult public func delete(environmentId: String) -> Bool { lock.lock(); items[environmentId] = nil; lock.unlock(); return true }
    public func environmentIds() -> [String] { lock.lock(); defer { lock.unlock() }; return items.keys.sorted() }
}

/// The per-machine credentials, as a view of the one-item `KeychainVault`.
public final class KeychainRemoteCredentialStore: RemoteCredentialStore, @unchecked Sendable {
    private let vault: KeychainVault
    public init(vault: KeychainVault) { self.vault = vault }

    /// The account name earlier versions used for one machine's own Keychain item (`approvals-remote-<percent-encoded id>`).
    /// Only the one-time migration into the vault reads such items now.
    static func account(for environmentId: String) -> String {
        var allowed = CharacterSet.asciiAlphanumerics; allowed.insert(charactersIn: "-_.")
        return KeychainVault.legacyRemotePrefix + (environmentId.addingPercentEncoding(withAllowedCharacters: allowed) ?? environmentId)
    }

    public func load(environmentId: String) -> RemoteApprovalCredential? {
        guard let c = vault.read({ $0.remote[environmentId] }), c.environmentId == environmentId else { return nil }
        return c
    }
    public func save(_ c: RemoteApprovalCredential) throws { try vault.mutate { $0.remote[c.environmentId] = c } }
    @discardableResult public func delete(environmentId: String) -> Bool {
        do { try vault.mutate { $0.remote[environmentId] = nil }; return true } catch { return false }
    }
    public func environmentIds() -> [String] { vault.read { $0.remote.keys.sorted() } }
}

/// Opt-in setup of inline approvals for another machine: a pairing code created ON THAT MACHINE becomes a bearer session there.
public enum RemoteApprovalEnrollment {
    /// The code is made on the other machine, so this is the command to show. Same scopes as the local one: the least set
    /// that was verified live. That credential could also send, launch and interrupt threads on that machine.
    public static var pairingCommand: String { ApprovalEnrollment.pairingCommand }

    /// Identity first (nothing secret goes out), then the single-use pairing code. Only the resulting session token is returned.
    public static func enroll(pairingCode: String, origin: ValidatedRemoteOrigin, environmentId: String, log: HuddleLog) async throws -> RemoteApprovalCredential {
        let verified = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: environmentId)
        let token = try await ApprovalEnrollment.performExchange(
            pairingCode: pairingCode, base: verified.origin.url, session: RemoteSession.make(timeout: 10),
            scopes: ApprovalEnrollment.scopes, label: ApprovalEnrollment.label, mustInclude: "orchestration:operate",
            lacking: "That pairing code cannot approve requests (no orchestration:operate). Create a new one on that machine with the command shown.",
            unreachable: .approval("Couldn’t reach \(verified.origin.host) to exchange the pairing code."), log: log)
        return RemoteApprovalCredential(environmentId: verified.environmentId, origin: verified.origin.url.absoluteString, token: token)
    }
}
