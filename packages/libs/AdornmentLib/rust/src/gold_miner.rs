//! The resident gold-miner seam (ADORNMENTLIB_SPEC 0.5.0 § Gold miner).
//! Rust twin of Swift `GoldMiner` / `GoldMinerEngine`.
//!
//! Requirements (Bob, 2026-08-26 — verbatim constraints):
//!   - EVERY record in the database must be adorned; coverage is a MUST.
//!   - Sustained single-record ingest (hundreds/hour) and bulk import both
//!     feed the miner; it is NOT a lightly used tool.
//!   - The miner is RESIDENT — never load-on-demand — and must not consume
//!     gigabytes.
//!   - It serves one-off mining (impatient writes) and batch mining
//!     (dreaming passes; imports may defer to dreaming).
//!   - The Rust port carries its own small local engine (quantized LLM),
//!     the equivalent of Swift's Apple on-device engine.
//!
//! Architecture: the ENGINE is a plug. `GoldMinerEngine` is the only thing
//! a model implementation touches; everything above it (resident owner,
//! one-off/batch entry points, the adornment pass, map-reduce, truncation)
//! is engine-agnostic. Swapping models means implementing one trait, never
//! rewriting the miner.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use candle_core::quantized::gguf_file;
use candle_core::{Device, Tensor};
use crate::minter_recipe::{
    normalize_mint_output, top_level_json_object_prefix, MinterRecipe, MintOutputKind,
    QUANTIZED_RECIPE,
};
use crate::quantized_qwen2_lean::ModelWeights as Qwen2LeanWeights;
use candle_transformers::models::quantized_qwen3::ModelWeights as Qwen3Weights;
use tokenizers::Tokenizer;

// ── Engine plug ─────────────────────────────────────────────────────────────

/// One pluggable minting engine: prompt in, claim out.
///
/// Engines own their model residency. `mint` returns None for a per-prompt
/// failure (the pair stays in debt and is retried); it must never take the
/// whole miner down for one bad prompt.
pub trait GoldMinerEngine: Send {
    /// Stable identity for logs, run provenance, and the minter master.
    /// Product engines use their recipe's composed ID (e.g.
    /// "qwen2-0.5b-q4km-p2-s1"). Never a user-facing name.
    fn identity(&self) -> String;
    /// Mint one claim. None = per-prompt failure.
    fn mint(&mut self, prompt: &str) -> Option<String>;
}

// ── Resident owner ──────────────────────────────────────────────────────────

static GOLD_MINER: Mutex<Option<Box<dyn GoldMinerEngine>>> = Mutex::new(None);

/// Install the process's engine. The composition layer calls this once at
/// startup (or on minter-family activation). The engine loads when
/// constructed and is NEVER unloaded (the resident rule); installing a
/// different engine replaces the old one.
pub fn install_engine(engine: Box<dyn GoldMinerEngine>) {
    if let Ok(mut slot) = GOLD_MINER.lock() {
        *slot = Some(engine);
    }
}

/// The active engine's identity, or None when no engine is installed.
pub fn engine_identity() -> Option<String> {
    GOLD_MINER
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|e| e.identity()))
}

/// One-off mint for the impatient write path. The resident engine makes
/// this sub-second; there is no load cost on this path by design. None
/// when no engine is installed or the engine fails this prompt.
pub fn mint_one(prompt: &str) -> Option<String> {
    let mut slot = GOLD_MINER.lock().ok()?;
    slot.as_mut()?.mint(prompt)
}

/// Whether an engine is installed (drives the generator's routing: an
/// installed engine wins over the subprocess seam).
pub fn engine_installed() -> bool {
    GOLD_MINER
        .lock()
        .map(|slot| slot.is_some())
        .unwrap_or(false)
}

/// Batch mint for dreaming passes and import drains. Order-preserving; a
/// None element is that prompt's per-prompt failure. Runs on the SAME
/// resident engine as `mint_one` — batch is an access pattern, not a
/// second residency.
pub fn mint_batch(prompts: &[String]) -> Vec<Option<String>> {
    match GOLD_MINER.lock() {
        Ok(mut slot) => match slot.as_mut() {
            Some(engine) => prompts.iter().map(|p| engine.mint(p)).collect(),
            None => vec![None; prompts.len()],
        },
        Err(_) => vec![None; prompts.len()],
    }
}

