
/// Resolves `--out` and CREATES the directory before the run starts.
///
/// The report is the entire product of a lane run, and it is written last. A
/// missing output directory therefore surfaced only after every unit had been
/// ingested, encoded and scored — the run did all its work and then threw
/// "the file doesn't exist" with nowhere to put the results. On a full-corpus
/// lane that is hours of a quiet-machine window spent for nothing.
///
/// Creating it here makes the failure immediate and the success durable: an
/// unwritable path fails before the first estate is provisioned, and a valid
/// one is guaranteed to exist when the report lands.
///
/// - Returns: the resolved directory, or nil when `--out` was not passed (the
///   lanes then write into the current directory, which necessarily exists).
func resolvedOutputDirectory(in args: [String]) throws -> URL? {
    guard let raw = optionValue("--out", in: args) else { return nil }
    let url = URL(fileURLWithPath: raw)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        throw MCPError(description:
            "--out directory could not be created at \(url.path): \(error.localizedDescription)")
    }
    return url
}

import Foundation
import IntellectusLib
import ObserverSink

// CLI.swift — subcommand parsing + dispatch for the core benchmarker binary
// (the thin executable target's main.swift calls `benchmarkerMain`).
//
// Hand-rolled argument parsing (swift-subprocess is the only external dep —
// no swift-argument-parser). Core subcommands:
//
//   mcp-benchmarker benchmark --config c.json --manifest out.json --report report.json [--compare-source] [--stats-store stats.sqlite]
//   mcp-benchmarker lmeb      --data-dir <dir> [--evidence-types ET1,ET2,...] [--mootx01-binary <path>]
//                             [--limit N] [--offset K] [--seed S] [--out <dir>]
//   mcp-benchmarker locomo    --data-file <locomo10.json> [--mootx01-binary <path>]
//                             [--limit N] [--offset K] [--seed S] [--out <dir>]
//   mcp-benchmarker report    --report report.json
//
// benchmark : manifest-replay verification — verify the manifest against the
//             target, score divergence. DegeneracyGuard runs before scoring.
//             Output labelled "manifest-replay verification."
// report    : pretty-print an existing report.json.
//
// --stats-store : when given, the run emits its real metrics (capture
//             throughput + latency, recall latency, divergence) through
//             IntellectusLib into the ObserverSink PersistenceStatsSink at the
//             named SQLite path. The benchmarker is the first real emitter into
//             the shared stats store. The store's monitoring flag is enabled
//             for the duration of the run so samples land.

/// Usage text shown for `--help`, no subcommand, or a bad invocation.
func usageText() -> String {
    """
    mcp-benchmarker — benchmark and load-test MCP memory servers

    USAGE:
      mcp-benchmarker benchmark --config <c.json> --manifest <out.json> --report <report.json> [--compare-source]
      mcp-benchmarker gauntlet-corpus --seed <N> --out <dir> [--per-tier N] [--distractors N] [--tiers T1=a,T2=b,…]
      mcp-benchmarker gauntlet  --config <c.json> --corpus <dir> --run-label <label> [--out <dir>] [--k 1,5,10] [--limit N] [--quick] [--moot-only]
                        [--seed-path live|batch]
      mcp-benchmarker longmemeval --data-dir <dir> --variant s|m|oracle [--mootx01-binary <path>]
                        [--limit N] [--offset K] [--seed S] [--out <dir>]
                        [--synthesize-arm] [--shape disk|ram] [--parallel N]
      mcp-benchmarker lmeb      --data-dir <dir> [--evidence-types ET1,ET2,...] [--mootx01-binary <path>]
                        [--limit N] [--offset K] [--seed S] [--out <dir>]
                        [--shape disk|ram] [--parallel N]
      mcp-benchmarker locomo    --data-file <locomo10.json> [--mootx01-binary <path>]
                        [--limit N] [--offset K] [--seed S] [--out <dir>]
                        [--strategy search|shaped|precise] [--recall-shape <preset>]
                        [--shape disk|ram] [--parallel N]
      mcp-benchmarker locomo-spec --data-file <locomo10.json> [--mootx01-binary <path>]
                        [--limit N] [--offset K] [--seed S] [--out <dir>]
                        [--encode-barrier drain|impatient|none] [--estate-cache off|reuse|require]
                        [--cache-dir <dir>] [--estate-mode unencrypted|encrypted]
                        [--shape disk|ram] [--parallel N]
                        [--guard-sample once|per-unit] [--run-id <id>]
                        [--dump-answer-inputs <path>] [--answer-hydration-depth N]
                        [--hydration-tier distilled|full]
      mcp-benchmarker artifact-recall --dataset locomo|convomem|membench|lme-s
                        --questions <jsonl>
                        [--target-scale unit|bench-aggregate|complete-aggregate]
                        (--estate-dir <estate dir> | --catalog <catalog.json>)
                        [--scope wing|estate] [--id-prefix <str>] [--limit N]
                        [--top-k K] [--out <report.json>] [--mootx01-binary <path>]
      mcp-benchmarker lme-spec --data-dir <dir> --variant s|m|oracle [--mootx01-binary <path>]
                        [--limit N] [--offset K] [--seed S] [--out <dir>]
                        [--encode-barrier drain|impatient|none] [--estate-cache off|reuse|require]
                        [--cache-dir <dir>] [--estate-mode unencrypted|encrypted]
                        [--shape disk|ram] [--parallel N]
                        [--guard-sample once|per-unit] [--run-id <id>]
                        [--dump-judge-inputs <path>] [--judge-cmd <cmd>] [--judge-model <id>]
                        [--dump-answer-inputs <path>] [--answer-hydration-depth N]
                        [--hydration-tier distilled|full]  (default distilled — production shape)
      mcp-benchmarker lme-agentic --data-dir <dir> --variant s|m|oracle
                        --model <name> --answer-cmd <cmd> [--mootx01-binary <path>]
                        [--cache-dir <dir>] [--max-tool-calls N]
                        [--limit N] [--offset K] [--seed S] [--out <dir>]
                        [--encode-barrier drain|impatient|none]
                        [--guard-sample once|per-unit] [--run-id <id>]
                        [--dump-judge-inputs <path>] [--judge-model <id>]
      mcp-benchmarker membench  --data-dir <MemData/> [--mootx01-binary <path>]
                        [--agent FirstAgent|ThirdAgent] [--category <name>]
                        [--limit N] [--offset K] [--seed S] [--out <dir>]
                        [--shape disk|ram] [--parallel N]
      mcp-benchmarker answer-batch --inputs <answer-inputs.jsonl> --answer-cmd <cmd> --out <path>
                        [--limit N] [--offset N] [--reader-model <id>]
      mcp-benchmarker apple-answer [--max-tokens N]   (default 512; requires macOS 26, Apple Intelligence on)
      mcp-benchmarker report    --report <report.json>
      mcp-benchmarker supersession [--mootx01-binary <path>]
                        [--seed N] [--entities N] [--versions N] [--contradictions N]
                        [--divergences N] [--decoys N]
                        [--k N] [--recall-shape <preset>]
                        [--skip-contradictions] [--skip-dream]
                        [--dump-seed <path.json>] [--estate-mode unencrypted|encrypted|both]
                        [--fact-layer] [--structured-tier] [--seed-path live|batch]
      mcp-benchmarker journey   [--mootx01-binary <path>] [--shape disk|ram]
                        [--run-mode quiet|contended]
                        [--dump-seed <path.json>] [--out <dir>]
                        [--seed N]
                        [--precise-miss-count N] [--cluster-count N]
                        [--members-per-cluster N]
      mcp-benchmarker timing    [--binary <path>] [--mootx01-binary <path>]
                        [--seed N] [--repeats k] [--out <dir>]
                        [--run-mode quiet|contended]
                        [--sizes 2000,10000,100000]   ascending; smaller = smoke run
                        [--landscape-cache <dir>]     restore stored landscapes
                                                      instead of ingesting them
      mcp-benchmarker landscape-build --cache-dir <dir> [--sizes 2000,10000,100000]
                        [--landscape synthetic|corpus] [--landscape-corpus <name>]
                        [--landscape-variant <v>] [--landscape-data-dir <dir>]
                        [--seed N] [--estate-mode <mode>] [--mootx01-binary <path>]
                        builds the timing lane's background rows ahead of the
                        measured run; not measured, may run on a loaded machine
      mcp-benchmarker throughput --lane locomo --data-file <locomo.json> [--mootx01-binary <path>]
                        [--window-seconds N (default 300)] [--parallel N]
                        [--estate-cache require|reuse (default require)] [--cache-dir <dir>]
                        [--limit N] [--offset K] [--seed S] [--out <dir>] [--run-id <id>]
                        sustained-load throughput measurement: cycles units from the pinned
                        subset for the window; output is throughput-<lane>-<serial>.json
                        (timing artifact — no recall figures)

      benchmark accepts --stats-store <stats.sqlite> to
      emit metrics to the ObserverSink stats store for moot-mgr dashboards.

      benchmark: manifest-replay verification. Issues each manifest entry's
        recall query to the live target, computes divergence. Output is labelled
        "manifest-replay verification." Guard applies.

      gauntlet: run and score the MOOT backend (this lane is always
        moot-only; --moot-only is accepted for compatibility with older
        invocations).

      longmemeval: provision a scratch mootx01 estate, ingest LongMemEval
        haystack sessions, and measure session-recall quality. The estate
        lifecycle (provision, teardown) is owned by the runner. The dataset
        must be pre-fetched with scripts/fetch-longmemeval.sh.
        --variant s|m|oracle     which LongMemEval variant file to load
        --data-dir <dir>         directory containing the variant JSON files
        --mootx01-binary <path>  path to the mootx01 binary (auto-discovered if absent)
        --limit N                run only the first N questions
        --offset K               skip the first K questions (default 0)
        --seed S                 seed for deterministic question order (default 20260725)
        --out <dir>              write results to <dir> (default: current directory)
        --synthesize-arm         add moot_synthesize as the fourth answer-payload mode
                                 beside preview / distilled / full-hydrated. Calls
                                 moot_synthesize per question and judges the generated
                                 answer. No retrieval metric — only judge accuracy is
                                 measurable. Off by default. Live runs require the operator's
                                 quiet-machine authorization.
        --synthesize-limit N     forward N as moot_synthesize's limit (tool default
                                 20). The default cap is applied newest-first before
                                 any relevance signal; this knob isolates its effect
                                 on the synthesize cell. Judge transcript entries for
                                 the arm carry the full payload for diagnosis.
        --estate-mode unencrypted|encrypted
                                 unencrypted (default): scratch estates carry the
                                 transient catalog record, created plaintext, no keychain contact.
                                 encrypted: scratch estates are SQLCipher-encrypted under a
                                 TEMPORAL key (harness key file beside the estate) — zero
                                 keychain and zero on-disk key residue; incompatible with
                                 --estate-cache reuse.
                                 --no-plaintext-scratch, which selected the encrypted
                                 posture before --estate-mode existed, is REJECTED —
                                 not aliased. Pass --estate-mode encrypted.

      --judge-cmd and --rerank-cmd accept a shell command string that reads the
      prompt on stdin and writes its answer on stdout (exit 0). Because the
      command may embed API keys, two paths exist:
        --judge-cmd <cmd>            flag: value appears in `ps` argv (visible
                                     to all users on the machine)
        MOOT_BENCH_JUDGE_CMD=<cmd>   env var: not visible in `ps` argv, and
                                     unset before the command runs, so it is
                                     not inherited by the command or its
                                     descendants. It remains readable in THIS
                                     benchmark process's environment while it
                                     runs (same-user process inspection).
        --rerank-cmd <cmd>           flag: same exposure as --judge-cmd
        MOOT_BENCH_RERANK_CMD=<cmd>  env var: same handling as
                                     MOOT_BENCH_JUDGE_CMD
      If the env var is set, it takes precedence over the flag. The command is
      executed via /bin/sh and supports pipes, env-var expansion, and quoted
      args. Only presence (cmd_set: true) is recorded in run reports — command
      text is never logged, hashed, or emitted.

      Unrecognised options are rejected, not ignored: an option this binary does
      not know is an error naming the accepted set. Values are separate arguments
      (--estate-mode encrypted), never joined with '=' .

      locomo: provision per-conversation scratch mootx01 estates, ingest LoCoMo
        conversation turns, and measure turn-level recall quality with per-category
        breakdown (single_hop/temporal/multi_hop/open_domain). The dataset must be
        pre-fetched with scripts/fetch-locomo.sh. License: CC BY-NC 4.0 (non-commercial).
        --data-file <path>       path to locomo10.json
        --mootx01-binary <path>  path to the mootx01 binary (auto-discovered if absent)
        --limit N                run only the first N questions
        --offset K               skip the first K questions (default 0)
        --seed S                 seed for deterministic question order (default 20260725)
        --out <dir>              write results to <dir> (default: current directory)
        --strategy search|shaped|precise|multihop
                                 query verb strategy (default: search).
                                 search: moot_memory_search with location filter (default,
                                   byte-stable — identical to all prior LoCoMo runs).
                                 shaped: moot_recall_shaped; steers the signed-weight
                                   fusion engine; accepts --recall-shape preset.
                                 precise: moot_recall_precise precision-retrieval mode.
                                 multihop: two-pass decompose→pools→RRF-intersect over
                                   moot_memory_search, with a bridge re-query when the
                                   sub-cue pools are disjoint (see LoCoMoMultiHop.swift).
                                 The strategy name appears in the run label and report.
        --category single_hop|temporal|multi_hop|open_domain
                                 run ONE question category as its own cell. Applied
                                 before --limit so the limit counts the requested
                                 category (multi-hop is ~4% of a shuffled slice). The
                                 report's category breakdown states the composition.
        --recall-shape <preset>  named RecallShape preset for --strategy shaped.
                                 Omit to use the product's default (balanced, unsteered).
        --estate-mode unencrypted|encrypted
                                 unencrypted (default): scratch estates carry the
                                 transient catalog record, created plaintext, no keychain contact.
                                 encrypted: scratch estates are SQLCipher-encrypted under a
                                 TEMPORAL key (harness key file beside the estate) — zero
                                 keychain and zero on-disk key residue; incompatible with
                                 --estate-cache reuse.

      lmeb also accepts --estate-mode with the same semantics.

      locomo-spec: provision per-conversation scratch mootx01 estates, ingest LoCoMo
        conversation turns, and evaluate per-question answer quality per the
        official LoCoMo QA scoring protocol (§1–§6): F1 / exact-match / abstention.
        Answers are produced via moot_synthesize (the "existing moot answer-production
        path"). Categories: 1=single_hop, 2=temporal, 3=multi_hop, 4=open_domain,
        5=adversarial. The dataset must be pre-fetched with scripts/fetch-locomo.sh.
        License: CC BY-NC 4.0 (non-commercial).
        --data-file <path>       path to locomo10.json (same fixture as locomo lane)
        --mootx01-binary <path>  path to the mootx01 binary (auto-discovered if absent)
        --limit N                run only the first N questions
        --offset K               skip the first K questions (default 0)
        --seed S                 seed for deterministic question order (default 20260818;
                                 distinct from the locomo lane's 20260725 so the two
                                 lanes produce different shuffle orders)
        --out <dir>              write results to <dir> (default: current directory)
        --encode-barrier drain|impatient|none
                                 drain (default): poll moot_drain_status after ingest.
                                 impatient: per-turn impatient:true inline encoding.
                                 none: no barrier — documents the encoding race.
        --estate-cache off|reuse|require
                                 off (default): fresh ingest every run.
                                 reuse: restore snapshot when present; build when absent.
                                 require: restore snapshot; fail hard when absent (B7).
        --cache-dir <dir>        root for estate snapshots (default: <out>/estate-cache)
        --estate-mode unencrypted|encrypted
                                 unencrypted (default): scratch estates carry the
                                 transient catalog record, created plaintext, no keychain contact.
                                 encrypted: scratch estates are SQLCipher-encrypted under a
                                 TEMPORAL key (harness key file beside the estate) — zero
                                 keychain and zero on-disk key residue; incompatible with
                                 --estate-cache reuse.
        --shape disk|ram         disk (default): SQLite-on-disk scratch estate.
                                 ram: ephemeral in-memory estate (serve --in-memory);
                                 incompatible with --estate-cache reuse|require.
        --parallel N             max conversations to process concurrently
                                 (default: ~80% of logical cores)
        --guard-sample once|per-unit
                                 once (default): probe the DegeneracyGuard once per run.
                                 per-unit: probe before every conversation.
        --run-id <id>            serial embedded in the record filename stem
                                 (locomo-spec-<arm>-<id>.json). Supplied by make.

      lme-spec: official LongMemEval QA evaluation protocol (LONGMEMEVAL_OFFICIAL_PROTOCOL.md §1–§4).
        Provisions a fresh scratch estate per question, ingests LongMemEval haystack sessions,
        and evaluates per-question answer quality. Answers are produced via moot_synthesize.
        ALL 500 instances, including abstentions, flow through the full ask path (§6 row 2 fix).
        Judge calls use byte-exact §2 anscheck prompts and §3 call parameters (n=1, temp 0,
        max_tokens 10). Aggregation: per-type, task-averaged, overall, abstention accuracy (§4).
        The dataset must be pre-fetched with scripts/fetch-longmemeval.sh.
        Record naming: lme-spec-<variant>-<serial>.json + params sidecar.
        lme-spec artifact cache entries are DISTINCT from longmemeval entries even for the
        same variant (the artifact provenance benchmark field is "lme-spec", not "longmemeval").
        Run artifacts-lme-spec before measure-lme-spec with --estate-cache require.
        --data-dir <dir>         directory containing the variant JSON files (same as longmemeval)
        --variant s|m|oracle     which LongMemEval variant to evaluate (required)
        --mootx01-binary <path>  path to the mootx01 binary (auto-discovered if absent)
        --limit N                run only the first N questions
        --offset K               skip the first K questions (default 0)
        --seed S                 seed for deterministic question order (default 20260725)
        --out <dir>              write results to <dir> (default: current directory)
        --encode-barrier drain|impatient|none
                                 drain (default): poll moot_drain_status after ingest.
                                 impatient: per-turn impatient:true inline encoding.
                                 none: no barrier — documents the encoding race.
        --estate-cache off|reuse|require
                                 off (default): fresh ingest every run.
                                 reuse: restore snapshot when present; build when absent.
                                 require: restore snapshot; fail hard when absent (B7).
        --cache-dir <dir>        root for estate snapshots (default: <out>/estate-cache)
        --estate-mode unencrypted|encrypted
                                 unencrypted (default): scratch estates carry the
                                 transient catalog record, created plaintext, no keychain contact.
                                 encrypted: scratch estates are SQLCipher-encrypted under a
                                 TEMPORAL key (harness key file beside the estate) — zero
                                 keychain and zero on-disk key residue; incompatible with
                                 --estate-cache reuse.
        --shape disk|ram         disk (default): SQLite-on-disk scratch estate.
                                 ram: ephemeral in-memory estate (serve --in-memory);
                                 incompatible with --estate-cache reuse|require.
        --parallel N             max questions to run concurrently (default: ~80% of cores)
        --guard-sample once|per-unit
                                 once (default): probe the DegeneracyGuard once per run.
                                 per-unit: probe before every question.
        --run-id <id>            serial embedded in the record filename stem
                                 (lme-spec-<variant>-<id>.json). Supplied by make.
        --dump-judge-inputs <path>
                                 write §1–§3 judge-input JSONL to <path> for offline judging.
                                 Each line: {"type":"question","question_id":…,
                                 "anscheck_prompt":…,"model":"gpt-4o-2024-08-06",
                                 "n":1,"temperature":0,"max_tokens":10,…}.
                                 Consume offline with the judge-batch subcommand.
        --judge-cmd <cmd>        shell command for inline judging (reads §2 anscheck
                                 prompt on stdin, writes yes/no on stdout; exit 0).
                                 SECURE PATH: use MOOT_BENCH_JUDGE_CMD env var instead —
                                 the flag value appears in `ps` argv, the env var does not.
                                 Env var takes precedence when both are set.
        --judge-model <id>       §3 model identifier recorded in every judge-input dump
                                 line and verdict record (default: gpt-4o-2024-08-06;
                                 any external model name is accepted).
        --dump-answer-inputs <path>
                                 reader-model flow: write one answer_input JSONL line per
                                 question after retrieval. Each line carries the question,
                                 memory_texts (hydrated at the chosen tier), and the
                                 moot_synthesize hypothesis digest for reference.
                                 Consume offline with the answer-batch subcommand.
        --answer-hydration-depth N
                                 number of drawer texts to hydrate per question via
                                 moot_memory_get (default 10).
        --hydration-tier distilled|full
                                 depth tier passed to moot_memory_get for answer-input
                                 hydration. distilled (default) is the production shape —
                                 the reader sees what a real caller would receive. full is
                                 the comparison arm. Rows without a distillate fall back to
                                 full content on the server side (marked served_from_content).

      lme-agentic: OFFICIAL-protocol agentic answering arm. Per question, spawns
        mootx01 serve on that question's PREBUILT estate (restored from the lme-spec
        artifact store; a missing artifact is a hard error — this lane never builds,
        run artifacts-lme-spec first) and hands an external answering AI the question
        plus the estate's read-only MCP tool surface. The AI may make MULTIPLE tool
        calls before answering; the final answer becomes the official hypothesis
        ({"question_id":…,"hypothesis":…} JSONL, judged via the same offline
        judge-batch path as lme-spec). Per-question tool-call count and reported
        token usage are recorded beside the official fields; the answering model
        NAME goes into the report and params sidecar so no score is unattributed.
        The AI seam is an external command: one JSON request on stdin → one JSON
        response on stdout per turn (shape documented in LMEAgenticRunner.swift).
        --data-dir <dir>         directory containing the variant JSON files
        --variant s|m|oracle     which LongMemEval variant to evaluate (required)
        --model <name>           the answering model's name, recorded verbatim (required)
        --answer-cmd <cmd>       the external answering command (required).
                                 SECURE PATH: use MOOT_BENCH_ANSWER_CMD env var instead —
                                 the flag value appears in `ps` argv, the env var does not.
                                 Env var takes precedence when both are set.
        --max-tool-calls N       per-question tool-call budget (default 15)
        --mootx01-binary <path>  path to the mootx01 binary (auto-discovered if absent)
        --cache-dir <dir>        root of the lme-spec artifact store
                                 (default: <out>/estate-cache)
        --limit N / --offset K / --seed S
                                 question selection; same seeded shuffle as lme-spec, so
                                 equal values address the same artifact entries
                                 (seed default 20260725)
        --out <dir>              write results to <dir> (default: current directory)
        --encode-barrier drain|impatient|none
                                 must match the barrier the ARTIFACTS were built under
                                 (cache-key component; default drain)
        --guard-sample once|per-unit
                                 once (default): probe the DegeneracyGuard once per run.
        --run-id <id>            serial embedded in the record filename stem
                                 (lme-agentic-<variant>-<id>.json). Supplied by make.
        --dump-judge-inputs <path>
                                 write §2 anscheck judge-input JSONL for offline judging
                                 (same consume path as lme-spec dumps)
        --judge-model <id>       §3 model identifier recorded in dump lines
                                 (default: gpt-4o-2024-08-06)

      membench: provision per-item scratch mootx01 estates, ingest all session turns
        per item, and measure turn-level recall quality with per-category breakdown
        (simple/comparative/aggregative/conditional/knowledge_update/
        post_processing/noisy). Each item gets its own fresh estate (per-item model,
        parallel to LME). The dataset must be pre-fetched with
        scripts/fetch-membench.sh. License: see dataset repo (no explicit license
        found as of 2026-08-06; for research/internal diagnostic use only).
        --data-dir <path>        MemData directory containing FirstAgent/ or ThirdAgent/
        --mootx01-binary <path>  path to the mootx01 binary (auto-discovered if absent)
        --agent FirstAgent|ThirdAgent
                                 which agent perspective to load (default: FirstAgent)
        --category <name>        run ONE category as its own cell (e.g. simple, noisy).
                                 Applied before --limit so the limit counts items of the
                                 requested category. nil = all LowLevel categories.
        --limit N                run only the first N items
        --offset K               skip the first K items (default 0)
        --seed S                 seed for deterministic item order (default 20260806)
        --out <dir>              write results to <dir> (default: current directory)
        --encode-barrier drain|impatient|none
                                 drain (default): poll moot_drain_status after ingest.
                                 impatient: per-turn impatient:true inline encoding.
                                 none: no barrier — documents the encoding race.
        --estate-mode unencrypted|encrypted
                                 unencrypted (default): scratch estates carry the
                                 transient catalog record, created plaintext, no keychain contact.
                                 encrypted: scratch estates are SQLCipher-encrypted under a
                                 TEMPORAL key (harness key file beside the estate) — zero
                                 keychain and zero on-disk key residue.

      supersession: one persistent estate, chronologically-ingested fact timeline,
        scoring on whether the CURRENT version of a changed attribute outranks its
        superseded versions in recall results. Measures history-dependent behaviour
        the public benchmarks cannot observe (they provision a fresh estate per
        question). See SupersessionCorpus.swift for the design rationale and the
        fairness rule that governs what may be scored here.
        --entities N             number of entity chains (default 40)
        --versions N             versions per chain (default 3)
        --contradictions N       planted contradiction pairs (default 10)
        --divergences N          planted digit-valued divergence pairs (tier-3
                                 class: same entity + attribute, numeric values
                                 differing, one shared event_time; default 5)
        --decoys N               planted adversarial NON-contradictions that must
                                 fire at no tier (default 5). Three shapes cycle:
                                 supersession-marker chain, distinct-entity
                                 same-value pair, unit-equivalent value pair (the
                                 last is a known tier-3 limitation, scored in its
                                 own row)
        --k N                    contamination window for stale-in-top-k (default 10)
        --recall-shape <preset>  run queries with moot_recall_shaped and this preset
                                 instead of plain moot_memory_search
        --skip-contradictions    omit the moot_hunt_contradictions sweep
        --skip-dream             omit moot_dream (compares virgin vs dreamed estates)
        --dump-seed <path>       write the generated seed JSON (schema v1, the
                                 moot_json_import interchange format) and exit
                                 (no binary needed)
        --seed-path live|batch   how the seed loads into the estate (default batch:
                                 one moot_json_import; live: per-record capture,
                                 the slow lane kept for equivalence re-proving)
        --estate-mode unencrypted|encrypted|both
                                 unencrypted: scratch estate is plaintext (transient catalog record).
                                 encrypted: SQLCipher-encrypted under a TEMPORAL key
                                   (harness key file beside the estate) — zero keychain and
                                   zero on-disk key residue. Incompatible with
                                   --estate-cache reuse.
                                 both: run the lane TWICE — once per posture, each with its
                                   own scratch estate (provisioned and torn down independently).
                                   Corpus is generated ONCE (same seed) and both postures
                                   ingest the identical corpus. Prints both scorecards plus an
                                   "estate-mode delta (encrypted − unencrypted):" section
                                   comparing CURRENT-OVER-STALE rate, current found rate,
                                   mean stale@k, mean current rank, and query p50.
                                 Default: encrypted (ephemeral key, zero residue).
        --structured-tier        After the ranking queries and lexical sweep,
                                 file one KGFact per corpus record (anchored
                                 to its ingest drawer) and score the TYPED proving
                                 lane: planted pairs proven, and false proofs
                                 outside the planted set (must be 0).
        --fact-layer             INTERNAL CAPABILITY CELL. Switches the estate to the
                                 structured-fact lifecycle: file via moot_file_fact,
                                 retire non-current versions via moot_retire_fact,
                                 query via moot_fact_search. Ground truth is keyed on
                                 fact UUIDs, not drawer UUIDs. This cell is NOT part of
                                 the fairness-rule comparative lane; every report carrying
                                 it carries cell_type: internal_capability.
      replay:   same seed twice → identical scored outcomes; timing excluded.
                Proves end-to-end replay determinism by running the full
                supersession lane N times (default 2) with the same seed,
                each on a freshly provisioned scratch estate, then comparing
                the deterministic-eligible outcome fields across runs. Prints
                a per-field MATCH/DRIFT table. Exit 0 when all fields match
                across all runs; exit 1 on any drift.
                --runs N                 replay iterations (default 2, minimum 2)
                --estate-mode unencrypted|encrypted
                                         posture for all scratch estates. "both" is
                                         NOT accepted: replay compares runs of the
                                         SAME posture, not two postures. Default:
                                         encrypted.
                All --seed/--entities/--versions/--contradictions/--k/
                --recall-shape/--skip-contradictions/--skip-dream/
                --structured-tier flags are accepted with the same semantics
                as the supersession subcommand.

      capturespread-corpus: generate a capture-spread corpus (seed-file + probe file)
        without running any lane. Both files go to --out.
        --seed N                 generator seed (default 42)
        --probes N               probe topic count (default 50)
        --distractors N          distractor topic count (default 150)
        --variant spread|burst   seed file variant to emit (default spread)
        --out <dir>              output directory (default: current directory)

      capturespread: run the capture-spread benchmark lane.
        ONE estate for all probes (whole corpus ingested once).
        Two build variants via --variant:
          spread  records keep their designed captureDate → distinct HLC values
          burst   captureDate stripped → batch wall-clock (control cell)
        --mootx01-binary <path>  path to the mootx01 binary
        --corpus <path>          .probes.json from capturespread-corpus
        --seed N                 generate corpus on-the-fly with this seed (default 42)
        --probes N               probe count when generating on-the-fly (default 50)
        --distractors N          distractor count (default 150)
        --variant spread|burst   build variant (default spread)
        --recall-shape <preset>  named RecallShape preset (default matrix_decayed)
        --k N                    top-k for recall scoring (default 10)
        --estate-cache off|reuse|require  (default off)
        --cache-dir <dir>        cache root directory
        --out <dir>              output directory for report JSON
        --run-id <id>            caller-supplied run ID

    """
}

/// Returns the value following `--name`, or nil if the flag is absent or has
/// no value after it.
public func optionValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// True when a bare flag (no value) is present.
public func flagPresent(_ name: String, in args: [String]) -> Bool {
    args.contains(name)
}

/// Parses a count-like option that carries a real lower bound, or throws.
///
/// REJECT, DO NOT CLAMP. A benchmark run whose parameters were silently
/// corrected reports numbers labelled with what the operator asked for and
/// measured with something else, which is worse than no run at all. Every
/// failure path here names the option, the supplied value, and the
/// constraint; the error propagates out of `benchmarkerMain` as exit 1.
///
/// `minimum` is the smallest value that keeps the generated corpus
/// well-formed — never a matter of taste. Each call site carries a comment
/// citing the generator code that would break below it.
///
/// Twin of Rust `validated_count`.
public func validatedCount(_ name: String,
                           in args: [String],
                           default defaultValue: Int,
                           minimum: Int) throws -> Int {
    guard let raw = optionValue(name, in: args) else { return defaultValue }
    guard let value = Int(raw) else {
        throw MCPError(description:
            "\(name) must be an integer >= \(minimum); got '\(raw)'")
    }
    guard value >= minimum else {
        throw MCPError(description:
            "\(name) must be >= \(minimum); got \(value)")
    }
    return value
}

/// Parses `--limit` as a non-negative integer, or nil when absent.
///
/// A negative `--limit` is a CLI error: silently clamping or ignoring a
/// negative value would produce a run labelled with what the operator asked
/// for and measured with something else. Any `Collection.prefix` call on a
/// negative value also traps at runtime. Twin of Rust `parse_limit_option`.
public func parseLimitOption(in args: [String]) throws -> Int? {
    guard let raw = optionValue("--limit", in: args) else { return nil }
    guard let value = Int(raw) else {
        throw MCPError(description: "--limit must be a non-negative integer; got '\(raw)'")
    }
    guard value >= 0 else {
        throw MCPError(description: "--limit must be non-negative; got \(value)")
    }
    return value
}

/// A comma-separated ascending list of positive sizes, or a usage error.
///
/// Used by the timing lane's `--sizes` override. The list must ASCEND because
/// the landscape is built monotonically — each segment starts where the
/// previous one ended, so a descending entry would ask for a negative delta.
/// Equal neighbours are rejected for the same reason: a zero-row segment is a
/// checkpoint that measures nothing.
public func validatedAscendingSizes(_ name: String,
                                    in args: [String],
                                    default defaultValue: [Int]) throws -> [Int] {
    guard let raw = optionValue(name, in: args) else { return defaultValue }
    let fields = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard !fields.isEmpty else {
        throw MCPError(description: "\(name) must list at least one size; got '\(raw)'")
    }
    var sizes: [Int] = []
    for field in fields {
        guard let value = Int(field), value > 0 else {
            throw MCPError(description:
                "\(name) entries must be positive integers; got '\(field)'")
        }
        if let last = sizes.last, value <= last {
            throw MCPError(description:
                "\(name) must ascend — each size starts where the previous ended; "
                + "got \(value) after \(last)")
        }
        sizes.append(value)
    }
    return sizes
}

/// A required option, or a usage error.
public func requireOption(_ name: String, in args: [String]) throws -> String {
    guard let value = optionValue(name, in: args) else {
        throw MCPError(description: "missing required option \(name)")
    }
    return value
}

// MARK: - Option-surface validation

/// The accepted option surface of one subcommand: options that take a value as
/// the following argument, and bare flags that take none.
///
/// The split is load-bearing for validation, not decoration. The token after a
/// VALUED option is skipped, so `--seed -1` does not read `-1` as an option.
/// The token after a BARE flag is not skipped, which is what lets
/// `--skip-dream --typo` be caught.
public struct OptionSurface: Sendable {
    /// Options whose value is the next argument.
    public let valued: Set<String>
    /// Flags that carry no value.
    public let bare: Set<String>

    public init(valued: Set<String>, bare: Set<String> = []) {
        self.valued = valued
        self.bare = bare
    }

