
#[path = "../src/v2/memory_list.rs"]
mod memory_list;
#[path = "../src/v2/memory_list_snapshot_provider.rs"]
mod memory_list_snapshot_provider;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use genius_locus_kit::EstateCoordinator;
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    frames::CaptureFrame,
    provenance::Sensitivity as ProvenanceSensitivity,
};
use memory_list::{
    MemoryListAuthorization, MemoryListError, MemoryListFilter, MemoryListRequest,
    MemoryListService, MemoryListSnapshot, MemoryListSnapshotProvider, MemoryListSnapshotRow,
};
use memory_list_snapshot_provider::{
    public_capture_provenance, public_projection, AriaMemoryListSnapshotProvider,
    MemoryListAuthorizationAuthority, MemoryListAuthorizedContext,
};
use uuid::Uuid;

struct Authority {
    context: MemoryListAuthorizedContext,
    revalidations: AtomicUsize,
}

#[test]
fn capture_provenance_admits_only_raw_normal_and_elevated() {
    for raw in [0_i64, 16] {
        assert!(
            public_capture_provenance(raw << 30),
            "raw {raw} must be visible"
        );
    }
    for raw in [32_i64, 48, 63] {
        assert!(
            !public_capture_provenance(raw << 30),
            "raw {raw} must be hidden"
        );
    }
}

impl MemoryListAuthorizationAuthority for Authority {
    fn authorize_memory_list(
        &self,
        requested: Option<Uuid>,
    ) -> Result<MemoryListAuthorizedContext, MemoryListError> {
        if requested.is_some_and(|estate| estate != self.context.estate_id) {
            return Err(MemoryListError::operational(
                "inventory_unavailable",
                "wrong estate",
                false,
            ));
        }
        Ok(self.context.clone())
    }

    fn revalidate_memory_list(
        &self,
        _: &MemoryListAuthorization,
    ) -> Result<MemoryListAuthorizedContext, MemoryListError> {
        self.revalidations.fetch_add(1, Ordering::SeqCst);
        Ok(self.context.clone())
    }
}

fn opened_provider() -> (
    AriaMemoryListSnapshotProvider<Arc<Authority>>,
    Arc<Authority>,
    Uuid,
) {
    let coordinator = Arc::new(Mutex::new(EstateCoordinator::new()));
    let handle = {
        let mut coordinator = coordinator.lock().unwrap();
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(1_700_000_000, None).unwrap());
        coordinator
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap()
    };
    {
        let coordinator = coordinator.lock().unwrap();
        let mut normal = CaptureFrame::new(
            "normal memory",
            CaptureChannel::Typed,
            "inbox",
            LatticeAnchor::udc("000"),
            "agent",
            "embed-v1",
        );
        normal.wing = Some("Agentic Memory".to_owned());
        normal.sensitivity = AdjectiveSensitivity::Normal;
        coordinator.capture(&handle, normal, 1_700_000_000).unwrap();

        let mut restricted = CaptureFrame::new(
            "restricted memory",
            CaptureChannel::Typed,
            "inbox",
            LatticeAnchor::udc("000"),
            "agent",
            "embed-v1",
        );
        restricted.wing = Some("Agentic Memory".to_owned());
        restricted.sensitivity = AdjectiveSensitivity::Restricted;
        coordinator
            .capture(&handle, restricted, 1_700_000_001)
            .unwrap();

        for (content, room, raw) in [
            (
                "elevated provenance control",
                "other",
                ProvenanceSensitivity::Elevated,
            ),
            (
                "restricted provenance hidden",
                "inbox",
                ProvenanceSensitivity::Restricted,
            ),
            (
                "secret provenance hidden",
                "inbox",
                ProvenanceSensitivity::Secret,
            ),
        ] {
            let mut frame = CaptureFrame::new(
                content,
                CaptureChannel::Typed,
                room,
                LatticeAnchor::udc("000"),
                "agent",
                "embed-v1",
            );
            frame.wing = Some("Agentic Memory".to_owned());
            frame.subject = Some(content.to_owned());
            frame.provenance_sensitivity = raw;
            coordinator.capture(&handle, frame, 1_700_000_002).unwrap();
        }
    }
    let estate_id = Uuid::from_bytes(handle.estate_uuid);
    let authority = Arc::new(Authority {
        context: MemoryListAuthorizedContext {
            estate_id,
            estate_handle: handle,
            caller_binding: "caller-a".to_owned(),
            context_id: "context-a".to_owned(),
            policy_version: "policy-v1".to_owned(),
            authorization_generation: "generation-1".to_owned(),
        },
        revalidations: AtomicUsize::new(0),
    });
    let provider =
        AriaMemoryListSnapshotProvider::new(Arc::clone(&coordinator), Arc::clone(&authority));
    (provider, authority, estate_id)
}

