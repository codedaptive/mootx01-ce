// SQLiteIdentifierValidator.swift
//
// Module-level free function for SQL identifier validation in the
// PersistenceKitSQLite target. Shared by SQLiteStorage (row operations,
// table names, ORDER BY columns) and SQLitePredicateCompiler (predicate
// column names). Factored out of the private method on SQLiteStorage so both
// types in the same module can call a single seam — no forked validator.
//
// The rule: [A-Za-z_][A-Za-z0-9_]* — the safe subset of SQLite identifier
// syntax. Any name declared by LocusKit's schema passes; the gate rejects
// adversarial inputs before they can alter a dynamically-constructed SQL string.
// Double-quoting alone is insufficient: a name containing `"` breaks the
// delimiter and can change the query semantics.

import PersistenceKit

/// Validate a caller-supplied SQL identifier (column name, table name, ORDER BY
/// column).
///
/// Accepts only names matching `[A-Za-z_][A-Za-z0-9_]*`. Double-quoting is not
/// sufficient protection when a name contains `"` — that character escapes the
/// double-quote delimiter and can alter a dynamically-constructed SQL string.
/// Throws `StorageError.invalidIdentifier` for any name outside the safe set.
///
/// This is the single validation seam for the PersistenceKitSQLite module.
/// Both `SQLiteStorage` and `SQLitePredicateCompiler` call it rather than
/// maintaining independent copies of the rule (SECFIX-WS2-PK F7/F9/F10).
func validateSQLIdentifier(_ name: String) throws {
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
