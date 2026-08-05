# Makefile — mootx01 build orchestration (Swift + Rust polyglot monorepo).
#
# There is no single native build system spanning Swift, Rust, and Python, so
# this Makefile provides the repo-level lanes. Unit tests are the default lane;
# product, validation, and full-regression sweeps are explicit targets.
#
# Common targets:
#   make build        build every Swift package + Rust crate (debug)
#   make test         run the fast core unit lane
#   make test-one     run the package/crate owning DIR=...
#   make test-changed run only package/crate/python roots changed from BASE
#   make test-full    run unit + product + validation + lint/check gates
#   make conformance  run the cross-language shared-vector gate
#   make release      build the host-arch release archive (mootx01 + moot-mgr)
#   make list         show the discovered packages/crates
#   make clean        strip all build artifacts (clean-dry to preview)
#   make help         this list
#
# Test lanes are fail-fast: the first failing package stops the run and prints
# which one failed.

SHELL := /bin/bash

# ── Shared Rust target directory ──────────────────────────────────────────
# VISIBLE, not dotted (Bob, 2026-08-04). This directory reaches tens of GB.
# A hidden one is where cleanup silently fails, because nobody sees what
# accumulated. If it is on disk it should show up in a plain `ls`.
# This repo holds 30 independent Cargo workspaces. With cargo's default
# per-workspace `target/`, every shared dependency is compiled and stored
# once per workspace — the tree reached 31 GB of build output (measured
# 2026-08-04). One target directory per CHECKOUT collapses that to a single
# copy of each dependency.
#
# Per-checkout, not machine-global, on purpose: cargo takes an exclusive
# lock on the target directory, so a single shared path would serialize
# builds across concurrent checkouts.
#
# $(CURDIR) is this Makefile's directory (the repo root), so the value is
# absolute and every `cd $$d && cargo ...` recipe below inherits it.
# scripts/moot-test sets the same value independently — it is invoked as a
# subprocess for discovery, so it does not inherit this export.
export CARGO_TARGET_DIR := $(CURDIR)/cargo-target

# ── Discovery ─────────────────────────────────────────────────────────────
TEST_RUNNER := bash scripts/moot-test
SWIFT_PKGS  := $(shell $(TEST_RUNNER) list-swift all)
RUST_CRATES := $(shell $(TEST_RUNNER) list-rust all)
PYTHON_PKGS := $(shell $(TEST_RUNNER) list-python all)

HARNESS := docs/validation/substrate_math_performance/test-harness
DIST    ?= dist
BASE    ?= origin/develop/1.0.x

.PHONY: help build build-swift build-rust test test-unit test-swift test-rust test-python \
        test-product test-product-swift test-product-rust test-product-python \
        test-validation test-validation-swift test-validation-rust test-validation-python \
        test-one test-changed test-full test-all test-checks test-glk-latency test-topology-zoom \
        test-perf-bench test-apple-app-ios \
        conformance release pkg list clean clean-dry clean-index check-static-assets check-edition-boundary

help:
	@echo "mootx01 build targets:"
	@echo "  build        — build all Swift packages + Rust crates (debug)"
	@echo "  build-swift  — swift build each Swift package"
	@echo "  build-rust   — cargo build each Rust crate"
	@echo "  test         — fast core unit lane (packages/ Swift + Rust + Python only)"
	@echo "  test-swift   — fast core Swift unit lane"
	@echo "  test-rust    — fast core Rust unit lane"
	@echo "  test-python  — fast core Python unit lane"
	@echo "  test-one DIR=path — run nearest owning Package.swift/Cargo.toml/pyproject.toml"
	@echo "  test-changed BASE=$(BASE) — run changed package/crate/python roots"
	@echo "  test-product — app/example tests (explicit product lane)"
	@echo "  test-validation — validation and benchmark harness tests"
	@echo "  test-full    — unit + product + validation + check gates"
	@echo "  test-topology-zoom — run the pure semantic-zoom controller tests"
	@echo "  test-apple-app-ios — regenerate and build the Apple app for the generic iOS simulator"
	@echo "  check-static-assets — verify StaticAssets.swift matches DashboardAssets/ source"
	@echo "  check-edition-boundary — verify no SHARED file references an EE-only path"
	@echo "  conformance  — cross-language shared-vector conformance gate"
	@echo "  release      — build host-arch release archive (mootx01 + moot-mgr) into $(DIST)/"
	@echo "  pkg          — build the host-arch macOS .pkg installer into $(DIST)/ (unsigned without identities)"
	@echo "  list         — print discovered packages and crates"
	@echo "  clean        — remove all build artifacts (clean-dry previews, clean-index also drops .codegraph)"

