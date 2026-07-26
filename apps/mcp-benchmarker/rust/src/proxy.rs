//! proxy.rs — the `serve` mode translation layer + ProxyRunReport.
//!
//! Ports `ProxyServer.swift`. The pure, deterministic core ported here is:
//!   - [`classify_mirror_call`] — classify a tools/call by tool name against
//!     the primary verbMap (write/query/list/fetch, or None → skip).
//!   - [`translate_mirror_call`] — rebuild a primary-side tools/call into a
//!     secondary-side tools/call: extract the variable arg under the primary's
//!     arg-role key, inject it under the secondary's, add the secondary's
//!     constantArgs, assign a fresh JSON-RPC id, and fence writes/list calls
//!     under `mirror_reads_only`.
//!   - [`ProxyRunReport`] / [`DivergingTail`] — the head-to-head artifact
//!     emitted on shutdown, with its rendered stderr block.
//!   - [`RawMcpBackend`] — the raw, verbatim, id-preserving stdio JSON-RPC
//!     forwarder (newline-delimited framing), matching Swift `RawMCPBackend`.

use crate::config::VerbMap;
use crate::json_value::JsonValue;
use std::collections::BTreeMap;

// ─────────────────────────────────────────────────────────────────────────────
// MirrorCallType
// ─────────────────────────────────────────────────────────────────────────────

/// The classified call type for a tools/call message. Mirrors Swift
/// `MirrorCallType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MirrorCallType {
    Write,
    Query,
    List,
    Fetch,
}

/// Classifies a tools/call by tool name against the primary verbMap. Returns
/// the call type, or None when the tool name matches none of the primary's
/// known verbs (unclassifiable → do not blind-forward). Mirrors Swift
/// `ProxyServer.classifyMirrorCall`.
pub fn classify_mirror_call(tool_name: &str, primary: &VerbMap) -> Option<MirrorCallType> {
    if tool_name == primary.write {
        return Some(MirrorCallType::Write);
    }
    if tool_name == primary.query {
        return Some(MirrorCallType::Query);
    }
    if let Some(list) = &primary.list {
        if tool_name == list {
            return Some(MirrorCallType::List);
        }
    }
    if let Some(fetch) = &primary.fetch {
        if tool_name == fetch {
            return Some(MirrorCallType::Fetch);
        }
    }
    None
}

