import Foundation
import GeniusLocusKit

// VK-ADAPT-01 — corpus projection for migration verification.
//
// data-movement privacy tiers retired GLK's flat import verb but kept the
// substrate's recall-based migration verification (`verifyMigration`)
// and NeuronKit's in-product fidelity benchmark, both of which consume
// the reference-corpus type `ExternalCorpus`. This projection feeds
// them from the adapter pipeline: adapter → `[NoteIR]` → projection →
// `ExternalCorpus`. VaultKit already depends on GeniusLocusKit, so the
// dependency direction is legal (no inversion).

/// Projects canonical notes to the GLK reference-corpus type. No
/// instances — a pure function namespace.
public enum CorpusProjection {

    /// Build an `ExternalCorpus` from decoded notes.
    ///
    /// Per-entry mapping is the inverse of `ExchangeAdapter`'s read
    /// mapping: `stableSourceKey` → `id`, `flattenedBody` → `content`,
    /// `tags` → `tags`. Entry order follows `notes` order (the adapter
    /// emits stableSourceKey-sorted notes, so the projection is
    /// deterministic end to end).
    ///
    /// - Parameters:
    ///   - name: corpus name — typically `ExchangeExport.name`.
    ///   - notes: the notes to project, e.g. from `ExchangeAdapter.decode`.
    /// - Returns: the reference corpus `verifyMigration` and the
    ///   NeuronKit benchmark score against.
    public static func externalCorpus(name: String, notes: [NoteIR]) -> ExternalCorpus {
        ExternalCorpus(
            name: name,
            entries: notes.map { note in
                ExternalEntry(
                    id: note.stableSourceKey,
                    content: note.flattenedBody,
                    tags: note.tags
                )
            }
        )
    }
}
