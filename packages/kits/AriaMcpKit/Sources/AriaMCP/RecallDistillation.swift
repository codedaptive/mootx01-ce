import ContextDistillLib

/// The converter actually used by memory-get distilled reads in both dispatch paths.
public enum RecallDistillation {
    public static let converter: ContextDistillConverter = .intentSpanV23Attributed

    static func render(_ original: String) -> String {
        ContextDistiller().distill(DistillationInput(original: original), converter: converter).aiText
    }
}
