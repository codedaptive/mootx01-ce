# ARIA_Rust

**Status:** Planned — not yet built. (A Rust-side demonstration app; role defined in `docs/concepts/MOOTX01_AND_ARIA_CANON.md` under "Demonstration apps".)

ARIA_Rust is the Rust-side demonstration app, the counterpart to ARIA_MacOS and ARIA_iOS on the Swift side. It is not an end-user product. Its purpose is to show a developer how to use the Rust kits.

## Why it exists

The Swift and Rust implementations of MOOTx01 are conformance-gated against shared test vectors (see `ARIA.md`), and the kits ship a Rust port in parallel with Swift. A demonstration set with only Swift apps would teach only one of the two gated ports. ARIA_Rust closes that gap.

## What it demonstrates

- The SDK in use: link the Rust kits or their lib equivalents as compile targets.
- The kit-to-lib pattern: take a kit, expose it as a lib, then build a small monitoring binary that compiles, updates, installs, and does something useful with it.
- Source-as-documentation: the module is itself a source kit, a worked example a developer reads and reuses, and it carries detailed instructions written for agentic agents so an agent can read the entire source and program against the Rust kits autonomously.

## Status

Not yet built. Until it lands, the working Rust path is the GLK quickstart
(`docs/start-here/SDK_QUICKSTART.md`) and each kit's `rust/tests/` — worked, compiling references.
