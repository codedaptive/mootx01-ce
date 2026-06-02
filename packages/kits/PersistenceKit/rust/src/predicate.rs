//! Closed-enum predicate algebra.
//!
//! Mirror of Swift's `StoragePredicate`. Three operator families:
//! logical, comparison, bitmap. Backends compile to native
//! query languages; the kit treats the predicate as opaque
//! except for compilation.

use crate::types::{Column, TypedValue};

#[derive(Debug, Clone)]
pub enum StoragePredicate {
    // Logical
    And(Vec<StoragePredicate>),
    Or(Vec<StoragePredicate>),
    Not(Box<StoragePredicate>),
    IsTrue,
    IsFalse,

    // Comparison
    Eq(Column, TypedValue),
    Neq(Column, TypedValue),
    Lt(Column, TypedValue),
    Lte(Column, TypedValue),
    Gt(Column, TypedValue),
    Gte(Column, TypedValue),
    IsNull(Column),
    IsNotNull(Column),
    In(Column, Vec<TypedValue>),
    Like(Column, String),

    // Bitmap (Int64 / Bitmap columns only)
    BitmaskAll {
        column: Column,
        mask: i64,
    },
    BitmaskAny {
        column: Column,
        mask: i64,
    },
    BitmaskNone {
        column: Column,
        mask: i64,
    },
    BitwiseEq {
        column: Column,
        expected: i64,
        mask: i64,
    },
}

impl StoragePredicate {
    /// Combine predicates with AND, short-circuiting trivial
    /// cases. Mirror of Swift's `StoragePredicate.all`.
    pub fn all(predicates: Vec<StoragePredicate>) -> StoragePredicate {
        let mut filtered: Vec<StoragePredicate> = predicates
            .into_iter()
            .filter(|p| !matches!(p, StoragePredicate::IsTrue))
            .collect();
        if filtered.is_empty() {
            return StoragePredicate::IsTrue;
        }
        if filtered
            .iter()
            .any(|p| matches!(p, StoragePredicate::IsFalse))
        {
            return StoragePredicate::IsFalse;
        }
        if filtered.len() == 1 {
            return filtered.remove(0);
        }
        StoragePredicate::And(filtered)
    }

    /// Combine predicates with OR. Mirror of Swift's
    /// `StoragePredicate.any`.
    pub fn any(predicates: Vec<StoragePredicate>) -> StoragePredicate {
        let mut filtered: Vec<StoragePredicate> = predicates
            .into_iter()
            .filter(|p| !matches!(p, StoragePredicate::IsFalse))
            .collect();
        if filtered.is_empty() {
            return StoragePredicate::IsFalse;
        }
        if filtered
            .iter()
            .any(|p| matches!(p, StoragePredicate::IsTrue))
        {
            return StoragePredicate::IsTrue;
        }
        if filtered.len() == 1 {
            return filtered.remove(0);
        }
        StoragePredicate::Or(filtered)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderDirection {
    Ascending,
    Descending,
}

#[derive(Debug, Clone)]
pub struct OrderClause {
    pub column: Column,
    pub direction: OrderDirection,
}

impl OrderClause {
    pub fn new(column: Column, direction: OrderDirection) -> Self {
        OrderClause { column, direction }
    }

    pub fn ascending(column: Column) -> Self {
        OrderClause {
            column,
            direction: OrderDirection::Ascending,
        }
    }

    pub fn descending(column: Column) -> Self {
        OrderClause {
            column,
            direction: OrderDirection::Descending,
        }
    }
}
