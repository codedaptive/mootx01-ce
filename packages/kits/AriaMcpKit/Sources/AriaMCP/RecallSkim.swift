import AriaMCPWire
import CognitionKit
import ContextDistillLib
import GeniusLocusKit

/// Wire-safe preview. Never serialize PassageViewResult's fullText or continuation.
struct RecallSkim {
    let text: String
    let complete: Bool
    let budgetHonored: Bool
    let savings: String

    init(original: String) throws {
        let distilled = GeniusLocusKit.distilledRendering(of: original)
        let preview = try PassageViews.skim(body: distilled, budget: 512, ordered: false)
        text = preview.text
        complete = preview.complete
        budgetHonored = preview.budgetHonored
        savings = DistilledSavings.text(original: original, reduced: distilled, enabled: true, skimmed: preview.text)
    }

    var json: JSONValue {
        .object(["text": .string(text), "complete": .bool(complete),
                 "budgetHonored": .bool(budgetHonored), "savings": .string(savings)])
    }

    var rendered: String {
        "\(text)\ncomplete: \(complete); budgetHonored: \(budgetHonored)\n\(savings)"
    }
}
