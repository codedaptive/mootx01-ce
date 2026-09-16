//! duty_queue.rs — the patient form of the estate's row-debt duties.
//!
//! Product mandate (Bob, 2026-09-16): every long-running function passes
//! through QueueKit so it is resumable. The duties below were built in their
//! impatient form only — the caller ran the batch inline — and a signal's work
//! ran inside its emit closure with only a receipt reaching the queue. This
//! module gives each duty a queued form on the shared per-estate
//! `queue.sqlite` (the same PersistenceKit backend the encode and dreaming
//! streams use), one stream per duty:
//!
//!   duty-span-encode      one batch of `run_span_encode_batch`
//!   duty-subject-backfill one batch of `subject_backfill_sweep`
//!   duty-facts-backfill   one pass of `backfill_ssc_facts`
//!   duty-fact-extraction  one batch of `run_fact_extraction_batch`
//!   duty-retrain-basis    one `reindex_corpus`
//!
//! A duty job means "pay one batch of this estate's debt for this duty". The
//! debt predicate (bit 27 clear, subject NULL, ssc_facts NULL, bit 28 clear)
//! is the cursor: a batch is idempotent, so a job reclaimed after a crash
//! simply runs again and the estate converges. The existing inline functions
//! are unchanged and remain the impatient path; here they are the batch body
//! a claimed job runs.
//!
//! Producer: `enqueue_duty` sends one job when the estate owes work on that
//! duty and this process has not already queued one (single occupancy per
//! estate and duty; a duplicate after a restart is harmless because batches
//! are idempotent). Drainer: `drain_duty` claims the stream's jobs, runs one
//! batch per job, replies done, and re-enqueues while debt remains so the
//! stream carries the work forward. The resident queues every owed duty
//! before its signal tick and drains the duties no signal owns after it;
//! `pay_duty_until_settled` is the impatient caller's loop (upgrade, dream,
//! impatient import). Twin of Swift `DutyQueue.swift`.

use std::collections::HashSet;

use crate::coordinator::{EstateCoordinator, GeniusLocusKitError};
use crate::EstateHandle;

/// The duties with a queued form. The wire name is the stream suffix and the
/// `duty` extension on every job; both ports spell them identically.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DutyKind {
    SpanEncode,
    SubjectBackfill,
    FactsBackfill,
    FactExtraction,
    RetrainBasis,
}

impl DutyKind {
    pub const ALL: [DutyKind; 5] = [
        DutyKind::SpanEncode,
        DutyKind::SubjectBackfill,
        DutyKind::FactsBackfill,
        DutyKind::FactExtraction,
        DutyKind::RetrainBasis,
    ];

    /// Duties whose debt the resident pays on its own cadence. The retrain is
    /// requested by the dreaming theta hook and the upgrade, never inferred.
    pub const RESIDENT: [DutyKind; 3] =
        [DutyKind::SpanEncode, DutyKind::SubjectBackfill, DutyKind::FactExtraction];

    /// Duties no standing signal owns; the tick drains these after the
    /// scheduler so each tick pays exactly one batch per duty.
    pub const UNSIGNALLED: [DutyKind; 3] =
        [DutyKind::SubjectBackfill, DutyKind::FactsBackfill, DutyKind::RetrainBasis];

    pub fn wire_name(self) -> &'static str {
        match self {
            DutyKind::SpanEncode => "span-encode",
            DutyKind::SubjectBackfill => "subject-backfill",
            DutyKind::FactsBackfill => "facts-backfill",
            DutyKind::FactExtraction => "fact-extraction",
            DutyKind::RetrainBasis => "retrain-basis",
        }
    }

    /// The QueueKit stream this duty's jobs ride.
    pub fn stream_id(self) -> queuekit::StreamId {
        queuekit::StreamId(format!("duty-{}", self.wire_name()))
    }

    fn debt_driven(self) -> bool {
        !matches!(self, DutyKind::FactsBackfill | DutyKind::RetrainBasis)
    }
}

/// What one `drain_duty` call did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DutyDrainReport {
    pub kind: DutyKind,
    /// Jobs claimed and completed on the duty's stream.
    pub jobs_run: usize,
    /// Units the batches paid: drawers encoded, subjects written, facts rows
    /// written, sources settled by extraction, or 1 per completed retrain.
    pub units_paid: usize,
    /// Debt still owed after the drain (0 for the retrain).
    pub remaining_debt: usize,
    pub made_progress: bool,
}

