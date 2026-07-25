// StandalonePassageDarkTests.swift
//
// Negative composition gate: the CorpusKit dependency selected by GLK does
// not enable the StandalonePassages trait. The index-unit enum therefore has
// only `.wholeContent`, and neither policy authority nor passage ranges can
// enter the estate schema.

import CorpusKit
import Testing

@Suite("Standalone passage machinery is dark in GLK")
struct StandalonePassageDarkTests {
    @Test func dependencyBuildContainsOnlyWholeContentPolicy() {
        // A Swift enum with one payload-free case has no runtime payload.
        // Enabling StandalonePassages adds the two-Int token-window case and
        // makes this non-zero, so this is a compile-selection gate rather than
        // merely an attached-mode runtime assertion.
        #expect(MemoryLayout<CorpusIndexUnitPolicy>.size == 0)
        #expect(MemoryLayout<CorpusIndexUnitPolicy>.stride == 1)
    }

    @Test func attachedSchemaContainsNoStandalonePassageAuthority() {
        let declaration = CorpusSchemaProfile.attachedDeclaration
        let tables = Set(declaration.tables.map(\.name))
        #expect(!tables.contains("corpus_index_configuration"))
        #expect(!tables.contains("corpus_passages"))
        #expect(!tables.contains("corpus_documents"))
        #expect(!tables.contains("chunks"))
        for table in declaration.tables {
            #expect(!table.columns.contains { column in
                column.name == "window_tokens"
                    || column.name == "overlap_tokens"
                    || column.name == "policy_fingerprint"
            })
        }
    }
}
