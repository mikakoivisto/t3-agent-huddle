import Foundation
import HuddleCore
import FakeT3

func fixture(_ name: String) throws -> JSON {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).json")
    return try JSON.parse(try Data(contentsOf: url))
}

func startFake(_ options: FakeT3Server.Options = .init(), populate: Bool = true) async throws -> FakeT3Server {
    let s = FakeT3Server(options: options)
    if populate { Scenario.populate(s) }
    try await s.start()
    return s
}

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("huddle-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

final class LogCapture: @unchecked Sendable {
    private let lock = NSLock(); private var _lines: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    lazy var log = HuddleLog { [self] l in lock.lock(); _lines.append(l); lock.unlock() }
}

@MainActor
func makeModel(_ server: FakeT3Server, token: String? = nil, log: HuddleLog = HuddleLog(sink: { _ in }),
               jumper: Jumper = RecordingJumper(), prefs: PreferencesStore? = nil,
               store: TokenStore? = nil, approvals: TokenStore = MemoryTokenStore()) -> HuddleModel {
    HuddleModel(config: HuddleConfig(source: .fixed(server.url),
                                     tokenStore: store ?? MemoryTokenStore(token: token ?? server.token),
                                     approvalStore: approvals,
                                     preferences: prefs, log: log, jumper: jumper))
}
