import Testing
import Foundation
@testable import HuddleCore

/// The one-item Keychain vault and the migration from the old per-credential items. Runs on `MemorySecretStorage`:
/// a real Keychain prompt would hang CI.
@Suite("Keychain vault")
struct KeychainVaultTests {
    static let envA = "11111111-2222-3333-4444-555555555555"
    static let envB = "env_b/odd id"

    static func credential(_ id: String, token: String = "remote-token") -> RemoteApprovalCredential {
        RemoteApprovalCredential(environmentId: id, origin: "https://mac-mini.tailnet-demo.ts.net", token: token)
    }
    static func legacyStorage() throws -> MemorySecretStorage {
        let s = MemorySecretStorage()
        s.setLegacy(account: "bearer", text: "mcp-token")
        s.setLegacy(account: "approvals-bearer", text: "approvals-token")
        for id in [envA, envB] {
            let data = try JSONEncoder().encode(credential(id, token: "remote-\(id.count)"))
            s.setLegacy(account: KeychainRemoteCredentialStore.account(for: id), text: String(data: data, encoding: .utf8)!)
        }
        return s
    }
    static func stores(_ storage: MemorySecretStorage) -> (KeychainVault, KeychainTokenStore, KeychainTokenStore, KeychainRemoteCredentialStore) {
        let v = KeychainVault(storage: storage)
        return (v, KeychainTokenStore(vault: v, slot: .bearer), KeychainTokenStore(vault: v, slot: .approvals), KeychainRemoteCredentialStore(vault: v))
    }

    @Test func nothingIsWrittenOrPromptedUntilSomethingIsSaved() {
        let storage = MemorySecretStorage()
        let (_, bearer, approvals, remote) = Self.stores(storage)
        #expect(bearer.load() == nil && approvals.load() == nil && remote.environmentIds().isEmpty)
        #expect(storage.accounts().isEmpty)
    }

    @Test func everyCredentialSharesTheOneItem() throws {
        let storage = MemorySecretStorage()
        let (_, bearer, approvals, remote) = Self.stores(storage)
        try bearer.save("mcp"); try approvals.save("appr"); try remote.save(Self.credential(Self.envA))
        #expect(storage.accounts() == ["vault"])
        let (_, b2, a2, r2) = Self.stores(storage)       // a new process
        #expect(b2.load() == "mcp" && a2.load() == "appr" && r2.load(environmentId: Self.envA)?.token == "remote-token")
    }

