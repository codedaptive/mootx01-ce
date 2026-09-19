# benchmarks/Makefile — the estate ARTIFACT BUILDER (B1/B8, benchmark reset
# 2026-08-13).
#
# Test estates are build artifacts, not a cache (BENCHMARK_BUILD_ARCHITECTURE
# §1): a settled estate is a deterministic function of its declared inputs, so
# it is built ONCE here and reused by every measurement run until an input
# changes. Each artifact carries a provenance manifest (artifact.json, B2)
# validated hard on open; the cache key carries no binary fingerprint (B3);
# snapshots are taken after dream + basis retrain (B4); restores are APFS
# clones (B5).
#
# The split this Makefile enforces (M8): BUILDING needs no quiet machine —
# run `make -j$(JOBS) artifacts` on a busy box, walk away. MEASURING
# (`make measure-…`) restores artifacts under --estate-cache require, which
# HARD-FAILS on any missing artifact (B7) so a leg can never silently mix
# built-fresh and restored units.
#
# B8 SAFETY: this Makefile does not invoke `mootx01` query paths directly —
# `mootx01 query` routes to the resident daemon when one is running and would
# write into the user's LIVE estate (finding H23). Targets go through the
# harness binaries, whose lanes pin the stdio transport with an asserted
# scratch `--db /tmp/...` (a transient catalog record) before any write. The
# one exception is `backfill-staging`, which invokes the product binary
# directly (serve-open + upgrade --backfill-only) but passes `--db <dir>` for
# each staged estate on every invocation — the same containment the harness
# lanes assert, and no resident routing is involved because a transient record
# is never the resident's.
#
# D4 NOTE (keychain): artifact builds run PLAINTEXT scratch estates
# (--estate-mode unencrypted is the default; a transient record is plaintext
# by the product's rule) and encrypted scratch estates use a temporal
# in-process key — NEITHER touches the login keychain, so `make clean` has no
# keychain ledger to tear down. A target that mints named encrypted
# estates (mootx01 db create) MUST record every minted keychain item and echo
# loudly that the keychain stays polluted until `make clean` removes them.
#
# Measurement targets drive the SWIFT harness only: Swift is the primary
# port and the measurement instrument; the Rust twin exists for parity
# conformance, not measurement. `rust-harness` builds it for test runs.
#
# Parallelism: lane targets are independent — `make -j$(JOBS) artifacts`
# builds them concurrently. JOBS defaults to ~80% of the machine's cores
# (BENCHMARK_BUILD_ARCHITECTURE §1). Units inside one lane run serially.

# ── Configuration ────────────────────────────────────────────────────────────

# The checked-out repository is immutable input. Every mutable byte produced
# by this Makefile lives under BENCH_WORK_ROOT: compiler products, dependency
# caches, downloaded corpora, seed projections, estates, smoke receipts, logs,
# raw reports, and temporary bundles. scripts/work-root.py resolves symlinks,
# rejects roots inside (or containing) the repository, and marks the exact
# directory that `make clean` is allowed to empty.
#
# ADOPTION RULE: `prepare` creates a missing work root and marks it, and
# accepts an existing directory only when it is EMPTY or already carries the
# marker file. An existing nonempty directory without the marker is refused,
# because prepare runs while make parses this file — for `make clean` too —
# and a marker it wrote itself would be the only thing standing between
# `make clean BENCH_WORK_ROOT=<some real directory>` and that directory's
# contents. Pointing the harness at a shared directory therefore takes a
# deliberate step: empty it, or create the marker there yourself.
REPO_ROOT := $(abspath $(CURDIR)/..)
# The work root defaults to a VISIBLE peer of the repository —
# <repo-parent>/benchmark-work/<repo-name> — never a hidden directory and
# never <repo-parent>/benchmark-cache, which holds only the benchmark
# artifact databases and nothing the harness generates — and
# never a system cache location: hidden paths conceal gigabytes from a
# human auditing disk use, and macOS treats ~/Library/Caches as purgeable,
# which can evaporate generated estates mid-run.
# The peer is measured from the REPOSITORY root, which is not always the
# parent of this directory: an authoring checkout may keep the harness
# further down its tree, and anchoring on the parent there would put the
# "peer" inside the repository, which work-root.py rejects. Ask the version
# control system, which knows the real root wherever the harness sits.
#
# The fallback is not a degraded mode. Source archives and verification
# scaffolds are built without a .git directory on purpose, and in those the
# harness IS a direct child of the tree root — so the parent is the right
# answer exactly when the query returns nothing.
#
# PARSE-TIME SHELL GUARD. `$(shell …)` runs through /bin/sh while make reads
# this file — before any target, and before work-root.py can validate
# anything. The two path values interpolated into those commands (CURDIR,
# and the operator-supplied work root) are single-quoted inside them, and a
# single quote in the value would end that quoting; a space would also
# split the value where recipes below pass it unquoted. So a value carrying
# whitespace, a quote, or a shell metacharacter stops make here with a
# clear message instead of reaching the shell. GNU make only ($(foreach),
# $(findstring), $(error)), like the rest of this file. `$$` is a literal
# dollar and `\#` a literal hash in a make assignment.
SHELL_UNSAFE_CHARS := ' " ` $$ ; & | ( ) < > * ? ! \# ~ [ ] { }
define shell-unsafe
$(strip $(if $(word 2,$(1)),whitespace,)$(findstring \,$(1))$(foreach c,$(SHELL_UNSAFE_CHARS),$(findstring $(c),$(1))))
endef
ifneq ($(call shell-unsafe,$(CURDIR)),)
  $(error CURDIR contains whitespace, a quote, or a shell metacharacter and cannot be passed to $$(shell): "$(CURDIR)" — move the checkout to a plain path)
endif
WORK_ANCHOR := $(or $(shell git -C '$(CURDIR)' rev-parse --show-toplevel 2>/dev/null),$(REPO_ROOT))
REQUESTED_BENCH_WORK_ROOT ?= $(abspath $(WORK_ANCHOR)/..)/benchmark-work/$(notdir $(WORK_ANCHOR))
BENCH_WORK_ROOT ?= $(REQUESTED_BENCH_WORK_ROOT)
ifneq ($(call shell-unsafe,$(BENCH_WORK_ROOT)),)
  $(error BENCH_WORK_ROOT contains whitespace, a quote, or a shell metacharacter: "$(BENCH_WORK_ROOT)" — choose a plain absolute path)
endif
BENCH_WORK_ROOT := $(shell python3 scripts/work-root.py prepare --repo '$(REPO_ROOT)' --work '$(BENCH_WORK_ROOT)')
ifeq ($(strip $(BENCH_WORK_ROOT)),)
  $(error BENCH_WORK_ROOT validation failed)
endif

BUILD_ROOT   := $(BENCH_WORK_ROOT)/build
FIXTURE_ROOT := $(BENCH_WORK_ROOT)/fixtures
RESULTS_ROOT := $(BENCH_WORK_ROOT)/results
SEEDING      := $(BENCH_WORK_ROOT)/seeding
SEEDING_TOOLS := $(CURDIR)/seeding

# ~80% of logical cores, minimum 1.
NCPU     := $(shell sysctl -n hw.ncpu 2>/dev/null || nproc)
JOBS     ?= $(shell echo $$(( $(NCPU) * 4 / 5 > 0 ? $(NCPU) * 4 / 5 : 1 )))

# Harness binaries (built by the *-harness targets below).
# RUST_BENCH_BIN is the Rust benchmarker; the plain RUST_BIN name belongs
# to the Rust PRODUCT binary (defined in the twin-build section) — the two
# previously collided under one name, with the later := silently winning.
# Make supplies an external Cargo target directory; no Cargo output lands
# under this checkout.
SWIFT_BUILD_DIR := $(BUILD_ROOT)/harness-swift
RUST_BUILD_DIR  := $(BUILD_ROOT)/harness-rust
SWIFT_BIN      := $(SWIFT_BUILD_DIR)/release/mcp-benchmarker
RUST_BENCH_BIN := $(RUST_BUILD_DIR)/release/mcp-benchmarker-rs

# Product binary under test. ISOLATION RULE (Bob, 2026-08-18): measurement
# never uses an installed binary — it builds one from THIS tree and uses it
# in 100% isolation. The default is this repo's own release build, produced
# by the `moot-binary` prereq below; lane discovery (the empty-flag fallback)
# was likewise cut back to tree build products only. Override MOOT_BINARY
# explicitly only to measure a DIFFERENT tree's build, never an install.
PRODUCT_SWIFT_BUILD_DIR := $(BUILD_ROOT)/product-swift
PRODUCT_RUST_BUILD_DIR  := $(BUILD_ROOT)/product-rust
MOOT_BINARY ?= $(PRODUCT_SWIFT_BUILD_DIR)/release/mootx01
MOOT_FLAG   := $(if $(MOOT_BINARY),--mootx01-binary $(MOOT_BINARY),)

# Builds the product binary from this tree (the measurement subject). Kept
# out of the artifact-build path (artifacts reuse whatever binary built them,
# recorded in provenance); every measure-* target requires it via
# MEASURE_PREREQS so a stale or absent tree build can never be measured.

# Per-machine encoder model cache. Sits beside the work root so cp -c
# (APFS copy-on-write) reaches the share slot on the same volume without a
# data copy. Survives 'make clean'; re-runs skip the fetch when already verified.
MODEL_MACHINE_CACHE ?= $(dir $(BENCH_WORK_ROOT))models
NUEXTRACT_MODEL_ID := nuextract-tiny-v1.5
# The NuExtract assets are fetched the way the encoder model is: through
# tools/encoder-models/fetch-release.sh from the models-nuextract-tiny-v1.5
# release, verified against tools/encoder-models/nuextract-models-{apple,linux}.json.

# Stage the arctic-embed-s-w60 Apple model into ModelDirectoryResolver slot 3
# (<exe>/../share/mootx01/models/<id>/) beside the Swift product binary.
# The Swift SPM scratch dir hardlinks the release binary into out/Products/Release/
# so os.path.realpath() resolves there; the share slot must be out/Products/share/.
# fetch-release.sh is idempotent: skips the download when the cache is verified.
stage-encoder-model-swift:
	$(WORK_ANCHOR)/tools/encoder-models/fetch-release.sh apple \
	  $(MODEL_MACHINE_CACHE)/apple/arctic-embed-s-w60
	mkdir -p $(PRODUCT_SWIFT_BUILD_DIR)/out/Products/share/mootx01/models
	rm -rf $(PRODUCT_SWIFT_BUILD_DIR)/out/Products/share/mootx01/models/arctic-embed-s-w60
	cp -Rc $(MODEL_MACHINE_CACHE)/apple/arctic-embed-s-w60 \
	  $(PRODUCT_SWIFT_BUILD_DIR)/out/Products/share/mootx01/models/arctic-embed-s-w60

# Stage the arctic-embed-s-w60 Linux/Rust model into ModelDirectoryResolver slot 2
# (<exe>/../share/mootx01/models/<id>/) beside the Rust product binary.
# Cargo puts the release binary at target/release/mootx01; slot is target/share/.
# Linux layout: config.json, tokenizer.json, model.safetensors, vocab.txt.
stage-encoder-model-rust:
	$(WORK_ANCHOR)/tools/encoder-models/fetch-release.sh linux \
	  $(MODEL_MACHINE_CACHE)/linux/arctic-embed-s-w60
	mkdir -p $(PRODUCT_RUST_BUILD_DIR)/release/../share/mootx01/models
	rm -rf $(PRODUCT_RUST_BUILD_DIR)/release/../share/mootx01/models/arctic-embed-s-w60
	cp -Rc $(MODEL_MACHINE_CACHE)/linux/arctic-embed-s-w60 \
	  $(PRODUCT_RUST_BUILD_DIR)/release/../share/mootx01/models/arctic-embed-s-w60

# Stage the pinned NuExtract fact-extraction assets beside each product binary,
# in the same share slot the encoder model uses. fetch-release.sh verifies every
# staged byte against the checked-in platform manifest before the product builds.
stage-nuextract-model-swift:
	$(WORK_ANCHOR)/tools/encoder-models/fetch-release.sh apple \
	  $(MODEL_MACHINE_CACHE)/apple/$(NUEXTRACT_MODEL_ID) $(NUEXTRACT_MODEL_ID)
	mkdir -p $(PRODUCT_SWIFT_BUILD_DIR)/out/Products/share/mootx01/models
	rm -rf $(PRODUCT_SWIFT_BUILD_DIR)/out/Products/share/mootx01/models/$(NUEXTRACT_MODEL_ID)
	cp -Rc $(MODEL_MACHINE_CACHE)/apple/$(NUEXTRACT_MODEL_ID) \
	  $(PRODUCT_SWIFT_BUILD_DIR)/out/Products/share/mootx01/models/$(NUEXTRACT_MODEL_ID)

stage-nuextract-model-rust:
	$(WORK_ANCHOR)/tools/encoder-models/fetch-release.sh linux \
	  $(MODEL_MACHINE_CACHE)/linux/$(NUEXTRACT_MODEL_ID) $(NUEXTRACT_MODEL_ID)
	mkdir -p $(PRODUCT_RUST_BUILD_DIR)/release/../share/mootx01/models
	rm -rf $(PRODUCT_RUST_BUILD_DIR)/release/../share/mootx01/models/$(NUEXTRACT_MODEL_ID)
	cp -Rc $(MODEL_MACHINE_CACHE)/linux/$(NUEXTRACT_MODEL_ID) \
	  $(PRODUCT_RUST_BUILD_DIR)/release/../share/mootx01/models/$(NUEXTRACT_MODEL_ID)

# Stage the ms-marco cross encoder (CROSSENCODER_SPEC) beside each product
# binary, the same share slot the sentence encoder uses, so the encoder-on arm
# has its pair scorer. fetch-release.sh verifies the staged bytes against the
# checked-in cross-encoder manifests.
CROSS_ENCODER_MODEL_ID := ms-marco-minilm-l6-cross-v1
stage-cross-encoder-model-swift:
	$(WORK_ANCHOR)/tools/encoder-models/fetch-release.sh apple \
	  $(MODEL_MACHINE_CACHE)/apple/$(CROSS_ENCODER_MODEL_ID) $(CROSS_ENCODER_MODEL_ID)
	mkdir -p $(PRODUCT_SWIFT_BUILD_DIR)/out/Products/share/mootx01/models
	rm -rf $(PRODUCT_SWIFT_BUILD_DIR)/out/Products/share/mootx01/models/$(CROSS_ENCODER_MODEL_ID)
	cp -Rc $(MODEL_MACHINE_CACHE)/apple/$(CROSS_ENCODER_MODEL_ID) \
	  $(PRODUCT_SWIFT_BUILD_DIR)/out/Products/share/mootx01/models/$(CROSS_ENCODER_MODEL_ID)

stage-cross-encoder-model-rust:
	$(WORK_ANCHOR)/tools/encoder-models/fetch-release.sh linux \
	  $(MODEL_MACHINE_CACHE)/linux/$(CROSS_ENCODER_MODEL_ID) $(CROSS_ENCODER_MODEL_ID)
	mkdir -p $(PRODUCT_RUST_BUILD_DIR)/release/../share/mootx01/models
	rm -rf $(PRODUCT_RUST_BUILD_DIR)/release/../share/mootx01/models/$(CROSS_ENCODER_MODEL_ID)
	cp -Rc $(MODEL_MACHINE_CACHE)/linux/$(CROSS_ENCODER_MODEL_ID) \
	  $(PRODUCT_RUST_BUILD_DIR)/release/../share/mootx01/models/$(CROSS_ENCODER_MODEL_ID)

moot-binary: stage-encoder-model-swift stage-nuextract-model-swift stage-cross-encoder-model-swift
	# -DMOOTX01_HARNESS_KEYFILE: the matrix lane's encrypted cell requires
	# BOTH binaries built with the file-based db-key read compiled in; a
	# plain product build here left serve unable to open the encrypted
	# clone ("file is not a database", smoke 2026-08-26). Benchmark-context
	# builds therefore always carry the define.
	swift build --package-path $(WORK_ANCHOR)/apps/mootx01 --scratch-path $(PRODUCT_SWIFT_BUILD_DIR) -c release --product mootx01 -Xswiftc -DMOOTX01_HARNESS_KEYFILE

# Artifact store. ONE root shared by build and measure runs — the run-config
# key (lane, seed, barrier, posture, granularity, …) namespaces entries.
CACHE_DIR ?= $(BENCH_WORK_ROOT)/estate-cache

