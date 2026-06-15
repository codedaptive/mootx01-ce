// control_channel.rs — Rust twin of the Swift moot-mgr ControlChannel.swift.
//
// ============================ SECURITY BOUNDARY =============================
// Privileged state changes (monitoring on/off, set retention, estate provision/
// lifecycle) travel this Unix domain socket, NOT the loopback HTTP surface. The
// socket file is created at mode 0600 (owner-only read/write). A browser cannot
// speak a Unix domain socket — that is the feature: privileged ops stay off the
// loopback HTTP path by construction, and the filesystem permission bits (0600)
// are the access gate. No token is needed on the UDS because the OS already
// authenticates by the connecting process's effective uid via the socket-file
// permission bits.
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
// Implementation: a std::os::unix UnixListener, chmod'd 0600 directly. NO
// external packages. The accept loop runs on a dedicated thread; each connection
// is served inline.

use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use crate::http_read_api::HttpReadApi;

/// The mode the socket file is created/verified at: owner-only (0600). Mirrors
/// Swift `ControlChannel.socketMode`.
const SOCKET_MODE: u32 = 0o600;

/// Read cap to guard against an unbounded request line (matches the Swift 64 KiB).
const MAX_REQUEST_BYTES: usize = 64 * 1024;

/// The UDS-backed gated control channel. One instance per resident host. Mirrors
/// Swift `ControlChannel`.
pub struct ControlChannel {
    /// The API whose `apply_control` implements the verbs (shared with the HTTP
    /// control surface so both behave identically).
    api: Arc<HttpReadApi>,
    /// Filesystem path of the Unix domain socket. Any existing file here is
    /// removed on `start()` so a stale socket cannot be reused.
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

    /// Create the socket (bound + chmod 0600) and begin accepting connections on
    /// a dedicated thread. Mirrors Swift `ControlChannel.start()`.
    pub fn start(&self) -> std::io::Result<()> {
        // Remove a stale socket file so the bind does not fail on EADDRINUSE.
        let _ = std::fs::remove_file(&self.socket_path);
        let listener = UnixListener::bind(&self.socket_path)?;
        // chmod 0600 — owner-only. This IS the access gate (the OS authenticates
        // by the connecting process's uid via these permission bits).
        std::fs::set_permissions(&self.socket_path, std::fs::Permissions::from_mode(SOCKET_MODE))?;
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
                        Err(_) => {
                            if !running.load(Ordering::SeqCst) {
                                break;
                            }
                        }
                    }
                }
                // Clean up the socket file on loop exit so a restart binds cleanly.
                let _ = std::fs::remove_file(&socket_path);
            })?;
        *self.accept_thread.lock().unwrap() = Some(handle);
        Ok(())
    }

    /// Stop accepting and remove the socket file. Idempotent. Mirrors Swift
    /// `ControlChannel.stop()`.
    ///
    /// The accept loop is woken by flipping `running` and poking the socket with a
    /// throwaway connection so `incoming()` observes the flag.
    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        // Poke the listener so the blocking accept wakes and observes !running.
        let _ = UnixStream::connect(&self.socket_path);
        if let Some(handle) = self.accept_thread.lock().unwrap().take() {
            let _ = handle.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

/// Read one request line, dispatch the verb through the shared `apply_control`,
/// write the JSON result + newline. Mirrors Swift `ControlChannel.serve(_:)`.
fn serve(api: &HttpReadApi, mut stream: UnixStream) {
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
fn read_line(stream: &mut UnixStream) -> Option<String> {
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
