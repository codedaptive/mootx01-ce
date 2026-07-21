//! Canonical, deterministic layout signature for a `SchemaDeclaration`
//! (GLK shared-content 1.1, P0). Rust twin of Swift
//! `SchemaLayoutSignature.swift`.
//!
//! Migration detection must key on the DECLARED STRUCTURE of an estate —
//! table names, column layouts, keys, and indices — never on a copied
//! version comment or one magic legacy version number. This module renders
//! a `SchemaDeclaration` to a canonical text form that is byte-identical
//! across the Swift and Rust ports for equivalent declarations.
//!
//! The signature is purely structural: kit_id and version are deliberately
//! EXCLUDED (a version number is an assertion; the layout is the fact).
//! Column order follows declaration order (physical layout order in SQL
//! backends); tables and indices are sorted by name so composition order
//! does not leak into the signature.

use crate::schema::{ColumnRole, IndexDeclaration, SchemaDeclaration, TableDeclaration};
use crate::types::ColumnType;
use std::fmt::Write as _;

/// FNV-1a 64-bit offset basis — mirrors Swift `SchemaLayoutFNV.offsetBasis`.
pub const FNV1A64_OFFSET_BASIS: u64 = 14_695_981_039_346_656_037;
/// FNV-1a 64-bit prime — mirrors Swift `SchemaLayoutFNV.prime`.
pub const FNV1A64_PRIME: u64 = 1_099_511_628_211;

/// Fold `bytes` into an FNV-1a 64 hash state.
pub fn fnv1a64_fold(bytes: &[u8], mut hash: u64) -> u64 {
    for &b in bytes {
        hash = (hash ^ u64::from(b)).wrapping_mul(FNV1A64_PRIME);
    }
    hash
}

/// Canonical name of a column type in the layout signature. Matches the
/// Swift `ColumnType` String raw values exactly.
fn column_type_name(t: ColumnType) -> &'static str {
    match t {
        ColumnType::Uuid => "uuid",
        ColumnType::Bitmap => "bitmap",
        ColumnType::Text => "text",
        ColumnType::Timestamp => "timestamp",
        ColumnType::Float => "float",
        ColumnType::Int => "int",
        ColumnType::Bool => "bool",
        ColumnType::Blob => "blob",
        ColumnType::Json => "json",
        ColumnType::Hlc => "hlc",
        ColumnType::Fingerprint => "fingerprint",
    }
}

/// Canonical name of a column role. Matches the Swift `ColumnRole`
/// String raw values exactly.
fn column_role_name(role: ColumnRole) -> &'static str {
    match role {
        ColumnRole::CreatedHlc => "createdHlc",
        ColumnRole::TombstonedHlc => "tombstonedHlc",
    }
}

/// Canonical layout signature text for one table. See
/// [`layout_signature_text`] for the format contract.
pub fn table_layout_signature_text(table: &TableDeclaration) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "table={}", table.name);
    for column in &table.columns {
        let def = match &column.default_value {
            Some(value) => value.type_description(),
            None => "-",
        };
        let role = match column.role {
            Some(r) => column_role_name(r),
            None => "-",
        };
        let _ = writeln!(
            out,
            "  col={} type={} null={} default={} role={}",
            column.name,
            column_type_name(column.column_type),
            u8::from(column.nullable),
            def,
            role
        );
    }
    for gen in &table.generated_columns {
        let _ = writeln!(
            out,
            "  gen={} type={}",
            gen.name,
            column_type_name(gen.column_type)
        );
    }
    let _ = writeln!(out, "  pk={}", table.primary_key.join(","));
    for constraint in &table.unique_constraints {
        let _ = writeln!(out, "  unique={}", constraint.join(","));
    }
    let _ = writeln!(
        out,
        "  appendOnly={} hashable={}",
        u8::from(table.append_only),
        u8::from(table.hashable)
    );
    out
}