# The kit whose store the drift gate checks. Relative to this Makefile.
CORPUSKIT_DIR := $(WORK_ANCHOR)/packages/kits/CorpusKit

# Corpus fixtures (canonical locations; fetch scripts live in scripts/).
LME_DATA_DIR      := $(FIXTURE_ROOT)/longmemeval/data
LOCOMO_JSON       := $(FIXTURE_ROOT)/locomo/data/locomo10.json
LMEB_DATA_DIR     := $(FIXTURE_ROOT)/lmeb/data/ConvoMem
MEMBENCH_DATA_DIR := $(FIXTURE_ROOT)/membench/MemData

# cl100k_base tokenizer vocabulary (the membench-spec §6 capacity token axis).
# SHA-256-pinned in the fetch script; gitignored; the capacity mode fails loud
# without it. `make fetch-cl100k` places it here for anyone rebuilding.
CL100K_VOCAB := $(FIXTURE_ROOT)/cl100k/cl100k_base.tiktoken
export MOOT_BENCH_CL100K := $(CL100K_VOCAB)

# LMEB evidence categories. ConvoMem defines SIX; the targets below hardcoded
# user_evidence alone until 2026-08-16, so every LMEB figure produced before
# that date covered one sixth of the benchmark while being reported as LMEB.
# The corpus digest keys the artifact store on this list, so changing it is a
# different set rather than a silent overwrite.
COMMA := ,
LMEB_EVIDENCE ?= abstention_evidence,assistant_facts_evidence,changing_evidence,implicit_connection_evidence,preference_evidence,user_evidence

# Arm names for the record filenames. These MUST equal what the harness writes
# into the report name, or a report and its sidecar stop pairing. The harness
# side is `recordFilename(test:arm:serial:)`; LMEB collapses six categories to
# `all6`, LoCoMo names the conversation count.
LOCOMO_CONVERSATIONS ?= 10
LMEB_ARM := $(if $(filter 6,$(words $(subst $(COMMA), ,$(LMEB_EVIDENCE)))),all6,$(subst $(COMMA),+,$(LMEB_EVIDENCE)))

# MemBench agent perspective. The dataset ships TWO (FirstAgent, ThirdAgent)
# and every layer defaulted to FirstAgent — fetch script, loader, and these
# targets — so 7,000 of the dataset's 20,137 items were ever built.
MEMBENCH_AGENT ?= FirstAgent

# Run parameters. Seeds are the lanes' documented defaults; override per
# invocation (`make seeds SEED=7`). LIMIT bounds units per lane for
# partial fleets (empty = full corpus). PARALLEL sets bounded query
# concurrency on the accuracy lanes (parallel and serial runs produce the
# same accuracy figures, method §8.1). ANSWER_DUMP writes the BYOAI
# answer-input JSONL for offline answering on the lanes that support it.
SEED  ?=
LIMIT ?=
PARALLEL ?=
ANSWER_DUMP ?=
SEED_FLAG  := $(if $(SEED),--seed $(SEED),)
LIMIT_FLAG := $(if $(LIMIT),--limit $(LIMIT),)
PARALLEL_FLAG := $(if $(PARALLEL),--parallel $(PARALLEL),)
ANSWER_DUMP_FLAG := $(if $(ANSWER_DUMP),--dump-answer-inputs $(ANSWER_DUMP),)

BUILD_FLAGS   := --estate-cache reuse   --cache-dir $(CACHE_DIR) $(MOOT_FLAG) $(SEED_FLAG) $(LIMIT_FLAG) $(PARALLEL_FLAG)
# Deferred (`=`, not `:=`) because RUN_ID is defined further down the file:
# an immediate expansion here resolved --run-id to the empty string, which
# the lanes accept silently and then fall back to their own timestamp,
# breaking the report/sidecar serial pairing that is the whole point.
MEASURE_FLAGS = --estate-cache require --cache-dir $(CACHE_DIR) $(MOOT_FLAG) $(SEED_FLAG) $(LIMIT_FLAG) $(PARALLEL_FLAG) --run-id $(RUN_ID)

.PHONY: all artifacts measure clean rebuild swift-harness rust-harness \
        drift-gate drift-gate-swift drift-gate-rust drift-stamp-current refresh \
        seeds fleets wing-estates smoke-wings smoke-fleets smoke-measures \
        stage-encoder-model-swift stage-encoder-model-rust \
        stage-nuextract-model-swift stage-nuextract-model-rust \
        measure-locomo measure-convomem measure-membench measure-lme-s \
        measure-external measure-locomo-spec \
        artifacts-lme-spec measure-lme-spec measure-membench-spec measure-lmeb-spec \
        measure-convomem-spec \
        measure-matrix measure-timing measure-supersession measure-journey \
        measure-gauntlet landscape schema-gate verify-artifacts determinism-current \
        snapshot smoke fetch-cl100k moot-binary

all: artifacts

# ── Store-integrity drift gate (runs BEFORE either harness builds) ──────────
#
# The benchmarker measures the product's store. If that store has drifted into
# an incoherent shape, every number the harness produces measures a defect
# rather than performance — and it looks like an ordinary result, which is the
# worst kind of wrong answer this program can emit.
#
# The invariants checked here were each discovered by a separate mission
# colliding with them, never by a test:
#
#   I-1  every count_references row has a live counts row
#   I-2  no dictionary model bit without payload rows for that model
#   I-3  every payload row is reachable through the dictionary
#   I-4  an invalidation sentinel has no surviving v3 vocab rows
#
# They live in CorpusKit's own suites, so a session that did not run the full
# suite has no evidence they hold. This gate is the second check: it re-runs
# them on the way into every harness build, closing the "the suite was green
# last week" path into a measurement run. Both ports, because the write and
# delete paths that produced all four defects exist in both.
#
# Deliberately NOT overridable. A gate with a skip flag is a suggestion, and
# what it guards against is silent by nature — a wrong number that reads as a
# right one. If this gate fails, the thing to fix is the store, not the gate.
#
# Cost: few tests, but each port builds its test target first. That is the
# price of not measuring a broken store.

# The stamp is the gate's receipt: the ISO instant plus a CONTENT fingerprint
# of the kit sources the gate validated. Written only on success, so a failed
# gate leaves the previous receipt to go stale rather than refreshing it.
#
# The fingerprint, not the timestamp, is what carries the guarantee. An earlier
# draft of this gate compared the stamp's mtime to the binary's and was
# VACUOUS: swift-harness depends on drift-gate, so the stamp was rewritten on
# the way in and was always fresher than anything it was compared against. A
# check that cannot fail is not a check.
DRIFT_STAMP  := $(CACHE_DIR)/.drift-gate-stamp
# Paths are single-quoted (see the parse-time shell guard in Configuration):
# CORPUSKIT_DIR descends from the guarded CURDIR, and KIT_SRC is that tree's
# tracked file list, quoted per entry.
KIT_SRC      := $(shell find '$(CORPUSKIT_DIR)/Sources' '$(CORPUSKIT_DIR)/rust/src' -type f \( -name '*.swift' -o -name '*.rs' \) 2>/dev/null | sort)
KIT_FINGERPRINT = $(shell cat $(foreach f,$(KIT_SRC),'$(f)') 2>/dev/null | shasum -a 256 | cut -d' ' -f1)

drift-gate: drift-gate-swift drift-gate-rust
	@mkdir -p $(dir $(DRIFT_STAMP))
	@printf '%s\n%s\n%s\n' \
	  "$$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
	  "$(KIT_FINGERPRINT)" \
	  "$$(stat -f %m $(KIT_SRC) | sort -n | tail -1)" > $(DRIFT_STAMP)
	@echo "[make] drift gate PASSED — receipt: $(DRIFT_STAMP) (kit $(KIT_FINGERPRINT))"

# Refuse to measure unless the binary was built from the source the gate just
# validated. Two independent conditions, both required:
#
#   1. FINGERPRINT — the kit sources hash to what the receipt recorded. Catches
#      a source edit between the gate and the run, which the timestamp alone
#      cannot see.
#   2. FRESHNESS — the binary is newer than every kit source file. Catches the
#      common case: someone edits the kit, does not rebuild, and measures a
#      binary that predates the code the gate validated.
#
# Skipped only when MOOT_BINARY is unset, because the lane discovers its own
# binary and make cannot stat a path it does not know. The condition still
# holds; it is simply unenforceable from here.
drift-stamp-current:
	@if [ ! -f "$(DRIFT_STAMP)" ]; then \
	  echo "[make] REFUSING: no drift-gate receipt. Run 'make drift-gate' first."; exit 1; \
	fi
	@recorded=$$(sed -n 2p $(DRIFT_STAMP)); \
	if [ "$$recorded" != "$(KIT_FINGERPRINT)" ]; then \
	  echo "[make] REFUSING: kit sources changed since the gate ran."; \
	  echo "[make]   receipt:  $$recorded"; \
	  echo "[make]   current:  $(KIT_FINGERPRINT)"; \
	  echo "[make] Run 'make drift-gate' against the current source."; exit 1; \
	fi
	@if [ -z "$(MOOT_BINARY)" ]; then \
	  echo "[make] fingerprint matches; binary freshness unenforceable (MOOT_BINARY unset)"; \
	else \
	  stale=$$(find $(KIT_SRC) -newer "$(MOOT_BINARY)" 2>/dev/null | head -1); \
	  if [ -n "$$stale" ]; then \
	    echo "[make] REFUSING: $(MOOT_BINARY) is older than kit source $$stale."; \
	    echo "[make] The binary predates the code the gate validated. Rebuild it."; exit 1; \
	  fi; \
	  echo "[make] receipt current: fingerprint matches and $(MOOT_BINARY) is newer than all kit source"; \
	fi

drift-gate-swift:
	@echo "[make] drift gate (Swift): CorpusKit counts-store invariants"
	swift test --package-path $(CORPUSKIT_DIR) --scratch-path $(BUILD_ROOT)/drift-swift --filter CountsIntegrityRunner

drift-gate-rust:
	@echo "[make] drift gate (Rust): CorpusKit counts-store invariants"
	cd $(CORPUSKIT_DIR)/rust && CARGO_TARGET_DIR=$(BUILD_ROOT)/drift-rust cargo test --offline --test counts_integrity_runner_tests

# ── Harness builds ───────────────────────────────────────────────────────────
#
# Both depend on drift-gate: no harness is built against a store whose
# invariants have not just been checked.

# MOOTX01_HARNESS_KEYFILE compiles in the file-based db key, which is how the
# storage matrix's encrypted cell is served: the harness converts a copy of a
# prebuilt database and has to hand the server the key it used. Keychain custody
# would cost an approval prompt per spawned server and leave one durable item
# per database behind. The condition is set HERE and nowhere else — no product
# target defines it, so it is absent from every shipping binary.
#
# The mootx01 binary the matrix serves must carry the same flag. Build it with:
#   swift build -c release -Xswiftc -DMOOTX01_HARNESS_KEYFILE
# from apps/mootx01. Without it the matrix refuses the encrypted cell rather
# than reporting a cell it never served.
HARNESS_DEFINES := -Xswiftc -DMOOTX01_HARNESS_KEYFILE

swift-harness: drift-gate
	swift build --scratch-path $(SWIFT_BUILD_DIR) -c release --product mcp-benchmarker $(HARNESS_DEFINES)

rust-harness: drift-gate
	cd rust && CARGO_TARGET_DIR=$(RUST_BUILD_DIR) cargo build --release --offline

# Focused synthetic resume/security tests; no estate or reader model needed.
.PHONY: test-answer-resume-swift test-answer-resume-rust
test-answer-resume-swift:
	swift test --scratch-path $(SWIFT_BUILD_DIR) --jobs 4 --filter LMESpecAnswerBatch $(HARNESS_DEFINES)

test-answer-resume-rust:
	cd rust && CARGO_TARGET_DIR=$(RUST_BUILD_DIR) cargo test --offline --jobs 4 --lib spec_answer_batch

# ── Artifact builds ──────────────────────────────────────────────────────────
#
# Estate artifacts are built by the seeding pipeline (seeds, fleets,
# wing-estates — see the "Estate seeding + fleet builds" section
# below). The `artifacts` aggregate near that section chains all of it.
# The spec lanes that build their own estates (artifacts-lme-spec)
# remain here.

# ── Fixture downloaders ──────────────────────────────────────────────────────
#
# The corpus fetch scripts under scripts/ are invoked by hand today; the
# cl100k vocabulary gets a make target because harness code (the membench-spec
# capacity token axis) depends on the file at a pinned path and fails loud
# without it. Idempotent: the script verifies the pinned SHA-256 and skips the
# download when the file is already present and correct.

fetch-cl100k:
	BENCH_WORK_ROOT=$(BENCH_WORK_ROOT) scripts/fetch-cl100k.sh

# ── Preflight (run book §3.1) ───────────────────────────────────────────────
# fetch: download every external source corpus into its fixture path
# (each script verifies what it downloads and is safe to rerun on present
# fixtures). Internal datasets need no fetch — `make seeds` generates
# their corpora.
fetch: fetch-cl100k
	BENCH_WORK_ROOT=$(BENCH_WORK_ROOT) scripts/fetch-longmemeval.sh
	BENCH_WORK_ROOT=$(BENCH_WORK_ROOT) scripts/fetch-locomo.sh
	BENCH_WORK_ROOT=$(BENCH_WORK_ROOT) scripts/fetch-lmeb.sh
	BENCH_WORK_ROOT=$(BENCH_WORK_ROOT) scripts/fetch-membench.sh FirstAgent
	BENCH_WORK_ROOT=$(BENCH_WORK_ROOT) scripts/fetch-membench.sh ThirdAgent

# binaries: both product binaries and both benchmarkers, one command.
rust-moot-binary: stage-encoder-model-rust stage-nuextract-model-rust stage-cross-encoder-model-rust
	# harness-keyfile: lets the Rust product serve a scratch estate the harness
	# converted to ciphertext. Off by default in the product's Cargo.toml —
	# no shipping build enables it.
	cd $(WORK_ANCHOR)/apps/mootx01/rust && CARGO_TARGET_DIR=$(PRODUCT_RUST_BUILD_DIR) cargo build --release --bins --features harness-keyfile

binaries: moot-binary rust-moot-binary swift-harness rust-harness

# ── Pre-test snapshot (Apple hardware) ──────────────────────────────────────
#
# Every measured lane takes an APFS local snapshot BEFORE it runs, and waits
# for it. `tmutil localsnapshot` is synchronous — it returns only once the
# snapshot exists — and the listing check below is the proof rather than the
# assumption. A pass that destroys a record (2026-08-17: four matrix arms
# sharing one filename, 4h19m lost) is then recoverable from the snapshot
# instead of only from a re-run.
#
# Requires manual snapshots to be configured; no sudo is needed. On non-Darwin
# hosts the target is a no-op, so the Rust port's Linux targets are unaffected.
# Set SNAPSHOT=0 to skip — for a throwaway run, never for a measured pass.
#
# Local snapshots are purgeable in principle, but macOS does NOT reliably
# purge them ahead of disk pressure: on 2026-08-26, 43 accumulated gate
# snapshots pinned ~145 GB while the disk ran to 15 GB free. The gate now
# thins its own population after verifying the new snapshot, keeping the
# newest SNAPSHOT_KEEP. A snapshot is a convenience, not an archive. The
# archive is ARCHIVE_ROOT (see the archive target).
SNAPSHOT ?= 1
SNAPSHOT_KEEP ?= 4
snapshot:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
	  echo "[make] snapshot: not Darwin, skipping"; \
	elif [ "$(SNAPSHOT)" != "1" ]; then \
	  echo "[make] snapshot: SNAPSHOT=$(SNAPSHOT), skipping"; \
	else \
	  out=$$(tmutil localsnapshot / 2>&1) || { \
	    echo "[make] REFUSING: snapshot failed — configure manual Time Machine snapshots or pass SNAPSHOT=0"; \
	    echo "$$out"; exit 1; }; \
	  name=$$(printf '%s' "$$out" | sed -n 's/.*date: //p'); \
	  if [ -z "$$name" ]; then \
	    echo "[make] REFUSING: tmutil reported no snapshot date"; echo "$$out"; exit 1; \
	  fi; \
	  tmutil listlocalsnapshots / 2>/dev/null | grep -q "$$name" || { \
	    echo "[make] REFUSING: snapshot $$name is not listed — not proceeding on an unverified snapshot"; exit 1; }; \
	  echo "[make] snapshot verified: com.apple.TimeMachine.$$name.local"; \
	  tm=$$(tmutil listlocalsnapshots / 2>/dev/null \
	    | sed -n 's/^com\.apple\.TimeMachine\.\(.*\)\.local$$/\1/p' | sort); \
	  total=$$(printf '%s\n' "$$tm" | sed '/^$$/d' | wc -l | tr -d ' '); \
	  if [ "$$total" -gt "$(SNAPSHOT_KEEP)" ]; then \
	    printf '%s\n' "$$tm" | sed '/^$$/d' \
	      | grep -v "^$$name$$" \
	      | head -n $$(( total - $(SNAPSHOT_KEEP) )) \
	      | while read -r d; do \
	          tmutil deletelocalsnapshots "$$d" >/dev/null 2>&1 \
	            && echo "[make] snapshot thinned: $$d (keep $(SNAPSHOT_KEEP))"; \
	        done; \
	  fi; \
	fi

