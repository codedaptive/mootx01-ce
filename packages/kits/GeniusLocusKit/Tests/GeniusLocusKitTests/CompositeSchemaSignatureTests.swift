// CompositeSchemaSignatureTests.swift
//
// Composite-schema layout-signature parity gate
// (GLK shared-content 1.1, P0).
//
// The composite estate schema must be DERIVED from the live component
// declarations — never asserted by a copied version comment. These tests
// pin that derivation structurally:
//
//   1. the composite version equals the sum of the live component
//      versions plus the two GLK-owned addends;
//   2. the composite's canonical layout signature matches the frozen
//      cross-port fixture (`Tests/Fixtures/composite_schema_signature.txt`),
//      which the Rust twin (`composite_schema_signature_tests.rs`) asserts
//      byte-identically — so the two ports cannot silently diverge in any
//      table, column, key, or index of the pre-cutover layout.
//
// When a deliberate schema change lands (e.g. the shared-content attached
// cutover), regenerate the fixture in BOTH ports' test runs and commit the
// new file with the schema change — the diff of the fixture IS the layout
// review artifact.

import Testing
import Foundation
import LocusKit
import VectorKit
import CorpusKit
import PersistenceKit
@testable import GeniusLocusKit

struct CompositeSchemaSignatureTests {

    private var fixtureURL: URL {
        // …/Tests/GeniusLocusKitTests/CompositeSchemaSignatureTests.swift
        //   → …/Tests/Fixtures/composite_schema_signature.txt
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/composite_schema_signature.txt")
    }

    @Test func compositeVersionIsSumOfLiveComponentVersions() {
        let expected = LocusKitSchema.version
            + VectorStore.schemaDeclaration.version
            + VectorRepresentationClaims.schemaDeclaration.version
            + CorpusSchemaProfile.attachedDeclaration.version
            + EstateFormatStore.schemaDeclaration.version
            + 1  // grants
            + MatrixSnapshotStore.schemaDeclaration.version
        #expect(GeniusLocusKitSchema.version == expected)
        #expect(GeniusLocusKitSchema.estateSchemaDeclaration.version == expected)
    }

    @Test func compositeTableNamesAreUnique() {
        let names = GeniusLocusKitSchema.estateSchemaDeclaration.tables.map(\.name)
        #expect(Set(names).count == names.count, "duplicate table in composite schema")
    }

    @Test func compositeSignatureMatchesFrozenCrossPortFixture() throws {
        let actual = GeniusLocusKitSchema.estateSchemaDeclaration.layoutSignatureText()
        // Maintainer regen: MOOT_REGEN_COMPOSITE_FIXTURE=1 rewrites the
        // fixture from THIS port; run the Rust twin the same way and verify
        // the two runs produce a byte-identical file before committing.
        if ProcessInfo.processInfo.environment["MOOT_REGEN_COMPOSITE_FIXTURE"] == "1" {
            try actual.write(to: fixtureURL, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        #expect(actual == expected,
                "composite layout signature diverged from the frozen fixture — if this change is deliberate, regenerate the fixture in both ports")
    }
}
