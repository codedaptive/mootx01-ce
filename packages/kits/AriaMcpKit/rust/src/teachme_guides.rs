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
        "moot_memory_list" => GUIDE_MEMORY_LIST,
        "moot_memory_get" => GUIDE_MEMORY_GET,
        "moot_update_memory" => GUIDE_UPDATE_MEMORY,
        "moot_withdraw_memory" => GUIDE_WITHDRAW_MEMORY,
        "moot_erase_memory" => GUIDE_ERASE_MEMORY,
        "moot_confirm_memory" => GUIDE_CONFIRM_MEMORY,
        "moot_move_memory" => GUIDE_MOVE_MEMORY,
        // Tier 2 — Connections
        "moot_link_memories" => GUIDE_LINK_MEMORIES,
        "moot_review_tunnel" => GUIDE_REVIEW_TUNNEL,
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
        // Monitoring control
        "moot_monitoring_status" => GUIDE_MONITORING_STATUS,
        // Federation
        "moot_federated_search" => GUIDE_FEDERATED_SEARCH,
        // Maintenance
        "moot_palace_import" => GUIDE_PALACE_IMPORT,
        // Recipe — contradiction hunter (on-demand sweep)
        "moot_hunt_contradictions" => GUIDE_HUNT_CONTRADICTIONS,
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
  subject  (string) one sentence (≤120 chars) stating what the memory
           asserts — written for the NEXT AI that will scan it in a
           result list: telegraphic register, entities and claims
           front-loaded, no narrative framing. Returned in recall rows,
           never searched.
  location (string) room path, e.g. \"projects/notes\"

