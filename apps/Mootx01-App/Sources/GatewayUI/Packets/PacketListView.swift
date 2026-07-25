import SwiftUI
import WorkPacketKit

// MARK: - PacketListView (FAB5-I3)
//
// Lists work packets filed in the estate. Tapping a row pushes PacketDetailView.
// Empty-state placeholder shows when no packets are present.
//
// Accepts a packet provider closure so the view can be exercised without a live
// estate client in tests. The default closure returns [] (empty list). Production
// callers pass a WorkPacketStore.list wrapper:
//
//   let store = WorkPacketStore(client: EstateAdapter(estate))
//   PacketListView { try await store.list() }
//
// Kong ruling (FAB5-I3): Advanced-only tab in ContentView, SF Symbol "shippingbox",
// after the Miners tab. Records the nav ruling per Known Ambiguity resolution.

public struct PacketListView: View {
    let loadPackets: @Sendable () async throws -> [WorkPacket]

    @State private var packets: [WorkPacket] = []
    @State private var isLoading = false
    @State private var loadError: String?

    public init(loadPackets: @escaping @Sendable () async throws -> [WorkPacket] = { [] }) {
        self.loadPackets = loadPackets
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "Loading packets"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = loadError {
                    VStack(spacing: 8) {
                        // Orange = retryable warning (not hard error); Refresh button is available.
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if packets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "No work packets"))
                            .font(.headline)
                        Text(String(localized: "Work packets filed by AI agents appear here."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(packets, id: \.id) { packet in
                        NavigationLink(destination: PacketDetailView(packet: packet)) {
                            PacketRowView(packet: packet)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Packets"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        .frame(maxWidth: UIAdaptivity.readableContentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .task { await reload() }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            packets = try await loadPackets()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - PacketRowView

// One row in the packet list: objective (truncated) + agent and model metadata.
struct PacketRowView: View {
    let packet: WorkPacket

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(packet.objective)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(packet.provenance.agent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(packet.provenance.model)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
