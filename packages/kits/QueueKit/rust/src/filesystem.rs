// FilesystemBackend (Rust) per QUEUEKIT_SPEC §5,6,8,9.
//
// Independent reimplementation from the spec, not a translation of
// the Swift. Byte-identical to Swift on all conformance fixtures.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use crate::backend::{QueueBackend, WatchHandler};
use crate::error::QueueError;
use std::any::Any;
use crate::job::{
    encode_job, encode_signal, filename_for_job, ArtifactRef, HLC, Job, JobId,
    ObservationStatus, SessionId, SignalFile, StreamId,
};

const STALE_TMP: Duration = Duration::from_secs(5 * 60);

/// Poll cadence for the directory watcher's polling path.
///
/// 200 ms — matches Swift's `Watcher.watchPoll` interval (200_000_000 ns)
/// so both ports deliver the same near-realtime guarantee. Short enough for
/// near-realtime throughput; long enough that the thread does not spin a core.
///
/// Used by the `poll_watch_loop` helper, which is:
///   - the sole `watch()` implementation when the `watch` feature is disabled.
///   - the runtime fallback when `watch` is enabled but `RecommendedWatcher`
///     setup fails (inotify watch-limit exhausted, unsupported filesystem, etc.).
const WATCH_POLL_INTERVAL: Duration = Duration::from_millis(200);

pub struct FilesystemBackend {
    root: PathBuf,
    hlc: Mutex<HlcGenState>,
}

struct HlcGenState {
    node_id: i32,
    last_physical: i64,
    last_logical: i32,
}

/// Opens `path` for exclusive write creation (O_CREAT | O_EXCL).
/// On Unix the file is created with mode 0o600 (owner read/write only) —
/// queue files carry encoded job payloads that may include sensitive content
/// from the estate. Restricting access to the owning process is defense in
/// depth. Windows has no equivalent octal permission model so the mode call
/// is omitted.
fn create_exclusive(path: &Path) -> std::io::Result<File> {
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    opts.mode(0o600);
    opts.open(path)
}

// MARK: - Identifier validation (planned security hardening, CAND-023)

/// Validates that `id` is a safe single filesystem path component.
///
/// An identifier used to build a queue path (stream_id, job id, or any
/// caller-influenced component) must not contain characters that could
/// escape the queue root via path traversal. Specifically, rejects:
///   - empty strings
///   - "." or ".." (dot directory components)
///   - '/' or '\' (POSIX and Windows path separators)
///   - ASCII control characters 0x00–0x1F and 0x7F
///
/// Legitimate identifiers — 32-char hex job ids, stream names like "encode"
/// or "dreaming" — all pass. Enforces the same rule as Swift and Python
/// ports. Returns `Err(QueueError::InvalidIdentifier)` on rejection.
fn validate_identifier(id: &str) -> Result<(), QueueError> {
    if id.is_empty() {
        return Err(QueueError::InvalidIdentifier(
            "empty identifier".to_string()));
    }
    if id == "." || id == ".." {
        return Err(QueueError::InvalidIdentifier(
            format!("dot component: {:?}", id)));
    }
    for ch in id.chars() {
        if ch == '/' || ch == '\\' {
            return Err(QueueError::InvalidIdentifier(
                format!("path separator in {:?}", id)));
        }
        let v = ch as u32;
        if v <= 0x1F || v == 0x7F {
            return Err(QueueError::InvalidIdentifier(
                format!("control character in {:?}", id)));
        }
    }
    Ok(())
}

impl FilesystemBackend {
    pub fn new(root: impl Into<PathBuf>, node_id: i32) -> Result<Self, QueueError> {
        let root: PathBuf = root.into();
        let me = FilesystemBackend {
            root: root.clone(),
            hlc: Mutex::new(HlcGenState {
                node_id, last_physical: 0, last_logical: 0
            }),
        };
        me.ensure_maildir()?;
        me.clean_stale_tmp()?;
        Ok(me)
    }

    fn tmp_dir(&self) -> PathBuf { self.root.join("tmp") }
    fn new_dir(&self) -> PathBuf { self.root.join("new") }
    fn cur_dir(&self) -> PathBuf { self.root.join("cur") }
    fn done_dir(&self) -> PathBuf { self.root.join("done") }