/// Translates a primary-side tools/call into a secondary-side tools/call.
/// Mirrors Swift `ProxyServer.translateMirrorCall`.
///
/// Returns None when the call should be skipped:
///   - `mirror_reads_only` is true and `call_type` is `Write` or `List`;
///   - the client line cannot be decoded as a valid JSON-RPC message.
///
/// The returned bytes are a complete newline-free JSON-RPC tools/call. The
/// `fresh_id` becomes the JSON-RPC id — never the client's original id.
pub fn translate_mirror_call(
    client_line: &[u8],
    call_type: MirrorCallType,
    primary: &VerbMap,
    secondary: &VerbMap,
    mirror_reads_only: bool,
    fresh_id: i64,
) -> Option<Vec<u8>> {
    // Read-only mirror fence: skip writes and list calls (mutation paths).
    if mirror_reads_only
        && (call_type == MirrorCallType::Write || call_type == MirrorCallType::List)
    {
        return None;
    }

    // Decode the client line and pull out params.arguments as an object.
    let parsed = JsonValue::from_slice(client_line).ok()?;
    let client_args = match parsed.get("params").and_then(|p| p.get("arguments")) {
        Some(JsonValue::Object(map)) => map.clone(),
        // An absent / non-object arguments value is treated as empty, matching
        // the Swift `?? .object([:])` fallback (which still produces a call).
        None => BTreeMap::new(),
        Some(_) => return None,
    };

    // Build the secondary's argument dict: start with the secondary's
    // constantArgs, then map the variable arg(s).
    let mut secondary_args: BTreeMap<String, JsonValue> = secondary
        .constant_args
        .iter()
        .map(|(k, v)| (k.clone(), JsonValue::String(v.clone())))
        .collect();

    let mut carry = |from_key: &str, to_key: &str| {
        if let Some(value) = client_args.get(from_key) {
            secondary_args.insert(to_key.to_string(), value.clone());
        }
    };

    match call_type {
        MirrorCallType::Write => carry(&primary.content_arg, &secondary.content_arg),
        MirrorCallType::Query => carry(&primary.query_arg, &secondary.query_arg),
        MirrorCallType::List => {
            carry(&primary.list_limit_arg, &secondary.list_limit_arg);
            carry(&primary.list_offset_arg, &secondary.list_offset_arg);
        }
        MirrorCallType::Fetch => carry(&primary.fetch_id_arg, &secondary.fetch_id_arg),
    }

    // Determine the secondary tool name for this call type.
    let secondary_tool = match call_type {
        MirrorCallType::Write => secondary.write.clone(),
        MirrorCallType::Query => secondary.query.clone(),
        MirrorCallType::List => secondary.list.clone().unwrap_or_else(|| secondary.query.clone()),
        MirrorCallType::Fetch => secondary.fetch.clone().unwrap_or_else(|| secondary.query.clone()),
    };

    // Assemble the translated JSON-RPC envelope with the fresh id.
    let envelope = JsonValue::object([
        ("jsonrpc".to_string(), JsonValue::String("2.0".to_string())),
        ("id".to_string(), JsonValue::Number(fresh_id as f64)),
        ("method".to_string(), JsonValue::String("tools/call".to_string())),
        (
            "params".to_string(),
            JsonValue::object([
                ("name".to_string(), JsonValue::String(secondary_tool)),
                ("arguments".to_string(), JsonValue::Object(secondary_args)),
            ]),
        ),
    ]);
    envelope.to_vec().ok()
}

// ─────────────────────────────────────────────────────────────────────────────
// ProxyRunReport (SPEC §4.5)
// ─────────────────────────────────────────────────────────────────────────────

/// A single worst-diverging recall comparison — the sample with the highest
/// Jaccard divergence, with both full rankings retained. Mirrors Swift
/// `ProxyRunReport.DivergingTail`.
#[derive(Debug, Clone, PartialEq)]
pub struct DivergingTail {
    pub jaccard_divergence: f64,
    pub primary_ranking: Vec<String>,
    pub secondary_ranking: Vec<String>,
}

/// The consolidated head-to-head report emitted when `serve` shuts down.
/// Mirrors Swift `ProxyRunReport`.
#[derive(Debug, Clone, PartialEq)]
pub struct ProxyRunReport {
    pub primary_latency_series: Vec<f64>,
    pub secondary_latency_series: Vec<f64>,
    pub jaccard_mean: f64,
    pub kendall_rank_mean: f64,
    pub divergence_sample_count: usize,
    pub secondary_failure_count: usize,
    pub worst_diverging_tail: Option<DivergingTail>,
}

impl ProxyRunReport {
    /// Mean latency (seconds) over the primary samples, or 0.
    pub fn primary_mean_latency(&self) -> f64 {
        if self.primary_latency_series.is_empty() {
            0.0
        } else {
            self.primary_latency_series.iter().sum::<f64>()
                / self.primary_latency_series.len() as f64
        }
    }

    /// Mean latency (seconds) over the secondary samples, or 0.
    pub fn secondary_mean_latency(&self) -> f64 {
        if self.secondary_latency_series.is_empty() {
            0.0
        } else {
            self.secondary_latency_series.iter().sum::<f64>()
                / self.secondary_latency_series.len() as f64
        }
    }

