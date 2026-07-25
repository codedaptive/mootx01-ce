// drain_lease.rs — stream-keyed heartbeat-TTL drain lease for QueueKit.
//
// A stream-keyed, heartbeat-TTL drain lease. Many processes can open the same
// durable estate and each can start its own drain worker for a given queue
// stream. This lease guarantees exactly ONE drainer per (estate, stream) pair
// runs at a time, while two DIFFERENT streams can each hold their own lease
// simultaneously — enabling the encode drainer and the dreaming drainer to
// run concurrently without blocking each other.
//
// The lease file is keyed by stream: `<dir>/<stream>.drain.lease`, so streams
// are fully independent — both can be acquired at once.
//
// This is a heartbeat-TTL lease, NOT a PID-liveness check. Portable across
// macOS/Windows/Linux: no FFI, no libc/Win32 OpenProcess, no OS-specific
// process table query. The holder refreshes a wall-clock heartbeat on each
// drain pass; a would-be drainer stands down while the lease is fresh and
// takes it over when it goes stale (holder crashed or exited uncleanly) or
// absent. Worst-case takeover latency is one TTL (15 seconds).
//
// This is the SQLite-first form: the lease file lives beside the durable
// maildir. A Postgres-estate DB-backed lease (row lock or advisory lock) is
// deferred while the queue implementation remains SQLite-first.
//
// Wall-clock here is INFRASTRUCTURE (lease liveness), not the deterministic
// drain engine. Same exception that QueueKit's drain telemetry clock takes.
// Mirrors the Swift `DrainLease` in `DrainLease.swift`.

use std::path::{Path, PathBuf};

/// The lease is fresh while its heartbeat is within this many seconds of `now`.
/// Matches Swift's `DrainLease.ttl` default: 15 s.
pub const DRAIN_LEASE_TTL_SECS: f64 = 15.0;

/// The recommended heartbeat interval for drain loops. Callers should call
/// `heartbeat` at this cadence (every ~5 s) to stay well inside the TTL.
/// Matches Swift's `DrainLease.heartbeatInterval`: 5 s < 15 s TTL.
pub const DRAIN_LEASE_HEARTBEAT_SECS: f64 = 5.0;

/// A stream-keyed heartbeat-TTL drain lease.
///
/// One instance per (estate directory, stream) pair. Two different streams
/// produce independent lease files and can both be held simultaneously.
///
/// Owner identity is the caller-supplied token (typically PID + Arc address
/// or similar per-process nonce), so a reused PID after a crash cannot
/// impersonate the prior holder.
pub struct DrainLease {
    /// Lease file: `<directory>/<stream>.drain.lease`.
    /// Each stream gets its own file, so leases are fully independent.
    lease_path: PathBuf,
    /// Per-writer temp sibling for atomic replace (write tmp, then rename),
    /// unique by owner token so two concurrent writers never share a temp
    /// and clobber each other mid-rename.
    tmp_path: PathBuf,
    /// Owner token: typically `"pid-<pid>-<instance_ptr>"`.
    owner: String,
    /// The lease is fresh while its heartbeat is within this window (seconds).
    ttl_secs: f64,
}

impl DrainLease {
    /// Create a new `DrainLease` for a specific stream within an estate directory.
    ///
    /// # Parameters
    /// - `dir`: The durable maildir directory for this queue (beside the estate db).
    /// - `stream`: The stream key (e.g. `"encode"`, `"dreaming"`). Used as the
    ///   lease filename prefix so different streams have independent leases.
    /// - `owner`: A per-process identifier that uniquely identifies this drainer
    ///   instance. Recommended form: `format!("pid-{}-{:p}", std::process::id(), arc_ptr)`.
    /// - `ttl_secs`: Time-to-live for a heartbeat before the lease is reclaimable.
    ///   Defaults to [`DRAIN_LEASE_TTL_SECS`] (15 s) — use `DrainLease::new` for
    ///   the production default, or `DrainLease::with_ttl` to override in tests.
    pub fn new(dir: &Path, stream: &str, owner: String) -> Self {
        Self::with_ttl(dir, stream, owner, DRAIN_LEASE_TTL_SECS)
    }

    /// Create a `DrainLease` with an explicit TTL (primarily for tests with short TTLs).
    pub fn with_ttl(dir: &Path, stream: &str, owner: String, ttl_secs: f64) -> Self {
        // Sanitise the stream key so the filename is safe on all platforms.
        let safe_stream: String = stream
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' })
            .collect();
        // Sanitise the owner token for use in the temp filename (no slashes, spaces).
        let safe_owner: String = owner
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' })
            .collect();
        let lease_path = dir.join(format!("{safe_stream}.drain.lease"));
        let tmp_path = dir.join(format!(".{safe_stream}.drain.lease.tmp.{safe_owner}"));
        Self { lease_path, tmp_path, owner, ttl_secs }
    }

    // MARK: - Public API

