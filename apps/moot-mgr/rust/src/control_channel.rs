// control_channel.rs — Rust twin of the Swift moot-mgr ControlChannel.swift.
//
// ============================ SECURITY BOUNDARY =============================
// Privileged state changes (monitoring on/off, set retention, estate provision/
// lifecycle) travel a local IPC channel, NOT the loopback HTTP surface. A
// browser cannot speak that channel — that is the feature: privileged ops stay
// off the loopback HTTP path by construction, and the OS authenticates the
// connecting peer for us:
//
//   * Unix (Linux/macOS): a filesystem Unix-domain socket created at mode 0600
//     (owner-only read/write). The permission bits ARE the access gate — the OS
//     authenticates by the connecting process's effective uid. No token needed.
//   * Windows: a named pipe carrying the creating user's default ACL (owner-only).
//     The ACL is the equivalent gate; the pipe is not on the filesystem, so its
//     name is derived from the control-socket path (see `windows_pipe_name`).
//
// The protocol is line-oriented and tiny: a client connects, writes ONE control
// path optionally followed by a tab and a JSON body, terminated by a newline;
// the server applies the verb and writes back the JSON ControlResponse. The
// verbs are the SAME control paths the HTTP control surface uses, dispatched
// through the shared `HttpReadApi::apply_control` so both surfaces have identical
// semantics.
//
//   request : "/api/control/monitoring/on\n"
//   request : "/api/control/retention\t{\"seconds\":3600}\n"
//   response: "{\"detail\":\"...\",\"ok\":true}\n"
// ===========================================================================
//
// Implementation: a cross-platform local socket via the `interprocess` crate —
// a Unix-domain socket on Unix (chmod'd 0600 directly) and a named pipe on
// Windows. The accept loop runs on a dedicated thread; each connection is served
// inline. Per the platform law the Rust vertical targets Windows AND Linux, so
// the transport must compile and run on both.

use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use interprocess::local_socket::prelude::*;
use interprocess::local_socket::{Listener, ListenerNonblockingMode, ListenerOptions, Stream};

use crate::http_read_api::HttpReadApi;

/// The mode the Unix socket file is created/verified at: owner-only (0600).
/// Mirrors Swift `ControlChannel.socketMode`. (Windows uses the named-pipe ACL
/// instead — see the security-boundary header.)
#[cfg(unix)]
const SOCKET_MODE: u32 = 0o600;

/// Read cap to guard against an unbounded request line (matches the Swift 64 KiB).
const MAX_REQUEST_BYTES: usize = 64 * 1024;

/// The gated control channel. One instance per resident host. Mirrors Swift
/// `ControlChannel`.
pub struct ControlChannel {
    /// The API whose `apply_control` implements the verbs (shared with the HTTP
    /// control surface so both behave identically).
    api: Arc<HttpReadApi>,
    /// On Unix, the filesystem path of the Unix-domain socket (any existing file
    /// here is removed on `start()` so a stale socket cannot be reused). On
    /// Windows, the seed from which the named-pipe identifier is derived.
    socket_path: String,
    running: Arc<AtomicBool>,
    accept_thread: Mutex<Option<JoinHandle<()>>>,
}

impl ControlChannel {
    /// Create the control channel. Mirrors Swift `ControlChannel.init(api:socketPath:)`.
    pub fn new(api: Arc<HttpReadApi>, socket_path: impl Into<String>) -> Self {
        ControlChannel {
            api,
            socket_path: socket_path.into(),
            running: Arc::new(AtomicBool::new(false)),
            accept_thread: Mutex::new(None),
        }
    }

