// Runs the backend-agnostic conformance suite against the SQLite backend.
// Each factory() call opens a fresh temp-file database.

mod conformance;

use conformance::{run_all, Factory};
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use uuid::Uuid;

#[test]
fn sqlite_conformance() {
    let factory: Factory = Box::new(|| {
        let path = std::env::temp_dir().join(format!("pk_conf_{}.sqlite", Uuid::new_v4()));
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        Box::new(SqliteStorage::new(config).expect("open sqlite storage")) as Box<dyn Storage>
    });
    run_all("SQLite", &factory);
}
