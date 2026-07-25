//! Negative composition gate: GLK's corpus-kit dependency does not enable
//! `standalone-passages`. Only the zero-sized WholeContent policy and attached
//! derived schema are present.

use corpus_kit::{attached_declaration, CorpusIndexUnitPolicy};
use std::collections::BTreeSet;

#[test]
fn dependency_build_contains_only_whole_content_policy() {
    assert_eq!(std::mem::size_of::<CorpusIndexUnitPolicy>(), 0);
}

#[test]
fn attached_schema_contains_no_standalone_passage_authority() {
    let declaration = attached_declaration();
    let tables: BTreeSet<&str> = declaration.tables.iter().map(|t| t.name.as_str()).collect();
    for absent in [
        "corpus_index_configuration",
        "corpus_passages",
        "corpus_documents",
        "chunks",
    ] {
        assert!(!tables.contains(absent), "attached schema leaked {absent}");
    }
    for table in declaration.tables {
        for column in table.columns {
            assert!(!matches!(
                column.name.as_str(),
                "window_tokens" | "overlap_tokens" | "policy_fingerprint"
            ));
        }
    }
}