# ── Measurement (quiet machine; artifacts REQUIRED — B7 hard-fails on miss) ──
#
# MEASURE_PREREQS is the gate chain every measured lane carries: a verified
# snapshot, a harness matching its source, a binary no older than that source,
# artifact schemas matching the build, and a determinism receipt. All of them
# are receipt-based, so re-deriving them once per lane buys nothing: on
# 2026-08-17 a twelve-lane smoke pass spent about 5m53s per lane on gates and
# roughly a second per lane measuring.
#
# A pass that has already run the gates overrides this to empty and inherits
# the receipts. A hand-run lane leaves it alone and carries its own gates.
MEASURE_PREREQS ?= snapshot moot-binary swift-harness drift-stamp-current schema-gate determinism-current

# External retrieval measurement runs on the rebuilt artifacts through
# the artifact measure surface (measure-<ds> / measure-external in the
# seeding section below); the pre-rebuild self-provisioning retrieval
# lanes are retired. The judged spec lanes below remain.

# ── Judged protocols on artifacts (run book §8) ────────────────────────────
# The five official spec lanes open the PRE-BUILT artifacts through the
# artifact estate seam (per-instance protocols default to SCALE=unit —
# the port's fleet; SCALE=bench-aggregate opens the port's Form-2
# estate). Judged lanes (lme, convomem, membench) attach models via
# MOOT_BENCH_ANSWER_CMD / MOOT_BENCH_JUDGE_CMD (environment, never
# flags) and defer judging with DUMP=1 → a judge-input dump under
# results/judge-dumps/. locomo and lmeb are mechanically scored (F1 /
# retrieval grid): DUMP has no meaning there and is refused by the
# recipe rather than silently ignored.
JUDGE_DUMPS := $(RESULTS_ROOT)/judge-dumps
# Spec lanes default to unit scale even though the global SCALE default
# is bench-aggregate: only an explicit command-line SCALE overrides.
SPEC_SCALE = $(if $(filter command line,$(origin SCALE)),$(SCALE),unit)
SPEC_DIR_FLAG = $(if $(filter unit,$(SPEC_SCALE)),--catalog $(PORT_FLEETS)/$(1)/catalog.json,--estate-dir $(PORT_WINGS)/$(1))

measure-lme-spec: $(MEASURE_PREREQS)
	@mkdir -p $(RESULTS_ROOT) $(JUDGE_DUMPS)
	$(PORT_BENCH_BIN) lme-spec --data-dir $(LME_DATA_DIR) --variant s \
	  --target-scale $(SPEC_SCALE) $(call SPEC_DIR_FLAG,lme-s) \
	  $(if $(or $(DUMP),$(DUMP_DIR)),--dump-judge-inputs $(or $(DUMP_DIR),$(JUDGE_DUMPS)/lme-$(shell date -u +%Y%m%dT%H%M%SZ))/judge-inputs.jsonl,) \
	  $(MOOT_FLAG) $(SEED_FLAG) $(LIMIT_FLAG) --run-id $(RUN_ID) --out $(OUT)

measure-locomo-spec: $(MEASURE_PREREQS)
	@test -z "$(DUMP)" || { echo "REFUSED: locomo-spec is mechanically scored (F1) — no judge inputs exist; drop DUMP"; exit 1; }
	@mkdir -p $(RESULTS_ROOT)
	$(PORT_BENCH_BIN) locomo-spec --data-file $(LOCOMO_JSON) \
	  --target-scale $(SPEC_SCALE) $(call SPEC_DIR_FLAG,locomo) \
	  $(MOOT_FLAG) $(SEED_FLAG) $(LIMIT_FLAG) --run-id $(RUN_ID) --out $(OUT)

INSTRUCTION ?= without
measure-lmeb-spec: $(MEASURE_PREREQS)
	@test -z "$(DUMP)" || { echo "REFUSED: lmeb-spec is the mechanical retrieval grid — no judge inputs exist; drop DUMP"; exit 1; }
	@mkdir -p $(RESULTS_ROOT)
	$(PORT_BENCH_BIN) lmeb-spec --data-dir $(LMEB_DATA_DIR) \
	  --evidence-types $(LMEB_EVIDENCE) --instruction-setting $(INSTRUCTION) \
	  --target-scale $(SPEC_SCALE) $(call SPEC_DIR_FLAG,convomem) \
	  $(MOOT_FLAG) $(SEED_FLAG) $(LIMIT_FLAG) --run-id $(RUN_ID) --out $(OUT)

measure-convomem-spec: $(MEASURE_PREREQS)
	@mkdir -p $(RESULTS_ROOT) $(JUDGE_DUMPS)
	$(PORT_BENCH_BIN) convomem-spec --data-dir $(LMEB_DATA_DIR) \
	  --evidence-types $(LMEB_EVIDENCE) \
	  --target-scale $(SPEC_SCALE) $(call SPEC_DIR_FLAG,convomem) \
	  $(if $(or $(DUMP),$(DUMP_DIR)),--dump-answer-inputs $(or $(DUMP_DIR),$(JUDGE_DUMPS)/convomem-$(shell date -u +%Y%m%dT%H%M%SZ))/answer-inputs.jsonl,$(ANSWER_DUMP_FLAG)) \
	  $(MOOT_FLAG) $(SEED_FLAG) $(LIMIT_FLAG) --run-id $(RUN_ID) --out $(OUT)

CAPACITY ?=
CAPACITY_FLAG := $(if $(CAPACITY),--capacity $(CAPACITY),)
measure-membench-spec: $(MEASURE_PREREQS)
	@mkdir -p $(RESULTS_ROOT) $(JUDGE_DUMPS)
	$(PORT_BENCH_BIN) membench-spec --data-dir $(MEMBENCH_DATA_DIR) \
	  --agent $(MEMBENCH_AGENT) $(CAPACITY_FLAG) \
	  --target-scale $(SPEC_SCALE) $(call SPEC_DIR_FLAG,membench) \
	  $(if $(or $(DUMP),$(DUMP_DIR)),--dump-answer-inputs $(or $(DUMP_DIR),$(JUDGE_DUMPS)/membench-$(shell date -u +%Y%m%dT%H%M%SZ))/answer-inputs.jsonl,$(ANSWER_DUMP_FLAG)) \
	  $(MOOT_FLAG) $(SEED_FLAG) $(LIMIT_FLAG) --run-id $(RUN_ID) --out $(OUT)

# ── Judged-protocol smokes (run book §8.3–§8.5) ────────────────────────────
# smoke-spec-<protocol>: SMOKE_MEASURE_Q questions through the real spec
# lane against the port's artifacts (judged lanes with a deferred dump;
# mechanical lanes report-only), then spec_smoke_verify.py reviews the
# report and dump shape exactly. Stamps .smoke-ok-spec-<protocol>-<port>.
SPEC_SMOKE_OUT = $(RESULTS_ROOT)/spec-smoke-$*-$(PORT)

smoke-spec-lme smoke-spec-convomem smoke-spec-membench: smoke-spec-%:
	rm -rf $(SPEC_SMOKE_OUT) $(JUDGE_DUMPS)/smoke-$*-$(PORT) && mkdir -p $(SPEC_SMOKE_OUT) $(JUDGE_DUMPS)/smoke-$*-$(PORT)
	$(MAKE) -C $(CURDIR) measure-$*-spec PORT=$(PORT) MEASURE_PREREQS= \
	  LIMIT=$(SMOKE_MEASURE_Q) OUT=$(SPEC_SMOKE_OUT) \
	  DUMP_DIR=$(JUDGE_DUMPS)/smoke-$*-$(PORT)
	python3 $(SEEDING_TOOLS)/spec_smoke_verify.py --report-dir $(SPEC_SMOKE_OUT) \
	  --protocol $* --dump-dir $(JUDGE_DUMPS)/smoke-$*-$(PORT) \
	  && touch $(SEEDING)/.smoke-ok-spec-$*-$(PORT)

smoke-spec-locomo smoke-spec-lmeb: smoke-spec-%:
	rm -rf $(SPEC_SMOKE_OUT) && mkdir -p $(SPEC_SMOKE_OUT)
	$(MAKE) -C $(CURDIR) measure-$*-spec PORT=$(PORT) MEASURE_PREREQS= \
	  LIMIT=$(SMOKE_MEASURE_Q) OUT=$(SPEC_SMOKE_OUT)
	python3 $(SEEDING_TOOLS)/spec_smoke_verify.py --report-dir $(SPEC_SMOKE_OUT) \
	  --protocol $* && touch $(SEEDING)/.smoke-ok-spec-$*-$(PORT)

# Bench-with-live-judging smoke: same vehicle with the judge attached;
# the receipt must show judged_count == SMOKE_MEASURE_Q. Refuses without
# a judge — it never substitutes a stub.
smoke-spec-lme-inflight smoke-spec-convomem-inflight smoke-spec-membench-inflight: smoke-spec-%-inflight:
	@test -n "$$MOOT_BENCH_JUDGE_CMD" || { echo "REFUSED: smoke-spec-$*-inflight needs MOOT_BENCH_JUDGE_CMD set — it never substitutes a stub judge"; exit 1; }
	rm -rf $(RESULTS_ROOT)/spec-smoke-$*-inflight-$(PORT) && mkdir -p $(RESULTS_ROOT)/spec-smoke-$*-inflight-$(PORT)
	$(MAKE) -C $(CURDIR) measure-$*-spec PORT=$(PORT) MEASURE_PREREQS= \
	  LIMIT=$(SMOKE_MEASURE_Q) OUT=$(RESULTS_ROOT)/spec-smoke-$*-inflight-$(PORT)
	python3 $(SEEDING_TOOLS)/spec_smoke_verify.py \
	  --report-dir $(RESULTS_ROOT)/spec-smoke-$*-inflight-$(PORT) \
	  --protocol $* --expect-judged $(SMOKE_MEASURE_Q)

# Deferred-judging smoke: consume the tiny dump from smoke-spec-<p>.
# Judge attached = real verdicts land; judge absent = the batch reports
# the judge-absent state as such and the receipt says so. The gate is
# shared across ports (dumps are port-independent files).
smoke-judge-batch:
	@d=$$(ls -td $(JUDGE_DUMPS)/smoke-* 2>/dev/null | head -1); \
	test -n "$$d" || { echo "REFUSED: no smoke dump found — run 'make smoke-spec-lme' (or convomem/membench) first"; exit 1; }; \
	if [ -n "$$MOOT_BENCH_JUDGE_CMD" ]; then \
	  $(PORT_BENCH_BIN) judge-batch --inputs $$d --out $$d && \
	  echo "smoke-judge-batch GREEN: verdicts written beside $$d"; \
	else \
	  echo "smoke-judge-batch: no judge attached — verifying the batch consumes the dump and reports the judge-absent state"; \
	  $(PORT_BENCH_BIN) judge-batch --inputs $$d --out $$d 2>&1 | head -3; \
	  echo "smoke-judge-batch GREEN (shape-only: dump consumed, judge-absent state reported)"; \
	fi; \
	touch $(SEEDING)/.smoke-ok-judge-batch

# Deferred judging alone: consume a judge-input dump with the judge
# attached (MOOT_BENCH_JUDGE_CMD); verdicts land beside the dump and the
# run report's judged_count is updated by the consuming lane's fold-in.
judge-batch:
	@test -n "$(DUMPS)" || { echo "judge-batch requires DUMPS=<dump dir or file>"; exit 1; }
	$(PORT_BENCH_BIN) judge-batch --inputs $(DUMPS) --out $(dir $(DUMPS))

# answer-batch: offline answer pass for the two answer-dump lanes (convomem-spec,
# membench-spec). Reads an answer-inputs JSONL produced by --dump-answer-inputs,
# dispatches on the header's "benchmark" field, and writes a file --consume-answers
# can ingest.
#
#   INPUTS     — path to the answer-inputs JSONL file (required)
#   ANSWER_CMD — shell command that reads a prompt on stdin and writes the
#                answer letter (or JSON {"choice":"A"}) on stdout (required)
#   OUT        — output path for the answered file (required)
#
# Example:
#   make answer-batch INPUTS=results/answer-dumps/run-id/answers.jsonl \
#                     ANSWER_CMD="claude -p --model claude-sonnet-4-6" \
#                     OUT=results/answer-dumps/run-id/answered.jsonl
answer-batch:
	@test -n "$(INPUTS)"     || { echo "answer-batch requires INPUTS=<answer-inputs.jsonl>"; exit 1; }
	@test -n "$(ANSWER_CMD)" || { echo "answer-batch requires ANSWER_CMD=<cmd>"; exit 1; }
	@test -n "$(OUT)"        || { echo "answer-batch requires OUT=<path>"; exit 1; }
	$(PORT_BENCH_BIN) answer-batch --inputs $(INPUTS) --answer-cmd "$(ANSWER_CMD)" --out $(OUT)

# ── Lanes that are not corpus-accuracy lanes ────────────────────────────────
#
# These went unrepresented here until 2026-08-16, which meant they were run by
# hand — outside the drift gate, and with the pinned values (seed, cache dir,
# landscape) supplied from memory each time. Every one of them now carries the
# same gates the accuracy lanes carry: drift-gate to prove the harness matches
# the source it was built from, drift-stamp-current to prove the binary is not
# older than that source.
#
# Output goes to OUT (default: results/<date>), never to the tracked tree.
OUT ?= $(RESULTS_ROOT)/$(shell date -u +%Y%m%dT%H%M%SZ)

# ── Run parameters sidecar ──────────────────────────────────────────────────
#
# Every measured lane writes a params file beside its report, in the same
# timestamped output directory, carrying WHAT was run and WITH WHICH VALUES.
#
# The report says what the numbers are. It does not say how much of the
# benchmark produced them, and that omission is what had LMEB scored over one
# of six evidence categories and MemBench over one of two agent perspectives
# for eight days, with no number ever looking wrong. Documentation does not
# close it: the document is not attached to the JSON when the figure is quoted.
#
# Emitted from the Makefile rather than from each lane because the Makefile is
# where the values are chosen — a lane can only report what it was handed, and
# a lane that forgets is silently non-compliant. Here, one macro covers all of
# them and a new lane that omits the call is visibly missing a file.
#
# $(1) = lane name, $(2) = coverage fields as JSON (may be empty).
# ── Determinism receipt (build time, NOT measurement time) ──────────────────
#
# BENCHMARK_PROTOCOL §4 requires that figures are not used until a replay shows
# the outcome fields are deterministic across runs of the same seed and binary.
#
# That check belongs HERE, with the artifact build, and not in the measured
# pass. It needs no quiet machine, and a benchmark window is the scarcest thing
# in this program — spending one to learn the pipeline is nondeterministic
# wastes the very resource the check is meant to protect. Run it on a loaded
# machine, once, and let the measured run read the answer.
#
# The receipt records WHEN the check passed and against WHICH harness sources,
# by the same fingerprint the drift gate uses. A harness rebuilt from changed
# sources invalidates it, because determinism was proved of the old code.
DETERMINISM_RECEIPT := $(CACHE_DIR)/.determinism-receipt
REPLAY_RUNS ?= 2

verify-artifacts: swift-harness
	@echo "[make] determinism: $(REPLAY_RUNS) replay runs (loaded machine is fine)"
	$(SWIFT_BIN) replay --runs $(REPLAY_RUNS) --estate-mode unencrypted $(MOOT_FLAG)
	@mkdir -p $(dir $(DETERMINISM_RECEIPT))
	@printf '%s\n%s\n%s\n' \
	  "$$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
	  "$(KIT_FINGERPRINT)" \
	  "runs=$(REPLAY_RUNS)" > $(DETERMINISM_RECEIPT)
	@echo "[make] determinism PASSED — receipt: $(DETERMINISM_RECEIPT)"

