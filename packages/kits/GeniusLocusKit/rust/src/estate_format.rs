//! Stable GLK estate-format identity owned by the current runtime.
//!
//! Concrete historical migrations live in the optional sibling migration
//! crate. Core knows only how to stamp a fresh estate and require the one
//! format it can serve.

use persistence_kit::{
    Column, ColumnDeclaration, SchemaDeclaration, Storage, StoragePredicate, TableDeclaration,
    TypedValue,
};
use std::collections::BTreeMap;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct EstateFormatVersion {
    pub major: u32,
    pub minor: u32,
}

impl EstateFormatVersion {
    pub const V1_0: Self = Self { major: 1, minor: 0 };
    pub const V1_1: Self = Self { major: 1, minor: 1 };
    pub const CURRENT: Self = Self::V1_1;
}

impl std::fmt::Display for EstateFormatVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}", self.major, self.minor)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EstateFormatError {
    MigrationRequired {
        current: EstateFormatVersion,
    },
    Unsupported {
        found: EstateFormatVersion,
        current: EstateFormatVersion,
    },
    Storage(String),
}

pub struct EstateFormatStore {
    storage: Arc<dyn Storage>,
}

impl EstateFormatStore {
    const SINGLETON_ID: &'static str = "estate-format";

    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "GLKEstateFormat",
            1,
            vec![TableDeclaration::new(
                "glk_estate_format",
                vec![
                    ColumnDeclaration::text("id"),
                    ColumnDeclaration::int("major"),
                    ColumnDeclaration::int("minor"),
                    ColumnDeclaration::timestamp("updated_at"),
                ],
                vec!["id".to_string()],
            )],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        Self { storage }
    }

    /// Read without creating the table. Missing table/row means unstamped.
    pub fn read_if_present(&self) -> Result<Option<EstateFormatVersion>, EstateFormatError> {
        let registered = self
            .storage
            .current_schema_version_for("GLKEstateFormat")
            .map_err(|error| EstateFormatError::Storage(format!("{error:?}")))?;
        let rows = match self.storage.row_store().query(
            "glk_estate_format",
            Some(&StoragePredicate::Eq(
                Column::new("glk_estate_format", "id"),
                TypedValue::Text(Self::SINGLETON_ID.to_string()),
            )),
            &[],
            Some(1),
            None,
        ) {
            Ok(rows) => rows,
            Err(_) if registered == 0 => return Ok(None),
            Err(error) => return Err(EstateFormatError::Storage(format!("{error:?}"))),
        };
        let Some(row) = rows.first() else {
            if registered == 0 {
                return Ok(None);
            }
            return Err(EstateFormatError::Storage(
                "registered singleton row is missing".to_string(),
            ));
        };
        let major = match row.get("major") {
            Some(TypedValue::Int(value)) => *value,
            _ => {
                return Err(EstateFormatError::Storage(
                    "registered singleton major is malformed".to_string(),
                ))
            }
        };
        let minor = match row.get("minor") {
            Some(TypedValue::Int(value)) => *value,
            _ => {
                return Err(EstateFormatError::Storage(
                    "registered singleton minor is malformed".to_string(),
                ))
            }
        };
        Ok(Some(EstateFormatVersion {
            major: u32::try_from(major).map_err(|_| {
                EstateFormatError::Storage("negative estate-format major".to_string())
            })?,
            minor: u32::try_from(minor).map_err(|_| {
                EstateFormatError::Storage("negative estate-format minor".to_string())
            })?,
        }))
    }

    pub fn stamp(
        &self,
        version: EstateFormatVersion,
        now_millis: i64,
    ) -> Result<(), EstateFormatError> {
        self.storage
            .migrate(&Self::schema_declaration())
            .map_err(|error| EstateFormatError::Storage(format!("{error:?}")))?;
        let mut values = BTreeMap::new();
        values.insert(
            "id".to_string(),
            TypedValue::Text(Self::SINGLETON_ID.to_string()),
        );
        values.insert("major".to_string(), TypedValue::Int(version.major as i64));
        values.insert("minor".to_string(), TypedValue::Int(version.minor as i64));
        values.insert("updated_at".to_string(), TypedValue::Timestamp(now_millis));
        self.storage
            .row_store()
            .upsert("glk_estate_format", values, &["id".to_string()])
            .map_err(|error| EstateFormatError::Storage(format!("{error:?}")))?;
        Ok(())
    }

    pub fn require_current(&self) -> Result<(), EstateFormatError> {
        let Some(found) = self.read_if_present()? else {
            return Err(EstateFormatError::MigrationRequired {
                current: EstateFormatVersion::CURRENT,
            });
        };
        if found != EstateFormatVersion::CURRENT {
            return Err(EstateFormatError::Unsupported {
                found,
                current: EstateFormatVersion::CURRENT,
            });
        }
        Ok(())
    }
}
