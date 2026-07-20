// RowKeyDerivationConformanceTests.swift
//
// Gap 5 fix verification — the row-values→rowKey minting seam.
//
// Pre-fix, `FederationJSONConformanceTests.swift` (ConvergenceKit) already
// exercised the SyncRecord wire format extensively, but every vector there
// started from a pre-built `SyncRecord` with `rowKey` already given
// (`FederationJSONConformanceTests.swift:50-53,73`) — the seam that mints
// `rowKey` FROM raw row values (`RowKeyDerivation.deterministicRowKey` /
// Rust's `deterministic_row_key`, called from `InMemoryStorage.
// resolveOrAllocateKey` / `SQLiteBackend.extractRowKey` / the Postgres
// backends / their Rust twins) was never exercised by ANY conformance
// vector — exactly why the Swift/Rust divergence (Swift already had a
// `.text`→UUID-string-parse fallback; Rust's `inmemory.rs`/`sqlite.rs`/
// `postgres.rs` had none at all) survived CI undetected.
//
// These tests close that gap: they feed RAW STRING PK VALUES through
// `RowKeyDerivation.deterministicRowKey(from:)` and assert against a fixed
// vector set. The SAME vector set (same input strings, same expected
// output UUIDs) is asserted in Rust's `row_key_derivation.rs` conformance
// tests (`shared_vector_*` test names) — a genuine cross-language
// conformance gate, not self-consistency within one language.

import Testing
import Foundation
@testable import PersistenceKit

@Suite("RowKeyDerivation — gap 5 conformance (row-values→rowKey minting seam)")
struct RowKeyDerivationConformanceTests {

    // MARK: - UUID-shaped input: parses directly, unchanged from before gap 5

    @Test("a UUID-shaped string parses directly to that UUID")
    func uuidShapedStringParsesDirectly() {
        let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        #expect(RowKeyDerivation.deterministicRowKey(from: id.uuidString) == id)
    }

    @Test("a lowercase UUID-shaped string parses to the same UUID as uppercase")
    func lowercaseUUIDStringParsesSameAsUppercase() {
        let lower = "e621e1f8-c36c-495a-93fc-0c247a3e6e5f"
        let upper = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
        #expect(RowKeyDerivation.deterministicRowKey(from: lower) == RowKeyDerivation.deterministicRowKey(from: upper))
    }

    // MARK: - Non-UUID input: SHA-256 derivation, deterministic and stable

    @Test("the same non-UUID string always derives the same UUID")
    func sameNonUUIDStringDerivesSameUUID() {
        let a = RowKeyDerivation.deterministicRowKey(from: "widget-alpha")
        let b = RowKeyDerivation.deterministicRowKey(from: "widget-alpha")
        #expect(a == b)
    }

    @Test("different non-UUID strings derive different UUIDs")
    func differentNonUUIDStringsDeriveDifferentUUIDs() {
        let a = RowKeyDerivation.deterministicRowKey(from: "widget-alpha")
        let b = RowKeyDerivation.deterministicRowKey(from: "widget-beta")
        #expect(a != b)
    }

    /// SHARED VECTOR — this exact (input, expected output) pair is asserted
    /// identically in Rust's `row_key_derivation.rs::tests::
    /// shared_vector_widget_alpha_matches_swift`. If either implementation's
    /// derivation algorithm (SHA-256 primitive, version/variant bit
    /// placement) ever drifts from the other, this test and its Rust twin
    /// diverge — this IS the conformance gate for the minting seam.
    @Test("shared vector: 'widget-alpha' derives the fixed cross-language UUID")
    func sharedVectorWidgetAlpha() {
        let derived = RowKeyDerivation.deterministicRowKey(from: "widget-alpha")
        #expect(derived.uuidString == "5653F1D5-D5DE-5B4F-A820-E6BA150A14E2")
    }

    /// SHARED VECTOR — mirrors Rust's `shared_vector_supersedes_matches_swift`.
    /// Same string LocusKit's own tunnel-id pattern already uses
    /// (`DrawerStore.swift:373`, `id: "supersedes:\(d.id):\(priorID)"`),
    /// chosen so this vector exercises a realistic non-UUID id shape.
    @Test("shared vector: a colon-delimited slug string derives the fixed cross-language UUID")
    func sharedVectorSupersedesSlug() {
        let derived = RowKeyDerivation.deterministicRowKey(from: "supersedes:abc:def")
        #expect(derived.uuidString == "6EF50667-202D-5EAD-B435-0F49A7C45C0C")
    }

    // MARK: - Version/variant bits (UUIDv5-style, per the derivation algorithm)

    @Test("a derived (non-UUID-parse) UUID carries version nibble 5")
    func derivedUUIDHasVersionNibbleFive() {
        let derived = RowKeyDerivation.deterministicRowKey(from: "not-a-uuid-at-all")
        let bytes = withUnsafeBytes(of: derived.uuid) { Array($0) }
        #expect((bytes[6] & 0xF0) == 0x50, "version nibble (byte 6 high nibble) must be 5")
        #expect((bytes[8] & 0xC0) == 0x80, "variant bits (byte 8 high 2 bits) must be 10")
    }

    // MARK: - Full resolver-cell parity across backends (InMemory + SQLite)
    // See RowKeyDerivationCrossBackendMoneyTests.swift (PersistenceKitInMemoryTests
    // / PersistenceKitSQLiteTests) for the end-to-end "two independent storage
    // instances resolve the SAME internal RowKey" proof, per backend.
}
