import SwiftUI
import MootGateway
import MootIntentKit   // LexiconMap lives in MootGateway; intents are in MootIntentKit

// MARK: - AppleSurfacesView
//
// The iOS-native verb surface: six live App Intents routed through the ARIA
// tool surface in-process. All six verbs have real perform() implementations
// in MootIntentKit; they are not system-registered with the Shortcuts catalog
// yet because that requires the Xcode app bundle packaging step — not a
// capability gap, a packaging step.
//
// All six verbs have "Run in-process" buttons. The structural verbs
// (reanchor/mutate/withdraw) operate on the most recently captured id held in
// AppModel. Expunge runs with confirmed=false so in-process testing does not
// permanently erase data; the substrate refusal (confirmation guard active)
// is logged to the run log.
//
// Display chrome via String(localized:); mapping data (intent type names,
// reach, notes) and the run log are content and stay verbatim.

struct AppleSurfacesView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                intentList
                if !model.intentRunLog.isEmpty { runLog }
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "iOS-native verb surface")).font(.title3.weight(.semibold))
            Text(String(localized: "Six live App Intents routed through the ARIA tool surface. Run in-process now. Not yet in the system Shortcuts catalog — that requires the Xcode app bundle packaging step."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var intentList: some View {
        GroupBox(String(localized: "Caller-driven verbs — App Intents")) {
            VStack(spacing: 0) {
                ForEach(LexiconMap.callerVerbs) { verb in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verb.intentType ?? "—")   // type name — verbatim
                                    .font(.callout.monospaced().weight(.semibold))
                                Text(String(localized: "· \(verb.verb)")).font(.caption).foregroundStyle(.secondary)
                            }
                            // "reach:" label + data — localizable format with the data interpolated.
                            Text(String(localized: "reach: \(verb.appleReach.joined(separator: ", "))"))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(verb.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        // All six verbs have a Run in-process button. Expunge
                        // is additionally marked destructive-safe: it runs with
                        // confirmed=false so the in-process test exercises the
                        // confirmation guard without permanently erasing data.
                        Button(verbButtonLabel(for: verb.verb)) {
                            Task { await model.runIntent(verb.verb) }
                        }
                        .controlSize(.small)
                        .disabled(model.bridge == nil)
                    }
                    .padding(.vertical, 7)
                    if verb.id != LexiconMap.callerVerbs.last?.id { Divider() }
                }
            }
            .padding(6)
        }
    }

    /// Button label for each verb. Expunge notes the confirmed=false guard so
    /// the operator knows it won't permanently erase.
    private func verbButtonLabel(for verb: String) -> String {
        switch verb {
        case "expunge":
            return String(localized: "Run (guard test)")
        default:
            return String(localized: "Run in-process")
        }
    }

    private var runLog: some View {
        GroupBox(String(localized: "In-process run log")) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.intentRunLog.enumerated()), id: \.offset) { _, line in
                    Text(line)   // run-log line — runtime data
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(6)
        }
    }
}
