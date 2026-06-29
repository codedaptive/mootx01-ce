//! Schema declaration types: SchemaDeclaration, TableDeclaration,
//! ColumnDeclaration, IndexDeclaration, Migration, SchemaOperation.

use crate::generated_column::GeneratedColumn;
use crate::types::{ColumnType, TypedValue};

#[derive(Debug, Clone)]
pub struct SchemaDeclaration {
    pub kit_id: String,
    pub version: i32,
    pub tables: Vec<TableDeclaration>,
    pub indices: Vec<IndexDeclaration>,
    pub migrations: Vec<Migration>,
}

impl SchemaDeclaration {
    pub fn new(kit_id: impl Into<String>, version: i32, tables: Vec<TableDeclaration>) -> Self {
        SchemaDeclaration {
            kit_id: kit_id.into(),
            version,
            tables,
            indices: Vec::new(),
            migrations: Vec::new(),
        }
    }

    pub fn with_indices(mut self, indices: Vec<IndexDeclaration>) -> Self {
        self.indices = indices;
        self
    }

    pub fn with_migrations(mut self, migrations: Vec<Migration>) -> Self {
        self.migrations = migrations;
        self
    }
}

#[derive(Debug, Clone)]
pub struct TableDeclaration {
    pub name: String,
    pub columns: Vec<ColumnDeclaration>,
    pub primary_key: Vec<String>,
    pub unique_constraints: Vec<Vec<String>>,
    /// Computed columns derived from an expression over other
    /// columns in the same row. SQLite and PostgreSQL emit native
    /// STORED generated columns; InMemory materializes them on
    /// every row write. Index one with an ordinary IndexDeclaration
    /// that names it.
    pub generated_columns: Vec<GeneratedColumn>,
    /// When true, the table rejects UPDATE and DELETE. SQLite emits
    /// a BEFORE UPDATE / BEFORE DELETE trigger pair; PostgreSQL
    /// attaches a BEFORE UPDATE OR DELETE trigger; InMemory rejects
    /// in row update / delete with StorageError::AppendOnlyViolation.
    /// INSERT remains allowed.
    pub append_only: bool,
    /// When true, the hash-on-write hook computes a ContentHash for
    /// every insert, update, and upsert on this table's rows. The
    /// hash is supplied by a `ContentHashProvider` callback injected
    /// into `HashingRowStore`; PersistenceKit does not depend on
    /// substrate-lib or substrate-kernel (ADR-017 §16 / NT-P2).
    pub hashable: bool,
}

impl TableDeclaration {
    pub fn new(
        name: impl Into<String>,
        columns: Vec<ColumnDeclaration>,
        primary_key: Vec<String>,
    ) -> Self {
        TableDeclaration {
            name: name.into(),
            columns,
            primary_key,
            unique_constraints: Vec::new(),
            generated_columns: Vec::new(),
            append_only: false,
            hashable: false,
        }
    }

    pub fn with_unique_constraints(mut self, constraints: Vec<Vec<String>>) -> Self {
        self.unique_constraints = constraints;
        self
    }

    pub fn with_generated_columns(mut self, generated: Vec<GeneratedColumn>) -> Self {
        self.generated_columns = generated;
        self
    }

    pub fn append_only(mut self) -> Self {
        self.append_only = true;
        self
    }

    /// Marks this table for hash-on-write: every insert, update, and
    /// upsert computes a ContentHash via a caller-supplied callback
    /// (ADR-017 §16 / NT-P2).
    pub fn hashable(mut self) -> Self {
        self.hashable = true;
        self
    }

    /// Returns the column name tagged with `CreatedHlc` role, if any.
    pub fn created_hlc_column(&self) -> Option<&str> {
        self.columns
            .iter()
            .find(|c| c.role == Some(ColumnRole::CreatedHlc))
            .map(|c| c.name.as_str())
    }

    /// Returns the column name tagged with `TombstonedHlc` role, if any.
    pub fn tombstoned_hlc_column(&self) -> Option<&str> {
        self.columns
            .iter()
            .find(|c| c.role == Some(ColumnRole::TombstonedHlc))
            .map(|c| c.name.as_str())
    }

    /// True when the table declares temporal validity columns
    /// and can participate in as-of filtering.
    pub fn supports_as_of_filter(&self) -> bool {
        self.created_hlc_column().is_some()
    }
}

