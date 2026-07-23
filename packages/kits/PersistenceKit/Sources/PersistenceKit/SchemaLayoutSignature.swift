// SchemaLayoutSignature.swift
//
// Canonical, deterministic layout signature for a SchemaDeclaration
// (GLK shared-content 1.1, P0).
//
// Migration detection must key on the DECLARED STRUCTURE of an estate —
// table names, column layouts, keys, and indices — never on a copied
// version comment or one magic legacy version number. This file renders
// a SchemaDeclaration to a canonical text form that is byte-identical
// across the Swift and Rust ports for equivalent declarations, so:
//
//   - the composite-schema parity gate can freeze one signature fixture
//     and assert both ports derive it from their LIVE declarations; and
//   - the legacy-estate detector can compare a candidate layout against
//     the known legacy layouts structurally.
//
// The signature is purely structural: kitID and version are deliberately
// EXCLUDED (a version number is an assertion; the layout is the fact).
// Column order follows declaration order (physical layout order in SQL
// backends); tables and indices are sorted by name so composition order
// does not leak into the signature.

import Foundation

extension SchemaDeclaration {

    /// Canonical layout signature text for this declaration.
    ///
    /// Line-oriented, one trailing `\n` per line. Cross-port stable: the
    /// Rust twin (`SchemaDeclaration::layout_signature_text`) produces
    /// byte-identical output for an equivalent declaration.
    public func layoutSignatureText() -> String {
        var out = ""
        for table in tables.sorted(by: { $0.name < $1.name }) {
            out += table.layoutSignatureText()
        }
        for index in indices.sorted(by: { $0.name < $1.name }) {
            out += "index=\(index.name) table=\(index.table) "
                + "cols=\(index.columns.joined(separator: ",")) "
                + "unique=\(index.unique ? 1 : 0)\n"
        }
        return out
    }

    /// FNV-1a 64-bit digest of `layoutSignatureText()`, lowercase hex.
    ///
    /// A compact fingerprint for logs and quick comparison. NOT a
    /// cryptographic attestation — parity gates should compare the full
    /// signature text; this digest exists for telemetry and status output.
    public func layoutSignatureDigest() -> String {
        SchemaLayoutFNV.fold(layoutSignatureText())
    }
}

extension TableDeclaration {

    /// Canonical layout signature text for one table. See
    /// `SchemaDeclaration.layoutSignatureText()` for the format contract.
    public func layoutSignatureText() -> String {
        var out = "table=\(name)\n"
        for column in columns {
            let def: String
            if let value = column.defaultValue {
                def = value.typeDescription
            } else {
                def = "-"
            }
            let role = column.role?.rawValue ?? "-"
            out += "  col=\(column.name) type=\(column.type.rawValue) "
                + "null=\(column.nullable ? 1 : 0) default=\(def) role=\(role)\n"
        }
        for gen in generatedColumns {
            out += "  gen=\(gen.name) type=\(gen.type.rawValue)\n"
        }
        out += "  pk=\(primaryKey.joined(separator: ","))\n"
        for constraint in uniqueConstraints {
            out += "  unique=\(constraint.joined(separator: ","))\n"
        }
        out += "  appendOnly=\(appendOnly ? 1 : 0) hashable=\(hashable ? 1 : 0)\n"
        return out
    }
}

/// FNV-1a 64-bit fold used by the layout signature digest and the
/// database inventory. Deterministic, dependency-free, cross-port
/// identical (Rust twin: `layout_signature::fnv1a64`).
enum SchemaLayoutFNV {
    static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    static let prime: UInt64 = 1_099_511_628_211

    static func fold(_ text: String) -> String {
        var h = offsetBasis
        for byte in text.utf8 {
            h = (h ^ UInt64(byte)) &* prime
        }
        return String(format: "%016llx", h)
    }

    static func fold(bytes: [UInt8], into hash: UInt64) -> UInt64 {
        var h = hash
        for byte in bytes {
            h = (h ^ UInt64(byte)) &* prime
        }
        return h
    }
}