Example:
  { \"content\": \"Meeting notes from standup\",
    \"subject\": \"Standup: release slips one week; QA owns the gate.\",
    \"location\": \"work/meetings\" }

Response: \"filed memory <id>\\nroom: <room>\\nlineage: <uuid>\"

Mistakes:
  — Sending udcCode, embeddingModelID, or latticeAnchor: server owns these fields.
  — Sending an empty content string (rejected by substrate).
  — Writing the subject as a title (\"Meeting notes\") instead of an
    assertion (\"Release slips one week\").
  — Truncating the subject mid-sentence: compress the claim, don't cut it.";

const GUIDE_MEMORY_SEARCH: &str = "\
moot_memory_search — search memories by keyword, or pivot with near:<uuid>

Args (exactly one of):
  query (string) keyword or phrase — hybrid BM25+vector recall
  near  (string) UUID of an anchor memory — returns the memories most
        similar to it (the anchor itself is excluded)

Example:
  { \"query\": \"meeting notes\" }
  { \"near\": \"<uuid>\" }

Response: \"found N memory(s)\" then one DENSE ROW per hit:
  <uuid> · <subject> · fdc:<code> · qid:<QID> · <event_time>
Travel on subjects; fetch bodies via moot_memory_get
(depth:subject|distilled|full). \"(no subject)\" rows are subject debt.
A discrimination line appears ONLY when the ranking is not clear
(low/medium); a recall_provenance line ONLY when the dense lane was dark
or stages degraded. Silence means nominal.

Mistakes:
  — Queries over 200 characters trigger a hint to shorten the query.
  — Passing both query and near: they are mutually exclusive.
  — Zero results usually means the estate is empty or the query is too specific.";

const GUIDE_MEMORY_LIST: &str = "\
moot_memory_list — enumerate all memory drawer IDs in a wing

Returns one dense row per drawer — uuid · subject · fdc · qid ·
event_time. Capped at 200 results. Use for structural inventory, not
semantic search.

When to use vs siblings:
  — moot_memory_search: when you need ranked semantic results by query
  — moot_memory_get:    when you already have an ID and need the full record
  — moot_estate_map:    when you want wing/room counts, not individual IDs

Required args:
  wing (string) wing name to enumerate, e.g. \"Agentic Memory\"

Optional args:
  room   (string) further narrow to a single room within the wing
  filter (string) missing_subject — the subject-debt enumerator: lists
         only live drawers with no subject line, id-only (no preview).
         Walk them with moot_memory_get, then write each subject via
         moot_update_memory mutation=setSubject.

Example:
  { \"wing\": \"Agentic Memory\" }
  { \"wing\": \"Agentic Memory\", \"room\": \"architecture\" }
  { \"wing\": \"Agentic Memory\", \"filter\": \"missing_subject\" }

Response: \"drawers in wing <wing>: N\" then one dense row per drawer.

Mistakes:
  — Calling without wing: wing is required; omitting it returns an error.
  — Using this as a search tool: it is a structural enumerator; use
    moot_memory_search for semantic recall.
  — Expecting more than 200 results: for large wings, filter by room.";

const GUIDE_MEMORY_GET: &str = "\
moot_memory_get — fetch memory drawers by id, at a chosen depth

One hydration verb, three tiers (depth argument): subject (dense row
only — travel), distilled (dense row + distilled text; fallback rows
carry \"source: content (not yet distilled)\" then verbatim content),
full (default — the complete record). Batch with ids:[…] to winnow a
shortlist in ONE call.

At depth:full, returns verbatim content (never truncated), room/wing,
subject (when present), filed_at and event_time, the adjective-axis
metadata (state, trust, sensitivity, exportability, confirmation),
lineage, and a linked-tunnel summary.
Applies the same default gate as moot_memory_search — a drawer that
exists but is contested/withdrawn/rejected, untrustworthy, or
restricted/secret is reported not-found, identical to a genuinely
absent id. This tool cannot be used to bypass that gate.

When to use vs siblings:
  — moot_memory_search: when you don't yet have an id, or want a ranked
    set of candidates
  — moot_recollect: when fanning out from a distilled factoid to its
    source memories, not a single known id

Required args:
  id (string) drawer UUID returned by moot_file_memory or moot_memory_search

Example:
  { \"id\": \"abc-123\" }

Response: \"memory <id>\\nroom: <room>  wing: <wing>\\nfiled_at: ...\\n\
event_time: ...\\nstate: ...\\ntrust: ...\\nsensitivity: ...\\n\
exportability: ...\\nconfirmation: ...\\nlineage: <uuid>\\ntunnels: N\\n  \
→ <other-id>  [<kind>]\\ncontent:\\n<verbatim content>\"

Mistakes:
  — Calling with an id that does not exist, or one not already found via
    moot_memory_search. Search first.
  — Expecting a found result for a withdrawn/erased/restricted drawer.
    The gate reports it not-found, same as a genuinely absent id — this
    is deliberate, not a bug.";

const GUIDE_UPDATE_MEMORY: &str = "\
moot_update_memory — apply a named mutation to a memory

Required args:
  id       (string) drawer ID returned by moot_file_memory
  mutation (string) one of: confirm, reject, contest, resolve, supersede,
           revive, accept, correctExportability(public),
           correctExportability(private), setSubject

Optional args:
  subject (string) required for mutation=setSubject, ignored otherwise:
          one sentence (≤120 chars) in the AI-facing register —
          telegraphic, entities and claims front-loaded. This is the
          backfill/correction path for subject-debt rows found via
          moot_memory_list filter:missing_subject.

Example:
  { \"id\": \"<uuid>\", \"mutation\": \"confirm\" }
  { \"id\": \"<uuid>\", \"mutation\": \"setSubject\",
    \"subject\": \"Deploy pipeline: staging gate now requires two approvals.\" }

Response: \"updated memory <id> (<mutation>)\"

Mistakes:
  — Using unknown mutation names returns invalidParams.
  — The preferred path for user confirmation is moot_confirm_memory.
  — Passing the subject text in `note` for setSubject: it goes in the
    dedicated `subject` argument.";

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

Optional args:
  proposed (bool) file the link as a PROPOSED (agent-derived, unreviewed)
                  edge instead of an active one — use when adjudicating
                  borderline candidates from moot_hunt_contradictions.
                  The user settles it via moot_review_tunnel. Default false.

Example:
  { \"from_id\": \"<uuid-a>\", \"to_id\": \"<uuid-b>\", \"kind\": \"elaborates\" }

Response: \"linked <from_id> → <to_id> via <kind> (<tunnel_id>)\"

Mistakes:
  — Both from_id and to_id must exist in the estate.
  — Unknown kind strings are rejected (invalidParams), not defaulted.
  — Filing an ACTIVE contradicts edge for a merely-suspected conflict;
    use proposed:true so the user gets to review it.";

const GUIDE_REVIEW_TUNNEL: &str = "\
moot_review_tunnel — settle a PROPOSED connection: accept or reject

Proposed edges come from the contradiction hunter (background scout,
moot_dream sweep, or moot_hunt_contradictions) and from agent-filed
moot_link_memories proposed:true links. Accept activates the edge;
reject withdraws it PERMANENTLY — a rejected pair is never re-proposed.

Required args:
  tunnel_id (string) tunnel ID (shown by moot_lens_contradiction)
  verdict   (string) \"accept\" or \"reject\"

Optional args:
  reason (string) note explaining the verdict

Example:
  { \"tunnel_id\": \"<uuid>\", \"verdict\": \"accept\" }

Mistakes:
  — Rejecting to \"snooze\" a finding: rejection is durable.
  — Reviewing an active or withdrawn tunnel; only proposed ones qualify.";

const GUIDE_HUNT_CONTRADICTIONS: &str = "\
moot_hunt_contradictions — hunt memory content for contradictions

One bounded sweep: finds lexically-near memory pairs via the corpus
keyword (BM25) index, screens each pair with a lexical conflict cue
(negation asymmetry, value divergence, revision markers), then:
  — STRONG findings persist as PROPOSED contradicts links; settle them
    with moot_review_tunnel.
  — BORDERLINE pairs are RETURNED with snippets for YOU to judge; if a
    pair genuinely conflicts, record it with moot_link_memories
    kind=contradicts proposed=true.

Optional args:
  probe_limit (int)    max vector-indexed memories probed (default 500)
  now         (string) ISO8601 instant for deterministic runs

Requires the corpus search index — run moot_reindex after bulk import.
Rejected and already-linked pairs are deduplicated (never re-proposed).";

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
  — source_id is optional but recommended when a supporting memory exists.";

const GUIDE_FACT_SEARCH: &str = "\
moot_fact_search — search KG facts by subject, predicate, or object

Optional args:
  query (string) substring match across all three fields
  subject_exact, predicate_exact, object_exact, source_id_exact (string)
    case-sensitive exact filters; filters combine
  limit (integer) default 100, maximum 500

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
  — Retired facts are excluded from moot_fact_search but remain visible
    in moot_fact_timeline for audit purposes.";

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
  — Omitting agent leaves the entry under the default \"mcp-agent\" identity,
    which may not match across sessions; pass an explicit agent name for
    reliable journal continuity.";

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

Returns: estate name, drawer count, subject-debt counter
(\"subjects: N/M (K missing)\"), KG fact count, wing list, plus the ARIA
session protocol block.

Subject debt — STANDING BEHAVIOR: when K > 0, offer the user an
interactive backfill, and only proceed with their explicit
time-and-permission consent. The walk: moot_memory_list
filter:missing_subject → moot_memory_get per id → moot_update_memory
mutation=setSubject with a one-sentence AI-facing subject. Never
backfill silently; the debt line is a reminder, not a license.

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
moot_federated_search — grant-authorized cross-estate federated search

Fans across all locally-open estates the requester holds an active grant
for. Each estate's contribution is narrowed to the grant's scope. Results
carry custody metadata (custody mode, budget debit) and hydration is
fail-closed (missing bodies are omitted, not fabricated).

ANTI-SPOOF: requesterEstateID is optional (Item 2 hardening). When omitted
the requester is always the default (authenticated caller) estate. When
supplied it must match the default estate's UUID exactly — supplying a
different UUID is refused to prevent cross-estate identity spoofing.

Optional args:
  requesterEstateID (string)  Optional UUID of the calling estate. Omit to use
                              the default. Must match the default estate if supplied.
  filter         (string)  userConfirmed | unconfirmed | exportable | contained; omit for ordinary recall
  hydrationLevel (string)  full | structured | bitmapOnly (default: full)
  limit          (integer) max memories per estate (default: 20)

Example (omit requesterEstateID — the default is used automatically):
  { \"filter\": \"userConfirmed\", \"limit\": 20 }

Response:
  estate <name> [<uuid>] — grant <uuid>, N row(s)
  <uuid>  [room]  <content preview…>

Custody modes supported: immediate, timeAging (confidence decays with age),
and budget-debited (each recall deducts from a configured budget).

Mistakes:
  — Supplying a requesterEstateID that doesn't match the default estate;
    the call is refused with an error. Omit the field instead.
  — Expecting results from estates with no active grant naming you;
    the call returns a clean refusal when no grant authorizes access.";

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
This is a vault tool. Vault tools manage estate export, import, and
reconciliation against a filesystem vault archive.

Workflow:
  — moot_vault_export    export the estate to a vault archive
  — moot_vault_import    import a previously exported archive
  — moot_vault_status    inspect the vault archive state
  — moot_vault_reconcile detect drift between the live estate and archive

Reconcile two-step workflow:
  1. moot_vault_reconcile vaultPath=<path>
     Dry-run: reports added/modified/deleted candidates without writing anything.
  2. moot_vault_reconcile vaultPath=<path> apply=true
     Apply: imports the added and modified candidates into the estate synchronously.
     Deleted files are always reported only; no drawer is expunged.

All vault tools require a vaultPath argument (absolute filesystem path to
the vault directory). Add teachme:true to any specific vault tool for its
full argument reference.";

// ---------------------------------------------------------------------------
// Monitoring control
// ---------------------------------------------------------------------------

const GUIDE_MONITORING_STATUS: &str = "\
moot_monitoring_status — read or set the daemon telemetry monitoring flag

No args → read path (no mutation):
  {}  →  \"monitoring: enabled\"   or   \"monitoring: disabled\"
        \"monitoring: unavailable\"  when no telemetry store is wired (stdio
        transport, test harnesses, provision-less contexts).

Optional arg:
  enabled (bool)  write path — persists flag, echoes new state.
    { \"enabled\": true }   →  \"monitoring: enabled\\nmonitoring_source: user\"
    { \"enabled\": false }  →  \"monitoring: disabled\\nmonitoring_source: user\"
    monitoring_source: user distinguishes operator changes from env-var / default seeds.

Note:
  \"unavailable\" ≠ \"disabled\" — unavailable means no telemetry store is wired.
  Never substitute unavailable for disabled in your reasoning.
  The flag is daemon-global; the tool resolves the estate for routing only.";

// ---------------------------------------------------------------------------
// Maintenance
// ---------------------------------------------------------------------------

const GUIDE_PALACE_IMPORT: &str = "\
moot_palace_import — import a MemPalace directly into the estate

Required args:
  palace_path (string) the MemPalace ROOT dir (the one CONTAINING palace/)

Optional args:
  mode (string) encode SPEED: \"foreground\" (default) drains the encode
        queue hard on the performance cores; \"background\" drains gently
        (for very large imports). The write strategy (bulk transaction vs
        stream) is chosen automatically by source size — you do not set it.

Reads palace/chroma.sqlite3 (drawers), tunnels.json (connections), and
knowledge_graph.sqlite3 (KG facts). Idempotent: re-importing an unchanged
palace writes zero drawers.

Post-import (AUTOMATIC — do NOT tell the user to run reindex/dream): the
import triggers its own indexing in the background — it enqueues the
encode/index work, the encode drain turns it into the BM25 + vector lanes, and
then it retrains the corpus embedding-basis on the WHOLE import; the resident
daemon's dreaming duty builds the association matrix on its cadence. Poll
moot_drain_status to watch the encode queue converge.

RECALL LIGHTS UP IN STAGES — this matters for what you can trust right after an
import: keyword (exact-term) and structured (wing/room) recall work almost
immediately, but full SEMANTIC / vector recall (meaning-based RAG search) is
available only AFTER the basis retrain finishes. A just-imported term that
appears only in a later chunk batch reads dense_lane:dark:vocabMiss until the
retrain republishes the basis with the full vocabulary. So on a fresh import be
patient: poll moot_drain_status until idle before relying on semantic search
over the imported memories, and tell the user that deep meaning-based recall
over a fresh import becomes available shortly after import (tens of seconds to a
few minutes on a large one), not instantly.

moot_reindex and moot_dream remain available to re-trigger on demand but are
NOT a required follow-up. (Running WITHOUT a resident daemon? Then run
moot_dream yourself for matrix-aware recall/distillation — only the resident
builds the matrix automatically.)

Use moot_vault_import instead for a Markdown/Obsidian vault.

Long imports: this call returns only when the import finishes, and a large
import can run for many minutes. If your client supports
sub-agents or background execution, run this call in one so your main
session stays responsive. Live per-record progress goes to the server's
stderr log, not to this call's response (which carries only the summary). To
watch the background encode queue converge after this call returns, poll
moot_drain_status — it reports the encode drain's pending + in-flight counts
and a draining/idle state.

Example:
  { \"palace_path\": \"/Users/me/.mempalace\" }

Response: \"palace import complete: <n> written, <n> updated, <n> unchanged,
<n> tombstoned, <n> tunnels, <n> skipped\"

Mistakes:
  — Skipping reindex/dream then calling the estate ready: recall stays dark.
  — Passing the inner palace/ dir instead of the ROOT that contains it.";

const GUIDE_GENERIC: &str = "\
No teachme guide is available for this tool.
Call moot_estate_status (no teachme) for the protocol block, or with teachme:true for the tool orientation guide.";
