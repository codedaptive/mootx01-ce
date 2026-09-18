//! obsidian — deterministic Obsidian sync-status state machine (Wave C2: CORE-06 Rust parity).
//!
//! Implements the ObsidianStatus discriminated union and its canonical JSON
//! serialization so that vector-in produces byte-identical output to the shared
//! vectors at apps/mootx01/testdata/obsidian-vectors/*.json and to the Swift
//! CommunityObsidianModels implementation.
//!
//! # Status Union
//!
//! Discriminator field: "state"
//! Values: starting | scanning | synchronizing | idle | waiting | paused |
//!         interrupted | blocked | failed
//!
//! # Invariants (machine-checkable, mirrored from vector README)
//!
//! 1. checkpointAt and recordCount are BOTH present or BOTH absent (never one
//!    without the other).
//! 2. pendingCount and totalCount are BOTH present or BOTH absent.
//! 3. When both pendingCount and totalCount are present: pendingCount <= totalCount.
//! 4. States interrupted/blocked/failed MUST carry a reason string.
//! 5. States interrupted/failed MUST carry a retryable boolean.
//!
//! # Transition Rules
//!
//! disable: any running state → paused; checkpoint fields PRESERVED.
//! retry:   only permitted when state == interrupted AND retryable == true;
//!          refused (cannot_retry) otherwise.
//!
//! # Canonical JSON
//!
//! Keys are sorted alphabetically (BTreeMap-backed, same pattern as review.rs).
//! Values: state/reason/checkpointAt/until as strings; retryable as bool;
//! recordCount/pendingCount/totalCount as integers.
//! The _comment field from vector files is NEVER included in serialized output.

use std::collections::BTreeMap;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// All fields use owned Strings for checkpoint/reason timestamps to avoid
/// chrono dependency (matching review.rs: ISO8601 strings are stored as-is;
/// string comparison is valid for UTC ISO8601).
///
/// pendingCount/totalCount/recordCount use i64 to match the contract's
/// integer type (matching the Swift Int64 encoding in CommunityObsidianModels).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ObsidianStatus {
    /// Service started; startup resync in progress — no checkpoint yet.
    Starting,
    /// Active filesystem scan in progress — discovered changes being enumerated.
    Scanning,
    /// Actively writing changes to the vault.
    ///
    /// pendingCount and totalCount appear together (both or neither).
    /// pendingCount <= totalCount enforced by the invariant.
    /// checkpoint fields track last committed sync point (may be from a prior run).
    Synchronizing {
        pending_count: Option<i64>,
        total_count: Option<i64>,
        checkpoint_at: Option<String>,
        record_count: Option<i64>,
    },
    /// Sync complete; next poll scheduled. checkpoint fields reflect last commit.
    Idle {
        checkpoint_at: Option<String>,
        record_count: Option<i64>,
    },
    /// Idle; waiting until the next scheduled poll tick.
    ///
    /// `until` is the ISO8601 timestamp of the next wake, if known.
    Waiting {
        until: Option<String>,
        checkpoint_at: Option<String>,
        record_count: Option<i64>,
    },
    /// Service is disabled (user-disabled or vault not selected).
    ///
    /// checkpoint fields PRESERVED from the last successful sync so that
    /// re-enable can resume without a full rescan.
    Paused {
        checkpoint_at: Option<String>,
        record_count: Option<i64>,
    },
    /// Sync was running and was interrupted by a transient condition.
    ///
    /// retryable == true  → caller may call retry() to resume.
    /// retryable == false → requires manual intervention (terminal).
    ///
    /// pendingCount/totalCount may be present when the interruption happened
    /// mid-batch (carrying over the in-progress progress counters).
    Interrupted {
        reason: String,
        retryable: bool,
        pending_count: Option<i64>,
        total_count: Option<i64>,
        checkpoint_at: Option<String>,
        record_count: Option<i64>,
    },
    /// Service cannot start because a precondition is permanently unmet.
    ///
    /// No retryable field — blocked states are not auto-retried.
    Blocked {
        reason: String,
        checkpoint_at: Option<String>,
        record_count: Option<i64>,
    },
    /// Sync failed with a non-recoverable error after an attempt.
    ///
    /// retryable == true  → daemon will retry automatically.
    /// retryable == false → requires external intervention (e.g. manual repair).
    Failed {
        reason: String,
        retryable: bool,
        checkpoint_at: Option<String>,
        record_count: Option<i64>,
    },
}