    /// Acquire the lease iff it is absent or expired. Returns `true` iff this
    /// drainer holds the lease after the call.
    ///
    /// If another drainer holds a fresh (non-expired) lease, returns `false`
    /// and the caller should stand down. `now_secs` is wall-clock epoch seconds
    /// (infrastructure — pass `wall_now_secs()`).
    pub fn try_acquire(&self, now_secs: f64) -> bool {
        if let Some((held_owner, held_at)) = self.read() {
            if held_owner != self.owner && now_secs - held_at <= self.ttl_secs {
                return false; // fresh and held by another drainer — stand down
            }
        }
        // Absent, ours, or stale → (re)claim, then re-read to resolve a write
        // race: atomic rename is last-writer-win; the losing writer sees the
        // winner's token on re-read and defers.
        self.write(now_secs);
        self.read().map(|(o, _)| o == self.owner).unwrap_or(false)
    }

    /// Refresh the heartbeat while this drainer actively holds the lease.
    ///
    /// Call at [`DRAIN_LEASE_HEARTBEAT_SECS`] cadence (every ~5 s) while
    /// draining to prevent the lease expiring during a slow drain pass. Does
    /// not check ownership — the caller is responsible for only heartbeating
    /// when it successfully acquired.
    pub fn heartbeat(&self, now_secs: f64) {
        self.write(now_secs);
    }

    /// Whether another drainer currently holds a fresh (non-expired) lease.
    ///
    /// Returns `true` iff the lease file exists, its heartbeat is within the
    /// TTL, and its owner is not this drainer.
    pub fn is_held_by_other(&self, now_secs: f64) -> bool {
        match self.read() {
            Some((owner, at)) => owner != self.owner && now_secs - at <= self.ttl_secs,
            None => false,
        }
    }

    /// Release the lease on clean teardown. Removes the lease file so another
    /// drainer can take over immediately rather than waiting out the TTL.
    /// Only removes the file if this drainer still holds it.
    pub fn release(&self) {
        if self.read().map(|(o, _)| o == self.owner).unwrap_or(false) {
            let _ = std::fs::remove_file(&self.lease_path);
        }
    }

    // MARK: - File I/O — format: `<owner>\n<epochSeconds>`

    fn read(&self) -> Option<(String, f64)> {
        let text = std::fs::read_to_string(&self.lease_path).ok()?;
        let mut lines = text.splitn(2, '\n');
        let owner = lines.next()?.to_string();
        let at: f64 = lines.next()?.trim().parse().ok()?;
        Some((owner, at))
    }

    fn write(&self, now_secs: f64) {
        let body = format!("{}\n{}", self.owner, now_secs);
        // Atomic replace: write a per-writer temp then rename so a concurrent
        // reader never sees a torn file. Per-owner tmp path prevents two
        // concurrent writers from clobbering each other's temp mid-rename.
        //
        // P9-secfix (Windows): std::fs::rename returns Err when the destination
        // already exists on Windows (ERROR_ALREADY_EXISTS / ERROR_ACCESS_DENIED).
        // POSIX guarantees an atomic replace. Work around the Windows gap:
        // attempt rename; on failure remove the stale destination and retry.
        // This is not fully atomic on Windows (window between remove and rename)
        // but is the idiomatic cross-platform approximation — the same window
        // exists in every Windows file-copy utility. On POSIX the first rename
        // always succeeds and the retry branch is dead code.
        if std::fs::write(&self.tmp_path, body.as_bytes()).is_ok() {
            if std::fs::rename(&self.tmp_path, &self.lease_path).is_err() {
                // Windows fallback: remove stale destination before rename.
                let _ = std::fs::remove_file(&self.lease_path);
                let _ = std::fs::rename(&self.tmp_path, &self.lease_path);
            }
        }
    }
}

