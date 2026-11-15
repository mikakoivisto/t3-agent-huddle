import AppKit
import SwiftUI
import HuddleCore
import FakeT3

// Agent Huddle — native macOS companion for T3 Code (SPEC §6).
//
//   AgentHuddle                       live: runtime file + Keychain token + real jump
//   AgentHuddle --fixture             in-process fake T3 on 127.0.0.1 (no T3, no Keychain, jump is a log stub)
//   AgentHuddle --mcp-url URL         any loopback MCP URL (e.g. `fake-t3`); token from $HUDDLE_MCP_TOKEN (default: fake-token)
//   AgentHuddle --snapshot DIR        render the UI states to PNGs against the fake machines and exit
//   AgentHuddle --record DIR          scripted run against the fake machines: frames of the live panel + stills (demo/)
//   AgentHuddle --prefs-dir DIR       store preferences here instead of ~/Library/Application Support/AgentHuddle
//
// There is deliberately no --token flag: tokens never go on a command line (SPEC §10).

struct Options {
    var fixture = false
    var mcpURL: URL?
    var snapshotDir: URL?
    var prefsDir: URL?
    var sound = false
    var noToken = false
    var iconFile: URL?
    var printWindowId = false
    var recordDir: URL?
    var runtimeFile: URL?
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--sound": o.sound = true
        case "--icon": if let v = it.next() { o.iconFile = URL(fileURLWithPath: v) }   // render the 1024px app icon and exit (build-app.sh)
#if DEBUG
        // Development and demo switches. A release build refuses all of them, so nothing that launches the shipped app (a login
        // item, another process) can redirect its token to another endpoint, swap the credential stores, or move its files.
        case "--fixture": o.fixture = true
        case "--no-token": o.noToken = true   // with --fixture: start signed out; "Connect" runs the OAuth flow against the fake and auto-approves
        case "--record": if let v = it.next() { o.recordDir = URL(fileURLWithPath: v) }   // demo: capture frames of the live panel
        case "--print-window-id": o.printWindowId = true   // demo capture helper
        case "--mcp-url": if let v = it.next() { o.mcpURL = URL(string: v) }
        case "--snapshot": if let v = it.next() { o.snapshotDir = URL(fileURLWithPath: v) }
        case "--prefs-dir": if let v = it.next() { o.prefsDir = URL(fileURLWithPath: v) }
        case "--runtime-file": if let v = it.next() { o.runtimeFile = URL(fileURLWithPath: v) }
#else
        case "--fixture", "--no-token", "--record", "--print-window-id", "--mcp-url", "--snapshot", "--prefs-dir", "--runtime-file":
            FileHandle.standardError.write(Data("\(a) is only available in debug builds\n".utf8)); exit(2)
#endif
        case "--help", "-h":
            print("usage: AgentHuddle [--fixture | --mcp-url http://127.0.0.1:PORT/mcp] [--snapshot DIR] [--prefs-dir DIR] [--sound]")
            exit(0)
        default: FileHandle.standardError.write(Data("unknown option\n".utf8)); exit(2)
        }
    }
    return o
}

final class NoFollow: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

let options = parseArgs()

@MainActor func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if let icon = options.iconFile { AppIcon.writePNG(to: icon); exit(0) }
    let log = HuddleLog()
    let sound: @Sendable () -> Void = { NSSound(named: "Glass")?.play() }
    let quiet: @Sendable () -> Void = { }
    let demoSound: @Sendable () -> Void = options.sound ? sound : quiet
    let tempPrefs = FileManager.default.temporaryDirectory.appendingPathComponent("agent-huddle-demo-\(ProcessInfo.processInfo.processIdentifier)")

    var fake: FakeT3Server?
    let config: HuddleConfig

    // Stills and the video: two fake machines, loopback only, memory credential stores (DemoRig, Snapshots.swift). Nothing real.
    if let dir = options.snapshotDir {
        Task { @MainActor in await Snapshots.run(into: dir); exit(0) }
        app.run()
        return
    }
    if let dir = options.recordDir {
        Task { @MainActor in
            let rig = await DemoRig.make(prefs: tempPrefs)
            let controller = PanelController(model: rig.model)
            rig.model.start()
            controller.show()
            if options.printWindowId { print("WINDOW_ID=\(controller.panel.windowNumber)"); fflush(stdout) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await DemoRecorder(controller: controller, rig: rig, dir: dir).run()
            rig.stop(); exit(0)
        }
        app.run()
        return
    }

    if options.fixture {
        var fo = FakeT3Server.Options(); fo.acceptStaticToken = !options.noToken
        let s = FakeT3Server(options: fo); Scenario.populate(s); fake = s
        let sem = DispatchSemaphore(value: 0)
        Task.detached { try? await s.start(); sem.signal() }
        sem.wait()
        s.startTicker(interval: 1) { Scenario.advanceRender($0) }
        let approve: @Sendable (URL) -> Void = { url in   // stands in for the browser + user approval (fake only)
            Task.detached {
                let sess = URLSession(configuration: .ephemeral, delegate: NoFollow(), delegateQueue: nil)
                if let (_, r) = try? await sess.data(from: url), let loc = (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
                   let u = URL(string: loc) { _ = try? await sess.data(from: u) }
            }
        }
        config = HuddleConfig(source: .fixed(s.url), tokenStore: MemoryTokenStore(token: options.noToken ? nil : s.token),
                              preferences: PreferencesStore(directory: options.prefsDir ?? tempPrefs), log: log,
                              jumper: RecordingJumper(log: log), playSound: demoSound, openURL: approve)
        log.log("fixture mode: fake T3 on \(s.url.absoluteString) (loopback only; no real T3, no Keychain)")
    } else if let url = options.mcpURL {
        guard (try? LoopbackGuard.validate(url)) != nil else {
            FileHandle.standardError.write(Data("refusing non-loopback --mcp-url\n".utf8)); exit(2)
        }
        let token = ProcessInfo.processInfo.environment["HUDDLE_MCP_TOKEN"] ?? "fake-token"
        config = HuddleConfig(source: .fixed(url), tokenStore: MemoryTokenStore(token: token),
                              preferences: PreferencesStore(directory: options.prefsDir ?? tempPrefs), log: log,
                              jumper: RecordingJumper(log: log), playSound: demoSound)
    } else {
        config = HuddleConfig(source: .runtimeFile(Discovery(runtimeFile: options.runtimeFile ?? Discovery.defaultRuntimeFile)),
                              tokenStore: KeychainTokenStore(), approvalStore: KeychainTokenStore(account: "approvals-bearer"),
                              remoteApprovalStore: KeychainRemoteCredentialStore(),
                              peerVerifier: BundlePeerVerifier(),
                              preferences: PreferencesStore(directory: options.prefsDir ?? PreferencesStore.defaultDirectory),
                              log: log, jumper: T3Jumper(), playSound: sound,
                              openURL: { NSWorkspace.shared.open($0) })
    }
    let model = HuddleModel(config: config)

    let controller = PanelController(model: model)
    let status = StatusItemController(model: model)
    model.start()
    controller.show()
    if options.printWindowId { print("WINDOW_ID=\(controller.panel.windowNumber)"); fflush(stdout) }
    withExtendedLifetime((controller, status, fake)) { app.run() }
}

MainActor.assumeIsolated { run() }
