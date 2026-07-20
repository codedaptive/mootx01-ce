//! Tests for `EstateConfiguration::queue_sibling` — recall-driven dreaming.
//!
//! Coverage:
//!   1. SQLite estate: sibling is at `<estate-dir>/<estate-stem>.<filename>`,
//!      same busy_timeout_secs, encryption_config carried over (mode, key
//!      identifier), sibling estate_id differs from parent.
//!   2. Cross-estate isolation: two distinct estate DB files in the SAME
//!      directory produce DIFFERENT sibling paths (the core security invariant).
//!   3. Same estate → same sibling path across repeated calls (determinism).
//!   4. InMemory estate: sibling is InMemory, deterministic sibling ID.
//!   5. PostgreSQL estate: queue_sibling returns StorageError::FeatureGated
//!      (deferred path), never a silent wrong config.
//!   6. Determinism: repeated calls on the same input return equal configs.
//!   7. Different filenames → different sibling IDs.
//!
//! Mirrors Swift `EstateConfigurationQueueSiblingTests`.

use persistence_kit::{
    BackendConfiguration, EstateConfiguration, EstateEncryptionConfig, StorageError,
};

// ─────────────────────────────────────────────────────────────────────────────
// SQLite backend
// ─────────────────────────────────────────────────────────────────────────────

/// SQLite sibling lands in the same directory as the estate DB, with the
/// sibling filename derived from the estate's own file stem + the requested
/// filename (`<stem>.<filename>`). This isolates estates sharing a directory.
#[test]
fn sqlite_sibling_path_is_in_same_directory() {
    let parent_id = uuid::Uuid::new_v4();
    let config = EstateConfiguration::new(
        parent_id,
        BackendConfiguration::Sqlite {
            path: "/tmp/estates/estate.sqlite".to_owned(),
            busy_timeout_secs: 5.0,
        },
    );

    let sibling = config.queue_sibling("queue.sqlite").expect("queue_sibling must not fail for SQLite");

    match &sibling.backend {
        BackendConfiguration::Sqlite { path, .. } => {
            // Sibling filename is <estate-stem>.<filename> — NOT the bare filename.
            // Estate stem "estate" + filename "queue.sqlite" → "estate.queue.sqlite".
            assert!(
                path.ends_with("/estate.queue.sqlite"),
                "expected sibling path to end with /estate.queue.sqlite, got: {path}"
            );
            // Directory must still be /tmp/estates.
            let parent = std::path::Path::new(path)
                .parent()
                .expect("sibling path has a parent dir")
                .to_string_lossy()
                .into_owned();
            assert_eq!(parent, "/tmp/estates");
        }
        other => panic!("expected Sqlite backend on sibling, got {other:?}"),
    }
}

/// Two distinct estate DB files in the SAME directory produce DIFFERENT
/// sibling paths — the core recall-driven dreaming isolation invariant.
/// Before this fix both derived the same `<dir>/queue.sqlite`, enabling
/// cross-estate corpus disclosure. After the fix each estate's queue is
/// at `<dir>/<estate-stem>.queue.sqlite`, unique per estate.
#[test]
fn two_estates_in_same_directory_get_different_sibling_paths() {
    let uuid_a = uuid::Uuid::new_v4();
    let uuid_b = uuid::Uuid::new_v4();
    let config_a = EstateConfiguration::new(
        uuid_a,
        BackendConfiguration::Sqlite {
            path: format!("/tmp/shared-estates/{}.sqlite", uuid_a),
            busy_timeout_secs: 5.0,
        },
    );
    let config_b = EstateConfiguration::new(
        uuid_b,
        BackendConfiguration::Sqlite {
            path: format!("/tmp/shared-estates/{}.sqlite", uuid_b),
            busy_timeout_secs: 5.0,
        },
    );

    let sibling_a = config_a.queue_sibling("queue.sqlite")
        .expect("queue_sibling must not fail for SQLite");
    let sibling_b = config_b.queue_sibling("queue.sqlite")
        .expect("queue_sibling must not fail for SQLite");

    match (&sibling_a.backend, &sibling_b.backend) {
        (
            BackendConfiguration::Sqlite { path: path_a, .. },
            BackendConfiguration::Sqlite { path: path_b, .. },
        ) => {
            // Sibling paths must differ — different estates, same directory.
            assert_ne!(
                path_a, path_b,
                "Two estates in the same dir must produce different queue sibling paths.\n\
                 path_a={path_a}\npath_b={path_b}"
            );
            // Both siblings must still be in the same parent directory.
            let dir_a = std::path::Path::new(path_a)
                .parent().expect("sibling_a has parent").to_string_lossy().into_owned();
            let dir_b = std::path::Path::new(path_b)
                .parent().expect("sibling_b has parent").to_string_lossy().into_owned();
            assert_eq!(dir_a, "/tmp/shared-estates");
            assert_eq!(dir_b, "/tmp/shared-estates");
        }
        other => panic!("expected Sqlite backends on both siblings, got {other:?}"),
    }
}

