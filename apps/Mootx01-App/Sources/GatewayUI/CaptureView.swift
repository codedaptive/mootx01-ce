import SwiftUI

// MARK: - CaptureView  (verb: capture · A4b submit-in · WRITE)
//
// Type content, pick a location, sensitivity, and exportability, then file the
// content as a verbatim drawer through moot_file_memory — the exact tool a
// Share Sheet or a Siri capture would call.
//
// Exportability: private (default) or public. A "public" drawer is returned by
// filter:exportable recall (the §6.2 serve-out gate); a "private" drawer is
// never surfaced that way. The moot_update_memory correctExportability(public)
// mutation can promote an existing private drawer to public post-capture.
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
                            // accessibilityLabel so VoiceOver identifies this Picker by name
                            // rather than reading only the current value. The sibling Text label
                            // is visual only; the Picker needs the association explicitly.
                            .accessibilityLabel(String(localized: "Sensitivity"))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Exportability")).font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $model.captureExportability) {
                                // Adjective raw values — "private" or "public" map directly to the
                                // moot_file_memory exportability argument and the §6.2 serve-out gate.
                                ForEach(model.exportabilityOptions, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            // accessibilityLabel so VoiceOver identifies this Picker as
                            // "Exportability" rather than reading only "private" or "public".
                            // Fixes WCAG 1.3.1: the programmatic relationship between the visual
                            // caption and the control must be machine-determinable.
                            .accessibilityLabel(String(localized: "Exportability"))
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
                    Text(String(localized: "Set Exportability to \"public\" to include this drawer in serve-out (filter:exportable recall). Private drawers are never surfaced by the serve-out gate. Use moot_update_memory correctExportability(public) to promote an existing private drawer."))
                } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                CallRecordView(title: String(localized: "moot_file_memory result"), call: model.lastCaptureCall)
            }
            .padding(20)
        }
    }
}
