import Testing
import Foundation
@testable import HuddleCore

@Suite("Discovery")
struct DiscoveryTests {
    func write(_ json: String) -> URL {
        let f = tempDir().appendingPathComponent("server-runtime.json")
        try! json.write(to: f, atomically: true, encoding: .utf8); return f
    }

    @Test func resolvesLoopbackRuntimeFile() throws {
        let f = write(#"{"host":"127.0.0.1","port":3773,"origin":"http://127.0.0.1:3773","pid":42,"serverVersion":"0.1.9"}"#)
        let ep = try Discovery(runtimeFile: f).resolve()
        #expect(ep.url.absoluteString == "http://127.0.0.1:3773/mcp"); #expect(ep.pid == 42)
    }
    @Test func missingFile() {
        let f = tempDir().appendingPathComponent("nope.json")
        #expect(throws: HuddleError.runtimeFileMissing) { try Discovery(runtimeFile: f).resolve() }
    }
    @Test func nonLoopbackHostRefused() {
        for host in ["0.0.0.0", "192.168.1.20", "example.com", "100.64.0.1", "localhost"] {
            let f = write(#"{"host":"\#(host)","port":3773}"#)
            #expect(throws: HuddleError.nonLoopback(host)) { try Discovery(runtimeFile: f).resolve() }
        }
    }
    @Test func ipv6LoopbackAccepted() throws {
        let f = write(#"{"host":"::1","port":4000}"#)
        #expect(try Discovery(runtimeFile: f).resolve().url.absoluteString == "http://[::1]:4000/mcp")
    }
    @Test func invalidFiles() {
        #expect(throws: HuddleError.self) { try Discovery(runtimeFile: write("not json")).resolve() }
        #expect(throws: HuddleError.self) { try Discovery(runtimeFile: write(#"{"host":"127.0.0.1"}"#)).resolve() }
        #expect(throws: HuddleError.self) { try Discovery(runtimeFile: write(#"{"host":"127.0.0.1","port":0}"#)).resolve() }
    }
    @Test func portChangeIsPickedUpOnNextResolve() throws {
        let f = write(#"{"host":"127.0.0.1","port":3773}"#)
        let d = Discovery(runtimeFile: f)
        #expect(try d.resolve().url.port == 3773)
        try #"{"host":"127.0.0.1","port":4001}"#.write(to: f, atomically: true, encoding: .utf8)
        #expect(try d.resolve().url.port == 4001)
    }
}
