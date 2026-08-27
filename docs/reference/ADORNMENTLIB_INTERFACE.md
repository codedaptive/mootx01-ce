---
title: AdornmentLib Interface
version: 0.7.0
status: active
date: 2026-08-26
description: "Public API surface for AdornmentLib in both ports: minter recipes (composed model-pN-sN identities, digests, text|json normalizer), the resident GoldMiner engine seam (pluggable engines; Apple on-device / quantized in-process LLM), validation (mint-path excluded), generation with silent mechanical truncation and map-reduce chunking, command-seam harness vehicle, minter identity and activation values, stored-adornment values, ADORNMENT_MAX_LENGTH and ADORNMENT_CHUNK_THRESHOLD."
spec_type: library
authors: MOOTx01 maintainers
package: AdornmentLib
languages: [swift, rust]
relates_to:
  - docs/reference/ADORNMENTLIB_SPEC.md
  - benchmark-ee/benchmarks/payload-economics.md
---

# AdornmentLib Interface

## Swift (AdornmentLib module)

```swift
/// ── Gold miner (0.5.0) — the resident, engine-pluggable mint surface ──
///
/// One pluggable engine: prompt in, claim out. Engines own their model
/// residency; nil = per-prompt failure (pair retried). Swapping models
/// means implementing this protocol, never rewriting the miner.
public protocol GoldMinerEngine: Sendable {
    var identity: String { get }
    func mint(prompt: String) async -> String?
}

/// Process-wide resident owner: ONE engine residency serves every mint
/// path (impatient one-off writes, dreaming batches, import drains).
/// Engine resolution: installed engine → Apple on-device model (the ONLY
/// engine on iOS, the DEFAULT on macOS) → MOOT_MINT_CMD command engine
/// (macOS harness vehicle) → inactive.
public actor GoldMiner {
    public static let shared: GoldMiner
    public func install(engine: any GoldMinerEngine)
    public var engineIdentity: String? { get }
    public func mintOne(prompt: String) async -> String?
    public func mintBatch(prompts: [String]) async -> [String?]
}

/// Apple's bundled on-device model (FoundationModels; macOS 26+/iOS 26+).
/// Weights are OS-resident — zero added footprint.
public final class AppleFoundationEngine: GoldMinerEngine {
    public static func ifAvailable() -> AppleFoundationEngine?
}

/// External-command engine over the MOOT_MINT_CMD contract (macOS-only;
/// harness vehicle, never the product default).
public final class CommandEngine: GoldMinerEngine {
    public init(command: String)
}

/// ── Minter recipes (0.6.0) — compile-time generation contracts ──
///
/// The payload shape a minting model emits (drives the normalizer).
public enum MintOutputKind: String, Sendable, Equatable { case text, json }

/// One complete minter generation contract. Built-in recipes are the
/// compile-time constants block (version-ledger comment header; model
/// choice is a developer build-time decision). `id` is the cross-port
/// minter identity `<model>-p<promptVersion>-s<settingsVersion>`.
public struct MinterRecipe: Sendable, Equatable {
    public let model: String
    public let promptVersion: Int
    public let settingsVersion: Int
    public let systemPrompt: String
    public let chatTemplate: String   // {system}/{input} wrapper; trivial for session engines
    public let parameters: [String: String]
    public let output: MintOutputKind
    public let family: String
    public var id: String { get }
    public var promptDigest: String { get }
    public var parametersDigest: String { get }
    public func descriptor(id rowID: String, isActive: Bool) -> AdornmentMinterDescriptor
    public func assemblePrompt(_ rawInput: String) -> String
    /// Built-in: Apple FoundationModels recipe ("apple-fm-p1-s1").
    public static let apple: MinterRecipe
}

/// FNV-1a 64-bit digest, lowercase hex — the recipe fingerprint
/// function. Non-cryptographic; identical values in both ports
/// (golden-pinned).
public func fnv1a64Hex(_ s: String) -> String

/// Normalize a raw model emission into the claim line per output kind:
/// text = first meaningful line; json = deterministic flattening
/// (lexical key order, "; " joins; unparseable falls back to text).
/// "" = per-prompt failure upstream.
public func normalizeMintOutput(_ raw: String, kind: MintOutputKind) -> String

/// Canonical claim-line extraction (fences, list markers, control
/// tokens stripped; first non-empty line).
public func extractClaimLine(_ raw: String) -> String

// MARK: - Constants

/// Maximum character count for a valid adornment text.
/// Provisional pending the judging-density study (SPEC §2).
public let ADORNMENT_MAX_LENGTH: Int = 280

// MARK: - Generation identity values

/// Reusable configuration of one adornment minter.
/// `parameters` contains every generation-affecting setting. A persistence
/// owner serializes the map in key order when it needs a canonical form.
public struct AdornmentMinterDescriptor: Sendable, Equatable {
    public let id: String
    public let name: String
    public let family: String
    public let modelID: String
    public let modelVersion: String
    public let promptDigest: String
    public let parameters: [String: String]
    public let isActive: Bool

    public init(
        id: String,
        name: String,
        family: String,
        modelID: String,
        modelVersion: String,
        promptDigest: String,
        parameters: [String: String],
        isActive: Bool)
}

/// One persistent output. All other Drawer and minter data is referenced.
public struct StoredAdornment: Sendable, Equatable {
    public let drawerID: String
    public let minterID: String
    public let text: String

    public init(drawerID: String, minterID: String, text: String)
}

// MARK: - AdornmentValidators

/// Validation gate for adornment candidates (AV-1..AV-8).
///
/// All methods are pure functions. No I/O. No side effects.
public enum AdornmentValidators {

    /// AV-1..AV-3: Word-boundary containment check.
    /// Returns true if `entity` appears as a whole word in `sourceText`.
    public static func containsWordBoundary(entity: String, in sourceText: String) -> Bool

    /// AV-4..AV-5: Count validation.
    /// Returns true if `expectedCount` appears as a token in `sourceText`
    /// when `claim` references that count.
    public static func validateCount(
        claim: String, in sourceText: String, expectedCount: Int) -> Bool

    /// AV-6..AV-8: Date grounding validation.
    /// Returns true if every 4-digit year token appearing in `claim`
    /// also appears in `sourceText`. Returns true when claim has no year.
    public static func validateDate(claim: String, in sourceText: String) -> Bool
}

/// Protocol-adapter for injecting AdornmentValidators as closures
/// into GeniusLocusKit without creating a circular package dependency.
public struct AdornmentValidationFunctions: Sendable {
    public let containsWordBoundary: @Sendable (String, String) -> Bool
    public let validateCount: @Sendable (String, String, Int) -> Bool
    public let validateDate: @Sendable (String, String) -> Bool

    public init(
        containsWordBoundary: @escaping @Sendable (String, String) -> Bool,
        validateCount: @escaping @Sendable (String, String, Int) -> Bool,
        validateDate: @escaping @Sendable (String, String) -> Bool)
}

// MARK: - AdornmentGenerator

/// Build the adornment prompt for a drawer's content.
///
/// The prompt instructs the adornment binary to produce ONE dense line of
/// word blobs (2-3 word chunks, "; "-separated, decreasing importance)
/// per SPEC_ADORNMENT §§2b+8: entities in full, dates only when available
/// in the prompt data (a "Record date:" line is emitted when eventDate is
/// provided), counts as stated, soft length ask.
public func buildAdornmentPrompt(
    drawerContent: String,
    eventDate: String? = nil,
    maxLength: Int = ADORNMENT_MAX_LENGTH) -> String

/// Invoke the adornment command seam (MOOT_MINT_CMD).
///
/// Reads MOOT_MINT_CMD from the environment. Returns nil when the env var
/// is unset or empty, the binary exits non-zero, or the output is empty or
/// non-UTF-8. Non-empty output is trimmed and SILENTLY MECHANICALLY
/// TRUNCATED to `maxLength` characters (the prompt never mentions
/// truncation; the code enforces the ceiling).
///
/// Resident batch mode: selected by capability probe, never
/// configuration — the seam runs `CMD --mint-capabilities` once per
/// command (cached; the probe answers before any model load) and uses
/// batch when the minter lists "batch". The command is then spawned
/// ONCE with `--batch` and held resident by an internal actor session
/// (`ResidentMintSession`); prompts go down its stdin NUL-terminated and
/// responses return NUL-terminated in order. A bare-NUL response is the
/// minter's per-prompt failure marker (nil, pair retried). Any protocol
/// fault tears the child down; the next call respawns. A changed
/// MOOT_MINT_CMD tears down first — a previous minter's replies never
/// answer a new minter's prompts. The child is reaped after 120 s idle so
/// its model residency is released between dream-time fires. One-shot
/// spawning (above) remains the default contract.
public func invokeAdornmentCommand(
    prompt: String, maxLength: Int = ADORNMENT_MAX_LENGTH) async -> String?

// MARK: - Map-reduce chunking

/// Character threshold above which a record is minted in pieces
/// (tightest miner window: apple-mint 8192 tokens at 4 bytes/token floor).
public let ADORNMENT_CHUNK_THRESHOLD: Int = 16_000

/// Mint one record's adornment, chunking when the record exceeds
/// `chunkThreshold`: deterministic line-boundary pieces, per-piece mint,
/// concatenate, re-summarize through the model for the final blob line.
/// The `mint` closure is the model seam (prompt in, candidate out) —
/// production passes `invokeAdornmentCommand`.
public func mintAdornmentMapReduce(
    drawerContent: String,
    eventDate: String?,
    maxLength: Int = ADORNMENT_MAX_LENGTH,
    chunkThreshold: Int = ADORNMENT_CHUNK_THRESHOLD,
    mint: (String) async -> String?
) async -> String?
```