/// Semantic role of a column within the as-of temporal filter
/// (ADR-017 §15). Columns tagged with a role participate in the
/// temporal validity window: `created_hlc <= T AND
/// (tombstoned_hlc IS NULL OR tombstoned_hlc > T)`.
/// Kits declare roles at schema time; PersistenceKit uses them to
/// push the filter into the engine without knowing kit-specific
/// column names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnRole {
    /// The HLC at which the row became valid.
    CreatedHlc,
    /// The HLC at which the row was superseded or deleted. Nullable
    /// by convention — a nil tombstone means "still live."
    TombstonedHlc,
}

#[derive(Debug, Clone)]
pub struct ColumnDeclaration {
    pub name: String,
    pub column_type: ColumnType,
    pub nullable: bool,
    pub default_value: Option<TypedValue>,
    /// Semantic role for temporal filtering. None means the column
    /// has no special role in the as-of filter.
    pub role: Option<ColumnRole>,
}

impl ColumnDeclaration {
    pub fn new(name: impl Into<String>, column_type: ColumnType) -> Self {
        ColumnDeclaration {
            name: name.into(),
            column_type,
            nullable: false,
            default_value: None,
            role: None,
        }
    }

    pub fn nullable(mut self) -> Self {
        self.nullable = true;
        self
    }

    pub fn with_default(mut self, value: TypedValue) -> Self {
        self.default_value = Some(value);
        self
    }

    // Convenience constructors mirroring Swift extensions.
    pub fn uuid(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Uuid)
    }
    pub fn bitmap(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Bitmap)
    }
    pub fn text(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Text)
    }
    pub fn timestamp(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Timestamp)
    }
    pub fn int(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Int)
    }
    pub fn float(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Float)
    }
    pub fn bool_col(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Bool)
    }
    pub fn blob(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Blob)
    }
    pub fn json(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Json)
    }
    pub fn hlc(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Hlc)
    }
    /// HLC column tagged as the row-creation timestamp for
    /// as-of temporal filtering (ADR-017 §15).
    pub fn created_hlc(name: impl Into<String>) -> Self {
        let mut col = Self::new(name, ColumnType::Hlc);
        col.role = Some(ColumnRole::CreatedHlc);
        col
    }
    /// HLC column tagged as the row-tombstone timestamp for
    /// as-of temporal filtering (ADR-017 §15). Nullable by
    /// convention — a nil tombstone means "still live."
    pub fn tombstoned_hlc(name: impl Into<String>) -> Self {
        let mut col = Self::new(name, ColumnType::Hlc);
        col.nullable = true;
        col.role = Some(ColumnRole::TombstonedHlc);
        col
    }
    pub fn fingerprint(name: impl Into<String>) -> Self {
        Self::new(name, ColumnType::Fingerprint)
    }
    /// Builder: set the column role for temporal filtering.
    pub fn with_role(mut self, role: ColumnRole) -> Self {
        self.role = Some(role);
        self
    }
}

#[derive(Debug, Clone)]
pub struct IndexDeclaration {
    pub name: String,
    pub table: String,
    pub columns: Vec<String>,
    pub unique: bool,
}

impl IndexDeclaration {
    pub fn new(name: impl Into<String>, table: impl Into<String>, columns: Vec<String>) -> Self {
        IndexDeclaration {
            name: name.into(),
            table: table.into(),
            columns,
            unique: false,
        }
    }

    pub fn unique(mut self) -> Self {
        self.unique = true;
        self
    }
}

#[derive(Debug, Clone)]
pub struct Migration {
    pub from_version: i32,
    pub to_version: i32,
    pub operations: Vec<SchemaOperation>,
}

#[derive(Debug, Clone)]
pub enum SchemaOperation {
    CreateTable(TableDeclaration),
    DropTable {
        name: String,
    },
    AddColumn {
        table: String,
        column: ColumnDeclaration,
    },
    DropColumn {
        table: String,
        column_name: String,
    },
    RenameColumn {
        table: String,
        from: String,
        to: String,
    },
    AddIndex(IndexDeclaration),
    DropIndex {
        name: String,
    },
    /// Per-backend SQL escape hatch. Optional strings for each
    /// backend keep the migration portable.
    Custom {
        sqlite: Option<String>,
        postgresql: Option<String>,
    },
}