/// Canonical layout signature text for a whole declaration.
///
/// Line-oriented, one trailing `\n` per line. Cross-port stable: the Swift
/// twin (`SchemaDeclaration.layoutSignatureText()`) produces byte-identical
/// output for an equivalent declaration.
pub fn layout_signature_text(schema: &SchemaDeclaration) -> String {
    let mut out = String::new();
    let mut tables: Vec<&TableDeclaration> = schema.tables.iter().collect();
    tables.sort_by(|a, b| a.name.cmp(&b.name));
    for table in tables {
        out.push_str(&table_layout_signature_text(table));
    }
    let mut indices: Vec<&IndexDeclaration> = schema.indices.iter().collect();
    indices.sort_by(|a, b| a.name.cmp(&b.name));
    for index in indices {
        let _ = writeln!(
            out,
            "index={} table={} cols={} unique={}",
            index.name,
            index.table,
            index.columns.join(","),
            u8::from(index.unique)
        );
    }
    out
}

/// FNV-1a 64 digest of [`layout_signature_text`], lowercase hex.
///
/// A compact fingerprint for logs and quick comparison. NOT a cryptographic
/// attestation — parity gates should compare the full signature text.
pub fn layout_signature_digest(schema: &SchemaDeclaration) -> String {
    let text = layout_signature_text(schema);
    format!(
        "{:016x}",
        fnv1a64_fold(text.as_bytes(), FNV1A64_OFFSET_BASIS)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{ColumnDeclaration, IndexDeclaration, TableDeclaration};

    fn sample_schema() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "SampleKit",
            3,
            vec![
                TableDeclaration::new(
                    "zeta",
                    vec![
                        ColumnDeclaration::uuid("id"),
                        ColumnDeclaration::text("name").nullable(),
                    ],
                    vec!["id".to_string()],
                ),
                TableDeclaration::new(
                    "alpha",
                    vec![
                        ColumnDeclaration::uuid("id"),
                        ColumnDeclaration::int("rank"),
                    ],
                    vec!["id".to_string()],
                )
                .with_unique_constraints(vec![vec!["rank".to_string()]]),
            ],
        )
        .with_indices(vec![IndexDeclaration::new(
            "idx_alpha_rank",
            "alpha",
            vec!["rank".to_string()],
        )])
    }

    /// Frozen cross-port fixture — must match the Swift twin
    /// (`SchemaLayoutSignatureTests.expectedSampleSignature`) byte for byte.
    #[test]
    fn signature_matches_cross_port_fixture() {
        let expected = "\
table=alpha
  col=id type=uuid null=0 default=- role=-
  col=rank type=int null=0 default=- role=-
  pk=id
  unique=rank
  appendOnly=0 hashable=0
table=zeta
  col=id type=uuid null=0 default=- role=-
  col=name type=text null=1 default=- role=-
  pk=id
  appendOnly=0 hashable=0
index=idx_alpha_rank table=alpha cols=rank unique=0
";
        assert_eq!(layout_signature_text(&sample_schema()), expected);
    }

    #[test]
    fn signature_sorts_tables_and_keeps_column_order() {
        let text = layout_signature_text(&sample_schema());
        let alpha_pos = text.find("table=alpha").unwrap();
        let zeta_pos = text.find("table=zeta").unwrap();
        assert!(alpha_pos < zeta_pos, "tables must sort by name");
        assert!(text.contains("  col=id type=uuid null=0 default=- role=-\n"));
        assert!(text.contains("  unique=rank\n"));
        assert!(text.contains("index=idx_alpha_rank table=alpha cols=rank unique=0\n"));
    }

    #[test]
    fn signature_excludes_kit_id_and_version() {
        let a = layout_signature_text(&sample_schema());
        let mut renamed = sample_schema();
        renamed.kit_id = "OtherKit".to_string();
        renamed.version = 99;
        assert_eq!(a, layout_signature_text(&renamed));
    }

    #[test]
    fn digest_is_stable() {
        let schema = sample_schema();
        assert_eq!(
            layout_signature_digest(&schema),
            layout_signature_digest(&schema)
        );
    }
}