## Rust (adornment_lib crate)

```rust
// src/lib.rs
pub mod adornment_validators;
pub mod adornment_generator;
pub mod adornment_identity;

// Re-exported at crate root:
pub use adornment_validators::AdornmentValidators;
pub use adornment_generator::{
    build_adornment_prompt,
    invoke_adornment_command,
    ADORNMENT_MAX_LENGTH,
};
pub use adornment_identity::{
    AdornmentMinterDescriptor,
    StoredAdornment,
};

// src/adornment_identity.rs
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AdornmentMinterDescriptor {
    pub id: String,
    pub name: String,
    pub family: String,
    pub model_id: String,
    pub model_version: String,
    pub prompt_digest: String,
    pub parameters: BTreeMap<String, String>,
    pub is_active: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredAdornment {
    pub drawer_id: String,
    pub minter_id: String,
    pub text: String,
}

// src/adornment_validators.rs
pub struct AdornmentValidators;

impl AdornmentValidators {
    pub fn contains_word_boundary(entity: &str, source_text: &str) -> bool;
    pub fn validate_count(claim: &str, source_text: &str, expected_count: usize) -> bool;
    pub fn validate_date(claim: &str, source_text: &str) -> bool;
}

// src/adornment_generator.rs
pub const ADORNMENT_MAX_LENGTH: usize = 280;
pub const ADORNMENT_CHUNK_THRESHOLD: usize = 16_000;

pub fn build_adornment_prompt(
    drawer_content: &str,
    event_date: Option<&str>,
    max_length: usize,
) -> String;

// Non-empty output is trimmed and silently mechanically truncated to
// max_length; None when the command is absent, exits non-zero, or the
// output is empty/non-UTF-8.
pub fn invoke_adornment_command(prompt: &str, max_length: usize) -> Option<String>;

pub fn mint_adornment_map_reduce(
    drawer_content: &str,
    event_date: Option<&str>,
    max_length: usize,
    chunk_threshold: usize,
    mint: impl FnMut(&str) -> Option<String>,
) -> Option<String>;
```

