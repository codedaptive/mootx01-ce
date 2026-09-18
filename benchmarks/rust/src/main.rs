//! main.rs — the mcp-benchmarker-rs CLI.
//!
//! Ports the subcommand dispatch + option parsing of `main.swift` for the
//! core benchmark surface this crate covers. The transfer and `report`
//! subcommands are not part of this crate.
//!
//! The stats-store / IntellectusLib instrumentation and the quality/pressure
//! subcommands depend on infrastructure outside this parity pass and are not
//! exposed by the Rust CLI (see the crate-level parity notes).

use mcp_benchmarker_rs::encode_barrier::EncodeBarrier;
use mcp_benchmarker_rs::longmemeval_runner::ExactRecallStrategy;
use mcp_benchmarker_rs::estate_cache::EstateCacheMode;
use mcp_benchmarker_rs::lmeb_corpus::load_lmeb_corpus;
use mcp_benchmarker_rs::lmeb_runner::{
    run_lmeb_consolidated_queries, run_lmeb_queries, BenchRunShape, LmebEstateShape, LmebRunConfig,
};
use mcp_benchmarker_rs::lmeb_scorer::{build_lmeb_report, score_lmeb_query, write_lmeb_report};
use mcp_benchmarker_rs::locomo_corpus::load_locomo_corpus;
use mcp_benchmarker_rs::locomo_runner::{run_locomo_questions, EstateShape, LoCoMoRecallStrategy, LoCoMoRunConfig};
use mcp_benchmarker_rs::artifact_recall::{
    run_artifact_recall_lane, ArtifactDataset, ArtifactRecallConfig, ArtifactRecallScope,
    ArtifactTargetScale,
};
use mcp_benchmarker_rs::payload_economics::{run_payload_economics_lane, PayloadLaneConfig};
use mcp_benchmarker_rs::locomo_spec_corpus::load_locomo_spec_corpus;
use mcp_benchmarker_rs::locomo_spec_runner::{run_locomo_spec_questions, LoCoMoSpecRunConfig};
use mcp_benchmarker_rs::lme_spec_corpus::load_spec_corpus as load_lme_spec_corpus;
use mcp_benchmarker_rs::lme_spec_runner::{run_lme_spec, LmeSpecRunConfig};
// locomo_spec_scorer functions (aggregate, score_question) are called inside the
// spec runner itself; the run_locomo_spec dispatcher only consumes the already-
// computed LoCoMoSpecRunResult aggregate from run_locomo_spec_questions.
// No direct scorer imports needed here.
use mcp_benchmarker_rs::locomo_scorer::{
    build_locomo_report, score_locomo_question, write_locomo_report,
};
use mcp_benchmarker_rs::membench_corpus::load_membench_corpus;
use mcp_benchmarker_rs::timing_lane_runner::{run_timing_lane, TimingLaneConfig};
use mcp_benchmarker_rs::membench_runner::{
    run_membench_items, run_membench_items_consolidated, run_membench_items_capacity_tier,
    CapacityTier, EstateGroupingMode, MemBenchRunConfig,
};
use mcp_benchmarker_rs::membench_scorer::{
    build_membench_report, score_membench_item, write_membench_report, MemBenchReportConfig,
};
use mcp_benchmarker_rs::longmemeval_corpus::load_corpus;
use mcp_benchmarker_rs::longmemeval_judge::LmeJudgeGrading;
use mcp_benchmarker_rs::longmemeval_runner::{
    discover_moot_binary, run_lme_questions, LmeArm, LmeRunConfig,
    SplitMix64, LME_DEFAULT_JUDGE_PAYLOAD_HYDRATION_DEPTH, LME_RECALL_SHAPE_PRESETS,
};
use mcp_benchmarker_rs::longmemeval_scorer::{
    build_lme_report, score_lme_question, write_lme_report, LmePayloadEntry,
    LmeReportRunParameters,
};
use mcp_benchmarker_rs::mcp_client::MCPClient;
use mcp_benchmarker_rs::run_environment::{IdentityEnvironment, RunEnvironment};
use mcp_benchmarker_rs::scratch_posture::ScratchEstatePosture;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn usage() -> &'static str {
    "mcp-benchmarker-rs — Rust twin of the mcp-benchmarker LME/LoCoMo core\n\
     \n\
     USAGE:\n\
     \x20\x20mcp-benchmarker-rs longmemeval --corpus <path.json> [--binary <path>]\n\
     \x20\x20                               [--variant s|m|oracle] [--seed N] [--limit N]\n\
     \x20\x20                               [--out <dir>] [--label <label>]\n\
     \x20\x20mcp-benchmarker-rs lmeb        --data-dir <dir> [--evidence-types ET1,ET2,...] [--binary <path>]\n\
     \x20\x20                               [--seed N] [--limit N] [--offset N] [--out <dir>]\n\
     \x20\x20mcp-benchmarker-rs locomo      --corpus <path.json> [--binary <path>]\n\
     \x20\x20                               [--seed N] [--limit N] [--offset N]\n\
     \x20\x20                               [--out <dir>] [--label <label>]\n\
     \x20\x20mcp-benchmarker-rs locomo-spec --corpus <path.json> [--binary <path>]\n\
     \x20\x20                               [--seed N] [--limit N] [--offset N]\n\
     \x20\x20                               [--dump-answer-inputs <path.jsonl>]\n\
     \x20\x20                               [--answer-hydration-depth N]\n\
     \x20\x20                               [--hydration-tier distilled|full]\n\
     \x20\x20                               [--encode-barrier drain|impatient|none]\n\
     \x20\x20                               [--estate-cache off|reuse|require]\n\
     \x20\x20                               [--cache-dir <dir>] [--out <dir>]\n\
     \x20\x20                               [--estate-mode unencrypted|encrypted]\n\
     \x20\x20                               [--granularity turn|session]\n\
     \x20\x20                               [--shape disk|ram] [--parallel N]\n\
     \x20\x20                               [--guard-sample once|per-unit]\n\
     \x20\x20                               [--run-id <id>]\n\
     \x20\x20mcp-benchmarker-rs artifact-recall --dataset locomo|convomem|membench|lme-s\n\
     \x20\x20                               --questions <jsonl>\n\
     \x20\x20                               [--target-scale unit|bench-aggregate|complete-aggregate]\n\
     \x20\x20                               (--estate-dir <estate dir> | --catalog <catalog.json>)\n\
     \x20\x20                               [--scope wing|estate] [--id-prefix <str>] [--limit N]\n\
     \x20\x20                               [--top-k K] [--out <report.json>] [--binary <path>]\n\
     \x20\x20mcp-benchmarker-rs payload-economics --estate-dir <estate dir>\n\
     \x20\x20                               --questions <jsonl> --data-dir <dir>\n\
     \x20\x20                               [--variant s|m] [--synthesize-arm]\n\
     \x20\x20                               [--synthesize-limit N] [--payload-arm v0..v5]\n\
     \x20\x20                               [--limit N] [--top-k K] [--out <report.json>]\n\
     \x20\x20                               [--binary <path>]\n\
     \x20\x20mcp-benchmarker-rs lme-spec    --data-dir <dir> [--variant s|m|oracle]\n\
     \x20\x20                               [--binary <path>] [--seed N]\n\
     \x20\x20                               [--limit N] [--offset N]\n\
     \x20\x20                               [--dump-judge-inputs <path.jsonl>]\n\
     \x20\x20                               [--judge-cmd <cmd>] [--judge-model <id>]\n\
     \x20\x20                               [--encode-barrier drain|impatient|none]\n\
     \x20\x20                               [--estate-cache off|reuse|require]\n\
     \x20\x20                               [--cache-dir <dir>] [--out <dir>]\n\
     \x20\x20                               [--estate-mode unencrypted|encrypted]\n\
     \x20\x20                               [--shape disk|ram] [--parallel N]\n\
     \x20\x20                               [--guard-sample once|per-unit]\n\
     \x20\x20                               [--run-id <id>]\n\
     \x20\x20mcp-benchmarker-rs membench-spec --data-dir <MemData/> [--binary <path>]\n\
     \x20\x20                               [--agent FirstAgent|ThirdAgent]\n\
     \x20\x20                               [--category <c1,c2,...>] [--seed N]\n\
     \x20\x20                               [--limit N] [--offset N]\n\
     \x20\x20                               [--answer-cmd <cmd>]\n\
     \x20\x20                               [--dump-answer-inputs <path.jsonl>]\n\
     \x20\x20                               [--consume-answers <path.jsonl>]\n\
     \x20\x20                               [--capacity default|b1,b2,...]\n\
     \x20\x20                               [--encode-barrier drain|impatient|none]\n\
     \x20\x20                               [--estate-mode unencrypted|encrypted]\n\
     \x20\x20                               [--shape disk|ram] [--out <dir>]\n\
     \x20\x20                               [--run-id <id>]\n\
     \x20\x20mcp-benchmarker-rs membench    --data-dir <MemData/> [--binary <path>]\n\
     \x20\x20                               [--agent FirstAgent|ThirdAgent]\n\
     \x20\x20                               [--category <cat>] [--seed N]\n\
     \x20\x20                               [--limit N] [--offset N]\n\
     \x20\x20                               [--encode-barrier drain|impatient|none]\n\
     \x20\x20                               [--estate-mode unencrypted|encrypted]\n\
     \x20\x20                               [--out <dir>]\n\
     \x20\x20mcp-benchmarker-rs answer-batch --inputs <answer-inputs.jsonl> --answer-cmd <cmd> --out <path> [--limit N] [--offset N] [--reader-model <id>]\n\
     \x20\x20mcp-benchmarker-rs supersession [--binary <path>] [--seed N]\n\
     \x20\x20                               [--entities N] [--versions N]\n\
     \x20\x20                               [--contradictions N] [--k N]\n\
     \x20\x20                               [--divergences N] [--decoys N]\n\
     \x20\x20                               [--recall-shape <preset>]\n\
     \x20\x20                               [--dump-seed <path.json>]\n\
     \x20\x20                               [--seed-path live|batch]\n\
     \x20\x20                               [--estate-mode unencrypted|encrypted|both]\n\
     \x20\x20mcp-benchmarker-rs replay      [--binary <path>] [--seed N] [--runs N]\n\
     \x20\x20                               [--entities N] [--versions N]\n\
     \x20\x20                               [--contradictions N] [--k N]\n\
     \x20\x20                               [--recall-shape <preset>]\n\
     \x20\x20                               [--seed-path live|batch]\n\
     \x20\x20                               [--estate-mode unencrypted|encrypted]\n\
     \x20\x20mcp-benchmarker-rs journey     [--mootx01-binary <path>] [--shape disk|ram]\n\
     \x20\x20                               [--run-mode quiet|contended] [--out <dir>]\n\
     \x20\x20                               [--dump-seed <path.json>]\n\
     \x20\x20                               [--seed N] [--k N]\n\
     \x20\x20                               [--precise-miss-count N] [--cluster-count N]\n\
     \x20\x20                               [--members-per-cluster N]\n\
     \x20\x20                               [--estate-mode unencrypted|encrypted]\n\
     \x20\x20mcp-benchmarker-rs timing      [--binary <path>] [--mootx01-binary <path>]\n\
     \x20\x20                               [--seed N] [--repeats k] [--out <dir>]\n\
     \x20\x20                               [--run-mode quiet|contended]\n\
     \x20\x20mcp-benchmarker-rs capturespread-corpus [--seed N] [--probes N]\n\
     \x20\x20                               [--distractors N] [--out <dir>]\n\
     \x20\x20mcp-benchmarker-rs capturespread [--binary <path>] [--seed N]\n\
     \x20\x20                               [--probes N] [--distractors N]\n\
     \x20\x20                               [--variant spread|burst] [--k N]\n\
     \x20\x20                               [--recall-shape <preset>]\n\
     \x20\x20                               [--estate-cache off|reuse|require]\n\
     \x20\x20                               [--cache-dir <dir>] [--out <dir>]\n\
     \x20\x20mcp-benchmarker-rs gauntlet-corpus [--seed N] [--out <dir>]\n\
     \x20\x20                               [--per-tier N] [--distractors N]\n\
     \x20\x20                               [--tiers T1,T2,...]\n\
     \x20\x20mcp-benchmarker-rs gauntlet    --binary <path> [--corpus <dir>]\n\
     \x20\x20                               [--seed N] [--run-label <label>]\n\
     \x20\x20                               [--out <dir>] [--k K1,K2,...]\n\
     \x20\x20                               [--quick] [--moot-only]\n\
     \x20\x20                               [--seed-path live|batch] [--shape disk|ram]\n\
     \x20\x20                               [--guard-sample once|per-unit]\n\
     \x20\x20                               [--scratch-dir <dir>] [--run-mode quiet|contended]\n\
     \x20\x20                               [--reuse-backends]\n\
     \x20\x20longmemeval/locomo/membench/lmeb accept --estate-mode unencrypted|encrypted\n\
     \x20\x20(default: unencrypted). unencrypted attaches each scratch estate as a\n\
     \x20\x20transient catalog record (serve --db <scratch>), plaintext with no keychain\n\
     \x20\x20contact. encrypted runs the estate SQLCipher-encrypted under the harness\n\
     \x20\x20key file beside it — zero keychain and zero persisted key; incompatible\n\
     \x20\x20with --estate-cache reuse. --no-plaintext-scratch, which selected the\n\
     \x20\x20encrypted posture before --estate-mode existed, is REJECTED — not\n\
     \x20\x20aliased. Pass --estate-mode encrypted.\n\
     \n\
     \x20\x20supersession also accepts --estate-mode both: runs the lane TWICE,\n\
     \x20\x20once per posture, each with its own scratch estate (provisioned and\n\
     \x20\x20torn down independently). Corpus is generated ONCE (same seed) and\n\
     \x20\x20both postures ingest the identical corpus. Prints both scorecards plus\n\
     \x20\x20an \"estate-mode delta (encrypted - unencrypted):\" section comparing\n\
     \x20\x20CURRENT-OVER-STALE rate, current found rate, mean stale@k, mean\n\
     \x20\x20current rank, and query p50. Default for supersession: encrypted.\n\
     \n\
     \x20\x20replay: same seed twice -> identical scored outcomes; timing excluded.\n\
     \x20\x20Proves end-to-end replay determinism by running the full supersession\n\
     \x20\x20lane N times (default 2) with the same seed, each on a freshly\n\
     \x20\x20provisioned scratch estate, then comparing the deterministic-eligible\n\
     \x20\x20outcome fields across runs. Prints a per-field MATCH/DRIFT table.\n\
     \x20\x20Exit 0 when all fields match; exit 1 on any drift.\n\
     \x20\x20  --runs N                replay iterations (default 2, minimum 2)\n\
     \x20\x20  --estate-mode unencrypted|encrypted\n\
     \x20\x20                          posture for all scratch estates. \"both\" is\n\
     \x20\x20                          NOT accepted: replay compares runs of the\n\
     \x20\x20                          SAME posture. Default: encrypted.\n\
     \x20\x20  All --seed/--entities/--versions/--contradictions/--k/\n\
     \x20\x20  --recall-shape/--skip-contradictions/--skip-dream/\n\
     \x20\x20  --structured-tier flags have the same semantics as supersession.\n\
     \n\
     \x20\x20--judge-cmd and --rerank-cmd accept a shell command that reads the prompt\n\
     \x20\x20on stdin and writes its answer to stdout (exit 0). Because the command\n\
     \x20\x20may embed API keys, two paths exist:\n\
     \x20\x20  --judge-cmd <cmd>           flag: value appears in `ps` argv\n\
     \x20\x20  MOOT_BENCH_JUDGE_CMD=<cmd>  env var: not in `ps` argv; unset before the\n\
     \x20\x20                              command runs so the command and its\n\
     \x20\x20                              descendants never inherit it. Still readable\n\
     \x20\x20                              in THIS process's environment while it runs.\n\
     \x20\x20  --rerank-cmd <cmd>          flag: value appears in `ps` argv\n\
     \x20\x20  MOOT_BENCH_RERANK_CMD=<cmd> env var: same handling as MOOT_BENCH_JUDGE_CMD\n\
     \x20\x20If the env var is set, it takes precedence over the flag. Only presence\n\
     \x20\x20(cmd_set: true) is recorded in run reports — command text never logged.\n\
     \n\
     \x20\x20Unrecognised options are rejected, not ignored: an option this binary\n\
     \x20\x20does not know is an error naming the accepted set. Values are separate\n\
     \x20\x20arguments (--estate-mode encrypted), never joined with '='.\n"
}

/// Returns the value following `--name`, or None if absent / no value. Mirrors
/// Swift `optionValue`.
fn option_value<'a>(name: &str, args: &'a [String]) -> Option<&'a str> {
    let i = args.iter().position(|a| a == name)?;
    args.get(i + 1).map(String::as_str)
}

/// Parses a count-like option that carries a real lower bound, or returns an
/// error naming the option, the supplied value, and the constraint.
///
/// REJECT, DO NOT CLAMP. A benchmark run whose parameters were silently
/// corrected reports numbers labelled with what the operator asked for and
/// measured with something else, which is worse than no run at all.
///
/// `minimum` is the smallest value that keeps the generated corpus
/// well-formed — never a matter of taste. Each call site carries a comment
/// citing the generator code that would break below it.
///
/// The value is parsed as `i64` before the bound check, deliberately: parsing
/// straight into `usize` turns `-1` into an opaque "invalid digit found in
/// string" that names neither the constraint nor the value the operator
/// typed. Twin of Swift `validatedCount`.
fn validated_count(
    name: &str,
    args: &[String],
    default: usize,
    minimum: usize,
) -> Result<usize, String> {
    let Some(raw) = option_value(name, args) else {
        return Ok(default);
    };
    let value: i64 = raw
        .parse()
        .map_err(|_| format!("{name} must be an integer >= {minimum}; got '{raw}'"))?;
    if value < minimum as i64 {
        return Err(format!("{name} must be >= {minimum}; got {value}"));
    }
    Ok(value as usize)
}

/// Parses `--limit` as a non-negative integer, or None when absent.
///
/// A negative `--limit` is a CLI error: silently treating it as "no limit" via
/// `parse::<usize>().ok()` would swallow a typo or a negative offset expression
/// and produce an unbounded run while the operator believes it is bounded.
/// Twin of Swift `parseLimitOption(in:)`.
fn parse_limit_option(args: &[String]) -> Result<Option<usize>, String> {
    let Some(raw) = option_value("--limit", args) else { return Ok(None) };
    let value: i64 = raw.parse()
        .map_err(|_| format!("--limit must be a non-negative integer; got '{raw}'"))?;
    if value < 0 {
        return Err(format!("--limit must be non-negative; got {value}"));
    }
    Ok(Some(value as usize))
}

/// Parses `--estate-mode unencrypted|encrypted` (default: unencrypted) into
/// the scratch posture, refusing encrypted mode combined with
/// `--estate-cache reuse` (a temporal-key estate snapshot could never be
/// reopened). Twin of Swift `parseEstateMode(in:)`.
fn parse_estate_mode(args: &[String]) -> Result<ScratchEstatePosture, String> {
    let mode = option_value("--estate-mode", args).unwrap_or("unencrypted");
    let posture = match mode {
        "unencrypted" => ScratchEstatePosture::PlaintextTransient,
        "encrypted" => ScratchEstatePosture::EncryptedEphemeral,
        other => {
            return Err(format!(
                "--estate-mode must be 'unencrypted' or 'encrypted'; got '{other}'"
            ))
        }
    };
    if posture == ScratchEstatePosture::EncryptedEphemeral
        && option_value("--estate-cache", args) == Some("reuse")
    {
        return Err(
            "--estate-mode encrypted cannot be combined with --estate-cache reuse: \
             an encrypted scratch estate uses a temporal in-process key, so a \
             snapshot could not be reopened. Run encrypted mode with --estate-cache off."
                .to_string(),
        );
    }
    Ok(posture)
}

/// True when a bare flag is present. Mirrors Swift `flagPresent`.
fn flag_present(name: &str, args: &[String]) -> bool {
    args.iter().any(|a| a == name)
}

/// The accepted option surface of one subcommand: options that take a value as
/// the following argument, and bare flags that take none.
///
/// The split is load-bearing for validation, not decoration. The token after a
/// VALUED option is skipped, so `--seed -1` does not read `-1` as an option.
/// The token after a BARE flag is not skipped, which is what lets
/// `--skip-dream --typo` be caught. Twin of Swift `OptionSurface`.
struct OptionSurface {
    /// Options whose value is the next argument.
    valued: &'static [&'static str],
    /// Flags that carry no value.
    bare: &'static [&'static str],
}

impl OptionSurface {
    /// Every accepted name, sorted, for the failure message.
    fn accepted_names(&self) -> String {
        let mut names: Vec<&str> = self.valued.iter().chain(self.bare.iter()).copied().collect();
        names.sort_unstable();
        names.join(" ")
    }
}

/// Options this CLI used to accept and no longer does, each paired with the
/// replacement the failure message names.
///
/// FAIL, DO NOT ALIAS. Accepting a retired name as a synonym keeps it alive
/// indefinitely and hides the migration from the operator. Rejected once, the
/// stored script gets fixed once.
///
/// `--no-plaintext-scratch` selected the encrypted scratch posture until
/// `--estate-mode unencrypted|encrypted` replaced it. It matters more than the
/// usual retired flag because a missing `--estate-mode` defaults to
/// `unencrypted` -> `PlaintextTransient`: an
/// invocation still carrying the retired name ran PLAINTEXT while its author
/// believed it had asked for encryption, and nothing said so. Twin of Swift
/// `retiredOptions`.
const RETIRED_OPTIONS: &[(&str, &str)] = &[("--no-plaintext-scratch", "--estate-mode encrypted")];

/// Every subcommand of `mcp-benchmarker-rs` and the options it accepts.
///
/// This table is the whole reason an unrecognised argument can be rejected at
/// all: each parser reads its own options by name, so without a declared
/// surface there is nothing to compare a stray token against. A new option MUST
/// be added here in the same commit that teaches a parser to read it —
/// otherwise the parser reads it and the validator rejects it, making the
/// feature silently unreachable from the CLI.
///
/// INVARIANT: every flag any lane runner reads via `option_value` or
/// `flag_present` MUST be listed in its subcommand's surface here. A parsed
/// but unregistered flag is unreachable — `validate_options` fires before the
/// runner sees the argument. This defect class has recurred across the C10 and
/// C11 commits (BH-02 finding #6); enforce it by grepping for
/// `option_value("--` and `flag_present("--` in the runner when adding a lane.
///
/// Asymmetry with the Swift twin's table is expected and intentional: the two
/// ports deliberately take different names for some of the same inputs (Rust
/// `--corpus` / `--binary` where Swift takes `--data-file` /
/// `--mootx01-binary`), and the Swift binary carries subcommands this one does
/// not. The official matrix scripts already pass per-port flag sets for exactly
/// that reason.
// Transfer and report subcommands are not part of this crate.
const OPTION_SURFACES: &[(&str, OptionSurface)] = &[
    (
        // `lme` is an accepted alias of this subcommand and shares the surface.
        "longmemeval",
        OptionSurface {
            valued: &["--run-id", 
                "--arm",
                "--binary",
                "--cache-dir",
                "--corpus",
                "--data-dir",
                "--dump-judge-inputs",
                "--encode-barrier",
                "--estate-cache",
                "--estate-mode",
                "--exact-strategy",
                "--judge-cmd",
                "--judge-grading",
                "--judge-hydration-depth",
                "--label",
                "--limit",
                "--mootx01-binary",
                "--out",
                "--recall-shape",
                "--rerank-cmd",
                "--parallel",
                "--shape",
                "--seed",
                "--seed-path",
                "--slice",
                "--variant",
            ],
            bare: &["--settle", "--synthesize-arm"],
        },
    ),
    (
        "locomo",
        OptionSurface {
            valued: &["--run-id", 
                "--binary",
                "--cache-dir",
                "--corpus",
                "--data-file",
                "--encode-barrier",
                "--estate-cache",
                "--estate-mode",
                "--guard-sample",
                "--label",
                "--limit",
                "--mootx01-binary",
                "--offset",
                "--out",
                "--parallel",
                "--recall-shape",
                "--rerank-cmd",
                "--seed",
                "--seed-path",
                "--shape",
                "--strategy",
            ],
            bare: &[],
        },
    ),
    (
        // locomo-spec: official LoCoMo QA scoring protocol (§1–§6). Uses the same
        // corpus fixture as `locomo` but evaluates answer quality (F1/exact/abstention)
        // rather than recall@k/MRR. --strategy/--category/--recall-shape/--rerank-cmd
        // are absent: the spec lane always uses moot_synthesize and scores all five
        // categories. --seed-path is always batch; --estate-shape is always
        // per-conversation (spec never uses the consolidated Shape 3 topology).
        // INVARIANT: every flag run_locomo_spec reads via option_value MUST be listed here.
        "locomo-spec",
        OptionSurface {
            valued: &[
                "--run-id",
                "--binary",
                "--mootx01-binary",
                "--corpus",
                "--data-file",
                "--dump-answer-inputs",
                "--answer-hydration-depth",
                "--hydration-tier",
                "--target-scale",
                "--catalog",
                "--estate-dir",
                "--guard-sample",
                "--limit",
                "--offset",
                "--out",
                "--parallel",
                "--recall-shape",      // shaped-recall preset (moot_recall_shaped)
                "--request-limit",     // per-query MCP request cap
                "--scoring",
                "--seed",
                "--short-query-terms", // token budget for short-query sub-metric
            ],
            bare: &["--pool-metrics"], // expose pool-coverage metrics in the report
        },
    ),
    (
        // artifact-recall: read-only recall measurement against PRE-BUILT
        // benchmark artifacts, all four datasets (#94 measure seam). No
        // seeding, no scratch estate: --target-scale picks unit
        // (--catalog, one catalog-resolved estate per instance) or an aggregate
        // (--estate-dir); id-map.json inside each estate maps seed record
        // ids to drawer UUIDs for scoring; --id-prefix defaults to
        // "<dataset>/" at complete-aggregate (the build-plumbing record-id
        // prefix). --mootx01-binary is the Swift twin's spelling of
        // --binary (accepted for contract parity). Twin of the Swift
        // "artifact-recall" subcommand.
        // INVARIANT: every flag run_artifact_recall reads via option_value
        // MUST be listed here.
        "artifact-recall",
        OptionSurface {
            valued: &[
                "--dataset",
                "--target-scale",
                "--estate-dir",
                "--catalog",
                "--id-prefix",
                "--questions",
                "--scope",
                "--limit",
                "--top-k",
                "--out",
                "--binary",
                "--mootx01-binary",
            ],
            bare: &[],
        },
    ),
    (
        // payload-economics: payload-token-economics measurement over the
        // frozen lme-s artifact estate (run book §9). Mechanical, judge-free
        // — exact/dense retrieval payloads plus an optional moot_synthesize
        // digest arm (--synthesize-arm; that combination is the
        // synthesis-payload lane, same runner). --activation-arm serves a
        // copy-on-write clone of the artifact with exactly that minter set
        // active; --arm-scratch-root is where the clone lives. Twin of the
        // Swift "payload-economics" subcommand.
        // INVARIANT: every flag run_payload_economics reads via option_value
        // or flag_present MUST be listed here.
        "payload-economics",
        OptionSurface {
            valued: &[
                "--estate-dir",
                "--questions",
                "--data-dir",
                "--variant",
                "--synthesize-limit",
                "--payload-arm",
                "--limit",
                "--top-k",
                "--out",
                "--binary",
                "--mootx01-binary",
            ],
            bare: &["--synthesize-arm"],
        },
    ),
    (
        // lme-spec: official LongMemEval judged-QA protocol
        // (LONGMEMEVAL_OFFICIAL_PROTOCOL.md §1–§4). Same dataset dir as
        // `longmemeval`; runs ALL 500 instances including abstention, produces
        // hypothesis JSONL + §2 anscheck judge-input dumps; §3 verdicts via the
        // BYOAI judge-cmd seam. Twin of the Swift "lme-spec" subcommand.
        // INVARIANT: every flag run_lme_spec_cmd reads via option_value MUST be
        // listed here.
        "lme-spec",
        OptionSurface {
            valued: &[
                "--run-id",
                "--binary",
                "--mootx01-binary",
                "--data-dir",
                "--variant",
                "--target-scale",
                "--catalog",
                "--estate-dir",
                "--dump-judge-inputs",
                "--dump-answer-inputs",
                "--answer-hydration-depth",
                "--hydration-tier",
                "--judge-cmd",
                "--judge-model",
                "--guard-sample",
                "--limit",
                "--offset",
                "--out",
                "--parallel",
                "--seed",
            ],
            bare: &[],
        },
    ),
    (
        // membench-spec: official MemBench protocol (MEMBENCH_OFFICIAL_PROTOCOL.md
        // §2–§6). §3 answers via --answer-cmd (BYOAI; MOOT_BENCH_ANSWER_CMD env
        // preferred) or the dump/consume offline pair; --capacity switches to the
        // §6 step_cap walk. No --estate-cache/--cache-dir: fresh per-item estates
        // only (§5 timers forbid snapshot reuse). Twin of Swift "membench-spec".
        // INVARIANT: every flag run_membench_spec_cmd reads MUST be listed here.
        "membench-spec",
        OptionSurface {
            valued: &[
                "--run-id",
                "--binary",
                "--mootx01-binary",
                "--agent",
                "--capacity",
                "--category",
                "--consume-answers",
                "--data-dir",
                "--answer-cmd",
                "--dump-answer-inputs",
                "--encode-barrier",
                "--shape",
                "--target-scale",
                "--catalog",
                "--estate-dir",
                "--limit",
                "--offset",
                "--out",
                "--scoring",
                "--seed",
                "--estate-mode",
                "--seed-units-dir",
            ],
            bare: &[],
        },
    ),
    (
        // lmeb-spec: official LMEB retrieval protocol (§A1–§A4): full metric
        // grid + R_cap, two-level aggregation, --instruction-setting per §A4.
        // Twin of Swift "lmeb-spec". INVARIANT: every flag
        // parse_lmeb_spec_invocation / run_lmeb_spec_cmd reads MUST be here.
        "lmeb-spec",
        OptionSurface {
            valued: &[
                "--run-id",
                "--binary",
                "--mootx01-binary",
                "--data-dir",
                "--evidence-types",
                "--instruction-setting",
                "--target-scale",
                "--catalog",
                "--estate-dir",
                "--guard-sample",
                "--limit",
                "--offset",
                "--out",
                "--parallel",
                "--recall-shape",
                "--request-limit",     // per-query MCP request cap
                "--scoring",
                "--seed",
                "--short-query-terms", // token budget for short-query sub-metric
            ],
            bare: &["--pool-metrics"], // expose pool-coverage metrics in the report
        },
    ),
    (
        // convomem-spec: official ConvoMem judged-QA protocol (§B1–§B4). §B1
        // answers via --answer-cmd (MOOT_BENCH_ANSWER_CMD env preferred), §B2/§B3
        // judging via --judge-cmd (MOOT_BENCH_JUDGE_CMD env preferred); offline
        // dump paths for both. --consume-answers invokes the offline judge-dump
        // path without opening any estate. Twin of Swift "convomem-spec".
        // INVARIANT: every flag the shared parse + run_convomem_spec_cmd reads
        // MUST be here.
        "convomem-spec",
        OptionSurface {
            valued: &[
                "--run-id",
                "--binary",
                "--mootx01-binary",
                "--data-dir",
                "--evidence-types",
                "--instruction-setting",
                "--target-scale",
                "--catalog",
                "--estate-dir",
                "--answer-cmd",
                "--judge-cmd",
                "--judge-model",
                "--judge-hydration-depth",
                "--dump-answer-inputs",
                "--dump-judge-inputs",
                "--hydration-tier",
                "--consume-answers",
                "--guard-sample",
                "--limit",
                "--offset",
                "--out",
                "--parallel",
                "--seed",
            ],
            bare: &[],
        },
    ),
    (
        "membench",
        OptionSurface {
            // INVARIANT: every flag the membench runner reads via option_value or
            // flag_present MUST be registered here. An unregistered flag is
            // silently unreachable — the validator rejects the invocation before
            // the runner ever sees it. This defect class recurred across the C10
            // and C11 commits; the invariant is written here so the next person
            // adding a membench flag will see it at the declaration site.
            valued: &[
                "--run-id",
                "--agent",
                "--binary",
                // --capacity-tier selects the C11 capacity tier
                // (baseline | 10k | 100k). Read by the membench runner via
                // option_value.
                "--capacity-tier",
                "--category",
                "--cache-dir",
                "--data-dir",
                "--encode-barrier",
                "--estate-cache",
                // --estate-grouping selects the C10 estate shape
                // (per-item | consolidated). Read by the membench runner via
                // option_value.
                "--estate-grouping",
                "--estate-mode",
                "--limit",
                "--mootx01-binary",
                "--offset",
                "--out",
                "--parallel",
                "--seed",
                "--seed-path",
                "--shape",
            ],
            bare: &[],
        },
    ),
    (
        "lmeb",
        OptionSurface {
            valued: &["--run-id", 
                "--binary",
                "--cache-dir",
                "--corpus",
                "--data-dir",
                "--dump-judge-inputs",
                "--encode-barrier",
                "--estate-cache",
                "--estate-mode",
                // --estate-shape selects LMEB estate topology
                // (per-query | consolidated). Read by the lmeb runner via
                // option_value.
                "--estate-shape",
                "--evidence-types",
                "--label",
                "--limit",
                "--mootx01-binary",
                "--offset",
                "--out",
                "--parallel",
                "--seed",
                "--seed-path",
                "--shape",
            ],
            bare: &[],
        },
    ),
    (
        "judge-batch",
        OptionSurface {
            valued: &[
                "--inputs",
                "--judge-cmd",
                "--judge-grading",
                "--out",
            ],
            bare: &[],
        },
    ),
    (
        "answer-batch",
        OptionSurface {
            valued: &[
                "--inputs", "--answer-cmd", "--out", "--limit", "--offset",
                "--reader-model", "--judge-model",
            ],
            bare: &[],
        },
    ),
    (
        "supersession",
        OptionSurface {
            valued: &["--run-id", 
                "--binary",
                "--contradictions",
                "--decoys",
                "--divergences",
                "--dump-seed",
                "--entities",
                "--estate-cache",
                "--estate-mode",
                "--k",
                "--mootx01-binary",
                "--recall-shape",
                "--seed",
                "--seed-path",
                "--shape",
                "--versions",
            ],
            bare: &[
                "--fact-layer",
                "--skip-contradictions",
                "--skip-dream",
                "--structured-tier",
            ],
        },
    ),
    (
        "journey",
        OptionSurface {
            // --binary / --mootx01-binary, --k, and --estate-mode are needed
            // by the live runner (run_journey_lane): binary discovery, the
            // PRECISE-MISS/VAGUE-NARROW rank cutoff, and scratch-estate
            // posture respectively. (The Swift `journey` OptionSurface in
            // CLI.swift has not been updated to accept these — a pre-existing
            // gap out of this mission's Rust-only scope; noted for a future
            // Swift-side mission.)
            valued: &[
                "--run-id",
                "--binary",
                "--cluster-count",
                "--dump-seed",
                "--estate-mode",
                "--k",
                "--members-per-cluster",
                "--mootx01-binary",
                "--out",
                "--precise-miss-count",
                "--run-mode",
                "--seed",
                "--shape",
            ],
            bare: &[],
        },
    ),
    (
        // timing: C2 write/ingest timing lane (benchmark reset 2026-08-13).
        // Twin of Swift "timing" surface in optionSurfaces.
        "timing",
        OptionSurface {
            valued: &["--run-id", 
                "--binary",
                "--mootx01-binary",
                "--out",
                "--repeats",
                "--run-mode",
                "--seed",
                "--sizes",
            ],
            bare: &[],
        },
    ),
    (
        // replay: supersession determinism probe. Accepts the same corpus-shaping
        // and recall flags as supersession, plus --runs. Does NOT accept
        // --dump-seed, --fact-layer, or --estate-mode both (those are
        // supersession-only; replay compares runs of one posture, not postures).
        // Twin of Swift "replay" surface in optionSurfaces.
        "replay",
        OptionSurface {
            valued: &[
                "--binary",
                "--contradictions",
                "--entities",
                "--estate-mode",
                "--k",
                "--mootx01-binary",
                "--recall-shape",
                "--runs",
                "--seed",
                "--seed-path",
                "--versions",
            ],
            bare: &[
                "--lane-capture",
                "--skip-contradictions",
                "--skip-dream",
                "--structured-tier",
            ],
        },
    ),
    (
        // gauntlet-corpus: deterministic corpus generation only (no live backend).
        // Twin of Swift GauntletCLI.swift "gauntlet-corpus" subcommand.
        "gauntlet-corpus",
        OptionSurface {
            valued: &[
                "--seed",
                "--out",
                "--per-tier",
                "--distractors",
                "--tiers",
            ],
            bare: &[],
        },
    ),
    (
        // capturespread-corpus: deterministic corpus generation only (no live backend).
        // Twin of Swift CaptureSpreadCorpus.swift "capturespread-corpus" subcommand.
        "capturespread-corpus",
        OptionSurface {
            valued: &[
                "--seed",
                "--probes",
                "--distractors",
                "--out",
            ],
            bare: &[],
        },
    ),
    (
        // capturespread: capture-spread benchmark lane.
        // Twin of Swift CaptureSpreadRunner.swift "capturespread" subcommand.
        "capturespread",
        OptionSurface {
            valued: &[
                "--run-id",
                "--binary",
                "--cache-dir",
                "--distractors",
                "--estate-cache",
                "--k",
                "--mootx01-binary",
                "--out",
                "--probes",
                "--recall-shape",
                "--seed",
                "--serial",
                "--variant",
            ],
            bare: &[],
        },
    ),
    (
        // gauntlet: full recall gauntlet — seed, dream, guard, score, report.
        // Twin of Swift GauntletCLI.swift "gauntlet" subcommand.
        "gauntlet",
        OptionSurface {
            valued: &["--run-id", 
                "--binary",
                "--config",
                "--corpus",
                "--distractors",
                "--guard-sample",
                "--k",
                "--limit",
                "--mootx01-binary",
                "--out",
                "--per-tier",
                "--run-label",
                "--run-mode",
                "--scratch-dir",
                "--seed",
                "--seed-path",
                "--shape",
                "--tiers",
            ],
            bare: &[
                "--moot-only",
                "--quick",
                "--reuse-backends",
            ],
        },
    ),
];

