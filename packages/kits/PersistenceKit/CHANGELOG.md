# PersistenceKit Changelog

## 2026-06-28 — SECFIX-C-SQLITE-INJECT: SQLite identifier injection + DB file hardening (HIGH + MEDIUM)

**Branch:** `secfix/c-sqlite-inject`

**Security classification:** HIGH (CAND-047) + MEDIUM (CAND-052)

### CAND-047 (HIGH) — SQLite SQL-identifier injection on insert/upsert/update (both ports)

**Surface:** `sqlite.rs::SqliteStorage::insert/upsert/update` (Rust) + `SQLiteStorage.insertRow/upsertRow/updateRows` (Swift)

**Finding:** The SQLite backend interpolated caller-supplied column names from
`values.keys()` and `conflict_columns` directly into INSERT, upsert ON CONFLICT,
and UPDATE SET SQL strings without validation. A column name containing `"` or
`;` could escape double-quote delimiters and alter the query
(SQL-identifier injection). The PostgreSQL backend and the `queryProjected` path
were already guarded; the write paths were not.

**Fix:** Both ports — call the EXISTING shared validator (`validate_sql_identifier`
in Rust `error.rs`; `validateSQLIdentifier` in Swift `SQLiteStorage`) on every
caller-supplied column name before any SQL is constructed. This is the same
validator already used by `queryProjected` and the Postgres backend — one seam,
no forked copy. Reject with `StorageError::InvalidIdentifier` / `StorageError.invalidIdentifier`.
11 new Rust regression tests; 10 new Swift regression tests covering all three
write paths and the projected-read regression.

### CAND-052 (MEDIUM) — SQLite estate DB file not verified private / symlink-resistant

**Surface:** `sqlite.rs::SqliteStorage::new` (Rust) + `SQLiteConnection.init` (Swift)

**Finding:** The DB file open/create path called `Connection::open`/`sqlite3_open_v2`
without checking for a pre-planted symlink at the DB path. A symlink could
redirect all SQLite writes to an arbitrary file. New DB files were created with
whatever permissions the process umask produced (typically 0644), making them
readable by other OS users.

**Fix:**
- Rust: before `Connection::open`, call `symlink_metadata` (lstat). If the path
  exists and is a symlink, reject with `StorageError::BackendError`. After a
  successful open of a NEW file, set permissions to 0600 (Unix, best-effort).
- Swift: before `sqlite3_open_v2`, query `resourceValues(forKeys: [.isSymbolicLinkKey])`
  (lstat semantics). If the result is a symlink, throw `StorageError.backendError`.
  Apple Data Protection (`.completeUntilFirstUserAuthentication`) is already applied
  post-open and covers the file at rest; the symlink check is an orthogonal guard
  for the redirection attack surface.
3 new Rust regression tests; 2 new Swift regression tests.

**SPEC:** Added SPEC I-21 (identifier validation contract) and I-22 (symlink
refusal + 0600 creation mode) to `PERSISTENCEKIT_SPEC.md` (v1.6.0). Added
`StorageError.invalidIdentifier` to `PERSISTENCEKIT_INTERFACE.md` (v1.6.0).

## 2026-06-28 — SECFIX-C-PG-TLS-DOWNGRADE: Rust PostgreSQL TLS no-downgrade fix (HIGH)

**Branch:** `secfix/c-pg-tls-downgrade`

**Security classification:** HIGH — silent TLS downgrade of operator-specified
security boundaries.

### CAND-029 (c-pg-tls-downgrade) — No-downgrade guarantee for DSN sslmode

**Surface:** `postgres.rs::Pool::open_connection` + `postgres_tls.rs` (Rust)

**Finding:** `open_connection` called `set_sslmode(conn_str, env_mode_str)`
unconditionally, replacing any existing `sslmode=` in the operator's
connection string. When the env var `ARIA_MCP_POSTGRES_TLS` was absent
(defaulting to `Prefer`), a DSN containing `sslmode=require` was silently
rewritten to `sslmode=prefer` — downgrading a mandatory-TLS boundary to
TLS-optional/plaintext-fallback. The code comment claiming "Never silently
downgrades from Require" described the intended behaviour, not the actual
behaviour.

