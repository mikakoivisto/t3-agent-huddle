import Foundation
import Darwin

/// Does process `pid` itself own a TCP listening socket on loopback `port`? The runtime file names a pid and a port
/// independently, and a file written by another process could pair a real T3 pid with the port of some other server. Asking the
/// kernel who owns the listening socket closes that gap (it does not by itself prove who the program is).
public enum ListenerOwnership {
    public static func pidOwnsLoopbackListener(pid: Int, port: Int) -> Bool {
        guard pid > 0, (1...65535).contains(port) else { return false }
        let p = pid_t(pid)
        let needed = proc_pidinfo(p, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 8)
        let got = proc_pidinfo(p, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(p, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let si = info.psi
            guard si.soi_kind == SOCKINFO_TCP, si.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = si.soi_proto.pri_tcp.tcpsi_ini
            guard UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)) == UInt16(port) else { continue }
            if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                let addr = UInt32(bigEndian: ini.insi_laddr.ina_46.i46a_addr4.s_addr)
                if addr == 0x7F00_0001 || addr == 0 { return true }          // 127.0.0.1 or any
            } else if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
                return true                                                    // [::1] or [::]: the guard validated the host already
            }
        }
        return false
    }
}
