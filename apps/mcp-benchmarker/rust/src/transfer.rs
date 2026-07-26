//! transfer.rs — moves a corpus from source to target, recording a manifest
//! and timing each capture, then verifying every entry round-trips.
//!
//! Ports `TransferEngine.swift`. The flow matches the Swift leg exactly:
//!   1. PAGINATE the source `list` verb (limit + offset) to exhaustion (or the
//!      `max_entries` cap, reported, never a silent truncation).
//!   2. For each listed item, FETCH its full content by id via the source
//!      `fetch` verb when one is configured (the list preview is truncated).
//!   3. WRITE to the target via the target `write` verb, timing each capture; a
//!      transient failure is retried, a permanent one recorded as `Failed`.
//!   4. VERIFY the round-trip: query the target for the written content and
//!      confirm the assigned id comes back.
//!
//! The engine is generic over [`ToolCaller`] so the deterministic flow is
//! exercised without a live MCP process — the same purity discipline the Swift
//! tests follow. `now` is injected (a `Fn() -> String` producing the ISO8601
//! timestamp) so timestamps are not read from a hidden global, matching the
//! MOOTx01 "pass now as a parameter" rule.

use crate::config::{ResultFormat, VerbMap};
use crate::json_value::JsonValue;
use crate::transfer_manifest::{Manifest, ManifestEntry, TransferOutcome};
use crate::mcp_client::{MCPError, ToolCaller};
use crate::mcp_result::MCPResultItem;
use std::collections::BTreeMap;
use std::time::Instant;

/// One entry that failed its post-write round-trip check. Mirrors Swift
/// `RoundTripFailure`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoundTripFailure {
    pub id: String,
    pub reason: RoundTripReason,
}

/// Why a transferred entry failed verification. Mirrors Swift
/// `RoundTripFailure.Reason`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoundTripReason {
    /// It was never written.
    WriteFailed,
    /// It was written but did not come back when the target was queried.
    NotRecalled,
}

impl RoundTripReason {
    /// The raw-value string for this reason. Mirrors the Swift enum raw values.
    pub fn as_str(&self) -> &'static str {
        match self {
            RoundTripReason::WriteFailed => "writeFailed",
            RoundTripReason::NotRecalled => "notRecalled",
        }
    }
}

/// The outcome of a transfer run. Mirrors Swift `TransferResult`.
#[derive(Debug, Clone, PartialEq)]
pub struct TransferResult {
    pub manifest: Manifest,
    /// Per-write capture latencies (seconds), in transfer order.
    pub capture_latencies: Vec<f64>,
    pub round_trip_failures: Vec<RoundTripFailure>,
    /// Number of items the source enumerated (before the cap / empty skips).
    pub source_enumerated: usize,
    /// True when the run stopped at the `max_entries` cap rather than corpus end.
    pub capped_by_sample: bool,
}

/// Drives a source → target transfer and produces the ground-truth manifest.
/// Mirrors Swift `TransferEngine`.
pub struct TransferEngine<'a, S: ToolCaller, T: ToolCaller> {
    pub source: &'a mut S,
    pub target: &'a mut T,
    pub source_verbs: VerbMap,
    pub target_verbs: VerbMap,
    /// Retries per entry on a transient write failure before it is recorded as
    /// permanently failed.
    pub max_retries: u32,
    /// Cap on entries to transfer. None = whole corpus.
    pub max_entries: Option<usize>,
    /// When true, query the target after each write to confirm round-trip.
    pub verify_round_trip: bool,
    /// Clock injected at the CLI boundary so timestamps are deterministic in
    /// tests. Produces the ISO8601 TEXT timestamp recorded on each entry.
    pub now_iso8601: Box<dyn Fn() -> String + 'a>,
}

