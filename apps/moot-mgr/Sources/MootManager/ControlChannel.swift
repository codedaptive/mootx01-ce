// ControlChannel.swift
//
// The gated control channel for moot-mgr (P3) over a Unix domain socket.
//
// ============================ SECURITY BOUNDARY =============================
// Privileged state changes (monitoring on/off, set retention) travel this UDS,
// NOT the loopback HTTP surface. The socket file is created at mode 0600
// (owner-only read/write — enforced in POSIXSocket.listenUnix). A browser
// cannot speak a Unix domain socket — that is the feature (concepts §1.6):
// privileged ops stay off the loopback HTTP path by construction, and the
// filesystem permission bits (0600) are the access gate. No token is needed on
// the UDS because the OS already authenticates by the process's effective uid
// via the socket-file permission bits.
//
// The protocol is line-oriented and tiny: a client connects, writes ONE control
// path optionally followed by a tab and a JSON body, terminated by a newline;
// the server applies the verb and writes back the JSON ControlResult. Verbs are
// the SAME control paths the HTTP control surface uses, dispatched through the
// shared HTTPReadAPI.applyControl so both surfaces have identical semantics.
//
//   request : "/api/control/monitoring/on\n"
//   request : "/api/control/retention\t{\"seconds\":3600}\n"
//   response: "{\"detail\":\"...\",\"ok\":true}\n"
// ===========================================================================
//
// Implementation: a POSIX Unix-domain listening socket (POSIXSocket.swift). NO
// external packages. (NWListener cannot bind a server UDS at a chosen path in
// this environment; the POSIX path binds and chmods 0600 directly.) The accept
// loop runs on a dedicated thread; each connection is served on the actor.

import Foundation
import OSLog

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - ControlChannel

/// The UDS-backed gated control channel. One instance per resident host.
public actor ControlChannel {

    /// The API whose `applyControl` implements the verbs (shared with the HTTP
    /// control surface so both behave identically).
    private let api: HTTPReadAPI

    /// Filesystem path of the Unix domain socket.
    private let socketPath: String

    private let logger = Logger(subsystem: "com.mootx01.kit", category: "ControlChannel")

    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let running = RunningFlag()

    /// The mode the socket file is created/verified at: owner-only (0600).
    static let socketMode: mode_t = 0o600

    // MARK: - Init

    /// Create the control channel.
    ///
    /// - Parameters:
    ///   - api:        The read-API whose `applyControl` implements the verbs.
    ///   - socketPath: Filesystem path for the UDS. Any existing file here is
    ///                 removed on `start()` so a stale socket cannot be reused.
    public init(api: HTTPReadAPI, socketPath: String) {
        self.api = api
        self.socketPath = socketPath
    }

    // MARK: - Lifecycle

    /// Create the socket (bound + chmod 0600) and begin accepting connections.
    ///
    /// - Throws: `SocketError` if the socket cannot be created/bound/chmod'd.
    public func start() throws {
        let fd = try POSIXSocket.listenUnix(path: socketPath)
        self.listenFD = fd
        running.set(true)

        let thread = Thread { [weak self, fd, running] in
            while running.get() {
                guard let cfd = POSIXSocket.acceptOne(fd) else {
                    if !running.get() { break }
                    continue
                }
                guard let self else { close(cfd); break }
                Task { await self.serve(cfd) }
            }
        }
        thread.name = "com.mootx01.kit.ControlChannel.accept"
        thread.start()
        self.acceptThread = thread
        logger.info("ControlChannel listening on UDS \(self.socketPath) (0600)")
    }

    /// Stop accepting and remove the socket file. Idempotent.
    public func stop() async {
        running.set(false)
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        acceptThread = nil
        unlink(socketPath)
    }

    // MARK: - Connection handling

    /// Read one request line, dispatch the verb, write the JSON result.
    private func serve(_ fd: Int32) async {
        defer { close(fd) }
        guard let line = readLine(fd) else { return }
        // Split on the first tab: path before, optional JSON body after.
        let (path, body): (String, Data) = {
            if let tab = line.firstIndex(of: "\t") {
                let p = String(line[line.startIndex..<tab])
                let b = String(line[line.index(after: tab)...])
                return (p.trimmingCharacters(in: .whitespacesAndNewlines), Data(b.utf8))
            }
            return (line.trimmingCharacters(in: .whitespacesAndNewlines), Data())
        }()

        let response = await api.applyControl(path: path, body: body)
        var out = response.json
        out.append(Data("\n".utf8))
        POSIXSocket.sendAll(fd, out)
    }

    /// Read until the first newline (the request terminator), returning the line
    /// without the newline. Caps the read to guard against an unbounded request.
    private func readLine(_ fd: Int32) -> String? {
        var buffer = Data()
        let cap = 64 * 1024
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer[buffer.startIndex..<nl], encoding: .utf8)
            }
            if buffer.count > cap { return nil }
            guard let chunk = POSIXSocket.recv(fd, max: 16 * 1024), !chunk.isEmpty else {
                // Connection closed; return whatever line we have, if any.
                return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
            }
            buffer.append(chunk)
        }
    }
}
