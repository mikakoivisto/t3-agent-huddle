import Testing
import Foundation
@testable import HuddleCore
import FakeT3

/// Drives the "browser": GET the authorize URL without following redirects, then GET the redirect (the app's loopback listener).
@Sendable func autoApprove(_ url: URL) {
    Task.detached {
        let s = LoopbackSession.make(timeout: 5)
        guard let (_, r) = try? await s.data(from: url), let http = r as? HTTPURLResponse,
              let loc = http.value(forHTTPHeaderField: "Location"), let u = URL(string: loc) else { return }
        _ = try? await s.data(from: u)
    }
}

@MainActor
@Suite("OAuth (PKCE, dynamic registration) against the fake authorization server")
struct OAuthTests {
    func realisticFake() async throws -> FakeT3Server {
        var o = FakeT3Server.Options(); o.acceptStaticToken = false   // what the real T3 did to the CLI token (Q4)
        return try await startFake(o)
    }

    @Test func pkceChallengeMatchesRFC7636Vector() {
        #expect(OAuthClient.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func fullFlowRegistersExchangesAndConnects() async throws {
        let s = try await realisticFake(); defer { s.stop() }
        let store = MemoryTokenStore()
        let cap = LogCapture()
        let m = HuddleModel(config: HuddleConfig(source: .fixed(s.url), tokenStore: store, log: cap.log, openURL: autoApprove))
        await m.refresh()
        #expect(m.state.connection == .unauthorized); #expect(s.requestCount == 0)    // no token → nothing sent
        await m.runSignIn()
        #expect(m.state.connection == .connected)
        #expect(s.registrations == 1)
        let token = try #require(store.load())
        #expect(token.hasPrefix("oauth-access-"))
        #expect(m.sessions.count == 4)
        #expect(cap.lines.allSatisfy { !$0.contains(token) })                          // never logged
        let req = try #require(s.tokenRequests.first)
        #expect(req["grant_type"] == "authorization_code" && req["client_id"] == "client-1")
        #expect(req["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
    }

    @Test func staticTokenIsRejectedLikeRealT3() async throws {
        let s = try await realisticFake(); defer { s.stop() }
        let store = MemoryTokenStore(token: s.token)
        let m = HuddleModel(config: HuddleConfig(source: .fixed(s.url), tokenStore: store))
        await m.refresh()
        #expect(m.state.connection == .unauthorized); #expect(m.connectNote?.contains("401") == true)
    }

    @Test func secondSignInReusesTheRegisteredClientWhenPortIsFree() async throws {
        // The second sign-in reuses the client only if the first one's port is still free; parallel tests can grab a freed port,
        // in which case registering again is the right behaviour. So allow a few independent attempts for the reuse to be seen.
        var reused = false
        for _ in 0..<5 {
            let s = try await realisticFake(); defer { s.stop() }
            let m = HuddleModel(config: HuddleConfig(source: .fixed(s.url), tokenStore: MemoryTokenStore(),
                                                     preferences: PreferencesStore(directory: tempDir()), openURL: autoApprove))
            await m.runSignIn(); await m.runSignIn()
            #expect(m.state.connection == .connected)
            if s.registrations == 1 { reused = true; break }
        }
        #expect(reused)
    }

