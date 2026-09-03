//! commands/redistill.rs — `mootx01 redistill`: force-redistill every active
//! item of an estate and rebuild both recall lanes, from the terminal.
//!
//! The same operation the `moot_redistill` MCP tool performs. This command
//! opens the estate the way `drain` and `dream` do and dispatches that tool
//! through the same dispatch layer a serve would, so the call tree and the
//! printed result are the server's own. `--dry-run` reports how many rows
//! are stale under the active converter and writes nothing. Rust twin of the
//! Swift `RedistillCommand`.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::ExitCode;
use std::time::Instant;

use aria_mcp::estate_registry::EstateRegistry;
use aria_mcp::jsonrpc::JsonValue;
use aria_mcp::surfaced_recall_ledger::SurfacedRecallLedger;

use crate::core::paths;
use crate::exit;

/// Host identity for the open (matches the registry's production default).
const OWNER: &str = "aria-mcp-default";

/// The MCP tool this verb dispatches. One name, one implementation.
pub const TOOL_NAME: &str = "moot_redistill";

pub fn run(db: Option<String>, dry_run: bool) -> ExitCode {
    let data = paths::data_dir();
    let name = db.unwrap_or_else(|| paths::active_estate(&data));
    // Estate path: an explicit ARIA_MCP_SQLITE_PATH override wins; else the
    // named/active estate (mirrors drain.rs).
    let estate = match std::env::var("ARIA_MCP_SQLITE_PATH") {
        Ok(p) if !p.is_empty() => p,
        _ => paths::estate_sqlite_path(&data, &name).to_string_lossy().into_owned(),
    };
    // `mootx01 db create` makes the estate directory; the substrate writes
    // the SQLite file on first open, so a never-opened estate is still a
    // valid (empty) target. A missing directory is a typo or a wrong data
    // directory.
    let dir_exists = Path::new(&estate).parent().map(Path::exists).unwrap_or(false);
    if !dir_exists {
        eprintln!("mootx01 redistill fatal: estate '{name}' not found at {estate}");
        return ExitCode::from(exit::FAILURE);
    }
    match run_on_estate(&estate, &name, dry_run) {
        Ok(lines) => {
            for line in lines {
                println!("{line}");
            }
            ExitCode::from(exit::OK)
        }
        Err(e) => {
            eprintln!("mootx01 redistill fatal: {e}");
            ExitCode::from(exit::FAILURE)
        }
    }
}

/// Open `estate`, report the stale-row count under the active converter, and
/// unless `dry_run` dispatch `moot_redistill` through the ARIA dispatch layer.
/// Returns the lines to print; a tool result flagged `isError` is an `Err`
/// carrying its text so the exit status follows it.
pub(crate) fn run_on_estate(estate: &str, name: &str, dry_run: bool) -> Result<Vec<String>, String> {
    let reg = EstateRegistry::new_sqlite(estate, OWNER)?;
    let handle = reg.default.handle.clone();
    let mut lines = vec![
        format!("estate: {name}"),
        format!("converter: {}", genius_locus_kit::distillation_converter_id()),
    ];
    // The "distillation" drain entry counts rows the currency rule calls
    // stale under the active converter — the rows `mootx01 upgrade` would
    // regenerate. The force sweep rewrites every active item regardless.
    let stale = {
        let coord = reg.coord.lock().map_err(|e| format!("coordinator lock poisoned: {e}"))?;
        coord
            .drain_statuses(&handle)
            .map_err(|e| format!("{e:?}"))?
            .into_iter()
            .find(|d| d.name == "distillation")
            .map(|d| d.pending)
            .unwrap_or(0)
    };
    lines.push(format!("rows stale under the active converter: {stale}"));
    if dry_run {
        lines.push("dry run: no rows written".to_string());
        return Ok(lines);
    }
    let start = Instant::now();
    let args: BTreeMap<String, JsonValue> = BTreeMap::new();
    let result = aria_mcp::dispatch::dispatch_tool(TOOL_NAME, &args, &reg, &SurfacedRecallLedger::new())
        .map_err(|e| e.message)?;
    let text = result["content"][0]["text"].as_str().unwrap_or("").to_string();
    if result["isError"].as_bool().unwrap_or(false) {
        return Err(text);
    }
    lines.push(text);
    lines.push(format!("elapsed: {:.1}s", start.elapsed().as_secs_f64()));
    Ok(lines)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_estate() -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("estate.sqlite").to_string_lossy().into_owned();
        (dir, path)
    }

    fn file_memory(estate: &str, content: &str) {
        let reg = EstateRegistry::new_sqlite(estate, OWNER).expect("open");
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("content".into(), JsonValue::from(serde_json::json!(content)));
        args.insert("subject".into(), JsonValue::from(serde_json::json!(content)));
        args.insert("location".into(), JsonValue::from(serde_json::json!("redistill-cli")));
        let result = aria_mcp::dispatch::dispatch_tool("moot_file_memory", &args, &reg, &SurfacedRecallLedger::new())
            .expect("file memory");
        assert!(!result["isError"].as_bool().unwrap_or(false), "{result}");
    }

    #[test]
    fn dry_run_reports_and_writes_nothing() {
        let (_dir, estate) = temp_estate();
        file_memory(&estate, "redistill dry run test content");
        let before = std::fs::metadata(&estate).expect("estate file").len();
        let lines = run_on_estate(&estate, "t", true).expect("dry run");
        assert_eq!(lines[0], "estate: t");
        assert!(lines[1].starts_with("converter: "), "{lines:?}");
        assert!(lines[2].starts_with("rows stale under the active converter: "), "{lines:?}");
        assert_eq!(lines[3], "dry run: no rows written");
        assert_eq!(lines.len(), 4);
        // A dry run must not run the sweep: re-opening and running for real
        // afterwards still finds the same rows to rewrite, and the file was
        // not rewritten by the dry run (size unchanged; the open itself is
        // read-only on an already-migrated estate).
        let after = std::fs::metadata(&estate).expect("estate file").len();
        assert_eq!(before, after, "a dry run must not write the estate");
    }

    #[test]
    fn run_dispatches_the_tool_and_reports_its_text() {
        let (_dir, estate) = temp_estate();
        file_memory(&estate, "redistill run test content one");
        file_memory(&estate, "redistill run test content two");
        let lines = run_on_estate(&estate, "t", false).expect("run");
        let text = &lines[3];
        assert!(text.starts_with("moot_redistill: sweep complete\nitemsRedistilled: "), "{text}");
        assert!(text.ends_with("reindexed: both lanes (BM25 + dense)"), "{text}");
        let count: usize = text
            .lines()
            .find_map(|l| l.strip_prefix("itemsRedistilled: "))
            .and_then(|n| n.parse().ok())
            .expect("count line");
        assert!(count >= 2, "both filed items are active and must be redistilled; got {count}");
        assert!(lines[4].starts_with("elapsed: "), "{lines:?}");
    }
}
