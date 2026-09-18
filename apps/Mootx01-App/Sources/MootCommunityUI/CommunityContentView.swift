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
            recallOutcomeView
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Recall"))
    }

    /// The Recall pane's decoded outcome (census com.recall.result R-C6,
    /// com.recall.empty R-C7): recalled records render as a human list, zero
    /// results as an explicit empty state, and the verbatim wire reply only
    /// ever appears behind the labeled disclosure below.
    @ViewBuilder
    private var recallOutcomeView: some View {
        switch model.recallOutcome {
        case .idle:
            // Nothing searched yet — no fabricated state.
            EmptyView()
        case .results(let items, let reply):
            Section {
                ForEach(items) { item in recallResultRow(item) }
            }
            recallReplyDisclosure(reply)
        case .empty(let reply):
            Section {
                Text(String(localized: "recall.empty"))
                    .foregroundStyle(.secondary)
            }
            recallReplyDisclosure(reply)
        case .unstructured(let reply):
            // The reply carried no decodable structured rows: say so, and
            // show the labeled verbatim reply rather than guessed structure.
            Section {
                Text(String(localized: "recall.unstructured"))
                    .foregroundStyle(.secondary)
            }
            recallReplyDisclosure(reply)
        case .failed(let reply):
            Section {
                Text(String(localized: "recall.failed"))
            }
            recallReplyDisclosure(reply)
        }
    }

    /// One recalled record: subject (or honest fallback) as the primary name,
    /// body excerpt, then room and filed date as secondary captions.
    private func recallResultRow(_ item: CommunityRecallResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayTitle)
                .font(.headline)
            if let content = item.content, content != item.displayTitle {
                Text(content)
                    .lineLimit(3)
            }
            HStack(spacing: 12) {
                if let room = item.room {
                    Text(String(localized: "recall.result.room \(room)"))
                }
                if let recordedAt = item.recordedAt {
                    Text(Self.recallDateFormatter.string(from: recordedAt))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    /// The verbatim wire reply, demoted to an explicitly labeled, copyable
    /// disclosure — never the pane's primary content (R-C6).
    private func recallReplyDisclosure(_ reply: String) -> some View {
        Section {
            DisclosureGroup(String(localized: "recall.reply.title")) {
                Text(reply)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Locale-aware rendering for a recalled record's filed instant.
    private static let recallDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var engineView: some View {
        Form {
            LabeledContent(String(localized: "Resident daemon"), value: model.status)
            // Estate identity token — labeled so the reader knows what the
            // identifier is; stays copyable and secondary
            // (CommunityEngineIdentityDisplay, census com.engine.identity-token, R-C8).
            if let token = model.estateIdentity?.displayToken {
                LabeledContent(CommunityEngineIdentityDisplay.tokenLabel) {
                    Text(token).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Button(String(localized: "Reconnect")) { Task { await model.start() } }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Engine"))
    }

    private var daemonUnavailableView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label(model.status, systemImage: "externaldrive.badge.exclamationmark")
                    // Blocked states keep the exact machine reason code as a
                    // labeled, selectable detail under the human status (R-C1).
                    if let detail = model.statusTechnicalDetail {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
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

// MARK: - CommunityEngineIdentityDisplay

/// Presentation seam for the Engine form's estate identity token (census
/// com.engine.identity-token, R-C8): the token is a technical identifier, so
/// it renders labeled, copyable, and secondary — never bare.
enum CommunityEngineIdentityDisplay {
    /// The label naming what the identity token is.
    static var tokenLabel: String { String(localized: "Estate identity") }
}
