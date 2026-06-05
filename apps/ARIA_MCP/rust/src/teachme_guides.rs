//! TeachmeGuides — per-tool usage guides returned when `teachme:true`.
//!
//! Mirrors Swift `TeachmeGuides.swift`. When any tool is called with
//! `teachme:true` in its arguments, `dispatch.rs` intercepts the call before
//! any runner fires and returns the guide for that tool name.
//!
//! Each guide covers: what the tool does, required and optional arguments,
//! a usage example, and common mistakes. Content mirrors Swift TeachmeGuides.swift
//! at ≥80% fidelity (structure preserved; some details abbreviated).

/// Return the teachme guide for `tool_name`, or a generic fallback.
///
/// Called by `dispatch.rs` when `args["teachme"] == true`. Returns a static
/// string; the caller wraps it in `text_result`. Estate is never touched.
pub fn guide(tool_name: &str) -> &'static str {
    match tool_name {
        // Tier 1 — Core memory
        "moot_file_memory" => GUIDE_FILE_MEMORY,
        "moot_memory_search" => GUIDE_MEMORY_SEARCH,
        "moot_update_memory" => GUIDE_UPDATE_MEMORY,
        "moot_withdraw_memory" => GUIDE_WITHDRAW_MEMORY,
        "moot_erase_memory" => GUIDE_ERASE_MEMORY,
        "moot_confirm_memory" => GUIDE_CONFIRM_MEMORY,
        "moot_move_memory" => GUIDE_MOVE_MEMORY,
        // Tier 2 — Connections
        "moot_link_memories" => GUIDE_LINK_MEMORIES,
        "moot_connection_search" => GUIDE_CONNECTION_SEARCH,
        "moot_connection_map" => GUIDE_CONNECTION_MAP,
        // Tier 3 — Knowledge graph
        "moot_file_fact" => GUIDE_FILE_FACT,
        "moot_fact_search" => GUIDE_FACT_SEARCH,
        "moot_retire_fact" => GUIDE_RETIRE_FACT,
        "moot_fact_timeline" => GUIDE_FACT_TIMELINE,
        // Tier 4 — Journal
        "moot_write_journal" => GUIDE_WRITE_JOURNAL,
        "moot_read_journal" => GUIDE_READ_JOURNAL,
        // Tier 5 — Estate
        "moot_estate_status" => GUIDE_ESTATE_STATUS,
        "moot_estate_map" => GUIDE_ESTATE_MAP,
        "moot_estate_ping" => GUIDE_ESTATE_PING,
        // Federation
        "moot_federated_search" => GUIDE_FEDERATED_SEARCH,
        // Generic fallbacks for prefixed groups
        _ if tool_name.starts_with("moot_lens_") => GUIDE_LENS_GENERIC,
        _ if matches!(
            tool_name,
            "moot_list_lenses"
                | "moot_synthesize"
                | "moot_run_migration"
                | "moot_confirm_migration"
        ) =>
        {
            GUIDE_RECIPE_GENERIC
        }
        _ if tool_name.starts_with("moot_vault_") => GUIDE_VAULT_GENERIC,
        _ => GUIDE_GENERIC,
    }
}

// ---------------------------------------------------------------------------
// Tier 1 — Core memory
// ---------------------------------------------------------------------------

const GUIDE_FILE_MEMORY: &str = "\
moot_file_memory — store a memory in the estate

Required args:
  content  (string) the text to store
  location (string) room path, e.g. \"projects/notes\"