/// Classification of a retry decision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RetryDecision {
    /// Retry is permitted — the caller may attempt to resume sync.
    Permitted,
    /// Retry is refused — the current state is not retryable.
    ///
    /// Reason is the contract error code (e.g. "sync-not-retryable").
    Refused { reason: String },
}

// ---------------------------------------------------------------------------
// Transition helpers
// ---------------------------------------------------------------------------

/// Evaluate whether the current status permits a retry.
///
/// Only `interrupted{retryable: true}` returns `Permitted`. Every other state —
/// including `interrupted{retryable: false}` and `failed` — returns `Refused`.
/// This mirrors C6-T7 in CommunityObsidianTests: "retry from terminal
/// non-retryable state ⇒ refused{sync-not-retryable}".
pub fn can_retry(status: &ObsidianStatus) -> RetryDecision {
    match status {
        ObsidianStatus::Interrupted { retryable: true, .. } => RetryDecision::Permitted,
        _ => RetryDecision::Refused {
            reason: "sync-not-retryable".to_string(),
        },
    }
}

/// Apply a disable transition, preserving checkpoint fields.
///
/// Any active state transitions to `paused`; checkpoint_at and record_count
/// are carried forward unchanged so that re-enable can resume without a
/// full rescan. The disable-preserves-content contract (CORE-06 acceptance
/// criterion and C6-T8) is expressed here.
pub fn transition_disable(status: &ObsidianStatus) -> ObsidianStatus {
    // Extract checkpoint fields from whatever state we are in.
    let (checkpoint_at, record_count) = extract_checkpoint(status);
    ObsidianStatus::Paused { checkpoint_at, record_count }
}

/// Classify an interruption reason: is it retryable or terminal?
///
/// The retryability rules follow the contract's error-code table:
///   - vault-access-revoked   → retryable (re-mount / re-auth resolves it)
///   - permission-revoked     → retryable (user can re-grant)
///   - vault-authorization-missing → NOT retryable (needs explicit re-auth flow)
///   - vault-content-malformed     → NOT retryable (manual repair needed)
///   - unexpected-failure          → NOT retryable by default (conservative)
///   - sync-not-retryable          → NOT retryable (explicit terminal)
///   - internal-error              → NOT retryable (conservative)
///   - daemon-blocked              → NOT retryable (structural precondition unmet)
///   - anything else (unknown)     → NOT retryable (fail closed)
pub fn classify_retryable(reason: &str) -> bool {
    matches!(reason, "vault-access-revoked" | "permission-revoked")
}

// ---------------------------------------------------------------------------
// Parsing from JSON (vector entry → ObsidianStatus)
// ---------------------------------------------------------------------------

