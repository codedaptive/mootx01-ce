// GeneratedColumn.swift
//
// First-class generated (computed) columns and the structured
// expression algebra that defines them. Added to support the
// GeniusLocus bitmap layout: LocusKit declares functional columns
// such as the state cluster `(adjective_bitmap & 0xF)` or a
// six-bit field extract `(adjective_bitmap >> 6) & 0x3F`, then
// indexes them with an ordinary IndexDeclaration. (Field semantics:
// LocusKit/Adjectives.swift is the source of truth for the adjective
// axes; PersistenceKit cannot import it — LocusKit depends on
// PersistenceKit — so this file sees only the raw bit algebra.)
//
// Why structured, not a SQL string. A SQL-text generated column
// would be the same anti-pattern as SchemaOperation.custom: it
// pushes backend-specific text into the declaration, and the
// InMemory backend cannot evaluate arbitrary SQL. A structured
// expression has exactly one meaning that every backend realizes
// faithfully: SQLite and PostgreSQL render it to identical
// bit-operator DDL inside GENERATED ALWAYS AS (...) STORED;
// InMemory evaluates it directly against the row at write time.
// One expression, three faithful realizations, no escape hatch.

import Foundation
import SubstrateTypes
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

/// A column whose value is computed from an expression over other
/// columns in the same row. Always STORED: PostgreSQL has no
/// VIRTUAL generated columns, so STORED is the only representation
/// that both SQL backends honor identically. The InMemory backend
/// materializes the value on every row write.
public struct GeneratedColumn: Sendable, Equatable {
    public let name: String
    /// Result type of the expression. Typically `.int`, `.bitmap`,
    /// or `.bool`. Drives the SQL column type and the InMemory
    /// stored TypedValue case.
    public let type: ColumnType
    public let expression: GeneratedExpression

    public init(name: String, type: ColumnType, expression: GeneratedExpression) {
        self.name = name
        self.type = type
        self.expression = expression
    }
}

/// Structured integer expression over row columns. Covers the
/// bit-field algebra the GeniusLocus substrate needs: masking,
/// field extraction via shift-then-mask, and presence tests. The
/// expression evaluates to an `Int64` (booleans are 0 or 1) so a
/// single evaluator and a single SQL renderer serve every backend.
public indirect enum GeneratedExpression: Sendable, Equatable {
    /// Reference another column in the same row. The referenced
    /// column must hold an integer-family value (`.int`, `.bitmap`,
    /// `.bool`, or `.hlc`); other types evaluate to 0.
    case column(String)
    /// A constant. Masks like `0x3F` and shift results live here.
    case literal(Int64)
    /// Bitwise AND.
    case bitAnd(GeneratedExpression, GeneratedExpression)
    /// Bitwise OR.
    case bitOr(GeneratedExpression, GeneratedExpression)
    /// Bitwise XOR.
    case bitXor(GeneratedExpression, GeneratedExpression)
    /// Logical right shift by a fixed bit count.
    case shiftRight(GeneratedExpression, UInt8)
    /// Left shift by a fixed bit count.
    case shiftLeft(GeneratedExpression, UInt8)
    /// Equality test. Evaluates to 1 when equal, 0 otherwise.
    case equal(GeneratedExpression, GeneratedExpression)
    /// Inequality test. Evaluates to 1 when not equal, 0 otherwise.
    case notEqual(GeneratedExpression, GeneratedExpression)

    /// Render to SQL text. SQLite and PostgreSQL share identical
    /// syntax for integer bit operators (`&`, `|`, `<<`, `>>`) and
    /// double-quoted identifiers, so one renderer serves both.
    /// Equality is rendered through CASE so the result is an
    /// integer 0/1 on both backends rather than a native boolean
    /// (PostgreSQL's `=` yields BOOLEAN; SQLite's yields 0/1).
    public func renderSQL() -> String {
        switch self {
        case .column(let name):
            return "\"\(name)\""
        case .literal(let value):
            return String(value)
        case .bitAnd(let lhs, let rhs):
            return "(\(lhs.renderSQL()) & \(rhs.renderSQL()))"
        case .bitOr(let lhs, let rhs):
            return "(\(lhs.renderSQL()) | \(rhs.renderSQL()))"
        case .bitXor(let lhs, let rhs):
            // SQLite lacks a binary XOR operator; both backends can
            // express it as (a | b) - (a & b). PostgreSQL also
            // accepts that form, so the rendering stays shared.
            let a = lhs.renderSQL()
            let b = rhs.renderSQL()
            return "((\(a) | \(b)) - (\(a) & \(b)))"
        case .shiftRight(let expr, let bits):
            return "(\(expr.renderSQL()) >> \(bits))"
        case .shiftLeft(let expr, let bits):
            return "(\(expr.renderSQL()) << \(bits))"
        case .equal(let lhs, let rhs):
            return "(CASE WHEN \(lhs.renderSQL()) = \(rhs.renderSQL()) THEN 1 ELSE 0 END)"
        case .notEqual(let lhs, let rhs):
            return "(CASE WHEN \(lhs.renderSQL()) <> \(rhs.renderSQL()) THEN 1 ELSE 0 END)"
        }
    }

    /// Evaluate against a row for the InMemory backend. Returns the
    /// integer result; the caller wraps it in the GeneratedColumn's
    /// declared TypedValue case.
    public func evaluate(_ row: [String: TypedValue]) -> Int64 {
        switch self {
        case .column(let name):
            return GeneratedExpression.integerValue(row[name])
        case .literal(let value):
            return value
        case .bitAnd(let lhs, let rhs):
            return lhs.evaluate(row) & rhs.evaluate(row)
        case .bitOr(let lhs, let rhs):
            return lhs.evaluate(row) | rhs.evaluate(row)
        case .bitXor(let lhs, let rhs):
            return lhs.evaluate(row) ^ rhs.evaluate(row)
        case .shiftRight(let expr, let bits):
            // Logical shift over the bit pattern, matching SQLite
            // and PostgreSQL semantics for non-negative operands.
            return Int64(bitPattern: UInt64(bitPattern: expr.evaluate(row)) >> UInt64(bits))
        case .shiftLeft(let expr, let bits):
            return Int64(bitPattern: UInt64(bitPattern: expr.evaluate(row)) << UInt64(bits))
        case .equal(let lhs, let rhs):
            return lhs.evaluate(row) == rhs.evaluate(row) ? 1 : 0
        case .notEqual(let lhs, let rhs):
            return lhs.evaluate(row) != rhs.evaluate(row) ? 1 : 0
        }
    }

    /// Extract an integer from an integer-family TypedValue. Other
    /// cases (and absent columns) read as 0, matching the SQL
    /// behavior where a generated column over a NULL integer column
    /// is NULL-coalesced to 0 by the surrounding bit operations.
    static func integerValue(_ value: TypedValue?) -> Int64 {
        switch value {
        case .int(let i), .bitmap(let i): return i
        case .bool(let b): return b ? 1 : 0
        case .hlc(let h): return Int64(bitPattern: h.packed)
        default: return 0
        }
    }
}
