import CoreSpotlight
import Foundation
import FoundationModels
import MootIntentKit
import UniformTypeIdentifiers

private final class SpotlightAcknowledgement: @unchecked Sendable {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
}

public struct MootSpotlightRecord: Sendable, Equatable {
    public let id: String
    public let room: String
    public let content: String
    public let sensitivity: String
    public let exportability: String

    public var isEligible: Bool {
        let safeSensitivity = sensitivity == "normal" || sensitivity == "elevated"
        let explicitlyPublic = exportability == "public" || exportability == "public_"
        return safeSensitivity && explicitlyPublic
    }

    static func parse(_ text: String) -> MootSpotlightRecord? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("memory "),
              let roomLine = lines.first(where: { $0.hasPrefix("room: ") }),
              let sensitivityLine = lines.first(where: { $0.hasPrefix("sensitivity: ") }),
              let exportabilityLine = lines.first(where: { $0.hasPrefix("exportability: ") }),
              let contentIndex = lines.firstIndex(of: "content:") else { return nil }
        let id = String(first.dropFirst("memory ".count))
        let roomAndWing = String(roomLine.dropFirst("room: ".count))
        let room = roomAndWing.components(separatedBy: "  wing: ").first ?? "memory"
        let sensitivity = String(sensitivityLine.dropFirst("sensitivity: ".count))
        let exportability = String(exportabilityLine.dropFirst("exportability: ".count))
        var contentLines = Array(lines.dropFirst(contentIndex + 1))
        if contentLines.last?.hasPrefix("sensitivity_advisory: ") == true {
            contentLines.removeLast()
        }
        let content = contentLines.joined(separator: "\n")
        guard !id.isEmpty, !content.isEmpty else { return nil }
        return MootSpotlightRecord(
            id: id,
            room: room,
            content: content,
            sensitivity: sensitivity,
            exportability: exportability
        )
    }
}

/// Apple-only searchable projection. Core Spotlight is a derived index; MOOT
/// remains canonical. Only explicitly public, normal/elevated drawers are
/// donated. Clearing the domain before refresh removes items that later became
/// private, restricted, withdrawn, or unavailable.
public final class MootSpotlightIndexer: NSObject, CSSearchableIndexDelegate, @unchecked Sendable {
    public static let domainIdentifier = "com.codedaptive.mootx01.memory"

    private let caller: any MootToolCalling
    private let index: CSSearchableIndex

    public init(
        caller: any MootToolCalling,
        index: CSSearchableIndex = .default()
    ) {
        self.caller = caller
        self.index = index
        super.init()
        index.indexDelegate = self
    }

    @discardableResult
    public func refreshEligible(limit: Int = 500) async throws -> Int {
        guard CSSearchableIndex.isIndexingAvailable() else { return 0 }
        let drawers = await caller.recallDrawers(query: "", limit: min(max(1, limit), 500))
        let records = await records(for: drawers.map(\.id)).filter(\.isEligible)
        try await deleteDomain()
        let items = records.map(searchableItem)
        if !items.isEmpty {
            try await indexItems(items)
        }
        return items.count
    }

    public func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
    ) {
        let acknowledgement = SpotlightAcknowledgement(acknowledgementHandler)
        Task {
            _ = try? await refreshEligible()
            acknowledgement.callback()
        }
    }

    public func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexSearchableItemsWithIdentifiers identifiers: [String],
        acknowledgementHandler: @escaping () -> Void
    ) {
        let acknowledgement = SpotlightAcknowledgement(acknowledgementHandler)
        Task {
            let records = await records(for: identifiers)
            let eligibleIDs = Set(records.filter(\.isEligible).map(\.id))
            let staleIDs = identifiers.filter { !eligibleIDs.contains($0) }
            if !staleIDs.isEmpty { try? await deleteItems(withIdentifiers: staleIDs) }
            let items = records.filter(\.isEligible).map(searchableItem)
            if !items.isEmpty { try? await indexItems(items) }
            acknowledgement.callback()
        }
    }

    public func searchableItems(forIdentifiers identifiers: [String]) async -> [CSSearchableItem] {
        await records(for: identifiers).filter(\.isEligible).map(searchableItem)
    }

    private func records(for identifiers: [String]) async -> [MootSpotlightRecord] {
        var records: [MootSpotlightRecord] = []
        for id in identifiers {
            let result = await caller.callTool("moot_memory_get", arguments: ["id": .string(id)])
            guard !result.isError, let record = MootSpotlightRecord.parse(result.text) else { continue }
            records.append(record)
        }
        return records
    }

    private func searchableItem(_ record: MootSpotlightRecord) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = String(record.content.prefix(80))
        attributes.textContent = record.content
        attributes.contentDescription = record.content
        attributes.keywords = [record.room, "MOOTx01"]
        attributes.containerTitle = record.room
        attributes.userOwned = true
        attributes.userCreated = true
        attributes.contentURL = URL(
            string: "mootx01://x-callback-url/recall?query=\(record.id)"
        )
        return CSSearchableItem(
            uniqueIdentifier: record.id,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributes
        )
    }

    private func deleteDomain() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { error in
                error.map(continuation.resume(throwing:)) ?? continuation.resume()
            }
        }
    }

    private func indexItems(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                error.map(continuation.resume(throwing:)) ?? continuation.resume()
            }
        }
    }

    private func deleteItems(withIdentifiers identifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withIdentifiers: identifiers) { error in
                error.map(continuation.resume(throwing:)) ?? continuation.resume()
            }
        }
    }
}

#if arch(arm64)
public enum MootSpotlightSearch {
    public static func makeTool(delegate: MootSpotlightIndexer) -> SpotlightSearchTool {
        let source = CoreSpotlightSource(
            searchableIndexDelegate: delegate,
            fetchAttributes: [.title, .textContent, .contentDescription, .containerTitle]
        )
        return SpotlightSearchTool(configuration: .init(
            sources: [.coreSpotlight(source)],
            guide: .focused(.items),
            maximumResponseSize: 8_192
        ))
    }
}
#endif