## Package layout

```
packages/libs/AdornmentLib/
├── Package.swift               — zero external deps
├── Sources/AdornmentLib/
│   ├── AdornmentValidators.swift
│   ├── AdornmentGenerator.swift
│   └── AdornmentIdentity.swift
├── Tests/AdornmentLibTests/
│   └── AdornmentValidatorsTests.swift  — AV-1..AV-8 golden pins
└── rust/
    ├── Cargo.toml
    └── src/
        ├── lib.rs
        ├── adornment_validators.rs
        ├── adornment_generator.rs
        └── adornment_identity.rs
```

The identity types are persistence-neutral. Their string identifiers are
assigned by LocusKit; AdornmentLib opens no database and imports no Drawer or
estate type. LocusKit owns the permanent normalized storage interface.

## Rust twin (gold miner)

```rust
pub trait GoldMinerEngine: Send {
    fn identity(&self) -> String;
    fn mint(&mut self, prompt: &str) -> Option<String>;
}
pub fn install_engine(engine: Box<dyn GoldMinerEngine>);
pub fn engine_identity() -> Option<String>;
pub fn engine_installed() -> bool;
pub fn mint_one(prompt: &str) -> Option<String>;
pub fn mint_batch(prompts: &[String]) -> Vec<Option<String>>;

/// The Rust port's small local engine: GGUF-quantized Qwen2-family model
/// via candle's quantized kernels, in-process. Q4 weights (~350 MB for
/// 0.5B) computed directly on quantized blocks — no full-precision copy
/// ever exists; the KV cache resets every mint. Enforced residency
/// budget: the test gate fails if load+mint exceeds 1 GiB RSS delta.
pub struct QuantizedLlmEngine { /* engine plug */ }
impl QuantizedLlmEngine {
    pub fn load(gguf_path: &Path, tokenizer_path: &Path) -> Result<Self, String>;
    /// Load under a specific recipe (comparison builds; default = QUANTIZED_RECIPE).
    pub fn load_with_recipe(gguf_path: &Path, tokenizer_path: &Path, recipe: MinterRecipe) -> Result<Self, String>;
}
pub fn default_engine_paths(data_root: &Path) -> (PathBuf, PathBuf);

// ── Minter recipes (0.6.0) — twins of the Swift surface ──
pub enum MintOutputKind { Text, Json }
pub struct MinterRecipe {
    pub model: &'static str,
    pub prompt_version: u32,
    pub settings_version: u32,
    pub system_prompt: &'static str,
    pub chat_template: &'static str, // {system}/{input} wrapper
    pub parameters: &'static [(&'static str, &'static str)],
    pub output: MintOutputKind,
    pub family: &'static str,
}
impl MinterRecipe {
    pub fn id(&self) -> String;                    // "<model>-pN-sN"
    pub fn prompt_digest(&self) -> String;
    pub fn parameters_digest(&self) -> String;
    pub fn descriptor(&self, row_id: &str, is_active: bool) -> AdornmentMinterDescriptor;
    pub fn assemble_prompt(&self, raw_input: &str) -> String;
}
/// The Qwen2-family chatml wrapper constant.
pub const CHATML_TEMPLATE: &str;
/// Built-in: the quantized engine recipe ("qwen2-0.5b-q4km-p1-s1").
pub const QUANTIZED_RECIPE: MinterRecipe;
pub fn fnv1a64_hex(s: &str) -> String;
pub fn normalize_mint_output(raw: &str, kind: MintOutputKind) -> String;
pub fn extract_claim_line(raw: &str) -> String;
```

