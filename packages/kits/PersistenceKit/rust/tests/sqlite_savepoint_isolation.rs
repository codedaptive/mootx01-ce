// SV-01 — SQLite savepoint nesting transaction-isolation coverage.
//
// Codex finding (introduced by 6751fc618, still present at HEAD e1f4ca4b9):
// the Rust SQLite backend's savepoint nesting does not respect transaction
// boundaries in all cases, so a caller that believes it wrapped a
// multi-step write in an isolated transaction can end up with a partial
// commit, or have an inner rollback discard more (or less) than intended.
//
// Investigation summary: the SAME-THREAD nesting mechanism 6751fc618 added
// (`Inner::nest_begin`/`nest_commit`/`nest_rollback`, driven by
// `Inner::tx_depth` and per-depth `SAVEPOINT tx_{depth}` names) is
// call-stack-correct — an inner rollback undoes only the inner scope, an
// inner release does not commit the outer scope, and an outer rollback
// undoes everything inside it, verified directly against this file's own
// reproduction before any fix was applied.
//
// The actual defect is cross-thread: `Storage::transaction` was the only
// entry point that serialized itself against concurrent callers (the old
// `tx_lock: Mutex<()>`, held for the whole bracket). `RowStore::
// begin_transaction`/`commit_transaction`/`rollback_transaction` and
// `DatasetStore::append_rows` each locked `Inner` only for the duration of
// a single nest_begin/nest_commit/nest_rollback call — not for the whole
// bracket — so an unrelated thread's independent begin/commit pair could
// interleave through the shared connection and get silently absorbed as a
// SAVEPOINT nested inside another thread's still-open `transaction()`
// bracket, then get discarded by that bracket's later rollback even
// though the second caller believed its own work had already committed.
//
// Every test below pairs one thread ("A") driving a same-thread nesting
// pattern with a second thread ("B") that opens and closes its own,
// logically independent bracket via the explicit begin/commit API while
// A's bracket is open. The discriminating assertion is temporal: B's
// bracket must never observe A's bracket as still open — i.e. B's
// `begin_transaction()` call must not return successfully until A's
// bracket has fully closed (whether by commit or rollback). Before the
// SV-01 fix this does not hold (B proceeds immediately, unserialized);
// after the fix, `TxCoordinator` blocks B in `begin_transaction()` until
// A's bracket depth returns to zero.
//
// Part 3 (below Part 1) broadens coverage per mission: two levels of
// nesting, inner failure with outer success, outer failure discarding a
// successful inner scope, and sequential sibling inner scopes — each
// crossed with the same concurrent-unrelated-thread check, since that is
// the axis the fix actually touches (same-thread nesting semantics were
// already correct pre-fix; verified by reverting sqlite.rs's fix commit
// locally and re-running this file — all five tests failed on the
// temporal assertion, none on the same-thread row-presence assertions).

use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, EstateConfiguration, IsolationLevel,
    SchemaDeclaration, SqliteStorage, Storage, StorageError, TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};
use uuid::Uuid;

/// How long thread A holds its bracket open past the point where thread B
/// is released to attempt its own bracket. Long enough that B's unguarded
/// begin/insert/commit sequence (microseconds on an in-process SQLite
/// connection) reliably completes inside the window pre-fix, without
/// making the suite slow.
const HOLD_OPEN: Duration = Duration::from_millis(150);

