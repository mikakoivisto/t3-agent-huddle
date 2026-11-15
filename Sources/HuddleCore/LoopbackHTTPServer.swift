import Foundation
import Network
import CryptoKit

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]   // lower-cased names
    public var body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}

/// Tiny HTTP/1.1 server bound to **127.0.0.1 only** on an ephemeral port (or a fixed one).
/// Used by the fake T3 (tests/demo) and for the one-shot OAuth redirect listener (SPEC §7.4).
public final class LoopbackHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse
    /// WebSocket upgrade: accept (every text frame gets the returned text frames back) or answer with a plain HTTP response.
    public enum WebSocketDecision: Sendable {
        case reject(HTTPResponse)
        case accept(onText: @Sendable (String) -> [String])
    }
    public typealias WebSocketHandler = @Sendable (HTTPRequest) -> WebSocketDecision
    private let handler: Handler
    private let webSocket: WebSocketHandler?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fake-t3.http")
    public private(set) var port: UInt16 = 0
    /// A request (headers plus body) larger than this, or one that is not complete within `requestDeadline`, is dropped.
    public var maxRequestBytes = 4 * 1024 * 1024
    public var requestDeadline: TimeInterval = 30

    public init(handler: @escaping Handler, webSocket: WebSocketHandler? = nil) { self.handler = handler; self.webSocket = webSocket }

    public func start(port requested: UInt16 = 0) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: requested == 0 ? .any : NWEndpoint.Port(rawValue: requested)!)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        return try await withCheckedThrowingContinuation { cont in
            let done = NSLock(); var resumed = false
            l.stateUpdateHandler = { [weak self, weak l] state in
                done.lock(); defer { done.unlock() }
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    self?.port = l?.port?.rawValue ?? 0
                    cont.resume(returning: self?.port ?? 0)
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    public func stop() { listener?.cancel(); listener = nil }

    private final class Progress: @unchecked Sendable { var parsed = false }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let progress = Progress()
        queue.asyncAfter(deadline: .now() + requestDeadline) { if !progress.parsed { conn.cancel() } }   // a stalled or trickling client
        receive(conn, buffer: Data(), progress: progress)
    }

    private func receive(_ conn: NWConnection, buffer: Data, progress: Progress) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > self.maxRequestBytes {
                conn.send(content: Self.serialize(HTTPResponse(status: 413)), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            if let req = Self.parse(buf) {
                progress.parsed = true
                if let ws = self.webSocket, req.headers["upgrade"]?.lowercased() == "websocket", let key = req.headers["sec-websocket-key"] {
                    switch ws(req) {
                    case .reject(let r): conn.send(content: Self.serialize(r), completion: .contentProcessed { _ in conn.cancel() })
                    case .accept(let onText): self.upgrade(conn, key: key, onText: onText)
                    }
                    return
                }
                let resp = self.handler(req)
                conn.send(content: Self.serialize(resp), completion: .contentProcessed { _ in conn.cancel() })
            } else if error != nil || isComplete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf, progress: progress)
            }
        }
    }

    // MARK: WebSocket (RFC 6455, just enough for the fake: masked client text frames in, unmasked text frames out)

    private func upgrade(_ conn: NWConnection, key: String, onText: @escaping @Sendable (String) -> [String]) {
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in self?.readFrames(conn, buffer: Data(), onText: onText) })
    }

    private func readFrames(_ conn: NWConnection, buffer: Data, onText: @escaping @Sendable (String) -> [String]) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            while let (opcode, payload, used) = Self.parseFrame(buf) {
                buf.removeFirst(used)
                switch opcode {
                case 1:
                    for reply in onText(String(decoding: payload, as: UTF8.self)) { conn.send(content: Self.textFrame(reply), completion: .idempotent) }
                case 9: conn.send(content: Self.frame(opcode: 10, payload: payload), completion: .idempotent)
                case 8: conn.send(content: Self.frame(opcode: 8, payload: Data()), completion: .contentProcessed { _ in conn.cancel() }); return
                default: break
                }
            }
            if error != nil || isComplete { conn.cancel() } else { self.readFrames(conn, buffer: buf, onText: onText) }
        }
    }

    static func parseFrame(_ d: Data) -> (opcode: UInt8, payload: Data, used: Int)? {
        let b = [UInt8](d)
        guard b.count >= 2 else { return nil }
        let opcode = b[0] & 0x0F, masked = b[1] & 0x80 != 0
        var len = Int(b[1] & 0x7F), i = 2
        if len == 126 { guard b.count >= 4 else { return nil }; len = Int(b[2]) << 8 | Int(b[3]); i = 4 }
        else if len == 127 { guard b.count >= 10 else { return nil }; len = (2..<10).reduce(0) { $0 << 8 | Int(b[$1]) }; i = 10 }
        let mask: [UInt8] = masked ? (b.count >= i + 4 ? Array(b[i..<i + 4]) : []) : [0, 0, 0, 0]
        if masked { guard mask.count == 4 else { return nil }; i += 4 }
        guard b.count >= i + len else { return nil }
        let payload = (0..<len).map { b[i + $0] ^ mask[$0 % 4] }
        return (opcode, Data(payload), i + len)
    }

    static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        if payload.count < 126 { out.append(UInt8(payload.count)) }
        else if payload.count < 65536 { out.append(126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF)) }
        else { out.append(127); for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((payload.count >> s) & 0xFF)) } }
        return out + payload
    }
    static func textFrame(_ text: String) -> Data { frame(opcode: 1, payload: Data(text.utf8)) }

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[range.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }

    static func serialize(_ r: HTTPResponse) -> Data {
        let reason = [200: "OK", 201: "Created", 202: "Accepted", 302: "Found", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 413: "Payload Too Large", 426: "Upgrade Required", 500: "Internal Server Error"][r.status] ?? "OK"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        var h = r.headers
        // "X-Close-Delimited" (tests) sends a body of unknown length, ended by closing the connection, like a chunked response.
        if h.removeValue(forKey: "X-Close-Delimited") == nil { h["Content-Length"] = String(r.body.count) }
        h["Connection"] = "close"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        return Data(head.utf8) + Data("\r\n".utf8) + r.body
    }
}
