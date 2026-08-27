//! Adornment identity value types.
//!
//! Pure, persistence-neutral carriers for one registered minter
//! (`AdornmentMinterDescriptor`) and one stored adornment (`StoredAdornment`).
//! Ports `AdornmentIdentity.swift` — same field semantics, Rust naming
//! conventions (snake_case).
//!
//! Design invariants:
//!   - A configuration change creates a new `AdornmentMinterDescriptor`; the
//!     `id` field is the opaque stable reference. `is_active` is the only
//!     mutable field on an existing descriptor.
//!   - `StoredAdornment` carries only the two FK references and the generated
//!     text. Drawer content and minter metadata are references to their owning
//!     records; they are NEVER copied here.
//!   - `parameters` uses `BTreeMap` so that iteration order is always
//!     lexicographic, matching the Swift canonical-key-order serialization
//!     contract.

use std::collections::BTreeMap;

// MARK: - AdornmentMinterDescriptor

/// Reusable configuration identity of one adornment minter.
///
/// Represents one row in the minter master table. Every generation-affecting
/// setting is captured here so a configuration change is a NEW row, not an
/// update to an existing one. `is_active` is the only mutable field:
/// activation and deactivation toggle `is_active` on the existing row.
///
/// `parameters` captures every generation-affecting parameter (temperature,
/// top-p, seed, etc.) as a sorted string-to-string map. The `BTreeMap`
/// ensures lexicographic iteration order, which matches the Swift canonical
/// key-order serialization contract for the minter's JSON `parameters` column.
///
/// Mirrors Swift `AdornmentMinterDescriptor`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AdornmentMinterDescriptor {
    /// Opaque descriptor identifier assigned by the persistence owner (LocusKit).
    pub id: String,
    /// Stable, human-readable minter name.
    pub name: String,
    /// Minter family (e.g. "apple", "candle").
    pub family: String,
    /// Model identifier (e.g. "apple-gen1").
    pub model_id: String,
    /// Model version or revision string (e.g. "2026-07", "v1.2").
    pub model_version: String,
    /// Digest of the prompt template (SHA-256 hex or equivalent fingerprint).
    pub prompt_digest: String,
    /// Every generation-affecting parameter. BTreeMap for lexicographic
    /// iteration order (matches Swift canonical key-order serialization).
    pub parameters: BTreeMap<String, String>,
    /// Whether this minter is currently active. The ONLY mutable field.
    pub is_active: bool,
}

impl AdornmentMinterDescriptor {
    /// Construct a descriptor value.
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        family: impl Into<String>,
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        prompt_digest: impl Into<String>,
        parameters: BTreeMap<String, String>,
        is_active: bool,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            family: family.into(),
            model_id: model_id.into(),
            model_version: model_version.into(),
            prompt_digest: prompt_digest.into(),
            parameters,
            is_active,
        }
    }
}

// MARK: - StoredAdornment

/// One persistent output from an adornment minter.
///
/// Represents one row in the `adornments` table with composite primary key
/// `(drawer_id, minter_id)`. Only the two FK references and the generated
/// text are stored; Drawer content and minter metadata live in their owning
/// records.
///
/// Mirrors Swift `StoredAdornment`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredAdornment {
    /// Identifier of the Drawer this adornment was produced for.
    pub drawer_id: String,
    /// Identifier of the minter that produced this adornment.
    pub minter_id: String,
    /// The generated adornment text.
    pub text: String,
}

impl StoredAdornment {
    /// Construct a stored adornment value.
    pub fn new(
        drawer_id: impl Into<String>,
        minter_id: impl Into<String>,
        text: impl Into<String>,
    ) -> Self {
        Self {
            drawer_id: drawer_id.into(),
            minter_id: minter_id.into(),
            text: text.into(),
        }
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    /// Golden pin: descriptor round-trips through clone with identical fields.
    #[test]
    fn descriptor_clone_equality() {
        let mut params = BTreeMap::new();
        params.insert("temperature".to_string(), "0.7".to_string());
        params.insert("top_p".to_string(), "0.9".to_string());

        let d = AdornmentMinterDescriptor::new(
            "minter-001",
            "Apple Gen1",
            "apple",
            "apple-gen1",
            "2026-07",
            "abc123",
            params,
            true,
        );
        let cloned = d.clone();
        assert_eq!(d, cloned);
    }

    /// Golden pin: stored adornment carries the exact references.
    #[test]
    fn stored_adornment_fields() {
        let sa = StoredAdornment::new("drawer-abc", "minter-001", "Stated facts; key claim");
        assert_eq!(sa.drawer_id, "drawer-abc");
        assert_eq!(sa.minter_id, "minter-001");
        assert_eq!(sa.text, "Stated facts; key claim");
    }

    /// BTreeMap parameter ordering: iteration produces lexicographic key order,
    /// matching the Swift canonical-serialization contract.
    #[test]
    fn parameters_lexicographic_order() {
        let mut params = BTreeMap::new();
        params.insert("top_p".to_string(), "0.9".to_string());
        params.insert("seed".to_string(), "42".to_string());
        params.insert("temperature".to_string(), "0.7".to_string());

        let keys: Vec<&str> = params.keys().map(|s| s.as_str()).collect();
        // BTreeMap iterates in ascending key order.
        assert_eq!(keys, vec!["seed", "temperature", "top_p"]);
    }

    /// Two descriptors with different is_active values are not equal.
    #[test]
    fn descriptor_activation_equality() {
        let params = BTreeMap::new();
        let active = AdornmentMinterDescriptor::new(
            "m1", "M", "apple", "model-a", "v1", "digest", params.clone(), true,
        );
        let inactive = AdornmentMinterDescriptor::new(
            "m1", "M", "apple", "model-a", "v1", "digest", params, false,
        );
        assert_ne!(active, inactive);
    }
}