/// Wall-clock epoch seconds for lease timestamps. Infrastructure only — not
/// used in the deterministic drain engine (same exception as `drain_telemetry_now`
/// in `corpus_ingest_queue.rs`).
pub fn wall_now_secs() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Create a temporary directory for one test, cleaned up on drop.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let dir = std::env::temp_dir()
                .join(format!("drain_lease_test_{}", uuid_simple()));
            fs::create_dir_all(&dir).unwrap();
            TempDir(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// A simple deterministic "UUID" for temp dirs — no uuid crate dependency here
    /// (we rely on process id + a counter for uniqueness in tests).
    fn uuid_simple() -> String {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        format!("{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed))
    }

    // Deterministic time base — all tests offset from here, no real wall clock.
    const T0: f64 = 1_700_000_000.0;

    /// Acquire on a free lease succeeds.
    #[test]
    fn acquire_on_free_lease() {
        let dir = TempDir::new();
        let lease = DrainLease::new(dir.path(), "encode", "owner-a".to_string());
        assert!(lease.try_acquire(T0));
    }

    /// While one drainer holds a fresh lease, a second owner cannot acquire.
    /// `is_held_by_other` returns true for the blocked drainer.
    #[test]
    fn second_owner_blocked_while_lease_held() {
        let dir = TempDir::new();
        let owner1 = DrainLease::new(dir.path(), "encode", "owner-1".to_string());
        let owner2 = DrainLease::new(dir.path(), "encode", "owner-2".to_string());

        assert!(owner1.try_acquire(T0));
        assert!(!owner2.try_acquire(T0));
        assert!(owner2.is_held_by_other(T0));
    }

    /// After the TTL elapses with no heartbeat, the lease is re-acquirable.
    #[test]
    fn expired_lease_is_reacquirable() {
        let dir = TempDir::new();
        let ttl = 0.1_f64;
        let owner1 = DrainLease::with_ttl(dir.path(), "encode", "owner-1".to_string(), ttl);
        let owner2 = DrainLease::with_ttl(dir.path(), "encode", "owner-2".to_string(), ttl);

        assert!(owner1.try_acquire(T0));

        // Advance past TTL.
        let expired = T0 + 1.0;
        assert!(owner2.try_acquire(expired));
        // Owner1 is no longer the holder.
        assert!(owner1.is_held_by_other(expired));
    }

    /// Heartbeat keeps the lease held across what would otherwise be expiry.
    #[test]
    fn heartbeat_keeps_lease_held() {
        let dir = TempDir::new();
        let ttl = 0.5_f64;
        let owner1 = DrainLease::with_ttl(dir.path(), "encode", "owner-1".to_string(), ttl);
        let owner2 = DrainLease::with_ttl(dir.path(), "encode", "owner-2".to_string(), ttl);

        assert!(owner1.try_acquire(T0));

        // Heartbeat at T0 + 0.3 s (within TTL from T0, but past half).
        let t1 = T0 + 0.3;
        owner1.heartbeat(t1);

        // At T0 + 0.7 s the original heartbeat (T0) would have expired,
        // but the refreshed heartbeat (t1 = T0+0.3) is still within TTL.
        let t2 = T0 + 0.7; // t2 - t1 = 0.4 s < 0.5 s TTL
        assert!(!owner2.try_acquire(t2));
        assert!(owner2.is_held_by_other(t2));
    }

    /// Two different stream keys yield independent leases — both acquirable
    /// simultaneously. This is the key behavior for concurrent encode+dreaming
    /// drainers.
    #[test]
    fn independent_streams_both_acquirable() {
        let dir = TempDir::new();
        let encode  = DrainLease::new(dir.path(), "encode",   "owner-enc".to_string());
        let dreaming = DrainLease::new(dir.path(), "dreaming", "owner-drm".to_string());

        // Both streams can be acquired at the same time by different owners.
        assert!(encode.try_acquire(T0));
        assert!(dreaming.try_acquire(T0));

        // Each holder does not see the other stream as "held by other".
        assert!(!encode.is_held_by_other(T0));   // owner-enc holds "encode"
        assert!(!dreaming.is_held_by_other(T0)); // owner-drm holds "dreaming"

        // A third party on the encode stream sees it held.
        let observer = DrainLease::new(dir.path(), "encode", "observer".to_string());
        assert!(observer.is_held_by_other(T0));
        assert!(!observer.try_acquire(T0));
    }

    /// Release frees the lease immediately (not after TTL).
    #[test]
    fn release_frees_lease_immediately() {
        let dir = TempDir::new();
        let owner1 = DrainLease::new(dir.path(), "encode", "owner-1".to_string());
        let owner2 = DrainLease::new(dir.path(), "encode", "owner-2".to_string());

        assert!(owner1.try_acquire(T0));
        owner1.release();

        // Immediately after release, owner2 can acquire.
        assert!(owner2.try_acquire(T0));
    }

    /// Release by a non-holder is a no-op and does not remove the lease file.
    #[test]
    fn release_by_non_holder_is_noop() {
        let dir = TempDir::new();
        let owner1    = DrainLease::new(dir.path(), "encode", "owner-1".to_string());
        let interloper = DrainLease::new(dir.path(), "encode", "interloper".to_string());

        assert!(owner1.try_acquire(T0));
        interloper.release(); // no-op — interloper doesn't hold it

        // owner1 still holds it
        assert!(interloper.is_held_by_other(T0));
    }

    /// `is_held_by_other` returns false when no lease file exists.
    #[test]
    fn is_held_by_other_false_when_absent() {
        let dir = TempDir::new();
        let lease = DrainLease::new(dir.path(), "encode", "owner-a".to_string());
        assert!(!lease.is_held_by_other(T0));
    }

    /// The heartbeat interval constant is less than the TTL constant — a
    /// continuously-heartbeating drainer never lets its lease expire.
    #[test]
    fn heartbeat_interval_less_than_ttl() {
        assert!(DRAIN_LEASE_HEARTBEAT_SECS < DRAIN_LEASE_TTL_SECS);
    }

    /// The two independent stream lease files have distinct paths on disk.
    #[test]
    fn stream_lease_files_have_distinct_paths() {
        let dir = TempDir::new();
        let encode   = DrainLease::new(dir.path(), "encode",   "owner".to_string());
        let dreaming = DrainLease::new(dir.path(), "dreaming", "owner".to_string());
        assert_ne!(encode.lease_path, dreaming.lease_path);
        assert!(encode.lease_path.to_str().unwrap().contains("encode.drain.lease"));
        assert!(dreaming.lease_path.to_str().unwrap().contains("dreaming.drain.lease"));
    }
}
