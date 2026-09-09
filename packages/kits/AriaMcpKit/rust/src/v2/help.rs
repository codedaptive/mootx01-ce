//! Typed v2 help over the effective registry, wire-aligned with Swift.
use serde_json::{json, Value};
use crate::jsonrpc::JsonValue;
use super::codec::{optional_string, reject_unknown_fields, strict_object, V2DecodeResult, V2InvalidArgument};
use super::operation::{V2DirectoryRecord, V2OperationDescriptor};
use super::registry::V2EffectiveRegistry;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct V2HelpRequest { pub intent: Option<String>, pub tool: Option<String> }
impl V2HelpRequest {
    pub fn decode(arguments: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(arguments, ["intent", "tool"])?;
        reject_unknown_fields(object, ["intent", "tool"])?;
        let intent = optional_string(object, "intent")?.map(str::to_owned);
        let tool = optional_string(object, "tool")?.map(str::to_owned);
        if intent.is_some() && tool.is_some() { return Err(V2InvalidArgument::new("$", "intent and tool are mutually exclusive").correction("supply either intent or tool")); }
        Ok(Self { intent, tool })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum V2HelpResult {
    Directory { operations: Vec<V2OperationDescriptor>, directory_records: Vec<V2DirectoryRecord> },
    Operation(V2OperationDescriptor),
    Intent { intent: String, operations: Vec<V2OperationDescriptor> },
}
impl V2HelpResult {
    pub fn as_value(&self) -> Value {
        match self {
            Self::Directory { operations, directory_records } => json!({"operations":operations.iter().map(operation_value).collect::<Vec<_>>(),"directory_records":directory_records.iter().map(directory_value).collect::<Vec<_>>() }),
            Self::Operation(operation) => json!({"operation":operation_value(operation)}),
            Self::Intent { intent, operations } => json!({"intent":intent,"operations":operations.iter().map(operation_value).collect::<Vec<_>>() }),
        }
    }
}

/// Unknown tools return `None`; unmatched intents remain successful empty lists.
pub fn resolve_help(registry: &V2EffectiveRegistry, request: &V2HelpRequest) -> Option<V2HelpResult> {
    if let Some(tool)=&request.tool { return registry.operation(tool).cloned().map(V2HelpResult::Operation); }
    if let Some(intent)=&request.intent {
        let needle=intent.trim().to_lowercase();
        let operations=registry.operations().filter(|op| op.help.intents.iter().any(|candidate| candidate.trim().to_lowercase()==needle)).cloned().collect();
        return Some(V2HelpResult::Intent { intent:intent.clone(), operations });
    }
    Some(V2HelpResult::Directory { operations:registry.operations().cloned().collect(), directory_records:registry.directory_records().cloned().collect() })
}

fn operation_value(operation: &V2OperationDescriptor) -> Value {
    json!({"id":operation.identity,"name":operation.public_name,"description":operation.help.description,"effect":operation.effect,"input_schema":operation.input_schema,"output_schema":operation.projection.output_schema,"intents":operation.help.intents})
}
fn directory_value(record: &V2DirectoryRecord) -> Value {
    json!({"recipe_id":record.recipe_id,"description":record.help.description,"callable":false,"callable_tools":record.callable_tools})
}