# Read by every measured lane. A file read, never a re-run: the proof was done
# at build time and this only confirms it happened and still applies.
determinism-current:
	@if [ ! -f "$(DETERMINISM_RECEIPT)" ]; then \
	  echo "[make] REFUSING: no determinism receipt for $(CACHE_DIR)."; \
	  echo "       Run 'make verify-artifacts' — it needs no quiet machine."; exit 1; \
	fi
	@recorded=$$(sed -n 2p $(DETERMINISM_RECEIPT)); \
	if [ "$$recorded" != "$(KIT_FINGERPRINT)" ]; then \
	  echo "[make] REFUSING: determinism receipt was recorded against different harness sources."; \
	  echo "       Determinism was proved of code that is no longer what would run."; \
	  echo "       Re-run 'make verify-artifacts'."; exit 1; \
	fi
	@echo "[make] determinism receipt current ($$(sed -n 1p $(DETERMINISM_RECEIPT)))"

# ── Schema soft gate ────────────────────────────────────────────────────────
#
# The expected schema comes from the harness's own constant, read here rather
# than obtained by launching the product: the Makefile can know it without
# paying for a probe, and a measured run must not spend its window discovering
# per-unit that a whole set is the wrong shape.
#
# Artifacts of two schema lines do NOT coexist. The store key carries no schema
# version, so both lines land on the same key and the older set stops opening.
ESTATE_SCHEMA := $(shell rg -o 'currentEstateSchemaVersion = "([^"]+)"' -r '$$1' Sources/mcp-benchmarker/ArtifactManifest.swift 2>/dev/null)

schema-gate:
	@scripts/schema-gate.sh $(CACHE_DIR) $(ESTATE_SCHEMA)

# ── Smoke pass ──────────────────────────────────────────────────────────────
#
# END TO END, one real unit per arm, every lane, into ONE output directory.
# This is the pass that runs before any long pass. It is not a unit test and it
# is not a subset of lanes: it exercises the real path — build, serve, capture,
# recall, score, write the record — at the smallest scope that still produces a
# record, so a fault surfaces in minutes rather than after hours of measurement.
#
# It exists because 2026-08-17 spent 4h19m producing matrix measurements that
# four arms then overwrote into one file, and because the journey lane was
# called as a measured lane while having no live runner behind it. Both are
# visible in a one-unit-per-arm pass and invisible in a per-lane check.
#
# MemBench smokes ThirdAgent only: FirstAgent's set is 317 GB and lives on the
# archive, and `--estate-cache require` refuses rather than building fresh, so a
# smoke against it would fail on absence rather than on defect. Timing smokes
# only when a landscape is already on disk, for the same reason.
SMOKE_STAMP := $(shell date -u +%Y%m%dT%H%M%SZ)
SMOKE_OUT   := $(RESULTS_ROOT)/smoke-$(SMOKE_STAMP)
# RUN_ID is pinned to the bare stamp rather than left to derive from OUT: the
# smoke directory is `smoke-<stamp>`, and deriving from it would put
# `smoke-` inside every record name, where the arm belongs.
# MEASURE_PREREQS=snapshot, not empty: the receipt-based gates are hoisted to
# the pass, but the snapshot is NOT a gate — it is a rollback point, and it
# belongs immediately before each lane. Twelve lanes take twelve snapshots.
SMOKE_MK     = $(MAKE) OUT=$(SMOKE_OUT) RUN_ID=$(SMOKE_STAMP) MOOT_BINARY=$(MOOT_BINARY) MEASURE_PREREQS=snapshot

# The gates and the snapshot run ONCE for the pass; the lanes inherit them via
# MEASURE_PREREQS= (empty). Twelve lanes re-deriving receipt-based gates cost
# about 70 minutes on 2026-08-17 to produce about a second of measurement each.
smoke: snapshot swift-harness drift-stamp-current schema-gate determinism-current
	@mkdir -p $(SMOKE_OUT)
	# Keychain baseline (keychain-pollution guard, 2026-08-26): the pass
	# must mint ZERO moot keychain items — every harness estate is declared
	# ephemeral (identity keys in-memory) and plaintext-optout or
	# keyfile-backed (no db-key mints). A grown count after the arms is a
	# posture regression; smoke-check.sh compares against this file. The
	# 8-13→8-26 recurrence accumulated ~1,000 items before anyone noticed.
	@security dump-keychain 2>/dev/null \
	  | grep -c 'com\.mootx01\.estate\.identity\|com\.codedaptive\.mootx01' \
	  > $(SMOKE_OUT)/keychain-baseline.txt || echo 0 > $(SMOKE_OUT)/keychain-baseline.txt
	@printf '%s\n' \
	  "# lane arm kind — kind is 'report' (writes JSON) or 'stdout' (prints only)" \
	  "locomo all1 report" \
	  "lmeb all6 report" \
	  "lme s report" \
	  "membench ThirdAgent report" \
	  "matrix locomo report" \
	  "matrix lmeb report" \
	  "matrix lme-s report" \
	  "matrix membench-ThirdAgent report" \
	  "supersession gen stdout" \
	  "gauntlet official report" \
	  "journey disk report" \
	  "journey ram report" \
	  > $(SMOKE_OUT)/expected-arms.txt
	@echo "[smoke] one unit per arm -> $(SMOKE_OUT)"
	-@$(SMOKE_MK) measure-locomo   LIMIT=1 LOCOMO_CONVERSATIONS=1 > $(SMOKE_OUT)/locomo.log 2>&1 || echo "[smoke] locomo FAILED (see log)"
	-@$(SMOKE_MK) measure-lmeb     LIMIT=1 > $(SMOKE_OUT)/lmeb.log 2>&1 || echo "[smoke] lmeb FAILED (see log)"
	-@$(SMOKE_MK) measure-lme      LIMIT=1 > $(SMOKE_OUT)/lme.log 2>&1 || echo "[smoke] lme FAILED (see log)"
	-@$(SMOKE_MK) measure-membench LIMIT=1 MEMBENCH_AGENT=ThirdAgent > $(SMOKE_OUT)/membench.log 2>&1 || echo "[smoke] membench FAILED (see log)"
	-@for lane in locomo lmeb lme-s membench-ThirdAgent; do \
	    $(SMOKE_MK) measure-matrix LANE=$$lane MATRIX_LIMIT=1 MATRIX_PROBES=2 \
	      > $(SMOKE_OUT)/matrix-$$lane.log 2>&1 || echo "[smoke] matrix-$$lane FAILED (see log)"; \
	  done
	-@$(SMOKE_MK) measure-supersession > $(SMOKE_OUT)/supersession.log 2>&1 || echo "[smoke] supersession FAILED (see log)"
	-@$(SMOKE_MK) measure-gauntlet > $(SMOKE_OUT)/gauntlet.log 2>&1 || echo "[smoke] gauntlet FAILED (see log)"
	-@$(SMOKE_MK) measure-journey SHAPE=disk JOURNEY_PRECISE_MISS=1 JOURNEY_CLUSTERS=1 JOURNEY_MEMBERS=2 > $(SMOKE_OUT)/journey-disk.log 2>&1 || echo "[smoke] journey-disk FAILED (see log)"
	-@$(SMOKE_MK) measure-journey SHAPE=ram  JOURNEY_PRECISE_MISS=1 JOURNEY_CLUSTERS=1 JOURNEY_MEMBERS=2 > $(SMOKE_OUT)/journey-ram.log 2>&1 || echo "[smoke] journey-ram FAILED (see log)"
	@echo
	@scripts/smoke-check.sh $(SMOKE_OUT) $(SMOKE_OUT)/expected-arms.txt

RUN_ID := $(notdir $(OUT))
# $(1) test name, $(2) ARM, $(3) coverage fields.
#
# The sidecar is named <test>-<arm>-<serial>-params.json so it pairs with its
# report BY NAME. Before 2026-08-17 it was <test>-params.json: every arm of a
# multi-arm lane wrote one path, and the surviving sidecar labelled a report it
# did not describe. Naming a record by its make target rather than its arm is
# what let that happen.
define emit_params
	@mkdir -p $(OUT)
	@printf '%s\n' \
	  '{' \
	  '  "run_id": "$(RUN_ID)",' \
	  '  "lane": "$(1)",' \
	  '  "arm": "$(2)",' \
	  '  "make_target": "measure-$(1)",' \
	  '  "seed": "$(SEED)",' \
	  '  "cache_dir": "$(CACHE_DIR)",' \
	  '  "mootx01_binary": "$(MOOT_BINARY)",' \
	  '  "limit": "$(LIMIT)",' \
	  '  "coverage": { $(3) }' \
	  '}' > $(OUT)/$(1)-$(2)-$(RUN_ID)-params.json
	@echo "[make] params: $(OUT)/$(1)-$(2)-$(RUN_ID)-params.json"
endef


# The storage matrix. Both cells are served, which requires binaries built with
# -Xswiftc -DMOOTX01_HARNESS_KEYFILE; without it the encrypted cell refuses
# rather than reporting a cell it never served. LANE selects one set;
# MATRIX_LIMIT bounds a set and is recorded in the report as the measured scope.
MATRIX_PROBES ?= 8
MATRIX_LIMIT  ?=
MATRIX_LIMIT_FLAG := $(if $(MATRIX_LIMIT),--limit $(MATRIX_LIMIT),)

measure-matrix: $(MEASURE_PREREQS)
	@test -n "$$SMOKE_PROBE" || test -f $(SEEDING)/.smoke-ok-measure-matrix-swift || \
	  { echo "REFUSED: smoke gate not green — run 'make smoke-measure-matrix' first"; exit 1; }
	$(call emit_params,matrix,$(if $(LANE),$(LANE),allsets),"lane": "$(LANE)", "probes": $(MATRIX_PROBES))
	@mkdir -p $(OUT)
	$(SWIFT_BIN) matrix --run-id $(RUN_ID) --cache-dir $(CACHE_DIR) $(LANE_FLAG) \
	  --probes $(MATRIX_PROBES) $(MATRIX_LIMIT_FLAG) $(MOOT_FLAG) --out $(OUT)

# Timing. The only lane that restores prebuilt landscapes rather than ingesting
# one, so the ingest sits outside the measured window. ESTATE_MODE picks the
# at-rest posture; the two postures are separate runs because the difference
# between them is itself a reported figure.
LANDSCAPE_CACHE ?= $(BENCH_WORK_ROOT)/landscape-cache
ESTATE_MODE     ?= unencrypted
REPEATS         ?=
REPEATS_FLAG    := $(if $(REPEATS),--repeats $(REPEATS),)

measure-timing: $(MEASURE_PREREQS)
	@test -n "$$SMOKE_PROBE" || test -f $(SEEDING)/.smoke-ok-measure-timing-swift || \
	  { echo "REFUSED: smoke gate not green — run 'make smoke-measure-timing' first"; exit 1; }
	$(call emit_params,timing,$(ESTATE_MODE),"estate_mode": "$(ESTATE_MODE)", "landscape": "$(LANDSCAPE_CACHE)")
	@if [ ! -d "$(LANDSCAPE_CACHE)" ] || [ -z "$$(ls -A $(LANDSCAPE_CACHE) 2>/dev/null)" ]; then \
	  echo "[make] REFUSING: no landscapes in $(LANDSCAPE_CACHE). Build them first:"; \
	  echo "       make landscape"; exit 1; \
	fi
	@mkdir -p $(OUT)
	$(SWIFT_BIN) timing --run-id $(RUN_ID) --run-mode quiet --estate-mode $(ESTATE_MODE) \
	  --landscape corpus --landscape-cache $(LANDSCAPE_CACHE) \
	  $(REPEATS_FLAG) $(MOOT_FLAG) --out $(OUT)

# Landscape build. NOT a measurement: it may run on a loaded machine, and it
# resumes from the largest stored size rather than rebuilding what exists.
# Intermediate checkpoints exist to make an interrupted build cheap. A
# landscape is snapshotted only at a declared size, so a run stopped between
# 10,000 and 100,000 loses everything built since the last one — 24,000 rows
# and two hours, on 2026-08-16. The extra snapshots cost about 30 GB and turn a
# six-hour build into one resumable in roughly hourly steps.
#
# They do not change the landscape: sizes are monotonic prefixes, so the
# 100,000-row landscape is the same rows either way. A timing run asking for
# 2000,10000,100000 simply ignores the sizes it did not ask for.
LANDSCAPE_SIZES ?= 2000,10000,25000,50000,75000,100000
landscape: swift-harness
	$(SWIFT_BIN) landscape-build --cache-dir $(LANDSCAPE_CACHE) \
	  --sizes $(LANDSCAPE_SIZES) --landscape corpus \
	  --landscape-data-dir $(LME_DATA_DIR) $(MOOT_FLAG)

# Lanes that generate their own data from a seed. No prebuilt set is involved,
# so these are the cheapest complete numbers in the suite.
measure-supersession: $(MEASURE_PREREQS)
	@test -n "$$SMOKE_PROBE" || test -f $(SEEDING)/.smoke-ok-measure-supersession-swift || \
	  { echo "REFUSED: smoke gate not green — run 'make smoke-measure-supersession' first"; exit 1; }
	$(call emit_params,supersession,gen,"generated": true)
	@mkdir -p $(OUT)
	# No --out: this lane reports to stdout rather than writing a JSON file,
	# and the run script captures each lane's stdout into the output directory.
	$(SWIFT_BIN) supersession --run-id $(RUN_ID) $(MOOT_FLAG)

SHAPE ?= disk
# Journey generates its own corpus, so its scope is the generator's counts
# rather than LIMIT. Defaults match the generator's own defaults; the smoke
# pass narrows them to one scenario and one cluster so an arm is one unit.
# members-per-cluster has a floor of 2: a cluster needs something to narrow
# among, which is the entire point of the VAGUE-NARROW lane.
JOURNEY_PRECISE_MISS ?= 20
JOURNEY_CLUSTERS     ?= 10
JOURNEY_MEMBERS      ?= 6
measure-journey: $(MEASURE_PREREQS)
	@test -n "$$SMOKE_PROBE" || test -f $(SEEDING)/.smoke-ok-measure-journey-$(PORT) || \
	  { echo "REFUSED: smoke gate not green — run 'make smoke-measure-journey PORT=$(PORT)' first"; exit 1; }
	$(call emit_params,journey,$(SHAPE),"generated": true, "shape": "$(SHAPE)")
	@mkdir -p $(OUT)
	$(SWIFT_BIN) journey --run-id $(RUN_ID) --shape $(SHAPE) \
	  --precise-miss-count $(JOURNEY_PRECISE_MISS) \
	  --cluster-count $(JOURNEY_CLUSTERS) \
	  --members-per-cluster $(JOURNEY_MEMBERS) $(MOOT_FLAG) --out $(OUT)

# The gauntlet's corpus is a pure function of the seed, so it is generated here
# rather than carried between runs.
GAUNTLET_CONFIG_TEMPLATE := configs/gauntlet-moot.json
GAUNTLET_CONFIG ?= $(BENCH_WORK_ROOT)/config/gauntlet-moot.json
GAUNTLET_SEED   ?= 20260725
# The lane's arm. It names the record (gauntlet-<arm>-<serial>.json) and the
# sidecar, so the two pair by name; the runner takes the same value as its
# --run-label.
GAUNTLET_RUN_LABEL ?= official

# Where the lane's served estate lives. Read from the config's own stdio
# command so this Makefile keeps no second copy of the path: the scratch
# directory is the token after `--db` (the product's transient-record
# selector). JSON is parsed with a JSON reader; only the command string itself
# is split.
define GAUNTLET_DATA_DIR_PY
import json, sys, shlex
cfg = json.load(open(sys.argv[1]))
tokens = shlex.split(cfg["source"]["transport"]["stdio"]["command"])
for i, token in enumerate(tokens[:-1]):
    if token == "--db":
        print(tokens[i + 1]); break
endef
export GAUNTLET_DATA_DIR_PY

gauntlet-config: moot-binary
	python3 scripts/render-gauntlet-config.py --template $(GAUNTLET_CONFIG_TEMPLATE) \
	  --output $(GAUNTLET_CONFIG) --binary $(MOOT_BINARY) --work-root $(BENCH_WORK_ROOT)

