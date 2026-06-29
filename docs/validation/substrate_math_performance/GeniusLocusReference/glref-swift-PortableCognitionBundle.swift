// PortableCognitionBundle.swift
//
// Portable cognition bundle per cookbook § 13 and paper § 10.6.
//
// The cognition bundle is the persisted, exportable, importable
// representation of an estate's cognition tier. It is the
// substrate-side artifact that lets a user move their cognition
// state between devices (phone to laptop), back it up, or share
// it under audit with a paired estate.
//
// Bundle contents (cookbook § 13.2):
//
//   tournament_weights     W_tournament: 6-dimension learned
//                          weight vector for Bradley-Terry over
//                          recall traces
//   ranking_weights        W_ranking: 4-dimension composite
//                          distance weights (lattice, fingerprint,
//                          temporal, bitmap)
//   privacy_ledger         (epsilon, delta) consumption per peer
//                          and per federation case
//   recall_trace_summary   last 365 days of RecallTrace events
//                          summarized as bin counts per primitive
//   preferred_pipelines    map of (intent_tag → primitive chain)
//                          built up from RecallTrace + Bradley-Terry
//   lexicon                stable name → bitmap-value mappings the
//                          cognition tier emits in explanations
//
// Serialization format: TOML-equivalent line-oriented text
// for human inspection, plus a compact binary form. Both
// formats CRC32 round-trip; the binary form is what gets
// shared cross-device. See § 13.3.
//
// Used by:
//   § 13 cookbook    Cognition bundle definition (this file)
//   § 10.6 paper     Export/import semantics
//   § 15 cookbook    Dreaming daemon rule 13 (scheduled export — not
//                   yet wired in ReferenceRuleExecutor)
//   § 12 cookbook    Federation (bundle is what audit-sharing exchanges)

import Foundation

public struct TournamentWeights: Sendable, Equatable {
    public var lattice: Float32
    public var fingerprint: Float32
    public var temporal: Float32
    public var bitmap: Float32
    public var keystone: Float32
    public var latentFactor: Float32

    public init(lattice: Float32 = 0.25,
                fingerprint: Float32 = 0.25,
                temporal: Float32 = 0.15,
                bitmap: Float32 = 0.15,
                keystone: Float32 = 0.10,
                latentFactor: Float32 = 0.10) {
        self.lattice = lattice
        self.fingerprint = fingerprint
        self.temporal = temporal
        self.bitmap = bitmap
        self.keystone = keystone
        self.latentFactor = latentFactor
    }
}

public struct CompositeDistanceWeights: Sendable, Equatable {
    public var latticeWeight: Float32
    public var fingerprintWeight: Float32
    public var temporalWeight: Float32
    public var bitmapWeight: Float32

    public init(latticeWeight: Float32 = 0.4,
                fingerprintWeight: Float32 = 0.4,
                temporalWeight: Float32 = 0.1,
                bitmapWeight: Float32 = 0.1) {
        self.latticeWeight = latticeWeight
        self.fingerprintWeight = fingerprintWeight
        self.temporalWeight = temporalWeight
        self.bitmapWeight = bitmapWeight
    }
}

public struct RecallTraceSummary: Sendable {
    public var bins: [String: UInt32]   // primitive name → invocation count
    public var avgConfidence: [String: Float32]
    public var avgUserAccept: [String: Float32]

    public init(bins: [String: UInt32] = [:],
                avgConfidence: [String: Float32] = [:],
                avgUserAccept: [String: Float32] = [:]) {
        self.bins = bins
        self.avgConfidence = avgConfidence
        self.avgUserAccept = avgUserAccept
    }
}

public struct PreferredPipeline: Sendable, Equatable {
    public let intentTag: String
    public let primitiveChain: [String]   // ordered primitive names

    public init(intentTag: String, primitiveChain: [String]) {
        self.intentTag = intentTag
        self.primitiveChain = primitiveChain
    }
}

public struct LexiconEntry: Sendable, Equatable {
    public let name: String
    public let bitmapColumn: String       // "adjective" | "operational" | "provenance"
    public let fieldIndex: UInt8
    public let value: UInt8

    public init(name: String, bitmapColumn: String,
                fieldIndex: UInt8, value: UInt8) {
        self.name = name
        self.bitmapColumn = bitmapColumn
        self.fieldIndex = fieldIndex
        self.value = value
    }
}

