import Testing
import Foundation
@testable import HuddleCore
import FakeT3

@Suite("Security basics (SPEC §10)")
struct SecurityTests {
    @Test @MainActor func tokenNeverAppearsInLogsEvenOn401AndErrors() async throws {
        let s = try await startFake(); defer { s.stop() }
        let cap = LogCapture()
        let secret = "SUPER-SECRET-TOKEN-12345"
        // Wrong token → 401 path; then right-looking path through the paste API.
        let m = makeModel(s, token: secret, log: cap.log)
        await m.refresh()
        await m.submitToken("ANOTHER-SECRET-TOKEN-999")
        s.stop(); try await Task.sleep(nanoseconds: 100_000_000)
        await m.refresh()
        #expect(!cap.lines.isEmpty)
        for l in cap.lines {
            #expect(!l.contains(secret)); #expect(!l.contains("ANOTHER-SECRET-TOKEN-999"))
        }
    }

    @Test func logScrubberRedactsBearerPatterns() {
        let cap = LogCapture()
        cap.log.register(secret: "abcd1234")
        cap.log.log("Authorization: Bearer eyJhbGciOi.payload.sig and raw abcd1234 end")
        let l = cap.lines[0]
        #expect(!l.contains("eyJhbGciOi")); #expect(!l.contains("abcd1234"))
    }

    @Test func redirectsAreNotFollowed() async throws {
        // A server that 302s to another loopback port must not receive the token.
        let hits = Hits()
        let target = LoopbackHTTPServer { req in hits.add(req.method, req.path, req.headers["authorization"]); return HTTPResponse(status: 200, body: Data("{}".utf8)) }
        let tPort = try await target.start(); defer { target.stop() }
        let redirector = LoopbackHTTPServer { _ in
            HTTPResponse(status: 302, headers: ["Location": "http://127.0.0.1:\(tPort)/mcp"]) }
        let rPort = try await redirector.start(); defer { redirector.stop() }
        let c = try MCPClient(endpoint: URL(string: "http://127.0.0.1:\(rPort)/mcp")!, token: "tok")
        await #expect(throws: HuddleError.self) { try await c.toolsList() }
        #expect(hits.count == 0)   // the redirect target received nothing at all: a followed redirect would have shown up here
    }

    @Test func fakeServerListensOnLoopbackOnly() async throws {
        let s = try await startFake(); defer { s.stop() }
        #expect(LoopbackGuard.isLoopbackHost(s.url.host!))
        let out = try shell("/usr/sbin/lsof", ["-nP", "-iTCP:\(s.port)", "-sTCP:LISTEN"])
        #expect(out.contains("127.0.0.1:\(s.port)"))
        #expect(!out.contains("*:\(s.port)") && !out.contains("0.0.0.0"))
    }

    @Test func loopbackGuardRules() {
        for ok in ["127.0.0.1", "::1", "[::1]"] { #expect(LoopbackGuard.isLoopbackHost(ok)) }
        for bad in ["localhost", "0.0.0.0", "127.0.0.2.evil.com", "10.0.0.1", "", "::"] { #expect(!LoopbackGuard.isLoopbackHost(bad)) }
    }

    @Test func sourcesTouchHomeT3OnlyForTheRuntimeFileAndNeverOpenSQLite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 5)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            let name = f.lastPathComponent
            #expect(!text.lowercased().contains("sqlite"), "\(name) mentions sqlite")
            #expect(!text.contains("userdata/secrets") && !text.contains("connection-catalog"), "\(name) reads T3 secrets")
            // ~/.t3 may appear only in Discovery (read server-runtime.json) and T3Jumper (exec ~/.t3/bin/t3 app).
            for line in text.split(separator: "\n") where line.contains(".t3/") {
                switch name {
                case "Discovery.swift": #expect(line.contains("userdata/server-runtime.json") || line.hasPrefix("///") || line.hasPrefix("//"), "\(line)")
                case "main.swift", "Scenario.swift", "FakeT3Server.swift": #expect(line.hasPrefix("//"), "\(name): \(line)")
                default: #expect(Bool(false), "\(name) references ~/.t3: \(line)")
                }
            }
            #expect(!text.contains("UserDefaults"), "\(name) uses UserDefaults")
        }
    }

    @Test func appBinaryDoesNotAcceptATokenOnTheCommandLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AgentHuddle")
        let text = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!text.contains("\"--token\""))
    }

    @Test func keychainStoreRoundTripIsSeparatedFromTests() {
        // Automated tests deliberately use MemoryTokenStore: a Keychain prompt would hang CI.
        let store = MemoryTokenStore()
        #expect(store.load() == nil); try? store.save("t"); #expect(store.load() == "t"); store.delete(); #expect(store.load() == nil)
    }
}

func shell(_ path: String, _ args: [String]) throws -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

@Suite("Listener ownership: the runtime file cannot pair a real pid with another process's port")
struct ListenerOwnershipTests {
    @Test func aProcessOwnsItsOwnLoopbackListenerAndNothingElse() async throws {
        let server = LoopbackHTTPServer { _ in HTTPResponse(status: 200) }
        let port = try await server.start(); defer { server.stop() }
        let me = Int(getpid())
        #expect(ListenerOwnership.pidOwnsLoopbackListener(pid: me, port: Int(port)))               // this process listens there
        #expect(!ListenerOwnership.pidOwnsLoopbackListener(pid: me, port: 1))   // a port this process does not listen on
        #expect(!ListenerOwnership.pidOwnsLoopbackListener(pid: 1, port: Int(port)))               // launchd does not own it
        #expect(!ListenerOwnership.pidOwnsLoopbackListener(pid: 0, port: Int(port)))
        #expect(!ListenerOwnership.pidOwnsLoopbackListener(pid: me, port: 0))
    }
}
