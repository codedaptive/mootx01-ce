//! palace_pump — the outbound data pump: MOOTx01's data model → MemPalace over
//! its live MCP server. Rust parallel of the Swift `PalacePump`.
//!
//! Live-transport sibling of `ExchangeAdapter` (which writes the JSON exchange
//! document to disk). Fixes every gap the benchmarker's TransferEngine left:
//!
//!   GAP A (per-item args)  → `palace_pump_mapping::make_args` per `NoteIR`.
//!   GAP B (write id)       → `palace_response_parsing::parse_add_drawer_id`.
//!   GAP C (verify by id)   → round-trip verification by `get_drawer` of the
//!                            assigned id (MemPalace search has no stable id).
//!   GAP D (resume)         → the [`CheckpointQueue`] IS the checkpoint: each
//!                            note is a job file; a crash mid-run resumes from
//!                            the queue's `pending/` directory, not from zero.
//!   GAP E (pacing)         → a paced drain (`delay_per_item`) between writes.
//!   GAP F (drift)          → `palace_drift_detector` diffs the live tools/list
//!                            against the expected manifest BEFORE any write.
//!
//! ## Why a self-contained checkpoint queue (not the `queuekit` crate)
//!
//! The Swift pump uses the QueueKit package. The Rust port uses a small
//! dependency-free filesystem queue local to this module, realizing the same
//! maildir-style "queue is the checkpoint" semantics. The checkpoint guarantee
//! (resume from disk, not from zero) is identical; only the implementation
//! differs, as the two languages' ecosystem constraints differ.

use crate::drawer_mapping::DrawerMapping;
use crate::mcp_stdio_client::{McpClientError, McpStdioClient};
use crate::note_ir::NoteIR;
use crate::palace_drift_detector::{self, PalaceDriftFinding, PalaceLiveTool};
use crate::palace_pump_mapping::{self, PalaceDrawerArgs};
use crate::palace_response_parsing;
use crate::vault_export_scope::VaultExportScope;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// The outcome of one note's pump. Mirrors Swift `PalacePumpItemResult`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PalacePumpItemResult {
    /// The note's `stable_source_key`.
    pub source_key: String,
    /// The assigned noun id from MemPalace (drawer id, tunnel id, triple id,
    /// or entry id depending on the noun written); `None` only when the
    /// write failed.
    pub drawer_id: Option<String>,
    /// True when a `get_drawer` fetch returned the content the pump wrote.
    pub verified: bool,
}

/// The result of a full pump run. Mirrors Swift `PalacePumpResult`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PalacePumpResult {
    /// One result per note drained and written.
    pub items: Vec<PalacePumpItemResult>,
    /// Secret-tier drawers the substrate withheld from the projection.
    pub withheld_secret_tier: usize,
}

impl PalacePumpResult {
    /// Notes that wrote AND verified by round-trip fetch.
    pub fn verified_count(&self) -> usize {
        self.items.iter().filter(|i| i.verified).count()
    }
    /// Notes whose write failed (no assigned id).
    pub fn failed_count(&self) -> usize {
        self.items.iter().filter(|i| i.drawer_id.is_none()).count()
    }
}

/// Errors the pump raises that halt the run.
#[derive(Debug)]
pub enum PalacePumpError {
    /// The live MemPalace surface no longer matches the expected manifest. The
    /// pump writes NOTHING when this is raised (drift check runs first).
    DriftDetected(Vec<PalaceDriftFinding>),
    /// An MCP transport/protocol error.
    Client(McpClientError),
    /// A filesystem checkpoint error.
    Io(std::io::Error),
    /// A mapping/encode error while building a write.
    Mapping(String),
}

impl std::fmt::Display for PalacePumpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PalacePumpError::DriftDetected(findings) => {
                let joined = findings
                    .iter()
                    .map(|x| x.to_string())
                    .collect::<Vec<_>>()
                    .join("; ");
                write!(f, "MemPalace tool drift detected: {joined}")
            }
            PalacePumpError::Client(e) => write!(f, "{e}"),
            PalacePumpError::Io(e) => write!(f, "pump checkpoint I/O error: {e}"),
            PalacePumpError::Mapping(m) => write!(f, "pump mapping error: {m}"),
        }
    }
}

impl std::error::Error for PalacePumpError {}

