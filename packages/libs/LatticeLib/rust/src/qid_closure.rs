// qid_closure.rs — Q-ID taxonomic-closure surface
//
// Port of QIDClosure.swift. Loads the pinned Wikidata direct-edge graph
// (`QIDClosureEdges.json`) once per process via `include_bytes!` and exposes
// the TRANSITIVE ancestor closure of any Q-ID.
//
// The Swift surface loads via `Bundle.module.url(forResource:...)`. The Rust
// equivalent is `include_bytes!` at compile time — same pinning guarantee,
// zero runtime I/O. Mirrors `fdc_runtime.rs`'s artifact embedding.
//
// The bundled artifact is a pinned, build-time, offline Wikidata snapshot of
// direct P31/P279 (instance-of / subclass-of) edges:
//
//   { "edges": { "<qid>": ["<sorted direct parent qids>", ...] }, ... }
//
// produced by the Q-ID closure ETL (EE build tooling) and checked in like the FDC
// artifacts. The runtime NEVER re-queries Wikidata — the closure is computed
// locally by BFS over these pinned edges. This keeps `ancestors` pure,
// deterministic, and byte-identical to the Swift port (`QIDClosure.swift`).
//
// Artifact path is relative to this source file (the macro resolves relative
// to the source file location, not the crate root). The JSON lives at:
//   ../../Sources/LatticeLib/Resources/QIDClosureEdges.json
// which is correct for the position of this file at
//   packages/libs/LatticeLib/rust/src/qid_closure.rs

use std::collections::{BTreeSet, HashMap};
use std::sync::{Mutex, OnceLock};

/// The decoded edge graph: `{ "<qid>": [<direct parent qids>] }` plus the
/// pinned-artifact version. Decoded once per process from the embedded JSON.
#[derive(serde::Deserialize)]
struct GraphFile {
    edges: HashMap<String, Vec<String>>,
    version: String,
}

/// The loaded graph, parsed once per process. `None` only if the embedded JSON
/// fails to parse (a build-time invariant — the artifact is checked in).
static GRAPH: OnceLock<Option<GraphFile>> = OnceLock::new();

/// Per-qid closure memo, guarded by a `Mutex`. Mirrors the Swift
/// `os_unfair_lock`-guarded `memo` dictionary: the closure of a distinct qid
/// is computed at most once per process.
static MEMO: OnceLock<Mutex<HashMap<String, Vec<String>>>> = OnceLock::new();

fn graph() -> Option<&'static GraphFile> {
    GRAPH
        .get_or_init(|| {
            // Embed the pinned edge graph at compile time. Path is relative to
            // this source file (matches `fdc_runtime.rs`'s artifact paths).
            const EDGES_JSON: &[u8] =
                include_bytes!("../../Sources/LatticeLib/Resources/QIDClosureEdges.json");
            serde_json::from_slice::<GraphFile>(EDGES_JSON).ok()
        })
        .as_ref()
}

fn memo() -> &'static Mutex<HashMap<String, Vec<String>>> {
    MEMO.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The transitive ancestor closure of `qid` over the pinned P31/P279 edge
/// graph, sorted numerically by the integer part of the Q-ID and EXCLUDING
/// `qid` itself. An empty or unknown qid (or unavailable artifact) → `vec![]`.
///
/// Deterministic and pure over the pinned artifact. The result is memoized
/// per distinct qid for the life of the process. Byte-identical to the Swift
/// `QIDClosure.ancestors(of:)`: same edges, same BFS, same numeric sort, same
/// exclusion of the queried qid.
///
/// # Arguments
/// * `qid` — A Wikidata Q-ID, e.g. `"Q146"`.
///
/// # Returns
/// The sorted ancestor Q-IDs, e.g. `["Q336", "Q729", ...]`.
pub fn ancestors(qid: &str) -> Vec<String> {
    if qid.is_empty() {
        return Vec::new();
    }
    let graph = match graph() {
        Some(g) => g,
        None => return Vec::new(),
    };

    // Memo fast path: the closure of a distinct qid is computed once. The BFS
    // runs outside the lock (the lock only guards the map), so concurrent
    // callers for different qids do not serialize on the compute. A lost-update
    // race for the same qid is harmless — the closure is pure, so both threads
    // produce the identical Vec.
    if let Some(cached) = memo().lock().expect("qid-closure memo poisoned").get(qid) {
        return cached.clone();
    }

    let result = compute_closure(qid, &graph.edges);

    memo()
        .lock()
        .expect("qid-closure memo poisoned")
        .insert(qid.to_string(), result.clone());
    result
}

/// True when the bundled edge graph loaded and the surface is ready.
pub fn is_available() -> bool {
    graph().is_some()
}

/// The pinned-artifact version string (`"version"` field of the bundled
/// graph), or `"0.0.0-unavailable"` when the artifact failed to load.
pub fn data_version() -> &'static str {
    graph().map(|g| g.version.as_str()).unwrap_or("0.0.0-unavailable")
}

