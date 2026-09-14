use std::{ffi::OsString, path::Path, sync::Mutex};

use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::EstateRegistry,
    jsonrpc::JSONRPCRequest,
};

static ENVIRONMENT_LOCK: Mutex<()> = Mutex::new(());

struct EnvironmentRestore {
    vault: Option<OsString>,
    memory: Option<OsString>,
}

impl EnvironmentRestore {
    fn capture() -> Self {
        Self {
            vault: std::env::var_os("MOOTX01_VAULT"),
            memory: std::env::var_os("MOOTX01_MEMORY_TOOL"),
        }
    }
}

impl Drop for EnvironmentRestore {
    fn drop(&mut self) {
        match &self.vault {
            Some(value) => std::env::set_var("MOOTX01_VAULT", value),
            None => std::env::remove_var("MOOTX01_VAULT"),
        }
        match &self.memory {
            Some(value) => std::env::set_var("MOOTX01_MEMORY_TOOL", value),
            None => std::env::remove_var("MOOTX01_MEMORY_TOOL"),
        }
    }
}

#[test]
fn fixture_variants_match_live_catalogs() {
    let _serialized = ENVIRONMENT_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    let _restore = EnvironmentRestore::capture();

    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let fixture_path = Path::new(&manifest_dir)
        .parent()
        .expect("rust manifest must sit beneath AriaMcpKit")
        .join("Tests/Conformance/aria_v2_mission02_vectors.json");
    let fixture: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&fixture_path)
            .unwrap_or_else(|error| panic!("read {}: {error}", fixture_path.display())),
    )
    .expect("shared ARIA v2 mission02 vectors must be valid JSON");
    let variants = fixture["catalog"]["catalog_variants"]
        .as_array()
        .expect("catalog_variants must be an array");
    assert_eq!(variants.len(), 4, "fixture must contain the four gated variants");

    for variant in variants {
        let id = variant["id"].as_str().expect("variant id must be a string");
        let (vault, memory) = match id {
            "vault_on_memory_off" => ("1", "0"),
            "vault_off_memory_off" => ("0", "0"),
            "vault_on_memory_on" => ("1", "1"),
            "vault_off_memory_on" => ("0", "1"),
            unknown => panic!("unrecognized fixture variant {unknown}"),
        };
        std::env::set_var("MOOTX01_VAULT", vault);
        std::env::set_var("MOOTX01_MEMORY_TOOL", memory);

        let dispatcher = Dispatcher::new(
            EstateRegistry::new_inmemory(),
            "ARIA_MCP_Rust",
            "test",
            "fixture-variants",
            None,
        );
        let request = JSONRPCRequest::decode(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        }))
        .expect("tools/list request must decode");
        let response = serde_json::to_value(dispatcher.handle(&request))
            .expect("tools/list response must serialize");
        let live_names: Vec<String> = response["result"]["tools"]
            .as_array()
            .expect("tools/list result must contain tools")
            .iter()
            .map(|tool| tool["name"].as_str().expect("tool name must be a string").to_owned())
            .collect();
        let expected_names: Vec<String> = variant["tools"]
            .as_array()
            .expect("variant tools must be an array")
            .iter()
            .map(|name| name.as_str().expect("fixture tool name must be a string").to_owned())
            .collect();
        let expected_count = variant["expected_tool_count"]
            .as_u64()
            .expect("expected_tool_count must be an integer") as usize;

        assert_eq!(
            (live_names.len(), live_names),
            (expected_count, expected_names),
            "{id} must match the exact ordered tools/list roster and count"
        );
    }
}