// ── Quantized in-process engine ─────────────────────────────────────────────

/// Default maximum new tokens generated per minting call. Claims are
/// short (one dense line). Capping prevents runaway generation when the
/// model fails to emit an EOS token. The effective cap is PER-RECIPE:
/// the engine reads the recipe's "max_new_tokens" setting at load
/// (NUEXTRACT-TAIL finding 2026-08-31: JSON-emitting recipes need more
/// headroom than one prose line — a 96-token cap truncated NuExtract's
/// JSON on long records, and the truncated object salvaged to a bare
/// "{" claim ~28% of the time). This constant is the fallback when a
/// recipe carries no such setting.
const MAX_NEW_TOKENS: usize = 96;

/// Vocabulary token ID for `<|im_end|>` (end of assistant turn).
/// Identical across every supported architecture — Qwen2, Qwen3, and
/// the Qwen3-based fine-tunes share the Tiktoken vocabulary (verified
/// against each checkpoint's tokenizer.json, 2026-08-31).
const IM_END_TOKEN_ID: u32 = 151645;
/// Vocabulary token ID for `<|endoftext|>` (EOS fallback). Same
/// cross-architecture note as `IM_END_TOKEN_ID`.
const ENDOFTEXT_TOKEN_ID: u32 = 151643;

/// The quantized weight graphs this engine can run, dispatched by the
/// recipe's model token at load (QWEN3-ENGINE, 2026-08-31). Qwen2-family
/// models use the lean vendored module (F16 embedding table — the
/// sub-GiB residency trick); Qwen3-family models use upstream candle,
/// which dequantizes its embedding table to F32 at load (~600 MB on the
/// 151k vocabulary) — acceptable for workshop/benchmark use, and the
/// lean-vendor treatment is a follow-up gated on a product-residency
/// need, never applied speculatively.
enum ArchWeights {
    Qwen2Lean(Qwen2LeanWeights),
    Qwen3(Qwen3Weights),
}

impl ArchWeights {
    /// Uniform forward: both candle modules share the exact
    /// `(input, offset) -> logits` contract (verified signatures,
    /// Smythe QWEN3-ENGINE pre-flight).
    fn forward(&mut self, input: &Tensor, offset: usize) -> candle_core::Result<Tensor> {
        match self {
            ArchWeights::Qwen2Lean(m) => m.forward(input, offset),
            ArchWeights::Qwen3(m) => m.forward(input, offset),
        }
    }

    /// Reset per-mint state. The KV-cache contract DIFFERS between the
    /// modules: the lean Qwen2 module discards its cache itself whenever
    /// a forward runs at position 0, but upstream quantized_qwen3's
    /// ConcatKvCache appends UNCONDITIONALLY — without this explicit
    /// clear, a second mint would decode against the previous mint's
    /// cache (wrong claims, unbounded growth). Called at the top of
    /// every generate().
    fn reset_mint_state(&mut self) {
        match self {
            ArchWeights::Qwen2Lean(_) => {} // self-resetting at position 0
            ArchWeights::Qwen3(m) => m.clear_kv_cache(),
        }
    }
}

/// The Rust port's small local engine: a GGUF-quantized model run
/// in-process through candle's quantized kernels, dispatched across the
/// supported architectures (`ArchWeights`: Qwen2-family lean module,
/// Qwen3-family upstream module).
///
/// Memory contract (the reason this engine exists):
///   - Weights load from a quantized GGUF (~350 MB for a 0.5B Q4 model)
///     and compute runs directly on the quantized blocks — a
///     full-precision copy of the model NEVER exists (the f32
///     up-conversion that produced the 10 GB benchmark minter is
///     structurally impossible here). Exception: upstream modules
///     dequantize the embedding table at load (see ArchWeights doc).
///   - The KV cache resets on every mint (`reset_mint_state`). No
///     growth across a day of ingest.
///   - One instance per process, shared by every mint path.
pub struct QuantizedLlmEngine {
    model: ArchWeights,
    tokenizer: Tokenizer,
    device: Device,
    /// The engine's generation contract: prompt template, settings, output
    /// kind, and the composed minter identity. Selected at load time
    /// (registry default, or the operator's `MOOT_MINT_MODEL` choice via
    /// `selected_recipe`) — the GGUF at the load path is expected to be
    /// the artifact the recipe's model token names.
    recipe: MinterRecipe,
    /// Harness override for the per-recipe generation budget (spec-v2
    /// finish-or-retry). None = recipe parameter / MAX_NEW_TOKENS
    /// fallback governs, which is every product path.
    max_new_tokens_override: Option<usize>,
    /// JSON recipes stop at the first parseable top-level object in product
    /// operation. Historical benchmark replays can disable this explicitly.
    stop_at_complete_json: bool,
    /// (generated tokens, budget-capped-without-EOS) from the most
    /// recent successful `generate` — the harness binaries' per-mint
    /// telemetry read-back. Product paths ignore it.
    last_telemetry: (usize, bool),
    /// Raw decoded text of the most recent generation BEFORE
    /// normalization (Wave-1 protocol-lab evidence: the normalizer's
    /// first-line extraction hides what a runaway actually produced).
    /// Product paths ignore it.
    last_raw: String,
}