# ── Build ───────────────────────────────────────────────────────────────
build: build-swift build-rust

build-swift:
	@for d in $(SWIFT_PKGS); do \
		echo "── swift build: $$d"; \
		( cd "$$d" && swift build ) || { echo "FAILED (swift build): $$d"; exit 1; }; \
	done
	@echo "✓ all Swift packages built"

build-rust:
	@for d in $(RUST_CRATES); do \
		echo "── cargo build: $$d"; \
		( cd "$$d" && cargo build ) || { echo "FAILED (cargo build): $$d"; exit 1; }; \
	done
	@echo "✓ all Rust crates built"

# ── Test ────────────────────────────────────────────────────────────────
# Default TDD lane: core packages only. Product apps, validation harnesses,
# benchmarks, GLK latency suites, and repo lint/check gates are explicit so
# coding agents can iterate on the local unit of work without accidentally
# launching a whole-product regression sweep.
test: test-unit

test-unit:
	@$(TEST_RUNNER) unit

test-swift:
	@$(TEST_RUNNER) unit-swift

test-rust:
	@$(TEST_RUNNER) unit-rust

test-python:
	@$(TEST_RUNNER) unit-python

test-product:
	@$(TEST_RUNNER) product

test-product-swift:
	@$(TEST_RUNNER) product-swift

test-product-rust:
	@$(TEST_RUNNER) product-rust

test-product-python:
	@$(TEST_RUNNER) product-python

test-validation:
	@$(TEST_RUNNER) validation

test-validation-swift:
	@$(TEST_RUNNER) validation-swift

test-validation-rust:
	@$(TEST_RUNNER) validation-rust

test-validation-python:
	@$(TEST_RUNNER) validation-python

test-one:
	@$(TEST_RUNNER) path "$(DIR)"

test-changed:
	@$(TEST_RUNNER) changed "$(BASE)"

test-checks: check-static-assets check-edition-boundary test-topology-zoom

test-topology-zoom:
	@node --test apps/moot-mgr/Sources/MootManager/DashboardAssets/tests/semantic-zoom.test.mjs
	@node --check apps/moot-mgr/Sources/MootManager/DashboardAssets/app.js
	@node --check apps/moot-mgr/Sources/MootManager/DashboardAssets/semantic-zoom.mjs
	@node --check apps/moot-mgr/Tests/BrowserFixtures/topology_v3_server.mjs

test-apple-app-ios:
	@$(TEST_RUNNER) apple-app-ios

test-full:
	@$(MAKE) test-checks
	@$(TEST_RUNNER) full

test-all: test-full

# GLK latency suites: gated behind GLK_LATENCY_TESTS=1 (self-skip on a bare
# `swift test`) because their near-realtime assertions are CPU-bound embed
# work that false-fails when the package's 117 suites run in parallel and
# saturate every core. The isolated pass below runs them alone, serially, on
# a quiet machine — where a latency number means what it claims. See the
# file headers in Tests/GeniusLocusKitTests/EncodeDrainNearRealtimeTests.swift
# and EncodeIntakeTests.swift.
test-glk-latency:
	@$(TEST_RUNNER) glk-latency

