//! LocusKit manifest. Ports `Manifest.swift`.
//!
//! Typed key constants for the v1 manifest key-value table, plus a
//! read-only snapshot value type returned by the future `DrawerStore`
//! port. Per `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` §5.9 and §7.8.1.

// MARK: - ManifestKey

/// Typed key constants for the v1 manifest key-value table.
///
/// The raw string is the exact value stored in the `manifest.key` column.
/// `as_str` returns it; `from_str` decodes a row's key column back to the
/// typed case. Unknown strings return `None` (Swift's
/// `ManifestKey(rawValue:)` returns nil for unrecognised strings — the
/// kit then treats the row as a forward-schema entry it does not know how
/// to interpret).
///
/// All 23 cases — 18 required + 5 optional — are present and ordered
/// to match the Swift declaration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ManifestKey {
    // Required keys (18)
    ManifestVersion,
    SchemaVersion,
    EstateUUID,
    EstateName,
    OwnerIdentifier,
    LatticeCitation,
    FrameworkProfile,
    FrameworkProfileDefinition,
    ZoomWindowLow,
    ZoomWindowHigh,
    AccessPosture,
    ProvenanceDefaults,
    ActiveStorageMode,
    TablesPresent,
    CreatedAt,
    LastModified,
    BitmapLayoutVersion,
    ProvenanceBitmapVersion,

    // Optional keys (5)
    FederationGroupID,
    MiningPatternsHash,
    TinyModelID,
    TinyModelTrainingCorpusSize,
    OperationalBitmapLayouts,
}

impl ManifestKey {
    /// Stored string for this key. Mirrors the Swift `rawValue` and the
    /// strings written into `manifest.key`.
    pub fn as_str(self) -> &'static str {
        match self {
            ManifestKey::ManifestVersion => "manifest_version",
            ManifestKey::SchemaVersion => "schema_version",
            ManifestKey::EstateUUID => "estate_uuid",
            ManifestKey::EstateName => "estate_name",
            ManifestKey::OwnerIdentifier => "owner_identifier",
            ManifestKey::LatticeCitation => "lattice_citation",
            ManifestKey::FrameworkProfile => "framework_profile",
            ManifestKey::FrameworkProfileDefinition => "framework_profile_definition",
            ManifestKey::ZoomWindowLow => "zoom_window_low",
            ManifestKey::ZoomWindowHigh => "zoom_window_high",
            ManifestKey::AccessPosture => "access_posture",
            ManifestKey::ProvenanceDefaults => "provenance_defaults",
            ManifestKey::ActiveStorageMode => "active_storage_mode",
            ManifestKey::TablesPresent => "tables_present",
            ManifestKey::CreatedAt => "created_at",
            ManifestKey::LastModified => "last_modified",
            ManifestKey::BitmapLayoutVersion => "bitmap_layout_version",
            ManifestKey::ProvenanceBitmapVersion => "provenance_bitmap_version",
            ManifestKey::FederationGroupID => "federation_group_id",
            ManifestKey::MiningPatternsHash => "mining_patterns_hash",
            ManifestKey::TinyModelID => "tiny_model_id",
            ManifestKey::TinyModelTrainingCorpusSize => "tiny_model_training_corpus_size",
            ManifestKey::OperationalBitmapLayouts => "operational_bitmap_layouts",
        }
    }

    /// Decode a stored key string back to the typed case. Returns
    /// `None` for unrecognised strings, matching the Swift fallible
    /// `ManifestKey(rawValue:)` initialiser — the caller decides how to
    /// surface forward-schema rows.
    ///
    /// Named `from_str` by cross-leg convention (mirrors Swift `init(rawValue:)`).
    /// Returns `Option<ManifestKey>` rather than `Result<_, _>`, so this
    /// does not implement `std::str::FromStr` (different return type).
    /// The `#[allow]` suppresses the lint that warns about the similar name.
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<ManifestKey> {
        Some(match s {
            "manifest_version" => ManifestKey::ManifestVersion,
            "schema_version" => ManifestKey::SchemaVersion,
            "estate_uuid" => ManifestKey::EstateUUID,
            "estate_name" => ManifestKey::EstateName,
            "owner_identifier" => ManifestKey::OwnerIdentifier,
            "lattice_citation" => ManifestKey::LatticeCitation,
            "framework_profile" => ManifestKey::FrameworkProfile,
            "framework_profile_definition" => ManifestKey::FrameworkProfileDefinition,
            "zoom_window_low" => ManifestKey::ZoomWindowLow,
            "zoom_window_high" => ManifestKey::ZoomWindowHigh,
            "access_posture" => ManifestKey::AccessPosture,
            "provenance_defaults" => ManifestKey::ProvenanceDefaults,
            "active_storage_mode" => ManifestKey::ActiveStorageMode,
            "tables_present" => ManifestKey::TablesPresent,
            "created_at" => ManifestKey::CreatedAt,
            "last_modified" => ManifestKey::LastModified,
            "bitmap_layout_version" => ManifestKey::BitmapLayoutVersion,
            "provenance_bitmap_version" => ManifestKey::ProvenanceBitmapVersion,
            "federation_group_id" => ManifestKey::FederationGroupID,
            "mining_patterns_hash" => ManifestKey::MiningPatternsHash,
            "tiny_model_id" => ManifestKey::TinyModelID,
            "tiny_model_training_corpus_size" => ManifestKey::TinyModelTrainingCorpusSize,
            "operational_bitmap_layouts" => ManifestKey::OperationalBitmapLayouts,
            _ => return None,
        })
    }

    /// The 18 required keys that every conforming estate must populate.
    /// Mirrors `ManifestKey.required` on the Swift side.
    pub const REQUIRED: [ManifestKey; 18] = [
        ManifestKey::ManifestVersion,
        ManifestKey::SchemaVersion,
        ManifestKey::EstateUUID,
        ManifestKey::EstateName,
        ManifestKey::OwnerIdentifier,
        ManifestKey::LatticeCitation,
        ManifestKey::FrameworkProfile,
        ManifestKey::FrameworkProfileDefinition,
        ManifestKey::ZoomWindowLow,
        ManifestKey::ZoomWindowHigh,
        ManifestKey::AccessPosture,
        ManifestKey::ProvenanceDefaults,
        ManifestKey::ActiveStorageMode,
        ManifestKey::TablesPresent,
        ManifestKey::CreatedAt,
        ManifestKey::LastModified,
        ManifestKey::BitmapLayoutVersion,
        ManifestKey::ProvenanceBitmapVersion,
    ];

    /// The 5 optional keys. Absent means "not configured".
    pub const OPTIONAL: [ManifestKey; 5] = [
        ManifestKey::FederationGroupID,
        ManifestKey::MiningPatternsHash,
        ManifestKey::TinyModelID,
        ManifestKey::TinyModelTrainingCorpusSize,
        ManifestKey::OperationalBitmapLayouts,
    ];
}

