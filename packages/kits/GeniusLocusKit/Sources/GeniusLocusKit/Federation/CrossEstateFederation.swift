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
/// ## What is enforced
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
/// Enforced: **custodyMode gate** — each CustodyMode has distinct
/// recall-path semantics (documented inline and in the spec). Fail-closed
/// on modes that cannot be verified or are not yet implemented.
///
/// Enforced: **inferenceRemainingBudget debit** — each federated recall
/// debits the authorizing grant's budget by `FederatedRecallGate.budgetDebitPerRead`
/// (0.01 per read, ~100 reads on a full 1.0 allotment). A budget of 0.0
/// refuses the read. The debit is persisted atomically with the read so
/// concurrent reads cannot double-spend below zero.
public extension GeniusLocusKit {

    /// Per-read budget debit quantum.
    ///
    /// Spec §6 states "the federation layer debits [the budget] as inference
    /// is spent" but does not specify the debit amount. The fail-closed rule
    /// (as required when the spec is silent) is 0.01 per read, giving ~100
    /// reads on a full 1.0 budget. Grants whose budget is already 0.0 or
    /// below refuse all further reads.
    static let budgetDebitPerRead: Double = 0.01

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
    /// 2. Build/fetch the **source** estate's grant surface (store + vault).
    /// 3. From the source's active grants, keep those whose
    ///    `granteeEstateID` equals the requester's estate UUID. If none,
    ///    throw `.crossEstateReadRefused(reason: .noActiveGrant)`. (A
    ///    revoked grant has already been dropped from `active()`, so a
    ///    read after revocation lands here.)
    /// 4. Among the matching grants, require at least one unexpired at
    ///    `now` (`lifetime.expiry(issuedAt:)` is `nil` for a permanent
    ///    grant, or strictly in the future). If every matching grant is
    ///    expired, throw `.crossEstateReadRefused(reason: .grantExpired)`.
    /// 5. CustodyMode gate (per-mode semantics):
    ///    - `.mediated`: the source vault must hold the scope key for the
    ///      authorizing grant; if the vault has no key (estate restarted,
    ///      key never loaded), throw `.custodyRefused`.
    ///    - `.handedOver`: the key was handed to the recipient at issue;
    ///      offline reads are permitted within the grant window. No vault
    ///      check. The expiry check in step 4 covers mode-2 lifetime.
    ///    - `.decayDerived`: the grant's decay window is expressed via its
    ///      `lifetime` field (typically `.decayWindow`); the expiry check
    ///      in step 4 covers it. If the grant's lifetime has not expired
    ///      we accept the read (the source cannot independently verify
    ///      share viability without the reconstruction parameters, which
    ///      are not persisted in the grants schema — GRT-01 known
    ///      limitation). If the grant IS expired (step 4 already caught
    ///      that), the read was already refused before reaching here.
    ///    - `.timeAging` (mode 4): the grant's effective content level
    ///      attenuates by its `DecayPolicy` (half-life of elapsed time since
    ///      `startedAt`, floored at `floor`), computed against the injected
    ///      `now`. A grant decayed to an effective level of 0 (floor 0) has
    ///      aged out of all access and throws `.custodyRefused`. Otherwise the
    ///      read proceeds and step 8 gates content with the attenuated level.
    ///    - Any unrecognized custody mode: fail-closed, throw `.custodyRefused`.
    /// 6. InferenceRemainingBudget gate: read the current budget for the
    ///    authorizing grant from the store (re-read to capture concurrent
    ///    debits). If budget <= 0, throw `.budgetExhausted`. Otherwise
    ///    debit `GeniusLocusKit.budgetDebitPerRead` (0.01) from the
    ///    persisted row atomically before the read proceeds.
    /// 7. Only with a valid grant in hand: run `frame` through the source
    ///    estate's `recall`, draining the `RecallStream` fully.
    /// 8. Apply the content-level sensitivity gate: exclude drawers whose
    ///    `adjectiveSensitivity.rawValue` exceeds `grant.contentLevel`.
    /// 9. Apply the scope subtree filter: exclude drawers outside the
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
    ///   - now: evaluation instant for grant expiry and vault checks,
    ///     supplied so the gate is deterministic and testable. Defaults
    ///     to the call-site time.
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

        // 2. The source estate's grant surface. Both the store (persistent
        // grant rows) and the vault (mode-1 scope keys in memory) are
        // needed: the store for active-grant queries and budget debit;
        // the vault for the custody-mode gate in step 5.
        let (store, vault) = try await ensureGrantSurface(for: source)

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
        // higher-level one when both are active.
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

