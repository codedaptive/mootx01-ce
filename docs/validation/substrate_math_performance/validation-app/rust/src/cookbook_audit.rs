// SubstrateValidator (Rust) — subsystem 5: source <-> cookbook structural audit.
//
// ──────────────────────────────────────────────────────────────────────────
// WHAT THIS IS — AND WHAT IT IS NOT
//
// This is a STRUCTURAL / HEURISTIC correspondence check, NOT a semantic-
// equivalence proof. It reads the approved engineering cookbook's per-
// primitive pseudocode, derives a small set of "signature tokens" from that
// pseudocode (magic hex constants + a handful of operation keywords), then
// checks that the SHIPPING Rust library source for the same primitive
// mentions those same tokens. It reports MATCH / DRIFT per primitive.
//
// A MATCH means: "the shipping source references the same algorithm
// signatures the cookbook prescribes" — same constants, same named ops.
// It does NOT mean the two compute the same function. Two implementations
// can share every token and still disagree on a sign, an index bound, or a
// loop direction. Conversely a DRIFT is not proof of a bug: the cookbook
// pseudocode and the shipping code may legitimately re-express the same math
// (e.g. the cookbook writes matrix decay as `pow(0.5, t/h)` while the
// shipping code writes the algebraically identical `exp(-t*ln(2)/h)`). The
// token model accepts such re-expressions where it knows about them, but it
// cannot know about all of them.
//
// The authoritative cross-language / cross-platform equivalence guarantee is
// the CRC conformance gate (subsystems 1 & 2 in main.rs), which runs the real
// implementations against committed vectors. THIS subsystem is a cheap
// drift smoke-test on top of that gate: it catches a primitive whose source
// no longer even mentions the constants its math contract requires.
//
// Contract: `pub fn run() -> usize` prints a per-primitive table and returns
// the DRIFT count (0 == every mapped primitive matched). std-only.
// ──────────────────────────────────────────────────────────────────────────

use std::fs;
use std::path::{Path, PathBuf};

// Document locations, resolved relative to this crate. The crate lives at
// docs/validation/substrate_math_performance/validation-app/rust, so the repo
// root is five directories up (rust -> validation-app -> substrate_math_
// performance -> validation -> docs -> <root>). main.rs's drift_check() uses
// the same five-up hop for packages/libs, so we mirror it here.
const COOKBOOK_REL: &str =
    "../../../../../docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md";
const HARNESS_REF_REL: &str =
    "../../../../../docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md";
const LIBS_REL: &str = "../../../../../packages/libs";

// ── token model ─────────────────────────────────────────────────────────────

/// A signature token expected to appear in BOTH the cookbook pseudocode and
/// the shipping source. `spellings` holds equivalent surface forms; the token
/// is "present" in a body if ANY spelling appears. This is how we tolerate
/// the cookbook/source re-expressions noted in the header (`pow` vs `exp`,
/// `popcount` vs `count_ones`, etc.) without lying about correspondence.
struct Token {
    /// Display label for the report's "missing" column.
    label: String,
    /// Equivalent surface forms; presence of any one satisfies the token.
    spellings: Vec<String>,
    /// Hex constants are matched case-insensitively (Rust spells them
    /// `0xCBF2...` or `0xcbf2...`; the cookbook may differ). Keyword ops are
    /// matched case-insensitively too, which is harmless for ASCII keywords.
    is_hex: bool,
}

impl Token {
    fn keyword(label: &str, spellings: &[&str]) -> Token {
        Token {
            label: label.to_string(),
            spellings: spellings.iter().map(|s| s.to_lowercase()).collect(),
            is_hex: false,
        }
    }
    fn hex(h: &str) -> Token {
        // Normalize to lowercase once; comparison lowercases the haystack.
        Token {
            label: h.to_string(),
            spellings: vec![h.to_lowercase()],
            is_hex: true,
        }
    }

    /// True if any spelling appears in `lower_haystack` (already lowercased).
    fn present_in(&self, lower_haystack: &str) -> bool {
        self.spellings.iter().any(|s| lower_haystack.contains(s))
    }
}

