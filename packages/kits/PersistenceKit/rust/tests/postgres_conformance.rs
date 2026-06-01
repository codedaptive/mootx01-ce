// Runs the backend-agnostic conformance suite against the PostgreSQL
// backend — but ONLY when PERSISTENCEKIT_PG_URL names a reachable server.
// Without it the test is a no-op (so default `cargo test` stays green
// without a live database). Each factory() call uses a fresh schema-
// qualified set of tables in the target database; point it at a scratch
// database. This backend is UNVERIFIED until run against a real PG.

mod conformance;

use conformance::{run_all, vector_fixtures, Factory};
use persistence_kit::{BackendConfiguration, EstateConfiguration, PostgresStorage, Storage};
use uuid::Uuid;

#[test]
fn postgres_conformance() {
    let url = match std::env::var("PERSISTENCEKIT_PG_URL") {
        Ok(u) if !u.is_empty() => u,
        _ => {
            eprintln!(
                "postgres_conformance: skipped (set PERSISTENCEKIT_PG_URL to a scratch \
                 PostgreSQL database to run it)"
            );
            return;
        }
    };
    let factory: Factory = Box::new(move || {
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Postgresql {
                connection_string: url.clone(),
                pool_size: 1,
                connection_timeout_secs: 5.0,
                idle_timeout_secs: 30.0,
            },
        );
        Box::new(PostgresStorage::new(config).expect("connect postgres")) as Box<dyn Storage>
    });
    run_all("PostgreSQL", &factory);
    vector_fixtures("PostgreSQL", &factory);
}