// MARK: - ManifestValues

/// A typed, read-only snapshot of the estate manifest. Obtained via the
/// future `DrawerStore::read_manifest`. Consumed by `Estate::manifest`.
///
/// ## Type choices
///
/// - Strings are owned (`String`) because the snapshot outlives the row
///   read that produced it; no lifetime would survive being returned
///   from an async store call.
/// - `Int` fields on the Swift side are i64-width on Apple Silicon, so
///   they map to `i64` (or `i32` where a smaller width is documented).
/// - Bitmap-typed fields (access_posture, provenance_defaults,
///   active_storage_mode) are `i64` per the schema's `bitmap` column
///   type.
/// - `Date` fields use `i64` Unix epoch seconds, matching the LP-1A
///   convention in `audit_types.rs` and the `TypedValue::Timestamp(i64)`
///   shape in persistence-kit. The Swift port stores dates as TEXT ISO8601
///   in SQLite; the i64 representation carries the same semantic value
///   without a calendar library at this layer.
/// - Optional fields are `Option<T>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestValues {
    // Required fields
    pub manifest_version: String,
    pub schema_version: String,
    pub estate_uuid: String,
    pub estate_name: String,
    pub owner_identifier: String,
    pub lattice_citation: String,
    pub framework_profile: String,
    /// Raw JSON string. Parsed by the consumer when needed.
    pub framework_profile_definition: String,
    pub zoom_window_low: i64,
    pub zoom_window_high: i64,
    /// Bitmap value.
    pub access_posture: i64,
    /// Bitmap value.
    pub provenance_defaults: i64,
    /// Bitmap value.
    pub active_storage_mode: i64,
    /// Comma-separated list of table names.
    pub tables_present: String,
    /// Unix epoch seconds.
    pub created_at: i64,
    /// Unix epoch seconds.
    pub last_modified: i64,
    pub bitmap_layout_version: String,
    pub provenance_bitmap_version: String,

    // Optional fields (None = absent / not configured)
    pub federation_group_id: Option<String>,
    pub mining_patterns_hash: Option<String>,
    pub tiny_model_id: Option<String>,
    pub tiny_model_training_corpus_size: Option<i64>,
    pub operational_bitmap_layouts: Option<String>,
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Every required key's `as_str` matches the spec's stored string.
    #[test]
    fn required_keys_raw_strings() {
        let pairs: &[(ManifestKey, &str)] = &[
            (ManifestKey::ManifestVersion, "manifest_version"),
            (ManifestKey::SchemaVersion, "schema_version"),
            (ManifestKey::EstateUUID, "estate_uuid"),
            (ManifestKey::EstateName, "estate_name"),
            (ManifestKey::OwnerIdentifier, "owner_identifier"),
            (ManifestKey::LatticeCitation, "lattice_citation"),
            (ManifestKey::FrameworkProfile, "framework_profile"),
            (
                ManifestKey::FrameworkProfileDefinition,
                "framework_profile_definition",
            ),
            (ManifestKey::ZoomWindowLow, "zoom_window_low"),
            (ManifestKey::ZoomWindowHigh, "zoom_window_high"),
            (ManifestKey::AccessPosture, "access_posture"),
            (ManifestKey::ProvenanceDefaults, "provenance_defaults"),
            (ManifestKey::ActiveStorageMode, "active_storage_mode"),
            (ManifestKey::TablesPresent, "tables_present"),
            (ManifestKey::CreatedAt, "created_at"),
            (ManifestKey::LastModified, "last_modified"),
            (ManifestKey::BitmapLayoutVersion, "bitmap_layout_version"),
            (
                ManifestKey::ProvenanceBitmapVersion,
                "provenance_bitmap_version",
            ),
        ];
        for (k, s) in pairs {
            assert_eq!(k.as_str(), *s, "as_str mismatch on {:?}", k);
        }
    }

    /// Every optional key's `as_str` matches the spec.
    #[test]
    fn optional_keys_raw_strings() {
        assert_eq!(
            ManifestKey::FederationGroupID.as_str(),
            "federation_group_id"
        );
        assert_eq!(
            ManifestKey::MiningPatternsHash.as_str(),
            "mining_patterns_hash"
        );
        assert_eq!(ManifestKey::TinyModelID.as_str(), "tiny_model_id");
        assert_eq!(
            ManifestKey::TinyModelTrainingCorpusSize.as_str(),
            "tiny_model_training_corpus_size"
        );
        assert_eq!(
            ManifestKey::OperationalBitmapLayouts.as_str(),
            "operational_bitmap_layouts"
        );
    }

    /// Round-trip every required and optional key.
    #[test]
    fn from_str_roundtrips_every_key() {
        for k in ManifestKey::REQUIRED
            .iter()
            .chain(ManifestKey::OPTIONAL.iter())
        {
            assert_eq!(ManifestKey::from_str(k.as_str()), Some(*k));
        }
    }

    /// Unknown key strings decode to None — Swift's fallible init shape.
    #[test]
    fn from_str_returns_none_for_unknown() {
        assert_eq!(ManifestKey::from_str(""), None);
        assert_eq!(ManifestKey::from_str("future_unknown_key"), None);
        assert_eq!(ManifestKey::from_str("Manifest_Version"), None); // case sensitive
    }

    /// 18 required keys, 5 optional, 23 total.
    #[test]
    fn key_counts() {
        assert_eq!(ManifestKey::REQUIRED.len(), 18);
        assert_eq!(ManifestKey::OPTIONAL.len(), 5);
    }

    /// Required and optional sets are disjoint.
    #[test]
    fn required_and_optional_are_disjoint() {
        for r in ManifestKey::REQUIRED.iter() {
            for o in ManifestKey::OPTIONAL.iter() {
                assert_ne!(r, o, "{:?} appears in both required and optional", r);
            }
        }
    }

    /// ManifestValues can be constructed with the documented field set
    /// and round-trips equality. Smoke test — full read/write semantics
    /// arrive with the DrawerStore impl in a follow-on mission.
    #[test]
    fn manifest_values_construction_and_equality() {
        let mv = ManifestValues {
            manifest_version: "1".to_string(),
            schema_version: "1".to_string(),
            estate_uuid: "00000000-0000-0000-0000-000000000000".to_string(),
            estate_name: "test-estate".to_string(),
            owner_identifier: "alice@icloud.com".to_string(),
            lattice_citation: "UDC-2.0-2020".to_string(),
            framework_profile: "default".to_string(),
            framework_profile_definition: "{}".to_string(),
            zoom_window_low: -3,
            zoom_window_high: 3,
            access_posture: 0,
            provenance_defaults: 0,
            active_storage_mode: 1,
            tables_present: "drawers,tunnels,diary".to_string(),
            created_at: 1_700_000_000,
            last_modified: 1_700_000_000,
            bitmap_layout_version: "v1.0".to_string(),
            provenance_bitmap_version: "v1".to_string(),
            federation_group_id: None,
            mining_patterns_hash: None,
            tiny_model_id: None,
            tiny_model_training_corpus_size: None,
            operational_bitmap_layouts: None,
        };
        let mv2 = mv.clone();
        assert_eq!(mv, mv2);
        assert_eq!(mv.bitmap_layout_version, "v1.0");
    }
}