**Fix:** Replaced `set_sslmode` with `effective_sslmode(conn_str, env_mode)`
in `postgres_tls.rs`. The effective sslmode is `max(env_rank, dsn_rank)` using
a six-level security ranking (`disable < allow < prefer < require < verify-ca <
verify-full`). The env var may raise the security level above the DSN's but
may never lower an operator-specified floor. Connector selection follows the
effective mode (not the raw env mode), closing the secondary case where
`env=Disable` + `DSN sslmode=require` would have produced a plaintext
connection.

Unrecognised DSN sslmode values (future libpq values) are preserved verbatim
and force TLS connector selection — conservative handling.

**Changes:**
- `postgres_tls.rs`: New `SslModeRank` enum (pub, derives Ord for security
  ordering) + `effective_sslmode` (pub fn) + private `dsn_sslmode_str` helper
  + private `set_sslmode_in_str` (renamed from the old `set_sslmode` in
  postgres.rs, now called only when raising the mode).
- `postgres.rs`: `open_connection` replaced three-arm `match tls_mode` with
  a single `effective_sslmode` call. Stale comment claiming "Never silently
  downgrades" replaced with accurate description of the new behaviour.
- `secfix_tests.rs`: 13 new pure-function tests covering the full truth table:
  preserve DSN require, preserve verify-full, raise prefer to require,
  env=Disable yields NoTls only when DSN has no floor, URL/DSN append forms,
  SslModeRank ordering, round-trips, and unrecognised-value handling.

**Parity:** Swift `PostgreSQLPool.swift` parses connection strings structurally
(`parseConnectionString` extracts host/port/user/password/database from the
URL) and never reads a `sslmode=` parameter from the DSN. TLS mode comes
exclusively from the env var via `parseTLSMode(host:)`. The Swift side has no
equivalent downgrade path — **no Swift change needed**.

**Test counts:**
- Rust: 272 (was 259 — added 13 pure-function tests in secfix_tests.rs)
- Swift: build complete, no test regressions

---

## 2026-06-28 — SECFIX-C-PG-TLS: Rust PostgreSQL TLS transport wired (CAND-029 completion)

**Branch:** `secfix/c-pg-tls`

**Security classification:** MEDIUM — planned hardening completion.

Completes CAND-029 for the Rust port. The Swift side shipped a full TLS
transport in SECFIX-C-PG-DBKEY; the Rust side had the `PostgresTlsMode`
knob but `Pool::open_connection` was fail-closed for `Prefer`/`Require`
pending a C-1 per-crate exception. That exception is now approved.

### CAND-029 — Rust PostgreSQL TLS transport (completion)

**Surface:** `postgres.rs::Pool::open_connection` (Rust)

**Fix:** `postgres-native-tls = "0.5"` added to `Cargo.toml` (C-1
exception recorded in `DECISION_RUST_POSTGRES_TLS_CRATE_2026-06-28.md`).
`Pool::open_connection` now selects the transport via a `match` on
`PostgresTlsMode`:

- `Disable` → `NoTls` (unchanged — plaintext, loopback/Unix-socket only)
- `Prefer` → `MakeTlsConnector` (platform TLS) + `sslmode=prefer` in the
  connection string. Attempts TLS; falls back to plaintext if the server
  declines. Mirrors Swift's `.prefer(NIOSSLContext)`.
- `Require` → `MakeTlsConnector` + `sslmode=require`. TLS mandatory; fails
  closed if the server does not offer TLS. Mirrors Swift's `.require(context)`.

The fail-closed `dep_required_error()` stub has been removed.
`postgres_tls.rs` module doc updated to reflect approved-and-wired status.

**Parity:** Rust `disable`/`prefer`/`require` semantics now match Swift
NIOSSL `disable`/`prefer`/`require` semantics. Default remains `prefer`.

