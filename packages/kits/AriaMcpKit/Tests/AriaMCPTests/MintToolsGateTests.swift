import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Dark mint tools — launch-time gate (codex finding 16, 2026-09-02).
///
/// `moot_register_adornment_minter` and `moot_run_adornment_pass` dispatch
/// ONLY when the serving process was launched with `MOOTX01_MINT_TOOLS=1`.
/// Hiding them from tools/list is not authorization; without the variable
/// both names are unknown tools. The gate is read once per process, so
/// these tests inject it through `isRecipeTool(_:mintToolsEnabled:)` /
/// `dispatch(...mintToolsEnabled:)` rather than mutating the environment.
/// Mirrors Rust `mint_tools_gate_tests.rs`.
@Suite("dark mint tools launch gate")
struct MintToolsGateTests {

    private static let runPass = RecipeTools.runAdornmentPassToolName
    private static let registerMinter = RecipeTools.registerAdornmentMinterToolName

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore()
        )
    }

    private func passArgs() -> [String: JSONValue] {
        [
            "now": .string("2026-09-02T00:00:00Z"),
            "batch_size": .string("999999"),
        ]
    }

    private func text(of result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?.first?
            .objectValue?["text"]?.stringValue ?? ""
    }

    /// Exactly the literal "1" enables; every other value leaves the gate off.
    @Test func gateValueIsExactlyOne() {
        #expect(RecipeTools.mintToolsEnvironmentVariable == "MOOTX01_MINT_TOOLS")
        #expect(!RecipeTools.mintToolsEnabled(environment: [:]))
        #expect(!RecipeTools.mintToolsEnabled(environment: ["MOOTX01_MINT_TOOLS": ""]))
        #expect(!RecipeTools.mintToolsEnabled(environment: ["MOOTX01_MINT_TOOLS": "0"]))
        #expect(!RecipeTools.mintToolsEnabled(environment: ["MOOTX01_MINT_TOOLS": "true"]))
        #expect(!RecipeTools.mintToolsEnabled(environment: ["MOOTX01_MINT_TOOLS": "1 "]))
        #expect(RecipeTools.mintToolsEnabled(environment: ["MOOTX01_MINT_TOOLS": "1"]))
    }

    /// Gate off: both dark names are outside the recipe routing set and a
    /// direct dispatch throws the same methodNotFound "Unknown tool" error
    /// the dispatcher throws for any unregistered name.
    @Test func darkToolsAreUnknownWhenGateOff() async throws {
        #expect(!RecipeTools.isRecipeTool(Self.runPass, mintToolsEnabled: false))
        #expect(!RecipeTools.isRecipeTool(Self.registerMinter, mintToolsEnabled: false))
        // The gate never touches the listed recipe tools.
        #expect(RecipeTools.isRecipeTool(
            RecipeTools.preciseRecallToolName, mintToolsEnabled: false))

        let owner = OwnerCredentials(ownerIdentifier: "mint-gate-off")
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit, owner: owner)

        for name in [Self.runPass, Self.registerMinter] {
            do {
                _ = try await RecipeTools.dispatch(
                    name: name, args: passArgs(), kit: kit,
                    defaultHandle: handle, resolveHandle: { _ in handle },
                    mintToolsEnabled: false)
                Issue.record("gated dark tool \(name) must be an unknown tool")
            } catch let error as JSONRPCError {
                #expect(error.code == JSONRPCErrorCode.methodNotFound)
                #expect(error.message == "Unknown tool: \(name)")
            }
        }
    }

    /// Gate on: both names route, and a pass call with batch_size 999999
    /// reaches the handler — the value is clamped, never rejected — and
    /// completes.
    @Test func darkToolsDispatchWhenGateOn() async throws {
        #expect(RecipeTools.isRecipeTool(Self.runPass, mintToolsEnabled: true))
        #expect(RecipeTools.isRecipeTool(Self.registerMinter, mintToolsEnabled: true))

        let owner = OwnerCredentials(ownerIdentifier: "mint-gate-on")
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit, owner: owner)

        let result = try await RecipeTools.dispatch(
            name: Self.runPass, args: passArgs(), kit: kit,
            defaultHandle: handle, resolveHandle: { _ in handle },
            mintToolsEnabled: true)
        #expect(result.objectValue?["isError"]?.boolValue == false)
        #expect(text(of: result).hasPrefix("moot_run_adornment_pass: pass complete"),
                "handler must be reached; got: \(text(of: result))")
    }

    /// The production entry points (`isRecipeTool`, `ToolDispatcher.dispatch`)
    /// follow the once-per-process gate: whichever way this test process was
    /// launched, routing and dispatch agree with `processMintToolsEnabled`.
    @Test func processGateDrivesProductionDispatch() async throws {
        let enabled = RecipeTools.processMintToolsEnabled
        #expect(RecipeTools.isRecipeTool(Self.runPass) == enabled)
        #expect(RecipeTools.isRecipeTool(Self.registerMinter) == enabled)

        let owner = OwnerCredentials(ownerIdentifier: "mint-gate-process")
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        do {
            let result = try await dispatcher.dispatch(
                name: Self.runPass, arguments: .object(passArgs()))
            #expect(enabled, "gate off: the dark name must be unknown")
            #expect(text(of: result).hasPrefix("moot_run_adornment_pass: pass complete"))
        } catch let error as JSONRPCError {
            #expect(!enabled, "gate on: the pass handler must run")
            #expect(error.code == JSONRPCErrorCode.methodNotFound)
            #expect(error.message == "Unknown tool: \(Self.runPass)")
        }
    }
}