/// The same estate DB produces the same sibling path across repeated calls
/// (all processes that open the same estate share one queue file per recall-driven dreaming).
#[test]
fn same_estate_same_sibling_path() {
    let estate_id = uuid::Uuid::new_v4();
    let config = EstateConfiguration::new(
        estate_id,
        BackendConfiguration::Sqlite {
            path: "/tmp/estates/shared-estate.sqlite".to_owned(),
            busy_timeout_secs: 5.0,
        },
    );

    let first  = config.queue_sibling("queue.sqlite").unwrap();
    let second = config.queue_sibling("queue.sqlite").unwrap();

    match (&first.backend, &second.backend) {
        (
            BackendConfiguration::Sqlite { path: p1, .. },
            BackendConfiguration::Sqlite { path: p2, .. },
        ) => {
            assert_eq!(p1, p2, "Same estate must produce identical sibling paths across calls");
        }
        _ => panic!("expected Sqlite backends on both calls"),
    }
}

/// `busy_timeout_secs` from the estate config is preserved on the sibling.
#[test]
fn sqlite_sibling_preserves_busy_timeout() {
    let config = EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: "/tmp/estates/estate.sqlite".to_owned(),
            busy_timeout_secs: 12.5,
        },
    );

    let sibling = config.queue_sibling("queue.sqlite").unwrap();

    match &sibling.backend {
        BackendConfiguration::Sqlite { busy_timeout_secs, .. } => {
            assert_eq!(*busy_timeout_secs, 12.5);
        }
        other => panic!("expected Sqlite backend on sibling, got {other:?}"),
    }
}

/// Encryption config is carried over verbatim to the sibling — mode and key
/// identifier are the same (key bytes are cloned, not regenerated).
///
/// This is the core recall-driven dreaming invariant: the queue DB uses the same
/// cipher key as the estate so QueueKit can open it without additional key
/// distribution.
///
/// Note: `EstateEncryptionConfig.key` is `pub(crate)` and not visible to
/// integration tests. We assert equality of the public fields (`mode`,
/// `key_identifier`) instead. The same key identifier on both configs
/// means they reference the same logical key slot — a re-mint would produce
/// a fresh UUID identifier, which would fail the equality check below.
#[test]
fn sqlite_sibling_carries_encryption_config() {
    let encryption = EstateEncryptionConfig::row_encryption();
    let expected_mode = encryption.mode;
    let expected_key_identifier = encryption.key_identifier.clone();

    let mut config = EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: "/tmp/estates/estate.sqlite".to_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    // Inject the non-plaintext encryption config.
    config.encryption_config = encryption;

    let sibling = config.queue_sibling("queue.sqlite").unwrap();

    // Mode must be carried over unchanged.
    assert_eq!(sibling.encryption_config.mode, expected_mode);
    // Key identifier must be the same string — not a re-mint.
    // A re-mint would produce a fresh UUID identifier, proving the key was
    // not carried over. Identical identifier proves the config was cloned.
    assert_eq!(sibling.encryption_config.key_identifier, expected_key_identifier);
}