**Tests added/extended:**
- `postgres_tls_mode_env_parsing` (secfix_tests.rs) extended with transport-
  wired assertions: Prefer/Require now return `BackendError` (connection
  refused against 127.0.0.1:9999) rather than `InvalidConfiguration`. This
  proves the transport is compiled in and the fail-closed stub is removed.

**Test counts:**
- Rust: 259 (was 259 — same count; test extended, not split)

---

## 2026-06-28 — SECFIX-C-PG-DBKEY: Planned security hardening (CAND-052/055, CAND-047, CAND-029)

**Branch:** `secfix/c-pg-dbkey`

**Security classification:** MEDIUM — desktop audit revalidation at HEAD.

Three planned hardening items: db.key creation race, PostgreSQL identifier
injection gap, and PostgreSQL TLS configuration knob. Both ports. Framed as
a planned lockdown of data security surfaces.

### CAND-052/055 — db.key atomic creation (F-key)

**Surface:** `encryption.rs::load_or_create_install_key` (Rust). Swift uses
Apple Keychain (`KeychainKeyStore.swift`) which is inherently atomic — no
change needed on the Swift side.

The Rust db.key was written with `std::fs::write` then `chmod 0600` applied
afterward, leaving a race window where the file was world/group-readable for
a brief interval. Additionally, `std::fs::write` follows symlinks, so a
pre-planted symlink at the key path was exploitable.

**Fix:** Replaced the two-step write+chmod with a single atomic
`OpenOptions::new().write(true).create_new(true).mode(0o600).open()` call.
On Unix, `create_new(true)` maps to `O_CREAT | O_EXCL`: the inode is created
with mode 0600 before the directory entry is visible, eliminating the race
window. `O_EXCL` also refuses to follow a symlink at the final path
component, blocking the pre-planted symlink attack.

The creation logic was extracted to `create_key_file_atomic()` for
independent testability.

**Regression tests added:**
- `key_file_permissions_are_0600_at_creation` — verifies mode 0o600 using
  `std::fs::metadata().permissions().mode()` immediately after creation.
- `key_file_creation_refuses_pre_planted_symlink` — plants a dangling symlink
  at the key path and verifies that `ensure_install_key` returns `Err`, with
  the symlink still present afterward.

### CAND-047 — PostgreSQL identifier injection gap (F2)

**Surfaces:**
- `postgres.rs::PgRowStore::query_projected` (Rust) — missing guard
- `PostgreSQLStores.swift::PostgreSQLRowStore.insert/upsert/update` (Swift)

The SQLite backend and `TxRowStore::query_projected` (Rust) already validate
caller-supplied column names via `validate_sql_identifier` / `validateSQLIdentifier`.
`PgRowStore::query_projected` lacked the equivalent guard and interpolated
unvalidated column names directly into `SELECT "col" FROM "table"`.

The Swift Postgres backend's `insert`, `upsert`, and `update` methods built
`INSERT INTO … (colList)` and `UPDATE … SET col = $n` from `values.keys`
without any identifier check.

**Fix (Rust):** Added `for c in columns { validate_sql_identifier(c)?; }` at
the top of `PgRowStore::query_projected`, mirroring the guard in
`TxRowStore::query_projected`.

