import SwiftUI

// MARK: - RecallView  (verb: recall · A4a serve-out · READ)
//
// Query the MOOT and read drawers back. The "Public only" toggle is the
// export-policy gate (§6.2) made physical: ON sets filter:exportable, so only
// drawers marked public are returned. filter:exportable WORKS — it returns
// drawers captured with exportability:"public" or promoted via
// moot_update_memory correctExportability(public). Since CaptureView
// defaults to private and doesn't yet expose a toggle, a user who only
// captures here will see zero results — but that reflects the UI gap, not
// a system gap.
//
// Display chrome via String(localized:) per .claude/rules/localization.md.

struct RecallView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Serve-out — read drawers back, filtered by the export policy."))
                    .font(.title3.weight(.semibold))

                // Flexible widths: query field fills the row, controls wrap below
                // so nothing overflows a narrow iPhone.
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Query")).font(.caption).foregroundStyle(.secondary)
                        TextField(String(localized: "query"), text: $model.recallQuery)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    }
                    HStack {
                        Toggle(String(localized: "Public only (filter: exportable)"), isOn: $model.recallPublicOnly)
                            .toggleStyle(.switch)
                        Spacer()
                        Button {
                            Task { await model.doRecall() }
                        } label: {
                            Label(String(localized: "Recall"), systemImage: "magnifyingglass")
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.bridge == nil)
                    }
                }

                if model.recallPublicOnly {
                    Label {
                        Text(String(localized: "Export gate ON. Returns only drawers marked public (exportability:\"public\" at capture, or promoted via moot_update_memory correctExportability(public)). CaptureView defaults to private, so results here are empty unless you used the tool path directly."))
                    } icon: {
                        Image(systemName: "lock.shield").foregroundStyle(.blue)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                CallRecordView(title: String(localized: "moot_memory_search result"), call: model.lastRecallCall)
            }
            .padding(20)
        }
    }
}
