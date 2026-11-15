import Foundation
import Security

// All of the app's secrets live in ONE Keychain item (service `app.t3huddle.AgentHuddle`, account `vault`).
// Why one: macOS asks for access per item, and an ad-hoc signed build has a new identity after every update, so three
// or more items meant three or more prompts per new build. One item is read once per launch and cached in memory.
//
// Earlier versions kept `bearer`, `approvals-bearer` and one `approvals-remote-<id>` item per machine. The first launch
// with no vault copies those into it, then deletes them. A legacy item the user declined to unlock is left alone and
// tried again on the next launch.

public enum SecretRead: Equatable, Sendable {
    case found(Data)
    case missing
    /// Denied, cancelled, locked or otherwise unreadable. Never treated as "not there".
    case failed(OSStatus)
}

/// The raw item operations, so the vault logic runs against memory in tests (a real Keychain prompt would hang CI).
public protocol SecretItemStorage: Sendable {
    func read(account: String) -> SecretRead
    /// Updates the item in place (the old value is never deleted first) or adds it. `errSecSuccess` when stored.
    func write(account: String, data: Data) -> OSStatus
    /// `errSecSuccess` or `errSecItemNotFound` when the item is gone afterwards.
    func delete(account: String) -> OSStatus
    /// Attributes only, so no secret is read and nothing prompts: every account of this service.
    func accounts() -> [String]
}

public final class SystemKeychainStorage: SecretItemStorage, @unchecked Sendable {
    private let service: String
    public init(service: String = "app.t3huddle.AgentHuddle") { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func read(account: String) -> SecretRead {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let d = out as? Data else { return .failed(status) }
        return .found(d)
    }
    public func write(account: String, data: Data) -> OSStatus {
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(base(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = base(account)
            for (k, v) in attrs { q[k] = v }
            status = SecItemAdd(q as CFDictionary, nil)
        }
        return status
    }
    public func delete(account: String) -> OSStatus { SecItemDelete(base(account) as CFDictionary) }
    public func accounts() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

public final class MemorySecretStorage: SecretItemStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]
    /// Accounts whose read fails, like a Keychain prompt the user declined.
    public var failReads: Set<String> = []
    public var failWrites = false
    public private(set) var reads: [String] = []
    public init(_ items: [String: Data] = [:]) { self.items = items }

    public func read(account: String) -> SecretRead {
        lock.lock(); defer { lock.unlock() }
        reads.append(account)
        if failReads.contains(account) { return .failed(errSecAuthFailed) }
        return items[account].map(SecretRead.found) ?? .missing
    }
    public func write(account: String, data: Data) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if failWrites { return errSecAuthFailed }
        items[account] = data; return errSecSuccess
    }
    public func delete(account: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if failWrites { return errSecAuthFailed }
        return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }
    public func accounts() -> [String] { lock.lock(); defer { lock.unlock() }; return items.keys.sorted() }
    public func data(account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func setLegacy(account: String, text: String) { lock.lock(); items[account] = Data(text.utf8); lock.unlock() }
}

struct VaultContents: Codable, Equatable {
    var version = 1
    /// The MCP access token.
    var bearer: String?
    /// This Mac's opt-in approvals session.
    var approvals: String?
    /// One credential per linked machine; each carries the one origin it may be sent to.
    var remote: [String: RemoteApprovalCredential] = [:]
    /// False while a legacy item could not be read, so the next launch tries again.
    var migrated = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        bearer = try c.decodeIfPresent(String.self, forKey: .bearer)
        approvals = try c.decodeIfPresent(String.self, forKey: .approvals)
        remote = try c.decodeIfPresent([String: RemoteApprovalCredential].self, forKey: .remote) ?? [:]
        migrated = try c.decodeIfPresent(Bool.self, forKey: .migrated) ?? true
    }
    enum Keys: String, CodingKey { case version, bearer, approvals, remote, migrated }

    var isEmpty: Bool { bearer == nil && approvals == nil && remote.isEmpty }
}

public final class KeychainVault: @unchecked Sendable {
    public static let account = "vault"
    static let legacyBearer = "bearer", legacyApprovals = "approvals-bearer", legacyRemotePrefix = "approvals-remote-"

    private enum State { case unloaded, loaded, blocked }
    private let storage: SecretItemStorage
    private let lock = NSLock()
    private var contents = VaultContents()
    private var state = State.unloaded
    private var legacyToDelete: [String] = []

