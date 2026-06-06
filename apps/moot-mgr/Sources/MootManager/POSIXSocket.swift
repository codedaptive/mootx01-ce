// POSIXSocket.swift
//
// Thin POSIX-socket helpers for the moot-mgr loopback read-API and the UDS
// control channel. NO external packages — these wrap the system C socket API
// (libc / Darwin), which is the zero-dependency path the kit rules require.
//
// WHY NOT Network.framework: the mission's first choice was NWListener, but
// NWListener cannot bind a *listening* server socket in the command-line build
// environment used here (it returns POSIXErrorCode 22 / EINVAL on every
// configuration, including an unrestricted TCP listener — a non-app-bundle
// constraint). The security requirements are mechanism-independent, so the
// listeners are built on POSIX sockets, which bind correctly. See the
// completion report's deviation note. The security boundary (loopback-only
// bind, UDS at 0600) is enforced identically — arguably more directly, since
// the bind address and file mode are set explicitly here.

import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - POSIXSocket

/// Minimal blocking-socket helpers shared by the TCP read-API listener and the
/// UDS control listener. All calls are synchronous; callers run them off the
/// cooperative pool (a dedicated Thread or `Task.detached`).
enum POSIXSocket {

    /// Bind a TCP listening socket to 127.0.0.1:port and start listening.
    ///
    /// SECURITY: the bind address is hard-pinned to `INADDR_LOOPBACK`
    /// (127.0.0.1) — never `INADDR_ANY` / 0.0.0.0. The kernel therefore accepts
    /// connections only on the loopback interface (concepts §1.6).
    ///
    /// - Parameter port: Requested port; 0 lets the OS assign one.
    /// - Returns: `(fd, boundPort)` — the listening descriptor and the actual port.
    /// - Throws: `SocketError` on any syscall failure.
    static func listenLoopbackTCP(port: UInt16) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // 127.0.0.1 in network byte order. Loopback only — never INADDR_ANY.
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian

        let bindResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno; close(fd); throw SocketError.syscall("bind", e)
        }
        guard listen(fd, 16) == 0 else {
            let e = errno; close(fd); throw SocketError.syscall("listen", e)
        }

        // Read back the actual port (relevant when port 0 was requested).
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        let actualPort = UInt16(bigEndian: bound.sin_port)
        return (fd, actualPort)
    }

    /// Bind a Unix-domain listening socket at `path` and chmod it to 0600.
    ///
    /// SECURITY: the socket file is created then immediately chmod'd to 0600
    /// (owner read/write only). The filesystem permission bits ARE the access
    /// gate for the privileged control channel (concepts §1.6) — a browser
    /// cannot speak a UDS, so privileged ops stay off the loopback HTTP surface
    /// by construction. Any stale file at `path` is removed first so a leftover
    /// socket from a crashed run cannot block the bind.
    ///
    /// - Parameter path: Filesystem path for the socket.
    /// - Returns: The listening descriptor.
    /// - Throws: `SocketError` on any syscall failure.
    static func listenUnix(path: String) throws -> Int32 {
        unlink(path) // remove a stale socket if present (ignore failure)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let ok: Bool = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: cap) { dstPtr in
                    // Path must fit the fixed sun_path buffer (with the NUL).
                    guard strlen(src) < cap else { return false }
                    strncpy(dstPtr, src, cap - 1)
                    return true
                }
            }
        }
        guard ok else { close(fd); throw SocketError.pathTooLong }

        let bindResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno; close(fd); throw SocketError.syscall("bind", e)
        }

        // Enforce owner-only (0600) on the socket file before listening, so the
        // window where the socket is bindable-but-world-accessible is closed.
        guard chmod(path, 0o600) == 0 else {
            let e = errno; close(fd); unlink(path); throw SocketError.syscall("chmod", e)
        }
        guard listen(fd, 16) == 0 else {
            let e = errno; close(fd); unlink(path); throw SocketError.syscall("listen", e)
        }
        return fd
    }

    /// Accept one connection on a listening fd. Returns the connection fd, or
    /// nil if accept was interrupted/failed (the caller decides whether to retry).
    static func acceptOne(_ listenFD: Int32) -> Int32? {
        let cfd = accept(listenFD, nil, nil)
        return cfd >= 0 ? cfd : nil
    }

    /// Read up to `max` bytes. Returns the data read (possibly empty on EOF) or
    /// nil on error.
    static func recv(_ fd: Int32, max: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, max) }
        if n < 0 { return nil }
        return Data(buf[0..<n])
    }

    /// Write all of `data` to the fd. Returns true on success.
    @discardableResult
    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress, remaining.count)
            }
            if written <= 0 { return false }
            remaining.removeFirst(written)
        }
        return true
    }
}

// MARK: - SocketError

/// Structured socket error (project error-handling rule: enums, not optionals).
enum SocketError: Error, Sendable, Equatable {
    /// A named syscall failed with this errno.
    case syscall(String, Int32)
    /// The UDS path did not fit the fixed `sun_path` buffer.
    case pathTooLong
}
