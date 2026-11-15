import Testing
import Foundation
@testable import HuddleCore
import FakeT3

/// Machines (spec 15): T3 on this Mac or on another machine, each reached through its own MCP. Two fakes on loopback stand in
/// for the two machines; the remote one is reached with the loopback fixture policy (production refuses http and IPs).
@Suite("Machines (spec 15)")
@MainActor
struct MachinesTests {
    static let env = "env_remote"
    static let remoteRunning = "thr_remote_running"
    static let remoteQuestion = "thr_remote_question"

    func remoteFake(_ change: ((inout FakeT3Server.Options) -> Void)? = nil) async throws -> FakeT3Server {
        var o = FakeT3Server.Options()
        o.environmentId = Self.env; o.environmentLabel = "Studio Mac"; o.localEnvironmentLabel = "Studio Mac"
        change?(&o)
        let r = FakeT3Server(options: o)
        r.add(.init(id: Self.remoteRunning, title: "Remote render", status: "running", items: [Scenario.cmd(0, "make", output: "ok")], environmentId: Self.env))
        r.add(.init(id: Self.remoteQuestion, title: "Remote question", status: "waiting", questions: [
            .init(requestId: "rq_remote", header: "PICK", question: "Which?", options: ["A", "B"])], environmentId: Self.env))
        try await r.start()
        return r
    }

    func credential(_ r: FakeT3Server, id: String = env, token: String? = nil) -> MachineCredential {
        MachineCredential(environmentId: id, origin: "http://127.0.0.1:\(r.port)", token: token ?? r.token, label: "Studio Mac")
    }

    /// No T3 on this Mac: a config whose local source answers nothing and holds no token.
    func noLocalModel(_ store: MachineCredentialStore, openURL: @escaping @Sendable (URL) -> Void = { _ in }) -> HuddleModel {
        HuddleModel(config: HuddleConfig(source: .fixed(URL(string: "http://127.0.0.1:9/mcp")!), tokenStore: MemoryTokenStore(),
                                         remotePolicy: .loopbackFixture, machineStore: store, log: HuddleLog(sink: { _ in }), openURL: openURL))
    }

    // MCH-01
    @Test func withNoT3HereAnotherMachineIsListedAnsweredAndMessaged() async throws {
        let r = try await remoteFake(); defer { r.stop() }
        let m = noLocalModel(MemoryMachineCredentialStore([credential(r)]))
        await m.refresh()
        let running = try #require(m.state.sessions[Self.remoteRunning])
        #expect(running.environmentId == Self.env, "the row carries the machine the app listed it from")
        #expect(m.machineStatus[Self.env] == .connected)
        #expect(m.groups.map(\.label) == ["Studio Mac"])
        #expect(m.canMessage(running) && m.canAnswer(running))

        m.composer.drafts[ComposerStore.messageKey(Self.remoteRunning)] = "hello from the panel"
        await m.sendMessage(threadId: Self.remoteRunning)
        #expect(r.sends.map(\.message) == ["hello from the panel"])
        #expect(r.sends.first?.environmentId == nil, "sent to that machine's own T3, not through a link")

        let q = try #require(m.state.sessions[Self.remoteQuestion]?.question)
        m.select(option: "B", for: q); await m.sendAnswer(threadId: Self.remoteQuestion)
        #expect(r.answers.count == 1)
    }

    @Test func aMachineConnectedDirectlyIsNotAlsoReadThroughTheLink() async throws {
        let two = try await startTwoMachines(); defer { two.stop() }
        let store = MemoryMachineCredentialStore([credential(two.remote)])
        let m = HuddleModel(config: HuddleConfig(source: .fixed(two.local.url), tokenStore: MemoryTokenStore(token: two.local.token),
                                                 remotePolicy: .loopbackFixture, machineStore: store, log: HuddleLog(sink: { _ in })))
        await m.refresh()
        let bench = try #require(m.state.sessions[Scenario.remoteApprovalThread])
        #expect(bench.environmentId == Self.env && !m.isLinkedOnly(bench))
        #expect(!two.local.calls.contains { $0.args["environmentId"].string == Self.env }, "no call goes through this Mac's link for it")
        #expect(two.remote.calls.contains { $0.tool == "t3_thread_list" })
        #expect(m.groups.map(\.label).count == 2)
    }