impl From<McpClientError> for PalacePumpError {
    fn from(e: McpClientError) -> Self {
        PalacePumpError::Client(e)
    }
}
impl From<std::io::Error> for PalacePumpError {
    fn from(e: std::io::Error) -> Self {
        PalacePumpError::Io(e)
    }
}

/// The QueueKit-job analogue: the fully-built `add_drawer` arguments for one
/// note. The envelope is already folded into `content`, so a resumed drain
/// needs nothing but this. Mirrors Swift `PumpJobPayload`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PumpJobPayload {
    pub wing: String,
    pub room: String,
    pub content: String,
    pub source_file: String,
    pub added_by: String,
}

impl PumpJobPayload {
    fn from_args(args: &PalaceDrawerArgs) -> Self {
        Self {
            wing: args.wing.clone(),
            room: args.room.clone(),
            content: args.content.clone(),
            source_file: args.source_file.clone(),
            added_by: args.added_by.clone(),
        }
    }
}

/// A small dependency-free filesystem checkpoint queue with maildir-style
/// semantics: each job is a file under `pending/`; draining moves it to
/// `done/` only after the write completes. A crash mid-run leaves the unwritten
/// jobs in `pending/`, so re-draining resumes exactly where it stopped (GAP D).
/// This mirrors the role QueueKit's FilesystemBackend plays for the Swift pump.
pub struct CheckpointQueue {
    pending: PathBuf,
    done: PathBuf,
    seq: u64,
}

impl CheckpointQueue {
    /// Mount (or re-mount) the checkpoint queue rooted at `root`, creating the
    /// `pending/` and `done/` directories if absent. Re-mounting an existing
    /// root preserves any jobs still in `pending/` — that is the resume path.
    pub fn mount(root: &Path) -> Result<Self, std::io::Error> {
        let pending = root.join("pending");
        let done = root.join("done");
        std::fs::create_dir_all(&pending)?;
        std::fs::create_dir_all(&done)?;
        Ok(Self {
            pending,
            done,
            seq: 0,
        })
    }

    /// Enqueue one job: write the payload to a uniquely-named file in
    /// `pending/`. The filename is zero-padded sequence + a uuid so the drain
    /// order is stable and two enqueues never collide.
    pub fn send(&mut self, payload: &PumpJobPayload) -> Result<(), std::io::Error> {
        let name = format!("{:016}-{}.json", self.seq, uuid::Uuid::new_v4());
        self.seq += 1;
        let body = serde_json::to_vec(payload)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        // Write to a tmp sibling then rename, so a crash never leaves a
        // half-written job visible in pending/ (atomic-publish, maildir-style).
        let tmp = self.pending.join(format!(".tmp-{name}"));
        std::fs::write(&tmp, &body)?;
        std::fs::rename(&tmp, self.pending.join(&name))?;
        Ok(())
    }

    /// The sorted list of pending job filenames (drain order).
    pub fn pending_jobs(&self) -> Result<Vec<PathBuf>, std::io::Error> {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(&self.pending)?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("json"))
            .collect();
        entries.sort();
        Ok(entries)
    }

    /// Read one job's payload from its file.
    pub fn read_job(&self, path: &Path) -> Result<PumpJobPayload, std::io::Error> {
        let bytes = std::fs::read(path)?;
        serde_json::from_slice(&bytes)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
    }

    /// Enqueue one four-noun item job (the same atomic-publish semantics as
    /// [`send`], for the four-noun [`PalaceItemJobPayload`]).
    ///
    /// [`send`]: CheckpointQueue::send
    pub fn send_item(&mut self, payload: &PalaceItemJobPayload) -> Result<(), std::io::Error> {
        let name = format!("{:016}-{}.json", self.seq, uuid::Uuid::new_v4());
        self.seq += 1;
        let body = serde_json::to_vec(payload)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        let tmp = self.pending.join(format!(".tmp-{name}"));
        std::fs::write(&tmp, &body)?;
        std::fs::rename(&tmp, self.pending.join(&name))?;
        Ok(())
    }

    /// Read one four-noun item job's payload from its file.
    pub fn read_item_job(&self, path: &Path) -> Result<PalaceItemJobPayload, std::io::Error> {
        let bytes = std::fs::read(path)?;
        serde_json::from_slice(&bytes)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
    }

    /// Mark a job complete by moving its file from `pending/` to `done/`, so a
    /// resume never re-processes it.
    pub fn complete(&self, path: &Path) -> Result<(), std::io::Error> {
        let name = path.file_name().expect("job path has a filename");
        std::fs::rename(path, self.done.join(name))
    }
}

