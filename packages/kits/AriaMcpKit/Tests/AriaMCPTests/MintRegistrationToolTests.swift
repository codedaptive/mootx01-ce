import Testing
import Foundation
import AdornmentLib
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Dark registration tool tests (MINTCLI-78): `moot_register_adornment_minter`
/// registers one full minter descriptor through the product surface
/// (`GeniusLocusKit.registerAdornmentMinter`) and atomically replaces the
/// active set with exactly that minter (`setActiveAdornmentMinters`).
///
/// The tool is dark: dispatched by name, never advertised in tools/list, and
/// only behind the `MOOTX01_MINT_TOOLS=1` launch gate — these tests pass the
/// gate explicitly to `RecipeTools.dispatch` (see `MintToolsGateTests` for
/// the gate itself). The benchmark mint subcommand calls it once per
/// restored estate before looping `moot_run_adornment_pass` to zero debt.
@Suite("moot_register_adornment_minter dark tool")
struct MintRegistrationToolTests {

    /// Dispatch through the recipe router with the mint-tool gate open.
    private func dispatchGated(
        name: String, arguments: JSONValue, kit: GeniusLocusKit, handle: EstateHandle
    ) async throws -> JSONValue {
        try await RecipeTools.dispatch(
            name: name, args: arguments.objectValue ?? [:], kit: kit,
            defaultHandle: handle, resolveHandle: { _ in handle },
            mintToolsEnabled: true)
    }

    // MARK: - Harness (same in-memory pattern as AdornmentRenderTests)

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> (EstateHandle, InMemoryStorage) {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore()
        )
        return (handle, storage)
    }

    /// Read the estate's registered minters via a peer LocusKit estate on the
    /// same InMemoryStorage (standard write-side/read-side test pattern —
    /// GLK does not expose listAdornmentMinters).
    private func listMinters(
        storage: InMemoryStorage, owner: OwnerCredentials
    ) async throws -> [AdornmentMinterDescriptor] {
        let estate = try await LocusKit.Estate.open(storage: storage, owner: owner)
        return try await estate.listAdornmentMinters()
    }

    private func registrationArgs(
        id: String,
        family: String = "audition",
        parameters: [String: JSONValue]? = nil
    ) -> JSONValue {
        var args: [String: JSONValue] = [
            "minter_id": .string(id),
            "minter_name": .string(id),
            "minter_family": .string(family),
            "minter_model_id": .string("apple-mint"),
            "minter_model_version": .string("abc123def456"),
            "minter_prompt_digest": .string("d1gest"),
        ]
        if let parameters { args["minter_parameters"] = .object(parameters) }
        return .object(args)
    }

    // MARK: - Tests

    /// Registering through the dark tool lands the full descriptor row with
    /// is_active set — the mint pass that follows sees exactly one active minter.
    @Test func testRegisterLandsDescriptorAndActivates() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "mint-reg")
        let kit = GeniusLocusKit()
        let (handle, storage) = try await openEstate(in: kit, owner: owner)
        let result = try await dispatchGated(
            name: "moot_register_adornment_minter",
            arguments: registrationArgs(
                id: "apple280",
                parameters: ["adornment_max_length": .string("280")]),
            kit: kit, handle: handle)
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("minter: apple280"))
        #expect(text.contains("active: 1"))

        let minters = try await listMinters(storage: storage, owner: owner)
        #expect(minters.count == 1)
        let m = try #require(minters.first)
        #expect(m.id == "apple280")
        #expect(m.family == "audition")
        #expect(m.modelID == "apple-mint")
        #expect(m.modelVersion == "abc123def456")
        #expect(m.promptDigest == "d1gest")
        #expect(m.parameters == ["adornment_max_length": "280"])
        #expect(m.isActive)
    }

    /// A second registration for a different minter REPLACES the active set:
    /// afterwards exactly the newly registered minter is active.
    @Test func testSecondRegistrationReplacesActiveSet() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "mint-reg-2")
        let kit = GeniusLocusKit()
        let (handle, storage) = try await openEstate(in: kit, owner: owner)
        _ = try await dispatchGated(
            name: "moot_register_adornment_minter",
            arguments: registrationArgs(id: "apple280"),
            kit: kit, handle: handle)
        _ = try await dispatchGated(
            name: "moot_register_adornment_minter",
            arguments: registrationArgs(id: "candle200", family: "candle"),
            kit: kit, handle: handle)

        let minters = try await listMinters(storage: storage, owner: owner)
        #expect(minters.count == 2)
        let active = minters.filter(\.isActive).map(\.id)
        #expect(active == ["candle200"])
    }

    /// The tool is dark: it must never appear in the advertised tool catalog.
    @Test func testRegistrationToolIsDark() {
        let advertised = RecipeTools.tools().map(\.name)
        #expect(!advertised.contains("moot_register_adornment_minter"))
    }
}
