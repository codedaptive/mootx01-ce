import Foundation
import Testing
@testable import AriaMCP

/// Verifies that first-party validation refusals carry the structured `data`
/// payload introduced by the v2 lane: path, allowed, and (where applicable)
/// correction.  Before this change every first-party refusal was produced by
/// `invalid(_:)`, which called `JSONRPCError(code:message:)` with no `data`
/// argument, so any assertion on `error.data` would have failed immediately at
/// the `try #require` step.
@Suite("FirstPartyProvider refusal structured data")
struct FirstPartyRefusalStructuredDataTests {

    /// A bad enum value on `moot_update_memory` must produce a `data.allowed`
    /// field containing the declared enum list and `data.path == "mutation"`.
    ///
    /// The expected list is read from the live registry descriptor — not typed
    /// from this file — so the assertion proves the production code and the
    /// expectation agree rather than proving two identical literals match.
    @Test func badEnumArgumentCarriesAllowedList() throws {
        let id = JSONValue.string("11111111-2222-3333-4444-555555555555")

        // Observe the declared mutation enum list from the live descriptor so
        // the test cannot pass if the catalog changes the list without updating
        // the test's expected values.
        let descriptor = try #require(
            FirstPartyProviderCatalog.registry.operation(named: "moot_update_memory"),
            "moot_update_memory must be a registered first-party operation"
        )
        let expectedAllowed = try #require(
            descriptor.inputSchema.objectValue?["properties"]?.objectValue?["mutation"]?.objectValue?["enum"]?.arrayValue,
            "mutation property must carry an enum array in the input schema"
        ).compactMap { $0.stringValue }.sorted()
        #expect(!expectedAllowed.isEmpty, "enum list must be non-empty")

        // Call with a mutation value that is not in the declared list.
        var caughtError: JSONRPCError?
        do {
            try FirstPartyProviderCatalog.validateArguments(
                name: "moot_update_memory",
                arguments: ["id": id, "mutation": .string("not_a_real_mutation")]
            )
        } catch let e as JSONRPCError {
            caughtError = e
        }

        let error = try #require(caughtError, "validateArguments must throw for an undeclared mutation value")
        let data = try #require(error.data?.objectValue, "refusal must carry a structured data object")

        // path must identify the specific argument that failed.
        #expect(data["path"] == .string("mutation"))

        // allowed must carry every declared enum value; jsonRPCError sorts the
        // list before encoding (AriaV2ArgumentDecoder.swift:33), so compare sorted.
        let actualAllowed = try #require(
            data["allowed"]?.arrayValue,
            "refusal must carry an allowed list for an enum argument"
        ).compactMap { $0.stringValue }.sorted()
        #expect(actualAllowed == expectedAllowed)
    }
}
