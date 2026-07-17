import SwiftUI
import MootGateway

// MARK: - Miner settings  (M-ING-2 — consent/config surface)
//
// Per-source configuration for the platform miners: enable toggle and cadence
// (D7: user-configurable daily/weekly/manual). Sources ship DISABLED
// until the user turns them on; enabling arms the source but the FIRST LIVE
// READ (and its TCC consent prompt) only happens when a mining run actually
// fires — never from merely rendering this view.
//
// Settings persist in UserDefaults under miner.<sourceID>.* keys. This is
// app-level configuration, not entity state (no bitmap rules apply).

/// One source's persisted configuration.
public struct MinerSourceConfig: Sendable, Equatable {
    public let sourceID: String
    public var enabled: Bool
    public var wing: String
    public var room: String
    public var cadence: MiningCadence

    public init(sourceID: String, enabled: Bool = false,
                wing: String = "Personal Life", room: String,
                cadence: MiningCadence = .daily) {
        self.sourceID = sourceID
        self.enabled = enabled
        self.wing = wing
        self.room = room
        self.cadence = cadence
    }

    static func key(_ sourceID: String, _ field: String) -> String {
        "miner.\(sourceID).\(field)"
    }

    /// Load from defaults; absent keys yield the shipped defaults
    /// (disabled, "Personal Life", per-source room, daily).
    public static func load(sourceID: String, room: String,
                            defaults: UserDefaults = .standard) -> MinerSourceConfig {
        MinerSourceConfig(
            sourceID: sourceID,
            enabled: defaults.bool(forKey: key(sourceID, "enabled")),
            wing: defaults.string(forKey: key(sourceID, "wing")) ?? "Personal Life",
            room: defaults.string(forKey: key(sourceID, "room")) ?? room,
            cadence: MiningCadence(
                rawValue: defaults.string(forKey: key(sourceID, "cadence")) ?? ""
            ) ?? .daily
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.key(sourceID, "enabled"))
        defaults.set(wing, forKey: Self.key(sourceID, "wing"))
        defaults.set(room, forKey: Self.key(sourceID, "room"))
        defaults.set(cadence.rawValue, forKey: Self.key(sourceID, "cadence"))
    }
}

/// Settings form for the two shipping sources (health joins on the iOS leg).
public struct MinerSettingsView: View {
    @State private var calendar = MinerSourceConfig.load(sourceID: "calendar", room: "calendar")
    @State private var birthdays = MinerSourceConfig.load(sourceID: "birthdays", room: "birthdays")
    @State private var runningSources: Set<String> = []
    @State private var sourceStatus: [String: String] = [:]

    public init() {}

    public var body: some View {
        Form {
            sourceSection(
                title: String(localized: "miner.calendar.title", defaultValue: "Calendar"),
                note: String(localized: "miner.calendar.note",
                             defaultValue: "Files upcoming events as facts. Asks for calendar access on the first run."),
                sourceID: "calendar",
                config: $calendar
            )
            sourceSection(
                title: String(localized: "miner.birthdays.title", defaultValue: "Birthdays"),
                note: String(localized: "miner.birthdays.note",
                             defaultValue: "Files contact birthdays as facts. Asks for contacts access on the first run."),
                sourceID: "birthdays",
                config: $birthdays
            )
        }
        .formStyle(.grouped)
        .onChange(of: calendar) { _, new in new.save() }
        .onChange(of: birthdays) { _, new in new.save() }
    }

    @ViewBuilder
    private func sourceSection(title: String, note: String, sourceID: String,
                               config: Binding<MinerSourceConfig>) -> some View {
        Section {
            Toggle(title, isOn: config.enabled)
            if config.wrappedValue.enabled {
                Picker(String(localized: "miner.cadence", defaultValue: "Cadence"),
                       selection: config.cadence) {
                    Text(String(localized: "miner.cadence.daily", defaultValue: "Daily"))
                        .tag(MiningCadence.daily)
                    Text(String(localized: "miner.cadence.weekly", defaultValue: "Weekly"))
                        .tag(MiningCadence.weekly)
                    Text(String(localized: "miner.cadence.manual", defaultValue: "Manual only"))
                        .tag(MiningCadence.manual)
                }
                Button {
                    Task { await mineNow(sourceID: sourceID) }
                } label: {
                    Label(
                        runningSources.contains(sourceID)
                            ? String(localized: "miner.running", defaultValue: "Mining")
                            : String(localized: "miner.now", defaultValue: "Mine Now"),
                        systemImage: "play.fill"
                    )
                }
                .disabled(runningSources.contains(sourceID))
                if let status = sourceStatus[sourceID] {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(note)
        }
    }

    @MainActor
    private func mineNow(sourceID: String) async {
        runningSources.insert(sourceID)
        defer { runningSources.remove(sourceID) }
        do {
            let caller = try await GatewayRuntime.shared.bridge()
            let loop = MinerRunLoop.liveLoop()
            let summary = await loop.runNow(sourceID: sourceID, now: Date(), caller: caller)
            if let summary {
                sourceStatus[sourceID] = String(
                    localized: "miner.complete",
                    defaultValue: "Filed \(summary.result.filed), updated the current source snapshot."
                )
            } else {
                let state = loop.lastStatus(for: sourceID) ?? "unavailable"
                sourceStatus[sourceID] = String(
                    localized: "miner.unavailable",
                    defaultValue: "Mining did not run (\(state))."
                )
            }
        } catch {
            sourceStatus[sourceID] = error.localizedDescription
        }
    }
}