/// Drives the outbound pump. Reads an estate's whole data model as
/// `Vec<NoteIR>`, enqueues each as a checkpoint job, then paced-drains,
/// writing each to MemPalace and verifying it by round-trip fetch.
pub struct PalacePump {
    delay_per_item: std::time::Duration,
}

impl PalacePump {
    /// Build a pump with the given per-item pacing delay (GAP E). Zero = drain
    /// as fast as the server accepts.
    pub fn new(delay_per_item: std::time::Duration) -> Self {
        Self { delay_per_item }
    }

    /// Run the drift gate: `tools/list` → parse → diff against the expected
    /// manifest. Errors with [`PalacePumpError::DriftDetected`] if the surface
    /// moved. Call before any write (the full [`run`] does so automatically).
    ///
    /// [`run`]: PalacePump::run
    pub fn check_drift(&self, client: &mut McpStdioClient) -> Result<(), PalacePumpError> {
        let tools_json = client.list_tools()?;
        let live = PalaceLiveTool::parse(&tools_json)
            .map_err(|e| PalacePumpError::Mapping(e.to_string()))?;
        let findings = palace_drift_detector::diff(&live, &palace_drift_detector::expected_manifest());
        if !findings.is_empty() {
            return Err(PalacePumpError::DriftDetected(findings));
        }
        Ok(())
    }

    /// Enqueue every note as a checkpoint job whose payload is its built
    /// `add_drawer` arguments (envelope already folded in). Returns the number
    /// enqueued. A crash after this point resumes from the queue (GAP D).
    pub fn enqueue(
        &self,
        queue: &mut CheckpointQueue,
        notes: &[NoteIR],
    ) -> Result<usize, PalacePumpError> {
        let mut count = 0;
        for note in notes {
            let args = palace_pump_mapping::make_args(note)
                .map_err(|e| PalacePumpError::Mapping(e.to_string()))?;
            queue.send(&PumpJobPayload::from_args(&args))?;
            count += 1;
        }
        Ok(count)
    }

    /// Drain the queue, writing each job to MemPalace and verifying it by
    /// `get_drawer` of the assigned id. Paces by `delay_per_item`. Each drained
    /// job is moved to `done/`, so a re-drain after a crash only re-processes
    /// jobs still in `pending/`.
    pub fn drain(
        &self,
        queue: &mut CheckpointQueue,
        client: &mut McpStdioClient,
    ) -> Result<Vec<PalacePumpItemResult>, PalacePumpError> {
        let mut results = Vec::new();
        for job_path in queue.pending_jobs()? {
            let payload = queue.read_job(&job_path)?;
            let result = self.process_job(&payload, client)?;
            results.push(result);
            queue.complete(&job_path)?;
            if !self.delay_per_item.is_zero() {
                std::thread::sleep(self.delay_per_item);
            }
        }
        Ok(results)
    }

    /// Write one job's drawer and verify it. The args were fully built at
    /// enqueue time, so this is pure transport + parse.
    fn process_job(
        &self,
        payload: &PumpJobPayload,
        client: &mut McpStdioClient,
    ) -> Result<PalacePumpItemResult, PalacePumpError> {
        // Write (GAP A — per-item args).
        let write_result = client.call_tool(
            "mempalace_add_drawer",
            serde_json::json!({
                "wing": payload.wing,
                "room": payload.room,
                "content": payload.content,
                "source_file": payload.source_file,
                "added_by": payload.added_by,
            }),
        )?;
        let drawer_id = match palace_response_parsing::parse_add_drawer_id(&write_result.text_blocks)
        {
            Ok(id) => id,
            Err(_) => {
                return Ok(PalacePumpItemResult {
                    source_key: payload.source_file.clone(),
                    drawer_id: None,
                    verified: false,
                })
            }
        };
        // Verify by round-trip fetch (GAP C — by id, not search).
        let verified = self.verify(client, &drawer_id, &payload.content);
        Ok(PalacePumpItemResult {
            source_key: payload.source_file.clone(),
            drawer_id: Some(drawer_id),
            verified,
        })
    }