    /// Crash recovery: move every job left in `cur/` (claimed by a prior process
    /// that exited before completing it) back to `new/`, so the next
    /// `drain_available` re-drives it. The inverse of the new/→cur/ claim.
    ///
    /// Safe to call ONLY at mount, when no drain session is live: a freshly
    /// started process owns no in-flight work, so every entry in `cur/` is a crash
    /// orphan from a prior run. With one writer per estate this holds. Returns the
    /// number of jobs reclaimed. Mirrors Swift `FilesystemBackend.reclaimInFlight()`.
    pub fn reclaim_in_flight(&self) -> Result<usize, QueueError> {
        let mut entries: Vec<String> = fs::read_dir(self.cur_dir())
            .map_err(|e| QueueError::BackendUnavailable(format!("list cur/: {}", e)))?
            .filter_map(Result::ok)
            .filter_map(|e| e.file_name().into_string().ok())
            .collect();
        entries.sort();
        let mut reclaimed = 0usize;
        for entry in entries {
            let src = self.cur_dir().join(&entry);
            let dst = self.new_dir().join(&entry);
            match fs::rename(&src, &dst) {
                Ok(()) => reclaimed += 1,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => {
                    return Err(QueueError::RenameFailed {
                        from: src.display().to_string(),
                        to: dst.display().to_string(),
                        msg: e.to_string(),
                    })
                }
            }
        }
        Ok(reclaimed)
    }

    fn ensure_maildir(&self) -> Result<(), QueueError> {
        for sub in &["tmp", "new", "cur", "done"] {
            let p = self.root.join(sub);
            fs::create_dir_all(&p).map_err(|e|
                QueueError::DirectoryCreationFailed(format!("{}: {}", p.display(), e)))?;
        }
        Ok(())
    }

    fn clean_stale_tmp(&self) -> Result<(), QueueError> {
        let tmp = self.tmp_dir();
        if !tmp.exists() { return Ok(()); }
        let now = SystemTime::now();
        for entry in fs::read_dir(&tmp).map_err(QueueError::from)? {
            let entry = entry.map_err(QueueError::from)?;
            if let Ok(meta) = entry.metadata() {
                if let Ok(mtime) = meta.modified() {
                    if now.duration_since(mtime).unwrap_or(Duration::ZERO) > STALE_TMP {
                        let _ = fs::remove_file(entry.path());
                    }
                }
            }
        }
        Ok(())
    }

    /// 200 ms poll loop — the watch fallback shared by both build configurations.
    ///
    /// Active in two scenarios:
    ///   1. `watch` feature disabled (no-watch build) — sole watcher implementation.
    ///   2. `watch` feature enabled but `RecommendedWatcher` setup failed at
    ///      runtime (inotify watch-limit exhausted, unsupported filesystem, etc.)
    ///      — automatic fallback from the evented path.
    ///
    /// Drain-first: jobs present before this is called are drained in the initial
    /// pass, not lost. Each 200 ms tick is treated as a wake hint; drain_available()
    /// is the authority on what is claimable. Spurious ticks that find new/ empty
    /// drain to nothing and loop. A drain error propagates fail-closed (SPEC §5 B-3).
    ///
    /// Exposed as `pub` so integration tests can call it directly to verify the
    /// fallback path's contract without triggering evented watcher setup.
    /// Not part of the `QueueBackend` trait — this is an inherent helper on
    /// `FilesystemBackend` specifically.
    pub fn poll_watch_loop(&self, handler: WatchHandler) -> Result<(), QueueError> {
        // Drain anything already present before entering the poll loop so jobs
        // that arrived before watch() was called are not lost.
        for (job, session_id) in self.drain_available()? {
            handler(job, session_id)?;
        }

        loop {
            std::thread::sleep(WATCH_POLL_INTERVAL);
            // Each tick is treated as a wake hint; drain_available() is the
            // authority. Spurious ticks that find new/ empty drain to nothing.
            let pairs = self.drain_available()?;
            for (job, session_id) in pairs {
                handler(job, session_id)?;
            }
        }
    }

