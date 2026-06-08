import SwiftUI

// MARK: - CaptureView  (verb: capture · A4b submit-in · WRITE)
//
// Type content, pick a location and sensitivity, and file it as a verbatim
// drawer through moot_file_memory — the exact tool a Share Sheet or a Siri
// capture would call. Note there is no exportability control: capture has no
// way to mark a drawer public (the half-wired export-policy edge). That
// absence is intentional and called out, not hidden.
//
// Display chrome via String(localized:) per .claude/rules/localization.md;
// model state and tool results stay verbatim.

struct CaptureView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Submit-in — bring content into the MOOT as a verbatim drawer."))
                    .font(.title3.weight(.semibold))

                GroupBox(String(localized: "Content")) {
                    TextEditor(text: $model.captureContent)
                        .font(.body.monospaced())
                        .frame(height: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                }

                // Flexible widths so the row fits both a wide macOS window and a
                // narrow iPhone without overflowing the leading edge.
                VStack(spacing: 12) {
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Location (room)")).font(.caption).foregroundStyle(.secondary)
                            TextField(String(localized: "location"), text: $model.captureLocation)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Sensitivity")).font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $model.captureSensitivity) {
                                // Adjective raw values — substrate vocabulary, not display copy.
                                ForEach(model.sensitivityOptions, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                    HStack {
                        Spacer()
                        Button {
                            Task { await model.doCapture() }
                        } label: {
                            Label(String(localized: "Capture"), systemImage: "tray.and.arrow.down")
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.bridge == nil)
                    }
                }

                Label {
                    Text(String(localized: "No exportability control here — CaptureFrame has no exportability slot and MutationKind has no set-public case. Drawers are captured private; see the Edges tab."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                CallRecordView(title: String(localized: "moot_file_memory result"), call: model.lastCaptureCall)
            }
            .padding(20)
        }
    }
}