    /// Every accepted name, sorted, for the failure message.
    var acceptedNames: [String] { (valued.union(bare)).sorted() }
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
/// `unencrypted` → `.plaintextTransient`, which writes the transient-record plaintext rule:
/// an invocation still carrying the retired name ran PLAINTEXT while its
/// author believed it had asked for encryption, and nothing said so.
public let retiredOptions: [String: String] = [
    "--no-plaintext-scratch": "--estate-mode encrypted",
]

/// Every subcommand of `mcp-benchmarker` and the options it accepts.
///
/// This table is the whole reason an unrecognised argument can be rejected at
/// all: each parser reads its own options by name, so without a declared
/// surface there is nothing to compare a stray token against. A new option
/// MUST be added here in the same commit that teaches a parser to read it —
/// otherwise the parser reads it and the validator rejects it.
///
/// Asymmetry with the Rust twin's table is expected and intentional: the two
/// ports deliberately take different names for some of the same inputs (Swift
/// `--data-file` / `--mootx01-binary` where Rust takes `--corpus` /
/// `--binary`), and the Swift binary carries subcommands the Rust one does not.
// NOTE: the "transfer" subcommand and its OptionSurface are not part of this
// benchmarker and are not registered here.
public let optionSurfaces: [String: OptionSurface] = [
    "benchmark": OptionSurface(
        valued: ["--config", "--manifest", "--report", "--stats-store"],
        bare: ["--compare-source"]),
    "gauntlet-corpus": OptionSurface(
        valued: ["--distractors", "--out", "--per-tier", "--seed", "--tiers"]),
    "gauntlet": OptionSurface(
        valued: ["--run-id", "--config", "--corpus", "--k", "--limit", "--out", "--run-label",
                 "--seed-path"],
        bare: ["--moot-only", "--quick", "--reuse-backends"]),
    // longmemeval and locomo reach --estate-mode/--estate-cache through
    // parseEstateMode; the surface names what the subcommand accepts, not
    // which function reads it.
    "longmemeval": OptionSurface(
        valued: ["--run-id", "--arm", "--binary", "--cache-dir", "--corpus", "--data-dir",
                 "--dump-judge-inputs",
                 "--encode-barrier", "--estate-cache", "--estate-mode",
                 "--exact-strategy", "--judge-cmd",
                 "--judge-grading", "--judge-hydration-depth", "--limit",
                 "--mootx01-binary", "--offset", "--out", "--recall-shape",
                 "--rerank-cmd",
                 "--parallel", "--shape", "--seed", "--seed-path", "--slice", "--synthesize-limit", "--variant"],
        bare: ["--settle",
               "--synthesize-arm", "--timing-sidecar"]),
    "locomo": OptionSurface(
        valued: ["--run-id", "--binary", "--cache-dir", "--category", "--corpus",
                 "--data-file", "--encode-barrier", "--estate-cache",
                 "--estate-mode", "--limit",
                 "--mootx01-binary", "--offset", "--out", "--recall-shape",
                 "--rerank-cmd",
                 "--parallel", "--shape", "--seed", "--seed-path", "--strategy"],
        bare: ["--timing-sidecar"]),
    // locomo-spec: official LoCoMo QA protocol (§1–§6). Uses the same corpus fixture
    // as the locomo lane but evaluates answer quality (F1/exact/abstention) rather
    // than recall@k/MRR. No --strategy/--category/--recall-shape/--rerank-cmd:
    // the spec lane always uses moot_synthesize for answer production and scores
    // all five categories. --seed-path is always batch; the estate topology is
    // always per-conversation.
    // artifact-recall: read-only recall measurement against PRE-BUILT
    // benchmark artifacts, all four datasets (#94 measure seam). No seeding,
    // no scratch estate: --target-scale picks unit (--catalog, resolved per
    // dataset catalog.json) or an aggregate (--estate-dir); id-map.json inside
    // each estate maps seed record ids to drawer UUIDs for scoring; --id-prefix
    // defaults to "<dataset>/" at complete-aggregate (the build-plumbing
    // record-id prefix). --binary is the Rust twin's spelling of
    // --mootx01-binary (accepted for contract parity).
    "artifact-recall": OptionSurface(
        valued: ["--dataset", "--target-scale", "--estate-dir", "--catalog",
                 "--id-prefix", "--questions", "--scope", "--limit",
                 "--top-k", "--out", "--mootx01-binary", "--binary"]),
    // payload-economics: the two mechanical payload lanes (run book §9).
    // --synthesize-arm selects the synthesis-payload lane; --payload-arm
    // v0..v5 selects a harness-side shape variant (MOOT_BENCH_PAYLOAD_ARM
    // copy-on-write clone of the artifact with exactly that minter set
    // --target-scale: the lane's artifact dependency is fixed to the
    // selected port's Form-2 lme-s estate.
    // INVARIANT: every flag runPayloadEconomics reads via optionValue MUST
    // be registered here.
    "payload-economics": OptionSurface(
        valued: ["--estate-dir", "--questions", "--data-dir", "--variant",
                 "--synthesize-limit", "--payload-arm",                  "--limit", "--top-k",
                 "--out", "--mootx01-binary", "--binary"],
        bare: ["--synthesize-arm"]),
    "locomo-spec": OptionSurface(
        valued: ["--run-id", "--binary", "--corpus", "--data-file",
                 "--answer-hydration-depth", "--dump-answer-inputs",
                 "--hydration-tier",
                 "--target-scale", "--catalog", "--estate-dir",
                 "--guard-sample", "--limit", "--mootx01-binary",
                 "--offset", "--out", "--parallel",
                 "--recall-shape",      // shaped-recall preset (moot_recall_shaped)
                 "--request-limit",     // per-query MCP request cap
                 "--scoring",
                 "--seed",
                 "--short-query-terms"], // token budget for short-query sub-metric
        bare: ["--pool-metrics"]),      // expose pool-coverage metrics in the report
    // lme-spec: official LongMemEval QA evaluation protocol (LONGMEMEVAL_OFFICIAL_PROTOCOL.md §1–§4).
    // Uses the same corpus fixture as the longmemeval lane but evaluates answer quality
    // (LLM-judged accuracy per §4: task-averaged, overall, abstention) rather than
    // recall@k/MRR. All 500 instances including abstentions flow through the full ask path.
    // Answers are produced via moot_synthesize; judging is the BYOAI seam (§3 verdict rule).
    // --seed-path is always batch; fresh-per-question is always true.
    // INVARIANT: every flag runLMESpec reads via optionValue MUST be registered here.
    "lme-spec": OptionSurface(
        valued: ["--run-id", "--binary", "--corpus",
                 "--answer-hydration-depth", // reader-model flow: drawer texts to hydrate per question
                 "--hydration-tier",         // reader-model flow: distilled (default) or full
                 "--data-dir", "--dump-answer-inputs", // reader-model flow: answer-input JSONL dump
                 "--dump-judge-inputs",  // §1: judge-input JSONL dump path
                 "--estate-dir",    // aggregate estate path (bench-aggregate / complete-aggregate)
                 "--catalog",       // catalog.json path (unit scale)
                 "--guard-sample",
                 "--judge-cmd",     // §3: inline judge subprocess (SECURE: prefer env var)
                 "--judge-model",   // §3: model identifier (default: gpt-4o-2024-08-06)
                 "--limit", "--mootx01-binary", "--offset", "--out",
                 "--seed", "--target-scale", "--variant"]),
    // lme-agentic: OFFICIAL-protocol agentic answering arm. An external AI
    // (--answer-cmd; MOOT_BENCH_ANSWER_CMD env preferred for secrecy) answers
    // each question by querying the estate itself over the MCP tool surface,
    // with multiple tool calls allowed. Estates are restored from the lme-spec
    // artifact store under require semantics — this lane NEVER builds; run
    // artifacts-lme-spec first. No --estate-cache/--estate-mode/--shape/
    // --parallel flags: require, plaintext, disk, serial are the lane's only
    // modes. Swift only — the Rust benchmarker has no lme-agentic subcommand
    // (declared asymmetry, mission LME-AGENTIC).
    // INVARIANT: every flag runLMEAgenticCommand reads via optionValue MUST
    // be registered here.
    "lme-agentic": OptionSurface(
        valued: ["--run-id",
                 "--answer-cmd",     // the external AI seam (SECURE: prefer env var)
                 "--binary", "--cache-dir", "--corpus",
                 "--data-dir", "--dump-judge-inputs",
                 "--encode-barrier", "--guard-sample",
                 "--judge-model", "--limit",
                 "--max-tool-calls", // per-question tool-call budget (default 15)
                 "--model",          // answering model NAME, recorded in params
                 "--mootx01-binary", "--offset", "--out",
                 "--seed", "--variant"]),
    "membench": OptionSurface(
        valued: ["--run-id", "--agent", "--binary", "--capacity-tier", "--category", "--data-dir",
                 "--encode-barrier", "--estate-cache", "--estate-mode", "--limit",
                 "--mootx01-binary", "--offset", "--out", "--parallel", "--cache-dir", "--seed",
                 "--seed-path", "--shape"],
        bare: ["--timing-sidecar"]),
    // membench-spec: official MemBench protocol (MEMBENCH_OFFICIAL_PROTOCOL.md
    // §2–§6). §3 answers come from --answer-cmd (BYOAI; MOOT_BENCH_ANSWER_CMD env
    // preferred for secrecy) or the --dump-answer-inputs/--consume-answers offline
    // pair — never a letter-scan heuristic. --capacity <default|b1,b2,...> switches
    // to the §6 step_cap walk with the given token-bucket boundaries. Standard
    // mode opens pre-built artifact estates; step_cap keeps
    // fresh-estate-per-item (there, building IS the measurement) and retains
    // encode-barrier, estate-mode, and shape for that path only.
    // INVARIANT: every flag runMemBenchSpec reads via optionValue MUST be here.
    "membench-spec": OptionSurface(
        valued: ["--run-id", "--agent",
                 "--answer-cmd",         // §3: BYOAI answering command
                 "--binary",
                 "--capacity",           // §6: step_cap mode + bucket boundaries
                 "--category",
                 "--consume-answers",    // §3 offline: pre-scored answers JSONL
                 "--data-dir",
                 "--dump-answer-inputs", // §3 offline: answer-prompt dump JSONL
                 "--encode-barrier",     // step_cap mode only
                 "--estate-dir",         // aggregate estate path
                 "--estate-mode",        // step_cap mode only
                 "--catalog",            // catalog.json path (unit scale)
                 "--limit",
                 "--mootx01-binary", "--offset", "--out",
                 "--scoring",            // search scoring strategy (raw|rrf|matrixAware|discriminative)
                 "--seed", "--shape",    // step_cap mode only
                 "--seed-units-dir",     // lineage id-map fallback: dir of per-unit seed JSONs
                 "--target-scale"]),
    "lmeb": OptionSurface(
        valued: ["--run-id", "--binary", "--cache-dir", "--data-dir", "--dump-judge-inputs",
                 "--encode-barrier",
                 "--estate-cache", "--estate-mode",
                 "--evidence-types",
                 "--judge-cmd", "--judge-grading", "--judge-hydration-depth",
                 "--limit", "--mootx01-binary", "--offset", "--out", "--parallel",
                 "--seed", "--seed-path", "--shape"],
        bare: ["--timing-sidecar"]),
    // lmeb-spec: official LMEB retrieval protocol (LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md
    // §A1–§A4): full metric grid at k∈{1,5,10,25,50} + R_cap, two-level aggregation,
    // --instruction-setting per §A4. INVARIANT: every flag runLMEBSpec /
    // parseLMEBSpecInvocation reads via optionValue MUST be registered here.
    "lmeb-spec": OptionSurface(
        valued: ["--run-id", "--binary", "--data-dir",
                 "--estate-dir",          // aggregate estate path
                 "--evidence-types",
                 "--catalog",             // catalog.json path (unit scale)
                 "--instruction-setting", // §A4: without|with
                 "--limit", "--mootx01-binary", "--offset", "--out",
                 "--parallel", "--recall-shape", "--request-limit",
                 "--scoring", "--seed",
                 "--short-query-terms",   // token budget for short-query sub-metric
                 "--target-scale", "--guard-sample"],
        bare: ["--pool-metrics"]),       // expose pool-coverage metrics in the report
    // convomem-spec: official ConvoMem judged-QA protocol (§B1–§B4). §B1 answers
    // via --answer-cmd (BYOAI; MOOT_BENCH_ANSWER_CMD env preferred), §B2/§B3
    // judging via --judge-cmd (MOOT_BENCH_JUDGE_CMD env preferred); offline dump
    // paths for both. INVARIANT: every flag runConvoMemSpec /
    // parseLMEBSpecInvocation reads via optionValue MUST be registered here.
    "convomem-spec": OptionSurface(
        valued: ["--run-id",
                 "--answer-cmd",           // §B1: BYOAI answering command
                 "--binary",
                 "--consume-answers",      // §B2 offline: judge an answer-batch output
                 "--data-dir",
                 "--dump-answer-inputs",   // §B1 offline: answer-input dump JSONL
                 "--dump-judge-inputs",    // §B2 offline: judge-input dump JSONL
                 "--estate-dir",           // aggregate estate path
                 "--evidence-types",
                 "--catalog",              // catalog.json path (unit scale)
                 "--hydration-tier",       // §B1: distilled (default) or full
                 "--instruction-setting",  // shared parse; recorded per run
                 "--judge-cmd",            // §B2/§B3: judge command
                 "--judge-hydration-depth",// §B1: memory texts per prompt
                 "--judge-model",          // §B4: judge identity string
                 "--limit", "--mootx01-binary", "--offset", "--out",
                 "--parallel", "--seed", "--target-scale", "--guard-sample"]),
    "supersession": OptionSurface(
        valued: ["--run-id", "--binary", "--contradictions", "--decoys", "--divergences",
                 "--dump-seed", "--entities",
                 "--estate-cache", "--estate-mode", "--guard-sample", "--k",
                 "--mootx01-binary", "--recall-shape", "--run-mode", "--seed",
                 "--seed-path", "--shape", "--versions"],
        bare: ["--fact-layer", "--skip-contradictions", "--skip-dream",
               "--structured-tier"]),
    // Every flag the live runner reads is registered here. An unregistered
    // flag is silently unreachable: the validator rejects the invocation
    // before the runner sees it, so a lane can read a flag its own CLI
    // refuses. --k, --binary and --estate-mode were missing when the live
    // runner landed, which made the live path unreachable through this CLI.
    "journey": OptionSurface(
        valued: ["--run-id", "--binary", "--cluster-count", "--dump-seed",
                 "--estate-mode", "--k", "--members-per-cluster",
                 "--mootx01-binary", "--out", "--precise-miss-count",
                 "--run-mode", "--seed", "--shape"]),
    // replay: the supersession lane's determinism probe. Accepts the same
    // corpus-shaping and recall flags as supersession, plus --runs. Does NOT
    // accept --dump-seed, --fact-layer, or --estate-mode both (those are
    // supersession-only; replay compares runs of one posture, not postures).
    "replay": OptionSurface(
        valued: ["--binary", "--contradictions", "--entities",
                 "--estate-mode", "--guard-sample", "--k", "--mootx01-binary",
                 "--recall-shape", "--run-mode", "--runs", "--seed", "--seed-path",
                 "--shape", "--versions"],
        bare: ["--lane-capture", "--skip-contradictions", "--skip-dream", "--structured-tier"]),
    "timing": OptionSurface(
        valued: ["--run-id", "--binary", "--estate-mode", "--landscape", "--landscape-cache",
                 "--landscape-corpus", "--landscape-data-dir", "--landscape-variant",
                 "--mootx01-binary", "--out", "--repeats", "--run-mode", "--seed",
                 "--sizes"]),
    "landscape-build": OptionSurface(
        valued: ["--binary", "--cache-dir", "--estate-mode", "--landscape",
                 "--landscape-corpus", "--landscape-data-dir", "--landscape-variant",
                 "--mootx01-binary", "--seed", "--sizes"]),
    "refresh": OptionSurface(
        valued: ["--cache-dir", "--mootx01-binary", "--lane", "--parallel", "--estate-mode"]),
    "matrix": OptionSurface(
        valued: ["--run-id", "--cache-dir", "--k", "--lane", "--limit", "--mootx01-binary",
                 "--out", "--probes", "--run-mode", "--seed"]),
    "convert": OptionSurface(valued: ["--source", "--dest", "--key-hex"], bare: ["--verify"]),
    "report": OptionSurface(valued: ["--report"]),
    "judge-batch": OptionSurface(
        valued: ["--inputs", "--judge-cmd", "--judge-grading", "--out"]),
    // answer-batch: runs an offline answer pass against a dump produced by
    // convomem-spec --dump-answer-inputs or membench-spec --dump-answer-inputs.
    // Dispatches on the "benchmark" field in the dump header.
    "answer-batch": OptionSurface(
        valued: ["--inputs", "--answer-cmd", "--out", "--limit",
                 "--offset", "--reader-model",
                 "--judge-model"]),  // lme-spec: judge identity recorded in judge_ready lines
    // apple-answer: reads a prompt from stdin, generates through Apple
    // Foundation Models (macOS 26+, Apple Intelligence required), prints the
    // reply to stdout. Satisfies the answer-cmd contract so it can be passed
    // directly to answer-batch via scripts/apple-reader.sh.
    "apple-answer": OptionSurface(
        valued: ["--context-tokens", "--max-tokens", "--mode", "--note-cap", "--pick-k", "--round-budget"],
        bare:   ["--guided"]),
    // capturespread-corpus: generates a corpus JSON + probe file for the
    // capture-spread benchmark. No binary needed — pure generator.
    "capturespread-corpus": OptionSurface(
        valued: ["--distractors", "--out", "--probes", "--seed", "--variant"]),
    // capturespread: runs the capture-spread lane. Two variants (spread/burst)
    // against one shared estate per run. Uses estate-cache with unit = "run".
    "capturespread": OptionSurface(
        valued: ["--binary", "--cache-dir", "--corpus", "--distractors",
                 "--estate-cache", "--k", "--mootx01-binary", "--out",
                 "--probes", "--recall-shape", "--run-id", "--seed", "--variant"]),
    // throughput: sustained-load query throughput measurement. Drives ONE lane
    // (--lane locomo|longmemeval|lmeb|membench) with N parallel workers for a
    // fixed window. Output is a TIMING artifact — no recall figures.
    // --estate-cache require (default for throughput) is mandatory.
    "throughput": OptionSurface(
        valued: ["--binary", "--cache-dir", "--corpus", "--data-dir", "--data-file",
                 "--encode-barrier", "--estate-cache", "--estate-mode",
                 "--lane", "--limit", "--mootx01-binary", "--offset",
                 "--out", "--parallel", "--run-id", "--seed", "--seed-path",
                 "--window-seconds"]),
]

/// Rejects retired options and unrecognised options before a subcommand runs.
///
/// Both parsers used to ignore anything they did not recognise: `optionValue`
/// finds a name or returns nil, and an unmatched token is never read and never
/// reported. That is how `--no-plaintext-scratch` came to run a plaintext
/// estate silently, and it is equally how `--estate-mode=encrypted` (the `=`
/// form this CLI does not take) or `--estate-mod encrypted` would.
///
/// Positional arguments — tokens that do not start with `-` — are ignored;
/// only option-shaped tokens are checked. A subcommand with no declared
/// surface gets the retired-option check only.
///
/// Twin of Rust `validate_options`.
public func validateOptions(subcommand: String,
                            in args: [String],
                            surfaces: [String: OptionSurface] = optionSurfaces) throws {
    // Retired names are rejected under EVERY subcommand, including ones that
    // never accepted them, so the operator gets the same answer wherever the
    // stale invocation lives.
    for arg in args {
        // `--name=value` is not a form this CLI accepts anywhere; split at the
        // first `=` so a retired name written that way is still recognised.
        let name = String(arg.split(separator: "=", maxSplits: 1).first ?? "")
        if let replacement = retiredOptions[name] {
            throw MCPError(description:
                "\(name) was removed and is NOT accepted as a synonym; use "
                + "\(replacement) instead. A run that asked for encryption and "
                + "silently got plaintext is worse than a run that failed.")
        }
    }
    guard let surface = surfaces[subcommand] else { return }
    var index = 0
    while index < args.count {
        let arg = args[index]
        guard arg.hasPrefix("-") else { index += 1; continue }
        if surface.valued.contains(arg) {
            // Skip the value so a value that itself starts with `-` (a negative
            // number, a leading-dash judge command) is not read as an option.
            index += 2
            continue
        }
        if surface.bare.contains(arg) { index += 1; continue }
        throw MCPError(description:
            "unknown option '\(arg)' for subcommand '\(subcommand)'. This CLI "
            + "takes an option value as a separate argument (--estate-mode "
            + "encrypted), never joined with '='. Accepted: "
            + surface.acceptedNames.joined(separator: " "))
    }
    try rejectRamShapeWithArtifacts(in: args)
}

/// RAM shape and the artifact store are mutually exclusive.
///
/// `--shape ram` runs the estate through `serve --in-memory`, so there
/// is no estate file on disk to snapshot. Left unguarded the pair is silently
/// destructive rather than merely useless: the run would snapshot a scratch
/// directory holding no estate, store it under a key that carries no shape
/// component, and a later disk run under `--estate-cache require` would restore
/// that empty artifact and measure nothing — reporting the result as a
/// successful measurement.
///
/// Refusing the combination is better than adding shape to the cache key. A
/// keyed RAM artifact would be a correctly-filed useless artifact; the estate
/// still is not on disk, so there is nothing worth storing either way.
func rejectRamShapeWithArtifacts(in args: [String]) throws {
    guard optionValue("--shape", in: args) == "ram" else { return }
    let cacheMode = optionValue("--estate-cache", in: args) ?? "off"
    guard cacheMode != "off" else { return }
    throw MCPError(description:
        "--shape ram cannot be combined with --estate-cache \(cacheMode): a RAM "
        + "estate has no file on disk to snapshot or restore. Artifacts are disk "
        + "estates by definition (Shape 2). Use --shape disk to build or measure "
        + "against artifacts, or drop --estate-cache to run RAM uncached.")
}

// MARK: - Stats-store instrumentation

/// Opens the ObserverSink stats store at `path`, installs a
/// `PersistenceStatsSink` into IntellectusLib, and enables monitoring (both
/// the IntellectusLib gate and the store's flag row) so emitted samples land.
///
/// Returns the opened store so the caller can close it after the run. The
/// dropbox id identifies the benchmarker's rows in the shared store.
func installStatsStore(at path: String) async throws -> StatsStore {
    let store = try StatsStore(url: URL(fileURLWithPath: path))
    try await store.open()
    // The benchmarker is the producer here, so it turns the store flag on for
    // the duration of its own run. In the manager pipeline the manager owns
    // this flag; for a standalone benchmark run the tool enables it itself.
    try await store.setMonitoringEnabled(true)
    let sink = PersistenceStatsSink(store: store, dropboxID: "mcp-benchmarker")
    Intellectus.install(sink: sink)
    Intellectus.setEnabled(true)
    return store
}

/// Lets the in-flight async sink Tasks drain before the store is closed.
/// `PersistenceStatsSink.receive(_:)` dispatches each insert to an unstructured
/// Task; a brief yield lets those complete so the rows are visible to a reader
/// (and the close below does not race the inserts).
func drainStatsSink() async {
    try? await Task.sleep(nanoseconds: 300_000_000)  // 300 ms
}

/// Emits the transfer's capture metrics into the stats store via IntellectusLib.
/// No-op (off-path, ~1 ns) when monitoring was never enabled.
func emitCaptureMetrics(_ summary: TimingSeries, count: Int, now: Double) {
    Intellectus.report(.metric(name: "benchmarker.capture.count",
                               value: Double(count), tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.capture.latency_ms.mean",
                               value: summary.mean * 1000, tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.capture.latency_ms.p95",
                               value: summary.p95 * 1000, tags: [:], ts: now))
    // Throughput: entries per second over the summed capture time.
    let totalSeconds = summary.mean * Double(count)
    let throughput = totalSeconds > 0 ? Double(count) / totalSeconds : 0
    Intellectus.report(.metric(name: "benchmarker.capture.throughput_per_s",
                               value: throughput, tags: [:], ts: now))
}

/// Emits the benchmark report's recall + divergence metrics into the stats
/// store via IntellectusLib. No-op when monitoring was never enabled.
func emitBenchmarkMetrics(_ report: BenchmarkReport, now: Double) {
    Intellectus.report(.metric(name: "benchmarker.recall.latency_ms.mean",
                               value: report.recall.mean * 1000, tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.recall.latency_ms.p95",
                               value: report.recall.p95 * 1000, tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.divergence.jaccard_set",
                               value: report.jaccardSetDivergence, tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.divergence.mean_rank",
                               value: report.meanRankDivergence, tags: [:], ts: now))
    // Source recall latency lands only when --compare-source ran (sampleCount > 0).
    if report.sourceRecall.sampleCount > 0 {
        Intellectus.report(.metric(name: "benchmarker.source_recall.latency_ms.mean",
                                   value: report.sourceRecall.mean * 1000, tags: [:], ts: now))
    }
}

/// An opaque handle over the ObserverSink stats store for out-of-package
/// callers (extension CLIs). Wraps install + snapshot emit + drain/close so
/// the caller never names the ObserverSink types directly.
public struct StatsStoreSession {
    let store: StatsStore

    /// Opens the store at `path`, installs the IntellectusLib sink, and enables
    /// monitoring (same semantics as `installStatsStore`).
    public static func install(at path: String) async throws -> StatsStoreSession {
        StatsStoreSession(store: try await installStatsStore(at: path))
    }

    /// Emits one rolling-stats snapshot into the store via IntellectusLib.
    public func emit(_ snap: RollingStatsSnapshot, now: Double) {
        emitRollingSnapshot(snap, now: now)
    }

    /// Emits capture timing metrics (count, mean latency, p95 latency,
    /// throughput) into the stats store via IntellectusLib. Public so an
    /// out-of-package caller can emit the same metrics after a corpus-load
    /// run; the core CLI calls the internal `emitCaptureMetrics` helper.
    public func emitCapture(count: Int, meanLatencyMs: Double, p95LatencyMs: Double,
                            throughputPerS: Double, now: Double) {
        Intellectus.report(.metric(name: "benchmarker.capture.count",
                                   value: Double(count), tags: [:], ts: now))
        Intellectus.report(.metric(name: "benchmarker.capture.latency_ms.mean",
                                   value: meanLatencyMs, tags: [:], ts: now))
        Intellectus.report(.metric(name: "benchmarker.capture.latency_ms.p95",
                                   value: p95LatencyMs, tags: [:], ts: now))
        Intellectus.report(.metric(name: "benchmarker.capture.throughput_per_s",
                                   value: throughputPerS, tags: [:], ts: now))
    }

    /// Drains in-flight sink tasks and closes the store.
    public func close() async {
        await drainStatsSink()
        await store.close()
    }
}

/// Builds and connects a client for one endpoint.
public func connectedClient(for endpoint: EndpointConfig) async throws -> MCPClient {
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()
    return client
}

/// benchmark subcommand.
func runBenchmark(_ args: [String]) async throws {
    let configPath = try requireOption("--config", in: args)
    let manifestPath = try requireOption("--manifest", in: args)
    let reportPath = try requireOption("--report", in: args)
    let compareSource = flagPresent("--compare-source", in: args)

    let config = try BenchmarkerConfig.load(from: URL(fileURLWithPath: configPath))
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))

    let source = try await connectedClient(for: config.source)
    let target = try await connectedClient(for: config.target)
    defer { Task { await source.disconnect(); await target.disconnect() } }

    let engine = BenchmarkEngine(
        source: source,
        target: target,
        sourceVerbs: config.source.verbMap,
        targetVerbs: config.target.verbMap,
        compareSourceRanking: compareSource
    )
    // Optional stats-store instrumentation.
    var statsStore: StatsStore?
    if let statsStorePath = optionValue("--stats-store", in: args) {
        statsStore = try await installStatsStore(at: statsStorePath)
    }

    // DegeneracyGuard probe (SPEC §9): probe the target before scoring recall.
    // benchmark replays a recorded manifest; the guard still applies because we
    // are emitting a recall number. Non-healthy verdict exits non-zero.
    let guard_ = DegeneracyGuard()
    let targetRankings = await probeMCPClient(target, verbMap: config.target.verbMap,
                                              name: config.target.name)
    let targetVerdict = guard_.classify(probeRankings: targetRankings)
    enforceGuard(verdict: targetVerdict, backendName: config.target.name)

    let report = try await engine.run(manifest: manifest)
    // Label the output clearly: recall here is replayed from a recorded
    // manifest, not measured against a live session (SPEC §6b).
    let labelledOutput = "[benchmark] manifest-replay verification\n"
        + report.rendered()
    try report.encoded().write(to: URL(fileURLWithPath: reportPath))

    if let statsStore {
        emitBenchmarkMetrics(report, now: Date().timeIntervalSince1970)
        await drainStatsSink()
        await statsStore.close()
    }

    FileHandle.standardOutput.write(Data(labelledOutput.utf8))
}

/// report subcommand.
func runReport(_ args: [String]) throws {
    let reportPath = try requireOption("--report", in: args)
    let report = try BenchmarkReport.load(from: URL(fileURLWithPath: reportPath))
    FileHandle.standardOutput.write(Data(report.rendered().utf8))
}

/// Emits a rolling-stats snapshot's series + divergence into the stats store
/// via IntellectusLib. No-op when monitoring was never enabled. Used by both
/// `serve` and `pressure` so the standing stats reach moot-mgr's dashboard.
func emitRollingSnapshot(_ snap: RollingStatsSnapshot, now: Double) {
    for s in snap.series {
        // The series label (e.g. "mootx01.read", "primary.tools/call") becomes
        // a tag so the dashboard can split the four paths / two backends.
        Intellectus.report(.metric(name: "benchmarker.rolling.latency_ms.mean",
                                   value: s.mean * 1000, tags: ["series": s.label], ts: now))
        Intellectus.report(.metric(name: "benchmarker.rolling.latency_ms.p95",
                                   value: s.p95 * 1000, tags: ["series": s.label], ts: now))
        Intellectus.report(.metric(name: "benchmarker.rolling.count",
                                   value: Double(s.totalCount), tags: ["series": s.label], ts: now))
    }
    if snap.divergenceSampleCount > 0 {
        Intellectus.report(.metric(name: "benchmarker.rolling.divergence.jaccard_set",
                                   value: snap.jaccardMean, tags: [:], ts: now))
        Intellectus.report(.metric(name: "benchmarker.rolling.divergence.kendall_rank",
                                   value: snap.kendallRankMean, tags: [:], ts: now))
    }
}

// MARK: - DegeneracyGuard probe helpers (SPEC §9)

/// The three distinct probe queries used for the guard's query-invariance check.
/// They are deliberately broad and varied so a well-functioning backend should
/// return meaningfully different result sets for each.
private let guardProbeQueries = [
    "memory recall search recent",
    "project task planning notes",
    "important decision context background",
]

/// Issues ≥3 distinct probe queries to a connected `MCPClient` and returns
/// the normalized-content rankings for each probe. Used by the benchmark path.
func probeMCPClient(_ client: MCPClient, verbMap: EndpointConfig.VerbMap,
                    name: String) async -> [[String]] {
    var rankings: [[String]] = []
    for query in guardProbeQueries {
        let args = AriaV2Surface.memorySearchArgs(verbMap: verbMap, query: query)
        do {
            let result = try await client.callTool(verbMap.query, arguments: args,
                                                   format: verbMap.resultFormat)
            let order = BenchmarkEngine.normalizedContentOrder(result.items)
            rankings.append(order)
        } catch {
            rankings.append([])
        }
    }
    return rankings
}

/// Runs the DegeneracyGuard against the probe rankings and emits a diagnostic
/// + exits non-zero if the verdict is not `.healthy`. Returns normally on a
/// `.healthy` verdict. Call BEFORE emitting any recall/quality number.
/// Public so out-of-package callers can enforce the same guard contract using
/// the same diagnostic format.
public func enforceGuard(verdict: DegeneracyGuard.Verdict, backendName: String) {
    switch verdict {
    case .healthy:
        return
    default:
        let msg = "[DegeneracyGuard] REFUSED to publish comparison for '\(backendName)': "
            + verdict.diagnostic + "\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(1)
    }
}

/// Parses `--estate-mode unencrypted|encrypted` (default: unencrypted) into
/// the scratch posture, and refuses the encrypted mode combined with
/// `--estate-cache reuse`: an encrypted scratch estate's key is TEMPORAL
/// (in-memory in the serve process), so a cached snapshot could never be
/// reopened — refusing loudly beats a run that silently measures nothing.
/// longmemeval subcommand — LongMemEval session-recall harness.
///
///   mcp-benchmarker longmemeval --data-dir <dir> --variant s|m|oracle
///       [--mootx01-binary <path>] [--limit N] [--offset K] [--seed S]
///       [--out <dir>]
///
/// Restores a pre-built estate artifact per question (seeding pipeline,
/// BENCHMARK_ESTATES.md) into a scratch dir under /tmp/lme-bench-, queries via
/// MCP query, and reports Recall-any@k / MRR / latency. Dataset must be
/// pre-fetched with scripts/fetch-longmemeval.sh.
// MARK: - Legacy-lane darkening gates (ruling 2026-08-18)

/// Rejects a darkened non-deterministic legacy option (ruling 2026-08-18:
/// deterministic legacy lanes stay runnable on demand; non-deterministic
/// legacy paths go dark in code until a removal ruling). The code behind each
/// gate is retained; only the activation path errors. The spec lanes carry
/// the sanctioned model-dependent paths (official protocols, BYOAI seams).
///
/// The per-path inventory is enforced by the lane's conformance tests.
func rejectDarkenedLegacyOptions(
    lane: String,
    flags: [String],
    envVars: [String],
    in args: [String],
    replacement: String
) throws {
    for flag in flags where optionValue(flag, in: args) != nil {
        throw MCPError(description:
            "\(flag) is dark on the legacy \(lane) lane (non-deterministic path; "
            + "ruling 2026-08-18). The code is retained but the path is disabled. "
            + "Use \(replacement) instead.")
    }
    for env in envVars where ProcessInfo.processInfo.environment[env] != nil {
        throw MCPError(description:
            "\(env) is dark on the legacy \(lane) lane (non-deterministic path; "
            + "ruling 2026-08-18). Unset it for legacy runs, or use \(replacement).")
    }
}

