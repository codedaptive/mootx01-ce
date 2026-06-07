// swift-tools-version: 6.2
//
// AriaLexicon, the reified ARIA grammar. One noun, nine verbs, four
// adjectives, and the verb-noun acceptance matrix, as data. No
// behavior. This is the vocabulary every MOOTx01 kit and every ARIA
// surface conforms to, so the Swift and Rust ports can be checked for
// agreement on the words themselves. The canonical statement is
// ARIA_LEXICON.md; this module makes it first-class in code.
//
// Foundational: depends on nothing. It sits above SubstrateLib and
// PersistenceKit and below LocusKit, VectorKit, and CorpusKit, because every
// one of them conforms to it.

import PackageDescription

let package = Package(
    name: "AriaLexiconLib",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "AriaLexiconLib",
            targets: ["AriaLexiconLib"]
        ),
    ],
    targets: [
        .target(
            name: "AriaLexiconLib"
        ),
        .testTarget(
            name: "AriaLexiconLibTests",
            dependencies: ["AriaLexiconLib"]
        ),
    ]
)