    /// Create the listener (UDS chmod 0600 on Unix / owner-ACL named pipe on
    /// Windows) and begin accepting connections on a dedicated thread. Mirrors
    /// Swift `ControlChannel.start()`.
    pub fn start(&self) -> std::io::Result<()> {
        let listener = bind_listener(&self.socket_path)?;
        // Nonblocking accept: the loop polls `running` between accepts instead of
        // blocking indefinitely. This makes shutdown deterministic on BOTH
        // platforms without a wakeup connection — critical on Windows, where a
        // named-pipe "poke" races the accept and can leave it blocked forever
        // (see the platform note on `Listener::accept`).
        listener.set_nonblocking(ListenerNonblockingMode::Accept)?;
        self.running.store(true, Ordering::SeqCst);

        let api = Arc::clone(&self.api);
        let running = Arc::clone(&self.running);
        let socket_path = self.socket_path.clone();
        let handle = std::thread::Builder::new()
            .name("moot-mgr.ControlChannel.accept".to_string())
            .spawn(move || {
                for stream in listener.incoming() {
                    if !running.load(Ordering::SeqCst) {
                        break;
                    }
                    match stream {
                        Ok(s) => serve(&api, s),
                        // No client waiting (nonblocking). Sleep briefly, then
                        // loop — re-checking `running` so stop() takes effect
                        // within one tick.
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(std::time::Duration::from_millis(20));
                        }
                        Err(_) => {
                            if !running.load(Ordering::SeqCst) {
                                break;
                            }
                        }
                    }
                }
                // Best-effort cleanup of the Unix socket file on loop exit so a
                // restart binds cleanly (no-op on Windows, where the named pipe
                // is released when the listener drops).
                let _ = std::fs::remove_file(&socket_path);
            })?;
        *self.accept_thread.lock().unwrap() = Some(handle);
        Ok(())
    }

    /// Stop accepting and remove the socket file. Idempotent. Mirrors Swift
    /// `ControlChannel.stop()`.
    ///
    /// The accept loop polls `running` between nonblocking accepts, so flipping
    /// the flag is enough — it exits within one poll tick on its own. No wakeup
    /// connection is needed (and none would be reliable on Windows named pipes).
    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(handle) = self.accept_thread.lock().unwrap().take() {
            let _ = handle.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

/// Bind the gated control-channel listener for this platform.
///
/// Unix: a filesystem Unix-domain socket at `socket_path`, chmod'd 0600 — the
/// owner-only permission bits ARE the access gate. Windows: a named pipe whose
/// name is derived from `socket_path`, carrying the creating user's default ACL
/// (owner-only). A browser can speak neither, by construction.
fn bind_listener(socket_path: &str) -> std::io::Result<Listener> {
    #[cfg(unix)]
    {
        use interprocess::local_socket::GenericFilePath;
        // Remove a stale socket file so the bind does not fail on EADDRINUSE.
        let _ = std::fs::remove_file(socket_path);
        let name = socket_path.to_fs_name::<GenericFilePath>()?;
        let listener = ListenerOptions::new().name(name).create_sync()?;
        // chmod 0600 — owner-only. THIS is the Unix access gate (the OS
        // authenticates by the connecting process's uid via these bits).
        std::fs::set_permissions(
            socket_path,
            std::fs::Permissions::from_mode(SOCKET_MODE),
        )?;
        Ok(listener)
    }
    #[cfg(windows)]
    {
        use interprocess::local_socket::GenericNamespaced;
        let pipe = windows_pipe_name(socket_path);
        let name = pipe.to_ns_name::<GenericNamespaced>()?;
        // Windows access gate: `interprocess` v2 creates the named pipe with the
        // calling process's default DACL (Windows default), which restricts access
        // to the pipe owner and members of the Administrators group. This provides
        // the owner-only equivalent of the Unix 0600 chmod — remote/arbitrary
        // users on the same machine cannot connect.
        //
        // Explicit DACL control (e.g. restricting to exactly the creating SID with
        // no Administrators inheritance) would require a direct `windows-sys` call
        // to `CreateNamedPipeW` with a custom SECURITY_ATTRIBUTES. That would
        // introduce a new external dependency, which the no-new-external-dep rule
        // prohibits. The `interprocess` v2 API does not expose DACL configuration
        // through `ListenerOptions`. The default DACL is the correct hardening
        // posture for the local manager: it excludes unprivileged local users,
        // which is the threat model. Administrator-level access is expected to have
        // equivalent privilege to the moot-mgr process itself.
        ListenerOptions::new().name(name).create_sync()
    }
}

/// Derive a stable Windows named-pipe identifier from the control-socket path.
/// Named pipes are not filesystem objects, so the per-data-dir control-socket
/// PATH is folded (FNV-1a) into a flat-namespace name: distinct data dirs get
/// distinct pipes; the same data dir always maps to the same pipe.
#[cfg(windows)]
fn windows_pipe_name(socket_path: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in socket_path.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("mootx01-mgr-{h:016x}.sock")
}

/// Read one request line, dispatch the verb through the shared `apply_control`,
/// write the JSON result + newline. Mirrors Swift `ControlChannel.serve(_:)`.
fn serve(api: &HttpReadApi, mut stream: Stream) {
    let line = match read_line(&mut stream) {
        Some(l) => l,
        None => return,
    };
    // Split on the first tab: path before, optional JSON body after.
    let (path, body): (String, Vec<u8>) = match line.find('\t') {
        Some(tab) => {
            let p = line[..tab].trim().to_string();
            let b = line[tab + 1..].as_bytes().to_vec();
            (p, b)
        }
        None => (line.trim().to_string(), Vec::new()),
    };

    let response = api.apply_control(&path, &body);
    let mut out = response.json;
    out.push(b'\n');
    let _ = stream.write_all(&out);
    let _ = stream.flush();
}

/// Read until the first newline (the request terminator), returning the line
/// without the newline. Caps the read against an unbounded request. Mirrors
/// Swift `ControlChannel.readLine(_:)`.
fn read_line(stream: &mut Stream) -> Option<String> {
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    loop {
        if let Some(nl) = buffer.iter().position(|&b| b == b'\n') {
            return Some(String::from_utf8_lossy(&buffer[..nl]).into_owned());
        }
        if buffer.len() > MAX_REQUEST_BYTES {
            return None;
        }
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            // Connection closed; return whatever line we have, if any.
            return if buffer.is_empty() {
                None
            } else {
                Some(String::from_utf8_lossy(&buffer).into_owned())
            };
        }
        buffer.extend_from_slice(&chunk[..n]);
    }
}