Example:
  { \"content\": \"Meeting notes from standup\", \"location\": \"work/meetings\" }

Response: \"filed memory <id>\\nroom: <room>\\nlineage: <uuid>\"

Mistakes:
  — Sending udcCode, embeddingModelID, or latticeAnchor: server owns these fields.
  — Sending an empty content string (rejected by substrate).";

const GUIDE_MEMORY_SEARCH: &str = "\
moot_memory_search — search memories by keyword

Required args:
  query (string) keyword or phrase to match against content and room

Example:
  { \"query\": \"meeting notes\" }

Response: \"found N memory(s)\\n<id>  [<room>]  <content_preview>\"

Mistakes:
  — Queries over 200 characters trigger a hint to shorten the query.
  — Zero results usually means the estate is empty or the query is too specific.";

const GUIDE_UPDATE_MEMORY: &str = "\
moot_update_memory — apply a named mutation to a memory

Required args:
  id       (string) drawer ID returned by moot_file_memory
  mutation (string) one of: confirm, reject, contest, resolve, supersede, revive, accept

Example:
  { \"id\": \"<uuid>\", \"mutation\": \"confirm\" }

Response: \"updated memory <id> (<mutation>)\"

Mistakes:
  — Using unknown mutation names returns invalidParams.
  — The preferred path for user confirmation is moot_confirm_memory.";

const GUIDE_WITHDRAW_MEMORY: &str = "\
moot_withdraw_memory — soft-delete a memory (reversible via revive)

Required args:
  id     (string) drawer ID to withdraw

Optional args:
  reason (string) why this memory was withdrawn

Example:
  { \"id\": \"<uuid>\", \"reason\": \"outdated\" }

Response: \"withdrew memory <id>\"

Mistakes:
  — Withdraw is reversible. Use moot_erase_memory for permanent deletion.";

const GUIDE_ERASE_MEMORY: &str = "\
moot_erase_memory — permanently delete a memory (irreversible)

Required args:
  id        (string) drawer ID to erase
  reason    (string) why this memory is being erased
  confirmed (bool)   must be true

Example:
  { \"id\": \"<uuid>\", \"reason\": \"personal data request\", \"confirmed\": true }

Response: \"erased memory <id>\"

Mistakes:
  — Omitting confirmed or sending confirmed:false returns isError:true.
  — This action cannot be undone. Use moot_withdraw_memory for recoverable deletion.";

const GUIDE_CONFIRM_MEMORY: &str = "\
moot_confirm_memory — mark a memory as user-confirmed

Required args:
  id (string) drawer ID to confirm

Example:
  { \"id\": \"<uuid>\" }

Response: \"confirmed memory <id>\"

Notes:
  — Confirmed memories pass the userConfirmed filter in searches.
  — Equivalent to moot_update_memory with mutation:confirm.";

const GUIDE_MOVE_MEMORY: &str = "\
moot_move_memory — move a memory to a different room

Required args:
  id       (string) drawer ID to move
  location (string) new room path, e.g. \"archive/2024\"

Example:
  { \"id\": \"<uuid>\", \"location\": \"archive/2024\" }

Response: \"moved memory <id> to <location>\"";

// ---------------------------------------------------------------------------
// Tier 2 — Connections
// ---------------------------------------------------------------------------

const GUIDE_LINK_MEMORIES: &str = "\
moot_link_memories — create a typed directional tunnel between two memories

Required args:
  from_id (string) source drawer ID
  to_id   (string) target drawer ID
  kind    (string) one of: references, supersedes, blocks, validates,
                   contradicts, derivesFrom, covers, elaborates, respondsTo

Example:
  { \"from_id\": \"<uuid-a>\", \"to_id\": \"<uuid-b>\", \"kind\": \"elaborates\" }

Response: \"linked <from_id> → <to_id> via <kind> (<tunnel_id>)\"

Mistakes:
  — Both from_id and to_id must exist in the estate.
  — Unknown kind strings default to references.";

const GUIDE_CONNECTION_SEARCH: &str = "\
moot_connection_search — list outgoing tunnels from a memory

Required args:
  from_id (string) source drawer ID

Example:
  { \"from_id\": \"<uuid>\" }

Response: \"connections from <id>: N\\n  <tunnel_id> [<label>] → <target_id>\"";

const GUIDE_CONNECTION_MAP: &str = "\
moot_connection_map — list incoming tunnels to a memory

Required args:
  to_id (string) target drawer ID

Example:
  { \"to_id\": \"<uuid>\" }

Response: \"connections to <id>: N\\n  <tunnel_id> [<label>] ← <source_id>\"";

// ---------------------------------------------------------------------------
// Tier 3 — Knowledge graph
// ---------------------------------------------------------------------------

const GUIDE_FILE_FACT: &str = "\
moot_file_fact — store a structured subject-predicate-object fact

Required args:
  subject   (string) the entity this fact is about
  predicate (string) the relationship or property
  object    (string) the value or target entity

Optional args:
  source_id (string) drawer ID that grounds this fact

Example:
  { \"subject\": \"Alice\", \"predicate\": \"worksAt\", \"object\": \"Acme Corp\" }

Response: \"filed fact <id>: [<subject>] <predicate> [<object>]\"

Notes:
  — Facts are immutable once filed; use moot_retire_fact to retract.
  — Currently requires a pending write-path mission in the Rust port.";

const GUIDE_FACT_SEARCH: &str = "\
moot_fact_search — search KG facts by subject, predicate, or object

Optional args:
  query (string) substring match across all three fields

Example:
  { \"query\": \"Alice\" }

Response: \"facts matching \\\"<query>\\\": N\" or \"facts: N\"";

const GUIDE_RETIRE_FACT: &str = "\
moot_retire_fact — retract a KG fact (soft-delete)

Required args:
  id (string) fact ID returned by moot_file_fact

Example:
  { \"id\": \"<uuid>\" }

Response: \"retired fact <id>\"

Notes:
  — Currently requires a pending write-path mission in the Rust port.";

const GUIDE_FACT_TIMELINE: &str = "\
moot_fact_timeline — view KG facts in chronological order

Optional args:
  entity (string) filter to facts mentioning this entity in subject or object

Example:
  { \"entity\": \"Alice\" }

Response: \"fact timeline: N\\n  <timestamp> | [<subject>] <predicate> [<object>]\"";

// ---------------------------------------------------------------------------
// Tier 4 — Journal
// ---------------------------------------------------------------------------

const GUIDE_WRITE_JOURNAL: &str = "\
moot_write_journal — write a journal entry for this session

Required args:
  entry (string) the journal text (NOT content — the field is named entry)

Optional args:
  agent (string) actor identifier, default \"mcp-agent\"

Example:
  { \"entry\": \"Completed analysis of Q1 metrics\" }

Response: \"wrote journal entry for <agent>\"

Mistakes:
  — Sending content instead of entry returns isError:true (missing required arg).
  — Currently requires a pending write-path mission in the Rust port.";

const GUIDE_READ_JOURNAL: &str = "\
moot_read_journal — read recent journal entries

Optional args:
  agent  (string)  actor to read for, default \"mcp-agent\"
  last_n (integer) max entries to return, default 10

Example:
  { \"last_n\": 5 }

Response: \"journal for <agent>: N entry(s)\\n  <timestamp> | <entry_preview>\"";

// ---------------------------------------------------------------------------
// Tier 5 — Estate
// ---------------------------------------------------------------------------

const GUIDE_ESTATE_STATUS: &str = "\
moot_estate_status — get estate metadata and health summary

Optional args:
  estateID (string) defaults to the default estate
  teachme  (bool)   true returns this guide without touching the estate

Returns: estate name, drawer count, KG fact count, wing list, plus the ARIA
session protocol block.

Tips:
  — Call moot_estate_status with teachme:true for a full orientation on first connect.
  — Wing list helps you navigate to specific areas with moot_memory_search.";

const GUIDE_ESTATE_MAP: &str = "\
moot_estate_map — show memory taxonomy grouped by wing and room

Returns: a tree of wing → room → count, summarizing where memories live.

Example response:
  estate map: 42 drawer(s)
    wing_alice/
      work: 12
      personal: 8
  ...";

const GUIDE_ESTATE_PING: &str = "\
moot_estate_ping — verify the estate connection is live

Returns: \"pong: estate <name> [<uuid>] is live\"

Tips:
  — Use after a long pause to confirm the session handle is still valid.
  — A successful ping means the estate can accept further operations.";

// ---------------------------------------------------------------------------
// Federation
// ---------------------------------------------------------------------------

const GUIDE_FEDERATED_SEARCH: &str = "\
moot_federated_search — search across multiple estates simultaneously

Note: federation requires the grant model which is not yet implemented
in the Rust server. Use moot_memory_search within a single estate
while federation is unavailable.";

// ---------------------------------------------------------------------------
// Generic fallbacks
// ---------------------------------------------------------------------------

const GUIDE_LENS_GENERIC: &str = "\
This is a reasoning-lens tool. Lens tools run cognition algorithms over
the memories in your estate to surface patterns, themes, structure,
and temporal dynamics.

Call moot_list_lenses to see all available lenses with descriptions.
Add teachme:true to any specific lens to learn its arguments.";

const GUIDE_RECIPE_GENERIC: &str = "\
This is a recipe tool. Recipe tools compose multiple lenses and memory
operations into named workflows.

Call moot_list_lenses to see all available lenses and recipes.
Add teachme:true to any specific recipe to learn its arguments.";

const GUIDE_VAULT_GENERIC: &str = "\
This is a vault tool. Vault tools handle estate export, import, and
reconciliation.

Note: vault tools are advertised but return methodNotFound until
VaultKit-Rust ships (ADR-VAULTKIT-002).";

const GUIDE_GENERIC: &str = "\
No teachme guide is available for this tool.
Call moot_estate_status with teachme:true for a full orientation guide.";