    /// Fetch the drawer by id and confirm the written content came back
    /// verbatim. Any error or mismatch is a failed verification (recorded,
    /// never fatal).
    fn verify(&self, client: &mut McpStdioClient, drawer_id: &str, expected: &str) -> bool {
        match client.call_tool(
            "mempalace_get_drawer",
            serde_json::json!({ "drawer_id": drawer_id }),
        ) {
            Ok(fetch_result) => {
                match palace_response_parsing::parse_get_drawer(&fetch_result.text_blocks) {
                    Ok(fetched) => fetched.drawer_id == drawer_id && fetched.content == expected,
                    Err(_) => false,
                }
            }
            Err(_) => false,
        }
    }

    /// Run the whole pump for one estate: drift gate → project to `Vec<NoteIR>`
    /// → enqueue → paced drain with round-trip verification.
    ///
    /// The Rust `DrawerMapping::export` is synchronous, so the whole run is
    /// synchronous (matching the Rust port's blocking style).
    pub fn run(
        &self,
        client: &mut McpStdioClient,
        queue: &mut CheckpointQueue,
        coordinator: &genius_locus_kit::coordinator::EstateCoordinator,
        handle: &genius_locus_kit::handle::EstateHandle,
        scope: VaultExportScope,
        now_millis: i64,
    ) -> Result<PalacePumpResult, PalacePumpError> {
        // GAP F: refuse to write against a drifted surface.
        self.check_drift(client)?;

        let mapping = DrawerMapping::default();
        let projection = mapping
            .export(coordinator, handle, now_millis, scope)
            .map_err(|e| PalacePumpError::Mapping(e.to_string()))?;

        self.enqueue(queue, &projection.notes)?;
        let items = self.drain(queue, client)?;
        Ok(PalacePumpResult {
            items,
            withheld_secret_tier: projection.excluded_secret_tier,
        })
    }

    // --- Four-noun pump (drawer / tunnel / KG fact / diary) ---
    //
    // The canonical path: the caller (the operator driver's reader) injects the
    // full `Vec<PalaceItem>` noun stream, and the pump writes each through the
    // per-noun mapping, verifies it by the noun's read tool, and checkpoints it.
    // The drift gate (now covering all four write tools + read tools) runs first.
    // Rust parallel of the Swift `PalacePump.runItems`.

    /// Enqueue every [`PalaceItem`] as a checkpoint job whose payload is the
    /// fully-built MemPalace call (tool + native args, envelope folded in) plus
    /// the noun and source id needed to verify. Returns the number enqueued.
    pub fn enqueue_items(
        &self,
        queue: &mut CheckpointQueue,
        items: &[crate::palace_item::PalaceItem],
    ) -> Result<usize, PalacePumpError> {
        let mut count = 0;
        for item in items {
            let call = palace_pump_mapping::call(item)
                .map_err(|e| PalacePumpError::Mapping(e.to_string()))?;
            queue.send_item(&PalaceItemJobPayload {
                noun: item.noun,
                source_id: item.source_id.clone(),
                body: item.body.clone(),
                call,
            })?;
            count += 1;
        }
        Ok(count)
    }

    /// Drain the four-noun queue, writing each job's call to MemPalace and
    /// verifying it by the noun's read tool. Each drained job is moved to
    /// `done/`, so a re-drain after a crash only re-processes pending jobs.
    pub fn drain_items(
        &self,
        queue: &mut CheckpointQueue,
        client: &mut McpStdioClient,
    ) -> Result<Vec<PalacePumpItemResult>, PalacePumpError> {
        let mut results = Vec::new();
        for job_path in queue.pending_jobs()? {
            let payload = queue.read_item_job(&job_path)?;
            let result = self.process_item_job(&payload, client)?;
            results.push(result);
            queue.complete(&job_path)?;
            if !self.delay_per_item.is_zero() {
                std::thread::sleep(self.delay_per_item);
            }
        }
        Ok(results)
    }