**Fix (Swift):** Added `validatePSQLIdentifier(_:)` (private, byte-identical
to SQLite's `validateSQLIdentifier`) to `PostgreSQLRowStore`; called at the
top of `insert`, `upsert`, and `update` for each column key. `conflictColumns`
in `upsert` are also validated.

### CAND-029 — PostgreSQL TLS disabled (F3)

**Surfaces:**
- `PostgreSQLPool.swift::parseConnectionString` (Swift) — hardcoded `.disable`
- `postgres.rs::Pool::open_connection` (Rust) — hardcoded `NoTls`

**Fix (Swift):** Added `parseTLSMode(host:)` and `makeTLSContext()` to
`PostgreSQLPool`. Reads `ARIA_MCP_POSTGRES_TLS` env var; maps `disable` →
`.disable`, `require` → `.require(NIOSSLContext)`, anything else (including
absent) → `.prefer(NIOSSLContext)`. The default is `prefer` — encrypts when
the server agrees, no connection failure on legacy servers. `NIOSSL` is
already a transitive dep (PostgresNIO requires `swift-nio-ssl`); made explicit
in `PersistenceKitPostgreSQL` target deps in `Package.swift`.

**Fix (Rust):** Added `postgres_tls.rs` module with `PostgresTlsMode` enum
and `from_env()` parser. Wired into `Pool::open_connection`. At this point,
`Prefer` and `Require` returned `StorageError::InvalidConfiguration` (fail-
closed placeholder pending C-1 dep approval). The full transport was
completed in stream `secfix/c-pg-tls` — see the entry above.

**Regression tests added:**
- Rust `secfix_tests.rs`: `postgres_tls_mode_env_defaults_to_prefer`,
  `postgres_tls_mode_env_disable`, `postgres_tls_mode_env_require`,
  `postgres_tls_mode_env_prefer_explicit`,
  `postgres_tls_mode_env_unknown_value_defaults_to_prefer` (5 tests),
  `pg_identifier_guard_rejects_double_quote`,
  `pg_identifier_guard_rejects_whitespace`,
  `pg_identifier_guard_accepts_valid_names` (3 tests),
  `key_file_permissions_are_0600_at_creation`,
  `key_file_creation_refuses_pre_planted_symlink` (2 tests).
- Swift `PostgreSQLSecurityTests.swift`: 7 tests covering identifier guard
  and TLS mode env-var contract.

**Test counts after hardening:**
- Swift: 343 (was 336, +7)
- Rust: 263 (was 253, +10)

---

## 2026-06-28 — SECFIX-QUEUE-ISOLATION: Per-estate queue isolation (ADR-021 D7)

**Branch:** `secfix/queue-isolation`

**Security classification:** HIGH — cross-estate isolation defect.

`EstateConfiguration.queueSibling(filename:)` (Swift) and
`EstateConfiguration::queue_sibling` (Rust) previously derived the queue
sibling file path by replacing only the last path component with the caller's
literal `"queue.sqlite"` filename. For two estates in the same directory
(`<dir>/<uuidA>.sqlite`, `<dir>/<uuidB>.sqlite`), both produced the same
`<dir>/queue.sqlite` — one shared queue. A CorpusKit encode-drain worker for
estate B could claim estate A's encode jobs, enabling cross-estate corpus
disclosure and corruption.

**Fix:** The sibling filename is now derived as `<estate-stem>.<filename>`
(e.g. `<dir>/<uuidA>.sqlite` + `"queue.sqlite"` → `<dir>/<uuidA>.queue.sqlite`).
Same estate across processes = deterministic same path; different estates in the
same directory = different paths. The fix implements ADR-021 Decision 7 as written.

**Scope:**
- `EstateConfiguration.queueSibling(filename:)` — Swift path derivation
- `EstateConfiguration::queue_sibling` — Rust path derivation
- Docstrings updated to describe per-estate isolation, not shared queue semantics

**Tests added:** `twoEstatesInSameDirectoryGetDifferentSiblingPaths`,
`sameEstateSameSiblingPath` (both ports). Updated `sqliteSiblingPathIsInSameDirectory`
and corresponding Rust twin to assert the stem-prefixed filename.

---

## 2026-06-28 — SECFIX-WS2-PK: Planned security hardening

**Branch:** `secfix/ws2-pk`

Six planned security hardening items implemented across Swift and Rust ports.
The unifying contract: nothing from an uncommitted/rolled-back transaction is
ever observable, replicated, hashed, or synced; deletes propagate to replicas.

### F1 — SQL identifier injection guard

**Surfaces:** `SQLiteBackend.queryRows(columns:)` (Swift), `SqliteRowStore::query_projected` (Rust), `PostgresRowStore::query_projected` (Rust).

Caller-supplied column names are now validated against `[A-Za-z_][A-Za-z0-9_]*`
before being embedded in dynamically-constructed SELECT lists. Names containing
`"`, spaces, semicolons, or other special characters are rejected with
`StorageError.invalidIdentifier(name:)` / `StorageError::InvalidIdentifier`.
Double-quoting a name is insufficient protection because a name containing `"`
can escape the delimiter and alter the query.

New shared utility: `validateSQLIdentifier(_:)` (Swift), `validate_sql_identifier` (Rust, in `error.rs`).

### F2 — InMemory transaction row-change notification isolation

**Surface:** `InMemoryStorage.transaction` (Swift + Rust).

Row change events (`TableChange` / `StorageEvent`) are now buffered while a
transaction is in progress and flushed to observers only on COMMIT. A ROLLBACK
discards the pending buffer without delivering any notifications. Prior to this
fix, notifications were dispatched immediately inside the transaction block,
allowing sync engines to observe phantom state for rows that were subsequently
rolled back.

**Swift:** Added `isBufferingNotifications`, `pendingRowNotifications`,
`pendingBlobNotifications` to `InMemoryStateActor`.  
**Rust:** Added `in_transaction`, `pending_row_events`, `pending_blob_events` to
`State` (part of the snapshot so rollback automatically resets them).

### F3 — SQLite blob observer isolation

**Surface:** `SQLiteBackend.putBlob` / `deleteBlob` (Swift).

Blob change events (`BlobChange`) are now buffered while a SQLite transaction
is active (`inTransaction == true`) and flushed to the blob observer on COMMIT.
A ROLLBACK discards the pending buffer. Prior to this fix, blob events were
emitted immediately after the SQLite step — before COMMIT — so a ROLLBACK left
blob observers holding phantom-payload notifications.

### F4 — InMemory blob observer isolation

**Surface:** `InMemoryBlobStore.put` / `delete` (Rust).

Blob events are buffered in `State.pending_blob_events` during a transaction and
emitted via `blob_hub` on commit; discarded on rollback via snapshot restore.
Swift's InMemory backend gained the same fix under F2 (unified notification
buffering for rows and blobs).

