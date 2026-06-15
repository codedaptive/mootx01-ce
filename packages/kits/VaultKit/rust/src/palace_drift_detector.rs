//! palace_drift_detector — diffs the live MemPalace tool surface against the
//! pump's expected manifest. Rust parallel of the Swift `PalaceDriftDetector`.
//! Fixes the benchmarker's GAP F (no drift detection).
//!
//! At pump start the orchestrator calls `tools/list` and diffs the live
//! surface against the tools+args the pump was written for. If a tool was
//! renamed/removed, a required arg the pump depends on disappeared, or a NEW
//! required arg appeared that the pump does not supply, the pump HALTS with a
//! precise diff rather than writing garbage. Only NAME presence and
//! REQUIRED-arg facts are asserted (added optional args are forward-compatible).

use std::collections::BTreeSet;

/// One tool the pump depends on, with the argument facts a faithful call
/// requires. Mirrors Swift `PalaceExpectedTool`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PalaceExpectedTool {
    /// The MCP tool name.
    pub name: String,
    /// The arguments the pump treats as required (removal is breaking drift).
    pub required_args: BTreeSet<String>,
    /// Every argument the pump can supply (a live required arg outside this
    /// set is breaking drift).
    pub supplied_args: BTreeSet<String>,
}

/// The live shape of one tool from `tools/list`: its name and its
/// `inputSchema.required` set. Mirrors Swift `PalaceLiveTool`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PalaceLiveTool {
    /// The live MCP tool name.
    pub name: String,
    /// The live `inputSchema.required` argument names.
    pub required_args: BTreeSet<String>,
}

/// Error surfaced when the tools/list payload itself cannot be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PalaceDriftError {
    UnreadableToolsList,
}

impl std::fmt::Display for PalaceDriftError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "unreadable tools/list payload")
    }
}

impl std::error::Error for PalaceDriftError {}

impl PalaceLiveTool {
    /// Parse the live tools from a `tools/list` result JSON. Accepts either the
    /// bare result object (`{ "tools": [...] }`) or a JSON-RPC envelope
    /// (`{ "result": { "tools": [...] } }`). Tolerant of extra keys.
    pub fn parse(tools_list_json: &[u8]) -> Result<Vec<PalaceLiveTool>, PalaceDriftError> {
        let root: serde_json::Value =
            serde_json::from_slice(tools_list_json).map_err(|_| PalaceDriftError::UnreadableToolsList)?;
        let tools = root
            .get("tools")
            .or_else(|| root.get("result").and_then(|r| r.get("tools")))
            .and_then(|t| t.as_array())
            .ok_or(PalaceDriftError::UnreadableToolsList)?;
        let mut out = Vec::new();
        for entry in tools {
            let name = match entry.get("name").and_then(|v| v.as_str()) {
                Some(n) => n.to_owned(),
                None => continue,
            };
            let required = entry
                .get("inputSchema")
                .and_then(|s| s.get("required"))
                .and_then(|r| r.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(|s| s.to_owned()))
                        .collect::<BTreeSet<String>>()
                })
                .unwrap_or_default();
            out.push(PalaceLiveTool {
                name,
                required_args: required,
            });
        }
        Ok(out)
    }
}

/// A single drift finding — what changed, named precisely. Mirrors Swift
/// `PalaceDriftFinding`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PalaceDriftFinding {
    /// An expected tool is absent from the live surface (renamed/removed).
    ToolMissing { name: String },
    /// An arg the pump treats as required is no longer required live.
    RequiredArgRemoved { tool: String, arg: String },
    /// The live schema requires an arg the pump does not supply.
    NewRequiredArgUnsupplied { tool: String, arg: String },
}

impl std::fmt::Display for PalaceDriftFinding {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PalaceDriftFinding::ToolMissing { name } => write!(
                f,
                "tool '{name}' is missing from the live MemPalace surface (renamed or removed)"
            ),
            PalaceDriftFinding::RequiredArgRemoved { tool, arg } => write!(
                f,
                "tool '{tool}' no longer requires '{arg}' that the pump depends on"
            ),
            PalaceDriftFinding::NewRequiredArgUnsupplied { tool, arg } => write!(
                f,
                "tool '{tool}' now requires '{arg}', which the pump does not supply"
            ),
        }
    }
}