/// Parse an ObsidianStatus from a JSON object (e.g. a vector entry).
///
/// Returns `None` when the "state" field is missing or unrecognised —
/// unknown states fail closed per the contract.
///
/// The `_comment` field (used in vector files for human documentation) is
/// silently ignored. All other unexpected fields are also ignored so that
/// vectors can carry forward-compatible additions without breaking existing
/// tests.
pub fn parse_status(entry: &serde_json::Value) -> Option<ObsidianStatus> {
    let state = entry["state"].as_str()?;

    // Checkpoint fields — read together; both or neither.
    // parse_checkpoint enforces the invariant: if one is present the other
    // must be present too; mismatched pairs return (None, None) with a debug
    // warning rather than silently violating the invariant.
    let (checkpoint_at, record_count) = parse_checkpoint(entry);

    match state {
        "starting" => Some(ObsidianStatus::Starting),

        "scanning" => Some(ObsidianStatus::Scanning),

        "synchronizing" => {
            // pendingCount and totalCount appear together.
            let (pending_count, total_count) = parse_pending_total(entry);
            Some(ObsidianStatus::Synchronizing {
                pending_count,
                total_count,
                checkpoint_at,
                record_count,
            })
        }

        "idle" => Some(ObsidianStatus::Idle { checkpoint_at, record_count }),

        "waiting" => {
            let until = entry.get("until")
                .and_then(|v| v.as_str())
                .map(String::from);
            Some(ObsidianStatus::Waiting { until, checkpoint_at, record_count })
        }

        "paused" => Some(ObsidianStatus::Paused { checkpoint_at, record_count }),

        "interrupted" => {
            let reason = entry["reason"].as_str()?.to_string();
            let retryable = entry["retryable"].as_bool()?;
            // pendingCount/totalCount may be present when interrupted mid-batch.
            let (pending_count, total_count) = parse_pending_total(entry);
            Some(ObsidianStatus::Interrupted {
                reason,
                retryable,
                pending_count,
                total_count,
                checkpoint_at,
                record_count,
            })
        }

        "blocked" => {
            let reason = entry["reason"].as_str()?.to_string();
            Some(ObsidianStatus::Blocked {
                reason,
                checkpoint_at,
                record_count,
            })
        }

        "failed" => {
            let reason = entry["reason"].as_str()?.to_string();
            let retryable = entry["retryable"].as_bool()?;
            Some(ObsidianStatus::Failed {
                reason,
                retryable,
                checkpoint_at,
                record_count,
            })
        }

        // Unknown states fail closed — unknown field/enum → None.
        _ => None,
    }
}

/// Parse checkpoint fields; enforce the both-or-neither invariant.
///
/// Returns (None, None) when either field is absent or the pair is mismatched.
fn parse_checkpoint(entry: &serde_json::Value) -> (Option<String>, Option<i64>) {
    let ca = entry.get("checkpointAt").and_then(|v| v.as_str()).map(String::from);
    let rc = entry.get("recordCount").and_then(|v| v.as_i64());
    // Invariant: both or neither.
    match (ca, rc) {
        (Some(c), Some(r)) => (Some(c), Some(r)),
        (None, None) => (None, None),
        // Mismatched — treat as both absent (fail safely).
        _ => (None, None),
    }
}

/// Parse pendingCount/totalCount; enforce the both-or-neither and ≤ invariant.
///
/// Returns (None, None) when mismatched or when pendingCount > totalCount.
fn parse_pending_total(entry: &serde_json::Value) -> (Option<i64>, Option<i64>) {
    let p = entry.get("pendingCount").and_then(|v| v.as_i64());
    let t = entry.get("totalCount").and_then(|v| v.as_i64());
    match (p, t) {
        (Some(p_val), Some(t_val)) if p_val <= t_val => (Some(p_val), Some(t_val)),
        (None, None) => (None, None),
        // Mismatched or invariant violation — omit both.
        _ => (None, None),
    }
}

/// Extract checkpoint fields from any ObsidianStatus variant.
///
/// Used by transition_disable to carry checkpoint forward into Paused.
fn extract_checkpoint(status: &ObsidianStatus) -> (Option<String>, Option<i64>) {
    match status {
        ObsidianStatus::Starting  | ObsidianStatus::Scanning => (None, None),
        ObsidianStatus::Synchronizing { checkpoint_at, record_count, .. }
        | ObsidianStatus::Idle      { checkpoint_at, record_count }
        | ObsidianStatus::Waiting   { checkpoint_at, record_count, .. }
        | ObsidianStatus::Paused    { checkpoint_at, record_count }
        | ObsidianStatus::Interrupted { checkpoint_at, record_count, .. }
        | ObsidianStatus::Blocked   { checkpoint_at, record_count, .. }
        | ObsidianStatus::Failed    { checkpoint_at, record_count, .. } => {
            (checkpoint_at.clone(), *record_count)
        }
    }
}