impl QuantizedLlmEngine {
    /// Load a quantized engine from a GGUF file plus its HF tokenizer.json.
    ///
    /// Convenience wrapper for the DEFAULT recipe (Qwen2-family lean
    /// path): any Qwen2-family GGUF plugs in here without code changes.
    /// Other architectures come through `load_with_recipe`, which
    /// dispatches by the recipe's model token.
    pub fn load(gguf_path: &Path, tokenizer_path: &Path) -> Result<Self, String> {
        Self::load_with_recipe(gguf_path, tokenizer_path, QUANTIZED_RECIPE)
    }

    /// Load the engine under a specific recipe — the serve-start
    /// selection path (`selected_recipe` / `recipe_for_model`) and the
    /// benchmark harness builds both come through here. The recipe
    /// supplies identity, prompt contract, and output kind; the model
    /// files must be the artifact the recipe's model token names.
    ///
    /// Harness note (spec-v2, 2026-09-01): `set_max_new_tokens` lets the
    /// candle-mint `--max-new-tokens` flag override the recipe budget for
    /// finish-or-retry runs, and `last_mint_telemetry` reports the most
    /// recent mint's generated-token count and cap-hit flag. Product
    /// paths touch neither.
    pub fn load_with_recipe(
        gguf_path: &Path,
        tokenizer_path: &Path,
        recipe: MinterRecipe,
    ) -> Result<Self, String> {
        // Device selection is BUILD-conditional: every macOS build lights
        // the Metal arm (the Cargo target block enables candle's metal
        // kernels there — Bob ruling 2026-08-29), and the explicit `metal`
        // feature covers non-macOS harness builds. Metal falling over at
        // runtime degrades to CPU rather than failing the load; Windows and
        // Linux product builds compile the CPU arm only.
        #[cfg(any(feature = "metal", target_os = "macos"))]
        let device = Device::new_metal(0).unwrap_or_else(|e| {
            let _ = writeln!(std::io::stderr(), "gold miner: metal unavailable ({e}); using CPU");
            Device::Cpu
        });
        #[cfg(not(any(feature = "metal", target_os = "macos")))]
        let device = Device::Cpu;
        let mut file = std::fs::File::open(gguf_path)
            .map_err(|e| format!("gold miner: open {}: {e}", gguf_path.display()))?;
        let content = gguf_file::Content::read(&mut file)
            .map_err(|e| format!("gold miner: gguf parse {}: {e}", gguf_path.display()))?;
        // Architecture dispatch by the recipe's MODEL TOKEN, never by
        // re-reading GGUF metadata: the recipe is the contract, and a
        // GGUF whose architecture disagrees with the selected recipe
        // should fail the load loudly rather than silently run under
        // the wrong identity. Qwen3-based fine-tunes (osmosis-*) share
        // the qwen3 graph.
        let model = if recipe.model.starts_with("qwen3-")
            || recipe.model.starts_with("osmosis-")
        {
            ArchWeights::Qwen3(
                Qwen3Weights::from_gguf(content, &mut file, &device)
                    .map_err(|e| format!("gold miner: gguf load {}: {e}", gguf_path.display()))?,
            )
        } else {
            ArchWeights::Qwen2Lean(
                Qwen2LeanWeights::from_gguf(content, &mut file, &device)
                    .map_err(|e| format!("gold miner: gguf load {}: {e}", gguf_path.display()))?,
            )
        };
        let mut tokenizer = Tokenizer::from_file(tokenizer_path)
            .map_err(|e| format!("gold miner: tokenizer {}: {e}", tokenizer_path.display()))?;
        // Some checkpoints bake a truncation stanza into tokenizer.json
        // (NuExtract-tiny: max_length 2500). Honoring it silently drops
        // the tail of long prompts inside the engine — prompt bounding
        // is the CALLER's job (chunking upstream, the probe's documented
        // last-resort cap). Disable it so encode() always sees the full
        // prompt. The Swift port's custom BPE never read the stanza, so
        // this also restores cross-port encode parity on long inputs.
        tokenizer
            .with_truncation(None)
            .map_err(|e| format!("gold miner: tokenizer truncation reset: {e}"))?;
        // Return load-time transients to the OS (Linux). GGUF loading frees
        // large per-tensor buffers; glibc retains them without a trim.
        // On macOS the equivalent retention is the allocator's LARGE-chunk
        // cache, which pressure relief does NOT purge — the HOSTING PROCESS
        // must launch with MallocLargeCache=0 (measured: 1.5 GB resident
        // with the cache vs 705 MB without, on identical live data). The
        // daemon's launch configuration owns that variable; the budget test
        // below runs under it.
        #[cfg(target_os = "linux")]
        unsafe {
            libc::malloc_trim(0);
        }

        let stop_at_complete_json = recipe.output == MintOutputKind::Json;
        Ok(Self {
            model,
            tokenizer,
            device,
            recipe,
            max_new_tokens_override: None,
            stop_at_complete_json,
            last_telemetry: (0, false),
            last_raw: String::new(),
        })
    }