/// Parses --target-scale from the argument list.
///
/// Valid values: "unit" (default), "bench-aggregate", "complete-aggregate".
/// Used by all four M4 spec lanes (lme-spec, lmeb-spec, convomem-spec, membench-spec).
func parseArtifactTargetScale(in args: [String]) throws -> ArtifactTargetScale {
    let raw = optionValue("--target-scale", in: args) ?? "unit"
    switch raw {
    case "unit":             return .unit
    case "bench-aggregate":  return .benchAggregate
    case "complete-aggregate": return .completeAggregate
    default:
        throw MCPError(description:
            "--target-scale must be 'unit', 'bench-aggregate', or 'complete-aggregate'; got '\(raw)'")
    }
}

func parseEstateMode(in args: [String]) throws -> ScratchEstatePosture {
    let mode = optionValue("--estate-mode", in: args) ?? "unencrypted"
    let posture: ScratchEstatePosture
    switch mode {
    case "unencrypted": posture = .plaintextTransient
    case "encrypted":   posture = .encryptedEphemeral
    default:
        throw MCPError(description:
            "--estate-mode must be 'unencrypted' or 'encrypted'; got '\(mode)'")
    }
    if posture == .encryptedEphemeral,
       (optionValue("--estate-cache", in: args) ?? "off") != "off" {
        throw MCPError(description:
            "--estate-mode encrypted cannot be combined with --estate-cache reuse: "
            + "an encrypted scratch estate uses a temporal in-process key, so a "
            + "snapshot could not be reopened. Run encrypted mode with --estate-cache off.")
    }
    return posture
}