/// Canonicalises a subcommand token to the name its surface is filed under.
fn surface_key(subcommand: &str) -> &str {
    match subcommand {
        "lme" => "longmemeval",
        other => other,
    }
}

/// Rejects retired options and unrecognised options before a subcommand runs.
///
/// Both parsers used to ignore anything they did not recognise: `option_value`
/// finds a name or returns None, and an unmatched token is never read and never
/// reported. That is how `--no-plaintext-scratch` came to run a plaintext
/// estate silently, and it is equally how `--estate-mode=encrypted` (the `=`
/// form this CLI does not take) or `--estate-mod encrypted` would.
///
/// Positional arguments — tokens that do not start with `-` — are ignored; only
/// option-shaped tokens are checked. A subcommand with no declared surface gets
/// the retired-option check only. Twin of Swift `validateOptions`.
fn validate_options(subcommand: &str, args: &[String]) -> Result<(), String> {
    // Retired names are rejected under EVERY subcommand, including ones that
    // never accepted them, so the operator gets the same answer wherever the
    // stale invocation lives.
    for arg in args {
        // `--name=value` is not a form this CLI accepts anywhere; split at the
        // first `=` so a retired name written that way is still recognised.
        let name = arg.split('=').next().unwrap_or(arg);
        if let Some((_, replacement)) = RETIRED_OPTIONS.iter().find(|(r, _)| *r == name) {
            return Err(format!(
                "{name} was removed and is NOT accepted as a synonym; use \
                 {replacement} instead. A run that asked for encryption and \
                 silently got plaintext is worse than a run that failed."
            ));
        }
    }
    let key = surface_key(subcommand);
    let Some((_, surface)) = OPTION_SURFACES.iter().find(|(name, _)| *name == key) else {
        return Ok(());
    };
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].as_str();
        if !arg.starts_with('-') {
            index += 1;
            continue;
        }
        if surface.valued.contains(&arg) {
            // Skip the value so a value that itself starts with `-` (a negative
            // number, a leading-dash judge command) is not read as an option.
            index += 2;
            continue;
        }
        if surface.bare.contains(&arg) {
            index += 1;
            continue;
        }
        return Err(format!(
            "unknown option '{arg}' for subcommand '{subcommand}'. This CLI \
             takes an option value as a separate argument (--estate-mode \
             encrypted), never joined with '='. Accepted: {}",
            surface.accepted_names()
        ));
    }
    reject_ram_shape_with_artifacts(args)
}

/// RAM shape and the artifact store are mutually exclusive.
///
/// `--shape ram` runs the estate with `--in-memory`, so there
/// is no estate file on disk to snapshot. Left unguarded the pair is silently
/// destructive rather than merely useless: the run would snapshot a scratch
/// directory holding no estate, store it under a key that carries no shape
/// component, and a later disk run under `--estate-cache require` would restore
/// that empty artifact and measure nothing — reporting the result as a
/// successful measurement.
///
/// Twin of Swift `rejectRamShapeWithArtifacts(in:)`.
fn reject_ram_shape_with_artifacts(args: &[String]) -> Result<(), String> {
    if option_value("--shape", args) != Some("ram") {
        return Ok(());
    }
    let cache_mode = option_value("--estate-cache", args).unwrap_or("off");
    if cache_mode == "off" {
        return Ok(());
    }
    Err(format!(
        "--shape ram cannot be combined with --estate-cache {cache_mode}: a RAM \
         estate has no file on disk to snapshot or restore. Artifacts are disk \
         estates by definition (Shape 2). Use --shape disk to build or measure \
         against artifacts, or drop --estate-cache to run RAM uncached."
    ))
}

#[cfg(test)]
mod ram_shape_guard_tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    /// A RAM estate has no file on disk, so pairing it with the artifact store
    /// would snapshot an empty scratch directory under a key that carries no
    /// shape component — and a later disk run under `require` would restore
    /// that empty artifact and report measuring nothing as a success.
    #[test]
    fn ram_shape_rejected_with_artifacts() {
        for mode in ["reuse", "require"] {
            let a = args(&["--shape", "ram", "--estate-cache", mode]);
            assert!(validate_options("membench", &a).is_err(), "mode {mode} must be refused");
        }
    }

    #[test]
    fn ram_shape_allowed_uncached() {
        assert!(validate_options("membench", &args(&["--shape", "ram"])).is_ok());
        assert!(
            validate_options("membench", &args(&["--shape", "ram", "--estate-cache", "off"]))
                .is_ok()
        );
    }

    #[test]
    fn disk_shape_unaffected() {
        assert!(
            validate_options("membench", &args(&["--shape", "disk", "--estate-cache", "require"]))
                .is_ok()
        );
    }
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

// ─────────────────────────────────────────────────────────────────────────────
// Legacy-lane darkening gates (ruling 2026-08-18)
// ─────────────────────────────────────────────────────────────────────────────

/// Rejects a darkened non-deterministic legacy option (ruling 2026-08-18:
/// deterministic legacy lanes stay runnable on demand; non-deterministic
/// legacy paths go dark in code until a removal ruling). Code retained;
/// activation disabled. The spec lanes carry the sanctioned model-dependent
/// paths. Twin of Swift `rejectDarkenedLegacyOptions`.
/// The inventory is enforced by the lane's conformance tests.
fn reject_darkened_legacy_options(
    lane: &str,
    flags: &[&str],
    env_vars: &[&str],
    args: &[String],
    replacement: &str,
) -> Result<(), String> {
    for flag in flags {
        if option_value(flag, args).is_some() {
            return Err(format!(
                "{flag} is dark on the legacy {lane} lane (non-deterministic \
                 path; ruling 2026-08-18). The code is retained but the path is \
                 disabled. Use {replacement} instead."
            ));
        }
    }
    for env in env_vars {
        if std::env::var(env).is_ok() {
            return Err(format!(
                "{env} is dark on the legacy {lane} lane (non-deterministic \
                 path; ruling 2026-08-18). Unset it for legacy runs, or use \
                 {replacement}."
            ));
        }
    }
    Ok(())
}

fn run_longmemeval(args: &[String]) -> Result<(), String> {
    // Darkening gates ND-LME-1..4 (ruling 2026-08-18).
    reject_darkened_legacy_options(
        "longmemeval",
        &["--judge-cmd", "--rerank-cmd"],
        &["MOOT_BENCH_JUDGE_CMD", "MOOT_BENCH_RERANK_CMD"],
        args,
        "the lme-spec lane (official judged protocol, offline judge batches)",
    )?;
    if option_value("--judge-grading", args) == Some("verdict") {
        return Err(
            "--judge-grading verdict is dark on the legacy longmemeval lane \
             (ND-LME-2, ruling 2026-08-18). Use the lme-spec lane's §3 verdicts."
                .to_string(),
        );
    }
    if args.iter().any(|a| a == "--synthesize-arm") {
        return Err(
            "--synthesize-arm is dark on the legacy longmemeval lane \
             (ND-LME-4, ruling 2026-08-18). Use the lme-spec lane."
                .to_string(),
        );
    }
    // --corpus is the Rust-native flag; --data-dir is the Swift twin spelling.
    // Accept both: --data-dir takes priority when both are present.
    let corpus_path = option_value("--data-dir", args)
        .or_else(|| option_value("--corpus", args))
        .map(str::to_string)
        .ok_or_else(|| "missing required option --corpus (or --data-dir)".to_string())?;
    // --binary is the Rust-native flag; --mootx01-binary is the Swift twin spelling.
    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
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
    let limit = parse_limit_option(args)?;
    let label = option_value("--label", args).map(str::to_string);
    let out_dir = option_value("--out", args).map(PathBuf::from);
    if let Some(ref d) = out_dir {
        std::fs::create_dir_all(d)
            .map_err(|e| format!("could not create output directory '{}': {}", d.display(), e))?;
    }
    // --arm exact|dense|both (default: both). Controls which recall arms run.
    let arm_str = option_value("--arm", args).unwrap_or("both");
    let arm = match arm_str {
        "exact" => LmeArm::Exact,
        "dense" => LmeArm::Dense,
        "both"  => LmeArm::Both,
        other   => return Err(format!("--arm must be 'exact', 'dense', or 'both'; got '{other}'")),
    };
    // --encode-barrier drain|impatient|none (default: drain).
    // Controls encode-queue synchronization strategy.
    let encode_barrier = match option_value("--encode-barrier", args) {
        Some(s) => EncodeBarrier::from_str(s).map_err(|e| e)?,
        None => EncodeBarrier::default(),
    };
    // Judge mode (LME-03 Part 4): optional LLM-judged QA. Off by default.
    // The command receives the prompt on stdin and writes its answer on stdout.
    // SECURE PATH: set MOOT_BENCH_JUDGE_CMD in the environment — the env var
    // does not appear in `ps` argv. The --judge-cmd flag is kept for
    // compatibility; its value IS visible in `ps`. Env var takes precedence.
    let judge_cmd: Option<String> = std::env::var("MOOT_BENCH_JUDGE_CMD")
        .ok()
        .or_else(|| option_value("--judge-cmd", args).map(str::to_string));
    // Rerank mode (W2-rerank): optional rerank command applied after retrieval.
    // Top-10 hits are handed to the command; it returns a permutation of
    // candidate numbers. Presence only in the report — same secrecy rule as
    // judge_cmd (user-supplied shell may carry API keys).
    // SECURE PATH: set MOOT_BENCH_RERANK_CMD in the environment (same rationale).
    let rerank_cmd: Option<String> = std::env::var("MOOT_BENCH_RERANK_CMD")
        .ok()
        .or_else(|| option_value("--rerank-cmd", args).map(str::to_string));
    // Judge grading mode: substring (deterministic, free, under-counts
    // paraphrases) or verdict (a second judge call returns CORRECT/INCORRECT —
    // the protocol published leaderboard figures use). Twin of Swift
    // --judge-grading.
    let judge_grading = LmeJudgeGrading::from_str(
        option_value("--judge-grading", args).unwrap_or("substring"),
    )?;
    // How many ranked hits are hydrated to full content for the judge. The
    // recall verbs return 120-char previews, which are not answerable context.
    // THIS MOVES THE ACCURACY NUMBER — it is printed with the result.
    let judge_hydration_depth: usize = match option_value("--judge-hydration-depth", args) {
        Some(v) => v
            .parse()
            .map_err(|_| "--judge-hydration-depth must be a positive integer".to_string())
            .and_then(|n: usize| {
                if n == 0 {
                    Err("--judge-hydration-depth must be a positive integer".to_string())
                } else {
                    Ok(n)
                }
            })?,
        None => LME_DEFAULT_JUDGE_PAYLOAD_HYDRATION_DEPTH,
    };
    // --estate-cache off|reuse (default: off). Controls estate snapshot reuse.
    let estate_cache = match option_value("--estate-cache", args) {
        Some(s) => EstateCacheMode::from_str(s).map_err(|e| e)?,
        None => EstateCacheMode::default(),
    };
    // --cache-dir <path>: override cache root (default: <out>/estate-cache).
    let cache_dir = option_value("--cache-dir", args).map(PathBuf::from);
    // --estate-mode unencrypted|encrypted (default: unencrypted). Encrypted
    // runs use the temporal-key posture (see parse_estate_mode). Encrypted and
    // unencrypted are SEPARATE runs under the one-test-at-a-time protocol.
    let scratch_posture = parse_estate_mode(args)?;
    // 2026-08-18 doctrine: encryption is a timing-lane-only concern.
    if scratch_posture == ScratchEstatePosture::EncryptedEphemeral {
        return Err("encryption is tested only by the timing lane".to_string());
    }
    // --settle: run each question twice — ORGANIC cell (immediately after ingest +
    // drain) and SETTLED cell (after moot_reindex + drain). Both cells appear in the
    // report under testmark_cells. Off by default. Twin of Swift --settle flag.
    let settle = flag_present("--settle", args);
    // --synthesize-arm: on the Swift leg, calls moot_synthesize per question as a
    // fourth answer-payload mode (PR-08 D3). Additive — does not affect retrieval
    // scoring. Off by default.
    //
    // NOT IMPLEMENTED IN THIS PORT. The per-question runner does not call
    // moot_synthesize, so the flag changes nothing about what runs. It is accepted
    // rather than rejected so a shared invocation can be pointed at either leg,
    // but an operator who supplies it and reads a synthesize cell of zeros is owed
    // an explanation at the point of the request rather than a silent no-op. The
    // report's synthesize cell is computed from observed results and will read
    // enabled: false, question_count: 0 — which is the truth, not a bug.
    let synthesize_arm = flag_present("--synthesize-arm", args);
    if synthesize_arm {
        eprintln!(
            "[lme] WARNING: --synthesize-arm is not implemented in the Rust port. \
             moot_synthesize is not called per question; the run proceeds without \
             the synthesize arm and the report's synthesize_cell will report \
             enabled: false, question_count: 0. Use the Swift leg for this arm."
        );
    }

    eprintln!("[lme] loading corpus from {corpus_path}");
    let corpus = load_corpus(Path::new(&corpus_path))
        .map_err(|e| format!("corpus load failed: {}", e.0))?;
    // B2 provenance: digest the corpus fixture once at load time.
    let lme_corpus_digest =
        mcp_benchmarker_rs::run_environment::file_sha256_hex(&corpus_path)
            .unwrap_or_else(|| "unknown".to_string());
    eprintln!(
        "[lme] corpus: {} questions ({} abstention excluded)",
        corpus.questions.len(),
        corpus.abstention_count,
    );
    eprintln!("[lme] binary: {binary}  variant: {variant}  seed: {seed}");
    if let Some(n) = limit {
        eprintln!("[lme] limit: {n}");
    }
    let exact_strategy = match option_value("--exact-strategy", args) {
        Some(v) => ExactRecallStrategy::parse(v).ok_or_else(||
            format!("--exact-strategy must be auto|search|relevance|precise|shaped; got '{v}'"))?,
        None => ExactRecallStrategy::Auto,
    };
    // --recall-shape <preset>: RecallShape preset for --exact-strategy shaped.
    // Validated against the roster so a typo fails loudly instead of silently
    // running the product default. Twin of the Swift preset validation.
    let recall_shape = option_value("--recall-shape", args).map(str::to_string);
    if let Some(ref shape) = recall_shape {
        if !LME_RECALL_SHAPE_PRESETS.contains(&shape.as_str()) {
            return Err(format!(
                "--recall-shape must be one of: {}; got '{shape}'",
                LME_RECALL_SHAPE_PRESETS.join(", ")
            ));
        }
    }
    eprintln!("[lme] exact-strategy: {}", exact_strategy.as_str());
    if let Some(ref shape) = recall_shape {
        eprintln!("[lme] recall-shape: {shape}");
    }
    eprintln!("[lme] encode-barrier: {}", encode_barrier.as_str());
    if settle {
        eprintln!("[lme] settle: on (ORGANIC + SETTLED cells via moot_reindex)");
    }

    // --slice dev|holdout (default: absent = full set). Applied AFTER the seeded
    // shuffle and BEFORE the limit, so `--slice dev --limit 10` returns the first
    // 10 questions of the 50-question dev half. The boundary is hard-coded at 50
    // (LME_DEV_SLICE_SIZE in longmemeval_runner.rs). Cells produced with different
    // --slice values are NOT interchangeable; the value is recorded in run_parameters.
    let slice: Option<String> = match option_value("--slice", args) {
        None => None,
        Some(v) => {
            match v {
                "dev" | "holdout" => Some(v.to_string()),
                other => {
                    return Err(format!(
                        "--slice value '{other}' is not accepted. Valid values: dev, holdout"
                    ));
                }
            }
        }
    };
    if let Some(ref s) = slice {
        eprintln!("[lme] slice: {s}");
    }

    // --dump-judge-inputs <path>: write pre-judge payload JSONL for offline judging.
    let dump_judge_inputs_path = option_value("--dump-judge-inputs", args).map(str::to_string);
    if let Some(ref p) = dump_judge_inputs_path {
        eprintln!("[lme] dump-judge-inputs: {p}");
    }

    // Every run option that moves the accuracy number (MXE-BK). Each was
    // already honoured by the run; it just was not written down. Built HERE,
    // before `run_config` takes ownership of `arm` and `recall_shape`.
    //
    // The judge command is recorded as presence ONLY — never its text and
    // never anything derived from it, which is user-supplied shell that
    // routinely carries API keys (see the `judge_cmd_set` doc comment for
    // why derived material is also banned).
    let run_parameters = LmeReportRunParameters {
        judge_hydration_depth,
        judge_grading: judge_grading.as_str().to_string(),
        judge_cmd_set: judge_cmd.is_some(),
        // Presence only — same secrecy rule as judge_cmd_set.
        rerank_cmd_set: rerank_cmd.is_some(),
        arm: match arm {
            LmeArm::Exact => "exact",
            LmeArm::Dense => "dense",
            LmeArm::Both => "both",
        }
        .to_string(),
        exact_strategy: exact_strategy.as_str().to_string(),
        recall_shape: recall_shape.clone(),
        seed,
        limit,
        slice: slice.clone(),
    };

    // C1: --shape disk|ram (default: disk). Backend shape for the scratch estate.
    // ram passes --in-memory to the serve command.
    // Incompatible with estate_cache Reuse or Require (rejected below).
    let lme_shape = match option_value("--shape", args).unwrap_or("disk") {
        "disk" => mcp_benchmarker_rs::longmemeval_runner::LmeShape::Disk,
        "ram"  => mcp_benchmarker_rs::longmemeval_runner::LmeShape::Ram,
        v => return Err(format!("--shape must be 'disk' or 'ram'; got '{v}'")),
    };
    if lme_shape == mcp_benchmarker_rs::longmemeval_runner::LmeShape::Ram
        && estate_cache != mcp_benchmarker_rs::estate_cache::EstateCacheMode::Off
    {
        return Err(
            "--shape ram cannot be combined with --estate-cache reuse or require: \
             an in-memory estate vanishes when the server exits, so there is no \
             snapshot to restore. Run --shape ram with --estate-cache off."
                .to_string(),
        );
    }
    // C6: --parallel N (default: max(1, 80% of logical cores)).
    // Maximum concurrent questions on the fresh-per-question path (serial = 1).
    let lme_default_parallel = std::thread::available_parallelism()
        .map(|n| std::cmp::max(1, (n.get() as f64 * 0.8) as usize))
        .unwrap_or(1);
    let lme_parallel_units: usize = match option_value("--parallel", args) {
        None => lme_default_parallel,
        Some(v) => v
            .parse::<usize>()
            .ok()
            .filter(|&n| n >= 1)
            .ok_or_else(|| format!("--parallel must be a positive integer; got '{v}'"))?,
    };

    // 2026-08-18 doctrine: accuracy lane emits binary identity only, not full machine profile.
    let mut lme_run_env = IdentityEnvironment::collect(Some(binary.as_str()));
    // Instrument seams (environment-only; see retrieval_call_spec.rs):
    // MOOT_BENCH_RETRIEVAL_TOOL/_ARGS override the query call;
    // MOOT_BENCH_UNIT_IDS pins the unit set.
    let retrieval_call = mcp_benchmarker_rs::retrieval_call_spec::retrieval_call_spec_from_environment()?;
    let unit_ids = mcp_benchmarker_rs::retrieval_call_spec::unit_ids_from_environment()?;
    // --payload-arm v0..v5 (PAYLOAD-ARMS; MOOT_BENCH_PAYLOAD_ARM as the
    // environment spelling): payload-economics shape variant applied to
    // seam-routed retrieval text_blocks. Recorded in run_environment.
    let payload_arm = mcp_benchmarker_rs::payload_arm::parse_payload_arm(
        option_value("--payload-arm", args)
            .map(str::to_string)
            .or_else(|| std::env::var("MOOT_BENCH_PAYLOAD_ARM").ok())
            .as_deref())?;
    if let Some(ids) = &unit_ids {
        mcp_benchmarker_rs::unit_id_filter::validate_unit_ids(
            ids, corpus.questions.iter().map(|q| q.question_id.as_str()), "longmemeval")?;
    }
    // Fail-loud (mislabeled-cell rule): the arm only acts on seam-routed
    // retrieval in this lane; an arm without the seam would be recorded in
    // run_environment yet never applied — a falsified cell.
    if payload_arm.is_some() && retrieval_call.is_none() {
        return Err("--payload-arm requires the retrieval seam in the longmemeval lane \
(set MOOT_BENCH_RETRIEVAL_TOOL); the exact-strategy doors do not carry the arm".to_string());
    }
    lme_run_env.payload_arm = payload_arm.map(|a| a.as_str().to_string());
    let run_config = LmeRunConfig {
        moot_binary: binary,
        unit_ids: unit_ids.clone(),
        retrieval_call: retrieval_call.clone(),
        payload_arm,
        variant: variant.clone(),
        seed,
        limit,
        label: label.clone(),
        out_dir: out_dir.clone(),
        arm,
        judge_cmd: judge_cmd.clone(),
        judge_grading,
        judge_hydration_depth,
        rerank_cmd: rerank_cmd.clone(),
        encode_barrier,
        estate_cache,
        exact_strategy,
        recall_shape,
        cache_dir,
        scratch_posture,
        settle,
        synthesize_arm,
        slice,
        // Batch by default (ruling 8D5B8053); `--seed-path live` retains the slow lane.
        seed_path: mcp_benchmarker_rs::seed_export::SeedPathMode::parse(
            option_value("--seed-path", args))?,
        dump_judge_inputs_path,
        // Guard probe sampling (--guard-sample once|per-unit, default once):
        // the guard validates the binary, not the unit — probe once per leg.
        guard_sampling_policy: mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
            option_value("--guard-sample", args))?,
        corpus_digest: lme_corpus_digest.clone(),
        shape: lme_shape,
        parallel_units: lme_parallel_units,
    };

    // Keep results alongside scores so the transcript writer can read judge fields,
    // and the report builder can compute token efficiency metrics.
    // score_lme_question takes LmeQuestionResult by value — clone the parts needed
    // before consuming results.
    let (results, lme_rerank_failures, lme_timing_report) = run_lme_questions(&corpus, &run_config)?;

    // Extract judge fields (for transcript writer, LME-03 Part 4).
    struct JudgeEntry {
        question_id: String,
        exact_judge_answer: Option<String>,
        exact_judge_correct: Option<bool>,
        dense_judge_answer: Option<String>,
        dense_judge_correct: Option<bool>,
    }
    let judge_entries: Vec<JudgeEntry> = results
        .iter()
        .map(|r| JudgeEntry {
            question_id: r.question_id.clone(),
            exact_judge_answer: r.exact_judge_answer.clone(),
            exact_judge_correct: r.exact_judge_correct,
            dense_judge_answer: r.dense_judge_answer.clone(),
            dense_judge_correct: r.dense_judge_correct,
        })
        .collect();

    // Extract payload texts (for token efficiency block, LME-03 Part 5).
    let payload_entries: Vec<LmePayloadEntry> = results
        .iter()
        .map(|r| LmePayloadEntry {
            question_id: r.question_id.clone(),
            exact_payload_text: r.exact_payload_text.clone(),
            dense_payload_text: r.dense_payload_text.clone(),
        })
        .collect();

    // Judged-metric aggregates, computed before `results` is consumed by the
    // scorer. Twin of the Swift judged print block (accuracy, three-way
    // payload frontier, tokens-per-correct, gold reachability).
    let judge_accuracy = mcp_benchmarker_rs::longmemeval_scorer::lme_aggregate_judge_accuracy(
        &results,
        judge_grading.as_str(),
    );
    let preview_cells: Vec<(bool, usize)> = results
        .iter()
        .filter_map(|r| r.preview_judge_correct.map(|c| (c, r.preview_judge_tokens.unwrap_or(0))))
        .collect();
    // (tokens, correct) per arm for tokens-per-correct; None correct = not judged.
    let frontier_arms: Vec<(&str, Vec<(usize, Option<bool>)>)> = vec![
        ("preview", results.iter()
            .map(|r| (r.preview_judge_tokens.unwrap_or(0), r.preview_judge_correct)).collect()),
        ("distilled", results.iter()
            .map(|r| (r.dense_judge_tokens.unwrap_or(0), r.dense_judge_correct)).collect()),
        ("full", results.iter()
            .map(|r| (r.exact_judge_tokens.unwrap_or(0), r.exact_judge_correct)).collect()),
    ];
    let exact_judge_tokens: Vec<usize> =
        results.iter().filter_map(|r| r.exact_judge_tokens).collect();
    let dense_judge_tokens: Vec<usize> =
        results.iter().filter_map(|r| r.dense_judge_tokens).collect();
    let gold_reach: Vec<bool> =
        results.iter().filter_map(|r| r.exact_gold_reachable).collect();

    // Extract cache_hit_by_id before consuming results (required by build_lme_report).
    let cache_hit_by_id: std::collections::HashMap<String, Option<bool>> = results
        .iter()
        .map(|r| (r.question_id.clone(), r.cache_hit))
        .collect();
    // Same extraction for the drain-barrier lane evidence (FIX-HARNESS-20260727).
    let drain_lane_by_id: std::collections::HashMap<String, Option<bool>> = results
        .iter()
        .map(|r| (r.question_id.clone(), r.drain_lane_observed))
        .collect();
    // Extract synthesize (payload text, judge correct) before consuming results
    // for the synthesize_cell descriptor (PR-08 D3).
    let synthesize_results: Vec<(Option<String>, Option<bool>)> = results
        .iter()
        .map(|r| (r.synthesize_payload_text.clone(), r.synthesize_judge_correct))
        .collect();

    let scores: Vec<_> = results.into_iter().map(score_lme_question).collect();

    let run_id = {
        // Deterministic run ID: seed the same RNG used for shuffling and draw
        // one u64.  Different seeds / variants produce distinct IDs.
        let mut rng = mcp_benchmarker_rs::longmemeval_runner::SplitMix64::new(seed ^ 0xDEADBEEF);
        format!("{:016x}", rng.next_u64())
    };
    let mut run_label = label.unwrap_or_else(|| format!("lme-{variant}-seed{seed}"));
    // Append distinguishing suffix when rerank is active so cells are
    // identifiable in multi-run comparisons without reading run_parameters.
    if rerank_cmd.is_some() {
        run_label.push_str("-rerank");
    }
    let generated_at = now_iso8601();

    // Stamp testname-arm-serial before consuming lme_run_env (D1 discipline).
    // The arm is the LongMemEval variant; serial matches what crate_record_filename uses.
    let lme_serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(&args);
    lme_run_env.benchmark_test_name  = Some("lme".to_string());
    lme_run_env.benchmark_arm        = Some(variant.to_string());
    lme_run_env.benchmark_run_serial = Some(lme_serial);

    let report = build_lme_report(
        run_id,
        run_label,
        variant.clone(),
        generated_at,
        encode_barrier.as_str().to_string(),
        run_config.guard_sampling_policy.as_str().to_string(),
        run_config.shape.as_str().to_string(),
        run_config.parallel_units,
        corpus.questions.len() + corpus.abstention_count,
        corpus.abstention_count,
        &scores,
        &corpus,
        &payload_entries,
        &cache_hit_by_id,
        &drain_lane_by_id,
        estate_cache.as_str().to_string(),
        scratch_posture.as_str().to_string(),
        // Every artifact this lane restores is turn-granularity with no
        // corpus-side preference extraction, and the report records that.
        "turn".to_string(),
        false,
        settle,
        &synthesize_results,
        run_parameters,
        rerank_cmd.as_ref().map(|_| lme_rerank_failures),
        Some(lme_run_env),
        lme_timing_report,
        // C10: conflict_key_stats. None because the Rust port has no shared-estate
        // execution path (see the comment in longmemeval_runner.rs). The field exists
        // in LmeReport to match the Swift twin's JSON contract (byte-identical keys);
        // it will only be Some when a future mission wires the Rust shared-estate path.
        None,
    );

    // Print summary.
    let te = &report.token_efficiency;
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
    match te.exact_arm_mean_tokens {
        Some(t) => println!("  exact_mean_tokens:  {:.0}", t),
        None    => println!("  exact_mean_tokens:  N/A"),
    }
    match te.dense_arm_mean_tokens {
        Some(t) => println!("  dense_mean_tokens:  {:.0}", t),
        None    => println!("  dense_mean_tokens:  N/A"),
    }
    match te.dense_exact_token_ratio {
        Some(r) => println!("  dense/exact ratio:  {:.3}", r),
        None    => println!("  dense/exact ratio:  N/A"),
    }
    match te.exact_evidence_hit_rate {
        Some(r) => println!("  exact_evidence_rate:{:.3}", r),
        None    => println!("  exact_evidence_rate:N/A (no has_answer)"),
    }
    match te.dense_evidence_hit_rate {
        Some(r) => println!("  dense_evidence_rate:{:.3}", r),
        None    => println!("  dense_evidence_rate:N/A (no has_answer)"),
    }

    // Write report file.
    // `<test>-<arm>-<serial>`: the arm is the LongMemEval variant.
    let report_filename = crate_record_filename("lme", &variant.to_string(), &args);
    let report_path = out_dir
        .as_deref()
        .unwrap_or_else(|| Path::new("."))
        .join(&report_filename);
    write_lme_report(&report, &report_path)?;
    println!("report written to {}", report_path.display());

    // Judge transcript (LME-03 Part 4): write per-question judge calls to JSONL.
    // Written only when --judge-cmd was supplied.
    if judge_cmd.is_some() {
        // Build a question_id → gold_answer lookup from the corpus.
        let gold_lookup: std::collections::HashMap<&str, &str> = corpus
            .questions
            .iter()
            .map(|q| (q.question_id.as_str(), q.answer.as_str()))
            .collect();

        let mut lines: Vec<String> = Vec::new();
        for entry in &judge_entries {
            let gold = gold_lookup.get(entry.question_id.as_str()).copied().unwrap_or("");
            if let Some(ref answer) = entry.exact_judge_answer {
                let correct = entry.exact_judge_correct.unwrap_or(false);
                let row = serde_json::json!({
                    "question_id": entry.question_id,
                    "arm": "exact",
                    "gold_answer": gold,
                    "judge_answer": answer,
                    "correct": correct,
                });
                lines.push(row.to_string());
            }
            if let Some(ref answer) = entry.dense_judge_answer {
                let correct = entry.dense_judge_correct.unwrap_or(false);
                let row = serde_json::json!({
                    "question_id": entry.question_id,
                    "arm": "dense",
                    "gold_answer": gold,
                    "judge_answer": answer,
                    "correct": correct,
                });
                lines.push(row.to_string());
            }
        }
        let transcript_content = lines.join("\n") + if lines.is_empty() { "" } else { "\n" };
        let transcript_filename = format!("judge-transcript-{}-seed{}.jsonl", variant, seed);
        let transcript_path = out_dir
            .as_deref()
            .unwrap_or_else(|| Path::new("."))
            .join(&transcript_filename);
        std::fs::write(&transcript_path, transcript_content)
            .map_err(|e| format!("transcript write failed: {e}"))?;
        println!("judge transcript: {}", transcript_path.display());
    }

    // Answer accuracy (the comparable-to-published metric). Printed only when
    // a judge ran — a run without one has no accuracy, and printing 0 would
    // read as "answered nothing correctly" rather than "did not measure".
    // Twin of the Swift judged print block.
    if let Some(acc) = judge_accuracy {
        println!("  judge grading:        {}", acc.grading);
        println!("  judge hydration depth: {judge_hydration_depth}");
        // Three-way payload frontier: preview vs distilled vs full hydrated.
        if !preview_cells.is_empty() {
            let n_correct = preview_cells.iter().filter(|(c, _)| *c).count();
            let mean_tokens = preview_cells.iter().map(|(_, t)| *t).sum::<usize>() as f64
                / preview_cells.len() as f64;
            println!(
                "  answer accuracy (preview): {:.4}  ({}/{} judged, {:.0} tokens)",
                n_correct as f64 / preview_cells.len() as f64,
                n_correct,
                preview_cells.len(),
                mean_tokens,
            );
        }
        // END-TO-END EFFICIENCY: tokens spent per CORRECT answer. Payload
        // size alone does not say which mode is worth using — a mode that
        // halves the tokens but also halves the correct answers has not saved
        // anything. Lower is better; a mode with zero correct answers has no
        // finite cost and is reported as such.
        for (label, cells) in &frontier_arms {
            let judged: Vec<&(usize, Option<bool>)> =
                cells.iter().filter(|(_, c)| c.is_some()).collect();
            if judged.is_empty() {
                continue;
            }
            let total_tokens: usize = judged.iter().map(|(t, _)| *t).sum();
            let n_correct = judged.iter().filter(|(_, c)| *c == Some(true)).count();
            let cost = if n_correct > 0 {
                format!("{:.0}", total_tokens as f64 / n_correct as f64)
            } else {
                "n/a (0 correct)".to_string()
            };
            println!("  tokens per correct answer — {label}: {cost}");
        }
        // Like-for-like token cost: what the judge actually read per arm.
        if !exact_judge_tokens.is_empty() || !dense_judge_tokens.is_empty() {
            let em = if exact_judge_tokens.is_empty() {
                0.0
            } else {
                exact_judge_tokens.iter().sum::<usize>() as f64 / exact_judge_tokens.len() as f64
            };
            let dm = if dense_judge_tokens.is_empty() {
                0.0
            } else {
                dense_judge_tokens.iter().sum::<usize>() as f64 / dense_judge_tokens.len() as f64
            };
            let ratio = if em > 0.0 && dm > 0.0 {
                format!("   ratio: {:.3}", dm / em)
            } else {
                String::new()
            };
            println!(
                "  judge tokens read — exact(full): {em:.0}   dense(distilled): {dm:.0}{ratio}"
            );
        }
        // Retrieval ceiling for the judged metric. Reading this next to the
        // accuracy separates "moot did not retrieve it" from "the judge could
        // not read it". Upper bound only — short gold answers over-report.
        if !gold_reach.is_empty() {
            let hits = gold_reach.iter().filter(|&&g| g).count();
            println!(
                "  gold reachable (exact): {:.4}  ({}/{})",
                hits as f64 / gold_reach.len() as f64,
                hits,
                gold_reach.len(),
            );
        }
        if let Some(e) = acc.exact {
            println!(
                "  answer accuracy (exact): {:.4}  ({}/{} judged)",
                e.accuracy, e.correct, e.judged
            );
        }
        if let Some(d) = acc.dense {
            println!(
                "  answer accuracy (dense): {:.4}  ({}/{} judged)",
                d.accuracy, d.correct, d.judged
            );
        }
    }

    Ok(())
}