/// One primitive's audit spec: which cookbook § to read its pseudocode from,
/// which shipping Rust module to check, and the operation keywords that
/// matter for it. Hex constants are NOT hand-listed here — they are scraped
/// automatically from the primitive's cookbook § (see `scrape_hex`).
struct PrimSpec {
    /// Cookbook §, e.g. "3.6". Drives both the section title shown in the
    /// table and the pseudocode-block extraction.
    section: &'static str,
    /// Operation keywords whose presence we require in the shipping source.
    /// Each is a set of equivalent spellings (see Token).
    ops: Vec<Token>,
}

/// The primitive -> (§, shipping Rust module) map comes from the
/// HARNESS_REFERENCE §2.0 table (parsed at runtime). The §-per-primitive and
/// the op keywords below come from reading the cookbook pseudocode for each.
/// Only primitives whose op-set we have hand-derived appear here; the rest
/// are reported SKIP (mapped-but-unaudited) so the table stays honest about
/// coverage.
fn op_specs() -> Vec<(&'static str, PrimSpec)> {
    // Spelling sets reused across primitives.
    let popcount = || Token::keyword("popcount", &["popcount", "count_ones"]);
    let xor = || Token::keyword("XOR", &["xor", "^"]);
    let or_op = || Token::keyword("OR", &["|=", " | ", " or ", "bitor"]);
    let and_op = || Token::keyword("AND", &["&", " and "]);

    vec![
        // §3.6 SimHash: per-bit dot via popcount of AND with ±masks, OR-in a
        // left-shifted bit. Shipping simhash.rs uses count_ones + shifts.
        (
            "simhash",
            PrimSpec {
                section: "3.6",
                ops: vec![
                    popcount(),
                    and_op(),
                    Token::keyword("shift", &["<<", "shl", "shifted_left"]),
                ],
            },
        ),
        // §8.2 Hamming: popcount of XOR over blocks.
        (
            "hamming",
            PrimSpec {
                section: "8.2",
                ops: vec![popcount(), xor()],
            },
        ),
        // §8.5 OR-reduce: bitwise OR accumulate.
        (
            "or_reduce",
            PrimSpec {
                section: "8.5",
                ops: vec![or_op()],
            },
        ),
        // §8.6 bitwise combinators: intersect=AND, difference=XOR, prototype
        // = majority vote (threshold). Require AND, XOR, and a popcount-or-
        // count to back the majority/threshold.
        (
            "bitwise",
            PrimSpec {
                section: "8.6",
                ops: vec![and_op(), xor(), Token::keyword("threshold", &["threshold", "> "])],
            },
        ),
        // §3.6 fingerprint: composes four simhash_block calls.
        (
            "fingerprint",
            PrimSpec {
                section: "3.6",
                ops: vec![popcount(), Token::keyword("block", &["block0", "block"])],
            },
        ),
        // §5.2 HLC: lexicographic compare on (physical, logical, node).
        (
            "hlc",
            PrimSpec {
                section: "5.2",
                ops: vec![
                    Token::keyword("physical_time", &["physical_time", "physical"]),
                    Token::keyword("logical_count", &["logical_count", "logical"]),
                    Token::keyword("node_id", &["node_id", "node"]),
                ],
            },
        ),
        // §3.3 FNV-1a: XOR-then-multiply. The 64/32-bit offset-basis and prime
        // hex constants live in the SHIPPING source, not the cookbook prose,
        // so we list them as required spellings here (they are still scraped
        // from §3.3 where present and unioned in — see build_tokens).
        (
            "fnv",
            PrimSpec {
                section: "3.3",
                ops: vec![
                    xor(),
                    Token::keyword("multiply", &["wrapping_mul", "* prime", "*="]),
                    Token::hex("0xCBF29CE484222325"), // 64-bit offset basis
                    Token::hex("0x100000001B3"),      // 64-bit FNV prime
                    Token::hex("0x811C9DC5"),         // 32-bit offset basis
                    Token::hex("0x01000193"),         // 32-bit FNV prime
                ],
            },
        ),
        // §2.8 masked equals: (bitmap & mask) == expected.
        (
            "bit_field_masked_equals",
            PrimSpec {
                section: "2.8",
                ops: vec![and_op(), Token::keyword("equals", &["==", "masked_equals"])],
            },
        ),
        // §8.3 lattice (udc_tree_distance): longest-common-prefix delta
        // normalized to [0,1].
        (
            "lattice",
            PrimSpec {
                section: "8.3",
                ops: vec![Token::keyword(
                    "prefix",
                    &["prefix", "common", "udc_tree_distance"],
                )],
            },
        ),
        // §8.11 info theory: entropy/MI/KL all use log (base-2).
        (
            "info_theory",
            PrimSpec {
                section: "8.11",
                ops: vec![Token::keyword("log", &["log2", "log(", ".log", "ln("])],
            },
        ),
        // §8.12 Bradley-Terry: logistic gradient step with learning rate.
        (
            "bradley_terry",
            PrimSpec {
                section: "8.12",
                ops: vec![
                    Token::keyword("exp/logistic", &["exp", "logistic", "sigmoid"]),
                    Token::keyword("eta/lr", &["eta", "learning", "lr"]),
                ],
            },
        ),
        // §8.8 partial state recall: rewards matching some blocks, differing
        // on others — Hamming over blocks.
        (
            "partial_state_recall",
            PrimSpec {
                section: "8.8",
                ops: vec![Token::keyword("hamming/block", &["hamming", "block", "popcount", "count_ones"])],
            },
        ),
        // §8.14 temporal compression: cascading OR-reduce over buckets.
        (
            "temporal_compression",
            PrimSpec {
                section: "8.14",
                ops: vec![or_op()],
            },
        ),
        // §8.13 anomaly z-score: (distance - mean) / stddev; stddev via sqrt.
        (
            "anomaly",
            PrimSpec {
                section: "8.13",
                ops: vec![
                    Token::keyword("mean", &["mean", "mu"]),
                    Token::keyword("stddev/sqrt", &["stddev", "sqrt", "sigma"]),
                ],
            },
        ),
        // §6.8 matrix decay: cookbook writes pow(0.5, t/h); shipping writes
        // the equivalent exp(-t*ln(2)/h). Accept either spelling.
        (
            "matrix_decay",
            PrimSpec {
                section: "6.8",
                ops: vec![
                    Token::keyword("decay-exp", &["pow", "exp", "ln_2", "ln(2)", "powf"]),
                    Token::keyword("half_life", &["half_life", "half-life"]),
                ],
            },
        ),
        // §8.7 moment summary: OR-reduce over rows matching active_during.
        (
            "moment_summary",
            PrimSpec {
                section: "8.7",
                ops: vec![or_op()],
            },
        ),
        // §6.1 field-presence matrix F: per-(field,bit) population counts;
        // capture increments, expunge decrements.
        (
            "field_presence_matrix_f",
            PrimSpec {
                section: "6.1",
                ops: vec![Token::keyword(
                    "increment/decrement",
                    &["+= 1", "-= 1", "increment", "decrement", "+=", "-="],
                )],
            },
        ),
        // §12.3 tier contribution: re-fingerprint under shared seeds, OR-reduce.
        (
            "tier_contribution",
            PrimSpec {
                section: "12.3",
                ops: vec![or_op(), Token::keyword("seed/scope", &["seed", "scope"])],
            },
        ),
        // §12.2 pairing handshake: deterministic shared hyperplane family per
        // scope.
        (
            "pairing_handshake",
            PrimSpec {
                section: "12.2",
                ops: vec![Token::keyword("hyperplane/scope", &["hyperplane", "scope", "family"])],
            },
        ),
        // §8.10 FFT: butterfly with trig (cos/sin) over power-of-two windows.
        (
            "fft",
            PrimSpec {
                section: "8.10",
                ops: vec![Token::keyword("trig", &["cos", "sin", "twiddle"])],
            },
        ),
        // §8.2 hamming_nn: top-K by Hamming via popcount(XOR).
        (
            "hamming_nn",
            PrimSpec {
                section: "8.2",
                ops: vec![popcount(), xor()],
            },
        ),
        // §6.9 NMF: multiplicative-update alternating least squares.
        (
            "nmf",
            PrimSpec {
                section: "6.9",
                ops: vec![Token::keyword("update", &["update", "multiplic", "factor"])],
            },
        ),
        // §7.2 eigenvalue centrality: power iteration, L2 normalize (sqrt),
        // Perron shift.
        (
            "eigenvalue_centrality",
            PrimSpec {
                section: "7.2",
                ops: vec![
                    Token::keyword("normalize/sqrt", &["sqrt", "norm"]),
                    Token::keyword("shift", &["shift"]),
                ],
            },
        ),
        // §5.3 audit log fold: replay events in HLC order to project state.
        (
            "audit_log_fold",
            PrimSpec {
                section: "5.3",
                ops: vec![Token::keyword("hlc-order", &["hlc", "sort", "order"])],
            },
        ),
    ]
}

