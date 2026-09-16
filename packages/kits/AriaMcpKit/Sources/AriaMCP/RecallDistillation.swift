import ContextDistillLib
import MootProductIdentity

/// The converter actually used by memory-get distilled reads in both dispatch paths.
public enum RecallDistillation {
    public static let converter: ContextDistillConverter = .intentSpanV23Attributed

    static func render(_ original: String) -> String {
        let cap = MootProductIdentity.Settings.load().recallDistillationMaxSourceBytes
        // Inspect at most cap+1 bytes, before classification or atom allocation.
        // Budget exhaustion sacrifices compression, never source evidence.
        guard original.utf8.prefix(cap + 1).count <= cap else { return original }
        let result = ContextDistiller().distill(DistillationInput(original: original), converter: converter, boundedSelection: true)
        return result.selectionDetails["compression_skipped"] as? Bool == true ? original : result.aiText
    }
}