measure-gauntlet: $(MEASURE_PREREQS) gauntlet-config
	@test -n "$$SMOKE_PROBE" || test -f $(SEEDING)/.smoke-ok-measure-gauntlet-$(PORT) || \
	  { echo "REFUSED: smoke gate not green — run 'make smoke-measure-gauntlet PORT=$(PORT)' first"; exit 1; }
	$(call emit_params,gauntlet,$(GAUNTLET_RUN_LABEL),"generated": true, "gauntlet_seed": "$(GAUNTLET_SEED)")
	@mkdir -p $(OUT)
	# The lane serves an EPHEMERAL estate: the database key lives in process
	# memory and is gone when the run ends, so anything left in the data dir is
	# permanently unopenable. A second run then dies on it with "file is not a
	# database" before it issues a single query, which is how this lane failed
	# on 2026-08-17. Clearing belongs here rather than in the serving process,
	# which cannot know whether it owns what it finds. The /tmp guard mirrors
	# assertScratchBackend's own refusal.
	@dir=$$(python3 -c "$$GAUNTLET_DATA_DIR_PY" $(GAUNTLET_CONFIG)); \
	  [ -n "$$dir" ] || { echo "[make] REFUSING: no --db scratch directory in $(GAUNTLET_CONFIG)"; exit 1; }; \
	  canon=$$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$$dir"); \
	  case "$$canon" in \
	    /tmp/?*|/private/tmp/?*) if [ -e "$$canon" ]; then \
	              echo "[make] clearing ephemeral gauntlet estate: $$canon"; rm -rf "$$canon"; \
	            fi ;; \
	    *) echo "[make] REFUSING: gauntlet data dir resolves outside /tmp: $$dir -> $$canon"; exit 1 ;; \
	  esac
	$(PORT_BENCH_BIN) gauntlet-corpus --seed $(GAUNTLET_SEED) --out $(OUT)/gauntlet-corpus
	# No $(MOOT_FLAG): both ports accept --config and derive the binary from the
	# config's stdio command. Swift rejects --mootx01-binary outright. Rust
	# additionally accepts --binary/--mootx01-binary as a Rust-only override
	# that takes precedence over --config; those flags are not used here.
	# $(PORT_BENCH_BIN) selects swift (PORT=swift) or rust (PORT=rust).
	$(PORT_BENCH_BIN) gauntlet --config $(GAUNTLET_CONFIG) --corpus $(OUT)/gauntlet-corpus \
	  --run-label $(GAUNTLET_RUN_LABEL) --run-id $(RUN_ID) --out $(OUT)

# ── Archive and local cleanup ───────────────────────────────────────────────
#
# Artifacts live in two places: the working copy under this directory, which
# measurement runs read, and the archive on external storage, which is the
# permanent home. Moving between them is two separate operations on purpose.
#
#   make archive       copy the working copies to the archive (never deletes)
#   make archive-verify compare the two, unit by unit, and report
#   make clean-local   remove a working copy ONLY where the archive verifies
#
# The split is the safety property. `archive` cannot delete anything, and
# `clean-local` cannot delete a unit the archive does not already hold. A
# clean against an absent or empty archive refuses outright, and any unit that
# fails verification is kept and named.
#
# Verification compares file counts and byte totals per unit rather than
# hashing hundreds of gigabytes; see the header of scripts/artifact-archive.sh
# for exactly what that does and does not cover.
#
# PROVE IT FIRST: `make selftest-archive` runs the whole thing against
# throwaway directories, including the refusal cases. It touches no real
# artifact and no real archive.
#
# Archive cleanup is always preceded by its destructive-path self-test. Local
# snapshots provide rollback; archive verification is the authorization for
# deletion.
# Durable archive for estate caches. The public default lives under the work
# root; a machine that keeps its archive on a dedicated volume overrides it
# from the environment (ARCHIVE_ROOT=/path/to/volume make archive). Never put
# a volume or user path here: this file is published.
ARCHIVE_ROOT ?= $(BENCH_WORK_ROOT)/archive
ARCHIVE_SH   := scripts/artifact-archive.sh

.PHONY: archive archive-verify clean-local selftest-archive

selftest-archive:
	@bash scripts/artifact-archive-selftest.sh

archive: selftest-archive
	@bash $(ARCHIVE_SH) copy $(CACHE_DIR) $(ARCHIVE_ROOT)/estate-cache
	@bash $(ARCHIVE_SH) copy $(LANDSCAPE_CACHE) $(ARCHIVE_ROOT)/landscape-cache

archive-verify:
	@bash $(ARCHIVE_SH) verify $(CACHE_DIR) $(ARCHIVE_ROOT)/estate-cache
	@bash $(ARCHIVE_SH) verify $(LANDSCAPE_CACHE) $(ARCHIVE_ROOT)/landscape-cache

# Runs the selftest first, every time. The one command in this Makefile that
# deletes artifacts does not run until the logic that decides what to delete
# has proved itself on throwaway data.
clean-local: selftest-archive
	@bash $(ARCHIVE_SH) clean $(CACHE_DIR) $(ARCHIVE_ROOT)/estate-cache
	@bash $(ARCHIVE_SH) clean $(LANDSCAPE_CACHE) $(ARCHIVE_ROOT)/landscape-cache

# ── Refresh (re-settle an existing fleet, no re-ingest) ─────────────────────
#
# Artifacts are not all-or-nothing. Only a SCHEMA change voids them:
#
#   schema change       estates are the wrong shape  -> make artifacts (rebuild)
#   calculation change  right corpus, older math     -> make refresh
#   no change           reuse as-is                  -> make measure
#
# A calculation change (recall weights, fusion, distillation, basis math)
# leaves the corpus correct and only the derived state stale. Refresh restores
# each estate, runs the build's own settle sequence (dream, basis retrain,
# drain), and writes the snapshot back. No corpus is re-ingested.
#
# The scale difference is what makes this worth a target rather than a rebuild:
# measured 2026-08-16, a LongMemEval fleet is 500 artifacts / 171 GB and a
# MemBench fleet is 7,000 / ~322 GB. Rebuilding those to recompute derived
# state is hours of ingest to arrive back at corpora that never changed.
#
# Every estate is independent and gets its own stdio process, so this runs wide;
# the harness defaults the width to the core count because the bound is CPU
# (encode and basis math), not I/O. Override with PARALLEL=N.
#
# A schema change surfaces here as a provenance hard-fail per artifact rather
# than a silent rebuild — that failure is the signal to run `make artifacts`.
#
# LANE=<substring> refreshes one fleet (LANE=locomo, LANE=lme-s, ...).
LANE     ?=
PARALLEL ?=
LANE_FLAG     := $(if $(LANE),--lane $(LANE),)
PARALLEL_FLAG := $(if $(PARALLEL),--parallel $(PARALLEL),)

refresh: swift-harness
	$(SWIFT_BIN) refresh --cache-dir $(CACHE_DIR) $(MOOT_FLAG) $(LANE_FLAG) $(PARALLEL_FLAG)
	@echo "[make] fleet re-settled — re-run 'make drift-gate' before measuring"

# ── Backfill staged estates (schema + data convergence, no re-ingest) ───────
#
# Converges every staged estate under STAGING_DIR to the current product
# schema, in two steps per estate:
#
#   1. serve-open — launch `mootx01 serve --db <dir>` over stdio (the staged
#      estate as a transient record) with stdin at EOF. The open path runs the
#      product's open-time schema migrations, then serve exits on the closed
#      stdin. stdout (MCP framing) is discarded; stderr (the serve log) is
#      kept.
#   2. `mootx01 upgrade --backfill-only` — the data-directory moves (kg_facts
#      identity, adornment store migration, shared-content reclaim), which
#      assume the schema step 1 just brought current. No network, no plugin
#      convergence, no encryption offer.
#
# Both steps are idempotent (the backfill's moves are per-row atomic), so the
# loop fails FAST on the first broken estate and a re-run after the fix picks
# up where it left off without harm.
#
# Layout: a staged estate is any directory holding an estate.sqlite at its
# root (the flat default-estate layout every harness snapshot uses), found at
# any depth under STAGING_DIR — same discovery convention as
# scripts/estate-schema-restamp.sh. The named-estate layout
# (databases/<name>/estate.sqlite) is refused rather than mis-resolved.
#
# A transient record keeps its identity in memory and is plaintext by rule
# (zero Keychain contact); a staged estate already exists, so nothing is created.
#
# Registered-path guard is intentionally absent here. The product-config dir
# guard in `mootServeCommand`/`moot_serve_command` protects *benchmark lanes*
# from accidentally targeting live registered estates during automated runs.
# `backfill-staging` is an operator maintenance tool: the operator explicitly
# names a staging directory and may legitimately place it anywhere on the
# filesystem. Refusing based on path prefix would prevent valid migration
# workflows. INTENTIONALLY_LEFT — see BLAST_RADIUS report, `backfill-staging`.
STAGING_DIR ?=

