import SwiftUI
import MootGateway

// MARK: - ContentView
//
// The five-tab shell, shared by the macOS executable and the iOS app. Each tab
// makes one face of the gateway tangible: Capture (write-in), Recall
// (serve-out + export policy), The Top (the ARIA contract a caller sees),
// Apple Surfaces (the adapter shells, run live), and Edges (the seam readout).
//
// All user-visible chrome goes through String(localized:) per
// docs/engineering/LOCALIZATION_GUIDE.md (English-as-key, no catalog ships).
// Model-driven Text (results, wire JSON, mapping data) is content, not display
// literals, and stays verbatim.

public struct ContentView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabView {
                Tab(String(localized: "Capture"), systemImage: "tray.and.arrow.down") {
                    CaptureView(model: model)
                }
                Tab(String(localized: "Recall"), systemImage: "tray.and.arrow.up") {
                    RecallView(model: model)
                }
                Tab(String(localized: "The Top"), systemImage: "list.bullet.rectangle") {
                    SurfaceMapView(model: model)
                }
                Tab(String(localized: "Apple Surfaces"), systemImage: "apple.logo") {
                    AppleSurfacesView(model: model)
                }
                Tab(String(localized: "Edges"), systemImage: "exclamationmark.triangle") {
                    EdgesView(model: model)
                }
                Tab(String(localized: "Engine"), systemImage: "cpu") {
                    EngineView(model: model)
                }
            }
            Divider()
            statusBar
        }
        // A5: route inbound mootx01://x-callback-url/<verb>?… through MootURLRouter.
        // The verb allowlist (capture/recall/reanchor only) and the empty callback-scheme
        // allowlist (host never auto-opens return URLs) are enforced in the router.
        .onOpenURL { url in
            Task { await model.handleOpenURL(url) }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.bridge == nil ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            // model.statusLine is runtime data, not a display literal.
            Text(model.statusLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Shared call-record view
//
// Renders a GatewayCall as request/response JSON side by side with the
// flattened result — the "see the wire" panel reused across tabs. `title` is
// localized by the caller.
struct CallRecordView: View {
    let title: String
    let call: GatewayCall?

    var body: some View {
        GroupBox(title) {
            if let call {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: call.isError ? "xmark.octagon.fill" : "checkmark.seal.fill")
                            .foregroundStyle(call.isError ? .red : .green)
                        Text(call.isError ? String(localized: "substrate refused") : String(localized: "ok"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(call.isError ? .red : .green)
                    }
                    Text(call.text.isEmpty ? String(localized: "(no text content)") : call.text)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureGroup(String(localized: "JSON-RPC wire")) {
                        VStack(alignment: .leading, spacing: 10) {
                            wirePane(String(localized: "request →"), call.requestJSON)
                            wirePane(String(localized: "← response"), call.responseJSON)
                        }
                    }
                    .font(.caption)
                }
                .padding(6)
            } else {
                Text(String(localized: "No call yet."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        }
    }

    private func wirePane(_ label: String, _ json: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(json)   // rendered wire JSON — data, not a display literal
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .background(Color.gatewayEditorField)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
