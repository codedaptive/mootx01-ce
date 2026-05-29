// FilesystemBackend (Rust) per QUEUEKIT_SPEC §5,6,8,9.
//
// Independent reimplementation from the spec, not a translation of
// the Swift. Byte-identical to Swift on all conformance fixtures.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use crate::backend::QueueBackend;
use crate::error::QueueError;
use crate::job::{
    encode_job, encode_signal, filename_for_job, ArtifactRef, HLC, Job, JobId,
    ObservationStatus, SessionId, SignalFile, StreamId,
};

const STALE_TMP: Duration = Duration::from_secs(5 * 60);

pub struct FilesystemBackend {
    root: PathBuf,
    hlc: Mutex<HlcGenState>,
}

struct HlcGenState {
    node_id: i32,
    last_physical: i64,
    last_logical: i32,
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
    // spec §8
    fn write(&self, job: &Job) -> Result<(), QueueError> {
        let encoded = encode_job(job);
        let filename = filename_for_job(job);
        let tmp_path = self.tmp_dir().join(&filename);
        let new_path = self.new_dir().join(&filename);

        // Step 3: O_CREAT | O_EXCL
        let mut f = OpenOptions::new()
            .write(true).create_new(true).mode(0o644)
            .open(&tmp_path)
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
        let mut f = OpenOptions::new().write(true).create_new(true)
            .mode(0o644).open(&sig_tmp)
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

    fn in_flight(&self) -> Result<Vec<Job>, QueueError> {
        list_jobs(&self.cur_dir(), None)
    }

    fn completed(&self, stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError> {
        list_jobs(&self.done_dir(), stream_id)
    }

    // spec §3, §4: watch()
    //
    // The notify crate raises an event when a file lands in new/.
    // Each event is treated as a wake signal only; the authoritative
    // claim path is drain_available(), which performs the atomic
    // rename from new/ to cur/. This honours the spec rule that
    // watch() must never short-circuit the claim atomicity.
    #[cfg(feature = "watch")]
    fn watch<F>(&self, handler: F) -> Result<(), QueueError>
    where
        F: Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync,
    {
        use notify::{Config, RecommendedWatcher, RecursiveMode, Watcher};
        use std::sync::mpsc;

        let (tx, rx) = mpsc::channel();
        let mut watcher = RecommendedWatcher::new(tx, Config::default())
            .map_err(|e| QueueError::WatcherFailed(e.to_string()))?;
        watcher
            .watch(self.new_dir().as_path(), RecursiveMode::NonRecursive)
            .map_err(|e| QueueError::WatcherFailed(e.to_string()))?;

        // Drain anything already present before blocking on events,
        // so jobs that arrived between the maildir scan and the
        // watcher attach are not lost.
        for (job, session_id) in self.drain_available()? {
            handler(job, session_id)?;
        }

        loop {
            match rx.recv() {
                Ok(_event) => {
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
    fn watch<F>(&self, _handler: F) -> Result<(), QueueError>
    where
        F: Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync,
    {
        Err(QueueError::BackendUnavailable(
            "watch() requires the 'watch' feature. \
             Enable with --features watch.".to_string()))
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
