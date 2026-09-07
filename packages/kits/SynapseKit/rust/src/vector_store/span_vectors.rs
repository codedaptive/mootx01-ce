//! Encoder span rows in the `vectors` table (ENCODER_RERANK_CONTRACT §3,
//! SYNAPSEKIT_SPEC § I-4a). A retrieval-trained sentence encoder splits each
//! drawer's content into overlapping word windows ("spans"); every span is
//! stored as ONE `vectors` row under the encoder's model id:
//!
//!   item_id       = the drawer UUID
//!   vector_index  = the span index (0-based, span order)
//!   kind          = 2 (Int8), dim = the model dimension
//!   payload       = dim bytes, two's-complement i8 (substrate-kernel int8_vec)
//!   scale         = the per-vector dequantisation scale (REAL)
//!   generation    = the model's serving generation (0 unless a swap happened)
//!   ext           = {"cv":"<content_version>","e":<end_word>,"s":<start_word>}
//!
//! No new table and no new column: this is the multi-vector row shape the
//! table has carried since Lane F (`vector_index`), with the Int8 lane now
//! populated under the ratified quantisation policy. Whole-record encoder
//! vectors are never stored — spans only.
//!
//! Why a dedicated API instead of `add_payloads`: a span set is replaced as
//! a unit. Re-encoding a drawer after a content edit must never leave a
//! stale tail (old span 7 surviving next to new spans 0–5), so
//! `write_span_vectors` deletes the item's span rows and inserts the new set
//! in ONE transaction. Span rows never enter the resident Hamming array or a
//! float index: the rerank stage fetches them per query by item id
//! (`span_vectors`) and scores them with `int8_vec::dot_query`; that is the
//! whole read path.
//!
//! `ext` is written by hand with sorted keys and minimal escaping so the
//! Swift and Rust ports emit byte-identical text (this crate carries no JSON
//! library, and Foundation's JSONSerialization escapes "/"). Reading is
//! tolerant of key order.
//!
//! Swift twin: Sources/SynapseKit/VectorStore+SpanVectors.swift.

use super::*;

/// One span to persist through `VectorStore::write_span_vectors`.
///
/// `int8` and `scale` come straight from `int8_vec::quantize` over the
/// encoder's L2-normalised span vector. `start_word`/`end_word` are the
/// half-open word bounds `[start_word, end_word)` of the span in the
/// product's word split, kept so the composer can render the evidence
/// snippet without re-spanning. `content_version` is the drawer's
/// `content_hash` at encode time; a later content write changes it, which
/// is how a stale span set is recognised. Mirrors Swift `SpanVectorInput`.
#[derive(Debug, Clone, PartialEq)]
pub struct SpanVectorInput {
    /// Span index within the item (0-based, in span order). Stored as
    /// `vector_index`; unique within one write.
    pub index: u32,
    /// Quantised coefficients, exactly `dim` entries.
    pub int8: Vec<i8>,
    /// Per-vector dequantisation scale (`int8_vec::quantize` output).
    pub scale: f32,
    /// First word of the span (inclusive).
    pub start_word: usize,
    /// End word of the span (exclusive).
    pub end_word: usize,
    /// The drawer's content version (`content_hash`) the span was cut from.
    pub content_version: String,
}

/// One span row read back through `VectorStore::span_vectors`. Same fields
/// as `SpanVectorInput`; a distinct type so the write shape and the read
/// shape can diverge later without an API break. Mirrors Swift
/// `SpanVectorRow`.
#[derive(Debug, Clone, PartialEq)]
pub struct SpanVectorRow {
    pub index: u32,
    pub int8: Vec<i8>,
    pub scale: f32,
    pub start_word: usize,
    pub end_word: usize,
    pub content_version: String,
}

/// Upper bound on ids per `IN (...)` clause. SQLite caps expression-tree
/// depth at 1000; 900 leaves headroom for the surrounding predicate.
const SPAN_QUERY_ID_CHUNK: usize = 900;