/// The manifest the pump is written against — the tools it drives and the arg
/// facts a faithful call depends on. Verified against the live mempalace-mcp
/// surface (v3.3.3, 2026-06). Mirrors Swift `expectedManifest`.
pub fn expected_manifest() -> Vec<PalaceExpectedTool> {
    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }
    vec![
        // --- write tools, one per noun ---
        PalaceExpectedTool {
            name: "mempalace_add_drawer".to_owned(),
            required_args: set(&["wing", "room", "content"]),
            supplied_args: set(&["wing", "room", "content", "source_file", "added_by"]),
        },
        PalaceExpectedTool {
            name: "mempalace_create_tunnel".to_owned(),
            required_args: set(&["source_wing", "source_room", "target_wing", "target_room"]),
            supplied_args: set(&[
                "source_wing",
                "source_room",
                "target_wing",
                "target_room",
                "source_drawer_id",
                "target_drawer_id",
                "label",
            ]),
        },
        PalaceExpectedTool {
            name: "mempalace_kg_add".to_owned(),
            required_args: set(&["subject", "predicate", "object"]),
            supplied_args: set(&["subject", "predicate", "object", "valid_from", "source_closet"]),
        },
        PalaceExpectedTool {
            name: "mempalace_diary_write".to_owned(),
            required_args: set(&["agent_name", "entry"]),
            supplied_args: set(&["agent_name", "entry", "topic", "wing"]),
        },
        // --- read / verify tools ---
        PalaceExpectedTool {
            name: "mempalace_get_drawer".to_owned(),
            required_args: set(&["drawer_id"]),
            supplied_args: set(&["drawer_id"]),
        },
        PalaceExpectedTool {
            name: "mempalace_list_tunnels".to_owned(),
            required_args: set(&[]),
            supplied_args: set(&["wing", "room", "limit", "offset"]),
        },
        PalaceExpectedTool {
            name: "mempalace_kg_query".to_owned(),
            required_args: set(&["entity"]),
            supplied_args: set(&["entity", "limit"]),
        },
        PalaceExpectedTool {
            name: "mempalace_diary_read".to_owned(),
            required_args: set(&["agent_name"]),
            supplied_args: set(&["agent_name", "topic", "limit"]),
        },
        PalaceExpectedTool {
            name: "mempalace_list_drawers".to_owned(),
            required_args: set(&[]),
            supplied_args: set(&["wing", "room", "limit", "offset"]),
        },
        PalaceExpectedTool {
            name: "mempalace_search".to_owned(),
            required_args: set(&["query"]),
            supplied_args: set(&["query", "limit", "wing", "room", "max_distance", "context"]),
        },
    ]
}

/// Diff the live tools against an expected manifest. Returns every finding in a
/// deterministic order (manifest order, then arg name). An empty result means
/// the live surface satisfies the pump's assumptions.
pub fn diff(live: &[PalaceLiveTool], expected: &[PalaceExpectedTool]) -> Vec<PalaceDriftFinding> {
    let mut findings = Vec::new();
    for tool in expected {
        let live_tool = match live.iter().find(|t| t.name == tool.name) {
            Some(t) => t,
            None => {
                findings.push(PalaceDriftFinding::ToolMissing {
                    name: tool.name.clone(),
                });
                continue;
            }
        };
        // A required arg the pump depends on must still be required. BTreeSet
        // iterates in sorted order, so findings are deterministic.
        for arg in &tool.required_args {
            if !live_tool.required_args.contains(arg) {
                findings.push(PalaceDriftFinding::RequiredArgRemoved {
                    tool: tool.name.clone(),
                    arg: arg.clone(),
                });
            }
        }
        // A live required arg the pump cannot supply is breaking.
        for arg in &live_tool.required_args {
            if !tool.supplied_args.contains(arg) {
                findings.push(PalaceDriftFinding::NewRequiredArgUnsupplied {
                    tool: tool.name.clone(),
                    arg: arg.clone(),
                });
            }
        }
    }
    findings
}
