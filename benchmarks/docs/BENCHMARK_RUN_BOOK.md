---
title: MOOTx01 Benchmark Run Book
release: "1.1"
version: v0.9
date: 2026-09-17
description: "Operator instructions for building benchmark artifacts, running retrieval measurements and judged protocols, and validating release candidates."
changelog:
  - version: v0.9
    date: 2026-09-17
    description: "§7.1: a bounded fleet build's unit-scale measurement excludes questions naming a unit the catalog does not carry, applying --limit after that filter; document the questions_in_file / questions_measured / questions_outside_catalog report fields."
  - version: v0.8
    date: 2026-09-17
    description: "Opens with a quick start: the commands to run one benchmark start to finish through make, with the configuration steps pointed at their sections. Configuration table: the fleet root comes from the storage config, the Rust binary from the work root."
  - version: v0.7
    date: 2026-09-17
    description: "Product line: setup/teardown own the work root; PRODUCT=1 runs the builder on the product binary through the seam and writes the binary stamp (FLEET_GATE=faker retired); proof-unit, LIMIT=/UNITS=, config, stash/restore, logs; release-qualification (§10) fires every ARIA tool once against a proven unit."
  - version: v0.6
    date: 2026-09-14
    description: "Add BUILDER_EXE and FLEET_GATE to the runtime configuration table; both gate the fleet lane and appeared only in section prose."
  - version: v0.5
    date: 2026-09-14
    description: "Fix residual smoke-fleet-* references: command scope rule, §3.3 sequence, §5.1 fleet gate requirement, §6.1 smoke-builder description, §11 stamp table. Distinguish faker (.smoke-ok-builder-faker-<port>) from binary (.smoke-ok-builder-binary-<port>) stamps; document FLEET_GATE=faker operator sequence."
  - version: v0.4
    date: 2026-09-14
    description: "Catalog layout (v0.8): FLEET_ROOT resolved from MOOTX01_BENCH_TARGET_MAP; fleet directory layout is catalog-based (estates/<unit>/ path is retired); smoke-fleet-* replaced by smoke-builder."
  - version: v0.3
    date: 2026-09-09
    description: "Remove stale adornment_minters table reference from payload-economics lane description (schema 19 dropped that table)."
  - version: v0.2
    date: 2026-09-09
    description: "Schema 19: replace adornment/mint coverage checks with span encoder coverage (checks 12-13); remove retired mint target and judge-join sections."
  - version: v0.1
    date: 2026-09-04
    description: "Initial run book."
---

# MOOTx01 Benchmark Run Book

Use this run book to prepare benchmark estates, confirm that they are ready, run retrieval measurements, run judged protocols, and validate release candidates.

Run every command from `benchmarks/`.

## Quick start

One benchmark, start to finish, on the Swift port. Every step is a `make`
command run from `benchmarks/`; the two configuration steps point at the
sections that explain them. The whole sequence takes a few hours on a fast
machine, most of it in step 5.

```bash
# 1. Build the work root from nothing: fetch the datasets, build both product
#    binaries and both benchmarkers, write the seed projections.
make setup

# 2. Complete the storage configuration (see section 2.1): make config writes
#    benchmark-config/storage.json beside the work root; edit it to name the
#    internal folder artifacts build in and the external volumes they move to.
make config

# 3. Prove the line on one estate: the assembly-line smoke, then the same
#    line on the product binary. Both stamp the gate the wide build requires.
make smoke-builder PORT=swift
make smoke-builder PORT=swift PRODUCT=1

# 4. Confirm the board: every dataset reports MISSING and nothing errors.
make status PORT=swift

# 5. Build the LoCoMo estates. Every unit is imported and settled by the
#    product; the catalog lands in the internal primary named in step 2.
make fleet-locomo PORT=swift

# 6. Run the measurement at smoke scale first (three questions), then the
#    measurement itself, both against the unit fleet step 5 built. Results
#    land in $BENCH_WORK_ROOT/results. Without SCALE=unit the measure opens
#    the Form-2 wing estate, which this sequence has not built.
make smoke-measure-locomo PORT=swift SCALE=unit
make measure-locomo PORT=swift SCALE=unit

# 7. Judged answers need a model (see section 2.2): set the answering and
#    judging commands in the environment, then run the protocol. Skip this
#    step for a retrieval-only result.
make measure-locomo-spec PORT=swift
```

Run the same sequence with `PORT=rust` for the Rust port. Replace `locomo`
with `lme-s`, `convomem` or `membench` for the other external datasets; the
order of steps does not change. `make artifacts PORT=…` builds every dataset
at once (step 5 for all four), and `make teardown` removes the work root when
you are done.

## 1. Operating model

The benchmark system has five parts:

1. **Seeds** generate the benchmark inputs.
2. **Artifacts** turn those inputs into Swift and Rust estates.
3. **Smoke gates** exercise each phase on a small specimen before a wide run is allowed.
4. **Measure** evaluates retrieval against pre-built artifacts.
5. **Judged protocols** evaluate answer quality, either with a live judge or through a deferred judging pass.

```text
seeds
  └── artifact smoke → artifact build
                           └── measure smoke → retrieval measurement
                                                   └── protocol smoke → judged run
                                                                          ├── inflight judging
                                                                          └── deferred judging → judge-batch
```

### 1.1 Datasets

