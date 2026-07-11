import Foundation

/// A deterministic programming-language refinement for FDC `005`.
/// The Q-IDs are pinned public Wikidata identifiers; detection is local and
/// rule-based so Swift and Rust produce the same stored anchor.
public struct FDCCodeLanguage: Equatable, Sendable {
    public let identifier: String
    public let label: String
    public let wikidataQID: String
}

enum FDCFencedCodeHint: Equatable {
    case language(FDCCodeLanguage)
    case operational
    case unknown
}

public enum FDCCodeLanguageDetector {
    private struct Definition {
        let language: FDCCodeLanguage
        let aliases: Set<String>
        let signals: [(String, Int)]
    }

    private static func definition(
        _ identifier: String,
        _ label: String,
        _ qid: String,
        aliases: [String],
        signals: [(String, Int)]
    ) -> Definition {
        Definition(
            language: FDCCodeLanguage(identifier: identifier, label: label, wikidataQID: qid),
            aliases: Set(aliases),
            signals: signals)
    }

    private static let definitions: [Definition] = [
        definition("objective-c", "Objective-C", "Q188531",
                   aliases: ["objective-c", "objectivec", "objc", "obj-c"],
                   signals: [("@interface", 4), ("@implementation", 4),
                             ("#import <", 3), ("nsstring", 3), ("@property", 2)]),
        definition("typescript", "TypeScript", "Q978185",
                   aliases: ["typescript", "ts", "tsx"],
                   signals: [("interface ", 2), (": string", 2), (": number", 2),
                             (" as const", 2), ("readonly ", 1), ("implements ", 1)]),
        definition("javascript", "JavaScript", "Q2005",
                   aliases: ["javascript", "js", "jsx", "node", "nodejs"],
                   signals: [("console.log", 3), ("function ", 2), ("=>", 2),
                             ("document.", 2), ("require(", 2), ("const ", 1), ("let ", 1)]),
        definition("swift", "Swift", "Q17118377",
                   aliases: ["swift"],
                   signals: [("import foundation", 3), ("import swiftui", 3),
                             ("guard let ", 2), ("public let ", 2), ("public var ", 2),
                             ("func ", 2), (" let ", 1), (" var ", 1)]),
        definition("rust", "Rust", "Q575650",
                   aliases: ["rust", "rs"],
                   signals: [("use std::", 3), ("let mut ", 2), ("pub struct ", 2),
                             ("impl ", 2), ("fn ", 2), ("match ", 1), ("::", 1)]),
        definition("python", "Python", "Q28865",
                   aliases: ["python", "py", "python3"],
                   signals: [("__init__", 3), ("self.", 2), ("def ", 2),
                             ("elif ", 2), ("print(", 1), (" import ", 1)]),
        definition("kotlin", "Kotlin", "Q3816639",
                   aliases: ["kotlin", "kt", "kts"],
                   signals: [("data class ", 3), ("companion object", 3),
                             ("fun ", 2), ("val ", 2), ("println(", 1)]),
        definition("go", "Go", "Q37227",
                   aliases: ["go", "golang"],
                   signals: [("package main", 4), ("func ", 2), (":=", 2),
                             ("fmt.", 2), ("defer ", 2)]),
        definition("ruby", "Ruby", "Q161053",
                   aliases: ["ruby", "rb"],
                   signals: [("attr_", 2), ("require ", 2), ("puts ", 2),
                             ("do |", 2), ("def ", 2), ("\nend", 1)]),
        definition("csharp", "C#", "Q2370",
                   aliases: ["c#", "csharp", "cs"],
                   signals: [("using system;", 4), ("using system.", 4),
                             ("console.writeline", 3),
                             ("namespace ", 2), ("static void main", 2), ("public class ", 2)]),
        definition("cpp", "C++", "Q2407",
                   aliases: ["c++", "cpp", "cxx", "cc"],
                   signals: [("#include <iostream", 5), ("std::", 3),
                             ("cout <<", 3), ("namespace ", 2)]),
        definition("c", "C", "Q15777",
                   aliases: ["c"],
                   signals: [("#include <", 2), ("int main(", 2),
                             ("printf(", 2), ("malloc(", 2)]),
        definition("java", "Java", "Q251",
                   aliases: ["java"],
                   signals: [("static void main", 4), ("system.out.", 3),
                             ("public class ", 3), ("package ", 1)]),
    ]

    private static let operationalFenceAliases: Set<String> = [
        "bash", "console", "fish", "markdown", "md", "plaintext", "powershell",
        "ps1", "sh", "shell", "text", "terminal", "zsh",
    ]

    static func fencedHint(in text: String) -> FDCFencedCodeHint? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { continue }
            let raw = trimmed.dropFirst(3).lowercased()
            let token = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: ".{}"))
            if normalized.isEmpty { return .unknown }
            if operationalFenceAliases.contains(normalized) { return .operational }
            if let definition = definitions.first(where: { $0.aliases.contains(normalized) }) {
                return .language(definition.language)
            }
            return .unknown
        }
        return nil
    }

    public static func detect(in text: String) -> FDCCodeLanguage? {
        switch fencedHint(in: text) {
        case let .language(language)?: return language
        case .operational?: return nil
        case .unknown?, nil: break
        }

        let lowered = text.lowercased()
        let scores = definitions.map { definition in
            definition.signals.reduce(0) { score, signal in
                lowered.contains(signal.0) ? score + signal.1 : score
            }
        }
        guard let maximum = scores.max(), maximum >= 3 else { return nil }
        guard scores.filter({ $0 == maximum }).count == 1,
              let index = scores.firstIndex(of: maximum) else { return nil }
        return definitions[index].language
    }
}