impl VectorStore {
    /// Replace every span row of `(item_id, model_id)` with `spans`,
    /// atomically.
    ///
    /// Deletes the item's existing Int8 rows under `model_id` at the serving
    /// generation and inserts one row per span inside ONE transaction, so a
    /// reader never observes a mix of the old and the new span set. Passing
    /// an empty `spans` removes the item's spans (a drawer whose content
    /// shrank to nothing).
    ///
    /// `filed_at` is the filing instant, passed in (determinism discipline:
    /// the store never reads the clock) and stored through
    /// `TypedValue::Timestamp` unchanged, the same unit the caller uses for
    /// `VectorPayloadInput::filed_at_unix_secs`.
    ///
    /// Errors: `SynapseKitError::InvalidPayload` when the spans disagree on
    /// dimension, carry an empty vector, repeat an index, or invert a word
    /// range; storage errors surface as `StoreUnavailable`.
    /// Mirrors Swift `VectorStore.writeSpanVectors`.
    pub fn write_span_vectors(
        &self,
        item_id: &str,
        model_id: &str,
        model_version: &str,
        spans: &[SpanVectorInput],
        filed_at: i64,
    ) -> Result<(), SynapseKitError> {
        validate_span_set(spans, item_id)?;
        let serving_gen = self.serving_generation(model_id)?;
        let row_store = self.storage.row_store();
        row_store
            .begin_transaction()
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let db_result = (|| -> Result<(), SynapseKitError> {
            row_store
                .delete("vectors", &span_rows_predicate(item_id, model_id, serving_gen))
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            for span in spans {
                let mut values = BTreeMap::new();
                values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
                values.insert("item_id".to_string(), TypedValue::Text(item_id.to_string()));
                values.insert("vector_index".to_string(), TypedValue::Int(span.index as i64));
                values.insert("model_id".to_string(), TypedValue::Text(model_id.to_string()));
                values.insert(
                    "model_version".to_string(),
                    TypedValue::Text(model_version.to_string()),
                );
                values.insert("kind".to_string(), TypedValue::Int(VectorKind::Int8.raw()));
                values.insert("dim".to_string(), TypedValue::Int(span.int8.len() as i64));
                values.insert(
                    "payload".to_string(),
                    TypedValue::Blob(span.int8.iter().map(|&q| q as u8).collect()),
                );
                values.insert("scale".to_string(), TypedValue::Float(span.scale as f64));
                values.insert("filed_at".to_string(), TypedValue::Timestamp(filed_at));
                values.insert(
                    "ext".to_string(),
                    TypedValue::Text(encode_span_ext(
                        span.start_word,
                        span.end_word,
                        &span.content_version,
                    )),
                );
                values.insert("generation".to_string(), TypedValue::Int(serving_gen));
                row_store
                    .insert("vectors", values)
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            }
            Ok(())
        })();
        match db_result {
            Ok(()) => row_store
                .commit_transaction()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string())),
            Err(e) => {
                let _ = row_store.rollback_transaction();
                Err(e)
            }
        }
    }

    /// The span rows of every item in `item_ids` under `model_id`, serving
    /// generation only, keyed by item id and ordered by span index.
    ///
    /// Items with no span rows are absent from the result (the rerank stage
    /// keeps them at their lexical rank). Ids are queried in chunks of
    /// `SPAN_QUERY_ID_CHUNK`, so a 1000-item head is two statements. A row
    /// whose payload, scale, or `ext` is malformed is skipped, matching the
    /// store's other read paths (`decode_stored_vector`), because one bad
    /// row must not take a query down. Mirrors Swift
    /// `VectorStore.spanVectors(itemIDs:modelID:)`.
    pub fn span_vectors(
        &self,
        item_ids: &[&str],
        model_id: &str,
    ) -> Result<BTreeMap<String, Vec<SpanVectorRow>>, SynapseKitError> {
        let mut result: BTreeMap<String, Vec<SpanVectorRow>> = BTreeMap::new();
        if item_ids.is_empty() {
            return Ok(result);
        }
        let serving_gen = self.serving_generation(model_id)?;
        let mut unique: Vec<&str> = item_ids.to_vec();
        unique.sort_unstable();
        unique.dedup();
        let row_store = self.storage.row_store();
        for chunk in unique.chunks(SPAN_QUERY_ID_CHUNK) {
            let ids: Vec<TypedValue> = chunk.iter().map(|s| TypedValue::Text(s.to_string())).collect();
            let predicate = StoragePredicate::And(vec![
                StoragePredicate::In(Column::new("vectors", "item_id"), ids),
                StoragePredicate::Eq(
                    Column::new("vectors", "model_id"),
                    TypedValue::Text(model_id.to_string()),
                ),
                StoragePredicate::Eq(
                    Column::new("vectors", "kind"),
                    TypedValue::Int(VectorKind::Int8.raw()),
                ),
                StoragePredicate::Eq(
                    Column::new("vectors", "generation"),
                    TypedValue::Int(serving_gen),
                ),
            ]);
            let order = vec![
                OrderClause::new(Column::new("vectors", "item_id"), OrderDirection::Ascending),
                OrderClause::new(Column::new("vectors", "vector_index"), OrderDirection::Ascending),
            ];
            let rows = row_store
                .query("vectors", Some(&predicate), &order, None, None)
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            for row in rows {
                let item = match row.get("item_id") {
                    Some(TypedValue::Text(s)) => s.clone(),
                    _ => continue,
                };
                if let Some(span) = span_row_from(&row) {
                    result.entry(item).or_default().push(span);
                }
            }
        }
        Ok(result)
    }

    /// Remove every span row of `(item_id, model_id)` across all generations.
    /// Used when a drawer is expunged; a content edit goes through
    /// `write_span_vectors` instead, which replaces rather than deletes.
    /// Mirrors Swift `VectorStore.deleteSpanVectors(itemID:modelID:)`.
    pub fn delete_span_vectors(&self, item_id: &str, model_id: &str) -> Result<(), SynapseKitError> {
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("vectors", "item_id"),
                TypedValue::Text(item_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "kind"),
                TypedValue::Int(VectorKind::Int8.raw()),
            ),
        ]);
        self.storage
            .row_store()
            .delete("vectors", &predicate)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Delete the rows `mootx01 upgrade` reclaims: every row of the retired
    /// model ids, and every row whose generation is not its model's serving
    /// generation. Returns `(retired_model_rows, non_serving_rows)`.
    ///
    /// Models with a shadow build in flight (`shadow_state == "building"`)
    /// are left alone: their shadow rows are work in progress, not garbage.
    /// Matching `hnsw_graph` rows go with their vectors. Because this is a
    /// maintenance pass over the durable table, the resident structures are
    /// rebuilt from the table afterwards whenever anything was deleted, so a
    /// long-lived store stays coherent; the upgrade opens a fresh store and
    /// pays nothing. Never runs inside a query path. Mirrors Swift
    /// `VectorStore.reclaimRetiredVectorRows(retiredModelIDs:)`.
    pub fn reclaim_retired_vector_rows(
        &self,
        retired_model_ids: &[&str],
    ) -> Result<(usize, usize), SynapseKitError> {
        let row_store = self.storage.row_store();
        let store_err = |e: persistence_kit::StorageError| SynapseKitError::StoreUnavailable(e.to_string());
        let mut retired_rows = 0usize;
        if !retired_model_ids.is_empty() {
            let ids: Vec<TypedValue> = retired_model_ids
                .iter()
                .map(|s| TypedValue::Text(s.to_string()))
                .collect();
            retired_rows = row_store
                .delete(
                    "vectors",
                    &StoragePredicate::In(Column::new("vectors", "model_id"), ids.clone()),
                )
                .map_err(store_err)?;
            row_store
                .delete(
                    "hnsw_graph",
                    &StoragePredicate::In(Column::new("hnsw_graph", "model_id"), ids),
                )
                .map_err(store_err)?;
        }

        // Serving generation per registered model; models with an active
        // shadow build are skipped entirely.
        let mut serving_by_model: BTreeMap<String, i64> = BTreeMap::new();
        let mut building: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        let registry = row_store
            .query("vector_generations", None, &[], None, None)
            .map_err(store_err)?;
        for row in &registry {
            let model = match row.get("model_id") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => continue,
            };
            if let Some(TypedValue::Int(gen)) = row.get("serving_generation") {
                serving_by_model.insert(model.clone(), *gen);
            }
            if let Some(TypedValue::Text(state)) = row.get("shadow_state") {
                if state == "building" {
                    building.insert(model);
                }
            }
        }
        // Distinct (model, generation) pairs present in the table, read
        // through a two-column projection so no payload is materialised.
        let pair_rows = row_store
            .query_projected("vectors", &["model_id", "generation"], None, &[], None, None)
            .map_err(store_err)?;
        let mut seen: std::collections::BTreeSet<(String, i64)> = std::collections::BTreeSet::new();
        let mut stale: Vec<(String, i64)> = Vec::new();
        for row in &pair_rows {
            let model = match row.get("model_id") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => continue,
            };
            let generation = match row.get("generation") {
                Some(TypedValue::Int(g)) => *g,
                _ => 0,
            };
            if !seen.insert((model.clone(), generation)) || building.contains(&model) {
                continue;
            }
            // Unregistered models serve generation 0 (never swapped).
            if generation != serving_by_model.get(&model).copied().unwrap_or(0) {
                stale.push((model, generation));
            }
        }
        let mut non_serving_rows = 0usize;
        for (model, generation) in &stale {
            non_serving_rows += row_store
                .delete(
                    "vectors",
                    &StoragePredicate::And(vec![
                        StoragePredicate::Eq(
                            Column::new("vectors", "model_id"),
                            TypedValue::Text(model.clone()),
                        ),
                        StoragePredicate::Eq(
                            Column::new("vectors", "generation"),
                            TypedValue::Int(*generation),
                        ),
                    ]),
                )
                .map_err(store_err)?;
            row_store
                .delete(
                    "hnsw_graph",
                    &StoragePredicate::And(vec![
                        StoragePredicate::Eq(
                            Column::new("hnsw_graph", "model_id"),
                            TypedValue::Text(model.clone()),
                        ),
                        StoragePredicate::Eq(
                            Column::new("hnsw_graph", "generation"),
                            TypedValue::Int(*generation),
                        ),
                    ]),
                )
                .map_err(store_err)?;
        }
        if retired_rows + non_serving_rows > 0 {
            let mut state = self.state.lock().map_err(|_| {
                SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
            })?;
            for id in retired_model_ids {
                state.float_indices.remove(*id);
                state.hnsw_indices.remove(*id);
                state.live_float_counts.remove(*id);
                state.hnsw_graph_dirty.remove(*id);
            }
            self.rebuild_binary_index_from_table_locked(&mut state)?;
        }
        Ok((retired_rows, non_serving_rows))
    }

    /// Delete every whole-record float row (`kind` 1, the `Float32` payloads
    /// the retired whole-record dense lane read) and every `hnsw_graph` row
    /// (the float lane's graph, rebuilt from those rows and useless without
    /// them), then rebuild the resident binary index and the `.vec` sidecar
    /// from the surviving rows so the sidecar's live count and generation
    /// match the serving table. Returns `(float_rows, graph_rows)`. Kind 0
    /// (binary fingerprints) and kind 2 (int8 spans) are never touched.
    ///
    /// The GLK 1.6 to 1.7 migration capsule calls this once per populated
    /// estate. Idempotent: a vacuumed estate deletes nothing and the rebuild
    /// rewrites an identical sidecar. Never runs inside a query path. Twin of
    /// Swift `VectorStore.reclaimWholeRecordFloatRows()`.
    pub fn reclaim_whole_record_float_rows(&self) -> Result<(usize, usize), SynapseKitError> {
        let row_store = self.storage.row_store();
        let store_err = |e: persistence_kit::StorageError| SynapseKitError::StoreUnavailable(e.to_string());
        let float_rows = row_store
            .delete(
                "vectors",
                &StoragePredicate::Eq(
                    Column::new("vectors", "kind"),
                    TypedValue::Int(VectorKind::Float32.raw()),
                ),
            )
            .map_err(store_err)?;
        let graph_rows = row_store
            .delete("hnsw_graph", &StoragePredicate::IsTrue)
            .map_err(store_err)?;
        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        // The resident float and HNSW state described rows that are gone.
        state.float_indices.clear();
        state.hnsw_indices.clear();
        state.live_float_counts.clear();
        state.hnsw_graph_dirty.clear();
        self.rebuild_binary_index_from_table_locked(&mut state)?;
        Ok((float_rows, graph_rows))
    }
}

