import Foundation
import GeniusLocusKit

/// A predicted-next memory: the target drawer id and how many tunnels
/// lead to it from the anchor.
public struct Successor: Sendable, Equatable, Codable {
    public let id: String
    public let weight: Int
    public init(id: String, weight: Int) {
        self.id = id
        self.weight = weight
    }
}

/// TunnelSuccessor — directed-tunnel successor prediction (prediction
/// lens, category 8). Given an anchor memory, follow its OUTGOING
/// tunnels (the directed association graph) and rank where they lead by
/// frequency — "this memory points onward to these."
///
/// This is NOT Anticipate. Anticipate is the LEARNED action-outcome /
/// temporal-causality model — "after you DO X you tend to NEED Y." This
/// recipe is the simpler, explicit-graph successor signal: what the
/// author linked downstream, not what behaviour tends to follow. Kept as
/// its own honest lens; named for what it actually computes.
///
/// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): a pure graph read over
/// GLK `recallTunnels` — it sequences no reasoning surface and implements
/// no algorithm beyond counting. Read-only — no estate write (B-6, I-6).
/// Swift version of `run_tunnel_successor`.
public enum TunnelSuccessor {

    /// Predict the memories most likely to follow `anchorID` in `wing`:
    /// rank the targets of its outgoing drawer-to-drawer tunnels by
    /// frequency, top `k` (ties broken by ascending id). A self-loop is
    /// not a successor. A recall-tunnels failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        wing: String,
        anchorID: String,
        k: Int
    ) async throws -> [Successor] {
        let tunnels = try await kit.recallTunnels(handle, wing: wing)

        var counts: [String: Int] = [:]
        for tunnel in tunnels
        where tunnel.sourceDrawerId == anchorID {
            guard let target = tunnel.targetDrawerId, target != anchorID else { continue }
            counts[target, default: 0] += 1
        }

        let ranked = counts
            .map { Successor(id: $0.key, weight: $0.value) }
            .sorted { a, b in
                if a.weight != b.weight { return a.weight > b.weight }
                return a.id < b.id   // ties by ascending id
            }
        return Array(ranked.prefix(k))
    }
}
