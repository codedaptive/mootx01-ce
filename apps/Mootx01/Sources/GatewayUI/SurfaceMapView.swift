import SwiftUI
import MootGateway

// MARK: - SurfaceMapView  ("The Top")
//
// The ARIA contract as a caller sees it: one noun, nine verbs (caller-driven
// vs Brain-emitted), four adjectives, and the live `moot_*` tool surface from
// tools/list with each tool's input schema. This is exactly what Siri, a
// Shortcut, or Claude would discover — the top-level communication surface.
//
// Display chrome via String(localized:); lexicon/tool data (verb names, notes,
// tool names, schemas, adjective values) is content and stays verbatim.

struct SurfaceMapView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                contractHeader
                verbTable
                adjectiveTable
                Divider()
                toolSurface
            }
            .padding(20)
        }
    }

    private var contractHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "The ARIA contract")).font(.title3.weight(.semibold))
            Text(String(localized: "One noun · nine verbs · four adjectives. Every call is one verb applied to the noun, optionally constrained by adjectives."))
                .font(.callout).foregroundStyle(.secondary)
            Label(String(localized: "Noun: Drawer — the atomic unit of memory (one verbatim capture)."), systemImage: "doc.text")
                .font(.callout).padding(.top, 2)
        }
    }

    private var verbTable: some View {
        GroupBox(String(localized: "Nine verbs")) {
            VStack(spacing: 0) {
                ForEach(LexiconMap.verbs) { verb in
                    HStack(alignment: .top, spacing: 10) {
                        Text(verb.verb)   // lexicon vocabulary — verbatim
                            .font(.callout.monospaced().weight(.semibold))
                            .frame(width: 92, alignment: .leading)
                        flowBadge(verb.flow)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if let tool = verb.mootTool {
                                    Text(tool).font(.caption.monospaced()).foregroundStyle(.blue)
                                } else {
                                    Text(String(localized: "no tool")).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(verb.direction.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(verb.note).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    if verb.id != LexiconMap.verbs.last?.id { Divider() }
                }
            }
            .padding(6)
        }
    }

    private func flowBadge(_ flow: VerbFlow) -> some View {
        let (text, color): (String, Color) = {
            switch flow {
            case .callerDriven: return (String(localized: "caller"), .green)
            case .brainEmitted: return (String(localized: "brain"), .purple)
            case .groundingDriven: return (String(localized: "ground"), .teal)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .frame(width: 64)
    }

    private var adjectiveTable: some View {
        GroupBox(String(localized: "Four adjectives")) {
            VStack(spacing: 0) {
                ForEach(LexiconMap.adjectives) { adj in
                    HStack(alignment: .top, spacing: 10) {
                        Text(adj.axis)   // adjective axis name — verbatim
                            .font(.callout.monospaced().weight(.semibold))
                            .frame(width: 110, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(adj.values.joined(separator: " · "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(adj.appleRole).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    if adj.id != LexiconMap.adjectives.last?.id { Divider() }
                }
            }
            .padding(6)
        }
    }

    private var toolSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Live tool surface")).font(.title3.weight(.semibold))
                Spacer()
                Text(String(localized: "\(model.tools.count) tools"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(String(localized: "From tools/list against the attached estate — what an MCP client discovers."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.toolGroups, id: \.0) { group, items in
                // group is a data-derived category; the count is interpolated
                // into a localizable format.
                GroupBox(String(localized: "\(group) · \(items.count)")) {
                    VStack(spacing: 0) {
                        ForEach(items) { tool in
                            DisclosureGroup {
                                Text(tool.schemaPretty)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.name).font(.caption.monospaced().weight(.semibold))
                                    Text(tool.description).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }
}