# CVK perf benchmarks: gated behind MOOT_PERF_BENCH=1 (self-skip on a bare
# `swift test` via .enabled(if:) on each @Suite). The four Q1/Q2/Q3/Q5
# suites pushed the ConvergenceKit CloudKit bundle from 2s to ~77s. The
# isolated pass below runs them alone, serially, where timing numbers mean
# what they claim. See the file header in
# Tests/ConvergenceKitCloudKitTests/CVK_ICLOUD_P4M5_PerfTests.swift.
test-perf-bench:
	@$(TEST_RUNNER) perf-bench

# ── Static-asset lint gate ─────────────────────────────────────────────────────
# Verifies that apps/moot-mgr/Sources/MootManager/StaticAssets.swift is in sync
# with the DashboardAssets/ source files. Fails if the script would produce a
# different file — meaning a developer edited DashboardAssets/ without committing
# the regenerated StaticAssets.swift. Chained into `make test` so CI catches
# out-of-sync commits.
#
# The gen_static_assets.sh script accepts an optional first argument to redirect
# output to an arbitrary path; the check uses a temp directory to avoid touching
# the live StaticAssets.swift. The script is copied with the asset sources so it
# can locate them via its own dirname resolution.
check-static-assets:
	@TMPDIR=$$(mktemp -d) && \
	trap "rm -rf $$TMPDIR" EXIT && \
	cp apps/moot-mgr/Sources/MootManager/DashboardAssets/index.html \
	   apps/moot-mgr/Sources/MootManager/DashboardAssets/app.css \
	   apps/moot-mgr/Sources/MootManager/DashboardAssets/app.js \
	   apps/moot-mgr/Sources/MootManager/DashboardAssets/semantic-zoom.mjs \
	   apps/moot-mgr/Sources/MootManager/DashboardAssets/three.min.js \
	   apps/moot-mgr/Sources/MootManager/DashboardAssets/OrbitControls.js \
	   apps/moot-mgr/Sources/MootManager/DashboardAssets/gen_static_assets.sh \
	   "$$TMPDIR/" && \
	bash "$$TMPDIR/gen_static_assets.sh" "$$TMPDIR/StaticAssets.swift.new" && \
	diff apps/moot-mgr/Sources/MootManager/StaticAssets.swift \
	     "$$TMPDIR/StaticAssets.swift.new" > /dev/null \
	|| { echo "ERROR: StaticAssets.swift is out of sync with DashboardAssets/." && \
	     echo "       Run: apps/moot-mgr/Sources/MootManager/DashboardAssets/gen_static_assets.sh" && \
	     echo "       Then commit the regenerated StaticAssets.swift." && \
	     exit 1; }
	@echo "✓ StaticAssets.swift is in sync with DashboardAssets/"

# ── Edition-boundary lint gate ──────────────────────────────────────────────
# Enforces the core invariant of EDITION_BOUNDARY.md / the CE/EE boundary: SHARED code (the
# tree this edition ships) must not reference an EE-only path, or it cannot
# build/test/run standalone. Greps SHARED paths for the high-signal EE-internal
# markers (docs_internal/,.claude/rules). Excludes the CE/EE boundary (which DEFINES the
# boundary by naming these paths) and apps/moot-agent-skills (which documents the
# Claude Code .claude/ convention for a user's own project, not this repo).
check-edition-boundary:
	@hits=$$(git grep --untracked -nE "docs_internal|\.claude/rules" -- \
	  'packages/**' 'apps/**' 'examples/**' 'docs/**' \
	  ':!apps/moot-bridge/**' ':!docs/AGENTS.md' ':!docs/CLAUDE.md' \
	  ':!docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md' ':!apps/moot-agent-skills/**' \
	  ':!docs/start-here/AI_INSTALL_MANIFEST.json' || true); \
	if [ -n "$$hits" ]; then \
	  echo "ERROR: SHARED code references an EE-only path (see EDITION_BOUNDARY.md and docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md):"; \
	  echo "$$hits"; \
	  echo "Fix: vendor the material into the package, or move it to a public docs/ location."; \
	  exit 1; \
	fi
	@echo "✓ edition boundary clean — no SHARED→EE-only references"

