import Foundation

/// Paged async sequence of recall results. Per spec § 7.8.4.
///
/// The first page is produced synchronously when iteration begins
/// (spec § 7.4 — "first page synchronous"). Subsequent pages are
/// produced lazily on each call to `next()`. The final page has
/// `RecallPage.isLast == true`; every earlier page is `false`.
///
/// `HydrationLevel` is applied at page-emission time:
/// `.bitmapOnly` strips the `content` field so callers receive only
/// the bitmap / metadata surface (spec § 7.3 lightest tier);
/// `.structured` and `.full` return the row unchanged at this tier —
/// `.full` becomes distinct from `.structured` only when the blob
/// tier ships in a later mission.
///
/// This sequence carries already-fetched rows. A compiled-filter /
/// plan-driven page generator that streams from `DrawerStore`
/// page-by-page is not yet implemented; the constructor takes a
/// pre-filtered `[Drawer]`. The page boundary contract (`pageIndex`,
/// `isLast`, hydration semantics) matches the spec.
public struct RecallStream: AsyncSequence, Sendable {
    public typealias Element = RecallPage

    /// Default rows per page when `RecallFrame.limit` is nil. Per
    /// spec § 7.8.4 — implementation default is 50.
    public static let defaultPageSize = 50

    private let rows: [Drawer]
    private let pageSize: Int
    private let hydrationLevel: HydrationLevel

    /// Named internal-read failures that occurred while `Estate.recall`
    /// produced this stream. EMPTY for a genuine result (every internal
    /// read succeeded — including the genuine-empty estate, where the
    /// reads succeeded and simply matched no rows). NON-EMPTY only when
    /// an internal read (`liveRows`, room-fingerprints, room-drawer-read,
    /// or the bitmap evaluator) FAILED and its rows were dropped: in that
    /// case `rows` may be empty for a reason OTHER than "no matches," and
    /// this array names which stage failed so a consumer can tell a FAILED
    /// recall from a GENUINE-EMPTY estate. Spec § 7.8.1.
    ///
    /// Stage identifiers (stable, cross-port):
    /// - `locus.liveRows.readFailed` — the bounded corpus scan failed.
    /// - `locus.roomFingerprints.readFailed` — the room-fingerprint
    ///   enumeration failed (fingerprint-pruning path).
    /// - `locus.roomDrawerRead.readFailed` — a surviving room's drawer
    ///   read failed (fingerprint-pruning path).
    /// - `locus.bitmapEval.failed` — `BitmapEvaluator.evaluate` threw.
    ///
    /// `recall` is non-throwing per spec § 7.8.1, so this field — not a
    /// thrown error — is the channel by which an internal-read failure
    /// reaches the caller. The GLK `RecallDirector` merges these into
    /// `GLKRecallResult.degradedStages`.
    public let degradedStages: [String]

    /// Constructed by `Estate.recall`. `pageSize` is clamped to at
    /// least 1 — a non-positive page size would loop forever or
    /// produce zero-row pages with `isLast == false`, both of which
    /// violate the spec § 7.8.4 contract.
    ///
    /// `degradedStages` defaults to `[]` so non-recall constructors
    /// (e.g. an in-memory reranked stream) carry no spurious degradation
    /// without restating the default.
    internal init(
        rows: [Drawer],
        pageSize: Int = RecallStream.defaultPageSize,
        hydrationLevel: HydrationLevel = .structured,
        degradedStages: [String] = []
    ) {
        self.rows = rows
        // `Swift.max` qualifier — `Sequence.max()` is an instance
        // method on the surrounding Array context and would shadow
        // the global function here.
        self.pageSize = Swift.max(1, pageSize)
        self.hydrationLevel = hydrationLevel
        self.degradedStages = degradedStages
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(rows: rows, pageSize: pageSize, hydrationLevel: hydrationLevel)
    }

    /// One page of recall results. `pageIndex` is zero-based;
    /// `isLast` is true only on the final page emitted by the
    /// iterator.
    public struct RecallPage: Sendable {
        public let rows: [Drawer]
        public let pageIndex: Int
        public let isLast: Bool
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let allRows: [Drawer]
        private let pageSize: Int
        private let hydrationLevel: HydrationLevel
        private var offset = 0
        private var pageIndex = 0
        private var exhausted = false

        init(rows: [Drawer], pageSize: Int, hydrationLevel: HydrationLevel) {
            self.allRows = rows
            self.pageSize = pageSize
            self.hydrationLevel = hydrationLevel
        }

        public mutating func next() async -> RecallPage? {
            guard !exhausted else { return nil }
            // Empty corpus is emitted as a single final page with
            // `rows.isEmpty` and `isLast == true` — callers can run
            // a uniform `for await` loop without special-casing the
            // zero-row corpus.
            // `Swift.min` — same shadowing reason as the `Swift.max`
            // call in the initializer above.
            let end = Swift.min(offset + pageSize, allRows.count)
            let slice = Array(allRows[offset..<end]).map(hydrate)
            let isLast = end >= allRows.count
            let page = RecallPage(rows: slice, pageIndex: pageIndex, isLast: isLast)
            offset = end
            pageIndex += 1
            if isLast { exhausted = true }
            return page
        }

        /// Apply `hydrationLevel` to a row. `.bitmapOnly` rebuilds the
        /// `Drawer` with `content = ""` while preserving every other
        /// field (notably the bitmap columns — adjective, operational,
        /// provenance — which are the entire point of this tier).
        /// `.structured` and `.full` pass the row through unchanged.
        private func hydrate(_ d: Drawer) -> Drawer {
            switch hydrationLevel {
            case .bitmapOnly:
                return Drawer(
                    id: d.id,
                    content: "",
                    parentNodeId: d.parentNodeId,
                    sourceFile: d.sourceFile,
                    chunkIndex: d.chunkIndex,
                    addedBy: d.addedBy,
                    filedAt: d.filedAt,
                    // Preserve eventTime (ING-01): bitmapOnly hydration
                    // must not collapse the event clock onto filedAt.
                    eventTime: d.eventTime,
                    embeddingModelID: d.embeddingModelID,
                    tombstonedAt: d.tombstonedAt,
                    removedByBatch: d.removedByBatch,
                    provenance: d.provenance,
                    adjectiveBitmap: d.adjectiveBitmap,
                    operationalBitmap: d.operationalBitmap,
                    lineageID: d.lineageID,
                    udcCode: d.udcCode,
                    udcFacets: d.udcFacets,
                    wikidataQID: d.wikidataQID,
                    wikidataQidsSecondary: d.wikidataQidsSecondary
                )
            case .structured, .full:
                return d
            }
        }
    }
}
