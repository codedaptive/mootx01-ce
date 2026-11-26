// SubjectCutToContract.swift
//
// The cut the subject-backfill sweep applies to a producer's answer before
// validating it against `SubjectRegister`. A model often answers a little
// over the subject length contract; cutting at the last word boundary keeps
// a usable subject instead of rejecting the whole answer, and the Rust port
// cuts at the same place so both ports store the same subject.

import LocusKit

extension GeniusLocusKit {

    /// `answer` cut to `DrawerStore.subjectLengthContract` characters
    /// (grapheme clusters, the contract's unit) at its last word boundary.
    /// An answer within the contract is returned unchanged. Over it, the cut
    /// falls on the last whitespace character among the first contract + 1
    /// characters (the character just past the limit may itself be the
    /// boundary), and the trailing whitespace before it is dropped. An answer
    /// with no word boundary in that window (one long identifier) is cut at
    /// the limit itself, so a model that gave text never leaves the subject
    /// empty. Twin of Rust `subject_cut_to_contract`
    /// (brain/subject_cut_to_contract.rs); both test a character's first
    /// scalar for White_Space, so the ports cut at the same place.
    static func subjectCutToContract(_ answer: String) -> String {
        let limit = DrawerStore.subjectLengthContract
        guard answer.count > limit else { return answer }
        let window = Array(answer.prefix(limit + 1))
        func isSpace(_ c: Character) -> Bool { c.unicodeScalars.first?.properties.isWhitespace ?? false }
        // Index 0 is never a boundary: a cut there would leave nothing.
        if let boundary = window.indices.dropFirst().last(where: { isSpace(window[$0]) }) {
            var kept = window[..<boundary]
            while let last = kept.last, isSpace(last) { kept = kept.dropLast() }
            if !kept.isEmpty { return String(kept) }
        }
        return String(window.prefix(limit))
    }
}
