//! Pipeline-p2.3 coreference stage (W2.2 Stage A, accepted design A1):
//! resolves THIRD-PERSON pronouns in the DISTILLED rendering against a
//! session antecedent pool — the anchored entities of up to K preceding
//! same-room items within the G-minute session window. The verbatim body
//! is never touched. CONSERVATIVE: a pronoun substitutes ONLY when the
//! pool holds exactly ONE distinct candidate of compatible class
//! (thing-pronoun → non-person entity, person-pronoun → person entity);
//! an ambiguous window leaves the pronoun untouched. "her" is excluded
//! on purpose (object and possessive share the form). Deterministic —
//! mirrors Swift `CorefStage` exactly.

use crate::brain::enrichment_stage::{MAX_PHRASE_WORDS, MIN_NOUN_LENGTH, STOPWORDS};

/// Session-window constants (accepted A1 shape). Changing either bumps
/// the pipeline version.
pub const WINDOW_ITEMS: usize = 5;
pub const WINDOW_MINUTES: i64 = 30;

/// The Wikidata class for "human".
const HUMAN_QID: &str = "Q5";

const PERSON_PLAIN: [&str; 5] = ["he", "him", "she", "they", "them"];
const PERSON_POSSESSIVE: [&str; 4] = ["his", "hers", "their", "theirs"];
const THING_PLAIN: [&str; 1] = ["it"];
const THING_POSSESSIVE: [&str; 1] = ["its"];

/// One antecedent candidate. Mirrors Swift `CorefStage.Antecedent`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Antecedent {
    pub value: String,
    pub is_person: bool,
}

/// Extract the antecedent pool an item CONTRIBUTES: its anchored entities
/// in first-seen order — the same selection the categorizer makes
/// (multi-word phrase pre-pass, then anchoring nouns), reusing the pinned
/// stopword/length/root-class rules. Mirrors Swift
/// `CorefStage.contributedEntities(from:)`.
pub fn contributed_entities(content: &str) -> Vec<Antecedent> {
    let mut result: Vec<Antecedent> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();

    let tokens: Vec<String> = content
        .split(|c: char| !c.is_alphabetic())
        .filter(|t| !t.is_empty())
        .map(|t| t.to_lowercase())
        .collect();

    // Multi-word phrase pass (mirrors the categorizer's pre-pass).
    let mut consumed: std::collections::HashSet<usize> = std::collections::HashSet::new();
    let mut i = 0usize;
    while i < tokens.len() {
        let mut matched = false;
        let mut n = MAX_PHRASE_WORDS.min(tokens.len() - i);
        while n >= 2 {
            let phrase = tokens[i..i + n].join(" ");
            if let Some(qid) = lattice_lib::qid_facts::qid_for_phrase(&phrase) {
                for k in i..i + n {
                    consumed.insert(k);
                }
                if seen.insert(phrase.clone()) {
                    result.push(Antecedent {
                        value: phrase,
                        is_person: is_person_qid(qid),
                    });
                }
                i += n;
                matched = true;
                break;
            }
            n -= 1;
        }
        if !matched {
            i += 1;
        }
    }

    // Single-token pass (mirrors the categorizer's noun pass).
    for (index, token) in tokens.iter().enumerate() {
        if consumed.contains(&index) {
            continue;
        }
        if token.chars().count() < MIN_NOUN_LENGTH
            || STOPWORDS.contains(&token.as_str())
            || lattice_lib::word_class_table::word_class_no_record(token) != lattice_lib::WordClass::Noun
        {
            continue;
        }
        let anchor = eidetic_lib::lookup(token);
        if anchor.code.is_empty() || anchor.code == "000" {
            continue;
        }
        if seen.insert(token.clone()) {
            result.push(Antecedent {
                value: token.clone(),
                is_person: anchor
                    .wikidata_qid
                    .as_deref()
                    .map(is_person_qid)
                    .unwrap_or(false),
            });
        }
    }
    result
}

/// True when the pinned taxonomy derives `qid` from Q5 (human).
fn is_person_qid(qid: &str) -> bool {
    !qid.is_empty() && lattice_lib::qid_closure::ancestors(qid).iter().any(|a| a == HUMAN_QID)
}

/// Resolve third-person pronouns in `rendering` against `pool`.
/// Token-boundary replacement over letter runs — never regex. Mirrors
/// Swift `CorefStage.resolve(rendering:pool:)` exactly.
pub fn resolve(rendering: &str, pool: &[Antecedent]) -> String {
    if pool.is_empty() {
        return rendering.to_string();
    }
    let persons = unique_values(pool.iter().filter(|a| a.is_person));
    let things = unique_values(pool.iter().filter(|a| !a.is_person));
    let person = if persons.len() == 1 { Some(persons[0].as_str()) } else { None };
    let thing = if things.len() == 1 { Some(things[0].as_str()) } else { None };
    if person.is_none() && thing.is_none() {
        return rendering.to_string();
    }

    let mut out = String::with_capacity(rendering.len());
    let mut word = String::new();
    for ch in rendering.chars() {
        if ch.is_alphabetic() {
            word.push(ch);
        } else {
            out.push_str(&substituted(&word, person, thing));
            word.clear();
            out.push(ch);
        }
    }
    out.push_str(&substituted(&word, person, thing));
    out
}

/// Distinct candidate values in first-seen order.
fn unique_values<'a>(antecedents: impl Iterator<Item = &'a Antecedent>) -> Vec<String> {
    let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
    let mut out = Vec::new();
    for a in antecedents {
        if seen.insert(a.value.as_str()) {
            out.push(a.value.clone());
        }
    }
    out
}

/// The replacement for one word token, or the token unchanged.
fn substituted(word: &str, person: Option<&str>, thing: Option<&str>) -> String {
    if word.is_empty() {
        return String::new();
    }
    let lower = word.to_lowercase();
    if let Some(thing) = thing {
        if THING_PLAIN.contains(&lower.as_str()) {
            return thing.to_string();
        }
        if THING_POSSESSIVE.contains(&lower.as_str()) {
            return format!("{thing}'s");
        }
    }
    if let Some(person) = person {
        if PERSON_PLAIN.contains(&lower.as_str()) {
            return person.to_string();
        }
        if PERSON_POSSESSIVE.contains(&lower.as_str()) {
            return format!("{person}'s");
        }
    }
    word.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thing(v: &str) -> Antecedent {
        Antecedent { value: v.to_string(), is_person: false }
    }

    #[test]
    fn resolves_single_thing_candidate() {
        // Mirrors the Swift CorefStageTests pins.
        let pool = vec![thing("guitar")];
        assert_eq!(
            resolve("I bought it a year ago. Its neck warped.", &pool),
            "I bought guitar a year ago. guitar's neck warped."
        );
    }

    #[test]
    fn ambiguous_pool_leaves_pronoun() {
        let pool = vec![thing("guitar"), thing("camera")];
        assert_eq!(resolve("I bought it a year ago.", &pool), "I bought it a year ago.");
    }

    #[test]
    fn her_is_never_substituted() {
        let pool = vec![Antecedent { value: "alice".to_string(), is_person: true }];
        assert_eq!(resolve("I met her yesterday.", &pool), "I met her yesterday.");
    }

    #[test]
    fn person_pronoun_needs_person_candidate() {
        let pool = vec![thing("guitar")];
        assert_eq!(resolve("He plays daily.", &pool), "He plays daily.");
    }

    #[test]
    fn empty_pool_is_identity() {
        assert_eq!(resolve("It broke.", &[]), "It broke.");
    }
}
