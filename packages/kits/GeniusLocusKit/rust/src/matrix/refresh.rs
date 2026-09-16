//! One background refresh owner per estate. The worker never takes the
//! request-serving coordinator mutex, including when publishing its result.
use super::record_store::{check_cancel, fail};
use super::{MatrixRecordStore, MatrixTier};
use crate::audit::{EntryUUID, UnifiedAuditLog};
use persistence_kit::*;
use std::collections::{HashMap, HashSet};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Condvar, Mutex, RwLock,
};
use substrate_types::hlc::HLC;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MatrixRefreshLimits {
    pub audit_events: usize,
    pub cells: usize,
    pub source_rows: usize,
}
impl Default for MatrixRefreshLimits {
    fn default() -> Self {
        Self {
            audit_events: 1_000_000,
            cells: 1_000_000,
            source_rows: 1_000_000,
        }
    }
}
#[derive(Clone, Debug)]
pub struct MatrixRefreshStatus {
    pub phase: String,
    pub generation: Option<String>,
    pub watermark: HLC,
    pub reason: Option<String>,
    pub migration_phase: String,
    pub reclaimed_bytes: i64,
}
impl Default for MatrixRefreshStatus {
    fn default() -> Self {
        Self {
            phase: "idle".into(),
            generation: None,
            watermark: HLC::ZERO,
            reason: None,
            migration_phase: "complete".into(),
            reclaimed_bytes: 0,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatrixRefreshDisposition {
    Queued,
    Coalesced,
}
type RefreshResult = Result<Option<Arc<MatrixTier>>, String>;
struct Run {
    result: Mutex<Option<RefreshResult>>,
    done: Condvar,
    training: bool,
}
/// A caller may wait on this ticket AFTER releasing its coordinator lock.
#[derive(Clone)]
pub struct MatrixRefreshTicket {
    run: Arc<Run>,
}
impl MatrixRefreshTicket {
    pub fn wait(&self) -> RefreshResult {
        let mut state = self.run.result.lock().unwrap();
        while state.is_none() {
            state = self.run.done.wait(state).unwrap();
        }
        state.as_ref().unwrap().clone()
    }
}
struct State {
    active: Option<Arc<Run>>,
    status: MatrixRefreshStatus,
}
pub struct MatrixRefreshWorker {
    storage: Arc<dyn Storage>,
    id: String,
    state: Mutex<State>,
    serving: RwLock<Option<Arc<MatrixTier>>>,
    cancel: AtomicBool,
    frozen: bool,
}
impl MatrixRefreshWorker {
    pub fn new(
        storage: Arc<dyn Storage>,
        id: String,
        initial: Option<Arc<MatrixTier>>,
        frozen: bool,
    ) -> Arc<Self> {
        Arc::new(Self {
            storage,
            id,
            state: Mutex::new(State {
                active: None,
                status: MatrixRefreshStatus::default(),
            }),
            serving: RwLock::new(initial),
            cancel: AtomicBool::new(false),
            frozen,
        })
    }
    pub fn current(&self) -> Option<Arc<MatrixTier>> {
        self.serving.read().unwrap().clone()
    }
    pub fn status(&self) -> MatrixRefreshStatus {
        self.state.lock().unwrap().status.clone()
    }
    pub fn request(
        self: &Arc<Self>,
        now_millis: i64,
        limits: MatrixRefreshLimits,
        training_only: bool,
    ) -> StorageResult<(MatrixRefreshDisposition, MatrixRefreshTicket)> {
        let mut state = self.state.lock().unwrap();
        check_cancel(&self.cancel)?;
        if let Some(run) = &state.active {
            if run.training && !training_only {
                return Err(fail(
                    "deferred: training pass in progress; retry full refresh",
                ));
            }
            return Ok((
                MatrixRefreshDisposition::Coalesced,
                MatrixRefreshTicket { run: run.clone() },
            ));
        }
        let run = Arc::new(Run {
            result: Mutex::new(None),
            done: Condvar::new(),
            training: training_only,
        });
        state.active = Some(run.clone());
        state.status.phase = "running".into();
        state.status.reason = None;
        let owner = self.clone();
        let work = run.clone();
        let spawned = std::thread::Builder::new()
            .name("matrix-refresh".into())
            .spawn(move || {
                // Always notify waiters, even if legacy math panics on corrupt input.
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    owner.compute(now_millis, limits, training_only)
                }))
                .unwrap_or_else(|_| Err(fail("refresh panicked")))
                .map_err(|e| e.to_string());
                let mut state = owner.state.lock().unwrap();
                match &result {
                    Ok(Some(tier)) if !owner.cancel.load(Ordering::Acquire) => {
                        *owner.serving.write().unwrap() = Some(tier.clone());
                        state.status.watermark = tier.last_hlc;
                        state.status.phase = "idle".into();
                    }
                    Ok(_) => {
                        state.status.phase = "idle".into();
                        state.status.reason =
                            Some("training gate dormant; no refresh performed".into());
                    }
                    Err(reason) => {
                        state.status.phase = if reason.contains("deferred:") {
                            "deferred"
                        } else {
                            "failed"
                        }
                        .into();
                        state.status.reason = Some(reason.clone());
                    }
                }
                state.active = None;
                *work.result.lock().unwrap() = Some(result);
                work.done.notify_all();
            });
        if let Err(e) = spawned {
            state.active = None;
            state.status.phase = "failed".into();
            state.status.reason = Some(e.to_string());
            return Err(fail(e.to_string()));
        }
        Ok((
            MatrixRefreshDisposition::Queued,
            MatrixRefreshTicket { run },
        ))
    }
    pub fn close(&self) {
        self.cancel.store(true, Ordering::Release);
        let active = self.state.lock().unwrap().active.clone();
        if let Some(run) = active {
            let _ = MatrixRefreshTicket { run }.wait();
        }
    }
    fn compute(
        &self,
        now_millis: i64,
        limits: MatrixRefreshLimits,
        training: bool,
    ) -> StorageResult<Option<Arc<MatrixTier>>> {
        let store = MatrixRecordStore::new(self.storage.clone());
        if !self.frozen {
            store.prepare()?;
        }
        let expected = store.active_generation(&self.id)?;
        let mut tier = match store.load(&self.id, limits.cells) {
            Ok(tier) => tier,
            Err(StorageError::BackendError { underlying })
                if underlying.starts_with("matrix:") && !underlying.contains("deferred:") =>
            {
                None
            }
            Err(error) => return Err(error),
        };
        if let Some(tier) = &tier {
            *self.serving.write().unwrap() = Some(Arc::new(tier.clone()));
        }
        let source_count = self.storage.audit_log().count()?;
        let mut log = UnifiedAuditLog::new();
        let mut after = None;
        let mut count = 0;
        loop {
            check_cancel(&self.cancel)?;
            let page = self.storage.audit_log().iterate(after, None, 1024)?;
            if page.is_empty() {
                break;
            }
            count += page.len();
            if count > limits.audit_events {
                return Err(fail("deferred: audit replay exceeds configured limit"));
            }
            for event in &page {
                for entry in crate::hydration::bridge_storage_audit_event(event) {
                    log.add(entry);
                }
            }
            after = page.last().map(|e| e.hlc);
            if page.len() < 1024 {
                break;
            }
            std::thread::yield_now();
        }
        if training
            && !crate::training::TrainingThresholdGate::default()
                .decide(crate::training::TrainingThresholdGate::transition_count(
                    &log,
                ))
                .is_active()
        {
            return Ok(None);
        }
        let mut times = HashMap::new();
        let mut last_id: Option<String> = None;
        loop {
            check_cancel(&self.cancel)?;
            let predicate = last_id.as_ref().map(|id| {
                StoragePredicate::Gt(Column::new("drawers", "id"), TypedValue::Text(id.clone()))
            });
            let page = self.storage.row_store().query_projected(
                "drawers",
                &["id", "eventTime", "filedAt"],
                predicate.as_ref(),
                &[OrderClause::ascending(Column::new("drawers", "id"))],
                Some(1024),
                None,
            )?;
            if page.is_empty() {
                break;
            }
            for row in &page {
                if let Some(TypedValue::Text(id)) = row.get("id") {
                    if let Ok(id) = uuid::Uuid::parse_str(id) {
                        let time = match row.get("eventTime") {
                            Some(TypedValue::Timestamp(t)) => Some(*t),
                            _ => match row.get("filedAt") {
                                Some(TypedValue::Timestamp(t)) => Some(*t),
                                _ => None,
                            },
                        };
                        if let Some(time) = time {
                            times.insert(EntryUUID(id.as_u128().to_be_bytes()), time);
                        }
                    }
                }
            }
            if times.len() > limits.source_rows {
                return Err(fail("deferred: event-time budget exceeded"));
            }
            last_id = page.last().and_then(|r| match r.get("id") {
                Some(TypedValue::Text(id)) => Some(id.clone()),
                _ => None,
            });
            if last_id.is_none() {
                return Err(fail("missing drawer cursor"));
            }
            if page.len() < 1024 {
                break;
            }
        }
        if count != source_count || self.storage.audit_log().count()? != source_count {
            return Err(fail("deferred: source changed"));
        }
        check_cancel(&self.cancel)?;
        if let Some(tier) = &mut tier {
            tier.incremental_update(&log, &times);
        } else {
            tier = Some(MatrixTier::full_rebuild(&log, &times));
        }
        let mut tier = tier.unwrap();
        tier.co_occurrence_decayed = MatrixTier::decayed_co_occurrence(&log, now_millis);
        check_cancel(&self.cancel)?;
        tier.temporal_causality_decayed =
            MatrixTier::rebuild_temporal_from_with_decay(&log, HLC::ZERO, &times, Some(now_millis))
                .temporal_causality_decayed;
        tier.decayed_as_of_ms = now_millis;
        check_cancel(&self.cancel)?;
        if self.frozen {
            return Ok(Some(Arc::new(tier)));
        }
        // Bound abandoned staging across repeated publication failures.
        store.prune(&self.id, &expected.iter().cloned().collect(), &self.cancel)?;
        let gen = uuid::Uuid::new_v4().to_string();
        store.stage(
            &self.id,
            &tier,
            &gen,
            now_millis,
            limits.cells,
            &self.cancel,
        )?;
        store.publish(
            &self.id,
            &gen,
            expected.as_deref(),
            Some(source_count),
            &self.cancel,
        )?;
        // Publication is committed even if the separately retryable prune fails.
        let tier = Arc::new(tier);
        if !self.cancel.load(Ordering::Acquire) {
            *self.serving.write().unwrap() = Some(tier.clone());
        }
        store.prune(
            &self.id,
            &std::iter::once(gen.clone())
                .chain(expected)
                .collect::<HashSet<_>>(),
            &self.cancel,
        )?;
        let record = store.state(&self.id)?;
        let mut state = self.state.lock().unwrap();
        state.status.generation = Some(gen);
        if let Some(record) = record {
            if let Some(TypedValue::Text(p)) = record.get("migration_phase") {
                state.status.migration_phase = p.clone();
            }
            if let Some(TypedValue::Int(n)) = record.get("reclaimed_bytes") {
                state.status.reclaimed_bytes = *n;
            }
        }
        Ok(Some(tier))
    }
}
