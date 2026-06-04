import Foundation
import OSLog
import GeniusLocusKit
import LocusKit

/// Counts returned by an import run.
public struct ImportReport: Sendable, Equatable {

    /// Drawers captured for a lineage not previously present.
    public var drawersWritten: Int

    /// Re-imports that superseded an existing drawer (idempotent update).
    public var drawersUpdated: Int

    /// `.references` tunnels created across all notes (post-dedup).
    public var tunnelsCreated: Int

    /// Notes that could not be imported (e.g. empty content under I-5).
    public var itemsSkipped: Int

    /// Drawers whose UDC came from a live FDC anchor or an explicit
    /// frontmatter `udc`.
    public var fdcClassified: Int

    /// Drawers that landed with the `"000"` fallback UDC because no live
    /// FDC anchor resolved and no explicit `udc` was supplied.
    public var fdcUnclassified: Int

    public init(
        drawersWritten: Int = 0,
        drawersUpdated: Int = 0,
        tunnelsCreated: Int = 0,
        itemsSkipped: Int = 0,
        fdcClassified: Int = 0,
        fdcUnclassified: Int = 0
    ) {
        self.drawersWritten = drawersWritten
        self.drawersUpdated = drawersUpdated
        self.tunnelsCreated = tunnelsCreated
        self.itemsSkipped = itemsSkipped
        self.fdcClassified = fdcClassified
        self.fdcUnclassified = fdcUnclassified
    }
}

/// The public surface a control layer (ARIA_MCP, later) calls to bridge a
/// MOOT estate and a Markdown vault in both directions.
///
/// `VaultBridge` is a thin facade: `ObsidianAdapter` (or any
/// `VaultAdapter`) handles file ⇄ `NoteIR`, and `DrawerMapping` handles
/// `NoteIR` ⇄ substrate. The bridge fuses the two into one projection per
/// MOOT. Synchronous-per-call is sufficient for V1; the long-run enqueue,
/// drift detection, and watched-source scheduler are A2 (Stream va), not
/// here.
public struct VaultBridge: Sendable {

    private let kit: GeniusLocusKit
    private let adapter: VaultAdapter
    private let mapping: DrawerMapping

    private static let log = Logger(subsystem: "com.mootx01.kit", category: "VaultKit")

    /// - Parameters:
    ///   - kit: the opened `GeniusLocusKit` instance whose estates this
    ///     bridge reads and writes.
    ///   - adapter: the vault format adapter. Defaults to Obsidian.
    ///   - mapping: the substrate mapping policy (actor id, embedding-model
    ///     id, FDC feature flag). Defaults are import-safe.
    public init(
        kit: GeniusLocusKit,
        adapter: VaultAdapter = ObsidianAdapter(),
        mapping: DrawerMapping = DrawerMapping()
    ) {
        self.kit = kit
        self.adapter = adapter
        self.mapping = mapping
    }

    // MARK: - Export

    /// Project an estate to a Markdown vault — drawers → notes,
    /// `.references` tunnels → wikilinks, wing/room → folders,
    /// provenance/anchors → frontmatter. One vault per MOOT.
    public func export(estate handle: EstateHandle, to vaultURL: URL) async throws {
        let notes = try await mapping.export(kit: kit, handle: handle)
        try adapter.fromIR(notes, to: vaultURL)
        Self.log.info("exported \(notes.count, privacy: .public) notes to vault")
    }

    // MARK: - Import

    /// Import a Markdown vault into an estate via the capture seam.
    ///
    /// Idempotent on each note's `stableSourceKey`: a re-import supersedes
    /// the existing drawer (no duplicate) and creates no duplicate
    /// tunnels. Every captured drawer satisfies invariant I-5.
    ///
    /// - Returns: an `ImportReport` with written/updated/tunnel/skipped
    ///   and FDC-classified counts.
    public func importVault(at vaultURL: URL, into handle: EstateHandle) async throws -> ImportReport {
        let notes = try adapter.toIR(vaultURL: vaultURL)

        // Snapshot existing state once so written-vs-updated and tunnel
        // de-duplication need no per-note probe.
        let (existingLineageIDs, existingWings) = try await existingDrawerState(handle: handle)
        var existingTunnelSignatures = try await existingTunnelSignatures(
            handle: handle, wings: existingWings
        )

        var report = ImportReport()
        for note in notes {
            let outcome = try await mapping.importNote(
                note,
                kit: kit,
                handle: handle,
                existingLineageIDs: existingLineageIDs,
                existingTunnelSignatures: &existingTunnelSignatures
            )
            switch outcome {
            case let .written(tunnels, classified):
                report.drawersWritten += 1
                report.tunnelsCreated += tunnels
                if classified { report.fdcClassified += 1 } else { report.fdcUnclassified += 1 }
            case let .updated(tunnels, classified):
                report.drawersUpdated += 1
                report.tunnelsCreated += tunnels
                if classified { report.fdcClassified += 1 } else { report.fdcUnclassified += 1 }
            case .skipped:
                report.itemsSkipped += 1
            }
        }

        Self.log.info(
            "imported vault: \(report.drawersWritten, privacy: .public) written, \(report.drawersUpdated, privacy: .public) updated, \(report.itemsSkipped, privacy: .public) skipped"
        )
        return report
    }

    // MARK: - Snapshot helpers

    /// The lineage IDs of currently-believed drawers and the set of wings
    /// they occupy. Used to classify written vs. updated and to scope the
    /// tunnel-signature snapshot.
    private func existingDrawerState(
        handle: EstateHandle
    ) async throws -> (lineageIDs: Set<UUID>, wings: Set<String>) {
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured)
        )
        return (Set(drawers.map(\.lineageID)), Set(drawers.map(\.wing)))
    }

    /// The stable signatures of existing `.references` tunnels, so a
    /// re-import does not duplicate them.
    private func existingTunnelSignatures(
        handle: EstateHandle,
        wings: Set<String>
    ) async throws -> Set<String> {
        var signatures: Set<String> = []
        for wing in wings {
            let tunnels = try await kit.recallTunnels(handle, wing: wing)
            for tunnel in tunnels where tunnel.kind == .references {
                signatures.insert(DrawerMapping.tunnelSignature(
                    sourceWing: tunnel.sourceWing,
                    sourceRoom: tunnel.sourceRoom,
                    targetRoom: tunnel.targetRoom,
                    label: tunnel.label,
                    kind: tunnel.kind
                ))
            }
        }
        return signatures
    }
}