impl<'a, S: ToolCaller, T: ToolCaller> TransferEngine<'a, S, T> {
    /// Runs the transfer. Paginates + full-content-fetches the source, writes to
    /// the target, and (when enabled) verifies each entry round-trips. Mirrors
    /// Swift `TransferEngine.run`.
    pub fn run(&mut self) -> Result<TransferResult, MCPError> {
        let list_verb = self
            .source_verbs
            .list
            .clone()
            .ok_or_else(|| MCPError { description: "source verbMap has no `list` verb; cannot enumerate corpus".to_string() })?;

        let mut manifest = Manifest::new();
        let mut capture_latencies: Vec<f64> = Vec::new();
        let mut round_trip_failures: Vec<RoundTripFailure> = Vec::new();

        // 1. Enumerate the source by paginating list(limit, offset).
        let (items, capped) = self.enumerate_source(&list_verb)?;
        let source_enumerated = items.len();

        for (index, item) in items.iter().enumerate() {
            // 1-based positional id fallback, matching the Swift `positional`
            // counter (incremented before use, so the first item is 1).
            let positional = index + 1;
            // 2. Fetch full content by id when a fetch verb is configured.
            let content = self.full_content(item)?;
            let content = match content {
                Some(c) if !c.is_empty() => c,
                _ => continue,
            };
            let source_id = item.id.clone().unwrap_or_else(|| format!("source-{positional}"));

            // 3. Write to the target, capturing the assigned id + latency.
            let (outcome, assigned_id, elapsed) = self.write_with_retry(&content);
            capture_latencies.push(elapsed);
            manifest.record_capture_latency(elapsed);
            let manifest_id = assigned_id.clone().unwrap_or(source_id);
            manifest.record(ManifestEntry {
                id: manifest_id.clone(),
                content: content.clone(),
                transferred_at: (self.now_iso8601)(),
                outcome,
            });

            // 4. Round-trip verify.
            if outcome == TransferOutcome::Failed {
                round_trip_failures.push(RoundTripFailure {
                    id: manifest_id,
                    reason: RoundTripReason::WriteFailed,
                });
            } else if self.verify_round_trip {
                let recalled = self.round_trips(&content, &manifest_id);
                if !recalled {
                    round_trip_failures.push(RoundTripFailure {
                        id: manifest_id,
                        reason: RoundTripReason::NotRecalled,
                    });
                }
            }
        }

        Ok(TransferResult {
            manifest,
            capture_latencies,
            round_trip_failures,
            source_enumerated,
            capped_by_sample: capped,
        })
    }

    /// Paginates the source `list` verb to exhaustion (or the cap). A page
    /// shorter than the page size (or empty) marks corpus end. Mirrors Swift
    /// `enumerateSource`.
    fn enumerate_source(&mut self, list_verb: &str) -> Result<(Vec<MCPResultItem>, bool), MCPError> {
        let page_size = self.source_verbs.list_page_size.max(1) as usize;
        let mut offset: i64 = 0;
        let mut collected: Vec<MCPResultItem> = Vec::new();
        loop {
            let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
            args.insert(self.source_verbs.list_limit_arg.clone(), JsonValue::Number(page_size as f64));
            args.insert(self.source_verbs.list_offset_arg.clone(), JsonValue::Number(offset as f64));
            let page = self.source.call_tool(list_verb, args, &self.source_verbs.result_format)?;
            if page.items.is_empty() {
                break;
            }
            let page_len = page.items.len();
            collected.extend(page.items);

            if let Some(cap) = self.max_entries {
                if collected.len() >= cap {
                    collected.truncate(cap);
                    return Ok((collected, true));
                }
            }
            // A short page means we reached the end of the corpus.
            if page_len < page_size {
                break;
            }
            offset += page_size as i64;
        }
        Ok((collected, false))
    }

    /// Returns the full content for an item: when the source has a `fetch` verb
    /// and the item has an id, fetch the full record by id. Otherwise use the
    /// content the list returned. Mirrors Swift `fullContent`.
    fn full_content(&mut self, item: &MCPResultItem) -> Result<Option<String>, MCPError> {
        let fetch_verb = match (&self.source_verbs.fetch, &item.id) {
            (Some(f), Some(_)) => f.clone(),
            _ => return Ok(item.content.clone()),
        };
        let id = item.id.clone().unwrap();
        // The fetch result is a single full record whose content lives under a
        // DIFFERENT key than the list preview. Parse it with a format keyed on
        // the full content key; the list's id key still applies.
        let fetch_format = match &self.source_verbs.result_format {
            ResultFormat::JsonObjects { id_key, .. } => ResultFormat::JsonObjects {
                id_key: id_key.clone(),
                content_key: self.source_verbs.fetch_content_key.clone(),
            },
            // A mootText server exposes no separate fetch; keep the format.
            ResultFormat::MootText => ResultFormat::MootText,
        };
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert(self.source_verbs.fetch_id_arg.clone(), JsonValue::String(id));
        let result = self.source.call_tool(&fetch_verb, args, &fetch_format)?;
        // Take the single record's content; fall back to the list preview.
        Ok(result
            .items
            .first()
            .and_then(|i| i.content.clone())
            .or_else(|| item.content.clone()))
    }

    /// Queries the target for the just-written content and confirms the
    /// expected id appears in the results. Mirrors Swift `roundTrips`.
    fn round_trips(&mut self, content: &str, expected_id: &str) -> bool {
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert(self.target_verbs.query_arg.clone(), JsonValue::String(content.to_string()));
        match self
            .target
            .call_tool(&self.target_verbs.query.clone(), args, &self.target_verbs.result_format.clone())
        {
            Ok(result) => result.ordered_ids.iter().any(|id| id == expected_id),
            Err(_) => false,
        }
    }

