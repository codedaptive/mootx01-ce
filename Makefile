# Makefile for the mootx01-ee source tree.
#
# `make clean` strips all build artifacts from the entire tree so the
# checkout can be zipped for backup, or its footprint reclaimed, without
# carrying the ~16 GB of compiler output the Swift/Rust builds produce.
#
# Scope is the whole repo: packages/, apps/, tools/, installer/, and the
# substrate validation harnesses under docs/validation/. For cleaning
# packages/ alone, packages/Makefile still has its own `clean` target.
#
# Removes, at any depth beneath this directory:
#   .build/        — Swift Package Manager build output
#   .swiftpm/      — SwiftPM local config/cache
#   target/        — Rust/Cargo build output (every crate)
#   DerivedData/   — Xcode build output
#   __pycache__/   — Python bytecode cache (port/python harnesses)
#   .pytest_cache/ .ruff_cache/ .mypy_cache/ — Python tool caches
#   *.egg-info/ htmlcov/ — Python packaging/coverage output
# and stray *.pyc / *.test / coverage.out / coverage.html / .coverage
# files, plus .DS_Store files left by Finder.
#
# NOT removed: .codegraph/ (the codegraph index — a live tool index, not
# build output; deleting it forces a full re-index). Run `make clean-index`
# explicitly if you want it gone too.
#
# `make clean-dry` prints what would be deleted without removing anything.

.PHONY: clean clean-dry clean-index

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
