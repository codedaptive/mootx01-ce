//! Selected-v2 unknown-operation regression coverage.

mod test_support;

use std::collections::BTreeMap;

use aria_mcp::{
    estate_registry::EstateRegistry,
    jsonrpc::{JsonValue, JSONRPCErrorCode},
};
use test_support::SelectedV2Session;

#[test]
fn unknown_public_v2_operation_returns_method_not_found() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let error = session
        .call("moot_nonexistent_tool", &BTreeMap::<String, JsonValue>::new())
        .expect_err("unknown selected-v2 operation must produce a transport fault");

    assert_eq!(error.code, JSONRPCErrorCode::METHOD_NOT_FOUND);
}