/// Batch sizes per job. The subject figure matches the `dream` finisher
/// (256 per pass); fact extraction keeps this port's Signal 14 batch (20).
const DUTY_SUBJECT_BATCH: usize = 256;
const DUTY_FACT_EXTRACTION_BATCH: usize = 16;

impl EstateCoordinator {
    fn duty_failure(kind: DutyKind, detail: String) -> GeniusLocusKitError {
        GeniusLocusKitError::UnderlyingEstateFailure {
            reason: format!("duty {}: {detail}", kind.wire_name()),
        }
    }

    /// How much this estate still owes on `kind`. Zero when the duty's
    /// prerequisite (encoder provisioned, subject producer, extractor) is
    /// absent, so a duty with nothing to run is never queued. The facts
    /// backfill has no cheap count and is paid on demand; the retrain is
    /// requested, not inferred.
    pub fn duty_debt(&self, handle: &EstateHandle, kind: DutyKind) -> Result<usize, GeniusLocusKitError> {
        self.duty_debt_at(handle, kind, (queuekit::wall_now_secs() * 1000.0) as i64)
    }

    fn duty_debt_at(&self, handle: &EstateHandle, kind: DutyKind, now: i64) -> Result<usize, GeniusLocusKitError> {
        let estate = self.estate_for(handle)?;
        let count = match kind {
            DutyKind::SpanEncode => {
                let provisioned = matches!(
                    estate.meta(Self::EMBEDDING_PROVIDER_META_KEY),
                    Ok(Some(ref id)) if id == Self::ENCODER_PROVIDER_ID
                );
                if !provisioned || !self.vector_stores.contains_key(handle) {
                    return Ok(0);
                }
                estate.count_span_index_debt()
            }
            DutyKind::SubjectBackfill => {
                if !self.subject_producers.contains_key(handle) {
                    return Ok(0);
                }
                estate.count_subject_debt()
            }
            DutyKind::FactExtraction => {
                if !self.fact_extractors.contains_key(handle) {
                    return Ok(0);
                }
                let state = self.fact_extraction_work_status(handle, now)?;
                return Ok(state.runnable + state.in_flight + state.retrying + state.blocked + state.rejected);
            }
            DutyKind::FactsBackfill | DutyKind::RetrainBasis => return Ok(0),
        };
        count.map_err(|e| Self::duty_failure(kind, format!("debt count: {e:?}")))
    }

    /// Queue one job for `kind` on this estate. Returns `true` when a job was
    /// sent, `false` when one is already queued (in this process's set, or
    /// pending on the stream from an earlier process) or, for the
    /// debt-driven duties, the estate owes nothing.
    pub fn enqueue_duty(&self, handle: &EstateHandle, kind: DutyKind, now_millis: i64) -> Result<bool, GeniusLocusKitError> {
        if self.duty_queued.borrow().get(handle).is_some_and(|set| set.contains(&kind)) {
            return Ok(false);
        }
        if kind == DutyKind::FactExtraction && self.fact_extraction_work_status(handle, now_millis)?.runnable == 0 {
            return Ok(false);
        }
        if kind.debt_driven() && self.duty_debt_at(handle, kind, now_millis)? == 0 {
            return Ok(false);
        }
        self.ensure_dreaming_queue(handle);
        // Single occupancy is durable: a job left pending by an earlier
        // process is this process's job, not a reason to queue another.
        let pending = {
            let map = self.dreaming_queues.borrow();
            let Some((queue, _)) = map.get(handle) else {
                return Err(Self::duty_failure(kind, "queue entry missing after ensure_dreaming_queue".to_string()));
            };
            queue
                .pending_count_for_stream(&kind.stream_id())
                .map_err(|e| Self::duty_failure(kind, format!("pending count: {e:?}")))?
        };
        if pending > 0 {
            self.duty_queued.borrow_mut().entry(handle.clone()).or_default().insert(kind);
            return Ok(false);
        }
        let payload = serde_json::json!({
            "estateUUID": uuid::Uuid::from_bytes(handle.estate_uuid).hyphenated().to_string().to_uppercase(),
            "duty": kind.wire_name(),
        });
        let payload = serde_json::to_vec(&payload)
            .map_err(|e| Self::duty_failure(kind, format!("payload: {e}")))?;
        let mut extensions = serde_json::Map::new();
        extensions.insert("duty".to_string(), serde_json::Value::String(kind.wire_name().to_string()));
        let mut map = self.dreaming_queues.borrow_mut();
        let Some((queue, hlc)) = map.get_mut(handle) else {
            return Err(Self::duty_failure(kind, "queue entry missing after ensure_dreaming_queue".to_string()));
        };
        let job = queuekit::Job {
            id: queuekit::JobId(uuid::Uuid::new_v4().simple().to_string()),
            stream_id: kind.stream_id(),
            submitted_at: hlc.send(now_millis),
            priority: 40,
            payload,
            extensions,
        };
        queue.send(&job).map_err(|e| Self::duty_failure(kind, format!("send: {e:?}")))?;
        drop(map);
        self.duty_queued.borrow_mut().entry(handle.clone()).or_default().insert(kind);
        Ok(true)
    }