    /// Raw decoded text of the most recent mint, pre-normalization
    /// (empty after a failed generate). Diagnostic read-back for the
    /// candle-mint --raw flag; product paths never call this.
    pub fn last_mint_raw(&self) -> &str {
        &self.last_raw
    }

    /// Mint from a FULLY PRE-ASSEMBLED prompt: the recipe's template is
    /// NOT applied (the caller framed the prompt completely), while
    /// generation, normalization, telemetry, and raw capture behave
    /// exactly as `mint`. Harness protocol-lab seam (candle-mint
    /// --no-assemble) for testing candidate templates cross-port before
    /// they become recipe changes; product paths never call this.
    pub fn mint_preassembled(&mut self, full_prompt: &str) -> Option<String> {
        match self.generate(full_prompt) {
            Ok(raw) => {
                let claim = normalize_mint_output(&raw, self.recipe.output);
                self.last_raw = raw;
                if claim.is_empty() { None } else { Some(claim) }
            }
            Err(e) => {
                let _ = writeln!(std::io::stderr(), "{e}");
                None
            }
        }
    }

    /// Override the per-recipe generation budget (spec-v2 harness runs
    /// only; None restores recipe governance).
    pub fn set_max_new_tokens(&mut self, n: Option<usize>) {
        self.max_new_tokens_override = n;
    }

    /// Control the parse-validated JSON structural stop. Product JSON recipes
    /// enable it by default; versioned harnesses set it explicitly so old
    /// protocol results remain reproducible.
    pub fn set_stop_at_complete_json(&mut self, enabled: bool) {
        self.stop_at_complete_json = enabled;
    }

    /// Telemetry from the most recent successful mint: (generated
    /// tokens, cap-hit). Cap-hit = the budget ran out before a stop
    /// token — the spec-v2 finish-or-retry trigger.
    pub fn last_mint_telemetry(&self) -> (usize, bool) {
        self.last_telemetry
    }

