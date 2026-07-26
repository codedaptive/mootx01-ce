//! main.rs — the mcp-benchmarker-rs CLI.
//!
//! Ports the subcommand dispatch + option parsing of `main.swift` for the
//! transport/transfer surface this crate covers. The wiring matches the Swift
//! `runTransfer` flow: load config → connect both endpoints over stdio →
//! paginate/fetch/write/verify via the transfer engine → write the manifest →
//! print the round-trip summary.
//!
//! Subcommands:
//!   - `transfer  --config <c.json> --manifest <out.json> [--limit N] [--no-verify]`
//!   - `report    --manifest <m.json>`  (manifest summary; the Swift `report`
//!     subcommand renders a benchmark report — here we render the manifest the
//!     transfer wrote, the artifact this crate's transfer leg produces.)
//!
//! The stats-store / IntellectusLib instrumentation and the quality/pressure
//! subcommands depend on infrastructure outside this parity pass and are not
//! exposed by the Rust CLI (see the crate-level parity notes).

use mcp_benchmarker_rs::config::BenchmarkerConfig;
use mcp_benchmarker_rs::longmemeval_corpus::load_corpus;
use mcp_benchmarker_rs::longmemeval_runner::{
    discover_moot_binary, run_lme_questions, LmeRunConfig,
};
use mcp_benchmarker_rs::longmemeval_scorer::{
    build_lme_report, score_lme_question, write_lme_report,
};
use mcp_benchmarker_rs::mcp_client::MCPClient;
use mcp_benchmarker_rs::transfer::TransferEngine;
use mcp_benchmarker_rs::transfer_manifest::Manifest;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn usage() -> &'static str {
    "mcp-benchmarker-rs — Rust twin of the mcp-benchmarker transport/transfer/LME core\n\
     \n\
     USAGE:\n\
     \x20\x20mcp-benchmarker-rs transfer    --config <c.json> --manifest <out.json> [--limit N] [--no-verify]\n\
     \x20\x20mcp-benchmarker-rs report      --manifest <m.json>\n\
     \x20\x20mcp-benchmarker-rs longmemeval --corpus <path.json> [--binary <path>]\n\
     \x20\x20                               [--variant s|m|oracle] [--seed N] [--limit N]\n\
     \x20\x20                               [--out <dir>] [--label <label>]\n"
}

/// Returns the value following `--name`, or None if absent / no value. Mirrors
/// Swift `optionValue`.
fn option_value<'a>(name: &str, args: &'a [String]) -> Option<&'a str> {
    let i = args.iter().position(|a| a == name)?;
    args.get(i + 1).map(String::as_str)
}

/// True when a bare flag is present. Mirrors Swift `flagPresent`.
fn flag_present(name: &str, args: &[String]) -> bool {
    args.iter().any(|a| a == name)
}

/// A required option, or an error. Mirrors Swift `requireOption`.
fn require_option(name: &str, args: &[String]) -> Result<String, String> {
    option_value(name, args)
        .map(str::to_string)
        .ok_or_else(|| format!("missing required option {name}"))
}