// ── document parsing ─────────────────────────────────────────────────────────

/// Parse the HARNESS_REFERENCE §2.0 table rows of the form
/// `| `name` | Package | `Swift.swift` | `module.rs` |` into
/// (primitive, package, rust_module). Backtick fences around cells are
/// stripped. Rows without a `.rs` module cell are ignored.
fn parse_primitive_map(harness_md: &str) -> Vec<(String, String, String)> {
    let mut out = Vec::new();
    for line in harness_md.lines() {
        let t = line.trim();
        // A data row has at least four pipe-delimited cells and no header
        // dashes. The §2.0 table header is "| Primitive | Package | Swift
        // file | Rust module |"; skip that and the `---` separator.
        if !t.starts_with('|') {
            continue;
        }
        let cells: Vec<&str> = t.trim_matches('|').split('|').map(|c| c.trim()).collect();
        if cells.len() < 4 {
            continue;
        }
        let prim = strip_backticks(cells[0]);
        let pkg = cells[1].to_string();
        let rust_mod = strip_backticks(cells[3]);
        // Header / separator guards.
        if prim.eq_ignore_ascii_case("primitive") || prim.starts_with("---") {
            continue;
        }
        if !rust_mod.ends_with(".rs") {
            continue;
        }
        // Package cell must look like a substrate package name (no spaces).
        if pkg.is_empty() || pkg.contains(' ') {
            continue;
        }
        out.push((prim, pkg, rust_mod));
    }
    out
}

