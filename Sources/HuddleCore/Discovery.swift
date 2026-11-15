import Foundation

public struct Endpoint: Equatable, Sendable {
    public var url: URL            // …/mcp
    public var pid: Int?
}

/// Reads `server-runtime.json` (the one T3 file the huddle reads, SPEC §10) and refuses non-loopback hosts.
public struct Discovery: Sendable {
    public var runtimeFile: URL
    public init(runtimeFile: URL) { self.runtimeFile = runtimeFile }

    public static var defaultRuntimeFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/server-runtime.json")
    }

    public func resolve() throws -> Endpoint {
        guard FileManager.default.fileExists(atPath: runtimeFile.path) else { throw HuddleError.runtimeFileMissing }
        // A small regular file owned by this user: no symlink, no other owner, no huge file.
        var st = stat()
        guard lstat(runtimeFile.path, &st) == 0 else { throw HuddleError.runtimeFileMissing }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_size < 64 * 1024 else {
            throw HuddleError.runtimeFileInvalid("not a small regular file owned by you")
        }
        let data: Data
        do { data = try Data(contentsOf: runtimeFile) } catch { throw HuddleError.runtimeFileMissing }
        guard let json = try? JSON.parse(data), json.object != nil else {
            throw HuddleError.runtimeFileInvalid("not a JSON object")
        }
        guard let host = json["host"].string, let port = json["port"].int, (1...65535).contains(port) else {
            throw HuddleError.runtimeFileInvalid("host/port missing")
        }
        guard LoopbackGuard.isLoopbackHost(host) else { throw HuddleError.nonLoopback(host) }
        let hostPart = host.contains(":") ? "[\(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]" : host
        guard let url = URL(string: "http://\(hostPart):\(port)/mcp") else {
            throw HuddleError.runtimeFileInvalid("bad url")
        }
        try LoopbackGuard.validate(url)
        return Endpoint(url: url, pid: json["pid"].int)
    }
}

/// "Verify the peer before sending the token" (SPEC §10).
public protocol PeerVerifier: Sendable {
    /// `pid` and `port` come from the runtime file. A verifier must tie them together (the process owns that listener).
    func verify(pid: Int?, port: Int) -> Bool
}
public struct AcceptAnyPeer: PeerVerifier {
    public init() {}
    public func verify(pid: Int?, port: Int) -> Bool { true }
}
