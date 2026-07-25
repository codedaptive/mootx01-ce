// SchemaLayoutSignatureTests.swift
//
// Canonical layout-signature coverage (GLK shared-content 1.1, P0).
//
// The signature is the structural identity migration detection keys on —
// it must be deterministic, independent of kitID/version labels, and
// byte-identical to the Rust twin's rendering of an equivalent
// declaration. The frozen `expectedSampleSignature` below is duplicated
// verbatim in `layout_signature.rs::tests::signature_matches_cross_port_fixture`;
// a change that breaks either port's copy is a cross-port layout break.

import Testing
import Foundation
import PersistenceKit

struct SchemaLayoutSignatureTests {

    private func sampleSchema(kitID: String = "SampleKit", version: Int = 3) -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: kitID,
            version: version,
            tables: [
                TableDeclaration(
                    name: "zeta",
                    columns: [.uuid("id"), .text("name", nullable: true)],
                    primaryKey: ["id"]
                ),
                TableDeclaration(
                    name: "alpha",
                    columns: [.uuid("id"), .int("rank")],
                    primaryKey: ["id"],
                    uniqueConstraints: [["rank"]]
                )
            ],
            indices: [
                IndexDeclaration(name: "idx_alpha_rank", table: "alpha", columns: ["rank"])
            ]
        )
    }

    /// Frozen cross-port fixture — must match the Rust twin byte for byte.
    private let expectedSampleSignature = """
        table=alpha
          col=id type=uuid null=0 default=- role=-
          col=rank type=int null=0 default=- role=-
          pk=id
          unique=rank
          appendOnly=0 hashable=0
        table=zeta
          col=id type=uuid null=0 default=- role=-
          col=name type=text null=1 default=- role=-
          pk=id
          appendOnly=0 hashable=0
        index=idx_alpha_rank table=alpha cols=rank unique=0

        """

    @Test func signatureMatchesCrossPortFixture() {
        #expect(sampleSchema().layoutSignatureText() == expectedSampleSignature)
    }

    @Test func signatureExcludesKitIDAndVersion() {
        let a = sampleSchema().layoutSignatureText()
        let b = sampleSchema(kitID: "OtherKit", version: 99).layoutSignatureText()
        #expect(a == b)
    }

    @Test func signatureSortsTablesAndKeepsColumnOrder() {
        let text = sampleSchema().layoutSignatureText()
        let alphaRange = text.range(of: "table=alpha")
        let zetaRange = text.range(of: "table=zeta")
        #expect(alphaRange != nil && zetaRange != nil)
        if let alphaRange, let zetaRange {
            #expect(alphaRange.lowerBound < zetaRange.lowerBound)
        }
        // Column order stays declaration order (id before rank, id before name).
        #expect(text.contains("  col=id type=uuid null=0 default=- role=-\n  col=rank type=int"))
    }

    @Test func digestIsStableAndChangesWithLayout() {
        let base = sampleSchema().layoutSignatureDigest()
        #expect(base == sampleSchema().layoutSignatureDigest())

        var mutatedTables = sampleSchema().tables
        mutatedTables[0] = TableDeclaration(
            name: "zeta",
            columns: [.uuid("id"), .text("name", nullable: false)],
            primaryKey: ["id"]
        )
        let mutated = SchemaDeclaration(
            kitID: "SampleKit", version: 3, tables: mutatedTables,
            indices: sampleSchema().indices)
        #expect(mutated.layoutSignatureDigest() != base)
    }

    @Test func rolesAndFlagsAppearInSignature() {
        let table = TableDeclaration(
            name: "events",
            columns: [.uuid("id"), .createdHlc("created"), .tombstonedHlc("tombstoned")],
            primaryKey: ["id"],
            appendOnly: true,
            hashable: true
        )
        let text = table.layoutSignatureText()
        #expect(text.contains("col=created type=hlc null=0 default=- role=createdHlc"))
        #expect(text.contains("col=tombstoned type=hlc null=1 default=- role=tombstonedHlc"))
        #expect(text.contains("appendOnly=1 hashable=1"))
    }
}