backfill-staging: moot-binary
	@if [ -z "$(STAGING_DIR)" ] || [ ! -d "$(STAGING_DIR)" ]; then \
	  echo "[make] REFUSING: STAGING_DIR must name an existing directory of staged estates."; \
	  echo "       make backfill-staging STAGING_DIR=/path/to/staging"; \
	  exit 1; \
	fi
	@set -e; \
	list=$$(find "$(STAGING_DIR)" -name estate.sqlite -type f | sort); \
	if [ -z "$$list" ]; then \
	  echo "[make] REFUSING: no estate.sqlite under $(STAGING_DIR) — nothing to backfill."; exit 1; \
	fi; \
	n=0; \
	for db in $$list; do \
	  dir=$$(dirname "$$db"); \
	  case "$$dir" in */databases/*) \
	    echo "[make] REFUSING: named-estate layout not supported: $$db"; \
	    echo "       backfill-staging expects the flat default layout (<dir>/estate.sqlite)."; \
	    exit 1 ;; \
	  esac; \
	  echo "[backfill] serve-open  $$dir"; \
	  "$(MOOT_BINARY)" serve --db "$$dir" < /dev/null > /dev/null; \
	  echo "[backfill] backfill    $$dir"; \
	  "$(MOOT_BINARY)" upgrade --db "$$dir" --backfill-only; \
	  n=$$((n + 1)); \
	done; \
	echo "[backfill] $$n estate(s) converged in $(STAGING_DIR)"

# ── Lifecycle ────────────────────────────────────────────────────────────────

# make clean: every artifact is reproducible from its declared inputs, so the
# store is always safe to delete. No keychain teardown is required today (see
# the D4 note in the header) — if a future target mints keychain items, its
# ledger teardown belongs HERE, loudly.
clean:
	@python3 scripts/work-root.py clean --repo "$(REPO_ROOT)" --work "$(BENCH_WORK_ROOT)" --keep archive
	@echo "[make] external work root emptied: $(BENCH_WORK_ROOT)"

# ── Setup and teardown (the work root's whole life) ─────────────────────────
# setup creates the external work root and fills it from nothing: the source
# corpora (fetch), both product binaries and both benchmarkers (binaries),
# and the seed projections (seeds). teardown empties it and removes the
# directory, cache included. Nothing in the work root is hand-made; a run
# after `make teardown setup` is the proof.
.PHONY: setup teardown
setup: fetch binaries seeds
	@echo "[make] work root ready: $(BENCH_WORK_ROOT)"

teardown:
	@python3 scripts/work-root.py clean --repo "$(REPO_ROOT)" --work "$(BENCH_WORK_ROOT)"
	@rm -rf "$(CACHE_DIR)" "$(BENCH_WORK_ROOT)"
	@echo "[make] work root removed: $(BENCH_WORK_ROOT)"

# ── Storage configuration (survives teardown) ───────────────────────────────
# One config file names the three storage roles (Bob, 2026-09-17):
#   internal_primary    the internal folder every artifact is built in and
#                       served from (artifact rules: built, settled and run
#                       on internal disk)
#   external_storage_1  the first external volume finished sets are stashed
#                       to and restored from
#   external_storage_2  the overflow volume, used when the first is full
# It lives in a config peer of the work root, never inside it, so teardown
# cannot erase it; `make config` writes the template (internal primary =
# the benchmark-cache peer of the repository, both externals empty) and
# prints it — edit the externals to name the machine's volumes. The artifact builder's target map (spec R1) is
# derived from it: every set is laid out under the internal primary.
# TARGET_MAP= on a build target still overrides for one run (the smoke keeps
# its own map).
BENCH_CONFIG_DIR ?= $(dir $(patsubst %/,%,$(BENCH_WORK_ROOT)))benchmark-config
STORAGE_CONFIG   ?= $(BENCH_CONFIG_DIR)/storage.json
storage_role = $(shell python3 -c 'import json,sys; print(json.load(open("$(STORAGE_CONFIG)")).get("$(1)",""))' 2>/dev/null)
# Default internal primary: the benchmark-cache peer of the repository (the
# layout rule: artifact databases live there and nothing else does). Derived
# from WORK_ANCHOR, not from BENCH_WORK_ROOT: the work root is operator-
# overridable to any absolute path, and a peer computed from it would land
# the cache beside whatever folder the operator chose instead of beside the
# repository.
INTERNAL_PRIMARY   := $(or $(call storage_role,internal_primary),$(abspath $(WORK_ANCHOR)/../benchmark-cache))
EXTERNAL_STORAGE_1 := $(call storage_role,external_storage_1)
EXTERNAL_STORAGE_2 := $(call storage_role,external_storage_2)
.PHONY: config
config:
	@mkdir -p $(BENCH_CONFIG_DIR)
	@test -f $(STORAGE_CONFIG) || printf '%s\n' \
	  '{' \
	  '  "internal_primary": "$(INTERNAL_PRIMARY)",' \
	  '  "external_storage_1": "",' \
	  '  "external_storage_2": ""' \
	  '}' > $(STORAGE_CONFIG)
	@echo "[make] storage config: $(STORAGE_CONFIG)"
	@cat $(STORAGE_CONFIG)

# ── Artifact movement (external storage in and out) ─────────────────────────
# A finished dataset lives at <internal primary>/<port>/<ds>/. stash copies
# it out to the first external store with room for it (external_storage_1,
# else external_storage_2; EXTERNAL= names one explicitly) and removes the
# internal copy; restore finds it on either store and copies it back under
# the internal primary for a run. Plain copies (cp -c clones on APFS); both
# refuse to overwrite a destination that already exists.
.PHONY: stash-artifacts restore-artifacts
STASH_SRC = $(INTERNAL_PRIMARY)/$(PORT)/$(DS)
stash-artifacts:
	@test -d $(STASH_SRC) || { echo "error: nothing built at $(STASH_SRC)"; exit 2; }
	@need=$$(du -sk $(STASH_SRC) | cut -f1); dest=""; \
	 for cand in $(EXTERNAL) $(EXTERNAL_STORAGE_1) $(EXTERNAL_STORAGE_2); do \
	   [ -d "$$cand" ] || continue; free=$$(df -k "$$cand" | tail -1 | awk '{print $$4}'); \
	   [ "$$free" -gt "$$need" ] && { dest=$$cand; break; }; done; \
	 [ -n "$$dest" ] || { echo "error: no external store with $$need KB free (config: $(STORAGE_CONFIG))"; exit 2; }; \
	 [ ! -e "$$dest/$(PORT)/$(DS)" ] || { echo "error: $$dest/$(PORT)/$(DS) exists; remove it first"; exit 2; }; \
	 mkdir -p "$$dest/$(PORT)"; \
	 cp -c -R $(STASH_SRC) "$$dest/$(PORT)/$(DS)" 2>/dev/null || cp -R $(STASH_SRC) "$$dest/$(PORT)/$(DS)"; \
	 rm -rf $(STASH_SRC); \
	 $(call relocate_catalog,$$dest); \
	 echo "[make] stashed $(PORT)/$(DS) -> $$dest/$(PORT)/$(DS) ($$(du -sh "$$dest/$(PORT)/$(DS)" | cut -f1))"

restore-artifacts:
	@test ! -e $(STASH_SRC) || { echo "error: $(STASH_SRC) exists; remove it first"; exit 2; }
	@src=""; for cand in $(EXTERNAL) $(EXTERNAL_STORAGE_1) $(EXTERNAL_STORAGE_2); do \
	   [ -d "$$cand/$(PORT)/$(DS)" ] && { src=$$cand; break; }; done; \
	 [ -n "$$src" ] || { echo "error: $(PORT)/$(DS) is not on any external store (config: $(STORAGE_CONFIG))"; exit 2; }; \
	 mkdir -p $(INTERNAL_PRIMARY)/$(PORT); \
	 cp -c -R "$$src/$(PORT)/$(DS)" $(STASH_SRC) 2>/dev/null || cp -R "$$src/$(PORT)/$(DS)" $(STASH_SRC); \
	 $(call relocate_catalog,$(INTERNAL_PRIMARY)); \
	 echo "[make] restored $(PORT)/$(DS) <- $$src/$(PORT)/$(DS)"

# A catalog records each set's absolute base folder, so a moved dataset gets
# its catalog rewritten for the folder it now sits in (every estate_set* and
# the aggregate under <base>/<port>/<ds>). relocate-catalog does it alone for
# a dataset moved by hand; BASE= names the folder it now sits in.
define relocate_catalog
python3 $(SEEDING_TOOLS)/artifact_layout.py write-catalog --primary-base "$(1)" --port $(PORT) --dataset $(DS) \
	   $$(for d in "$(1)"/$(PORT)/$(DS)/estate_set* "$(1)"/$(PORT)/$(DS)/aggregate; do [ -d "$$d" ] && printf -- '--set-base %s --set-path %s ' "$(1)" "$(PORT)/$(DS)/$$(basename "$$d")"; done)
endef
.PHONY: relocate-catalog
relocate-catalog:
	@test -n "$(BASE)" || { echo "error: BASE=<folder the dataset now sits in> is required"; exit 2; }
	@$(call relocate_catalog,$(BASE))
	@echo "[make] catalog rewritten for $(BASE)/$(PORT)/$(DS)"

# ── Log bundle ──────────────────────────────────────────────────────────────
# Every log the work root holds (builder, watcher, import, drain, measure,
# smoke) into one date-stamped zip in a logs peer of the work root, so a run
# can be handed over or filed without the estates.
BENCH_LOGS_DIR ?= $(dir $(patsubst %/,%,$(BENCH_WORK_ROOT)))benchmark-logs
.PHONY: logs
logs:
	@mkdir -p $(BENCH_LOGS_DIR)
	@stamp=$$(date -u +%Y%m%dT%H%M%SZ); \
	 ( cd $(BENCH_WORK_ROOT) && find . -type f \( -name '*.log' -o -name '*.txt' -o -name 'SUMMARY*' -o -name 'summary.json' \) -not -path './build/*' -not -path './fixtures/*' \
	   | zip -q $(BENCH_LOGS_DIR)/logs-$$stamp.zip -@ ) && \
	 echo "[make] $(BENCH_LOGS_DIR)/logs-$$stamp.zip ($$(du -sh $(BENCH_LOGS_DIR)/logs-$$stamp.zip | cut -f1))"

rebuild: clean
	$(MAKE) -j$(JOBS) artifacts

# ── Estate seeding + fleet builds (reproducible entry points) ────────────────
#
# The seeding pipeline projects each public dataset into the estate the
# product would have built (BENCHMARK_ESTATES.md: the two filing rules,
# rooms/wings, the two artifact forms) and imports it through the product's
# own moot_json_import. These targets are the ONLY sanctioned way to build
# the estate artifacts — a result is reproducible exactly because the same
# make invocation rebuilds the same estates from the same fixtures.
#
# Parallelism: FLEET_JOBS workers per fleet target (unit builds are
# independent single-core serves, so the knob scales linearly until the
# machine runs out of cores). FLEET_ROOT names where fleets land — the
# storage config's internal primary.
#
# Resumable: every target skips work that already exists (units with an
# import-output.txt, seeds already on disk are regenerated deterministically
# in place), so interrupting and re-running converges instead of repeating.

# Worker sizing (measured 2026-08-28): fleet import workers are gate-bound,
# not compute-bound, so the machine sustains ~10 workers per performance
# core. Solo default below = 10 x perflevel0 cores. When OTHER benchmark
# builds share the machine, pass FLEET_JOBS=20 (up to 30) instead.
PERF_CORES := $(shell sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4)
FLEET_JOBS ?= $(shell echo $$(( $(PERF_CORES) * 10 )))
# Fleet root: the storage config's internal primary, where every artifact
# is built and served from (see the storage configuration section).
FLEET_ROOT = $(INTERNAL_PRIMARY)

# ── Port resolution (run book §1.4) ─────────────────────────────────────────
# Every build, smoke, and measure command takes the same PORT variable.
# The port selects the product binary, the benchmarker, and the port's
# subtree of each artifact root; the command name never changes. Gate
# stamps carry the port, so each port gates independently.
PORT ?= swift
RUST_BIN  := $(PRODUCT_RUST_BUILD_DIR)/release/mootx01
WING_ROOT ?= $(BENCH_WORK_ROOT)/wing-store
ifeq ($(PORT),swift)
  PORT_MOOT_BIN  := $(MOOT_BINARY)
  PORT_BENCH_BIN := $(SWIFT_BIN)
else ifeq ($(PORT),rust)
  PORT_MOOT_BIN  := $(RUST_BIN)
  PORT_BENCH_BIN := $(RUST_BENCH_BIN)
else
  $(error PORT must be swift or rust; got '$(PORT)')
endif
PORT_FLEETS = $(FLEET_ROOT)/$(PORT)
PORT_WINGS  := $(WING_ROOT)/$(PORT)

# Form-2 seed file per wing key (locomo/convomem/membench are the
# wing-per-instance estates; lme-s is the deduplicated estate; complete
# is the one-database estate).
WING_SEED_locomo   := out-locomo/wing-estate.json
WING_SEED_convomem := out-convomem/wing-estate.json
WING_SEED_membench := out-membench/wing-estate.json
WING_SEED_lme-s    := out-lme-s/aggregate.json
WING_SEED_complete := out-complete/aggregate.json
WING_KEYS := locomo convomem membench lme-s complete

# Regenerate every seed projection at full fleet size (deterministic:
# same fixtures in, same seeds out; --limit caps are lifted to the full
# instance counts).
# One dataset at a time (the builder goes smallest first; see the artifact
# builder spec §4). `seeds` remains the all-four form.
.PHONY: seed-locomo seed-lme-s seed-convomem seed-membench
seed-locomo:
	mkdir -p $(SEEDING)
	python3 $(SEEDING_TOOLS)/seed_locomo.py --fixture $(LOCOMO_JSON) --out $(SEEDING)/out-locomo
seed-lme-s:
	mkdir -p $(SEEDING)
	python3 $(SEEDING_TOOLS)/seed_lme_s.py --fixture $(LME_DATA_DIR)/longmemeval_s_cleaned.json --out $(SEEDING)/out-lme-s --limit 500
seed-convomem:
	mkdir -p $(SEEDING)
	python3 $(SEEDING_TOOLS)/seed_convomem.py --fixture-root $(LMEB_DATA_DIR) --out $(SEEDING)/out-convomem --limit 99999
seed-membench:
	mkdir -p $(SEEDING)
	python3 $(SEEDING_TOOLS)/seed_membench.py --fixture-root $(MEMBENCH_DATA_DIR) --out $(SEEDING)/out-membench --limit 99999

seeds:
	mkdir -p $(SEEDING)
	python3 $(SEEDING_TOOLS)/seed_lme_s.py --fixture $(LME_DATA_DIR)/longmemeval_s_cleaned.json --out $(SEEDING)/out-lme-s --limit 500
	python3 $(SEEDING_TOOLS)/seed_locomo.py --fixture $(LOCOMO_JSON) --out $(SEEDING)/out-locomo
	python3 $(SEEDING_TOOLS)/seed_convomem.py --fixture-root $(LMEB_DATA_DIR) --out $(SEEDING)/out-convomem --limit 99999
	python3 $(SEEDING_TOOLS)/seed_membench.py --fixture-root $(MEMBENCH_DATA_DIR) --out $(SEEDING)/out-membench --limit 99999
	python3 $(SEEDING_TOOLS)/build_complete.py --root $(SEEDING)

# One Form-1 fleet: estate-per-instance for every unit of one dataset,
# on the selected port, laid out in the v0.8 catalog layout.
# Delegates to build-dataset (artifact_build.py) which writes the catalog
# and places estates under the target-map bases.
#
# GATE: two stamps are possible after smoke-builder runs.
#   .smoke-ok-builder-binary-<port>  BUILDER_EXE was a product binary;
#       the builder pipeline and product binary were both exercised on one
#       unit.  This stamp satisfies the gate directly.
#   .smoke-ok-builder-faker-<port>   BUILDER_EXE was the default faker
#       (mootx01_faker.py); only the builder pipeline on synthetic data was
#       proven.  The product binary was NOT exercised.  This stamp does NOT
#       satisfy the gate on its own — pass FLEET_GATE=faker explicitly to
#       proceed and acknowledge the weaker proof.
# The binary stamp is written by `make smoke-builder PORT=<port> PRODUCT=1`,
# which runs the line on the product binary through the seam. The refusal
# below tells the operator this plainly.
# SMOKE_PROBE is a deliberate manual operator override; it also travels into
# recursive make calls inside smoke_gate.sh for other targets.
fleet-lme-s fleet-locomo fleet-convomem fleet-membench: fleet-%:
	@test -n "$$SMOKE_PROBE" \
	  || test -f $(SEEDING)/.smoke-ok-builder-binary-$(PORT) \
	  || { test "$(FLEET_GATE)" = "faker" \
	       && test -f $(SEEDING)/.smoke-ok-builder-faker-$(PORT); } \
	  || { echo "REFUSED: fleet build requires .smoke-ok-builder-binary-$(PORT)."; \
	       echo "  smoke-builder at defaults only exercises the builder pipeline on synthetic"; \
	       echo "  data (faker); it does not prove the product binary. Write the binary stamp with:"; \
	       echo "    make smoke-builder PORT=$(PORT) PRODUCT=1"; \
	       echo "  To proceed with only the faker assembly-line smoke, pass FLEET_GATE=faker:"; \
	       echo "    FLEET_GATE=faker make fleet-$* PORT=$(PORT)"; \
	       exit 1; }
	$(MAKE) -C $(CURDIR) build-dataset PORT=$(PORT) DS=$* PRODUCT=1 \
	  $(if $(FLOOR),FLOOR=$(FLOOR),) $(if $(TARGET_MAP),TARGET_MAP=$(TARGET_MAP),) \
	  $(if $(LIMIT),LIMIT=$(LIMIT),) $(if $(UNITS),UNITS="$(UNITS)",)

# Every Form-1 fleet. Serial across datasets by default so FLEET_JOBS is
# the machine-wide worker count; run with make -j4 to overlap datasets and
# multiply the knobs deliberately.
fleets: fleet-lme-s fleet-locomo fleet-convomem fleet-membench

# Form-2 estates: the wing-per-instance files, the deduplicated
# LongMemEval estate, and the complete one-database estate, on the
# selected port. Import is windowed and drain-gated; each build is
# idempotent and convergent (run book §5): absent imports, a
# partially-encoded estate resumes, a converged estate verifies and
# exits clean. One stock target per estate; `wing-estates` runs all
# five serially (make -j5 overlaps). Each full build refuses to run
# until 'make smoke-wing-<ds> PORT=<port>' has stamped its gate green.
# SMOKE_PROBE=1 marks the gate's own inner probe invocation, the one
# build allowed through un-stamped.
# Full builds carry a 48h drain budget: the big wings (membench 152k,
# complete 185k records) need many hours of encode + inline mint, and the
# driver's 2400s default is a probe-scale budget that would abandon them
# mid-drain. Probes never see this value — the smoke window stops them
# first.
IMPORT_DRAIN_TIMEOUT ?= 172800

wing-estate-locomo wing-estate-convomem wing-estate-membench \
wing-estate-lme-s wing-estate-complete: wing-estate-%:
	@test -n "$$SMOKE_PROBE" || test -f $(SEEDING)/.smoke-ok-wing-$*-$(PORT) || \
	  { echo "REFUSED: smoke gate not green — run 'make smoke-wing-$* PORT=$(PORT)' first"; exit 1; }
	cd $(SEEDING) && MOOTX01_BINARY=$(PORT_MOOT_BIN) \
	  IMPORT_DRAIN_TIMEOUT=$(IMPORT_DRAIN_TIMEOUT) \
	  python3 -u $(SEEDING_TOOLS)/import_units.py \
	  --file $(WING_SEED_$*) --estates-dir $(PORT_WINGS) --estate-name $*

wing-estates: wing-estate-locomo wing-estate-convomem wing-estate-membench \
	wing-estate-lme-s wing-estate-complete

# Estate artifact build aggregate: seeds → fleets → wing-estates.
artifacts: seeds fleets wing-estates

# ── Smoke gate (smoke doctrine, Bob 2026-08-28) ─────────────────────────────
# A smoke test is ONE short pass that builds the test vehicle, followed by
# a thorough review that the data is EXACTLY the shape it is supposed to
# be. smoke_gate.sh echoes the checklist, builds the specimen through the
# SAME stock recipe (stopped at the smoke window if still running), runs
# the automated shape review (seeding/smoke_verify.py — exact equalities
# against the seed's own numbers), and stamps .smoke-ok-*-$(PORT) on
# green. The full-build targets above refuse to run without their stamp.
# A specimen that completes inside the window is verified strictly and
# KEPT (it is the real artifact — locomo finishes inside); a stopped
# probe is verified in bounded --partial mode and deleted (strict-append
# import is not resumable). Stamps live in $(SEEDING); re-running a smoke
# target always rebuilds the specimen and re-stamps.
#
# Window: each target carries a window sized to its dataset. membench
# (152k records) and complete (185k) both parse a 300-500MB seed, write
# 120k-record window parts, and must land their first drawers inside the
# window — 1200s covers that; a 300s window expires before the first
# drawer lands and the probe's subject check RED-fails on an empty
# estate. Every other dataset carries 300. SMOKE_SECONDS overrides.
SMOKE_WINDOW = $(or $(SMOKE_SECONDS),$(if $(filter membench complete,$*),1200,300))

smoke-wing-locomo smoke-wing-convomem smoke-wing-membench \
smoke-wing-lme-s smoke-wing-complete: smoke-wing-%:
	cd $(SEEDING) && $(SEEDING_TOOLS)/smoke_gate.sh $(WING_SEED_$*) \
	  $(PORT_WINGS)/$* .smoke-ok-wing-$*-$(PORT) $(SMOKE_WINDOW) \
	  -- env SMOKE_PROBE=1 $(MAKE) -C $(CURDIR) wing-estate-$* PORT=$(PORT)

smoke-wings: smoke-wing-locomo smoke-wing-convomem smoke-wing-membench \
	smoke-wing-lme-s smoke-wing-complete

# Fleet assembly-line smoke: use 'make smoke-builder PORT=<port>' (§8 of the
# run book) to verify the builder and binary before running fleet-*.
# smoke-fleet-* wrote into the retired estates/ directory layout and has been
# removed; smoke-builder is the replacement.
smoke-fleets: smoke-builder

# ── Measure smoke + release-candidate validation ────────────────────────────
# smoke-measure-<ds>: a tiny artifact-recall pass (the measure vehicle)
# against the selected port's Form-2 estate, then measure_verify.py
# reviews the RECEIPT with the same exactness smoke_verify.py applies to
# an estate — every question got a call-return, the report carries every
# field the ramp relies on, returned ids map through the id-map.
# Mechanism only, NEVER scores: retrieval quality is the ramp's question,
# on settled artifacts, one pass per cell. Requires the estate present
# (built via its smoke-gated wing-estate target). Stamps
# .smoke-ok-measure-<ds>-$(PORT). lme-s measures unscoped (the deduped
# estate has no instance wings); the complete-estate smoke measures
# locomo questions unscoped with dataset-prefixed ground truth.
SMOKE_MEASURE_Q ?= 3
MEASURE_SCOPE = $(if $(filter lme-s,$*),estate,wing)

# The smoke measures at the same SCALE the measurement will (default
# bench-aggregate = the wing estate; SCALE=unit = the per-unit fleet through
# its catalog), so a fleet-only build can smoke and measure without a wing.
PORT_HARNESS = $(if $(filter rust,$(PORT)),rust-harness,swift-harness)
smoke-measure-locomo smoke-measure-convomem smoke-measure-membench \
smoke-measure-lme-s: smoke-measure-%: $(PORT_HARNESS)
	cd $(SEEDING) && $(PORT_BENCH_BIN) artifact-recall --dataset $* \
	  --target-scale $(SCALE) $(MEASURE_DIR_FLAG) \
	  --questions out-$*/questions.jsonl --scope $(MEASURE_SCOPE) \
	  --limit $(SMOKE_MEASURE_Q) --top-k 10 \
	  --out smoke-measure-$*-$(PORT).json --mootx01-binary $(PORT_MOOT_BIN)
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/measure_verify.py \
	  --report smoke-measure-$*-$(PORT).json \
	  --dataset $* --target-scale $(SCALE) \
	  --expect-questions $(SMOKE_MEASURE_Q) && touch .smoke-ok-measure-$*-$(PORT)