/// The serving-generation span rows of one item under one model.
fn span_rows_predicate(item_id: &str, model_id: &str, generation: i64) -> StoragePredicate {
    StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new("vectors", "item_id"),
            TypedValue::Text(item_id.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new("vectors", "model_id"),
            TypedValue::Text(model_id.to_string()),
        ),
        StoragePredicate::Eq(Column::new("vectors", "kind"), TypedValue::Int(VectorKind::Int8.raw())),
        StoragePredicate::Eq(Column::new("vectors", "generation"), TypedValue::Int(generation)),
    ])
}

/// One dimension, non-empty vectors, unique indexes, ordered word ranges.
fn validate_span_set(spans: &[SpanVectorInput], item_id: &str) -> Result<(), SynapseKitError> {
    let Some(first) = spans.first() else { return Ok(()) };
    let dim = first.int8.len();
    if dim == 0 {
        return Err(SynapseKitError::InvalidPayload(format!(
            "write_span_vectors({item_id}): span vectors must not be empty"
        )));
    }
    let mut seen = std::collections::BTreeSet::new();
    for span in spans {
        if span.int8.len() != dim {
            return Err(SynapseKitError::InvalidPayload(format!(
                "write_span_vectors({item_id}): span {} has dim {}, expected {dim}",
                span.index,
                span.int8.len()
            )));
        }
        if !seen.insert(span.index) {
            return Err(SynapseKitError::InvalidPayload(format!(
                "write_span_vectors({item_id}): duplicate span index {}",
                span.index
            )));
        }
        if span.end_word < span.start_word {
            return Err(SynapseKitError::InvalidPayload(format!(
                "write_span_vectors({item_id}): span {} has word range [{}, {})",
                span.index, span.start_word, span.end_word
            )));
        }
    }
    Ok(())
}