    public init(storage: SecretItemStorage = SystemKeychainStorage()) { self.storage = storage }

    // MARK: Access (used by the three store views)

    /// Loads once per process. If the Keychain refused (declined prompt, locked), later reads see nothing and do not
    /// prompt again; the next write tries once more.
    func read<T>(_ body: (VaultContents) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        if state == .unloaded { load() }
        return body(contents)
    }

    func mutate(_ body: (inout VaultContents) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if state != .loaded { load() }
        guard state == .loaded else { throw HuddleError.toolFailed("Keychain unavailable") }
        var next = contents
        body(&next)
        guard next != contents else { return }
        try persist(next)
        contents = next
        flushLegacyDeletes()
    }

    // MARK: Loading and migration (lock held)

    private func load() {
        switch storage.read(account: Self.account) {
        case .found(let data):
            contents = (try? JSONDecoder().decode(VaultContents.self, from: data)) ?? VaultContents()
            state = .loaded
            if !contents.migrated { migrateLegacy() }
        case .missing:
            contents = VaultContents()
            state = .loaded
            migrateLegacy()
        case .failed:
            contents = VaultContents()
            state = .blocked
        }
    }

    /// Copies what earlier versions stored into the vault, then removes the old items. A slot the vault already holds is
    /// not read at all, so a newer credential is never replaced by an old one and no needless prompt is raised.
    private func migrateLegacy() {
        var next = contents
        var consumed: [String] = []
        var incomplete = false

        func take(_ account: String) -> Data? {
            switch storage.read(account: account) {
            case .found(let d): return d
            case .missing: return nil
            case .failed: incomplete = true; return nil
            }
        }
        if next.bearer == nil, let d = take(Self.legacyBearer), let s = String(data: d, encoding: .utf8), !s.isEmpty {
            next.bearer = s; consumed.append(Self.legacyBearer)
        }
        if next.approvals == nil, let d = take(Self.legacyApprovals), let s = String(data: d, encoding: .utf8), !s.isEmpty {
            next.approvals = s; consumed.append(Self.legacyApprovals)
        }
        for account in storage.accounts() where account.hasPrefix(Self.legacyRemotePrefix) {
            guard let id = String(account.dropFirst(Self.legacyRemotePrefix.count)).removingPercentEncoding, next.remote[id] == nil,
                  let d = take(account),
                  let c = try? JSONDecoder().decode(RemoteApprovalCredential.self, from: d), c.environmentId == id else { continue }
            next.remote[id] = c; consumed.append(account)
        }
        next.migrated = !incomplete
        guard next != contents else { return }
        contents = next                        // usable this session even if the write below fails
        legacyToDelete = consumed
        do { try persist(next); flushLegacyDeletes() }
        catch { /* the legacy items stay; the next launch migrates again */ }
    }

    // MARK: Writing (lock held)

    private func persist(_ next: VaultContents) throws {
        if next.isEmpty {
            let status = storage.delete(account: Self.account)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw HuddleError.toolFailed("Keychain delete failed (\(status))") }
            return
        }
        guard let data = try? JSONEncoder().encode(next) else { throw HuddleError.toolFailed("Could not encode the Keychain item") }
        let status = storage.write(account: Self.account, data: data)
        guard status == errSecSuccess else { throw HuddleError.toolFailed("Keychain save failed (\(status))") }
    }

    private func flushLegacyDeletes() {
        guard !legacyToDelete.isEmpty else { return }
        legacyToDelete = legacyToDelete.filter { account in
            let status = storage.delete(account: account)
            return !(status == errSecSuccess || status == errSecItemNotFound)
        }
    }
}

/// The MCP token (`.bearer`) or this Mac's approvals session (`.approvals`), as a view of the vault.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    public enum Slot: Sendable { case bearer, approvals }
    private let vault: KeychainVault
    private let slot: Slot
    public init(vault: KeychainVault, slot: Slot) { self.vault = vault; self.slot = slot }

    public func load() -> String? { vault.read { slot == .bearer ? $0.bearer : $0.approvals } }
    public func save(_ token: String) throws { try vault.mutate { if slot == .bearer { $0.bearer = token } else { $0.approvals = token } } }
    @discardableResult public func delete() -> Bool {
        do { try vault.mutate { if slot == .bearer { $0.bearer = nil } else { $0.approvals = nil } }; return true }
        catch { return false }
    }
}