smoke-measure-complete-locomo:
	cd $(SEEDING) && $(PORT_BENCH_BIN) artifact-recall --dataset locomo \
	  --target-scale complete-aggregate --estate-dir $(PORT_WINGS)/complete \
	  --questions out-locomo/questions.jsonl --scope estate \
	  --limit $(SMOKE_MEASURE_Q) --top-k 10 \
	  --out smoke-measure-complete-locomo-$(PORT).json --mootx01-binary $(PORT_MOOT_BIN)
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/measure_verify.py \
	  --report smoke-measure-complete-locomo-$(PORT).json \
	  --dataset locomo --target-scale complete-aggregate \
	  --expect-questions $(SMOKE_MEASURE_Q) && touch .smoke-ok-measure-complete-locomo-$(PORT)

# ── measure-smoke: unit-scale artifact-recall against the synthetic smoke set ──
# Builds the in-tree smoke set (writes questions.jsonl alongside it), then
# runs one artifact-recall pass at target-scale unit through the catalog
# resolver — exercising Swift artifactUnitEstateDir / Rust resolve_unit_from_catalog.
# Uses --dataset locomo because the binary has no "smoke" dataset variant;
# sample_id values match the unit estate directory names (unit000-unit005) so
# the catalog resolver routes each question to the correct estate.
# Stamps .smoke-ok-measure-smoke-$(PORT) on success.
SMOKE_SCRATCH    = $(SEEDING_TOOLS)/scratch
SMOKE_CATALOG    = $(SMOKE_SCRATCH)/$(PORT)/base-primary/$(PORT)/smoke/catalog.json
SMOKE_QUESTIONS  = $(SMOKE_SCRATCH)/$(PORT)/questions.jsonl

measure-smoke:
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/smoke_builder.py \
	  --port $(PORT) --exe $(MOOT_BINARY)
	cd $(SEEDING) && $(PORT_BENCH_BIN) artifact-recall --dataset locomo \
	  --target-scale unit --catalog $(SMOKE_CATALOG) \
	  --questions $(SMOKE_QUESTIONS) --scope estate --top-k 10 \
	  --out smoke-measure-smoke-$(PORT).json --mootx01-binary $(PORT_MOOT_BIN)
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/measure_verify.py \
	  --report smoke-measure-smoke-$(PORT).json \
	  --dataset locomo --target-scale unit \
	  --expect-questions $(shell python3 -c "import json; c=json.load(open('$(SEEDING_TOOLS)/smoke/$(PORT).json')); print(c['sets'] * c['units_per_set'])") && \
	  touch $(SEEDING)/.smoke-ok-measure-smoke-$(PORT)

smoke-measures: smoke-measure-locomo smoke-measure-convomem \
	smoke-measure-membench smoke-measure-lme-s smoke-measure-complete-locomo

# ── Measure retrieval (external datasets; run book §7) ──────────────────────
# Full retrieval measurement through artifact-recall on the selected
# port at the selected SCALE. unit iterates the fleet's per-instance
# estates; bench-aggregate opens the Form-2 estate (wing-scoped where
# wings exist, unscoped for lme-s); complete-aggregate opens the
# complete estate unscoped with dataset-prefixed ground truth. Gated on
# the measure smoke stamp. Reports land under results/ named
# measure-<ds>-<scale>-<port>-<serial>.json.
TOPK  ?= 10
SCALE ?= bench-aggregate
# LIMIT is the shared question-cap variable (defined empty at the top of
# this Makefile for the spec lanes); empty and 0 both mean "run every
# question" here.
MEASURE_DIR_FLAG = $(if $(filter unit,$(SCALE)),--catalog $(PORT_FLEETS)/$*/catalog.json,--estate-dir $(if $(filter complete-aggregate,$(SCALE)),$(PORT_WINGS)/complete,$(PORT_WINGS)/$*))
MEASURE_RUN_SCOPE = $(if $(filter complete-aggregate,$(SCALE)),estate,$(if $(filter lme-s,$*),estate,wing))

measure-locomo measure-convomem measure-membench measure-lme-s: measure-%:
	@test -f $(SEEDING)/.smoke-ok-measure-$*-$(PORT) || \
	  { echo "REFUSED: measure smoke not green — run 'make smoke-measure-$* PORT=$(PORT)' first"; exit 1; }
	@mkdir -p $(RESULTS_ROOT)
	cd $(SEEDING) && $(PORT_BENCH_BIN) artifact-recall --dataset $* \
	  --target-scale $(SCALE) $(MEASURE_DIR_FLAG) \
	  --questions out-$*/questions.jsonl --scope $(MEASURE_RUN_SCOPE) \
	  --limit $(or $(LIMIT),0) --top-k $(TOPK) \
	  --out $(RESULTS_ROOT)/measure-$*-$(SCALE)-$(PORT)-$(shell date -u +%Y%m%dT%H%M%SZ).json \
	  --mootx01-binary $(PORT_MOOT_BIN)

measure-external: measure-locomo measure-convomem measure-membench measure-lme-s

# ── Payload lanes (run book §9) ─────────────────────────────────────────────
# payload-economics / synthesis-payload: MOOTx01-authored instruments over
# the frozen lme-s corpus and the selected port's Form-2 lme-s artifact.
# Scoring is mechanical and judge-free (evidence/answer presence per 1000
# tokens); the artifact dependency is fixed, so the targets take no SCALE.
# Preparation per the book: fetch + seeds + smoke-wing-lme-s +
# wing-estate-lme-s on the selected port. --payload-arm shape variants
# ride through MOOT_BENCH_PAYLOAD_ARM (the env spelling). SYNTH_LIMIT
# forwards --synthesize-limit on the synthesis lane only.
SYNTH_LIMIT ?=
PAYLOAD_LANE_FLAGS = --estate-dir $(PORT_WINGS)/lme-s \
	  --questions out-lme-s/questions.jsonl \
	  --data-dir $(LME_DATA_DIR) --variant s \
	  --top-k $(TOPK) --mootx01-binary $(PORT_MOOT_BIN) \

measure-payload-economics:
	@test -f $(SEEDING)/.smoke-ok-measure-payload-economics-$(PORT) || \
	  { echo "REFUSED: measure smoke not green — run 'make smoke-measure-payload-economics PORT=$(PORT)' first"; exit 1; }
	@mkdir -p $(RESULTS_ROOT)
	cd $(SEEDING) && $(PORT_BENCH_BIN) payload-economics $(PAYLOAD_LANE_FLAGS) \
	  --limit $(or $(LIMIT),0) \
	  --out $(RESULTS_ROOT)/measure-payload-economics-$(PORT)-$(shell date -u +%Y%m%dT%H%M%SZ).json

measure-synthesis-payload:
	@test -f $(SEEDING)/.smoke-ok-measure-synthesis-payload-$(PORT) || \
	  { echo "REFUSED: measure smoke not green — run 'make smoke-measure-synthesis-payload PORT=$(PORT)' first"; exit 1; }
	@mkdir -p $(RESULTS_ROOT)
	cd $(SEEDING) && $(PORT_BENCH_BIN) payload-economics $(PAYLOAD_LANE_FLAGS) \
	  --synthesize-arm $(if $(SYNTH_LIMIT),--synthesize-limit $(SYNTH_LIMIT),) \
	  --limit $(or $(LIMIT),0) \
	  --out $(RESULTS_ROOT)/measure-synthesis-payload-$(PORT)-$(shell date -u +%Y%m%dT%H%M%SZ).json

# Payload measure smokes: the real lane on a bounded specimen against the
# ready lme-s artifact, then the receipt review, then the stamp. Same
# mechanism-only rule as every measure smoke — never scores.
smoke-measure-payload-economics:
	cd $(SEEDING) && $(PORT_BENCH_BIN) payload-economics $(PAYLOAD_LANE_FLAGS) \
	  --limit $(SMOKE_MEASURE_Q) \
	  --out smoke-measure-payload-economics-$(PORT).json
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/internal_smoke_verify.py \
	  --report-dir . --report-file smoke-measure-payload-economics-$(PORT).json \
	  --lane payload-economics \
	  && touch .smoke-ok-measure-payload-economics-$(PORT)

smoke-measure-synthesis-payload:
	cd $(SEEDING) && $(PORT_BENCH_BIN) payload-economics $(PAYLOAD_LANE_FLAGS) \
	  --synthesize-arm --limit $(SMOKE_MEASURE_Q) \
	  --out smoke-measure-synthesis-payload-$(PORT).json
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/internal_smoke_verify.py \
	  --report-dir . --report-file smoke-measure-synthesis-payload-$(PORT).json \
	  --lane synthesis-payload \
	  && touch .smoke-ok-measure-synthesis-payload-$(PORT)

# validate-rc — the release-candidate validation vehicle: on a SCRATCH
# root (never the production artifacts), the candidate binaries build the
# locomo wing estate from seed, the estate passes the full smoke-doctrine
# shape review, and the measure lane proves the MCP call end-to-end —
# both ports. Point MOOT_BINARY / RUST_BIN (product) at release
# candidates to validate them. Judging legs (inflight --judge-cmd and
# deferred --dump-judge-inputs + judge-batch) join this chain when the
# spec lanes run on rebuilt artifacts and a local judge is reachable.
RC_ROOT ?= $(BENCH_WORK_ROOT)/validate-rc

validate-rc:
	rm -rf $(RC_ROOT) && mkdir -p $(RC_ROOT)
	cd $(SEEDING) && MOOTX01_BINARY=$(MOOT_BINARY) python3 -u $(SEEDING_TOOLS)/import_units.py \
	  --file out-locomo/wing-estate.json --estates-dir $(RC_ROOT)/swift
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/smoke_verify.py --seed out-locomo/wing-estate.json \
	  --estate-dir $(RC_ROOT)/swift/wing-estate
	cd $(SEEDING) && MOOTX01_BINARY=$(RUST_BIN) python3 -u $(SEEDING_TOOLS)/import_units.py \
	  --file out-locomo/wing-estate.json --estates-dir $(RC_ROOT)/rust
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/smoke_verify.py --seed out-locomo/wing-estate.json \
	  --estate-dir $(RC_ROOT)/rust/wing-estate
	cd $(SEEDING) && $(SWIFT_BIN) artifact-recall --dataset locomo \
	  --target-scale bench-aggregate --estate-dir $(RC_ROOT)/swift/wing-estate \
	  --questions out-locomo/questions.jsonl --scope wing --limit $(SMOKE_MEASURE_Q) \
	  --top-k 10 --out $(RC_ROOT)/rc-swift.json --mootx01-binary $(MOOT_BINARY)
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/measure_verify.py --report $(RC_ROOT)/rc-swift.json \
	  --dataset locomo --target-scale bench-aggregate \
	  --expect-questions $(SMOKE_MEASURE_Q)
	cd $(SEEDING) && $(RUST_BENCH_BIN) artifact-recall --dataset locomo \
	  --target-scale bench-aggregate --estate-dir $(RC_ROOT)/rust/wing-estate \
	  --questions out-locomo/questions.jsonl --scope wing --limit $(SMOKE_MEASURE_Q) \
	  --top-k 10 --out $(RC_ROOT)/rc-rust.json --binary $(RUST_BIN)
	cd $(SEEDING) && python3 $(SEEDING_TOOLS)/measure_verify.py --report $(RC_ROOT)/rc-rust.json \
	  --dataset locomo --target-scale bench-aggregate \
	  --expect-questions $(SMOKE_MEASURE_Q)
	@echo "VALIDATE-RC GREEN: seed -> build -> shape review -> MCP-call measure, both ports"

# ── Internal benchmarks on the surface (run book §9) ────────────────────────
# The eight MOOTx01-authored benchmarks share the operating model:
# `make seeds` generates their corpora; smoke-measure-<key> runs the
# smoke vehicle (a small pass through the real lane, receipt-reviewed by
# seeding/internal_smoke_verify.py, stamped); measure-<key> runs wide,
# gated on the stamp. PORT applies where the lane's Rust twin exists
# (gauntlet, journey); matrix, timing, and supersession are Swift-lane
# instruments and refuse PORT=rust by name — a parity gap is reported,
# never papered over. deterministic-alternatives is the umbrella over
# the four external deterministic retrieval measurements (its
# definition: one judge-free method per public dataset).
INTERNAL_SWIFT_ONLY = @test "$(PORT)" = "swift" || { echo "REFUSED: $@ is a Swift-lane instrument — its Rust twin does not exist (parity gap, reported not papered)"; exit 1; }

measure-deterministic-alternatives: measure-external

smoke-measure-gauntlet:
	rm -rf $(RESULTS_ROOT)/int-smoke-gauntlet-$(PORT) && mkdir -p $(RESULTS_ROOT)/int-smoke-gauntlet-$(PORT)
	env SMOKE_PROBE=1 $(MAKE) -C $(CURDIR) measure-gauntlet PORT=$(PORT) MEASURE_PREREQS= \
	  OUT=$(RESULTS_ROOT)/int-smoke-gauntlet-$(PORT)
	python3 $(SEEDING_TOOLS)/internal_smoke_verify.py \
	  --report-dir $(RESULTS_ROOT)/int-smoke-gauntlet-$(PORT) --lane gauntlet \
	  && touch $(SEEDING)/.smoke-ok-measure-gauntlet-$(PORT)

smoke-measure-journey:
	rm -rf $(RESULTS_ROOT)/int-smoke-journey-$(PORT) && mkdir -p $(RESULTS_ROOT)/int-smoke-journey-$(PORT)
	env SMOKE_PROBE=1 $(MAKE) -C $(CURDIR) measure-journey PORT=$(PORT) MEASURE_PREREQS= \
	  JOURNEY_CLUSTERS=2 JOURNEY_MEMBERS=3 JOURNEY_PRECISE_MISS=2 \
	  OUT=$(RESULTS_ROOT)/int-smoke-journey-$(PORT)
	python3 $(SEEDING_TOOLS)/internal_smoke_verify.py \
	  --report-dir $(RESULTS_ROOT)/int-smoke-journey-$(PORT) --lane journey \
	  && touch $(SEEDING)/.smoke-ok-measure-journey-$(PORT)

smoke-measure-supersession:
	$(INTERNAL_SWIFT_ONLY)
	rm -rf $(RESULTS_ROOT)/int-smoke-supersession && mkdir -p $(RESULTS_ROOT)/int-smoke-supersession
	env SMOKE_PROBE=1 $(MAKE) -C $(CURDIR) measure-supersession MEASURE_PREREQS= \
	  OUT=$(RESULTS_ROOT)/int-smoke-supersession \
	  > $(RESULTS_ROOT)/int-smoke-supersession/stdout.txt 2>&1
	python3 $(SEEDING_TOOLS)/internal_smoke_verify.py \
	  --report-dir $(RESULTS_ROOT)/int-smoke-supersession --lane supersession \
	  --stdout-file $(RESULTS_ROOT)/int-smoke-supersession/stdout.txt \
	  && touch $(SEEDING)/.smoke-ok-measure-supersession-swift

smoke-measure-matrix:
	$(INTERNAL_SWIFT_ONLY)
	rm -rf $(RESULTS_ROOT)/int-smoke-matrix && mkdir -p $(RESULTS_ROOT)/int-smoke-matrix
	env SMOKE_PROBE=1 $(MAKE) -C $(CURDIR) measure-matrix MEASURE_PREREQS= MATRIX_PROBES=2 \
	  OUT=$(RESULTS_ROOT)/int-smoke-matrix
	python3 $(SEEDING_TOOLS)/internal_smoke_verify.py \
	  --report-dir $(RESULTS_ROOT)/int-smoke-matrix --lane matrix \
	  && touch $(SEEDING)/.smoke-ok-measure-matrix-swift

smoke-measure-timing:
	$(INTERNAL_SWIFT_ONLY)
	rm -rf $(RESULTS_ROOT)/int-smoke-timing && mkdir -p $(RESULTS_ROOT)/int-smoke-timing
	env SMOKE_PROBE=1 $(MAKE) -C $(CURDIR) measure-timing MEASURE_PREREQS= \
	  OUT=$(RESULTS_ROOT)/int-smoke-timing
	python3 $(SEEDING_TOOLS)/internal_smoke_verify.py \
	  --report-dir $(RESULTS_ROOT)/int-smoke-timing --lane timing \
	  && touch $(SEEDING)/.smoke-ok-measure-timing-swift

