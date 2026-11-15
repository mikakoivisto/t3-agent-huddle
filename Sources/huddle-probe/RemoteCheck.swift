import Foundation
import HuddleCore

// huddle-probe --remote ADDRESS ENVIRONMENT_ID  — live check of the "another machine" approvals path (scripts/live-check-remote.sh).
// With THIS Mac's own https address (`tailscale serve`) and its own environment id it exercises the real remote code path end to end:
// origin policy, identity check, token exchange over TLS (system trust), and — only when a thread is named — one decision.
// Secrets come from the environment, never argv, and are never printed:
//   HUDDLE_REMOTE_PAIRING     pairing code created on the machine (orchestration:read + orchestration:operate), single use
//   HUDDLE_DISCOVERY_PAIRING  optional: code created on this Mac (orchestration:read + access:read) for `peerLinks.list`
//   HUDDLE_APPROVAL_THREAD / HUDDLE_APPROVAL_ITEM / HUDDLE_APPROVAL_DECISION (accept|decline)   optional: decide one throwaway request
enum RemoteCheck {
    static func run(address: String, environmentId: String) async -> Never {
        let env = ProcessInfo.processInfo.environment
        let log = HuddleLog { _ in }
        var ok = true
        func step(_ name: String, _ f: () async throws -> String) async {
            do { print("ok    \(name): \(try await f())") }
            catch { ok = false; print("FAIL  \(name): \((error as? HuddleError)?.description ?? "\(error)")") }
        }
        func expectRefusal(_ name: String, _ f: () async throws -> Void) async {
            do { try await f(); ok = false; print("FAIL  \(name): was not refused") }
            catch { print("ok    \(name): refused (\((error as? HuddleError)?.description ?? "\(error)"))") }
        }
        let policy = RemoteOriginPolicy.production
        var origin: ValidatedRemoteOrigin?
        await step("address passes the production policy") { origin = try policy.validate(address); return origin!.url.absoluteString }
        guard let origin else { exit(1) }
        await expectRefusal("plain http is refused") { _ = try policy.validate("http://" + origin.host) }
        await expectRefusal("loopback is refused") { _ = try policy.validate("https://127.0.0.1:3773") }

        if let code = env["HUDDLE_DISCOVERY_PAIRING"], !code.isEmpty {
            log.register(secret: code)
            await step("discovery: peerLinks.list on this Mac's T3") {
                let endpoint = try Discovery(runtimeFile: Discovery.defaultRuntimeFile).resolve().url
                let links = try await PeerLinkDiscovery.discover(pairingCode: code, origin: endpoint, log: log)
                let lines = links.map { "\($0.label) [\($0.environmentId.prefix(8))…] \($0.urls)" }
                return "\(links.count) linked machine(s): " + lines.joined(separator: "; ")
            }
        }

        await expectRefusal("identity check refuses a different environment id") {
            _ = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: "00000000-0000-0000-0000-000000000000")
        }
        var verified: VerifiedRemoteOrigin?
        await step("identity: address answers as the linked machine") {
            verified = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: environmentId)
            return "environment \(environmentId.prefix(8))… matches"
        }
        guard verified != nil else { print("remote check: FAILED"); exit(1) }

        if let code = env["HUDDLE_REMOTE_PAIRING"], !code.isEmpty {
            log.register(secret: code)
            var credential: RemoteApprovalCredential?
            await step("enrollment: pairing code exchanged over https") {
                credential = try await RemoteApprovalEnrollment.enroll(pairingCode: code, origin: origin, environmentId: environmentId, log: log)
                return "session token received (\(credential!.token.count) chars), kept in memory only"
            }
            if let credential, let thread = env["HUDDLE_APPROVAL_THREAD"], let item = env["HUDDLE_APPROVAL_ITEM"],
               let requestId = ApprovalWire.requestId(fromItemId: item) {
                let decision: ApprovalDecision = env["HUDDLE_APPROVAL_DECISION"] == "decline" ? .decline : .accept
                await step("decision: \(decision.rawValue) one request over wss") {
                    let v = try await RemoteIdentity.verify(origin: origin, expectedEnvironmentId: environmentId)
                    let socket = try ApprovalSocket(remote: v, token: credential.token, log: log)
                    log.register(secret: credential.token)
                    let seq = try await socket.respond(threadId: thread, requestId: requestId, decision: decision)
                    return "connected to \(socket.connectURL.scheme ?? "?")://\(socket.connectURL.host ?? "?"), T3 sequence \(seq.map(String.init) ?? "-")"
                }
            }
        }
        print(ok ? "remote check: PASSED" : "remote check: FAILED")
        exit(ok ? 0 : 1)
    }
}
