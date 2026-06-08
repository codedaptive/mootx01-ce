import SwiftUI
import MootGateway

// MARK: - EdgesView
//
// The honest seam readout — the concrete shape of the gateway. Adapter status
// (A1–A6: live / seam / shell with the "why"), the concrete edges discovered
// only by wiring it, and the database path for the cross-process demo (point
// a real aria-mcp at the same SQLite file and watch an external client hit
// the same drawers — the A2 transport gap made felt).
//
// Display chrome via String(localized:); adapter/finding data and the command
// string are content and stay verbatim.

struct EdgesView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Where the edges are")).font(.title3.weight(.semibold))

                adapterBoard
                crossProcess
                findings
            }
            .padding(20)
        }
    }

    private var adapterBoard: some View {
        GroupBox(String(localized: "Adapter status")) {
            VStack(spacing: 0) {
                ForEach(GatewayEdges.adapters) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.code)   // "A1".."A6" — identifier, verbatim
                            .font(.callout.monospaced().weight(.bold))
                            .frame(width: 32, alignment: .leading)
                        stateBadge(row.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.callout.weight(.semibold))
                            Text(row.why).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    if row.id != GatewayEdges.adapters.last?.id { Divider() }
                }
            }
            .padding(6)
        }
    }

    private func stateBadge(_ state: AdapterState) -> some View {
        // state.rawValue ("live"/"seam"/"shell") is substrate-side vocabulary
        // from MootGateway; surfaced verbatim as a status chip.
        let color: Color = {
            switch state {
            case .live: return .green
            case .seam: return .orange
            case .shell: return .blue
            }
        }()
        return Text(state.rawValue)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .frame(width: 52)
    }

    private var crossProcess: some View {
        GroupBox(String(localized: "Cross-process demo (the A2 transport gap, felt)")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "This estate is a SQLite file. Point a real aria-mcp at the same file and an external MCP client (Claude Code) sees the same drawers — proving the substrate is shared while there is no live network transport in this app."))
                    .font(.caption).foregroundStyle(.secondary)
                if let path = model.databasePath {
                    HStack(spacing: 8) {
                        Text(commandText(path))   // shell command — verbatim, copyable
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gatewayEditorField)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Button {
                            gatewayCopyToPasteboard(commandText(path))
                        } label: { Image(systemName: "doc.on.doc") }
                            .help(String(localized: "Copy command"))
                            .accessibilityLabel(String(localized: "Copy command"))
                    }
                } else {
                    Text(String(localized: "In-memory estate — nothing on disk to share. A durable SQLite estate is created under Application Support on attach."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private func commandText(_ path: String) -> String {
        "ARIA_MCP_SQLITE_PATH=\(path) \\\n  swift run --package-path apps/ARIA_MCP aria-mcp"
    }

    private var findings: some View {
        GroupBox(String(localized: "Edges discovered by wiring it")) {
            VStack(spacing: 0) {
                ForEach(GatewayEdges.findings) { finding in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(finding.title, systemImage: "scissors")   // finding data — verbatim
                            .font(.callout.weight(.semibold))
                        Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    if finding.id != GatewayEdges.findings.last?.id { Divider() }
                }
            }
            .padding(6)
        }
    }
}