fn run_locomo(args: &[String]) -> Result<(), String> {
    // Darkening gates ND-LOCO-1/2: reranker call sites (ruling 2026-08-18).
    reject_darkened_legacy_options(
        "locomo",
        &["--rerank-cmd"],
        &["MOOT_BENCH_RERANK_CMD"],
        args,
        "the locomo-spec lane (official QA protocol)",
    )?;
    // --corpus is the Rust-native flag; --data-file is the Swift twin spelling.
    // Accept both: --data-file takes priority when both are present.
    let corpus_path = option_value("--data-file", args)
        .or_else(|| option_value("--corpus", args))
        .map(str::to_string)
        .ok_or_else(|| "missing required option --corpus (or --data-file)".to_string())?;
    // --binary is the Rust-native flag; --mootx01-binary is the Swift twin spelling.
    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY".to_string()
        })?;
    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_260_725_u64);
    let limit = parse_limit_option(args)?;
    let offset: usize = option_value("--offset", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let label = option_value("--label", args).map(str::to_string);
    let out_dir = option_value("--out", args).map(PathBuf::from);
    if let Some(ref d) = out_dir {
        std::fs::create_dir_all(d)
            .map_err(|e| format!("could not create output directory '{}': {}", d.display(), e))?;
    }
    // --encode-barrier drain|impatient|none (default: drain).
    let encode_barrier = match option_value("--encode-barrier", args) {
        Some(s) => EncodeBarrier::from_str(s).map_err(|e| e)?,
        None => EncodeBarrier::default(),
    };
    // --estate-cache off|reuse (default: off). Controls estate snapshot reuse.
    let estate_cache = match option_value("--estate-cache", args) {
        Some(s) => EstateCacheMode::from_str(s).map_err(|e| e)?,
        None => EstateCacheMode::default(),
    };
    // --cache-dir <path>: override cache root (default: <out>/estate-cache).
    let cache_dir_locomo = option_value("--cache-dir", args).map(PathBuf::from);
    // --estate-mode: see the longmemeval parser — same semantics.
    let scratch_posture = parse_estate_mode(args)?;
    // 2026-08-18 doctrine: encryption is a timing-lane-only concern.
    if scratch_posture == ScratchEstatePosture::EncryptedEphemeral {
        return Err("encryption is tested only by the timing lane".to_string());
    }

    // --shape disk|ram (default: disk). Controls whether each conversation's
    // scratch estate uses a SQLite-on-disk backend ("disk") or an ephemeral
    // in-memory backend ("ram", passes --in-memory to serve).
    let locomo_shape = match option_value("--shape", args) {
        None | Some("disk") => EstateShape::Disk,
        Some("ram") => EstateShape::Ram,
        Some(unknown) => {
            return Err(format!("--shape must be 'disk' or 'ram'; got '{unknown}'"));
        }
    };
    // RAM shape is ephemeral — no disk writes, no keychain contact, no cache.
    // Reject --estate-cache reuse|require when --shape ram is active.
    if locomo_shape == EstateShape::Ram && estate_cache != EstateCacheMode::Off {
        return Err(format!(
            "--shape ram is incompatible with --estate-cache {}: \
             an in-memory estate is not written to disk and cannot be snapshotted. \
             Use --estate-cache off (the default) with --shape ram.",
            estate_cache.as_str()
        ));
    }
    // --parallel N (default: 80 % of logical cores, minimum 1). Each conversation
    // runs as an independent thread; results are reassembled in conversation-index
    // order for byte-deterministic output.
    let locomo_default_parallel = {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1);
        (cores * 4 / 5).max(1)
    };
    let locomo_parallel: usize = match option_value("--parallel", args) {
        None => locomo_default_parallel,
        Some(s) => {
            let n: usize = s.parse().map_err(|_| {
                format!("--parallel must be a positive integer; got '{s}'")
            })?;
            if n == 0 {
                return Err(format!("--parallel must be a positive integer; got '{s}'"));
            }
            n
        }
    };

    eprintln!("[locomo] loading corpus from {corpus_path}");
    // B2 provenance: digest the corpus fixture once at load time.
    let locomo_corpus_digest =
        mcp_benchmarker_rs::run_environment::file_sha256_hex(&corpus_path)
            .unwrap_or_else(|| "unknown".to_string());
    let corpus = load_locomo_corpus(Path::new(&corpus_path))
        .map_err(|e| format!("corpus load failed: {e}"))?;
    eprintln!(
        "[locomo] corpus: {} conversations, {} questions ({} adversarial excluded)",
        corpus.conversations.len(),
        corpus.questions.len(),
        corpus.adversarial_count,
    );
    eprintln!("[locomo] binary: {binary}  seed: {seed}");
    if let Some(n) = limit {
        eprintln!("[locomo] limit: {n}");
    }
    if offset > 0 {
        eprintln!("[locomo] offset: {offset}");
    }
    eprintln!("[locomo] encode-barrier: {}", encode_barrier.as_str());
    eprintln!("[locomo] shape: {}", locomo_shape.as_str());
    eprintln!("[locomo] parallel: {locomo_parallel}");
    // --strategy search|shaped|precise (default: search). PR-08 D1.
    // `search` produces no run-label suffix — preserving byte-stable label
    // behaviour for all prior LoCoMo runs. `shaped`/`precise` append the name.
    let strategy = match option_value("--strategy", args) {
        Some("shaped")  => LoCoMoRecallStrategy::Shaped,
        Some("precise") => LoCoMoRecallStrategy::Precise,
        None | Some("search") => LoCoMoRecallStrategy::Search,
        Some(unknown) => {
            return Err(format!("--strategy must be 'search', 'shaped', or 'precise'; got '{unknown}'"));
        }
    };
    // --recall-shape <preset>: named preset for shaped strategy. Ignored for others.
    // Validated against the canonical preset roster so an invalid name fails fast
    // here rather than at the GLK layer, matching Swift's lmeRecallShapePresets
    // check in CLI.swift. Both twins MUST reject the same invalid names.
    let recall_shape: Option<String> = option_value("--recall-shape", args).map(str::to_string);
    if let Some(ref preset) = recall_shape {
        if !LME_RECALL_SHAPE_PRESETS.contains(&preset.as_str()) {
            return Err(format!(
                "--recall-shape must be one of: {}; got '{preset}'",
                LME_RECALL_SHAPE_PRESETS.join(", ")
            ));
        }
    }
    eprintln!("[locomo] strategy: {}", strategy.as_str());
    if let Some(ref preset) = recall_shape {
        eprintln!("[locomo] recall-shape: {preset}");
    }
    // Rerank mode (W2-rerank): optional rerank command applied after retrieval.
    // Presence only in the report — same secrecy rule as LME's rerank_cmd.
    // SECURE PATH: set MOOT_BENCH_RERANK_CMD in the environment.
    let locomo_rerank_cmd: Option<String> = std::env::var("MOOT_BENCH_RERANK_CMD")
        .ok()
        .or_else(|| option_value("--rerank-cmd", args).map(str::to_string));
    // Seed-path (--seed-path batch|live, default batch). Governing ruling 8D5B8053.
    let locomo_seed_path =
        mcp_benchmarker_rs::seed_export::SeedPathMode::parse(option_value("--seed-path", args))
            .map_err(|e| e)?;

    // 2026-08-18 doctrine: accuracy lane emits binary identity only, not full machine profile.
    let mut locomo_run_env = IdentityEnvironment::collect(Some(binary.as_str()));
    // Instrument seams (environment-only; see retrieval_call_spec.rs):
    // MOOT_BENCH_RETRIEVAL_TOOL/_ARGS override the query call;
    // MOOT_BENCH_UNIT_IDS pins the unit set.
    let retrieval_call = mcp_benchmarker_rs::retrieval_call_spec::retrieval_call_spec_from_environment()?;
    let unit_ids = mcp_benchmarker_rs::retrieval_call_spec::unit_ids_from_environment()?;
    // --payload-arm v0..v5 (PAYLOAD-ARMS; MOOT_BENCH_PAYLOAD_ARM as the
    // environment spelling): payload-economics shape variant applied to
    // seam-routed retrieval text_blocks. Recorded in run_environment.
    let payload_arm = mcp_benchmarker_rs::payload_arm::parse_payload_arm(
        option_value("--payload-arm", args)
            .map(str::to_string)
            .or_else(|| std::env::var("MOOT_BENCH_PAYLOAD_ARM").ok())
            .as_deref())?;
    if let Some(ids) = &unit_ids {
        mcp_benchmarker_rs::unit_id_filter::validate_unit_ids(
            ids, corpus.questions.iter().map(|q| q.question_id.as_str()), "locomo")?;
    }
    // Fail-loud (mislabeled-cell rule): only the Search strategy routes
    // through the retrieval seam in this lane.
    if payload_arm.is_some() && strategy != mcp_benchmarker_rs::locomo_runner::LoCoMoRecallStrategy::Search {
        return Err(format!("--payload-arm requires --strategy search in the locomo lane; got '{strategy:?}'"));
    }
    locomo_run_env.payload_arm = payload_arm.map(|a| a.as_str().to_string());
    let run_config = LoCoMoRunConfig {
        moot_binary: binary,
        unit_ids: unit_ids.clone(),
        retrieval_call: retrieval_call.clone(),
        payload_arm,
        seed,
        limit,
        offset,
        label: label.clone(),
        out_dir: out_dir.clone(),
        encode_barrier,
        estate_cache,
        cache_dir: cache_dir_locomo,
        scratch_posture,
        strategy,
        recall_shape: recall_shape.clone(),
        rerank_cmd: locomo_rerank_cmd.clone(),
        seed_path: locomo_seed_path,
        // Guard probe sampling (--guard-sample once|per-unit, default once):
        // the guard validates the binary, not the unit — probe once per leg.
        guard_sampling_policy: mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
            option_value("--guard-sample", args))?,
            corpus_digest: locomo_corpus_digest.clone(),
        shape: locomo_shape,
        parallel_units: locomo_parallel,
    };

    let (results, locomo_rerank_failures, locomo_timing_report) = run_locomo_questions(&corpus, &run_config)?;
    // Conversations MEASURED, taken before `results` is consumed at the scores
    // map below. The Rust result carries no conversation index; its question_id
    // is "<conv>_q<N>" (e.g. "conv-26_q3"), so the conversation is the prefix.
    // Same count as the Swift leg's distinct conversationIndex set.
    let measured_conversations = results
        .iter()
        .map(|r| r.question_id.split('_').next().unwrap_or("").to_string())
        .collect::<std::collections::BTreeSet<_>>()
        .len();
    // Extract cache_hit_by_id (keyed by question_id) before consuming results.
    let cache_hit_by_id_locomo: std::collections::HashMap<String, Option<bool>> = results
        .iter()
        .map(|r| (r.question_id.clone(), r.cache_hit))
        .collect();
    let drain_lane_by_id_locomo: std::collections::HashMap<String, Option<bool>> = results
        .iter()
        .map(|r| (r.question_id.clone(), r.drain_lane_observed))
        .collect();
    // C10: this port has no consolidated (Shape 3) mode — the
    // wing-per-instance artifact estates carry that topology — so the
    // report's consolidated fields are always absent.
    let locomo_consolidated_total_turns: Option<usize> = None;
    let scores: Vec<_> = results.into_iter().map(score_locomo_question).collect();

    let run_id = {
        let mut rng = mcp_benchmarker_rs::longmemeval_runner::SplitMix64::new(seed ^ 0xDEADBEEF_CAFEBABE);
        format!("{:016x}", rng.next_u64())
    };
    // Build run label with strategy suffix (PR-08 D1). `.search` has no suffix —
    // byte-stable with all prior LoCoMo run labels. `.shaped`/`.precise` append
    // the strategy name (and the preset when set) to distinguish cells.
    // `-rerank` is appended last when rerank is active (W2-rerank).
    let run_label = {
        let mut lbl = label.unwrap_or_else(|| {
            let mut l = format!("locomo-seed{seed}");
            if strategy != LoCoMoRecallStrategy::Search {
                l.push('-');
                l.push_str(strategy.as_str());
                if let Some(ref preset) = recall_shape {
                    l.push('-');
                    l.push_str(preset);
                }
            }
            l
        });
        if locomo_rerank_cmd.is_some() {
            lbl.push_str("-rerank");
        }
        lbl
    };
    let generated_at = now_iso8601();

    // Stamp testname-arm-serial before consuming locomo_run_env (D1 discipline).
    // Arm mirrors crate_record_filename: measured conversation count.
    let locomo_serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(&args);
    locomo_run_env.benchmark_test_name  = Some("locomo".to_string());
    locomo_run_env.benchmark_arm        = Some(format!("all{}", measured_conversations));
    locomo_run_env.benchmark_run_serial = Some(locomo_serial);

    let report = build_locomo_report(
        run_id,
        run_label,
        generated_at,
        encode_barrier.as_str().to_string(),
        run_config.guard_sampling_policy.as_str().to_string(),
        corpus.questions.len() + corpus.adversarial_count,
        corpus.adversarial_count,
        &scores,
        &cache_hit_by_id_locomo,
        &drain_lane_by_id_locomo,
        estate_cache.as_str().to_string(),
        scratch_posture.as_str().to_string(),
        // Every artifact this lane restores is turn-granularity, and the
        // report records that.
        "turn".to_string(),
        strategy.as_str().to_string(),
        recall_shape.clone(),
        locomo_rerank_cmd.is_some(),
        locomo_rerank_cmd.as_ref().map(|_| locomo_rerank_failures),
        Some(locomo_run_env),
        run_config.shape.as_str().to_string(),
        run_config.parallel_units,
        locomo_consolidated_total_turns,  // C10: None for per-conversation runs
        locomo_timing_report,
    );

    // Print summary.
    println!("LoCoMo results (seed={seed}):");
    println!("  questions_run:      {}", report.corpus_stats.questions_run);
    println!("  guard_excluded:     {}", report.corpus_stats.guard_excluded);
    println!("  query_count:        {}", report.aggregate.query_count);
    println!("  recall_any@5:       {:.4}", report.aggregate.recall_any_at_5);
    println!("  recall_all@5:       {:.4}", report.aggregate.recall_all_at_5);
    println!("  recall_any@10:      {:.4}", report.aggregate.recall_any_at_10);
    println!("  mrr:                {:.4}", report.aggregate.mrr);
    println!("  query_p50_s:        {:.4}", report.latency.query_p50_seconds);
    println!("  query_p95_s:        {:.4}", report.latency.query_p95_seconds);
    println!("  category_breakdown:");
    for cat in &report.category_breakdown {
        println!(
            "    {:12}  n={:4}  any@5={:.4}  all@5={:.4}  mrr={:.4}",
            cat.label, cat.query_count,
            cat.recall_any_at_5, cat.recall_all_at_5, cat.mrr
        );
    }

    // Write report file.
    // `<test>-<arm>-<serial>`: LoCoMo's arm is how many conversations were
    // MEASURED, not how many were loaded. `--limit` bounds questions, so a
    // one-question smoke run touches one conversation while the loaded corpus
    // still holds ten — naming the arm from the corpus would let a bounded run
    // wear a full run's filename.
    let report_filename =
        crate_record_filename("locomo", &format!("all{}", measured_conversations), &args);
    let report_path = out_dir
        .as_deref()
        .unwrap_or_else(|| Path::new("."))
        .join(&report_filename);
    write_locomo_report(&report, &report_path)?;
    println!("report written to {}", report_path.display());

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// run_locomo_spec — official LoCoMo QA scoring protocol (§1–§6)
// ─────────────────────────────────────────────────────────────────────────────
//
// Twin of Swift `runLoCoMoSpec`. Uses the same locomo10.json corpus fixture as
// the `locomo` lane but evaluates answer quality (F1/exact-match/abstention)
// rather than recall@k/MRR. Answers are produced via moot_synthesize.
// Record naming: locomo-spec-<arm>-<serial>.json.

// ─────────────────────────────────────────────────────────────────────────────
// run_artifact_recall — read-only recall vs a pre-built artifact estate
// ─────────────────────────────────────────────────────────────────────────────

/// The `artifact-recall` subcommand: parses flags and runs the lane
/// (artifact_recall.rs). Twin of Swift `runArtifactRecall(_:)`.
fn run_artifact_recall(args: &[String]) -> Result<(), String> {
    let dataset = option_value("--dataset", args)
        .and_then(ArtifactDataset::parse)
        .ok_or_else(|| {
            "artifact-recall requires --dataset locomo|convomem|membench|lme-s".to_string()
        })?;
    let target_scale = match option_value("--target-scale", args) {
        None => ArtifactTargetScale::BenchAggregate,
        Some(s) => ArtifactTargetScale::parse(s).ok_or_else(|| {
            format!("--target-scale must be unit|bench-aggregate|complete-aggregate; got '{s}'")
        })?,
    };
    let estate_dir = option_value("--estate-dir", args).map(PathBuf::from);
    let catalog_path = option_value("--catalog", args).map(PathBuf::from);
    match target_scale {
        ArtifactTargetScale::Unit if catalog_path.is_none() => {
            return Err("--target-scale unit requires --catalog <path to catalog.json>".to_string());
        }
        ArtifactTargetScale::BenchAggregate | ArtifactTargetScale::CompleteAggregate
            if estate_dir.is_none() =>
        {
            return Err(format!(
                "--target-scale {} requires --estate-dir <path>",
                target_scale.as_str()
            ));
        }
        _ => {}
    }
    // Complete-aggregate expected ids carry the dataset prefix minted by
    // build_complete.py ("<dataset>/"); overridable for future layouts.
    let id_prefix = option_value("--id-prefix", args)
        .map(str::to_string)
        .unwrap_or_else(|| {
            if target_scale == ArtifactTargetScale::CompleteAggregate {
                format!("{}/", dataset.as_str())
            } else {
                String::new()
            }
        });
    let questions_path = option_value("--questions", args)
        .map(PathBuf::from)
        .ok_or_else(|| "artifact-recall requires --questions <jsonl path>".to_string())?;
    let scope = match option_value("--scope", args).unwrap_or("wing") {
        "wing" => ArtifactRecallScope::Wing,
        "estate" => ArtifactRecallScope::Estate,
        other => return Err(format!("--scope must be 'wing' or 'estate'; got '{other}'")),
    };
    let limit: usize = parse_limit_option(args)?.unwrap_or(0);
    let top_k_raw: i64 = match option_value("--top-k", args) {
        Some(s) => s.parse().map_err(|_| format!("--top-k must be a positive integer; got '{s}'"))?,
        None => 10,
    };
    if top_k_raw <= 0 {
        return Err(format!("--top-k must be positive; got {top_k_raw}"));
    }
    let top_k = top_k_raw as usize;
    let out_path = option_value("--out", args)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("artifact-recall-report.json"));

    // --binary is the Rust-native flag; --mootx01-binary is the Swift twin
    // spelling. Same resolution order as every other lane.
    let moot_binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY".to_string()
        })?;

    run_artifact_recall_lane(&ArtifactRecallConfig {
        dataset,
        target_scale,
        estate_dir,
        catalog_path,
        questions_path,
        scope,
        id_prefix,
        limit,
        top_k,
        out_path,
        moot_binary,
    })
    .map_err(|e| e.description)
}

/// The `payload-economics` subcommand: parses flags and runs the lane.
/// `--synthesize-arm` selects the synthesis-payload lane (same runner,
/// digest arm added, lane name switched — run book §9 twin keys). Twin of
/// Swift `runPayloadEconomics(_:)`.
fn run_payload_economics(args: &[String]) -> Result<(), String> {
    let estate_dir = option_value("--estate-dir", args)
        .map(PathBuf::from)
        .ok_or_else(|| {
            "payload-economics requires --estate-dir <the selected port's Form-2 lme-s \
             artifact> (run book §9; the lane takes no scale)"
                .to_string()
        })?;
    let questions_path = option_value("--questions", args)
        .map(PathBuf::from)
        .ok_or_else(|| {
            "payload-economics requires --questions <seeding questions.jsonl>".to_string()
        })?;
    let data_dir = option_value("--data-dir", args).map(PathBuf::from).ok_or_else(|| {
        "payload-economics requires --data-dir <official LongMemEval data dir>".to_string()
    })?;
    let variant = option_value("--variant", args).unwrap_or("s").to_string();
    let synthesize_arm = flag_present("--synthesize-arm", args);
    let synthesize_limit: Option<usize> = if option_value("--synthesize-limit", args).is_some() {
        Some(validated_count("--synthesize-limit", args, 20, 1)?)
    } else {
        None
    };
    if synthesize_limit.is_some() && !synthesize_arm {
        return Err(
            "--synthesize-limit requires --synthesize-arm (the digest arm is what the cap \
             bounds)"
                .to_string(),
        );
    }
    // --payload-arm v0..v5 (PAYLOAD-ARMS; MOOT_BENCH_PAYLOAD_ARM as the
    // environment spelling): payload-economics shape variant applied to all
    // three arms' text_blocks before token/evidence measurement.
    let payload_arm = mcp_benchmarker_rs::payload_arm::parse_payload_arm(
        option_value("--payload-arm", args)
            .map(str::to_string)
            .or_else(|| std::env::var("MOOT_BENCH_PAYLOAD_ARM").ok())
            .as_deref(),
    )?;
    let limit: usize = parse_limit_option(args)?.unwrap_or(0);
    // Parse as i64 first so "-3" is rejected loudly instead of falling back
    // to the default (Swift-guard parity).
    let top_k_raw: i64 = match option_value("--top-k", args) {
        Some(s) => {
            s.parse().map_err(|_| format!("--top-k must be a positive integer; got '{s}'"))?
        }
        None => 10,
    };
    if top_k_raw <= 0 {
        return Err(format!("--top-k must be positive; got {top_k_raw}"));
    }
    let top_k = top_k_raw as usize;
    let out_path = option_value("--out", args)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("payload-economics-report.json"));

    // --binary is the Rust-native flag; --mootx01-binary is the Swift twin
    // spelling. Same resolution order as every other lane.
    let moot_binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY"
                .to_string()
        })?;

    run_payload_economics_lane(&PayloadLaneConfig {
        estate_dir,
        questions_path,
        data_dir,
        variant,
        synthesize_arm,
        synthesize_limit,
        payload_arm,
        limit,
        top_k,
        out_path,
        moot_binary,
    })
    .map_err(|e| e.description)
}

fn run_locomo_spec(args: &[String]) -> Result<(), String> {
    // --corpus is the Rust-native flag; --data-file is the Swift twin spelling.
    // Accept both: --data-file takes priority when both are present.
    let corpus_path = option_value("--data-file", args)
        .or_else(|| option_value("--corpus", args))
        .map(str::to_string)
        .ok_or_else(|| "missing required option --corpus (or --data-file)".to_string())?;

    if !std::path::Path::new(&corpus_path).exists() {
        return Err(format!(
            "LoCoMo-spec dataset file not found at '{}'. \
             Run scripts/fetch-locomo.sh to download the dataset.",
            corpus_path
        ));
    }

    // --binary is the Rust-native flag; --mootx01-binary is the Swift twin spelling.
    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY".to_string()
        })?;

    // Seed default 20260818 — distinct from the locomo lane's 20260725 so the two
    // lanes produce different shuffle orders and record filenames never collide.
    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_260_818_u64);
    let limit = parse_limit_option(args)?;
    let offset: usize = option_value("--offset", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let out_dir = option_value("--out", args).map(PathBuf::from);
    if let Some(ref d) = out_dir {
        std::fs::create_dir_all(d)
            .map_err(|e| format!("could not create output directory '{}': {}", d.display(), e))?;
    }
    let dump_answer_inputs_path = option_value("--dump-answer-inputs", args)
        .map(PathBuf::from);
    let answer_hydration_depth: usize = option_value("--answer-hydration-depth", args)
        .unwrap_or("10")
        .parse()
        .map_err(|_| "--answer-hydration-depth must be a positive integer".to_string())?;
    if answer_hydration_depth == 0 {
        return Err("--answer-hydration-depth must be a positive integer".to_string());
    }
    let answer_hydration_tier = match option_value("--hydration-tier", args)
        .unwrap_or("distilled")
    {
        "distilled" => mcp_benchmarker_rs::journey_driver::HydrationDepth::Distilled,
        "full" => mcp_benchmarker_rs::journey_driver::HydrationDepth::Full,
        other => return Err(format!(
            "--hydration-tier must be 'distilled' or 'full'; got '{other}'"
        )),
    };

    // ── Artifact estate seam (run book §8) ──────────────────────────────────────
    // The spec runner opens pre-built artifacts; it builds nothing. unit (the
    // default — the official per-instance protocol shape) requires --catalog;
    // bench-aggregate requires --estate-dir. completeAggregate is REFUSED.
    let scale_str = option_value("--target-scale", args).unwrap_or("unit");
    let target_scale: ArtifactTargetScale = ArtifactTargetScale::parse(scale_str)
        .ok_or_else(|| format!(
            "--target-scale must be 'unit' or 'bench-aggregate' for locomo-spec; got '{scale_str}'"
        ))?;
    if target_scale == ArtifactTargetScale::CompleteAggregate {
        return Err(
            "--target-scale complete-aggregate is not supported for locomo-spec; \
             use 'unit' (default) or 'bench-aggregate'"
                .to_string(),
        );
    }
    let catalog_path = option_value("--catalog", args).map(PathBuf::from);
    let estate_dir = option_value("--estate-dir", args).map(PathBuf::from);
    match target_scale {
        ArtifactTargetScale::Unit => {
            if catalog_path.is_none() {
                return Err(
                    "locomo-spec --target-scale unit requires --catalog <catalog.json>"
                        .to_string(),
                );
            }
        }
        ArtifactTargetScale::BenchAggregate => {
            if estate_dir.is_none() {
                return Err(
                    "locomo-spec --target-scale bench-aggregate requires --estate-dir <path>"
                        .to_string(),
                );
            }
        }
        ArtifactTargetScale::CompleteAggregate => unreachable!(),
    }

    // --parallel N (default: ~80% of logical cores). Bounded conversation concurrency.
    // bench-aggregate is forced to 1 (one serve holds the estate at a time).
    let spec_default_parallel = {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1);
        (cores * 4 / 5).max(1)
    };
    let spec_parallel: usize = if target_scale == ArtifactTargetScale::BenchAggregate {
        1 // one serve holds the estate at a time
    } else {
        match option_value("--parallel", args) {
            None => spec_default_parallel,
            Some(s) => {
                let n: usize = s.parse().map_err(|_| {
                    format!("--parallel must be a positive integer; got '{s}'")
                })?;
                if n == 0 {
                    return Err(format!("--parallel must be a positive integer; got '{s}'"));
                }
                n
            }
        }
    };

    // --guard-sample once|per-unit (default: once). The guard validates the binary.
    let guard_sampling_policy =
        mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
            option_value("--guard-sample", args))?;

    eprintln!("[locomo-spec] loading corpus from {corpus_path}");
    // B2 provenance: digest the corpus fixture once at load time and embed in the
    // report so a report/fixture pairing can be verified without re-running.
    let corpus_digest =
        mcp_benchmarker_rs::run_environment::file_sha256_hex(&corpus_path)
            .unwrap_or_else(|| "unknown".to_string());
    // Load via the spec corpus loader (produces typed QA pairs, five categories).
    // Same locomo10.json fixture as the locomo lane.
    let corpus = load_locomo_spec_corpus(std::path::Path::new(&corpus_path))
        .map_err(|e| format!("corpus load failed: {e:?}"))?;
    eprintln!(
        "[locomo-spec] loaded {} conversations, {} questions",
        corpus.conversations.len(),
        corpus.questions.len()
    );
    eprintln!("[locomo-spec] binary: {binary}  seed: {seed}");
    if let Some(n) = limit { eprintln!("[locomo-spec] limit: {n}"); }
    if offset > 0           { eprintln!("[locomo-spec] offset: {offset}"); }
    eprintln!("[locomo-spec] target-scale: {scale_str}");
    eprintln!("[locomo-spec] parallel: {spec_parallel}");

    // Run label: "locomo-spec-seed<N>" — embeds the seed so different seeds produce
    // distinguishable arms and filenames without an explicit --label flag. Consistent
    // with the locomo lane's "locomo-seed<N>" shape.
    let run_label = format!("locomo-spec-seed{seed}");

    let config = LoCoMoSpecRunConfig {
        moot_binary: binary.clone(),
        dataset_path: PathBuf::from(&corpus_path),
        limit,
        offset,
        seed,
        out_dir: out_dir.clone(),
        run_label: run_label.clone(),
        target_scale,
        catalog_path,
        estate_dir,
        parallel_units: spec_parallel,
        guard_sampling_policy,
        corpus_digest: corpus_digest.clone(),
        dump_answer_inputs_path: dump_answer_inputs_path.clone(),
        answer_hydration_depth,
        answer_hydration_tier,
        // --scoring raw|rrf|matrixAware|discriminative: when given, passed as the
        // "scoring" key in every moot_memory_search call. When omitted, the call is
        // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
        scoring_strategy: option_value("--scoring", args).map(|s| s.to_string()),
        // --recall-shape <preset>: switches per-question recall call to moot_recall_shaped.
        // Mutually exclusive with --scoring (CLI rejects both together).
        recall_shape: option_value("--recall-shape", args).map(|s| s.to_string()),
        // --request-limit N: per-question verb call limit (default 20, always sent explicitly).
        request_limit: option_value("--request-limit", args)
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(20),
        // --short-query-terms N: content-term threshold for the short-query gate (default 4).
        short_query_terms: option_value("--short-query-terms", args)
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(4),
    };

    let result = run_locomo_spec_questions(&corpus, &config)?;

    // §5 aggregate is already in result.aggregate (computed by the runner).
    // Recompute score triples for the summary (the runner already did this,
    // but the struct doesn't expose them independently — the aggregate is the
    // authoritative value).
    let conversations_used = {
        // Count distinct conversation indices from question records.
        let mut seen = std::collections::BTreeSet::new();
        for r in &result.question_records {
            // question_id is "<conv_sample_id>_q<idx>"; prefix before first '_q' is the key.
            if let Some(prefix) = r.question_id.split("_q").next() {
                seen.insert(prefix.to_string());
            }
        }
        seen.len()
    };

    // Arm: "all<N>" where N is conversations used — consistent with the locomo
    // lane's naming convention (locomo uses all10 for the full dataset).
    let arm = format!("all{conversations_used}");
    let serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(args);
    let report_filename = mcp_benchmarker_rs::record_writer::record_filename(
        "locomo-spec", &arm, &serial, "", "json");

    // Build the JSON report. No pre-built Serialize impl on the result types;
    // construct it with serde_json macros mirroring the Swift loCoMoSpecReportJSON
    // structure (locomo-spec-<arm>-<serial> stem, §5 category order [4,1,2,3,5]).
    let category_labels: std::collections::HashMap<u8, &str> = [
        (1u8, "single_hop"), (2, "temporal"), (3, "multi_hop"),
        (4, "open_domain"), (5, "adversarial"),
    ].iter().cloned().collect();

    let by_category: Vec<serde_json::Value> = result.aggregate.by_category.iter().map(|cm| {
        serde_json::json!({
            "category":             cm.category,
            "category_label":       category_labels.get(&cm.category).copied().unwrap_or("unknown"),
            "accuracy":             cm.accuracy,
            "mean_evidence_recall": cm.mean_recall,
            "question_count":       cm.question_count,
        })
    }).collect();

    let corpus_category_counts: serde_json::Value = {
        let mut m = serde_json::Map::new();
        for (k, v) in &corpus.category_counts {
            m.insert(k.to_string(), serde_json::Value::Number((*v).into()));
        }
        serde_json::Value::Object(m)
    };

    let per_question: Vec<serde_json::Value> = result.question_records.iter().map(|r| {
        serde_json::json!({
            "question_id":          r.question_id,
            "category":             r.category,
            "category_label":       r.category_label,
            "gold_answer":          r.gold_answer,
            "prediction":           r.prediction,
            "retrieved_dia_ids":    r.retrieved_dia_ids,
            "score":                r.score,
            "evidence_recall":      r.evidence_recall_value,
            "guard_healthy":        r.guard_healthy,
            "guard_diagnostic":     r.guard_diagnostic,
            "turns_ingested":       r.turns_ingested,
            "cache_hit":            r.cache_hit,
            // Expand-verify scoreboard parity fields (§7.5).
            "content_term_count":   r.content_term_count,
            "gold_ranks":           r.gold_ranks,
        })
    }).collect();

    // Short-query subset metrics (§7.5): mirrors Swift's computation exactly.
    // A question is "short" when guard_healthy is true and content_term_count
    // is strictly less than short_query_terms.
    let short_query_terms = result.metadata.short_query_terms;
    let included: Vec<_> = result.question_records.iter()
        .filter(|r| r.guard_healthy)
        .collect();
    let short: Vec<_> = included.iter()
        .filter(|r| r.content_term_count < short_query_terms)
        .collect();
    let short_query_count = short.len();
    let short_query_mean_score: f64 = if short_query_count > 0 {
        short.iter().map(|r| r.score).sum::<f64>() / short_query_count as f64
    } else { 0.0 };
    let short_query_mean_evidence_recall: f64 = if short_query_count > 0 {
        short.iter().map(|r| r.evidence_recall_value).sum::<f64>() / short_query_count as f64
    } else { 0.0 };
    let short_query_pool_guarantee: f64 = if short_query_count > 0 {
        short.iter().filter(|r| !r.gold_ranks.is_empty()).count() as f64
            / short_query_count as f64
    } else { 0.0 };

    let record_name_stem = mcp_benchmarker_rs::record_writer::record_filename(
        "locomo-spec", &arm, &serial, "", "json");
    // §6 required report fields (F1): binary identity only (2026-08-18 doctrine).
    // testname-arm-serial stamped so the record self-identifies (D1 discipline).
    // Pre-computed before json!() — serde_json::json! does not accept block expressions.
    let locomo_spec_run_env: serde_json::Value = {
        let mut env = IdentityEnvironment::collect(Some(&binary));
        env.benchmark_test_name  = Some("locomo-spec".to_string());
        env.benchmark_arm        = Some(arm.clone());
        env.benchmark_run_serial = Some(serial.clone());
        serde_json::to_value(env).unwrap_or(serde_json::Value::Null)
    };
    let report = serde_json::json!({
        "record_name_stem":                 record_name_stem,
        "lane":                             "locomo-spec",
        "overall_accuracy":                 result.aggregate.overall,
        "overall_mean_evidence_recall":     result.aggregate.overall_mean_recall,
        "total_questions":                  result.metadata.total_questions,
        "category_order":                   [4, 1, 2, 3, 5],
        "by_category":                      by_category,
        "corpus_category_counts":           corpus_category_counts,
        // Short-query subset metrics for the scoreboard (§7.5).
        "short_query_count":                short_query_count,
        "short_query_mean_score":           short_query_mean_score,
        "short_query_mean_evidence_recall": short_query_mean_evidence_recall,
        "short_query_pool_guarantee":       short_query_pool_guarantee,
        "run_environment":                  locomo_spec_run_env,
        "run_parameters": mcp_benchmarker_rs::locomo_spec_runner::locomo_spec_run_parameters(
            &result.metadata, &arm, &serial),
        "per_question_records": per_question,
    });

    // Sort keys to match Swift's .sortedKeys output formatting.
    let sorted = mcp_benchmarker_rs::longmemeval_scorer::sorted_json_value(&report);
    let json_bytes = serde_json::to_vec_pretty(&sorted)
        .map_err(|e| format!("report encode failed: {e}"))?;

    let report_path = out_dir
        .as_deref()
        .unwrap_or_else(|| Path::new("."))
        .join(&report_filename);
    mcp_benchmarker_rs::record_writer::write_record_never_overwrite(&json_bytes, &report_path)
        .map_err(|e| format!("report write failed: {e}"))?;

    if let Some(answer_inputs_path) = dump_answer_inputs_path {
        let bytes = mcp_benchmarker_rs::locomo_spec_runner::answer_inputs_jsonl(
            &result,
            answer_hydration_depth,
            answer_hydration_tier,
        )?;
        mcp_benchmarker_rs::record_writer::write_record_never_overwrite(
            &bytes,
            &answer_inputs_path,
        )
        .map_err(|e| format!("answer-input write failed: {e}"))?;
        println!("  answer inputs written to: {}", answer_inputs_path.display());
    }

    // Summary to stdout.
    println!("[locomo-spec] run complete");
    println!("  questions processed:         {}", result.metadata.total_questions);
    println!("  conversations used:          {} of {}", conversations_used, corpus.conversations.len());
    println!("  overall_accuracy:            {:.4}", result.aggregate.overall);
    println!("  overall_mean_evidence_recall: {:.4}", result.aggregate.overall_mean_recall);
    println!();
    for cm in &result.aggregate.by_category {
        let label = category_labels.get(&cm.category).copied().unwrap_or("unknown");
        println!("  {:<14} acc={:.4} recall={:.4} (n={})",
            label, cm.accuracy, cm.mean_recall, cm.question_count);
    }
    println!("  report written to: {}", report_path.display());

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// run_lme_spec_cmd — official LongMemEval judged-QA protocol (§1–§4)
// ─────────────────────────────────────────────────────────────────────────────
//
// Twin of Swift `runLMESpec`. Same dataset directory as the `longmemeval` lane
// but implements LONGMEMEVAL_OFFICIAL_PROTOCOL.md: ALL 500 instances including
// abstention flow through the ask path (§1); hypotheses are written as official
// JSONL; §2 anscheck prompts go to a judge-input dump or an inline judge-cmd;
// verdicts follow the §3 contains-"yes" rule; aggregation per §4. The runner
// (`run_lme_spec`) writes the report + params sidecar itself — this dispatcher
// only parses flags, loads the corpus, and prints the summary.
// Record naming: lme-spec-<variant>-<serial>.json.

