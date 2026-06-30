// PostgreSQLIdentifierValidator.swift
//
// Module-level free function for SQL identifier validation in the
// PersistenceKitPostgreSQL target. Shared by PostgreSQLRowStore (row
// operations, table names, ORDER BY columns) and PostgreSQLPredicateCompiler
// (predicate column names). Factored out of the private method on
// PostgreSQLRowStore so both types in the same module call a single seam —
// no forked validator.
//
// The rule matches SQLiteIdentifierValidator.swift and the Rust
// `validate_sql_identifier` in error.rs: [A-Za-z_][A-Za-z0-9_]*.

import PersistenceKit

/// Validate a caller-supplied SQL identifier (column name, table name, ORDER BY
/// column) for the PostgreSQL backend.
///
/// Accepts only names matching `[A-Za-z_][A-Za-z0-9_]*`. Double-quoting is not
/// sufficient protection when a name contains `"` — that character escapes the
/// double-quote delimiter and can alter a dynamically-constructed SQL string.
/// Throws `StorageError.invalidIdentifier` for any name outside the safe set.
///
/// Mirrors the SQLite validator (`validateSQLIdentifier`) and the Rust
/// `validate_sql_identifier` in `error.rs` — identical rule, three single
/// seams, one per module (SECFIX-WS2-PK F7/F9/F10).
func validatePSQLIdentifier(_ name: String) throws {
    guard !name.isEmpty else {
        throw StorageError.invalidIdentifier(name: name)
    }
    for (index, char) in name.unicodeScalars.enumerated() {
        let valid: Bool
        if index == 0 {
            // First character: letter or underscore.
            valid = (char >= "A" && char <= "Z")
                || (char >= "a" && char <= "z")
                || char == "_"
        } else {
            // Subsequent characters: letter, digit, or underscore.
            valid = (char >= "A" && char <= "Z")
                || (char >= "a" && char <= "z")
                || (char >= "0" && char <= "9")
                || char == "_"
        }
        guard valid else {
            throw StorageError.invalidIdentifier(name: name)
        }
    }
}
