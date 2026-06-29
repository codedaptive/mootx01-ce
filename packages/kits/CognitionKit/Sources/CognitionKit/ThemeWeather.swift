import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// ThemeWeather — the conscious "what's rising, what's fading" recipe
/// (Lens 2, Topics). Recall a set, and for each room compare its
/// historical presence (raw count) to its recent attention
/// (decay-weighted mass by capture time) via NeuronKit `themeWeather` —
/// momentum, not just presence.
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — recall via
/// GLK + NeuronKit `recencyWeight`/`themeWeather` (SubstrateML decay).
/// Read-only (B-6, I-6). Swift version of `run_theme_weather`.
public enum ThemeWeather {

    /// Per-room momentum (heating positive, cooling negative), hottest
    /// first (ties by ascending room name). `halfLifeSeconds` sets how
    /// fast attention decays with age; `now` anchors the decay so the
    /// result is a deterministic function of the inputs. Read-only; a
    /// recall failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        frame: LocusKit.RecallFrame,
        halfLifeSeconds: Double,
        now: Date
    ) async throws -> [CategoryMomentum] {
        let drawers = try await kit.recall(handle, frame)

        var raw: [String: Double] = [:]
        var weighted: [String: Double] = [:]
        for drawer in drawers {
            let elapsed = max(now.timeIntervalSince(drawer.filedAt), 0)
            raw[drawer.parentNodeId, default: 0] += 1
            weighted[drawer.parentNodeId, default: 0] += NeuronKit.recencyWeight(
                elapsedSeconds: elapsed, halfLifeSeconds: halfLifeSeconds)
        }

        // Sorted parentNodeId keys ⇒ a deterministic category order
        // into the lens (same discipline as the Rust BTreeMap walk).
        let categories = raw.keys.sorted().map { nodeId in
            (category: nodeId, rawCount: raw[nodeId]!, weightedMass: weighted[nodeId] ?? 0)
        }
        return NeuronKit.themeWeather(categories: categories)
    }
}
