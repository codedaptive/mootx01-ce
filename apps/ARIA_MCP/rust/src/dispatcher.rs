//! The method router — dispatches JSON-RPC requests to handlers.
//!
//! Mirrors the Swift `ARIA_MCPDispatcher.route(_:)` method: handles
//! `initialize`, `ping`, `tools/list`, and `tools/call`. All other method
//! names return a `methodNotFound` error.
//!
//! `tools/call` delegates to `crate::dispatch::dispatch_tool` which holds
//! the full tool dispatch table (recipe tools, lens tools, lexicon tools).

use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JSONRPCRequest, JSONRPCResponse, JsonValue};
use crate::tool_list::build_tool_list;

/// The method router and tool registry. Owns the estate registry and
/// the tool list; dispatches each inbound request to the right handler.
pub struct Dispatcher {
    registry: EstateRegistry,
    server_name: String,
    server_version: String,
    tools: serde_json::Value,
}

impl Dispatcher {
    /// Construct from an estate registry and server identity.
    pub fn new(registry: EstateRegistry, name: &str, version: &str) -> Self {
        let tools = build_tool_list();
        Dispatcher {
            registry,
            server_name: name.to_owned(),
            server_version: version.to_owned(),
            tools,
        }
    }

    /// Handle one parsed inbound request. Returns the response.
    /// (Notifications are already filtered out by the stdio loop before
    /// reaching this method.)
    pub fn handle(&self, request: &JSONRPCRequest) -> JSONRPCResponse {
        let id = request.id.clone().unwrap_or(JsonValue::Null);
        match self.route(request) {
            Ok(result) => JSONRPCResponse::ok(id, result),
            Err(e) => JSONRPCResponse::failure(id, e),
        }
    }

    fn route(&self, request: &JSONRPCRequest) -> Result<serde_json::Value, JSONRPCError> {
        match request.method.as_str() {
            "initialize" => self.initialize(request.params.as_ref()),
            "ping" => Ok(serde_json::json!({})),
            "tools/list" => Ok(serde_json::json!({ "tools": self.tools })),
            "tools/call" => self.tools_call(request.params.as_ref()),
            _ => Err(JSONRPCError::new(
                JSONRPCErrorCode::METHOD_NOT_FOUND,
                format!("Method not found: {}", request.method),
            )),
        }
    }

    fn initialize(&self, params: Option<&JsonValue>) -> Result<serde_json::Value, JSONRPCError> {
        // Echo the client's protocolVersion; default to "2024-11-05" if absent.
        // Matches the Swift ARIA_MCPDispatcher.initialize(params:) behavior.
        let protocol_version = params
            .and_then(|p| p.as_object())
            .and_then(|o| o.get("protocolVersion"))
            .and_then(|v| v.as_str())
            .unwrap_or("2024-11-05")
            .to_owned();

        Ok(serde_json::json!({
            "protocolVersion": protocol_version,
            "capabilities": {
                // tools/list and tools/call are the only primitives this
                // server implements (v1). Resources, prompts, sampling,
                // elicitation, and tasks are not advertised.
                "tools": {}
            },
            "serverInfo": {
                "name": self.server_name,
                "version": self.server_version
            }
        }))
    }

    fn tools_call(&self, params: Option<&JsonValue>) -> Result<serde_json::Value, JSONRPCError> {
        let obj = params.and_then(|p| p.as_object()).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "tools/call requires a 'name' parameter",
            )
        })?;
        let name = obj.get("name").and_then(|v| v.as_str()).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "tools/call requires a 'name' parameter",
            )
        })?;
        let arguments = obj
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| JsonValue::Object(Default::default()));
        let args_map = arguments.as_object().cloned().unwrap_or_default();

        crate::dispatch::dispatch_tool(name, &args_map, &self.registry)
    }
}
