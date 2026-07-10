//! Deterministic programming-language refinement for FDC `005`.
//! Q-IDs are pinned public Wikidata identifiers. The rules mirror
//! `FDCCodeLanguage.swift` exactly.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FdcCodeLanguage {
    pub identifier: &'static str,
    pub label: &'static str,
    pub wikidata_qid: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FencedCodeHint {
    Language(FdcCodeLanguage),
    Operational,
    Unknown,
}

struct Definition {
    language: FdcCodeLanguage,
    aliases: &'static [&'static str],
    signals: &'static [(&'static str, usize)],
}

const DEFINITIONS: &[Definition] = &[
    Definition {
        language: FdcCodeLanguage {
            identifier: "objective-c",
            label: "Objective-C",
            wikidata_qid: "Q188531",
        },
        aliases: &["objective-c", "objectivec", "objc", "obj-c"],
        signals: &[
            ("@interface", 4),
            ("@implementation", 4),
            ("#import <", 3),
            ("nsstring", 3),
            ("@property", 2),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "typescript",
            label: "TypeScript",
            wikidata_qid: "Q978185",
        },
        aliases: &["typescript", "ts", "tsx"],
        signals: &[
            ("interface ", 2),
            (": string", 2),
            (": number", 2),
            (" as const", 2),
            ("readonly ", 1),
            ("implements ", 1),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "javascript",
            label: "JavaScript",
            wikidata_qid: "Q2005",
        },
        aliases: &["javascript", "js", "jsx", "node", "nodejs"],
        signals: &[
            ("console.log", 3),
            ("function ", 2),
            ("=>", 2),
            ("document.", 2),
            ("require(", 2),
            ("const ", 1),
            ("let ", 1),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "swift",
            label: "Swift",
            wikidata_qid: "Q17118377",
        },
        aliases: &["swift"],
        signals: &[
            ("import foundation", 3),
            ("import swiftui", 3),
            ("guard let ", 2),
            ("public let ", 2),
            ("public var ", 2),
            ("func ", 2),
            (" let ", 1),
            (" var ", 1),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "rust",
            label: "Rust",
            wikidata_qid: "Q575650",
        },
        aliases: &["rust", "rs"],
        signals: &[
            ("use std::", 3),
            ("let mut ", 2),
            ("pub struct ", 2),
            ("impl ", 2),
            ("fn ", 2),
            ("match ", 1),
            ("::", 1),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "python",
            label: "Python",
            wikidata_qid: "Q28865",
        },
        aliases: &["python", "py", "python3"],
        signals: &[
            ("__init__", 3),
            ("self.", 2),
            ("def ", 2),
            ("elif ", 2),
            ("print(", 1),
            (" import ", 1),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "kotlin",
            label: "Kotlin",
            wikidata_qid: "Q3816639",
        },
        aliases: &["kotlin", "kt", "kts"],
        signals: &[
            ("data class ", 3),
            ("companion object", 3),
            ("fun ", 2),
            ("val ", 2),
            ("println(", 1),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "go",
            label: "Go",
            wikidata_qid: "Q37227",
        },
        aliases: &["go", "golang"],
        signals: &[
            ("package main", 4),
            ("func ", 2),
            (":=", 2),
            ("fmt.", 2),
            ("defer ", 2),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "ruby",
            label: "Ruby",
            wikidata_qid: "Q161053",
        },
        aliases: &["ruby", "rb"],
        signals: &[
            ("attr_", 2),
            ("require ", 2),
            ("puts ", 2),
            ("do |", 2),
            ("def ", 2),
            ("\nend", 1),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "csharp",
            label: "C#",
            wikidata_qid: "Q2370",
        },
        aliases: &["c#", "csharp", "cs"],
        signals: &[
            ("using system;", 4),
            ("using system.", 4),
            ("console.writeline", 3),
            ("namespace ", 2),
            ("static void main", 2),
            ("public class ", 2),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "cpp",
            label: "C++",
            wikidata_qid: "Q2407",
        },
        aliases: &["c++", "cpp", "cxx", "cc"],
        signals: &[
            ("#include <iostream", 5),
            ("std::", 3),
            ("cout <<", 3),
            ("namespace ", 2),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "c",
            label: "C",
            wikidata_qid: "Q15777",
        },
        aliases: &["c"],
        signals: &[
            ("#include <", 2),
            ("int main(", 2),
            ("printf(", 2),
            ("malloc(", 2),
        ],
    },
    Definition {
        language: FdcCodeLanguage {
            identifier: "java",
            label: "Java",
            wikidata_qid: "Q251",
        },
        aliases: &["java"],
        signals: &[
            ("static void main", 4),
            ("system.out.", 3),
            ("public class ", 3),
            ("package ", 1),
        ],
    },
];

const OPERATIONAL_FENCE_ALIASES: &[&str] = &[
    "bash",
    "console",
    "fish",
    "markdown",
    "md",
    "plaintext",
    "powershell",
    "ps1",
    "sh",
    "shell",
    "text",
    "terminal",
    "zsh",
];

pub(crate) fn fenced_hint(text: &str) -> Option<FencedCodeHint> {
    for line in text.lines() {
        let trimmed = line.trim_start();
        if !trimmed.starts_with("```") && !trimmed.starts_with("~~~") {
            continue;
        }
        let raw = trimmed[3..].to_ascii_lowercase();
        let token = raw.split_whitespace().next().unwrap_or("");
        let normalized = token.trim_matches(|character| ".{}".contains(character));
        if normalized.is_empty() {
            return Some(FencedCodeHint::Unknown);
        }
        if OPERATIONAL_FENCE_ALIASES.contains(&normalized) {
            return Some(FencedCodeHint::Operational);
        }
        if let Some(definition) = DEFINITIONS
            .iter()
            .find(|definition| definition.aliases.contains(&normalized))
        {
            return Some(FencedCodeHint::Language(definition.language));
        }
        return Some(FencedCodeHint::Unknown);
    }
    None
}

pub fn detect_code_language(text: &str) -> Option<FdcCodeLanguage> {
    match fenced_hint(text) {
        Some(FencedCodeHint::Language(language)) => return Some(language),
        Some(FencedCodeHint::Operational) => return None,
        Some(FencedCodeHint::Unknown) | None => {}
    }

    let lowered = text.to_lowercase();
    let scores: Vec<usize> = DEFINITIONS
        .iter()
        .map(|definition| {
            definition
                .signals
                .iter()
                .fold(0, |score, (signal, weight)| {
                    score + usize::from(lowered.contains(signal)) * weight
                })
        })
        .collect();
    let maximum = scores.iter().copied().max()?;
    if maximum < 3 || scores.iter().filter(|score| **score == maximum).count() != 1 {
        return None;
    }
    let index = scores.iter().position(|score| *score == maximum)?;
    Some(DEFINITIONS[index].language)
}
