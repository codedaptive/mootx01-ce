//! PostgreSQL TLS configuration knob (SECFIX-WS2-PK F3 — CAND-029).
//!
//! # Summary
//!
//! The `postgres-native-tls = "0.5"` crate has been approved (C-1 per-crate
//! exception recorded in `DECISION_RUST_POSTGRES_TLS_CRATE_2026-06-28.md`)
//! and is compiled in. `Pool::open_connection` in `postgres.rs` uses a
//! `postgres_native_tls::MakeTlsConnector` for `Prefer` and `Require` modes,
//! providing parity with the Swift `NIOSSL` transport in `PostgreSQLPool.swift`.
//!
//! # TLS mode knob
//!
//! | Value      | Behaviour                                                          |
//! |---|---|
//! | `disable`  | `NoTls` — plaintext connection (appropriate for loopback/UNIX socket) |
//! | `prefer`   | Attempt TLS; fall back to plaintext if the server does not support it |
//! | `require`  | TLS mandatory; fail the connection if the server does not offer it |
//! | *(absent)* | Defaults to `prefer` (safe default — encrypts when the server agrees) |
//! | *(unknown)*| Defaults to `prefer` (unknown values are not silently treated as disable) |
//!
//! # No-downgrade guarantee
//!
//! The effective sslmode for a connection is `max(env_mode_rank, dsn_sslmode_rank)`.
//! The env var may raise the security level above what the DSN specifies, but it
//! must never lower what the operator's DSN explicitly requested. See
//! `effective_sslmode` for the full implementation and `SslModeRank` for the
//! ordering. `Pool::open_connection` in `postgres.rs` calls `effective_sslmode`
//! and selects the TLS connector from the effective mode, not the raw env mode.

/// Desired TLS behaviour for PostgreSQL connections.
///
/// Parsed from the `ARIA_MCP_POSTGRES_TLS` environment variable by
/// `PostgresTlsMode::from_env`. Used by `Pool::open_connection` (via
/// `effective_sslmode`) to select the transport at connect time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PostgresTlsMode {
    /// No TLS. Appropriate for loopback (127.0.0.1 / ::1) or Unix-socket
    /// connections where the OS provides process isolation. Never use over
    /// a network or when the server is on a different host.
    Disable,
    /// Attempt TLS negotiation; accept a plaintext connection if the server
    /// does not offer TLS. Suitable when connecting to an older or
    /// misconfigured server where TLS is unavailable, and the network path
    /// is otherwise trusted (e.g. private VPC subnet).
    Prefer,
    /// TLS mandatory. The connection is refused if the server does not
    /// offer TLS. Use for production connections over untrusted networks.
    Require,
}

impl PostgresTlsMode {
    /// Read the TLS mode from the `ARIA_MCP_POSTGRES_TLS` env var.
    ///
    /// Returns `Prefer` when the variable is absent or contains an
    /// unrecognised value. Unknown values are NOT mapped to `Disable` —
    /// a misconfigured value defaults safe, not open.
    pub fn from_env() -> Self {
        match std::env::var("ARIA_MCP_POSTGRES_TLS")
            .as_deref()
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Ok("disable") => Self::Disable,
            Ok("require") => Self::Require,
            // "prefer", absent, or any unrecognised value → Prefer.
            _ => Self::Prefer,
        }
    }
}

/// Security ranking for libpq `sslmode` values, ordered from weakest to
/// strongest. Used by `effective_sslmode` to enforce the no-downgrade rule.
///
/// The ordering matches libpq's own security progression (PostgreSQL docs,
/// "SSL Support" table). `PartialOrd`/`Ord` derive gives the natural
/// enum-ordinal ordering (Disable=0 < Allow=1 < ... < VerifyFull=5).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SslModeRank {
    /// `sslmode=disable` — plaintext only; TLS refused even if the server
    /// offers it.
    Disable,
    /// `sslmode=allow` — prefer plaintext; use TLS only if the server
    /// requires it. Stronger than Disable (allows TLS as a fallback) but
    /// weaker than Prefer (does not attempt TLS proactively).
    Allow,
    /// `sslmode=prefer` — attempt TLS; fall back to plaintext if the server
    /// does not support it. The libpq default.
    Prefer,
    /// `sslmode=require` — TLS mandatory; plaintext refused. Does not verify
    /// the server certificate.
    Require,
    /// `sslmode=verify-ca` — TLS mandatory + server certificate must be
    /// signed by a trusted CA. Does not verify the hostname.
    VerifyCa,
    /// `sslmode=verify-full` — TLS mandatory + certificate CA check +
    /// hostname verification. Highest libpq security level.
    VerifyFull,
}

impl SslModeRank {
    /// Parse a libpq `sslmode` string to its rank. Returns `None` for
    /// unrecognised values so callers can apply conservative handling
    /// (preserve the unknown value verbatim rather than overwriting it).
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "disable" => Some(Self::Disable),
            "allow" => Some(Self::Allow),
            "prefer" => Some(Self::Prefer),
            "require" => Some(Self::Require),
            "verify-ca" => Some(Self::VerifyCa),
            "verify-full" => Some(Self::VerifyFull),
            _ => None,
        }
    }

    /// Return the libpq string representation of this rank.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disable => "disable",
            Self::Allow => "allow",
            Self::Prefer => "prefer",
            Self::Require => "require",
            Self::VerifyCa => "verify-ca",
            Self::VerifyFull => "verify-full",
        }
    }

    /// Convert a `PostgresTlsMode` env-var setting to its `SslModeRank`.
    ///
    /// The env var expresses only three levels. `Disable` → weakest,
    /// `Prefer` → middle, `Require` → strong (but below verify-ca/verify-full).
    pub fn from_tls_mode(mode: PostgresTlsMode) -> Self {
        match mode {
            PostgresTlsMode::Disable => Self::Disable,
            PostgresTlsMode::Prefer => Self::Prefer,
            PostgresTlsMode::Require => Self::Require,
        }
    }

    /// True when this rank requires a TLS connector (`MakeTlsConnector`).
    ///
    /// Only `Disable` uses `NoTls`; every other level — including `Allow`
    /// (the server may upgrade) — is served by a TLS-capable connector.
    /// The `sslmode=` value in the connection string tells the postgres crate
    /// the exact policy; the connector just needs to be TLS-capable.
    pub fn uses_tls(self) -> bool {
        self != Self::Disable
    }
}