fn run_lme_spec_cmd(args: &[String]) -> Result<(), String> {
    // --data-dir names the LongMemEval dataset directory (Swift twin spelling).
    let data_dir = option_value("--data-dir", args)
        .map(str::to_string)
        .ok_or_else(|| "missing required option --data-dir".to_string())?;

    // Variant → dataset filename, byte-identical to the longmemeval lane's map.
    let variant = option_value("--variant", args).unwrap_or("s").to_string();
    let variant_filename = match variant.as_str() {
        "s" => "longmemeval_s_cleaned.json",
        "m" => "longmemeval_m_cleaned.json",
        "oracle" => "longmemeval_oracle.json",
        other => {
            return Err(format!("--variant must be 's', 'm', or 'oracle'; got '{other}'"));
        }
    };
    let dataset_path = std::path::Path::new(&data_dir).join(variant_filename);
    if !dataset_path.exists() {
        return Err(format!(
            "LongMemEval dataset file not found at '{}'. \
             Run scripts/fetch-longmemeval.sh to download the dataset.",
            dataset_path.display()
        ));
    }

    // --binary is the Rust-native flag; --mootx01-binary is the Swift twin spelling.
    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY".to_string()
        })?;

    // Seed default 20260818 — the spec lanes' shared default, distinct from the
    // legacy lanes' 20260725 so record filenames never collide across lanes.
    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_260_818_u64);
    let limit = parse_limit_option(args)?;
    let offset: usize = option_value("--offset", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let out_dir = option_value("--out", args).map(PathBuf::from);
    if let Some(ref d) = out_dir {
        std::fs::create_dir_all(d)
            .map_err(|e| format!("could not create output directory '{}': {}", d.display(), e))?;
    }

    // §1/§3 judge seam. The judge command may carry API keys: it is passed to
    // the config but never printed and never recorded (only boolean presence).
    let dump_judge_inputs_path =
        option_value("--dump-judge-inputs", args).map(str::to_string);
    let judge_cmd = option_value("--judge-cmd", args).map(str::to_string);
    // §4: the official aggregator asserts gpt-4o-2024-08-06; that is the default
    // identity recorded per verdict when the operator does not name the judge.
    let judge_model = option_value("--judge-model", args)
        .unwrap_or("gpt-4o-2024-08-06")
        .to_string();

    // Artifact estate scale: unit (default) or bench-aggregate.
    // completeAggregate is refused for this lane (§8 spec: per-instance scope).
    let target_scale = match option_value("--target-scale", args) {
        None => ArtifactTargetScale::Unit,
        Some(s) => ArtifactTargetScale::parse(s)
            .ok_or_else(|| format!("--target-scale must be 'unit' or 'bench-aggregate'; got '{s}'"))?,
    };
    if target_scale == ArtifactTargetScale::CompleteAggregate {
        return Err("--target-scale complete-aggregate is refused for lme-spec (§8)".to_string());
    }
    // --catalog: path to catalog.json for unit-scale resolution.
    let catalog_path = option_value("--catalog", args).map(PathBuf::from);
    // --estate-dir: the bench-aggregate estate directory.
    let estate_dir = option_value("--estate-dir", args).map(PathBuf::from);

    // Validate: unit scale requires catalog_path; bench-aggregate requires estate_dir.
    match target_scale {
        ArtifactTargetScale::Unit => {
            if catalog_path.is_none() {
                return Err("lme-spec unit scale requires --catalog".to_string());
            }
        }
        ArtifactTargetScale::BenchAggregate => {
            if estate_dir.is_none() {
                return Err("lme-spec bench-aggregate scale requires --estate-dir".to_string());
            }
        }
        ArtifactTargetScale::CompleteAggregate => unreachable!(),
    }

    // --parallel N (default: ~80% of logical cores; bench-aggregate is forced to 1).
    let default_parallel = {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1);
        (cores * 4 / 5).max(1)
    };
    let parallel_units: usize = match option_value("--parallel", args) {
        None => {
            if target_scale == ArtifactTargetScale::BenchAggregate { 1 } else { default_parallel }
        }
        Some(s) => {
            let n: usize = s
                .parse()
                .map_err(|_| format!("--parallel must be a positive integer; got '{s}'"))?;
            if n == 0 {
                return Err(format!("--parallel must be a positive integer; got '{s}'"));
            }
            n
        }
    };

    let guard_sampling_policy =
        mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
            option_value("--guard-sample", args))?;

    eprintln!("[lme-spec] loading corpus from {}", dataset_path.display());
    // B2 provenance: digest the fixture once at load and embed in the report.
    let corpus_digest = mcp_benchmarker_rs::run_environment::file_sha256_hex(
        &dataset_path.to_string_lossy())
        .unwrap_or_else(|| "unknown".to_string());
    let corpus = load_lme_spec_corpus(&dataset_path)
        .map_err(|e| format!("corpus load failed: {e:?}"))?;
    eprintln!(
        "[lme-spec] loaded {} instances ({} abstention) — §1: nothing excluded",
        corpus.questions.len(),
        corpus.questions.iter().filter(|q| q.question_id.contains("_abs")).count()
    );
    eprintln!("[lme-spec] binary: {binary}  seed: {seed}  variant: {variant}");
    if let Some(n) = limit { eprintln!("[lme-spec] limit: {n}"); }
    if offset > 0           { eprintln!("[lme-spec] offset: {offset}"); }
    eprintln!("[lme-spec] target-scale: {}  parallel: {parallel_units}", target_scale.as_str());
    eprintln!("[lme-spec] judge: dump={} inline={}",
        dump_judge_inputs_path.is_some(), judge_cmd.is_some());

    let dump_answer_inputs_path = option_value("--dump-answer-inputs", args).map(str::to_string);
    let answer_hydration_depth: usize = option_value("--answer-hydration-depth", args)
        .and_then(|s| s.parse::<usize>().ok())
        .filter(|&d| d > 0)
        .unwrap_or(10);
    let answer_hydration_tier = match option_value("--hydration-tier", args) {
        Some("full") => mcp_benchmarker_rs::journey_driver::HydrationDepth::Full,
        Some("distilled") | None => mcp_benchmarker_rs::journey_driver::HydrationDepth::Distilled,
        Some(other) => {
            return Err(format!(
                "lme-spec --hydration-tier must be distilled or full; got '{other}'"
            ));
        }
    };

    let run_serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(args);
    let config = LmeSpecRunConfig {
        moot_binary: binary.clone(),
        dataset_path: dataset_path.clone(),
        variant: variant.clone(),
        limit,
        offset,
        seed,
        out_dir,
        run_label: format!("lme-spec-{variant}-seed{seed}"),
        run_serial: run_serial.clone(),
        dump_judge_inputs_path,
        judge_cmd,
        judge_model,
        // Artifact estate seam (run book §8): opens pre-built estates, builds nothing.
        target_scale,
        catalog_path,
        estate_dir,
        parallel_units,
        guard_sampling_policy,
        corpus_digest,
        // §6 required report fields (F1): machine + binary provenance,
        // collected at the CLI layer exactly as every legacy lane does.
        // 2026-08-18 doctrine: accuracy lane emits binary identity only.
        // Stamp testname-arm-serial so the record self-identifies (D1 discipline).
        run_environment: {
            let mut lme_spec_env = IdentityEnvironment::collect(Some(&binary));
            lme_spec_env.benchmark_test_name  = Some("lme-spec".to_string());
            lme_spec_env.benchmark_arm        = Some(variant.clone());
            lme_spec_env.benchmark_run_serial = Some(run_serial.clone());
            Some(lme_spec_env)
        },
        dump_answer_inputs_path,
        answer_hydration_depth,
        answer_hydration_tier,
    };

    // run_lme_spec writes the report + params sidecar itself
    // (lme-spec-<variant>-<serial>.json via record_filename).
    let report = run_lme_spec(&corpus.questions, &config, None)?;

    // Summary to stdout. §4 fields are Some only when judged_count > 0.
    println!("[lme-spec] run complete");
    println!("  instances processed: {}", report.per_type.iter().map(|t| t.count).sum::<usize>());
    println!("  judged_count:        {}", report.judged_count);
    for t in &report.per_type {
        println!("  {:<26} acc={:.4} (n={})", t.question_type, t.accuracy, t.count);
    }
    if let Some(v) = report.task_averaged_accuracy {
        println!("  task_averaged_accuracy: {v:.4}");
    }
    if let Some(v) = report.overall_accuracy {
        println!("  overall_accuracy:       {v:.4}");
    }
    if let Some(v) = report.abstention_accuracy {
        println!("  abstention_accuracy:    {v:.4} (n={})", report.abstention_count);
    }

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// run_membench_spec_cmd — official MemBench protocol (§2–§6)
// ─────────────────────────────────────────────────────────────────────────────
//
// Twin of Swift `runMemBenchSpec`. Same MemData corpus as `membench`, but
// implements MEMBENCH_OFFICIAL_PROTOCOL.md: §2 step-prefixed storage, §3
// answering-model letter choice (BYOAI --answer-cmd or dump/consume; NO
// letter-scan heuristic), §4 get_recall over step ids, §5 wall-clock timers,
// §6 step_cap capacity walk (--capacity). The runner writes the report +
// params sidecar itself. Record naming: membench-spec-<agent>-<serial>.json.

fn run_membench_spec_cmd(args: &[String]) -> Result<(), String> {
    let data_dir_str = option_value("--data-dir", args)
        .map(str::to_string)
        .ok_or_else(|| "missing required option --data-dir".to_string())?;
    let data_dir = PathBuf::from(&data_dir_str);
    if !data_dir.exists() {
        return Err(format!(
            "MemBench data directory not found at '{}'. \
             Run scripts/fetch-membench.sh to download the dataset.",
            data_dir.display()
        ));
    }

    // --agent FirstAgent|ThirdAgent (default FirstAgent, matching the parent lane).
    let agent = option_value("--agent", args).unwrap_or("FirstAgent").to_string();
    if agent != "FirstAgent" && agent != "ThirdAgent" {
        return Err(format!(
            "--agent must be 'FirstAgent' or 'ThirdAgent'; got '{agent}'"
        ));
    }

    // --category <name>[,<name>…]: optional category filter, parent-lane spelling.
    let categories: Option<Vec<String>> = option_value("--category", args)
        .map(|s| s.split(',').map(str::to_string).collect());

    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY".to_string()
        })?;

    // Seed default 20260818 — the spec lanes' shared default.
    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_260_818_u64);
    let limit = parse_limit_option(args)?;
    let offset: usize = option_value("--offset", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let out_dir = option_value("--out", args).map(PathBuf::from);
    if let Some(ref d) = out_dir {
        std::fs::create_dir_all(d)
            .map_err(|e| format!("could not create output directory '{}': {}", d.display(), e))?;
    }

    // Artifact estate flags (Standard mode only — --target-scale selects the
    // artifact path; StepCap always provisions scratch estates).
    let target_scale_raw = option_value("--target-scale", args);
    let target_scale: Option<mcp_benchmarker_rs::artifact_recall::ArtifactTargetScale> =
        match target_scale_raw {
            None => None,
            Some(s) => {
                let ts = mcp_benchmarker_rs::artifact_recall::ArtifactTargetScale::parse(s)
                    .ok_or_else(|| {
                        format!("--target-scale must be 'unit' or 'bench-aggregate'; got '{s}'")
                    })?;
                if ts == mcp_benchmarker_rs::artifact_recall::ArtifactTargetScale::CompleteAggregate {
                    return Err("--target-scale complete-aggregate is refused for membench-spec".to_string());
                }
                Some(ts)
            }
        };
    let catalog_path = option_value("--catalog", args).map(PathBuf::from);
    let estate_dir_artifact = option_value("--estate-dir", args).map(PathBuf::from);

    // Validate artifact flag combinations when target_scale is given.
    if let Some(ref ts) = target_scale {
        match ts {
            mcp_benchmarker_rs::artifact_recall::ArtifactTargetScale::Unit => {
                if catalog_path.is_none() {
                    return Err("--catalog is required when --target-scale=unit".to_string());
                }
            }
            mcp_benchmarker_rs::artifact_recall::ArtifactTargetScale::BenchAggregate => {
                if estate_dir_artifact.is_none() {
                    return Err("--estate-dir is required when --target-scale=bench-aggregate".to_string());
                }
            }
            mcp_benchmarker_rs::artifact_recall::ArtifactTargetScale::CompleteAggregate => {}
        }
    }

    let encode_barrier = match option_value("--encode-barrier", args) {
        Some(s) => EncodeBarrier::from_str(s).map_err(|e| e)?,
        None => EncodeBarrier::default(),
    };
    let scratch_posture = parse_estate_mode(args)?;
    // 2026-08-18 doctrine: encryption is a timing-lane-only concern.
    if scratch_posture == ScratchEstatePosture::EncryptedEphemeral {
        return Err("encryption is tested only by the timing lane".to_string());
    }

    let shape = mcp_benchmarker_rs::membench_runner::BenchShape::parse(
        option_value("--shape", args))?;

    // §3 answering seam (BYOAI). MOOT_BENCH_ANSWER_CMD env preferred over the
    // flag (flag values are visible in `ps` argv); may carry API keys — never
    // printed, never recorded beyond boolean presence.
    let answer_cmd = std::env::var("MOOT_BENCH_ANSWER_CMD")
        .ok()
        .or_else(|| option_value("--answer-cmd", args).map(str::to_string));
    let dump_answer_inputs_path =
        option_value("--dump-answer-inputs", args).map(PathBuf::from);
    let consume_answers_path =
        option_value("--consume-answers", args).map(PathBuf::from);

    // --capacity <default|b1,b2,...> switches to the §6 step_cap walk with the
    // given token-bucket boundaries (default [1000, 5000, 20000] = paper tiers).
    let capacity_arg = option_value("--capacity", args);
    let run_mode = if capacity_arg.is_some() {
        mcp_benchmarker_rs::membench_spec_runner::MemBenchSpecRunMode::StepCap
    } else {
        mcp_benchmarker_rs::membench_spec_runner::MemBenchSpecRunMode::Standard
    };
    let capacity_bucket_boundaries: Vec<i64> = match capacity_arg {
        Some(s) if !s.is_empty() && s != "default" => {
            let parsed: Vec<i64> = s.split(',').filter_map(|b| b.parse().ok()).collect();
            if parsed.is_empty() {
                return Err(format!(
                    "--capacity expects 'default' or comma-separated token boundaries; got '{s}'"
                ));
            }
            parsed
        }
        _ => vec![1000, 5000, 20000],
    };

    let run_serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(args);

    eprintln!("[membench-spec] loading corpus from {} agent={agent}", data_dir.display());
    let category_refs: Option<Vec<&str>> =
        categories.as_ref().map(|v| v.iter().map(String::as_str).collect());
    // limit applies after the seeded shuffle, inside the runner — load everything.
    let corpus = mcp_benchmarker_rs::membench_corpus::load_membench_corpus(
        &data_dir, &agent, category_refs.as_deref(), None)
        .map_err(|e| format!("corpus load failed: {e}"))?;
    eprintln!(
        "[membench-spec] loaded {} items; mode={} answer={}",
        corpus.items.len(),
        match run_mode {
            mcp_benchmarker_rs::membench_spec_runner::MemBenchSpecRunMode::StepCap => "step_cap (§6)",
            _ => "standard (§3–§5)",
        },
        if answer_cmd.is_some() { "inline" }
        else if consume_answers_path.is_some() { "consume" } else { "none" }
    );

    let config = mcp_benchmarker_rs::membench_spec_runner::MemBenchSpecRunConfig {
        moot_binary_path: PathBuf::from(&binary),
        data_dir,
        agent: agent.clone(),
        categories,
        limit,
        offset,
        seed,
        out_dir,
        run_label: format!("membench-spec-{agent}-seed{seed}"),
        run_serial: run_serial.clone(),
        encode_barrier,
        scratch_posture,
        shape,
        answer_cmd,
        dump_answer_inputs_path,
        consume_answers_path,
        run_mode,
        capacity_bucket_boundaries,
        target_scale,
        catalog_path,
        estate_dir: estate_dir_artifact,
        // §6 required report fields (F1): binary identity only (2026-08-18 doctrine:
        // accuracy lane emits only the three identity fields).
        // Stamp testname-arm-serial so the record self-identifies (D1 discipline).
        run_environment: {
            let mut membench_spec_env = IdentityEnvironment::collect(Some(&binary));
            membench_spec_env.benchmark_test_name  = Some("membench-spec".to_string());
            membench_spec_env.benchmark_arm        = Some(agent.clone());
            membench_spec_env.benchmark_run_serial = Some(run_serial.clone());
            Some(membench_spec_env)
        },
        // --scoring raw|rrf|matrixAware|discriminative: when given, passed as the
        // "scoring" key in every moot_memory_search call. When omitted, the call is
        // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
        scoring_strategy: option_value("--scoring", args).map(|s| s.to_string()),
        // Depth matches lme-spec / convomem-spec default (10). membench uses
        // moot_memory_search (not moot_memory_get), so this records the
        // search-result context size; it is informational for downstream tooling.
        answer_hydration_depth: 10,
        // --guard-sample once|per-unit (default once). PerUnit probes on every
        // query; useful for aggregate-estate debugging.
        guard_sampling_policy: mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
            option_value("--guard-sample", args))?,
        // --seed-units-dir <path>: optional directory of per-estate seed-unit JSON
        // files used as the third fallback for id-map derivation on JSON-import-lane
        // estates whose drawers.lineageID encodes FNV-1a-128 of the seed record id.
        seed_units_dir: option_value("--seed-units-dir", args)
            .map(|s| std::path::PathBuf::from(s)),
    };

    // The runner writes the report + params sidecar itself
    // (membench-spec-<agent>-<serial>.json via record_filename).
    let report = mcp_benchmarker_rs::membench_spec_runner::run_membench_spec(
        &corpus.items, &config)
        .map_err(|e| format!("membench-spec run failed: {e:?}"))?;

    println!("[membench-spec] run complete");
    println!("  run label:      {}", report.run_label);
    println!("  answered_count: {}", report.answered_count);
    println!("  run_mode:       {}", report.run_mode);

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// run_lmeb_spec_cmd / run_convomem_spec_cmd — official LMEB + ConvoMem protocols
// ─────────────────────────────────────────────────────────────────────────────
//
// Twins of Swift `runLMEBSpec` / `runConvoMemSpec`. Both share the parent
// `lmeb` lane's corpus (six ConvoMem evidence-type subsets) and estate
// machinery. lmeb-spec = §A1–§A4 retrieval metric grid; convomem-spec =
// §B1–§B4 judged QA. The runners return results; report JSON + record files
// are built HERE at the dispatcher layer (same division as the Swift twin —
// the same division as the Swift twin).

/// Shared flag parsing + corpus load for lmeb-spec and convomem-spec.
fn parse_lmeb_spec_invocation(
    args: &[String],
    lane_tag: &str,
) -> Result<
    (
        mcp_benchmarker_rs::lmeb_corpus::LmebCorpus,
        Vec<mcp_benchmarker_rs::lmeb_spec_runner::LmebSpecQuery>,
        mcp_benchmarker_rs::lmeb_spec_runner::LmebSpecRunConfig,
    ),
    String,
> {
    use mcp_benchmarker_rs::lmeb_spec_metrics::{LmebInstructionSetting, LmebSpecOptions};
    use mcp_benchmarker_rs::lmeb_spec_runner::{LmebSpecQuery, LmebSpecRunConfig};

    let data_dir_str = option_value("--data-dir", args)
        .map(str::to_string)
        .ok_or_else(|| "missing required option --data-dir".to_string())?;
    let data_dir = PathBuf::from(&data_dir_str);
    if !data_dir.exists() {
        return Err(format!(
            "LMEB data directory not found at '{}'. \
             Run scripts/fetch-lmeb.sh to download the dataset.",
            data_dir.display()
        ));
    }

    // --evidence-types ET1,ET2,… (default: all six ConvoMem subsets, §8 whole-set).
    let all_types = [
        "abstention_evidence", "assistant_facts_evidence", "changing_evidence",
        "implicit_connection_evidence", "preference_evidence", "user_evidence",
    ];
    let evidence_types: Vec<String> = match option_value("--evidence-types", args) {
        Some(s) => s.split(',').map(str::to_string).collect(),
        None => all_types.iter().map(|s| s.to_string()).collect(),
    };

    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY".to_string()
        })?;

    // Seed default 20260818 — the spec lanes' shared default.
    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_260_818_u64);
    let limit = parse_limit_option(args)?;
    let offset: usize = option_value("--offset", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let out_dir = option_value("--out", args).map(PathBuf::from);
    if let Some(ref d) = out_dir {
        std::fs::create_dir_all(d)
            .map_err(|e| format!("could not create output directory '{}': {}", d.display(), e))?;
    }

    // Artifact estate scale: unit (default) or bench-aggregate.
    // completeAggregate is refused for spec lanes (§8 per-scene scope).
    let target_scale = match option_value("--target-scale", args) {
        None => ArtifactTargetScale::Unit,
        Some(s) => ArtifactTargetScale::parse(s)
            .ok_or_else(|| format!("--target-scale must be 'unit' or 'bench-aggregate'; got '{s}'"))?,
    };
    if target_scale == ArtifactTargetScale::CompleteAggregate {
        return Err(format!("--target-scale complete-aggregate is refused for {lane_tag} (§8)"));
    }
    let catalog_path = option_value("--catalog", args).map(PathBuf::from);
    let estate_dir = option_value("--estate-dir", args).map(PathBuf::from);

    // Validate: unit scale requires catalog_path; bench-aggregate requires estate_dir.
    match target_scale {
        ArtifactTargetScale::Unit => {
            if catalog_path.is_none() {
                return Err(format!("{lane_tag} unit scale requires --catalog"));
            }
        }
        ArtifactTargetScale::BenchAggregate => {
            if estate_dir.is_none() {
                return Err(format!("{lane_tag} bench-aggregate scale requires --estate-dir"));
            }
        }
        ArtifactTargetScale::CompleteAggregate => unreachable!(),
    }

    // --parallel N: bounded query concurrency (default 1). Parallel and serial
    // runs produce the same accuracy figures (method §8.1).
    // bench-aggregate is always forced to 1 (single shared estate, no concurrent access).
    let parallel_units: usize = match option_value("--parallel", args) {
        Some(s) => {
            let n = s
                .parse::<usize>()
                .map_err(|_| format!("--parallel must be >= 1; got '{s}'"))?;
            if n < 1 {
                return Err(format!("--parallel must be >= 1; got {n}"));
            }
            n
        }
        None => 1,
    };

    // §A4: --instruction-setting without|with (default: without, the canonical
    // zero-instruction baseline; both settings produce published LMEB numbers).
    let instruction_setting = match option_value("--instruction-setting", args) {
        None | Some("without") => LmebInstructionSetting::WithoutInstruction,
        Some("with") => LmebInstructionSetting::WithInstruction,
        Some(other) => {
            return Err(format!(
                "--instruction-setting must be 'without' or 'with'; got '{other}'"
            ));
        }
    };

    eprintln!(
        "[{lane_tag}] loading corpus from {} ({} evidence types)",
        data_dir.display(),
        evidence_types.len()
    );
    // Provenance: same full four-file-per-type digest the lmeb lane records
    // when it builds the artifacts — the spec lanes restore those artifacts,
    // so the digests must be computed identically or require-mode refuses
    // every entry as a provenance mismatch.
    let corpus_digest = {
        let type_refs: Vec<&str> = evidence_types.iter().map(String::as_str).collect();
        mcp_benchmarker_rs::lmeb_corpus::lmeb_corpus_digest(&data_dir, &type_refs)
    };
    let type_refs: Vec<&str> = evidence_types.iter().map(String::as_str).collect();
    let corpus = mcp_benchmarker_rs::lmeb_corpus::load_lmeb_corpus(&data_dir, &type_refs)
        .map_err(|e| format!("corpus load failed: {e:?}"))?;

    // Spec queries from the namespaced id space ("{evidenceType}__{rawID}",
    // the loader's cross-category collision guard). Sorted by id so the
    // runner's seeded shuffle starts from a fixed order (HashMap iteration
    // order would otherwise vary run to run).
    let mut ids: Vec<&String> = corpus.queries_by_id.keys().collect();
    ids.sort();
    let spec_queries: Vec<LmebSpecQuery> = ids
        .into_iter()
        .map(|id| {
            let evidence_type = id.split("__").next().unwrap_or("unknown").to_string();
            // Minimal constructor: correct_answer None, evidence_count 1, no
            // messages — the Rust corpus's queries.jsonl carries no answer field
            // (the Swift twin's optional answer enrichment has no Rust source yet;
            // the judge step counts such questions unscored per §B3).
            LmebSpecQuery::new(corpus.queries_by_id[id].clone(), evidence_type)
        })
        .collect();

    let config = LmebSpecRunConfig {
        moot_binary: binary,
        data_dir,
        evidence_types,
        limit,
        offset,
        seed,
        out_dir,
        run_label: format!("{lane_tag}-seed{seed}"),
        // Artifact estate seam (run book §8): opens pre-built estates, builds nothing.
        target_scale,
        catalog_path,
        estate_dir,
        guard_sampling_policy: mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
            option_value("--guard-sample", args))?,
        corpus_digest,
        parallel_units,
        instruction_setting,
        spec_options: LmebSpecOptions::default(),
        answer_cmd: None,
        answer_hydration_depth: 10,
        answer_hydration_tier: mcp_benchmarker_rs::journey_driver::HydrationDepth::Distilled,
        judge_cmd: None,
        judge_max_retries: 3,
        judge_identity: "unknown".to_string(),
        dump_answer_inputs_path: None,
        dump_judge_inputs_path: None,
        // --scoring raw|rrf|matrixAware|discriminative: when given, passed as the
        // "scoring" key in every moot_memory_search call. When omitted, the call is
        // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
        // Mutually exclusive with --recall-shape (checked below after construction).
        scoring_strategy: option_value("--scoring", args).map(|s| s.to_string()),
        // --recall-shape <preset>: when given, the per-query call switches to
        // moot_recall_shaped with this preset. The server validates the preset against
        // its roster; the client passes it through unvalidated.
        // Mutually exclusive with --scoring: moot_recall_shaped runs matrixAware
        // internally and does not accept a "scoring" key.
        recall_shape: option_value("--recall-shape", args).map(|s| s.to_string()),
        // --request-limit N: per-question verb call limit (default 20, always sent
        // explicitly so the estate respects it even when 20 matches the server default).
        request_limit: option_value("--request-limit", args)
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(20),
        // --pool-metrics: when present, pass explain:true in the recall call so the
        // response carries the pool provenance breakdown. Off by default to preserve
        // byte-identical baseline runs.
        pool_metrics_enabled: args.iter().any(|a| a == "--pool-metrics"),
        // --short-query-terms N: content-term threshold for the short-query gate (default 4).
        // A question with content_term_count < N is counted as a short query.
        short_query_terms: option_value("--short-query-terms", args)
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(4),
    };
    // Fail fast if both --scoring and --recall-shape are given, before any estate
    // is opened, so the error is immediate and unambiguous.
    if config.scoring_strategy.is_some() && config.recall_shape.is_some() {
        return Err(
            "--scoring and --recall-shape are mutually exclusive: \
             moot_recall_shaped always runs matrixAware and does not accept a scoring key"
                .to_string(),
        );
    }
    Ok((corpus, spec_queries, config))
}

/// Serialises a per-k metric grid as {"<name>_at_<k>": value} JSON pairs.
fn lmeb_spec_grid_json(name: &str, grid: &[(usize, f64)]) -> serde_json::Map<String, serde_json::Value> {
    grid.iter()
        .map(|(k, v)| (format!("{name}_at_{k}"), serde_json::json!(v)))
        .collect()
}

/// R_cap variant: §A3 None-propagation serialises as JSON null.
fn lmeb_spec_grid_json_opt(name: &str, grid: &[(usize, Option<f64>)]) -> serde_json::Map<String, serde_json::Value> {
    grid.iter()
        .map(|(k, v)| (format!("{name}_at_{k}"), match v {
            Some(x) => serde_json::json!(x),
            None => serde_json::Value::Null,
        }))
        .collect()
}

fn run_lmeb_spec_cmd(args: &[String]) -> Result<(), String> {
    use mcp_benchmarker_rs::lmeb_spec_metrics::LmebInstructionSetting;

    let (corpus, spec_queries, config) = parse_lmeb_spec_invocation(args, "lmeb-spec")?;
    let serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(args);

    let results = mcp_benchmarker_rs::lmeb_spec_runner::run_lmeb_spec_queries(
        &spec_queries, &corpus, &config)?;

    // Arm mirrors the parent lane (all6 for the full set, else joined names)
    // suffixed with the §A4 instruction setting: the two settings are distinct
    // arms of one pass and each record carries its own name (records are
    // never overwritten).
    let evidence_arm = if config.evidence_types.len() == 6 { "all6".to_string() }
        else { config.evidence_types.join("+") };
    let arm = format!("{evidence_arm}-{}", match config.instruction_setting {
        mcp_benchmarker_rs::lmeb_spec_metrics::LmebInstructionSetting::WithInstruction => "with",
        mcp_benchmarker_rs::lmeb_spec_metrics::LmebInstructionSetting::WithoutInstruction => "without",
    });

    // subset_metrics: add evidence_type alias alongside the existing subset key
    // so ev-table.py can address the subset by either name.
    let subsets: Vec<serde_json::Value> = results.subset_metrics.iter().map(|s| {
        let mut obj = serde_json::Map::new();
        obj.insert("subset".into(), serde_json::json!(s.subset_name));
        // evidence_type alias: ev-table.py reads this key from subset_metrics entries.
        obj.insert("evidence_type".into(), serde_json::json!(s.subset_name));
        obj.insert("query_count".into(), serde_json::json!(s.query_count));
        obj.extend(lmeb_spec_grid_json("ndcg", &s.ndcg));
        obj.extend(lmeb_spec_grid_json("map", &s.map));
        obj.extend(lmeb_spec_grid_json("recall", &s.recall));
        obj.extend(lmeb_spec_grid_json("precision", &s.precision));
        obj.extend(lmeb_spec_grid_json("mrr", &s.mrr));
        obj.extend(lmeb_spec_grid_json_opt("r_cap", &s.r_cap));
        serde_json::Value::Object(obj)
    }).collect();

    let mut task = serde_json::Map::new();
    task.insert("subset_count".into(), serde_json::json!(results.task_metrics.subset_count));
    task.extend(lmeb_spec_grid_json("ndcg", &results.task_metrics.ndcg));
    task.extend(lmeb_spec_grid_json("map", &results.task_metrics.map));
    task.extend(lmeb_spec_grid_json("recall", &results.task_metrics.recall));
    task.extend(lmeb_spec_grid_json("precision", &results.task_metrics.precision));
    task.extend(lmeb_spec_grid_json("mrr", &results.task_metrics.mrr));
    task.extend(lmeb_spec_grid_json_opt("r_cap", &results.task_metrics.r_cap));
    // Expand-verify scoreboard task metrics (§7.5).
    task.insert("pool_guarantee".into(), serde_json::json!(results.task_metrics.pool_guarantee));
    task.insert("pool_gold_recall".into(), serde_json::json!(results.task_metrics.pool_gold_recall));
    task.insert("short_query_count".into(), serde_json::json!(results.task_metrics.short_query_count));
    task.insert("short_query_ndcg_at_10".into(), serde_json::json!(results.task_metrics.short_query_ndcg_at_10));
    task.insert("short_query_recall_at_10".into(), serde_json::json!(results.task_metrics.short_query_recall_at_10));
    task.insert("short_query_pool_guarantee".into(), serde_json::json!(results.task_metrics.short_query_pool_guarantee));

    // per_question_records: one entry per query with all §7.5 required fields.
    let per_question: Vec<serde_json::Value> = results.per_query_results.iter().map(|r| {
        let gold_doc_ids: Vec<&String> = r.relevant_doc_ids.iter().collect();
        serde_json::json!({
            "query_id":           r.query_id,
            "evidence_type":      r.evidence_type,
            "content_term_count": r.content_term_count,
            "returned_count":     r.retrieved_doc_ids.len(),
            "gold_doc_ids":       gold_doc_ids,
            "gold_ranks":         r.gold_ranks,
            "pool_size":          r.pool_size,
            "pool_gold_hit":      r.pool_gold_hit,
            "pool_provenance":    r.pool_provenance,
            "latency_seconds":    r.query_latency_seconds,
        })
    }).collect();

    // §6 required report fields (F1): binary identity only (2026-08-18 doctrine).
    // Stamp testname-arm-serial so the record self-identifies (D1 discipline).
    // Pre-computed before json!() — serde_json::json! does not accept block expressions.
    let lmeb_spec_run_env: serde_json::Value = {
        let mut env = IdentityEnvironment::collect(Some(&config.moot_binary));
        env.benchmark_test_name  = Some("lmeb-spec".to_string());
        env.benchmark_arm        = Some(arm.clone());
        env.benchmark_run_serial = Some(serial.clone());
        serde_json::to_value(env).unwrap_or(serde_json::Value::Null)
    };

    let report = serde_json::json!({
        "benchmark": "lmeb-spec",
        "run_label": config.run_label,
        "port": "rust",
        "target_scale": config.target_scale.as_str(),
        "estate_mode": if config.target_scale == ArtifactTargetScale::Unit {
            "artifact-unit" } else { "artifact-aggregate" },
        "seed": config.seed,
        "arm": arm,
        "serial": serial,
        "evidence_types": config.evidence_types,
        "instruction_setting": match results.instruction_setting {
            LmebInstructionSetting::WithInstruction => "with",
            LmebInstructionSetting::WithoutInstruction => "without",
        },
        "skip_first_result": results.spec_options.skip_first_result,
        "ignore_identical_ids": results.spec_options.ignore_identical_ids,
        "total_queries": results.total_queries,
        "guard_excluded_count": results.guard_excluded_count,
        // Scoring strategy: "default" when --scoring was omitted, the literal value otherwise.
        "scoring": config.scoring_strategy.as_deref().unwrap_or("default"),
        // Recall shape preset: "none" when --recall-shape was absent (moot_memory_search
        // baseline), the literal preset name otherwise. Enables arm comparisons where
        // the recall shape is the variable.
        "recall_shape": config.recall_shape.as_deref().unwrap_or("none"),
        "task_metrics": serde_json::Value::Object(task),
        "subset_metrics": subsets,
        // Per-question verb limit (default 20), pool-metrics switch and short-query gate: top-level,
        // matching the Swift lmeb-spec report key for key.
        "request_limit": config.request_limit,
        "pool_metrics_enabled": config.pool_metrics_enabled,
        "short_query_terms": config.short_query_terms,
        "per_question_records": per_question,
        "run_environment":         lmeb_spec_run_env,
        // Dream drain status captured once at run start (item 8).
        "dream_pending":  results.dream_pending,
        "dream_draining": results.dream_draining,
    });
    let sorted = mcp_benchmarker_rs::longmemeval_scorer::sorted_json_value(&report);
    let bytes = serde_json::to_vec_pretty(&sorted)
        .map_err(|e| format!("report encode failed: {e}"))?;
    let filename = mcp_benchmarker_rs::record_writer::record_filename(
        "lmeb-spec", &arm, &serial, "", "json");
    let path = config.out_dir.as_deref().unwrap_or_else(|| Path::new(".")).join(&filename);
    mcp_benchmarker_rs::record_writer::write_record_never_overwrite(&bytes, &path)
        .map_err(|e| format!("report write failed: {e}"))?;

    println!("[lmeb-spec] run complete");
    println!("  queries processed: {}", results.total_queries);
    println!("  task ndcg_at_10:   {:.5}", results.task_metrics.ndcg_at_10());
    println!("  report written to: {}", path.display());
    Ok(())
}