    /// Greedy incremental decode: full prompt at position 0 (which resets
    /// the internal KV cache), then one token per step at its cached
    /// offset. Deterministic for a given model file.
    fn generate(&mut self, prompt: &str) -> Result<String, String> {
        // Per-mint isolation (see ArchWeights::reset_mint_state): every
        // mint starts from an empty KV cache regardless of architecture.
        // Telemetry resets with it so a failed mint never reports the
        // previous mint's numbers.
        self.model.reset_mint_state();
        self.last_telemetry = (0, false);
        self.last_raw.clear();
        let encoding = self
            .tokenizer
            .encode(prompt, false)
            .map_err(|e| format!("gold miner: encode: {e}"))?;
        let mut all_ids: Vec<u32> = encoding.get_ids().to_vec();
        let prompt_len = all_ids.len();

        // Per-recipe generation budget (see MAX_NEW_TOKENS doc comment);
        // a harness override (spec-v2 finish-or-retry) wins when set.
        let max_new_tokens = self.max_new_tokens_override.unwrap_or_else(|| {
            self.recipe
                .parameters
                .iter()
                .find(|(k, _)| *k == "max_new_tokens")
                .and_then(|(_, v)| v.parse::<usize>().ok())
                .unwrap_or(MAX_NEW_TOKENS)
        });

        // Cap-hit ledger: true unless a stop token ends the generation
        // inside the budget.
        let mut hit_cap = true;
        for step in 0..max_new_tokens {
            let (input_ids, offset): (&[u32], usize) = if step == 0 {
                (all_ids.as_slice(), 0)
            } else {
                (&all_ids[all_ids.len() - 1..], all_ids.len() - 1)
            };
            let input = Tensor::from_slice(input_ids, (1, input_ids.len()), &self.device)
                .map_err(|e| format!("gold miner: input tensor: {e}"))?;
            let logits = self
                .model
                .forward(&input, offset)
                .map_err(|e| format!("gold miner: forward: {e}"))?;
            // quantized_qwen2 returns last-position logits [batch, vocab];
            // handle a full-sequence shape too so the extraction is
            // rank-aware rather than positional.
            let next_logits = match *logits.dims() {
                [_, _] => logits
                    .squeeze(0)
                    .map_err(|e| format!("gold miner: squeeze: {e}"))?,
                [_, seq, _] => logits
                    .narrow(1, seq - 1, 1)
                    .and_then(|t| t.squeeze(1))
                    .and_then(|t| t.squeeze(0))
                    .map_err(|e| format!("gold miner: narrow: {e}"))?,
                _ => return Err(format!("gold miner: logits rank {:?}", logits.dims())),
            };
            let next_token = next_logits
                .argmax(0)
                .and_then(|t| t.to_scalar::<u32>())
                .map_err(|e| format!("gold miner: argmax: {e}"))?;
            if next_token == IM_END_TOKEN_ID || next_token == ENDOFTEXT_TOKEN_ID {
                hit_cap = false;
                break;
            }
            all_ids.push(next_token);
            if self.stop_at_complete_json
                && self.recipe.output == MintOutputKind::Json
            {
                let generated = self
                    .tokenizer
                    .decode(&all_ids[prompt_len..], true)
                    .map_err(|e| format!("gold miner: incremental decode: {e}"))?;
                if top_level_json_object_prefix(&generated).is_some() {
                    hit_cap = false;
                    break;
                }
            }
        }
        self.last_telemetry = (all_ids.len() - prompt_len, hit_cap);

        let raw = self.tokenizer
            .decode(&all_ids[prompt_len..], true)
            .map_err(|e| format!("gold miner: decode: {e}"))?;
        if self.stop_at_complete_json && self.recipe.output == MintOutputKind::Json {
            if let Some(prefix) = top_level_json_object_prefix(&raw) {
                return Ok(prefix.to_string());
            }
        }
        Ok(raw)
    }

}

impl GoldMinerEngine for QuantizedLlmEngine {
    fn identity(&self) -> String {
        self.recipe.id()
    }

    fn mint(&mut self, prompt: &str) -> Option<String> {
        let assembled = self.recipe.assemble_prompt(prompt);
        match self.generate(&assembled) {
            Ok(raw) => {
                let claim = normalize_mint_output(&raw, self.recipe.output);
                self.last_raw = raw;
                if claim.is_empty() {
                    None
                } else {
                    Some(claim)
                }
            }
            Err(e) => {
                // Per-prompt failure isolation: log to stderr (the server
                // log) and leave the pair in debt; the engine keeps serving.
                let _ = writeln!(std::io::stderr(), "{e}");
                None
            }
        }
    }
}

