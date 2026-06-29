import Foundation
import SubstrateTypes

// MARK: - Supporting typealiases for Filter

/// Stable lineage identifier — UUID identifying a content lineage.
/// All versions of the same content share one LineageID per spec § 5.10.
public typealias LineageID = UUID

/// Room identifier — a namespaced location within the estate.
/// Free-form String; the substrate does not validate against a closed set.
public typealias RoomID = String

/// Wing identifier — top-level namespace within the estate.
/// Free-form String; wing and room names are resolved through the node tree
/// via `DrawerStore.resolveNodeNames`.
public typealias WingID = String

/// Wikidata Q-ID string (e.g. "Q11165").
public typealias WikidataQID = String

/// Provenance channel — alias for the existing `Channel` enum in
/// `Provenance.swift`, used in Filter cases under the spec's filter
/// vocabulary. The two names refer to the same enum.
public typealias ProvenanceChannel = Channel

/// Feature-flag filter argument — alias for `DrawerFeatureFlags`
/// (bits 12–23 of `Drawer.operationalBitmap`). A filter matches when
/// any of the specified flags are set.
public typealias FeatureFlag = DrawerFeatureFlags

// Note on `Sensitivity`: the spec uses the bare name `Sensitivity` in
// the Filter case shapes (e.g. `Filter.sensitivityAtMost(Sensitivity)`).
// `Provenance.swift` declares a `public enum Sensitivity` for provenance
// sensitivity (scale-gapped rawValues: normal=0, elevated=16,
// restricted=32, secret=48; stored in the provenance bitmap's 6-bit
// sensitivity field). The adjective-axis `AdjectiveSensitivity` is a
// separate type. Declaring a typealias here would shadow the provenance
// enum and break the `Drawer.sensitivity` accessor (which returns
// provenance Sensitivity). We therefore use the fully-qualified
// `AdjectiveSensitivity` type in the adjective-axis filter cases below
// and rely on the type system to make the choice unambiguous at call sites.

// MARK: - StateCluster

/// State-cluster membership filter. Coarser than `State`; used when the
/// caller cares about the cluster, not the exact state value. Per spec § 6.1.
public enum StateCluster: Sendable {
    /// State in {active, pending, contested} — the "know now" cluster.
    case knowNow
    /// State in {superseded, decayed, withdrawn, expired} — the "knew past" cluster.
    case knewPast
    /// State in {rejected, tombstoned} — the terminal cluster.
    case terminal
}

// MARK: - Filter

/// Named recall filter algebra. Per spec § 7.9.1.
///
/// No case takes a raw bit position, mask, or threshold integer.
/// Every case is either a named enum value or a domain-meaningful
/// argument. The evaluator (LOCI_V035_16) translates Filter cases
/// into the bitmap primitives in § 7.9.2 internally; callers never
/// write `state < 3` or `trust < 4`.
///
/// A `RecallFrame.filterChain` is `[Filter]` interpreted as implicit
/// AND — equivalent to `Filter.all(filterChain)`.
public indirect enum Filter: Sendable {

    // MARK: State queries

    /// Rows in the know-now cluster (state < 3). The evaluator prepends
    /// this filter when no state filter is present, so "no state filter"
    /// defaults to currently-believed content.
    case currentlyBelieve
    /// Rows in the knew-past cluster (3 ≤ state < 7).
    case usedToBelieve
    /// Rows in the terminal cluster (state ≥ 7).
    case knewOnceAndErased
    /// Rows with exactly this state value.
    case state(State)
    /// Rows in this state cluster.
    case stateInCluster(StateCluster)

    // MARK: Trust queries

    /// Rows with trust below the action threshold (trust < 4). The
    /// evaluator prepends this filter when no trust filter is present.
    case trustworthy
    /// Rows with trust at or above the action threshold (trust ≥ 4).
    case requiresConfirmation
    /// Rows with exactly this trust value.
    case trust(Trust)
    /// Rows with trust ≤ this value.
    case trustAtMost(Trust)

    // MARK: Sensitivity queries

    /// Rows with exactly this sensitivity tier.
    case sensitivity(AdjectiveSensitivity)
    /// Rows with sensitivity ≤ this tier. Primary use is access-gate
    /// filtering when a caller's clearance is bounded.
    case sensitivityAtMost(AdjectiveSensitivity)

    // MARK: Exportability queries

    /// Rows marked as exportable (exportability == .public_).
    case exportable
    /// Rows marked as contained (exportability == .private_).
    case contained

    // MARK: Provenance queries

    /// Rows where confirmation ≥ user_confirmed. This is explicit; ordinary
    /// recall does not add a confirmation gate.
    case userConfirmed
    /// Rows where confirmation == automated_confirmed only (not user/peer/actuator).
    /// F13: was `modelConfirmedOnly` in v0.35; cookbook §2.5 vocab.
    case automatedConfirmedOnly
    /// Rows that are unconfirmed.
    case unconfirmed
    /// Rows with this source type.
    case sourceType(SourceType)
    /// Rows captured via this provenance channel.
    case channel(ProvenanceChannel)
    /// Rows with confidence at least this level.
    case confidenceAtLeast(Confidence)

    // MARK: Operational queries

    /// Rows captured via this channel (operational bitmap bits 0–5).
    case captureChannel(CaptureChannel)
    /// Rows with this content kind.
    case contentKind(ContentKind)
    /// Rows where any of the specified feature flags are set.
    case hasFeatureFlag(FeatureFlag)

    // MARK: Structural queries

    /// Rows filed in this room.
    case inRoom(RoomID)
    /// Rows filed in this wing.
    case inWing(WingID)
    /// Rows with this lineage identifier.
    case lineageID(LineageID)
    /// Rows captured strictly after this timestamp.
    case createdAfter(Date)
    /// Rows captured strictly before this timestamp.
    case createdBefore(Date)
    /// Rows with a matching lattice anchor.
    case latticeAnchor(LatticeAnchor)
    /// Rows whose UDC code begins with this prefix (depth-axis subtree).
    case latticeUnder(udcPrefix: String)
    /// Rows associated with this Wikidata Q-ID (primary or secondary).
    case wikidataConcept(WikidataQID)

    // MARK: Content queries

    /// Rows whose verbatim content contains this string.
    case contentMatches(String)

    // MARK: Composition

    /// All child filters must match (AND).
    case all([Filter])
    /// At least one child filter must match (OR).
    case any([Filter])
    /// Child filter must not match (NOT).
    case not(Filter)
}