fn run_convomem_spec_cmd(args: &[String]) -> Result<(), String> {
    // Parse the shared invocation first so both the --consume-answers branch
    // and the inline branch read evidence_types, run_label, seed, and
    // target_scale from the same parsed config — matching the Swift twin
    // (runConvoMemSpec calls parseLMEBSpecInvocation before either path).
    let (corpus, spec_queries, mut config) = parse_lmeb_spec_invocation(args, "convomem-spec")?;

    // --consume-answers: offline judge-dump path. Reads a judge_ready JSONL,
    // runs the judge offline per line, and writes a §B4 aggregate record.
    // Twin of Swift runConvoMemSpec --consume-answers arm; all record fields
    // (run_label, seed, target_scale, evidence_types, arm) come from the
    // parsed invocation, matching the inline-run record exactly.
    if let Some(consume_path) = option_value("--consume-answers", args) {
        let judge_cmd = std::env::var("MOOT_BENCH_JUDGE_CMD").ok()
            .or_else(|| option_value("--judge-cmd", args).map(str::to_string))
            .ok_or_else(|| {
                "--consume-answers requires a judge command; pass --judge-cmd or \
                 set MOOT_BENCH_JUDGE_CMD"
                    .to_string()
            })?;
        let judge_identity = option_value("--judge-model", args)
            .unwrap_or("unknown")
            .to_string();
        let serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(args);

        let agg = mcp_benchmarker_rs::lmeb_spec_runner::run_convomem_spec_judge_dump(
            consume_path,
            &judge_cmd,
            3, // §B3 bounded retry limit, matching Swift twin
        )
        .map_err(|e| format!("convomem-spec consume-answers failed: {}", e.description))?;

        // arm derived from the parsed invocation's evidence_types — same rule
        // as the inline path and the Swift twin (all6 for six types, else joined).
        let arm = if config.evidence_types.len() == 6 {
            "all6".to_string()
        } else {
            config.evidence_types.join("+")
        };

        let mut report = serde_json::Map::new();
        report.insert("benchmark".into(), serde_json::json!("convomem-spec"));
        // run_label from parsed invocation (e.g. "convomem-spec-seed20260818"),
        // matching the inline-run record and the Swift twin's convention.
        report.insert("run_label".into(), serde_json::json!(config.run_label));
        report.insert("port".into(), serde_json::json!("rust"));
        // target_scale from the parsed --target-scale flag (default: "unit"),
        // matching the Swift twin which also reads it from the invocation.
        report.insert("target_scale".into(), serde_json::json!(config.target_scale.as_str()));
        report.insert("estate_mode".into(), serde_json::json!("consumed-answers"));
        // seed from the parsed --seed flag (default 20260818), matching Swift.
        report.insert("seed".into(), serde_json::json!(config.seed));
        report.insert("arm".into(), serde_json::json!(arm));
        report.insert("serial".into(), serde_json::json!(serial));
        // evidence_types from the parsed --evidence-types flag (default: all six),
        // matching the Swift twin which reads them from the invocation.
        report.insert("evidence_types".into(), serde_json::json!(config.evidence_types));
        report.insert("consumed_answers_path".into(), serde_json::json!(consume_path));
        report.insert("judge_identity".into(), serde_json::json!(judge_identity));
        // judge_cmd presence is recorded as a boolean; the command text is never
        // stored (may carry API keys — SECRECY rule).
        report.insert("judge_cmd_set".into(), serde_json::json!(true));
        // Stamp testname-arm-serial so the record self-identifies (D1 discipline).
        {
            let mut convomem_consume_env = IdentityEnvironment::collect(Some(&config.moot_binary));
            convomem_consume_env.benchmark_test_name  = Some("convomem-spec".to_string());
            convomem_consume_env.benchmark_arm        = Some(arm.clone());
            convomem_consume_env.benchmark_run_serial = Some(serial.clone());
            report.insert("run_environment".into(), serde_json::to_value(convomem_consume_env)
                .unwrap_or(serde_json::Value::Null));
        }
        // §B4 aggregate fields.
        report.insert("accuracy_by_evidence_type".into(), serde_json::json!(
            agg.per_type.iter().map(|r| serde_json::json!({
                "evidence_type": r.evidence_type, "accuracy": r.accuracy,
                "correct_count": r.correct_count, "scored_count": r.scored_count,
                "unscored_count": r.unscored_count,
            })).collect::<Vec<_>>()));
        report.insert("accuracy_by_evidence_count".into(), serde_json::json!(
            agg.per_count.iter().map(|r| serde_json::json!({
                "evidence_count": r.evidence_count, "accuracy": r.accuracy,
                "correct_count": r.correct_count, "scored_count": r.scored_count,
                "unscored_count": r.unscored_count,
            })).collect::<Vec<_>>()));
        report.insert("overall_accuracy".into(), serde_json::json!(agg.overall_accuracy));
        report.insert("overall_correct_count".into(), serde_json::json!(agg.overall_correct_count));
        report.insert("overall_scored_count".into(), serde_json::json!(agg.overall_scored_count));
        report.insert("overall_unscored_count".into(), serde_json::json!(agg.overall_unscored_count));

        let sorted = mcp_benchmarker_rs::longmemeval_scorer::sorted_json_value(
            &serde_json::Value::Object(report));
        let bytes = serde_json::to_vec_pretty(&sorted)
            .map_err(|e| format!("report encode failed: {e}"))?;
        let filename = mcp_benchmarker_rs::record_writer::record_filename(
            "convomem-spec", &arm, &serial, "", "json");
        let path = config.out_dir.as_deref().unwrap_or_else(|| Path::new(".")).join(&filename);
        mcp_benchmarker_rs::record_writer::write_record_never_overwrite(&bytes, &path)
            .map_err(|e| format!("report write failed: {e}"))?;

        println!("[convomem-spec] consume complete");
        println!("  overall_accuracy:       {}", agg.overall_accuracy);
        println!("  overall_correct_count:  {}", agg.overall_correct_count);
        println!("  overall_scored_count:   {}", agg.overall_scored_count);
        println!("  overall_unscored_count: {}", agg.overall_unscored_count);
        println!("  report written to:      {}", path.display());
        return Ok(());
    }

    // Inline run path — config already parsed above.
    let serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(args);

    // §B1/§B2 seams. Env vars preferred over flags (`ps` argv visibility);
    // commands may carry API keys — never printed, never recorded.
    config.answer_cmd = std::env::var("MOOT_BENCH_ANSWER_CMD").ok()
        .or_else(|| option_value("--answer-cmd", args).map(str::to_string));
    config.judge_cmd = std::env::var("MOOT_BENCH_JUDGE_CMD").ok()
        .or_else(|| option_value("--judge-cmd", args).map(str::to_string));
    config.judge_identity = option_value("--judge-model", args)
        .unwrap_or("unknown").to_string();
    if let Some(depth) = option_value("--judge-hydration-depth", args)
        .and_then(|s| s.parse().ok()) {
        config.answer_hydration_depth = depth;
    }
    config.dump_answer_inputs_path =
        option_value("--dump-answer-inputs", args).map(str::to_string);
    config.dump_judge_inputs_path =
        option_value("--dump-judge-inputs", args).map(str::to_string);
    if let Some(tier_str) = option_value("--hydration-tier", args) {
        config.answer_hydration_tier = match tier_str {
            "full" => mcp_benchmarker_rs::journey_driver::HydrationDepth::Full,
            "distilled" => mcp_benchmarker_rs::journey_driver::HydrationDepth::Distilled,
            other => {
                return Err(format!(
                    "convomem-spec --hydration-tier must be distilled or full; got '{other}'"
                ));
            }
        };
    }

    // MOOT_BENCH_UNIT_IDS: pin the query set to an explicit ID subset.
    // Accepted forms: bare query ID (scene_N_q_M) or unit-stem form
    // (<evidence>__scene_N_q_M). Normalise stem-form IDs to the bare
    // query-id form so both representations match the same queries.
    let spec_queries: Vec<mcp_benchmarker_rs::lmeb_spec_runner::LmebSpecQuery> =
        if let Some(ids_str) = std::env::var("MOOT_BENCH_UNIT_IDS").ok() {
            let ids_path = ids_str.trim();
            let raw = std::fs::read_to_string(ids_path)
                .map_err(|e| format!("MOOT_BENCH_UNIT_IDS: cannot read '{}': {e}", ids_path))?;
            // Normalise via normalize_unit_id: stem-form IDs match the same queries as bare IDs.
            let unit_ids: std::collections::HashSet<String> = raw.lines()
                .map(|l| l.trim())
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .map(|l| mcp_benchmarker_rs::unit_id_filter::normalize_unit_id(l))
                .collect();
            let filtered: Vec<_> = spec_queries.into_iter()
                .filter(|q| unit_ids.contains(q.query.id.as_str()))
                .collect();
            eprintln!("[convomem-spec] MOOT_BENCH_UNIT_IDS: {} queries selected", filtered.len());
            filtered
        } else {
            spec_queries
        };

    let results = mcp_benchmarker_rs::lmeb_spec_runner::run_convomem_spec_queries(
        &spec_queries, &corpus, &config)?;

    let arm = if config.evidence_types.len() == 6 { "all6".to_string() }
        else { config.evidence_types.join("+") };

    let mut report = serde_json::Map::new();
    report.insert("benchmark".into(), serde_json::json!("convomem-spec"));
    report.insert("target_scale".into(), serde_json::json!(config.target_scale.as_str()));
    report.insert("estate_mode".into(), serde_json::json!(
        if config.target_scale == ArtifactTargetScale::Unit {
            "artifact-unit" } else { "artifact-aggregate" }));
    report.insert("run_label".into(), serde_json::json!(config.run_label));
    report.insert("port".into(), serde_json::json!("rust"));
    report.insert("seed".into(), serde_json::json!(config.seed));
    report.insert("arm".into(), serde_json::json!(arm));
    report.insert("serial".into(), serde_json::json!(serial));
    report.insert("evidence_types".into(), serde_json::json!(config.evidence_types));
    report.insert("total_queries".into(), serde_json::json!(results.total_queries));
    report.insert("answered_count".into(), serde_json::json!(results.answered_count));
    report.insert("judged_count".into(), serde_json::json!(results.judged_count));
    report.insert("guard_excluded_count".into(), serde_json::json!(results.guard_excluded_count));
    // §B4: judge identity recorded; command text never recorded (secrecy).
    report.insert("judge_identity".into(), serde_json::json!(results.judge_identity));
    report.insert("answer_cmd_set".into(), serde_json::json!(results.answer_cmd_set));
    report.insert("judge_cmd_set".into(), serde_json::json!(results.judge_cmd_set));
    report.insert("memory_texts_empty_count".into(), serde_json::json!(results.memory_texts_empty_count));
    // §6 required report fields (F1).
    // 2026-08-18 doctrine: accuracy lane emits binary identity only.
    // Stamp testname-arm-serial so the record self-identifies (D1 discipline).
    {
        let mut convomem_live_env = IdentityEnvironment::collect(Some(&config.moot_binary));
        convomem_live_env.benchmark_test_name  = Some("convomem-spec".to_string());
        convomem_live_env.benchmark_arm        = Some(arm.clone());
        convomem_live_env.benchmark_run_serial = Some(serial.clone());
        report.insert("run_environment".into(), serde_json::to_value(convomem_live_env)
            .unwrap_or(serde_json::Value::Null));
    }
    if let Some(agg) = &results.aggregate_result {
        // §B4: accuracy per evidence type / per evidence count / overall,
        // counts alongside every mean, unscored counted separately.
        report.insert("accuracy_by_evidence_type".into(), serde_json::json!(
            agg.per_type.iter().map(|r| serde_json::json!({
                "evidence_type": r.evidence_type, "accuracy": r.accuracy,
                "correct_count": r.correct_count, "scored_count": r.scored_count,
                "unscored_count": r.unscored_count,
            })).collect::<Vec<_>>()));
        report.insert("accuracy_by_evidence_count".into(), serde_json::json!(
            agg.per_count.iter().map(|r| serde_json::json!({
                "evidence_count": r.evidence_count, "accuracy": r.accuracy,
                "correct_count": r.correct_count, "scored_count": r.scored_count,
                "unscored_count": r.unscored_count,
            })).collect::<Vec<_>>()));
        report.insert("overall_accuracy".into(), serde_json::json!(agg.overall_accuracy));
        report.insert("overall_correct_count".into(), serde_json::json!(agg.overall_correct_count));
        report.insert("overall_scored_count".into(), serde_json::json!(agg.overall_scored_count));
        report.insert("overall_unscored_count".into(), serde_json::json!(agg.overall_unscored_count));
    }
    // Dream drain status captured once at run start (item 8).
    report.insert("dream_pending".into(), serde_json::json!(results.dream_pending));
    report.insert("dream_draining".into(), serde_json::json!(results.dream_draining));
    let sorted = mcp_benchmarker_rs::longmemeval_scorer::sorted_json_value(
        &serde_json::Value::Object(report));
    let bytes = serde_json::to_vec_pretty(&sorted)
        .map_err(|e| format!("report encode failed: {e}"))?;
    let filename = mcp_benchmarker_rs::record_writer::record_filename(
        "convomem-spec", &arm, &serial, "", "json");
    let path = config.out_dir.as_deref().unwrap_or_else(|| Path::new(".")).join(&filename);
    mcp_benchmarker_rs::record_writer::write_record_never_overwrite(&bytes, &path)
        .map_err(|e| format!("report write failed: {e}"))?;

    // Broken-hydration gate: all queries returning empty memory_texts means
    // estate hydration failed across the board — not a complete run.
    if results.total_queries > 0
        && results.memory_texts_empty_count == results.total_queries
    {
        if let Some(first_empty) = results.per_query_results
            .iter()
            .find(|r| r.retrieved_memory_texts.is_empty())
        {
            eprintln!(
                "[convomem-spec] ERROR: all {} queries produced empty memory_texts; \
                 first affected query: {}. \
                 Estate hydration failed (check --catalog and id-map.json).",
                results.total_queries, first_empty.query_id
            );
            std::process::exit(1);
        }
    }

    println!("[convomem-spec] run complete");
    println!("  queries processed:        {}", results.total_queries);
    println!("  answered_count:           {}", results.answered_count);
    println!("  judged_count:             {}", results.judged_count);
    println!("  memory_texts_empty_count: {}", results.memory_texts_empty_count);
    println!("  report written to:        {}", path.display());
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// run_membench — MemBench per-item recall lane
// ─────────────────────────────────────────────────────────────────────────────

fn run_membench(args: &[String]) -> Result<(), String> {
    // --data-dir is required.
    let data_dir_str = option_value("--data-dir", args)
        .map(str::to_string)
        .ok_or_else(|| {
            "missing required option --data-dir (path to MemData/ directory containing \
             FirstAgent/ or ThirdAgent/)"
                .to_string()
        })?;
    let data_dir = Path::new(&data_dir_str);
    if !data_dir.exists() {
        return Err(format!(
            "MemBench MemData directory not found at '{}'. \
             Run scripts/fetch-membench.sh to download the dataset.",
            data_dir.display()
        ));
    }

    // --binary / --mootx01-binary.
    let binary_str = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY"
                .to_string()
        })?;

    let agent = option_value("--agent", args).unwrap_or("FirstAgent");
    if agent != "FirstAgent" && agent != "ThirdAgent" {
        return Err(format!(
            "--agent must be 'FirstAgent' or 'ThirdAgent'; got '{agent}'"
        ));
    }

    let limit = parse_limit_option(args)?;
    let offset = option_value("--offset", args)
        .map(|s| s.parse::<usize>().map_err(|_| format!("--offset must be a non-negative integer; got '{s}'")))
        .transpose()?
        .unwrap_or(0);
    // Default seed 20260806 — the date this lane was added — distinguishes
    // MemBench runs from LoCoMo (20260725) and LME (20260725) in multi-run logs.
    let seed = option_value("--seed", args)
        .map(|s| s.parse::<u64>().map_err(|_| format!("--seed must be a non-negative integer; got '{s}'")))
        .transpose()?
        .unwrap_or(20_260_806);

    let encode_barrier = match option_value("--encode-barrier", args) {
        Some(s) => EncodeBarrier::from_str(s).map_err(|e| e)?,
        None => EncodeBarrier::default(),
    };
    let scratch_posture = parse_estate_mode(args)?;
    // 2026-08-18 doctrine: encryption is a timing-lane-only concern.
    if scratch_posture == ScratchEstatePosture::EncryptedEphemeral {
        return Err("encryption is tested only by the timing lane".to_string());
    }
    let out_dir = option_value("--out", args).map(PathBuf::from);
    if let Some(ref d) = out_dir {
        std::fs::create_dir_all(d)
            .map_err(|e| format!("could not create output directory '{}': {}", d.display(), e))?;
    }

    let category_filter = option_value("--category", args).map(str::to_string);
    // Seed-path (--seed-path batch|live, default batch). Governing ruling 8D5B8053.
    let membench_seed_path =
        mcp_benchmarker_rs::seed_export::SeedPathMode::parse(option_value("--seed-path", args))
            .map_err(|e| e)?;

    // --estate-cache off|reuse (default: off) — B6 membench artifact wiring.
    let membench_estate_cache_str = option_value("--estate-cache", args);
    let membench_estate_cache = match membench_estate_cache_str {
        Some(s) => EstateCacheMode::from_str(s).map_err(|e| e)?,
        None => EstateCacheMode::default(),
    };
    // --cache-dir <path>: override cache root (default: <out>/estate-cache).
    let membench_cache_dir = option_value("--cache-dir", args).map(PathBuf::from);

    // C1: storage backend shape (--shape disk|ram, default disk).
    // RAM shape passes --in-memory to serve — no disk artifact exists,
    // so estate-cache modes Reuse and Require are rejected before any work.
    let membench_shape =
        mcp_benchmarker_rs::membench_runner::BenchShape::parse(option_value("--shape", args))
            .map_err(|e| e)?;
    if membench_shape == mcp_benchmarker_rs::membench_runner::BenchShape::Ram
        && membench_estate_cache != EstateCacheMode::Off
    {
        return Err(format!(
            "--shape ram cannot be combined with --estate-cache {}: \
             a RAM estate holds no disk artifact, so no snapshot can be taken or \
             restored. Run RAM shape with --estate-cache off.",
            membench_estate_cache_str.unwrap_or("reuse")
        ));
    }

    // C6: parallel items (--parallel N, default 80% of available cores, minimum 1).
    // N == 1 reproduces previous serial behaviour; thread::scope preserves ordering
    // via indexed collection and sort-by-run_index before return.
    let membench_parallel_units: usize = match option_value("--parallel", args) {
        Some(s) => {
            let n = s.parse::<usize>().map_err(|_| {
                format!("--parallel must be a positive integer; got '{s}'")
            })?;
            if n < 1 {
                return Err(format!("--parallel must be >= 1; got '{s}'"));
            }
            n
        }
        None => {
            let cores = std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(1);
            ((cores as f64 * 0.8) as usize).max(1)
        }
    };
    // C10: estate grouping mode (--estate-grouping per-item|consolidated, default per-item).
    // Consolidated mode groups items by conflict key (question text) and runs each
    // group in a shared estate; every report figure carries protocol-deviation labels.
    let membench_estate_grouping =
        EstateGroupingMode::parse(option_value("--estate-grouping", args))?;

    // C11: capacity tier (--capacity-tier baseline|10k|100k, default baseline).
    // Non-baseline tiers grow each item's estate to the target token volume using
    // conflict-free filler before the query; figures carry protocol-deviation labels.
    let membench_capacity_tier =
        CapacityTier::parse(option_value("--capacity-tier", args))?;

    // B2 provenance: MemData is a directory corpus — combine the per-file
    // digests of the agent subtree's JSON fixtures (sorted by relative path)
    // into one stable value. Mirrors the Swift CLI's memBenchCorpusDigest.
    let membench_corpus_digest: String = {
        let agent_root = data_dir.join(agent);
        let mut files: Vec<PathBuf> = Vec::new();
        fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
            if let Ok(entries) = std::fs::read_dir(dir) {
                for entry in entries.flatten() {
                    let p = entry.path();
                    if p.is_dir() {
                        walk(&p, out);
                    } else if p.extension().map(|e| e == "json").unwrap_or(false) {
                        out.push(p);
                    }
                }
            }
        }
        walk(&agent_root, &mut files);
        if files.is_empty() {
            "unknown".to_string()
        } else {
            files.sort();
            let mut combined = String::new();
            let root_len = agent_root.to_string_lossy().len();
            for f in &files {
                let rel = &f.to_string_lossy()[root_len..].to_string();
                let d = mcp_benchmarker_rs::run_environment::file_sha256_hex(
                    &f.to_string_lossy(),
                )
                .unwrap_or_else(|| "unknown".to_string());
                combined.push_str(&format!("{rel}={d};"));
            }
            mcp_benchmarker_rs::run_environment::sha256_hex(combined.as_bytes())
        }
    };

    eprintln!("[membench] loading corpus from {} (agent: {agent})", data_dir.display());

    let corpus = load_membench_corpus(
        data_dir,
        agent,
        None, // all LowLevel categories; category_filter applied by runner
        None, // limit applied by runner
    )?;
    eprintln!(
        "[membench] loaded {} items ({} skipped)",
        corpus.items.len(),
        corpus.skipped_count
    );

    // Instrument seams (environment-only; see retrieval_call_spec.rs):
    // MOOT_BENCH_RETRIEVAL_TOOL/_ARGS override the query call;
    // MOOT_BENCH_UNIT_IDS pins the unit set.
    let retrieval_call = mcp_benchmarker_rs::retrieval_call_spec::retrieval_call_spec_from_environment()?;
    let unit_ids = mcp_benchmarker_rs::retrieval_call_spec::unit_ids_from_environment()?;
    // --payload-arm v0..v5 (PAYLOAD-ARMS; MOOT_BENCH_PAYLOAD_ARM as the
    // environment spelling): payload-economics shape variant applied to
    // seam-routed retrieval text_blocks. Recorded in run_environment.
    let payload_arm = mcp_benchmarker_rs::payload_arm::parse_payload_arm(
        option_value("--payload-arm", args)
            .map(str::to_string)
            .or_else(|| std::env::var("MOOT_BENCH_PAYLOAD_ARM").ok())
            .as_deref())?;
    if let Some(ids) = &unit_ids {
        mcp_benchmarker_rs::unit_id_filter::validate_unit_ids(
            ids, corpus.items.iter().map(|i| i.item_id.as_str()), "membench")?;
    }

    let run_label = format!("membench-{}-seed{seed}", agent.to_lowercase());

    let run_config = MemBenchRunConfig {
        moot_binary_path: PathBuf::from(&binary_str),
        unit_ids: unit_ids.clone(),
        retrieval_call: retrieval_call.clone(),
        payload_arm,
        data_dir: data_dir.to_path_buf(),
        agent: agent.to_string(),
        limit,
        offset,
        seed,
        out_dir: out_dir.clone(),
        run_label: run_label.clone(),
        encode_barrier,
        scratch_posture,
        category_filter: category_filter.clone(),
        seed_path: membench_seed_path,
        // Guard probe sampling (--guard-sample once|per-unit, default once):
        // the guard validates the binary, not the unit — probe once per leg.
        guard_sampling_policy: mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
            option_value("--guard-sample", args))?,
        estate_cache: membench_estate_cache,
        cache_dir: membench_cache_dir,
        corpus_digest: membench_corpus_digest,
        shape: membench_shape,
        parallel_units: membench_parallel_units,
        estate_grouping: membench_estate_grouping,
        capacity_tier: membench_capacity_tier,
    };

    // C10: branch on estate grouping mode.
    // Consolidated mode groups items by conflict key and runs each group in a shared
    // estate; results carry protocol-deviation labels in the report. Per-item mode
    // is the default published MemBench protocol.
    // C10/C11: branch on estate grouping + capacity tier.
    // ConsolidatedShape3 and capacity-tier modes are mutually exclusive;
    // if both are requested, estate grouping takes priority.
    let (
        results,
        membench_timing_report,
        shape3_items_per_group,
        cap_achieved_tokens,
        cap_items_per_estate,
    ) = if membench_estate_grouping == EstateGroupingMode::ConsolidatedShape3 {
        let (r, t, per_group) = run_membench_items_consolidated(&corpus.items, &run_config)?;
        (r, t, Some(per_group), None, None)
    } else if let Some(target_tokens) = membench_capacity_tier.target_tokens() {
        let (r, t, achieved, per_estate) =
            run_membench_items_capacity_tier(&corpus.items, &run_config, target_tokens)?;
        (r, t, None, Some(achieved), Some(per_estate))
    } else {
        let (r, t) = run_membench_items(&corpus.items, &run_config)?;
        (r, t, None, None, None)
    };
    // Compute unique conflict-key count from result questions (Shape 3 metadata).
    let shape3_unique_keys: Option<usize> = shape3_items_per_group.as_ref().map(|_| {
        let unique: std::collections::HashSet<&str> =
            results.iter().map(|r| r.question.as_str()).collect();
        unique.len()
    });
    let scores: Vec<_> = results.into_iter().map(score_membench_item).collect();

    // 2026-08-18 doctrine: accuracy lane emits binary identity only, not full machine profile.
    let mut membench_run_env = IdentityEnvironment::collect(Some(binary_str.as_str()));
    membench_run_env.payload_arm = payload_arm.map(|a| a.as_str().to_string());
    // Stamp testname-arm-serial before consuming membench_run_env (D1 discipline).
    // The arm is the agent perspective — same value crate_record_filename uses.
    let membench_serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(&args);
    membench_run_env.benchmark_test_name  = Some("membench".to_string());
    membench_run_env.benchmark_arm        = Some(agent.to_string());
    membench_run_env.benchmark_run_serial = Some(membench_serial);
    let cfg = MemBenchReportConfig {
        run_label: &run_label,
        encode_barrier: encode_barrier.as_str(),
        guard_sampling: run_config.guard_sampling_policy.as_str(),
        estate_encryption: scratch_posture.as_str(),
        agent,
        categories_included: None,
        category_filter,
        items_loaded: corpus.items.len(),
        items_skipped: corpus.skipped_count,
        run_environment: Some(membench_run_env),
        shape: membench_shape.as_str(),
        parallel_units: membench_parallel_units,
        timing_report: membench_timing_report,
        shape3_items_per_group,
        shape3_unique_keys,
        capacity_tier: membench_capacity_tier,
        capacity_achieved_tokens: cap_achieved_tokens,
        capacity_items_per_estate: cap_items_per_estate,
    };
    let report = build_membench_report(&cfg, &scores);

    println!("MemBench results (seed={seed}, agent={agent}):");
    println!("  items_run:          {}", report.corpus_stats.items_run);
    println!("  guard_excluded:     {}", report.corpus_stats.guard_excluded);
    println!("  query_count:        {}", report.aggregate.query_count);
    println!("  recall_any@5:       {:.4}", report.aggregate.recall_any_at_5);
    println!("  recall_all@5:       {:.4}", report.aggregate.recall_all_at_5);
    println!("  recall_any@10:      {:.4}", report.aggregate.recall_any_at_10);
    println!("  mrr:                {:.4}", report.aggregate.mrr);
    println!("  query_p50_s:        {:.4}", report.latency.query_p50_seconds);
    println!("  query_p95_s:        {:.4}", report.latency.query_p95_seconds);
    println!("  category_breakdown:");
    for cat in &report.category_breakdown {
        println!(
            "    {:22}  n={:4}  any@5={:.4}  all@5={:.4}  mrr={:.4}",
            cat.label, cat.query_count, cat.recall_any_at_5, cat.recall_all_at_5, cat.mrr
        );
    }

    // `<test>-<arm>-<serial>`: the arm is the agent perspective. FirstAgent and
    // ThirdAgent are different task shapes, and before 2026-08-17 they shared
    // one filename — the second measured would have destroyed the first.
    let report_filename = crate_record_filename("membench", &report.agent, &args);
    let report_path = out_dir
        .as_deref()
        .unwrap_or_else(|| Path::new("."))
        .join(&report_filename);
    write_membench_report(&report, &report_path)?;
    println!("report written to {}", report_path.display());

    Ok(())
}