    fn next_hlc(&self) -> HLC {
        let now_ms: i64 = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64).unwrap_or(0);
        let mut s = self.hlc.lock().unwrap();
        if now_ms > s.last_physical {
            s.last_physical = now_ms;
            s.last_logical = 0;
        } else {
            s.last_logical = s.last_logical.wrapping_add(1);
        }
        HLC {
            physical_time: s.last_physical,
            logical_count: s.last_logical,
            node_id: s.node_id,
        }
    }
}

impl QueueBackend for FilesystemBackend {
    fn as_any(&self) -> &dyn Any {
        self
    }

    // spec §8
    fn write(&self, job: &Job) -> Result<(), QueueError> {
        // Validate before any filesystem path construction.
        validate_identifier(&job.stream_id.0)?;
        validate_identifier(&job.id.0)?;
        let encoded = encode_job(job);
        let filename = filename_for_job(job);
        let tmp_path = self.tmp_dir().join(&filename);
        let new_path = self.new_dir().join(&filename);

        // Step 3: O_CREAT | O_EXCL
        let mut f = create_exclusive(&tmp_path)
            .map_err(|e| QueueError::WriteFailed(format!("O_EXCL: {}", e)))?;
        // Steps 4 + 5 + 6
        f.write_all(&encoded).map_err(QueueError::from)?;
        f.sync_data().map_err(QueueError::from)?;
        drop(f);

        // Step 7: rename
        if let Err(e) = fs::rename(&tmp_path, &new_path) {
            // ENOENT — recreate and retry
            if let Some(2) = e.raw_os_error() { // ENOENT = 2 on Linux/macOS
                let _ = fs::create_dir_all(self.new_dir());
                if let Err(e2) = fs::rename(&tmp_path, &new_path) {
                    let _ = fs::remove_file(&tmp_path);
                    return Err(QueueError::WriteFailed(
                        format!("rename retry: {}", e2)));
                }
            } else {
                let _ = fs::remove_file(&tmp_path);
                return Err(QueueError::RenameFailed {
                    from: tmp_path.display().to_string(),
                    to: new_path.display().to_string(),
                    msg: e.to_string(),
                });
            }
        }

        // Step 8: fsync the new/ directory
        if let Ok(d) = File::open(self.new_dir()) {
            let _ = d.sync_all();
        }
        Ok(())
    }

    // Batch enqueue: write all job files, then fsync new/ ONCE. The per-job
    // `write` fsyncs each file (sync_data) and the new/ directory; a bulk reindex
    // enqueuing tens of thousands of jobs serial-fsyncs a full core. Here each
    // file is still written O_EXCL + renamed into new/, but the durability
    // barrier is a single new/ fsync for the whole batch.
    //
    // Safe durability: a crash before the final fsync may lose some just-enqueued
    // jobs, but the bulk producer (reindex) derives its jobs from the durable
    // estate, so the next resume's reindex re-enqueues any drawer still missing
    // its index — AT-LEAST-ONCE via the estate as source of truth. Per-file
    // content is NOT fsynced before rename (matching the batched profile); a job
    // file that turns up empty after a crash decodes-fail and is dropped to done/
    // by the drain, then re-enqueued by reindex. Streaming capture keeps per-job
    // durability via the unchanged `write`.
    fn write_batch(&self, jobs: &[Job]) -> Result<usize, QueueError> {
        if jobs.is_empty() {
            return Ok(0);
        }
        let mut written = 0usize;
        for job in jobs {
            // Validate before any filesystem path construction.
            validate_identifier(&job.stream_id.0)?;
            validate_identifier(&job.id.0)?;
            let encoded = encode_job(job);
            let filename = filename_for_job(job);
            let tmp_path = self.tmp_dir().join(&filename);
            let new_path = self.new_dir().join(&filename);
            let mut f = create_exclusive(&tmp_path)
                .map_err(|e| QueueError::WriteFailed(format!("O_EXCL: {}", e)))?;
            f.write_all(&encoded).map_err(QueueError::from)?;
            // No per-file sync_data — one new/ fsync below covers the batch.
            drop(f);
            if let Err(e) = fs::rename(&tmp_path, &new_path) {
                if let Some(2) = e.raw_os_error() {
                    let _ = fs::create_dir_all(self.new_dir());
                    if let Err(e2) = fs::rename(&tmp_path, &new_path) {
                        let _ = fs::remove_file(&tmp_path);
                        return Err(QueueError::WriteFailed(format!("rename retry: {}", e2)));
                    }
                } else {
                    let _ = fs::remove_file(&tmp_path);
                    return Err(QueueError::RenameFailed {
                        from: tmp_path.display().to_string(),
                        to: new_path.display().to_string(),
                        msg: e.to_string(),
                    });
                }
            }
            written += 1;
        }
        // Single durability barrier for the whole batch.
        if let Ok(d) = File::open(self.new_dir()) {
            let _ = d.sync_all();
        }
        Ok(written)
    }

