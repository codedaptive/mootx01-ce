import SwiftUI
import WorkPacketKit

// MARK: - PacketDetailView (FAB5-I3)
//
// Full detail for one work packet: objective, claims (with confidence),
// uncertainties, next steps, provenance, and a lineage navigation link.
//
// Accepts a `loadAntecedents` closure so LineageView can be driven from a
// real estate client or from test fixtures. The default closure returns []
// (empty antecedents). Production callers pass a LineageGraph.antecedents
// wrapper:
//
//   let graph = LineageGraph(client: EstateAdapter(estate))
//   PacketDetailView(packet: p, drawerID: id) { id in
//       try await graph.antecedents(of: id)
//   }

public struct PacketDetailView: View {
    let packet: WorkPacket
    let drawerID: String
    let loadAntecedents: @Sendable (String) async throws -> [WorkPacket]

    public init(
        packet: WorkPacket,
        drawerID: String = "",
        loadAntecedents: @escaping @Sendable (String) async throws -> [WorkPacket] = { _ in [] }
    ) {
        self.packet = packet
        self.drawerID = drawerID
        self.loadAntecedents = loadAntecedents
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Objective
                GroupBox(String(localized: "Objective")) {
                    Text(packet.objective)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }

                // Claims — each shown with confidence percentage
                if !packet.claims.isEmpty {
                    GroupBox(String(localized: "Claims")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(packet.claims, id: \.id) { claim in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(claim.confidence.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                    Text(claim.statement)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                // Uncertainties
                if !packet.uncertainties.isEmpty {
                    GroupBox(String(localized: "Uncertainties")) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(packet.uncertainties, id: \.self) { uncertainty in
                                Label {
                                    Text(uncertainty)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } icon: {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                // Next Steps
                if !packet.nextSteps.isEmpty {
                    GroupBox(String(localized: "Next Steps")) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(packet.nextSteps, id: \.self) { step in
                                Label {
                                    Text(step)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } icon: {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                // Provenance
                GroupBox(String(localized: "Provenance")) {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(String(localized: "Agent"), value: packet.provenance.agent)
                        LabeledContent(String(localized: "Model"), value: packet.provenance.model)
                    }
                    .padding(.top, 2)
                }

                // Lineage navigation — shown only when lineage links are present
                if !packet.lineageLinks.isEmpty {
                    NavigationLink(destination: LineageView(
                        rootPacket: packet,
                        rootDrawerID: drawerID,
                        loadAntecedents: loadAntecedents
                    )) {
                        Label(String(localized: "View Lineage"), systemImage: "arrow.triangle.branch")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .frame(maxWidth: UIAdaptivity.readableContentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .navigationTitle(String(localized: "Packet Detail"))
    }
}
