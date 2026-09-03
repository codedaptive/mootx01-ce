//! estate_posture.rs — the live / frozen posture of a served estate.
//!
//! A frozen serve makes a served estate behave like a read-only, side-effect-
//! free snapshot: no background workers are spawned, no recall traces or
//! reward marks are written on the read path, and every mutating tool is
//! refused. The posture lives on the serve process and its dispatcher only;
//! nothing about it is persisted in the estate.
//!
//! Swift twin: packages/kits/AriaMcpKit/Sources/AriaMCP/EstatePosture.swift.

/// Whether the served estate is live (the default) or frozen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstatePosture {
    /// Normal serve: background workers run, recall traces and reward marks
    /// are written, mutating tools execute.
    Live,
    /// Snapshot serve: `mootx01 serve --frozen` or `MOOTX01_FROZEN=1`.
    Frozen,
}

impl EstatePosture {
    /// Environment twin of `mootx01 serve --frozen`. The value `"1"` enables
    /// the frozen posture; any other value, or absence, leaves the estate
    /// live. Strict on purpose: a benchmark lane that exports a stray value
    /// must not silently freeze a seeding serve.
    pub const ENVIRONMENT_KEY: &'static str = "MOOTX01_FROZEN";

    /// The line a frozen serve logs at startup. Byte-identical in both ports.
    pub const FROZEN_LOG_LINE: &'static str =
        "FROZEN: no background workers, no recall traces, mutating tools refused";

    /// Resolve the posture from the `--frozen` flag and the environment
    /// value. The flag wins: `--frozen` freezes even when the variable is
    /// absent or holds another value. Without the flag, `MOOTX01_FROZEN=1`
    /// freezes.
    pub fn resolve(frozen_flag: bool, environment_value: Option<&str>) -> Self {
        if frozen_flag || environment_value == Some("1") {
            EstatePosture::Frozen
        } else {
            EstatePosture::Live
        }
    }

    /// Resolve from the process environment alone (no flag). Used by the
    /// dispatcher constructor, which runs inside the runtime after the CLI
    /// has translated `--frozen` into `MOOTX01_FROZEN=1`.
    pub fn from_process_environment() -> Self {
        Self::resolve(false, std::env::var(Self::ENVIRONMENT_KEY).ok().as_deref())
    }

    /// The `isError` text a frozen dispatcher returns for a mutating tool.
    /// Byte-identical in both ports.
    pub fn refusal_message(tool: &str) -> String {
        format!("estate is frozen (serve --frozen): {tool} is a mutating tool and was refused")
    }

    /// Value rendered on the `frozen:` line of `moot_estate_status`.
    pub fn status_value(self) -> &'static str {
        match self {
            EstatePosture::Frozen => "true",
            EstatePosture::Live => "false",
        }
    }

    /// True when the posture is frozen.
    pub fn is_frozen(self) -> bool {
        self == EstatePosture::Frozen
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_environment_is_live() {
        assert_eq!(EstatePosture::resolve(false, None), EstatePosture::Live);
    }

    #[test]
    fn environment_one_freezes_and_other_values_stay_live() {
        assert_eq!(EstatePosture::resolve(false, Some("1")), EstatePosture::Frozen);
        for v in ["0", "true", "yes", ""] {
            assert_eq!(EstatePosture::resolve(false, Some(v)), EstatePosture::Live, "MOOTX01_FROZEN={v}");
        }
    }

    #[test]
    fn flag_wins_over_environment() {
        assert_eq!(EstatePosture::resolve(true, Some("0")), EstatePosture::Frozen);
        assert_eq!(EstatePosture::resolve(true, None), EstatePosture::Frozen);
    }

    #[test]
    fn contract_text_is_pinned() {
        assert_eq!(
            EstatePosture::FROZEN_LOG_LINE,
            "FROZEN: no background workers, no recall traces, mutating tools refused"
        );
        assert_eq!(
            EstatePosture::refusal_message("moot_file_memory"),
            "estate is frozen (serve --frozen): moot_file_memory is a mutating tool and was refused"
        );
        assert_eq!(EstatePosture::Frozen.status_value(), "true");
        assert_eq!(EstatePosture::Live.status_value(), "false");
    }
}