/// `{"cv":"…","e":N,"s":N}` with sorted keys and minimal JSON string
/// escaping (quote, backslash, control characters as \u00XX). Byte-identical
/// to the Swift writer by construction.
pub(crate) fn encode_span_ext(start: usize, end: usize, content_version: &str) -> String {
    let mut out = String::with_capacity(24 + content_version.len());
    out.push_str("{\"cv\":\"");
    for ch in content_version.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push_str("\",\"e\":");
    out.push_str(&end.to_string());
    out.push_str(",\"s\":");
    out.push_str(&start.to_string());
    out.push('}');
    out
}

/// Parse the `ext` JSON object written by `encode_span_ext` (either port).
/// A flat object of string and integer members; key order is not assumed;
/// unknown members are ignored. Returns `None` for anything malformed.
pub(crate) fn decode_span_ext(text: &str) -> Option<(usize, usize, String)> {
    let mut chars = text.chars().peekable();
    fn skip_ws(it: &mut std::iter::Peekable<std::str::Chars<'_>>) {
        while matches!(it.peek(), Some(c) if c.is_whitespace()) {
            it.next();
        }
    }
    fn read_string(it: &mut std::iter::Peekable<std::str::Chars<'_>>) -> Option<String> {
        // Opening quote already consumed by the caller.
        let mut out = String::new();
        loop {
            match it.next()? {
                '"' => return Some(out),
                '\\' => match it.next()? {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'b' => out.push('\u{8}'),
                    'f' => out.push('\u{c}'),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'u' => {
                        let mut code = 0u32;
                        for _ in 0..4 {
                            code = code * 16 + it.next()?.to_digit(16)?;
                        }
                        out.push(char::from_u32(code)?);
                    }
                    _ => return None,
                },
                c => out.push(c),
            }
        }
    }
    skip_ws(&mut chars);
    if chars.next()? != '{' {
        return None;
    }
    let (mut start, mut end, mut cv): (Option<usize>, Option<usize>, Option<String>) = (None, None, None);
    loop {
        skip_ws(&mut chars);
        match chars.peek()? {
            '}' => {
                chars.next();
                break;
            }
            ',' => {
                chars.next();
                continue;
            }
            '"' => {
                chars.next();
            }
            _ => return None,
        }
        let key = read_string(&mut chars)?;
        skip_ws(&mut chars);
        if chars.next()? != ':' {
            return None;
        }
        skip_ws(&mut chars);
        if chars.peek()? == &'"' {
            chars.next();
            let value = read_string(&mut chars)?;
            if key == "cv" {
                cv = Some(value);
            }
        } else {
            let mut digits = String::new();
            while matches!(chars.peek(), Some(c) if c.is_ascii_digit() || *c == '-') {
                digits.push(chars.next()?);
            }
            let value: usize = digits.parse().ok()?;
            match key.as_str() {
                "s" => start = Some(value),
                "e" => end = Some(value),
                _ => {}
            }
        }
    }
    Some((start?, end?, cv?))
}

