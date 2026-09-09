import Foundation

/// Bounded distilled-fact drain. It is inert unless a host has explicitly
/// activated a recipe and supplied a live cycle closure.
public enum FactExtractionSignal {
    public static let defaultCadenceSeconds: TimeInterval = 300
    public static let signalName = "fact-extraction"

    public static func spec(
        factExtractionCycle: @escaping @Sendable (Date) async throws -> Int
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let count = try await factExtractionCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "fact-extraction.complete",
                        detail: "completed \(count) source(s) at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    return [.diagnostic(DiagnosticReport(
                        title: "fact-extraction.error", detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }

    public static func defaultSpec() -> SignalSpec {
        spec { _ in 0 }
    }
}