fn make_storage() -> Arc<dyn Storage> {
    let path = std::env::temp_dir().join(format!("pk_sv01_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");
    let schema = SchemaDeclaration::new(
        "Sv01IsolationKit",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![ColumnDeclaration::uuid("id"), ColumnDeclaration::text("name")],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open schema");
    Arc::from(storage)
}

fn row(name: &str) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".into(), TypedValue::Uuid(Uuid::new_v4()));
    m.insert("name".into(), TypedValue::Text(name.into()));
    m
}

fn names_in(storage: &Arc<dyn Storage>) -> Vec<String> {
    storage
        .row_store()
        .query("items", None, &[], None, None)
        .expect("query")
        .iter()
        .map(|r| match r.values.get("name") {
            Some(TypedValue::Text(s)) => s.clone(),
            _ => "?".into(),
        })
        .collect()
}

/// Run thread B's independent bracket: a plain begin/insert/commit via the
/// explicit RowStore API, timestamped on either side of `begin_transaction`
/// and `commit_transaction` so the caller can assert non-overlap with A's
/// bracket. `start_after` gates B until A's bracket is confirmed open.
fn run_independent_bracket(
    storage: Arc<dyn Storage>,
    start_after: Arc<Barrier>,
    label: &'static str,
) -> thread::JoinHandle<(Instant, Instant)> {
    thread::spawn(move || {
        start_after.wait();
        let rows = storage.row_store();
        rows.begin_transaction().expect("B begin_transaction");
        let opened_at = Instant::now();
        rows.insert("items", row(label)).expect("B insert");
        rows.commit_transaction().expect("B commit_transaction");
        let closed_at = Instant::now();
        (opened_at, closed_at)
    })
}

// ─────────────────────────────────────────────────────────────────────
// Part 1 — grounding reproduction.
//
// "Nest transaction scopes, fail the inner one, and assert the outer
// scope's atomicity guarantee." The same-thread nesting itself already
// isolates the inner failure correctly (see the `outer_a`/`outer_c`
// present, `inner_b` absent assertions below — these hold even against
// the pre-fix code). What does NOT hold pre-fix is thread B's isolation
// from thread A's open bracket: B's independent commit gets absorbed into
// A's still-open transaction and is not safe from A's later operations.
// ─────────────────────────────────────────────────────────────────────
#[test]
fn sqlite_inner_failure_preserves_outer_and_unrelated_thread_isolation() {
    let storage = make_storage();
    let a_open_barrier = Arc::new(Barrier::new(2));
    let a_open_barrier_a = a_open_barrier.clone();

    let storage_b = storage.clone();
    let b_handle = run_independent_bracket(storage_b, a_open_barrier, "independent-b");

    let a_close_at = {
        let storage = storage.clone();
        thread::spawn(move || {
            storage
                .transaction(IsolationLevel::Serializable, &mut |tx| {
                    let rows = tx.row_store();
                    rows.insert("items", row("outer-a"))?;
                    // Nested scope via the explicit begin/commit/rollback API.
                    rows.begin_transaction()?;
                    rows.insert("items", row("inner-b"))?;
                    rows.rollback_transaction()?; // inner fails
                    rows.insert("items", row("outer-c"))?;
                    // Signal B that A's bracket is open (A is still inside
                    // it — the transaction() block hasn't returned yet), then
                    // hold the bracket open so B can race in before A closes.
                    a_open_barrier_a.wait();
                    thread::sleep(HOLD_OPEN);
                    Ok(())
                })
                .expect("outer commit");
            Instant::now()
        })
        .join()
        .expect("thread A panicked")
    };

    let (b_opened_at, _b_closed_at) = b_handle.join().expect("thread B panicked");

    let names = names_in(&storage);
    assert!(names.contains(&"outer-a".to_string()));
    assert!(names.contains(&"outer-c".to_string()));
    assert!(
        !names.contains(&"inner-b".to_string()),
        "inner rollback must not leave inner-b visible; got {names:?}"
    );
    assert!(
        names.contains(&"independent-b".to_string()),
        "thread B's independently committed row must survive; got {names:?}"
    );
    assert!(
        b_opened_at >= a_close_at,
        "thread B's begin_transaction() must not return until thread A's \
         transaction() bracket has fully closed — B opened at {b_opened_at:?}, \
         A closed at {a_close_at:?} (B opened before A closed: B's bracket \
         was silently absorbed into A's still-open transaction instead of \
         being serialized behind it)"
    );
}

// ─────────────────────────────────────────────────────────────────────
// Part 3 — nesting matrix.
// ─────────────────────────────────────────────────────────────────────

/// Two levels of nesting, both succeeding, with a concurrent unrelated
/// bracket from a second thread.
#[test]
fn sqlite_two_levels_of_nesting_isolates_unrelated_thread() {
    let storage = make_storage();
    let a_open_barrier = Arc::new(Barrier::new(2));
    let a_open_barrier_a = a_open_barrier.clone();

    let storage_b = storage.clone();
    let b_handle = run_independent_bracket(storage_b, a_open_barrier, "independent-two-level");

    let a_close_at = {
        let storage = storage.clone();
        thread::spawn(move || {
            storage
                .transaction(IsolationLevel::Serializable, &mut |tx| {
                    let rows = tx.row_store();
                    rows.insert("items", row("level1"))?;
                    rows.begin_transaction()?; // level 2
                    rows.insert("items", row("level2"))?;
                    rows.commit_transaction()?; // release level 2 into level 1
                    a_open_barrier_a.wait();
                    thread::sleep(HOLD_OPEN);
                    Ok(())
                })
                .expect("two-level commit");
            Instant::now()
        })
        .join()
        .expect("thread A panicked")
    };
    let (b_opened_at, _) = b_handle.join().expect("thread B panicked");

    let names = names_in(&storage);
    assert!(names.contains(&"level1".to_string()));
    assert!(names.contains(&"level2".to_string()));
    assert!(
        names.contains(&"independent-two-level".to_string()),
        "thread B's row must survive; got {names:?}"
    );
    assert!(
        b_opened_at >= a_close_at,
        "B must not open until A's two-level bracket fully closes \
         (B opened {b_opened_at:?}, A closed {a_close_at:?})"
    );
}

/// Inner failure with outer success: the inner scope's rollback must not
/// touch the outer scope's already-written rows, and the outer commit must
/// still land — alongside a concurrent unrelated bracket.
#[test]
fn sqlite_inner_failure_outer_success_isolates_unrelated_thread() {
    let storage = make_storage();
    let a_open_barrier = Arc::new(Barrier::new(2));
    let a_open_barrier_a = a_open_barrier.clone();

    let storage_b = storage.clone();
    let b_handle = run_independent_bracket(storage_b, a_open_barrier, "independent-inner-fail");

    let a_close_at = {
        let storage = storage.clone();
        thread::spawn(move || {
            storage
                .transaction(IsolationLevel::Serializable, &mut |tx| {
                    let rows = tx.row_store();
                    rows.insert("items", row("outer-success-pre"))?;
                    rows.begin_transaction()?;
                    rows.insert("items", row("inner-doomed"))?;
                    rows.rollback_transaction()?;
                    rows.insert("items", row("outer-success-post"))?;
                    a_open_barrier_a.wait();
                    thread::sleep(HOLD_OPEN);
                    Ok(())
                })
                .expect("outer must still succeed");
            Instant::now()
        })
        .join()
        .expect("thread A panicked")
    };
    let (b_opened_at, _) = b_handle.join().expect("thread B panicked");

    let names = names_in(&storage);
    assert!(names.contains(&"outer-success-pre".to_string()));
    assert!(names.contains(&"outer-success-post".to_string()));
    assert!(!names.contains(&"inner-doomed".to_string()));
    assert!(
        names.contains(&"independent-inner-fail".to_string()),
        "thread B's row must survive; got {names:?}"
    );
    assert!(
        b_opened_at >= a_close_at,
        "B must not open until A's bracket fully closes \
         (B opened {b_opened_at:?}, A closed {a_close_at:?})"
    );
}

/// Outer failure discarding a successful inner scope: the inner scope's
/// release merges into the outer bracket (not durable on its own), so the
/// outer rollback must discard it too — alongside a concurrent unrelated
/// bracket, which must survive independently of A's rollback.
#[test]
fn sqlite_outer_failure_discards_inner_and_isolates_unrelated_thread() {
    let storage = make_storage();
    let a_open_barrier = Arc::new(Barrier::new(2));
    let a_open_barrier_a = a_open_barrier.clone();

    let storage_b = storage.clone();
    let b_handle = run_independent_bracket(storage_b, a_open_barrier, "independent-outer-fail");

    let a_close_at = {
        let storage = storage.clone();
        thread::spawn(move || {
            let result = storage.transaction(IsolationLevel::Serializable, &mut |tx| {
                let rows = tx.row_store();
                rows.insert("items", row("doomed-outer"))?;
                rows.begin_transaction()?;
                rows.insert("items", row("doomed-inner-released"))?;
                rows.commit_transaction()?; // released into the (still open) outer
                a_open_barrier_a.wait();
                thread::sleep(HOLD_OPEN);
                Err(StorageError::BackendError {
                    underlying: "intentional outer rollback".into(),
                })
            });
            assert!(result.is_err(), "outer block must surface its Err");
            Instant::now()
        })
        .join()
        .expect("thread A panicked")
    };
    let (b_opened_at, _) = b_handle.join().expect("thread B panicked");

    let names = names_in(&storage);
    assert!(
        !names.contains(&"doomed-outer".to_string()),
        "outer rollback must discard the outer scope's own write; got {names:?}"
    );
    assert!(
        !names.contains(&"doomed-inner-released".to_string()),
        "outer rollback must discard the released-but-not-yet-committed \
         inner scope too; got {names:?}"
    );
    assert!(
        names.contains(&"independent-outer-fail".to_string()),
        "thread B's independently committed row must survive A's outer \
         rollback; got {names:?}"
    );
    assert!(
        b_opened_at >= a_close_at,
        "B must not open until A's bracket fully closes \
         (B opened {b_opened_at:?}, A closed {a_close_at:?})"
    );
}

/// Sequential sibling inner scopes: two nested brackets opened one after
/// the other (not overlapping) inside the same outer bracket. The first
/// sibling's release must survive; the second sibling's rollback must not
/// touch the first sibling's or the outer's writes — alongside a
/// concurrent unrelated bracket.
#[test]
fn sqlite_sequential_sibling_inner_scopes_isolate_unrelated_thread() {
    let storage = make_storage();
    let a_open_barrier = Arc::new(Barrier::new(2));
    let a_open_barrier_a = a_open_barrier.clone();

    let storage_b = storage.clone();
    let b_handle = run_independent_bracket(storage_b, a_open_barrier, "independent-siblings");

    let a_close_at = {
        let storage = storage.clone();
        thread::spawn(move || {
            storage
                .transaction(IsolationLevel::Serializable, &mut |tx| {
                    let rows = tx.row_store();
                    rows.begin_transaction()?;
                    rows.insert("items", row("sibling-a-committed"))?;
                    rows.commit_transaction()?; // sibling A releases first

                    rows.begin_transaction()?;
                    rows.insert("items", row("sibling-b-rolled-back"))?;
                    rows.rollback_transaction()?; // sibling B, opened after A closed

                    a_open_barrier_a.wait();
                    thread::sleep(HOLD_OPEN);
                    Ok(())
                })
                .expect("outer commit");
            Instant::now()
        })
        .join()
        .expect("thread A panicked")
    };
    let (b_opened_at, _) = b_handle.join().expect("thread B panicked");

    let names = names_in(&storage);
    assert!(names.contains(&"sibling-a-committed".to_string()));
    assert!(!names.contains(&"sibling-b-rolled-back".to_string()));
    assert!(
        names.contains(&"independent-siblings".to_string()),
        "thread B's row must survive; got {names:?}"
    );
    assert!(
        b_opened_at >= a_close_at,
        "B must not open until A's bracket fully closes \
         (B opened {b_opened_at:?}, A closed {a_close_at:?})"
    );
}
