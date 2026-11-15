import AppKit
import Darwin
import HuddleCore

/// Real jump: hands T3 Code its own thread deep link (`t3code://threads/<env>/<thread>`), which launches/raises the
/// app and selects that thread. (`t3 app <path>` is project-level and opens a *new* thread, so it is not used.)
struct T3Jumper: Jumper {
    static let bundleId = "com.t3tools.t3code"
    func jump(to target: JumpTarget) -> Bool {
        guard let url = target.deepLink else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// "Verify the peer before sending the token" (SPEC §10): the runtime file's `pid` must be alive, it must itself own the
/// listening socket on the file's port (so the file cannot pair a real T3 pid with another process's port), and its
/// executable must live inside an app bundle whose identifier is T3 Code's.
struct BundlePeerVerifier: PeerVerifier {
    func verify(pid: Int?, port: Int) -> Bool {
        guard let pid, pid > 0, kill(pid_t(pid), 0) == 0 else { return false }
        guard ListenerOwnership.pidOwnsLoopbackListener(pid: pid, port: port) else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid_t(pid), &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf)
        guard let r = path.range(of: ".app/") else { return false }
        let bundle = String(path[..<r.upperBound].dropLast())
        return Bundle(path: bundle)?.bundleIdentifier == T3Jumper.bundleId
    }
}