/// Decode one `vectors` row into a span row; `None` when malformed.
fn span_row_from(row: &persistence_kit::StorageRow) -> Option<SpanVectorRow> {
    let index = match row.get("vector_index") {
        Some(TypedValue::Int(v)) if *v >= 0 && *v <= u32::MAX as i64 => *v as u32,
        _ => return None,
    };
    let dim = match row.get("dim") {
        Some(TypedValue::Int(v)) if *v > 0 => *v as usize,
        _ => return None,
    };
    let bytes = match row.get("payload") {
        Some(TypedValue::Blob(b)) if b.len() == dim => b,
        _ => return None,
    };
    let scale = match row.get("scale") {
        Some(TypedValue::Float(f)) => *f as f32,
        _ => return None,
    };
    let ext = match row.get("ext") {
        Some(TypedValue::Text(s)) => s,
        _ => return None,
    };
    let (start_word, end_word, content_version) = decode_span_ext(ext)?;
    Some(SpanVectorRow {
        index,
        int8: bytes.iter().map(|&b| b as i8).collect(),
        scale,
        start_word,
        end_word,
        content_version,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn span_ext_round_trips_and_is_byte_stable() {
        let text = encode_span_ext(60, 120, "ab\"c\\d\u{1}");
        assert_eq!(text, "{\"cv\":\"ab\\\"c\\\\d\\u0001\",\"e\":120,\"s\":60}");
        assert_eq!(decode_span_ext(&text), Some((60, 120, "ab\"c\\d\u{1}".to_string())));
        // Key order is not assumed on read.
        assert_eq!(decode_span_ext("{\"s\":0,\"cv\":\"x\",\"e\":7}"), Some((0, 7, "x".to_string())));
        assert_eq!(decode_span_ext("{\"s\":0}"), None);
    }
}