func runLongMemEval(_ args: [String]) async throws {
    // Darkening gates ND-LME-1..4: judge, verdict grading, reranker, synthesize
    // arm. All were off by default and reachable by no Makefile target.
    try rejectDarkenedLegacyOptions(
        lane: "longmemeval",
        flags: ["--judge-cmd", "--rerank-cmd"],
        envVars: ["MOOT_BENCH_JUDGE_CMD", "MOOT_BENCH_RERANK_CMD"],
        in: args,
        replacement: "the lme-spec lane (official judged protocol, offline judge batches)")
    if optionValue("--judge-grading", in: args) == "verdict" {
        throw MCPError(description:
            "--judge-grading verdict is dark on the legacy longmemeval lane "
            + "(ND-LME-2, ruling 2026-08-18). Use the lme-spec lane's §3 verdicts.")
    }
    if args.contains("--synthesize-arm") {
        throw MCPError(description:
            "--synthesize-arm is dark on the legacy longmemeval lane "
            + "(ND-LME-4, ruling 2026-08-18). Use the lme-spec lane.")
    }
    let variant = try requireOption("--variant", in: args)
    guard ["s", "m", "oracle"].contains(variant) else {
        throw MCPError(description: "--variant must be 's', 'm', or 'oracle'; got '\(variant)'")
    }
    // --corpus is the Rust twin's canonical flag name; --data-dir is the Swift-native spelling.
    // Both are accepted; --data-dir takes priority when both are present.
    guard let dataDirStr = optionValue("--data-dir", in: args) ?? optionValue("--corpus", in: args) else {
        throw MCPError(description: "missing required option --data-dir (or --corpus)")
    }
    // Resolve variant filename from the variant flag.
    let variantFilename: String
    switch variant {
    case "s":      variantFilename = "longmemeval_s_cleaned.json"
    case "m":      variantFilename = "longmemeval_m_cleaned.json"
    case "oracle": variantFilename = "longmemeval_oracle.json"
    default: fatalError("unreachable")
    }
    let datasetPath = URL(fileURLWithPath: dataDirStr)
        .appendingPathComponent(variantFilename)

    guard FileManager.default.fileExists(atPath: datasetPath.path) else {
        throw MCPError(description:
            "dataset file not found at \(datasetPath.path). "
            + "Run scripts/fetch-longmemeval.sh to download the dataset.")
    }

    // mootx01 binary: --mootx01-binary is the Swift-native spelling; --binary is the
    // Rust twin's name. Both are accepted for CLI contract parity (Defect 4).
    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[longmemeval] auto-discovered mootx01 at: \(mootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(mootBinary)'. "
            + "Build with `swift build --package-path apps/mootx01`.")
    }

    let limit = try parseLimitOption(in: args)
    let offset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    let seed = optionValue("--seed", in: args).flatMap(UInt64.init) ?? 20_260_725
    // --encode-barrier drain|impatient|none (default: drain).
    //   drain:     write without inline-encoding, poll moot_drain_status post-ingest.
    //   impatient: write with impatient:true for inline encoding per write.
    //   none:      no barrier — documents the background-encoding race.
    let encodeBarrierStr = optionValue("--encode-barrier", in: args) ?? "drain"
    let lmeEncodeBarrier: EncodeBarrier
    switch encodeBarrierStr {
    case "drain":     lmeEncodeBarrier = .drain
    case "impatient": lmeEncodeBarrier = .impatient
    case "none":      lmeEncodeBarrier = .none
    default:
        throw MCPError(description:
            "--encode-barrier must be 'drain', 'impatient', or 'none'; got '\(encodeBarrierStr)'")
    }
    // --exact-strategy auto|search|relevance|precise (default: auto). How the
    // exact arm drives the recall surface; auto follows the program's documented
    // client protocol (relevance ordering + precise escalation on low
    // discrimination). See ExactRecallStrategy in LongMemEvalRunner.swift.
    let exactStrategyStr = optionValue("--exact-strategy", in: args) ?? "auto"
    guard let lmeExactStrategy = ExactRecallStrategy(rawValue: exactStrategyStr) else {
        throw MCPError(description:
            "--exact-strategy must be 'auto', 'search', 'relevance', or 'precise'; got '\(exactStrategyStr)'")
    }
    // --arm exact|dense|both (default: both). Controls which recall paths are exercised.
    //   exact: moot_memory_search only (LME-01 baseline path)
    //   dense: moot_recall_distilled only (requires moot_distill after ingest; Wave 1 rename)
    //   both:  both arms per question for the two-arm token-efficiency comparison
    let armStr = optionValue("--arm", in: args) ?? "both"
    let arm: LMEArm
    switch armStr {
    case "exact": arm = .exact
    case "dense": arm = .dense
    case "both":  arm = .both
    default:
        throw MCPError(description: "--arm must be 'exact', 'dense', or 'both'; got '\(armStr)'")
    }
    // Created up front: a missing --out used to surface only when the report
    // was written, after the whole run had already been paid for.
    let outDir = try resolvedOutputDirectory(in: args)
    // Judge mode (LME-03 Part 4): optional LLM-judged QA. Off by default.
    // The command receives the prompt on stdin and writes its answer on stdout.
    //
    // SECURE PATH: set MOOT_BENCH_JUDGE_CMD in the environment instead of
    // --judge-cmd. The env var never appears in `ps` output. The --judge-cmd
    // flag is kept for compatibility but its value IS visible in `ps` argv.
    // If both are set, the env var takes precedence.
    let judgeCmd: String? =
        ProcessInfo.processInfo.environment["MOOT_BENCH_JUDGE_CMD"]
        ?? optionValue("--judge-cmd", in: args)
    // Post-retrieval rerank (W2-rerank): optional external rerank command.
    // The command reads a numbered candidate prompt on stdin and writes a
    // permutation of candidate numbers on stdout (exit 0). Mirrors --judge-cmd's
    // contract. Presence only is recorded in the report; command text never logged.
    //
    // SECURE PATH: set MOOT_BENCH_RERANK_CMD in the environment instead of
    // --rerank-cmd. The env var never appears in `ps` output. If both are
    // set, the env var takes precedence.
    let lmeRerankCmd: String? =
        ProcessInfo.processInfo.environment["MOOT_BENCH_RERANK_CMD"]
        ?? optionValue("--rerank-cmd", in: args)
    // Judge grading mode: --judge-grading substring|verdict (default substring).
    //   substring: deterministic containment of the gold answer. Free, but it
    //              under-counts semantically-correct paraphrases.
    //   verdict:   a SECOND judge call returns CORRECT/INCORRECT. This is the
    //              protocol published leaderboard figures are produced under,
    //              so it is the mode to use when a cell must sit beside one.
    // The mode is recorded in the report — the two are not comparable.
    // Judge payload hydration depth: how many ranked hits are fetched at full
    // content for the judge to read. Recall verbs return 120-char previews,
    // which are not answerable context. This value MOVES THE ACCURACY NUMBER
    // and is recorded in the report — see LMERunConfig.judgeHydrationDepth.
    let judgeHydrationDepth = optionValue("--judge-hydration-depth", in: args)
        .flatMap(Int.init) ?? lmeDefaultJudgePayloadHydrationDepth
    guard judgeHydrationDepth > 0 else {
        throw MCPError(description: "--judge-hydration-depth must be a positive integer")
    }
    // RecallShape preset for --exact-strategy shaped. Validated against the
    // product roster so a typo fails at parse rather than silently falling
    // back to the unsteered default mid-run.
    let recallShape = optionValue("--recall-shape", in: args)
    if let shape = recallShape, !lmeRecallShapePresets.contains(shape) {
        throw MCPError(description:
            "--recall-shape must be one of: \(lmeRecallShapePresets.joined(separator: ", ")); got '\(shape)'")
    }
    let judgeGradingStr = optionValue("--judge-grading", in: args) ?? "substring"
    guard let lmeJudgeGrading = LMEJudgeGrading(rawValue: judgeGradingStr) else {
        throw MCPError(description:
            "--judge-grading must be 'substring' or 'verdict'; got '\(judgeGradingStr)'")
    }
    // Estate cache mode (LME-07): --estate-cache off|reuse (default: off).
    //   off:   fresh ingest every run. Gold standard.
    //   reuse: snapshot after ingest+encode; copy snapshot on subsequent runs with
    //          the same (benchmark, variant, question_id, seed, barrier, binary) key.
    //          Skips ~90% of wall-clock for runs 2..N. Recommended N-run pattern:
    //          run 1 with off (cold), runs 2..N with reuse (warm).
    let estateCacheStr = optionValue("--estate-cache", in: args) ?? "off"
    let lmeEstateCache: EstateCacheMode
    switch estateCacheStr {
    case "off":   lmeEstateCache = .off
    case "reuse": lmeEstateCache = .reuse
    case "require": lmeEstateCache = .require
    default:
        throw MCPError(description:
            "--estate-cache must be 'off', 'reuse', or 'require'; got '\(estateCacheStr)'")
    }
    // --cache-dir: override the default estate cache root (<out>/estate-cache).
    let lmeCacheDir = optionValue("--cache-dir", in: args).map { URL(fileURLWithPath: $0) }
    // --estate-mode unencrypted|encrypted (default: unencrypted). Encrypted
    // runs use the product's TEMPORAL-key posture (harness key file
    // ephemeral): the estate is SQLCipher-encrypted under an in-memory key —
    // zero Keychain and zero on-disk key residue. Encrypted and unencrypted
    // are SEPARATE runs under the one-test-at-a-time protocol; the report's
    // estate_encryption field records which mode this run measured.
    let lmeScratchPosture = try parseEstateMode(in: args)
    // Accuracy lanes never test encryption; that is the timing lane's mandate.
    if lmeScratchPosture == .encryptedEphemeral {
        throw MCPError(description: "encryption is tested only by the timing lane")
    }
    // --settle: run each question twice — first as the ORGANIC cell (immediately
    // after ingest + drain), then trigger moot_reindex, wait for the corpus_encode
    // drain to converge, and re-run identical queries as the SETTLED cell.
    // Reports both cells in the run report under testmark_cells. Off by default.
    // Adds ~30-60s per question for the reindex + drain wait.
    let lmeSettle = flagPresent("--settle", in: args)
    // --synthesize-arm: add moot_synthesize as the fourth answer-payload mode
    // beside preview / distilled / full-hydrated. Calls moot_synthesize per
    // question after ingest and judges the generated answer under the same
    // judge/grading configuration. Off by default. Actual runs require the operator's
    // quiet-machine authorization under the run protocol; the plumbing is built
    // and labeled without pre-judging the outcome.
    let lmeSynthesizeArm = flagPresent("--synthesize-arm", in: args)
    // --synthesize-limit N: forwarded as moot_synthesize's `limit`. The tool
    // default (20, newest-first before any relevance signal) is the suspected
    // score cap on large estates; this knob isolates that variable per run.
    let lmeSynthesizeLimit: Int? = optionValue("--synthesize-limit", in: args) != nil
        ? try validatedCount("--synthesize-limit", in: args, default: 20, minimum: 1)
        : nil
    // --slice dev|holdout (default: absent = full set). Applied AFTER the
    // seeded shuffle and BEFORE offset + limit — so `--slice dev --limit 10`
    // returns the first 10 of the 50-question dev half, NOT 10 of the full
    // set filtered to dev. The dev boundary is hard-coded at 50 (the historical
    // tuning slice). Cells produced with different --slice values are NOT
    // interchangeable; the value is recorded in run_parameters.
    let lmeSliceRaw: String? = optionValue("--slice", in: args)
    let lmeSlice: String?
    if let raw = lmeSliceRaw {
        let accepted = ["dev", "holdout"]
        guard accepted.contains(raw) else {
            throw MCPError(description:
                "--slice value '\(raw)' is not accepted. Valid values: \(accepted.joined(separator: ", "))")
        }
        lmeSlice = raw
    } else {
        lmeSlice = nil
    }

    let loadMsg = "[longmemeval] loading corpus from \(datasetPath.path)\n"
    FileHandle.standardOutput.write(Data(loadMsg.utf8))

    let corpus = try loadLMECorpus(from: datasetPath)
    // B2 provenance: digest the corpus fixture once at load time.
    let lmeCorpusDigest = fileSha256Hex(path: datasetPath.path) ?? "unknown"
    let loadedMsg = "[longmemeval] loaded \(corpus.questions.count) questions "
        + "(\(corpus.abstentionCount) abstentions excluded)\n"
    FileHandle.standardOutput.write(Data(loadedMsg.utf8))
    FileHandle.standardOutput.write(Data("[longmemeval] encode-barrier: \(lmeEncodeBarrier.rawValue)\n".utf8))

    // Rerank suffix appended to the label when active so cells with and without
    // reranking are immediately distinguishable in published output.
    let lmeRunLabel: String = {
        var label = "lme-\(variant)-seed\(seed)-arm\(armStr)"
        if lmeRerankCmd != nil { label += "-rerank" }
        return label
    }()
    // Seed path (--seed-path batch|live, default batch). Governing ruling 8D5B8053.
    // batch: emit seed-file schema v1 → moot_json_import → needle attribution.
    // live:  per-turn moot_file_memory (slow lane, retained for equivalence re-proving).
    let lmeSeedPath = try SeedPathMode.parse(optionValue("--seed-path", in: args))
    // Guard sampling policy (--guard-sample once|per-unit, default once).
    // once: probe on the first question only; cache verdict for the leg.
    // per-unit: probe every question (debugging only; 3× MCP calls per question).
    let lmeGuardSamplingPolicy = try GuardSamplingPolicy.parse(optionValue("--guard-sample", in: args))
    let lmeDumpJudgeInputsPath = optionValue("--dump-judge-inputs", in: args)
    // --shape disk|ram (default: disk). C1 — backend shape for the scratch estate.
    //   disk: standard SQLite-backed PersistenceKit estate (default).
    //   ram:  injects serve --in-memory into the serve command, selecting
    //         PersistenceKit's InMemory backend. Faster but volatile; the estate
    //         vanishes on server exit, so snapshot-based caching is incompatible.
    let lmeShapeStr = optionValue("--shape", in: args) ?? "disk"
    let lmeShape: LMEShape
    switch lmeShapeStr {
    case "disk": lmeShape = .disk
    case "ram":  lmeShape = .ram
    default:
        throw MCPError(description:
            "--shape must be 'disk' or 'ram'; got '\(lmeShapeStr)'")
    }
    // C1 compatibility gate: --shape ram cannot be combined with --estate-cache
    // reuse or require. An in-memory estate vanishes on server exit, so there is
    // no snapshot to save or restore. This mirrors the encrypted+cache rejection.
    if lmeShape == .ram && lmeEstateCache != .off {
        throw MCPError(description:
            "--shape ram cannot be combined with --estate-cache reuse or require: "
            + "an in-memory estate vanishes when the server exits, so there is no "
            + "snapshot to restore. Run --shape ram with --estate-cache off.")
    }
    // --parallel N (default: max(1, 80% of logical cores)). C6 — maximum number
    // of questions to run concurrently. 1 = serial.
    let defaultParallelUnits = max(1, Int(Double(ProcessInfo.processInfo.activeProcessorCount) * 0.8))
    let lmeParallelUnits: Int
    if let parallelStr = optionValue("--parallel", in: args) {
        guard let n = Int(parallelStr), n >= 1 else {
            throw MCPError(description:
                "--parallel must be a positive integer; got '\(parallelStr)'")
        }
        lmeParallelUnits = n
    } else {
        lmeParallelUnits = defaultParallelUnits
    }
    var runConfig = LMERunConfig(
        mootBinaryPath: mootBinary,
        datasetPath: datasetPath,
        variant: variant,
        limit: limit,
        offset: offset,
        seed: seed,
        outDir: outDir,
        runLabel: lmeRunLabel,
        arm: arm,
        judgeCmd: judgeCmd,
        judgeGrading: lmeJudgeGrading,
        judgeHydrationDepth: judgeHydrationDepth,
        recallShape: recallShape,
        encodeBarrier: lmeEncodeBarrier,
        estateCache: lmeEstateCache,
        cacheDir: lmeCacheDir,
        scratchPosture: lmeScratchPosture,
        exactStrategy: lmeExactStrategy,
        settle: lmeSettle,
        rerankCmd: lmeRerankCmd,
        synthesizeArm: lmeSynthesizeArm,
        synthesizeLimit: lmeSynthesizeLimit,
        dumpJudgeInputsPath: lmeDumpJudgeInputsPath,
        slice: lmeSlice,
        seedPath: lmeSeedPath
    )
    // Instrument seams (environment-only; see RetrievalCallSpec.swift):
    // MOOT_BENCH_RETRIEVAL_TOOL/_ARGS override the query call;
    // MOOT_BENCH_UNIT_IDS pins the unit set.
    runConfig.retrievalCall = try retrievalCallSpecFromEnvironment()
    runConfig.unitIDs = try unitIDsFromEnvironment()
    // --payload-arm v0..v5 (PAYLOAD-ARMS; MOOT_BENCH_PAYLOAD_ARM as the
    // environment spelling): payload-economics shape variant applied to
    // seam-routed retrieval textBlocks. Recorded in run_environment.
    runConfig.payloadArm = try parsePayloadArm(
        optionValue("--payload-arm", in: args)
        ?? ProcessInfo.processInfo.environment["MOOT_BENCH_PAYLOAD_ARM"])
    // Fail-loud (mislabeled-cell rule): the arm only acts on seam-routed
    // retrieval in this lane, so an arm without the seam would be recorded
    // in run_environment yet never applied — a falsified cell.
    if runConfig.payloadArm != nil && runConfig.retrievalCall == nil {
        throw MCPError(description:
            "--payload-arm requires the retrieval seam in the longmemeval lane "
            + "(set MOOT_BENCH_RETRIEVAL_TOOL); the exact-strategy doors do not "
            + "carry the arm")
    }
    runConfig.guardSamplingPolicy = lmeGuardSamplingPolicy
    runConfig.corpusDigest = lmeCorpusDigest
    runConfig.shape = lmeShape
    runConfig.parallelUnits = lmeParallelUnits
    FileHandle.standardOutput.write(Data("[longmemeval] exact-strategy: \(lmeExactStrategy.rawValue)\n".utf8))
    if lmeSettle {
        FileHandle.standardOutput.write(Data(
            "[longmemeval] settle: on (ORGANIC + SETTLED cells via moot_reindex)\n".utf8))
    }

    let (results, lmeRerankFailures, lmeTimingReport) = try await runLMEQuestions(questions: corpus.questions, config: runConfig)

    // Score the results (LongMemEvalScorer.swift). Guard-excluded questions are
    // counted but excluded from aggregate recall/MRR per the contract §1.2 guarantee 1.
    let scores = results.map { scoreLMEQuestion($0) }

    // Build and write the report. Collect identity provenance once before building.
    // Pre-compute arm from variant (= runConfig.variant = local `variant`) and serial
    // so the stamp is applied before report construction (testname-arm-serial discipline).
    let lmeSerial = resolveRunSerial(args)
    var lmeIdentity = IdentityEnvironment.collect(
        mootx01BinaryPath: mootBinary, payloadArm: runConfig.payloadArm)
    stampTestIdentity(&lmeIdentity, test: "lme", arm: variant, serial: lmeSerial)
    let report = buildLMEReport(config: runConfig, corpus: corpus, results: results, scores: scores, rerankFailures: lmeRerankFailures, identityEnvironment: lmeIdentity, timingReport: lmeTimingReport)
    // `<test>-<arm>-<serial>`: the arm is the LongMemEval variant. Serial and arm
    // were pre-computed above for the stamp.
    let reportFilename = recordFilename(
        test: "lme", arm: variant, serial: lmeSerial)
    let reportURL = (outDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent(reportFilename)
    try writeLMEReport(report, to: reportURL)

    // Timing sidecar (--timing-sidecar, default off).
    // Written beside the accuracy report as <basename>.timing.json.
    // The accuracy report shape is UNCHANGED; timing never enters it.
    // LME has a nullable queryLatencySeconds (exact arm only); use denseQueryLatencySeconds
    // as fallback when the exact arm was not run. Skip units where both arms are nil.
    if flagPresent("--timing-sidecar", in: args) {
        // lmeSerial was resolved above for the stamp; reuse it here.
        let unitLatencies: [(id: String, latencySeconds: Double)] = results.compactMap { r in
            if let lat = r.queryLatencySeconds { return (r.questionID, lat) }
            if let lat = r.denseQueryLatencySeconds { return (r.questionID, lat) }
            return nil
        }
        let sidecar = makeTimingSidecar(
            lane: "longmemeval",
            runID: lmeSerial,
            identity: lmeIdentity,
            unitLatencies: unitLatencies
        )
        try writeTimingSidecar(sidecar, beside: reportURL)
    }

    // Judge transcript (LME-03 Part 4): write per-question judge calls to JSONL.
    // Each line: {question_id, arm, gold_answer, judge_answer, correct}.
    // Written only when --judge-cmd was supplied.
    if judgeCmd != nil {
        // Build a question-id → gold-answer lookup from the corpus.
        let goldLookup = Dictionary(uniqueKeysWithValues:
            corpus.questions.map { ($0.questionID, $0.answer) })
        var lines: [String] = []
        for result in results {
            let gold = goldLookup[result.questionID] ?? ""
            if let answer = result.exactJudgeAnswer {
                let entry: [String: Any] = [
                    "question_id": result.questionID,
                    "arm": "exact",
                    "gold_answer": gold,
                    "judge_answer": answer,
                    "correct": result.exactJudgeCorrect ?? false,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: entry,
                                                          options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
            }
            if let answer = result.denseJudgeAnswer {
                let entry: [String: Any] = [
                    "question_id": result.questionID,
                    "arm": "dense",
                    "gold_answer": gold,
                    "judge_answer": answer,
                    "correct": result.denseJudgeCorrect ?? false,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: entry,
                                                          options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
            }
            // Synthesize arm transcript entry (PR-08 — fourth payload mode).
            // The payload rides along so a low cell is diagnosable from the
            // transcript alone — the 2026-08-05 investigation needed a code
            // read because payloads were never persisted.
            if let answer = result.synthesizeJudgeAnswer {
                var entry: [String: Any] = [
                    "question_id": result.questionID,
                    "arm": "synthesize",
                    "gold_answer": gold,
                    "judge_answer": answer,
                    "correct": result.synthesizeJudgeCorrect ?? false,
                ]
                if let payload = result.synthesizePayloadText {
                    entry["payload"] = payload
                }
                if let data = try? JSONSerialization.data(withJSONObject: entry,
                                                          options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
            }
        }
        let transcriptContent = lines.joined(separator: "\n")
            + (lines.isEmpty ? "" : "\n")
        let transcriptFilename =
            "judge-transcript-\(report.variant)-seed\(runConfig.seed).jsonl"
        let transcriptURL = (outDir
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent(transcriptFilename)
        try Data(transcriptContent.utf8).write(to: transcriptURL)
        FileHandle.standardOutput.write(Data(
            "[longmemeval] judge transcript: \(transcriptURL.path)\n".utf8))
    }

    // Answer accuracy (the comparable-to-published metric). Printed only when
    // a judge ran — a run without one has no accuracy, and printing 0 would
    // read as "answered nothing correctly" rather than "did not measure".
    if let judgeAcc = lmeAggregateJudgeAccuracy(results, grading: lmeJudgeGrading) {
        FileHandle.standardOutput.write(Data(
            "  judge grading:        \(judgeAcc.grading)\n".utf8))
        FileHandle.standardOutput.write(Data(
            "  judge hydration depth: \(judgeHydrationDepth)\n".utf8))
        // Retrieval ceiling for the judged metric. Reading this next to the
        // accuracy separates "moot did not retrieve it" from "the judge could
        // not read it": reachable HIGH + accuracy LOW means the judge is the
        // ceiling. Upper bound only — short gold answers over-report.
        // Three-way payload frontier: preview vs distilled vs full hydrated.
        let pvCorrect = results.compactMap(\.previewJudgeCorrect)
        let pvTok = results.compactMap(\.previewJudgeTokens)
        if !pvCorrect.isEmpty {
            let acc = Double(pvCorrect.filter { $0 }.count) / Double(pvCorrect.count)
            let mt = pvTok.isEmpty ? 0 : Double(pvTok.reduce(0,+)) / Double(pvTok.count)
            FileHandle.standardOutput.write(Data(String(
                format: "  answer accuracy (preview): %.4f  (%d/%d judged, %.0f tokens)\n",
                acc, pvCorrect.filter { $0 }.count, pvCorrect.count, mt).utf8))
        }
        // END-TO-END EFFICIENCY: tokens spent per CORRECT answer.
        //
        // Payload size alone does not say which mode is worth using — a mode
        // that halves the tokens but also halves the correct answers has not
        // saved anything. Dividing tokens consumed by answers actually
        // obtained gives the cost of a right answer, which is the quantity a
        // consumer is really choosing between. Lower is better; a mode that
        // scores zero correct has no finite cost and is reported as such.
        func costPerCorrect(_ label: String, tokens: [Int], correct: [Bool?]) {
            let judged = zip(tokens, correct).filter { $0.1 != nil }
            guard !judged.isEmpty else { return }
            let totalTokens = judged.reduce(0) { $0 + $1.0 }
            let nCorrect = judged.filter { $0.1 == true }.count
            let cost = nCorrect > 0 ? String(format: "%.0f", Double(totalTokens) / Double(nCorrect))
                                    : "n/a (0 correct)"
            FileHandle.standardOutput.write(Data(
                "  tokens per correct answer — \(label): \(cost)\n".utf8))
        }
        costPerCorrect("preview",     tokens: results.map { $0.previewJudgeTokens ?? 0 },
                       correct: results.map(\.previewJudgeCorrect))
        costPerCorrect("distilled",   tokens: results.map { $0.denseJudgeTokens ?? 0 },
                       correct: results.map(\.denseJudgeCorrect))
        costPerCorrect("full",        tokens: results.map { $0.exactJudgeTokens ?? 0 },
                       correct: results.map(\.exactJudgeCorrect))
        // Synthesize arm: fourth point on the frontier (PR-08).
        // moot_synthesize generates a direct answer without ranked retrieval,
        // so payload token count = full synthesize response length.
        costPerCorrect("synthesize",  tokens: results.map { $0.synthesizeJudgeTokens ?? 0 },
                       correct: results.map(\.synthesizeJudgeCorrect))

        // Like-for-like token cost: what the judge actually read per arm.
        let exTok = results.compactMap(\.exactJudgeTokens)
        let dnTok = results.compactMap(\.denseJudgeTokens)
        if !exTok.isEmpty || !dnTok.isEmpty {
            let em = exTok.isEmpty ? 0 : Double(exTok.reduce(0,+)) / Double(exTok.count)
            let dm = dnTok.isEmpty ? 0 : Double(dnTok.reduce(0,+)) / Double(dnTok.count)
            FileHandle.standardOutput.write(Data(String(
                format: "  judge tokens read — exact(full): %.0f   dense(distilled): %.0f%@\n",
                em, dm,
                (em > 0 && dm > 0) ? String(format: "   ratio: %.3f", dm / em) : "").utf8))
        }
        let reach = results.compactMap(\.exactGoldReachable)
        if !reach.isEmpty {
            let hits = reach.filter { $0 }.count
            FileHandle.standardOutput.write(Data(String(
                format: "  gold reachable (exact): %.4f  (%d/%d)\n",
                Double(hits) / Double(reach.count), hits, reach.count).utf8))
        }
        if let e = judgeAcc.exact {
            FileHandle.standardOutput.write(Data(String(
                format: "  answer accuracy (exact): %.4f  (%d/%d judged)\n",
                e.accuracy, e.correct, e.judged).utf8))
        }
        if let d = judgeAcc.dense {
            FileHandle.standardOutput.write(Data(String(
                format: "  answer accuracy (dense): %.4f  (%d/%d judged)\n",
                d.accuracy, d.correct, d.judged).utf8))
        }
        // Synthesize arm accuracy (PR-08).
        if let s = judgeAcc.synthesize {
            FileHandle.standardOutput.write(Data(String(
                format: "  answer accuracy (synthesize): %.4f  (%d/%d judged)\n",
                s.accuracy, s.correct, s.judged).utf8))
        }
    }

    // Print scored summary to stdout.
    let guardHealthyCount = scores.filter(\.guardHealthy).count
    let guardRefusals = scores.count - guardHealthyCount
    let totalTurns = results.map(\.turnsIngested).reduce(0, +)
    let (agg, lat) = aggregateLMEScores(scores)

    // Token efficiency summary lines (nil when arm absent or no has_answer).
    let te = report.tokenEfficiency
    func fmtTokens(_ t: Double?) -> String { t.map { String(format: "%.0f", $0) } ?? "N/A" }
    func fmtRatio(_ r: Double?) -> String  { r.map { String(format: "%.3f", $0) } ?? "N/A" }
    func fmtRate(_ r: Double?)  -> String  { r.map { String(format: "%.3f", $0) } ?? "N/A (no has_answer)" }

    let summary = """
        [longmemeval] run complete
          questions processed:  \(results.count)
          guard healthy:        \(guardHealthyCount)
          guard refusals:       \(guardRefusals)
          turns ingested total: \(totalTurns)
          recall-any@1:         \(String(format: "%.4f", agg.recallAnyAt1))
          recall-any@5:         \(String(format: "%.4f", agg.recallAnyAt5))
          recall-any@10:        \(String(format: "%.4f", agg.recallAnyAt10))
          recall-all@1:         \(String(format: "%.4f", agg.recallAllAt1))
          recall-all@5:         \(String(format: "%.4f", agg.recallAllAt5))
          recall-all@10:        \(String(format: "%.4f", agg.recallAllAt10))
          mrr:                  \(String(format: "%.4f", agg.mrr))
          query p50:            \(String(format: "%.1f", lat.queryP50Seconds * 1000)) ms
          query p95:            \(String(format: "%.1f", lat.queryP95Seconds * 1000)) ms
          exact mean tokens:    \(fmtTokens(te.exactArmMeanTokens))
          dense mean tokens:    \(fmtTokens(te.denseArmMeanTokens))
          dense/exact ratio:    \(fmtRatio(te.denseExactTokenRatio))
          exact evidence rate:  \(fmtRate(te.exactEvidenceHitRate))
          dense evidence rate:  \(fmtRate(te.denseEvidenceHitRate))
          estate strategy:      restored-artifact-per-question
          report written to:    \(reportURL.path)

        """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

// MARK: - lme-spec lane

/// lme-spec subcommand — official LongMemEval QA evaluation protocol (§1–§4).
///
///   mcp-benchmarker lme-spec --data-dir <dir> --variant s|m|oracle
///       [--mootx01-binary <path>] [--limit N] [--offset K] [--seed S]
///       [--out <dir>] [--encode-barrier drain|impatient|none]
///       [--estate-cache off|reuse|require] [--cache-dir <dir>]
///       [--estate-mode unencrypted|encrypted]
///       [--shape disk|ram] [--parallel N]
///       [--guard-sample once|per-unit] [--run-id <id>]
///       [--dump-judge-inputs <path>] [--judge-cmd <cmd>] [--judge-model <id>]
///
/// Realigns to LONGMEMEVAL_OFFICIAL_PROTOCOL.md: all 500 instances including
/// abstentions (§6 row 2 fix); byte-exact §2 anscheck prompts (§6 row 1 fix);
/// §4 aggregation (task-averaged, overall, abstention accuracy). Hypotheses are
/// produced via moot_synthesize and written as official hypothesis JSONL (§1).
/// Record naming: lme-spec-<variant>-<serial>.json + params sidecar.
///
/// ARTIFACT ISOLATION: lme-spec estate snapshots are stored under the key
/// "lme-spec" (not "longmemeval"). Artifacts from the longmemeval lane cannot
/// be restored by this lane — run artifacts-lme-spec before measure-lme-spec
/// with --estate-cache require.
func runLMESpec(_ args: [String]) async throws {
    // --variant s|m|oracle selects which LongMemEval variant file to evaluate.
    let variant = try requireOption("--variant", in: args)
    guard ["s", "m", "oracle"].contains(variant) else {
        throw MCPError(description: "--variant must be 's', 'm', or 'oracle'; got '\(variant)'")
    }
    // --corpus is the Rust twin's canonical flag; --data-dir is the Swift-native spelling.
    // Both accepted; --data-dir takes priority when both are present.
    guard let dataDirStr = optionValue("--data-dir", in: args) ?? optionValue("--corpus", in: args) else {
        throw MCPError(description: "missing required option --data-dir (or --corpus)")
    }
    // Resolve variant filename — same mapping as the longmemeval lane.
    let variantFilename: String
    switch variant {
    case "s":      variantFilename = "longmemeval_s_cleaned.json"
    case "m":      variantFilename = "longmemeval_m_cleaned.json"
    case "oracle": variantFilename = "longmemeval_oracle.json"
    default: fatalError("unreachable")
    }
    let datasetPath = URL(fileURLWithPath: dataDirStr)
        .appendingPathComponent(variantFilename)
    guard FileManager.default.fileExists(atPath: datasetPath.path) else {
        throw MCPError(description:
            "lme-spec dataset file not found at \(datasetPath.path). "
            + "Run scripts/fetch-longmemeval.sh to download the dataset.")
    }

    // mootx01 binary: --mootx01-binary is the Swift-native spelling; --binary is the
    // Rust twin's name. Both accepted for CLI contract parity.
    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[lme-spec] auto-discovered mootx01 at: \(mootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(mootBinary)'. "
            + "Build with `swift build --package-path apps/mootx01`.")
    }

    let limit  = try parseLimitOption(in: args)
    let offset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    let seed   = optionValue("--seed",   in: args).flatMap(UInt64.init) ?? 20_260_725

    // Created up front: a missing --out used to surface only when the report was
    // written, after the whole run had already been paid for.
    let outDir = try resolvedOutputDirectory(in: args)

    // --target-scale unit|bench-aggregate|complete-aggregate (default: unit).
    // 'unit': one pre-built estate per question (--catalog required).
    // 'bench-aggregate' / 'complete-aggregate': one shared estate (--estate-dir required).
    let lmsTargetScale = try parseArtifactTargetScale(in: args)

    // --catalog <path>: catalog.json path for the dataset (unit scale).
    // Required when --target-scale unit (the default).
    let lmsCatalogPath = optionValue("--catalog", in: args).map { URL(fileURLWithPath: $0) }

    // --estate-dir <path>: single shared estate for bench-aggregate / complete-aggregate.
    let lmsEstateDir = optionValue("--estate-dir", in: args).map { URL(fileURLWithPath: $0) }

    // Validate: unit scale needs --catalog; aggregate scales need estate-dir.
    switch lmsTargetScale {
    case .unit where lmsCatalogPath == nil:
        throw MCPError(description:
            "lme-spec: --target-scale unit requires --catalog <path to catalog.json>")
    case .benchAggregate where lmsEstateDir == nil,
         .completeAggregate where lmsEstateDir == nil:
        throw MCPError(description:
            "lme-spec: --target-scale \(lmsTargetScale.rawValue) requires --estate-dir <path>")
    default: break
    }

    // --guard-sample once|per-unit (default: once). The guard validates the
    // binary, not the unit — probing once per leg is sufficient for most runs.
    // Guard-sampling policy is validated but LMESpecRunConfig does not yet expose the field.
    _ = try GuardSamplingPolicy.parse(optionValue("--guard-sample", in: args))

    // Judge seam (BYOAI posture — LONGMEMEVAL_OFFICIAL_PROTOCOL.md §1–§4).
    //
    // Three modes: inline, dump-only, or neither (records judged_count=0).
    //
    // --judge-cmd / MOOT_BENCH_JUDGE_CMD (§3 inline): subprocess reads the §2
    // anscheck prompt on stdin and writes yes/no on stdout. The env var never
    // appears in `ps` argv; if both are set the env var takes precedence.
    let lmsJudgeCmd: String? =
        ProcessInfo.processInfo.environment["MOOT_BENCH_JUDGE_CMD"]
        ?? optionValue("--judge-cmd", in: args)
    // --judge-model: §3 model identifier recorded per verdict (default matches
    // the published leaderboard model). Any external model name is accepted;
    // the value is recorded verbatim in every judge-input dump line.
    let lmsJudgeModel = optionValue("--judge-model", in: args) ?? "gpt-4o-2024-08-06"
    // --dump-judge-inputs (§1): path for the JSONL file of anscheck prompts,
    // §3 call parameters, and metadata for each question. Consumed offline by
    // `mcp-benchmarker judge-batch` (the lme-spec variant of that path).
    let lmsDumpJudgeInputsPath = optionValue("--dump-judge-inputs", in: args)

    let lmsSerial   = resolveRunSerial(args)  // --run-id when set, UTC timestamp otherwise
    let lmsRunLabel = "lme-spec-\(variant)-seed\(seed)"

    FileHandle.standardOutput.write(Data("[lme-spec] loading corpus from \(datasetPath.path)\n".utf8))
    // Load via the spec corpus loader. Unlike the longmemeval lane, the spec corpus
    // includes ALL 500 instances — abstentions are not excluded (§6 row 2 fix).
    let lmsCorpus = try loadLMESpecCorpus(from: datasetPath)
    let lmsLoadedLine = "[lme-spec] loaded \(lmsCorpus.questions.count) questions "
        + "(spec corpus: all instances including abstentions)\n"
    FileHandle.standardOutput.write(Data(lmsLoadedLine.utf8))
    FileHandle.standardOutput.write(Data(
        "[lme-spec] target-scale: \(lmsTargetScale.rawValue)\n".utf8))

    // Build the runner config. `var` fields are mutated after init.
    var lmsConfig = LMESpecRunConfig(
        mootBinaryPath:       mootBinary,
        datasetPath:          datasetPath,
        variant:              variant,
        limit:                limit,
        offset:               offset,
        seed:                 seed,
        outDir:               outDir,
        runLabel:             lmsRunLabel,
        runSerial:            lmsSerial,
        dumpJudgeInputsPath:  lmsDumpJudgeInputsPath,
        judgeCmd:             lmsJudgeCmd,
        judgeModel:           lmsJudgeModel,
        targetScale:          lmsTargetScale,
        catalogPath:          lmsCatalogPath,
        estateDir:            lmsEstateDir
    )
    // Reader-model flow: --dump-answer-inputs writes one answer_input JSONL line
    // per question with the hydrated memory texts so an offline reader model
    // can form the hypothesis. --answer-hydration-depth caps the drawer count.
    // --hydration-tier selects the depth passed to moot_memory_get: distilled
    // (default, production shape) or full (comparison arm).
    lmsConfig.dumpAnswerInputsPath = optionValue("--dump-answer-inputs", in: args)
    if let depthStr = optionValue("--answer-hydration-depth", in: args),
       let depth = Int(depthStr), depth > 0 {
        lmsConfig.answerHydrationDepth = depth
    }
    if let tierStr = optionValue("--hydration-tier", in: args) {
        guard let tier = HydrationDepth(rawValue: tierStr) else {
            throw MCPError(description:
                "lme-spec --hydration-tier must be distilled or full; got '\(tierStr)'")
        }
        lmsConfig.answerHydrationTier = tier
    }
    // §6 required report fields (F1): binary provenance collected at the CLI layer.
    // Stamped with the testname-arm-serial triple so the emitted record is
    // self-identifying without its filename (D1 fix, testname-arm-serial discipline).
    lmsConfig.runEnvironment = IdentityEnvironment.collect(
        mootx01BinaryPath: lmsConfig.mootBinaryPath)
    stampTestIdentity(&lmsConfig.runEnvironment,
                      test: "lme-spec",
                      arm: lmsConfig.variant,
                      serial: lmsConfig.runSerial)
    // Instrument seam: MOOT_BENCH_UNIT_IDS pins the unit set for the spec lane.
    // Corpus is always loaded in full (corpus_digest unchanged); the filter selects
    // which question IDs run without touching the limit/offset machinery.
    let lmsUnitIDsPath = ProcessInfo.processInfo.environment["MOOT_BENCH_UNIT_IDS"]
    lmsConfig.unitIDs     = try lmsUnitIDsPath.map { try loadUnitIDs($0) }
    lmsConfig.unitIDsPath = lmsUnitIDsPath

    // runLMESpec (LMESpecRunner.swift) writes the report + params sidecar to
    // outDir via RecordWriter (lme-spec-<variant>-<serial>.json). The runner
    // also writes the §1 hypothesis JSONL alongside the report when a judge is set.
    let lmsReport = try await runLMESpec(
        questions: lmsCorpus.questions,
        config: lmsConfig)

    // Print a §4 summary. judgedCount == 0 when no judge was attached.
    let qCount    = lmsReport.totalQuestions
    let judgeNote = lmsReport.judgedCount > 0
        ? "\(lmsReport.judgedCount) questions judged"
        : "no judge attached (judged_count=0; set --judge-cmd or --dump-judge-inputs)"
    var lmsSummary = """
        [lme-spec] run complete
          variant:              \(variant)
          questions evaluated:  \(qCount)
          abstentions:          \(lmsReport.abstentionCount)
          \(judgeNote)

        """
    if lmsReport.judgedCount > 0 {
        let fmt = { (v: Double?) -> String in
            v.map { String(format: "%.4f", $0) } ?? "n/a"
        }
        lmsSummary += """
              task-averaged accuracy: \(fmt(lmsReport.taskAveragedAccuracy))
              overall accuracy:       \(fmt(lmsReport.overallAccuracy))
              abstention accuracy:    \(fmt(lmsReport.abstentionAccuracy))

            """
    }
    FileHandle.standardOutput.write(Data(lmsSummary.utf8))
}

// MARK: - lme-agentic lane

/// lme-agentic subcommand — OFFICIAL-protocol agentic answering arm.
///
///   mcp-benchmarker lme-agentic --data-dir <dir> --variant s|m|oracle
///       --model <name> --answer-cmd <cmd> [--mootx01-binary <path>]
///       [--cache-dir <dir>] [--max-tool-calls N]
///       [--limit N] [--offset K] [--seed S] [--out <dir>]
///       [--encode-barrier drain|impatient|none]
///       [--guard-sample once|per-unit] [--run-id <id>]
///       [--dump-judge-inputs <path>] [--judge-model <id>]
///
/// An external answering AI answers each question by querying the estate
/// itself over the read-only MCP tool surface, multiple tool calls allowed.
/// Estates restore from the lme-spec artifact store under REQUIRE semantics
/// (never builds). Output: official hypothesis JSONL + optional judge-input
/// dump (both shape-identical to lme-spec, so judging reuses the existing
/// judge-batch path) + report/params records carrying the answering model
/// name and per-question tool-call/token instrumentation.
/// See LMEAgenticRunner.swift for the answer-command JSON wire shape.
func runLMEAgenticCommand(_ args: [String]) async throws {
    let variant = try requireOption("--variant", in: args)
    guard ["s", "m", "oracle"].contains(variant) else {
        throw MCPError(description: "--variant must be 's', 'm', or 'oracle'; got '\(variant)'")
    }
    // --corpus is the fleet's Rust-canonical flag; --data-dir the Swift-native
    // spelling. Both accepted; --data-dir wins when both are present.
    guard let dataDirStr = optionValue("--data-dir", in: args) ?? optionValue("--corpus", in: args) else {
        throw MCPError(description: "missing required option --data-dir (or --corpus)")
    }
    let variantFilename: String
    switch variant {
    case "s":      variantFilename = "longmemeval_s_cleaned.json"
    case "m":      variantFilename = "longmemeval_m_cleaned.json"
    case "oracle": variantFilename = "longmemeval_oracle.json"
    default: fatalError("unreachable")
    }
    let datasetPath = URL(fileURLWithPath: dataDirStr)
        .appendingPathComponent(variantFilename)
    guard FileManager.default.fileExists(atPath: datasetPath.path) else {
        throw MCPError(description:
            "lme-agentic dataset file not found at \(datasetPath.path). "
            + "Run scripts/fetch-longmemeval.sh to download the dataset.")
    }

    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[lme-agentic] auto-discovered mootx01 at: \(mootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(mootBinary)'. "
            + "Build with `swift build --package-path apps/mootx01`.")
    }

    // The answering AI seam. MOOT_BENCH_ANSWER_CMD env preferred (a command
    // carrying an API key must not appear in `ps` argv — same secrecy law as
    // the judge command); the flag is the convenience path.
    guard let answerCmd = ProcessInfo.processInfo.environment["MOOT_BENCH_ANSWER_CMD"]
        ?? optionValue("--answer-cmd", in: args) else {
        throw MCPError(description:
            "missing required answering seam: set MOOT_BENCH_ANSWER_CMD or pass "
            + "--answer-cmd <cmd> (reads one JSON request on stdin, writes one "
            + "JSON response on stdout — see LMEAgenticRunner.swift)")
    }
    // The answering model NAME is required so no score is ever unattributed:
    // it goes into the report, the params sidecar, and every request.
    let answerModel = try requireOption("--model", in: args)

    let maxToolCallsStr = optionValue("--max-tool-calls", in: args) ?? "15"
    guard let maxToolCalls = Int(maxToolCallsStr), maxToolCalls >= 1 else {
        throw MCPError(description:
            "--max-tool-calls must be a positive integer; got '\(maxToolCallsStr)'")
    }

    let limit  = try parseLimitOption(in: args)
    let offset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    // Seed default matches lme-spec so the default run addresses the default
    // artifact fleet.
    let seed   = optionValue("--seed",   in: args).flatMap(UInt64.init) ?? 20_260_725

    // Barrier is a cache-key component — it must name what the ARTIFACTS were
    // built under, not a fresh choice (this lane never ingests).
    let encodeBarrierStr = optionValue("--encode-barrier", in: args) ?? "drain"
    let agenticBarrier: EncodeBarrier
    switch encodeBarrierStr {
    case "drain":     agenticBarrier = .drain
    case "impatient": agenticBarrier = .impatient
    case "none":      agenticBarrier = .none
    default:
        throw MCPError(description:
            "--encode-barrier must be 'drain', 'impatient', or 'none'; got '\(encodeBarrierStr)'")
    }

    let outDir = try resolvedOutputDirectory(in: args)
    let agenticCacheDir = optionValue("--cache-dir", in: args).map { URL(fileURLWithPath: $0) }
    let guardPolicy = try GuardSamplingPolicy.parse(optionValue("--guard-sample", in: args))

    let dumpJudgeInputsPath = optionValue("--dump-judge-inputs", in: args)
    let judgeModel = optionValue("--judge-model", in: args) ?? "gpt-4o-2024-08-06"

    let serial   = resolveRunSerial(args)
    let runLabel = "lme-agentic-\(variant)-seed\(seed)"

    FileHandle.standardOutput.write(Data("[lme-agentic] loading corpus from \(datasetPath.path)\n".utf8))
    let corpus = try loadLMESpecCorpus(from: datasetPath)
    let corpusDigest = fileSha256Hex(path: datasetPath.path) ?? "unknown"
    FileHandle.standardOutput.write(Data(
        "[lme-agentic] loaded \(corpus.questions.count) questions (spec corpus)\n".utf8))
    FileHandle.standardOutput.write(Data(
        "[lme-agentic] answering model: \(answerModel); tool budget: \(maxToolCalls)\n".utf8))

    var config = LMEAgenticRunConfig(
        mootBinaryPath:      mootBinary,
        datasetPath:         datasetPath,
        variant:             variant,
        cacheDir:            agenticCacheDir,
        encodeBarrier:       agenticBarrier,
        limit:               limit,
        offset:              offset,
        seed:                seed,
        answerCmd:           answerCmd,
        answerModel:         answerModel,
        maxToolCalls:        maxToolCalls,
        dumpJudgeInputsPath: dumpJudgeInputsPath,
        judgeModel:          judgeModel,
        outDir:              outDir,
        runLabel:            runLabel,
        runSerial:           serial,
        guardSamplingPolicy: guardPolicy,  // var
        corpusDigest:        corpusDigest  // var
    )
    config.runEnvironment = IdentityEnvironment.collect(
        mootx01BinaryPath: config.mootBinaryPath)
    stampTestIdentity(&config.runEnvironment,
                      test: "lme-agentic",
                      arm: config.variant,
                      serial: config.runSerial)

    let report = try await runLMEAgentic(questions: corpus.questions, config: config)

    let summary = """
        [lme-agentic] run complete
          variant:            \(variant)
          answering model:    \(report.answerModel)
          questions:          \(report.totalQuestions)
          answered:           \(report.answeredCount)
          tool calls (total): \(report.totalToolCalls)
          tokens (prompt/completion): \(report.totalPromptTokens)/\(report.totalCompletionTokens)
          hypotheses + report written under: \((outDir ?? URL(fileURLWithPath: ".")).path)

        """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// locomo subcommand — LoCoMo turn-level recall harness.
///
///   mcp-benchmarker locomo --data-file <locomo10.json>
///       [--mootx01-binary <path>] [--limit N] [--offset K] [--seed S]
///       [--out <dir>]
///
/// Provisions one scratch estate per conversation (10 total), ingests all turns
/// via live moot_file_memory with the configured encode barrier, and reports
/// Recall-any@k / MRR / latency with per-category breakdown. Dataset must be
/// pre-fetched with scripts/fetch-locomo.sh. License: CC BY-NC 4.0 (non-commercial).
func runLoCoMo(_ args: [String]) async throws {
    // Darkening gates ND-LOCO-1/2: reranker call sites (ruling 2026-08-18).
    try rejectDarkenedLegacyOptions(
        lane: "locomo",
        flags: ["--rerank-cmd"],
        envVars: ["MOOT_BENCH_RERANK_CMD"],
        in: args,
        replacement: "the locomo-spec lane (official QA protocol)")
    // --corpus is the Rust twin's canonical flag name; --data-file is the Swift-native spelling.
    // Both are accepted; --data-file takes priority when both are present.
    guard let dataFileStr = optionValue("--data-file", in: args) ?? optionValue("--corpus", in: args) else {
        throw MCPError(description: "missing required option --data-file (or --corpus)")
    }
    let datasetPath = URL(fileURLWithPath: dataFileStr)

    guard FileManager.default.fileExists(atPath: datasetPath.path) else {
        throw MCPError(description:
            "LoCoMo dataset file not found at \(datasetPath.path). "
            + "Run scripts/fetch-locomo.sh to download the dataset.")
    }

    // mootx01 binary: --mootx01-binary is the Swift-native spelling; --binary is the
    // Rust twin's name. Both are accepted for CLI contract parity (Defect 4).
    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[locomo] auto-discovered mootx01 at: \(mootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(mootBinary)'. "
            + "Build with `swift build --package-path apps/mootx01`.")
    }

    let limit = try parseLimitOption(in: args)
    let offset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    let seed = optionValue("--seed", in: args).flatMap(UInt64.init) ?? 20_260_725
    let encodeBarrierStr = optionValue("--encode-barrier", in: args) ?? "drain"
    let loCoMoEncodeBarrier: EncodeBarrier
    switch encodeBarrierStr {
    case "drain":     loCoMoEncodeBarrier = .drain
    case "impatient": loCoMoEncodeBarrier = .impatient
    case "none":      loCoMoEncodeBarrier = .none
    default:
        throw MCPError(description:
            "--encode-barrier must be 'drain', 'impatient', or 'none'; got '\(encodeBarrierStr)'")
    }
    // Created up front: a missing --out used to surface only when the report
    // was written, after the whole run had already been paid for.
    let outDir = try resolvedOutputDirectory(in: args)
    // Estate cache mode (LME-07).
    let loCoMoEstateCacheStr = optionValue("--estate-cache", in: args) ?? "off"
    let loCoMoEstateCache: EstateCacheMode
    switch loCoMoEstateCacheStr {
    case "off":   loCoMoEstateCache = .off
    case "reuse": loCoMoEstateCache = .reuse
    case "require": loCoMoEstateCache = .require
    default:
        throw MCPError(description:
            "--estate-cache must be 'off', 'reuse', or 'require'; got '\(loCoMoEstateCacheStr)'")
    }
    let loCoMoCacheDir = optionValue("--cache-dir", in: args).map { URL(fileURLWithPath: $0) }
    // --estate-mode: see the longmemeval parser — same semantics.
    let loCoMoScratchPosture = try parseEstateMode(in: args)
    // Accuracy lanes never test encryption; that is the timing lane's mandate.
    if loCoMoScratchPosture == .encryptedEphemeral {
        throw MCPError(description: "encryption is tested only by the timing lane")
    }

    FileHandle.standardOutput.write(Data(
        "[locomo] loading corpus from \(datasetPath.path)\n".utf8))

    let corpus = try loadLoCoMoCorpus(from: datasetPath)
    // B2 provenance: digest the corpus fixture once at load time.
    let loCoMoCorpusDigest = fileSha256Hex(path: datasetPath.path) ?? "unknown"
    FileHandle.standardOutput.write(Data((
        "[locomo] loaded \(corpus.conversations.count) conversations, "
        + "\(corpus.questions.count) scoreable questions "
        + "(\(corpus.adversarialCount) adversarial excluded)\n").utf8))
    FileHandle.standardOutput.write(Data("[locomo] encode-barrier: \(loCoMoEncodeBarrier.rawValue)\n".utf8))

    // --strategy search|shaped|precise (default: search).
    //   search:  bare moot_memory_search with location:benchmarks/locomo (byte-stable default).
    //   shaped:  moot_recall_shaped, steers the signed-weight fusion engine;
    //            accepts an optional preset via --recall-shape.
    //   precise: moot_recall_precise precision-retrieval mode.
    // The strategy name is embedded in the run label when non-default so cells
    // are distinguishable without reading the report JSON.
    let loCoMoStrategyStr = optionValue("--strategy", in: args) ?? "search"
    let loCoMoStrategy: LoCoMoRecallStrategy
    switch loCoMoStrategyStr {
    case "search":  loCoMoStrategy = .search
    case "shaped":  loCoMoStrategy = .shaped
    case "precise": loCoMoStrategy = .precise
    // Two-pass conversational multi-hop (item 12): decompose → pools →
    // RRF-intersect, bridge re-query when pools are disjoint.
    case "multihop": loCoMoStrategy = .multihop
    case "connected": loCoMoStrategy = .connected
    default:
        throw MCPError(description:
            "--strategy must be 'search', 'shaped', 'precise', or 'multihop', or 'connected'; got '\(loCoMoStrategyStr)'")
    }
    // --category single_hop|temporal|multi_hop|open_domain: run one question
    // category as its own cell (applied before --limit so the limit counts
    // the requested category — multi-hop is only ~4% of a shuffled slice).
    let loCoMoCategory = optionValue("--category", in: args)
    if let cat = loCoMoCategory,
       !["single_hop", "temporal", "multi_hop", "open_domain"].contains(cat) {
        throw MCPError(description:
            "--category must be 'single_hop', 'temporal', 'multi_hop', or "
            + "'open_domain'; got '\(cat)'")
    }
    // --recall-shape <preset>: named preset for --strategy shaped.
    // Validated against the product's 19-preset roster so a typo fails at parse
    // rather than silently falling through to the unsteered default mid-run.
    let loCoMoRecallShape = optionValue("--recall-shape", in: args)
    if let shape = loCoMoRecallShape, !lmeRecallShapePresets.contains(shape) {
        throw MCPError(description:
            "--recall-shape must be one of: \(lmeRecallShapePresets.joined(separator: ", ")); got '\(shape)'")
    }
    // Post-retrieval rerank (W2-rerank): optional external rerank command.
    // Presence only is recorded in the report; command text never logged.
    // SECURE PATH: set MOOT_BENCH_RERANK_CMD in the environment (env var takes
    // precedence over --rerank-cmd flag; flag value is visible in `ps` argv).
    let loCoMoRerankCmd: String? =
        ProcessInfo.processInfo.environment["MOOT_BENCH_RERANK_CMD"]
        ?? optionValue("--rerank-cmd", in: args)
    // Seed-path (--seed-path batch|live, default batch). Governing ruling 8D5B8053.
    let loCoMoSeedPath = try SeedPathMode.parse(optionValue("--seed-path", in: args))
    // Guard sampling policy (--guard-sample once|per-unit, default once).
    let loCoMoGuardSamplingPolicy = try GuardSamplingPolicy.parse(optionValue("--guard-sample", in: args))
    // --shape disk|ram (default: disk). C1 — selects the mootx01 backend.
    // "ram" injects serve --in-memory into the serve command and is
    // incompatible with --estate-cache reuse|require (an in-memory estate cannot
    // be snapshotted — see LoCoMoEstateShape for the full contract).
    let loCoMoShapeStr = optionValue("--shape", in: args) ?? "disk"
    let loCoMoShape: LoCoMoEstateShape
    switch loCoMoShapeStr {
    case "disk": loCoMoShape = .disk
    case "ram":  loCoMoShape = .ram
    default:
        throw MCPError(description:
            "--shape must be 'disk' or 'ram'; got '\(loCoMoShapeStr)'")
    }
    // RAM shape is incompatible with estate-cache reuse|require: a RAM estate is
    // ephemeral and cannot be written to disk for snapshot reuse.
    if loCoMoShape == .ram && loCoMoEstateCache != .off {
        throw MCPError(description:
            "--shape ram is incompatible with --estate-cache \(loCoMoEstateCache.rawValue): "
            + "an in-memory estate is not written to disk and cannot be snapshotted. "
            + "Use --estate-cache off (the default) with --shape ram.")
    }
    // --parallel N (default: max(1, 80% of logical cores)). C6 — bounded conversation
    // concurrency. 1 = serial behaviour. Each conversation owns its own estate and MCP
    // client; the per-question inner loop stays serial within each conversation.
    let loCoMoDefaultParallel = max(1, ProcessInfo.processInfo.activeProcessorCount * 4 / 5)
    let loCoMoParallel: Int
    if let parallelStr = optionValue("--parallel", in: args) {
        guard let n = Int(parallelStr), n >= 1 else {
            throw MCPError(description:
                "--parallel must be a positive integer; got '\(parallelStr)'")
        }
        loCoMoParallel = n
    } else {
        loCoMoParallel = loCoMoDefaultParallel
    }
    // Run label: omit strategy suffix for the default search so existing reports
    // stay byte-stable. Shaped/precise append the strategy (and preset if set).
    // -rerank suffix appended when active so cells are distinguishable.
    let loCoMoRunLabel: String = {
        var label: String
        if loCoMoStrategyStr == "search" {
            label = "locomo-seed\(seed)"
        } else {
            label = "locomo-seed\(seed)-\(loCoMoStrategyStr)"
            if let shape = loCoMoRecallShape { label += "-\(shape)" }
        }
        if loCoMoRerankCmd != nil { label += "-rerank" }
        return label
    }()
    var runConfig = LoCoMoRunConfig(
        mootBinaryPath: mootBinary,
        datasetPath: datasetPath,
        limit: limit,
        offset: offset,
        seed: seed,
        outDir: outDir,
        runLabel: loCoMoRunLabel,
        encodeBarrier: loCoMoEncodeBarrier,
        estateCache: loCoMoEstateCache,
        cacheDir: loCoMoCacheDir,
        scratchPosture: loCoMoScratchPosture,
        strategy: loCoMoStrategy,
        categoryFilter: loCoMoCategory,
        recallShape: loCoMoRecallShape,
        rerankCmd: loCoMoRerankCmd,
        seedPath: loCoMoSeedPath
    )
    // Instrument seams (environment-only; see RetrievalCallSpec.swift):
    // MOOT_BENCH_RETRIEVAL_TOOL/_ARGS override the query call;
    // MOOT_BENCH_UNIT_IDS pins the unit set.
    runConfig.retrievalCall = try retrievalCallSpecFromEnvironment()
    runConfig.unitIDs = try unitIDsFromEnvironment()
    // --payload-arm v0..v5 (PAYLOAD-ARMS; MOOT_BENCH_PAYLOAD_ARM as the
    // environment spelling): payload-economics shape variant applied to
    // seam-routed retrieval textBlocks. Recorded in run_environment.
    runConfig.payloadArm = try parsePayloadArm(
        optionValue("--payload-arm", in: args)
        ?? ProcessInfo.processInfo.environment["MOOT_BENCH_PAYLOAD_ARM"])
    // Fail-loud (mislabeled-cell rule): only the .search strategy routes
    // through the retrieval seam in this lane; any other strategy would
    // record the arm in run_environment yet never apply it.
    if runConfig.payloadArm != nil && loCoMoStrategy != .search {
        throw MCPError(description:
            "--payload-arm requires --strategy search in the locomo lane; "
            + "got '\(loCoMoStrategy)'")
    }
    runConfig.guardSamplingPolicy = loCoMoGuardSamplingPolicy
    runConfig.corpusDigest = loCoMoCorpusDigest
    // C1/C6: wire shape and parallel concurrency into the run config.
    runConfig.shape = loCoMoShape
    runConfig.parallelConversations = loCoMoParallel
    FileHandle.standardOutput.write(Data(
        "[locomo] shape: \(loCoMoShape.rawValue)\n".utf8))
    FileHandle.standardOutput.write(Data(
        "[locomo] parallel: \(loCoMoParallel)\n".utf8))

    let (results, loCoMoRerankFailures, loCoMoTimingReport) = try await runLoCoMoQuestions(
        questions: corpus.questions,
        conversations: corpus.conversations,
        config: runConfig
    )


    let scores = results.map { scoreLoCoMoQuestion($0) }
    // Collect identity provenance once before building the report.
    // Pre-compute arm and serial for the stamp — arm is measuredConversations which
    // is derivable from results before report construction (testname-arm-serial discipline).
    let measuredConversations = Set(results.map(\.conversationIndex)).count
    let loCoMoArm = "all\(measuredConversations)"
    let loCoMoSerial = resolveRunSerial(args)
    var loCoMoIdentity = IdentityEnvironment.collect(
        mootx01BinaryPath: mootBinary, payloadArm: runConfig.payloadArm)
    stampTestIdentity(&loCoMoIdentity, test: "locomo", arm: loCoMoArm, serial: loCoMoSerial)
    let report = buildLoCoMoReport(
        config: runConfig, corpus: corpus, results: results, scores: scores,
        rerankFailures: loCoMoRerankFailures, identityEnvironment: loCoMoIdentity,
        shape: loCoMoShape.rawValue, parallelUnits: loCoMoParallel,
        timingReport: loCoMoTimingReport)

    // `<test>-<arm>-<serial>`: LoCoMo's arm is how many conversations were
    // MEASURED, not how many were loaded. `--limit` bounds questions, so a
    // one-question smoke run touches one conversation while the loaded corpus
    // still holds ten — naming the arm from the corpus would let a bounded run
    // wear a full run's filename, which is the defect this naming exists to
    // prevent. Arm and serial were pre-computed above for the stamp.
    let reportFilename = recordFilename(
        test: "locomo", arm: loCoMoArm,
        serial: loCoMoSerial)
    let reportURL = (outDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent(reportFilename)
    try writeLoCoMoReport(report, to: reportURL)

    // Timing sidecar (--timing-sidecar, default off).
    // Written beside the accuracy report as <basename>.timing.json.
    // The accuracy report shape is UNCHANGED; timing never enters it.
    if flagPresent("--timing-sidecar", in: args) {
        // loCoMoSerial was resolved above for the stamp; reuse it here.
        let unitLatencies: [(id: String, latencySeconds: Double)] = results.map {
            ($0.questionID, $0.queryLatencySeconds)
        }
        let sidecar = makeTimingSidecar(
            lane: "locomo",
            runID: loCoMoSerial,
            identity: loCoMoIdentity,
            unitLatencies: unitLatencies
        )
        try writeTimingSidecar(sidecar, beside: reportURL)
    }

    let guardHealthyCount = scores.filter(\.guardHealthy).count
    let guardRefusals = scores.count - guardHealthyCount
    let totalTurns = results.map(\.turnsIngested).reduce(0, +)
    let (agg, cats, lat) = aggregateLoCoMoScores(scores)

    var summary = """
        [locomo] run complete
          questions processed:  \(results.count)
          guard healthy:        \(guardHealthyCount)
          guard refusals:       \(guardRefusals)
          conversations used:   \(Set(results.map(\.conversationIndex)).count) of \(Set(corpus.questions.map(\.conversationIndex)).count)
          turns ingested total: \(totalTurns)
          recall-any@1:         \(String(format: "%.4f", agg.recallAnyAt1))
          recall-any@5:         \(String(format: "%.4f", agg.recallAnyAt5))
          recall-any@10:        \(String(format: "%.4f", agg.recallAnyAt10))
          recall-all@1:         \(String(format: "%.4f", agg.recallAllAt1))
          recall-all@5:         \(String(format: "%.4f", agg.recallAllAt5))
          recall-all@10:        \(String(format: "%.4f", agg.recallAllAt10))
          mrr:                  \(String(format: "%.4f", agg.mrr))
          query p50:            \(String(format: "%.1f", lat.queryP50Seconds * 1000)) ms
          query p95:            \(String(format: "%.1f", lat.queryP95Seconds * 1000)) ms

        """
    // Per-category breakdown.
    for cat in cats {
        summary += String(format:
            "  %-14@ @5 any=%.4f all=%.4f mrr=%.4f (n=%d)\n",
            cat.label as NSString, cat.recallAnyAt5, cat.recallAllAt5, cat.mrr, cat.queryCount)
    }
    summary += "  report written to: \(reportURL.path)\n\n"
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// locomo-spec subcommand — official LoCoMo QA scoring protocol (§1–§6).
///
///   mcp-benchmarker locomo-spec --data-file <locomo10.json>
///       [--mootx01-binary <path>] [--limit N] [--offset K] [--seed S]
///       [--out <dir>] [--encode-barrier drain|impatient|none]
///       [--estate-cache off|reuse|require] [--cache-dir <dir>]
///       [--estate-mode unencrypted|encrypted]
///       [--granularity turn|session] [--shape disk|ram] [--parallel N]
///       [--guard-sample once|per-unit] [--run-id <id>]
///
/// Provisions one scratch estate per conversation (10 total), ingests turns via
/// moot_json_import (batch seed path — the spec lane never uses the live path),
/// and evaluates per-question answer quality. Answers are produced via
/// moot_synthesize. Scoring: F1 for categories 1–4, binary abstention for
/// category 5 (adversarial). Evidence recall (§4) is the fraction of evidence
/// turns present in the top-retrieved set. Record naming: locomo-spec-<arm>-<serial>.
///
/// This lane uses the same corpus fixture as the `locomo` lane (same locomo10.json
/// path) but evaluates different signals: answer quality vs rank-based recall.
/// The seed default (20260818) differs from the locomo lane's (20260725) so the
/// two lanes produce independent shuffle orders and record filenames never collide.
func runLoCoMoSpec(_ args: [String]) async throws {
    // --corpus is the Rust twin's canonical flag name; --data-file is the Swift-native spelling.
    // Both accepted; --data-file takes priority when both are present.
    guard let dataFileStr = optionValue("--data-file", in: args) ?? optionValue("--corpus", in: args) else {
        throw MCPError(description: "missing required option --data-file (or --corpus)")
    }
    let specDatasetPath = URL(fileURLWithPath: dataFileStr)
    guard FileManager.default.fileExists(atPath: specDatasetPath.path) else {
        throw MCPError(description:
            "LoCoMo-spec dataset file not found at \(specDatasetPath.path). "
            + "Run scripts/fetch-locomo.sh to download the dataset.")
    }

    // mootx01 binary: --mootx01-binary is the Swift-native spelling; --binary is the
    // Rust twin's name. Both accepted for CLI contract parity.
    let specMootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        specMootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        specMootBinary = discovered
        FileHandle.standardError.write(Data(
            "[locomo-spec] auto-discovered mootx01 at: \(specMootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: specMootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(specMootBinary)'. "
            + "Build with `swift build --package-path apps/mootx01`.")
    }

    let specLimit = try parseLimitOption(in: args)
    let specOffset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    // Seed default 20260818 — distinct from the locomo lane's 20260725 so the two
    // lanes produce different shuffle orders and record filenames never collide.
    let specSeed = optionValue("--seed", in: args).flatMap(UInt64.init) ?? 20_260_818

    // Created up front: a missing --out surfaced only when the report was
    // written, after the whole run had already been paid for.
    let specOutDir = try resolvedOutputDirectory(in: args)

    // ── Artifact estate seam (run book §8) ─────────────────────────────────
    // The spec runner opens pre-built artifacts; it builds nothing. unit
    // (the default — the official per-instance protocol shape) requires
    // --catalog; bench-aggregate requires --estate-dir.
    let specScaleStr = optionValue("--target-scale", in: args) ?? "unit"
    guard let specScale = ArtifactTargetScale(rawValue: specScaleStr),
          specScale != .completeAggregate else {
        throw MCPError(description:
            "--target-scale must be unit or bench-aggregate for locomo-spec; "
            + "got '\(specScaleStr)'")
    }
    let specCatalogPath = optionValue("--catalog", in: args).map { URL(fileURLWithPath: $0) }
    let specEstateDir = optionValue("--estate-dir", in: args).map { URL(fileURLWithPath: $0) }
    switch specScale {
    case .unit:
        guard specCatalogPath != nil else {
            throw MCPError(description:
                "locomo-spec --target-scale unit requires --catalog <catalog.json>")
        }
    default:
        guard specEstateDir != nil else {
            throw MCPError(description:
                "locomo-spec --target-scale \(specScale.rawValue) requires --estate-dir <path>")
        }
    }

    // --parallel N (default: ~80% of logical cores). Bounded conversation concurrency.
    // Each conversation owns its own estate and MCP client; the per-question inner
    // loop stays serial within each conversation.
    let specDefaultParallel = max(1, ProcessInfo.processInfo.activeProcessorCount * 4 / 5)
    let specParallel: Int
    if let parallelStr = optionValue("--parallel", in: args) {
        guard let n = Int(parallelStr), n >= 1 else {
            throw MCPError(description:
                "--parallel must be a positive integer; got '\(parallelStr)'")
        }
        specParallel = n
    } else {
        specParallel = specDefaultParallel
    }

    // --guard-sample once|per-unit (default: once). The guard validates the binary,
    // not the unit — probing once per leg is sufficient for most runs.
    let specGuardPolicy = try GuardSamplingPolicy.parse(optionValue("--guard-sample", in: args))

    FileHandle.standardOutput.write(Data(
        "[locomo-spec] loading corpus from \(specDatasetPath.path)\n".utf8))
    // The spec lane uses its own corpus type (LoCoMoSpecCorpus) loaded by
    // loadLoCoMoSpecCorpus, which parses the same locomo10.json fixture but
    // produces the typed QA pairs the spec scorer needs.
    let specCorpus = try loadLoCoMoSpecCorpus(from: specDatasetPath)
    // B2 provenance: digest the corpus fixture once at load time and embed in
    // the report so a report/fixture pairing can be verified without re-running.
    let specCorpusDigest = fileSha256Hex(path: specDatasetPath.path) ?? "unknown"
    FileHandle.standardOutput.write(Data((
        "[locomo-spec] loaded \(specCorpus.conversations.count) conversations, "
        + "\(specCorpus.questions.count) questions\n").utf8))
    FileHandle.standardOutput.write(Data(
        "[locomo-spec] target-scale: \(specScale.rawValue)\n".utf8))
    FileHandle.standardOutput.write(Data(
        "[locomo-spec] parallel: \(specParallel)\n".utf8))

    // Run label: "locomo-spec-seed<N>" embeds the seed so different seeds produce
    // distinguishable arms (and therefore distinct record filenames) without an
    // explicit --label flag. Consistent with the locomo lane's "locomo-seed<N>" shape.
    let specRunLabel = "locomo-spec-seed\(specSeed)"

    var specConfig = LoCoMoSpecRunConfig(
        mootBinaryPath: specMootBinary,
        datasetPath: specDatasetPath,
        limit: specLimit,
        offset: specOffset,
        seed: specSeed,
        outDir: specOutDir,
        runLabel: specRunLabel,
        targetScale: specScale,
        catalogPath: specCatalogPath,
        estateDir: specEstateDir
    )
    specConfig.parallelConversations = specParallel
    specConfig.guardSamplingPolicy = specGuardPolicy
    specConfig.corpusDigest = specCorpusDigest
    // Instrument seam: MOOT_BENCH_UNIT_IDS pins the unit set for the spec lane.
    // Corpus is always loaded in full (corpus_digest unchanged); the filter selects
    // which question IDs run without touching the limit/offset machinery.
    let locomoSpecUnitIDsPath = ProcessInfo.processInfo.environment["MOOT_BENCH_UNIT_IDS"]
    specConfig.unitIDs     = try locomoSpecUnitIDsPath.map { try loadUnitIDs($0) }
    specConfig.unitIDsPath = locomoSpecUnitIDsPath
    specConfig.dumpAnswerInputsPath = optionValue("--dump-answer-inputs", in: args)
    if let depthString = optionValue("--answer-hydration-depth", in: args) {
        guard let depth = Int(depthString), depth > 0 else {
            throw MCPError(description:
                "locomo-spec --answer-hydration-depth must be positive; got '\(depthString)'")
        }
        specConfig.answerHydrationDepth = depth
    }
    if let tierString = optionValue("--hydration-tier", in: args) {
        guard let tier = HydrationDepth(rawValue: tierString) else {
            throw MCPError(description:
                "locomo-spec --hydration-tier must be distilled or full; got '\(tierString)'")
        }
        specConfig.answerHydrationTier = tier
    }
    // --scoring raw|rrf|matrixAware|discriminative: when given, passed as the
    // "scoring" key in every moot_memory_search call. When omitted, the call is
    // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
    specConfig.scoringStrategy = optionValue("--scoring", in: args)

    // --recall-shape <preset>: when given, the per-question recall call switches to
    // moot_recall_shaped with this preset. Mutually exclusive with --scoring.
    let locomoRecallShape = optionValue("--recall-shape", in: args)
    if specConfig.scoringStrategy != nil && locomoRecallShape != nil {
        throw MCPError(description:
            "--scoring and --recall-shape are mutually exclusive for locomo-spec")
    }
    specConfig.recallShape = locomoRecallShape

    // --request-limit N: per-question verb result cap (default 20).
    if let rl = optionValue("--request-limit", in: args).flatMap(Int.init) {
        guard rl >= 1 else {
            throw MCPError(description: "--request-limit must be >= 1; got \(rl)")
        }
        specConfig.requestLimit = rl
    }

    // --short-query-terms N: content-term threshold for the short-query gate (default 4).
    if let sqt = optionValue("--short-query-terms", in: args).flatMap(Int.init) {
        guard sqt >= 1 else {
            throw MCPError(description: "--short-query-terms must be >= 1; got \(sqt)")
        }
        specConfig.shortQueryTerms = sqt
    }

    let specResult = try await runLoCoMoSpecQuestions(
        questions: specCorpus.questions,
        conversations: specCorpus.conversations,
        config: specConfig
    )

    if let dumpPath = specConfig.dumpAnswerInputsPath {
        let dumpData = try loCoMoSpecAnswerInputsJSONL(
            specResult,
            hydrationDepth: specConfig.answerHydrationDepth,
            hydrationTier: specConfig.answerHydrationTier)
        try writeRecordNeverOverwrite(
            dumpData, to: URL(fileURLWithPath: dumpPath))
        FileHandle.standardOutput.write(Data(
            "[locomo-spec] answer inputs written to: \(dumpPath)\n".utf8))
    }

    // Arm: number of conversations whose questions were actually processed.
    // conversationsUsed in the metadata is the authoritative count (determined
    // inside the runner after seed-shuffle + offset + limit apply).
    let specArm = "all\(specResult.metadata.conversationsUsed)"
    let specSerial = resolveRunSerial(args)  // --run-id when set, UTC timestamp otherwise

    // §6 required report fields (F1): decode the runner-built report object,
    // insert machine + binary provenance collected at this CLI layer (the
    // legacy-lane convention), and re-encode with the same sorted-keys format.
    let specReportData: Data = try {
        let base = try loCoMoSpecReportJSON(specResult, arm: specArm, serial: specSerial)
        guard var obj = try JSONSerialization.jsonObject(with: base) as? [String: Any] else {
            return base  // non-object report shape: leave untouched (never expected)
        }
        var specLocIdentity = IdentityEnvironment.collect(mootx01BinaryPath: specMootBinary)
        stampTestIdentity(&specLocIdentity,
                          test: "locomo-spec",
                          arm: specArm,
                          serial: specSerial)
        obj["run_environment"] = try identityEnvironmentJSONObject(specLocIdentity)
        return try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }()

    let specReportFilename = recordFilename(test: "locomo-spec", arm: specArm, serial: specSerial)
    let specReportURL = (specOutDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent(specReportFilename)
    try writeRecordNeverOverwrite(specReportData, to: specReportURL)

    let specOverall = specResult.aggregate.overall
    let specTotalQ = specResult.questionRecords.count
    let specGuardHealthy = specResult.questionRecords.filter(\.guardHealthy).count

    var specSummary = """
        [locomo-spec] run complete
          questions processed:  \(specTotalQ)
          guard healthy:        \(specGuardHealthy)
          conversations used:   \(specResult.metadata.conversationsUsed) of \(specCorpus.conversations.count)
          overall_accuracy:     \(String(format: "%.4f", specOverall))
          overall_evidence_recall: \(String(format: "%.4f", specResult.aggregate.overallMeanRecall))

        """
    // Per-category breakdown: category_order [4,1,2,3,5] per §5.
    let specCatLabels: [Int: String] = [
        1: "single_hop", 2: "temporal", 3: "multi_hop", 4: "open_domain", 5: "adversarial",
    ]
    for cm in specResult.aggregate.byCategory {
        let label = specCatLabels[cm.category] ?? "cat\(cm.category)"
        specSummary += String(format:
            "  %-14@ acc=%.4f recall=%.4f (n=%d)\n",
            label as NSString, cm.accuracy, cm.meanRecall, cm.questionCount)
    }
    specSummary += "  report written to: \(specReportURL.path)\n\n"
    FileHandle.standardOutput.write(Data(specSummary.utf8))
}

/// membench subcommand — MemBench per-item turn-recall harness.
///
///   mcp-benchmarker membench --data-dir <MemData/>
///       [--mootx01-binary <path>] [--agent FirstAgent|ThirdAgent]
///       [--category <name>] [--limit N] [--offset K] [--seed S]
///       [--encode-barrier drain|impatient|none] [--estate-mode unencrypted|encrypted]
///       [--estate-cache off|reuse|require] [--out <dir>]
///       [--shape disk|ram]      storage backend — disk (SQLite, default) or
///                               ram (InMemory, no snapshot; incompatible with --estate-cache reuse|require)
///       [--parallel N]          concurrent items — default 80% of logical cores; 1 = serial
///
/// Provisions one scratch estate per item, ingests all session turns via the
/// configured seed-path with the configured encode barrier, and reports
/// Recall-any@k / MRR / latency with per-category breakdown. Dataset must be
/// pre-fetched with scripts/fetch-membench.sh.
func runMemBench(_ args: [String]) async throws {
    guard let dataDirStr = optionValue("--data-dir", in: args) else {
        throw MCPError(description:
            "missing required option --data-dir (path to MemData/ directory containing "
            + "FirstAgent/ or ThirdAgent/)")
    }
    let dataDir = URL(fileURLWithPath: dataDirStr)
    guard FileManager.default.fileExists(atPath: dataDir.path) else {
        throw MCPError(description:
            "MemBench MemData directory not found at \(dataDir.path). "
            + "Run scripts/fetch-membench.sh to download the dataset.")
    }

    // mootx01 binary: --mootx01-binary is the Swift-native spelling; --binary is the
    // Rust twin's name. Both accepted for CLI contract parity.
    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[membench] auto-discovered mootx01 at: \(mootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(mootBinary)'. "
            + "Build with `swift build --package-path apps/mootx01`.")
    }

    let agent = optionValue("--agent", in: args) ?? "FirstAgent"
    guard agent == "FirstAgent" || agent == "ThirdAgent" else {
        throw MCPError(description:
            "--agent must be 'FirstAgent' or 'ThirdAgent'; got '\(agent)'")
    }

    let limit = try parseLimitOption(in: args)
    let offset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    // Default seed is 20260806 — the date this lane was added — so MemBench
    // runs are distinguishable from LoCoMo (20260725) and LME (20260725) seeds
    // in multi-run logs that don't record the subcommand name.
    let seed = optionValue("--seed", in: args).flatMap(UInt64.init) ?? 20_260_806

    let encodeBarrierStr = optionValue("--encode-barrier", in: args) ?? "drain"
    let memBenchEncodeBarrier: EncodeBarrier
    switch encodeBarrierStr {
    case "drain":     memBenchEncodeBarrier = .drain
    case "impatient": memBenchEncodeBarrier = .impatient
    case "none":      memBenchEncodeBarrier = .none
    default:
        throw MCPError(description:
            "--encode-barrier must be 'drain', 'impatient', or 'none'; got '\(encodeBarrierStr)'")
    }

    // Created up front: a missing --out used to surface only when the report
    // was written, after the whole run had already been paid for.
    let outDir = try resolvedOutputDirectory(in: args)

    let memBenchScratchPosture = try parseEstateMode(in: args)
    // Accuracy lanes never test encryption; that is the timing lane's mandate.
    if memBenchScratchPosture == .encryptedEphemeral {
        throw MCPError(description: "encryption is tested only by the timing lane")
    }

    // Seed-path (--seed-path batch|live, default batch). Governing ruling 8D5B8053.
    let memBenchSeedPath = try SeedPathMode.parse(optionValue("--seed-path", in: args))
    // Guard sampling policy (--guard-sample once|per-unit, default once).
    let memBenchGuardSamplingPolicy = try GuardSamplingPolicy.parse(optionValue("--guard-sample", in: args))

    // --category: optional single-category filter.
    let memBenchCategoryFilter = optionValue("--category", in: args)
    if let cat = memBenchCategoryFilter,
       !memBenchCategoryLabels.contains(cat) {
        // Allow non-canonical category names too (HighLevel categories like "highlevel").
        // Log a warning but don't throw — the user may be querying a non-LowLevel file.
        let catWarning = "[membench] warning: --category '\(cat)' is not a standard LowLevel category; "
            + "it will filter items whose category field equals this string.\n"
        FileHandle.standardError.write(Data(catWarning.utf8))
    }

    FileHandle.standardOutput.write(Data(
        "[membench] loading corpus from \(dataDir.path) (agent: \(agent))\n".utf8))

    let corpus = try loadMemBenchCorpus(
        dataDir: dataDir,
        agent: agent,
        categories: memBenchCategoryFilter.map { [$0] },
        limit: nil   // limit applied by the runner after shuffle
    )
    FileHandle.standardOutput.write(Data((
        "[membench] loaded \(corpus.items.count) items "
        + "(\(corpus.skippedCount) skipped)\n").utf8))
    FileHandle.standardOutput.write(Data(
        "[membench] encode-barrier: \(memBenchEncodeBarrier.rawValue)\n".utf8))

    // Estate cache mode (B6 — membench artifact wiring).
    let memBenchEstateCacheStr = optionValue("--estate-cache", in: args) ?? "off"
    let memBenchEstateCache: EstateCacheMode
    switch memBenchEstateCacheStr {
    case "off":   memBenchEstateCache = .off
    case "reuse": memBenchEstateCache = .reuse
    case "require": memBenchEstateCache = .require
    default:
        throw MCPError(description:
            "--estate-cache must be 'off', 'reuse', or 'require'; got '\(memBenchEstateCacheStr)'")
    }
    let memBenchCacheDir = optionValue("--cache-dir", in: args).map { URL(fileURLWithPath: $0) }

    // C1: storage backend shape (--shape disk|ram, default disk).
    // RAM shape injects serve --in-memory into the serve command — no SQLite
    // file is written, so no snapshot can be taken or restored. RAM + a non-off
    // estate-cache mode is therefore rejected before any work begins.
    let memBenchShape = try BenchShape.parse(optionValue("--shape", in: args))
    if memBenchShape == .ram && memBenchEstateCache != .off {
        throw MCPError(description:
            "--shape ram cannot be combined with --estate-cache \(memBenchEstateCacheStr): "
            + "a RAM estate holds no disk artifact, so no snapshot can be taken or restored. "
            + "Run RAM shape with --estate-cache off.")
    }

    // C6: parallel items (--parallel N, default 80% of logical cores, minimum 1).
    // N == 1 reproduces the previous serial behaviour exactly (one outstanding task at
    // a time); the TaskGroup sliding-window pattern sorts results by index before
    // returning, so report ordering is byte-deterministic at any concurrency level.
    let memBenchParallelUnits: Int
    if let rawParallel = optionValue("--parallel", in: args) {
        guard let n = Int(rawParallel), n >= 1 else {
            throw MCPError(description:
                "--parallel must be a positive integer; got '\(rawParallel)'")
        }
        memBenchParallelUnits = n
    } else {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        memBenchParallelUnits = max(1, Int(Double(cores) * 0.8))
    }

    // B2 provenance: MemData is a directory corpus — combine the per-file
    // digests of the agent subtree's JSON fixtures (sorted by relative path)
    // into one stable value, same shape as LMEB's multi-file digest.
    let memBenchCorpusDigest: String = {
        let agentRoot = dataDir.appendingPathComponent(agent)
        guard let en = FileManager.default.enumerator(
            at: agentRoot, includingPropertiesForKeys: nil) else { return "unknown" }
        var files: [String] = []
        for case let url as URL in en where url.pathExtension == "json" {
            files.append(url.path)
        }
        guard !files.isEmpty else { return "unknown" }
        var combined = ""
        for f in files.sorted() {
            combined += "\(f.dropFirst(agentRoot.path.count))=\(fileSha256Hex(path: f) ?? "unknown");"
        }
        return sha256HexOfString(combined)
    }()

    // C10: estate grouping mode (--estate-grouping per-item|consolidated, default per-item).
    // "consolidated" selects Shape 3: non-overlapping groups by question text, one
    // estate per group. Every Shape 3 figure carries protocol_deviation: true in the
    // report JSON so it is never confused with the published per-item numbers.
    let memBenchEstateGrouping = try EstateGroupingMode.parse(
        optionValue("--estate-grouping", in: args))

    // C11: capacity tier (--capacity-tier baseline|10k|100k, default baseline).
    // Non-baseline tiers grow each item's estate with conflict-free filler (same
    // C10 conflict key: question text) before querying. Report fields carry
    // capacity_tier, capacity_achieved_tokens_p50/max, and capacity_items_per_estate.
    let memBenchCapacityTier = try CapacityTier.parse(
        optionValue("--capacity-tier", in: args))

    let runLabel = "membench-\(agent.lowercased())-seed\(seed)"
    var runConfig = MemBenchRunConfig(
        mootBinaryPath: mootBinary,
        dataDir: dataDir,
        agent: agent,
        categories: nil,           // categories already filtered at load time
        limit: limit,
        offset: offset,
        seed: seed,
        outDir: outDir,
        runLabel: runLabel,
        encodeBarrier: memBenchEncodeBarrier,
        scratchPosture: memBenchScratchPosture,
        categoryFilter: memBenchCategoryFilter,
        seedPath: memBenchSeedPath,
        guardSamplingPolicy: memBenchGuardSamplingPolicy,
        estateCache: memBenchEstateCache,
        cacheDir: memBenchCacheDir,
        corpusDigest: memBenchCorpusDigest,
        shape: memBenchShape,
        parallelUnits: memBenchParallelUnits,
        estateGrouping: memBenchEstateGrouping,
        capacityTier: memBenchCapacityTier
    )
    // Instrument seams (environment-only; see RetrievalCallSpec.swift):
    // MOOT_BENCH_RETRIEVAL_TOOL/_ARGS override the query call;
    // MOOT_BENCH_UNIT_IDS pins the unit set.
    runConfig.retrievalCall = try retrievalCallSpecFromEnvironment()
    runConfig.unitIDs = try unitIDsFromEnvironment()
    // --payload-arm v0..v5 (PAYLOAD-ARMS; MOOT_BENCH_PAYLOAD_ARM as the
    // environment spelling): payload-economics shape variant applied to
    // seam-routed retrieval textBlocks. Recorded in run_environment.
    runConfig.payloadArm = try parsePayloadArm(
        optionValue("--payload-arm", in: args)
        ?? ProcessInfo.processInfo.environment["MOOT_BENCH_PAYLOAD_ARM"])

    // C10 + C11: branch on grouping mode and capacity tier.
    //   - Consolidated Shape 3 (C10): all items share one estate per conflict-key group.
    //   - Capacity tier (C11): per-item estates grown with conflict-free filler.
    //   - Baseline per-item (default): one estate per item, no filler.
    // Shape 3 and capacity tier are mutually exclusive: --estate-grouping consolidated
    // takes precedence over any --capacity-tier value when both are set.
    let results: [MemBenchItemResult]
    let membenchTimingReport: String?
    let shape3Groups: [[MemBenchItem]]?
    var capacityAchievedTokensPerItem: [Int]? = nil
    var capacityItemsPerEstate: [Int]? = nil
    if memBenchEstateGrouping == .consolidatedShape3 {
        let (r, t, g) = try await runMemBenchItemsConsolidated(items: corpus.items, config: runConfig)
        (results, membenchTimingReport, shape3Groups) = (r, t, g)
    } else if let targetTokens = memBenchCapacityTier.targetTokens {
        let (r, t, achieved, itemCounts) = try await runMemBenchItemsCapacityTier(
            items: corpus.items, config: runConfig, targetTokens: targetTokens)
        (results, membenchTimingReport, shape3Groups) = (r, t, nil)
        (capacityAchievedTokensPerItem, capacityItemsPerEstate) = (achieved, itemCounts)
    } else {
        let (r, t) = try await runMemBenchItems(items: corpus.items, config: runConfig)
        (results, membenchTimingReport, shape3Groups) = (r, t, nil)
    }
    let scores = results.map { scoreMemBenchItem($0) }
    // Collect identity provenance once before building the report.
    // Pre-compute arm (= agent, known before report construction) and serial
    // so the stamp is applied before report construction (testname-arm-serial discipline).
    let memBenchSerial = resolveRunSerial(args)
    var memBenchIdentity = IdentityEnvironment.collect(
        mootx01BinaryPath: mootBinary, payloadArm: runConfig.payloadArm)
    stampTestIdentity(&memBenchIdentity, test: "membench", arm: agent, serial: memBenchSerial)
    let report = buildMemBenchReport(
        config: runConfig, corpus: corpus, results: results, scores: scores,
        identityEnvironment: memBenchIdentity, timingReport: membenchTimingReport,
        shape3Groups: shape3Groups,
        achievedTokensPerItem: capacityAchievedTokensPerItem,
        itemsPerEstate: capacityItemsPerEstate)

    // `<test>-<arm>-<serial>`: the arm is the agent perspective. FirstAgent and
    // ThirdAgent are different task shapes, and before 2026-08-17 they shared
    // one filename — the second perspective measured would have destroyed the
    // first perspective's report. Arm and serial were pre-computed above for the stamp.
    let reportFilename = recordFilename(
        test: "membench", arm: agent, serial: memBenchSerial)
    let reportURL = (outDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent(reportFilename)
    try writeMemBenchReport(report, to: reportURL)

    // Timing sidecar (--timing-sidecar, default off).
    // Written beside the accuracy report as <basename>.timing.json.
    // The accuracy report shape is UNCHANGED; timing never enters it.
    if flagPresent("--timing-sidecar", in: args) {
        // memBenchSerial was resolved above for the stamp; reuse it here.
        let unitLatencies: [(id: String, latencySeconds: Double)] = results.map {
            ($0.itemID, $0.queryLatencySeconds)
        }
        let sidecar = makeTimingSidecar(
            lane: "membench",
            runID: memBenchSerial,
            identity: memBenchIdentity,
            unitLatencies: unitLatencies
        )
        try writeTimingSidecar(sidecar, beside: reportURL)
    }

    let guardHealthyCount = scores.filter(\.guardHealthy).count
    let guardRefusals = scores.count - guardHealthyCount
    let totalTurns = results.map(\.turnsIngested).reduce(0, +)
    let (agg, cats, lat) = aggregateMemBenchScores(scores)

    var summary = """
        [membench] run complete
          items processed:      \(results.count)
          guard healthy:        \(guardHealthyCount)
          guard refusals:       \(guardRefusals)
          turns ingested total: \(totalTurns)
          recall-any@1:         \(String(format: "%.4f", agg.recallAnyAt1))
          recall-any@5:         \(String(format: "%.4f", agg.recallAnyAt5))
          recall-any@10:        \(String(format: "%.4f", agg.recallAnyAt10))
          recall-all@1:         \(String(format: "%.4f", agg.recallAllAt1))
          recall-all@5:         \(String(format: "%.4f", agg.recallAllAt5))
          recall-all@10:        \(String(format: "%.4f", agg.recallAllAt10))
          mrr:                  \(String(format: "%.4f", agg.mrr))
          query p50:            \(String(format: "%.1f", lat.queryP50Seconds * 1000)) ms
          query p95:            \(String(format: "%.1f", lat.queryP95Seconds * 1000)) ms

        """
    // Per-category breakdown.
    for cat in cats {
        summary += String(format:
            "  %-22@ @5 any=%.4f all=%.4f mrr=%.4f (n=%d)\n",
            cat.label as NSString, cat.recallAnyAt5, cat.recallAllAt5, cat.mrr, cat.queryCount)
    }
    summary += "  report written to: \(reportURL.path)\n\n"
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// Runs the LMEB/ConvoMem retrieval benchmark.
///
/// Arguments:
///   --data-dir <dir>             Root directory containing evidence-type subdirs.
///   --evidence-types ET1,ET2,... Comma-separated evidence types to include.
///                                Defaults to all six ConvoMem evidence types.
///   --mootx01-binary <path>      Path to mootx01 binary (auto-discovered if omitted).
///   --limit N                    Run only the first N queries (after seeded shuffle).
///   --offset K                   Skip first K queries from the shuffled list.
///   --seed S                     Random seed for deterministic shuffling (default 20260725).
///   --out <dir>                  Output directory for the report file.
func runLMEB(_ args: [String]) async throws {
    // Darkening gates ND-LMEB-1/2: judged path (ruling 2026-08-18).
    try rejectDarkenedLegacyOptions(
        lane: "lmeb",
        flags: ["--judge-cmd"],
        envVars: ["MOOT_BENCH_JUDGE_CMD"],
        in: args,
        replacement: "the convomem-spec lane (official judged protocol)")
    if optionValue("--judge-grading", in: args) == "verdict" {
        throw MCPError(description:
            "--judge-grading verdict is dark on the legacy lmeb lane "
            + "(ND-LMEB-2, ruling 2026-08-18). Use the convomem-spec lane's §B3 verdicts.")
    }
    let allEvidenceTypes = [
        "abstention_evidence",
        "assistant_facts_evidence",
        "changing_evidence",
        "implicit_connection_evidence",
        "preference_evidence",
        "user_evidence",
    ]

    let dataDirStr = try requireOption("--data-dir", in: args)
    let dataDir = URL(fileURLWithPath: dataDirStr)

    guard FileManager.default.fileExists(atPath: dataDir.path) else {
        throw MCPError(description:
            "LMEB data directory not found at \(dataDir.path). "
            + "Run scripts/fetch-lmeb.sh to download the dataset.")
    }

    // Evidence types: comma-separated flag or default to all six.
    let evidenceTypes: [String]
    if let etStr = optionValue("--evidence-types", in: args) {
        evidenceTypes = etStr.split(separator: ",").map(String.init)
    } else {
        evidenceTypes = allEvidenceTypes
    }

    // mootx01 binary: --mootx01-binary is the Swift-native spelling; --binary is the
    // Rust twin's name. Both are accepted for CLI contract parity (Defect 4).
    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[lmeb] auto-discovered mootx01 at: \(mootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(mootBinary)'. "
            + "Build with `swift build --package-path apps/mootx01`.")
    }

    let limit   = try parseLimitOption(in: args)
    let offset  = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    let seed    = optionValue("--seed",   in: args).flatMap(UInt64.init) ?? 20_260_725
    let outDir  = try resolvedOutputDirectory(in: args)
    let lmebEncodeBarrierStr = optionValue("--encode-barrier", in: args) ?? "drain"
    let lmebEncodeBarrier: EncodeBarrier
    switch lmebEncodeBarrierStr {
    case "drain":     lmebEncodeBarrier = .drain
    case "impatient": lmebEncodeBarrier = .impatient
    case "none":      lmebEncodeBarrier = .none
    default:
        throw MCPError(description:
            "--encode-barrier must be 'drain', 'impatient', or 'none'; got '\(lmebEncodeBarrierStr)'")
    }
    // Estate cache mode (LME-07).
    let lmebEstateCacheStr = optionValue("--estate-cache", in: args) ?? "off"
    let lmebEstateCache: EstateCacheMode
    switch lmebEstateCacheStr {
    case "off":   lmebEstateCache = .off
    case "reuse": lmebEstateCache = .reuse
    case "require": lmebEstateCache = .require
    default:
        throw MCPError(description:
            "--estate-cache must be 'off', 'reuse', or 'require'; got '\(lmebEstateCacheStr)'")
    }
    let lmebCacheDir = optionValue("--cache-dir", in: args).map { URL(fileURLWithPath: $0) }
    // --estate-mode: see the longmemeval parser — same semantics.
    let lmebScratchPosture = try parseEstateMode(in: args)
    // Accuracy lanes never test encryption; that is the timing lane's mandate.
    if lmebScratchPosture == .encryptedEphemeral {
        throw MCPError(description: "encryption is tested only by the timing lane")
    }

    // Judge flags (W4-lmeb-accuracy). judgeCmd presence-only rule: the command
    // text carries API keys and must NEVER appear in report output (not even
    // as a hash or truncation). Only judge_cmd_set (bool) is written.
    // SECURE PATH: set MOOT_BENCH_JUDGE_CMD in the environment (env var takes
    // precedence over --judge-cmd flag; flag value is visible in `ps` argv).
    let lmebJudgeCmd: String? =
        ProcessInfo.processInfo.environment["MOOT_BENCH_JUDGE_CMD"]
        ?? optionValue("--judge-cmd", in: args)
    let lmebJudgeGradingStr = optionValue("--judge-grading", in: args) ?? "substring"
    let lmebJudgeGrading: LMEJudgeGrading
    switch lmebJudgeGradingStr {
    case "substring": lmebJudgeGrading = .substring
    case "verdict":   lmebJudgeGrading = .verdict
    default:
        throw MCPError(description:
            "--judge-grading must be 'substring' or 'verdict'; got '\(lmebJudgeGradingStr)'")
    }
    // Mirror longmemeval's guard: reject non-integer and reject <= 0.
    // Uses the same validatedCount helper that all other integer options use.
    let lmebJudgeHydrationDepth = try validatedCount(
        "--judge-hydration-depth", in: args,
        default: lmeDefaultJudgePayloadHydrationDepth, minimum: 1)

    let loadMsg = "[lmeb] loading corpus from \(dataDir.path) "
        + "(evidence types: \(evidenceTypes.joined(separator: ", ")))\n"
    FileHandle.standardOutput.write(Data(loadMsg.utf8))

    let corpus = try loadLMEBCorpus(baseDir: dataDir, evidenceTypes: evidenceTypes)
    // Provenance: hash each evidence type's four required files in fixed
    // ASCII-ascending order ({et}/candidates.jsonl, corpus.jsonl, qrels.tsv,
    // queries.jsonl). Returns "unknown" if any required file cannot be read,
    // which causes ArtifactProvenance.mismatches to refuse the cached artifact.
    // Mirrors the Rust CLI's lmeb_corpus_digest byte-for-byte.
    let lmebCorpusDigest = lmebCorpusDigest(baseDir: dataDir, evidenceTypes: evidenceTypes)
    let loadedMsg = "[lmeb] loaded \(corpus.queryCount) queries, "
        + "\(corpus.docCount) docs, \(corpus.qrelCount) qrels\n"
    FileHandle.standardOutput.write(Data(loadedMsg.utf8))
    FileHandle.standardOutput.write(Data("[lmeb] encode-barrier: \(lmebEncodeBarrier.rawValue)\n".utf8))

    let runLabel = "lmeb-seed\(seed)"
    // Seed path (--seed-path batch|live, default batch). Governing ruling 8D5B8053.
    // batch: emit seed-file schema v1 → moot_json_import → needle attribution.
    // live:  per-doc moot_file_memory (slow lane, retained for equivalence re-proving).
    let lmebSeedPath = try SeedPathMode.parse(optionValue("--seed-path", in: args))
    // Guard sampling policy (--guard-sample once|per-unit, default once).
    let lmebGuardSamplingPolicy = try GuardSamplingPolicy.parse(optionValue("--guard-sample", in: args))
    // --shape disk|ram (default: disk). C1 — selects the mootx01 backend.
    // "ram" injects serve --in-memory into the serve command. RAM
    // estates are ephemeral — no on-disk snapshot can be saved or restored,
    // so combining ram with --estate-cache reuse|require is rejected here.
    let lmebShapeStr = optionValue("--shape", in: args) ?? "disk"
    let lmebShape: BenchRunShape
    switch lmebShapeStr {
    case "disk": lmebShape = .disk
    case "ram":  lmebShape = .ram
    default:
        throw MCPError(description:
            "--shape must be 'disk' or 'ram'; got '\(lmebShapeStr)'")
    }
    if lmebShape == .ram && lmebEstateCache != .off {
        throw MCPError(description:
            "--shape ram cannot be combined with --estate-cache \(lmebEstateCacheStr): "
            + "a RAM estate is ephemeral — no on-disk snapshot exists to save or restore. "
            + "Run ram shape with --estate-cache off.")
    }
    // --parallel N (default: max(1, 80% of logical cores)). C6 — bounded
    // query-unit concurrency. 1 = serial behaviour. Each query owns its own
    // scratch dir, MCPClient, and mootx01 process. Results are sorted by
    // original index after the task group completes so report ordering is
    // byte-deterministic regardless of completion order.
    let lmebDefaultParallel = max(1, Int(Double(ProcessInfo.processInfo.activeProcessorCount) * 0.8))
    let lmebParallel: Int
    if let parallelStr = optionValue("--parallel", in: args) {
        guard let n = Int(parallelStr), n >= 1 else {
            throw MCPError(description:
                "--parallel must be a positive integer; got '\(parallelStr)'")
        }
        lmebParallel = n
    } else {
        lmebParallel = lmebDefaultParallel
    }
    let lmebDumpJudgeInputsPath = optionValue("--dump-judge-inputs", in: args)
    var runConfig = LMEBRunConfig(
        mootBinaryPath: mootBinary,
        dataDir: dataDir,
        evidenceTypes: evidenceTypes,
        limit: limit,
        offset: offset,
        seed: seed,
        outDir: outDir,
        runLabel: runLabel,
        encodeBarrier: lmebEncodeBarrier,
        estateCache: lmebEstateCache,
        cacheDir: lmebCacheDir,
        scratchPosture: lmebScratchPosture,
        judgeCmd: lmebJudgeCmd,
        judgeGrading: lmebJudgeGrading,
        judgeHydrationDepth: lmebJudgeHydrationDepth,
        dumpJudgeInputsPath: lmebDumpJudgeInputsPath,
        seedPath: lmebSeedPath
    )
    // Instrument seams (environment-only; see RetrievalCallSpec.swift):
    // MOOT_BENCH_RETRIEVAL_TOOL/_ARGS override the query call;
    // MOOT_BENCH_UNIT_IDS pins the unit set.
    runConfig.retrievalCall = try retrievalCallSpecFromEnvironment()
    runConfig.unitIDs = try unitIDsFromEnvironment()
    // --payload-arm v0..v5 (PAYLOAD-ARMS; MOOT_BENCH_PAYLOAD_ARM as the
    // environment spelling): payload-economics shape variant applied to
    // seam-routed retrieval textBlocks. Recorded in run_environment.
    runConfig.payloadArm = try parsePayloadArm(
        optionValue("--payload-arm", in: args)
        ?? ProcessInfo.processInfo.environment["MOOT_BENCH_PAYLOAD_ARM"])
    runConfig.guardSamplingPolicy = lmebGuardSamplingPolicy
    runConfig.corpusDigest = lmebCorpusDigest
    // C1/C6: wire shape and parallel concurrency into the run config.
    runConfig.shape = lmebShape
    runConfig.parallelUnits = lmebParallel
    FileHandle.standardOutput.write(Data(
        "[lmeb] shape: \(lmebShape.rawValue)\n".utf8))
    FileHandle.standardOutput.write(Data(
        "[lmeb] parallel: \(lmebParallel)\n".utf8))

    // Sort queries by ID for deterministic shuffle baseline.
    let queries = corpus.queriesByID.values.sorted { $0.id < $1.id }

    let (results, lmebTimingReport) = try await runLMEBQueries(
        queries: queries, corpus: corpus, config: runConfig)

    // Score results (LMEBScorer.swift).
    let scores = results.map { scoreLMEBQuery($0) }

    // Build and write the report. Collect identity provenance once before building.
    // Pre-compute arm from the local evidenceTypes var (same value the report carries)
    // so the stamp goes on before report construction (testname-arm-serial discipline).
    let lmebArm = evidenceTypes.count >= 6
        ? "all6"
        : evidenceTypes.sorted().joined(separator: "+")
    let lmebSerial = resolveRunSerial(args)
    var lmebIdentity = IdentityEnvironment.collect(
        mootx01BinaryPath: mootBinary, payloadArm: runConfig.payloadArm)
    stampTestIdentity(&lmebIdentity, test: "lmeb", arm: lmebArm, serial: lmebSerial)
    let report = buildLMEBReport(
        runLabel: runConfig.runLabel,
        evidenceTypes: evidenceTypes,
        queriesLoaded: corpus.queryCount,
        results: results,
        scores: scores,
        encodeBarrier: runConfig.encodeBarrier.rawValue,
        guardSampling: lmebGuardSamplingPolicy.rawValue,
        estateCache: runConfig.estateCache.rawValue,
        estateEncryption: runConfig.scratchPosture.rawValue,
        shape: runConfig.shape.rawValue,
        parallelUnits: runConfig.parallelUnits,
        judgeCmd: runConfig.judgeCmd,
        judgeGrading: runConfig.judgeCmd != nil ? runConfig.judgeGrading : nil,
        identityEnvironment: lmebIdentity,
        timingReport: lmebTimingReport
    )
    // `<test>-<arm>-<serial>`: arm and serial were pre-computed above for the stamp;
    // reuse them so the filename and the embedded triple are always identical.
    let reportFilename = recordFilename(
        test: "lmeb", arm: lmebArm, serial: lmebSerial)
    let reportURL = (outDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent(reportFilename)
    try writeLMEBReport(report, to: reportURL)

    // Timing sidecar (--timing-sidecar, default off).
    // Written beside the accuracy report as <basename>.timing.json.
    // The accuracy report shape is UNCHANGED; timing never enters it.
    if flagPresent("--timing-sidecar", in: args) {
        // lmebSerial was resolved above for the stamp; reuse it here.
        let unitLatencies: [(id: String, latencySeconds: Double)] = results.map {
            ($0.queryID, $0.queryLatencySeconds)
        }
        let sidecar = makeTimingSidecar(
            lane: "lmeb",
            runID: lmebSerial,
            identity: lmebIdentity,
            unitLatencies: unitLatencies
        )
        try writeTimingSidecar(sidecar, beside: reportURL)
    }

    // Print summary to stdout.
    let guardHealthyCount = scores.filter(\.guardHealthy).count
    let guardRefusals = scores.count - guardHealthyCount
    let totalDocs = results.map(\.docsIngested).reduce(0, +)
    let (agg, lat) = aggregateLMEBScores(scores)

    let summary = """
        [lmeb] run complete
          queries processed: \(results.count)
          guard healthy:     \(guardHealthyCount)
          guard refusals:    \(guardRefusals)
          docs ingested:     \(totalDocs)
          nDCG@10:           \(String(format: "%.4f", agg.nDCGAt10))
          MRR:               \(String(format: "%.4f", agg.mrr))
          recall@1:          \(String(format: "%.4f", agg.recallAt1))
          recall@5:          \(String(format: "%.4f", agg.recallAt5))
          recall@10:         \(String(format: "%.4f", agg.recallAt10))
          MAP@10:            \(String(format: "%.4f", agg.mapAt10))
          query p50:         \(String(format: "%.1f", lat.queryP50Seconds * 1000)) ms
          query p95:         \(String(format: "%.1f", lat.queryP95Seconds * 1000)) ms
          report written to: \(reportURL.path)

        """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// membench-spec subcommand — official MemBench protocol
/// (MEMBENCH_OFFICIAL_PROTOCOL.md §2–§6).
///
/// Same MemData corpus as the `membench` lane, but implements the documented
/// protocol: §2 step-prefixed storage lines, §3 answering-model letter choice
/// (BYOAI --answer-cmd or offline dump/consume; NO letter-scan heuristic),
/// §4 get_recall over step ids, §5 store/recall wall-clock timers, and the §6
/// step_cap capacity walk (--capacity, cl100k token axis).
/// Record naming: membench-spec-<agent>-<serial>.json + params sidecar.
func runMemBenchSpec(_ args: [String]) async throws {
    guard let dataDirStr = optionValue("--data-dir", in: args) else {
        throw MCPError(description: "missing required option --data-dir")
    }
    let specDataDir = URL(fileURLWithPath: dataDirStr)
    guard FileManager.default.fileExists(atPath: specDataDir.path) else {
        throw MCPError(description:
            "MemBench data directory not found at \(specDataDir.path). "
            + "Run scripts/fetch-membench.sh to download the dataset.")
    }

    // --agent FirstAgent|ThirdAgent (default FirstAgent, matching the parent lane).
    let specAgent = optionValue("--agent", in: args) ?? "FirstAgent"
    guard specAgent == "FirstAgent" || specAgent == "ThirdAgent" else {
        throw MCPError(description:
            "--agent must be 'FirstAgent' or 'ThirdAgent'; got '\(specAgent)'")
    }

    // --category <name>[,<name>…]: optional category filter, parent-lane spelling.
    let specCategories = optionValue("--category", in: args)
        .map { $0.split(separator: ",").map(String.init) }

    // mootx01 binary: --mootx01-binary is the Swift-native spelling; --binary is
    // the Rust twin's name. Both accepted for CLI contract parity.
    let specMootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        specMootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        specMootBinary = discovered
        FileHandle.standardError.write(Data(
            "[membench-spec] auto-discovered mootx01 at: \(specMootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: specMootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(specMootBinary)'.")
    }

    let specLimit = try parseLimitOption(in: args)
    let specOffset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    // Seed default 20260818 — the spec lanes' shared default, distinct from the
    // legacy lanes' 20260725 so record filenames never collide across lanes.
    let specSeed = optionValue("--seed", in: args).flatMap(UInt64.init) ?? 20_260_818

    let specOutDir = try resolvedOutputDirectory(in: args)

    // --encode-barrier drain|impatient|none (default: drain). Used ONLY in step_cap mode.
    // Standard mode opens pre-built artifact estates and has no encode phase.
    // Step_cap overrides this to impatient inside the runner (§6).
    let specEncodeBarrierStr = optionValue("--encode-barrier", in: args) ?? "drain"
    let specEncodeBarrier: EncodeBarrier
    switch specEncodeBarrierStr {
    case "drain":     specEncodeBarrier = .drain
    case "impatient": specEncodeBarrier = .impatient
    case "none":      specEncodeBarrier = .none
    default:
        throw MCPError(description:
            "--encode-barrier must be 'drain', 'impatient', or 'none'; got '\(specEncodeBarrierStr)'")
    }

    let specScratchPosture = try parseEstateMode(in: args)
    // Accuracy lanes never test encryption; that is the timing lane's mandate.
    if specScratchPosture == .encryptedEphemeral {
        throw MCPError(description: "encryption is tested only by the timing lane")
    }

    // --shape disk|ram (default: disk). Used ONLY in step_cap mode.
    let specShapeStr = optionValue("--shape", in: args) ?? "disk"
    let specShape: BenchShape
    switch specShapeStr {
    case "disk": specShape = .disk
    case "ram":  specShape = .ram
    default:
        throw MCPError(description: "--shape must be 'disk' or 'ram'; got '\(specShapeStr)'")
    }

    // --target-scale, --catalog, --estate-dir: artifact estate seam (standard mode).
    let specTargetScale = try parseArtifactTargetScale(in: args)
    let specCatalogPath = optionValue("--catalog",    in: args).map { URL(fileURLWithPath: $0) }
    let specEstateDir   = optionValue("--estate-dir", in: args).map { URL(fileURLWithPath: $0) }

    // §3 answering seam (BYOAI). --answer-cmd may carry API keys: never printed,
    // never recorded (the params sidecar stores boolean presence only).
    let specAnswerCmd = ProcessInfo.processInfo.environment["MOOT_BENCH_ANSWER_CMD"]
        ?? optionValue("--answer-cmd", in: args)
    let specDumpPath = optionValue("--dump-answer-inputs", in: args)
        .map { URL(fileURLWithPath: $0) }
    let specConsumePath = optionValue("--consume-answers", in: args)
        .map { URL(fileURLWithPath: $0) }

    // --run-mode-spec standard|capacity selects §3–§5 vs the §6 step_cap walk.
    // (--run-mode is the §6-report machine-state field quiet|contended, so the
    // mode flag takes a distinct name.)
    let specModeStr = optionValue("--capacity", in: args)
    let specRunMode: MemBenchSpecRunMode = (specModeStr != nil) ? .stepCap : .standard

    // §6 bucket boundaries. Default [1000, 5000, 20000] = the paper's tier sizes.
    let specBuckets: [Int]
    if let bucketsStr = specModeStr, !bucketsStr.isEmpty, bucketsStr != "default" {
        specBuckets = bucketsStr.split(separator: ",").compactMap { Int($0) }
        guard !specBuckets.isEmpty else {
            throw MCPError(description:
                "--capacity expects 'default' or comma-separated token boundaries; got '\(bucketsStr)'")
        }
    } else {
        specBuckets = [1000, 5000, 20000]
    }

    let specSerial = resolveRunSerial(args)

    FileHandle.standardError.write(Data(
        "[membench-spec] loading corpus from \(specDataDir.path) agent=\(specAgent)\n".utf8))
    let specCorpus = try loadMemBenchCorpus(
        dataDir: specDataDir,
        agent: specAgent,
        categories: specCategories,
        limit: nil)  // limit applies after the seeded shuffle, inside the runner
    let specModeLabel = specRunMode == .stepCap ? "step_cap (§6)" : "standard (§3–§5)"
    let specAnswerLabel = specAnswerCmd != nil ? "inline"
        : (specConsumePath != nil ? "consume" : "none")
    let specLoadedLine = "[membench-spec] loaded \(specCorpus.items.count) items; "
        + "mode=\(specModeLabel) answer=\(specAnswerLabel)\n"
    FileHandle.standardError.write(Data(specLoadedLine.utf8))

    var specConfig = MemBenchSpecRunConfig(
        mootBinaryPath: specMootBinary,
        dataDir: specDataDir,
        agent: specAgent,
        categories: specCategories,
        limit: specLimit,
        offset: specOffset,
        seed: specSeed,
        outDir: specOutDir,
        runLabel: "membench-spec-\(specAgent)-seed\(specSeed)",
        runSerial: specSerial,
        encodeBarrier: specEncodeBarrier,
        scratchPosture: specScratchPosture,
        shape: specShape,
        answerCmd: specAnswerCmd,
        dumpAnswerInputsPath: specDumpPath,
        consumeAnswersPath: specConsumePath,
        runMode: specRunMode,
        capacityBucketBoundaries: specBuckets)
    // Artifact estate seam (standard mode).
    specConfig.targetScale   = specTargetScale
    specConfig.catalogPath   = specCatalogPath
    specConfig.estateDir     = specEstateDir

    // §6 required report fields (F1): machine + binary provenance, collected
    // at the CLI layer exactly as every legacy lane does.
    // Stamped with testname-arm-serial so the emitted record is self-identifying (D1 fix).
    specConfig.runEnvironment = IdentityEnvironment.collect(
        mootx01BinaryPath: specMootBinary)
    stampTestIdentity(&specConfig.runEnvironment,
                      test: "membench-spec",
                      arm: specAgent,
                      serial: specSerial)
    // Instrument seam: MOOT_BENCH_UNIT_IDS pins the unit set for the spec lane.
    let membenchSpecUnitIDsPath = ProcessInfo.processInfo.environment["MOOT_BENCH_UNIT_IDS"]
    specConfig.unitIDs = try membenchSpecUnitIDsPath.map { try loadUnitIDs($0) }
    specConfig.unitIDsPath = membenchSpecUnitIDsPath
    // --scoring raw|rrf|matrixAware|discriminative: when given, passed as the
    // "scoring" key in every moot_memory_search call. When omitted, the call is
    // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
    specConfig.scoringStrategy = optionValue("--scoring", in: args)
    // --seed-units-dir <path>: enables lineage-based id-map derivation as the
    // third fallback when id-map.json is absent and sourceFile reconstruction
    // yields no rows. The unit file is <seed-units-dir>/<estateName>.json.
    specConfig.seedUnitsDir = optionValue("--seed-units-dir", in: args)
        .map { URL(fileURLWithPath: $0) }
    // --guard-sample once|per-unit (default once).
    // per-unit probes on every query; useful for aggregate-estate debugging where
    // the daemon may return different results across queries within one run.
    specConfig.guardSamplingPolicy = try GuardSamplingPolicy.parse(
        optionValue("--guard-sample", in: args))

    // The runner writes the report + params sidecar itself
    // (membench-spec-<agent>-<serial>.json via recordFilename).
    let (outcomes, report) = try await runMemBenchSpec(items: specCorpus.items, config: specConfig)

    let answered = outcomes.filter { $0.answeredCorrect != nil }.count
    let correct  = outcomes.filter { $0.answeredCorrect == true }.count
    let summary = """

        [membench-spec] run complete
          items processed:  \(outcomes.count)
          answered_count:   \(answered)\(answered > 0 ? String(format: "  accuracy: %.4f", Double(correct) / Double(answered)) : "")
          run label:        \(report.runLabel)

        """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

// MARK: - lmeb-spec / convomem-spec shared CLI plumbing

/// Parses the flag surface shared by the lmeb-spec and convomem-spec
/// subcommands and loads the corpus. Both lanes read the same ConvoMem data
/// directory and evidence-type selection as the parent `lmeb` lane; they
/// differ only in which runner consumes the spec queries.
///
/// Returns the loaded corpus, the flat spec-query list (sorted by namespaced
/// id for deterministic pre-shuffle order — `queriesByID` is a dictionary and
/// its iteration order would otherwise vary run to run), and the config.
private func parseLMEBSpecInvocation(
    _ args: [String], laneTag: String
) throws -> (corpus: LMEBCorpus, specQueries: [LMEBSpecQuery], config: LMEBSpecRunConfig) {
    guard let dataDirStr = optionValue("--data-dir", in: args) else {
        throw MCPError(description: "missing required option --data-dir")
    }
    let dataDir = URL(fileURLWithPath: dataDirStr)
    guard FileManager.default.fileExists(atPath: dataDir.path) else {
        throw MCPError(description:
            "LMEB data directory not found at \(dataDir.path). "
            + "Run scripts/fetch-lmeb.sh to download the dataset.")
    }

    // --evidence-types ET1,ET2,… (default: all six ConvoMem subsets, matching
    // the parent lane and the method doc's whole-set discipline (§9 in v0.4)).
    let allEvidenceTypes = [
        "abstention_evidence", "assistant_facts_evidence", "changing_evidence",
        "implicit_connection_evidence", "preference_evidence", "user_evidence",
    ]
    let evidenceTypes = optionValue("--evidence-types", in: args)
        .map { $0.split(separator: ",").map(String.init) } ?? allEvidenceTypes

    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[\(laneTag)] auto-discovered mootx01 at: \(discovered)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }

    let limit = try parseLimitOption(in: args)
    let offset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    // Seed default 20260818 — the spec lanes' shared default, distinct from the
    // legacy lanes' 20260725 so record filenames never collide across lanes.
    let seed = optionValue("--seed", in: args).flatMap(UInt64.init) ?? 20_260_818
    let outDir = try resolvedOutputDirectory(in: args)

    // --target-scale unit|bench-aggregate|complete-aggregate (default: unit).
    let targetScale = try parseArtifactTargetScale(in: args)
    // --catalog: catalog.json path for the dataset (unit scale).
    let catalogPath = optionValue("--catalog", in: args).map { URL(fileURLWithPath: $0) }
    // --estate-dir: single shared estate (bench-aggregate / complete-aggregate).
    let estateDir = optionValue("--estate-dir", in: args).map { URL(fileURLWithPath: $0) }

    FileHandle.standardError.write(Data(
        "[\(laneTag)] loading corpus from \(dataDir.path) (\(evidenceTypes.count) evidence types)\n".utf8))
    let corpus = try loadLMEBCorpus(baseDir: dataDir, evidenceTypes: evidenceTypes)
    let specCorpusDigest = lmebCorpusDigest(baseDir: dataDir, evidenceTypes: evidenceTypes)

    // Spec queries: one per corpus query, evidence type recovered from the
    // namespaced id ("{evidenceType}__{rawID}", the loader's collision guard).
    // Sorted by id so the runner's seeded shuffle starts from a fixed order.
    let specQueries: [LMEBSpecQuery] = corpus.queriesByID
        .sorted { $0.key < $1.key }
        .map { (id, query) in
            // Namespaced id shape is "{evidenceType}__{rawID}" (the loader's
            // cross-category collision guard); the prefix is the subset name.
            let evidenceType = id.components(separatedBy: "__").first ?? "unknown"
            return LMEBSpecQuery(query: query, evidenceType: evidenceType)
        }

    var config = LMEBSpecRunConfig(
        mootBinaryPath: mootBinary,
        dataDir: dataDir,
        evidenceTypes: evidenceTypes,
        limit: limit,
        offset: offset,
        seed: seed,
        outDir: outDir,
        runLabel: "\(laneTag)-seed\(seed)")
    config.targetScale  = targetScale
    config.catalogPath  = catalogPath
    config.estateDir    = estateDir
    config.corpusDigest = specCorpusDigest
    // Instrument seams (environment-only; see RetrievalCallSpec.swift):
    // MOOT_BENCH_UNIT_IDS pins the unit set for the spec lane without touching
    // the corpus load (corpus_digest unchanged) or the limit/offset machinery.
    let lmebSpecUnitIDsPath = ProcessInfo.processInfo.environment["MOOT_BENCH_UNIT_IDS"]
    config.unitIDs = try lmebSpecUnitIDsPath.map { try loadUnitIDs($0) }
    config.unitIDsPath = lmebSpecUnitIDsPath

    // --parallel N: bounded query concurrency (default 1). Parallel and serial
    // runs produce the same accuracy figures (method §8.1).
    if let par = optionValue("--parallel", in: args).flatMap(Int.init) {
        guard par >= 1 else {
            throw MCPError(description: "--parallel must be >= 1; got \(par)")
        }
        config.parallelUnits = par
    }

    // §A4: --instruction-setting without|with (default: without — the canonical
    // zero-instruction baseline; both settings produce published LMEB numbers).
    let instructionStr = optionValue("--instruction-setting", in: args) ?? "without"
    switch instructionStr {
    case "without": config.instructionSetting = .withoutInstruction
    case "with":    config.instructionSetting = .withInstruction
    default:
        throw MCPError(description:
            "--instruction-setting must be 'without' or 'with'; got '\(instructionStr)'")
    }

    // Guard probe sampling policy (parity: the Rust twin reads the same
    // flag; default .oncePerLeg).
    config.guardSamplingPolicy = try GuardSamplingPolicy.parse(
        optionValue("--guard-sample", in: args))

    // --scoring raw|rrf|matrixAware|discriminative: when given, passed as
    // the "scoring" key in every moot_memory_search call. When omitted, the
    // call is byte-identical to the pre-flag baseline.
    config.scoringStrategy = optionValue("--scoring", in: args)

    // --recall-shape <preset>: when given, the per-query call switches to
    // moot_recall_shaped with this preset. The server validates the preset
    // against its roster; the client passes it through unvalidated.
    // Mutually exclusive with --scoring: moot_recall_shaped runs matrixAware
    // internally and does not accept a "scoring" key. Fail fast here, before
    // any estate is opened, so the error is immediate and unambiguous.
    let recallShapeValue = optionValue("--recall-shape", in: args)
    if config.scoringStrategy != nil && recallShapeValue != nil {
        throw MCPError(description:
            "--scoring and --recall-shape are mutually exclusive: "
            + "moot_recall_shaped always runs matrixAware and does not accept a scoring key")
    }
    config.recallShape = recallShapeValue

    // --request-limit N: per-question verb result cap (default 20 = current behaviour).
    // Always sent explicitly in the query so the value is recorded and auditable.
    if let rl = optionValue("--request-limit", in: args).flatMap(Int.init) {
        guard rl >= 1 else {
            throw MCPError(description: "--request-limit must be >= 1; got \(rl)")
        }
        config.requestLimit = rl
    }

    // --pool-metrics: when present, sends explain:true in recall calls and reads pool
    // structure from the explain payload. Default off — omitting this flag keeps
    // default runs byte-identical to the pre-flag baseline.
    if args.contains("--pool-metrics") {
        config.poolMetricsMode = 1
    }

    // --short-query-terms N: content-term threshold for the short-query gate (default 4).
    // A query with content_term_count < N is counted in the short-query subset.
    if let sqt = optionValue("--short-query-terms", in: args).flatMap(Int.init) {
        guard sqt >= 1 else {
            throw MCPError(description: "--short-query-terms must be >= 1; got \(sqt)")
        }
        config.shortQueryTerms = sqt
    }

    return (corpus, specQueries, config)
}

/// Encodes a `RunEnvironment` as a JSON-object value suitable for insertion
/// into a `[String: Any]` report under the "run_environment" key.
/// Used only by the timing lane, which retains the full machine profile.
func runEnvironmentJSONObject(_ env: RunEnvironment) throws -> Any {
    let data = try JSONEncoder().encode(env)
    return try JSONSerialization.jsonObject(with: data)
}

/// Encodes an `IdentityEnvironment` as a JSON-object value suitable for
/// insertion into a `[String: Any]` report under the "run_environment" key.
/// Accuracy lanes emit only binary provenance (sha256, version, protocol);
/// timing fields are absent by design (2026-08-18 doctrine).
func identityEnvironmentJSONObject(_ env: IdentityEnvironment) throws -> Any {
    let data = try JSONEncoder().encode(env)
    return try JSONSerialization.jsonObject(with: data)
}

/// Serialises a per-k metric grid as {"<name>_at_<k>": value} JSON keys.
/// Optional values (R_cap's §A3 None-propagation) serialise as NSNull.
private func lmebSpecGridJSON(_ name: String, _ grid: [Int: Double]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in grid { out["\(name)_at_\(k)"] = v }
    return out
}
private func lmebSpecGridJSON(_ name: String, _ grid: [Int: Double?]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in grid { out["\(name)_at_\(k)"] = v ?? NSNull() }
    return out
}

/// lmeb-spec subcommand — official LMEB retrieval protocol
/// (LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md §A1–§A4).
///
/// Full metric grid at k∈{1,5,10,25,50} with capped recall and two-level
/// aggregation; --instruction-setting selects the §A4 setting.
/// Record naming: lmeb-spec-<arm>-<serial>.json + params sidecar.
func runLMEBSpec(_ args: [String]) async throws {
    let (corpus, specQueries, config) = try parseLMEBSpecInvocation(args, laneTag: "lmeb-spec")
    let serial = resolveRunSerial(args)

    let results = try await runLMEBSpecQueries(
        specQueries: specQueries, corpus: corpus, config: config)

    // Arm mirrors the parent lane (all6 for the full evidence set, else
    // joined names) suffixed with the §A4 instruction setting: the two
    // settings are distinct arms of one pass and each record carries its
    // own name (records are never overwritten).
    let evidenceArm = config.evidenceTypes.count == 6 ? "all6"
        : config.evidenceTypes.joined(separator: "+")
    let arm = "\(evidenceArm)-"
        + (config.instructionSetting == .withInstruction ? "with" : "without")

    // Stamp identity before building the report dict (testname-arm-serial discipline).
    var lmebSpecIdentity = IdentityEnvironment.collect(mootx01BinaryPath: config.mootBinaryPath)
    stampTestIdentity(&lmebSpecIdentity, test: "lmeb-spec", arm: arm, serial: serial)

    var subsetsJSON: [[String: Any]] = []
    for s in results.subsetMetrics {
        var obj: [String: Any] = [
            // evidence_type: alias for subset, read by ev-table.py per the scoreboard spec.
            "evidence_type": s.subsetName,
            "subset": s.subsetName,
            "query_count": s.queryCount,
        ]
        obj.merge(lmebSpecGridJSON("ndcg", s.ndcg)) { a, _ in a }
        obj.merge(lmebSpecGridJSON("map", s.map)) { a, _ in a }
        obj.merge(lmebSpecGridJSON("recall", s.recall)) { a, _ in a }
        obj.merge(lmebSpecGridJSON("precision", s.precision)) { a, _ in a }
        obj.merge(lmebSpecGridJSON("mrr", s.mrr)) { a, _ in a }
        obj.merge(lmebSpecGridJSON("r_cap", s.rCap)) { a, _ in a }
        subsetsJSON.append(obj)
    }
    var taskJSON: [String: Any] = ["subset_count": results.taskMetrics.subsetCount]
    taskJSON.merge(lmebSpecGridJSON("ndcg", results.taskMetrics.ndcg)) { a, _ in a }
    taskJSON.merge(lmebSpecGridJSON("map", results.taskMetrics.map)) { a, _ in a }
    taskJSON.merge(lmebSpecGridJSON("recall", results.taskMetrics.recall)) { a, _ in a }
    taskJSON.merge(lmebSpecGridJSON("precision", results.taskMetrics.precision)) { a, _ in a }
    taskJSON.merge(lmebSpecGridJSON("mrr", results.taskMetrics.mrr)) { a, _ in a }
    taskJSON.merge(lmebSpecGridJSON("r_cap", results.taskMetrics.rCap)) { a, _ in a }
    // Pool guarantee and short-query metrics (§3 / §7.5):
    // pool_guarantee: share of questions with ≥1 gold doc in the returned list.
    // short_query_count: questions with content_term_count < request_limit threshold.
    taskJSON["pool_guarantee"]            = results.taskMetrics.poolGuarantee
    taskJSON["pool_gold_recall"]          = results.taskMetrics.poolGoldRecall
    taskJSON["short_query_count"]         = results.taskMetrics.shortQueryCount
    taskJSON["short_query_ndcg_at_10"]    = results.taskMetrics.shortQueryNdcgAt10
    taskJSON["short_query_recall_at_10"]  = results.taskMetrics.shortQueryRecallAt10
    taskJSON["short_query_pool_guarantee"] = results.taskMetrics.shortQueryPoolGuarantee

    // Per-question records: one entry per query with the fields listed in the brief.
    // Sorted by query_id for deterministic output.
    let perQuestionRecords: [[String: Any]] = results.perQueryResults
        .sorted { $0.queryID < $1.queryID }
        .map { r in
            [
                "query_id":          r.queryID,
                "evidence_type":     r.evidenceType,
                "content_term_count": r.contentTermCount,
                "returned_count":    r.retrievedDocIDs.count,
                "gold_doc_ids":      Array(r.relevantDocIDs),
                "gold_ranks":        r.goldRanks,
                "pool_size":         r.poolSize,
                "pool_gold_hit":     r.poolGoldHit,
                "pool_provenance":   r.poolProvenance,
                "latency_seconds":   r.queryLatencySeconds,
            ] as [String: Any]
        }

    let report: [String: Any] = [
        "benchmark": "lmeb-spec",
        "run_label": config.runLabel,
        "port": "swift",
        "target_scale": config.targetScale.rawValue,
        "estate_mode": config.targetScale == .unit
            ? "artifact-unit" : "artifact-aggregate",
        "seed": config.seed,
        "arm": arm,
        "serial": serial,
        "evidence_types": config.evidenceTypes,
        // §A4 setting is methodology-defining: recorded on every report.
        "instruction_setting": config.instructionSetting == .withInstruction
            ? "with" : "without",
        "skip_first_result": config.specOptions.skipFirstResult,
        "ignore_identical_ids": config.specOptions.ignoreIdenticalIds,
        "total_queries": results.totalQueries,
        "guard_excluded_count": results.guardExcludedCount,
        // Unit-ID filter identity: present when MOOT_BENCH_UNIT_IDS was set,
        // absent on a full-corpus run. Enables subset/full-corpus disambiguation
        // in the register (testname-arm-serial discipline).
        "unit_ids_path": config.unitIDsPath as Any,
        "selected_count": results.totalQueries,
        // Scoring strategy: "default" when --scoring was omitted, the literal
        // value otherwise. Enables arm comparisons where scoring is the variable.
        "scoring": config.scoringStrategy ?? "default",
        // Recall shape preset: "none" when --recall-shape was absent (moot_memory_search
        // baseline), the literal preset name otherwise. Enables arm comparisons where
        // the recall shape is the variable.
        "recall_shape": config.recallShape ?? "none",
        // Per-question verb limit (default 20): always recorded so each report is
        // self-describing and arm comparisons are unambiguous.
        "request_limit": config.requestLimit,
        // Pool-metrics switch and short-query gate, recorded so the report is self-describing;
        // key for key with the Rust lmeb-spec report.
        "pool_metrics_enabled": config.poolMetricsMode != 0,
        "short_query_terms": config.shortQueryTerms,
        "task_metrics": taskJSON,
        "subset_metrics": subsetsJSON,
        "per_question_records": perQuestionRecords,
        // §6 required report fields (F1).
        "run_environment": try identityEnvironmentJSONObject(lmebSpecIdentity),
    ] as [String: Any]
    let reportData = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let reportFilename = recordFilename(test: "lmeb-spec", arm: arm, serial: serial)
    let reportURL = (config.outDir
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent(reportFilename)
    try writeRecordNeverOverwrite(reportData, to: reportURL)

    let headline = results.taskMetrics.ndcgAt10
    let summary = """

        [lmeb-spec] run complete
          queries processed: \(results.totalQueries)
          task ndcg_at_10:   \(String(format: "%.5f", headline))
          report written to: \(reportURL.path)

        """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// convomem-spec subcommand — official ConvoMem judged-QA protocol
/// (LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md §B1–§B4).
///
/// Answers via the §B1 memory-based prompt through --answer-cmd (BYOAI) and
/// judges via the §B2 templates + §B3 verdict rule through --judge-cmd; both
/// have offline dump paths. With neither attached the run records
/// answered_count/judged_count 0 — the mechanism is complete either way.
/// Record naming: convomem-spec-<arm>-<serial>.json.
func runConvoMemSpec(_ args: [String]) async throws {
    var (corpus, specQueries, config) =
        try parseLMEBSpecInvocation(args, laneTag: "convomem-spec")
    let serial = resolveRunSerial(args)

    // §B1/§B2 seams. Env vars preferred over flags (flag values appear in `ps`
    // argv). Commands may carry API keys: never printed, never recorded.
    config.answerCmd = ProcessInfo.processInfo.environment["MOOT_BENCH_ANSWER_CMD"]
        ?? optionValue("--answer-cmd", in: args)
    config.judgeCmd = ProcessInfo.processInfo.environment["MOOT_BENCH_JUDGE_CMD"]
        ?? optionValue("--judge-cmd", in: args)
    config.judgeIdentity = optionValue("--judge-model", in: args) ?? "unknown"
    if let depth = optionValue("--judge-hydration-depth", in: args).flatMap(Int.init) {
        config.answerHydrationDepth = depth
    }
    config.dumpAnswerInputsPath = optionValue("--dump-answer-inputs", in: args)
    config.dumpJudgeInputsPath = optionValue("--dump-judge-inputs", in: args)
    if let tierStr = optionValue("--hydration-tier", in: args) {
        guard let tier = HydrationDepth(rawValue: tierStr) else {
            throw MCPError(description:
                "convomem-spec --hydration-tier must be distilled or full; got '\(tierStr)'")
        }
        config.answerHydrationTier = tier
    }

    let arm = config.evidenceTypes.count == 6 ? "all6"
        : config.evidenceTypes.joined(separator: "+")

    // §B2 offline consume: the answers were produced by `answer-batch` from an
    // answer-input dump (judge_ready lines: query_id, question, correct_answer,
    // model_answer, evidence_type). No estate is opened and no answer command
    // runs; each line is judged with the same §B2 prompt the inline path
    // builds, through --judge-cmd, and the §B4 aggregate is written as the
    // record. This is the offline twin of membench-spec --consume-answers.
    if let consumePath = optionValue("--consume-answers", in: args) {
        guard let judgeCmd = config.judgeCmd else {
            throw MCPError(description:
                "convomem-spec --consume-answers requires --judge-cmd (or MOOT_BENCH_JUDGE_CMD)")
        }
        let agg = try runConvoMemSpecJudgeDump(inputsPath: consumePath, judgeCmd: judgeCmd)
        // Stamp before building the report dict (testname-arm-serial discipline).
        var convoMemConsumeIdentity = IdentityEnvironment.collect(
            mootx01BinaryPath: config.mootBinaryPath)
        stampTestIdentity(&convoMemConsumeIdentity,
                          test: "convomem-spec",
                          arm: arm,
                          serial: serial)
        var report: [String: Any] = [
            "benchmark": "convomem-spec",
            "run_label": config.runLabel,
            "port": "swift",
            "target_scale": config.targetScale.rawValue,
            "estate_mode": "consumed-answers",
            "seed": config.seed,
            "arm": arm,
            "serial": serial,
            "evidence_types": config.evidenceTypes,
            "consumed_answers_path": consumePath,
            // §B4: judge identity recorded; command text never recorded (secrecy).
            "judge_identity": config.judgeIdentity,
            "judge_cmd_set": true,
            "run_environment": try identityEnvironmentJSONObject(convoMemConsumeIdentity),
        ]
        report.merge(convoMemAggregateReportFields(agg)) { _, new in new }
        let reportData = try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportFilename = recordFilename(test: "convomem-spec", arm: arm, serial: serial)
        let reportURL = (config.outDir
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent(reportFilename)
        try writeRecordNeverOverwrite(reportData, to: reportURL)
        let summary = """

            [convomem-spec] consume complete
              scored_count:     \(agg.overallScoredCount)
              correct_count:    \(agg.overallCorrectCount)
              unscored_count:   \(agg.overallUnscoredCount)
              overall_accuracy: \(agg.overallAccuracy)
              report written to: \(reportURL.path)

            """
        FileHandle.standardOutput.write(Data(summary.utf8))
        return
    }

    let results = try await runConvoMemSpecQueries(
        specQueries: specQueries, corpus: corpus, config: config)

    // Stamp before building the report dict (testname-arm-serial discipline).
    var convoMemLiveIdentity = IdentityEnvironment.collect(
        mootx01BinaryPath: config.mootBinaryPath)
    stampTestIdentity(&convoMemLiveIdentity,
                      test: "convomem-spec",
                      arm: arm,
                      serial: serial)

    var report: [String: Any] = [
        "benchmark": "convomem-spec",
        "run_label": config.runLabel,
        "port": "swift",
        "target_scale": config.targetScale.rawValue,
        "estate_mode": config.targetScale == .unit
            ? "artifact-unit" : "artifact-aggregate",
        "seed": config.seed,
        "arm": arm,
        "serial": serial,
        "evidence_types": config.evidenceTypes,
        "total_queries": results.totalQueries,
        "answered_count": results.answeredCount,
        "judged_count": results.judgedCount,
        "guard_excluded_count": results.guardExcludedCount,
        // §B4: judge identity recorded; command text never recorded (secrecy).
        "judge_identity": results.judgeIdentity,
        "answer_cmd_set": results.answerCmdSet,
        "judge_cmd_set": results.judgeCmdSet,
        "memory_texts_empty_count": results.memoryTextsEmptyCount,
        // §6 required report fields (F1).
        "run_environment": try identityEnvironmentJSONObject(convoMemLiveIdentity),
    ]
    if let agg = results.aggregateResult {
        report.merge(convoMemAggregateReportFields(agg)) { _, new in new }
    }
    // ── Broken-hydration gate ─────────────────────────────────────────────────
    // A run where every query's answer input would carry zero memory texts
    // indicates that estate hydration failed across the board (id-space mismatch,
    // missing fleet, estate unreachable). This is not "complete" — exit non-zero
    // naming the first query so the operator can diagnose without inspecting the
    // dump file.
    if results.totalQueries > 0,
       results.memoryTextsEmptyCount == results.totalQueries,
       let firstEmpty = results.perQueryResults.first(where: { $0.retrievedMemoryTexts.isEmpty }) {
        let errMsg = "[convomem-spec] ERROR: all \(results.totalQueries) queries produced"
            + " empty memory_texts; first affected query: \(firstEmpty.queryID)."
            + " Estate hydration failed (check --catalog and id-map.json).\n"
        FileHandle.standardError.write(Data(errMsg.utf8))
        exit(1)
    }

    let reportData = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let reportFilename = recordFilename(test: "convomem-spec", arm: arm, serial: serial)
    let reportURL = (config.outDir
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent(reportFilename)
    try writeRecordNeverOverwrite(reportData, to: reportURL)

    let summary = """

        [convomem-spec] run complete
          queries processed:       \(results.totalQueries)
          answered_count:          \(results.answeredCount)
          judged_count:            \(results.judgedCount)
          memory_texts_empty_count: \(results.memoryTextsEmptyCount)
          report written to:       \(reportURL.path)

        """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// §B4 report fields for a ConvoMem aggregate: accuracy per evidence type,
/// per evidence count, and overall, with counts alongside every mean and
/// unscored counted separately. Shared by the inline run and the
/// --consume-answers path so both records carry the same keys.
func convoMemAggregateReportFields(_ agg: ConvoMemAggregateResult) -> [String: Any] {
    var fields: [String: Any] = [:]
    fields["accuracy_by_evidence_type"] = agg.perType.map { row in
        ["evidence_type": row.evidenceType, "accuracy": row.accuracy,
         "correct_count": row.correctCount, "scored_count": row.scoredCount,
         "unscored_count": row.unscoredCount] as [String: Any]
    }
    fields["accuracy_by_evidence_count"] = agg.perCount.map { row in
        ["evidence_count": row.evidenceCount, "accuracy": row.accuracy,
         "correct_count": row.correctCount, "scored_count": row.scoredCount,
         "unscored_count": row.unscoredCount] as [String: Any]
    }
    fields["overall_accuracy"] = agg.overallAccuracy
    fields["overall_correct_count"] = agg.overallCorrectCount
    fields["overall_scored_count"] = agg.overallScoredCount
    fields["overall_unscored_count"] = agg.overallUnscoredCount
    return fields
}

/// Dispatches one subcommand.
func dispatch(_ arguments: [String]) async throws {
    guard let subcommand = arguments.first else {
        FileHandle.standardOutput.write(Data(usageText().utf8))
        exit(2)
    }
    let rest = Array(arguments.dropFirst())
    // `<subcommand> --help` prints usage rather than tripping the unknown-option
    // check: the operator asking what a subcommand takes is exactly the person
    // the strict-option policy is for.
    if rest.contains("--help") || rest.contains("-h") {
        FileHandle.standardOutput.write(Data(usageText().utf8))
        return
    }
    // Retired and unrecognised options fail here, before any run starts. See
    // validateOptions for why silence was the defect.
    try validateOptions(subcommand: subcommand, in: rest)
    // No-encoder guard: hoist before any subprocess is spawned. A mislabeled
    // run (product-default arm recorded as no-encoder) is the defect; catching
    // it here rather than inside collect() avoids even starting serve/probe.
    // Skip for read-only and help subcommands that never spawn a process.
    if !isDispatchExemptFromNoEncoderGuard(subcommand), let msg = noEncoderActivationSeamMessage() {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        exit(1)
    }
    switch subcommand {
    case "benchmark":      try await runBenchmark(rest)
    case "gauntlet-corpus": try runGauntletCorpus(rest)
    case "gauntlet":       try await runGauntlet(rest)
    case "longmemeval":    try await runLongMemEval(rest)
    case "lme-spec":       try await runLMESpec(rest)
    case "lme-agentic":    try await runLMEAgenticCommand(rest)
    case "lmeb":           try await runLMEB(rest)
    case "lmeb-spec":      try await runLMEBSpec(rest)
    case "convomem-spec":  try await runConvoMemSpec(rest)
    case "supersession":   try await runSupersession(rest)
    case "replay":         try await runReplay(rest)
    case "locomo":         try await runLoCoMo(rest)
    case "locomo-spec":    try await runLoCoMoSpec(rest)
    case "artifact-recall": try await runArtifactRecall(rest)
    case "payload-economics": try await runPayloadEconomics(rest)
    case "membench":       try await runMemBench(rest)
    case "membench-spec":  try await runMemBenchSpec(rest)
    case "timing":         try await runTiming(rest)
    case "landscape-build": try await runLandscapeBuild(rest)
    case "refresh":        try await runRefresh(rest)
    case "matrix":         try await runMatrix(rest)
    case "convert":        try await runConvert(rest)
    case "journey":        try await runJourney(rest)
    case "report":         try runReport(rest)
    case "capturespread-corpus": try runCaptureSpreadCorpus(rest)
    case "capturespread":        try await runCaptureSpread(rest)
    case "throughput":           try await runThroughput(rest)
    case "answer-batch":    try runAnswerBatch(rest)
    case "apple-answer":    try await runAppleAnswer(rest)
    case "judge-batch":
        // Legacy judge-batch is dark (ruling 2026-08-18): its grading is the
        // legacy substring/verdict path, not an official protocol. The spec
        // lanes carry their own batch consumption (lme-spec judge dumps,
        // convomem-spec answer/judge dumps + the spec lanes' batch consumption).
        // Code retained; activation disabled pending a removal ruling.
        throw MCPError(description:
            "judge-batch is dark (legacy non-deterministic path; ruling "
            + "2026-08-18). Use the spec lanes' dump/consume seams with "
            + "the judge-batch subcommand instead.")
    case "--help", "-h", "help":
        FileHandle.standardOutput.write(Data(usageText().utf8))
    default:
        FileHandle.standardError.write(Data("unknown subcommand '\(subcommand)'\n".utf8))
        FileHandle.standardOutput.write(Data(usageText().utf8))
        exit(2)
    }
}

// MARK: - answer-batch subcommand

/// Runs an offline answer pass against a dump produced by a spec lane's
/// `--dump-answer-inputs` flag.
///
/// Dispatches on the `benchmark` field in the dump header:
///   - `convomem-spec` → delegates to the existing
///     `runConvoMemSpecAnswerDump(inputsPath:answerCmd:outputPath:)`.
///   - `membench-spec` → loops over `qa` records, runs the answer command with
///     each record's rendered prompt on stdin, extracts the letter via
///     `MemBenchAnswerConstraint.parseAnswerChoice`, and writes
///     `{"item_id":…,"answer":"<letter>","raw":"<trimmed stdout>"}` lines (the
///     format `--consume-answers` accepts). Per-record failures are written as
///     `{"item_id":…,"answer":null,"error":…}` and counted; the run exits
///     non-zero only when every record fails.
///
/// Required options: `--inputs`, `--answer-cmd`, `--out`.
/// Optional: `--limit N`, `--offset N`, and `--reader-model <identity>`.
func runAnswerBatch(_ args: [String]) throws {
    guard let inputsPath = optionValue("--inputs", in: args) else {
        throw MCPError(description: "answer-batch requires --inputs <answer-inputs.jsonl>")
    }
    guard let answerCmd = optionValue("--answer-cmd", in: args) else {
        throw MCPError(description: "answer-batch requires --answer-cmd <cmd>")
    }
    guard let outputPath = optionValue("--out", in: args) else {
        throw MCPError(description: "answer-batch requires --out <path>")
    }
    let limit: Int? = try parseLimitOption(in: args)
    let offset: Int
    if let rawOffset = optionValue("--offset", in: args) {
        guard let parsed = Int(rawOffset), parsed >= 0 else {
            throw MCPError(description:
                "answer-batch --offset must be a non-negative integer")
        }
        offset = parsed
    } else {
        offset = 0
    }
    let readerModel = optionValue("--reader-model", in: args) ?? "unknown"

    // Read and parse the dump file.
    guard let rawData = FileManager.default.contents(atPath: inputsPath),
          let content = String(data: rawData, encoding: .utf8) else {
        throw MCPError(description: "answer-batch: cannot read inputs file at '\(inputsPath)'")
    }
    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        throw MCPError(description: "answer-batch: inputs file is empty: '\(inputsPath)'")
    }

    // Parse and validate the header line; extract the benchmark type.
    guard let hData = lines[0].data(using: .utf8),
          let hObj = try? JSONSerialization.jsonObject(with: hData) as? [String: Any],
          (hObj["type"] as? String) == "header" else {
        throw MCPError(description:
            "answer-batch: first line is not a valid header in '\(inputsPath)'")
    }
    guard let benchmark = hObj["benchmark"] as? String else {
        throw MCPError(description:
            "answer-batch: header is missing the 'benchmark' field in '\(inputsPath)'")
    }

    switch benchmark {
    case "convomem-spec":
        // Delegate to the existing runner. It handles all record looping,
        // output writing, and per-record failure logging internally.
        // Pass limit and offset so --limit caps the ConvoMem branch the same way it
        // caps every other branch. Twin of the Rust convomem-spec dispatch path.
        try runConvoMemSpecAnswerDump(
            inputsPath: inputsPath,
            answerCmd: answerCmd,
            outputPath: outputPath,
            limit: limit,
            offset: offset
        )
        // Count records for the summary (header excluded).
        let recordLines = lines.dropFirst()
        let totalRecords = recordLines.filter {
            guard let d = $0.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return false }
            return (o["type"] as? String) == "answer_input"
        }.count
        FileHandle.standardOutput.write(Data(
            "answer-batch: records=\(totalRecords) benchmark=convomem-spec out=\(outputPath)\n"
                .utf8))

    case "membench-spec":
        // Resume: collect item_ids already answered in the output file. An existing
        // record with a non-null answer is evidence it was written by a previous run;
        // re-running the reader for it is wasteful and risks overwriting a good answer
        // with a bad one when the shared server is degraded.
        var resumedIDs = Set<String>()
        var resumedCount = 0
        if FileManager.default.fileExists(atPath: outputPath),
           let existingData = FileManager.default.contents(atPath: outputPath),
           let existingText = String(data: existingData, encoding: .utf8) {
            for existing in existingText.components(separatedBy: "\n") where !existing.isEmpty {
                guard let ed = existing.data(using: .utf8),
                      let eo = try? JSONSerialization.jsonObject(with: ed) as? [String: Any],
                      let eid = eo["item_id"] as? String,
                      !(eo["answer"] is NSNull) && eo["answer"] != nil else { continue }
                resumedIDs.insert(eid)
                resumedCount += 1
            }
        }
        // Open for append (create with restricted permissions if absent).
        if !FileManager.default.fileExists(atPath: outputPath) {
            FileManager.default.createFile(
                atPath: outputPath, contents: nil,
                attributes: [.posixPermissions: 0o600 as NSNumber])
        }
        let appendFd = open(outputPath, O_WRONLY | O_APPEND | O_CREAT, mode_t(0o600))
        guard appendFd >= 0 else {
            let err = errno
            throw MCPError(description:
                "answer-batch: cannot open output for append '\(outputPath)': "
                    + String(cString: strerror(err)))
        }
        let fh = FileHandle(fileDescriptor: appendFd, closeOnDealloc: true)
        defer { fh.closeFile() }

        var totalRecords = 0
        var answered = resumedCount
        var failed = 0

        // Apply the optional record limit on the qa rows only (header excluded).
        var qaLines = lines.dropFirst().filter {
            guard let d = $0.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return false }
            return (o["type"] as? String) == "qa"
        }
        if let cap = limit {
            qaLines = Array(qaLines.prefix(cap))
        }

        for line in qaLines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["type"] as? String) == "qa",
                  let itemID = obj["item_id"] as? String,
                  let prompt = obj["prompt"] as? String else {
                continue
            }
            totalRecords += 1

            // Resume: skip records whose answer was written by a previous run.
            if resumedIDs.contains(itemID) { continue }

            let outLine: [String: Any]
            // Keep the answer command's own error text: a failed subprocess and
            // an unparseable reply are different faults and the record says which.
            let attempt = Result { try lmeRunJudge(cmd: answerCmd, prompt: prompt) }
            if case .success(let rawResponse) = attempt,
               let letter = MemBenchAnswerConstraint.parseAnswerChoice(from: rawResponse) {
                // Reuse the same letter-extraction path as the live lane (§3).
                outLine = [
                    "item_id": itemID,
                    "answer": letter,
                    "raw": rawResponse,
                ]
                answered += 1
            } else {
                // Per-record failure: log and record with null answer.
                let errMsg: String
                switch attempt {
                case .failure(let error):
                    errMsg = "answer cmd failed for \(itemID): \(error)"
                case .success(let raw):
                    errMsg = "answer cmd returned an unparseable response for \(itemID): \(raw.prefix(120))"
                }
                FileHandle.standardError.write(Data(
                    "[membench-spec-batch] \(errMsg)\n".utf8))
                outLine = [
                    "item_id": itemID,
                    "answer": NSNull(),
                    "error": errMsg,
                ]
                failed += 1
            }
            if let ld = try? JSONSerialization.data(withJSONObject: outLine, options: [.sortedKeys]),
               var ls = String(data: ld, encoding: .utf8) {
                ls += "\n"
                fh.write(Data(ls.utf8))
            }
        }

        let summary = "answer-batch: records=\(totalRecords) answered=\(answered) "
            + "failed=\(failed) resumed=\(resumedCount) benchmark=membench-spec out=\(outputPath)\n"
        FileHandle.standardOutput.write(Data(summary.utf8))

        // Exit non-zero only when every record failed and at least one was attempted.
        if totalRecords > 0, answered == 0 {
            throw MCPError(description:
                "answer-batch: all \(totalRecords) membench-spec records failed to answer")
        }

    case "lme-spec":
        // Delegate to the lme-spec reader-model consumer. It handles header
        // parsing, prompt construction via the §2 anscheck builder, and per-record
        // failure logging internally. The output is judge_ready JSONL consumed
        // by judge-sessions.py and judge-batch unchanged.
        let abJudgeModel = optionValue("--judge-model", in: args) ?? "gpt-4o-2024-08-06"
        try runLMESpecAnswerBatch(
            inputsPath: inputsPath,
            answerCmd: answerCmd,
            outputPath: outputPath,
            judgeModel: abJudgeModel,
            limit: limit,
            offset: offset)

    case "locomo-spec":
        try runLoCoMoSpecAnswerBatch(
            inputsPath: inputsPath,
            answerCmd: answerCmd,
            outputPath: outputPath,
            limit: limit,
            offset: offset,
            readerModel: readerModel)

    default:
        throw MCPError(description:
            "answer-batch: unknown benchmark '\(benchmark)' in header; "
            + "supported: convomem-spec, membench-spec, lme-spec, locomo-spec")
    }
}

/// The library entry point the thin executable target calls. Runs the
/// subcommand dispatch and converts a thrown error into a non-zero exit,
/// exactly as the former top-level code did.
public func benchmarkerMain(_ arguments: [String]) async {
    do {
        try await dispatch(arguments)
    } catch {
        FileHandle.standardError.write(Data("mcp-benchmarker: \(error)\n".utf8))
        exit(1)
    }
}


// MARK: - supersession lane

/// Runs the supersession / contradiction lane: one persistent estate, a
/// chronologically-ingested timeline, and scoring on whether the CURRENT
/// version of a changed fact outranks its superseded versions.
///
/// The public benchmarks cannot ask this — they provision a fresh estate per
/// question, so nothing ever supersedes anything. See SupersessionCorpus.swift
/// for the design rationale and the fairness rule that governs what may be
/// scored here.
func runSupersession(_ args: [String]) async throws {
    let seed = UInt64(optionValue("--seed", in: args) ?? "") ?? 20260725
    // Minimums are the smallest values that keep the generated corpus
    // well-formed, established once here at the boundary so the generators
    // can go on trusting their inputs:
    //   --entities / --contradictions >= 0. A zero-size sub-corpus composes —
    //     an entities-only or contradictions-only run is legitimate, and
    //     --skip-contradictions already exists as a first-class flag. Only a
    //     negative count breaks anything: SupersessionCorpus builds
    //     `0..<entityCount` and `0..<contradictionCount`, which trap.
    //   --versions >= 1. SupersessionCorpus indexes
    //     `chainValues[chainValues.count - 1]` for the current version, which
    //     traps on the empty chain a zero produces (the Rust twin underflows
    //     its usize instead).
    //   --k >= 1. This one does not crash, which is why it is easy to miss:
    //     SupersessionRunner scores `staleRanks.filter { $0 <= topK }`, and
    //     ranks are 1-based, so a cutoff of zero makes the stale-in-top-K
    //     metric identically zero — a perfect score no matter what the
    //     product did. A rank cutoff below 1 measures nothing while still
    //     labelling the report as measured.
    let entities = try validatedCount("--entities", in: args, default: 40, minimum: 0)
    let versions = try validatedCount("--versions", in: args, default: 3, minimum: 1)
    let contradictions = try validatedCount("--contradictions", in: args, default: 10, minimum: 0)
    // MXE-CT3 P4 classes. Zero composes (a run without divergences or decoys
    // is legitimate); only negatives break the `0..<count` generator loops.
    // Rejection of non-integer/negative input rides validatedCount
    // (b77ec03e8 precedent).
    let divergences = try validatedCount("--divergences", in: args, default: 5, minimum: 0)
    let decoys = try validatedCount("--decoys", in: args, default: 5, minimum: 0)
    let topK = try validatedCount("--k", in: args, default: 10, minimum: 1)
    let shape = optionValue("--recall-shape", in: args)
    if let sh = shape, !lmeRecallShapePresets.contains(sh) {
        throw MCPError(description: "--recall-shape must be one of: "
            + lmeRecallShapePresets.joined(separator: ", ") + "; got '" + sh + "'")
    }

    let corpus = generateSupersessionCorpus(
        seed: seed, entityCount: entities, versionsPerChain: versions,
        contradictionCount: contradictions,
        divergenceCount: divergences, decoyCount: decoys)
    let header = "[supersession] corpus seed \(seed): \(corpus.records.count) records, "
        + "\(corpus.queries.count) chains, \(corpus.contradictions.count) contradiction pairs, "
        + "\(corpus.divergences.count) divergence pairs, \(corpus.decoys.count) decoys\n"
    FileHandle.standardOutput.write(Data(header.utf8))

    // --dump-seed <path>: write the seed the batch path would import —
    // seed-file schema v1 exactly (dump output == importer input == the
    // third-party interchange artifact), in the chronological file order the
    // lane ingests — and exit without running anything (no binary needed).
    // Cross-leg reproducibility: both legs' emitters are byte-identical
    // (conformance/seed_export_vectors.json), so diffing the two dumps
    // still proves leg agreement.
    if let dumpPath = optionValue("--dump-seed", in: args) {
        let ordered = corpus.records.sorted {
            ($0.eventTime, $0.id) < ($1.eventTime, $1.id)
        }
        let data = emitSeedJSON(
            name: "supersession-\(seed)",
            records: supersessionSeedRecords(from: ordered))
        let dumpURL = URL(fileURLWithPath: dumpPath)
        // Create the parent directory tree before writing. `Data.write(to:)` does
        // not create intermediate directories; a nested --dump-seed path fails
        // without this step.
        try FileManager.default.createDirectory(
            at: dumpURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: dumpURL)
        FileHandle.standardOutput.write(Data(
            "[supersession] seed dumped to \(dumpPath)\n".utf8))
        return
    }

    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args)
        ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Pass --binary <path>.")
    }

    // ── Fact-layer capability cell ────────────────────────────────────────
    // INTERNAL CAPABILITY CELL — outside the fairness-rule comparative lane.
    // --fact-layer activates the structured-fact lifecycle:
    //   file via moot_file_fact → retire non-current via moot_retire_fact
    //   → query via moot_fact_search → score on fact-UUID ground truth.
    // This branch exits early; the standard supersession flow is skipped.
    if flagPresent("--fact-layer", in: args) {
        let factCorpus = generateFactLayerCorpus(
            seed: seed, factCount: entities, versionsPerFact: versions)
        let factHeader = "[fact-layer] INTERNAL CAPABILITY CELL — "
            + "corpus seed \(seed): \(factCorpus.facts.count) fact records, "
            + "\(factCorpus.queries.count) queries\n"
        FileHandle.standardOutput.write(Data(factHeader.utf8))

        // The fact-layer dump keeps its lane-fixture format (facts + queries
        // — conformance-vector source, not an estate seed): schema v1 cannot
        // express sourceless facts, so there is no seed to dump here. Only
        // the public flag name changes (vocabulary ruling 2026-08-08).
        if let dumpPath = optionValue("--dump-seed", in: args) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(factCorpus)
            let dumpURL = URL(fileURLWithPath: dumpPath)
            // Create the parent directory tree before writing. `Data.write(to:)` does
            // not create intermediate directories; a nested --dump-seed path fails
            // without this step.
            try FileManager.default.createDirectory(
                at: dumpURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: dumpURL)
            FileHandle.standardOutput.write(Data(
                "[fact-layer] fixture dumped to \(dumpPath)\n".utf8))
            return
        }

        // C1: parse --shape; default is disk (SQLite). Same parse as the LME lane.
        let flShapeRaw = optionValue("--shape", in: args) ?? "disk"
        let flShape: LMEShape
        switch flShapeRaw {
        case "ram":  flShape = .ram
        case "disk": flShape = .disk
        default:
            throw MCPError(description:
                "--shape must be 'disk' or 'ram'; got '\(flShapeRaw)'")
        }

        let flPosture: ScratchEstatePosture = .encryptedEphemeral
        let flScratch = try lmeScratchDir(posture: flPosture)
        // Retired only on a clean finish; a throw keeps the estate and says
        // where (see keepScratchEstateOnFailure).
        var flCompleted = false
        defer {
            if flCompleted { try? retireScratchEstate(flScratch, teardown: lmeGuardedTeardown) }
            else { keepScratchEstateOnFailure(flScratch, lane: "fact-layer") }
        }
        let flConfig = FactLayerRunConfig(
            mootBinaryPath: mootBinary, seed: seed,
            factCount: entities, versionsPerFact: versions,
            scratchDir: flScratch, posture: flPosture,
            shape: flShape)
        let flOutcome = try await runFactLayerCell(corpus: factCorpus, config: flConfig)
        let flScores = scoreFactLayer(flOutcome.queryResults)

        FileHandle.standardOutput.write(Data(String(format: """
        [fact-layer] INTERNAL CAPABILITY CELL — run complete
          queries scored:           %d
          current-fact found rate:  %.4f   <- current version appeared in moot_fact_search results
          current-fact win rate:    %.4f   <- current outranked every surfaced retired version
          mean retired per query:   %.2f   <- retired fact UUIDs surfaced by search (0.0 = none)
          query p50:                %.1f ms
          ingest elapsed:           %.2f s <- Steps 1+2 (file + retire); no drain/dream in this cell
          unfiled facts:            %d     <- moot_file_fact calls that returned no parseable UUID

        NOTE: This cell is NOT a comparative measurement. It measures the
        structured-fact lifecycle (moot_file_fact / moot_retire_fact /
        moot_fact_search) end-to-end. No external system is scored here.
        cell_type: internal_capability

        """, flScores.queryCount, flScores.currentFoundRate, flScores.currentWinRate,
             flScores.meanRetiredPerQuery, flScores.p50LatencySeconds * 1000,
             flOutcome.ingestElapsedSeconds,
             flOutcome.unfiledFactIDs.count).utf8))

        // C7: emit minimal JSON report alongside the text summary.
        // Struct mirrors the Rust twin in main.rs. Identity block only.
        let flEnv = IdentityEnvironment.collect(mootx01BinaryPath: mootBinary)
        let flReport = FactLayerReport(
            cellType: "internal_capability",
            backendShape: flShape.rawValue,
            ingestElapsedSeconds: flOutcome.ingestElapsedSeconds,
            queryCount: flScores.queryCount,
            currentFoundRate: flScores.currentFoundRate,
            currentWinRate: flScores.currentWinRate,
            meanRetiredPerQuery: flScores.meanRetiredPerQuery,
            p50LatencySeconds: flScores.p50LatencySeconds,
            unfiledFactCount: flOutcome.unfiledFactIDs.count,
            runEnvironment: flEnv)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportJSON = try encoder.encode(flReport)
        FileHandle.standardOutput.write(reportJSON)
        FileHandle.standardOutput.write(Data("\n".utf8))
        flCompleted = true
        return
    }

    // ── Standard supersession lane (no --fact-layer) ──────────────────────
    // Ephemeral by DEFAULT: temporal in-memory key, zero key residue — the
    // posture the standing no-orphaned-keys rule requires of a lane that
    // provisions estates. --estate-mode exists so the two postures can be
    // compared; --estate-mode both runs both postures sequentially against
    // the same corpus and prints a delta section.
    let skipContradictions = flagPresent("--skip-contradictions", in: args)
    let skipDream          = flagPresent("--skip-dream", in: args)
    let doStructuredTier   = flagPresent("--structured-tier", in: args)
    // Batch by default (ruling 8D5B8053); `live` is the retained slow lane.
    let seedPath = try SeedPathMode.parse(optionValue("--seed-path", in: args))
    // C5: guard sampling policy (--guard-sample once|per-unit, default once).
    let supersessionGuardPolicy = try GuardSamplingPolicy.parse(
        optionValue("--guard-sample", in: args))
    // C1: backend shape (--shape disk|ram, default disk). "ram" injects
    // serve --in-memory. Supersession uses one long-lived estate so
    // RAM shape avoids any on-disk SQLite write path, matching the deployed
    // in-memory benchmark use case. Not compatible with --estate-cache reuse.
    let supersessionShapeStr = optionValue("--shape", in: args) ?? "disk"
    let supersessionShape: LMEShape
    switch supersessionShapeStr {
    case "disk": supersessionShape = .disk
    case "ram":  supersessionShape = .ram
    default:
        throw MCPError(description:
            "--shape must be 'disk' or 'ram'; got '\(supersessionShapeStr)'")
    }
    // C7: run-mode label for RunEnvironment (--run-mode <string>, default "unspecified").
    let supersessionRunMode = optionValue("--run-mode", in: args) ?? "unspecified"
    let rawEstateMode = optionValue("--estate-mode", in: args)

    if rawEstateMode == "both" {
        // Both mode: corpus generated once above; each posture provisions its
        // own scratch estate, runs fully, and tears down before the next run
        // starts. The delta section then compares the two scorecards.
        let unencryptedScores = try await runAndPrintSupersessionPosture(
            corpus: corpus, mootBinary: mootBinary, seed: seed,
            entityCount: entities, versionsPerChain: versions,
            contradictionCount: contradictions, topK: topK,
            recallShape: shape, skipContradictions: skipContradictions,
            skipDream: skipDream, structuredTier: doStructuredTier,
            seedPath: seedPath,
            guardSamplingPolicy: supersessionGuardPolicy,
            benchShape: supersessionShape,
            runMode: supersessionRunMode,
            posture: .plaintextTransient, postureLabel: "unencrypted")
        let encryptedScores = try await runAndPrintSupersessionPosture(
            corpus: corpus, mootBinary: mootBinary, seed: seed,
            entityCount: entities, versionsPerChain: versions,
            contradictionCount: contradictions, topK: topK,
            recallShape: shape, skipContradictions: skipContradictions,
            skipDream: skipDream, structuredTier: doStructuredTier,
            seedPath: seedPath,
            guardSamplingPolicy: supersessionGuardPolicy,
            benchShape: supersessionShape,
            runMode: supersessionRunMode,
            posture: .encryptedEphemeral, postureLabel: "encrypted")
        let delta = computeSupersessionEstateDelta(
            unencrypted: unencryptedScores, encrypted: encryptedScores)
        printSupersessionEstateDelta(delta)
    } else {
        // Single-posture mode. Default is encrypted (ephemeral key, zero
        // residue) when --estate-mode is absent.
        let posture: ScratchEstatePosture = rawEstateMode == nil
            ? .encryptedEphemeral
            : try parseEstateMode(in: args)
        _ = try await runAndPrintSupersessionPosture(
            corpus: corpus, mootBinary: mootBinary, seed: seed,
            entityCount: entities, versionsPerChain: versions,
            contradictionCount: contradictions, topK: topK,
            recallShape: shape, skipContradictions: skipContradictions,
            skipDream: skipDream, structuredTier: doStructuredTier,
            seedPath: seedPath,
            guardSamplingPolicy: supersessionGuardPolicy,
            benchShape: supersessionShape,
            runMode: supersessionRunMode,
            posture: posture, postureLabel: nil)
    }
}

// MARK: - Supersession helpers

/// Provisions a scratch estate for `posture`, runs the full supersession lane
/// against `corpus`, prints the complete scorecard section to stdout (including
/// contradiction sweep and structured tier when they ran), retires the scratch
/// estate, and returns the aggregate `SupersessionScores` for delta computation.
///
/// `postureLabel` is appended to the "[supersession] run complete" banner when
/// non-nil — single-posture runs pass nil to preserve the existing output shape,
/// and --estate-mode both passes "unencrypted" / "encrypted" to label each run.
///
/// Retirement (not bare teardown) is deferred so the error path cannot strand a
/// scratch estate: verifies zero residual key material when the estate dies.
func runAndPrintSupersessionPosture(
    corpus: SupersessionCorpus,
    mootBinary: String,
    seed: UInt64,
    entityCount: Int,
    versionsPerChain: Int,
    contradictionCount: Int,
    topK: Int,
    recallShape: String?,
    skipContradictions: Bool,
    skipDream: Bool,
    structuredTier: Bool,
    seedPath: SeedPathMode,
    guardSamplingPolicy: GuardSamplingPolicy = .oncePerLeg,
    benchShape: LMEShape = .disk,
    runMode: String = "unspecified",
    posture: ScratchEstatePosture,
    postureLabel: String?
) async throws -> SupersessionScores {
    // C15: print a loud deviation banner when --skip-dream is active.
    // A skipped-dream run measures the virgin estate, not the deployed steady
    // state. Published cells from such runs must be clearly distinguishable.
    if skipDream {
        FileHandle.standardOutput.write(Data("""
        ╔══════════════════════════════════════════════════════════════════╗
        ║  DEVIATION NOTICE — --skip-dream is active                     ║
        ║  This run measures the VIRGIN ESTATE (no matrix priors).       ║
        ║  Matrix-steering presets (temporal/connection/field/preference) ║
        ║  return byte-identical rankings on virgin estates because the  ║
        ║  columns are all 0.0 by contract. These results CANNOT be      ║
        ║  compared directly to dreamed-estate numbers.                  ║
        ║  skip_dream: true is stamped on all output fields below.       ║
        ╚══════════════════════════════════════════════════════════════════╝

        """.utf8))
    }
    let scratch = try lmeScratchDir(posture: posture)
    // Retired only on a clean finish; a throw keeps the estate and says where.
    var postureCompleted = false
    defer {
        if postureCompleted {
            try? retireScratchEstate(scratch, expectPlaintext: posture == .plaintextTransient, teardown: lmeGuardedTeardown)
        } else {
            keepScratchEstateOnFailure(scratch, lane: "supersession")
        }
    }
    var runConfig = SupersessionRunConfig(
        mootBinaryPath: mootBinary, seed: seed, entityCount: entityCount,
        versionsPerChain: versionsPerChain, contradictionCount: contradictionCount,
        topK: topK, recallShape: recallShape, scratchDir: scratch, posture: posture,
        contradictionSweep: !skipContradictions,
        dreamBeforeQueries: !skipDream,
        structuredTier: structuredTier,
        seedPath: seedPath)
    // C1/C5: wire shape and guard sampling into the run config.
    runConfig.shape = benchShape
    runConfig.guardSamplingPolicy = guardSamplingPolicy
    let outcome = try await runSupersessionLane(corpus: corpus, config: runConfig)
    let scores = scoreSupersession(outcome.queryResults, topK: topK)

    // C7: collect machine provenance once per run, before printing. The
    // RunEnvironment field is the same provenance attached to every LMEB/LME
    // report — it names the machine, the binary SHA, and the run mode so
    // a cell can always be attributed to its measurement context.
    let runEnv = RunEnvironment.collect(
        mootx01BinaryPath: mootBinary,
        runMode: runMode)

    // Guard health summary (C5).
    let guardHealthyCount = outcome.queryResults.filter(\.guardHealthy).count
    let guardRefusals = outcome.queryResults.count - guardHealthyCount

    // "[supersession] run complete" banner — posture label is appended only in
    // --estate-mode both so each run is clearly identified.
    let banner = postureLabel.map { " (estate-mode: \($0))" } ?? ""
    FileHandle.standardOutput.write(Data(String(format: """
    [supersession] run complete\(banner)
      chains scored:            %d
      guard healthy:            %d
      guard refused:            %d
      CURRENT-OVER-STALE rate:  %.4f   <- the headline: current outranks every superseded version
      current found rate:       %.4f
      mean stale in top-%d:      %.2f   <- outdated facts a consumer would paste into a prompt
      mean rank of current:     %.2f
      query p50:                %.1f ms
      recall shape:             %@
      guard_sampling:           %@
      shape:                    %@
      run_mode:                 %@
      run_environment:          %@ / %@

    """, scores.queryCount, guardHealthyCount, guardRefusals,
         scores.currentWinRate, scores.currentFoundRate,
         topK, scores.meanStaleInTopK, scores.meanCurrentRank,
         scores.p50LatencySeconds * 1000, recallShape ?? "none (moot_memory_search)",
         guardSamplingPolicy.rawValue,
         benchShape.rawValue,
         runMode,
         runEnv.hostname, runEnv.chipName).utf8))
    // Estate state is part of the measurement's identity: matrix-steering
    // presets only have signal on a dreamed estate.
    FileHandle.standardOutput.write(Data(
        "  estate state:             \(runConfig.dreamBeforeQueries ? "dreamed (matrix priors live)" : "virgin (no matrix priors)")\n".utf8))
    // C15: stamp skip_dream on the output so no published number can silently
    // come from a skipped-dream run. The field is always present (false on
    // standard runs) so tooling can assert on it without handling absent keys.
    FileHandle.standardOutput.write(Data(
        "  skip_dream:               \(skipDream ? "true  ← DEVIATION — virgin estate, NOT the deployed steady state" : "false")\n\n".utf8))

    // Contradiction sweep (scored behaviour 3). Detection of the planted,
    // recency-unresolvable pairs is the scored figure. Pairs flagged outside
    // the planted set are context, not error: superseded chain versions
    // genuinely conflict too — they are just resolvable by recency.
    if let c = outcome.contradiction {
        let anyRate = c.plantedCount > 0
            ? Double(c.detectedAnyTier) / Double(c.plantedCount) : 0
        let propRate = c.plantedCount > 0
            ? Double(c.detectedProposed) / Double(c.plantedCount) : 0
        FileHandle.standardOutput.write(Data(String(format: """
          contradiction sweep (moot_hunt_contradictions):
            planted pairs:            %d
            detected (any tier):      %.4f  (%d/%d)
            detected as PROPOSED:     %.4f  (%d/%d)
            flagged outside planted:  %d   <- includes superseded-chain conflicts (resolvable by recency)
            hunt wall time:           %.1f s

        """, c.plantedCount, anyRate, c.detectedAnyTier, c.plantedCount,
             propRate, c.detectedProposed, c.plantedCount,
             c.flaggedOutsidePlanted, c.huntSeconds).utf8))
    }

    // Typed proving tier. `proven planted` is the headline (target 10/10
    // where the lexical baseline was 0/10); for `proven outside planted`
    // ANY non-zero value is a false proof, not context — the chains must
    // resolve as historical succession, and their count shows up on the
    // historical line instead.
    if let s = outcome.structured {
        let provenRate = s.plantedCount > 0
            ? Double(s.provenPlanted) / Double(s.plantedCount) : 0
        FileHandle.standardOutput.write(Data(String(format: """
          structured tier (typed conflict projection, moot_lens_contradiction):
            planted pairs:            %d
            proven planted:           %.4f  (%d/%d)   <- typed lane vs the 0/10 lexical baseline
            proven outside planted:   %d   <- MUST be 0; any value here is a false proof
            proven reported:          %d
            historical reported:      %d   <- the chains, resolved by time, not proof
            coverage:                 %d/%d
            tier wall time:           %.1f s

        """, s.plantedCount, provenRate, s.provenPlanted, s.plantedCount,
             s.provenOutsidePlanted, s.provenReported, s.historicalReported,
             s.coverageProjected, s.coverageScanned, s.tierSeconds).utf8))
    }

    // MXE-CT3 P4 tiered scoring. Per-tier recall comes from single-tier
    // purpose runs (read-only searches); the exactly-once and timing figures
    // come from the tier=all synthesis digest. The decoy split is deliberate:
    // the must-be-0 row is a hard failure, the known-limitation row is the
    // unit-equivalence gap in the lexical digit cue, reported but not failed.
    if let t = outcome.tiered {
        let t2Rate = t.tier2PlantedCount > 0
            ? Double(t.tier2Detected) / Double(t.tier2PlantedCount) : 0
        let t3Rate = t.tier3PlantedCount > 0
            ? Double(t.tier3Detected) / Double(t.tier3PlantedCount) : 0
        FileHandle.standardOutput.write(Data(String(format: """
          tiered scoring (moot_hunt_contradictions tier=1|2|3 purpose runs):
            tier 2 detected:          %.4f  (%d/%d)   <- word-valued plants in the tier=2 purpose run
            tier 3 detected:          %.4f  (%d/%d)   <- digit-divergence plants in the tier=3 purpose run

        """, t2Rate, t.tier2Detected, t.tier2PlantedCount,
             t3Rate, t.tier3Detected, t.tier3PlantedCount).utf8))
        if let planted1 = t.tier1PlantedCount, let detected1 = t.tier1Detected {
            let t1Rate = planted1 > 0 ? Double(detected1) / Double(planted1) : 0
            FileHandle.standardOutput.write(Data(String(format:
                "    tier 1 detected:          %.4f  (%d/%d)   <- planted pairs proven typed (tier=1 after fact filing)\n",
                t1Rate, detected1, planted1).utf8))
        }
        FileHandle.standardOutput.write(Data(String(format: """
            decoy hits (must be 0):   %d   <- marker/distinct-entity decoys flagged at any tier or PROPOSED
            decoy known-limitation:   %d   <- unit-equivalent pairs firing tier 3 (digit cue cannot equate 90s and 1.5min)
            tier inflation:           %d   <- planted pairs double-reported across synthesis tier sections

        """, t.decoyHits.hard, t.decoyHits.knownLimitation, t.tierInflation).utf8))
        var timing = String(format: "    purpose lane seconds:     tier2=%.3f tier3=%.3f",
                            t.tier2PurposeSeconds, t.tier3PurposeSeconds)
        if let t1s = t.tier1PurposeSeconds {
            timing += String(format: " tier1=%.3f", t1s)
        }
        FileHandle.standardOutput.write(Data((timing + "\n").utf8))
        if let wall = t.synthesisWallSeconds {
            FileHandle.standardOutput.write(Data(String(format:
                "    synthesis wall:           %.3f s   <- report's own synthesis_wall_seconds line\n\n",
                wall).utf8))
        } else {
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    postureCompleted = true
    return scores
}

/// Formats and prints the estate-mode comparison delta to stdout.
/// Called only when --estate-mode both is used. The section header is fixed
/// by spec: "estate-mode delta (encrypted − unencrypted):".
func printSupersessionEstateDelta(_ delta: SupersessionEstateDelta) {
    var out = "estate-mode delta (encrypted \u{2212} unencrypted):\n"
    out += String(format: "  CURRENT-OVER-STALE rate:  %+.4f\n", delta.currentWinRateDiff)
    out += String(format: "  current found rate:       %+.4f\n", delta.currentFoundRateDiff)
    out += String(format: "  mean stale in top-k:      %+.2f\n", delta.meanStaleInTopKDiff)
    out += String(format: "  mean rank of current:     %+.2f\n", delta.meanCurrentRankDiff)
    if let pct = delta.queryP50PercentDiff {
        out += String(format: "  query p50:                %+.1f ms (%+.1f%%)\n",
                      delta.queryP50DiffMs, pct)
    } else {
        out += String(format: "  query p50:                %+.1f ms\n", delta.queryP50DiffMs)
    }
    out += "\n"
    FileHandle.standardOutput.write(Data(out.utf8))
}


// MARK: - Journey lane

/// Backend persistence shape for the journey benchmark lane.
///
/// Mirrors the shape enums in the other dataset lanes (LoCoMoEstateShape,
/// MemBenchEstateShape, etc.). The journey lane uses a small synthetic estate
/// (PRECISE-MISS + VAGUE-NARROW corpora), so the RAM shape (C1) is the
/// natural default for accuracy runs. Parsed from `--shape disk|ram`; live
/// run wiring lands with the journey live runner (not implemented in this
/// build).
enum JourneyEstateShape: String, Sendable {
    /// Disk-backed SQLite estate. Compatible with estate cache.
    case disk
    /// In-memory estate. Injects `serve --in-memory` into the serve
    /// command. Zero disk I/O; no keychain contact.
    case ram
}

/// Handles the `journey` subcommand.
///
/// `--dump-seed` writes the generated fixture and exits without a server.
/// Otherwise the lane runs live: it provisions a scratch estate, seeds both
/// sub-corpora in one import, waits for the encode queue to settle, scores
/// PRECISE-MISS with one query per scenario, and walks the four-step
/// survey/pivot/winnow/hydrate journey per VAGUE-NARROW cluster.
func runJourney(_ args: [String]) async throws {
    let seed = UInt64(optionValue("--seed", in: args) ?? "") ?? 20260725

    // The RAM shape is the natural fit for the journey lane's small synthetic
    // estates; disk is measured too, and the two are separate records.
    let shapeRaw = optionValue("--shape", in: args) ?? "ram"
    let shape: JourneyEstateShape
    switch shapeRaw {
    case "disk": shape = .disk
    case "ram":  shape = .ram
    default:
        throw MCPError(description:
            "--shape '\(shapeRaw)' is not recognised; accepted values: disk, ram")
    }
    // Same boundary rule as runSupersession:
    //   --precise-miss-count / --cluster-count >= 0. Either sub-corpus may be
    //     empty — a clusters-only or scenarios-only journey composes. Only a
    //     negative count breaks JourneyCorpus's `0..<count` loops.
    //   --members-per-cluster >= 2. JourneyCorpus documents the precondition
    //     at its generator signature and enforces nothing: it picks the
    //     answer-carrying member with `rng.next() % UInt64(membersPerCluster)`,
    //     which divides by zero at 0. One member above that clears the trap
    //     but leaves a cluster with nothing to narrow among, which is the
    //     entire point of the VAGUE-NARROW lane.
    let preciseMissCount = try validatedCount("--precise-miss-count", in: args, default: 20, minimum: 0)
    let clusterCount = try validatedCount("--cluster-count", in: args, default: 10, minimum: 0)
    let membersPerCluster = try validatedCount("--members-per-cluster", in: args, default: 6, minimum: 2)

    let corpus = generateJourneyCorpus(
        seed: seed, preciseMissCount: preciseMissCount,
        clusterCount: clusterCount, membersPerCluster: membersPerCluster)

    // --dump-seed <path>: write the generated journey fixture as sorted
    // pretty JSON and exit without running a live product. This dump is the
    // lane fixture (timeline + queries + expectations — conformance-vector
    // source), NOT an estate seed: the journey lane has no live seed path in
    // this build. Only the public flag name changed (vocabulary ruling
    // 2026-08-08); the cross-leg conformance diff of the two legs' dumps is
    // unchanged.
    if let dumpPath = optionValue("--dump-seed", in: args) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(corpus)
        let dumpURL = URL(fileURLWithPath: dumpPath)
        // Create the parent directory tree before writing. `Data.write(to:)` does
        // not create intermediate directories; a nested --dump-seed path fails
        // without this step.
        try FileManager.default.createDirectory(
            at: dumpURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: dumpURL)
        FileHandle.standardOutput.write(Data(
            "[journey] fixture dumped to \(dumpPath)\n".utf8))
        return
    }

    // ── Live run ──────────────────────────────────────────────────────────
    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args)
        ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Pass --binary <path>.")
    }

    // Rank cutoff. Ranks are 1-based, so a cutoff below 1 makes every "found"
    // metric identically zero while still labelling the report as measured —
    // the same trap the supersession lane documents at its own --k.
    let topK = try validatedCount("--k", in: args, default: 10, minimum: 1)

    // Ephemeral-encrypted by default: the key is minted in the serve process's
    // memory and dies with it, so a lane that provisions estates leaves no key
    // behind. --estate-mode selects the plaintext posture instead.
    let posture = try parseEstateMode(in: args)

    let scratch = try lmeScratchDir(posture: posture)
    // Retired only on a clean finish; a throw keeps the estate and says where.
    var journeyCompleted = false
    defer {
        if journeyCompleted { try? retireScratchEstate(scratch, teardown: lmeGuardedTeardown) }
        else { keepScratchEstateOnFailure(scratch, lane: "journey") }
    }

    let config = JourneyRunConfig(
        seed: seed,
        mootBinaryPath: mootBinary,
        scratchDir: scratch,
        posture: posture,
        shape: shape,
        topK: topK)

    FileHandle.standardOutput.write(Data("""
        [journey] corpus seed \(seed): \(corpus.preciseMiss.scenarios.count) PRECISE-MISS \
        scenarios, \(corpus.vagueNarrow.clusters.count) VAGUE-NARROW clusters \
        (\(corpus.vagueNarrow.membersPerCluster) members each), shape \(shape.rawValue)

        """.utf8))

    let outcome = try await runJourneyLane(corpus: corpus, config: config)
    // Pre-compute serial so the filename and the stamped run_environment block match
    // (testname-arm-serial discipline). arm is shape.rawValue, known before collect.
    let journeySerial = resolveRunSerial(args)
    var runEnvJourney = RunEnvironment.collect(
        mootx01BinaryPath: mootBinary,
        runMode: optionValue("--run-mode", in: args) ?? "unspecified")
    stampTestIdentity(&runEnvJourney,
                      test: "journey",
                      arm: shape.rawValue,
                      serial: journeySerial)
    let report = buildJourneyReport(
        corpus: corpus, outcome: outcome, config: config,
        runEnvironment: runEnvJourney)

    // `<test>-<arm>-<serial>`: the arm is the backend shape. Disk and RAM are
    // separate records — the difference between them is a reported figure, so
    // one must never occupy the other's name. Serial and arm pre-computed above.
    let outDir = try resolvedOutputDirectory(in: args)
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let recordName = recordFilename(
        test: "journey", arm: shape.rawValue, serial: journeySerial)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeRecordNeverOverwrite(
        try encoder.encode(report), to: outDir.appendingPathComponent(recordName))
    try appendToLedger(
        "journey\t\(shape.rawValue)\t\(recordName)"
        + "\tprecise_miss=\(outcome.preciseMiss.count)"
        + "\tvague_narrow=\(outcome.vagueNarrow.count)",
        at: outDir.appendingPathComponent("records.tsv"))

    FileHandle.standardOutput.write(Data(journeySummaryText(report).utf8))
    FileHandle.standardOutput.write(Data(
        "report written to \(outDir.appendingPathComponent(recordName).path)\n".utf8))
    journeyCompleted = true
}


// MARK: - Replay lane

/// Runs the supersession lane N times with the same seed to prove
/// end-to-end replay determinism. Each run provisions a fresh scratch
/// estate, regenerates the corpus from the seed, and scores the full
/// lane. After all runs complete, the deterministic-eligible outcome
/// fields are compared across runs and a per-field MATCH/DRIFT table is
/// printed. Exit 0 when all fields match; exit 1 on any drift.
///
/// Twin of Rust `run_replay` in main.rs.
func runReplay(_ args: [String]) async throws {
    let seed = UInt64(optionValue("--seed", in: args) ?? "") ?? 20260725
    // Same minimum contract as runSupersession — see that function's comments
    // for the per-option rationale.
    let entities      = try validatedCount("--entities",       in: args, default: 40, minimum: 0)
    let versions      = try validatedCount("--versions",       in: args, default: 3,  minimum: 1)
    let contradictions = try validatedCount("--contradictions", in: args, default: 10, minimum: 0)
    let topK          = try validatedCount("--k",              in: args, default: 10, minimum: 1)
    // --runs minimum is 2: a single run cannot be compared against anything,
    // and a "replay of one" would trivially pass without measuring anything.
    let runs          = try validatedCount("--runs",           in: args, default: 2,  minimum: 2)

    let shape = optionValue("--recall-shape", in: args)
    if let sh = shape, !lmeRecallShapePresets.contains(sh) {
        throw MCPError(description: "--recall-shape must be one of: "
            + lmeRecallShapePresets.joined(separator: ", ") + "; got '" + sh + "'")
    }

    // --estate-mode: "unencrypted" and "encrypted" accepted; "both" is
    // explicitly rejected. Replay compares runs of the SAME posture — running
    // two different postures would be a different experiment (like
    // --estate-mode both in supersession) and would destroy the determinism
    // claim by introducing a variable that is not the seed.
    let rawEstateMode = optionValue("--estate-mode", in: args)
    if rawEstateMode == "both" {
        throw MCPError(description:
            "--estate-mode both is not accepted by the replay subcommand: "
            + "replay compares runs of the same posture, not two postures. "
            + "Pass --estate-mode unencrypted or --estate-mode encrypted.")
    }
    let posture: ScratchEstatePosture = rawEstateMode == nil
        ? .encryptedEphemeral                   // default: encrypted, zero residue
        : try parseEstateMode(in: args)

    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args)
        ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Pass --binary <path>.")
    }

    let skipContradictions = flagPresent("--skip-contradictions", in: args)
    let skipDream          = flagPresent("--skip-dream",          in: args)
    let doStructuredTier   = flagPresent("--structured-tier",     in: args)
    // Capture per-query, per-lane scores from RecallExplainer output. Adds
    // explain: true to every recall call and prints a lane diff table after
    // all runs complete, naming the lane(s) whose means differ across runs.
    let doLaneCapture      = flagPresent("--lane-capture",        in: args)
    // Replay proves determinism of whichever seed path it is pointed at;
    // batch (the default) is the shipping pipeline.
    let seedPath = try SeedPathMode.parse(optionValue("--seed-path", in: args))
    // C5/C1: guard sampling and shape are replayed too — the determinism probe
    // must use the same lane config on every iteration. Defaults match the
    // supersession subcommand defaults so an operator does not need to pass
    // both when comparing a replay to a supersession run.
    let replayGuardPolicy = try GuardSamplingPolicy.parse(
        optionValue("--guard-sample", in: args))
    let replayShapeStr = optionValue("--shape", in: args) ?? "disk"
    let replayShape: LMEShape
    switch replayShapeStr {
    case "disk": replayShape = .disk
    case "ram":  replayShape = .ram
    default:
        throw MCPError(description:
            "--shape must be 'disk' or 'ram'; got '\(replayShapeStr)'")
    }

    let header = "[replay] seed \(seed): \(runs) run(s), entities \(entities), "
        + "versions \(versions), contradictions \(contradictions)\n"
    FileHandle.standardOutput.write(Data(header.utf8))

    var fingerprints: [ReplayFingerprint] = []
    var outcomes: [SupersessionLaneOutcome] = []
    fingerprints.reserveCapacity(runs)
    outcomes.reserveCapacity(runs)

    for runIndex in 1...runs {
        // Corpus is regenerated from the same seed on every iteration.
        // Corpus generation is a pure function of the seed, so the same
        // corpus will always be produced — but regenerating per run means
        // the generation step is INSIDE the replayed surface: any
        // non-determinism in the generator (e.g. a leaked clock source)
        // would be caught here rather than hidden by sharing one instance.
        let corpus = generateSupersessionCorpus(
            seed: seed, entityCount: entities, versionsPerChain: versions,
            contradictionCount: contradictions)

        let scratch = try lmeScratchDir(posture: posture)
        // Retire the scratch estate before the next run starts. The defer
        // executes at the end of each loop iteration's scope, so each run
        // gets a fresh, isolated estate. Retirement (not bare teardown)
        // verifies zero residual key material when the estate dies.
        var replayRunCompleted = false
        defer {
            // Diagnostic seam (MOOT_REPLAY_KEEP_ESTATES): keep every run's
            // scratch estate for post-hoc state diffing of a drifting pair.
            // Env-gated, replay-only — retirement (and its key-residue purge)
            // is skipped, so use only on plaintext throwaway estates.
            if ProcessInfo.processInfo.environment["MOOT_REPLAY_KEEP_ESTATES"] != nil {
                FileHandle.standardError.write(Data(
                    "[replay] run \(runIndex) estate KEPT for diffing at \(scratch.path)\n".utf8))
            } else if replayRunCompleted {
                try? retireScratchEstate(scratch, expectPlaintext: posture == .plaintextTransient, teardown: lmeGuardedTeardown)
            } else {
                keepScratchEstateOnFailure(scratch, lane: "replay")
            }
        }

        var runConfig = SupersessionRunConfig(
            mootBinaryPath: mootBinary, seed: seed, entityCount: entities,
            versionsPerChain: versions, contradictionCount: contradictions,
            topK: topK, recallShape: shape, scratchDir: scratch, posture: posture,
            contradictionSweep: !skipContradictions,
            dreamBeforeQueries: !skipDream,
            structuredTier: doStructuredTier,
            seedPath: seedPath,
            laneCapture: doLaneCapture)
        // C1/C5: wire shape and guard policy into replay so the determinism
        // probe runs the same lane config on every iteration.
        runConfig.shape = replayShape
        runConfig.guardSamplingPolicy = replayGuardPolicy
        // Bench-clock seam: pin the serve process's clock to a fixed instant
        // derived deterministically from the seed. Same seed → same epoch →
        // same filedAt stamps and temporal scores across all replay runs, so the
        // DETERMINISTIC verdict is achievable rather than probabilistic.
        // The epoch is the ONLY thing changing; all other lane config stays constant.
        runConfig.benchClockEpoch = benchClockEpochISO(for: seed)

        let outcome = try await runSupersessionLane(corpus: corpus, config: runConfig)
        outcomes.append(outcome)
        let scores  = scoreSupersession(outcome.queryResults, topK: topK)
        // Diagnostic seam (MOOT_REPLAY_QUERY_DUMP): per-query outcome lines so a
        // DRIFT verdict can be attributed to the exact flipping query. Env-gated,
        // replay-only, stderr — never part of scored output.
        if ProcessInfo.processInfo.environment["MOOT_REPLAY_QUERY_DUMP"] != nil {
            for qr in outcome.queryResults {
                FileHandle.standardError.write(Data(
                    "[qdump] run=\(runIndex) q=\(qr.queryID) rank=\(qr.currentRank.map(String.init) ?? "-") stale=\(qr.staleRanks) topK=\(qr.staleInTopK)\n".utf8))
            }
        }
        fingerprints.append(ReplayFingerprint(scores: scores, outcome: outcome))

        let summary = String(format:
            "[replay] run %d/%d: %d chains scored, win rate %.4f\n",
            runIndex, runs, scores.queryCount, scores.currentWinRate)
        FileHandle.standardOutput.write(Data(summary.utf8))
        replayRunCompleted = true
    }

    // Compare run 1's fingerprint against each later run.
    // - For N=2: one comparison, one table.
    // - For N>2: report the first drifting run's table so the operator sees
    //   the earliest deviation. If no run drifts, report the last comparison
    //   (all-MATCH table, showing every field was checked).
    let baseline = fingerprints[0]
    var tableRunIndex = runs        // 1-based index of the run shown in the table
    var tableDiffs: [ReplayFieldDiff] = []
    var anyDrift = false

    for i in 1..<runs {
        let cDiffs = compareReplayFingerprints(
            baseline: baseline, candidate: fingerprints[i])
        if !cDiffs.isEmpty, !anyDrift {
            // First drifting run: pin this one for the table.
            anyDrift      = true
            tableRunIndex = i + 1   // convert 0-based loop index to 1-based run number
            tableDiffs    = cDiffs
        } else if !anyDrift, i == runs - 1 {
            // No drift yet and this is the last candidate: use it so the
            // all-MATCH table appears and shows the operator what was verified.
            tableDiffs = cDiffs     // will be empty (all MATCH)
        }
    }

    printReplayFieldTable(
        baseline: baseline,
        candidate: fingerprints[tableRunIndex - 1],
        diffs: tableDiffs,
        candidateRunIndex: tableRunIndex,
        seed: seed,
        totalRuns: runs)

    // Lane capture: print per-lane mean tables for each consecutive run pair
    // so the caller can identify which scoring lane drifts run-to-run and
    // which lanes collapse between batch and live sessions.
    if doLaneCapture {
        let captures: [(Int, LaneCapture)] = outcomes.enumerated().compactMap { i, o in
            guard let cap = o.laneCapture else { return nil }
            return (i + 1, cap)
        }
        // Per-run lane means (one paragraph per run) for cross-session comparison.
        for (runIdx, cap) in captures {
            let header = "[lane-capture] run \(runIdx) import=\(cap.importTimestamp)\n"
            FileHandle.standardOutput.write(Data(header.utf8))
            let allDiffs = diffLaneCaptures(baseline: cap, candidate: cap)
            for d in allDiffs {
                let nameCol = d.laneName + String(repeating: " ",
                    count: max(0, 16 - d.laneName.count))
                let line = "  \(nameCol) \(String(format: "%.6f", d.baselineMean))\n"
                FileHandle.standardOutput.write(Data(line.utf8))
            }
        }
        // Run-to-run diff tables for each consecutive pair.
        for i in 0..<(captures.count - 1) {
            let (idx1, cap1) = captures[i]
            let (idx2, cap2) = captures[i + 1]
            let diffs = diffLaneCaptures(baseline: cap1, candidate: cap2)
            let preamble = "[lane-capture] run \(idx1) vs run \(idx2)\n"
            FileHandle.standardOutput.write(Data(preamble.utf8))
            let table = renderLaneDiffTable(
                baseline: cap1, candidate: cap2, diffs: diffs,
                label1: "run \(idx1)", label2: "run \(idx2)")
            FileHandle.standardOutput.write(Data(table.utf8))
        }
    }

    // Exit 1 on any drift so scripts and CI can detect non-determinism.
    // All output has already been printed by printReplayFieldTable before
    // this point, so exit(1) here does not truncate the report.
    if anyDrift {
        exit(1)
    }
}


/// `mcp-benchmarker refresh --cache-dir <dir> [--lane <substring>] [--parallel N]`
///
/// Re-settles every artifact in a fleet in place: restore, dream, basis
/// retrain, drain, snapshot back. The corpus is never re-ingested.
///
/// Use after a CALCULATION change — recall weights, fusion, distillation, basis
/// math — where the cached estates hold the right corpus computed by older
/// code. After a SCHEMA change the artifacts are the wrong shape and the
/// restore path's provenance check will hard-fail; that failure is the signal
/// to rebuild, and refresh deliberately does not paper over it.
///
/// Every estate is independent, so the work runs in parallel with one stdio
/// process per estate. The default width is the machine's core count because
/// the bound is CPU (encode and basis math), not I/O.
func runRefresh(_ args: [String]) async throws {
    guard let cacheDirRaw = optionValue("--cache-dir", in: args) else {
        throw MCPError(description: "refresh requires --cache-dir")
    }
    let cacheDir = URL(fileURLWithPath: cacheDirRaw)
    guard let mootBinary = optionValue("--mootx01-binary", in: args) else {
        throw MCPError(description: "refresh requires --mootx01-binary")
    }
    let lane = optionValue("--lane", in: args)
    let posture = try parseEstateMode(in: args)
    let width = optionValue("--parallel", in: args).flatMap(Int.init)
        ?? ProcessInfo.processInfo.activeProcessorCount

    let targets = try discoverRefreshTargets(cacheDir: cacheDir, runKeyFilter: lane)
    guard !targets.isEmpty else {
        throw MCPError(description:
            "refresh found no artifacts under \(cacheDir.path)"
            + (lane.map { " matching lane '\($0)'" } ?? "")
            + ". Build a fleet first (make artifacts).")
    }

    let fleets = Set(targets.map(\.runKey)).sorted()
    FileHandle.standardError.write(Data("""
        [refresh] \(targets.count) artifacts across \(fleets.count) fleet(s), parallel \(width)
        \(fleets.map { "[refresh]   \($0)" }.joined(separator: "\n"))

        """.utf8))

    // Failures are collected rather than thrown at the first one. A fleet
    // refresh is long; stopping on artifact 12 of 7,000 and discarding the
    // report of what else was wrong wastes the run twice.
    actor Tally {
        var done = 0
        var failures: [(String, String)] = []
        func succeed() -> Int { done += 1; return done }
        func fail(_ label: String, _ message: String) { failures.append((label, message)) }
        var snapshot: (Int, [(String, String)]) { (done, failures) }
    }
    let tally = Tally()

    await withTaskGroup(of: Void.self) { group in
        var index = 0
        var inFlight = 0
        while index < targets.count || inFlight > 0 {
            while inFlight < width, index < targets.count {
                let target = targets[index]
                index += 1
                inFlight += 1
                group.addTask {
                    do {
                        try await refreshOneArtifact(
                            target: target, mootBinaryPath: mootBinary, posture: posture)
                        let n = await tally.succeed()
                        if n % 25 == 0 || n == targets.count {
                            FileHandle.standardError.write(Data(
                                "[refresh] \(n)/\(targets.count) settled\n".utf8))
                        }
                    } catch {
                        await tally.fail(target.label, "\(error)")
                        FileHandle.standardError.write(Data(
                            "[refresh] FAILED \(target.label): \(error)\n".utf8))
                    }
                }
            }
            await group.next()
            inFlight -= 1
        }
    }

    let (done, failures) = await tally.snapshot
    FileHandle.standardError.write(Data("""

        [refresh] complete
          settled:  \(done)/\(targets.count)
          failed:   \(failures.count)

        """.utf8))
    if !failures.isEmpty {
        for (label, message) in failures.prefix(20) {
            FileHandle.standardError.write(Data("[refresh]   \(label): \(message)\n".utf8))
        }
        // A partially refreshed fleet is mixed-provenance: some estates carry
        // new derived state and some carry old. Measuring across it produces a
        // number nobody can attribute, which is the same failure --estate-cache
        // require exists to prevent. Exit non-zero so make stops.
        throw MCPError(description:
            "refresh left \(failures.count) artifact(s) unsettled; the fleet is mixed-provenance "
            + "and must not be measured until they succeed or are rebuilt")
    }
}