### F5 — Blob delete propagation in full snapshot replication

**Surface:** `StorageReplicator.replicateFull` (Swift).

After writing source blobs to the destination, `replicateFull` now enumerates
destination blob keys and deletes any that are absent from the source. Prior to
this fix, the replication was additive-only for blobs: blobs hard-deleted from
the source survived indefinitely in replicas. The delete propagation runs inside
the same serializable transaction as the rest of the replication payload.

### F6 — Hash-on-write correctness for update and upsert

**Surfaces:** `HashingRowStore.update` / `upsert` (Swift + Rust).

`update` and `upsert` on the update path now pre-read the current row, merge
incoming values over the current state, and compute the `content_hash` from the
full merged row. Prior to this fix, both operations hashed only the partial
SET-column dict / incoming values dict, omitting unchanged columns and producing
a hash that diverged from the actual committed row state.

The `content_hash` column itself is stripped before the hash function is called
(consistent with the INSERT path, which computes the hash before writing
`content_hash` into the row). This ensures the hash provider always receives
the same column set regardless of whether the write is an insert or an update.

**New helper:** `augmentWithHashForKnownKey` (Swift), `augment_with_hash_for_known_key` (Rust).

---

### Regression tests added

| Finding | Swift test file | Rust test file |
|---|---|---|
| F1 | `PersistenceKitSQLiteTests/SecurityHardeningTests.swift` | `tests/secfix_tests.rs` |
| F2 | `PersistenceKitInMemoryTests/SecurityHardeningTests.swift` | `tests/secfix_tests.rs` |
| F3 | `PersistenceKitSQLiteTests/SecurityHardeningTests.swift` | — (Rust SQLite observer is NoOp) |
| F4 | `PersistenceKitInMemoryTests/SecurityHardeningTests.swift` | `tests/secfix_tests.rs` |
| F5 | `PersistenceKitReplicationTests/SecurityHardeningTests.swift` | — (Rust replication not yet ported) |
| F6 | `PersistenceKitInMemoryTests/HashingRowStoreF6Tests.swift` | `tests/secfix_tests.rs` |

**Test counts after hardening:** Swift: 332 (was 312, +20). Rust: 249 (was 237, +12).