fn run_lmeb(args: &[String]) -> Result<(), String> {
    // Darkening gates ND-LMEB-1/2: judged path (ruling 2026-08-18).
    reject_darkened_legacy_options(
        "lmeb",
        &["--judge-cmd"],
        &["MOOT_BENCH_JUDGE_CMD"],
        args,
        "the convomem-spec lane (official judged protocol)",
    )?;
    if option_value("--judge-grading", args) == Some("verdict") {
        return Err(
            "--judge-grading verdict is dark on the legacy lmeb lane \
             (ND-LMEB-2, ruling 2026-08-18). Use the convomem-spec lane's §B3 verdicts."
                .to_string(),
        );
    }
    // ── Required ──────────────────────────────────────────────────────────────
    // --data-dir is the Rust-native flag; --corpus is the Swift twin spelling.
    // Accept both: --data-dir takes priority when both are present.
    let data_dir = option_value("--data-dir", args)
        .or_else(|| option_value("--corpus", args))
        .map(str::to_string)
        .ok_or_else(|| "missing required option --data-dir (or --corpus)".to_string())?;

    // ── Optional ──────────────────────────────────────────────────────────────
    // --binary is the Rust-native flag; --mootx01-binary is the Swift twin spelling.
    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY"
                .to_string()
        })?;

    // Default: all six LMEB ConvoMem evidence types.
    // "changing_evidence" is the HuggingFace directory name — matches Swift runner and
    // fetch-lmeb.sh. Note: NOT "changing_state_evidence".
    const ALL_EVIDENCE_TYPES: &[&str] = &[
        "abstention_evidence",
        "assistant_facts_evidence",
        "changing_evidence",
        "implicit_connection_evidence",
        "preference_evidence",
        "user_evidence",
    ];
    let evidence_types_owned: Vec<String> = option_value("--evidence-types", args)
        .map(|s| s.split(',').map(str::to_string).collect())
        .unwrap_or_else(|| ALL_EVIDENCE_TYPES.iter().map(|&s| s.to_string()).collect());
    let evidence_type_refs: Vec<&str> = evidence_types_owned.iter().map(String::as_str).collect();

    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_260_725_u64);
    let limit = parse_limit_option(args)?;
    let offset: usize = option_value("--offset", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let label = option_value("--label", args).map(str::to_string);
    let out_dir = option_value("--out", args).map(PathBuf::from);
    if let Some(ref d) = out_dir {
        std::fs::create_dir_all(d)
            .map_err(|e| format!("could not create output directory '{}': {}", d.display(), e))?;
    }
    // --encode-barrier drain|impatient|none (default: drain).
    let encode_barrier = match option_value("--encode-barrier", args) {
        Some(s) => EncodeBarrier::from_str(s).map_err(|e| e)?,
        None => EncodeBarrier::default(),
    };
    // --estate-cache off|reuse (default: off). Controls estate snapshot reuse.
    let estate_cache_lmeb = match option_value("--estate-cache", args) {
        Some(s) => EstateCacheMode::from_str(s).map_err(|e| e)?,
        None => EstateCacheMode::default(),
    };
    // --cache-dir <path>: override cache root (default: <out>/estate-cache).
    let cache_dir_lmeb = option_value("--cache-dir", args).map(PathBuf::from);
    // --estate-mode: see the longmemeval parser — same semantics.
    let scratch_posture = parse_estate_mode(args)?;
    // 2026-08-18 doctrine: encryption is a timing-lane-only concern.
    if scratch_posture == ScratchEstatePosture::EncryptedEphemeral {
        return Err("encryption is tested only by the timing lane".to_string());
    }

    // ── Load corpus ───────────────────────────────────────────────────────────
    eprintln!("[lmeb] loading corpus from {data_dir}");
    eprintln!("[lmeb] evidence types: {:?}", &evidence_type_refs);
    // Provenance: hash each evidence type's four required files in fixed
    // ASCII-ascending order ({et}/candidates.jsonl, corpus.jsonl, qrels.tsv,
    // queries.jsonl). Returns "unknown" if any required file cannot be read,
    // which causes ArtifactProvenance::mismatches to refuse the cached artifact.
    // Mirrors the Swift CLI's lmebCorpusDigest byte-for-byte.
    let lmeb_corpus_digest =
        mcp_benchmarker_rs::lmeb_corpus::lmeb_corpus_digest(
            Path::new(&data_dir), &evidence_type_refs);
    let corpus = load_lmeb_corpus(Path::new(&data_dir), &evidence_type_refs)
        .map_err(|e| format!("corpus load failed: {e}"))?;
    eprintln!(
        "[lmeb] corpus: {} docs, {} queries, {} qrels",
        corpus.doc_count(),
        corpus.query_count(),
        corpus.qrel_count()
    );
    eprintln!("[lmeb] binary: {binary}  seed: {seed}");
    if let Some(n) = limit {
        eprintln!("[lmeb] limit: {n}  offset: {offset}");
    }
    eprintln!("[lmeb] encode-barrier: {}", encode_barrier.as_str());

    // --dump-judge-inputs <path>: write pre-judge payload JSONL for offline judging.
    let lmeb_dump_judge_inputs_path =
        option_value("--dump-judge-inputs", args).map(str::to_string);
    if let Some(ref p) = lmeb_dump_judge_inputs_path {
        eprintln!("[lmeb] dump-judge-inputs: {p}");
    }

    // --shape disk|ram (default: disk). C1 — selects the mootx01 backend.
    // "ram" passes --in-memory to serve; incompatible with estate-cache reuse|require.
    let lmeb_shape = match option_value("--shape", args).unwrap_or("disk") {
        "disk" => BenchRunShape::Disk,
        "ram"  => BenchRunShape::Ram,
        other  => return Err(format!("--shape must be 'disk' or 'ram'; got '{other}'")),
    };
    if lmeb_shape == BenchRunShape::Ram && estate_cache_lmeb != EstateCacheMode::Off {
        let cache_str = option_value("--estate-cache", args).unwrap_or("off");
        return Err(format!(
            "--shape ram cannot be combined with --estate-cache {cache_str}: \
             a RAM estate is ephemeral — no on-disk snapshot exists to save or restore. \
             Run ram shape with --estate-cache off."
        ));
    }
    // --parallel N (default: max(1, 80% of logical cores)). C6 — bounded query
    // concurrency. 1 = serial behaviour. Each query owns its own scratch dir,
    // MCPClient, and mootx01 process. Results are index-sorted for determinism.
    let lmeb_default_parallel = {
        let cpus = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1);
        ((cpus as f64) * 0.8).max(1.0) as usize
    };
    let lmeb_parallel: usize = match option_value("--parallel", args) {
        Some(s) => {
            let n: usize = s.parse().map_err(|_| format!("--parallel must be a positive integer; got '{s}'"))?;
            if n < 1 { return Err(format!("--parallel must be a positive integer; got '{s}'")); }
            n
        }
        None => lmeb_default_parallel,
    };
    // --estate-shape per-query|consolidated (default: per-query). C10-LMEB Shape 3.
    // "consolidated" groups queries by scene_id into non-overlapping estates.
    // Incompatible with --estate-cache reuse|require (no per-scene cache support).
    let lmeb_estate_shape = LmebEstateShape::parse(
        option_value("--estate-shape", args).unwrap_or("per-query"),
    )
    .map_err(|e| e)?;
    if lmeb_estate_shape == LmebEstateShape::Consolidated
        && estate_cache_lmeb != EstateCacheMode::Off
    {
        let cache_str = option_value("--estate-cache", args).unwrap_or("off");
        return Err(format!(
            "--estate-shape consolidated cannot be combined with --estate-cache {cache_str}: \
             consolidated mode does not support per-scene cache snapshotting. \
             Run with --estate-cache off."
        ));
    }
    eprintln!("[lmeb] shape: {}", lmeb_shape.as_str());
    eprintln!("[lmeb] estate-shape: {}", lmeb_estate_shape.as_str());
    eprintln!("[lmeb] parallel: {lmeb_parallel}");

    // ── Build query list ──────────────────────────────────────────────────────
    let mut all_queries: Vec<_> = corpus.queries_by_id.values().cloned().collect();
    all_queries.sort_by(|a, b| a.id.cmp(&b.id)); // stable deterministic order before shuffle

    // 2026-08-18 doctrine: accuracy lane emits binary identity only, not full machine profile.
    let mut lmeb_run_env = IdentityEnvironment::collect(Some(binary.as_str()));
    // Instrument seams (environment-only; see retrieval_call_spec.rs):
    // MOOT_BENCH_RETRIEVAL_TOOL/_ARGS override the query call;
    // MOOT_BENCH_UNIT_IDS pins the unit set.
    let retrieval_call = mcp_benchmarker_rs::retrieval_call_spec::retrieval_call_spec_from_environment()?;
    let unit_ids = mcp_benchmarker_rs::retrieval_call_spec::unit_ids_from_environment()?;
    // --payload-arm v0..v5 (PAYLOAD-ARMS; MOOT_BENCH_PAYLOAD_ARM as the
    // environment spelling): payload-economics shape variant applied to
    // seam-routed retrieval text_blocks. Recorded in run_environment.
    let payload_arm = mcp_benchmarker_rs::payload_arm::parse_payload_arm(
        option_value("--payload-arm", args)
            .map(str::to_string)
            .or_else(|| std::env::var("MOOT_BENCH_PAYLOAD_ARM").ok())
            .as_deref())?;
    if let Some(ids) = &unit_ids {
        mcp_benchmarker_rs::unit_id_filter::validate_unit_ids(
            ids, corpus.queries_by_id.keys().map(String::as_str), "lmeb")?;
    }
    lmeb_run_env.payload_arm = payload_arm.map(|a| a.as_str().to_string());
    let run_config = LmebRunConfig {
        moot_binary: binary,
        unit_ids: unit_ids.clone(),
        retrieval_call: retrieval_call.clone(),
        payload_arm,
        seed,
        limit,
        offset,
        label: label.clone(),
        out_dir: out_dir.clone(),
        encode_barrier,
        estate_cache: estate_cache_lmeb,
        cache_dir: cache_dir_lmeb,
        scratch_posture,
        // Batch by default (ruling 8D5B8053); `--seed-path live` retains the slow lane.
        seed_path: mcp_benchmarker_rs::seed_export::SeedPathMode::parse(
            option_value("--seed-path", args))?,
        dump_judge_inputs_path: lmeb_dump_judge_inputs_path,
        // Guard probe sampling (--guard-sample once|per-unit, default once):
        // the guard validates the binary, not the unit — probe once per leg.
        guard_sampling_policy: mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
            option_value("--guard-sample", args))?,
        corpus_digest: lmeb_corpus_digest.clone(),
        // C1/C6/C10: wire shape, parallel concurrency, and estate grouping shape.
        shape: lmeb_shape,
        parallel_units: lmeb_parallel,
        // C10-LMEB Shape 3: estate grouping topology (per-query default).
        estate_shape: lmeb_estate_shape,
    };

    // ── Run harness (C10-LMEB: dispatch to consolidated or per-query runner) ──
    let queries_loaded = all_queries.len();
    let (results, lmeb_timing_report, lmeb_group_stats) =
        if lmeb_estate_shape == LmebEstateShape::Consolidated {
            // Shape 3: serial per-scene execution; returns group topology stats.
            let (r, t, g) = run_lmeb_consolidated_queries(&all_queries, &corpus, &run_config)?;
            (r, t, Some(g))
        } else {
            // Default: parallel per-query execution; no group stats.
            let (r, t) = run_lmeb_queries(&all_queries, &corpus, &run_config)?;
            (r, t, None)
        };
    // Extract cache_hit_by_id before consuming results.
    let cache_hit_by_id_lmeb: std::collections::HashMap<String, Option<bool>> = results
        .iter()
        .map(|r| (r.query_id.clone(), r.cache_hit))
        .collect();
    let drain_lane_by_id_lmeb: std::collections::HashMap<String, Option<bool>> = results
        .iter()
        .map(|r| (r.query_id.clone(), r.drain_lane_observed))
        .collect();
    let scores: Vec<_> = results.into_iter().map(score_lmeb_query).collect();

    // ── Build run ID + label ──────────────────────────────────────────────────
    let run_id = {
        let mut rng = SplitMix64::new(seed ^ 0xCAFEF00D);
        format!("{:016x}", rng.next_u64())
    };
    let run_label = label.unwrap_or_else(|| format!("lmeb-seed{seed}"));
    let generated_at = now_iso8601();

    // Stamp testname-arm-serial before consuming lmeb_run_env (D1 discipline).
    // Pre-compute the arm from evidence_types_owned — same derivation as
    // crate_record_filename uses from report.evidence_types after the build.
    let lmeb_arm_precomputed = if evidence_types_owned.len() >= 6 {
        "all6".to_string()
    } else {
        let mut t = evidence_types_owned.clone();
        t.sort();
        t.join("+")
    };
    let lmeb_serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(&args);
    lmeb_run_env.benchmark_test_name  = Some("lmeb".to_string());
    lmeb_run_env.benchmark_arm        = Some(lmeb_arm_precomputed);
    lmeb_run_env.benchmark_run_serial = Some(lmeb_serial);

    // ── Build report ──────────────────────────────────────────────────────────
    let report = build_lmeb_report(
        run_id,
        run_label.clone(),
        evidence_types_owned.clone(),
        generated_at,
        encode_barrier.as_str().to_string(),
        run_config.guard_sampling_policy.as_str().to_string(),
        queries_loaded,
        &scores,
        &cache_hit_by_id_lmeb,
        &drain_lane_by_id_lmeb,
        estate_cache_lmeb.as_str().to_string(),
        scratch_posture.as_str().to_string(),
        lmeb_shape.as_str().to_string(),
        lmeb_parallel,
        Some(lmeb_run_env),
        lmeb_timing_report,
        // C10-LMEB Shape 3: estate grouping shape and group topology stats.
        lmeb_estate_shape.as_str().to_string(),
        lmeb_group_stats,
    );

    // ── Print summary ─────────────────────────────────────────────────────────
    println!("LMEB results (label={run_label}, seed={seed}):");
    println!("  queries_run:     {}", report.corpus_stats.queries_run);
    println!("  guard_excluded:  {}", report.corpus_stats.guard_excluded);
    println!("  query_count:     {}", report.aggregate.query_count);
    println!("  nDCG@10:         {:.4}", report.aggregate.ndcg_at_10);
    println!("  MRR:             {:.4}", report.aggregate.mrr);
    println!("  recall@1:        {:.4}", report.aggregate.recall_at_1);
    println!("  recall@5:        {:.4}", report.aggregate.recall_at_5);
    println!("  recall@10:       {:.4}", report.aggregate.recall_at_10);
    println!("  MAP@10:          {:.4}", report.aggregate.map_at_10);
    println!("  query_p50_s:     {:.4}", report.latency.query_p50_seconds);
    println!("  query_p95_s:     {:.4}", report.latency.query_p95_seconds);

    // ── Write report ──────────────────────────────────────────────────────────
    // `<test>-<arm>-<serial>`: LMEB's arm is the evidence-category set. All six
    // is `all6`; a narrower run names its categories, so the eight-day
    // one-of-six narrowing could not have worn a full run's filename.
    let lmeb_arm = if report.evidence_types.len() >= 6 {
        "all6".to_string()
    } else {
        let mut t = report.evidence_types.clone();
        t.sort();
        t.join("+")
    };
    let report_filename = crate_record_filename("lmeb", &lmeb_arm, &args);
    let report_path = out_dir
        .as_deref()
        .unwrap_or_else(|| Path::new("."))
        .join(&report_filename);
    write_lmeb_report(&report, &report_path)?;
    println!("report written to {}", report_path.display());

    Ok(())
}

/// answer-batch subcommand — offline answer pass for the answer-dump lanes.
///
/// Reads the header record and dispatches on its `benchmark` field:
///   - `lme-spec`      → delegates to `run_lme_spec_answer_batch` (reader-model flow).
///   - `convomem-spec` → delegates to `run_convomem_spec_answer_dump`.
///   - `membench-spec` → loops over `qa` records, runs `--answer-cmd` per record,
///     extracts the letter via `parse_answer_choice`, and writes consume-answers lines.
///
/// Twin of `runAnswerBatch` in `CLI.swift`.
fn run_answer_batch_cmd(args: &[String]) -> Result<(), String> {
    let inputs = option_value("--inputs", args)
        .ok_or("answer-batch requires --inputs <answer-inputs.jsonl>")?;
    let answer_cmd = option_value("--answer-cmd", args)
        .ok_or("answer-batch requires --answer-cmd <cmd>")?;
    let out = option_value("--out", args)
        .ok_or("answer-batch requires --out <path>")?;
    let limit: Option<usize> = parse_limit_option(args)?;
    let offset: usize = match option_value("--offset", args) {
        Some(value) => value.parse::<usize>().map_err(|_| {
            "answer-batch --offset must be a non-negative integer".to_string()
        })?,
        None => 0,
    };
    let reader_model = option_value("--reader-model", args).unwrap_or("unknown");

    // Peek at the header to dispatch the lme-spec reader-model path before
    // delegating to the shared lmeb_spec_runner dispatcher.
    let benchmark = std::fs::read_to_string(&inputs)
        .ok()
        .and_then(|raw| {
            raw.lines()
                .find(|l| !l.is_empty())
                .and_then(|first| serde_json::from_str::<serde_json::Value>(first).ok())
                .and_then(|v| v.get("benchmark").and_then(|b| b.as_str()).map(str::to_string))
        });

    if benchmark.as_deref() == Some("lme-spec") {
        let judge_model = option_value("--judge-model", args)
            .unwrap_or("gpt-4o-2024-08-06");
        return mcp_benchmarker_rs::lme_spec_answer_batch::run_lme_spec_answer_batch(
            std::path::Path::new(&inputs),
            &answer_cmd,
            std::path::Path::new(&out),
            &judge_model,
        );
    }

    if benchmark.as_deref() == Some("locomo-spec") {
        return mcp_benchmarker_rs::locomo_spec_answer_batch::run_answer_batch(
            std::path::Path::new(&inputs),
            &answer_cmd,
            std::path::Path::new(&out),
            limit,
            offset,
            reader_model,
        );
    }

    mcp_benchmarker_rs::lmeb_spec_runner::run_answer_batch(inputs, answer_cmd, out, limit, offset)
        .map_err(|e| e.description)
}

/// supersession subcommand — the supersession / contradiction lane: one
/// persistent estate, a chronologically-ingested timeline, and scoring on
/// whether the CURRENT version of a changed fact outranks its superseded
/// versions. Twin of Swift `runSupersession(_:)`.
///
/// The public benchmarks cannot ask this — they provision a fresh estate per
/// question, so nothing ever supersedes anything. See supersession_corpus.rs
/// for the design rationale and the fairness rule that governs what may be
/// scored here.
fn run_supersession(args: &[String]) -> Result<(), String> {
    // The lane-running imports live in run_and_print_supersession_posture,
    // which owns the per-posture run since the --estate-mode both split.
    use mcp_benchmarker_rs::supersession_corpus::generate_supersession_corpus_tiered;

    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20260725);
    // Minimums are the smallest values that keep the generated corpus
    // well-formed, established once here at the boundary so the generators
    // can go on trusting their inputs:
    //   --entities / --contradictions >= 0. A zero-size sub-corpus composes —
    //     an entities-only or contradictions-only run is legitimate, and
    //     --skip-contradictions already exists as a first-class flag.
    //   --versions >= 1. supersession_corpus indexes
    //     `chain_values[chain_values.len() - 1]` for the current version,
    //     which underflows the usize on the empty chain a zero produces.
    //   --k >= 1. This one does not panic, which is why it is easy to miss:
    //     supersession_runner scores `stale_ranks.filter(|r| *r <= top_k)`,
    //     and ranks are 1-based, so a cutoff of zero makes the stale-in-top-K
    //     metric identically zero — a perfect score no matter what the
    //     product did.
    let entities = validated_count("--entities", args, 40, 0)?;
    let versions = validated_count("--versions", args, 3, 1)?;
    let contradictions = validated_count("--contradictions", args, 10, 0)?;
    // MXE-CT3 P4 classes. Zero composes (a run without divergences or decoys
    // is legitimate); only negatives break the `0..count` generator loops.
    // Rejection of non-integer/negative input rides validated_count
    // (b77ec03e8 precedent). Twin of the Swift flag block.
    let divergences = validated_count("--divergences", args, 5, 0)?;
    let decoys = validated_count("--decoys", args, 5, 0)?;
    let top_k = validated_count("--k", args, 10, 1)?;
    let recall_shape = option_value("--recall-shape", args).map(str::to_string);
    if let Some(ref shape) = recall_shape {
        if !LME_RECALL_SHAPE_PRESETS.contains(&shape.as_str()) {
            return Err(format!(
                "--recall-shape must be one of: {}; got '{shape}'",
                LME_RECALL_SHAPE_PRESETS.join(", ")
            ));
        }
    }

    // --fact-layer: INTERNAL CAPABILITY CELL — structured-fact lifecycle
    // (moot_file_fact → moot_retire_fact → moot_fact_search). Exits early;
    // the standard supersession flow is skipped. Twin of the Swift branch.
    if flag_present("--fact-layer", args) {
        use mcp_benchmarker_rs::fact_layer_corpus::generate_fact_layer_corpus;
        use mcp_benchmarker_rs::fact_layer_runner::{
            run_fact_layer_cell, score_fact_layer, FactLayerRunConfig,
        };
        use mcp_benchmarker_rs::key_residue::retire_scratch_estate;
        use mcp_benchmarker_rs::longmemeval_runner::lme_guarded_teardown;

        let fact_corpus = generate_fact_layer_corpus(seed, entities, versions);
        println!(
            "[fact-layer] INTERNAL CAPABILITY CELL — corpus seed {seed}: {} fact records, {} queries",
            fact_corpus.facts.len(),
            fact_corpus.queries.len(),
        );

        // The fact-layer dump keeps its lane-fixture format (facts + queries
        // — conformance-vector source, not an estate seed): schema v1 cannot
        // express sourceless facts, so there is no seed to dump here. Only
        // the public flag name changes (vocabulary ruling 2026-08-08).
        if let Some(dump_path) = option_value("--dump-seed", args) {
            let value = serde_json::to_value(&fact_corpus)
                .map_err(|e| format!("fact-layer fixture encode failed: {e}"))?;
            let sorted = mcp_benchmarker_rs::longmemeval_scorer::sorted_json_value(&value);
            let json = serde_json::to_string_pretty(&sorted)
                .map_err(|e| format!("fact-layer fixture encode failed: {e}"))?;
            // Create the parent directory tree before writing. `std::fs::write` does
            // not create intermediate directories; a nested --dump-seed path fails
            // with ENOENT without this step.
            if let Some(parent) = std::path::Path::new(dump_path).parent()
                .filter(|p| !p.as_os_str().is_empty()) {
                std::fs::create_dir_all(parent)
                    .map_err(|e| format!("fact-layer fixture dump: cannot create parent directory: {e}"))?;
            }
            std::fs::write(dump_path, json.as_bytes())
                .map_err(|e| format!("fact-layer fixture dump write failed: {e}"))?;
            println!("[fact-layer] fixture dumped to {dump_path}");
            return Ok(());
        }

        let binary = option_value("--mootx01-binary", args)
            .or_else(|| option_value("--binary", args))
            .map(str::to_string)
            .or_else(discover_moot_binary)
            .ok_or_else(|| "mootx01 binary not found. Pass --binary <path>.".to_string())?;

        // C1: parse --shape; default is disk (SQLite). Same parse as the LME lane.
        let fl_shape = match option_value("--shape", args).unwrap_or("disk") {
            "ram"  => mcp_benchmarker_rs::longmemeval_runner::LmeShape::Ram,
            "disk" => mcp_benchmarker_rs::longmemeval_runner::LmeShape::Disk,
            s => return Err(format!("--shape must be 'disk' or 'ram'; got '{s}'")),
        };

        // Fact-layer cell: always ephemeral. Structured-fact verbs are synchronous
        // and do not queue embedding jobs, but the estate still needs cleanup.
        let fl_posture = ScratchEstatePosture::EncryptedEphemeral;
        let fl_scratch =
            mcp_benchmarker_rs::supersession_runner::supersession_scratch_dir(seed, fl_posture)
                .map_err(|e| e.description.clone())?;
        let fl_config = FactLayerRunConfig {
            moot_binary_path: binary.clone(),
            seed,
            fact_count: entities,
            versions_per_fact: versions,
            scratch_dir: fl_scratch.clone(),
            posture: fl_posture,
            shape: fl_shape,
        };
        let run_result = run_fact_layer_cell(&fact_corpus, &fl_config);
        if let Err(e) = retire_scratch_estate(&fl_scratch, lme_guarded_teardown) {
            eprintln!("[fact-layer] teardown warning: {}", e.description);
        }
        let outcome = run_result.map_err(|e| e.description)?;
        let scores = score_fact_layer(&outcome.query_results);

        println!("[fact-layer] INTERNAL CAPABILITY CELL — run complete");
        println!("  queries scored:           {}", scores.query_count);
        println!(
            "  current-fact found rate:  {:.4}   <- current version appeared in moot_fact_search results",
            scores.current_found_rate
        );
        println!(
            "  current-fact win rate:    {:.4}   <- current outranked every surfaced retired version",
            scores.current_win_rate
        );
        println!(
            "  mean retired per query:   {:.2}   <- retired fact UUIDs surfaced by search (0.0 = none)",
            scores.mean_retired_per_query
        );
        println!("  query p50:                {:.1} ms", scores.p50_latency_seconds * 1000.0);
        println!(
            "  ingest elapsed:           {:.2} s <- Steps 1+2 (file + retire); no drain/dream in this cell",
            outcome.ingest_elapsed_seconds
        );
        println!("  unfiled facts:            {}     <- moot_file_fact calls that returned no parseable UUID",
                 outcome.unfiled_fact_ids.len());
        println!();
        println!("NOTE: This cell is NOT a comparative measurement. It measures the");
        println!("structured-fact lifecycle (moot_file_fact / moot_retire_fact /");
        println!("moot_fact_search) end-to-end. No external system is scored here.");
        println!("cell_type: internal_capability");
        println!();

        // C7: emit minimal JSON report alongside the text summary.
        // Twin of the Swift FactLayerReport struct in FactLayerRunner.swift.
        // Identity block only; accuracy files carry no timing columns.
        let run_env = mcp_benchmarker_rs::run_environment::IdentityEnvironment::collect(
            Some(binary.as_str()));
        let report = serde_json::json!({
            "cell_type": "internal_capability",
            "backend_shape": fl_shape.as_str(),
            "query_count": scores.query_count,
            "current_found_rate": scores.current_found_rate,
            "current_win_rate": scores.current_win_rate,
            "mean_retired_per_query": scores.mean_retired_per_query,
            "unfiled_fact_count": outcome.unfiled_fact_ids.len(),
            "run_environment": run_env,
        });
        println!("{}", serde_json::to_string_pretty(&report)
            .unwrap_or_else(|e| format!("{{\"error\": \"{e}\"}}"))
        );
        return Ok(());
    }

    let corpus = generate_supersession_corpus_tiered(
        seed, entities, versions, contradictions, divergences, decoys);
    println!(
        "[supersession] corpus seed {seed}: {} records, {} chains, {} contradiction pairs, {} divergence pairs, {} decoys",
        corpus.records.len(),
        corpus.queries.len(),
        corpus.contradictions.len(),
        corpus.divergences.len(),
        corpus.decoys.len(),
    );

    // C1 --shape: selects persistence backend.
    // "ram" passes --in-memory to serve so the estate lives in memory.
    let bench_shape = {
        use mcp_benchmarker_rs::longmemeval_runner::LmeShape;
        match option_value("--shape", args).unwrap_or("disk") {
            "disk" => LmeShape::Disk,
            "ram"  => LmeShape::Ram,
            other  => return Err(format!("--shape must be 'disk' or 'ram'; got '{other}'")),
        }
    };
    // C5 --guard-sample: degeneracy guard sampling policy.
    let guard_sampling_policy =
        mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
            option_value("--guard-sample", args)
        ).map_err(|e| e)?;
    // C7 --run-mode: annotates the scorecard; not a measurement input.
    let run_mode = option_value("--run-mode", args).unwrap_or("unspecified").to_string();

    // --dump-seed <path>: write the seed the batch path would import —
    // seed-file schema v1 exactly (dump output == importer input == the
    // third-party interchange artifact), in the chronological file order the
    // lane ingests — and exit without running anything. Cross-leg
    // reproducibility: both legs' emitters are byte-identical
    // (conformance/seed_export_vectors.json), so diffing the two dumps
    // still proves leg agreement.
    if let Some(dump_path) = option_value("--dump-seed", args) {
        use mcp_benchmarker_rs::supersession_runner::supersession_seed_records;
        let mut ordered: Vec<&mcp_benchmarker_rs::supersession_corpus::SupersessionRecord> =
            corpus.records.iter().collect();
        ordered.sort_by(|a, b| {
            a.event_time.cmp(&b.event_time).then_with(|| a.id.cmp(&b.id))
        });
        let records = supersession_seed_records(&ordered);
        let data = mcp_benchmarker_rs::seed_export::emit_seed_json(
            &format!("supersession-{seed}"), &records, &[], &[]);
        // Create the parent directory tree before writing. `std::fs::write` does
        // not create intermediate directories; a nested --dump-seed path fails
        // with ENOENT without this step.
        if let Some(parent) = std::path::Path::new(dump_path).parent()
            .filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("seed dump: cannot create parent directory: {e}"))?;
        }
        std::fs::write(dump_path, &data)
            .map_err(|e| format!("seed dump write failed: {e}"))?;
        println!("[supersession] seed dumped to {dump_path}");
        return Ok(());
    }

    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| "mootx01 binary not found. Pass --binary <path>.".to_string())?;

    // Ephemeral by DEFAULT: temporal in-memory key, zero key residue — the
    // posture the standing no-orphaned-keys rule requires of a lane that
    // provisions estates. --estate-mode exists so the two postures can be
    // compared; --estate-mode both runs both postures sequentially against
    // the same corpus and prints a delta section. Twin of the Swift CLI.
    let raw_estate_mode = option_value("--estate-mode", args);
    if raw_estate_mode == Some("both") {
        // Both mode: corpus generated once above; each posture provisions
        // its own scratch estate, runs fully, and tears down before the
        // next run starts. The delta section compares the two scorecards.
        let unencrypted = run_and_print_supersession_posture(
            &corpus, args, &binary, seed, top_k, &recall_shape,
            entities, versions, contradictions,
            ScratchEstatePosture::PlaintextTransient, Some("unencrypted"),
            bench_shape, guard_sampling_policy, &run_mode)?;
        let encrypted = run_and_print_supersession_posture(
            &corpus, args, &binary, seed, top_k, &recall_shape,
            entities, versions, contradictions,
            ScratchEstatePosture::EncryptedEphemeral, Some("encrypted"),
            bench_shape, guard_sampling_policy, &run_mode)?;
        let delta = mcp_benchmarker_rs::supersession_runner::compute_supersession_estate_delta(&unencrypted, &encrypted);
        print_supersession_estate_delta(&delta);
        return Ok(());
    }
    let posture = if raw_estate_mode.is_none() {
        ScratchEstatePosture::EncryptedEphemeral
    } else {
        parse_estate_mode(args)?
    };
    run_and_print_supersession_posture(
        &corpus, args, &binary, seed, top_k, &recall_shape,
        entities, versions, contradictions, posture, None,
        bench_shape, guard_sampling_policy, &run_mode)?;
    Ok(())
}

/// Formats and prints the estate-mode comparison delta to stdout.
/// Called only when --estate-mode both is used. The section header is fixed
/// by spec: "estate-mode delta (encrypted \u{2212} unencrypted):". Twin of
/// Swift `printSupersessionEstateDelta`.
fn print_supersession_estate_delta(
    delta: &mcp_benchmarker_rs::supersession_runner::SupersessionEstateDelta,
) {
    println!("estate-mode delta (encrypted \u{2212} unencrypted):");
    println!("  CURRENT-OVER-STALE rate:  {:+.4}", delta.current_win_rate_diff);
    println!("  current found rate:       {:+.4}", delta.current_found_rate_diff);
    println!("  mean stale in top-k:      {:+.2}", delta.mean_stale_in_top_k_diff);
    println!("  mean rank of current:     {:+.2}", delta.mean_current_rank_diff);
    match delta.query_p50_percent_diff {
        Some(pct) => println!(
            "  query p50:                {:+.1} ms ({:+.1}%)",
            delta.query_p50_diff_ms, pct
        ),
        None => println!("  query p50:                {:+.1} ms", delta.query_p50_diff_ms),
    }
    println!();
}

/// Provisions a scratch estate for `posture`, runs the full supersession
/// lane against `corpus`, prints the complete scorecard section (including
/// contradiction sweep and structured tier when they ran), retires the
/// scratch estate, and returns the aggregate scores for delta computation.
/// `posture_label` is appended to the run-complete banner when Some —
/// single-posture runs pass None to preserve the existing output shape.
/// Twin of Swift `runAndPrintSupersessionPosture`.
#[allow(clippy::too_many_arguments)]
fn run_and_print_supersession_posture(
    corpus: &mcp_benchmarker_rs::supersession_corpus::SupersessionCorpus,
    args: &[String],
    binary: &str,
    seed: u64,
    top_k: usize,
    recall_shape: &Option<String>,
    entities: usize,
    versions: usize,
    contradictions: usize,
    posture: ScratchEstatePosture,
    posture_label: Option<&str>,
    bench_shape: mcp_benchmarker_rs::longmemeval_runner::LmeShape,
    guard_sampling_policy: mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy,
    run_mode: &str,
) -> Result<mcp_benchmarker_rs::supersession_runner::SupersessionScores, String> {
    use mcp_benchmarker_rs::supersession_runner::{
        run_supersession_lane, score_supersession, supersession_scratch_dir,
        SupersessionRunConfig,
    };

    // True when the run WILL dream (the default); --skip-dream turns it off.
    let dream_before_queries = !flag_present("--skip-dream", args);
    // C15: deviation banner — printed before any scorecard when --skip-dream
    // is active, so every output is self-labelled as a virgin-estate cell.
    if !dream_before_queries {
        eprintln!("╔══════════════════════════════════════════════════════════════════╗");
        eprintln!("║  DEVIATION NOTICE — --skip-dream is active                     ║");
        eprintln!("║  This run measures the VIRGIN ESTATE (no matrix priors).       ║");
        eprintln!("║  Do NOT compare this cell against dreamed-estate figures.      ║");
        eprintln!("║  Published numbers MUST name estate state explicitly.          ║");
        eprintln!("╚══════════════════════════════════════════════════════════════════╝");
    }

    let binary = binary.to_string();
    let scratch =
        supersession_scratch_dir(seed, posture).map_err(|e| e.description.clone())?;
    let config = SupersessionRunConfig {
        moot_binary_path: binary,
        seed,
        entity_count: entities,
        versions_per_chain: versions,
        contradiction_count: contradictions,
        top_k,
        recall_shape: recall_shape.clone(),
        scratch_dir: scratch.clone(),
        posture,
        contradiction_sweep: !flag_present("--skip-contradictions", args),
        dream_before_queries,
        structured_tier: flag_present("--structured-tier", args),
        // Batch by default (ruling 8D5B8053); `live` is the retained slow lane.
        seed_path: mcp_benchmarker_rs::seed_export::SeedPathMode::parse(
            option_value("--seed-path", args))?,
        lane_capture: false,
        shape: bench_shape,
        guard_sampling_policy,
        bench_clock_epoch: None,
    };
    let run_outcome = run_supersession_lane(corpus, &config);
    // Retirement, not bare teardown: verifies zero residual key material
    // after the estate dies — on the error path too, so a failed run cannot
    // strand an estate.
    if let Err(e) = mcp_benchmarker_rs::key_residue::retire_scratch_estate(
        &scratch,
        mcp_benchmarker_rs::longmemeval_runner::lme_guarded_teardown,
    ) {
        eprintln!("[supersession] teardown warning: {}", e.description);
    }
    let outcome = run_outcome.map_err(|e| e.description)?;
    let scores = score_supersession(&outcome.query_results);
    // Compute guard stats from the raw (unfiltered) results for the report.
    let guard_refused_count = outcome.query_results.iter().filter(|r| !r.guard_healthy).count();
    let guard_healthy_count = outcome.query_results.len() - guard_refused_count;

    match posture_label {
        Some(label) => println!("[supersession] run complete — {label}"),
        None => println!("[supersession] run complete"),
    }
    println!("  chains scored:            {}", scores.query_count);
    println!("  guard healthy:            {guard_healthy_count}");
    println!("  guard refused:            {guard_refused_count}");
    println!(
        "  CURRENT-OVER-STALE rate:  {:.4}   <- the headline: current outranks every superseded version",
        scores.current_win_rate,
    );
    println!("  current found rate:       {:.4}", scores.current_found_rate);
    println!(
        "  mean stale in top-{}:      {:.2}   <- outdated facts a consumer would paste into a prompt",
        top_k, scores.mean_stale_in_top_k,
    );
    println!("  mean rank of current:     {:.2}", scores.mean_current_rank);
    println!("  query p50:                {:.1} ms", scores.p50_latency_seconds * 1000.0);
    println!(
        "  recall shape:             {}",
        recall_shape.as_deref().unwrap_or("none (moot_memory_search)"),
    );
    println!("  guard_sampling:           {}", guard_sampling_policy.as_str());
    println!("  shape:                    {}", bench_shape.as_str());
    println!("  run_mode:                 {run_mode}");
    // C15: stamp every scorecard with skip_dream field so no published number
    // can silently come from a skipped-dream run (virgin vs dreamed confusion).
    println!(
        "  skip_dream:               {}",
        if config.dream_before_queries { "false" } else { "true  <- DEVIATION: virgin estate, no matrix priors" }
    );
    // Estate state is part of the measurement's identity: matrix-steering
    // presets only have signal on a dreamed estate.
    println!(
        "  estate state:             {}",
        if config.dream_before_queries {
            "dreamed (matrix priors live)"
        } else {
            "virgin (no matrix priors)"
        },
    );

    // Contradiction sweep (scored behaviour 3). Detection of the planted,
    // recency-unresolvable pairs is the scored figure. Pairs flagged outside
    // the planted set are context, not error: superseded chain versions
    // genuinely conflict too — they are just resolvable by recency.
    if let Some(c) = outcome.contradiction {
        let any_rate = if c.planted_count > 0 {
            c.detected_any_tier as f64 / c.planted_count as f64
        } else {
            0.0
        };
        let prop_rate = if c.planted_count > 0 {
            c.detected_proposed as f64 / c.planted_count as f64
        } else {
            0.0
        };
        println!("  contradiction sweep (moot_hunt_contradictions):");
        println!("    planted pairs:            {}", c.planted_count);
        println!(
            "    detected (any tier):      {:.4}  ({}/{})",
            any_rate, c.detected_any_tier, c.planted_count
        );
        println!(
            "    detected as PROPOSED:     {:.4}  ({}/{})",
            prop_rate, c.detected_proposed, c.planted_count
        );
        println!(
            "    flagged outside planted:  {}   <- includes superseded-chain conflicts (resolvable by recency)",
            c.flagged_outside_planted
        );
        println!("    hunt wall time:           {:.1} s", c.hunt_seconds);
    }

    // Typed proving tier. `proven planted` is the headline (target 10/10
    // where the lexical baseline was 0/10); for `proven outside planted`
    // ANY non-zero value is a false proof, not context — the chains must
    // resolve as historical succession, and their count shows up on the
    // historical line instead. Twin of the Swift CLI block.
    if let Some(s) = &outcome.structured {
        let proven_rate = if s.planted_count > 0 {
            s.proven_planted as f64 / s.planted_count as f64
        } else {
            0.0
        };
        println!("  structured tier (typed conflict projection, moot_lens_contradiction):");
        println!("    planted pairs:            {}", s.planted_count);
        println!(
            "    proven planted:           {:.4}  ({}/{})   <- typed lane vs the 0/10 lexical baseline",
            proven_rate, s.proven_planted, s.planted_count
        );
        println!(
            "    proven outside planted:   {}   <- MUST be 0; any value here is a false proof",
            s.proven_outside_planted
        );
        println!("    proven reported:          {}", s.proven_reported);
        println!(
            "    historical reported:      {}   <- the chains, resolved by time, not proof",
            s.historical_reported
        );
        println!(
            "    coverage:                 {}/{}",
            s.coverage_projected, s.coverage_scanned
        );
        println!("    tier wall time:           {:.1} s", s.tier_seconds);
    }

    // MXE-CT3 P4 tiered scoring. Per-tier recall comes from single-tier
    // purpose runs (read-only searches); the exactly-once and timing figures
    // come from the tier=all synthesis digest. The decoy split is deliberate:
    // the must-be-0 row is a hard failure, the known-limitation row is the
    // unit-equivalence gap in the lexical digit cue, reported but not failed.
    // Twin of the Swift CLI block.
    if let Some(t) = &outcome.tiered {
        let t2_rate = if t.tier2_planted_count > 0 {
            t.tier2_detected as f64 / t.tier2_planted_count as f64
        } else {
            0.0
        };
        let t3_rate = if t.tier3_planted_count > 0 {
            t.tier3_detected as f64 / t.tier3_planted_count as f64
        } else {
            0.0
        };
        println!("  tiered scoring (moot_hunt_contradictions tier=1|2|3 purpose runs):");
        println!(
            "    tier 2 detected:          {:.4}  ({}/{})   <- word-valued plants in the tier=2 purpose run",
            t2_rate, t.tier2_detected, t.tier2_planted_count
        );
        println!(
            "    tier 3 detected:          {:.4}  ({}/{})   <- digit-divergence plants in the tier=3 purpose run",
            t3_rate, t.tier3_detected, t.tier3_planted_count
        );
        if let (Some(planted1), Some(detected1)) = (t.tier1_planted_count, t.tier1_detected) {
            let t1_rate = if planted1 > 0 {
                detected1 as f64 / planted1 as f64
            } else {
                0.0
            };
            println!(
                "    tier 1 detected:          {:.4}  ({}/{})   <- planted pairs proven typed (tier=1 after fact filing)",
                t1_rate, detected1, planted1
            );
        }
        println!(
            "    decoy hits (must be 0):   {}   <- marker/distinct-entity decoys flagged at any tier or PROPOSED",
            t.decoy_hits.hard
        );
        println!(
            "    decoy known-limitation:   {}   <- unit-equivalent pairs firing tier 3 (digit cue cannot equate 90s and 1.5min)",
            t.decoy_hits.known_limitation
        );
        println!(
            "    tier inflation:           {}   <- planted pairs double-reported across synthesis tier sections",
            t.tier_inflation
        );
        let mut timing = format!(
            "    purpose lane seconds:     tier2={:.3} tier3={:.3}",
            t.tier2_purpose_seconds, t.tier3_purpose_seconds
        );
        if let Some(t1s) = t.tier1_purpose_seconds {
            timing.push_str(&format!(" tier1={t1s:.3}"));
        }
        println!("{timing}");
        if let Some(wall) = t.synthesis_wall_seconds {
            println!(
                "    synthesis wall:           {wall:.3} s   <- report's own synthesis_wall_seconds line"
            );
        }
    }
    Ok(scores)
}