    /// Write one four-noun job's call and verify it by the noun's read tool.
    ///
    /// Security: the tool name is re-validated against the write-tool allowlist
    /// before every invocation. A persisted payload whose `call.tool` names any
    /// tool outside the four canonical write tools is rejected — never forwarded
    /// to the MCP server — so a tampered queue job cannot invoke arbitrary
    /// MemPalace tools during drain.
    fn process_item_job(
        &self,
        payload: &PalaceItemJobPayload,
        client: &mut McpStdioClient,
    ) -> Result<PalacePumpItemResult, PalacePumpError> {
        // Allowlist check: only the four write tools are permitted. The name
        // was embedded in the payload at enqueue time; validate before draining
        // to guard against tampered queue files on disk.
        const ALLOWED_WRITE_TOOLS: &[&str] = &[
            palace_pump_mapping::ADD_DRAWER_TOOL,
            palace_pump_mapping::CREATE_TUNNEL_TOOL,
            palace_pump_mapping::KG_ADD_TOOL,
            palace_pump_mapping::DIARY_WRITE_TOOL,
        ];
        if !ALLOWED_WRITE_TOOLS.contains(&payload.call.tool.as_str()) {
            // Log to stderr and count as a failed item — not a hard error, to
            // match the Swift pump's behaviour of continuing the drain.
            eprintln!(
                "vault-pump: refusing persisted tool '{}' for '{}' — not in write allowlist",
                payload.call.tool, payload.source_id
            );
            return Ok(PalacePumpItemResult {
                source_key: payload.source_id.clone(),
                drawer_id: None,
                verified: false,
            });
        }

        let args = serde_json::Value::Object(
            payload.call.arguments.clone().into_iter().collect(),
        );
        let write_result = match client.call_tool(&payload.call.tool, args) {
            Ok(r) => r,
            Err(_) => {
                return Ok(PalacePumpItemResult {
                    source_key: payload.source_id.clone(),
                    drawer_id: None,
                    verified: false,
                })
            }
        };
        let id_key = palace_response_parsing::assigned_id_key(payload.noun);
        let assigned_id =
            match palace_response_parsing::parse_assigned_id(&write_result.text_blocks, id_key) {
                Some(id) => id,
                None => {
                    return Ok(PalacePumpItemResult {
                        source_key: payload.source_id.clone(),
                        drawer_id: None,
                        verified: false,
                    })
                }
            };
        let verified = self.verify_item(client, payload, &assigned_id);
        Ok(PalacePumpItemResult {
            source_key: payload.source_id.clone(),
            drawer_id: Some(assigned_id),
            verified,
        })
    }

    /// Verify one written item by reading it back with the noun's own MemPalace
    /// read tool. Mirrors the Swift `verifyItem`. Any error/mismatch → false.
    fn verify_item(
        &self,
        client: &mut McpStdioClient,
        payload: &PalaceItemJobPayload,
        assigned_id: &str,
    ) -> bool {
        use crate::palace_item::PalaceNoun;
        let args = &payload.call.arguments;
        match payload.noun {
            PalaceNoun::Drawer => {
                let fetch = match client.call_tool(
                    palace_pump_mapping::GET_DRAWER_TOOL,
                    serde_json::json!({ "drawer_id": assigned_id }),
                ) {
                    Ok(r) => r,
                    Err(_) => return false,
                };
                let fetched = match palace_response_parsing::parse_get_drawer(&fetch.text_blocks) {
                    Ok(f) => f,
                    Err(_) => return false,
                };
                if fetched.drawer_id != assigned_id {
                    return false;
                }
                crate::palace_payload_envelope::decode_fields(&fetched.content)
                    .map(|d| d.body == payload.body)
                    .unwrap_or(false)
            }
            PalaceNoun::Tunnel => {
                let mut q = serde_json::Map::new();
                if let Some(w) = args.get("source_wing").and_then(|v| v.as_str()) {
                    q.insert("wing".to_owned(), serde_json::Value::String(w.to_owned()));
                }
                let result = match client
                    .call_tool("mempalace_list_tunnels", serde_json::Value::Object(q))
                {
                    Ok(r) => r,
                    Err(_) => return false,
                };
                any_array_contains(&result.text_blocks, "id", assigned_id)
            }
            PalaceNoun::KgFact => {
                let subject = args.get("subject").and_then(|v| v.as_str()).unwrap_or("");
                let predicate = args.get("predicate").and_then(|v| v.as_str()).unwrap_or("");
                let object = args.get("object").and_then(|v| v.as_str()).unwrap_or("");
                let normalized = predicate.to_lowercase().replace(' ', "_");
                let result = match client.call_tool(
                    "mempalace_kg_query",
                    serde_json::json!({ "entity": subject }),
                ) {
                    Ok(r) => r,
                    Err(_) => return false,
                };
                facts_contain(&result.text_blocks, &normalized, object)
            }
            PalaceNoun::DiaryEntry => {
                let agent = args.get("agent_name").and_then(|v| v.as_str()).unwrap_or("");
                let result = match client.call_tool(
                    "mempalace_diary_read",
                    serde_json::json!({ "agent_name": agent }),
                ) {
                    Ok(r) => r,
                    Err(_) => return false,
                };
                diary_contains(&result.text_blocks, &payload.body)
            }
        }
    }