The external dataset keys are `lme-s`, `locomo`, `convomem`, and `membench`. Their full names, publication origins, upstream corpus locations, fetch commands, and local fixture paths are maintained in [BENCHMARKS_USED.md](BENCHMARKS_USED.md#external-dataset-keys-and-provenance).

The internal dataset keys are `supersession`, `gauntlet`, `journey`, `timing`, `matrix`, `payload-economics`, `synthesis-payload`, and `deterministic-alternatives` — the MOOTx01-authored benchmarks, defined in [BENCHMARKS_USED.md](BENCHMARKS_USED.md#mootx01-authored-benchmarks). Six generate their source corpora deterministically during `make seeds`. The two payload keys, `payload-economics` and `synthesis-payload`, are MOOTx01-authored instruments over the frozen `lme-s` corpus and its Form-2 artifact. Section 9 defines their shared operating rules and the payload lanes' additional prerequisite.

The external storage projections follow the two filing rules in `BENCHMARK_ESTATES.md`.

Command scope rule: in the artifact-build and artifact-smoke commands (`fleet-*`, `wing-estate-*`, `smoke-wing-*`) `<ds>` is an EXTERNAL key; the wing commands also accept `complete`. `smoke-builder` takes no dataset. The judged-protocol commands (`measure-*-spec`, `smoke-spec-*`) take a PROTOCOL key — `lme`, `locomo`, `lmeb`, `convomem`, or `membench` (section 8 maps protocols to datasets). In `measure-<ds>`, `smoke-measure-<ds>`, and `smoke-bench-<ds>`, `<ds>` is ANY key, external or internal. No other command takes a dataset.

### 1.2 Target scales (external datasets)

Each EXTERNAL dataset can be measured at three scales. The questions and scoring remain the same; the scale determines which estate is opened. Internal datasets do not use scales; section 9 defines their options.

| Scale | Artifact shape | Location and behavior |
|---|---|---|
| `unit` | Form-1 estate-per-instance fleet; the official published protocol shape | Resolved from `catalog.json` at `$(FLEET_ROOT)/<port>/<ds>/catalog.json`; each set row names its base and path. `FLEET_ROOT` is the storage config's internal primary (section 2.1). |
| `bench-aggregate` | Form-2 one-estate-per-benchmark | `$(WING_ROOT)/<port>/<ds>/`. Datasets use separate wings where haystacks do not overlap. `lme-s` uses the deduplicated estate and runs unscoped. |
| `complete-aggregate` | One database containing every dataset | `$(WING_ROOT)/<port>/complete/` |

### 1.3 Smoke-gate rule

A smoke test sends a small specimen through the real phase machinery and checks the resulting artifact or receipt. A successful smoke test writes a `.smoke-ok-*` stamp under `seeding/`. Wide targets refuse to run until their required stamp exists.

For artifact-build smokes, a specimen that completes within the configured smoke window is retained as the real artifact. If the smoke window expires, the stopped probe is checked in bounded partial mode and then deleted because strict-append import cannot resume.

### 1.4 Swift and Rust ports

Every artifact and lane is available in both ports. Swift is primary. The Rust build of an artifact differs only in embedding-provider state.

Every build, smoke, and measure command takes the same `PORT` variable: `PORT=swift` (the default) or `PORT=rust`. The port selects the product binary, the benchmarker, and the port's artifact root; the command name never changes. Gate stamps carry the port, so each port gates independently. One exception: the judge-batch smoke and its stamp are shared across ports, because judge-input dumps are port-independent files (section 8.4).

## 2. Runtime configuration

### 2.1 Storage

`benchmark-config/storage.json`, beside the work root, names three folders:
`internal_primary` (every artifact is built in and served from it; the
default is the `benchmark-cache` peer of the repository), `external_storage_1`
and `external_storage_2` (finished datasets are moved out to the first with
room and restored from either with `make stash-artifacts` and
`make restore-artifacts`). `make config` writes the file with empty externals;
it survives `make teardown`.

### 2.2 Model commands

Judged lanes need an answering model and a judging model. Set
`MOOT_BENCH_ANSWER_CMD` and `MOOT_BENCH_JUDGE_CMD` in the environment before
running a `measure-<protocol>-spec` target. Retrieval measurements need
neither.

### 2.3 Variables

Override these variables on the `make` invocation when required.

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `swift` | Which port a command operates on: `swift` or `rust` |
| `MOOT_BINARY` | `$BENCH_WORK_ROOT/build/product-swift/release/mootx01` | Swift product binary under test (built by `make setup`) |
| `RUST_BIN` | `$BENCH_WORK_ROOT/build/product-rust/release/mootx01` | Rust product binary under test (built by `make setup`) |
| `FLEET_ROOT` | the storage config's `internal_primary` | Form-1 fleet root; catalog at `$(FLEET_ROOT)/<port>/<ds>/catalog.json`. Set `MOOTX01_BENCH_TARGET_MAP` in your shell dotfiles pointing at the machine-local target map JSON. |
| `WING_ROOT` | `./wing-store` | Form-2 estate root; layout is `$(WING_ROOT)/<port>/<ds>/` |
| `FLEET_JOBS` | 10 × performance cores | Number of fleet import workers. Use 20–30 when sharing the machine. |
| `PRODUCT` | unset | `PRODUCT=1` runs the artifact builder on the selected port's product binary through the seam (`seeding/mootx01_seam.py`); at defaults the faker runs and proves only the assembly line on synthetic data. Decides which stamp `smoke-builder` writes. `BUILDER_EXE` names the executable directly when neither fits. |
| `FLEET_GATE` | unset | Set to `faker` to let `.smoke-ok-builder-faker-<port>` satisfy the `fleet-*` gate for a pipeline-only run on synthetic data. The product gate is `make smoke-builder PRODUCT=1`. Pass it per command; do not export it. |
| `SMOKE_SECONDS` | per target | Smoke-build window. Each artifact smoke target carries a window sized to its dataset (`complete` carries `1200`; every other dataset carries `300`). Set `SMOKE_SECONDS` to override the target's window. |
| `SMOKE_MEASURE_Q` | `3` | Number of questions in measure and judged-protocol smoke runs |
| `SCALE` | `bench-aggregate` | Measurement scale: `unit`, `bench-aggregate`, or `complete-aggregate` |
| `TOPK` | `10` | Retrieval depth: the search result limit and the k of hit@k |
| `LIMIT` | `0` | Question cap for a measurement run; `0` runs every question |
| `DUMP` | unset | `DUMP=1` on a judged protocol defers judging to a judge-input dump |
| `DUMPS` | none | Dump directory consumed by `make judge-batch` |
| `RC_ROOT` | `/tmp/moot-validate-rc` | Scratch root used by the release-validation commands; wiped at the start of every run |
| `MOOT_BENCH_ANSWER_CMD` | unset | Answering-model command |
| `MOOT_BENCH_JUDGE_CMD` | unset | Judging-model command |

Set model commands through the environment, never as command-line flags. Command-line arguments are visible in `ps`.

## 3. Standard operating sequences

Choose the sequence that matches the work you need to perform.

### 3.1 Prepare a clean machine

Run these once on a machine that has never run the benchmarks:

```sh
make setup       # fetch, binaries, seeds: the work root from nothing
make config      # write the storage config into the config peer; fill in the two external volumes
make status      # confirm the board: everything reports MISSING, nothing errors
```

`make setup` runs `make fetch`, `make binaries` and `make seeds` in that
order into the external work root (`<repo-parent>/benchmark-work/<repo>`),
and `make teardown` empties and removes that root and the artifact cache.
Nothing in the work root is hand-made; a run after `make teardown setup`
is the reproducibility proof. Storage is `benchmark-config/storage.json`
beside the work root (it survives teardown) with three roles: the internal
primary every artifact is built in and served from, and two external stores
finished sets are stashed to and restored from (`make stash-artifacts` /
`make restore-artifacts DS= PORT=`). `make logs` zips every log the work
root holds into `benchmark-logs/logs-<stamp>.zip`.

`make fetch` runs each external dataset's fetch command from
[BENCHMARKS_USED.md](BENCHMARKS_USED.md#external-dataset-keys-and-provenance)
and verifies the fixture checksums. Six internal keys need no fetch because
`make seeds` generates their source corpora. The `payload-economics` and
`synthesis-payload` keys use the fetched `lme-s` corpus instead. After this
sequence, every build command in this run book is available; each wide build
still requires its smoke gate first.

### 3.2 Check whether artifacts are ready

```sh
make status
```

`make status` is the authoritative artifact health board. It reports one row for each dataset and tier, with one of four states:

- `READY`
- `BUILDING`
- `INCOMPLETE`
- `MISSING`

Readiness requires both artifact presence and complete encode coverage. The board also reports posture and format-drift flags.

### 3.3 Build all benchmark artifacts

Stamp the gates first, then build. All three commands honor the same
`PORT`; run the sequence once per port you need.

```sh
make smoke-builder [PORT=…]            # the assembly line on the faker; stamps .smoke-ok-builder-faker-<port>
make smoke-builder PRODUCT=1 [PORT=…]  # the same line on the product binary; stamps .smoke-ok-builder-binary-<port>
make smoke-wings  [PORT=…]             # stamps .smoke-ok-wing-<ds>-<port> for all five wing estates
make artifacts [PORT=…]                # seeds → fleets → wing estates
```

`make artifacts` refuses any build whose stamp is missing, so running it
directly reports exactly which smoke command is still owed. The fleet builds
run on the product binary through the seam (`PRODUCT=1`), which imports each
estate with the importer and settles it with the product finisher; a fleet
build accepts `LIMIT=N` (the first N units by sorted id) and `UNITS="a b"`
for a bounded build. `FLEET_GATE=faker` remains only for a pipeline-only run
on synthetic data.

### 3.4 Run one benchmark at smoke scale

```sh
make smoke-bench-<ds>
```

For an external dataset this runs, in order:

```text
build smoke → measure smoke → every mapped protocol smoke → judge-batch smoke
```

For an internal dataset it runs the measure smoke. The six corpus-generating
lanes build their own specimens. The two payload lanes use the selected port's
ready `lme-s` Form-2 artifact. The command finishes with one summary line.

To run the end-to-end smoke sequence for every dataset, external and internal:

```sh
make smoke-bench-all
```

The datasets run serially. Before this aggregate smoke, prepare the selected
port's `lme-s` Form-2 artifact for the two payload keys as specified in §9.

### 3.5 Run a measurement

External retrieval measurement takes a scale:

```sh
make measure-<external-ds> SCALE=<scale>
```

Use `unit`, `bench-aggregate`, or `complete-aggregate` for `<scale>`. The default is `bench-aggregate`.

Internal benchmarks take no scale:

```sh
make measure-<internal-ds>
```

The payload targets always use the selected port's `lme-s` Form-2 artifact;
that dependency is fixed and is not selected with `SCALE`.

### 3.6 Run an official judged protocol

Choose one judging mode for each run.

**Inflight judging** produces verdicts during the protocol run:

```sh
MOOT_BENCH_ANSWER_CMD="…" \
MOOT_BENCH_JUDGE_CMD="…" \
make measure-<protocol>-spec SCALE=<scale>
```

`<protocol>` is one of `lme`, `locomo`, `lmeb`, `convomem`, `membench` (section 8 maps protocols to datasets). The resulting report has a non-zero `judged_count`.

**Deferred judging** writes judge inputs during the protocol run and judges them later:

```sh
MOOT_BENCH_ANSWER_CMD="…" make measure-<protocol>-spec SCALE=<scale> DUMP=1
MOOT_BENCH_JUDGE_CMD="…" make judge-batch DUMPS=results/judge-dumps/<run-id>
```

The protocol run writes section-formatted judge-input JSONL and records `judged_count: 0`. The batch pass writes verdicts beside the dump and folds the final `judged_count` into the run report.

### 3.7 Validate release-candidate binaries

```sh
make validate-rc \
  MOOT_BINARY=/path/to/candidate \
  RUST_BIN=/path/to/candidate-rs
```

The release-validation commands always exercise BOTH ports in one run: they take the two binary variables and do not use `PORT`. Each run wipes and reuses the scratch root (`RC_ROOT`) to perform the following checks:

1. Both product binaries build the `locomo` wing estate from seed.
2. Both estates pass the full shape review.
3. Both benchmarkers measure through the MCP call.

Success produces one `VALIDATE-RC GREEN` verdict line.

To include the judged leg:

```sh
make validate-rc-full \
  MOOT_BINARY=/path/to/candidate \
  RUST_BIN=/path/to/candidate-rs
```

This adds the deferred-dump spec smoke and the judge-batch pass to `validate-rc`.

## 4. Generate seeds

```sh
make seeds
```

This deterministically regenerates every seed projection from the fixtures:

- per-unit files under `seeding/out-<ds>/units/`
- the Form-2 seed
- `questions.jsonl`
- the complete-aggregate seed

## 5. Build artifacts

Artifact import is strict-append and drain-gated. Each build fully converges its estate and writes `id-map.json` into the estate directory. The map records the seed record ID and its drawer UUID. Estates are built without a charter or identity.

Every build command is idempotent and convergent: on a fresh directory it imports from seed; on a partially encoded estate it resumes encoding to full coverage without re-importing; on a complete estate it verifies coverage and exits clean. Rerunning a build command is always safe and always ends at a converged artifact.

### 5.1 Build Form-1 fleets

| Command | Result |
|---|---|
| `make fleet-<ds> [PORT=…] [LIMIT=N] [UNITS="…"]` | Builds one dataset's fleet on the product binary for the selected port. Requires `.smoke-ok-builder-binary-<port>` (written by `make smoke-builder PRODUCT=1`); or `.smoke-ok-builder-faker-<port>` when `FLEET_GATE=faker` is passed. |
| `make proof-unit DS= PORT= UNIT=` | One unit through the whole product line into a scratch base under the work root; the proof before any real dataset build. |
| `make stash-artifacts DS= PORT= EXTERNAL=` / `make restore-artifacts …` | Move a built dataset out to an external base folder and back for a run. |
| `make fleets [PORT=…]` | Builds all four external fleets serially on the selected port. |

### 5.2 Build Form-2 estates

| Command | Result |
|---|---|
| `make wing-estate-<ds> [PORT=…]` | Builds one estate on the selected port. Accepted values are `locomo`, `convomem`, `membench`, `lme-s`, and `complete`. Requires `.smoke-ok-wing-<ds>-<port>`. |
| `make wing-estates [PORT=…]` | Builds all five estates serially on the selected port. Use `-j5` to overlap them. |

## 6. Run artifact-build smoke gates

Each build smoke test:

1. Prints the eleven-point shape checklist.
2. Builds the specimen through the stock build recipe.
3. Stops the build at `SMOKE_SECONDS` if it is still running.
4. Compares the result with exact values derived from the seed.
5. Writes the gate stamp only when every check passes.

The thirteen checks are:

1. Drawer count equals the seed record count.
2. There are no charter sentinel IDs.
3. `kg_facts` equals the seed fact count.
4. Tunnel count equals the seed tunnel count.
5. Encode coverage is complete.
6. Room distribution matches the projection.
7. Wing distribution matches the projection.
8. Subject wrappers are verbatim in the samples.
9. Posture is plaintext.
10. The estate format is current.
11. No federation identity was minted.
12. Exactly one active encoder is registered in `encoder_models`.
13. Span coverage equals eligible drawers (bounded in probe mode).

### 6.1 Artifact smoke commands

| Command | Specimen exercised |
|---|---|
| `make smoke-wing-<ds> [PORT=…]` | The Form-2 build on the selected port |
| `make smoke-builder [PORT=…] [PRODUCT=1]` | Assembly-line smoke for the Form-1 builder. Writes `.smoke-ok-builder-faker-<port>` at defaults (pipeline on synthetic data; product binary not exercised) or `.smoke-ok-builder-binary-<port>` with `PRODUCT=1` (the product binary through the seam). Replaces the retired `smoke-fleet-<ds>` commands. |
| `make smoke-wings [PORT=…]` | Every dataset's wing smoke on the selected port, serially |
| `make smoke-fleets [PORT=…]` | Delegates to `make smoke-builder` |

## 7. Measure retrieval (external datasets)

This section covers the four external datasets. Internal datasets are measured with the same `measure-<ds>` command but their own metrics and options; section 9 defines them.

The retrieval lane is named `artifact-recall`. It is read-only against a pre-built artifact and calls only `moot_memory_search`. It reports hit@k and MRR, along with:

- the run configuration
- a per-label breakdown
- an inspectable list of misses

### 7.1 Measurement command

```sh
make measure-<ds> [PORT=…] [SCALE=…] [TOPK=10] [LIMIT=0]
```

The port selects which port's artifacts are opened and which benchmarker measures them. Scale behavior is as follows:

| Scale | Behavior |
|---|---|
| `unit` | Iterates the fleet's per-instance estates, with questions grouped by unit. |
| `bench-aggregate` | Opens the Form-2 estate once per run; every query reuses that frozen server, so the estate's cold load is paid once. Runs wing-scoped where wings exist and unscoped for `lme-s`. |
| `complete-aggregate` | Opens the complete estate and uses dataset-prefixed ground truth. |

The report is written under `results/`.

At `unit` scale, a bounded fleet build (`make fleet-<ds> LIMIT=N` / `UNITS=…`) may hold fewer units than the dataset has; a question naming a unit the catalog does not carry is excluded before `--limit` is applied rather than failing the run, and the report's `questions_in_file`, `questions_measured`, and `questions_outside_catalog` fields record, respectively, how many questions the file held, how many were actually measured, and how many were outside the catalog.

To measure all four external datasets at one scale, serially:

```sh
make measure-external [PORT=…] SCALE=<scale>
```

### 7.2 Measure smoke tests

```sh
make smoke-measure-<ds> [PORT=…]
```

This sends `SMOKE_MEASURE_Q` questions through the real retrieval lane on the selected port and then checks the receipt. The review confirms that:

- every question produced a call and return;
- every required report field is present; and
- every returned ID resolves through `id-map.json`.

The smoke test checks the measurement mechanism, not the scores. Success writes `.smoke-ok-measure-<ds>-<port>`.

Additional measure-smoke commands:

| Command | Purpose |
|---|---|
| `make smoke-measure-complete-locomo [PORT=…]` | Runs the measure smoke against the complete estate with `locomo` questions and dataset-prefixed ground truth. |
| `make smoke-measures [PORT=…]` | Runs every measure smoke on the selected port, serially. |

### 7.3 Compare per-instance and one-database retrieval

Run the same target twice, then compare the two reports:

```sh
make measure-locomo SCALE=unit
make measure-locomo SCALE=complete-aggregate
```

## 8. Run judged protocols

The five official protocols measure answer quality on top of retrieval:

- `lme-spec`
- `locomo-spec`
- `lmeb-spec`
- `convomem-spec`
- `membench-spec`

Each spec runner opens pre-built artifacts through the same estate seam used by the measure lane. Per-instance protocols use the fleet with `SCALE=unit`, which is their default.

### 8.1 Protocol commands

The five protocols map to five literal target pairs:

| Protocol | Dataset measured | Measurement command | Smoke command |
|---|---|---|---|
| LongMemEval judged QA | `lme-s` | `make measure-lme-spec` | `make smoke-spec-lme` |
| LoCoMo judged QA | `locomo` | `make measure-locomo-spec` | `make smoke-spec-locomo` |
| LMEB retrieval grid | `convomem` | `make measure-lmeb-spec` | `make smoke-spec-lmeb` |
| ConvoMem judged QA | `convomem` | `make measure-convomem-spec` | `make smoke-spec-convomem` |
| MemBench judged protocol | `membench` | `make measure-membench-spec` | `make smoke-spec-membench` |

**ConvoMem judged prerequisite — answer enrichment.** The LMEB export (KaLM-Embedding/LMEB on HuggingFace) carries only `id` and `text` per query; the `answer` field is absent, so the harness skips the judge step and every convomem-spec record scores 0 on `judged_count`. Before running `make measure-convomem-spec`, enrich the fixture store with `benchmarks/scripts/enrich-convomem-answers.py` (set `BENCH_WORK_ROOT` to the run's work root). The script downloads the Salesforce/ConvoMem dataset from HuggingFace into `$BENCH_WORK_ROOT/fixtures/convomem-qa/` (idempotent), matches each LMEB query by question text to its ConvoMem gold answer across all six evidence types, backs up the original `queries.jsonl` as `queries.lmeb-original.jsonl`, and writes the enriched file in place. The script exits non-zero if any query is unmatched and prints per-type matched/unmatched counts to stdout.

Every protocol command takes the same options:

```sh
make measure-<protocol>-spec [PORT=…] [SCALE=…] [DUMP=1]
```

Attach the answering model with `MOOT_BENCH_ANSWER_CMD`. Then choose one judging mode:

| Mode | Configuration | Result |
|---|---|---|
| Inflight | Set `MOOT_BENCH_JUDGE_CMD`. | Verdicts are produced during the run and the report has a non-zero `judged_count`. |
| Deferred | Pass `DUMP=1`. | Judge-input JSONL is written to `results/judge-dumps/<run-id>/` in the protocol's section format. The initial report records `judged_count: 0`. |

### 8.2 Complete deferred judging

```sh
MOOT_BENCH_JUDGE_CMD="…" make judge-batch DUMPS=results/judge-dumps/<run-id>
```

`judge-batch` consumes the dump directory, writes verdicts beside the dump, and updates the run report with the resulting `judged_count`.

### 8.3 Smoke the judged-protocol lane

```sh
make smoke-spec-<protocol> [PORT=…]
```

This runs `SMOKE_MEASURE_Q` questions through the real spec lane on the selected port against the smoke specimen with `DUMP=1`. It then checks the JSONL structure and report counts. No judge model is required because this smoke test covers the benchmark and deferred-dump phase. Success writes `.smoke-ok-spec-<protocol>-<port>`.

### 8.4 Smoke deferred judging

```sh
make smoke-judge-batch
```

The judge-batch gate is shared across ports: dumps are port-independent files, so one stamp covers both ports. This runs `judge-batch` against the small dump created by `smoke-spec-<protocol>`.

- With `MOOT_BENCH_JUDGE_CMD` set, the receipt must show that real verdict rows were written and folded into the report.
- Without `MOOT_BENCH_JUDGE_CMD`, the receipt must show that the dump was consumed and the judge-absent state was reported.

Success writes `.smoke-ok-judge-batch`.

### 8.5 Smoke inflight judging

```sh
MOOT_BENCH_JUDGE_CMD="…" make smoke-spec-<protocol>-inflight [PORT=…]
```

This runs the same smoke vehicle with a live judge. The receipt must report:

```text
judged_count == SMOKE_MEASURE_Q
```

If `MOOT_BENCH_JUDGE_CMD` is unset, the command stops with a clear message. It does not substitute a stub judge.

### 8.6 Run the offline answer step (convomem-spec and membench-spec)

`convomem-spec` and `membench-spec` support a three-phase offline workflow:

1. Dump answer inputs during the retrieval run (`--dump-answer-inputs`).
2. Answer offline with `answer-batch` (this section).
3. Score and report with `--consume-answers`.

This step sits between the dump and the judge. It fills in model answers without requiring a live estate or the mootx01 binary.

```sh
make answer-batch \
    INPUTS=results/answer-dumps/<run-id>/answer-inputs.jsonl \
    ANSWER_CMD="claude -p --model claude-sonnet-4-6" \
    OUT=results/answer-dumps/<run-id>/answered.jsonl
```

Or call the binary directly:

```sh
mcp-benchmarker answer-batch \
    --inputs results/answer-dumps/<run-id>/answer-inputs.jsonl \
    --answer-cmd "claude -p --model claude-sonnet-4-6" \
    --out results/answer-dumps/<run-id>/answered.jsonl \
    [--limit N]
```

The command reads the header record and dispatches on its `benchmark` field:

| `benchmark` | Input record type | Output format |
|---|---|---|
| `convomem-spec` | `answer_input` records from `--dump-answer-inputs` | `judge_ready` lines (feed to `convomem-spec --consume-answers`) |
| `membench-spec` | `qa` records from `--dump-answer-inputs` | `{"item_id":…,"answer":"<letter>","raw":…}` lines (feed to `--consume-answers`) |

Per-record failures are written as `{"item_id":…,"answer":null,"error":…}` and counted. The command exits non-zero only when every record fails.

After answering, feed the output to the appropriate consume path:

- **convomem-spec**: re-run the spec lane with `--consume-answers answered.jsonl --judge-cmd <cmd>`. Each line is judged with the §B2 prompt the inline run builds; the §B4 aggregate is the record.
- **membench-spec**: re-run the spec lane with `--consume-answers answered.jsonl`.


### 8.7 LoCoMo offline reader and token-F1 flow

LoCoMo can record frozen retrieval once, run any answering model later, and
score its answers mechanically with the official token-F1 procedure. No judge
model or live estate participates in the answer step.

```sh
mcp-benchmarker locomo-spec --data-file <fixtures>/locomo/locomo10.json \
  --target-scale unit --fleet-dir <fleet>/locomo/estates \
  --hydration-tier distilled --answer-hydration-depth 10 \
  --dump-answer-inputs <dumps>/locomo/answer-inputs.jsonl \
  --mootx01-binary <path> --run-id <id> --out <results>

mcp-benchmarker answer-batch \
  --inputs <dumps>/locomo/answer-inputs.jsonl \
  --answer-cmd <reader-cmd> \
  --reader-model <stable-model-id> \
  --out <answers>/locomo.<reader-id>.jsonl \
  [--offset N] [--limit N]
```

Every row after the header must be a complete `answer_input` row; blank rows
are malformed input rather than silently skipped. Malformed JSON, a wrong
record kind, a duplicate `question_id`, a missing required field, a
non-parallel memory/drawer list, invalid one-based `retrieved_ranks`, or an
offset/limit selecting zero rows stops before the reader runs. The score
header records `input_row_count`, `selected_input_count`, and
`selected_input_sha256`; these identify the exact restart shard.
Reader-command failures remain explicit zero-score rows and are counted in
`failures`. Score files are created owner-only and never overwritten; re-running
with the same output path resumes from the progress file rather than requiring
a new path.

**Progress file and resume.** The reader writes each scored row to
`<out>.partial.jsonl` (mode 0600, sorted keys, same JSON shape as the final
rows) immediately after every reader call and syncs the file to disk. If the
process is killed mid-run, re-invoking with the same arguments resumes: rows
whose `question_id` appears in the progress file and in the current selected
set are reused without calling the reader again; rows outside the selected set
are ignored; a malformed progress-file line is a hard error. The final file is
assembled in input order regardless of resume, so the row bytes are
byte-identical to a clean run given the same reader answers. The score header
gains two additive fields: `resumed_row_count` (0 on a clean run) and
`progress_file` (path, for provenance). The progress file is removed once the
final file is written successfully. One stderr line per row reports progress:
`[locomo answer-batch] <done>/<selected> <question_id>`.

The answer-input rows preserve `retrieved_drawer_ids`, `retrieved_dia_ids`, and
the original one-based retrieval rank of every hydrated hit. This permits
presentation-only experiments over the same sealed retrieval result without
rerunning search. The output contains per-question scores, per-category means,
and `overall_token_f1`; it is already the scored result and has no judge-batch
phase.

### 8.8 lme-spec reader flow

The same three phases as 8.6, for `lme-spec`. Dump the answer inputs during the frozen retrieval run,
answer offline, then grade with the judge script.

```sh
mcp-benchmarker lme-spec --data-dir <fixtures>/longmemeval/data --variant s --target-scale unit \
  --fleet-dir <fleet>/lme-s/estates --hydration-tier distilled \
  --dump-answer-inputs <dumps>/lme/answer-inputs.jsonl --mootx01-binary <path> --run-id <id> --out <dir>

mcp-benchmarker answer-batch --inputs <dumps>/lme/answer-inputs.jsonl \
  --answer-cmd <reader-cmd> --out <answers>/lme.jsonl

python3 scripts/judge-sessions.py --inputs <answers>/lme.jsonl \
  --judge-id <judge-id> --judge-cmd <judge-cmd> --out <judged>/lme --batch-size 10
```

The `answer_input` lines carry `question_id`, `question`, `correct_answer`, `memory_texts`,
`retrieved_drawer_ids`, and `hypothesis_digest`; `answer-batch` writes `judge_ready` lines with the
reader's `hypothesis` and the per-type `anscheck_prompt` the judge script reads unchanged.


Every spec lane (`lmeb-spec`, `locomo-spec`, `membench-spec`) takes `--scoring raw|rrf|matrixAware|discriminative`, passed to `moot_memory_search` as the scoring strategy and recorded in the report as `scoring`; omitted, the call is unchanged and the report says `default`.

`membench-spec` accepts `--seed-units-dir <path>` to enable a third id-map derivation path. When `id-map.json` is absent and `sourceFile`/`chunkIndex` reconstruction yields no rows (as happens on JSON-import-lane estates), the runner loads `<path>/<estateName>.json`, computes the FNV-1a-128 hash of each seed record `id`, and matches against `drawers.lineageID` to recover the seed-id to drawer-UUID map. Omit the flag when the estate was seeded via the standard LoCoMo lane; include it when the estate was built via the JSON import lane and no `id-map.json` was written.
### 8.9 Apple Foundation Models as the reader

`mcp-benchmarker apple-answer` satisfies the answer-cmd contract (prompt on stdin, answer text on stdout, exit 0). Pass `scripts/apple-reader.sh` as `--answer-cmd` to feed the OS-resident on-device model into any answer-batch run:

```sh
mcp-benchmarker answer-batch \
  --inputs answer-inputs.<arm>.jsonl \
  --answer-cmd scripts/apple-reader.sh \
  --out answers/lme.apple-fm-p1-s1.jsonl
```

The subcommand requires macOS 26 with Apple Intelligence enabled. Set the record's `answer_model` field to `apple-fm-p1-s1` (the engine's recipe id) so the run record correctly identifies it beside the 27B and frontier readers. `--max-tokens` caps the response (default 512); lower values reduce generation time without affecting retrieval quality.

#### Reader flow modes (chunked payloads)

Apple Foundation Models has an 8 192-token context window; a 10-hit lme-spec retrieval payload is ~23 k tokens and is refused by the engine. Pass `--mode map-reduce` or `--mode refine` to select a reader recipe: both modes split the memory texts on numbered-record boundaries so each round fits inside `--round-budget` (default 6 000) input tokens, and emit a one-line summary on stderr (`apple-answer: mode=<m> rounds=<n> chunks=<c> max_round_tokens=<t>`). Map-reduce collects one note per chunk then combines the notes into the answer; refine builds an iterative draft, updating it with each successive chunk; single (the default) sends the full prompt in one call and exits non-zero with the engine's error text when the payload exceeds `--context-tokens`. Set `APPLE_READER_MODE`, `APPLE_READER_ROUND_BUDGET`, and `APPLE_READER_NOTE_CAP` in the environment and `scripts/apple-reader.sh` forwards them as flags automatically.

Pass `--mode pick --pick-k N` (default 3) to run a two-round picker: round 1 sends the question and a one-line candidate list of all records (UUID header plus adornments, when present) to select the N most relevant records by index; round 2 sends the picked records' full distilled bodies to produce the final answer, dropping picks from the tail if the round-2 prompt would exceed `--round-budget`. Pass `--guided` with any mode to request a structured answer (`{answer, evidence_ids, abstain}`): stdout still prints only the answer text (or "I don't know." when the model abstains), and the stderr summary line gains `guided=1 evidence=<n> abstain=<0|1>`; set `APPLE_READER_GUIDED=1` and `APPLE_READER_PICK_K=N` in the environment to activate these flags via `scripts/apple-reader.sh`.

### 8.10 OMLX adapter knobs

`judges/omlx-judge.sh` drives any OpenAI-compatible local server. These
environment variables tune the adapter:

| Variable | Default | Meaning |
|---|---|---|
| `OMLX_MODEL` | *(required)* | Model id as the server names it. |
| `OMLX_PORT` | `8000` | Server port. |
| `OMLX_HOST` | `localhost` | Server host — set when the server runs on a different machine. |
| `OMLX_MAX_TOKENS` | `1024` | Completion token cap. Reduce for verdict-only prompts; raise for long-form judging. |
| `OMLX_THINKING` | `on` | `off` disables chain-of-thought reasoning output (passes `enable_thinking: false` in `chat_template_kwargs`). Servers that ignore `chat_template_kwargs` still honour the token cap. |

## 9. Internal benchmarks

The eight MOOTx01-authored benchmarks share one command namespace but have two
source contracts:

- `supersession`, `gauntlet`, `journey`, `timing`, `matrix`, and
  `deterministic-alternatives` generate their source corpora deterministically
  during `make seeds` and build their own estate shape inside the lane.
- `payload-economics` and `synthesis-payload` are MOOTx01-authored instruments
  over the frozen `lme-s` questions, gold answers, and `has_answer` turn
  annotations. They reuse the selected port's ready `lme-s` Form-2 artifact.
  They do not generate a separate source corpus or build a separate estate.

The payload lanes therefore require the LongMemEval fetch, seed projection,
and selected port's `lme-s` wing estate before their smoke or wide measurement
targets run:

```sh
make fetch
make seeds
make smoke-wing-lme-s PORT=<port>
make wing-estate-lme-s PORT=<port>
```

The word "internal" identifies ownership of the instrument, not ownership of
its source corpus.

For every internal key, `make smoke-measure-<ds> [PORT=…]` runs the real lane
on a bounded specimen and reviews the receipt. The corpus-generating lanes
build that specimen from their generated source. The payload lanes run their
bounded question set against the ready `lme-s` Form-2 artifact. Success writes
`.smoke-ok-measure-<ds>-<port>`.

`make measure-<ds> [PORT=…]` runs the lane wide and requires its measure smoke
stamp. The corpus-generating lanes build, resume, or reuse their own estates.
The payload lanes reuse the ready `lme-s` Form-2 artifact without changing its
contents. Reports land under `results/` with the same naming as the external
lanes.

The two payload lanes accept `ACTIVATION_ARM=<spec>` (the `--activation-arm`
flag on `payload-economics`, both ports). The spec is `naked` for zero active
minters, one minter id, or a comma-separated list of minter ids for exactly
that set. With the flag set, the lane clones the artifact copy-on-write to
`<work root>/scratch/payload-arm/<estate>-arm-<slug>`, activates exactly the
named set on the clone, serves the clone frozen, and removes the clone after
the serve exits. The artifact's own bytes never change. Every named id must
be registered in the artifact's minter table; an unknown id or a
schema-19 artifact with no registered minters stops the run with no report written.
Without the flag the lane serves the artifact in place with whatever set it holds.

Every payload report records the arm beside `shape_mapping`: `activation_arm`
(the spec, or `null` when the artifact was served in place), `active_minters`
(the ids read back from the served database after activation), `arm_scratch_used`
(`true` when a clone was served), and `artifact_digest` (SHA-256 of the
artifact's `estate.sqlite`).

```sh
make measure-payload-economics PORT=swift ACTIVATION_ARM=naked
make measure-payload-economics PORT=swift ACTIVATION_ARM=apple-mint
make measure-synthesis-payload PORT=rust ACTIVATION_ARM=apple-mint,candle-mint
```

External Form-1/Form-2 artifact commands do not apply to the six
corpus-generating internal lanes. The two payload lanes have a fixed Form-2
`lme-s` dependency. No internal target accepts `SCALE` or `TOPK`; every
internal lane accepts `PORT` and `LIMIT`. Each lane's metrics and any
lane-specific options are defined in its definition under `benchmarks/`.

The internal keys and what each benchmark measures:

| Key | Measures |
|---|---|
| `supersession` | Correction and supersession behavior over evolving facts |
| `gauntlet` | Generated multi-hop recall over a controlled corpus |
| `journey` | Estate lifecycle behavior across capture, dreaming, and recall |
| `timing` | Operation latency and throughput on a quiet machine |
| `matrix` | Storage-posture combinations (encryption, backend, shape) |
| `payload-economics` | Result-payload size against retrieval effectiveness |
| `synthesis-payload` | Synthesis output shape and cost |
| `deterministic-alternatives` | Deterministic engine alternatives against model-backed ones |

For each payload arm, the report always carries `mean_tokens` and
`answer_presence_rate`. `answer_presence_rate` is the fraction of questions
whose rendered payload contains the question's gold answer under normalized
substring matching. When mean tokens are nonzero, the report also carries
`answer_presence_per_1k_tokens`. Retrieval arms additionally carry `hit_at_k`
and `mrr` through the artifact ID-map fold; the synthesis arm does not.

`evidence_hit_rate` is computed over questions carrying `has_answer` evidence
annotations, and `evidence_hits_per_1k_tokens` scales that rate by mean tokens.
The release `lme-s` corpus carries these annotations, so a full-coverage
release report must contain both fields. A bounded slice containing no
annotated question may omit them; the report's `no_evidence` count records that
condition, and omission means unavailable, never zero.

Internal benchmarks have no judged protocols; their scoring is mechanical and
deterministic. Readiness comes from the lane's own estate for the six
corpus-generating keys and from the `lme-s` Form-2 row for the two payload keys.
The smoke-gate rule, `PORT` rule, and result naming apply to all eight.

## 10. Release and end-to-end validation commands

| Command | Purpose |
|---|---|
| `make release-qualification PORT=…` | The final pass before a version goes quiet: setup verified, the faker smoke, the product smoke, one real unit through the whole line, then every ARIA tool fired once against a clone of that unit with each outcome pinned (`benchmarks/qualification/RELEASE_QUALIFICATION.md`). |
| `make validate-rc` | Builds and reviews the Swift and Rust `locomo` wing estates on `RC_ROOT`, then measures through the MCP call. |
| `make validate-rc-full` | Runs `validate-rc`, the deferred-dump spec smoke, and the judge-batch pass. |
| `make smoke-bench-<ds>` | Runs one external dataset through build smoke, measure smoke, every protocol smoke mapped to it, and the judge-batch smoke; runs one internal dataset through its measure smoke. A payload-key smoke requires the selected port's `lme-s` Form-2 artifact. |
| `make smoke-bench-all` | Runs the end-to-end smoke for every dataset, external and internal, serially. The selected port's `lme-s` Form-2 artifact must already be ready for the two payload keys. |

## 11. Evidence and output locations

| Path | Contents |
|---|---|
| `seeding/.smoke-ok-wing-<ds>-<port>` | Wing artifact-build gate stamps (written by `smoke-wing-<ds>`) |
| `seeding/.smoke-ok-builder-faker-<port>` | Builder assembly-line gate stamp (faker; pipeline only) |
| `seeding/.smoke-ok-builder-binary-<port>` | Builder binary gate stamp (product binary exercised) |
| `seeding/.smoke-ok-measure-<ds>-<port>` | Retrieval-measure gate stamps |
| `seeding/.smoke-ok-spec-<protocol>-<port>` | Judged-protocol gate stamps |
| `seeding/.smoke-ok-judge-batch` | Deferred-judging gate stamp |
| `seeding/smoke-*.log` | Smoke logs |
| `seeding/smoke-measure-<ds>.json` | Measure-smoke receipts |
| `<estate dir>/id-map.json` | Seed-record-ID to drawer-UUID map written during the build |
| `results/` | Measurement reports, named by test, arm, and serial |
| `results/judge-dumps/<run-id>/` | Deferred judge-input dumps and verdicts |
| `qualification/<port>-<stamp>/report.json` | Release-qualification catalog report: one row per tool call, outcome, latency, reply digest |

## 12. Operator decision guide

| Situation | Action |
|---|---|
| You need the current readiness state. | Run `make status`. |
| A wide build refuses to start because its gate is missing. | Run the corresponding `make smoke-*` target, then rerun the wide build after the smoke passes. |
| An estate is only partially encoded. | Rerun its build command; builds resume to full coverage without re-importing. |
| You need retrieval scores only. | Run `make measure-<ds>` at the required `SCALE`. |
| You need answer-quality results and a judge is available now. | Set both model commands and use inflight judging. |
| You need answer-quality results but judging will happen later. | Run the spec with `DUMP=1`, then run `judge-batch` against the resulting dump directory. |
| You need to confirm the mechanism without asserting score quality. | Run the applicable smoke target and review its receipt. |
| You need to compare official per-instance storage with one complete database. | Measure once with `SCALE=unit`, once with `SCALE=complete-aggregate`, and compare the reports. |
| You need to validate candidate Swift and Rust binaries. | Pass their paths to `make validate-rc` or `make validate-rc-full`. |

## 13. Command examples

```sh
# Report current artifact readiness.
make status

# Gate and build one Form-2 estate, each port.
make smoke-wing-convomem
make wing-estate-convomem
make smoke-wing-convomem PORT=rust
make wing-estate-convomem PORT=rust

# Smoke one benchmark end to end.
make smoke-bench-locomo

# Run an internal benchmark.
make smoke-measure-gauntlet
make measure-gauntlet

# Run the official per-instance retrieval shape.
make measure-locomo SCALE=unit

# Compare the per-instance and complete-database scales.
make measure-locomo SCALE=unit
make measure-locomo SCALE=complete-aggregate

# Run the official protocol with deferred judging, then judge the dump.
MOOT_BENCH_ANSWER_CMD="…" make measure-locomo-spec DUMP=1
MOOT_BENCH_JUDGE_CMD="…" make judge-batch DUMPS=results/judge-dumps/<run-id>

# Validate release-candidate binaries end to end.
make validate-rc MOOT_BINARY=/path/to/candidate RUST_BIN=/path/to/candidate-rs
make validate-rc-full MOOT_BINARY=/path/to/candidate RUST_BIN=/path/to/candidate-rs
```
