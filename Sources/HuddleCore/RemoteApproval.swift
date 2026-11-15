import Foundation

/// What is kept for one other machine: the bearer session, the machine it belongs to and the one origin it may be sent to.
/// They live in one Keychain item, so the credential can never be paired with a different host.
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

/// Keychain account `approvals-remote-<environment id>`; the item holds the JSON of the credential.
public final class KeychainRemoteCredentialStore: RemoteCredentialStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "app.t3huddle.AgentHuddle") { self.service = service }

    static func account(for environmentId: String) -> String {
        var allowed = CharacterSet.asciiAlphanumerics; allowed.insert(charactersIn: "-_.")
        return "approvals-remote-" + (environmentId.addingPercentEncoding(withAllowedCharacters: allowed) ?? environmentId)
    }
    private func store(_ id: String) -> KeychainTokenStore { KeychainTokenStore(service: service, account: Self.account(for: id)) }

    public func load(environmentId: String) -> RemoteApprovalCredential? {
        guard let text = store(environmentId).load(), let c = try? JSONDecoder().decode(RemoteApprovalCredential.self, from: Data(text.utf8)),
              c.environmentId == environmentId else { return nil }
        return c
    }
    public func save(_ c: RemoteApprovalCredential) throws {
        guard let data = try? JSONEncoder().encode(c), let text = String(data: data, encoding: .utf8) else { throw HuddleError.toolFailed("Could not encode the credential") }
        try store(c.environmentId).save(text)
    }
    @discardableResult public func delete(environmentId: String) -> Bool { store(environmentId).delete() }

    /// Attributes only (no secret data is read, so no prompt): the accounts of this service that start with the prefix.
    public func environmentIds() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        let prefix = "approvals-remote-"
        return rows.compactMap { ($0[kSecAttrAccount as String] as? String) }.filter { $0.hasPrefix(prefix) }
            .compactMap { String($0.dropFirst(prefix.count)).removingPercentEncoding }.sorted()
    }
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
