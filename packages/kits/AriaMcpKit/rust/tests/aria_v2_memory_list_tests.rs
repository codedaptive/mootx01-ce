#![cfg(feature = "aria-v2")]

#[path = "../src/v2/memory_list.rs"]
mod memory_list;

use std::sync::{Arc, Mutex};

use memory_list::{
    MemoryListAuthorization, MemoryListError, MemoryListFilter, MemoryListProjection,
    MemoryListRequest, MemoryListService, MemoryListSnapshot, MemoryListSnapshotProvider,
    MemoryListSnapshotRow, CURSOR_TTL_MILLIS,
};
use serde_json::{json, Map, Value};
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000;
const ESTATE: &str = "33333333-3333-4333-8333-333333333333";

struct Provider {
    authorization: Mutex<MemoryListAuthorization>,
    snapshot: Mutex<MemoryListSnapshot>,
}

impl MemoryListSnapshotProvider for Provider {
    fn authorize(&self, _: Option<Uuid>) -> Result<MemoryListAuthorization, MemoryListError> {
        Ok(self.authorization.lock().unwrap().clone())
    }

    fn capture_authorized_inventory(
        &self,
        _: &MemoryListAuthorization,
        _: &str,
        _: Option<&str>,
        _: Option<MemoryListFilter>,
    ) -> Result<MemoryListSnapshot, MemoryListError> {
        Ok(self.snapshot.lock().unwrap().clone())
    }

    fn revalidate(&self, _: &MemoryListAuthorization) -> Result<(), MemoryListError> { Ok(()) }
}

impl MemoryListSnapshotProvider for Arc<Provider> {
    fn authorize(&self, requested: Option<Uuid>) -> Result<MemoryListAuthorization, MemoryListError> {
        self.as_ref().authorize(requested)
    }

    fn capture_authorized_inventory(
        &self,
        authorization: &MemoryListAuthorization,
        wing: &str,
        room: Option<&str>,
        filter: Option<MemoryListFilter>,
    ) -> Result<MemoryListSnapshot, MemoryListError> {
        self.as_ref().capture_authorized_inventory(authorization, wing, room, filter)
    }

    fn revalidate(&self, authorization: &MemoryListAuthorization) -> Result<(), MemoryListError> {
        self.as_ref().revalidate(authorization)
    }
}

fn uuid(value: &str) -> Uuid { Uuid::parse_str(value).unwrap() }

fn projection(subject: Option<&str>, provenance: Option<&str>, context: Option<&str>, weight: i64) -> MemoryListProjection {
    Map::from_iter([
        ("subject".to_owned(), subject.map_or(Value::Null, |value| Value::String(value.to_owned()))),
        ("provenance".to_owned(), provenance.map_or(Value::Null, |value| Value::String(value.to_owned()))),
        ("context".to_owned(), context.map_or(Value::Null, |value| Value::String(value.to_owned()))),
        ("weight".to_owned(), Value::Number(weight.into())),
    ])
}

fn row(id: &str, subject: Option<&str>) -> MemoryListSnapshotRow {
    MemoryListSnapshotRow {
        memory_id: uuid(id),
        ancestry_ids: vec![uuid("11111111-1111-4111-8111-111111111111"), uuid("22222222-2222-4222-8222-222222222222")],
        ancestry_names: vec!["Agentic Memory".to_owned(), "inbox".to_owned()],
        eligibility_state: "current".to_owned(),
        visibility_state: "bulk_exportable".to_owned(),
        projection: projection(subject, Some("agent"), None, 7),
    }
}

fn snapshot(rows: Vec<MemoryListSnapshotRow>) -> MemoryListSnapshot {
    MemoryListSnapshot {
        estate_id: uuid(ESTATE), authorization_generation: "generation-1".to_owned(),
        drawer_rows: rows.len(), node_rows: 2, serialized_row_bytes: 128, rows,
    }
}

fn request(cursor: Option<String>) -> MemoryListRequest {
    MemoryListRequest {
        estate_id: None, wing: "Agentic Memory".to_owned(), room: None,
        filter: None, limit: 1, cursor,
    }
}

fn service() -> (MemoryListService<Arc<Provider>>, Arc<Provider>) {
    let provider = Arc::new(Provider {
        authorization: Mutex::new(MemoryListAuthorization {
            caller_binding: "caller-a".to_owned(), context_id: "context-a".to_owned(), policy_version: "policy-v1".to_owned(),
        }),
        snapshot: Mutex::new(snapshot(vec![
            row("f0000000-0000-4000-8000-000000000000", Some("last")),
            row("10000000-0000-4000-8000-000000000000", Some("first")),
            row("80000000-0000-4000-8000-000000000000", Some("middle")),
        ])),
    });
    (MemoryListService::new(Arc::clone(&provider), uuid(ESTATE)), provider)
}