    /// Writes one entry to the target, retrying transient failures up to
    /// `max_retries` times. Returns the final outcome, the target-assigned id
    /// (when the target mints one), and the total elapsed seconds. Mirrors Swift
    /// `writeWithRetry` (without the inter-attempt sleep, which only affects
    /// wall-clock latency, never the recorded outcome).
    fn write_with_retry(&mut self, content: &str) -> (TransferOutcome, Option<String>, f64) {
        let start = Instant::now();
        let mut attempt: u32 = 0;
        loop {
            // Build write arguments from the TARGET verbMap: content under the
            // target's content key, plus any required constant args. The
            // caller's id is never sent.
            let mut arguments: BTreeMap<String, JsonValue> = BTreeMap::new();
            arguments.insert(self.target_verbs.content_arg.clone(), JsonValue::String(content.to_string()));
            for (key, value) in &self.target_verbs.constant_args {
                arguments.insert(key.clone(), JsonValue::String(value.clone()));
            }
            let result = self.target.call_tool(
                &self.target_verbs.write.clone(),
                arguments,
                &self.target_verbs.result_format.clone(),
            );
            match result {
                Ok(r) => return (TransferOutcome::Transferred, r.write_assigned_id, start.elapsed().as_secs_f64()),
                Err(_) => {
                    attempt += 1;
                    if attempt > self.max_retries {
                        // Permanent failure: no id was assigned (nothing landed).
                        return (TransferOutcome::Failed, None, start.elapsed().as_secs_f64());
                    }
                    // Loop and retry — a transient write error.
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp_client::MCPError;
    use crate::mcp_result::MCPToolResult;

    /// A scripted ToolCaller: returns canned results per tool name, in queue
    /// order, so the deterministic transfer flow is exercised without a live
    /// MCP process.
    struct ScriptedCaller {
        /// tool name → queue of results (each call pops the front).
        scripts: BTreeMap<String, Vec<Result<MCPToolResult, MCPError>>>,
        /// Recorded (tool, arguments) calls, in order, for assertions.
        calls: Vec<(String, BTreeMap<String, JsonValue>)>,
    }

    impl ScriptedCaller {
        fn new() -> Self {
            ScriptedCaller { scripts: BTreeMap::new(), calls: Vec::new() }
        }
        fn script(&mut self, tool: &str, results: Vec<Result<MCPToolResult, MCPError>>) {
            self.scripts.insert(tool.to_string(), results);
        }
    }

    impl ToolCaller for ScriptedCaller {
        fn call_tool(
            &mut self,
            name: &str,
            arguments: BTreeMap<String, JsonValue>,
            _format: &ResultFormat,
        ) -> Result<MCPToolResult, MCPError> {
            self.calls.push((name.to_string(), arguments));
            let queue = self.scripts.get_mut(name).expect("no script for tool");
            if queue.len() == 1 {
                queue[0].clone()
            } else {
                queue.remove(0)
            }
        }
    }

    fn item(id: Option<&str>, content: Option<&str>) -> MCPResultItem {
        MCPResultItem {
            id: id.map(str::to_string),
            content: content.map(str::to_string),
        }
    }

    fn list_result(items: Vec<MCPResultItem>) -> MCPToolResult {
        let ordered_ids = items.iter().filter_map(|i| i.id.clone()).collect();
        MCPToolResult { ordered_ids, items, write_assigned_id: None, text_blocks: vec![] }
    }

    fn write_result(assigned: &str) -> MCPToolResult {
        MCPToolResult {
            ordered_ids: vec![],
            items: vec![],
            write_assigned_id: Some(assigned.to_string()),
            text_blocks: vec![],
        }
    }

    fn source_verbs() -> VerbMap {
        // MemPalace-style: list paginates, fetch full content, jsonObjects.
        let mut vm = VerbMap::new(
            "mempalace_add_drawer",
            "mempalace_search",
            Some("mempalace_list_drawers".to_string()),
            Some("mempalace_get_drawer".to_string()),
            None,
            None,
            Some(BTreeMap::new()),
            Some(ResultFormat::JsonObjects {
                id_key: Some("drawer_id".to_string()),
                content_key: "content_preview".to_string(),
            }),
        );
        vm.list_page_size = 2; // small page to exercise pagination
        vm
    }

    fn target_verbs() -> VerbMap {
        VerbMap::new(
            "moot_file_memory",
            "moot_memory_search",
            None,
            None,
            None,
            None,
            Some({
                let mut m = BTreeMap::new();
                m.insert("location".to_string(), "import/test".to_string());
                m
            }),
            Some(ResultFormat::MootText),
        )
    }

    #[test]
    fn paginates_fetches_writes_and_verifies() {
        let mut source = ScriptedCaller::new();
        // Page 1 (full, 2 items), page 2 (short, 1 item) → corpus end.
        source.script(
            "mempalace_list_drawers",
            vec![
                Ok(list_result(vec![
                    item(Some("d1"), Some("preview-1")),
                    item(Some("d2"), Some("preview-2")),
                ])),
                Ok(list_result(vec![item(Some("d3"), Some("preview-3"))])),
            ],
        );
        // Fetch full content per id.
        source.script("mempalace_get_drawer", vec![
            Ok(list_result(vec![item(Some("d1"), Some("full content 1"))])),
            Ok(list_result(vec![item(Some("d2"), Some("full content 2"))])),
            Ok(list_result(vec![item(Some("d3"), Some("full content 3"))])),
        ]);

        let mut target = ScriptedCaller::new();
        target.script("moot_file_memory", vec![
            Ok(write_result("UUID-1")),
            Ok(write_result("UUID-2")),
            Ok(write_result("UUID-3")),
        ]);
        // Round-trip query: each returns the assigned id at rank 1.
        target.script("moot_memory_search", vec![
            Ok(MCPToolResult { ordered_ids: vec!["UUID-1".into()], items: vec![], write_assigned_id: None, text_blocks: vec![] }),
            Ok(MCPToolResult { ordered_ids: vec!["UUID-2".into()], items: vec![], write_assigned_id: None, text_blocks: vec![] }),
            Ok(MCPToolResult { ordered_ids: vec!["UUID-3".into()], items: vec![], write_assigned_id: None, text_blocks: vec![] }),
        ]);

        let sv = source_verbs();
        let tv = target_verbs();
        let mut engine = TransferEngine {
            source: &mut source,
            target: &mut target,
            source_verbs: sv,
            target_verbs: tv,
            max_retries: 2,
            max_entries: None,
            verify_round_trip: true,
            now_iso8601: Box::new(|| "2026-06-10T00:00:00Z".to_string()),
        };
        let result = engine.run().unwrap();

        assert_eq!(result.source_enumerated, 3);
        assert!(!result.capped_by_sample);
        assert_eq!(result.manifest.entries().len(), 3);
        // Manifest records the TARGET-assigned ids, and the FULL content.
        assert_eq!(result.manifest.entries()[0].id, "UUID-1");
        assert_eq!(result.manifest.entries()[0].content, "full content 1");
        assert_eq!(result.manifest.entries()[0].outcome, TransferOutcome::Transferred);
        assert!(result.round_trip_failures.is_empty());
        assert_eq!(result.capture_latencies.len(), 3);
    }

    #[test]
    fn write_failure_recorded_and_capped_sample() {
        let mut source = ScriptedCaller::new();
        source.script("mempalace_list_drawers", vec![Ok(list_result(vec![
            item(Some("d1"), Some("full-1")),
            item(Some("d2"), Some("full-2")),
        ]))]);
        // No fetch verb in this config → list content is used directly.

        let mut target = ScriptedCaller::new();
        // Every write fails → permanent failure after retries.
        target.script(
            "moot_file_memory",
            vec![Err(MCPError { description: "boom".into() })],
        );

        // Source has no fetch verb: rebuild source verbs without fetch.
        let mut sv = source_verbs();
        sv.fetch = None;
        sv.list_page_size = 100;
        let tv = target_verbs();

        let mut engine = TransferEngine {
            source: &mut source,
            target: &mut target,
            source_verbs: sv,
            target_verbs: tv,
            max_retries: 1,
            max_entries: Some(1), // cap to one entry
            verify_round_trip: true,
            now_iso8601: Box::new(|| "2026-06-10T00:00:00Z".to_string()),
        };
        let result = engine.run().unwrap();

        assert!(result.capped_by_sample);
        assert_eq!(result.source_enumerated, 1);
        assert_eq!(result.manifest.entries().len(), 1);
        assert_eq!(result.manifest.entries()[0].outcome, TransferOutcome::Failed);
        // The failed entry falls back to the source id (no assigned id minted).
        assert_eq!(result.manifest.entries()[0].id, "d1");
        assert_eq!(result.round_trip_failures.len(), 1);
        assert_eq!(result.round_trip_failures[0].reason, RoundTripReason::WriteFailed);
    }

    #[test]
    fn missing_list_verb_errors() {
        let mut source = ScriptedCaller::new();
        let mut target = ScriptedCaller::new();
        let mut sv = source_verbs();
        sv.list = None;
        let tv = target_verbs();
        let mut engine = TransferEngine {
            source: &mut source,
            target: &mut target,
            source_verbs: sv,
            target_verbs: tv,
            max_retries: 2,
            max_entries: None,
            verify_round_trip: false,
            now_iso8601: Box::new(|| "x".to_string()),
        };
        let err = engine.run().unwrap_err();
        assert!(err.description.contains("no `list` verb"));
    }
}