impl MemoryListAuthorizationAuthority for Arc<Authority> {
    fn authorize_memory_list(
        &self,
        requested: Option<Uuid>,
    ) -> Result<MemoryListAuthorizedContext, MemoryListError> {
        self.as_ref().authorize_memory_list(requested)
    }

    fn revalidate_memory_list(
        &self,
        authorization: &MemoryListAuthorization,
    ) -> Result<MemoryListAuthorizedContext, MemoryListError> {
        self.as_ref().revalidate_memory_list(authorization)
    }
}

#[test]
fn captures_complete_scope_with_fixed_bulk_ceiling_and_three_revalidations() {
    let (provider, authority, estate_id) = opened_provider();
    let authorization = provider.authorize(Some(estate_id)).unwrap();
    let snapshot = provider
        .capture_authorized_inventory(
            &authorization,
            "Agentic Memory",
            Some("inbox"),
            Some(MemoryListFilter::MissingSubject),
        )
        .unwrap();

    assert_eq!(snapshot.estate_id, estate_id);
    assert_eq!(snapshot.rows.len(), 1);
    assert_eq!(snapshot.rows[0].ancestry_names, ["Agentic Memory", "inbox"]);
    assert_eq!(
        snapshot.rows[0].projection,
        serde_json::Map::from_iter([(
            "fetch".to_owned(),
            serde_json::json!({
                "tool": "moot_memory_get",
                "arguments": {"memory_id": snapshot.rows[0].memory_id.hyphenated().to_string()},
            }),
        ),]),
    );
    assert!(!snapshot.rows[0].projection.contains_key("subject"));
    assert!(!snapshot.rows[0].projection.contains_key("context"));
    assert!(!snapshot.rows[0].projection.contains_key("weight"));
    assert_eq!(snapshot.rows[0].visibility_state, "bulk_exportable");
    assert_eq!(authority.revalidations.load(Ordering::SeqCst), 3);

    let elevated = provider
        .capture_authorized_inventory(&authorization, "Agentic Memory", Some("other"), None)
        .unwrap();
    assert_eq!(elevated.rows.len(), 1);
    assert_eq!(
        elevated.rows[0].projection["subject"],
        "elevated provenance control"
    );
}

#[derive(Clone)]
struct ProjectionProvider {
    estate_id: Uuid,
    authorization: MemoryListAuthorization,
    snapshot: MemoryListSnapshot,
}

impl MemoryListSnapshotProvider for ProjectionProvider {
    fn authorize(&self, _: Option<Uuid>) -> Result<MemoryListAuthorization, MemoryListError> {
        Ok(self.authorization.clone())
    }

    fn capture_authorized_inventory(
        &self,
        _: &MemoryListAuthorization,
        _: &str,
        _: Option<&str>,
        _: Option<MemoryListFilter>,
    ) -> Result<MemoryListSnapshot, MemoryListError> {
        Ok(self.snapshot.clone())
    }

    fn revalidate(&self, _: &MemoryListAuthorization) -> Result<(), MemoryListError> {
        Ok(())
    }
}

