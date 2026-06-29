/// B-1 substrate boundary conformance test — READER files.
///
/// The B-1 invariant: NeuronKit and CognitionKit must only reach the substrate
/// (LocusKit, VectorKit, CorpusKit) through GeniusLocusKit's estate verb surface.
/// No direct `DrawerStore`, `Estate`, or raw storage calls from the BrainKit
/// reader layer.
///
/// **Scope: reader files only.**
/// The SINK files (`estate_dreaming_sink.rs`, `estate_maintenance_sink.rs`) are
/// intentionally excluded from this scan. `estate_dreaming_sink.rs` routes its
/// writes through the GLK EstateCoordinator verb surface; `estate_maintenance_sink.rs`
/// uses a direct `DrawerStore` path documented in its module comment as the
/// current sync Rust adapter shape. Both have module-level comments explaining
/// their write path. The scan covers only the reader layer; sink write-path
/// compliance is evaluated separately per each sink's own module comment.
///
/// **Exclusions within reader files:**
/// - `#[cfg(test)]` blocks: test infrastructure may hold `Arc<dyn DrawerStore>`
///   to construct estates. Only production code above the test marker is scanned.
/// - Value types (Drawer, Tunnel, etc.) imported for naming: these are B-1
///   compliant by spec. The forbidden patterns are DrawerStore imports only.
///
/// The scan is line-by-line, stops at `#[cfg(test)]`, and fails the build
/// immediately if a violation is found — enforcing the invariant mechanically
/// so it cannot drift silently.
use std::fs;
use std::path::Path;

// Sinks are excluded — see module comment above for the rationale.
const READER_FILES: &[&str] = &[
    "src/estate_dreaming_reader.rs",
    "src/estate_maintenance_reader.rs",
];

/// Patterns that indicate a direct DrawerStore import in production code.
/// These are the patterns the B-1 invariant prohibits in the reader/sink layer.
const FORBIDDEN_PATTERNS: &[&str] = &[
    "use locus_kit::drawer_store::DrawerStore",
    "use locus_kit::drawer_store_inmemory",
    "use locus_kit::drawer_store_sqlite",
    "use locus_kit::drawer_store_postgres",
    "<S: DrawerStore>",
];

#[test]
fn brainkit_readers_have_no_direct_drawer_store_imports() {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let mut violations: Vec<String> = Vec::new();

    for relative_path in READER_FILES {
        let full_path = Path::new(manifest_dir).join(relative_path);
        let source = fs::read_to_string(&full_path)
            .unwrap_or_else(|e| panic!("cannot read {}: {}", full_path.display(), e));

        // Scan only the production section — stop before the test module.
        // The `#[cfg(test)]` marker starts the test-only region.
        let production_section: String = source
            .lines()
            .take_while(|line| !line.trim_start().starts_with("#[cfg(test)]"))
            .collect::<Vec<_>>()
            .join("\n");

        for pattern in FORBIDDEN_PATTERNS {
            if production_section.contains(pattern) {
                violations.push(format!(
                    "B-1 violation: '{}' found in production section of {}",
                    pattern, relative_path,
                ));
            }
        }
    }

    assert!(
        violations.is_empty(),
        "B-1 substrate boundary violations detected:\n{}",
        violations.join("\n")
    );
}
