// Chunker.swift
//
// Sentence-aware chunking for RAG ingestion. Sentence
// segmentation is delegated to EideticLib.sentences(_:),
// which centralizes the apple-nlp-accel pattern (FDC encoder
// mandate, C-2) alongside Tokenizer / Normalizer / Stemmer /
// WordClassTagger. The default chunk size matches the substrate
// reference (target 800 chars, overlap 100).

import Foundation
import EideticLib
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

/// Chunking parameters. Defaults match the substrate reference
/// (800-char target with 100-char overlap).
public struct ChunkerConfiguration: Sendable {
    public let targetChars: Int
    public let overlapChars: Int
    public let respectSentences: Bool

    public init(
        targetChars: Int = 800,
        overlapChars: Int = 100,
        respectSentences: Bool = true
    ) {
        self.targetChars = max(1, targetChars)
        self.overlapChars = max(0, min(overlapChars, targetChars - 1))
        self.respectSentences = respectSentences
    }
}

public enum Chunker {

    /// Split text into chunks per the configuration. Each chunk
    /// carries the source identifier, the start offset (character
    /// index), and an HLC tag assigned in order.
    public static func chunk(
        text: String,
        sourceID: String,
        configuration: ChunkerConfiguration = ChunkerConfiguration(),
        hlcGenerator: inout HLCGenerator
    ) -> [Chunk] {
        let segments = configuration.respectSentences
            ? EideticLib.sentences(text)
            : [text[text.startIndex..<text.endIndex]]
        var chunks: [Chunk] = []
        var buffer = ""
        var bufferStart = 0
        var currentOffset = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            let hlc = hlcGenerator.send(now: Int64(Date().timeIntervalSince1970 * 1000))
            chunks.append(Chunk(
                sourceID: sourceID,
                startOffset: bufferStart,
                length: buffer.count,
                text: buffer,
                hlc: hlc
            ))
            // Begin next buffer at (current end) minus overlap.
            let overlap = min(configuration.overlapChars, buffer.count)
            let nextStart = bufferStart + buffer.count - overlap
            if overlap > 0 {
                let dropCount = buffer.count - overlap
                let idx = buffer.index(buffer.startIndex, offsetBy: dropCount)
                buffer = String(buffer[idx...])
            } else {
                buffer = ""
            }
            bufferStart = nextStart
        }

        for segment in segments {
            let segmentText = String(segment)
            let segmentLen = segmentText.count
            if buffer.isEmpty {
                bufferStart = currentOffset
            }
            if buffer.count + segmentLen <= configuration.targetChars || buffer.isEmpty {
                buffer.append(segmentText)
            } else {
                flush()
                if buffer.isEmpty { bufferStart = currentOffset }
                buffer.append(segmentText)
            }
            currentOffset += segmentLen
            if buffer.count >= configuration.targetChars {
                flush()
            }
        }
        if !buffer.isEmpty {
            let hlc = hlcGenerator.send(now: Int64(Date().timeIntervalSince1970 * 1000))
            chunks.append(Chunk(
                sourceID: sourceID,
                startOffset: bufferStart,
                length: buffer.count,
                text: buffer,
                hlc: hlc
            ))
        }
        return chunks
    }
}