    // spec §9
    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError> {
        let mut entries: Vec<String> = fs::read_dir(self.new_dir())
            .map_err(|e| QueueError::BackendUnavailable(format!("list new/: {}", e)))?
            .filter_map(Result::ok)
            .filter_map(|e| e.file_name().into_string().ok())
            .collect();
        entries.sort();

        let mut claimed: Vec<String> = vec![];
        for entry in entries {
            let src = self.new_dir().join(&entry);
            let dst = self.cur_dir().join(&entry);
            match fs::rename(&src, &dst) {
                Ok(()) => claimed.push(entry),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(QueueError::RenameFailed {
                    from: src.display().to_string(),
                    to: dst.display().to_string(),
                    msg: e.to_string(),
                }),
            }
        }

        let mut results: Vec<(Job, SessionId)> = vec![];
        for entry in claimed {
            let path = self.cur_dir().join(&entry);
            let bytes = match fs::read(&path) {
                Ok(b) => b,
                Err(_) => continue,
            };
            match crate::job::decode_job(&bytes) {
                Ok(j) => results.push(
                    (j, SessionId(uuid::Uuid::new_v4().to_string().to_lowercase()))),
                Err(_) => {
                    let _ = fs::rename(&path, self.done_dir().join(&entry));
                }
            }
        }
        results.sort_by(|a, b| {
            (a.0.submitted_at.physical_time,
             a.0.submitted_at.logical_count,
             a.0.submitted_at.node_id).cmp(&(
                b.0.submitted_at.physical_time,
                b.0.submitted_at.logical_count,
                b.0.submitted_at.node_id))
        });
        Ok(results)
    }

    fn complete(
        &self,
        job_id: &JobId,
        status: ObservationStatus,
        artifacts: Vec<ArtifactRef>,
    ) -> Result<(), QueueError> {
        // Validate before signal file path construction.
        validate_identifier(&job_id.0)?;
        if !status.is_terminal() {
            return Err(QueueError::InvalidTerminalStatus(
                status.raw().to_string()));
        }
        let mut match_name: Option<String> = None;
        for entry in fs::read_dir(self.cur_dir()).map_err(QueueError::from)? {
            let entry = entry.map_err(QueueError::from)?;
            let name = entry.file_name().into_string().unwrap_or_default();
            if name.ends_with(&format!("-{}", job_id.0)) {
                match_name = Some(name);
                break;
            }
        }
        let name = match_name.ok_or_else(||
            QueueError::JobNotFound(job_id.0.clone()))?;

        // Write signal file BEFORE renaming
        let completed = self.next_hlc();
        let sig = SignalFile {
            job_id: job_id.clone(),
            status,
            artifacts,
            completed_at: completed,
        };
        let sig_data = encode_signal(&sig);
        let sig_tmp = self.tmp_dir().join(format!("{}.signal", job_id.0));
        let sig_final = self.done_dir().join(format!("{}.signal", job_id.0));
        let mut f = create_exclusive(&sig_tmp)
            .map_err(|e| QueueError::WriteFailed(e.to_string()))?;
        f.write_all(&sig_data).map_err(QueueError::from)?;
        f.sync_data().map_err(QueueError::from)?;
        drop(f);
        fs::rename(&sig_tmp, &sig_final).map_err(|e| QueueError::RenameFailed {
            from: sig_tmp.display().to_string(),
            to: sig_final.display().to_string(),
            msg: e.to_string(),
        })?;

        fs::rename(self.cur_dir().join(&name), self.done_dir().join(&name))
            .map_err(|e| QueueError::RenameFailed {
                from: name.clone(),
                to: name,
                msg: e.to_string(),
            })?;
        Ok(())
    }

