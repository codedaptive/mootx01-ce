import Foundation
import CorpusKit
import SynapseKit

/// The persisted span-content version. Existing span rows use FNV-1a 64-bit
/// over UTF-8; strict recall compares this value before reconstructing spans.
public enum SpanContentVersion {
    public static func fnv1a64(_ content: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    /// Whether a serving-generation span set must be rebuilt before strict
    /// recall may treat it as fresh. An indexed drawer with no rows, a row the
    /// strict reader could not decode, or any row stamped with a different
    /// content version is repair debt even though bit 27 is already set.
    public static func requiresRepair(
        content: String,
        expectedDimension: Int,
        maxSpans: Int,
        rows: [SpanVectorRow],
        hasMalformedRows: Bool
    ) -> Bool {
        guard !hasMalformedRows, !rows.isEmpty, rows.count <= maxSpans else { return true }
        let expected = fnv1a64(content)
        let wordCount = Spanner.words(content).count
        for (offset, row) in rows.enumerated() {
            guard row.index == UInt32(offset),
                  row.int8.count == expectedDimension,
                  row.scale.isFinite, row.scale > 0,
                  row.startWord >= 0, row.endWord > row.startWord, row.endWord <= wordCount,
                  row.contentVersion == expected else {
                return true
            }
        }
        return false
    }
}
