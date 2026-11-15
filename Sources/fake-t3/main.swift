import Foundation
import FakeT3

// fake-t3 — standalone fake T3 MCP server on 127.0.0.1 for demos and manual poking. Never talks to real T3.
//   fake-t3 [--port N]        default: ephemeral port. Prints the MCP URL, then serves until killed.
// The bearer token is the fixed dummy "fake-token" (override with $FAKE_T3_TOKEN).

var port: UInt16 = 0
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    if a == "--port", let v = args.next(), let p = UInt16(v) { port = p }
    else { FileHandle.standardError.write(Data("usage: fake-t3 [--port N]\n".utf8)); exit(2) }
}

var opts = FakeT3Server.Options()
if let t = ProcessInfo.processInfo.environment["FAKE_T3_TOKEN"] { opts.token = t }
let server = FakeT3Server(options: opts)
Scenario.populate(server)
try await server.start(port: port)
server.startTicker(interval: 1) { Scenario.advanceRender($0) }
print("fake T3 MCP listening on \(server.url.absoluteString) (127.0.0.1 only)")
print("token: \(opts.token)   — run: HUDDLE_MCP_TOKEN=\(opts.token) AgentHuddle --mcp-url \(server.url.absoluteString)")
fflush(stdout)
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
