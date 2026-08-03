// meeting_decision_capture.rs — Rust twin of Brain/MeetingDecisionCapture.swift.
//
// DCP M6 — the report type for the meeting-decision filing seam. The
// pure parser lives in substrate_ml::meeting_decision_extractor; the
// filing verb (`capture_meeting_decisions`) lives on the coordinator,
// which owns estate access. This module holds only the shared report
// shape so both the coordinator and its tests name one type.

use std::collections::HashMap;
use substrate_ml::meeting_decision_extractor::MeetingDecisionExtraction;

/// One transcript's filing outcome.
#[derive(Debug, Clone)]
pub struct MeetingDecisionCaptureReport {
    /// The parse outcome (accepted + rejected lines).
    pub extraction: MeetingDecisionExtraction,
    /// Ids of facts filed THIS call, in transcript order.
    pub filed_fact_ids: Vec<String>,
    /// Ids skipped because an identical fact was already on file
    /// (deterministic-id replay).
    pub skipped_existing_ids: Vec<String>,
    /// `Replaces decision <id>` references, keyed by the filed (or
    /// skipped) fact id — the M5 supersession wiring input.
    pub replaces_by_fact_id: HashMap<String, String>,
}
