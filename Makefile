# Makefile — mootx01 build orchestration (Swift + Rust polyglot monorepo).
#
# There is no single native build system spanning both languages, so this
# Makefile is the one place that builds, tests, packages, and cleans the
# whole tree. Package/crate lists are discovered dynamically (find), so new
# kits and crates are picked up automatically — nothing to register here.
#
# Common targets:
#   make build        build every Swift package + Rust crate (debug)
#   make test         test every Swift package + Rust crate
#   make conformance  run the cross-language shared-vector gate
#   make release      build the host-arch release archive (mootx01 + moot-mgr)
#   make list         show the discovered packages/crates
#   make clean        strip all build artifacts (clean-dry to preview)
#   make help         this list
#
# build/test are fail-fast: the first failing package stops the run and
# prints which one failed.

SHELL := /bin/bash

# ── Discovery ─────────────────────────────────────────────────────────────
SWIFT_PKGS  := $(shell find . -name Package.swift  -not -path '*/.build/*' | xargs -n1 dirname | sort)
RUST_CRATES := $(shell find . -name Cargo.toml -not -path '*/target/*' -not -path '*/.build/*' | xargs -n1 dirname | sort)

HARNESS := docs/validation/substrate_math_performance/test-harness
DIST    ?= dist

.PHONY: help build build-swift build-rust test test-swift test-rust \
        conformance release list clean clean-dry clean-index check-static-assets

help:
	@echo "mootx01 build targets:"
	@echo "  build        — build all Swift packages + Rust crates (debug)"
	@echo "  build-swift  — swift build each Swift package"
	@echo "  build-rust   — cargo build each Rust crate"
	@echo "  test         — test all Swift packages + Rust crates"
	@echo "  test-swift   — swift test each Swift package (skips ones with no Tests/)"
	@echo "  test-rust    — cargo test each Rust crate"
	@echo "  check-static-assets — verify StaticAssets.swift matches DashboardAssets/ source"
	@echo "  conformance  — cross-language shared-vector conformance gate"
	@echo "  release      — build host-arch release archive (mootx01 + moot-mgr) into $(DIST)/"
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
test: test-swift test-rust check-static-assets

test-swift:
	@for d in $(SWIFT_PKGS); do \
		if [ -d "$$d/Tests" ]; then \
			echo "── swift test: $$d"; \
			( cd "$$d" && swift test ) || { echo "FAILED (swift test): $$d"; exit 1; }; \
		else \
			echo "── skip (no Tests/): $$d"; \
		fi; \
	done
	@echo "✓ all Swift tests passed"

test-rust:
	@for d in $(RUST_CRATES); do \
		echo "── cargo test: $$d"; \
		( cd "$$d" && cargo test ) || { echo "FAILED (cargo test): $$d"; exit 1; }; \
	done
	@echo "✓ all Rust tests passed"

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
	   apps/moot-mgr/Sources/MootManager/DashboardAssets/sigma.js \
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
	@arch=$$(uname -m); asset="mootx01-local-macos-$$arch.tar.gz"; \
	 ( cd "$(DIST)" && tar -czf "$$asset" mootx01 moot-mgr && shasum -a 256 "$$asset" ); \
	 echo "✓ release archive written to $(DIST)/"

list:
	@echo "Swift packages ($(words $(SWIFT_PKGS))):"; for d in $(SWIFT_PKGS); do echo "  $$d"; done
	@echo "Rust crates ($(words $(RUST_CRATES))):"; for d in $(RUST_CRATES); do echo "  $$d"; done

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

# Also drops the codegraph index. Separate target so a routine `clean`
# never forces an expensive re-index.
clean-index: clean
	@echo "Removing codegraph index ..."
	@find . -type d -name .codegraph -prune -print -exec rm -rf {} +
	@echo "Index removed."