/// Remove surrounding backticks and any stray whitespace from a table cell.
fn strip_backticks(s: &str) -> String {
    s.trim().trim_matches('`').trim().to_string()
}

/// Extract the fenced pseudocode block(s) immediately under a cookbook
/// section heading `### §<section>.`. The cookbook uses ``` fences with no
/// language tag. We find the heading, then collect every fenced block until
/// the next `###`/`##` heading at or above the same level. Returns the
/// concatenated block contents (without the fence lines). Empty string if the
/// section is not found or carries no fenced block.
fn extract_section_pseudocode(cookbook: &str, section: &str) -> String {
    let lines: Vec<&str> = cookbook.lines().collect();
    // Match either "### §3.6." or "## §5.2." — heading text after the number
    // varies, so anchor on the "§<section>" token followed by a dot or space.
    let needle_dot = format!("§{section}.");
    let needle_sp = format!("§{section} ");
    let mut i = 0;
    let start = loop {
        if i >= lines.len() {
            return String::new();
        }
        let l = lines[i].trim_start();
        let is_heading = l.starts_with("## ") || l.starts_with("### ") || l.starts_with("#### ");
        if is_heading && (l.contains(&needle_dot) || l.contains(&needle_sp)) {
            break i + 1;
        }
        i += 1;
    };

    let mut collected = String::new();
    let mut in_fence = false;
    let mut j = start;
    while j < lines.len() {
        let raw = lines[j];
        let l = raw.trim_start();
        // Stop at the next section heading (only when not inside a fence).
        if !in_fence
            && (l.starts_with("## ") || l.starts_with("### ") || l.starts_with("#### "))
        {
            break;
        }
        if l.starts_with("```") {
            in_fence = !in_fence;
            j += 1;
            continue;
        }
        if in_fence {
            collected.push_str(raw);
            collected.push('\n');
        }
        j += 1;
    }
    collected
}