Provisioning: `rust/scripts/fetch-goldminer-model.sh` fetches the default
Q4 GGUF. Any Qwen2-family GGUF at the same destination runs without
engine-code changes; the artifact choice is governed by the recipe
constants (an artifact swap changes `QUANTIZED_RECIPE`'s model token in
the same commit — SPEC § Minter recipes).

## Changelog

- 0.7.0 (2026-08-26): `chatTemplate`/`chat_template` on MinterRecipe
  (`{system}`/`{input}` placeholders; covered by promptDigest);
  `assemblePrompt`/`assemble_prompt`; `CHATML_TEMPLATE` constant;
  `QuantizedLlmEngine::load_with_recipe`; GoldMinerEngine +
  QuantizedLlmEngine re-exported at crate root.

- 0.6.0 (2026-08-26): Minter recipes — `MinterRecipe` /
  `MintOutputKind`, composed `<model>-pN-sN` identities as engine
  identities (Apple = "apple-fm-p1-s1"; quantized =
  "qwen2-0.5b-q4km-p1-s1"), FNV-1a-64 digests (`fnv1a64Hex` /
  `fnv1a64_hex`, golden-pinned cross-port), and the generic
  text|json normalizer (`normalizeMintOutput` / `normalize_mint_output`;
  canonical `extractClaimLine` / `extract_claim_line` replaces the
  per-engine extraction statics).

