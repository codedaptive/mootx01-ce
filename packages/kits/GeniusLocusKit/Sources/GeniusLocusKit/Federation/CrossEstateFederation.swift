import Foundation
import OSLog
import LocusKit

/// Grant-gated cross-estate federated read on `GeniusLocusKit`.
///
/// This is the grant-gated sibling of `CrossEstateRead.fanOutRecall`.
/// Where the lattice fan-out routes a read to every locally-open estate
/// whose zoom window overlaps a region and performs **no** grant check,
/// `federatedRecall` reads from exactly one source estate and refuses
/// unless that source holds an active, unexpired grant naming the
/// requester as grantee.
///
/// ## I-13 boundary (this layer does not federate over a wire)
///
/// Spec invariant I-13: federation is not a substrate concern; the
/// substrate does not communicate with other substrates. "Federated
/// read" **at this composition layer** means strictly local: both the
/// source and the requester are estates already `open` in the same kit
/// instance (both live in `registry`). This file opens no network
/// connection, no socket, performs no handshake, and does not "join" a
/// remote substrate. Crossing the device/process boundary is
/// `MCP-MULTI-01`'s job in ARIA_MCP, a separate access surface that
/// calls into this gate. Any API shaped like `federateWith(remoteHandle:)`
/// would be an I-13 violation and is deliberately absent here.
///
/// ## What is enforced and what is not
///
/// Enforced: grant **existence, validity, and grantee match** — the
/// binary "may the requester read the source at all" gate, fail-closed.
/// This is the executable form of the A-versus-C refusal
/// (DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §13, cookbook I-23):
/// B answers A only from B-authored or B-to-A-granted content; absent a
/// grant, the read is refused, not silently empty.
///
/// Not enforced here: per-scope row filtering (returning only rows
/// inside the granted wing/room/lattice subtree). The row→scope mapping
/// is an ARIA-surface answer-assembly concern (§10), left to
/// `MCP-MULTI-01`. `grant.scope` rides back on the result as advisory
/// metadata; it does not narrow the returned rows at this layer.
public extension GeniusLocusKit {

    private static var federationLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    /// Read content from `source` on behalf of `requester`, gated by the
    /// source estate's grant store.
    ///
    /// Behavior, in order, fail-closed:
    ///
    /// 1. Resolve both handles. A stale handle (either side) throws
    ///    `.estateNotOpen`.
    /// 2. Build/fetch the **source** estate's grant surface.
    /// 3. From the source's active grants, keep those whose
    ///    `granteeEstateID` equals the requester's estate UUID. If none,
    ///    throw `.crossEstateReadRefused(reason: .noActiveGrant)`. (A
    ///    revoked grant has already been dropped from `active()`, so a
    ///    read after revocation lands here.)
    /// 4. Among the matching grants, require at least one unexpired at
    ///    `now` (`lifetime.expiry(issuedAt:)` is `nil` for a permanent
    ///    grant, or strictly in the future). If every matching grant is
    ///    expired, throw `.crossEstateReadRefused(reason: .grantExpired)`.
    /// 5. Only with a valid grant in hand: run `frame` through the source
    ///    estate's `recall`, draining the `RecallStream` fully, and
    ///    return the drawers plus the authorizing grant.
    ///
    /// The grantee-scoped lookup filters `active()` in Swift rather than
    /// querying the store by grantee: `GrantStore` exposes no
    /// grantee-scoped query, the estate count per device is tens (spec
    /// §4.10), and active-grant counts are small, so an in-memory filter
    /// is correct and cheap (Known Ambiguities §1).
    ///
    /// - Parameters:
    ///   - frame: the recall to run against the source estate.
    ///   - source: the estate whose content is being read (the grantor).
    ///   - requester: the estate requesting the read (must be the
    ///     grantee named on an active source grant).
    ///   - now: evaluation instant for grant expiry, supplied so the gate
    ///     is deterministic and testable. Defaults to the call-site time.
    /// - Returns: the source estate's drawers and the authorizing grant.
    /// - Throws: `.estateNotOpen` for a stale handle;
    ///   `.crossEstateReadRefused` when the grant gate refuses.
    func federatedRecall(
        _ frame: RecallFrame,
        from source: EstateHandle,
        requestedBy requester: EstateHandle,
        now: Date = Date()
    ) async throws -> FederatedRecallResult {
        // 1. Resolve both handles. Resolving the requester too (not just
        // the source) keeps the gate fail-closed: a read on behalf of a
        // closed/never-issued requester is refused as a stale-handle
        // fault rather than silently proceeding.
        let sourceEstate = try estate(for: source)
        _ = try estate(for: requester)

        // 2. The source estate's grant surface. Grants live in the
        // source's own storage; the gate consults the grantor's record,
        // never the requester's.
        let (store, _) = try await ensureGrantSurface(for: source)

        // 3. Grantee-scoped filter over active (non-revoked) grants.
        let matching = try await store.active().filter {
            $0.granteeEstateID == requester.estateUUID
        }
        guard !matching.isEmpty else {
            throw GeniusLocusKitError.crossEstateReadRefused(
                source: source.estateUUID,
                requester: requester.estateUUID,
                reason: .noActiveGrant
            )
        }

        // 4. Require at least one matching grant that is unexpired at
        // `now`. A grant is expired iff its expiry is strictly before
        // `now`, matching `GrantStore.expired(before:)`; a permanent
        // grant (nil expiry) is always valid.
        let authorizing = matching.first { grant in
            guard let expiry = grant.lifetime.expiry(issuedAt: grant.issuedAt) else {
                return true
            }
            return expiry >= now
        }
        guard let authorizingGrant = authorizing else {
            throw GeniusLocusKitError.crossEstateReadRefused(
                source: source.estateUUID,
                requester: requester.estateUUID,
                reason: .grantExpired
            )
        }

        // 5. Valid grant in hand: read the source estate. Drain the
        // RecallStream fully, the same way CrossEstateRead.fanOutRecall
        // does, so the caller receives the complete result set. The read
        // runs against the source estate alone, so only the source's rows
        // are returned — the requester's own content is never included.
        var drawers: [Drawer] = []
        let stream = await sourceEstate.recall(frame)
        for await page in stream {
            drawers.append(contentsOf: page.rows)
        }

        Self.federationLog.debug(
            "federatedRecall source=\(source.estateUUID, privacy: .public) requester=\(requester.estateUUID, privacy: .public) grant=\(authorizingGrant.id, privacy: .public) rows=\(drawers.count, privacy: .public)"
        )
        return FederatedRecallResult(
            drawers: drawers,
            grant: authorizingGrant,
            sourceHandle: source,
            requesterHandle: requester
        )
    }
}