// ─────────────────────────────────────────────────────────────────────────────
// Replay subcommand
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the supersession lane N times with the same seed to prove end-to-end
/// replay determinism. Each run provisions a fresh scratch estate, regenerates
/// the corpus from the seed, and scores the full lane. After all runs complete,
/// the deterministic-eligible outcome fields are compared and a per-field
/// MATCH/DRIFT table is printed. Exits 0 when all fields match; exits 1 on
/// any drift (via `std::process::exit` after printing the verdict, so the
/// table output is not lost).
///
/// Twin of Swift `runReplay(_:)` in CLI.swift.
fn run_replay(args: &[String]) -> Result<(), String> {
    use mcp_benchmarker_rs::longmemeval_runner::{discover_moot_binary, LME_RECALL_SHAPE_PRESETS};
    use mcp_benchmarker_rs::supersession_corpus::generate_supersession_corpus;
    use mcp_benchmarker_rs::supersession_runner::{
        run_supersession_lane, score_supersession, supersession_scratch_dir,
        SupersessionRunConfig,
    };
    use mcp_benchmarker_rs::key_residue::retire_scratch_estate;
    use mcp_benchmarker_rs::longmemeval_runner::lme_guarded_teardown;
    use mcp_benchmarker_rs::replay_lane::{
        compare_replay_fingerprints, diff_lane_captures, print_replay_field_table,
        render_lane_diff_table, LaneCapture, ReplayFingerprint,
    };

    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20260725);
    // Same minimum contract as run_supersession — see that function's comments
    // for the per-option rationale.
    let entities      = validated_count("--entities",       args, 40, 0)?;
    let versions      = validated_count("--versions",       args, 3,  1)?;
    let contradictions = validated_count("--contradictions", args, 10, 0)?;
    let top_k         = validated_count("--k",              args, 10, 1)?;
    // --runs minimum is 2: a single run cannot be compared against anything.
    let runs          = validated_count("--runs",           args, 2,  2)?;

    let recall_shape = option_value("--recall-shape", args).map(str::to_string);
    if let Some(ref shape) = recall_shape {
        if !LME_RECALL_SHAPE_PRESETS.contains(&shape.as_str()) {
            return Err(format!(
                "--recall-shape must be one of: {}; got '{shape}'",
                LME_RECALL_SHAPE_PRESETS.join(", ")
            ));
        }
    }

    // --estate-mode: "unencrypted" and "encrypted" accepted; "both" is
    // explicitly rejected. Replay compares runs of the SAME posture — running
    // two different postures would be a different experiment (like
    // --estate-mode both in supersession) and would destroy the determinism
    // claim by introducing a variable that is not the seed.
    let raw_estate_mode = option_value("--estate-mode", args);
    if raw_estate_mode == Some("both") {
        return Err(
            "--estate-mode both is not accepted by the replay subcommand: \
             replay compares runs of the same posture, not two postures. \
             Pass --estate-mode unencrypted or --estate-mode encrypted."
                .to_string(),
        );
    }
    let posture = if raw_estate_mode.is_none() {
        ScratchEstatePosture::EncryptedEphemeral   // default: encrypted, zero residue
    } else {
        parse_estate_mode(args)?
    };

    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| "mootx01 binary not found. Pass --binary <path>.".to_string())?;

    println!(
        "[replay] seed {seed}: {runs} run(s), entities {entities}, \
         versions {versions}, contradictions {contradictions}"
    );

    let lane_capture_requested = flag_present("--lane-capture", args);
    let mut fingerprints: Vec<ReplayFingerprint> = Vec::with_capacity(runs);
    // Parallel to fingerprints: retains per-run LaneCapture when --lane-capture is set.
    // Swift always retains captures; this brings Rust replay to parity.
    let mut lane_captures: Vec<Option<LaneCapture>> = Vec::with_capacity(runs);

    for run_index in 1..=runs {
        // Corpus is regenerated from the same seed on every iteration.
        // Corpus generation is a pure function of the seed, so the same
        // corpus will always be produced — but regenerating per run means
        // the generation step is INSIDE the replayed surface: any
        // non-determinism in the generator (e.g. a leaked clock source)
        // would be caught here rather than hidden by sharing one instance.
        let corpus = generate_supersession_corpus(seed, entities, versions, contradictions);

        let scratch = supersession_scratch_dir(seed, posture)
            .map_err(|e| e.description.clone())?;

        let config = SupersessionRunConfig {
            moot_binary_path: binary.clone(),
            seed,
            entity_count: entities,
            versions_per_chain: versions,
            contradiction_count: contradictions,
            top_k,
            recall_shape: recall_shape.clone(),
            scratch_dir: scratch.clone(),
            posture,
            contradiction_sweep: !flag_present("--skip-contradictions", args),
            dream_before_queries: !flag_present("--skip-dream", args),
            structured_tier: flag_present("--structured-tier", args),
            // Replay proves determinism of whichever seed path it is pointed
            // at; batch (the default) is the shipping pipeline.
            seed_path: mcp_benchmarker_rs::seed_export::SeedPathMode::parse(
                option_value("--seed-path", args))?,
            lane_capture: flag_present("--lane-capture", args),
            // C1/C5: replay mirrors the shape and guard policy the caller
            // configures so determinism is proved for the actual pipeline flags.
            shape: {
                use mcp_benchmarker_rs::longmemeval_runner::LmeShape;
                match option_value("--shape", args).unwrap_or("disk") {
                    "disk" => LmeShape::Disk,
                    "ram"  => LmeShape::Ram,
                    other  => return Err(format!("--shape must be 'disk' or 'ram'; got '{other}'")),
                }
            },
            guard_sampling_policy:
                mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
                    option_value("--guard-sample", args)
                ).map_err(|e| e)?,
            // Replay pins the clock so same seed → same filedAt and temporal
            // scores across every run; the determinism proof would be vacuous
            // without this. Non-replay runs (run_supersession) leave it None.
            bench_clock_epoch: Some(
                mcp_benchmarker_rs::scratch_posture::bench_clock_epoch_iso(seed)
            ),
        };

        let run_result = run_supersession_lane(&corpus, &config);
        // Retire the scratch estate before the next run starts, regardless of
        // whether the lane succeeded or failed. Retirement (not bare teardown)
        // verifies zero residual key material when the estate dies.
        if let Err(e) = retire_scratch_estate(&scratch, lme_guarded_teardown) {
            eprintln!("[replay] teardown warning (run {run_index}): {}", e.description);
        }
        let outcome = run_result.map_err(|e| e.description)?;
        let scores  = score_supersession(&outcome.query_results);
        let fp      = ReplayFingerprint::new(&scores, &outcome);
        fingerprints.push(fp);
        // Move lane_capture out of outcome after fingerprint is built.
        lane_captures.push(outcome.lane_capture);

        println!(
            "[replay] run {run_index}/{runs}: {} chains scored, win rate {:.4}",
            scores.query_count, scores.current_win_rate
        );
    }

    // Compare run 1's fingerprint against each later run.
    // - For N=2: one comparison, one table.
    // - For N>2: report the first drifting run's table. If no run drifts,
    //   report the last comparison (all-MATCH table, showing every field
    //   was checked).
    let baseline = &fingerprints[0];
    let mut table_run_index = runs; // 1-based index of the run shown in the table
    let mut table_diffs: Vec<mcp_benchmarker_rs::replay_lane::ReplayFieldDiff> = Vec::new();
    let mut any_drift = false;

    for i in 1..runs {
        let c_diffs = compare_replay_fingerprints(baseline, &fingerprints[i]);
        if !c_diffs.is_empty() && !any_drift {
            // First drifting run: pin this one for the table.
            any_drift        = true;
            table_run_index  = i + 1;   // convert 0-based loop index to 1-based run number
            table_diffs      = c_diffs;
        } else if !any_drift && i == runs - 1 {
            // No drift yet, last candidate: use it for the all-MATCH table.
            table_diffs = c_diffs;  // will be empty (all MATCH)
        }
    }

    print_replay_field_table(
        baseline,
        &fingerprints[table_run_index - 1],
        &table_diffs,
        table_run_index,
        seed,
        runs,
    );

    // Lane-capture diff: printed when --lane-capture was set, matching Swift replay
    // parity. Uses the same baseline/candidate pair selected for the field table.
    if lane_capture_requested {
        let baseline_lc = lane_captures[0].as_ref();
        let candidate_lc = lane_captures[table_run_index - 1].as_ref();
        if let (Some(bl), Some(cl)) = (baseline_lc, candidate_lc) {
            let diffs = diff_lane_captures(bl, cl);
            print!("{}", render_lane_diff_table(
                bl, cl, &diffs, "run 1", &format!("run {table_run_index}"),
            ));
        }
    }

    // Exit 1 on drift. All output has been printed before this point, so
    // process::exit does not truncate the report. Uses process::exit rather
    // than returning Err so main does not prepend a spurious "error:" line to
    // the already-printed verdict. Twin of Swift exit(1) in runReplay.
    if any_drift {
        std::process::exit(1);
    }
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Journey subcommand
// ─────────────────────────────────────────────────────────────────────────────

/// Handles the `journey` subcommand: generates the two sub-corpora
/// (PRECISE-MISS, VAGUE-NARROW), and either dumps the fixture
/// (`--dump-seed`) or runs the live lane against a served mootx01 binary.
/// Twin of Swift `runJourney(_:)`.
fn run_journey(args: &[String]) -> Result<(), String> {
    use mcp_benchmarker_rs::journey_corpus::{generate_journey_corpus, JourneyCorpus};
    use mcp_benchmarker_rs::journey_runner::{
        build_journey_report, journey_summary_text, run_journey_lane, write_journey_report,
        JourneyEstateShape, JourneyRunConfig,
    };
    use mcp_benchmarker_rs::key_residue::retire_scratch_estate;
    use mcp_benchmarker_rs::longmemeval_runner::{lme_guarded_teardown, lme_scratch_dir};

    let seed: u64 = option_value("--seed", args)
        .unwrap_or("20260725")
        .parse()
        .map_err(|e| format!("--seed: {e}"))?;

    // C1 (benchmark reset 2026-08-13): the RAM shape is the natural fit for
    // the journey lane's small synthetic estates.
    let shape = match option_value("--shape", args).unwrap_or("ram") {
        "disk" => JourneyEstateShape::Disk,
        "ram"  => JourneyEstateShape::Ram,
        other  => return Err(format!(
            "--shape '{}' is not recognised; accepted values: disk, ram", other)),
    };
    // Same boundary rule as run_supersession:
    //   --precise-miss-count / --cluster-count >= 0. Either sub-corpus may be
    //     empty — a clusters-only or scenarios-only journey composes.
    //   --members-per-cluster >= 2. journey_corpus documents the precondition
    //     at its generator signature and enforces nothing: it picks the
    //     answer-carrying member with `rng.next_u64() % members_per_cluster`,
    //     which divides by zero at 0. One member above that clears the panic
    //     but leaves a cluster with nothing to narrow among, which is the
    //     entire point of the VAGUE-NARROW lane.
    let precise_miss_count = validated_count("--precise-miss-count", args, 20, 0)?;
    let cluster_count = validated_count("--cluster-count", args, 10, 0)?;
    let members_per_cluster = validated_count("--members-per-cluster", args, 6, 2)?;

    let corpus: JourneyCorpus =
        generate_journey_corpus(seed, precise_miss_count, cluster_count, members_per_cluster);

    // --dump-seed <path>: write the generated journey fixture as sorted
    // pretty JSON and exit without running a live product. This dump is the
    // lane fixture (timeline + queries + expectations — conformance-vector
    // source), NOT an estate seed: the journey lane has no live seed path in
    // this build. Only the public flag name changed (vocabulary ruling
    // 2026-08-08); the cross-leg conformance diff of the two legs' dumps is
    // unchanged.
    if let Some(dump_path) = option_value("--dump-seed", args) {
        let value = serde_json::to_value(&corpus)
            .map_err(|e| format!("fixture encode failed: {e}"))?;
        let sorted = mcp_benchmarker_rs::longmemeval_scorer::sorted_json_value(&value);
        let json = serde_json::to_string_pretty(&sorted)
            .map_err(|e| format!("fixture encode failed: {e}"))?;
        // Create the parent directory tree before writing. `std::fs::write` does
        // not create intermediate directories; a nested --dump-seed path fails
        // with ENOENT without this step.
        if let Some(parent) = std::path::Path::new(dump_path).parent()
            .filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("journey fixture dump: cannot create parent directory: {e}"))?;
        }
        std::fs::write(dump_path, json.as_bytes())
            .map_err(|e| format!("fixture dump write failed: {e}"))?;
        println!("[journey] fixture dumped to {dump_path}");
        return Ok(());
    }

    println!(
        "[journey] corpus seed {seed}: {} PRECISE-MISS scenarios, {} VAGUE-NARROW clusters \
         ({} members each), shape {}",
        corpus.precise_miss.scenarios.len(),
        corpus.vague_narrow.clusters.len(),
        corpus.vague_narrow.members_per_cluster,
        shape.as_str(),
    );

    // ── Live run ──────────────────────────────────────────────────────────
    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| "mootx01 binary not found. Pass --binary <path>.".to_string())?;

    // Rank cutoff. Ranks are 1-based, so a cutoff below 1 makes every "found"
    // metric identically zero while still labelling the report as measured —
    // the same trap the supersession lane documents at its own --k.
    let top_k = validated_count("--k", args, 10, 1)?;

    // Bare parseEstateMode call (matches the Swift `journey` call site
    // exactly, unlike run_supersession which overrides the default):
    // parse_estate_mode's own internal default is "unencrypted"
    // (PlaintextTransient) when --estate-mode is absent.
    let posture = parse_estate_mode(args)?;

    let scratch = lme_scratch_dir(seed, 0, posture).map_err(|e| e.description)?;

    let config = JourneyRunConfig {
        seed,
        moot_binary_path: binary.clone(),
        scratch_dir: scratch.clone(),
        posture,
        shape,
        top_k,
    };

    let run_outcome = run_journey_lane(&corpus, &config);
    // Retirement, not bare teardown: verifies zero residual key material
    // after the estate dies — on the error path too, so a failed run cannot
    // strand an estate. Rust has no `defer`, so teardown runs unconditionally
    // here before the outcome's `?` propagates any lane error.
    if let Err(e) = retire_scratch_estate(&scratch, lme_guarded_teardown) {
        eprintln!("[journey] teardown warning: {}", e.description);
    }
    let outcome = run_outcome.map_err(|e| e.description)?;

    let run_mode = option_value("--run-mode", args).unwrap_or("unspecified");
    let run_env_journey = mcp_benchmarker_rs::run_environment::RunEnvironment::collect_with_run_mode(
        Some(&binary), run_mode);
    let report = build_journey_report(
        &corpus,
        &outcome,
        &config,
        run_env_journey,
    );

    // `<test>-<arm>-<serial>`: the arm is the backend shape. Disk and RAM are
    // separate records — the difference between them is a reported figure, so
    // one must never occupy the other's name.
    let out_dir = option_value("--out", args).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    let serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(args);
    let record_name =
        mcp_benchmarker_rs::record_writer::record_filename("journey", shape.as_str(), &serial, "", "json");
    let record_path = out_dir.join(&record_name);
    write_journey_report(&report, &record_path)?;
    mcp_benchmarker_rs::record_writer::append_to_ledger(
        &format!(
            "journey\t{}\t{record_name}\tprecise_miss={}\tvague_narrow={}",
            shape.as_str(),
            outcome.precise_miss.len(),
            outcome.vague_narrow.len(),
        ),
        &out_dir.join("records.tsv"),
    )?;

    print!("{}", journey_summary_text(&report));
    println!("report written to {}", record_path.display());

    Ok(())
}

/// timing subcommand: C2 write/ingest timing lane (benchmark reset 2026-08-13).
///
/// Options (accept both Rust-native --binary and Swift-twin --mootx01-binary):
///   --binary / --mootx01-binary  path to the mootx01 binary (auto-discovered)
///   --seed N                     corpus seed (default 20260813)
///   --repeats k                  measured writes per column per checkpoint (default 5)
///   --out <dir>                  report output directory (default: current dir)
///   --run-mode quiet|contended   machine posture for the report
///
/// Twin of Swift `runTiming(_:)` in TimingLaneRunner.swift.
/// A comma-separated ascending list of positive sizes, or a usage error.
///
/// The list must ASCEND because the landscape is built monotonically — each
/// segment starts where the previous ended, so a descending entry would ask
/// for a negative delta. Equal neighbours are rejected for the same reason:
/// a zero-row segment is a checkpoint that measures nothing.
/// Twin of Swift `validatedAscendingSizes`.
fn validated_ascending_sizes(
    name: &str,
    args: &[String],
    default_value: &[usize],
) -> Result<Vec<usize>, String> {
    let Some(raw) = option_value(name, args) else {
        return Ok(default_value.to_vec());
    };
    let mut sizes: Vec<usize> = Vec::new();
    for field in raw.split(',') {
        let field = field.trim();
        let value: usize = field
            .parse()
            .map_err(|_| format!("{name} entries must be positive integers; got '{field}'"))?;
        if value == 0 {
            return Err(format!("{name} entries must be positive integers; got '{field}'"));
        }
        if let Some(&last) = sizes.last() {
            if value <= last {
                return Err(format!(
                    "{name} must ascend — each size starts where the previous ended; \
                     got {value} after {last}"
                ));
            }
        }
        sizes.push(value);
    }
    if sizes.is_empty() {
        return Err(format!("{name} must list at least one size; got '{raw}'"));
    }
    Ok(sizes)
}

fn run_timing(args: &[String]) -> Result<(), String> {
    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "could not find mootx01 binary; pass --binary <path> or set $MOOTX01_BINARY"
                .to_string()
        })?;
    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_260_813_u64);
    let repeats = validated_count("--repeats", args, 5, 1)?;
    let out_dir = option_value("--out", args).map(PathBuf::from);
    if let Some(ref d) = out_dir {
        std::fs::create_dir_all(d)
            .map_err(|e| format!("could not create output directory '{}': {}", d.display(), e))?;
    }
    let run_mode = option_value("--run-mode", args)
        .unwrap_or("unspecified")
        .to_string();
    // --sizes: override the landscape checkpoints. The published landscape is
    // 2k/10k/100k, and a run at that scale ingests 100,000 rows — too heavy to
    // prove the lane mechanically works. `--sizes 100,200` exercises every code
    // path in seconds. Sizes must ASCEND: each segment starts where the
    // previous ended, so a descending list would ask for a negative delta.
    // Twin of Swift `validatedAscendingSizes`.
    let sizes = validated_ascending_sizes("--sizes", args, &[2_000, 10_000, 100_000])?;

    eprintln!("[timing] mootx01: {binary}");
    eprintln!("[timing] seed: {seed}  repeats: {repeats}  run-mode: {run_mode}");

    let config = TimingLaneConfig {
        moot_binary_path: PathBuf::from(binary),
        seed,
        repeats,
        out_dir,
        run_mode,
        sizes,
        run_id: option_value("--run-id", args).map(str::to_string),
    };
    run_timing_lane(&config)
}

// ─────────────────────────────────────────────────────────────────────────────
// gauntlet-corpus subcommand
// ─────────────────────────────────────────────────────────────────────────────

/// gauntlet-corpus: generate a deterministic gauntlet corpus and write it to
/// the output directory (needles.json + records.json). No live backend needed.
///
/// Mirrors Swift `GauntletCLI.runGauntletCorpus(_:)`.
///
/// Options:
///   --seed N          corpus seed (default 42)
///   --out <dir>       output directory (default: current directory)
///   --per-tier N      needles per noise tier (default 2)
///   --distractors N   distractors per needle (default 10)
///   --tiers T1,T2,.. comma-separated tier subset (default: all five)
// ─────────────────────────────────────────────────────────────────────────────
// capturespread-corpus subcommand
// ─────────────────────────────────────────────────────────────────────────────