# ── Conformance ───────────────────────────────────────────────────────────
# The cross-language gate: Swift and Rust must stay in lockstep.
# `check-lockstep.py` audits 1:1 public-type parity between every Rust crate
# and its Swift counterpart (a Rust-only type is a violation). The per-kit
# byte-equality vector gates run inside `make test` (NeuronKit and
# CognitionKit's swift test / cargo test include them); the full generate →
# cross-validate vector matrix lives in $(HARNESS) (gen-vectors /
# validate-vectors), exercised by the conformance CI workflows.
conformance:
	@if [ -f "$(HARNESS)/check-lockstep.py" ]; then \
		echo "── Swift/Rust type-parity (lockstep) gate"; \
		python3 "$(HARNESS)/check-lockstep.py" && echo "✓ Swift/Rust type parity holds"; \
	else \
		echo "conformance harness not found at $(HARNESS)"; exit 1; \
	fi

# ── Release ─────────────────────────────────────────────────────────────
# Reproduce, for the host architecture, the archive that
# .github/workflows/release.yml builds (mootx01 + moot-mgr). The full asset
# matrix (macOS arm64/x86_64 .tar.gz, Linux .tar.gz, Windows .zip + checksums)
# is built in CI on a v* tag; this is the local host-arch counterpart.
release:
	@mkdir -p "$(DIST)"
	swift build -c release --package-path apps/mootx01 --product mootx01
	swift build -c release --package-path apps/moot-mgr --product moot-mgr
	@cp apps/mootx01/.build/release/mootx01 "$(DIST)/mootx01"
	@cp apps/moot-mgr/.build/release/moot-mgr "$(DIST)/moot-mgr"
	# SPM resource bundles MUST ship beside the Swift binaries: each
	# Bundle.module target (LatticeLib, EideticLib, swift-crypto) fatalErrors
	# on its first resource touch when its <Target>_<Target>.bundle is not
	# co-located with the executable — v1.0.9 shipped without them and the
	# installed CLI crashed on any classify/search path. Union of both
	# products' bundles; the cp glob failing loudly (no bundles built) is
	# deliberate. install.sh places every *.bundle it finds in the archive.
	@rm -rf "$(DIST)"/*.bundle
	@cp -R apps/mootx01/.build/release/*.bundle "$(DIST)/"
	@for b in apps/moot-mgr/.build/release/*.bundle; do \
		bn=$$(basename "$$b"); \
		[ -e "$(DIST)/$$bn" ] || cp -R "$$b" "$(DIST)/"; \
	done
	@arch=$$(uname -m); asset="mootx01-local-macos-$$arch.tar.gz"; \
	 ( cd "$(DIST)" && tar -czf "$$asset" mootx01 moot-mgr *.bundle && shasum -a 256 "$$asset" ); \
	 echo "✓ release archive written to $(DIST)/"

# ── macOS .pkg (local) ──────────────────────────────────────────────────
# Reproduce, for the host architecture, the .pkg installer that
# .github/workflows/release.yml builds in CI. Unsigned unless APP_IDENTITY
# and INSTALLER_IDENTITY are exported (build-pkg.sh warns and proceeds —
# fine for local layout testing, not distributable). Version defaults to
# the newest CHANGELOG.md entry; override with make pkg PKG_VERSION=X.Y.Z.
PKG_VERSION ?= $(shell sed -n 's/^\#\# v\([^ ]*\) .*/\1/p' CHANGELOG.md | head -1)
pkg:
	@mkdir -p "$(DIST)"
	swift build -c release --package-path apps/mootx01 --product mootx01
	swift build -c release --package-path apps/moot-mgr --product moot-mgr
	swift build -c release --package-path apps/Mootx01-Setup --product Mootx01Setup
	@arch=$$(uname -m); \
	 distribution/macos/build-pkg.sh "$(PKG_VERSION)" "$$arch" \
	   apps/mootx01/.build/release/mootx01 \
	   apps/moot-mgr/.build/release/moot-mgr \
	   apps/Mootx01-Setup/.build/release/Mootx01Setup && \
	 mv "mootx01-$(PKG_VERSION)-macos-$$arch.pkg" "$(DIST)/" && \
	 echo "✓ .pkg written to $(DIST)/mootx01-$(PKG_VERSION)-macos-$$arch.pkg"