    // MCH-03
    @Test func aMachineThatGoesAwayDoesNotStopTheOthers() async throws {
        let two = try await startTwoMachines(); defer { two.stop() }
        let store = MemoryMachineCredentialStore([credential(two.remote)])
        let m = HuddleModel(config: HuddleConfig(source: .fixed(two.local.url), tokenStore: MemoryTokenStore(token: two.local.token),
                                                 remotePolicy: .loopbackFixture, machineStore: store, log: HuddleLog(sink: { _ in })))
        await m.refresh()
        #expect(m.state.sessions[Scenario.remoteApprovalThread] != nil)
        two.remote.stop()
        await m.refresh(force: true)
        #expect(m.state.connection == .connected, "this Mac is unaffected")
        #expect(m.state.sessions[Scenario.renderThread] != nil)
        if case .offline = m.machineStatus[Self.env] {} else { Issue.record("expected offline, got \(String(describing: m.machineStatus[Self.env]))") }
        #expect(m.state.sessions[Scenario.remoteApprovalThread] != nil, "its last list stays for a short while")
        #expect(store.load(environmentId: Self.env) != nil, "going offline keeps the sign-in")
    }

    @Test func aRefusedToolCallDoesNotTakeTheMachineOffline() async throws {
        let r = try await remoteFake { $0.modeEscalationDenied = true }; defer { r.stop() }
        let m = noLocalModel(MemoryMachineCredentialStore([credential(r)]))
        await m.refresh()
        m.composer.drafts[ComposerStore.messageKey(Self.remoteRunning)] = "hi"
        await m.sendMessage(threadId: Self.remoteRunning)
        #expect(m.composeStates[Self.remoteRunning] == .error(HuddleModel.modeDeniedMessage))
        #expect(m.machineStatus[Self.env] == .connected, "a refusal is the call's, not the machine's")
        await m.refresh(force: true)
        #expect(m.state.sessions[Self.remoteRunning] != nil && m.machineStatus[Self.env] == .connected)
    }

    @Test func aFailedMachineSignOutSaysSo() async throws {
        let r = try await remoteFake(); defer { r.stop() }
        let store = MemoryMachineCredentialStore([credential(r)]); store.refuseDelete = true
        let m = noLocalModel(store)
        await m.refresh()
        #expect(!m.signOutMachine(Self.env))
        if case .failed? = m.machineSignIns[Self.env] {} else { Issue.record("expected a message") }
        #expect(m.connectedMachineIds.contains(Self.env))
    }

    // MCH-05
    @Test func aRejectedTokenDropsOnlyThatMachine() async throws {
        let two = try await startTwoMachines(); defer { two.stop() }
        let store = MemoryMachineCredentialStore([credential(two.remote, token: "revoked-token")])
        let local = MemoryTokenStore(token: two.local.token)
        let m = HuddleModel(config: HuddleConfig(source: .fixed(two.local.url), tokenStore: local,
                                                 remotePolicy: .loopbackFixture, machineStore: store, log: HuddleLog(sink: { _ in })))
        await m.refresh()
        #expect(m.machineStatus[Self.env] == .signInExpired)
        #expect(store.load(environmentId: Self.env) == nil && !m.connectedMachineIds.contains(Self.env))
        #expect(local.load() == two.local.token && m.state.connection == .connected, "this Mac's sign-in is untouched")
    }

    // MCH-02
    @Test func aMachineThatAnswersAsAnotherGetsNoToken() async throws {
        let r = try await remoteFake(); defer { r.stop() }
        let store = MemoryMachineCredentialStore([credential(r, id: "env_expected")])
        let m = noLocalModel(store)
        await m.refresh()
        if case .offline = m.machineStatus["env_expected"] {} else { Issue.record("expected offline") }
        #expect(r.calls.isEmpty, "the identity check failed before any MCP call carried the token")
        #expect(m.state.sessions.isEmpty)
    }

    @Test func theProductionPolicyRefusesPlainHttpAndAddresses() async throws {
        let store = MemoryMachineCredentialStore([MachineCredential(environmentId: Self.env, origin: "http://studio.example.ts.net", token: "t")])
        let m = HuddleModel(config: HuddleConfig(source: .fixed(URL(string: "http://127.0.0.1:9/mcp")!), tokenStore: MemoryTokenStore(),
                                                 machineStore: store, log: HuddleLog(sink: { _ in })))
        await m.refresh()
        if case .offline = m.machineStatus[Self.env] {} else { Issue.record("http must be refused for another machine") }
        await #expect(throws: (any Error).self) { try await m.identifyMachine(address: "100.64.1.2") }
    }