/// ISO8601 (UTC, second precision) timestamp for the current instant. Used as
/// the injected `now` at the CLI boundary — the engine itself never reads a
/// hidden clock. Computed from the Unix epoch without an external date crate.
fn now_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Civil-date conversion (days since epoch → y/m/d) via Howard Hinnant's
    // algorithm; avoids pulling in `chrono` and keeps the zero-dep line.
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (h, mi, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn run_transfer(args: &[String]) -> Result<(), String> {
    let config_path = require_option("--config", args)?;
    let manifest_path = require_option("--manifest", args)?;
    let limit = option_value("--limit", args).and_then(|s| s.parse::<usize>().ok());
    let verify = !flag_present("--no-verify", args);

    let config = BenchmarkerConfig::load(Path::new(&config_path))
        .map_err(|e| format!("config load failed: {e}"))?;

    let mut source = MCPClient::new(config.source.clone());
    source.connect().map_err(|e| format!("source connect failed: {e}"))?;
    let mut target = MCPClient::new(config.target.clone());
    target.connect().map_err(|e| format!("target connect failed: {e}"))?;

    let source_verbs = config.source.verb_map.clone();
    let target_verbs = config.target.verb_map.clone();

    let result = {
        let mut engine = TransferEngine {
            source: &mut source,
            target: &mut target,
            source_verbs,
            target_verbs,
            max_retries: 2,
            max_entries: limit,
            verify_round_trip: verify,
            now_iso8601: Box::new(now_iso8601),
        };
        engine.run().map_err(|e| format!("transfer failed: {e}"))?
    };

    source.disconnect();
    target.disconnect();

    let bytes = serde_json::to_vec_pretty(&result.manifest)
        .map_err(|e| format!("manifest encode failed: {e}"))?;
    std::fs::write(&manifest_path, &bytes)
        .map_err(|e| format!("manifest write failed: {e}"))?;

    let captured = &result.capture_latencies;
    let mean_ms = if captured.is_empty() {
        0.0
    } else {
        captured.iter().sum::<f64>() / captured.len() as f64 * 1000.0
    };
    println!(
        "transfer complete: {} entries ({} enumerated{}), capture mean {:.2} ms",
        result.manifest.entries().len(),
        result.source_enumerated,
        if result.capped_by_sample { ", capped by --limit sample" } else { "" },
        mean_ms
    );
    if verify {
        if result.round_trip_failures.is_empty() {
            println!("round-trip: all entries verified on the target");
        } else {
            println!(
                "round-trip: {} entries did NOT recall in the target's top results:",
                result.round_trip_failures.len()
            );
            for f in &result.round_trip_failures {
                println!("  id={}  reason={}", f.id, f.reason.as_str());
            }
        }
    }
    println!("manifest written to {manifest_path}");
    Ok(())
}

fn run_report(args: &[String]) -> Result<(), String> {
    let manifest_path = require_option("--manifest", args)?;
    let data = std::fs::read(&manifest_path).map_err(|e| format!("read failed: {e}"))?;
    let manifest = Manifest::from_slice(&data).map_err(|e| format!("manifest decode failed: {e}"))?;
    let entries = manifest.entries();
    let transferred = entries
        .iter()
        .filter(|e| matches!(e.outcome, mcp_benchmarker_rs::transfer_manifest::TransferOutcome::Transferred))
        .count();
    println!(
        "manifest: {} entries ({} transferred, {} failed), {} capture latencies recorded",
        entries.len(),
        transferred,
        entries.len() - transferred,
        manifest.capture_latencies().len()
    );
    Ok(())
}

fn run_longmemeval(args: &[String]) -> Result<(), String> {
    let corpus_path = require_option("--corpus", args)?;
    let binary = option_value("--binary", args)
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY".to_string()
        })?;
    let variant = option_value("--variant", args)
        .unwrap_or("s")
        .to_string();
    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_260_725_u64);
    let limit = option_value("--limit", args).and_then(|s| s.parse::<usize>().ok());
    let label = option_value("--label", args).map(str::to_string);
    let out_dir = option_value("--out", args).map(PathBuf::from);

    eprintln!("[lme] loading corpus from {corpus_path}");
    let corpus = load_corpus(Path::new(&corpus_path))
        .map_err(|e| format!("corpus load failed: {}", e.0))?;
    eprintln!(
        "[lme] corpus: {} questions ({} abstention excluded)",
        corpus.questions.len(),
        corpus.abstention_count,
    );
    eprintln!("[lme] binary: {binary}  variant: {variant}  seed: {seed}");
    if let Some(n) = limit {
        eprintln!("[lme] limit: {n}");
    }

    let run_config = LmeRunConfig {
        moot_binary: binary,
        variant: variant.clone(),
        seed,
        limit,
        label: label.clone(),
        out_dir: out_dir.clone(),
    };

    let results = run_lme_questions(&corpus, &run_config);
    let scores: Vec<_> = results.into_iter().map(score_lme_question).collect();

    let run_id = {
        // Deterministic run ID: seed the same RNG used for shuffling and draw
        // one u64.  Different seeds / variants produce distinct IDs.
        let mut rng = mcp_benchmarker_rs::longmemeval_runner::SplitMix64::new(seed ^ 0xDEADBEEF);
        format!("{:016x}", rng.next_u64())
    };
    let run_label = label.unwrap_or_else(|| format!("lme-{variant}-seed{seed}"));
    let generated_at = now_iso8601();

    let report = build_lme_report(
        run_id,
        run_label,
        variant.clone(),
        generated_at,
        corpus.questions.len() + corpus.abstention_count,
        corpus.abstention_count,
        &scores,
    );

    // Print summary.
    println!("LongMemEval results (variant={variant}, seed={seed}):");
    println!("  questions_run:      {}", report.corpus_stats.questions_run);
    println!("  guard_excluded:     {}", report.corpus_stats.guard_excluded);
    println!("  query_count:        {}", report.aggregate.query_count);
    println!("  recall_any@1:       {:.4}", report.aggregate.recall_any_at_1);
    println!("  recall_any@5:       {:.4}", report.aggregate.recall_any_at_5);
    println!("  recall_any@10:      {:.4}", report.aggregate.recall_any_at_10);
    println!("  recall_all@1:       {:.4}", report.aggregate.recall_all_at_1);
    println!("  recall_all@5:       {:.4}", report.aggregate.recall_all_at_5);
    println!("  recall_all@10:      {:.4}", report.aggregate.recall_all_at_10);
    println!("  mrr:                {:.4}", report.aggregate.mrr);
    println!("  query_p50_s:        {:.4}", report.latency.query_p50_seconds);
    println!("  query_p95_s:        {:.4}", report.latency.query_p95_seconds);

    // Write report file.
    let report_filename = format!("lme-report-{}-seed{}.json", variant, seed);
    let report_path = out_dir
        .as_deref()
        .unwrap_or_else(|| Path::new("."))
        .join(&report_filename);
    write_lme_report(&report, &report_path)?;
    println!("report written to {}", report_path.display());

    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (subcommand, rest) = match args.split_first() {
        Some((s, r)) => (s.as_str(), r),
        None => {
            print!("{}", usage());
            return ExitCode::SUCCESS;
        }
    };
    let result = match subcommand {
        "transfer" => run_transfer(rest),
        "report" => run_report(rest),
        "longmemeval" | "lme" => run_longmemeval(rest),
        "--help" | "-h" | "help" => {
            print!("{}", usage());
            return ExitCode::SUCCESS;
        }
        other => {
            eprintln!("unknown subcommand '{other}'");
            print!("{}", usage());
            return ExitCode::FAILURE;
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            eprintln!("error: {msg}");
            ExitCode::FAILURE
        }
    }
}
