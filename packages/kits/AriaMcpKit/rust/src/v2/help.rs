//! Typed v2 help over the effective registry, wire-aligned with Swift.
use serde_json::{json, Value};
use crate::jsonrpc::JsonValue;
use super::codec::{optional_string, reject_unknown_fields, strict_object, V2DecodeResult, V2InvalidArgument};
use super::operation::{V2DirectoryRecord, V2OperationDescriptor};
use super::registry::V2EffectiveRegistry;

/// The global-modifiers help entry returned in the moot_help directory payload.
///
/// Documented once here at the directory level. Absent from every per-tool input
/// schema and per-operation help text (the documented-once contract). Byte-identical
/// to Swift `AriaV2HelpService.globalModifiersHelpText`; pinned by
/// `Tests/Conformance/global_modifiers_help_fixture.json` in both ports.
pub const GLOBAL_MODIFIERS_HELP_TEXT: &str = "\
mode \u{2014} global modifier applied at the ARIA door before every operation decodes its arguments.\n\
Grammar: mode:\"Name\" sets the mode; mode:\"Name=Variant\" sets mode and variant; \
a bare name clears any prior variant for that mode; the last declaration on a call wins.\n\
Fail-open: an unknown mode name or variant is silently ignored and does not clobber existing sticky state.\n\
Excluded (own mode in their input schema): moot_reclassify_fdc, moot_palace_import, moot_vault_import, moot_lens_partial_cue.";

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
            // Global modifiers are documented once here at the directory level,
            // absent from every per-tool input schema and per-operation help.
            // Byte-identical to Swift globalModifiersHelpText; pinned by
            // Tests/Conformance/global_modifiers_help_fixture.json.
            Self::Directory { operations, directory_records } => json!({
                "operations": operations.iter().map(operation_value).collect::<Vec<_>>(),
                "directory_records": directory_records.iter().map(directory_value).collect::<Vec<_>>(),
                "global_modifiers": GLOBAL_MODIFIERS_HELP_TEXT,
            }),
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