    // Batch completion: ONE cur/ scan + ONE durability barrier for the whole
    // drained batch. The per-job `complete` does a full read_dir(cur/) to find
    // each job's file (O(N²) over a batch) and an fsync per job — observed live
    // as the dominant cost of a bulk-import drain (the worker pinned in
    // File::sync_all). Here we scan cur/ once into a job_id→filename index, then
    // write each signal file + rename without a per-file fsync, and fsync the
    // done/ directory ONCE at the end.
    //
    // Safe durability: a crash before the final dir fsync leaves the not-yet-
    // renamed jobs in cur/, so they are re-claimed on restart and re-ingested —
    // the AT-LEAST-ONCE contract is preserved (ingest is idempotent). The index
    // keys on the filename suffix after the last '-', which is the job_id:
    // QueueKit job ids (generate_job_id → Uuid::simple) carry no '-', so the
    // last '-' is always the separator before the id (same assumption the
    // per-job `complete` makes with its `ends_with("-{id}")` match).
    fn complete_batch(
        &self,
        completions: &[(JobId, ObservationStatus)],
    ) -> Result<usize, QueueError> {
        if completions.is_empty() {
            return Ok(0);
        }
        // Validate all identifiers before touching the filesystem.
        for (job_id, _) in completions {
            validate_identifier(&job_id.0)?;
        }
        for (_, status) in completions {
            if !status.is_terminal() {
                return Err(QueueError::InvalidTerminalStatus(status.raw().to_string()));
            }
        }
        // One scan: job_id (filename suffix) → filename.
        let mut by_id: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        for entry in fs::read_dir(self.cur_dir()).map_err(QueueError::from)? {
            let entry = entry.map_err(QueueError::from)?;
            let name = entry.file_name().into_string().unwrap_or_default();
            if let Some(idx) = name.rfind('-') {
                by_id.insert(name[idx + 1..].to_string(), name);
            }
        }

        let mut completed = 0usize;
        for (job_id, status) in completions {
            // Not in cur/ → already retired (or never claimed); skip, matching
            // per-job `complete`'s JobNotFound being a no-op for the batch caller.
            let Some(name) = by_id.get(&job_id.0) else { continue };
            let completed_at = self.next_hlc();
            let sig = SignalFile {
                job_id: job_id.clone(),
                status: *status,
                artifacts: Vec::new(),
                completed_at,
            };
            let sig_data = encode_signal(&sig);
            let sig_tmp = self.tmp_dir().join(format!("{}.signal", job_id.0));
            let sig_final = self.done_dir().join(format!("{}.signal", job_id.0));
            // No per-file fsync — one done/ fsync below covers the whole batch.
            let mut f = create_exclusive(&sig_tmp)
                .map_err(|e| QueueError::WriteFailed(e.to_string()))?;
            f.write_all(&sig_data).map_err(QueueError::from)?;
            drop(f);
            fs::rename(&sig_tmp, &sig_final).map_err(|e| QueueError::RenameFailed {
                from: sig_tmp.display().to_string(),
                to: sig_final.display().to_string(),
                msg: e.to_string(),
            })?;
            fs::rename(self.cur_dir().join(name), self.done_dir().join(name)).map_err(|e| {
                QueueError::RenameFailed {
                    from: name.clone(),
                    to: name.clone(),
                    msg: e.to_string(),
                }
            })?;
            completed += 1;
        }

        // Single durability barrier for the whole batch.
        if let Ok(d) = File::open(self.done_dir()) {
            let _ = d.sync_all();
        }
        Ok(completed)
    }

    fn in_flight(&self) -> Result<Vec<Job>, QueueError> {
        list_jobs(&self.cur_dir(), None)
    }