/// Default engine file locations relative to a data root, so composition
/// layers construct the engine from configuration rather than code:
/// `<root>/goldminer/model.gguf` + `<root>/goldminer/tokenizer.json`.
pub fn default_engine_paths(data_root: &Path) -> (PathBuf, PathBuf) {
    let dir = data_root.join("goldminer");
    (dir.join("model.gguf"), dir.join("tokenizer.json"))
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic fake engine for owner-contract tests: answers
    /// "<identity>:<prompt>", fails on its poison marker.
    struct FakeEngine {
        identity: String,
        poison: Option<String>,
    }
    impl GoldMinerEngine for FakeEngine {
        fn identity(&self) -> String {
            self.identity.clone()
        }
        fn mint(&mut self, prompt: &str) -> Option<String> {
            if let Some(p) = &self.poison {
                if prompt.contains(p.as_str()) {
                    return None;
                }
            }
            Some(format!("{}:{prompt}", self.identity))
        }
    }

    // Owner tests share the process-global slot; run them as one test so
    // ordering is deterministic without a serial harness.
    #[test]
    fn owner_contract_routing_batch_and_replacement() {
        install_engine(Box::new(FakeEngine {
            identity: "fake-a".into(),
            poison: None,
        }));
        assert!(engine_installed());
        assert_eq!(engine_identity().as_deref(), Some("fake-a"));
        assert_eq!(mint_one("hello").as_deref(), Some("fake-a:hello"));

        install_engine(Box::new(FakeEngine {
            identity: "fake-b".into(),
            poison: Some("BAD".into()),
        }));
        let out = mint_batch(&[
            "one".to_string(),
            "BAD apple".to_string(),
            "three".to_string(),
        ]);
        assert_eq!(out[0].as_deref(), Some("fake-b:one"));
        assert_eq!(out[1], None);
        assert_eq!(out[2].as_deref(), Some("fake-b:three"));
    }

    /// Footprint + end-to-end gate for the real quantized engine. Requires
    /// the model files; skips cleanly when absent so CI without the model
    /// stays green. Run with:
    ///   MOOT_GOLDMINER_GGUF=/path/model.gguf \
    ///   MOOT_GOLDMINER_TOKENIZER=/path/tokenizer.json cargo test gold_miner
    #[test]
    fn quantized_engine_mints_within_memory_budget() {
        let (Ok(gguf), Ok(tok)) = (
            std::env::var("MOOT_GOLDMINER_GGUF"),
            std::env::var("MOOT_GOLDMINER_TOKENIZER"),
        ) else {
            eprintln!("gold_miner: model env not set — quantized gate skipped");
            return;
        };
        let rss_before = resident_kb();
        let mut engine = QuantizedLlmEngine::load(Path::new(&gguf), Path::new(&tok))
            .expect("quantized engine must load");
        eprintln!("gold miner gate: rss after load = {} KiB (delta {})", resident_kb(), resident_kb().saturating_sub(rss_before));
        let claim = engine
            .mint("Record date: 2026-08-26\n\nMemory record:\nAlice planted 12 tomato saplings and mulched them with straw.\n\nAdornment:")
            .expect("mint must produce a claim");
        assert!(!claim.is_empty());
        eprintln!("gold miner gate: rss after mint1 = {} KiB; claim = {claim:?}", resident_kb());
        if std::env::var("MOOT_GOLDMINER_PAUSE").is_ok() {
            eprintln!("gold miner gate: pausing 30s for vmmap (pid {})", std::process::id());
            std::thread::sleep(std::time::Duration::from_secs(30));
        }
        let claim2 = engine.mint("Memory record:\nBob repaired the greenhouse irrigation pump.\n\nAdornment:");
        assert!(claim2.is_some(), "second mint on the same residency must work");
        let rss_after = resident_kb();
        // ENFORCED BUDGET (Bob constraint: no gigabytes): engine residency
        // must stay under 1 GiB above the test baseline.
        let delta_kb = rss_after.saturating_sub(rss_before);
        assert!(
            delta_kb < 1_048_576,
            "gold miner residency {delta_kb} KiB exceeds the 1 GiB budget"
        );
    }

    /// Current process resident set in KiB (macOS/Linux via ps).
    fn resident_kb() -> u64 {
        let pid = std::process::id().to_string();
        std::process::Command::new("ps")
            .args(["-o", "rss=", "-p", &pid])
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .and_then(|s| s.trim().parse::<u64>().ok())
            .unwrap_or(0)
    }
}