list:
	@echo "Swift packages ($(words $(SWIFT_PKGS))):"; for d in $(SWIFT_PKGS); do echo "  $$d"; done
	@echo "Rust crates ($(words $(RUST_CRATES))):"; for d in $(RUST_CRATES); do echo "  $$d"; done
	@echo "Python packages ($(words $(PYTHON_PKGS))):"; for d in $(PYTHON_PKGS); do echo "  $$d"; done

# ── Clean ─────────────────────────────────────────────────────────────────
# `make clean` strips all build artifacts from the entire tree so the checkout
# can be zipped/archived without carrying the gigabytes of compiler output the
# Swift/Rust builds produce. For packages/ alone, packages/Makefile has its own
# `clean`. NOT removed: .codegraph/ (a live tool index, not build output —
# deleting it forces a full re-index; use clean-index to drop it too).
# `make clean-dry` prints what would be deleted without removing anything.

# Directory names removed wholesale (pruned so find does not descend into them).
ARTIFACT_DIRS := .build .swiftpm target DerivedData __pycache__ \
                 .pytest_cache .ruff_cache .mypy_cache htmlcov

# Glob-named directories (handled separately; -name takes one pattern).
ARTIFACT_GLOB_DIRS := *.egg-info

# Stray artifact files removed by name.
ARTIFACT_FILES := .DS_Store .coverage coverage.out coverage.html

clean:
	@echo "Cleaning build artifacts under $(CURDIR) ..."
	@for d in $(ARTIFACT_DIRS); do \
		find . -type d -name "$$d" -prune -print -exec rm -rf {} + ; \
	done
	@for d in $(ARTIFACT_GLOB_DIRS); do \
		find . -type d -name "$$d" -prune -print -exec rm -rf {} + ; \
	done
	@for f in $(ARTIFACT_FILES); do \
		find . -type f -name "$$f" -print -delete ; \
	done
	@find . -type f \( -name '*.pyc' -o -name '*.pyo' -o -name '*.pyd' -o -name '*.test' \) -print -delete
	@# The shared Rust target directory is removed by path, not by name: the
	@# ARTIFACT_DIRS sweep above matches `target`, which cargo-target is not.
	@if [ -d "$(CARGO_TARGET_DIR)" ]; then echo "$(CARGO_TARGET_DIR)"; rm -rf "$(CARGO_TARGET_DIR)"; fi
	@echo "Clean complete."

clean-dry:
	@echo "Would remove (dry run, nothing deleted):"
	@for d in $(ARTIFACT_DIRS) $(ARTIFACT_GLOB_DIRS); do \
		find . -type d -name "$$d" -prune -print ; \
	done
	@for f in $(ARTIFACT_FILES); do \
		find . -type f -name "$$f" -print ; \
	done
	@find . -type f \( -name '*.pyc' -o -name '*.pyo' -o -name '*.pyd' -o -name '*.test' \) -print
	@if [ -d "$(CARGO_TARGET_DIR)" ]; then echo "$(CARGO_TARGET_DIR)"; fi

# Also drops the codegraph index. Separate target so a routine `clean`
# never forces an expensive re-index.
clean-index: clean
	@echo "Removing codegraph index ..."
	@find . -type d -name .codegraph -prune -print -exec rm -rf {} +
	@echo "Index removed."
