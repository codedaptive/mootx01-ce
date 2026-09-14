//! Test-local selected-v2 request adapter.
//!
//! Integration tests that predate the selected surface keep their compact
//! `Result<serde_json::Value, JSONRPCError>` assertions, while every call is
//! now admitted and executed by the public `Dispatcher::handle` path.

use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::TcpStream,
    time::{SystemTime, UNIX_EPOCH},
};

use aria_mcp::{
    dispatcher::{Dispatcher, UpdateAdvisoryProvider},
    estate_registry::{EstateRegistry, OpenEstate},
    http_server::{bind_loopback, serve_once},
    jsonrpc::{JSONRPCError, JSONRPCRequest, JsonValue, ResponsePayload},
};

pub struct SelectedV2Session {
    pub dispatcher: Dispatcher,
    pub default: OpenEstate,
    pub coord: std::sync::Arc<std::sync::Mutex<genius_locus_kit::EstateCoordinator>>,
}

impl SelectedV2Session {
    pub fn new(registry: EstateRegistry) -> Self {
        let default = registry.default.clone();
        let coord = std::sync::Arc::clone(&registry.coord);
        let dispatcher = Dispatcher::new(
            registry,
            "aria-mcp-test",
            "test",
            "test-serial",
            None,
        );
        Self { dispatcher, default, coord }
    }

    pub fn new_with_memory_enabled(registry: EstateRegistry) -> Self {
        let default = registry.default.clone();
        let coord = std::sync::Arc::clone(&registry.coord);
        let dispatcher = Dispatcher::new(
            registry,
            "aria-mcp-test",
            "test",
            "test-serial",
            None,
        )
        .with_memory_tool_enabled(true);
        Self { dispatcher, default, coord }
    }

    pub fn new_with_advisories(
        registry: EstateRegistry,
        build_serial: &str,
        version_skew: &str,
        update_advisory: Option<UpdateAdvisoryProvider>,
    ) -> Self {
        let default = registry.default.clone();
        let coord = std::sync::Arc::clone(&registry.coord);
        let dispatcher = Dispatcher::new(registry, "aria-mcp-test", "test", build_serial, None)
            .with_version_skew(version_skew.to_owned())
            .with_update_advisory(update_advisory);
        Self { dispatcher, default, coord }
    }

    pub fn call(
        &self,
        name: &str,
        args: &BTreeMap<String, JsonValue>,
    ) -> Result<serde_json::Value, JSONRPCError> {
        let request = JSONRPCRequest::decode(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": name,
                "arguments": serde_json::to_value(args).expect("test arguments must serialize"),
            },
        }))
        .expect("tools/call request must decode");

        match self.dispatcher.handle(&request).payload {
            ResponsePayload::Result(result) => Ok(result),
            ResponsePayload::Error(error) => Err(error),
        }
    }

    pub fn unlock(&self, tier: &str) {
        let listener = bind_loopback(0).expect("bind loopback unlock listener");
        let port = listener.local_addr().expect("unlock listener address").port();
        let proof_ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock after unix epoch")
            .as_millis();
        let body = serde_json::json!({ "tier": tier, "proof": { "ts": proof_ts } }).to_string();
        let mut client = TcpStream::connect(("127.0.0.1", port)).expect("connect unlock client");
        let request = format!(
            "POST /api/control/unlock HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            body.len(), body
        );
        client.write_all(request.as_bytes()).expect("write unlock request");
        client.flush().expect("flush unlock request");
        serve_once(&listener, &self.dispatcher, 4 * 1024 * 1024, None);
        let mut response = String::new();
        client.read_to_string(&mut response).expect("read unlock response");
        assert!(response.starts_with("HTTP/1.1 200"), "unlock must succeed: {response}");
    }
}
