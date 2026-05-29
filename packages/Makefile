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

# `audit-flags` color-flags files for security-audit triage in Finder:
#   Red    = added on this branch vs develop (new code)
#   Orange = changed on this branch vs develop
# `audit-clear` removes those labels. Both delegate to audit-flags.sh.
# Labels are local Finder xattrs only — not preserved by zip or git.

.PHONY: clean audit-flags audit-clear

clean:
	@echo "Cleaning build artifacts under $(CURDIR) ..."
	@find . -type d -name .build      -prune -print -exec rm -rf {} +
	@find . -type d -name .swiftpm    -prune -print -exec rm -rf {} +
	@find . -type d -name target      -prune -print -exec rm -rf {} +
	@find . -type d -name DerivedData -prune -print -exec rm -rf {} +
	@find . -type f -name .DS_Store -print -delete
	@echo "Clean complete."

audit-flags:
	@bash audit-flags.sh flag

audit-clear:
	@bash audit-flags.sh clear