    @Test func oneLaunchReadsTheItemOnce() throws {
        let storage = MemorySecretStorage()
        let (_, b0, a0, r0) = Self.stores(storage)
        try b0.save("mcp"); try a0.save("appr"); try r0.save(Self.credential(Self.envA))
        let fresh = MemorySecretStorage(["vault": try #require(storage.data(account: "vault"))])
        let (_, bearer, approvals, remote) = Self.stores(fresh)
        for _ in 0..<5 { _ = bearer.load(); _ = approvals.load(); _ = remote.load(environmentId: Self.envA); _ = remote.environmentIds() }
        #expect(fresh.reads == ["vault"], "many loads, one Keychain read")
    }

    // MARK: Migration

    @Test func theOldItemsAreCopiedIntoTheVaultAndRemoved() throws {
        let storage = try Self.legacyStorage()
        let (_, bearer, approvals, remote) = Self.stores(storage)
        #expect(bearer.load() == "mcp-token")
        #expect(approvals.load() == "approvals-token")
        #expect(remote.environmentIds() == [Self.envB, Self.envA].sorted())
        #expect(remote.load(environmentId: Self.envA)?.origin == "https://mac-mini.tailnet-demo.ts.net")
        #expect(remote.load(environmentId: Self.envB)?.environmentId == Self.envB)
        #expect(storage.accounts() == ["vault"], "legacy items are gone: \(storage.accounts())")
        // and it survives a restart
        let (_, b2, a2, r2) = Self.stores(storage)
        #expect(b2.load() == "mcp-token" && a2.load() == "approvals-token" && r2.environmentIds().count == 2)
    }

    @Test func aVaultThatExistsIsNeverOverwrittenByOldItems() throws {
        let storage = MemorySecretStorage()
        let (_, bearer, _, _) = Self.stores(storage)
        try bearer.save("new-token")
        storage.setLegacy(account: "bearer", text: "stale-token")
        let before = storage.reads.count
        let (_, b2, _, _) = Self.stores(storage)
        #expect(b2.load() == "new-token")
        #expect(storage.reads[before...] == ["vault"], "the old item is not even read")
    }

    @Test func aDeclinedOldItemIsKeptAndPickedUpOnTheNextLaunch() throws {
        let storage = try Self.legacyStorage()
        storage.failReads = ["approvals-bearer"]                     // the user declined that one prompt
        let (_, bearer, approvals, remote) = Self.stores(storage)
        #expect(bearer.load() == "mcp-token" && remote.environmentIds().count == 2)
        #expect(approvals.load() == nil)
        #expect(storage.accounts().contains("approvals-bearer"), "an item that could not be read is not deleted")
        #expect(!storage.accounts().contains("bearer"))

        storage.failReads = []                                       // next launch, the user says yes
        let (_, b2, a2, _) = Self.stores(storage)
        #expect(a2.load() == "approvals-token" && b2.load() == "mcp-token")
        #expect(storage.accounts() == ["vault"])
        let (_, _, a3, _) = Self.stores(storage)                     // and the work is not repeated
        let before = storage.reads.count
        #expect(a3.load() == "approvals-token")
        #expect(storage.reads.count == before + 1, "a finished migration reads only the vault")
    }

    @Test func aFailedWriteLeavesTheOldItemsAndStillWorksThisSession() throws {
        let storage = try Self.legacyStorage()
        storage.failWrites = true
        let (_, bearer, approvals, _) = Self.stores(storage)
        #expect(bearer.load() == "mcp-token" && approvals.load() == "approvals-token")
        #expect(storage.accounts().contains("bearer") && !storage.accounts().contains("vault"))
        storage.failWrites = false
        let (_, b2, _, r2) = Self.stores(storage)
        #expect(b2.load() == "mcp-token" && r2.environmentIds().count == 2)
        #expect(storage.accounts() == ["vault"])
    }

    @Test func aCredentialForTheWrongMachineOrGarbageIsNotMigratedOrDeleted() throws {
        let storage = MemorySecretStorage()
        let data = try JSONEncoder().encode(Self.credential("some-other-env"))
        storage.setLegacy(account: KeychainRemoteCredentialStore.account(for: Self.envA), text: String(data: data, encoding: .utf8)!)
        storage.setLegacy(account: "bearer", text: "")
        let (_, bearer, _, remote) = Self.stores(storage)
        #expect(bearer.load() == nil && remote.load(environmentId: Self.envA) == nil && remote.environmentIds().isEmpty)
        #expect(storage.accounts().count == 2, "nothing was destroyed")
    }

    // MARK: Failure and removal

    @Test func aRefusedVaultReadIsNotRetriedUntilTheNextWrite() throws {
        let storage = MemorySecretStorage()
        let (_, seed, _, _) = Self.stores(storage)
        try seed.save("mcp")
        storage.failReads = ["vault"]
        let before = storage.reads.count
        let (_, bearer, approvals, remote) = Self.stores(storage)
        for _ in 0..<5 { #expect(bearer.load() == nil && approvals.load() == nil && remote.environmentIds().isEmpty) }
        #expect(storage.reads[before...].filter { $0 == "vault" }.count == 1, "no prompt storm after Deny")
        #expect((try? approvals.save("x")) == nil, "a write cannot overwrite what could not be read")
        #expect(!approvals.delete())
        storage.failReads = []
        try approvals.save("appr")                                   // one retry on the write path
        #expect(bearer.load() == "mcp" && approvals.load() == "appr", "the unreadable item was merged, not replaced")
    }

    @Test func turningOffRemovesOnlyThatCredentialAndTheLastOneRemovesTheItem() throws {
        let storage = MemorySecretStorage()
        let (_, bearer, approvals, remote) = Self.stores(storage)
        try bearer.save("mcp"); try approvals.save("appr"); try remote.save(Self.credential(Self.envA)); try remote.save(Self.credential(Self.envB))
        #expect(remote.delete(environmentId: Self.envA) && remote.load(environmentId: Self.envA) == nil && remote.load(environmentId: Self.envB) != nil)
        #expect(approvals.delete() && approvals.load() == nil && bearer.load() == "mcp")
        let (_, _, a2, _) = Self.stores(storage)
        #expect(a2.load() == nil, "gone after a restart too")
        #expect(approvals.delete(), "deleting what is not there is fine and writes nothing")
        #expect(remote.delete(environmentId: Self.envB) && bearer.delete())
        #expect(storage.accounts().isEmpty, "an empty vault is deleted, not left behind")
    }

    @Test func aFailedDeleteReportsIt() throws {
        let storage = MemorySecretStorage()
        let (_, _, approvals, _) = Self.stores(storage)
        try approvals.save("appr")
        storage.failWrites = true
        #expect(!approvals.delete(), "the model must keep inline approvals on and say so")
        #expect(approvals.load() == "appr")
    }
}