/// capturespread-corpus: generates and writes a CaptureSpread corpus JSON
/// without running the benchmark lane. Twin of Swift `CaptureSpreadCorpus`
/// CLI `capturespread-corpus` subcommand.
///
/// Options:
///   --seed <u64>          Corpus seed (default 42).
///   --probes <int>        Probe topic count (default 50).
///   --distractors <int>   Distractor topic count (default 150).
///   --out <dir>           Output directory (default: .).
fn run_capturespread_corpus_cmd(args: &[String]) -> Result<(), String> {
    use mcp_benchmarker_rs::capturespread_corpus::generate_capture_spread_corpus;

    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(42);
    let probe_count = validated_count("--probes", args, 50, 1)?;
    let distractor_count = validated_count("--distractors", args, 150, 0)?;
    let out = option_value("--out", args).unwrap_or(".");

    std::fs::create_dir_all(out)
        .map_err(|e| format!("could not create output directory '{out}': {e}"))?;

    let corpus = generate_capture_spread_corpus(seed, probe_count, distractor_count);
    eprintln!(
        "[capturespread-corpus] seed={seed} probes={probe_count} distractors={distractor_count}: \
         {} records, {} probes",
        corpus.records.len(),
        corpus.probes.len(),
    );

    let bytes = serde_json::to_vec_pretty(&corpus)
        .map_err(|e| format!("corpus encode failed: {e}"))?;
    let out_path = std::path::Path::new(out)
        .join(format!("capturespread-corpus-seed{seed}.json"));
    std::fs::write(&out_path, &bytes)
        .map_err(|e| format!("corpus write failed to {}: {e}", out_path.display()))?;
    println!(
        "[capturespread-corpus] wrote {}",
        out_path.display()
    );
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// capturespread subcommand
// ─────────────────────────────────────────────────────────────────────────────

fn run_capturespread_cmd(args: &[String]) -> Result<(), String> {
    mcp_benchmarker_rs::capturespread_runner::run_capture_spread_cmd(args)
}

fn run_gauntlet_corpus(args: &[String]) -> Result<(), String> {
    use mcp_benchmarker_rs::gauntlet_corpus::{
        GauntletGenerator, GauntletProfile, NoiseTier,
    };
    use mcp_benchmarker_rs::gauntlet_io::write_corpus;

    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(42);
    let per_tier = validated_count("--per-tier", args, 2, 1)?;
    let distractors = validated_count("--distractors", args, 10, 1)?;
    let out = option_value("--out", args).unwrap_or(".");

    // --tiers T1,T2,...: restrict generation to a subset of the five noise
    // tiers. Useful for quick iteration on a single tier's mechanics without
    // generating the full corpus. When omitted, all five tiers are generated.
    let tier_counts: Option<std::collections::HashMap<NoiseTier, usize>> =
        option_value("--tiers", args).map(|raw| {
            raw.split(',')
                .filter_map(|t| NoiseTier::from_raw(t.trim()))
                .map(|tier| (tier, per_tier))
                .collect()
        });

    let profile = match tier_counts {
        None => GauntletProfile::even_mix(per_tier, distractors),
        Some(tc) => GauntletProfile::new(tc, distractors),
    };
    let corpus = GauntletGenerator::new(profile).generate(seed);
    eprintln!(
        "[gauntlet-corpus] seed={seed} per-tier={per_tier} distractors={distractors}: \
         {} records, {} needles",
        corpus.records.len(),
        corpus.needles.len(),
    );
    let (records_path, needles_path) = write_corpus(&corpus, out)
        .map_err(|e| format!("gauntlet-corpus: write failed: {}", e.description))?;
    println!(
        "[gauntlet-corpus] wrote {} (records) and {} (needles)",
        records_path.display(),
        needles_path.display(),
    );
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// gauntlet subcommand — config helper
// ─────────────────────────────────────────────────────────────────────────────

/// Derives the mootx01 binary path from a benchmarker config file. Mirrors
/// Swift `GauntletCLI.runGauntlet`'s `mootBinaryForEnv` extraction.
///
/// Loads the config at `path`, finds the endpoint whose `verbMap.write` starts
/// with `"moot_"` (the moot endpoint), and returns the first non-`VAR=value`
/// token from its stdio command. An env-assignment token has the shape
/// `UPPERCASE_KEY=value`; a token whose characters before the first `=` contain
/// a lowercase letter is the binary, not an assignment. Returns `None` when the
/// config cannot be loaded, has no moot endpoint, has a non-stdio transport, or
/// has a command whose first non-assignment token is empty.
fn binary_from_gauntlet_config(path: &str) -> Option<String> {
    use mcp_benchmarker_rs::config::{BenchmarkerConfig, Transport};

    let cfg = BenchmarkerConfig::load(std::path::Path::new(path)).ok()?;
    // Find the endpoint whose write verb is moot_* (the moot endpoint).
    // Mirrors Swift: `endpoints.first(where: { $0.verbMap.write.hasPrefix("moot_") })`.
    let endpoint = [&cfg.source, &cfg.target]
        .into_iter()
        .find(|ep| ep.verb_map.write.starts_with("moot_"))?;
    let command = match &endpoint.transport {
        Transport::Stdio { command } => command,
        _ => return None,
    };
    // Skip leading VAR=value env-assignment tokens; return the first token whose
    // key-part (everything before the first '=') contains a non-UPPER/digit/_
    // character. Mirrors Swift's `first(where:)` in mootBinaryForEnv.
    command
        .split_ascii_whitespace()
        .find(|token| {
            // A pure env assignment: UPPER/digit/_ chars before '='.
            // If there is no '=', it cannot be an assignment.
            match token.find('=') {
                None => true, // no '=': this is the binary token
                Some(eq_idx) => {
                    let key = &token[..eq_idx];
                    // Not an assignment when the key contains a lowercase letter.
                    key.chars().any(|c| c.is_lowercase())
                }
            }
        })
        .map(str::to_string)
}

// ─────────────────────────────────────────────────────────────────────────────
// gauntlet subcommand
// ─────────────────────────────────────────────────────────────────────────────

/// gauntlet: full recall gauntlet against a live moot backend. Loads the
/// corpus into a fresh scratch estate, dreams it, enforces the DegeneracyGuard,
/// scores every needle under every column, and writes the human report and JSON
/// sidecar.
///
/// Mirrors Swift `GauntletCLI.runGauntlet(_:)`.
///
/// Options (Swift-compatible flags — same names and meanings as the Swift port):
///   --config <path>              benchmarker config file (JSON); the mootx01 binary path
///                                is derived from the config's moot endpoint stdio command,
///                                matching Swift's behaviour. Swift-compatible.
///   --corpus <dir>               directory with corpus-<seed>.jsonl + needles-<seed>.json
///                                (if omitted, generates a fresh corpus with --seed)
///   --run-label <label>          label embedded in the report (default: gauntlet)
///   --out <dir>                  report output root (default: benchmarks/results)
///   --k K1,K2,...                found@k depths (default: 1,3,5,10)
///   --limit N                    max results per query (default: 10)
///   --quick                      skip the precise-recall ablation grid
///   --moot-only                  moot backend only (default; flag is accepted for symmetry)
///   --seed-path live|batch       estate seed path (default: batch)
///
/// Rust-only extras (not present in the Swift port):
///   --binary / --mootx01-binary  direct binary path; overrides the path derived from
///                                --config; Rust-only
///   --seed N                     corpus seed (default 42); Rust-only (Swift reads seed
///                                from the loaded corpus)
///   --per-tier N                 needles/tier when generating corpus (default 2); Rust-only
///   --distractors N              distractors/needle when generating (default 10); Rust-only
///   --shape disk|ram             estate storage backend (default: disk); Rust-only
///   --guard-sample once|per-unit degeneracy guard sampling policy (default: once); Rust-only
///   --scratch-dir <dir>          scratch estate root (default: /tmp/gauntlet-scratch-<seed>); Rust-only
///   --reuse-backends             reuse persisted estate (skip load + dream); Rust-only
///   --run-mode quiet|contended   machine posture annotation in report; Rust-only
fn run_gauntlet_cmd(args: &[String]) -> Result<(), String> {
    use mcp_benchmarker_rs::gauntlet_corpus::{
        GauntletGenerator, GauntletProfile, NoiseTier,
    };
    use mcp_benchmarker_rs::gauntlet_io::{load_corpus, write_report};
    use mcp_benchmarker_rs::gauntlet_runner::{
        GauntletRunConfig,
        capture_git_dirty_count, capture_git_sha, gauntlet_endpoint_config,
        gauntlet_verb_map, run_gauntlet,
    };
    use mcp_benchmarker_rs::gauntlet_scorer::GauntletScorer;
    use mcp_benchmarker_rs::seed_export::SeedPathMode;

    // Binary source priority (highest to lowest):
    //   1. --mootx01-binary / --binary  (Rust-only explicit override)
    //   2. --config: the moot endpoint's stdio command is the config's
    //      source of truth; the binary is the first non-VAR=value token.
    //      Mirrors Swift's `mootBinaryForEnv` extraction in GauntletCLI.swift.
    //   3. $MOOTX01_BINARY / PATH discovery  (auto-discovery fallback)
    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(|| {
            option_value("--config", args)
                .and_then(|path| binary_from_gauntlet_config(path))
        })
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "mootx01 binary not found; pass --config <path>, --binary <path>, \
             or set $MOOTX01_BINARY".to_string()
        })?;

    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(42);
    let per_tier = validated_count("--per-tier", args, 2, 1)?;
    let distractors = validated_count("--distractors", args, 10, 1)?;
    let search_limit = validated_count("--limit", args, 10, 1)?;
    let run_label = option_value("--run-label", args)
        .unwrap_or("gauntlet")
        .to_string();
    let run_mode = option_value("--run-mode", args)
        .unwrap_or("unspecified")
        .to_string();
    let quick_mode = flag_present("--quick", args);
    let reuse_backends = flag_present("--reuse-backends", args);

    // --k K1,K2,...: found@k depths. Default: 1,3,5,10.
    let k_values: Vec<i32> = option_value("--k", args)
        .map(|raw| {
            raw.split(',')
                .filter_map(|s| s.trim().parse::<i32>().ok())
                .collect()
        })
        .unwrap_or_else(|| vec![1, 3, 5, 10]);
    if k_values.is_empty() {
        return Err("--k produced an empty list; provide at least one depth".to_string());
    }

    // --seed-path live|batch: default batch (ruling 8D5B8053).
    let seed_path = SeedPathMode::parse(option_value("--seed-path", args))
        .map_err(|e| e)?;

    // --shape disk|ram (C1).
    let use_inmemory = match option_value("--shape", args).unwrap_or("disk") {
        "ram" => true,
        "disk" => false,
        other => return Err(format!("--shape must be 'disk' or 'ram'; got '{other}'")),
    };

    // --guard-sample once|per-unit (C5). Parsed for validation; gauntlet
    // always runs once-per-run structurally (one shared estate, one run).
    let _guard_sampling = mcp_benchmarker_rs::degeneracy_guard::GuardSamplingPolicy::parse(
        option_value("--guard-sample", args),
    ).map_err(|e| e)?;

    // --tiers T1,T2,...: restrict corpus generation to a tier subset.
    let tier_counts: Option<std::collections::HashMap<NoiseTier, usize>> =
        option_value("--tiers", args).map(|raw| {
            raw.split(',')
                .filter_map(|t| NoiseTier::from_raw(t.trim()))
                .map(|tier| (tier, per_tier))
                .collect()
        });

    // ── Corpus: load from --corpus dir OR generate fresh ────────────────────
    let corpus = if let Some(corpus_dir) = option_value("--corpus", args) {
        load_corpus(corpus_dir)
            .map_err(|e| format!("--corpus: could not load from '{}': {}", corpus_dir, e.description))?
    } else {
        let profile = match tier_counts {
            None => GauntletProfile::even_mix(per_tier, distractors),
            Some(tc) => GauntletProfile::new(tc, distractors),
        };
        GauntletGenerator::new(profile).generate(seed)
    };
    eprintln!(
        "[gauntlet] seed={} records={} needles={} quick={} reuse={}",
        corpus.seed, corpus.records.len(), corpus.needles.len(), quick_mode, reuse_backends
    );

    // ── Scratch estate ───────────────────────────────────────────────────────
    let default_scratch = format!("/tmp/gauntlet-scratch-{}", corpus.seed);
    let scratch_dir = option_value("--scratch-dir", args)
        .map(str::to_string)
        .unwrap_or(default_scratch);
    // Ensure the scratch directory exists.
    std::fs::create_dir_all(&scratch_dir)
        .map_err(|e| format!("could not create scratch dir '{}': {e}", scratch_dir))?;
    let marker_path = format!("{}/.gauntlet-loaded", scratch_dir);

    // ── Connect the moot backend ─────────────────────────────────────────────
    let endpoint = gauntlet_endpoint_config(&scratch_dir, &binary, use_inmemory)?;
    let verb_map = gauntlet_verb_map();
    let mut client = MCPClient::new(endpoint);
    client
        .connect()
        .map_err(|e| format!("could not connect to mootx01 ({binary}): {}", e.description))?;

    // ── Build and run the gauntlet ───────────────────────────────────────────
    let scorer = GauntletScorer::new(k_values.clone());
    let config = GauntletRunConfig {
        moot_verb_map: verb_map,
        corpus: corpus.clone(),
        scorer,
        run_label: run_label.clone(),
        search_limit,
        reuse_moot: reuse_backends,
        quick_mode,
        seed_path,
        scratch_dir: Some(scratch_dir.clone()),
        moot_marker: if reuse_backends { Some(marker_path.clone()) } else { None },
    };

    let mut report = run_gauntlet(&mut client, &config)
        .map_err(|e| format!("gauntlet run failed: {e}"))?;

    // ── Stamp provenance (C7) ────────────────────────────────────────────────
    report.git_sha = capture_git_sha();
    report.git_dirty_count = Some(capture_git_dirty_count());
    report.run_timestamp = {
        use std::time::{SystemTime, UNIX_EPOCH};
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        // Format as ISO8601 UTC (seconds precision).
        let t = secs;
        let s = t % 60; let t = t / 60;
        let m = t % 60; let t = t / 60;
        let h = t % 24; let days = t / 24;
        // Approximate: 2024-01-01 = unix day 19723.
        let approx_day = days;
        let y2024_base: u64 = 19723;
        let days_since_2024 = approx_day.saturating_sub(y2024_base);
        // Rough year/month/day (not leap-year–aware; fine for a log timestamp).
        let year = 2024 + days_since_2024 / 365;
        let rem = days_since_2024 % 365;
        let month = (rem / 30) + 1;
        let day = (rem % 30) + 1;
        format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", year, month.min(12), day.min(31), h, m, s)
    };
    let run_env = RunEnvironment::collect_with_run_mode(Some(binary.as_str()), &run_mode);
    report.run_environment = Some(run_env);

    // ── Write load marker (for future --reuse-backends) ─────────────────────
    if !reuse_backends {
        mcp_benchmarker_rs::gauntlet_runner::write_load_marker(
            &marker_path, corpus.seed, corpus.records.len(),
        );
    }

    // ── Print report ─────────────────────────────────────────────────────────
    println!("{}", report.rendered());

    // ── Write the record ─────────────────────────────────────────────────────
    // gauntlet-<run label>-<serial>.json in --out, rendered text beside it, and
    // the run appended to the pass ledger. The serial is --run-id when the
    // caller supplies one and a UTC stamp otherwise, so two runs of one seed
    // under one label stay distinct.
    let out_root = option_value("--out", args);
    let run_serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(args);
    let out_path = write_report(&report, out_root, &run_serial)
        .map_err(|e| format!("report write failed: {}", e.description))?;
    if let Some(root) = out_root {
        let needles: usize = report.tier_counts.values().sum();
        let name = out_path.file_name().unwrap_or_default().to_string_lossy().to_string();
        mcp_benchmarker_rs::record_writer::append_to_ledger(
            &format!(
                "gauntlet\t{}\t{}\tneedles={}\tstrategies={}",
                report.run_label,
                name,
                needles,
                report.strategies.len()
            ),
            &std::path::Path::new(root).join("records.tsv"),
        )
        .map_err(|e| format!("ledger append failed: {e}"))?;
    }
    eprintln!("[gauntlet] report written to {}", out_path.display());

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// gauntlet --config flag tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod gauntlet_config_flag_tests {
    use super::{binary_from_gauntlet_config, option_value, validate_options};

    fn argv(tokens: &[&str]) -> Vec<String> {
        tokens.iter().map(|t| t.to_string()).collect()
    }

    /// Verify that `--config` is parsed from an argv vector spelled exactly as
    /// the Makefile (after Part C) spells the Swift invocation:
    ///
    ///   $(PORT_BENCH_BIN) gauntlet --config $(GAUNTLET_CONFIG) \
    ///     --corpus $(OUT)/gauntlet-corpus --run-label $(GAUNTLET_RUN_LABEL) \
    ///     --run-id $(RUN_ID) --out $(OUT)
    ///
    /// The literal argv is named in the test body so a reader knows exactly
    /// what Makefile invocation this gate covers.
    #[test]
    fn gauntlet_config_flag_is_accepted() {
        // Exact Makefile argv (with representative values substituted for
        // Make variables):
        //   mcp-benchmarker-rs gauntlet \
        //     --config /bench/configs/gauntlet-moot-only.json \
        //     --corpus /bench/results/gauntlet-corpus \
        //     --run-label official \
        //     --run-id 20260914T000000Z \
        //     --out /bench/results
        let args = argv(&[
            "--config", "/bench/configs/gauntlet-moot-only.json",
            "--corpus", "/bench/results/gauntlet-corpus",
            "--run-label", "official",
            "--run-id", "20260914T000000Z",
            "--out", "/bench/results",
        ]);
        assert_eq!(
            option_value("--config", &args),
            Some("/bench/configs/gauntlet-moot-only.json"),
            "--config must be parsed from the Makefile argv"
        );
        assert!(
            validate_options("gauntlet", &args).is_ok(),
            "the strict CLI validator must accept the documented gauntlet --config invocation"
        );
    }

    /// Verify that `binary_from_gauntlet_config` extracts the binary token from
    /// the moot endpoint's stdio command, skipping leading VAR=value assignments.
    /// Uses an inline config JSON — the same schema the real config loader reads.
    #[test]
    fn binary_from_gauntlet_config_extracts_binary_path() {
        // Write a minimal config JSON to a temp file so binary_from_gauntlet_config
        // exercises the real BenchmarkerConfig::load path, not a hand-rolled parse.
        let config_json = r#"{
  "source": {
    "name": "moot",
    "transport": { "stdio": { "command": "MOOTX01_VAULT=1 /usr/local/bin/mootx01 serve --db /tmp/gs" } },
    "verbMap": { "write": "moot_file_memory", "query": "moot_memory_search" },
    "role": "both"
  },
  "target": {
    "name": "external",
    "transport": { "stdio": { "command": "/usr/bin/external-mcp" } },
    "verbMap": { "write": "ext_write", "query": "ext_query" },
    "role": "target"
  }
}"#;
        let path = format!("/tmp/gauntlet-config-test-{}.json", std::process::id());
        std::fs::write(&path, config_json).unwrap();
        let binary = binary_from_gauntlet_config(&path);
        std::fs::remove_file(&path).ok();
        assert_eq!(
            binary.as_deref(),
            Some("/usr/local/bin/mootx01"),
            "binary_from_gauntlet_config must return the first non-env-assignment token \
             from the moot endpoint's stdio command; the VAR=value prefix must be skipped"
        );
    }
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
    // `<subcommand> --help` prints usage rather than tripping the unknown-option
    // check: the operator asking what a subcommand takes is exactly the person
    // the strict-option policy is for.
    if rest.iter().any(|a| a == "--help" || a == "-h") {
        print!("{}", usage());
        return ExitCode::SUCCESS;
    }
    // Retired and unrecognised options fail here, before any run starts. See
    // validate_options for why silence was the defect.
    if let Err(msg) = validate_options(subcommand, rest) {
        eprintln!("error: {msg}");
        return ExitCode::FAILURE;
    }
    // No-encoder guard: hoist before any subprocess is spawned. A mislabeled
    // run (product-default arm recorded as no-encoder) is the defect; catching
    // it here avoids even starting serve/probe. Skip for help subcommands.
    if !mcp_benchmarker_rs::arm_register::is_no_encoder_dispatch_exempt(subcommand) {
        if let Some(msg) = mcp_benchmarker_rs::arm_register::no_encoder_activation_seam_message() {
            eprintln!("{msg}");
            return ExitCode::FAILURE;
        }
    }
    let result = match subcommand {
        // transfer and report subcommands are not part of this crate
        "longmemeval" | "lme" => run_longmemeval(rest),
        "lmeb" => run_lmeb(rest),
        "locomo" => run_locomo(rest),
        "locomo-spec" => run_locomo_spec(rest),
        "artifact-recall" => run_artifact_recall(rest),
        "payload-economics" => run_payload_economics(rest),
        "lme-spec" => run_lme_spec_cmd(rest),
        "membench-spec" => run_membench_spec_cmd(rest),
        "lmeb-spec" => run_lmeb_spec_cmd(rest),
        "convomem-spec" => run_convomem_spec_cmd(rest),
        "membench" => run_membench(rest),
        // Legacy judge-batch is dark (ruling 2026-08-18): its grading is the
        // legacy substring/verdict path, not an official protocol. The spec
        // lanes carry their own batch consumption. Code retained; activation
        // disabled pending a removal ruling. Twin of the Swift gate.
        "answer-batch" => run_answer_batch_cmd(rest),
        "judge-batch" => Err(
            "judge-batch is dark (legacy non-deterministic path; ruling \
             2026-08-18). Use the spec lanes' dump/consume seams with \
             the judge-batch subcommand instead."
                .to_string(),
        ),
        "supersession" => run_supersession(rest),
        "replay" => run_replay(rest),
        "timing" => run_timing(rest),
        "journey" => run_journey(rest),
        "capturespread-corpus" => run_capturespread_corpus_cmd(rest),
        "capturespread" => run_capturespread_cmd(rest),
        "gauntlet-corpus" => run_gauntlet_corpus(rest),
        "gauntlet" => run_gauntlet_cmd(rest),
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

// ─────────────────────────────────────────────────────────────────────────────
// Tests — CLI count-option validation
// ─────────────────────────────────────────────────────────────────────────────
//
// The generators are allowed to trust their inputs (supersession_corpus indexes
// `chain_values[len() - 1]`, journey_corpus divides by `members_per_cluster`),
// so validation happens once, at this boundary. These tests pin both halves of
// that contract: bad values are REJECTED with a message naming the option, and
// good values are passed through untouched.
//
// Rejected, never clamped. A benchmark run whose parameters were silently
// corrected reports numbers labelled with what the operator asked for and
// measured with something else. This is also the regression guard for the
// pre-fix Rust divergence, where run_supersession used
// `.and_then(|s| s.parse().ok()).unwrap_or(default)` and turned `--versions -1`
// into a silent 3.

/// The CLI boundary rejects the retired `--no-plaintext-scratch` flag and every
/// other unrecognised option, instead of ignoring them.
///
/// The defect these tests pin: both parsers located options by name and never
/// looked at the tokens they did not recognise. `--no-plaintext-scratch` used to
/// select the encrypted scratch posture; after `--estate-mode` replaced it, an
/// invocation still carrying it fell through to the unencrypted default and produced a PLAINTEXT scratch estate while its
/// author believed encryption had been requested.
///
/// FAIL, DO NOT ALIAS. Twin of Swift `EstateModeRejectionTests`.
#[cfg(test)]
mod estate_mode_rejection_tests {
    use super::{parse_estate_mode, validate_options, ScratchEstatePosture, OPTION_SURFACES};

    fn argv(tokens: &[&str]) -> Vec<String> {
        tokens.iter().map(|t| t.to_string()).collect()
    }

    /// Every subcommand that reaches `parse_estate_mode`. Four, not three — the
    /// supersession lane gained `--estate-mode` after the retired flag was
    /// removed, so it never accepted the old name, but an operator typing it
    /// there must get the same answer as everywhere else.
    const ESTATE_MODE_SUBCOMMANDS: &[&str] = &["longmemeval", "locomo", "membench", "lmeb", "supersession"];

    #[test]
    fn retired_flag_is_rejected_naming_the_replacement() {
        for subcommand in ESTATE_MODE_SUBCOMMANDS {
            let err = validate_options(subcommand, &argv(&["--no-plaintext-scratch"]))
                .expect_err("the retired flag must be rejected");
            // The message must carry enough to act on: the dead name and the
            // replacement to type instead.
            assert!(err.contains("--no-plaintext-scratch"), "{err}");
            assert!(err.contains("--estate-mode encrypted"), "{err}");
        }
    }

    #[test]
    fn retired_flag_is_rejected_in_a_realistic_invocation() {
        // The shape a stored script actually has: the retired flag buried in a
        // list of options that are all still current.
        let args = argv(&[
            "--corpus",
            "/tmp/lme.json",
            "--no-plaintext-scratch",
            "--limit",
            "10",
            "--seed",
            "20260725",
        ]);
        assert!(validate_options("longmemeval", &args).is_err());
    }

    #[test]
    fn retired_flag_is_rejected_under_every_subcommand() {
        for (subcommand, _) in OPTION_SURFACES {
            assert!(
                validate_options(subcommand, &argv(&["--no-plaintext-scratch"])).is_err(),
                "{subcommand} accepted the retired flag"
            );
        }
        // Including the `lme` alias and a subcommand with no declared surface.
        assert!(validate_options("lme", &argv(&["--no-plaintext-scratch"])).is_err());
        assert!(validate_options("not-a-subcommand", &argv(&["--no-plaintext-scratch"])).is_err());
    }

    #[test]
    fn retired_flag_is_not_silently_aliased_to_the_encrypted_posture() {
        // Fail, do not alias. If the flag were treated as a synonym,
        // parse_estate_mode would return EncryptedEphemeral for it. It must not
        // — nothing reads the name; the dispatch validator is what stops these
        // arguments ever reaching a run.
        let args = argv(&["--no-plaintext-scratch"]);
        assert_eq!(
            parse_estate_mode(&args).expect("no --estate-mode is not an error"),
            ScratchEstatePosture::PlaintextTransient
        );
        assert!(validate_options("longmemeval", &args).is_err());
    }

    #[test]
    fn unknown_option_is_rejected_naming_it_and_the_accepted_set() {
        let err = validate_options("lmeb", &argv(&["--not-an-option", "7"]))
            .expect_err("an unrecognised option must be rejected");
        assert!(err.contains("--not-an-option"), "{err}");
        assert!(err.contains("lmeb"), "{err}");
        assert!(err.contains("--estate-mode"), "{err}");
    }

    #[test]
    fn joined_value_form_is_rejected() {
        // `--name=value` is not a form this CLI accepts anywhere.
        assert!(validate_options("longmemeval", &argv(&["--estate-mode=encrypted"])).is_err());
    }

    #[test]
    fn misspelt_option_is_rejected_rather_than_ignored() {
        assert!(validate_options("longmemeval", &argv(&["--estate-mod", "encrypted"])).is_err());
    }

    #[test]
    fn typo_directly_after_a_bare_flag_is_still_caught() {
        // The value-skipping walk must not treat the token after a BARE flag as
        // that flag's value — supersession's --skip-dream takes none.
        assert!(validate_options("supersession", &argv(&["--skip-dream", "--typo"])).is_err());
    }

    #[test]
    fn every_declared_option_is_accepted() {
        for (subcommand, surface) in OPTION_SURFACES {
            for option in surface.valued {
                validate_options(subcommand, &argv(&[option, "value"]))
                    .unwrap_or_else(|e| panic!("{subcommand} {option}: {e}"));
            }
            for flag in surface.bare {
                validate_options(subcommand, &argv(&[flag]))
                    .unwrap_or_else(|e| panic!("{subcommand} {flag}: {e}"));
            }
        }
    }

    #[test]
    fn dash_leading_value_is_not_read_as_an_option() {
        // --seed -1 is a bad seed, not an unknown option; validated_count owns
        // that complaint, not the option walker.
        validate_options("journey", &argv(&["--seed", "-1"])).expect("a dash value is a value");
        validate_options("longmemeval", &argv(&["--judge-cmd", "--flagged-judge"]))
            .expect("a dash value is a value");
    }

    #[test]
    fn positionals_are_ignored() {
        validate_options("report", &argv(&["--manifest", "m.json", "extra"]))
            .expect("positional arguments are not options");
    }

    #[test]
    fn official_matrix_invocations_still_validate() {
        // Taken verbatim from scripts/official-matrix-11x-only.sh, the shape the
        // published runs use. If the strict policy broke these, it would have
        // broken every recorded benchmark.
        validate_options(
            "longmemeval",
            &argv(&[
                "--corpus", "/c", "--binary", "/m", "--variant", "s", "--limit", "10", "--seed",
                "1", "--out", "/o",
            ]),
        )
        .expect("the matrix LME leg must validate");
        validate_options(
            "locomo",
            &argv(&[
                "--corpus", "/c", "--binary", "/m", "--limit", "10", "--seed", "1", "--out", "/o",
            ]),
        )
        .expect("the matrix LoCoMo leg must validate");
        validate_options(
            "lmeb",
            &argv(&[
                "--data-dir",
                "/d",
                "--evidence-types",
                "user_evidence",
                "--binary",
                "/m",
                "--limit",
                "10",
                "--seed",
                "1",
                "--out",
                "/o",
            ]),
        )
        .expect("the matrix LMEB leg must validate");
    }

    /// A fresh empty directory for posture-application assertions.


    #[test]
    fn encrypted_mode_still_selects_ephemeral() {
        let posture =
            parse_estate_mode(&argv(&["--estate-mode", "encrypted"])).expect("encrypted is valid");
        assert_eq!(posture, ScratchEstatePosture::EncryptedEphemeral);
    }

    #[test]
    fn omitting_estate_mode_still_defaults_to_plaintext() {
        // The default is deliberately unchanged: it is not what was wrong here.
        let posture = parse_estate_mode(&[]).expect("an absent option is not an error");
        assert_eq!(posture, ScratchEstatePosture::PlaintextTransient);
    }

    #[test]
    fn invalid_estate_mode_value_is_still_rejected() {
        assert!(parse_estate_mode(&argv(&["--estate-mode", "plaintext"])).is_err());
    }

    /// Finding #6 (BH-02): flags that runner code already parses must be
    /// registered in OPTION_SURFACES, or the validator makes them unreachable.
    ///
    /// The flags below were all read by their lane's `option_value` call
    /// but absent from the surface declaration — so any invocation carrying
    /// them was rejected before the runner ever ran.
    ///
    /// This test fails pre-fix with "unknown option '<flag>' for subcommand
    /// '<subcommand>'" and passes post-fix once the flags are registered.
    #[test]
    fn parsed_but_unregistered_flags_are_now_accepted() {
        // (subcommand, flag, representative value)
        let cases: &[(&str, &str, &str)] = &[
            ("membench",  "--estate-grouping", "per-agent"),
            ("membench",  "--capacity-tier",   "small"),
            ("lmeb",      "--estate-shape",    "shared"),
        ];
        for (subcommand, flag, value) in cases {
            validate_options(subcommand, &argv(&[flag, value]))
                .unwrap_or_else(|e| panic!("{subcommand} {flag}: {e}"));
        }
    }

    /// 2026-08-18 doctrine: --run-mode is no longer accepted by accuracy lanes.
    /// The nine accuracy subcommands must reject --run-mode via the option
    /// surface validator; the three non-accuracy lanes must still accept it.
    #[test]
    fn run_mode_rejected_by_accuracy_lanes() {
        let accuracy_lanes = &[
            "longmemeval",
            "locomo",
            "locomo-spec",
            "lme-spec",
            "membench-spec",
            "lmeb-spec",
            "convomem-spec",
            "membench",
            "lmeb",
        ];
        for subcommand in accuracy_lanes {
            let err = validate_options(subcommand, &argv(&["--run-mode", "quiet"]))
                .expect_err("accuracy lane must reject --run-mode");
            // The error should mention the unknown flag or the subcommand.
            assert!(
                err.contains("--run-mode") || err.contains(subcommand),
                "{subcommand}: unexpected error format: {err}"
            );
        }
        // Timing and journey lanes still accept it.
        validate_options("timing", &argv(&["--run-mode", "quiet"]))
            .expect("timing lane must accept --run-mode");
        validate_options("journey", &argv(&["--run-mode", "quiet"]))
            .expect("journey lane must accept --run-mode");
    }
}

#[cfg(test)]
mod count_validation_tests {
    use super::validated_count;

    /// (option, default, minimum) paired with the generator code that would
    /// break below the minimum. One table so a future option has an obvious
    /// place to land.
    const MINIMUMS: &[(&str, usize, usize)] = &[
        // supersession
        ("--entities", 40, 0),             // supersession_corpus `0..entity_count`
        ("--versions", 3, 1),              // supersession_corpus `chain_values[len() - 1]`
        ("--contradictions", 10, 0),       // supersession_corpus `0..contradiction_count`
        ("--k", 10, 1),                    // supersession_runner stale-in-top-K cutoff
        // journey
        ("--precise-miss-count", 20, 0),   // journey_corpus `0..count`
        ("--cluster-count", 10, 0),        // journey_corpus `0..cluster_count`
        ("--members-per-cluster", 6, 2),   // journey_corpus `rng % members_per_cluster`
    ];

    fn argv(option: &str, value: &str) -> Vec<String> {
        vec![option.to_string(), value.to_string()]
    }

    #[test]
    fn below_minimum_is_rejected_naming_option_and_value() {
        for (option, default, minimum) in MINIMUMS {
            // `minimum` is usize, so step below it as i64 to reach -1 when the
            // minimum is 0.
            let bad = *minimum as i64 - 1;
            let args = argv(option, &bad.to_string());
            let err = validated_count(option, &args, *default, *minimum)
                .expect_err("value below the minimum must be rejected");
            // The message must carry enough to act on: which option, what was
            // supplied, and what the constraint is.
            assert!(err.contains(option), "message must name the option: {err}");
            assert!(err.contains(&bad.to_string()), "message must quote the value: {err}");
            assert!(err.contains(&minimum.to_string()), "message must state the bound: {err}");
        }
    }

    #[test]
    fn negative_is_rejected_for_every_count_option() {
        for (option, default, minimum) in MINIMUMS {
            let args = argv(option, "-1");
            assert!(validated_count(option, &args, *default, *minimum).is_err());
        }
    }

    #[test]
    fn non_integer_is_rejected_rather_than_silently_defaulted() {
        for (option, default, minimum) in MINIMUMS {
            let args = argv(option, "eight");
            let err = validated_count(option, &args, *default, *minimum)
                .expect_err("a non-integer must be rejected");
            // Not the opaque "invalid digit found in string" the bare usize
            // parse produced — the option and the bound are both named.
            assert!(err.contains(option), "message must name the option: {err}");
            assert!(err.contains("eight"), "message must quote the value: {err}");
        }
    }

    #[test]
    fn versions_zero_is_rejected_chain_index_would_underflow() {
        let args = argv("--versions", "0");
        assert!(validated_count("--versions", &args, 3, 1).is_err());
    }

    #[test]
    fn members_per_cluster_zero_is_rejected_picker_divides_by_it() {
        let args = argv("--members-per-cluster", "0");
        assert!(validated_count("--members-per-cluster", &args, 6, 2).is_err());
    }

    #[test]
    fn members_per_cluster_one_is_rejected_nothing_to_narrow_among() {
        let args = argv("--members-per-cluster", "1");
        assert!(validated_count("--members-per-cluster", &args, 6, 2).is_err());
    }

    #[test]
    fn absent_option_yields_default() {
        for (option, default, minimum) in MINIMUMS {
            let value = validated_count(option, &[], *default, *minimum)
                .expect("an absent option is not an error");
            assert_eq!(value, *default);
        }
    }

    #[test]
    fn minimum_and_default_are_accepted() {
        for (option, default, minimum) in MINIMUMS {
            let at_minimum = validated_count(option, &argv(option, &minimum.to_string()), *default, *minimum)
                .expect("the minimum itself is in range");
            assert_eq!(at_minimum, *minimum);

            let at_default = validated_count(option, &argv(option, &default.to_string()), *default, *minimum)
                .expect("the default is in range");
            assert_eq!(at_default, *default);
        }
    }

    #[test]
    fn valid_value_is_passed_through_unchanged_never_clamped() {
        let args = argv("--entities", "7");
        assert_eq!(validated_count("--entities", &args, 40, 0).unwrap(), 7);
    }
}

/// Finding 4 regression: run_replay now retains outcome.lane_capture and renders
/// a diff table when --lane-capture is present. These tests verify the two
/// unit-testable pieces: flag detection and the render path that run_replay invokes.
///
/// The end-to-end path (spawning a live endpoint and collecting captures from
/// RunOutcome) requires a running moot binary and is covered by integration tests.
#[cfg(test)]
mod lane_capture_replay_tests {
    use super::flag_present;
    use mcp_benchmarker_rs::replay_lane::{
        diff_lane_captures, render_lane_diff_table, HitLaneScores, LaneCapture,
        QueryLaneSnapshot,
    };

    fn make_capture(bm25: f64) -> LaneCapture {
        LaneCapture {
            import_timestamp: "2026-08-10T00:00:00Z".to_string(),
            snapshots: vec![QueryLaneSnapshot {
                query_id: "q1".to_string(),
                query_timestamp: "2026-08-10T00:00:01Z".to_string(),
                hit_scores: vec![HitLaneScores {
                    locus: 0.8, bm25, vector: 0.0, dense: 0.0,
                    field_fit: 0.0, co_occurrence: 0.0, temporal: 0.0,
                    graph: 0.0, preference: 0.0,
                }],
            }],
        }
    }

    /// --lane-capture flag is detected by flag_present (run_replay gates on this).
    #[test]
    fn flag_present_detects_lane_capture_flag() {
        let with_flag = vec!["--runs".to_string(), "3".to_string(),
                             "--lane-capture".to_string()];
        assert!(flag_present("--lane-capture", &with_flag));
        let without_flag = vec!["--runs".to_string(), "3".to_string()];
        assert!(!flag_present("--lane-capture", &without_flag));
    }

    /// When two LaneCaptures are collected by run_replay, the render path
    /// (diff_lane_captures → render_lane_diff_table) produces a non-empty table
    /// that contains the DRIFT verdict for a perturbed lane.
    ///
    /// This is the exact code path run_replay executes when --lane-capture is set
    /// and both baseline and candidate captures are Some(_).
    #[test]
    fn lane_capture_render_path_produces_drift_table() {
        let baseline  = make_capture(0.70);
        let candidate = make_capture(0.55); // bm25 perturbed by 0.15 → DRIFT

        // Simulate the run_replay render path after outcome.lane_capture is collected:
        let diffs = diff_lane_captures(&baseline, &candidate);
        let table = render_lane_diff_table(
            &baseline, &candidate, &diffs, "run 1", "run 2");

        assert!(!table.is_empty(), "lane diff table must be non-empty");
        assert!(table.contains("bm25"), "perturbed lane must appear in table");
        assert!(table.contains("DRIFT"), "perturbed lane must show DRIFT verdict");
    }
}

/// Builds a record filename for `test`/`arm`, taking the serial from `--run-id`.
///
/// Wraps the `record_filename` + `resolve_run_serial` pair so every lane in
/// this binary names records identically. Twin of the Swift leg's paired call
/// at each write site.
fn crate_record_filename(test: &str, arm: &str, args: &[String]) -> String {
    let serial = mcp_benchmarker_rs::record_writer::resolve_run_serial(args);
    mcp_benchmarker_rs::record_writer::record_filename(test, arm, &serial, "", "json")
}

/// parse_limit_option validation — the --limit variant used by corpus runners
/// (optional, no default). Previously-missed callers (run_artifact_recall,
/// run_membench) used option_value("--limit",...).and_then(|s| s.parse().ok())
/// which treated "--limit -3" as "no limit". Migration to parse_limit_option
/// gives both callers a hard CLI rejection for negatives.
#[cfg(test)]
mod parse_limit_option_tests {
    use super::parse_limit_option;

    fn argv(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn absent_returns_none() {
        assert_eq!(parse_limit_option(&argv(&[])).unwrap(), None);
    }

    #[test]
    fn zero_is_accepted() {
        assert_eq!(parse_limit_option(&argv(&["--limit", "0"])).unwrap(), Some(0));
    }

    #[test]
    fn positive_passes_through() {
        assert_eq!(parse_limit_option(&argv(&["--limit", "50"])).unwrap(), Some(50));
    }

    /// Formerly run_artifact_recall and run_membench silently clamped a negative
    /// --limit to 0 (usize parse failure → fallback). Now both callers reject it.
    #[test]
    fn negative_is_rejected_run_artifact_recall_and_run_membench_callers() {
        assert!(parse_limit_option(&argv(&["--limit", "-1"])).is_err());
        assert!(parse_limit_option(&argv(&["--limit", "-99"])).is_err());
    }

    #[test]
    fn non_integer_is_rejected() {
        assert!(parse_limit_option(&argv(&["--limit", "abc"])).is_err());
    }
}

// ── D2: dispatch-level no-encoder guard exemption ────────────────────────────
//
// main() hoists the guard before the subcommand match. Help subcommands are
// exempt. Run subcommands (longmemeval, benchmark, etc.) are not. These tests
// verify the production predicate is_no_encoder_dispatch_exempt() in
// arm_register.rs — the same function main() calls. There is no second copy
// of the exempt list: adding a subcommand to the production predicate
// immediately changes what these tests verify.
#[cfg(test)]
mod no_encoder_dispatch_exemption_tests {

    /// Help subcommands must be exempt from the dispatch no-encoder guard.
    /// Parity with Swift dispatch() exemption for "--help", "-h", "help".
    #[test]
    fn help_subcommands_are_exempt() {
        for sub in &["--help", "-h", "help"] {
            assert!(
                // Calls the production predicate — not a copy of it.
                mcp_benchmarker_rs::arm_register::is_no_encoder_dispatch_exempt(sub),
                "'{sub}' must be exempt from the dispatch no-encoder guard"
            );
        }
    }

    /// Run subcommands must NOT be exempt — the guard fires for them.
    /// The set is DERIVED from main.rs's dispatch match — not hand-written.
    /// A new dispatch arm added without considering the guard makes the
    /// arm-count or literal-count assertion fail, which is the point.
    #[test]
    fn run_subcommands_are_not_exempt() {
        // Read main.rs — path derived from CARGO_MANIFEST_DIR (<suite root>/rust/).
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let main_rs = manifest.join("src/main.rs");
        let source = std::fs::read_to_string(&main_rs)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", main_rs.display()));

        // Find the dispatch match block: "let result = match subcommand {" … "other =>".
        let lines: Vec<&str> = source.lines().collect();
        let start = lines
            .iter()
            .position(|l| l.contains("let result = match subcommand {"))
            .expect("dispatch match not found in main.rs");

        // Collect every named match arm: lines that (after trimming) start with
        // a `"` and contain `=>`. Stop at the wildcard arm.
        let mut arm_count: usize = 0;
        let mut all_literals: Vec<String> = Vec::new();

        for line in &lines[start + 1..] {
            let trimmed = line.trim();
            // Wildcard arm ends the named arms.
            if trimmed.starts_with("other =>") || trimmed.starts_with("_ =>") {
                break;
            }
            // A named match arm starts with a string literal and carries `=>`.
            if trimmed.starts_with('"') && trimmed.contains("=>") {
                arm_count += 1;
                // Extract every string literal from the arm pattern (before `=>`).
                // Splitting on `"` yields alternating outside/inside segments;
                // odd-indexed segments are the literal contents.
                let pattern_part = trimmed.split("=>").next().unwrap_or("");
                for (i, seg) in pattern_part.split('"').enumerate() {
                    if i % 2 == 1 {
                        // Odd index = content between a pair of quotes.
                        all_literals.push(seg.to_string());
                    }
                }
            }
        }

        // Drift gate: a new dispatch arm without guard consideration fails here.
        assert_eq!(
            arm_count, 22,
            "dispatch match must have 22 arms; got {arm_count} — update this assertion when adding a new subcommand"
        );
        assert_eq!(
            all_literals.len(), 25,
            "dispatch match must have 25 string literals; got {} — update this assertion when adding a new subcommand",
            all_literals.len()
        );

        // Subtract exempt subcommands by CALLING THE PRODUCTION PREDICATE.
        // There is no second copy of the exempt list in this file.
        let non_exempt: Vec<String> = all_literals
            .iter()
            .filter(|s| !mcp_benchmarker_rs::arm_register::is_no_encoder_dispatch_exempt(s))
            .cloned()
            .collect();

        // gauntlet must be in the derived non-exempt set.
        assert!(
            non_exempt.contains(&"gauntlet".to_string()),
            "\"gauntlet\" must be in the derived non-exempt set (found: {non_exempt:?})"
        );

        // Assert the production predicate's exempt set equals the expected set exactly.
        // Sort both sides so ordering does not matter.
        // The expected set is the GATE: widening or narrowing is_no_encoder_dispatch_exempt
        // must fail here immediately.
        //
        // Port note: Rust exempts ["--help", "-h", "help"] only. Swift also exempts "report"
        // (a Swift-only read-only dispatch subcommand with no Rust equivalent).
        // That asymmetry is intentional and is not a bug.
        let mut exempt_set: Vec<String> = all_literals
            .iter()
            .filter(|s| mcp_benchmarker_rs::arm_register::is_no_encoder_dispatch_exempt(s))
            .cloned()
            .collect();
        exempt_set.sort();
        let mut expected_exempt = vec!["--help".to_string(), "-h".to_string(), "help".to_string()];
        expected_exempt.sort();
        assert_eq!(
            exempt_set, expected_exempt,
            "exempt set must be exactly {expected_exempt:?}; widening or narrowing is_no_encoder_dispatch_exempt must fail here. Got: {exempt_set:?}"
        );
    }
}

// item (f) gate — Makefile fetch target coverage
//
// The `fetch:` recipe must invoke `scripts/fetch-membench.sh` for BOTH
// FirstAgent and ThirdAgent. Removing either invocation makes the corresponding
// assertion fail (gate is red).
//
// `CARGO_MANIFEST_DIR` is the rust/ crate root at compile time; the Makefile
// lives one level up at the suite package root.
#[cfg(test)]
mod makefile_fetch_tests {
    #[test]
    fn fetch_target_covers_both_agents() {
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        // Crate root is <suite root>/rust/; go up one level.
        let makefile = manifest.parent().unwrap().join("Makefile");
        let content = std::fs::read_to_string(&makefile)
            .unwrap_or_else(|e| panic!("cannot read Makefile at {}: {e}", makefile.display()));

        // Gate: both invocations must be present somewhere in the file.
        assert!(
            content.contains("fetch-membench.sh FirstAgent"),
            "Makefile fetch: recipe must invoke scripts/fetch-membench.sh FirstAgent"
        );
        assert!(
            content.contains("fetch-membench.sh ThirdAgent"),
            "Makefile fetch: recipe must invoke scripts/fetch-membench.sh ThirdAgent"
        );

        // Locate the fetch: recipe block and verify both invocations live inside it.
        // The block is the run of tab-prefixed command lines after the `fetch:` line.
        let mut in_fetch = false;
        let mut block = String::new();
        for line in content.lines() {
            if line.starts_with("fetch:") {
                in_fetch = true;
                continue;
            }
            if in_fetch {
                if line.starts_with('\t') {
                    block.push_str(line);
                    block.push('\n');
                } else if line.trim().is_empty() || line.starts_with('#') {
                    // Blank / comment lines inside a recipe are allowed.
                    block.push_str(line);
                    block.push('\n');
                } else {
                    break; // First non-recipe line ends the block.
                }
            }
        }
        assert!(!block.is_empty(), "fetch: recipe block must not be empty");
        assert!(
            block.contains("fetch-membench.sh FirstAgent"),
            "fetch: recipe block must contain fetch-membench.sh FirstAgent"
        );
        assert!(
            block.contains("fetch-membench.sh ThirdAgent"),
            "fetch: recipe block must contain fetch-membench.sh ThirdAgent"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dump-seed parent-directory creation gates
//
// Twin of Swift DumpSeedParentDirTests. Each test drives a CLI command with
// a --dump-seed path whose parent directory does not yet exist and asserts
// that the file lands with non-empty content.
//
// What makes each test go red: removing the `create_dir_all` block before the
// `std::fs::write` in the corresponding lane causes the write to fail ENOENT,
// so the function returns Err and the assert_eq on the file bytes panics.
// ─────────────────────────────────────────────────────────────────────────────
#[cfg(test)]
mod dump_seed_parent_dir_tests {
    fn argv(tokens: &[&str]) -> Vec<String> {
        tokens.iter().map(|t| t.to_string()).collect()
    }

    fn fresh_base(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("dump-seed-parent-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// journey --dump-seed: parent directory created when absent.
    #[test]
    fn journey_dump_seed_creates_parent_dir() {
        let base = fresh_base("journey");
        let dump_path = base.join("new-subdir").join("journey-fixture.json");
        // Precondition: parent does not exist.
        assert!(!base.join("new-subdir").exists(),
            "precondition: parent subdir must be absent");

        let result = super::run_journey(
            &argv(&["--dump-seed", dump_path.to_str().unwrap()]));
        let _ = std::fs::remove_dir_all(&base);
        result.expect("run_journey --dump-seed must succeed");
        // File was removed with the temp dir; just check the run succeeded.
    }

    /// journey --dump-seed: file content is non-empty when parent is created.
    #[test]
    fn journey_dump_seed_file_has_content() {
        let base = fresh_base("journey2");
        let dump_path = base.join("new-subdir").join("journey-fixture.json");
        let result = super::run_journey(
            &argv(&["--dump-seed", dump_path.to_str().unwrap()]));
        assert!(result.is_ok(), "run_journey --dump-seed must succeed: {:?}", result);
        let bytes = std::fs::read(&dump_path).expect("dump file must exist");
        assert!(!bytes.is_empty(), "dump file must be non-empty");
        let _ = std::fs::remove_dir_all(&base);
    }

    /// supersession --dump-seed: parent directory created when absent.
    #[test]
    fn supersession_dump_seed_creates_parent_dir() {
        let base = fresh_base("supersession");
        let dump_path = base.join("new-subdir").join("supersession-seed.json");
        assert!(!base.join("new-subdir").exists(),
            "precondition: parent subdir must be absent");

        let result = super::run_supersession(
            &argv(&["--dump-seed", dump_path.to_str().unwrap()]));
        assert!(result.is_ok(), "run_supersession --dump-seed must succeed: {:?}", result);
        let bytes = std::fs::read(&dump_path).expect("dump file must exist");
        assert!(!bytes.is_empty(), "dump file must be non-empty");
        let _ = std::fs::remove_dir_all(&base);
    }

    /// fact-layer --dump-seed: parent directory created when absent.
    #[test]
    fn fact_layer_dump_seed_creates_parent_dir() {
        let base = fresh_base("fact-layer");
        let dump_path = base.join("new-subdir").join("fact-layer-fixture.json");
        assert!(!base.join("new-subdir").exists(),
            "precondition: parent subdir must be absent");

        let result = super::run_supersession(
            &argv(&["--fact-layer", "--dump-seed", dump_path.to_str().unwrap()]));
        assert!(result.is_ok(), "run_supersession --fact-layer --dump-seed must succeed: {:?}", result);
        let bytes = std::fs::read(&dump_path).expect("dump file must exist");
        assert!(!bytes.is_empty(), "dump file must be non-empty");
        let _ = std::fs::remove_dir_all(&base);
    }
}