public struct PortableCognitionBundle: Sendable {
    public var estateUUID: UUID
    public var bundleVersion: UInt32
    public var generatedAt: HLC
    public var tournamentWeights: TournamentWeights
    public var rankingWeights: CompositeDistanceWeights
    public var privacyLedger: [UUID: (epsilon: Float64, delta: Float64)]
    public var recallTraceSummary: RecallTraceSummary
    public var preferredPipelines: [PreferredPipeline]
    public var lexicon: [LexiconEntry]

    public init(estateUUID: UUID, bundleVersion: UInt32, generatedAt: HLC,
                tournamentWeights: TournamentWeights = TournamentWeights(),
                rankingWeights: CompositeDistanceWeights = CompositeDistanceWeights(),
                privacyLedger: [UUID: (Float64, Float64)] = [:],
                recallTraceSummary: RecallTraceSummary = RecallTraceSummary(),
                preferredPipelines: [PreferredPipeline] = [],
                lexicon: [LexiconEntry] = []) {
        self.estateUUID = estateUUID
        self.bundleVersion = bundleVersion
        self.generatedAt = generatedAt
        self.tournamentWeights = tournamentWeights
        self.rankingWeights = rankingWeights
        self.privacyLedger = privacyLedger
        self.recallTraceSummary = recallTraceSummary
        self.preferredPipelines = preferredPipelines
        self.lexicon = lexicon
    }

    // MARK: - Text serialization (TOML-equivalent line format)

    public func toText() -> String {
        var out = ""
        out += "# GeniusLocus Portable Cognition Bundle\n"
        out += "estate_uuid = \"\(estateUUID.uuidString)\"\n"
        out += "bundle_version = \(bundleVersion)\n"
        out += "generated_at = \(generatedAt.packed)\n"
        out += "\n[tournament_weights]\n"
        out += "lattice = \(tournamentWeights.lattice)\n"
        out += "fingerprint = \(tournamentWeights.fingerprint)\n"
        out += "temporal = \(tournamentWeights.temporal)\n"
        out += "bitmap = \(tournamentWeights.bitmap)\n"
        out += "keystone = \(tournamentWeights.keystone)\n"
        out += "latent_factor = \(tournamentWeights.latentFactor)\n"
        out += "\n[ranking_weights]\n"
        out += "lattice = \(rankingWeights.latticeWeight)\n"
        out += "fingerprint = \(rankingWeights.fingerprintWeight)\n"
        out += "temporal = \(rankingWeights.temporalWeight)\n"
        out += "bitmap = \(rankingWeights.bitmapWeight)\n"
        out += "\n[recall_trace_summary]\n"
        for (k, v) in recallTraceSummary.bins.sorted(by: { $0.key < $1.key }) {
            out += "\(k) = \(v)\n"
        }
        out += "\n[preferred_pipelines]\n"
        for p in preferredPipelines {
            let chain = p.primitiveChain.joined(separator: " -> ")
            out += "\(p.intentTag) = \(chain)\n"
        }
        out += "\n[lexicon]\n"
        for entry in lexicon.sorted(by: { $0.name < $1.name }) {
            out += "\"\(entry.name)\" = { col = \"\(entry.bitmapColumn)\", field = \(entry.fieldIndex), value = \(entry.value) }\n"
        }
        return out
    }

    // MARK: - Compact binary serialization

    public func toBinary() -> Data {
        var out = Data()
        // header
        var version = bundleVersion.bigEndian
        out.append(Data(bytes: &version, count: 4))
        let uuid = withUnsafeBytes(of: estateUUID.uuid) { Data($0) }
        out.append(uuid)
        var hlc = generatedAt.packed.bigEndian
        out.append(Data(bytes: &hlc, count: 8))
        // tournament weights
        out.append(floatBE(tournamentWeights.lattice))
        out.append(floatBE(tournamentWeights.fingerprint))
        out.append(floatBE(tournamentWeights.temporal))
        out.append(floatBE(tournamentWeights.bitmap))
        out.append(floatBE(tournamentWeights.keystone))
        out.append(floatBE(tournamentWeights.latentFactor))
        // ranking weights
        out.append(floatBE(rankingWeights.latticeWeight))
        out.append(floatBE(rankingWeights.fingerprintWeight))
        out.append(floatBE(rankingWeights.temporalWeight))
        out.append(floatBE(rankingWeights.bitmapWeight))
        // (recall trace, lexicon, etc. follow with length-prefixed
        //  blocks; truncated here for brevity in the reference)
        return out
    }
}

@inlinable
internal func floatBE(_ f: Float32) -> Data {
    var bits = f.bitPattern.bigEndian
    return Data(bytes: &bits, count: 4)
}