// ---------------------------------------------------------------------------
// Canonical JSON serialization
// ---------------------------------------------------------------------------

/// Serialize an ObsidianStatus to a canonical sorted-key JSON Value.
///
/// Keys are sorted alphabetically via BTreeMap, matching:
///   - The Swift CommunityObsidianModels .sortedKeys encoding
///   - The vector files' field order after normalize_json
///
/// The _comment field is NEVER included in output. Only the wire fields
/// defined in the contract appear.
pub fn to_canonical_json(status: &ObsidianStatus) -> serde_json::Value {
    let mut btree: BTreeMap<&str, serde_json::Value> = BTreeMap::new();

    match status {
        ObsidianStatus::Starting => {
            btree.insert("state", serde_json::Value::String("starting".to_string()));
        }

        ObsidianStatus::Scanning => {
            btree.insert("state", serde_json::Value::String("scanning".to_string()));
        }

        ObsidianStatus::Synchronizing { pending_count, total_count, checkpoint_at, record_count } => {
            btree.insert("state", serde_json::Value::String("synchronizing".to_string()));
            // pendingCount and totalCount appear together — both or neither.
            if let (Some(p), Some(t)) = (pending_count, total_count) {
                btree.insert("pendingCount", serde_json::Value::Number((*p).into()));
                btree.insert("totalCount", serde_json::Value::Number((*t).into()));
            }
            // Common checkpoint fields — both or neither.
            insert_checkpoint(&mut btree, checkpoint_at.as_deref(), *record_count);
        }

        ObsidianStatus::Idle { checkpoint_at, record_count } => {
            btree.insert("state", serde_json::Value::String("idle".to_string()));
            insert_checkpoint(&mut btree, checkpoint_at.as_deref(), *record_count);
        }

        ObsidianStatus::Waiting { until, checkpoint_at, record_count } => {
            btree.insert("state", serde_json::Value::String("waiting".to_string()));
            if let Some(u) = until {
                btree.insert("until", serde_json::Value::String(u.clone()));
            }
            insert_checkpoint(&mut btree, checkpoint_at.as_deref(), *record_count);
        }

        ObsidianStatus::Paused { checkpoint_at, record_count } => {
            btree.insert("state", serde_json::Value::String("paused".to_string()));
            insert_checkpoint(&mut btree, checkpoint_at.as_deref(), *record_count);
        }

        ObsidianStatus::Interrupted { reason, retryable, pending_count, total_count, checkpoint_at, record_count } => {
            btree.insert("state", serde_json::Value::String("interrupted".to_string()));
            btree.insert("reason", serde_json::Value::String(reason.clone()));
            btree.insert("retryable", serde_json::Value::Bool(*retryable));
            // pendingCount/totalCount appear together when interrupted mid-batch.
            if let (Some(p), Some(t)) = (pending_count, total_count) {
                btree.insert("pendingCount", serde_json::Value::Number((*p).into()));
                btree.insert("totalCount", serde_json::Value::Number((*t).into()));
            }
            insert_checkpoint(&mut btree, checkpoint_at.as_deref(), *record_count);
        }

        ObsidianStatus::Blocked { reason, checkpoint_at, record_count } => {
            btree.insert("state", serde_json::Value::String("blocked".to_string()));
            btree.insert("reason", serde_json::Value::String(reason.clone()));
            insert_checkpoint(&mut btree, checkpoint_at.as_deref(), *record_count);
        }

        ObsidianStatus::Failed { reason, retryable, checkpoint_at, record_count } => {
            btree.insert("state", serde_json::Value::String("failed".to_string()));
            btree.insert("reason", serde_json::Value::String(reason.clone()));
            btree.insert("retryable", serde_json::Value::Bool(*retryable));
            insert_checkpoint(&mut btree, checkpoint_at.as_deref(), *record_count);
        }
    }

    // Convert sorted BTreeMap into a serde_json::Map to produce sorted-key JSON.
    let mut map = serde_json::Map::new();
    for (k, v) in btree {
        map.insert(k.to_string(), v);
    }
    serde_json::Value::Object(map)
}

