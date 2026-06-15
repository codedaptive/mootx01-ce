# ARIA_Rust

**Status:** Planned, stub. Canonical role defined in `docs/canon/MOOTX01_AND_ARIA_CANON.md`, Demonstration apps.

ARIA_Rust is the Rust-side demonstration app, the counterpart to ARIA_MacOS and ARIA_iOS on the Swift side. It is not an end-user product. Its purpose is to show a developer how to use the Rust kits.

## Why it exists

The Swift and Rust implementations of MOOTx01 are conformance-gated against shared test vectors (see `ARIA.md`), and the kits ship a Rust port in parallel with Swift. A demonstration set with only Swift apps would teach only one of the two gated ports. ARIA_Rust closes that gap.

## What it demonstrates

- The SDK in use: link the Rust kits or their lib equivalents as compile targets.
- The kit-to-lib pattern: take a kit, make a lib, then build a small monitoring binary that compiles, updates, installs, and does something interesting with it. This is the path the commercial product takes, shipping as libs for the regulation layer.
- Source-as-documentation: the module is itself a source kit, a worked example a developer reads and reuses, and it carries detailed instructions written for agentic agents so an agent can read the entire source and program against the Rust kits autonomously.

## Status

Stub only. Build sequencing follows the substrate and the BrainKits, alongside the Swift demonstration apps.