    // pendingCount (telemetry depth probe) — Swift parity.
    //
    // Count files in `new/` — each file is one pending job not yet claimed. A
    // non-existent directory means zero pending (matches Swift's guard).
    fn pending_count(&self) -> Result<usize, QueueError> {
        match fs::read_dir(self.new_dir()) {
            Ok(rd) => Ok(rd.filter_map(Result::ok).count()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
            Err(e) => Err(QueueError::BackendUnavailable(
                format!("pending_count list new/: {e}"))),
        }
    }

    // ── Stream-scoped drain (ADR-021 Decision 7 / T1) ──────────────────────

    /// Claim and return only the pending jobs that belong to `stream`.
    ///
    /// Scans `new/`, attempts a rename to `cur/` on each file, decodes it, and
    /// keeps the job only if `job.stream_id == stream`. Files belonging to other
    /// streams that were successfully renamed are renamed BACK to `new/` before
    /// returning so they remain available for their own stream's drain caller.
    /// This preserves the at-most-once claim guarantee per stream: a stream-a
    /// drainer never permanently claims stream-b files.
    ///
    /// Ordering and determinism are identical to `drain_available()`: sorted
    /// entries, rename-per-file, HLC ascending sort on results. Swift twin:
    /// `FilesystemBackend.drainAvailable(stream:)`.
    fn drain_available_for_stream(
        &self,
        stream: &StreamId,
    ) -> Result<Vec<(Job, SessionId)>, QueueError> {
        let mut entries: Vec<String> = fs::read_dir(self.new_dir())
            .map_err(|e| QueueError::BackendUnavailable(
                format!("list new/ for stream drain: {}", e)))?
            .filter_map(Result::ok)
            .filter_map(|e| e.file_name().into_string().ok())
            .collect();
        entries.sort();

        // Decode each file WHILE it is still in new/ — a read does not claim it —
        // and rename ONLY matching-stream files into cur/. Non-matching files are
        // never touched, so concurrent drainers of different streams (encode +
        // dreaming) cannot steal or race on each other's jobs. (The earlier
        // claim-all-then-unclaim form transiently moved every stream's files into
        // cur/, which collided under concurrent stream drains — ADR-021 D7 requires
        // that one stream's drain never disturbs another's.)
        let mut results: Vec<(Job, SessionId)> = vec![];
        for entry in entries {
            let new_path = self.new_dir().join(&entry);
            let bytes = match fs::read(&new_path) {
                // Gone already: another drainer claimed it between listing and read.
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(_) => continue,
                Ok(b) => b,
            };
            match crate::job::decode_job(&bytes) {
                Ok(j) => {
                    if &j.stream_id != stream {
                        continue; // belongs to another stream — leave it in new/
                    }
                    // Atomic claim: new/ → cur/. A same-stream drainer that won the
                    // race renames it first → our rename hits NotFound → skip.
                    let cur_path = self.cur_dir().join(&entry);
                    match fs::rename(&new_path, &cur_path) {
                        Ok(()) => results.push(
                            (j, SessionId(uuid::Uuid::new_v4().to_string().to_lowercase()))),
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                        Err(e) => return Err(QueueError::RenameFailed {
                            from: new_path.display().to_string(),
                            to: cur_path.display().to_string(),
                            msg: e.to_string(),
                        }),
                    }
                }
                Err(_) => {
                    // Undecodable poison: dispose to done/ (mirrors the all-streams
                    // drain) so it does not accumulate across stream-scoped drains.
                    let _ = fs::rename(&new_path, self.done_dir().join(&entry));
                }
            }
        }
        results.sort_by(|a, b| {
            (a.0.submitted_at.physical_time,
             a.0.submitted_at.logical_count,
             a.0.submitted_at.node_id).cmp(&(
                b.0.submitted_at.physical_time,
                b.0.submitted_at.logical_count,
                b.0.submitted_at.node_id))
        });
        Ok(results)
    }

    /// Count pending jobs in `new/` that belong to `stream`.
    ///
    /// Scans `new/`, decodes each file, counts those whose `stream_id` matches.
    /// Non-claiming: files stay in `new/`. Swift twin:
    /// `FilesystemBackend.pendingCount(stream:)`.
    fn pending_count_for_stream(&self, stream: &StreamId) -> Result<usize, QueueError> {
        let new_dir = self.new_dir();
        match fs::read_dir(&new_dir) {
            Ok(rd) => {
                let mut count = 0usize;
                for entry in rd.filter_map(Result::ok) {
                    let path = entry.path();
                    if let Ok(bytes) = fs::read(&path) {
                        if let Ok(job) = crate::job::decode_job(&bytes) {
                            if &job.stream_id == stream {
                                count += 1;
                            }
                        }
                    }
                }
                Ok(count)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
            Err(e) => Err(QueueError::BackendUnavailable(
                format!("pending_count_for_stream list new/: {e}"))),
        }
    }

    fn completed(&self, stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError> {
        list_jobs(&self.done_dir(), stream_id)
    }

    // spec §3, §4: watch()
    //
    // Architecture: evented by default with automatic poll fallback.
    //
    //   Default build (`watch` feature, which is now in `default`):
    //     Attempts to set up `RecommendedWatcher` from the `notify` crate —
    //     inotify on Linux, kqueue/FSEvents on macOS, ReadDirectoryChangesW
    //     on Windows. If setup fails (inotify watch-limit exhausted,
    //     unsupported filesystem, etc.), falls back to `poll_watch_loop`
    //     automatically. Same drain-first contract on both paths.
    //
    //   No-watch build (--no-default-features --features filesystem):
    //     Uses `poll_watch_loop` directly. No external dependency.
    //     Useful for embedded targets or constrained environments.
    //
    // Both paths share the same wake contract: every wake calls drain_available()
    // as the authority on what is claimable — the wake is a hint, never
    // authoritative. Spurious wakes drain to empty harmlessly. A drain error
    // propagates fail-closed (SPEC §5 B-3).

    #[cfg(feature = "watch")]
    fn watch(&self, handler: WatchHandler) -> Result<(), QueueError> {
        use notify::{Config, RecommendedWatcher, RecursiveMode, Watcher as NotifyWatcher};
        use std::sync::mpsc;

        let (tx, rx) = mpsc::channel();

        // Attempt evented watcher setup. Both `new` and `watch` can fail on
        // resource-exhausted or unsupported-fs conditions (inotify limits,
        // NFS, certain FUSE mounts). On any setup failure, fall back to
        // poll_watch_loop automatically — no error is surfaced for setup
        // failures, matching Swift's watchLinux fallback behavior.
        let mut watcher = match RecommendedWatcher::new(tx, Config::default()) {
            Ok(w) => w,
            Err(_) => return self.poll_watch_loop(handler),
        };
        if watcher
            .watch(self.new_dir().as_path(), RecursiveMode::NonRecursive)
            .is_err()
        {
            return self.poll_watch_loop(handler);
        }

        // Drain anything already present before blocking on events, so jobs
        // that arrived between the maildir scan and the watcher attach are not
        // lost (drain-before-block; mirrors Swift's runInotifyLoop pattern).
        for (job, session_id) in self.drain_available()? {
            handler(job, session_id)?;
        }

        loop {
            match rx.recv() {
                Ok(_event) => {
                    // Wake is a hint only; drain_available() is the authority
                    // on what is actually claimable (drain-first semantics).
                    let pairs = self.drain_available()?;
                    for (job, session_id) in pairs {
                        handler(job, session_id)?;
                    }
                }
                Err(e) => {
                    return Err(QueueError::WatcherFailed(e.to_string()));
                }
            }
        }
    }

    #[cfg(not(feature = "watch"))]
    fn watch(&self, handler: WatchHandler) -> Result<(), QueueError> {
        // No-watch build: poll_watch_loop is the sole implementation.
        self.poll_watch_loop(handler)
    }
}

fn list_jobs(dir: &PathBuf, stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError> {
    let mut jobs: Vec<Job> = vec![];
    if !dir.exists() { return Ok(jobs); }
    let mut entries: Vec<String> = fs::read_dir(dir).map_err(QueueError::from)?
        .filter_map(Result::ok)
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    entries.sort();
    for entry in entries {
        if entry.ends_with(".signal") { continue; }
        let bytes = match fs::read(dir.join(&entry)) {
            Ok(b) => b,
            Err(_) => continue,
        };
        if let Ok(j) = crate::job::decode_job(&bytes) {
            if let Some(s) = stream_id {
                if &j.stream_id != s { continue; }
            }
            jobs.push(j);
        }
    }
    Ok(jobs)
}
