// fdc_frame.rs — FDC classification frame and decimal-string ancestry
//
// Port of FDCFrame.swift. Ancestry is derived from the decimal string, NOT stored.
// The two ancestry regimes (integer-head Dewey positional hierarchy and
// decimal-tail per-segment hierarchy) are ported exactly from the Swift version.
//
// See the detailed comment in FDCFrame.swift for the "why not string-prefix"
// rationale — this port preserves that reasoning verbatim.

use serde::Deserialize;

/// One FDC code and its label, as stored in FDCFrame.json.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct FdcEntry {
    /// The decimal classification code, e.g. "000", "006", "006.6".
    pub code: String,
    /// The heading text exactly as it appears in fdc.txt.
    pub label: String,
}

/// The FDC frame: a versioned list of codes. Ancestry is computed from
/// the decimal strings, not stored. Matches FDCFrame.json schema.
#[derive(Debug, Clone, Deserialize)]
pub struct FdcFrame {
    /// Artifact version string (JSON key `frame_version`).
    #[serde(rename = "frame_version")]
    pub frame_version: String,
    /// All codes in the frame.
    pub codes: Vec<FdcEntry>,
}

impl FdcFrame {
    /// Deserialize from JSON bytes (the bundled FDCFrame.json artifact).
    pub fn from_json(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }

    /// The immediate parent of a code, or None for the root "000" (and for
    /// any string that is not a well-formed FDC code).
    ///
    /// Two ancestry regimes (mirroring the Swift `decimalParent(of:)` exactly):
    ///
    /// Regime 2 — decimal tail present: drop the last ".segment".
    ///   parent("006.6") = "006"
    ///   parent("006.6.1") = "006.6"
    ///
    /// Regime 1 — 3-digit integer head, Dewey positional hierarchy:
    ///   units place set (d3 != '0'): parent zeroes the units
    ///     parent("006") = "000"
    ///   tens place set, units zero: parent zeroes the tens
    ///     parent("010") = "000"
    ///   hundreds only: parent is root
    ///     parent("100") = "000"
    ///   root has no parent:
    ///     parent("000") = None
    pub fn decimal_parent(code: &str) -> Option<String> {
        // Regime 2: decimal tail present — drop the last ".segment".
        if let Some(last_dot) = code.rfind('.') {
            return Some(code[..last_dot].to_owned());
        }

        // Regime 1: 3-digit integer head.
        let chars: Vec<char> = code.chars().collect();
        if chars.len() != 3 || !chars.iter().all(|c| c.is_ascii_digit()) {
            return None;
        }
        let d1 = chars[0];
        let d2 = chars[1];
        let d3 = chars[2];
        let zero = '0';

        if d3 != zero {
            // Units place occupied: parent zeroes the units.
            return Some(format!("{}{}0", d1, d2));
        }
        if d2 != zero {
            // Tens place occupied, units zero: parent zeroes the tens.
            return Some(format!("{}00", d1));
        }
        if d1 != zero {
            // Hundreds only: parent is the root.
            return Some("000".to_owned());
        }
        // code == "000": root has no parent.
        None
    }

    /// All codes whose immediate parent is `node` (one level below in the
    /// FDC hierarchy). Returned sorted lexicographically for deterministic output.
    pub fn children(&self, node: &str) -> Vec<&FdcEntry> {
        let mut children: Vec<&FdcEntry> = self.codes
            .iter()
            .filter(|e| Self::decimal_parent(&e.code).as_deref() == Some(node))
            .collect();
        children.sort_by(|a, b| a.code.cmp(&b.code));
        children
    }

    /// All ancestors of `code`, root first, excluding `code` itself.
    /// Pure function of the decimal string (same contract as Swift).
    /// ancestors("006.6") == ["000", "006"]
    /// ancestors("000") == []
    pub fn ancestors(&self, code: &str) -> Vec<String> {
        let mut chain: Vec<String> = Vec::new();
        let mut current = code.to_owned();
        while let Some(parent) = Self::decimal_parent(&current) {
            chain.push(parent.clone());
            current = parent;
        }
        chain.reverse();
        chain
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimal_parent_root_is_none() {
        assert_eq!(FdcFrame::decimal_parent("000"), None);
    }

    #[test]
    fn decimal_parent_units_set() {
        assert_eq!(FdcFrame::decimal_parent("006"), Some("000".to_owned()));
        assert_eq!(FdcFrame::decimal_parent("016"), Some("010".to_owned()));
    }

    #[test]
    fn decimal_parent_tens_set() {
        assert_eq!(FdcFrame::decimal_parent("010"), Some("000".to_owned()));
        assert_eq!(FdcFrame::decimal_parent("510"), Some("500".to_owned()));
    }

    #[test]
    fn decimal_parent_hundreds_set() {
        assert_eq!(FdcFrame::decimal_parent("100"), Some("000".to_owned()));
        assert_eq!(FdcFrame::decimal_parent("500"), Some("000".to_owned()));
    }

    #[test]
    fn decimal_parent_decimal_tail() {
        assert_eq!(FdcFrame::decimal_parent("006.6"), Some("006".to_owned()));
        assert_eq!(FdcFrame::decimal_parent("006.6.1"), Some("006.6".to_owned()));
    }

    #[test]
    fn ancestors_006_6() {
        let frame = FdcFrame { frame_version: "t".to_owned(), codes: vec![] };
        assert_eq!(frame.ancestors("006.6"), vec!["000", "006"]);
    }

    #[test]
    fn ancestors_root_empty() {
        let frame = FdcFrame { frame_version: "t".to_owned(), codes: vec![] };
        assert!(frame.ancestors("000").is_empty());
    }

    #[test]
    fn children_sorting() {
        let frame = FdcFrame {
            frame_version: "t".to_owned(),
            codes: vec![
                FdcEntry { code: "006".to_owned(), label: "".to_owned() },
                FdcEntry { code: "001".to_owned(), label: "".to_owned() },
                FdcEntry { code: "003".to_owned(), label: "".to_owned() },
            ],
        };
        let children = frame.children("000");
        let codes: Vec<&str> = children.iter().map(|e| e.code.as_str()).collect();
        assert_eq!(codes, vec!["001", "003", "006"]);
    }
}
