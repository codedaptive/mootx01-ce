#if MOOTX01_MINERS
// AdornmentIdentity.swift
//
// Pure value types for one registered minter and one stored adornment
// (ADORNMENTLIB_INTERFACE 0.3.0, ADORNMENTLIB_SPEC §4).
//
// Design:
//   - These are persistence-neutral identity carriers. String identifiers
//     are assigned by LocusKit; this library opens no database and imports
//     no Drawer or estate type (layering invariant: AdornmentLib is BELOW
//     LocusKit in the dependency graph).
//   - A configuration change creates a new AdornmentMinterDescriptor
//     identity; `isActive` is the only mutable field on an existing
//     descriptor. The descriptor identifier references the complete
//     configuration record; it is never derived from or repeated inside
//     the adornment text.
//   - There is at most one StoredAdornment for a given (drawerID, minterID)
//     pair within one estate. Multiple minters may adorn the same drawer.
//   - StoredAdornment carries only the two compact references and the
//     generated text. Drawer content, subject, SSC, timestamps, location,
//     retrieval state, and minter metadata are references to their owning
//     records and MUST NOT be copied into this value.
//
// Both values are Sendable and Equatable per the interface contract.
// Rust twin: adornment_identity.rs (Clone, Debug, PartialEq, Eq).

import Foundation

// MARK: - AdornmentMinterDescriptor

/// Reusable configuration identity of one adornment minter.
///
/// Represents one row in the minter master table. Every generation-affecting
/// setting is captured here so that a configuration change is a NEW row, not
/// an update to an existing one. `isActive` is the only mutable field:
/// activation and deactivation toggle `is_active` on the existing row via
/// `setAdornmentMinterActive`; they do not replace the descriptor identity.
///
/// `parameters` captures every generation-affecting parameter (temperature,
/// top-p, seed, etc.) as a string-to-string map. The persistence owner
/// serializes the map in key order (lexical) when it needs a canonical form
/// (e.g. for the `parameters` JSON column in the minter master table).
///
/// Zero, one, or many descriptors MAY be active at runtime (neither Apple
/// nor Candle seats are hard-coded here).
///
/// Mirrors Rust `AdornmentMinterDescriptor` (same field names in snake_case).
public struct AdornmentMinterDescriptor: Sendable, Equatable {

    /// Opaque descriptor identifier assigned by the persistence owner (LocusKit).
    /// TEXT primary key in the minter master table.
    public let id: String

    /// Stable, human-readable minter name. Not globally unique — uniqueness
    /// is enforced by `id`.
    public let name: String

    /// Minter family identifier (e.g. "apple", "candle"). The schema does
    /// not constrain this field to a fixed vocabulary; it is a grouping key
    /// for display and legacy-migration labelling.
    public let family: String

    /// Identifier of the model driving this minter (e.g. "apple-gen1").
    public let modelID: String

    /// Model version or revision string (e.g. "2026-07", "v1.2"). Combined
    /// with `modelID` to fully identify the generation model.
    public let modelVersion: String

    /// Digest of the prompt template used by this minter (SHA-256 hex or
    /// equivalent stable fingerprint). Changing the prompt template requires
    /// a new descriptor.
    public let promptDigest: String

    /// Every generation-affecting parameter as a string-to-string map.
    /// Keys include sampling settings (temperature, top-p, seed, etc.).
    /// The persistence owner serializes in lexical key order for canonical
    /// JSON representation.
    public let parameters: [String: String]

    /// Whether this minter is currently active for new adornment generation.
    /// The ONLY mutable field on an existing descriptor; changed via
    /// `setAdornmentMinterActive` or `setActiveAdornmentMinters`.
    public let isActive: Bool

    /// Designated initializer.
    public init(
        id: String,
        name: String,
        family: String,
        modelID: String,
        modelVersion: String,
        promptDigest: String,
        parameters: [String: String],
        isActive: Bool
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.promptDigest = promptDigest
        self.parameters = parameters
        self.isActive = isActive
    }
}

// MARK: - StoredAdornment

/// One persistent output from an adornment minter.
///
/// Represents one row in the `adornments` table. The composite primary key
/// is `(drawerID, minterID)` — at most one stored adornment per
/// (Drawer, minter) pair. Multiple minters may adorn the same drawer,
/// each producing an independent row.
///
/// Only the two compact references and the generated text are stored here.
/// Drawer content, subject, SSC, timestamps, location, retrieval state, and
/// minter metadata live in their owning records and are never copied.
///
/// Mirrors Rust `StoredAdornment` (same field names in snake_case).
public struct StoredAdornment: Sendable, Equatable {

    /// Identifier of the Drawer this adornment was produced for.
    /// Foreign key to `drawers.id`.
    public let drawerID: String

    /// Identifier of the minter that produced this adornment.
    /// Foreign key to `adornment_minters.id`.
    public let minterID: String

    /// The generated adornment text. Length-bounded by
    /// `ADORNMENT_MAX_LENGTH` at mint time; stored verbatim here.
    public let text: String

    /// Designated initializer.
    public init(drawerID: String, minterID: String, text: String) {
        self.drawerID = drawerID
        self.minterID = minterID
        self.text = text
    }
}
#endif // MOOTX01_MINERS
