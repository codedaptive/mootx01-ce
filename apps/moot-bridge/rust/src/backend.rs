//! backend.rs — a raw, verbatim, id-preserving stdio JSON-RPC forwarder to one
//! MCP backend (Rust twin of the Swift `RawMCPBackend`).
//!
//! Launches the configured stdio command, then exchanges newline-delimited
//! JSON-RPC over its stdin/stdout. The bridge issues one request at a time per
//! backend, so a response is matched to its request by ORDERING on the single
//! transport — exactly the Swift contract. Request ids are preserved on the
//! primary path (the client cannot tell it is not talking to the backend
//! directly) and made disjoint on the secondary fan-out path.
//!
//! The command string is operator-supplied and treated at CLI-argument trust
//! level. An env-var prefix (`KEY=val program args...`) is honored: leading
//! `KEY=value` tokens are split off and set on the child's environment, matching
//! the `/usr/bin/env` behaviour the Swift twin relies on.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};

/// An error talking to a backend.
#[derive(Debug)]
pub struct BackendError(pub String);

impl std::fmt::Display for BackendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for BackendError {}

/// Raw, verbatim, id-preserving stdio JSON-RPC forwarder to one MCP backend.
pub struct RawMcpBackend {
    pub name: String,
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

impl RawMcpBackend {
    /// Launches the backend process from a full command string and returns the
    /// ready forwarder. Honors a leading `KEY=value ...` env prefix.
    pub fn start(name: &str, command: &str) -> Result<RawMcpBackend, BackendError> {
        let tokens: Vec<&str> = command.split_whitespace().collect();
        // Split leading KEY=value tokens (env assignments) from the program+args.
        let mut env_pairs: Vec<(String, String)> = Vec::new();
        let mut i = 0;
        while i < tokens.len() {
            if let Some(eq) = tokens[i].find('=') {
                // Only treat as env when it precedes the program name and the part
                // before '=' is a plausible identifier (no path separators).
                let key = &tokens[i][..eq];
                if !key.is_empty() && !key.contains('/') {
                    env_pairs.push((key.to_string(), tokens[i][eq + 1..].to_string()));
                    i += 1;
                    continue;
                }
            }
            break;
        }
        let program = tokens
            .get(i)
            .ok_or_else(|| BackendError(format!("empty command for backend {name}")))?;
        let args = &tokens[i + 1..];

        let mut cmd = Command::new(program);
        cmd.args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // The backend's own stderr passes through to the bridge's stderr, which
            // is the diagnostics channel (never stdout, the JSON-RPC channel).
            .stderr(Stdio::inherit());
        for (k, v) in env_pairs {
            cmd.env(k, v);
        }

        let mut child = cmd
            .spawn()
            .map_err(|e| BackendError(format!("spawn backend {name}: {e}")))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| BackendError(format!("backend {name} has no stdin")))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| BackendError(format!("backend {name} has no stdout")))?;

        Ok(RawMcpBackend {
            name: name.to_string(),
            child,
            stdin,
            stdout: BufReader::new(stdout),
        })
    }

    /// Sends one already-serialized JSON-RPC message (a request with an id) and
    /// returns the backend's response line verbatim. Blocking, ordered: one
    /// request → one response on the single transport.
    pub fn send_and_receive(&mut self, message: &str) -> Result<String, BackendError> {
        self.stdin
            .write_all(message.as_bytes())
            .and_then(|_| self.stdin.write_all(b"\n"))
            .and_then(|_| self.stdin.flush())
            .map_err(|e| BackendError(format!("write to {}: {e}", self.name)))?;
        self.read_line()
    }

    /// Sends a JSON-RPC notification (no id, no response expected).
    pub fn send_notification(&mut self, message: &str) -> Result<(), BackendError> {
        self.stdin
            .write_all(message.as_bytes())
            .and_then(|_| self.stdin.write_all(b"\n"))
            .and_then(|_| self.stdin.flush())
            .map_err(|e| BackendError(format!("notify {}: {e}", self.name)))
    }

    /// Reads one non-empty newline-delimited line from the backend stdout.
    fn read_line(&mut self) -> Result<String, BackendError> {
        loop {
            let mut line = String::new();
            let n = self
                .stdout
                .read_line(&mut line)
                .map_err(|e| BackendError(format!("read {}: {e}", self.name)))?;
            if n == 0 {
                return Err(BackendError(format!("backend {} closed its stream", self.name)));
            }
            let trimmed = line.trim_end_matches(['\r', '\n']);
            if trimmed.is_empty() {
                continue;
            }
            return Ok(trimmed.to_string());
        }
    }

    /// Tears the backend down. Safe to call more than once (terminate is
    /// best-effort).
    pub fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for RawMcpBackend {
    fn drop(&mut self) {
        self.stop();
    }
}
