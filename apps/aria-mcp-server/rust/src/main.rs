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
    // No plugin concept for this reference server — always "" (no skew to
    // report) and no release feed — None (no update advisory either).
    aria_mcp::runtime::run("mootx01", "", None);
}