    /// Queue every resident duty the estate currently owes. Called before the
    /// signal tick so the resident's cadence pays debt through the queue.
    pub fn enqueue_owed_duties(&self, handle: &EstateHandle, now_millis: i64) -> Result<(), GeniusLocusKitError> {
        for kind in DutyKind::RESIDENT {
            self.enqueue_duty(handle, kind, now_millis)?;
        }
        Ok(())
    }

    /// Claim the jobs on `kind`'s stream, run one batch per job, reply done,
    /// and re-enqueue while debt remains. A batch error completes the job
    /// with concerns and is returned after the reply so the queue never holds
    /// a job the process has given up on.
    pub fn drain_duty(&mut self, handle: &EstateHandle, kind: DutyKind, now_millis: i64) -> Result<DutyDrainReport, GeniusLocusKitError> {
        let extraction = if kind == DutyKind::FactExtraction {
            self.prepare_fact_extraction_batch(handle, DUTY_FACT_EXTRACTION_BATCH, now_millis)?
        } else { None };
        if kind == DutyKind::FactExtraction && extraction.is_none() {
            return Ok(DutyDrainReport { kind, jobs_run: 0, units_paid: 0,
                remaining_debt: self.duty_debt_at(handle, kind, now_millis)?, made_progress: false });
        }
        self.ensure_dreaming_queue(handle);
        let batch = {
            let map = self.dreaming_queues.borrow();
            let Some((queue, _)) = map.get(handle) else {
                return Err(Self::duty_failure(kind, "queue entry missing after ensure_dreaming_queue".to_string()));
            };
            queue
                .drain_for_stream(&kind.stream_id(), now_millis as f64 / 1000.0)
                .map_err(|e| Self::duty_failure(kind, format!("drain: {e:?}")))?
        };
        if let Some(set) = self.duty_queued.borrow_mut().get_mut(handle) {
            set.remove(&kind);
        }
        // Every job on a duty stream names the same debt, so several claimed
        // at once (queued across restarts, before the single-occupancy set
        // existed in this process) are paid by ONE batch, not one batch each.
        let mut jobs_run = 0usize;
        let mut units_paid = 0usize;
        let mut advanced = false;
        if !batch.is_empty() {
            let result = if kind == DutyKind::FactExtraction {
                extraction.expect("prepared extraction").run()
                    .map(|result| { advanced = result.made_progress; result.completed_sources })
            } else { self.run_duty_batch(handle, kind, now_millis).map(|units| { advanced = units > 0; units }) };
            match result {
                Ok(paid) => {
                    units_paid = paid;
                    for (job, _session) in &batch {
                        self.reply_duty(handle, &job.id, queuekit::ObservationStatus::Done);
                        jobs_run += 1;
                    }
                }
                Err(error) => {
                    for (job, _session) in &batch {
                        self.reply_duty(handle, &job.id, queuekit::ObservationStatus::DoneWithConcerns);
                    }
                    eprintln!(
                        "mootx01 duty {}: batch failed (estate {:?}): {error:?}",
                        kind.wire_name(),
                        handle.estate_uuid
                    );
                    return Err(error);
                }
            }
        }
        let remaining = self.duty_debt_at(handle, kind, now_millis)?;
        // Carry the work forward: a job that paid something and left debt
        // queues the next batch; a job that paid nothing does not loop.
        if jobs_run > 0 && advanced && remaining > 0 {
            self.enqueue_duty(handle, kind, now_millis)?;
        }
        Ok(DutyDrainReport { kind, jobs_run, units_paid, remaining_debt: remaining, made_progress: advanced })
    }