fn projection_page(
    projection: serde_json::Map<String, serde_json::Value>,
    filter: Option<MemoryListFilter>,
) -> memory_list::MemoryListPage {
    let estate_id = Uuid::parse_str("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").unwrap();
    let memory_id = Uuid::parse_str("10000000-0000-4000-8000-000000000000").unwrap();
    let wing_id = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
    let room_id = Uuid::parse_str("22222222-2222-4222-8222-222222222222").unwrap();
    let authorization = MemoryListAuthorization {
        caller_binding: "caller-binding-a".to_owned(),
        context_id: "context-42".to_owned(),
        policy_version: "policy-v3".to_owned(),
    };
    let snapshot = MemoryListSnapshot {
        estate_id,
        authorization_generation: "authorization-generation-7".to_owned(),
        drawer_rows: 1,
        node_rows: 3,
        serialized_row_bytes: 1024,
        rows: vec![MemoryListSnapshotRow {
            memory_id,
            ancestry_ids: vec![wing_id, room_id],
            ancestry_names: vec!["Agentic Memory".to_owned(), "inbox".to_owned()],
            eligibility_state: "current".to_owned(),
            visibility_state: "bulk_exportable".to_owned(),
            projection,
        }],
    };
    let provider = ProjectionProvider {
        estate_id,
        authorization,
        snapshot,
    };
    let request = MemoryListRequest {
        estate_id: Some(provider.estate_id),
        wing: "Agentic Memory".to_owned(),
        room: Some("inbox".to_owned()),
        filter,
        limit: 200,
        cursor: None,
    };
    MemoryListService::new(provider, estate_id)
        .list(request, 1_700_000_000_000)
        .unwrap()
}

#[test]
fn production_projection_caps_unicode_subject_before_payload_and_revision() {
    let memory_id = Uuid::parse_str("10000000-0000-4000-8000-000000000000").unwrap();
    let oversized = "🙂".repeat(513);
    let projection = public_projection(memory_id, Some("user"), Some(&oversized), false);
    let subject = projection["subject"].as_str().unwrap();
    assert_eq!(subject.chars().count(), 512);
    assert_eq!(subject, "🙂".repeat(512));

    let capped = public_projection(memory_id, Some("user"), Some(subject), false);
    let oversized_page = projection_page(projection, None);
    let capped_page = projection_page(capped, None);
    assert_eq!(oversized_page.memories, capped_page.memories);
    assert_eq!(
        oversized_page.memories[0]["memory_id"],
        serde_json::json!(memory_id.hyphenated().to_string())
    );
    assert_eq!(
        oversized_page.memories[0]["provenance"],
        serde_json::json!("user")
    );
    assert_eq!(
        oversized_page.memories[0]["subject"],
        serde_json::json!("🙂".repeat(512))
    );
    assert_eq!(oversized_page.revision, capped_page.revision);
    assert_eq!(
        oversized_page.revision,
        "60ef30d37844d9b1784fd54c073f3954c82a34d118a220c0b700a868b61f37a6"
    );
}

#[test]
fn production_missing_subject_projection_omits_provenance_and_pins_revision() {
    let memory_id = Uuid::parse_str("10000000-0000-4000-8000-000000000000").unwrap();
    let projection = public_projection(memory_id, Some("user"), None, true);
    assert!(!projection.contains_key("provenance"));
    assert!(!projection.contains_key("subject"));
    let page = projection_page(projection, Some(MemoryListFilter::MissingSubject));
    assert!(!page.memories[0].contains_key("provenance"));
    assert_eq!(
        page.memories[0]["memory_id"],
        serde_json::json!(memory_id.hyphenated().to_string())
    );
    assert_eq!(
        page.memories[0]["fetch"]["tool"],
        serde_json::json!("moot_memory_get")
    );
    assert_eq!(
        page.revision,
        "b08f5d455df559bebc519f897160506fb7909e2b92bb6717e2f54c358b5cb3bc"
    );
}
