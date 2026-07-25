import SwiftUI
import MootGateway

// MARK: - ContentView (FAB5-FR)
//
// Profile-driven tab shell shared by macOS and iOS. Two tab profiles:
//
//   Standard (default): Capture, Recall, Review, Intelligence, Settings.
//   Advanced: Standard + The Top, Apple Surfaces, Edges, Engine, Federation, Miners, Packets.
//
// On first launch (hasCompletedOnboarding == false) the onboarding flow is
// shown as a fullScreenCover. Once dismissed it never appears again.
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
                // Standard profile — always visible
                Tab(String(localized: "Capture"), systemImage: "tray.and.arrow.down") {
                    CaptureView(model: model)
                }
                Tab(String(localized: "Recall"), systemImage: "tray.and.arrow.up") {
                    RecallView(model: model)
                }
                // FAB5-G2: the Review Center — Dashboard, Morning, End-of-Day, and
                // Weekly reviews over FAB5-G1's ReviewReports. Kong ruling: third
                // in the Standard profile (capture, then recall, then review what
                // the estate surfaced), SF Symbol "checklist".
                Tab(String(localized: "Review"), systemImage: "checklist") {
                    ReviewCenterView(model: model)
                }
                Tab(String(localized: "Intelligence"), systemImage: "brain.head.profile") {
                    IntelligenceView()
                }
                Tab(String(localized: "Settings"), systemImage: "gear") {
                    AdvancedModeToggleView(model: model)
                }

                // Advanced-only tabs — hidden in Standard profile
                if model.isAdvancedMode {
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
                    // FED-OD-6: Federation panel — discover, pair, and start on-demand sessions.
                    // Visibility default is Off; users opt in explicitly (AirDrop-style).
                    Tab(String(localized: "Federation"), systemImage: "person.2.wave.2") {
                        FederationPanelView()
                    }
                    // M-ING-2: per-source mining consent/config. Sources ship
                    // disabled; enabling arms them — the consent prompt fires on
                    // the first actual read, never from this view.
                    Tab(String(localized: "Miners"), systemImage: "square.and.arrow.down.on.square") {
                        MinerSettingsView()
                    }
                    // FAB5-I3: work-packet list, detail, and lineage trace views.
                    // Kong ruling: Advanced-only tab, after Miners, SF Symbol "shippingbox".
                    // Production wiring: pass a WorkPacketStore.list closure to PacketListView;
                    // see docs/guide/THREE_MINDS_ONE_MEMORY.md for the full demo setup.
                    Tab(String(localized: "Packets"), systemImage: "shippingbox") {
                        PacketListView()
                    }
                }
            }
            Divider()
            statusBar
        }
        // First-run onboarding overlay — dismissed once, never shown again.
        // iOS: fullScreenCover for immersive first-run (hides tab bar).
        // macOS: sheet (fullScreenCover unavailable on macOS).
        // interactiveDismissDisabled prevents the iOS pull-down gesture from
        // snap-back-dismissing the cover with set:{_ in}, which would leave
        // hasCompletedOnboarding false and immediately re-present the cover.
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { !model.hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView(model: model)
                .interactiveDismissDisabled(true)
        }
        #else
        .sheet(isPresented: Binding(
            get: { !model.hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView(model: model)
                .interactiveDismissDisabled(true)
        }
        #endif
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