    /// Claim the jobs on `kind`'s stream without running them, for a caller
    /// that must run the batch body outside the coordinator lock (the
    /// dreaming theta retrain, which would otherwise hold every verb for the
    /// length of a retrain). Pair with `complete_duty_job`.
    pub fn claim_duty_jobs(&self, handle: &EstateHandle, kind: DutyKind, now_millis: i64) -> Result<Vec<queuekit::JobId>, GeniusLocusKitError> {
        self.ensure_dreaming_queue(handle);
        let map = self.dreaming_queues.borrow();
        let Some((queue, _)) = map.get(handle) else {
            return Err(Self::duty_failure(kind, "queue entry missing after ensure_dreaming_queue".to_string()));
        };
        let batch = queue
            .drain_for_stream(&kind.stream_id(), now_millis as f64 / 1000.0)
            .map_err(|e| Self::duty_failure(kind, format!("drain: {e:?}")))?;
        drop(map);
        if let Some(set) = self.duty_queued.borrow_mut().get_mut(handle) {
            set.remove(&kind);
        }
        Ok(batch.into_iter().map(|(job, _)| job.id).collect())
    }

    /// Complete a job claimed through `claim_duty_jobs`.
    pub fn complete_duty_job(&self, handle: &EstateHandle, job_id: &queuekit::JobId, succeeded: bool) {
        let status = if succeeded { queuekit::ObservationStatus::Done } else { queuekit::ObservationStatus::DoneWithConcerns };
        self.reply_duty(handle, job_id, status);
    }

    fn reply_duty(&self, handle: &EstateHandle, job_id: &queuekit::JobId, status: queuekit::ObservationStatus) {
        let map = self.dreaming_queues.borrow();
        if let Some((queue, _)) = map.get(handle) {
            if let Err(e) = queue.reply(job_id, status, Vec::new()) {
                eprintln!("mootx01 duty: reply failed for {:?}: {e:?}", job_id);
            }
        }
    }

    /// Drain the duty streams no standing signal owns, once. Called after the
    /// scheduler tick; the span-encode and fact-extraction signals drain
    /// their own streams inside their cycle.
    pub fn drain_duties(&mut self, handle: &EstateHandle, now_millis: i64) -> Result<Vec<DutyDrainReport>, GeniusLocusKitError> {
        let mut reports = Vec::new();
        for kind in DutyKind::UNSIGNALLED {
            reports.push(self.drain_duty(handle, kind, now_millis)?);
        }
        Ok(reports)
    }

    /// The impatient loop: enqueue and drain until the duty owes nothing or a
    /// batch pays nothing. Returns the units paid in total.
    pub fn pay_duty_until_settled(&mut self, handle: &EstateHandle, kind: DutyKind, now_millis: i64) -> Result<usize, GeniusLocusKitError> {
        let mut total = 0usize;
        loop {
            self.enqueue_duty(handle, kind, now_millis)?;
            let report = self.drain_duty(handle, kind, now_millis)?;
            total += report.units_paid;
            if report.jobs_run == 0 || !report.made_progress {
                return Ok(total);
            }
            if !kind.debt_driven() || report.remaining_debt == 0 {
                return Ok(total);
            }
        }
    }

    /// The existing impatient function for `kind`, run once as the body of a
    /// claimed job. Returns the units paid.
    fn run_duty_batch(&mut self, handle: &EstateHandle, kind: DutyKind, now_millis: i64) -> Result<usize, GeniusLocusKitError> {
        match kind {
            DutyKind::SpanEncode => self
                .run_span_encode_batch(handle, now_millis)
                .map(|n| n.max(0) as usize)
                .map_err(|e| Self::duty_failure(kind, e)),
            DutyKind::SubjectBackfill => {
                if !self.subject_producers.contains_key(handle) {
                    return Ok(0);
                }
                self.subject_backfill_sweep(handle, DUTY_SUBJECT_BATCH, now_millis).map(|r| r.written)
            }
            DutyKind::FactsBackfill => self
                .backfill_ssc_facts(handle)
                .map_err(|e| Self::duty_failure(kind, format!("{e:?}"))),
            DutyKind::FactExtraction => self
                .run_fact_extraction_batch(handle, DUTY_FACT_EXTRACTION_BATCH, now_millis)
                .map(|r| r.completed_sources),
            DutyKind::RetrainBasis => self
                .reindex_corpus(handle, now_millis)
                .map(|_| 1)
                .map_err(|e| Self::duty_failure(kind, format!("{e:?}"))),
        }
    }
}

/// The per-process single-occupancy guard, stored on the coordinator.
pub type DutyQueued = std::cell::RefCell<std::collections::HashMap<EstateHandle, HashSet<DutyKind>>>;
