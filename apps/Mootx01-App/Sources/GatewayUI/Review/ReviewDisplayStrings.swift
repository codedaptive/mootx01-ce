import Foundation
import MootGateway   // ReviewKind

// MARK: - ReviewDisplayStrings  (FAB5-G2 — G1 localization keys → display text)
//
// WHY THIS FILE EXISTS. FAB5-G1 sets `ReviewSection.title` and (for the two
// drift measures) `ReviewItem.title` to DOTTED LOCALIZATION KEYS —
// "review.section.momentum", "review.item.jensenShannon" — and documents that
// the view layer resolves them at render time
// (Sources/MootGateway/Review/ReviewModels.swift, "Localization" note).
//
// This app localizes English-as-key with NO catalog shipped
// (docs/engineering/LOCALIZATION_GUIDE.md; ContentView.swift's header note).
// `String(localized:)` with no matching catalog entry returns the key verbatim,
// so passing a dotted key straight through would print
// "review.section.momentum" on screen as the section header. The table below is
// the bridge: dotted key in, English display text out, and the English text is
// itself the localization key — so adding a real catalog later needs no change
// here and no `.strings` file ships now.
//
// Keyed on the full dotted string rather than on `ReviewSection.id` (the slug)
// for two reasons: `ReviewItem.title` also carries keys and items have no slug
// field, and two of the sixteen keys are proper nouns
// ("review.item.jensenShannon" → "Jensen-Shannon Divergence") that no
// mechanical de-slugging of "jensenShannon" would ever produce correctly.
//
// Kong ruling C (FAB5-G2), resolving Smythe pre-flight item Y-1.

enum ReviewDisplayStrings {

    /// Display text for one FAB5-G1 title key.
    ///
    /// The sixteen cases below are the complete set G1 emits today — fourteen
    /// `review.section.*` from the four builders plus the two `review.item.*`
    /// drift measures. They are matched exactly; a key G1 adds in a future build
    /// falls through to `humanized(_:)` so it renders as readable words rather
    /// than a raw dotted slug.
    ///
    /// A string that is not a key at all (a drawer UUID, a room name, a fact
    /// subject — what `ReviewItem.title` carries for every other surface) is
    /// returned unchanged: it is estate data, and estate data is never
    /// localized (LOCALIZATION_GUIDE.md, "What does NOT go through
    /// localization").
    static func title(forKey key: String) -> String {
        switch key {
        // Dashboard
        case "review.section.momentum": return String(localized: "Momentum")
        case "review.section.keystones": return String(localized: "Keystones")
        case "review.section.conflicts": return String(localized: "Conflicts")
        // Morning
        case "review.section.journal": return String(localized: "Journal")
        case "review.section.context": return String(localized: "Context")
        case "review.section.openWork": return String(localized: "Open Work")
        // End of day
        case "review.section.changes": return String(localized: "Changes")
        case "review.section.decisions": return String(localized: "Decisions")
        case "review.section.attention": return String(localized: "Attention")
        // Weekly
        case "review.section.fading": return String(localized: "Fading")
        case "review.section.drift": return String(localized: "Drift")
        case "review.section.contradicted": return String(localized: "Contradicted")
        case "review.section.retireReady": return String(localized: "Retire-ready")
        case "review.section.duplicates": return String(localized: "Duplicates")
        // The two drift measures, which arrive as ReviewItem.title.
        case "review.item.jensenShannon": return String(localized: "Jensen-Shannon divergence")
        case "review.item.klDivergence": return String(localized: "Kullback-Leibler divergence")
        default:
            return isTitleKey(key) ? humanized(key) : key
        }
    }

    /// Display name for one review.
    ///
    /// `ReviewKind`'s raw values are wire identifiers, not display text
    /// (`ReviewModels.swift` treats a rename as an API break), so the picker
    /// labels are written here instead of derived from them.
    static func name(for kind: ReviewKind) -> String {
        switch kind {
        case .dashboard: return String(localized: "Dashboard")
        case .morning: return String(localized: "Morning")
        case .endOfDay: return String(localized: "End of Day")
        case .weekly: return String(localized: "Weekly")
        }
    }

    /// The one-line description under each review's heading — what this review
    /// is for, in the roadmap's own terms (ROADMAP.md, "Ask what MOOT
    /// remembers").
    static func summary(for kind: ReviewKind) -> String {
        switch kind {
        case .dashboard:
            return String(localized: "What your estate remembers now.")
        case .morning:
            return String(localized: "The context and open work that matter today.")
        case .endOfDay:
            return String(localized: "What changed, what was decided, what still needs attention.")
        case .weekly:
            return String(localized: "Memories that may be stale, contradicted, or ready to retire.")
        }
    }

    /// Whether a string is one of G1's title keys rather than estate data.
    ///
    /// Prefix test, not a full-key test: it must be true for keys G1 has not
    /// invented yet, which is the whole point of the fallback path. Estate data
    /// never starts with these prefixes — the alternatives at an item's `title`
    /// position are a UUID, a room name, an ISO8601 stamp, or a fact subject.
    private static func isTitleKey(_ candidate: String) -> Bool {
        candidate.hasPrefix("review.section.") || candidate.hasPrefix("review.item.")
    }

    /// Readable words from an unrecognized key: drop the namespace, split the
    /// camel-cased tail, and capitalize the first letter.
    /// "review.section.newThing" → "New thing".
    ///
    /// Deliberately NOT wrapped in `String(localized:)`: the result is computed
    /// at runtime, so there is no literal for a translator to have translated.
    /// A key that reaches this path is a signal to add a real case above, and
    /// the untranslated-but-legible output is the honest interim rendering.
    private static func humanized(_ key: String) -> String {
        let tail = key
            .replacingOccurrences(of: "review.section.", with: "")
            .replacingOccurrences(of: "review.item.", with: "")
        guard !tail.isEmpty else { return key }
        // Split camelCase into words, LOWERCASING the boundary letter so the
        // result reads as a sentence rather than as Title Case:
        // "retireReady" → "retire ready", which the final line then caps to
        // "Retire ready".
        var words = ""
        for character in tail {
            if character.isUppercase, !words.isEmpty {
                words.append(" ")
                words.append(Character(character.lowercased()))
            } else {
                words.append(character)
            }
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