    // MCH-04
    @Test func aLinkedOnlyMachineIsReadOnly() async throws {
        let two = try await startTwoMachines(); defer { two.stop() }
        let m = makeRemoteModel(two)
        await m.refresh()
        let bench = try #require(m.state.sessions[Scenario.remoteApprovalThread])
        #expect(m.isLinkedOnly(bench) && !m.canAnswer(bench) && !m.canMessage(bench))
    }

    // Adding a machine: identify (nothing secret), sign in on that machine's page, then it is listed.
    @Test func addingAMachineSignsInOnThatMachineAndStoresItsOwnClient() async throws {
        let r = try await remoteFake { $0.acceptStaticToken = false }; defer { r.stop() }
        let store = MemoryMachineCredentialStore()
        let m = noLocalModel(store, openURL: autoApprove)
        await m.refresh()
        #expect(m.state.sessions.isEmpty)
        let found = try await m.identifyMachine(address: "http://127.0.0.1:\(r.port)")
        #expect(found.environmentId == Self.env && found.label == "Studio Mac")
        #expect(r.calls.isEmpty && r.registrations == 0, "identifying sends nothing secret and registers nothing")
        await m.runMachineSignIn(found)
        let saved = try #require(store.load(environmentId: Self.env))
        #expect(saved.token.hasPrefix("oauth-access-") && saved.origin == "http://127.0.0.1:\(r.port)" && saved.oauthClientId == "client-1")
        #expect(r.registrations == 1, "the client is registered on that machine")
        #expect(m.state.sessions[Self.remoteRunning] != nil)
        #expect(m.signOutMachine(Self.env))
        #expect(store.load(environmentId: Self.env) == nil)
    }

    @Test func thisMacCannotBeAddedAsAnotherMachine() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = HuddleModel(config: HuddleConfig(source: .fixed(s.url), tokenStore: MemoryTokenStore(token: s.token),
                                                 remotePolicy: .loopbackFixture, log: HuddleLog(sink: { _ in })))
        await m.refresh()
        await #expect(throws: (any Error).self) { try await m.identifyMachine(address: "http://127.0.0.1:\(s.port)") }
    }

    @Test func aVaultWrittenByTheEarlierVersionStillOpens() throws {
        // The exact shape v0.1.1 wrote: no `machines` field.
        let old = #"{"version":1,"bearer":"local-token","approvals":"appr","remote":{"env_remote":{"environmentId":"env_remote","origin":"https://studio.ts.net","token":"r"}},"migrated":true}"#
        let storage = MemorySecretStorage(["vault": Data(old.utf8)])
        let vault = KeychainVault(storage: storage)
        #expect(KeychainTokenStore(vault: vault, slot: .bearer).load() == "local-token")
        #expect(KeychainTokenStore(vault: vault, slot: .approvals).load() == "appr")
        #expect(KeychainRemoteCredentialStore(vault: vault).load(environmentId: "env_remote")?.token == "r")
        #expect(KeychainMachineStore(vault: vault).environmentIds().isEmpty)
    }

    // MCH-06
    @Test func theVaultKeepsMachineSignInsBesideTheOthers() throws {
        let storage = MemorySecretStorage()
        let vault = KeychainVault(storage: storage)
        let machines = KeychainMachineStore(vault: vault)
        try KeychainTokenStore(vault: vault, slot: .bearer).save("local")
        try machines.save(MachineCredential(environmentId: Self.env, origin: "https://studio.ts.net", token: "remote"))
        #expect(storage.accounts() == ["vault"])
        let again = KeychainMachineStore(vault: KeychainVault(storage: storage))
        #expect(again.load(environmentId: Self.env)?.token == "remote")
        #expect(KeychainTokenStore(vault: vault, slot: .bearer).delete())
        #expect(storage.accounts() == ["vault"], "the item stays while a machine sign-in is still in it")
        #expect(machines.delete(environmentId: Self.env) && storage.accounts().isEmpty)
    }
}