        // 5. CustodyMode gate. Each mode's recall-path semantics:
        //
        // .mediated (mode 1): the source vault must hold the scope key for
        // this grant. Every federated read is a live vault request — the
        // key never leaves custody, so without a vault entry the source
        // cannot serve the read. The vault's `access` call checks revoked
        // state and key presence in one atomic step; `scopeKeyUnavailable`
        // means the vault has no key (estate restarted or key was never
        // loaded) and the read is refused with `.custodyRefused`.
        //
        // .handedOver (mode 2): the key was handed to the recipient at
        // issue; offline reads are permitted within the grant window. The
        // source has no vault entry and issues no vault check. The expiry
        // check in step 4 already covers the mode-2 grant window.
        //
        // .decayDerived (mode 3): the grant's decay window is expressed via
        // its `lifetime` field (typically `.decayWindow(seconds:)`). The
        // expiry gate in step 4 covers it: if the window has elapsed the
        // grant is already expired and the read was refused before reaching
        // here. If the lifetime has not expired, the read is accepted. The
        // source cannot independently verify share viability at this layer
        // because the reconstruction parameters (threshold/totalShares/
        // driftRate) are not persisted in the grants schema (GRT-01 known
        // limitation); the lifetime field is the proxy for decay state.
        //
        // The effective content level the grant exposes at `now`. For every
        // mode except time-aging this is the grant's persisted `contentLevel`;
        // mode 4 attenuates it by its decay policy (computed below).
        var effectiveContentLevel = authorizingGrant.contentLevel
        switch authorizingGrant.custodyMode {
        case .mediated:
            // Live vault check: vault must hold the scope key. A missing
            // key means the source cannot serve this mediated read.
            do {
                _ = try await vault.access(grant: authorizingGrant, now: now)
            } catch GrantError.scopeKeyUnavailable {
                throw GeniusLocusKitError.crossEstateReadRefused(
                    source: source.estateUUID,
                    requester: requester.estateUUID,
                    reason: .custodyRefused
                )
            } catch GrantError.grantRevoked {
                // Should not reach here — revoked grants are excluded from
                // active() — but if the vault sees it, refuse closed.
                throw GeniusLocusKitError.crossEstateReadRefused(
                    source: source.estateUUID,
                    requester: requester.estateUUID,
                    reason: .grantRevoked
                )
            }
        case .handedOver:
            // Offline mode: no vault check. Expiry in step 4 covers the window.
            break
        case .decayDerived:
            // Decay window expressed via the grant's lifetime field.
            // Step 4 already refused if expired. If we reach here the
            // window has not elapsed; accept.
            break
        case .timeAging(let policy):
            // Mode 4: the grant's effective content level attenuates as a
            // half-life function of elapsed time (computed with the injected
            // `now`, never the wall clock, so it is deterministic). A grant
            // whose effective level has decayed to 0 — only reachable when the
            // policy floor is 0 — has aged out of all access and is refused.
            // A positive floor keeps the grant usable at the floor level.
            effectiveContentLevel = policy.effectiveLevel(
                baseLevel: authorizingGrant.contentLevel, now: now
            )
            if effectiveContentLevel <= 0 {
                throw GeniusLocusKitError.crossEstateReadRefused(
                    source: source.estateUUID,
                    requester: requester.estateUUID,
                    reason: .custodyRefused
                )
            }
        }

        // 6. Inference budget gate and debit.
        //
        // Re-read the stored budget for the authorizing grant to capture any
        // concurrent debits that occurred since step 3 loaded the grant. This
        // prevents a race where two concurrent reads both see budget > 0 and
        // both proceed, double-spending from the same remaining allotment.
        // Within the actor (GeniusLocusKit is an actor), concurrent reads are
        // serialized by the actor model, so this re-read is an additional
        // safety net for any future caller that bypasses the actor isolation.
        //
        // Debit quantum (spec §6 is silent; fail-closed chosen rule):
        //   GeniusLocusKit.budgetDebitPerRead = 0.01 per read.
        //   A fresh grant (budget = 1.0) supports ~100 reads before exhaustion.
        //   Budget <= 0 refuses the read before any content is returned.
        //
        // The debit is written to the persistence layer (GrantStore.debitBudget)
        // atomically with the read proceeding, so the budget row is updated
        // before the drawers are assembled. If persistence fails, the error
        // propagates and no content is returned — budget exhaustion is never
        // silently bypassed.
        let currentStored = try await store.get(id: authorizingGrant.id)
        let currentBudget = currentStored?.grant.inferenceRemainingBudget ?? 0.0
        guard currentBudget > 0.0 else {
            throw GeniusLocusKitError.crossEstateReadRefused(
                source: source.estateUUID,
                requester: requester.estateUUID,
                reason: .budgetExhausted
            )
        }
        // Debit persisted before the read returns content so no read can
        // succeed without consuming from the budget.
        try await store.debitBudget(
            id: authorizingGrant.id,
            amount: GeniusLocusKit.budgetDebitPerRead
        )

        // 7. Valid grant in hand: read the source estate. Drain the
        // RecallStream fully, the same way CrossEstateRead.fanOutRecall
        // does, so the caller receives the complete result set. The read
        // runs against the source estate alone, so only the source's rows
        // are returned — the requester's own content is never included.
        var drawers: [Drawer] = []
        let stream = await sourceEstate.recall(frame)
        for await page in stream {
            drawers.append(contentsOf: page.rows)
        }

        // 8. Content-level sensitivity gate. Exclude any drawer whose
        // sensitivity (bits 6–11 of adjectiveBitmap, scale-gapped at
        // 0/16/32/48 for normal/elevated/restricted/secret) exceeds the
        // grant's contentLevel. This is the GLK-layer primary enforcement:
        // callers that bypass ARIA still get sensitivity-narrowed results.
        // Default grant (contentLevel: 0) admits only normal-sensitivity
        // rows; callers issuing grants at higher contentLevel progressively
        // unlock elevated, restricted, and secret rows.
        // The mode-4 time-aging decay narrows `contentMax` to the attenuated
        // level computed in the custody gate; every other mode uses the grant's
        // raw contentLevel (effectiveContentLevel was initialised to it).
        let contentMax = effectiveContentLevel
        // Fail-open note: `Drawer.adjectiveSensitivity`
        // falls back to `.normal` (rawValue 0) for any bitmap value that
        // doesn't match a valid AdjectiveSensitivity case. A corrupt row
        // therefore passes this gate at contentLevel >= 0 (all grants).
        // This is the documented fail-open direction per Adjectives.swift
        // ("matching the estate-level default access posture"). The
        // trust boundary for bitmap integrity is DrawerStore/AuditGate,
        // not this filter.
        drawers = drawers.filter { $0.adjectiveSensitivity.rawValue <= contentMax }

        // 9. Scope subtree filter — GLK primary enforcement.
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