- 0.5.0 (2026-08-26): GoldMiner — the resident, engine-pluggable mint
  surface, both ports (Bob's one-pass directive: coverage is a MUST,
  resident always, no gigabytes, one-off + batch on one residency,
  Apple-only iOS / Apple-default macOS, Rust equivalent = in-process
  quantized LLM with an enforced memory budget). GLK's AdornmentPass
  default resolver routes through GoldMiner; the command seam survives
  as the macOS harness vehicle.

- 0.4.1 (2026-08-26): Batch selection is a CAPABILITY PROBE
  (`CMD --mint-capabilities` listing "batch"), cached per command —
  environment variables are not a viable end-user mechanism (Bob ruling
  2026-08-26); the MOOT_MINT_BATCH env seam is removed same-day,
  pre-release.
- 0.4.0 (2026-08-26): Resident batch minting: one minter child
  (`--batch`, NUL-framed prompt/response protocol) per process, both
  ports (`ResidentMintSession` / `resident_mint`), with per-prompt
  failure isolation, command-change respawn, and (Swift) a 120 s idle
  reaper. Motivation: one-shot spawning costs a full model load per
  claim — bulk minting and dream-time passes amortize one load.

### 0.3.0 -- 2026-08-25

Aligned the generator surface with the shipped slice-C code (b87b6a859)
and the SPEC_ADORNMENT § 8 rulings: `buildAdornmentPrompt` /
`build_adornment_prompt` carry the `eventDate` / `event_date` parameter
(Record date line); `invokeAdornmentCommand` documents silent mechanical
truncation (nil only for absent command, non-zero exit, empty or
non-UTF-8 output — over-length rejection does not exist); added the
previously undocumented shipped map-reduce surface
(`mintAdornmentMapReduce` / `mint_adornment_map_reduce` with the `mint`
closure seam, `ADORNMENT_CHUNK_THRESHOLD = 16_000`); Rust
`invoke_adornment_command` correctly listed as synchronous. No
behavioral change.

### 0.2.0 -- 2026-08-25

Added the cross-port `AdornmentMinterDescriptor` and `StoredAdornment` value
surfaces. The descriptor carries runtime activation, while each stored output
references only its Drawer and minter. LocusKit owns persistence; no benchmark
sidecar or variant-set abstraction is part of this interface.

### 0.1.0 -- 2026-08-23

Initial release. `AdornmentValidators` (AV-1..AV-8, moved from NeuronKit
`MarkerValidators`), `AdornmentGenerator` seam (`MOOT_MINT_CMD`),
`ADORNMENT_MAX_LENGTH = 280` (provisional). Both Swift and Rust ports ship
from this version. Golden pins AV-1..AV-8 verified in both ports.
