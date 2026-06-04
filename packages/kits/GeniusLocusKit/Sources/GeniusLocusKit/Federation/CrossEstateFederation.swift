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
/// Enforced: **content-level sensitivity gate** — drawers whose
/// `adjectiveSensitivity.rawValue` (bits 6–11 of `adjectiveBitmap`)
/// exceeds `grant.contentLevel` are excluded from the result before
/// it is returned. A default grant (`contentLevel: 0`) exposes only
/// normal-sensitivity rows; higher content levels progressively admit
/// elevated, restricted, and secret rows. This is the primary enforcer
/// per the architecture mandate: GLK is "one secure perimeter" and must
/// apply sensitivity filtering regardless of which caller invokes it.
///
/// Enforced: **per-scope subtree filtering** — drawers outside the
/// granted wing/room/lattice subtree/single row are excluded before the
/// result is returned. GLK is the primary enforcer; ARIA's scope
/// narrowing in `ToolDispatch` remains as defense-in-depth secondary.
///
/// Not enforced here (DEFERRED): `custodyMode` enforcement for the
/// recall path and `inferenceRemainingBudget` debit. Both fields exist
/// on `Grant` but no spec section defines their recall-path semantics;
/// enforcement stubs are absent rather than speculative. See Part 2
/// notes in GRANT_BOUNDARY_001 mission.
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
    ///    estate's `recall`, draining the `RecallStream` fully.
    /// 6. Apply the content-level sensitivity gate: exclude drawers whose
    ///    `adjectiveSensitivity.rawValue` exceeds `grant.contentLevel`.
    /// 7. Apply the scope subtree filter: exclude drawers outside the
    ///    granted wing/room/lattice subtree/single row, then return the
    ///    narrowed set plus the authorizing grant.
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
        // grant (nil expiry) is always valid. Among multiple valid
        // grants, select the one with the highest contentLevel — this
        // gives the requester the maximum access they are legitimately
        // entitled to and prevents a lower-level grant from shadowing a
        // higher-level one when both are active (Perkins A-2).
        let authorizing = matching
            .filter { grant in
                guard let expiry = grant.lifetime.expiry(issuedAt: grant.issuedAt) else {
                    return true
                }
                return expiry >= now
            }
            .max(by: { $0.contentLevel < $1.contentLevel })
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

        // 6. Content-level sensitivity gate. Exclude any drawer whose
        // sensitivity (bits 6–11 of adjectiveBitmap, scale-gapped at
        // 0/16/32/48 for normal/elevated/restricted/secret) exceeds the
        // grant's contentLevel. This is the GLK-layer primary enforcement:
        // callers that bypass ARIA still get sensitivity-narrowed results.
        // Default grant (contentLevel: 0) admits only normal-sensitivity
        // rows; callers issuing grants at higher contentLevel progressively
        // unlock elevated, restricted, and secret rows.
        let contentMax = authorizingGrant.contentLevel
        // Fail-open note (Perkins A-3): `Drawer.adjectiveSensitivity`
        // falls back to `.normal` (rawValue 0) for any bitmap value that
        // doesn't match a valid AdjectiveSensitivity case. A corrupt row
        // therefore passes this gate at contentLevel >= 0 (all grants).
        // This is the documented fail-open direction per Adjectives.swift
        // ("matching the estate-level default access posture"). The
        // trust boundary for bitmap integrity is DrawerStore/AuditGate,
        // not this filter.
        drawers = drawers.filter { $0.adjectiveSensitivity.rawValue <= contentMax }

        // 7. Scope subtree filter — GLK primary enforcement.
        // Runs after the content-level gate; the two filters compose so the
        // caller receives only rows that satisfy both sensitivity and scope.
        // .wholeEstate is a pass-through; the other four cases narrow to the
        // granted subtree. Drawer.id is String and GrantScope.singleRow
        // carries a UUID, so the comparison uses uuid.uuidString.
        // Drawer.udcCode is String (non-optional): empty string is the
        // "no anchor declared" sentinel (I-5) — hasPrefix returns false for
        // a non-empty prefix against an empty string, correctly excluding
        // anchor-less drawers from any lattice subtree grant.
        switch authorizingGrant.scope {
        case .wholeEstate:
            break
        case .wing(let name):
            drawers = drawers.filter { $0.wing == name }
        case .room(let name):
            drawers = drawers.filter { $0.room == name }
        case .latticeSubtree(let udcCode):
            // Dot-boundary guard: "500" must match "500" and "500.1" but NOT
            // "5001". Bare hasPrefix("500") would admit "5001" because "5001"
            // starts with "500". ARIA's ToolDispatch uses the same guard at
            // the secondary layer; GLK must match so direct callers are safe.
            drawers = drawers.filter {
                $0.udcCode == udcCode || $0.udcCode.hasPrefix(udcCode + ".")
            }
        case .singleRow(let uuid):
            drawers = drawers.filter { $0.id == uuid.uuidString }
        }

        // DEFERRED — custodyMode recall-path enforcement: grant.custodyMode
        // (mediated/handedOver/decayDerived/physicalDecay) governs key custody
        // at issue time (GENIUSLOCUSKIT_SPEC B-8) but no spec section defines
        // what the recall path should do based on custodyMode. In particular,
        // there is no spec-defined behavior for "block a recall when the mode
        // is X" or "modify results based on custodyMode." Enforcement stubs
        // are absent rather than speculative. When GENIUSLOCUSKIT_SPEC defines
        // recall-path custodyMode semantics, a guard should be inserted here.

        // DEFERRED — inferenceRemainingBudget debit: grant.inferenceRemainingBudget
        // is described as "the federation layer debits it as inference is spent"
        // (Grant.swift) but no spec section defines a debit protocol for the
        // basic recall path (what triggers a debit, by how much, and what happens
        // when the budget reaches zero). A floor guard and debit call should be
        // inserted here once GENIUSLOCUSKIT_SPEC § 6 defines these semantics.

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
