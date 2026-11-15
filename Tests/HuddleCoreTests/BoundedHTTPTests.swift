import Testing
import Foundation
import Network
@testable import HuddleCore

@Suite("Bounded HTTP reads and the loopback listener's limits")
struct BoundedHTTPTests {
    @Test func aResponseOverTheLimitIsRejectedWhileItArrives() async throws {
        let big = Data(repeating: 0x61, count: 2 * 1024 * 1024)
        let server = LoopbackHTTPServer { _ in HTTPResponse(status: 200, body: big) }
        let port = try await server.start(); defer { server.stop() }
        let session = LoopbackSession.make(timeout: 10)
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        await #expect(throws: HuddleError.self) { _ = try await BoundedHTTP.data(for: URLRequest(url: url), session: session, limit: 64 * 1024) }
        let (data, _) = try await BoundedHTTP.data(for: URLRequest(url: url), session: session, limit: 4 * 1024 * 1024)   // under the limit: fine
        #expect(data.count == big.count)
    }

    @Test func aResponseOfUnknownLengthIsCutOffAtTheLimitToo() async throws {
        // No Content-Length (a close-delimited body, like a chunked one): the limit must act while the bytes arrive.
        let big = Data(repeating: 0x61, count: 2 * 1024 * 1024)
        let server = LoopbackHTTPServer { _ in HTTPResponse(status: 200, headers: ["X-Close-Delimited": "1"], body: big) }
        let port = try await server.start(); defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let session = LoopbackSession.make(timeout: 10)
        await #expect(throws: HuddleError.self) { _ = try await BoundedHTTP.data(for: URLRequest(url: url), session: session, limit: 64 * 1024) }
        let (data, _) = try await BoundedHTTP.data(for: URLRequest(url: url), session: session, limit: 4 * 1024 * 1024)
        #expect(data.count == big.count)
    }

    @Test func aRequestOverTheLimitIsRefusedWith413() async throws {
        let server = LoopbackHTTPServer { _ in HTTPResponse(status: 200) }
        server.maxRequestBytes = 8 * 1024
        let port = try await server.start(); defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        req.httpMethod = "POST"; req.httpBody = Data(repeating: 0x62, count: 256 * 1024)
        let (_, resp) = try await LoopbackSession.make(timeout: 10).data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 413)
    }

    @Test func aClientThatNeverFinishesItsHeadersIsDroppedAtTheDeadline() async throws {
        let server = LoopbackHTTPServer { _ in HTTPResponse(status: 200) }
        server.requestDeadline = 0.3
        let port = try await server.start(); defer { server.stop() }
        let conn = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let closed: Bool = await withCheckedContinuation { cont in
            let lock = NSLock(); var done = false
            func finish(_ v: Bool) { lock.lock(); defer { lock.unlock() }; if !done { done = true; cont.resume(returning: v) } }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data("GET / HTTP/1.1\r\nHost: x\r\nX-Slow: ".utf8), completion: .contentProcessed { _ in })   // never ends the headers
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, complete, error in finish(complete || error != nil) }
                case .failed, .cancelled: finish(true)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(false) }
        }
        conn.cancel()
        #expect(closed)
    }
}
