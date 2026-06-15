//! Chunk + ScoredChunk. A unit of text retrievable from a RAG
//! bundle.
//!
//! The chunk id is content-addressed: a deterministic RFC 4122 v5
//! UUID over (source_id, start_offset, text). Identical content
//! yields an identical id, which makes re-ingestion idempotent and
//! lets the sync layer's AppendOnly conflict policy reconcile the
//! same chunk arriving from two devices. The derivation is fixed by
//! RFC 4122, so this matches the Swift port byte for byte (see
//! CorpusKit/Sources/CorpusKit/Chunk.swift::deriveID and the parity test).
//!
//! HLC is stored as the substrate's `HLC` value directly --
//! `substrate_types::hlc::HLC` is `Copy`, so embedding it adds no
//! cost. Metadata is the only field that ever crosses the serde
//! boundary (encoded as JSON in `BundleStore`); the struct itself
//! is not serde-derived because nothing serializes a `Chunk`
//! whole.

use std::collections::BTreeMap;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    /// Stable primary key, assigned on insert.
    pub id: Uuid,
    /// Identifier of the source document this chunk belongs to.
    /// Free-form: file path, drawer id, URL, etc.
    pub source_id: String,
    /// Character offset of this chunk in the source.
    pub start_offset: usize,
    /// Character length of this chunk's text.
    pub length: usize,
    /// Verbatim chunk text. Stored as-is; the kit does not
    /// normalize or lowercase.
    pub text: String,
    /// Substrate HLC for ordering across replicas. Filled by the
    /// chunker or the bundle store on insert.
    pub hlc: HLC,
    /// Free-form metadata. Encoded as JSON in storage; the
    /// `BTreeMap` ordering keeps the encoded bytes stable for
    /// fixture comparison.
    pub metadata: BTreeMap<String, String>,
}

impl Chunk {
    pub fn new(
        id: Uuid,
        source_id: impl Into<String>,
        start_offset: usize,
        length: usize,
        text: impl Into<String>,
        hlc: HLC,
        metadata: BTreeMap<String, String>,
    ) -> Self {
        Chunk {
            id,
            source_id: source_id.into(),
            start_offset,
            length,
            text: text.into(),
            hlc,
            metadata,
        }
    }

    /// Content-addressed constructor. Derives the id from
    /// (source_id, start_offset, text); identical content yields an
    /// identical id. This is what the chunker and normal ingestion
    /// use. `new` remains for reconstructing a chunk whose id is
    /// already known (decoding a row, or a test needing a specific id).
    pub fn content_addressed(
        source_id: impl Into<String>,
        start_offset: usize,
        length: usize,
        text: impl Into<String>,
        hlc: HLC,
        metadata: BTreeMap<String, String>,
    ) -> Self {
        let source_id = source_id.into();
        let text = text.into();
        let id = Self::derive_id(&source_id, start_offset, &text);
        Chunk {
            id,
            source_id,
            start_offset,
            length,
            text,
            hlc,
            metadata,
        }
    }

    /// Fixed namespace for CorpusKit chunk ids. MUST NOT change:
    /// changing it re-keys every chunk fleet-wide and breaks the join
    /// to existing vectors. UUID d6f3a1b2-7c84-4e5f-9a0b-1c2d3e4f5061.
    const NAMESPACE: Uuid = Uuid::from_bytes([
        0xd6, 0xf3, 0xa1, 0xb2, 0x7c, 0x84, 0x4e, 0x5f, 0x9a, 0x0b, 0x1c, 0x2d, 0x3e, 0x4f, 0x50,
        0x61,
    ]);

    /// Derive the content-addressed v5 UUID for a chunk. The name is
    /// the UTF-8 encoding of `source_id + US + start_offset + US +
    /// text`, where US is the unit separator (0x1F). RFC 4122 v5
    /// (SHA-1) makes this byte-identical to the Swift port.
    pub fn derive_id(source_id: &str, start_offset: usize, text: &str) -> Uuid {
        // Unit separator (0x1F) between the three identity fields.
        // Built outside the format literal so the escape does not
        // collide with format!'s brace parsing.
        const US: char = '\u{1f}';
        let mut name = String::new();
        name.push_str(source_id);
        name.push(US);
        name.push_str(&start_offset.to_string());
        name.push(US);
        name.push_str(text);
        Uuid::new_v5(&Self::NAMESPACE, name.as_bytes())
    }
}

/// Chunk plus its retrieval score. Returned by hybrid retrieval.
#[derive(Debug, Clone, PartialEq)]
pub struct ScoredChunk {
    pub chunk: Chunk,
    pub score: f32,
    pub vector_score: Option<f32>,
    pub keyword_score: Option<f32>,
}

impl ScoredChunk {
    pub fn new(chunk: Chunk, score: f32) -> Self {
        ScoredChunk {
            chunk,
            score,
            vector_score: None,
            keyword_score: None,
        }
    }

    pub fn with_subscores(mut self, vector_score: Option<f32>, keyword_score: Option<f32>) -> Self {
        self.vector_score = vector_score;
        self.keyword_score = keyword_score;
        self
    }
}
