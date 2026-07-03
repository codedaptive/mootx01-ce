# Makefile for the packages source tree.
#
# Single purpose: `make clean` strips all build artifacts from the
# source tree so the directory can be zipped for backup without
# carrying gigabytes of compiler output.
#
# Removes, at any depth beneath this directory:
#   .build/      — Swift Package Manager build output
#   .swiftpm/    — SwiftPM local config/cache
#   target/      — Rust/Cargo build output (every crate)
#   DerivedData/ — Xcode build output
# and stray .DS_Store files left by Finder.

.PHONY: clean concordance

clean:
	@echo "Cleaning build artifacts under $(CURDIR) ..."
	@find . -type d -name .build      -prune -print -exec rm -rf {} +
	@find . -type d -name .swiftpm    -prune -print -exec rm -rf {} +
	@find . -type d -name target      -prune -print -exec rm -rf {} +
	@find . -type d -name DerivedData -prune -print -exec rm -rf {} +
	@find . -type f -name .DS_Store -print -delete
	@echo "Clean complete."

# Concordance gate: fail if any public Swift/Rust type lacks a concordance row.
# Same check CI runs (.github/workflows/concordance.yml). Run before committing
# a new public type. Drop --strict for an advisory report.
concordance:
	@cd .. && python3 packages/scripts/concordance_audit/concordance_audit.py --strict