/// The sibling's estate_id is distinct from the parent's estate_id.
#[test]
fn sqlite_sibling_estate_id_differs_from_parent() {
    let parent_id = uuid::Uuid::new_v4();
    let config = EstateConfiguration::new(
        parent_id,
        BackendConfiguration::Sqlite {
            path: "/tmp/e/estate.sqlite".to_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let sibling = config.queue_sibling("queue.sqlite").unwrap();
    assert_ne!(sibling.estate_id, parent_id);
}

/// Two calls with the same input produce equal sibling configurations
/// (deterministic estate_id and path, no Uuid::new_v4() random minting).
#[test]
fn sqlite_sibling_is_deterministic() {
    let parent_id = uuid::Uuid::new_v4();
    let config = EstateConfiguration::new(
        parent_id,
        BackendConfiguration::Sqlite {
            path: "/tmp/e/estate.sqlite".to_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let first  = config.queue_sibling("queue.sqlite").unwrap();
    let second = config.queue_sibling("queue.sqlite").unwrap();

    assert_eq!(first.estate_id, second.estate_id);
    match (&first.backend, &second.backend) {
        (
            BackendConfiguration::Sqlite { path: p1, busy_timeout_secs: bt1 },
            BackendConfiguration::Sqlite { path: p2, busy_timeout_secs: bt2 },
        ) => {
            assert_eq!(p1, p2);
            assert_eq!(bt1, bt2);
        }
        _ => panic!("both calls should return Sqlite backends"),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// InMemory backend
// ─────────────────────────────────────────────────────────────────────────────

/// An InMemory estate produces an InMemory sibling (ephemeral alongside the
/// ephemeral estate, correct for tests and transient session estates).
#[test]
fn inmemory_sibling_is_inmemory() {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let sibling = config.queue_sibling("queue.sqlite").unwrap();
    assert!(
        matches!(sibling.backend, BackendConfiguration::InMemory),
        "expected InMemory backend on sibling, got {:?}",
        sibling.backend
    );
}

/// InMemory sibling estate_id is distinct from the parent's estate_id.
#[test]
fn inmemory_sibling_estate_id_differs_from_parent() {
    let parent_id = uuid::Uuid::new_v4();
    let config = EstateConfiguration::new(parent_id, BackendConfiguration::InMemory);
    let sibling = config.queue_sibling("queue.sqlite").unwrap();
    assert_ne!(sibling.estate_id, parent_id);
}

/// InMemory sibling is deterministic across two calls.
#[test]
fn inmemory_sibling_is_deterministic() {
    let parent_id = uuid::Uuid::new_v4();
    let config = EstateConfiguration::new(parent_id, BackendConfiguration::InMemory);
    let first  = config.queue_sibling("queue.sqlite").unwrap();
    let second = config.queue_sibling("queue.sqlite").unwrap();
    assert_eq!(first.estate_id, second.estate_id);
}

// ─────────────────────────────────────────────────────────────────────────────
// PostgreSQL backend — deferred, must fail loud
// ─────────────────────────────────────────────────────────────────────────────

/// The PostgreSQL queue-sibling branch is not implemented.
/// `queue_sibling` on a PostgreSQL estate must return `StorageError::FeatureGated`,
/// never silently produce a wrong or half-initialised config.
#[test]
fn postgresql_sibling_returns_feature_gated() {
    let config = EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::Postgresql {
            connection_string: "postgresql://localhost/test".to_owned(),
            pool_size: 10,
            connection_timeout_secs: 5.0,
            idle_timeout_secs: 300.0,
        },
    );
    let result = config.queue_sibling("queue.sqlite");
    assert!(result.is_err(), "PostgreSQL queue_sibling must return an error");
    match result.unwrap_err() {
        StorageError::FeatureGated { feature } => {
            assert!(
                feature.contains("PostgreSQL backend is deferred")
                    && feature.contains("SQLite or InMemory"),
                "FeatureGated message must name the deferred backend and supported alternatives, got: {feature}"
            );
        }
        other => panic!("expected StorageError::FeatureGated, got {other:?}"),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Determinism: different filenames → different sibling IDs
// ─────────────────────────────────────────────────────────────────────────────

/// Two different filenames applied to the same parent produce different sibling
/// estate IDs, ensuring each named sibling is distinct.
#[test]
fn different_filenames_produce_different_ids() {
    let parent_id = uuid::Uuid::new_v4();
    let config = EstateConfiguration::new(
        parent_id,
        BackendConfiguration::Sqlite {
            path: "/tmp/e/estate.sqlite".to_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let q = config.queue_sibling("queue.sqlite").unwrap();
    let d = config.queue_sibling("drain.sqlite").unwrap();
    assert_ne!(q.estate_id, d.estate_id);
}
