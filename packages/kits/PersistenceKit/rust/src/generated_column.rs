//! Generated (computed) columns and the structured expression
//! algebra that defines them. Rust mirror of the Swift
//! GeneratedColumn / GeneratedExpression types.
//!
//! A structured expression has exactly one meaning that every
//! backend realizes faithfully: SQLite and PostgreSQL render it to
//! identical bit-operator DDL inside GENERATED ALWAYS AS (...)
//! STORED; the InMemory backend evaluates it directly against the
//! row at write time. One expression, three faithful realizations,
//! no SQL-text escape hatch. All three backends ship in the Rust
//! version: InMemory evaluates directly, and the SQLite and
//! PostgreSQL backends render the expression via render_sql.

use crate::types::{ColumnType, TypedValue};
use std::collections::BTreeMap;

/// A column whose value is computed from an expression over other
/// columns in the same row. Always STORED: PostgreSQL has no
/// VIRTUAL generated columns, so STORED is the only representation
/// both SQL backends honor identically. The InMemory backend
/// materializes the value on every row write.
#[derive(Debug, Clone, PartialEq)]
pub struct GeneratedColumn {
    pub name: String,
    /// Result type. Typically Int, Bitmap, or Bool. Drives the SQL
    /// column type and the InMemory stored TypedValue variant.
    pub column_type: ColumnType,
    pub expression: GeneratedExpression,
}

impl GeneratedColumn {
    pub fn new(
        name: impl Into<String>,
        column_type: ColumnType,
        expression: GeneratedExpression,
    ) -> Self {
        GeneratedColumn {
            name: name.into(),
            column_type,
            expression,
        }
    }
}

/// Structured integer expression over row columns. Covers the
/// bit-field algebra the GeniusLocus substrate needs: masking,
/// field extraction via shift-then-mask, and presence tests.
/// Evaluates to an i64 (booleans are 0 or 1) so a single evaluator
/// and a single SQL renderer serve every backend.
#[derive(Debug, Clone, PartialEq)]
pub enum GeneratedExpression {
    /// Reference another column in the same row. The referenced
    /// column must hold an integer-family value (Int, Bitmap, Bool,
    /// or Hlc); other variants evaluate to 0.
    Column(String),
    /// A constant.
    Literal(i64),
    BitAnd(Box<GeneratedExpression>, Box<GeneratedExpression>),
    BitOr(Box<GeneratedExpression>, Box<GeneratedExpression>),
    BitXor(Box<GeneratedExpression>, Box<GeneratedExpression>),
    ShiftRight(Box<GeneratedExpression>, u8),
    ShiftLeft(Box<GeneratedExpression>, u8),
    /// Equality test. Evaluates to 1 when equal, 0 otherwise.
    Equal(Box<GeneratedExpression>, Box<GeneratedExpression>),
    /// Inequality test. Evaluates to 1 when not equal, 0 otherwise.
    NotEqual(Box<GeneratedExpression>, Box<GeneratedExpression>),
}

impl GeneratedExpression {
    /// Render to SQL text. SQLite and PostgreSQL share identical
    /// syntax for integer bit operators and double-quoted
    /// identifiers, so one renderer serves both. Equality is
    /// rendered through CASE so the result is an integer 0/1 on both
    /// backends rather than a native boolean.
    pub fn render_sql(&self) -> String {
        match self {
            GeneratedExpression::Column(name) => format!("\"{}\"", name),
            GeneratedExpression::Literal(value) => value.to_string(),
            GeneratedExpression::BitAnd(lhs, rhs) => {
                format!("({} & {})", lhs.render_sql(), rhs.render_sql())
            }
            GeneratedExpression::BitOr(lhs, rhs) => {
                format!("({} | {})", lhs.render_sql(), rhs.render_sql())
            }
            GeneratedExpression::BitXor(lhs, rhs) => {
                // SQLite lacks a binary XOR operator; both backends
                // can express it as (a | b) - (a & b).
                let a = lhs.render_sql();
                let b = rhs.render_sql();
                format!("(({} | {}) - ({} & {}))", a, b, a, b)
            }
            GeneratedExpression::ShiftRight(expr, bits) => {
                format!("({} >> {})", expr.render_sql(), bits)
            }
            GeneratedExpression::ShiftLeft(expr, bits) => {
                format!("({} << {})", expr.render_sql(), bits)
            }
            GeneratedExpression::Equal(lhs, rhs) => format!(
                "(CASE WHEN {} = {} THEN 1 ELSE 0 END)",
                lhs.render_sql(),
                rhs.render_sql()
            ),
            GeneratedExpression::NotEqual(lhs, rhs) => format!(
                "(CASE WHEN {} <> {} THEN 1 ELSE 0 END)",
                lhs.render_sql(),
                rhs.render_sql()
            ),
        }
    }

    /// Evaluate against a row for the InMemory backend. Returns the
    /// integer result; the caller wraps it in the GeneratedColumn's
    /// declared TypedValue variant.
    pub fn evaluate(&self, row: &BTreeMap<String, TypedValue>) -> i64 {
        match self {
            GeneratedExpression::Column(name) => integer_value(row.get(name)),
            GeneratedExpression::Literal(value) => *value,
            GeneratedExpression::BitAnd(lhs, rhs) => lhs.evaluate(row) & rhs.evaluate(row),
            GeneratedExpression::BitOr(lhs, rhs) => lhs.evaluate(row) | rhs.evaluate(row),
            GeneratedExpression::BitXor(lhs, rhs) => lhs.evaluate(row) ^ rhs.evaluate(row),
            GeneratedExpression::ShiftRight(expr, bits) => {
                // Logical shift over the bit pattern, matching SQLite
                // and PostgreSQL for non-negative operands.
                ((expr.evaluate(row) as u64) >> (*bits as u64)) as i64
            }
            GeneratedExpression::ShiftLeft(expr, bits) => {
                ((expr.evaluate(row) as u64) << (*bits as u64)) as i64
            }
            GeneratedExpression::Equal(lhs, rhs) => {
                if lhs.evaluate(row) == rhs.evaluate(row) {
                    1
                } else {
                    0
                }
            }
            GeneratedExpression::NotEqual(lhs, rhs) => {
                if lhs.evaluate(row) != rhs.evaluate(row) {
                    1
                } else {
                    0
                }
            }
        }
    }
}

/// Extract an integer from an integer-family TypedValue. Other
/// variants (and absent columns) read as 0, matching the SQL
/// behavior where a generated column over a NULL integer column is
/// coalesced to 0 by the surrounding bit operations.
pub fn integer_value(value: Option<&TypedValue>) -> i64 {
    match value {
        Some(TypedValue::Int(i)) | Some(TypedValue::Bitmap(i)) => *i,
        Some(TypedValue::Bool(b)) if *b => 1,
        Some(TypedValue::Hlc(h)) => h.packed() as i64,
        _ => 0,
    }
}
