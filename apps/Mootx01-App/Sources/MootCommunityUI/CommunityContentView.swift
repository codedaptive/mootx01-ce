import MootCommunityGateway
import SwiftUI

private enum CommunityDestination: String, CaseIterable, Identifiable {
    case capture = "Capture"
    case recall = "Recall"
    case operations = "Operations"
    case engine = "Engine"

    var id: String { rawValue }
    var accessibilityIdentifier: String {
        "community.destination.\(rawValue.lowercased())"
    }
    var symbol: String {
        switch self {
        case .capture: "tray.and.arrow.down"
        case .recall: "tray.and.arrow.up"
        case .operations: "square.grid.2x2"
        case .engine: "cpu"
        }
    }
}

/// The open macOS product surface. Its type lives in a Community-only module.
public struct CommunityContentView: View {
    @Bindable private var model: CommunityAppModel
    @State private var selection: CommunityDestination? = .capture

    public init(model: CommunityAppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            List(CommunityDestination.allCases, selection: $selection) { destination in
                Label(String(localized: String.LocalizationValue(destination.rawValue)),
                      systemImage: destination.symbol)
                    .tag(destination)
                    .accessibilityIdentifier(destination.accessibilityIdentifier)
            }
            .navigationTitle(String(localized: "MOOTx01 Community"))
        } detail: {
            Group {
                if model.isEstateReady {
                    destinationView(selection ?? .capture)
                } else {
                    daemonUnavailableView
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    if model.isEstateReady {
                        Button { selection = .capture } label: {
                            Image(systemName: "plus")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(Color.accentColor, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Capture"))
                        .padding(20)
                    }
                }
        }
        .onChange(of: model.setupModel.state) { _, state in
            if case .ready = state {
                Task { await model.setupBecameReady() }
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: CommunityDestination) -> some View {
        switch destination {
        case .capture: captureView
        case .recall: recallView
        case .operations:
            CommunityOperationsWorkspaceView(workspaceModel: model.operationsWorkspaceModel)
        case .engine: engineView
        }
    }

    private var captureView: some View {
        CommunityCaptureView(model: model.captureModel)
        .navigationTitle(String(localized: "Capture"))
    }

    private var recallView: some View {
        Form {
            TextField(String(localized: "Search your estate"), text: $model.recallQuery)
                .onSubmit { Task { await model.recall() } }
            Button(String(localized: "Recall")) { Task { await model.recall() } }
            ScrollView { Text(model.recallResult).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Recall"))
    }

    private var engineView: some View {
        Form {
            LabeledContent(String(localized: "Resident daemon"), value: model.status)
            if let token = model.estateIdentity?.displayToken {
                Text(token).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button(String(localized: "Reconnect")) { Task { await model.start() } }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Engine"))
    }

    private var daemonUnavailableView: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.status, systemImage: "externaldrive.badge.exclamationmark")
                Spacer()
                Button(String(localized: "Try Again")) { Task { await model.start() } }
            }
            .padding()
            Divider()
            CommunitySetupView(model: model.setupModel)
        }
        .accessibilityElement(children: .contain)
    }
}
