// Validates the backend-agnostic conformance suite against the InMemory
// backend. The same suite gates the SQLite and PostgreSQL backends.

mod conformance;

use conformance::{run_all, vector_fixtures, Factory};
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use uuid::Uuid;

#[test]
fn inmemory_conformance() {
    let factory: Factory =
        Box::new(|| Box::new(InMemoryStorage::with_estate(Uuid::new_v4())) as Box<dyn Storage>);
    run_all("InMemory", &factory);
    vector_fixtures("InMemory", &factory);
}
