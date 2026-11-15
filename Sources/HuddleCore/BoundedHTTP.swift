import Foundation

/// Reads an HTTP response with a size limit enforced while the bytes arrive, so a hostile or broken server cannot make the app
/// buffer an unbounded body (`URLSession.data(for:)` would). Used for every request the app makes to T3 or a linked machine.
public enum BoundedHTTP {
    /// MCP tool results (thread activity pages, long item text).
    public static let mcpLimit = 8 * 1024 * 1024
    /// OAuth metadata, registration and token responses; the public environment descriptor; the login exchange.
    public static let smallLimit = 1024 * 1024

    public static func data(for request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(limit) { throw HuddleError.badResponse("The response is larger than \(limit / 1024) KiB.") }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(min(response.expectedContentLength, Int64(limit)))) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw HuddleError.badResponse("The response is larger than \(limit / 1024) KiB.") }
        }
        return (data, response)
    }
}