    /// Run the canonical four-noun pump: drift gate → enqueue the injected
    /// `Vec<PalaceItem>` stream → paced drain with per-noun round-trip verify.
    /// The caller supplies the items (the read seam); the pump owns the wire
    /// format and verification.
    pub fn run_items(
        &self,
        client: &mut McpStdioClient,
        queue: &mut CheckpointQueue,
        items: &[crate::palace_item::PalaceItem],
    ) -> Result<PalacePumpResult, PalacePumpError> {
        self.check_drift(client)?;
        self.enqueue_items(queue, items)?;
        let results = self.drain_items(queue, client)?;
        Ok(PalacePumpResult {
            items: results,
            withheld_secret_tier: 0,
        })
    }
}

/// The checkpoint-job payload for a four-noun [`PalaceItem`]: the fully-built
/// MemPalace call plus the noun and source id the drain needs to parse the
/// assigned id and verify. Mirrors Swift `PalaceItemJobPayload`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PalaceItemJobPayload {
    /// The noun, so the drain picks the right assigned-id key and verify tool.
    pub noun: crate::palace_item::PalaceNoun,
    /// The source row id (checkpoint/result key).
    pub source_id: String,
    /// The source body (envelope stripped), for round-trip verify comparison.
    pub body: String,
    /// The fully-built MemPalace call.
    pub call: palace_pump_mapping::PalaceCall,
}

// --- verify response readers (pure; parallel to the Swift statics) ---

/// True when any JSON object in a text block's first array-valued member (or a
/// bare array block) carries `key == value`. Used for tunnel list-verify.
fn any_array_contains(text_blocks: &[String], key: &str, value: &str) -> bool {
    for block in text_blocks {
        let parsed: serde_json::Value = match serde_json::from_str(block) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Some(arr) = parsed.as_array() {
            if arr
                .iter()
                .any(|o| o.get(key).and_then(|v| v.as_str()) == Some(value))
            {
                return true;
            }
        } else if let Some(obj) = parsed.as_object() {
            for member in obj.values() {
                if let Some(arr) = member.as_array() {
                    if arr
                        .iter()
                        .any(|o| o.get(key).and_then(|v| v.as_str()) == Some(value))
                    {
                        return true;
                    }
                }
            }
        }
    }
    false
}

/// True when the `facts` array in a kg_query response carries a fact with the
/// given (normalized) predicate and clean object.
fn facts_contain(text_blocks: &[String], predicate: &str, object: &str) -> bool {
    for block in text_blocks {
        let parsed: serde_json::Value = match serde_json::from_str(block) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Some(facts) = parsed.get("facts").and_then(|f| f.as_array()) {
            if facts.iter().any(|f| {
                f.get("predicate").and_then(|v| v.as_str()) == Some(predicate)
                    && f.get("object").and_then(|v| v.as_str()) == Some(object)
            }) {
                return true;
            }
        }
    }
    false
}

/// True when the `entries` array in a diary_read response carries an entry
/// whose content (envelope stripped) equals `body`.
fn diary_contains(text_blocks: &[String], body: &str) -> bool {
    for block in text_blocks {
        let parsed: serde_json::Value = match serde_json::from_str(block) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Some(entries) = parsed.get("entries").and_then(|e| e.as_array()) {
            for entry in entries {
                if let Some(content) = entry.get("content").and_then(|v| v.as_str()) {
                    if crate::palace_payload_envelope::decode_fields(content)
                        .map(|d| d.body == body)
                        .unwrap_or(false)
                    {
                        return true;
                    }
                }
            }
        }
    }
    false
}