/// Scrape magic hex constants from a pseudocode block: `0x` followed by >= 3
/// hex digits. Returned lowercased and de-duplicated, preserving first-seen
/// order. CRC-style constants longer than 8 hex digits ARE captured — they
/// are rare in pseudocode bodies (the cookbook keeps CRCs in its §18 catalog,
/// not in algorithm pseudocode), so false positives are unlikely.
fn scrape_hex(block: &str) -> Vec<String> {
    let lower = block.to_lowercase();
    let bytes = lower.as_bytes();
    let mut found: Vec<String> = Vec::new();
    let mut k = 0usize;
    while k + 1 < bytes.len() {
        if bytes[k] == b'0' && bytes[k + 1] == b'x' {
            let mut m = k + 2;
            while m < bytes.len() && bytes[m].is_ascii_hexdigit() {
                m += 1;
            }
            let ndigits = m - (k + 2);
            if ndigits >= 3 {
                let lit = lower[k..m].to_string();
                if !found.contains(&lit) {
                    found.push(lit);
                }
            }
            k = m.max(k + 2);
        } else {
            k += 1;
        }
    }
    found
}

/// Build the final token set for a primitive: the hand-derived op keywords,
/// UNIONed with any hex constants scraped from its cookbook pseudocode. Hex
/// constants already named in the op spec (e.g. FNV's, which live in source
/// not prose) are not duplicated.
fn build_tokens(spec: &PrimSpec, pseudocode: &str) -> Vec<Token> {
    let mut tokens: Vec<Token> = Vec::new();
    let mut seen_hex: Vec<String> = Vec::new();

    for op in &spec.ops {
        if op.is_hex {
            seen_hex.push(op.spellings[0].clone());
        }
    }
    // Move the hand-listed ops in.
    for (label, spellings, is_hex) in spec
        .ops
        .iter()
        .map(|t| (t.label.clone(), t.spellings.clone(), t.is_hex))
        .collect::<Vec<_>>()
    {
        tokens.push(Token { label, spellings, is_hex });
    }
    // Union in scraped hexes not already present.
    for h in scrape_hex(pseudocode) {
        if !seen_hex.contains(&h) {
            seen_hex.push(h.clone());
            tokens.push(Token::hex(&h));
        }
    }
    tokens
}

// ── audit ────────────────────────────────────────────────────────────────────

#[derive(PartialEq)]
enum Status {
    Match,
    Drift,
    Skip,
}

struct Row {
    primitive: String,
    section: String,
    status: Status,
    missing: Vec<String>, // token labels absent from the shipping source
    note: String,         // reason for SKIP, or empty
}

fn manifest_path(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(rel)
}