/// Compute the transitive closure of `qid` by breadth-first walk over the
/// direct-edge map, excluding `qid` itself, returned sorted numerically by the
/// integer part of the Q-ID. The walk is iterative and dedupes via `seen`, so
/// any cycle in the source graph terminates. Identical control flow to the
/// Swift port's `computeClosure`.
fn compute_closure(qid: &str, edges: &HashMap<String, Vec<String>>) -> Vec<String> {
    let mut seen: BTreeSet<String> = BTreeSet::new();
    // Seed the frontier with the direct parents of `qid` (not `qid`), so `qid`
    // is excluded from its own closure.
    let mut frontier: Vec<String> = edges.get(qid).cloned().unwrap_or_default();
    while let Some(node) = frontier.pop() {
        if seen.contains(&node) {
            continue;
        }
        seen.insert(node.clone());
        if let Some(parents) = edges.get(&node) {
            frontier.extend(parents.iter().cloned());
        }
    }
    // Sort numerically by the integer part of the Q-ID. BTreeSet gives
    // lexicographic order; re-sort into numeric order to match the Swift port.
    let mut out: Vec<String> = seen.into_iter().collect();
    out.sort_by(|a, b| qid_int(a).cmp(&qid_int(b)).then_with(|| a.cmp(b)));
    out
}

/// The integer part of a Q-ID ("Q146" → 146). Returns 0 when the value has no
/// parseable trailing integer (defensive; not present in the artifact).
/// Mirrors the Swift `qidInt`.
fn qid_int(qid: &str) -> u64 {
    let digits: String = qid.chars().skip_while(|c| !c.is_ascii_digit()).collect();
    digits.parse::<u64>().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_qid_returns_empty() {
        assert!(ancestors("").is_empty());
    }

    #[test]
    fn unknown_qid_returns_empty() {
        // A Q-ID absent from the pinned graph has no ancestors.
        assert!(ancestors("Q999999999").is_empty());
    }

    #[test]
    fn qid_excluded_from_own_closure() {
        // The queried qid must never appear in its own ancestor closure.
        let anc = ancestors("Q146");
        assert!(!anc.contains(&"Q146".to_string()));
    }

    #[test]
    fn closure_is_numerically_sorted() {
        let anc = ancestors("Q146");
        if anc.len() < 2 {
            return; // artifact unavailable or trivial closure
        }
        for w in anc.windows(2) {
            assert!(
                qid_int(&w[0]) <= qid_int(&w[1]),
                "closure not numerically sorted: {} then {}",
                w[0],
                w[1]
            );
        }
    }

    #[test]
    fn memoized_call_is_stable() {
        // Two calls for the same qid produce identical results.
        let a = ancestors("Q5");
        let b = ancestors("Q5");
        assert_eq!(a, b);
    }

    #[test]
    fn qid_int_parses_trailing_integer() {
        assert_eq!(qid_int("Q146"), 146);
        assert_eq!(qid_int("Q1084"), 1084);
        assert_eq!(qid_int("Q5"), 5);
    }

    #[test]
    fn root_has_empty_closure() {
        // Q104709533 is present in the pinned graph with no direct parents.
        if !is_available() {
            return;
        }
        assert!(ancestors("Q104709533").is_empty());
    }

    // --- Golden cross-port pins (same artifact the Swift port bundles) ---
    //
    // These pin the EXACT representation DrawerFingerprint hashes: the
    // sorted-numeric "|"-joined closure, folded with the substrate FNV-1a
    // hash16. The Swift QIDClosureTests assert the identical 518/28752 and
    // 508/17946 values, so agreement here is a cross-port agreement on the
    // closure AND the qidClosureHash representation.

    /// FNV-1a hash16 — re-derived locally so the test does not take a
    /// substrate-types dev-dependency. Byte-identical to
    /// `substrate_types::fnv::hash16`.
    fn fnv_hash16(s: &str) -> u16 {
        let mut h: u64 = 0xCBF2_9CE4_8422_2325;
        for b in s.bytes() {
            h ^= b as u64;
            h = h.wrapping_mul(0x100_0000_01B3);
        }
        h as u16
    }

    #[test]
    fn q146_golden_pin() {
        if !is_available() {
            return;
        }
        let anc = ancestors("Q146");
        assert_eq!(anc.len(), 518);
        assert_eq!(anc.first().map(String::as_str), Some("Q336"));
        assert_eq!(fnv_hash16(&anc.join("|")), 28752);
    }

    #[test]
    fn q5_golden_pin() {
        if !is_available() {
            return;
        }
        let anc = ancestors("Q5");
        assert_eq!(anc.len(), 508);
        assert_eq!(fnv_hash16(&anc.join("|")), 17946);
    }

    #[test]
    fn distinct_closures_distinct_hashes() {
        if !is_available() {
            return;
        }
        let h146 = fnv_hash16(&ancestors("Q146").join("|"));
        let h5 = fnv_hash16(&ancestors("Q5").join("|"));
        assert_ne!(h146, h5);
    }
}