# ── End-to-end smoke chains + release validation (run book §10) ─────────────
# smoke-bench-<ds>: one dataset end to end at smoke scale. External:
# build smoke → measure smoke → every protocol smoke mapped to the
# dataset → judge-batch smoke (judged datasets). Internal: the measure
# smoke, which builds its own specimen. One summary line at the end.
smoke-bench-locomo:
	$(MAKE) -C $(CURDIR) smoke-wing-locomo PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-measure-locomo PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-spec-locomo PORT=$(PORT)
	@echo "SMOKE-BENCH-locomo GREEN ($(PORT))"

smoke-bench-lme-s:
	$(MAKE) -C $(CURDIR) smoke-wing-lme-s PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-measure-lme-s PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-spec-lme PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-judge-batch PORT=$(PORT)
	@echo "SMOKE-BENCH-lme-s GREEN ($(PORT))"

smoke-bench-convomem:
	$(MAKE) -C $(CURDIR) smoke-wing-convomem PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-measure-convomem PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-spec-lmeb PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-spec-convomem PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-judge-batch PORT=$(PORT)
	@echo "SMOKE-BENCH-convomem GREEN ($(PORT))"

smoke-bench-membench:
	$(MAKE) -C $(CURDIR) smoke-wing-membench PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-measure-membench PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-spec-membench PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-judge-batch PORT=$(PORT)
	@echo "SMOKE-BENCH-membench GREEN ($(PORT))"

smoke-bench-gauntlet smoke-bench-journey smoke-bench-matrix \
smoke-bench-supersession smoke-bench-timing \
smoke-bench-payload-economics smoke-bench-synthesis-payload: smoke-bench-%:
	$(MAKE) -C $(CURDIR) smoke-measure-$* PORT=$(PORT)
	@echo "SMOKE-BENCH-$* GREEN ($(PORT))"

smoke-bench-all: smoke-bench-locomo smoke-bench-lme-s smoke-bench-convomem \
	smoke-bench-membench smoke-bench-gauntlet smoke-bench-journey \
	smoke-bench-matrix smoke-bench-supersession smoke-bench-timing \
	smoke-bench-payload-economics smoke-bench-synthesis-payload
	@echo "SMOKE-BENCH-ALL GREEN ($(PORT))"

# validate-rc-full: validate-rc plus the judged leg on the same scratch
# root — one convomem fleet unit is built by the candidate binary, the
# convomem-spec lane runs a deferred dump against it, and judge-batch
# consumes the dump (real verdicts with MOOT_BENCH_JUDGE_CMD; a plain
# judge-absent receipt without).
validate-rc-full: validate-rc
	cd $(SEEDING) && u=$$(find out-convomem/units -maxdepth 1 -name 'user_evidence__*.json' | sort | head -1) && \
	  MOOTX01_BINARY=$(MOOT_BINARY) python3 -u $(SEEDING_TOOLS)/import_units.py --file $$u \
	  --estates-dir $(RC_ROOT)/spec-fleet/swift/convomem/estate_set1
	python3 $(SEEDING_TOOLS)/artifact_layout.py write-catalog \
	  --primary-base $(RC_ROOT)/spec-fleet \
	  --port swift \
	  --dataset convomem \
	  --set-base $(RC_ROOT)/spec-fleet \
	  --set-path swift/convomem/estate_set1
	rm -rf $(RC_ROOT)/spec-out $(RC_ROOT)/spec-dump && mkdir -p $(RC_ROOT)/spec-out $(RC_ROOT)/spec-dump
	@echo "user_evidence__scene_0_q_0" > $(RC_ROOT)/unit-ids.txt
	MOOT_BENCH_UNIT_IDS=$(RC_ROOT)/unit-ids.txt $(SWIFT_BIN) convomem-spec \
	  --data-dir $(CURDIR)/$(LMEB_DATA_DIR) --evidence-types user_evidence \
	  --target-scale unit --catalog $(RC_ROOT)/spec-fleet/swift/convomem/catalog.json \
	  --dump-answer-inputs $(RC_ROOT)/spec-dump/answer-inputs.jsonl --limit $(SMOKE_MEASURE_Q) \
	  --mootx01-binary $(MOOT_BINARY) --out $(RC_ROOT)/spec-out
	python3 $(SEEDING_TOOLS)/spec_smoke_verify.py --report-dir $(RC_ROOT)/spec-out \
	  --protocol convomem --dump-dir $(RC_ROOT)/spec-dump
	@if [ -n "$$MOOT_BENCH_JUDGE_CMD" ]; then \
	  $(SWIFT_BIN) judge-batch --inputs $(RC_ROOT)/spec-dump --out $(RC_ROOT)/spec-dump; \
	else \
	  echo "validate-rc-full: no judge attached — dump shape verified; verdict leg runs when MOOT_BENCH_JUDGE_CMD is set"; \
	fi
	@echo "VALIDATE-RC-FULL GREEN: build + shape + measure + judged leg, scratch-rooted"

# ── Artifact health summary ──────────────────────────────────────────────────
# One row per benchmark per tier (Form-1 fleet, Form-2 Swift, Form-2 twin):
# READY / BUILDING / INCOMPLETE / MISSING, judged on presence AND encode
# coverage (drawer-complete alone is not done), with posture and format-drift
# flags. Fleets are sampled; Form-2 estates checked exhaustively.
status:
	python3 $(SEEDING_TOOLS)/artifact_status.py --seeding-dir $(SEEDING) \
	  --fleet-root $(FLEET_ROOT) --wing-root $(WING_ROOT)

# ── Artifact builder (seeding/ARTIFACT_BUILDER_SPEC.md) ─────────
#
# The builder lays out, catalogues, imports and drains benchmark estates in
# waves. It reaches the product through one executable parameter (spec §11):
# mootx01_faker for the assembly-line smoke, mootx01_seam on the product for
# real builds. Base folders come from the target map named by
# MOOTX01_BENCH_TARGET_MAP (spec R1); no path lives in this Makefile.
BUILDER_TOOLS := $(SEEDING_TOOLS)
BUILDER_WATCHERS ?= 2
# PRODUCT=1 runs the line on the port's product binary through the seam
# (mootx01_seam.py, spec §11): the importer builds each estate and the
# product finisher settles it. The default is the faker (assembly-line only).
# Artifacts are built without fact extraction on both ports (Bob,
# 2026-09-17): the lane is experimental and slow, and it is run later on a
# chosen copy of an artifact; FACTS=1 keeps it on for one build.
ifeq ($(PRODUCT),1)
  BUILDER_EXE ?= $(BUILDER_TOOLS)/mootx01_seam.py
  BUILDER_ENV  = MOOTX01_BINARY=$(PORT_MOOT_BIN) IMPORT_DRAIN_TIMEOUT=$(IMPORT_DRAIN_TIMEOUT) \
                 $(if $(filter 1,$(FACTS)),,MOOTX01_BENCH_PREFERENCES_OFF_EXTRA=fact_extraction)
else
  BUILDER_EXE ?= $(BUILDER_TOOLS)/mootx01_faker.py
  BUILDER_ENV  =
endif

.PHONY: smoke-builder build-dataset proof-unit clean-seed-projections clean-smoke \
        batch-drain-binary test-seeding

# Unit tests for the seeding tools (no fixture dependency — runs in-worktree).
# Follows the same discover invocation as the root Makefile's check-edition-boundary
# target (python3 -m unittest discover).
test-seeding:
	python3 -m unittest discover -s $(SEEDING_TOOLS)/tests -p 'test_*.py'

# §8: assembly-line smoke for the Form-1 builder. PORT=swift|rust. Scratch is
# seeding/scratch/, gitignored, emptied at the start of each run.
# The stamp name records which executable was used:
#   .smoke-ok-builder-faker-<port>   BUILDER_EXE is the default faker
#       (assembly-line pipeline verified on synthetic data; product binary
#       NOT exercised).
#   .smoke-ok-builder-binary-<port>  BUILDER_EXE is a product binary
#       (both the builder pipeline and the product binary are verified).
# The fleet-* gate requires the binary stamp; pass FLEET_GATE=faker to
# proceed with the faker stamp until the product binary is available.
smoke-builder:
	@test -n "$(PORT)" || { echo "error: PORT=swift|rust is required"; exit 2; }
	$(BUILDER_ENV) python3 $(BUILDER_TOOLS)/smoke_builder.py --port $(PORT) --exe $(BUILDER_EXE)
	@case "$(BUILDER_EXE)" in \
	  *mootx01_faker.py) \
	    touch $(SEEDING)/.smoke-ok-builder-faker-$(PORT); \
	    echo "[smoke-builder] faker stamp written (.smoke-ok-builder-faker-$(PORT)); product binary not exercised" ;; \
	  *) \
	    touch $(SEEDING)/.smoke-ok-builder-binary-$(PORT); \
	    echo "[smoke-builder] binary stamp written (.smoke-ok-builder-binary-$(PORT))" ;; \
	esac

# §4: one dataset, one port, end to end. DS=locomo|lme-s|convomem|membench.
# TARGET_MAP= overrides MOOTX01_BENCH_TARGET_MAP; FLOOR= sets the disk floor in
# bytes (default: twice the previous set's encoded size). The seed projection
# is what `make seeds` wrote: $(SEEDING)/out-<DS>/projection under the marked
# work root (DS names match the seeds target: locomo, lme-s, convomem, membench).
# LIMIT=N builds the first N units by sorted id; UNITS="a b" builds exactly
# those. PRODUCT=1 builds on the product binary (see BUILDER_EXE above).
build-dataset:
	@test -n "$(PORT)" || { echo "error: PORT=swift|rust is required"; exit 2; }
	@test -n "$(DS)" || { echo "error: DS=<dataset> is required"; exit 2; }
	$(BUILDER_ENV) MOOTX01_SEAM_UNITS_DIR=$(SEEDING)/out-$(DS)/units \
	  python3 $(BUILDER_TOOLS)/artifact_build.py --exe $(BUILDER_EXE) --port $(PORT) \
	  --dataset $(DS) --projection $(SEEDING)/out-$(DS)/projection --watchers $(BUILDER_WATCHERS) \
	  $(if $(TARGET_MAP),--target-map $(TARGET_MAP),--base $(INTERNAL_PRIMARY)) $(if $(FLOOR),--floor $(FLOOR),) \
	  $(if $(LIMIT),--limit $(LIMIT),) $(if $(UNITS),--units $(UNITS),) \
	  --work $(BENCH_WORK_ROOT)/builder

# One unit through the whole product line into a scratch base under the work
# root: the proof that a binary builds and settles an estate before any real
# dataset build. PORT= DS= UNIT= are required; the target map is written here.
proof-unit:
	@test -n "$(UNIT)" || { echo "error: UNIT=<unit id> is required"; exit 2; }
	mkdir -p $(BENCH_WORK_ROOT)/proof/$(PORT)-$(DS)-$(UNIT)
	printf '{"%s":{"%s":[{"path":"%s"}]}}\n' $(PORT) $(DS) $(BENCH_WORK_ROOT)/proof/$(PORT)-$(DS)-$(UNIT) \
	  > $(BENCH_WORK_ROOT)/proof/$(PORT)-$(DS)-$(UNIT).map.json
	$(MAKE) -C $(CURDIR) build-dataset PORT=$(PORT) DS=$(DS) PRODUCT=1 UNITS=$(UNIT) \
	  BUILDER_WATCHERS=1 TARGET_MAP=$(BENCH_WORK_ROOT)/proof/$(PORT)-$(DS)-$(UNIT).map.json

# R6: seed projections are temporary; this removes only seeding/ under the
# marked work root, nothing else.
clean-seed-projections:
	@test -f "$(BENCH_WORK_ROOT)/.mootx01-benchmark-work-root" || { echo "error: $(BENCH_WORK_ROOT) is not a marked work root"; exit 2; }
	rm -rf "$(SEEDING)"
	@echo "[make] removed seed projections: $(SEEDING)"

# §8: empty the smoke scratch folder inside the worktree.
clean-smoke:
	rm -rf $(BUILDER_TOOLS)/scratch
	@echo "[make] removed $(BUILDER_TOOLS)/scratch"

# ── Release qualification (qualification/RELEASE_QUALIFICATION.md) ──────────
# The final pass before a version goes quiet: setup verified, the faker
# smoke, the product smoke, one real unit through the whole line, then
# every ARIA tool fired once against a clone of that unit with the outcome
# of each call pinned in qualification/catalog-calls.json. Nothing here
# debugs; a failure is a finding to take back to the product.
QUAL_DS   ?= locomo
QUAL_UNIT ?= conv-26
QUAL_OUT  ?= $(BENCH_WORK_ROOT)/qualification/$(PORT)-$(shell date -u +%Y%m%dT%H%M%SZ)
QUAL_ESTATE = $(BENCH_WORK_ROOT)/proof/$(PORT)-$(QUAL_DS)-$(QUAL_UNIT)/$(PORT)/$(QUAL_DS)/estate_set1/$(QUAL_UNIT)
.PHONY: release-qualification catalog-exercise verify-setup test-qualification
verify-setup:
	@test -x $(PORT_MOOT_BIN) || { echo "REFUSED: no product binary for $(PORT); run make setup"; exit 2; }
	@test -d $(SEEDING)/out-$(QUAL_DS)/projection || { echo "REFUSED: no seed projection for $(QUAL_DS); run make setup"; exit 2; }
	@echo "[make] setup verified for $(PORT): $(PORT_MOOT_BIN)"

catalog-exercise:
	@test -d $(QUAL_ESTATE) || { echo "REFUSED: no proof estate at $(QUAL_ESTATE); run make proof-unit PORT=$(PORT) DS=$(QUAL_DS) UNIT=$(QUAL_UNIT)"; exit 2; }
	mkdir -p $(QUAL_OUT)/scratch
	printf '%s\n' '{"format_version":1,"name":"cx","records":[{"id":"cx-1","content":"catalog exercise import record","room":"hobbies","subject":"catalog exercise import","wing":"Personal","event_time":"2026-01-01T00:00:00Z"}]}' > $(QUAL_OUT)/scratch/import.json
	python3 $(CURDIR)/qualification/catalog_exercise.py --binary $(PORT_MOOT_BIN) --estate $(QUAL_ESTATE) \
	  --calls $(CURDIR)/qualification/catalog-calls.json --out $(QUAL_OUT) --port $(PORT) $(if $(RECORD),--record,)

release-qualification: verify-setup
	$(MAKE) -C $(CURDIR) smoke-builder PORT=$(PORT)
	$(MAKE) -C $(CURDIR) smoke-builder PORT=$(PORT) PRODUCT=1
	$(MAKE) -C $(CURDIR) proof-unit PORT=$(PORT) DS=$(QUAL_DS) UNIT=$(QUAL_UNIT)
	$(MAKE) -C $(CURDIR) catalog-exercise PORT=$(PORT) QUAL_OUT=$(QUAL_OUT)
	@echo "[make] release qualification PASS for $(PORT): $(QUAL_OUT)/report.json"

test-qualification:
	python3 -m unittest discover -s $(CURDIR)/qualification/tests -p 'test_*.py'

# Drain every estate of a built fleet on the current product binary, a bounded
# number at a time, and record each estate's clock. A fleet built on an earlier
# binary carries the new binary's duties after this (the chest re-bin of
# ADR-026); the catalog's encoded state already holds. JOBS estates at once.
#   make fleet-drain PORT=swift DS=lme-s JOBS=4
FLEET_DRAIN_JOBS ?= 4
fleet-drain:
	@test -n "$(PORT)" || { echo "error: PORT=swift|rust is required"; exit 2; }
	@test -n "$(DS)" || { echo "error: DS=<dataset> is required"; exit 2; }
	@test -x "$(PORT_MOOT_BIN)" || { echo "error: no product binary at $(PORT_MOOT_BIN); run make moot-binary / rust-moot-binary"; exit 2; }
	python3 $(SEEDING_TOOLS)/fleet_drain.py --exe $(PORT_MOOT_BIN) --port $(PORT) --dataset $(DS) \
	  --catalog $(INTERNAL_PRIMARY)/$(PORT)/$(DS)/catalog.json --jobs $(FLEET_DRAIN_JOBS) \
	  --out $(BENCH_WORK_ROOT)/results/fleet-drain-$(PORT)-$(DS).json

# §7: batch-drain is the product finisher (`mootx01 drain --db`, one estate at
# a time, attached) behind the seam; there is no gated binary. The product
# binaries come from `make binaries`.
batch-drain-binary: binaries