/// Run the structural audit. Prints the table, returns the DRIFT count.
pub fn run() -> usize {
    let cookbook = match fs::read_to_string(manifest_path(COOKBOOK_REL)) {
        Ok(s) => s,
        Err(e) => {
            println!("cookbook_audit: cannot read cookbook ({e}); skipping subsystem 5.");
            return 0;
        }
    };
    let harness = match fs::read_to_string(manifest_path(HARNESS_REF_REL)) {
        Ok(s) => s,
        Err(e) => {
            println!("cookbook_audit: cannot read harness reference ({e}); skipping subsystem 5.");
            return 0;
        }
    };

    let prim_map = parse_primitive_map(&harness); // (primitive, package, module)
    let specs = op_specs();
    let libs_root = manifest_path(LIBS_REL);

    let mut rows: Vec<Row> = Vec::new();

    for (primitive, package, rust_mod) in &prim_map {
        // Find the op spec for this primitive. Unmapped -> SKIP.
        let Some((_, spec)) = specs.iter().find(|(n, _)| n == primitive) else {
            rows.push(Row {
                primitive: primitive.clone(),
                section: "-".into(),
                status: Status::Skip,
                missing: Vec::new(),
                note: "no op-spec".into(),
            });
            continue;
        };

        // Shipping source path: packages/libs/<Package>/rust/src/<module>.rs.
        let src_path = libs_root.join(package).join("rust/src").join(rust_mod);
        let src = match fs::read_to_string(&src_path) {
            Ok(s) => s,
            Err(_) => {
                rows.push(Row {
                    primitive: primitive.clone(),
                    section: format!("§{}", spec.section),
                    status: Status::Skip,
                    missing: Vec::new(),
                    note: format!("source not found: {}/{}", package, rust_mod),
                });
                continue;
            }
        };

        // Extract the cookbook pseudocode for this primitive's section.
        let pseudocode = extract_section_pseudocode(&cookbook, spec.section);
        if pseudocode.trim().is_empty() {
            rows.push(Row {
                primitive: primitive.clone(),
                section: format!("§{}", spec.section),
                status: Status::Skip,
                missing: Vec::new(),
                note: format!("no fenced pseudocode in §{}", spec.section),
            });
            continue;
        }

        // Build tokens (ops + scraped hexes) and test them against the source.
        // Comparison is case-insensitive for everything: hex constants because
        // Rust may spell them lowercase (0xbf58...) while the cookbook differs,
        // and keyword ops because case carries no semantic weight here.
        let tokens = build_tokens(spec, &pseudocode);
        let src_lower = src.to_lowercase();
        let mut missing: Vec<String> = Vec::new();
        for tok in &tokens {
            if !tok.present_in(&src_lower) {
                missing.push(tok.label.clone());
            }
        }

        rows.push(Row {
            primitive: primitive.clone(),
            section: format!("§{}", spec.section),
            status: if missing.is_empty() {
                Status::Match
            } else {
                Status::Drift
            },
            missing,
            note: String::new(),
        });
    }

    print_table(&rows, &prim_map, &libs_root);

    rows.iter().filter(|r| r.status == Status::Drift).count()
}

fn print_table(rows: &[Row], prim_map: &[(String, String, String)], libs_root: &Path) {
    println!("cookbook_audit — subsystem 5: source <-> cookbook structural audit");
    println!("  HEURISTIC structural correspondence (token/constant coverage).");
    println!("  This is NOT a semantic-equivalence proof — see the CRC conformance");
    println!("  gate (subsystems 1 & 2) for the authoritative bit-identity guarantee.");
    println!(
        "  map source: HARNESS_REFERENCE §2.0 ({} primitives mapped)",
        prim_map.len()
    );
    match libs_root.canonicalize() {
        Ok(p) => println!("  shipping source root: {}", p.display()),
        Err(_) => println!("  shipping source root: {} (not found)", libs_root.display()),
    }
    println!();

    println!("  {:<26} {:<8} {:<7} {}", "primitive", "§", "status", "missing");
    println!("  {:-<26} {:-<8} {:-<7} {:-<30}", "", "", "", "");

    let (mut matched, mut drift, mut skipped) = (0usize, 0usize, 0usize);
    for r in rows {
        let (status_str, detail) = match r.status {
            Status::Match => {
                matched += 1;
                ("MATCH", String::new())
            }
            Status::Drift => {
                drift += 1;
                ("DRIFT", r.missing.join(", "))
            }
            Status::Skip => {
                skipped += 1;
                ("SKIP", r.note.clone())
            }
        };
        println!(
            "  {:<26} {:<8} {:<7} {}",
            r.primitive, r.section, status_str, detail
        );
    }

    println!();
    println!("  {matched} matched, {drift} drift, {skipped} skipped");
}
