import SwiftUI
import WorkPacketKit

// MARK: - LineageView (FAB5-I3)
//
// Breadth-first lineage trace from a root packet outward to its antecedents.
// Antecedents are displayed in traversal order (nearest first) using the
// supplied `loadAntecedents` closure — the same closure passed through from
// PacketDetailView.
//
// When `rootDrawerID` is empty (e.g. the packet was not stored through
// WorkPacketStore and no estate drawer ID is known), lineage loading is
// skipped and the view shows an empty antecedent section immediately.
//
// Production wiring passes a LineageGraph.antecedents closure:
//
//   let graph = LineageGraph(client: EstateAdapter(estate))
//   LineageView(rootPacket: p, rootDrawerID: drawerID) { id in
//       try await graph.antecedents(of: id)
//   }

public struct LineageView: View {
    let rootPacket: WorkPacket
    let rootDrawerID: String
    let loadAntecedents: @Sendable (String) async throws -> [WorkPacket]

    @State private var antecedents: [WorkPacket] = []
    @State private var isLoading = false
    @State private var loadError: String?

    public init(
        rootPacket: WorkPacket,
        rootDrawerID: String = "",
        loadAntecedents: @escaping @Sendable (String) async throws -> [WorkPacket] = { _ in [] }
    ) {
        self.rootPacket = rootPacket
        self.rootDrawerID = rootDrawerID
        self.loadAntecedents = loadAntecedents
    }

    public var body: some View {
        List {
            // Root packet — always shown at the top of the trace
            Section(String(localized: "Root Packet")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rootPacket.objective)
                        .font(.body)
                        .textSelection(.enabled)
                    Text(rootPacket.provenance.agent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Antecedents — loaded lazily; empty-state shown while loading or
            // when the estate returns nothing.
            Section(String(localized: "Antecedents")) {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text(String(localized: "Tracing lineage"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = loadError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                } else if antecedents.isEmpty {
                    Text(String(localized: "No antecedents found."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(antecedents.enumerated()), id: \.element.id) { index, packet in
                        antecedentRow(packet: packet, hop: index + 1)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Lineage"))
        .task { await traceLineage() }
    }

    // One antecedent row: hop number, objective, agent, link kind badge.
    @ViewBuilder
    private func antecedentRow(packet: WorkPacket, hop: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(String(localized: "Hop"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(hop)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(packet.objective)
                .font(.body)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(packet.provenance.agent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Show the link kind from the root or intermediate packet's
                // first lineage link (the one that points to this antecedent).
                // The kind is stored on the CHILD packet's lineageLinks list;
                // antecedents() returns decoded parents so we cannot reconstruct
                // the kind cheaply here — show the packet's own outgoing link
                // kind as a proxy when present.
                if let firstLink = packet.lineageLinks.first {
                    Text(firstLink.kind.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(firstLink.kind == .derivesFrom ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }

    @MainActor
    private func traceLineage() async {
        guard !rootDrawerID.isEmpty else { return }
        isLoading = true
        loadError = nil
        do {
            antecedents = try await loadAntecedents(rootDrawerID)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
