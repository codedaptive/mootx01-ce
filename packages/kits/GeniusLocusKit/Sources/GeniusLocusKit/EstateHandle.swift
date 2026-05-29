import Foundation
import LocusKit

/// Identifies one estate opened through `GeniusLocusKit`.
///
/// An `EstateHandle` is a value-type ticket the kit issues when a
/// caller opens an estate via `EstateCoordinator.open`. The caller
/// holds the handle to address that estate for subsequent verbs,
/// closes, and read fan-out. The handle is opaque from the caller's
/// perspective: it carries enough identity to look the estate up in
/// the registry, plus a cached snapshot of the manifest fields the
/// coordinator needs without re-reading on every call.
///
/// Handles are `Sendable` and `Hashable` so they cross actor
/// boundaries cleanly and serve as registry keys.
///
/// The handle is **not** the estate. It does not hold a reference to
/// the live `LocusKit.Estate` actor; the kit's registry does. A handle
/// whose registry entry has been closed is stale, and any subsequent
/// lookup returns `GeniusLocusKitError.estateNotOpen`.
public struct EstateHandle: Sendable, Hashable {

    /// Stable identifier for the opened estate, drawn from the
    /// manifest's `estate_uuid`. Identical across re-opens of the same
    /// database file because estate identity is a property of the
    /// substrate, not the handle.
    public let estateUUID: UUID

    /// Zoom-window lower bound, captured from the manifest at open
    /// time. Cached on the handle so lattice-overlap routing does not
    /// have to re-read each estate's manifest on every fan-out call.
    /// Per `SUBSTRATE_MATHEMATICS.md` § 2.
    public let zoomWindowLow: Int

    /// Zoom-window upper bound, captured from the manifest at open
    /// time.
    public let zoomWindowHigh: Int

    /// Estate display name from the manifest. Useful for diagnostics
    /// and aggregation labels; not interpreted by the coordinator.
    public let estateName: String

    /// Construct a handle from a manifest snapshot. Internal because
    /// only the coordinator legitimately issues handles; outside
    /// callers receive handles back from `open` and never construct
    /// their own.
    internal init(manifest: ManifestValues) throws {
        guard let uuid = UUID(uuidString: manifest.estateUUID) else {
            throw GeniusLocusKitError.invalidManifest(
                key: "estate_uuid",
                detail: "value '\(manifest.estateUUID)' is not a valid UUID"
            )
        }
        guard manifest.zoomWindowLow <= manifest.zoomWindowHigh else {
            throw GeniusLocusKitError.invalidManifest(
                key: "zoom_window",
                detail: "low (\(manifest.zoomWindowLow)) must be <= high (\(manifest.zoomWindowHigh))"
            )
        }
        self.estateUUID = uuid
        self.zoomWindowLow = manifest.zoomWindowLow
        self.zoomWindowHigh = manifest.zoomWindowHigh
        self.estateName = manifest.estateName
    }
}
