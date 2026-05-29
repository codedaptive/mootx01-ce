// NotationSpine.swift
//
// The MDCC top-of-tree notation spine: ten main classes (000-900),
// each subdivided into ten divisions (NN0-NN9), each further into ten
// sections (NNN). The spine is editorial human judgment — it does not
// come out of the CC0 graph. Codes below the spine are assigned by the
// assembler walking the collapsed single-parent tree.
//
// The spine here is original work (not DDC and not UDC). It is
// published free under the same terms as the rest of MDCC. The choice
// of which top-level slot a concept sits under is a sovereign design
// decision; the CC0 graph informs but does not dictate.
//
// Reserved ranges within the spine are declared in ReservedRanges.swift.
// Curated community additions land in reserved ranges; without them,
// any later addition forces renumbering, which breaks downstream users.

import Foundation

/// A single class on the MDCC top-of-tree spine. Each class owns the
/// hundred contiguous integer codes from `base` through `base + 99`,
/// inclusive. The decimal-extension digits beyond the three-digit
/// spine code (`450.137`, etc.) carry the leaf-resolution data the
/// assembler fills in from the CC0 graph.
public struct MDCCClass: Sendable, Hashable {
    /// The three-digit integer base code (000, 100, ... 900). Stored
    /// as Int so arithmetic is direct; rendered with leading zeros.
    public let base: Int
    /// The human-readable class name. Used by the slow-docs channel
    /// to render the canon overview document.
    public let name: String
    /// One-sentence scope note explaining what the class collects.
    /// Authored, not derived from the CC0 graph.
    public let scopeNote: String

    public init(base: Int, name: String, scopeNote: String) {
        self.base = base
        self.name = name
        self.scopeNote = scopeNote
    }

    /// Renders the base code with leading zeros: 0 -> "000", 50 -> "050".
    /// All MDCC codes are three digits before the decimal point.
    public var renderedBase: String {
        String(format: "%03d", base)
    }
}

/// The MDCC v1 top-of-tree. Ten classes, each starting on a multiple
/// of 100. The spine numbering is intentionally Dewey-shaped so the
/// muscle memory of decimal classification carries over for librarians
/// and library-aware tooling, but the labels and scope notes are
/// authored fresh for MDCC.
public enum NotationSpine {

    /// The full top-of-tree, ordered by base code.
    public static let classes: [MDCCClass] = [
        MDCCClass(base: 0,
                  name: "Generalities",
                  scopeNote: "Knowledge, information, classification, computing, and reference works that span every other class."),
        MDCCClass(base: 100,
                  name: "Philosophy and psychology",
                  scopeNote: "Inquiry into mind, reason, and the structure of thought."),
        MDCCClass(base: 200,
                  name: "Religion and belief systems",
                  scopeNote: "Religions, mythologies, ritual practice, and the history of belief."),
        MDCCClass(base: 300,
                  name: "Social sciences",
                  scopeNote: "Society, economics, politics, law, and education."),
        MDCCClass(base: 400,
                  name: "Language and communication",
                  scopeNote: "Languages, linguistics, writing systems, and the practice of communication."),
        MDCCClass(base: 500,
                  name: "Natural sciences and mathematics",
                  scopeNote: "Mathematics and the natural sciences from formal logic through biology."),
        MDCCClass(base: 600,
                  name: "Applied sciences and technology",
                  scopeNote: "Engineering, medicine, agriculture, and the practical applications of natural science."),
        MDCCClass(base: 700,
                  name: "Arts and recreation",
                  scopeNote: "Fine arts, performing arts, design, sport, and recreation."),
        MDCCClass(base: 800,
                  name: "Literature",
                  scopeNote: "Literary works organised by language and form."),
        MDCCClass(base: 900,
                  name: "History and geography",
                  scopeNote: "History, biography, geography, and the historical record."),
    ]

    /// Returns the class that owns a given three-digit base code, or
    /// nil if no class on the spine owns that base. Lookup is O(N)
    /// over ten elements; not worth indexing.
    public static func owningClass(forBase base: Int) -> MDCCClass? {
        classes.first { $0.base == base }
    }

    /// Returns the class that owns a fully-rendered code such as
    /// "450.137". The integer part is parsed, then rounded down to the
    /// nearest hundred to find the owning class. Returns nil if the
    /// code is malformed or out of range.
    public static func owningClass(for code: String) -> MDCCClass? {
        let integerPart = code.split(separator: ".").first.map(String.init) ?? code
        guard let value = Int(integerPart), (0...999).contains(value) else {
            return nil
        }
        let base = (value / 100) * 100
        return owningClass(forBase: base)
    }
}
