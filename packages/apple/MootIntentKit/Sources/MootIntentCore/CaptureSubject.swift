import Foundation

// MARK: - CaptureSubject  (the derived-subject fallback for capture surfaces)
//
// `moot_file_memory` requires a `subject`: one sentence, ≤120 characters,
// stating what the memory asserts, written for the NEXT AI that will scan it
// in a result list. It is the field the dense recall row renders — the
// assertion beside the address — so a drawer captured without one is
// permanently harder to recall. That is why the tool refuses a capture that
// omits it rather than defaulting to a content prefix.
//
// Capture surfaces divide into two kinds:
//
//   Surfaces with real material — an App Intent parameter a Shortcut author
//   filled in, a @Guide'd field an on-device model wrote, a shared web page's
//   title. They pass their subject through verbatim and never come here.
//
//   Surfaces with only an opaque body — a Share-Sheet selection is text and
//   a room name, nothing else. They derive, and this helper is the derivation.
//
// The derivation is deliberately SECOND-BEST and every caller that uses it
// says so at the call site, naming the better material a future improvement
// should reach for. A leading sentence is an extract, not an assertion: it
// states what the content OPENS WITH, not what it CLAIMS. No amount of string
// work closes that gap — only a caller (or model) that understands the content
// can. Improving a call site means giving it real material, not improving this
// function.
//
// Register authority: LocusKit's `SubjectRegister` owns the register contract
// (length, single line, trimmed, no narrative-frame prefix) and the tool
// boundary (`ToolDispatch.runFileMemory`) enforces non-empty-after-trim and
// the length cap. MootIntentKit's only seam to the substrate is the ARIA tool
// surface — it links neither LocusKit nor GeniusLocusKit — so the two
// mechanical rules a derived subject must satisfy are re-stated here instead
// of imported.

public enum CaptureSubject {

    /// The store's subject length contract, mirrored from LocusKit
    /// `DrawerStore.subjectLengthContract` (120). Mirrored rather than
    /// imported because MootIntentKit does not link LocusKit (see the note
    /// above); if the store contract changes, this constant must follow.
    public static let maxLength = 120

    /// Characters that can end a sentence.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// A candidate leading sentence shorter than this is far more likely an
    /// abbreviation or a list marker ("e.g.", "Mr.", "1.", "No.") than a real
    /// sentence end, so scanning continues past it. Full abbreviation
    /// handling would need a lexicon; this length floor buys most of the
    /// benefit for none of the weight, and the worst case is only that a
    /// subject runs to the next terminator instead of stopping early.
    private static let minimumSentenceLength = 12

    /// Derive a register-conformant subject from an opaque body: leading
    /// sentence, flattened to one line, trimmed, truncated on a word boundary
    /// at `maxLength`.
    ///
    /// Returns the empty string only when `body` has no non-whitespace
    /// characters. That case is deliberately NOT papered over with a
    /// placeholder: a capture with an empty body has nothing to assert, and
    /// the substrate's own refusal names the problem precisely. Inventing a
    /// subject there would file an empty drawer with a confident-looking
    /// summary, which is worse than a rejected capture.
    public static func derive(fromBody body: String) -> String {
        let flat = normalize(body)
        guard !flat.isEmpty else { return "" }
        return truncateOnWordBoundary(leadingSentence(of: flat))
    }

    /// Bring a subject an author or model supplied into mechanical conformance:
    /// every whitespace run (including newlines and tabs) collapsed to a single
    /// space, ends trimmed. Length is deliberately NOT touched — see below.
    ///
    /// This is not cosmetic. The dense row is one line by contract, but the
    /// tool boundary only checks non-empty-after-trim and the length cap, so an
    /// interior newline passes dispatch and lands in the estate. A stored
    /// subject containing a newline splits one dense row into two at the reply
    /// surface, which is both a corrupt row and the exact shape a line-oriented
    /// consumer can be fed a forged record through. Every caller-supplied
    /// subject goes through here before it reaches the tool.
    ///
    /// Over-length subjects are passed through unchanged so the substrate
    /// refuses them, rather than silently truncated. A human Shortcut author or
    /// a model can be told "compress, don't truncate" — which is what the
    /// dispatcher's error says — and fix the wording. Quietly cutting an
    /// author's sentence in half would file a subject they never wrote and
    /// never see. Derived subjects truncate because there is no author to tell.
    public static func normalize(_ subject: String) -> String {
        subject.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// The one seam every capture surface resolves its subject through: use
    /// what the caller supplied when there is something usable in it,
    /// otherwise derive from the body.
    ///
    /// A supplied subject that normalizes to nothing (absent, empty, or only
    /// whitespace) is treated as absent rather than passed on — the tool would
    /// refuse it, and a body is better material than a rejection. Kept here
    /// rather than repeated at the three call sites so the precedence rule has
    /// exactly one definition.
    public static func resolve(supplied: String?, body: String) -> String {
        let normalized = normalize(supplied ?? "")
        return normalized.isEmpty ? derive(fromBody: body) : normalized
    }

    // MARK: - Steps

    /// The leading sentence of already-flattened text, including its
    /// terminator. A terminator counts as a sentence end only when it is
    /// followed by a space or the end of the text — "3.5x" and "example.com"
    /// must not split — and only once the candidate has reached
    /// `minimumSentenceLength`. Text with no qualifying terminator yields
    /// itself; truncation then does the bounding.
    private static func leadingSentence(of flat: String) -> String {
        var index = flat.startIndex
        var length = 0
        while index < flat.endIndex {
            length += 1
            if sentenceTerminators.contains(flat[index]), length >= minimumSentenceLength {
                let next = flat.index(after: index)
                if next == flat.endIndex || flat[next] == " " {
                    return String(flat[..<next])
                }
            }
            index = flat.index(after: index)
        }
        return flat
    }

    /// Truncate to at most `maxLength` characters, cutting at the last word
    /// boundary that fits so the subject ends on a whole word.
    ///
    /// No ellipsis is appended: a subject is an assertion, and a trailing "…"
    /// both spends scarce characters and signals "preview" to the reader it
    /// is written for. A single word longer than the cap is hard-cut, since
    /// there is no boundary to prefer.
    private static func truncateOnWordBoundary(_ sentence: String) -> String {
        guard sentence.count > maxLength else { return sentence }
        let cap = sentence.index(sentence.startIndex, offsetBy: maxLength)
        let head = sentence[..<cap]
        if let lastSpace = head.lastIndex(of: " ") {
            let wholeWords = String(head[..<lastSpace])
            if !wholeWords.isEmpty { return wholeWords }
        }
        return String(head)
    }
}
