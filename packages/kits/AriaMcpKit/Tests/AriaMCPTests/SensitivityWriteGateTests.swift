import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Sensitivity ceiling gate for write verbs (SENS_WRITE_GATE Unit 1).
///
/// A caller holding only a UUID must not be able to mutate a memory that it
/// cannot read.  Before this gate, `storedMemoryID` applied no ceiling check
/// and a write against a `.restricted` row succeeded even when the ceiling was
/// `.elevated`.  After the gate, every write verb routes through
/// `gatedStoredMemoryID` which checks `context.maximumSensitivity` before
/// handing the stored ID to the lower kit.
///
/// Oracle-closure rule: absent IDs and above-ceiling IDs must produce the
/// identical `memory_not_found` refusal so neither can be distinguished.
@Suite("Sensitivity write gate — moot_*_memory verbs", .serialized)
struct SensitivityWriteGateTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Seed a memory with the given adjective sensitivity directly through
    /// the kit, bypassing the write-gate under test.
    @discardableResult
    private func seed(
        _ content: String,
        sensitivity: AdjectiveSensitivity = .normal,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "swg-tests",
            latticeAnchor: .udc("swg"),
            addedBy: "swg-tests",
            embeddingModelID: "test-model-v1",
            sensitivity: sensitivity
        )
        return try await kit.capture(handle, frame)
    }

    /// Extract the structured error object from a refusal envelope.
    private func errorObject(
        _ result: JSONValue
    ) -> [String: JSONValue]? {
        result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue
    }

    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? false
    }

    // MARK: - Gate: blocked verbs

    /// Gate-discrimination proof: every write verb returns `memory_not_found`
    /// when the target memory sits above the caller's sensitivity ceiling.
    ///
    /// Pre-fix failure (verbatim — without `gatedStoredMemoryID` the old
    /// `storedMemoryID` returned the stored ID regardless of sensitivity and
    /// the lower kit applied the mutation successfully):
    ///
    ///     Expectation failed: isError(result)
    ///     moot_update_memory must be blocked on a restricted memory;
    ///     got: {"isError": false, ...}
    ///
    /// Post-fix (this test): isError is true, code is "memory_not_found".
    @Test(
        "gate blocks write verbs on above-ceiling memories",
        arguments: [
            ("moot_update_memory",   JSONValue.object(["mutation": .string("set_subject"), "subject": .string("blocked")])),
            ("moot_withdraw_memory", JSONValue.object([:])),
            ("moot_erase_memory",    JSONValue.object(["confirmation": .bool(true)])),
            ("moot_confirm_memory",  JSONValue.object([:])),
            ("moot_move_memory",     JSONValue.object(["wing": .string("test"), "room": .string("test")])),
        ] as [(String, JSONValue)]
    )
    func gateBlocksWriteVerbsOnAboveCeilingMemories(
        tool: String, extraArgs: JSONValue
    ) async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "swg-blocked-\(tool)")
        let handle = try await openEstate(in: kit, owner: owner)

        // Seed a restricted memory — above the default elevated ceiling.
        // No sensitivity grant is active, so the ceiling stays at .elevated.
        let restricted = try await seed(
            "restricted — must be invisible to write gate",
            sensitivity: .restricted,
            in: handle,
            kit: kit
        )

        var args: [String: JSONValue] = ["memory_id": .string(restricted.id)]
        if let extra = extraArgs.objectValue {
            for (k, v) in extra { args[k] = v }
        }

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: tool,
            arguments: .object(args)
        )

        #expect(isError(result),
            "\(tool) must be blocked on a restricted memory; got: \(result)")

        let err = try #require(errorObject(result),
            "\(tool) refusal must carry a structured error object")
        #expect(
            err["code"]?.stringValue == "memory_not_found",
            "\(tool) must return code memory_not_found; got: \(String(describing: err["code"]))")
        #expect(
            err["message"]?.stringValue == "No authorized memory matched the requested reference.",
            "\(tool) message must be exact oracle-closure text; got: \(String(describing: err["message"]))")
        #expect(
            err["retryable"]?.boolValue == false,
            "\(tool) memory_not_found must be non-retryable")
    }

    // MARK: - Oracle closure: restricted row ≡ nonexistent row

    /// Oracle-closure proof: the refusal envelope for a restricted-row ID is
    /// byte-identical to the refusal envelope for a freshly-generated nonexistent
    /// UUID, for every write verb.  Neither case can be distinguished by the caller.
    @Test(
        "oracle closure: restricted row and nonexistent UUID produce identical refusals",
        arguments: [
            ("moot_update_memory",   JSONValue.object(["mutation": .string("set_subject"), "subject": .string("blocked")])),
            ("moot_withdraw_memory", JSONValue.object([:])),
            ("moot_erase_memory",    JSONValue.object(["confirmation": .bool(true)])),
            ("moot_confirm_memory",  JSONValue.object([:])),
            ("moot_move_memory",     JSONValue.object(["wing": .string("test"), "room": .string("test")])),
        ] as [(String, JSONValue)]
    )
    func oracleClosureRestrictedEqualsNonexistent(
        tool: String, extraArgs: JSONValue
    ) async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "swg-oracle-\(tool)")
        let handle = try await openEstate(in: kit, owner: owner)

        let restricted = try await seed(
            "restricted oracle test",
            sensitivity: .restricted,
            in: handle,
            kit: kit
        )
        let nonexistent = UUID()

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        func callTool(_ id: String) async throws -> JSONValue {
            var args: [String: JSONValue] = ["memory_id": .string(id)]
            if let extra = extraArgs.objectValue {
                for (k, v) in extra { args[k] = v }
            }
            return try await dispatcher.dispatch(name: tool, arguments: .object(args))
        }

        let restrictedResponse = try await callTool(restricted.id)
        let nonexistentResponse = try await callTool(nonexistent.uuidString)

        let restrictedErr = try #require(errorObject(restrictedResponse),
            "restricted row refusal must carry an error object")
        let nonexistentErr = try #require(errorObject(nonexistentResponse),
            "nonexistent row refusal must carry an error object")

        #expect(
            restrictedErr["code"]?.stringValue == nonexistentErr["code"]?.stringValue,
            "\(tool): restricted and nonexistent must produce the same code; got \(String(describing: restrictedErr["code"])) vs \(String(describing: nonexistentErr["code"]))")
        #expect(
            restrictedErr["message"]?.stringValue == nonexistentErr["message"]?.stringValue,
            "\(tool): restricted and nonexistent must produce the same message")
        #expect(
            restrictedErr["retryable"]?.boolValue == nonexistentErr["retryable"]?.boolValue,
            "\(tool): restricted and nonexistent must produce the same retryable flag")
    }

    // MARK: - Gate passes for readable rows

    /// Gate passes when the memory is within the caller's sensitivity ceiling.
    /// `correct_sensitivity` raise (normal → restricted) must succeed because
    /// the memory is readable at `.normal`, within the default `.elevated` ceiling.
    @Test func gatePassesForReadableRow() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "swg-pass")
        let handle = try await openEstate(in: kit, owner: owner)

        // Normal-sensitivity memory — within the .elevated ceiling.
        let normal = try await seed(
            "normal — visible to write gate",
            sensitivity: .normal,
            in: handle,
            kit: kit
        )

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // Raise sensitivity: normal → restricted.  This write must succeed
        // because the memory is readable before the mutation lands.
        let result = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "memory_id": .string(normal.id),
                "mutation": .string("correct_sensitivity"),
                "sensitivity": .string("restricted"),
            ])
        )
        #expect(!isError(result),
            "correct_sensitivity raise on a normal memory must succeed; got: \(result)")
    }
}
