import Foundation
import LocusKit

/// The outcome of a successful grant-gated cross-estate federated read.
///
/// `federatedRecall` returns this when — and only when — the source
/// estate holds an active, unexpired grant naming the requester as
/// grantee. The result is deliberately self-describing: it carries the
/// authorizing `Grant` and both estate handles so the ARIA access
/// surface above this layer (`MCP-MULTI-01`) and the audit trail can
/// attribute the disclosure to a specific grant without re-querying the
/// grant store. Per DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §10,
/// attribution of which content was disclosed under which grant is the
/// load-bearing fact the answer-assembly layer needs.
///
/// Content-level sensitivity filtering **is** applied by the caller
/// (`CrossEstateFederation.federatedRecall`): drawers whose
/// `adjectiveSensitivity` exceeds `grant.contentLevel` are excluded
/// before this result is constructed, making GLK the primary enforcer.
///
/// Scope-subtree filtering **is** applied by the caller
/// (`CrossEstateFederation.federatedRecall`): drawers outside the
/// granted wing/room/lattice subtree/single row are excluded before
/// this result is constructed, making GLK the primary enforcer.
/// ARIA's scope narrowing in `ToolDispatch` remains as defense-in-depth
/// secondary.
public struct FederatedRecallResult: Sendable {

    /// The drawers recalled from the **source** estate. Hydration
    /// follows the `RecallFrame.hydrationLevel` the caller supplied; this
    /// layer does not re-hydrate. These are the source estate's rows
    /// only — never the requester's own (storage isolation is preserved
    /// because the recall runs against the source estate alone).
    public let drawers: [Drawer]

    /// The grant that authorized this read. Carried so the caller and
    /// the audit trail can attribute the disclosure to a concrete,
    /// signed grant. When more than one active grant names the requester,
    /// this is the grant the gate selected as valid at `now`.
    public let grant: Grant

    /// The estate the content was read from (the grantor).
    public let sourceHandle: EstateHandle

    /// The estate that requested the read (the grantee named on `grant`).
    public let requesterHandle: EstateHandle

    /// Construct a federated-read result.
    public init(
        drawers: [Drawer],
        grant: Grant,
        sourceHandle: EstateHandle,
        requesterHandle: EstateHandle
    ) {
        self.drawers = drawers
        self.grant = grant
        self.sourceHandle = sourceHandle
        self.requesterHandle = requesterHandle
    }
}

/// Why a cross-estate federated read was refused.
///
/// This is the payload of `GeniusLocusKitError.crossEstateReadRefused`
/// and the assertion surface for the A-versus-C refusal conformance
/// tests (DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §13, cookbook
/// I-23). The substrate refuses — it never returns silently empty —
/// when the source estate holds no valid grant naming the requester.
public enum FederatedReadRefusalReason: Sendable, Equatable {

    /// The source estate holds no active grant naming the requester as
    /// grantee. This is the A-versus-C case: B answers A only from
    /// B-authored or B-to-A-granted content, so a read of C's content by
    /// A — with no C-to-A grant — refuses here. Revocation also surfaces
    /// as this reason: a revoked grant is dropped from
    /// `GrantStore.active()`, so after revocation the requester simply
    /// has no active grant.
    case noActiveGrant

    /// A grant naming the requester exists but its lifetime has elapsed
    /// at the evaluation instant `now`. Distinguished from
    /// `noActiveGrant` so the caller can tell "never authorized" from
    /// "authorization lapsed".
    case grantExpired

    /// Defensive: the grant store returned a grant that is marked
    /// revoked. `GrantStore.active()` already excludes revoked grants, so
    /// this reason is unreachable through the active-grant path and is
    /// reserved for a store that ever hands back a revoked row. Modeled
    /// explicitly so the refusal vocabulary is complete per §13.
    case grantRevoked
}