/// Parse the raw `sslmode=` value from a postgres connection string.
///
/// Handles both URL form (`postgres://host/db?sslmode=require`) and DSN
/// form (`host=localhost sslmode=require`). Returns `None` when no
/// `sslmode=` parameter is present.
fn dsn_sslmode_str(conn_str: &str) -> Option<&str> {
    let pos = conn_str.find("sslmode=")?;
    let value_start = pos + "sslmode=".len();
    // URL params are delimited by '&'; DSN key-value pairs by whitespace.
    let is_url =
        conn_str.starts_with("postgres://") || conn_str.starts_with("postgresql://");
    let separator = if is_url { '&' } else { ' ' };
    let value_end = conn_str[value_start..]
        .find(separator)
        .map(|i| value_start + i)
        .unwrap_or(conn_str.len());
    Some(&conn_str[value_start..value_end])
}

/// Compute the effective sslmode for a connection, honouring the operator's
/// DSN as a security floor.
///
/// # No-downgrade rule
///
/// The effective sslmode is `max(env_mode_rank, dsn_sslmode_rank)`. The
/// env var may **raise** security above the DSN but must never **lower**
/// what the operator explicitly specified. A DSN with `sslmode=require`
/// must remain at `require` even when the env var defaults to `prefer`.
///
/// # Unrecognised DSN values
///
/// If the DSN contains a `sslmode=` value that is not in the known ranking
/// (e.g. a future libpq value, or a typo), the DSN string is returned
/// **verbatim** and a TLS connector is mandated. We must never overwrite an
/// unrecognised value that may be stronger than anything we understand.
///
/// # Returns
///
/// `(effective_conn_str, use_tls)` where:
/// - `effective_conn_str`: the connection string to pass to `Client::connect`.
///   Either the original string (DSN already at or above env rank, or
///   unrecognised DSN value) or a rewritten version with the env rank's
///   `sslmode=` substituted in.
/// - `use_tls`: `true` when `effective sslmode != disable`, meaning
///   `Pool::open_connection` must supply a `MakeTlsConnector`. `false` only
///   when the effective mode is `disable` (use `NoTls` — plaintext).
pub fn effective_sslmode(conn_str: &str, env_mode: PostgresTlsMode) -> (String, bool) {
    let env_rank = SslModeRank::from_tls_mode(env_mode);

    match dsn_sslmode_str(conn_str) {
        None => {
            // No sslmode in the DSN — apply the env mode directly by
            // appending sslmode= to the connection string.
            let written = set_sslmode_in_str(conn_str, env_rank.as_str());
            (written, env_rank.uses_tls())
        }
        Some(dsn_val) => {
            match SslModeRank::from_str(dsn_val) {
                None => {
                    // Unrecognised DSN sslmode value. Preserve verbatim and
                    // mandate TLS — we must not overwrite a value that may be
                    // stronger than anything in our ranking.
                    (conn_str.to_string(), true)
                }
                Some(dsn_rank) => {
                    if dsn_rank >= env_rank {
                        // DSN already specifies an equal or stronger mode —
                        // leave the connection string unchanged so the exact
                        // operator-specified value is preserved.
                        (conn_str.to_string(), dsn_rank.uses_tls())
                    } else {
                        // Env is stronger — raise the DSN to the env rank.
                        // This is the only case where we overwrite the DSN's
                        // sslmode: we are always upgrading, never downgrading.
                        let written = set_sslmode_in_str(conn_str, env_rank.as_str());
                        (written, env_rank.uses_tls())
                    }
                }
            }
        }
    }
}

/// Replace or append `sslmode=<mode>` in a postgres connection string.
///
/// Handles both URL form (`postgres://host/db?sslmode=X`) and DSN form
/// (`host=localhost sslmode=X`). If `sslmode=` is already present, the
/// existing value is replaced; otherwise the parameter is appended.
///
/// # Note
///
/// This function is called **only** when we have already determined that
/// the mode should be written (either because there was no existing sslmode,
/// or because we are raising the mode above the DSN's current value).
/// It is never called to downgrade.
fn set_sslmode_in_str(conn_str: &str, mode: &str) -> String {
    let is_url =
        conn_str.starts_with("postgres://") || conn_str.starts_with("postgresql://");
    let separator = if is_url { '&' } else { ' ' };

    // Replace an existing sslmode= value if present.
    if let Some(pos) = conn_str.find("sslmode=") {
        let value_start = pos + "sslmode=".len();
        let value_end = conn_str[value_start..]
            .find(separator)
            .map(|i| value_start + i)
            .unwrap_or(conn_str.len());
        return format!("{}sslmode={}{}", &conn_str[..pos], mode, &conn_str[value_end..]);
    }

    // No existing sslmode — append it using the appropriate separator.
    if is_url {
        if conn_str.contains('?') {
            format!("{}&sslmode={}", conn_str, mode)
        } else {
            format!("{}?sslmode={}", conn_str, mode)
        }
    } else {
        format!("{} sslmode={}", conn_str, mode)
    }
}
