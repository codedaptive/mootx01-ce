// Data+BOM.swift
//
// UTF-8 byte-order-mark tolerance for config reads.

import Foundation

extension Data {
    /// A copy of this data with a leading UTF-8 BOM (`EF BB BF`) removed, if
    /// present. Some editors and Windows tools — notably Windows PowerShell
    /// 5.1's `Set-Content -Encoding UTF8` — prepend a BOM, which
    /// `JSONSerialization` rejects (and TOML/YAML parsers treat as a stray
    /// leading character). Stripping it before parsing keeps config reads
    /// non-destructive. Mirrors the Rust `core::merge::strip_bom` on the
    /// parallel port so both verticals tolerate the same files.
    var strippingLeadingUTF8BOM: Data {
        starts(with: [0xEF, 0xBB, 0xBF]) ? Data(dropFirst(3)) : self
    }
}