    /// Renders the report as a human-readable block for stderr. Mirrors Swift
    /// `ProxyRunReport.rendered(primaryName:secondaryName:)`.
    pub fn rendered(&self, primary_name: &str, secondary_name: &str) -> String {
        let mut out = String::from("[serve] live head-to-head run report\n");
        out.push_str(&format!(
            "  primary   ({}): n={}  mean {:.2} ms\n",
            primary_name,
            self.primary_latency_series.len(),
            self.primary_mean_latency() * 1000.0
        ));
        out.push_str(&format!(
            "  secondary ({}): n={}  mean {:.2} ms\n",
            secondary_name,
            self.secondary_latency_series.len(),
            self.secondary_mean_latency() * 1000.0
        ));
        if self.secondary_failure_count > 0 {
            out.push_str(&format!(
                "  secondary failures (non-fatal): {}\n",
                self.secondary_failure_count
            ));
        }
        if self.divergence_sample_count > 0 {
            out.push_str(&format!(
                "  divergence (n={}):  jaccard set {:.4}   kendall rank {:.4}\n",
                self.divergence_sample_count, self.jaccard_mean, self.kendall_rank_mean
            ));
        }
        if let Some(tail) = &self.worst_diverging_tail {
            out.push_str(&format!(
                "  worst-diverging tail (jaccard {:.4}):\n",
                tail.jaccard_divergence
            ));
            out.push_str(&format!(
                "    primary:   {}\n",
                tail.primary_ranking.iter().take(5).cloned().collect::<Vec<_>>().join(", ")
            ));
            out.push_str(&format!(
                "    secondary: {}\n",
                tail.secondary_ranking.iter().take(5).cloned().collect::<Vec<_>>().join(", ")
            ));
        }
        out
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ProxyReportAccumulator (per-session run-report state)
// ─────────────────────────────────────────────────────────────────────────────

/// Accumulates the state needed to assemble a `ProxyRunReport` at session end.
/// Mirrors Swift `ProxyReportAccumulator`. Single-threaded here (the Rust serve
/// loop is sequential request/response), so no actor isolation is required —
/// the field set and the `build_report` math match the Swift actor exactly.
#[derive(Debug, Default)]
pub struct ProxyReportAccumulator {
    primary_samples: Vec<f64>,
    secondary_samples: Vec<f64>,
    jaccard_sum: f64,
    kendall_sum: f64,
    divergence_count: usize,
    failure_count: usize,
    worst_jaccard: f64,
    worst_tail_primary: Vec<String>,
    worst_tail_secondary: Vec<String>,
}

impl ProxyReportAccumulator {
    pub fn new() -> ProxyReportAccumulator {
        ProxyReportAccumulator {
            worst_jaccard: -1.0,
            ..Default::default()
        }
    }

    pub fn record_primary(&mut self, seconds: f64) {
        self.primary_samples.push(seconds);
    }

    pub fn record_secondary(&mut self, seconds: f64) {
        self.secondary_samples.push(seconds);
    }

    pub fn record_failure(&mut self) {
        self.failure_count += 1;
    }

    pub fn record_divergence(
        &mut self,
        jaccard: f64,
        kendall: f64,
        primary_ranking: Vec<String>,
        secondary_ranking: Vec<String>,
    ) {
        self.jaccard_sum += jaccard;
        self.kendall_sum += kendall;
        self.divergence_count += 1;
        if jaccard > self.worst_jaccard {
            self.worst_jaccard = jaccard;
            self.worst_tail_primary = primary_ranking;
            self.worst_tail_secondary = secondary_ranking;
        }
    }

    /// Assembles the immutable `ProxyRunReport` from accumulated state.
    /// Mirrors Swift `ProxyReportAccumulator.buildReport`.
    pub fn build_report(&self) -> ProxyRunReport {
        let n = self.divergence_count.max(1) as f64;
        let tail = if self.divergence_count > 0 {
            Some(DivergingTail {
                jaccard_divergence: self.worst_jaccard,
                primary_ranking: self.worst_tail_primary.clone(),
                secondary_ranking: self.worst_tail_secondary.clone(),
            })
        } else {
            None
        };
        ProxyRunReport {
            primary_latency_series: self.primary_samples.clone(),
            secondary_latency_series: self.secondary_samples.clone(),
            jaccard_mean: if self.divergence_count == 0 { 0.0 } else { self.jaccard_sum / n },
            kendall_rank_mean: if self.divergence_count == 0 { 0.0 } else { self.kendall_sum / n },
            divergence_sample_count: self.divergence_count,
            secondary_failure_count: self.failure_count,
            worst_diverging_tail: tail,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn verb_map(
        write: &str,
        query: &str,
        list: Option<&str>,
        content_arg: &str,
        query_arg: &str,
        constant_args: &[(&str, &str)],
    ) -> VerbMap {
        let constants: BTreeMap<String, String> = constant_args
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        VerbMap::new(
            write,
            query,
            list.map(str::to_string),
            None,
            Some(content_arg.to_string()),
            Some(query_arg.to_string()),
            Some(constants),
            None,
        )
    }

    fn client_call(id: i64, tool_name: &str, arguments: &[(&str, &str)]) -> Vec<u8> {
        let args: BTreeMap<String, JsonValue> = arguments
            .iter()
            .map(|(k, v)| (k.to_string(), JsonValue::String(v.to_string())))
            .collect();
        let msg = JsonValue::object([
            ("jsonrpc".to_string(), JsonValue::String("2.0".to_string())),
            ("id".to_string(), JsonValue::Number(id as f64)),
            ("method".to_string(), JsonValue::String("tools/call".to_string())),
            (
                "params".to_string(),
                JsonValue::object([
                    ("name".to_string(), JsonValue::String(tool_name.to_string())),
                    ("arguments".to_string(), JsonValue::Object(args)),
                ]),
            ),
        ]);
        msg.to_vec().unwrap()
    }

    // ── classifyMirrorCall ───────────────────────────────────────────────────

    #[test]
    fn classifies_write() {
        let p = verb_map("moot_file_memory", "moot_memory_search", None, "content", "query", &[]);
        assert_eq!(
            classify_mirror_call("moot_file_memory", &p),
            Some(MirrorCallType::Write)
        );
    }

    #[test]
    fn classifies_query() {
        let p = verb_map("moot_file_memory", "moot_memory_search", None, "content", "query", &[]);
        assert_eq!(
            classify_mirror_call("moot_memory_search", &p),
            Some(MirrorCallType::Query)
        );
    }

    #[test]
    fn classifies_unknown_as_none() {
        let p = verb_map("moot_file_memory", "moot_memory_search", None, "content", "query", &[]);
        assert_eq!(classify_mirror_call("some_other_tool", &p), None);
    }

    #[test]
    fn classifies_list() {
        let p = verb_map(
            "moot_file_memory",
            "moot_memory_search",
            Some("moot_list_memories"),
            "content",
            "query",
            &[],
        );
        assert_eq!(
            classify_mirror_call("moot_list_memories", &p),
            Some(MirrorCallType::List)
        );
    }

    // ── translateMirrorCall: write ───────────────────────────────────────────

    #[test]
    fn translates_write_to_secondary_verb() {
        let primary = verb_map(
            "moot_file_memory",
            "moot_memory_search",
            None,
            "content",
            "query",
            &[("location", "import/mempalace")],
        );
        let secondary = verb_map(
            "mempalace_add_drawer",
            "mempalace_search",
            None,
            "content",
            "query",
            &[("wing", "general"), ("room", "notes")],
        );
        let client_bytes = client_call(
            99,
            "moot_file_memory",
            &[("content", "hello world"), ("location", "my/location")],
        );
        let translated = translate_mirror_call(
            &client_bytes,
            MirrorCallType::Write,
            &primary,
            &secondary,
            false,
            1001,
        )
        .unwrap();
        let json = JsonValue::from_slice(&translated).unwrap();
        assert_eq!(json.get("method").and_then(JsonValue::string_value), Some("tools/call"));
        assert_eq!(
            json.get("params").and_then(|p| p.get("name")).and_then(JsonValue::string_value),
            Some("mempalace_add_drawer")
        );
        let args = json.get("params").and_then(|p| p.get("arguments")).unwrap();
        assert_eq!(args.get("content").and_then(JsonValue::string_value), Some("hello world"));
        assert_eq!(args.get("wing").and_then(JsonValue::string_value), Some("general"));
        assert_eq!(args.get("room").and_then(JsonValue::string_value), Some("notes"));
        // The primary's own constant arg (location) must NOT appear.
        assert!(args.get("location").is_none());
    }

    #[test]
    fn write_translation_uses_fresh_id() {
        let primary = verb_map("moot_file_memory", "moot_memory_search", None, "content", "query", &[]);
        let secondary = verb_map("mempalace_add_drawer", "mempalace_search", None, "content", "query", &[]);
        let client_bytes = client_call(42, "moot_file_memory", &[("content", "text")]);
        let translated = translate_mirror_call(
            &client_bytes,
            MirrorCallType::Write,
            &primary,
            &secondary,
            false,
            5555,
        )
        .unwrap();
        let json = JsonValue::from_slice(&translated).unwrap();
        match json.get("id") {
            Some(JsonValue::Number(n)) => assert_eq!(*n, 5555.0),
            other => panic!("expected numeric id, got {other:?}"),
        }
    }

    // ── translateMirrorCall: query ───────────────────────────────────────────

    #[test]
    fn translates_query_to_secondary_verb() {
        let primary = verb_map("moot_file_memory", "moot_memory_search", None, "content", "query", &[]);
        let secondary = verb_map("mempalace_add_drawer", "mempalace_search", None, "content", "query", &[]);
        let client_bytes = client_call(7, "moot_memory_search", &[("query", "what did I decide about auth")]);
        let translated = translate_mirror_call(
            &client_bytes,
            MirrorCallType::Query,
            &primary,
            &secondary,
            false,
            2001,
        )
        .unwrap();
        let json = JsonValue::from_slice(&translated).unwrap();
        assert_eq!(
            json.get("params").and_then(|p| p.get("name")).and_then(JsonValue::string_value),
            Some("mempalace_search")
        );
        assert_eq!(
            json.get("params")
                .and_then(|p| p.get("arguments"))
                .and_then(|a| a.get("query"))
                .and_then(JsonValue::string_value),
            Some("what did I decide about auth")
        );
    }

    #[test]
    fn translates_query_with_differing_arg_keys() {
        let primary = verb_map("w1", "q1", None, "content", "query", &[]);
        let secondary = verb_map("w2", "q2", None, "content", "search_text", &[]);
        let client_bytes = client_call(3, "q1", &[("query", "project planning notes")]);
        let translated = translate_mirror_call(
            &client_bytes,
            MirrorCallType::Query,
            &primary,
            &secondary,
            false,
            3001,
        )
        .unwrap();
        let json = JsonValue::from_slice(&translated).unwrap();
        assert_eq!(
            json.get("params").and_then(|p| p.get("name")).and_then(JsonValue::string_value),
            Some("q2")
        );
        let args = json.get("params").and_then(|p| p.get("arguments")).unwrap();
        assert_eq!(args.get("search_text").and_then(JsonValue::string_value), Some("project planning notes"));
        assert!(args.get("query").is_none());
    }

    // ── mirror-reads-only fence ──────────────────────────────────────────────

    #[test]
    fn mirror_reads_only_skips_write() {
        let primary = verb_map("moot_file_memory", "moot_memory_search", None, "content", "query", &[]);
        let secondary = verb_map("mempalace_add_drawer", "mempalace_search", None, "content", "query", &[]);
        let client_bytes = client_call(1, "moot_file_memory", &[("content", "data")]);
        let result = translate_mirror_call(
            &client_bytes,
            MirrorCallType::Write,
            &primary,
            &secondary,
            true,
            9999,
        );
        assert!(result.is_none());
    }

    #[test]
    fn mirror_reads_only_allows_query() {
        let primary = verb_map("moot_file_memory", "moot_memory_search", None, "content", "query", &[]);
        let secondary = verb_map("mempalace_add_drawer", "mempalace_search", None, "content", "query", &[]);
        let client_bytes = client_call(5, "moot_memory_search", &[("query", "test query")]);
        let translated = translate_mirror_call(
            &client_bytes,
            MirrorCallType::Query,
            &primary,
            &secondary,
            true,
            8888,
        )
        .unwrap();
        let json = JsonValue::from_slice(&translated).unwrap();
        assert_eq!(
            json.get("params").and_then(|p| p.get("name")).and_then(JsonValue::string_value),
            Some("mempalace_search")
        );
    }

    #[test]
    fn secondary_constant_args_injected_when_primary_has_none() {
        let primary = verb_map("w1", "q1", None, "content", "query", &[]);
        let secondary = verb_map(
            "mempalace_add_drawer",
            "mempalace_search",
            None,
            "content",
            "query",
            &[("wing", "main"), ("room", "inbox")],
        );
        let client_bytes = client_call(1, "w1", &[("content", "some memory")]);
        let translated = translate_mirror_call(
            &client_bytes,
            MirrorCallType::Write,
            &primary,
            &secondary,
            false,
            100,
        )
        .unwrap();
        let json = JsonValue::from_slice(&translated).unwrap();
        let args = json.get("params").and_then(|p| p.get("arguments")).unwrap();
        assert_eq!(args.get("content").and_then(JsonValue::string_value), Some("some memory"));
        assert_eq!(args.get("wing").and_then(JsonValue::string_value), Some("main"));
        assert_eq!(args.get("room").and_then(JsonValue::string_value), Some("inbox"));
    }

    // ── ProxyRunReport ───────────────────────────────────────────────────────

    #[test]
    fn fresh_report_is_zero() {
        let report = ProxyReportAccumulator::new().build_report();
        assert_eq!(report.secondary_failure_count, 0);
        assert_eq!(report.divergence_sample_count, 0);
        assert!(report.worst_diverging_tail.is_none());
    }

    #[test]
    fn report_carries_secondary_failure_count() {
        let mut acc = ProxyReportAccumulator::new();
        acc.record_primary(0.010);
        acc.record_primary(0.015);
        acc.record_primary(0.012);
        acc.record_secondary(0.020);
        acc.record_secondary(0.025);
        acc.record_failure();
        acc.record_failure();
        acc.record_failure();
        acc.record_divergence(0.1, 0.05, vec!["a".into()], vec!["b".into()]);
        acc.record_divergence(0.1, 0.05, vec!["a".into()], vec!["b".into()]);
        let report = acc.build_report();
        assert_eq!(report.secondary_failure_count, 3);
        assert_eq!(report.divergence_sample_count, 2);
    }

    #[test]
    fn worst_tail_holds_both_rankings() {
        let mut acc = ProxyReportAccumulator::new();
        acc.record_divergence(
            0.25,
            0.1,
            vec!["x".into()],
            vec!["y".into()],
        );
        acc.record_divergence(
            0.75,
            0.5,
            vec!["alpha".into(), "beta".into(), "gamma".into()],
            vec!["delta".into(), "epsilon".into(), "alpha".into()],
        );
        let report = acc.build_report();
        let tail = report.worst_diverging_tail.unwrap();
        assert_eq!(tail.primary_ranking, vec!["alpha", "beta", "gamma"]);
        assert_eq!(tail.secondary_ranking, vec!["delta", "epsilon", "alpha"]);
        assert!((tail.jaccard_divergence - 0.75).abs() < 1e-12);
    }

    #[test]
    fn report_renders_to_non_empty_string() {
        let mut acc = ProxyReportAccumulator::new();
        acc.record_primary(0.010);
        acc.record_primary(0.020);
        acc.record_secondary(0.030);
        acc.record_secondary(0.040);
        acc.record_failure();
        acc.record_divergence(0.5, 0.10, vec!["a".into(), "b".into()], vec!["c".into(), "d".into()]);
        acc.record_divergence(0.0, 0.10, vec!["a".into()], vec!["a".into()]);
        let report = acc.build_report();
        let text = report.rendered("mootx01", "mempalace");
        assert!(!text.is_empty());
        assert!(text.contains('1'));
    }
}
