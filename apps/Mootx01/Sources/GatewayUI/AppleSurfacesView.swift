import SwiftUI
import MootGateway

// MARK: - AppleSurfacesView
//
// Each deferred Apple adapter laid in as a compiling shell, with its lexicon
// mapping shown and a "Run in-process" button that actually invokes the App
// Intent shell's perform() against the live estate — proving the shells work
// today, before any app bundle registers them. The point Bob asked for: when
// Apple drops a change, it's a small finish into a slot that already exists.
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
            Text(String(localized: "Apple adapter shells")).font(.title3.weight(.semibold))
            Text(String(localized: "Real, compiling App Intents / Shortcuts / callback-URL shells routed through the same ARIA tool surface. Not system-registered (that needs an Xcode app bundle) — but runnable in-process now."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var intentList: some View {
        GroupBox(String(localized: "Caller-driven verbs → App Intents")) {
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
                        if verb.verb == "capture" || verb.verb == "recall" {
                            Button(String(localized: "Run in-process")) {
                                Task { await model.runIntent(verb.verb) }
                            }
                            .controlSize(.small)
                            .disabled(model.bridge == nil)
                        } else {
                            Text(String(localized: "shell"))
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.gray.opacity(0.18))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 7)
                    if verb.id != LexiconMap.callerVerbs.last?.id { Divider() }
                }
            }
            .padding(6)
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
