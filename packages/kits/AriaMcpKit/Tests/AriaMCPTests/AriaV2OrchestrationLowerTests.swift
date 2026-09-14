import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 orchestration lower adapter contracts")
struct AriaV2OrchestrationLowerTests {
    @Test("terminal and disqualified migration failures remain distinct")
    func migrationFailureCodesStayDistinct() {
        let branchID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        #expect(
            AriaV2OrchestrationLowerError.disqualifiedMigrationBranch(branchID).code
                == "disqualified_branch"
        )
        #expect(
            AriaV2OrchestrationLowerError.terminalMigrationBranch(branchID, status: "won").code
                == "terminal_branch"
        )
    }

    @Test("cleanup outcome status is explicit and does not require requested ids")
    func cleanupStatusesRemainObservable() {
        let branchID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let receipt = AriaV2MigrationConfirmationData(
            promotedBranchID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            discardedBranchIDs: [],
            discardOutcomes: [.init(branchID: branchID, status: .failed)]
        )
        #expect(receipt.promotedBranchID.uuidString.lowercased() == "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        #expect(receipt.discardOutcomes == [.init(branchID: branchID, status: .failed)])
    }

    @Test("production confirmation returns canonical observed cleanup receipts")
    func productionConfirmationOrdersObservedCleanup() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-orchestration-lower")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let winner = try await NeuronKit.deriveBranch(name: "winner", from: handle, in: kit)
        let firstLoser = try await NeuronKit.deriveBranch(name: "first loser", from: handle, in: kit)
        let secondLoser = try await NeuronKit.deriveBranch(name: "second loser", from: handle, in: kit)
        let unknown = UUID()
        let provider = AriaV2GeniusLocusOrchestrationProvider(
            kit: kit, handle: handle, federationSources: [])
        let request = try AriaV2ConfirmMigrationRequest(arguments: .object([
            "winner_branch_id": .string(winner.branchID.uuidString),
            // Deliberately noncanonical: public v2 UUID lists must be sorted
            // by canonical branch identity, not echoed request order.
            "discard_branch_ids": .array([
                .string(winner.branchID.uuidString),
                .string(secondLoser.branchID.uuidString),
                .string(unknown.uuidString),
                .string(firstLoser.branchID.uuidString),
            ]),
        ]))
        let receipt = try await provider.confirmMigration(
            request,
            context: .init(estateID: handle.estateUUID, serverIdentity: "test", sessionID: "test")
        )

        let expectedOutcomeIDs = [winner.branchID, firstLoser.branchID, secondLoser.branchID, unknown]
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let expectedDiscardedIDs = [firstLoser.branchID, secondLoser.branchID]
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        #expect(receipt.promotedBranchID == winner.branchID)
        #expect(receipt.discardOutcomes.map(\.branchID) == expectedOutcomeIDs)
        #expect(receipt.discardedBranchIDs == expectedDiscardedIDs)
        #expect(receipt.discardOutcomes.first(where: { $0.branchID == winner.branchID })?.status == .winnerSkipped)
        #expect(receipt.discardOutcomes.first(where: { $0.branchID == unknown })?.status == .unknown)
        #expect(receipt.discardOutcomes.filter { $0.status == .discarded }.map(\.branchID) == expectedDiscardedIDs)
    }

    /// Drives `moot_federated_recall` through `ToolDispatcher` with a real grant
    /// in place. Verifies that the grant receipt fields (source_estate_id,
    /// requester_estate_id, grant_id) appear in `structuredContent.data`, and
    /// that content planted in the source estate surfaces in
    /// `structuredContent.data.results[*].excerpt`.
    ///
    /// Uses `ToolDispatcher.registering(_:)` to wire the source estate into
    /// the dispatcher's internal federation map, then dispatches through
    /// `ToolDispatcher.dispatch(name:arguments:)` — the production tool surface.
    /// `AriaV2FederatedSearchData.json` serialises the receipt fields as
    /// snake_case canonical (lowercase) UUID strings in `structuredContent.data`.
    @Test("federated lower returns an actual registered peer grant receipt")
    func federatedLowerUsesAuthorizedPeer() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-federation-lower")
        let requesterStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let sourceStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: requesterStorage, owner: owner)
        _ = try await LocusKit.Estate.create(storage: sourceStorage, owner: owner)
        let requester = try await kit.open(
            storage: requesterStorage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: true)
        let source = try await kit.open(
            storage: sourceStorage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: true)
        // Source grants whole-estate read to the requester; capture the grant id
        // so we can assert the exact grant_id surfaced in structuredContent.data.
        let grant = try await kit.issueGrant(source, GrantOptions(
            granteeEstateID: requester.estateUUID,
            scope: .wholeEstate,
            custodyMode: .mediated,
            lifetime: .permanent
        ))
        _ = try await kit.capture(source, CaptureFrame(
            content: "peer-only-v2-federation-row",
            channel: .typed,
            room: "aria-v2-federation",
            latticeAnchor: .udc("004"),
            addedBy: "aria-v2-orchestration-lower-tests",
            embeddingModelID: "test-model-v1",
            subject: "peer-only-v2-federation-row"
        ))

        // Route through the production dispatcher. registering(source) wires the
        // source estate into the dispatcher's federation map so the orchestration
        // provider receives it as a federation source. The dispatcher path (not the
        // lower provider seam) is what live MCP clients exercise.
        let dispatcher = ToolDispatcher(kit: kit, handle: requester).registering(source)
        let result = try await dispatcher.dispatch(
            name: "moot_federated_recall",
            arguments: .object([
                "filter": .string("unconfirmed"),
                "hydration_level": .string("full"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let data = try #require(
            obj["structuredContent"]?.objectValue?["data"]?.objectValue,
            "structuredContent.data must be present for moot_federated_recall")

        // Receipt fields: the dispatcher must propagate the exact source estate,
        // requester estate, and grant that authorised the search.
        // AriaV2FederatedSearchData.json serialises these as lowercase UUID strings.
        #expect(data["source_estate_id"]?.stringValue == source.estateUUID.uuidString.lowercased(),
                "source_estate_id must match the source estate UUID")
        #expect(data["requester_estate_id"]?.stringValue == requester.estateUUID.uuidString.lowercased(),
                "requester_estate_id must match the requester estate UUID")
        #expect(data["grant_id"]?.stringValue == grant.grant.id.uuidString.lowercased(),
                "grant_id must match the issued grant UUID")

        // Content: the planted row must appear in a result excerpt (compactMemory
        // populates excerpt from drawer.content, not context).
        let results = try #require(data["results"]?.arrayValue, "data.results must be an array")
        #expect(
            results.contains { $0.objectValue?["excerpt"]?.stringValue?.contains("peer-only-v2-federation-row") == true },
            "federated recall must surface content from the peer estate; results: \(results)")
    }

    @Test("a federation response carries the lower engine grant identity")
    func federatedReceiptCarriesGrantIdentity() {
        let source = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let requester = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let grant = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let data = AriaV2FederatedSearchData(
            sourceEstateID: source,
            requesterEstateID: requester,
            grantID: grant,
            results: []
        )
        #expect(data.sourceEstateID == source)
        #expect(data.requesterEstateID == requester)
        #expect(data.grantID == grant)
    }

    /// Drives `moot_synthesize` end-to-end and asserts that `subject` and `context`
    /// in the compact synthesis row are truncated to exactly the 512-scalar compact form
    /// and that they are identical.
    ///
    /// The subject is built from 120 grapheme clusters with varying numbers of combining
    /// diacritical marks (4–7 scalars each, 660 scalars total).  The grapheme-cluster
    /// count satisfies `DrawerStore.subjectLengthContract` (≤ 120), so the filing gate
    /// passes.  The scalar count exceeds `AriaV2Envelope.compactTextScalarLimit` (512),
    /// so `compactMemory(_:)` truncates both `subject` and `context` to the 512-scalar
    /// prefix.  The test goes RED if either field is absent or untouched by truncation.
    ///
    /// Injection route: filed through `moot_file_memory` via `ToolDispatcher`.
    /// `DrawerStore` accepts the subject because `.count` is grapheme-cluster count;
    /// `compactText` truncates by scalar count, so the cap IS reachable.
    @Test func compact_row_subject_and_context_share_the_512_scalar_form() async throws {
        // Build 120 grapheme clusters with varying combining-mark counts so the total
        // scalar count exceeds 512 while the grapheme-cluster count stays at 120.
        // Four-cycle: 5, 6, 4, 7 scalars per cluster → 30 × (5+6+4+7) = 660 scalars.
        // Non-uniform per-cluster counts make a wrong truncation slice visibly wrong.
        let combiningSequences: [String] = [
            "\u{0300}\u{0301}\u{0302}\u{0303}",                      // 4 combining → 5 scalars
            "\u{0300}\u{0301}\u{0302}\u{0303}\u{0304}",              // 5 combining → 6 scalars
            "\u{0300}\u{0301}\u{0302}",                              // 3 combining → 4 scalars
            "\u{0300}\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}",      // 6 combining → 7 scalars
        ]
        let bases = "abcdefghijklmnopqrstuvwxyz"
        var subject = ""
        for i in 0..<120 {
            let baseIndex = bases.index(bases.startIndex, offsetBy: i % 26)
            subject.append(bases[baseIndex])
            subject += combiningSequences[i % combiningSequences.count]
        }

        // Pin the premise: if either property drifts, the test fails here rather than
        // silently going vacuous (a wrong assertion about 512 scalars).
        try #require(
            subject.count <= 120,
            "premise: subject must satisfy grapheme-cluster storage contract (\(subject.count) clusters)")
        try #require(
            subject.unicodeScalars.count > 512,
            "premise: subject must exceed 512-scalar compact cap (\(subject.unicodeScalars.count) scalars)")

        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: "v2b-compact-synthesis-512")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner,
                                        identityKeyStore: InMemoryEstateIdentityKeyStore())
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File through the production door.  The storage gate passes because
        // DrawerStore.subjectLengthContract checks grapheme-cluster count (≤ 120).
        _ = try await dispatcher.dispatch(name: "moot_file_memory", arguments: .object([
            "content": .string("compact-synthesis-test-content"),
            "subject": .string(subject),
            "location": .string("compact-512-form-tests"),
        ]))

        let result = try await dispatcher.dispatch(name: "moot_synthesize", arguments: .object([
            "filter": .string("unconfirmed"),
        ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let rows = try #require(
            obj["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "moot_synthesize must return a results array in structuredContent.data")
        let first = try #require(rows.first?.objectValue, "synthesis must return at least one row")

        let rowSubject = try #require(first["subject"]?.stringValue, "row must carry a subject field")
        let rowContext = try #require(first["context"]?.stringValue, "row must carry a context field")
        let compact = AriaV2Envelope.compactText(subject)

        // All three assertions must hold together: same text, same as compactText output,
        // and exactly 512 scalars.  Removing compactMemory's subject truncation turns
        // the last assertion red (raw subject has 660 scalars, not 512).
        #expect(rowSubject == rowContext,
                "subject and context must be identical in the compact synthesis row")
        #expect(rowSubject == compact,
                "subject must equal AriaV2Envelope.compactText of the filed subject")
        #expect(rowSubject.unicodeScalars.count == 512,
                "compact form must be exactly 512 scalars; got \(rowSubject.unicodeScalars.count)")
    }

    /// Drives `moot_synthesize` through `ToolDispatcher` with a real in-memory
    /// estate so the full synthesis path — including `compactMemory(_:)` and the
    /// synthesize inline site — is exercised end-to-end. Asserts that the compact
    /// synthesis row carries the drawer's subject in its `context` field.
    @Test func synthesis_row_context_carries_the_filed_subject() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: "v2b-context-synthesis")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner,
                                        identityKeyStore: InMemoryEstateIdentityKeyStore())
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let subject = "the drawer subject that context must carry"
        _ = try await dispatcher.dispatch(name: "moot_file_memory", arguments: .object([
            "content": .string(subject),
            "subject": .string(subject),
            "location": .string("context-field-tests"),
        ]))

        let result = try await dispatcher.dispatch(name: "moot_synthesize", arguments: .object([
            "filter": .string("unconfirmed"),
        ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let rows = try #require(
            obj["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "moot_synthesize must return a results array in structuredContent.data")
        let first = try #require(rows.first?.objectValue, "synthesis must return at least one row")
        #expect(
            first["context"]?.stringValue == subject,
            "synthesis compact row must carry the drawer subject in the context field; got: \(String(describing: first["context"]))")
    }
}