    @Test func aForgedStateIsIgnoredAndTheRealRedirectStillCompletesSignIn() async throws {
        let s = try await realisticFake(); defer { s.stop() }
        let tamper: @Sendable (URL) -> Void = { url in
            Task.detached {
                let sess = LoopbackSession.make(timeout: 5)
                guard let (_, r) = try? await sess.data(from: url), let loc = (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
                      var c = URLComponents(string: loc) else { return }
                let real = c.url!
                c.queryItems = c.queryItems?.map { $0.name == "state" ? .init(name: "state", value: "forged") : $0 }
                _ = try? await sess.data(from: c.url!)         // a stray local request with the wrong state first
                _ = try? await sess.data(from: real)           // then the genuine redirect
            }
        }
        let store = MemoryTokenStore()
        let m = HuddleModel(config: HuddleConfig(source: .fixed(s.url), tokenStore: store, openURL: tamper))
        await m.runSignIn()
        #expect(store.load() != nil); #expect(m.connectNote == nil)                    // the forged request did not use up the attempt
        #expect(s.tokenRequests.count == 1)                                            // exactly one code exchanged: the real one
    }

    @Test func theCallbackListenerOnlyAnswersItsExactPathAndOwnState() {
        let box = CallbackBox(expectedState: "s1")
        func req(_ path: String) -> HTTPRequest { HTTPRequest(method: "GET", path: path, headers: [:], body: Data()) }
        #expect(box.handle(req("/callbackx?state=s1&code=c")).status == 404)           // exact path only
        #expect(box.handle(req("/other?state=s1")).status == 404)
        #expect(box.handle(req("/callback?code=c")).status == 400)                      // no state
        #expect(box.handle(req("/callback?state=wrong&code=c")).status == 400)          // wrong state: ignored, attempt still open
        #expect(box.handle(req("/callback?state=s1&code=c")).status == 200)             // the genuine one resolves it
    }

    @Test func userDenialSurfacesAndStoresNothing() async throws {
        let s = try await realisticFake(); defer { s.stop() }
        let deny: @Sendable (URL) -> Void = { url in
            Task.detached {
                let sess = LoopbackSession.make(timeout: 5)
                let q = FakeT3Server.query(url.absoluteString.replacingOccurrences(of: "http://127.0.0.1:\(url.port!)", with: ""))
                _ = try? await sess.data(from: URL(string: q["redirect_uri"]! + "?error=access_denied&error_description=User%20denied&state=\(q["state"]!)")!)
            }
        }
        let store = MemoryTokenStore()
        let m = HuddleModel(config: HuddleConfig(source: .fixed(s.url), tokenStore: store, openURL: deny))
        await m.runSignIn()
        #expect(store.load() == nil); #expect(m.connectNote?.contains("User denied") == true)
    }

    @Test func authorizationServerOnAnotherHostIsRefused() async throws {
        let evil = LoopbackHTTPServer { req in
            HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("""
            {"issuer":"http://evil.example","authorization_endpoint":"http://evil.example/a","token_endpoint":"http://evil.example/t","registration_endpoint":"http://evil.example/r"}
            """.utf8)) }
        let port = try await evil.start(); defer { evil.stop() }
        let c = try OAuthClient(mcpEndpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, log: HuddleLog(sink: { _ in }),
                                opener: { _ in Issue.record("must not open a browser") }, timeout: 2)
        await #expect(throws: HuddleError.self) { try await c.authorize() }
    }

    @Test func relayOrRemoteEndpointsAreRefusedBeforeAnyRequest() {
        #expect(throws: HuddleError.self) {
            try OAuthClient(mcpEndpoint: URL(string: "https://prod-example.t3coderelay.com/mcp")!, log: HuddleLog(sink: { _ in }), opener: { _ in })
        }
    }

    @Test func timeoutWhenNobodyApproves() async throws {
        let s = try await realisticFake(); defer { s.stop() }
        let c = try OAuthClient(mcpEndpoint: s.url, log: HuddleLog(sink: { _ in }), opener: { _ in }, timeout: 0.5)
        await #expect(throws: HuddleError.oauth("timed out waiting for approval")) { try await c.authorize() }
    }

    @Test func peerRefusalBlocksRegistration() async throws {
        struct No: PeerVerifier { func verify(pid: Int?, port: Int) -> Bool { false } }
        let s = try await realisticFake(); defer { s.stop() }
        let f = tempDir().appendingPathComponent("server-runtime.json")
        try #"{"host":"127.0.0.1","port":\#(s.port),"pid":1}"#.write(to: f, atomically: true, encoding: .utf8)
        let m = HuddleModel(config: HuddleConfig(source: .runtimeFile(Discovery(runtimeFile: f)), tokenStore: MemoryTokenStore(),
                                                 peerVerifier: No(), openURL: { _ in Issue.record("no browser") }))
        await m.runSignIn()
        #expect(s.requestCount == 0); #expect(s.registrations == 0)
    }
}
