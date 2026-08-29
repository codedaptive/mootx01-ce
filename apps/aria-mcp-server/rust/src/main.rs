//! `aria-mcp` binary entry point.
//!
//! The full runtime — backend selection (`ARIA_MCP_POSTGRES_URL` /
//! `ARIA_MCP_SQLITE_PATH`), telemetry wiring (`ARIA_MCP_STATS_STORE`), and
//! transport select (stdio default; resident HTTP + Autonomic Governor when
//! `MOOTX01_HTTP_PORT` is set) — lives in `aria_mcp::runtime::run` so this
//! dev binary and the product `mootx01 serve` (apps/mootx01/rust) execute the
//! identical logic from one source of truth. See runtime.rs for the full
//! environment-variable contract and ARIA_MCP_SPEC §17.1 on governor
//! ownership.
//!
//! # Running
//!
//! ```sh
//! cargo run --manifest-path apps/aria-mcp-server/rust/Cargo.toml
//! ```

fn main() {
    // Resident gold-miner engine (DEFAULT-MINT-01): the product binary
    // installs the candle quantized engine from its data dir before
    // `runtime::run`; this dev binary mirrors that from MOOTX01_DATA_DIR so
    // the two Rust entry points do not silently diverge on minting. Absent
    // dir or model → loud skip; the adornment pass then uses the
    // deterministic mechanical fallback.
    match std::env::var("MOOTX01_DATA_DIR") {
        Ok(data) if !data.is_empty() => {
            let root = std::path::PathBuf::from(&data);
            let (gguf, tok) = adornment_lib::gold_miner::default_engine_paths(&root);
            if gguf.is_file() && tok.is_file() {
                match adornment_lib::gold_miner::QuantizedLlmEngine::load(&gguf, &tok) {
                    Ok(engine) => {
                        let id = adornment_lib::gold_miner::GoldMinerEngine::identity(&engine);
                        adornment_lib::gold_miner::install_engine(Box::new(engine));
                        eprintln!("aria-mcp: gold miner resident — {id}");
                    }
                    Err(e) => eprintln!("aria-mcp: gold miner unavailable — {e}"),
                }
            } else {
                eprintln!(
                    "aria-mcp: gold miner model not found at {} — adornment pass \
                     will use the mechanical fallback",
                    gguf.display()
                );
            }
        }
        _ => eprintln!(
            "aria-mcp: MOOTX01_DATA_DIR not set — no gold miner engine; adornment \
             pass will use the mechanical fallback"
        ),
    }
    // No plugin concept for this reference server — always "" (no skew to
    // report) and no release feed — None (no update advisory either).
    aria_mcp::runtime::run("mootx01", "", None);
}
