//! Tool list projection — thin shim over the v2 catalog.
//!
//! In ARIA v2 the canonical tool surface is defined by `crate::v2::catalog`.
//! This module retains the two environment-reading helpers (`vault_enabled`,
//! `memory_enabled`) that are called from dispatcher.rs, dispatch.rs, and
//! v2/catalog.rs, and delegates `build_tool_list` to the v2 catalog.

/// True when the vault MCP tool surface is enabled.
///
/// Reads `MOOTX01_VAULT` from the process environment. Any value other than
/// the literal string `"0"` (including absent/empty) means vault is ON.
/// The daemon has this variable set from the install-time `--vault-on/--vault-off`
/// choice. Default is vault-on.
pub fn vault_enabled() -> bool {
    std::env::var("MOOTX01_VAULT")
        .map(|v| v != "0")
        .unwrap_or(true) // absent = vault-on (the default)
}

/// True when the Anthropic memory adapter tool is enabled.
///
/// Opt-in: requires `MOOTX01_MEMORY_TOOL=1`.
/// Default (absent or any value other than "1") is OFF.
pub fn memory_enabled() -> bool {
    std::env::var("MOOTX01_MEMORY_TOOL")
        .map(|v| v == "1")
        .unwrap_or(false) // absent = off (the default)
}

/// Return the set of argument keys for a named v2 tool.
///
/// Returns `None` when the tool name is not in the v2 catalog. Used by the
/// dispatch hot-path to validate argument names before routing — mirrors Swift
/// `ToolProjection.acceptedArgKeys(for:)`.
pub fn accepted_arg_keys(name: &str) -> Option<std::collections::HashSet<String>> {
    let tools = crate::v2::catalog::selected_tools();
    let arr = tools.as_array()?;
    let tool = arr.iter().find(|t| t["name"].as_str() == Some(name))?;
    let properties = tool["inputSchema"]["properties"].as_object()?;
    Some(properties.keys().cloned().collect())
}

/// Build the v2 tool surface for `tools/list`.
///
/// Delegates to `crate::v2::catalog::selected_tools()` which reads
/// `vault_enabled()` to decide whether to include the vault-gated tools.
/// Returns 80 tools when vault is on (the default) or 73 tools when
/// `MOOTX01_VAULT=0`.
pub fn build_tool_list() -> serde_json::Value {
    crate::v2::catalog::selected_tools()
}