#[test]
fn pages_complete_authorized_state_in_uuid_byte_order() {
    let (service, _) = service();
    let first = service.list(request(None), NOW).unwrap();
    assert_eq!(first.memories[0]["memory_id"], "10000000-0000-4000-8000-000000000000");
    assert!(first.has_more);
    let cursor = first.next_cursor.clone().expect("usable cursor when has_more");

    let second = service.list(request(Some(cursor)), NOW + 1).unwrap();
    assert_eq!(second.memories[0]["memory_id"], "80000000-0000-4000-8000-000000000000");
    assert!(second.has_more);
    assert_eq!(first.revision, second.revision);
}

#[test]
fn stale_expired_and_mismatched_cursors_return_no_page() {
    let (service, provider) = service();
    let first = service.list(request(None), NOW).unwrap();
    let cursor = first.next_cursor.clone().unwrap();

    provider.snapshot.lock().unwrap().rows.push(row("20000000-0000-4000-8000-000000000000", Some("changed")));
    let stale = service.list(request(Some(cursor.clone())), NOW + 1).unwrap_err();
    assert_eq!(stale.code, "cursor_stale");

    let fresh = service.list(request(None), NOW + 2).unwrap();
    let fresh_cursor = fresh.next_cursor.clone().unwrap();
    provider.authorization.lock().unwrap().context_id = "context-b".to_owned();
    let mismatch = service.list(request(Some(fresh_cursor)), NOW + 3).unwrap_err();
    assert_eq!(mismatch.code, "cursor_mismatch");

    provider.authorization.lock().unwrap().context_id = "context-a".to_owned();
    let expiring = service.list(request(None), NOW + 4).unwrap();
    let expired = service.list(request(Some(expiring.next_cursor.unwrap())), NOW + 4 + CURSOR_TTL_MILLIS).unwrap_err();
    assert_eq!(expired.code, "cursor_expired");
}

#[test]
fn decoder_allows_absent_or_missing_subject_filter_and_empty_room_is_nil() {
    let absent = MemoryListRequest::decode(&json!({"wing": "Agentic Memory", "room": ""})).unwrap();
    assert_eq!(absent.room, None);
    assert_eq!(absent.filter, None);
    let filtered = MemoryListRequest::decode(&json!({"wing": "Agentic Memory", "filter": "missing_subject", "limit": 200})).unwrap();
    assert_eq!(filtered.filter, Some(MemoryListFilter::MissingSubject));
    assert!(MemoryListRequest::decode(&json!({"wing":"Agentic Memory","filter":"all"})).is_err());
    assert!(MemoryListRequest::decode(&json!({"wing":"Agentic Memory","extra":true})).is_err());
}

#[test]
fn revision_matches_shared_swift_vector_and_preserves_projection_nulls() {
    let fixture: Value = serde_json::from_str(include_str!("../../Tests/Conformance/aria_v2_memory_list_revision_vectors.json")).unwrap();
    let material = &fixture["revision_material"];
    let authorization = material["authorization"].as_object().unwrap();
    let mut rows = Vec::new();
    for source in material["rows"].as_array().unwrap() {
        let projection = source["projection"].as_object().unwrap().clone();
        rows.push(MemoryListSnapshotRow {
            memory_id: uuid(source["memory_id"].as_str().unwrap()),
            ancestry_ids: source["ancestry_ids"].as_array().unwrap().iter().map(|id| uuid(id.as_str().unwrap())).collect(),
            ancestry_names: source["ancestry_names"].as_array().unwrap().iter().map(|name| name.as_str().unwrap().to_owned()).collect(),
            eligibility_state: source["eligibility"].as_str().unwrap().to_owned(),
            visibility_state: source["visibility"].as_str().unwrap().to_owned(),
            projection,
        });
    }
    let provider = Arc::new(Provider {
        authorization: Mutex::new(MemoryListAuthorization {
            caller_binding: authorization["caller_binding"].as_str().unwrap().to_owned(),
            context_id: authorization["context_id"].as_str().unwrap().to_owned(),
            policy_version: authorization["policy_version"].as_str().unwrap().to_owned(),
        }),
        snapshot: Mutex::new(MemoryListSnapshot {
            estate_id: uuid(material["estate_id"].as_str().unwrap()),
            authorization_generation: authorization["authorization_generation"].as_str().unwrap().to_owned(),
            drawer_rows: rows.len(), node_rows: 2, serialized_row_bytes: 512, rows,
        }),
    });
    let request = MemoryListRequest {
        estate_id: None, wing: material["scope"]["wing"].as_str().unwrap().to_owned(), room: None,
        filter: Some(MemoryListFilter::MissingSubject), limit: 200, cursor: None,
    };
    let page = MemoryListService::new(Arc::clone(&provider), uuid(material["estate_id"].as_str().unwrap()))
        .list(request, NOW).unwrap();
    assert_eq!(page.revision, fixture["expected_sha256"].as_str().unwrap());
    assert_eq!(page.memories[0]["subject"], Value::Null);
    assert_eq!(page.memories[1]["provenance"], Value::Null);
    assert_eq!(page.memories[1]["context"], "planning");
}
