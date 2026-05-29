//! Schema declaration types: SchemaDeclaration, TableDeclaration,
//! ColumnDeclaration, IndexDeclaration, Migration, SchemaOperation.

use crate::types::{ColumnType, TypedValue};
use crate::generated_column::GeneratedColumn;

#[derive(Debug, Clone)]
pub struct SchemaDeclaration {
    pub kit_id: String,
    pub version: i32,
    pub tables: Vec<TableDeclaration>,
    pub indices: Vec<IndexDeclaration>,
    pub migrations: Vec<Migration>,
}

impl SchemaDeclaration {
    pub fn new(
        kit_id: impl Into<String>,
        version: i32,
        tables: Vec<TableDeclaration>,
    ) -> Self {
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
}

#[derive(Debug, Clone)]
pub struct ColumnDeclaration {
    pub name: String,
    pub column_type: ColumnType,
    pub nullable: bool,
    pub default_value: Option<TypedValue>,
}

impl ColumnDeclaration {
    pub fn new(name: impl Into<String>, column_type: ColumnType) -> Self {
        ColumnDeclaration {
            name: name.into(),
            column_type,
            nullable: false,
            default_value: None,
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
    pub fn uuid(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Uuid) }
    pub fn bitmap(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Bitmap) }
    pub fn text(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Text) }
    pub fn timestamp(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Timestamp) }
    pub fn int(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Int) }
    pub fn float(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Float) }
    pub fn bool_col(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Bool) }
    pub fn blob(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Blob) }
    pub fn json(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Json) }
    pub fn hlc(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Hlc) }
    pub fn fingerprint(name: impl Into<String>) -> Self { Self::new(name, ColumnType::Fingerprint) }
}

#[derive(Debug, Clone)]
pub struct IndexDeclaration {
    pub name: String,
    pub table: String,
    pub columns: Vec<String>,
    pub unique: bool,
}

impl IndexDeclaration {
    pub fn new(
        name: impl Into<String>,
        table: impl Into<String>,
        columns: Vec<String>,
    ) -> Self {
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
    DropTable { name: String },
    AddColumn { table: String, column: ColumnDeclaration },
    DropColumn { table: String, column_name: String },
    RenameColumn { table: String, from: String, to: String },
    AddIndex(IndexDeclaration),
    DropIndex { name: String },
    /// Per-backend SQL escape hatch. Optional strings for each
    /// backend keep the migration portable.
    Custom { sqlite: Option<String>, postgresql: Option<String> },
}