/// Insert checkpointAt and recordCount together — both or neither.
///
/// Enforces the contract invariant at the serialization boundary:
/// if one is Some, the other must also be Some; mismatched pairs are silently
/// omitted (both fields absent) rather than producing a malformed output.
fn insert_checkpoint(
    btree: &mut BTreeMap<&str, serde_json::Value>,
    checkpoint_at: Option<&str>,
    record_count: Option<i64>,
) {
    // Both present or both absent — invariant enforced here.
    if let (Some(ca), Some(rc)) = (checkpoint_at, record_count) {
        btree.insert("checkpointAt", serde_json::Value::String(ca.to_string()));
        btree.insert("recordCount", serde_json::Value::Number(rc.into()));
    }
    // If mismatched, omit both (fail safely).
}

// ---------------------------------------------------------------------------
// Normalize helper (reused from review.rs pattern)
// ---------------------------------------------------------------------------

/// Normalize a JSON Value to sorted-key objects at every level.
///
/// Strips the `_comment` key (used in vector files for human annotation;
/// never part of the canonical wire shape). Returns the cleaned,
/// sorted-key value for comparison against Rust-generated output.
pub fn normalize_vector_entry(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(map) => {
            let mut btree: BTreeMap<String, serde_json::Value> = BTreeMap::new();
            for (k, val) in map {
                // Drop _comment — it is a documentation field, not wire data.
                if k == "_comment" { continue; }
                btree.insert(k, normalize_vector_entry(val));
            }
            let mut out = serde_json::Map::new();
            for (k, val) in btree {
                out.insert(k, val);
            }
            serde_json::Value::Object(out)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(normalize_vector_entry).collect())
        }
        other => other,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Resolve the path to an obsidian vector file relative to the crate root.
    ///
    /// Vector files live at apps/mootx01/testdata/obsidian-vectors/ relative to
    /// the workspace root. From inside the crate at apps/mootx01/rust/ we go up
    /// one level (to apps/mootx01/), then descend into testdata/obsidian-vectors/.
    fn vector_path(name: &str) -> std::path::PathBuf {
        // CARGO_MANIFEST_DIR is apps/mootx01/rust when running tests.
        let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        manifest.join("..").join("testdata").join("obsidian-vectors").join(name)
    }

    /// Load and parse a vector file; return as a serde_json::Value (must be an array).
    fn load_vector_array(filename: &str) -> serde_json::Value {
        let path = vector_path(filename);
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read vector {}: {}", path.display(), e));
        serde_json::from_str(&text)
            .unwrap_or_else(|e| panic!("failed to parse vector {}: {}", filename, e))
    }

    /// Core parity assertion for a single vector file.
    ///
    /// For each entry in the file:
    ///   1. Normalise the entry (sort keys, strip _comment) → expected JSON.
    ///   2. Parse the entry into an ObsidianStatus.
    ///   3. Serialise to canonical JSON via to_canonical_json → got JSON.
    ///   4. Assert byte-identical output.
    fn assert_vector_parity(filename: &str) {
        let array = load_vector_array(filename);
        let entries = array.as_array()
            .unwrap_or_else(|| panic!("vector {} is not a JSON array", filename));

        for (idx, entry) in entries.iter().enumerate() {
            // Expected: the entry as it appears in the vector, minus _comment,
            // with keys sorted so comparison is key-order-independent.
            let expected_val = normalize_vector_entry(entry.clone());
            let expected_json = serde_json::to_string(&expected_val)
                .unwrap_or_else(|e| panic!("failed to serialise expected entry {}[{}]: {}", filename, idx, e));

            // Actual: parse to ObsidianStatus then re-serialise.
            let status = parse_status(entry)
                .unwrap_or_else(|| panic!(
                    "parse_status returned None for {}[{}] (state={:?})",
                    filename, idx, entry["state"]
                ));
            let got_val = to_canonical_json(&status);
            let got_json = serde_json::to_string(&got_val)
                .unwrap_or_else(|e| panic!("failed to serialise got entry {}[{}]: {}", filename, idx, e));

            assert_eq!(
                got_json, expected_json,
                "parity failure for {}[{}]\n  GOT:      {}\n  EXPECTED: {}",
                filename, idx, got_json, expected_json,
            );
        }
    }

    // -----------------------------------------------------------------------
    // C6-P1 to C6-P4: Vector parity tests — one per file
    // -----------------------------------------------------------------------

    /// C6-P1: Full state-machine lifecycle vector.
    /// Covers: blocked(no-auth) → paused → starting → scanning →
    ///         synchronizing → idle → waiting → paused(disabled).
    #[test]
    fn c6_p1_lifecycle_parity() {
        assert_vector_parity("status-lifecycle.json");
    }

    /// C6-P2: Error and interruption scenarios.
    /// Covers: interrupted(retryable) with/without checkpoint,
    ///         failed(non-retryable), blocked(daemon-blocked),
    ///         interrupted mid-batch with pendingCount/totalCount.
    #[test]
    fn c6_p2_error_states_parity() {
        assert_vector_parity("status-error-states.json");
    }

    /// C6-P3: Checkpoint field invariant vectors.
    /// Covers: paused with no checkpoint, idle with 0/1/large recordCount,
    ///         waiting with checkpoint, interrupted with checkpoint.
    #[test]
    fn c6_p3_checkpoint_parity() {
        assert_vector_parity("status-checkpoint.json");
    }

    /// C6-P4: Synchronizing state vectors with various pendingCount/totalCount.
    /// Covers: all-pending, half done, one remaining, zero pending (= about to
    ///         become idle), synchronizing with prior-run checkpoint.
    #[test]
    fn c6_p4_synchronizing_parity() {
        assert_vector_parity("status-synchronizing.json");
    }

    // -----------------------------------------------------------------------
    // C6-U: Unit tests for transition rules and invariant enforcement
    // -----------------------------------------------------------------------

    /// C6-U1: Retry is permitted from interrupted{retryable: true}.
    ///
    /// The only state that permits retry is interrupted with retryable==true.
    #[test]
    fn c6_u1_retry_permitted_from_interrupted_retryable() {
        let status = ObsidianStatus::Interrupted {
            reason: "vault-access-revoked".to_string(),
            retryable: true,
            pending_count: None,
            total_count: None,
            checkpoint_at: None,
            record_count: None,
        };
        assert_eq!(can_retry(&status), RetryDecision::Permitted);
    }

    /// C6-U2: Retry refused from interrupted{retryable: false}.
    ///
    /// A terminal interruption (e.g. corrupted state) cannot be retried.
    /// Mirrors C6-T7: "retry from terminal non-retryable state ⇒ refused{sync-not-retryable}".
    #[test]
    fn c6_u2_retry_refused_from_interrupted_non_retryable() {
        let status = ObsidianStatus::Interrupted {
            reason: "internal-error".to_string(),
            retryable: false,
            pending_count: None,
            total_count: None,
            checkpoint_at: None,
            record_count: None,
        };
        assert_eq!(can_retry(&status), RetryDecision::Refused {
            reason: "sync-not-retryable".to_string(),
        });
    }

    /// C6-U3: Retry refused from failed{retryable: false} (terminal failure).
    #[test]
    fn c6_u3_retry_refused_from_failed_non_retryable() {
        let status = ObsidianStatus::Failed {
            reason: "internal-error".to_string(),
            retryable: false,
            checkpoint_at: None,
            record_count: None,
        };
        assert_eq!(can_retry(&status), RetryDecision::Refused {
            reason: "sync-not-retryable".to_string(),
        });
    }

    /// C6-U4: Retry refused from idle (not an error state).
    ///
    /// Retry is a no-op for any non-interrupted state.
    #[test]
    fn c6_u4_retry_refused_from_idle() {
        let status = ObsidianStatus::Idle {
            checkpoint_at: Some("2026-08-23T14:00:00Z".to_string()),
            record_count: Some(5),
        };
        assert_eq!(can_retry(&status), RetryDecision::Refused {
            reason: "sync-not-retryable".to_string(),
        });
    }

    /// C6-U5: Retry refused from paused (service disabled — cannot auto-retry).
    #[test]
    fn c6_u5_retry_refused_from_paused() {
        let status = ObsidianStatus::Paused {
            checkpoint_at: None,
            record_count: None,
        };
        assert_eq!(can_retry(&status), RetryDecision::Refused {
            reason: "sync-not-retryable".to_string(),
        });
    }

    /// C6-U6: Retry refused from blocked (structural precondition unmet).
    #[test]
    fn c6_u6_retry_refused_from_blocked() {
        let status = ObsidianStatus::Blocked {
            reason: "vault-authorization-missing".to_string(),
            checkpoint_at: None,
            record_count: None,
        };
        assert_eq!(can_retry(&status), RetryDecision::Refused {
            reason: "sync-not-retryable".to_string(),
        });
    }

    /// C6-U7: Disable from synchronizing preserves checkpoint fields.
    ///
    /// Mirrors C6-T8: "disable preserves vault content + truthful checkpoint state".
    #[test]
    fn c6_u7_disable_preserves_checkpoint_from_synchronizing() {
        let status = ObsidianStatus::Synchronizing {
            pending_count: Some(3),
            total_count: Some(10),
            checkpoint_at: Some("2026-08-23T13:58:00Z".to_string()),
            record_count: Some(7),
        };
        let after = transition_disable(&status);
        assert_eq!(
            after,
            ObsidianStatus::Paused {
                checkpoint_at: Some("2026-08-23T13:58:00Z".to_string()),
                record_count: Some(7),
            }
        );
    }

    /// C6-U8: Disable from idle preserves checkpoint fields.
    #[test]
    fn c6_u8_disable_preserves_checkpoint_from_idle() {
        let status = ObsidianStatus::Idle {
            checkpoint_at: Some("2026-08-23T14:00:00Z".to_string()),
            record_count: Some(12),
        };
        let after = transition_disable(&status);
        assert_eq!(
            after,
            ObsidianStatus::Paused {
                checkpoint_at: Some("2026-08-23T14:00:00Z".to_string()),
                record_count: Some(12),
            }
        );
    }

    /// C6-U9: Disable from starting (no checkpoint) produces paused with no checkpoint.
    ///
    /// If the service was never able to complete a sync, disable produces
    /// paused with both checkpoint fields absent — not a contract violation.
    #[test]
    fn c6_u9_disable_from_starting_no_checkpoint() {
        let status = ObsidianStatus::Starting;
        let after = transition_disable(&status);
        assert_eq!(
            after,
            ObsidianStatus::Paused {
                checkpoint_at: None,
                record_count: None,
            }
        );
    }

    /// C6-U10: vault-access-revoked is classified as retryable.
    ///
    /// Re-mount or re-auth resolves this condition; the daemon should retry.
    #[test]
    fn c6_u10_vault_access_revoked_is_retryable() {
        assert!(classify_retryable("vault-access-revoked"));
    }

    /// C6-U11: permission-revoked is classified as retryable.
    #[test]
    fn c6_u11_permission_revoked_is_retryable() {
        assert!(classify_retryable("permission-revoked"));
    }

    /// C6-U12: vault-authorization-missing is classified as NOT retryable.
    ///
    /// This requires an explicit re-auth flow — automatic retry would loop.
    #[test]
    fn c6_u12_vault_authorization_missing_not_retryable() {
        assert!(!classify_retryable("vault-authorization-missing"));
    }

    /// C6-U13: internal-error is classified as NOT retryable.
    ///
    /// Conservative: unknown internal failure requires investigation.
    #[test]
    fn c6_u13_internal_error_not_retryable() {
        assert!(!classify_retryable("internal-error"));
    }

    /// C6-U14: Unknown/future error codes fail closed (not retryable).
    #[test]
    fn c6_u14_unknown_reason_not_retryable() {
        assert!(!classify_retryable("some-future-error-code"));
    }

    /// C6-U15: checkpointAt/recordCount invariant — mismatched pair omits both.
    ///
    /// If a caller provides checkpointAt without recordCount (or vice versa),
    /// to_canonical_json omits BOTH fields rather than violating the invariant.
    #[test]
    fn c6_u15_mismatched_checkpoint_omits_both() {
        // Construct directly (bypassing parse_status which also enforces it).
        let status = ObsidianStatus::Idle {
            checkpoint_at: Some("2026-08-23T14:00:00Z".to_string()),
            record_count: None,   // ← mismatched: checkpointAt present, recordCount absent
        };
        let json = to_canonical_json(&status);
        assert!(json.get("checkpointAt").is_none(), "checkpointAt must be absent when recordCount is absent");
        assert!(json.get("recordCount").is_none(), "recordCount must be absent when checkpointAt is absent");
    }

    /// C6-U16: pendingCount <= totalCount invariant on parse_pending_total.
    ///
    /// A vector entry with pendingCount > totalCount is malformed; parse_pending_total
    /// omits both fields rather than propagating the invalid pair.
    #[test]
    fn c6_u16_pending_greater_than_total_omits_both() {
        let entry = serde_json::json!({
            "state": "synchronizing",
            "pendingCount": 15,
            "totalCount": 10
        });
        let status = parse_status(&entry).expect("parse must succeed for synchronizing");
        let json = to_canonical_json(&status);
        assert!(json.get("pendingCount").is_none(), "pendingCount must be absent when it exceeds totalCount");
        assert!(json.get("totalCount").is_none(), "totalCount must be absent when pendingCount violates invariant");
    }

    /// C6-U17: Unknown state fails closed (parse_status returns None).
    ///
    /// Future/unknown state strings must not be accepted — fail closed per contract.
    #[test]
    fn c6_u17_unknown_state_fails_closed() {
        let entry = serde_json::json!({ "state": "some-future-state" });
        assert!(
            parse_status(&entry).is_none(),
            "unknown state must return None (fail closed)"
        );
    }

    /// C6-U18: All vector entries in every file are parseable and round-trip cleanly.
    ///
    /// This is the comprehensive invariant check: load all four files, parse every
    /// entry, re-serialise, and assert byte-identical match against the normalised
    /// vector entry. Duplicates the per-file parity tests for cross-verification.
    #[test]
    fn c6_u18_all_vectors_round_trip() {
        let files = [
            "status-lifecycle.json",
            "status-error-states.json",
            "status-checkpoint.json",
            "status-synchronizing.json",
        ];
        for filename in &files {
            // Each assert_vector_parity call panics on first mismatch with context.
            // Using the same helper as the per-file tests for consistency.
            // (Implemented inline here to avoid test isolation issues.)
            let array = load_vector_array(filename);
            let entries = array.as_array()
                .unwrap_or_else(|| panic!("{} is not a JSON array", filename));
            for (idx, entry) in entries.iter().enumerate() {
                let expected_val = normalize_vector_entry(entry.clone());
                let expected_json = serde_json::to_string(&expected_val).unwrap();

                let status = parse_status(entry).unwrap_or_else(|| {
                    panic!("parse_status returned None for {}[{}]", filename, idx)
                });
                let got_val = to_canonical_json(&status);
                let got_json = serde_json::to_string(&got_val).unwrap();

                assert_eq!(
                    got_json, expected_json,
                    "round-trip failure {}[{}]\n  GOT:      {}\n  EXPECTED: {}",
                    filename, idx, got_json, expected_json,
                );
            }
        }
    }
}
