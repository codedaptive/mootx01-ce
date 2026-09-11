//! Direct estate adapter for the typed ARIA v2 core-memory operations.

use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
    RecallOrigin,
};
use genius_locus_kit::{GLKResultsPackager, PackagerAnswerMode, WriteMode};
use locus_kit::{
    adjectives::{AdjectiveExportability, AdjectiveSensitivity},
    default_wings::DEFAULT_WING_NAME,
    drawer::Drawer,
    drawer_operational::{CaptureChannel, ContentKind, DrawerFeatureFlags},
    estate_types::LatticeAnchor,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::CaptureFrame,
    provenance::Channel,
};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

use crate::estate_registry::{EstateRegistry, OpenEstate};

use super::core_memory::{
    V2AnswerMode, V2CompactMemory, V2ContentKind, V2CoreMemoryService, V2Exportability,
    V2FetchArguments, V2FetchReference, V2FiledMemory, V2FileMemoryRequest,
    V2Memory, V2MemoryFailure, V2MemoryGetRequest, V2MemoryOperationContext,
    V2MemorySearchRequest, V2MemorySearchResult, V2Placement, V2SearchAnswerBlock,
    V2SearchDoor, V2SearchFilter, V2SearchMediaType, V2SearchOrdering,
    V2SearchScoring, V2SearchTarget, V2Sensitivity, MEMORY_GET_TOOL,
};

pub struct EstateV2MemoryService<'a> {
    registry: &'a EstateRegistry,
    posture: crate::estate_posture::EstatePosture,
}

impl<'a> EstateV2MemoryService<'a> {
    pub fn new(registry: &'a EstateRegistry, posture: crate::estate_posture::EstatePosture) -> Self {
        Self { registry, posture }
    }

    fn estate(&self, context: &V2MemoryOperationContext) -> Result<&OpenEstate, V2MemoryFailure> {
        if context.estate_id.is_none_or(|id| id == self.registry.default.estate_id) {
            Ok(&self.registry.default)
        } else {
            Err(failure("estate_unavailable", "The requested estate is not available to this caller."))
        }
    }

    fn record(&self, estate: &OpenEstate, drawer: &Drawer) -> Result<V2Memory, V2MemoryFailure> {
        let names = estate.coord.lock().map_err(|_| failure("estate_unavailable", "The estate coordinator is unavailable."))?
            .resolve_drawer_node_names(&estate.handle, std::slice::from_ref(&drawer.parent_node_id));
        let (wing, room) = names.get(&drawer.parent_node_id).cloned().unwrap_or_default();
        let memory_id = Uuid::parse_str(&drawer.id)
            .map_err(|_| failure("invalid_estate_row", "The estate returned an invalid memory identity."))?;
        Ok(V2Memory {
            memory_id,
            subject: drawer.subject.clone(),
            distilled: Some(crate::v2::render::compact_text(&drawer.content)),
            content: Some(drawer.content.clone()),
            placement: Some(V2Placement { wing, room }),
            filed_at: Some(crate::result_composer::iso8601_flex(drawer.filed_at)),
            event_time: Some(crate::result_composer::iso8601_flex(drawer.event_time)),
            state: Some(format!("{:?}", drawer.state()).to_lowercase()),
            trust: Some(format!("{:?}", drawer.trust()).to_lowercase()),
            sensitivity: Some(format!("{:?}", drawer.adjective_sensitivity()).to_lowercase()),
            exportability: Some(format!("{:?}", drawer.exportability()).to_lowercase()),
            confirmation: Some(format!("{:?}", drawer.confirmation()).to_lowercase()),
            lineage_id: Some(drawer.lineage_id.to_string()),
            fetch: placeholder_fetch(memory_id),
        })
    }
}

use crate::surfaced_recall_ledger::SurfacedRecallLedger;

impl V2CoreMemoryService for EstateV2MemoryService<'_> {
    /// Both storage spellings are tried: `mark_recall_used` matches trace rows
    /// by the stored drawer id, and the two portable estate writers disagree on
    /// UUID case, so a canonical-only lookup silently matches nothing on an
    /// estate written by the other port. `note_usage` carries the rest of the
    /// contract — frozen postures take no persistent write, an id the caller
    /// already knew earns no reward, and the retention window is derived from
    /// the ledger's own surfaced_at rather than this dispatch's instant.
    fn mark_dereferenced(
        &self,
        context: &V2MemoryOperationContext,
        memory_ids: &[uuid::Uuid],
        ledger: &SurfacedRecallLedger,
    ) {
        let Ok(estate) = self.estate(context) else { return };
        for memory_id in memory_ids {
            let canonical = memory_id.hyphenated().to_string();
            for spelling in [canonical.clone(), canonical.to_uppercase()] {
                crate::interface_tools::note_usage(&spelling, estate, ledger, self.posture);
            }
        }
    }

    fn file_memory(&self, context: &V2MemoryOperationContext, request: &V2FileMemoryRequest) -> Result<V2FiledMemory, V2MemoryFailure> {
        let estate = self.estate(context)?;
        let mut frame = CaptureFrame::new(
            request.content.clone(),
            CaptureChannel::Actuator,
            request.location.clone(),
            LatticeAnchor::udc("000"),
            self.registry.server_identity.clone(),
            "default",
        );
        frame.subject = Some(request.subject.clone());
        frame.wing = Some(request.wing.clone().unwrap_or_else(|| DEFAULT_WING_NAME.to_owned()));
        frame.sensitivity = request.sensitivity.map(sensitivity).unwrap_or(AdjectiveSensitivity::Normal);
        frame.exportability = request.exportability.map(exportability).unwrap_or(AdjectiveExportability::Private);
        frame.kind = request.kind.map(content_kind).unwrap_or(ContentKind::Prose);
        frame.provenance_channel = Channel::McpAgent;
        if let Some(raw) = &request.event_time {
            frame.event_time = Some(parse_iso8601_ms(raw).ok_or_else(|| failure("invalid_argument", "event_time must be an ISO-8601 instant"))?);
        }
        let drawer = estate.coord.lock().map_err(|_| failure("estate_unavailable", "The estate coordinator is unavailable."))?
            .capture_with_mode(
                &estate.handle,
                frame,
                context.now_millis,
                if request.impatient { WriteMode::Impatient } else { WriteMode::Regular },
            )
            .map_err(|error| failure("operation_failed", &format!("memory filing failed: {error:?}")))?;
        let names = estate.coord.lock().map_err(|_| failure("estate_unavailable", "The estate coordinator is unavailable."))?
            .resolve_drawer_node_names(&estate.handle, std::slice::from_ref(&drawer.parent_node_id));
        let (wing, room) = names.get(&drawer.parent_node_id).cloned().unwrap_or_default();
        Ok(V2FiledMemory {
            memory_id: Uuid::parse_str(&drawer.id).map_err(|_| failure("invalid_estate_row", "The estate returned an invalid memory identity."))?,
            placement: V2Placement { wing, room },
        })
    }

    fn search_memories(&self, context: &V2MemoryOperationContext, request: &V2MemorySearchRequest) -> Result<V2MemorySearchResult, V2MemoryFailure> {
        let estate = self.estate(context)?;

        // Build the filter chain: sensitivity ceiling first (from context),
        // then the explicit filter arg, then wing and media_type appended.
        // Mirrors Swift runMemorySearch filter chain construction.
        let mut filters = context.sensitivity_ceiling
            .map(|v| vec![Filter::SensitivityAtMost(sensitivity(v))])
            .unwrap_or_default();

        // Map typed filter to LocusKit Filter. All values have been validated at
        // decode; no unknown-value errors are possible here. Mirrors Swift
        // ToolDispatch.decodeFilterChain and dispatch::decode_filter_chain.
        if let Some(f) = request.filter {
            let filter = match f {
                V2SearchFilter::Unconfirmed   => Filter::Unconfirmed,
                V2SearchFilter::UserConfirmed => Filter::UserConfirmed,
                V2SearchFilter::Exportable    => Filter::Exportable,
                V2SearchFilter::Contained     => Filter::Contained,
                V2SearchFilter::Pinned        => Filter::HasFeatureFlag(DrawerFeatureFlags::IS_PINNED),
            };
            filters.push(filter);
        }

        // Optional `wing` argument: scopes recall to a single wing.
        // Empty string is accepted. Absent means all wings.
        if let Some(wing) = request.wing.as_deref() {
            filters.push(Filter::InWing(wing.to_string()));
        }

        // Map typed media_type to DrawerFeatureFlag. Values validated at decode.
        // Mirrors Swift runMemorySearch media_type decode.
        if let Some(mt) = request.media_type {
            let flag = match mt {
                V2SearchMediaType::Voice => DrawerFeatureFlags::HAS_VOICE,
                V2SearchMediaType::Image => DrawerFeatureFlags::HAS_IMAGE,
            };
            filters.push(Filter::HasFeatureFlag(flag));
        }

        let mut frame = RecallFrame::new(filters);
        frame.hydration_level = HydrationLevel::Full;
        frame.limit = Some(request.limit);

        // Map typed ordering to LocusKit Ordering. Values validated at decode.
        // "byRelevanceDesc" maps to ByCaptureTimeDesc: the scored unionBest path
        // already owns final relevance ordering. Mirrors Swift decodeOrdering.
        if let Some(ord) = request.ordering {
            frame.ordering = match ord {
                V2SearchOrdering::ByCaptureTimeDesc | V2SearchOrdering::ByRelevanceDesc => Ordering::ByCaptureTimeDesc,
                V2SearchOrdering::ByCaptureTimeAsc  => Ordering::ByCaptureTimeAsc,
                V2SearchOrdering::ByRoomAsc         => Ordering::ByRoomAsc,
            };
        }

        // Resolve the scoring via the front-door precedence chain:
        //   explicit door arg > explicit scoring arg > MatrixAware default.
        // All door and scoring values have been validated at decode.
        // `door:Guess` reads the provisioned DoorManifest because that requires
        // the estate handle and cannot run at decode time.
        let scoring: GLKRecallScoring = match request.door {
            Some(V2SearchDoor::Guess) => {
                estate.coord.lock()
                    .map_err(|_| failure("estate_unavailable", "The estate coordinator is unavailable."))?
                    .provisioned_door_config(&estate.handle)
                    .unwrap_or_default()
                    .scoring
            }
            Some(V2SearchDoor::Raw)            => GLKRecallScoring::Raw,
            Some(V2SearchDoor::Rrf)            => GLKRecallScoring::Rrf,
            Some(V2SearchDoor::MatrixAware)    => GLKRecallScoring::MatrixAware,
            Some(V2SearchDoor::Discriminative) => GLKRecallScoring::Discriminative,
            None => match request.scoring {
                Some(V2SearchScoring::Raw)            => GLKRecallScoring::Raw,
                Some(V2SearchScoring::Rrf)            => GLKRecallScoring::Rrf,
                Some(V2SearchScoring::MatrixAware)    => GLKRecallScoring::MatrixAware,
                Some(V2SearchScoring::Discriminative) => GLKRecallScoring::Discriminative,
                None => {
                    // Neither door nor scoring supplied: read per-corpus manifest,
                    // falls back to MatrixAware when no config is provisioned.
                    estate.coord.lock()
                        .map_err(|_| failure("estate_unavailable", "The estate coordinator is unavailable."))?
                        .provisioned_door_config(&estate.handle)
                        .unwrap_or_default()
                        .scoring
                }
            },
        };

        // PR-03: save the anchor UUID before resolving query text. The anchor must be
        // excluded from recall results after scoring (exclusion BEFORE packager so m1
        // top-margin and other gate signals are computed on non-anchor hits only).
        let anchor_id: Option<String> = match &request.target {
            V2SearchTarget::Near(id) => Some(id.to_string()),
            V2SearchTarget::Query(_) => None,
        };
        let query = match &request.target {
            V2SearchTarget::Query(query) => query.clone(),
            V2SearchTarget::Near(id) => {
                let anchor_frame = recall_frame(context, request.limit);
                // Both storage spellings: the two portable writers disagree on
                // UUID case, so a canonical-only lookup misses an estate
                // written by the other port.
                let canonical = id.hyphenated().to_string();
                let spellings = [canonical.clone(), canonical.to_uppercase()];
                let rows = estate.coord.lock().map_err(|_| failure("estate_unavailable", "The estate coordinator is unavailable."))?
                    .get_drawers_matching_frame(&estate.handle, &spellings, &anchor_frame)
                    .map_err(|error| failure("operation_failed", &format!("anchor lookup failed: {error:?}")))?;
                // The recall frame covers adjective sensitivity only.
                // Provenance sensitivity is a separate axis, and a
                // provenance-restricted row can pass the frame — so the same
                // predicate the search results and ordinary get already apply
                // is applied to the anchor BEFORE its content becomes the
                // query. Pivoting through a gated anchor would leak its
                // content-derived neighbours past the redaction boundary.
                //
                // An unauthorized anchor is reported exactly as an absent one:
                // the caller must not be able to tell which.
                rows.into_iter()
                    .find(|row| provenance_visible(row.provenance))
                    .map(|row| row.content)
                    .ok_or_else(V2MemoryFailure::not_found)?
            }
        };

        let mut recall = GLKRecallRequest::new(
            frame,
            GLKRecallMode::UnionBest,
            scoring,
            request.limit,
            RecallFallbackPolicy::AllowDegraded,
            if self.posture.is_frozen() { RecallOrigin::Internal } else { RecallOrigin::External },
        ).with_query_text(query).with_trace_limit(request.limit);
        recall.door = Some("memory_search".to_owned());

        // Optional `frontier_k`: per-call candidate-pool depth override.
        // The GLK engine clamps to [64, 256]; we do not clamp or reject here.
        // Absent means the engine default formula. Mirrors Swift frontier_k decode.
        if let Some(fk) = request.frontier_k {
            recall = recall.with_frontier_k(fk as usize);
        }

        let mut result = estate.coord.lock().map_err(|_| failure("estate_unavailable", "The estate coordinator is unavailable."))?
            .recall_scored(&estate.handle, recall, context.now_millis)
            .map_err(|error| failure("operation_failed", &format!("memory search failed: {error:?}")))?;

        // PR-03: exclude the anchor from results before packager gate computation so
        // m1 (top-margin) and other signals reflect non-anchor hits only. Every
        // consumer downstream (packager, compact rows, discrimination, count) works
        // from the filtered list. Mirrors Swift AriaV2GeniusLocusMemoryBackend.search()
        // anchor exclusion via storageIdentitySpellings and the v1 Rust retain call.
        if let Some(ref anchor) = anchor_id {
            result.hits.retain(|h| h.id != *anchor);
        }

        // PACKAGER: run the results packager for non-never modes. The Rust port has
        // no GroundedSynthesis (Swift-only seam), so composed_answer is always None.
        // The packager computes m1/m2/m3/m4 gate signals and the cliff cutoff; the
        // answer block carries an empty answer text (text divergence is the only
        // asymmetry between Swift and Rust on this path). answer:never fast path →
        // rows unchanged, no answer block. Mirrors the v1 Rust interface_tools packager call.
        let answer_mode = match request.answer {
            Some(V2AnswerMode::Always) => PackagerAnswerMode::Always,
            Some(V2AnswerMode::Auto)   => PackagerAnswerMode::Auto,
            _                          => PackagerAnswerMode::Never,
        };
        let tuning = estate.coord.lock()
            .map_err(|_| failure("estate_unavailable", "The estate coordinator is unavailable."))?
            .provisioned_recall_tuning(&estate.handle)
            .unwrap_or_default()
            .packager_thresholds();
        let packaged = GLKResultsPackager::new().package(&result, answer_mode, None, tuning);

        // Convert packager output rows to V2CompactMemory. For answer:never the rows
        // equal all hits; for non-never the packager may apply cliff cutoff.
        let rows: Vec<V2CompactMemory> = packaged.rows.iter().filter_map(|hit| {
            let drawer = hit.drawer.as_ref()?;
            if !provenance_visible(drawer.provenance) {
                return None;
            }
            let memory_id = Uuid::parse_str(&drawer.id).ok()?;
            let provenance = Some(format!("{:?}", drawer.source_type()).to_lowercase());
            Some(V2CompactMemory {
                memory_id,
                subject: drawer.subject.clone(),
                score: Some(hit.score.final_score as f64),
                provenance,
                context: None,
                excerpt: (!drawer.content.is_empty())
                    .then(|| crate::v2::render::compact_text(&drawer.content)),
                fetch: placeholder_fetch(memory_id),
            })
        }).collect();

        // Convert GLKAnswerBlock to V2SearchAnswerBlock for non-never modes.
        let answer_block = packaged.answer_block.map(|block| {
            let confidence = match block.confidence_level {
                genius_locus_kit::PackagerConfidenceLevel::Confident   => "confident",
                genius_locus_kit::PackagerConfidenceLevel::Intermediate => "intermediate",
                genius_locus_kit::PackagerConfidenceLevel::Weak        => "weak",
            }.to_owned();
            V2SearchAnswerBlock {
                text: block.answer,
                confidence,
                citation_ids: block.citation_ids,
                signals_m1: block.signals.m1,
                signals_m2: block.signals.m2,
                signals_m3: block.signals.m3,
                signals_m4: block.signals.m4,
            }
        });

        // Propagate degradation signal so execute_memory_search can emit the
        // "retrieval: degraded" control line, matching Swift AriaV2GeniusLocusMemoryBackend
        // which sets `degraded: !result.degradedStages.isEmpty` in the returned
        // AriaV2SearchResult. The rrf door on unionBest always records at least one
        // stage; matrixAware runs clean.
        // The span rerank stage's registration, so discrimination can cap a
        // high verdict on a lexical-only ranking. Read through the coordinator
        // because only it knows which stages are mounted.
        let span_rerank_registered = estate
            .coord
            .lock()
            .map(|coord| coord.is_span_rerank_registered(&estate.handle))
            .unwrap_or(true);
        Ok(V2MemorySearchResult {
            rows,
            answer_block,
            degraded: !result.degraded_stages.is_empty(),
            span_rerank_registered,
        })
    }

    fn get_memories(&self, context: &V2MemoryOperationContext, request: &V2MemoryGetRequest) -> Result<Vec<V2Memory>, V2MemoryFailure> {
        let estate = self.estate(context)?;
        // UUID references are canonical lowercase at the v2 boundary, while
        // Swift's persisted SQLite estates may retain uppercase drawer IDs.
        // Probe those two exact storage spellings only; do not widen this
        // dereference into a listing or case-insensitive scan.
        let ids = storage_identity_spellings(&request.memory_ids);
        let rows = estate.coord.lock().map_err(|_| failure("estate_unavailable", "The estate coordinator is unavailable."))?
            .get_drawers_matching_frame(&estate.handle, &ids, &recall_frame(context, ids.len()))
            .map_err(|error| failure("operation_failed", &format!("memory fetch failed: {error:?}")))?;
        let mut requested = BTreeSet::new();
        let mut requested_order = Vec::new();
        for memory_id in &request.memory_ids {
            if requested.insert(*memory_id) {
                requested_order.push(*memory_id);
            }
        }
        let mut selected = BTreeMap::<Uuid, &Drawer>::new();
        let mut ambiguous = BTreeSet::<Uuid>::new();
        for drawer in &rows {
            if !provenance_visible(drawer.provenance) {
                continue;
            }
            let memory_id = Uuid::parse_str(&drawer.id)
                .map_err(|_| failure("invalid_estate_row", "The estate returned an invalid memory identity."))?;
            if !requested.contains(&memory_id) {
                continue;
            }
            if let Some(existing) = selected.get(&memory_id) {
                if existing.id != drawer.id {
                    ambiguous.insert(memory_id);
                }
            } else {
                selected.insert(memory_id, drawer);
            }
        }
        requested_order.iter().filter_map(|memory_id| {
            (!ambiguous.contains(memory_id)).then(|| selected.get(memory_id))
                .flatten().map(|drawer| self.record(estate, drawer))
        }).collect()
    }
}

fn storage_identity_spellings(memory_ids: &[Uuid]) -> Vec<String> {
    let mut spellings = BTreeSet::new();
    for id in memory_ids {
        let canonical = id.to_string();
        spellings.insert(canonical.clone());
        spellings.insert(canonical.to_uppercase());
    }
    spellings.into_iter().collect()
}

fn provenance_visible(provenance: i64) -> bool {
    matches!((provenance >> 30) & 0x3f, 0 | 16)
}

#[cfg(test)]
mod tests {
    use super::{provenance_visible, EstateV2MemoryService};
    use crate::{estate_posture::EstatePosture, estate_registry::EstateRegistry};
    use crate::sensitivity_grant_ledger::SensitivityGrantLedger;
    use crate::surfaced_recall_ledger::SurfacedRecallLedger;
    use crate::v2::core_memory::{execute_memory_get, V2CoreMemoryDependencies, V2CoreMemoryOperation, V2CoreMemoryService, V2FileMemoryRequest, V2MemoryAuthorization, V2MemoryClock, V2MemoryDepth, V2MemoryFailure, V2MemoryGetRequest, V2MemoryOperationContext};
    use crate::v2::operation::V2OperationEffect;
    use crate::v2::render::V2ResultMeta;
    use locus_kit::drawer_store::DrawerStore;
    use uuid::Uuid;

    struct Allow;
    impl V2MemoryAuthorization for Allow {
        fn authorize(&self, _: V2CoreMemoryOperation, _: &V2MemoryOperationContext) -> Result<(), V2MemoryFailure> {
            Ok(())
        }
    }

    struct FixedClock;
    impl V2MemoryClock for FixedClock {
        fn now_millis(&self) -> i64 { 1_700_000_000_000 }
    }

    #[test]
    fn selected_memory_projection_rejects_sensitive_and_unknown_raw_provenance() {
        for raw in [0, 16] {
            assert!(provenance_visible(raw << 30), "raw sensitivity {raw} must remain visible");
        }
        for raw in [32, 48, 63] {
            assert!(!provenance_visible(raw << 30), "raw sensitivity {raw} must be refused");
        }
    }

    #[test]
    fn canonical_reference_reads_swift_uppercase_storage_only_when_provenance_is_visible() {
        let directory = std::env::temp_dir().join(format!("aria-v2-swift-uuid-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&directory).expect("create private SQLite test directory");
        let path = directory.join("estate.sqlite");
        let registry = EstateRegistry::new_sqlite(path.to_str().expect("UTF-8 path"), "test-owner")
            .expect("open SQLite estate");
        let service = EstateV2MemoryService::new(&registry, EstatePosture::Frozen);
        let context = V2MemoryOperationContext {
            estate_id: None,
            caller_identity: "test".to_owned(),
            now_millis: 1_700_000_000_000,
            sensitivity_ceiling: None,
        };
        // Capture once to obtain a real room parent, then inject the exact
        // Swift storage distinction: the persisted drawer id is uppercase
        // while v2's fetch reference is the UUID crate's lowercase canonical
        // spelling. This stays a bounded by-id lookup, never a scan.
        let seed = service.file_memory(&context, &V2FileMemoryRequest {
            estate_id: None,
            content: "seed parent".to_owned(),
            subject: "seed".to_owned(),
            location: "Lab".to_owned(),
            wing: Some("Lab".to_owned()),
            sensitivity: None,
            exportability: None,
            kind: None,
            event_time: None,
            impatient: false,
        }).expect("seed capture");
        let seed_drawer = registry.default.store.get_drawer(&seed.memory_id.to_string())
            .expect("read seed").expect("seed exists");

        // Raw 63 is reserved and rejected by the storage capture gate; its
        // fail-closed projection is covered above without manufacturing an
        // impossible persisted row. These are the legal persisted raw values
        // needed to exercise the service path.
        for (raw, expected_visible) in [(0_i64, true), (16, true), (32, false), (48, false)] {
            let memory_id = Uuid::new_v4();
            let mut swift_drawer = seed_drawer.clone();
            swift_drawer.id = memory_id.to_string().to_uppercase();
            swift_drawer.lineage_id = Uuid::new_v4();
            swift_drawer.content = format!("Swift uppercase persisted raw-{raw}");
            swift_drawer.provenance = raw << 30;
            registry.default.store.add_drawer(&swift_drawer, context.now_millis)
                .expect("insert Swift-shaped drawer");

            let rows = service.get_memories(&context, &V2MemoryGetRequest {
                estate_id: None,
                memory_ids: vec![memory_id],
                depth: V2MemoryDepth::Full,
            }).expect("bounded v2 fetch");
            assert_eq!(rows.len(), if expected_visible { 1 } else { 0 }, "raw provenance {raw}");
            if expected_visible {
                assert_eq!(rows[0].memory_id, memory_id);
            }
        }

        let numeric_id = Uuid::parse_str("00000000-0000-4000-8000-000000000001").expect("numeric UUID");
        let mut numeric_drawer = seed_drawer.clone();
        numeric_drawer.id = numeric_id.to_string().to_uppercase();
        numeric_drawer.lineage_id = Uuid::new_v4();
        numeric_drawer.content = "Swift numeric-only persisted UUID".to_owned();
        numeric_drawer.provenance = 0;
        registry.default.store.add_drawer(&numeric_drawer, context.now_millis)
            .expect("insert numeric Swift-shaped drawer");

        let collision_id = Uuid::parse_str("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").expect("case-collision UUID");
        for spelling in [collision_id.to_string(), collision_id.to_string().to_uppercase()] {
            let mut collision_drawer = seed_drawer.clone();
            collision_drawer.id = spelling;
            collision_drawer.lineage_id = Uuid::new_v4();
            collision_drawer.content = format!("case-collision {}", Uuid::new_v4());
            collision_drawer.provenance = 0;
            registry.default.store.add_drawer(&collision_drawer, context.now_millis)
                .expect("insert case-collision drawer");
        }

        let authorization = Allow;
        let clock = FixedClock;
        let sensitivity_ledger = SensitivityGrantLedger::new();
        let surfaced_recall_ledger = SurfacedRecallLedger::new();
        let dependencies = V2CoreMemoryDependencies {
            service: &service,
            authorization: &authorization,
            clock: &clock,
            sensitivity_ledger: &sensitivity_ledger,
            surfaced_recall_ledger: &surfaced_recall_ledger,
            caller_identity: "test",
            meta: V2ResultMeta::incomplete("test", "digest", V2OperationEffect::Read),
        };
        let numeric = execute_memory_get(V2MemoryGetRequest {
            estate_id: None,
            memory_ids: vec![numeric_id],
            depth: V2MemoryDepth::Full,
        }, &dependencies).expect("public numeric UUID fetch");
        assert_eq!(numeric["structuredContent"]["data"]["memories"].as_array().expect("memories").len(), 1);
        let canonical_numeric = numeric_id.to_string();
        assert_eq!(numeric["structuredContent"]["data"]["memories"][0]["memory_id"].as_str(), Some(canonical_numeric.as_str()));

        let collision = execute_memory_get(V2MemoryGetRequest {
            estate_id: None,
            memory_ids: vec![collision_id],
            depth: V2MemoryDepth::Full,
        }, &dependencies).expect("public collision fetch");
        assert_eq!(collision["structuredContent"]["error"]["code"], "memory_not_found");
        drop(service);
        drop(registry);
        std::fs::remove_dir_all(directory).expect("remove private SQLite test directory");
    }
}

fn recall_frame(context: &V2MemoryOperationContext, limit: usize) -> RecallFrame {
    let filters = context.sensitivity_ceiling.map(|value| vec![Filter::SensitivityAtMost(sensitivity(value))]).unwrap_or_default();
    let mut frame = RecallFrame::new(filters);
    frame.hydration_level = HydrationLevel::Full;
    frame.limit = Some(limit);
    frame
}

fn sensitivity(value: V2Sensitivity) -> AdjectiveSensitivity { match value { V2Sensitivity::Normal => AdjectiveSensitivity::Normal, V2Sensitivity::Elevated => AdjectiveSensitivity::Elevated, V2Sensitivity::Restricted => AdjectiveSensitivity::Restricted, V2Sensitivity::Secret => AdjectiveSensitivity::Secret } }
fn exportability(value: V2Exportability) -> AdjectiveExportability { match value { V2Exportability::Private => AdjectiveExportability::Private, V2Exportability::Public => AdjectiveExportability::Public } }
fn content_kind(value: V2ContentKind) -> ContentKind { match value { V2ContentKind::Prose => ContentKind::Prose, V2ContentKind::Code => ContentKind::Code, V2ContentKind::Transcript => ContentKind::Transcript, V2ContentKind::List => ContentKind::List, V2ContentKind::StructuredJson => ContentKind::StructuredJson, V2ContentKind::ImageCaption => ContentKind::ImageCaption, V2ContentKind::FingerprintOnly => ContentKind::FingerprintOnly } }
fn placeholder_fetch(memory_id: Uuid) -> V2FetchReference { V2FetchReference { tool: MEMORY_GET_TOOL, arguments: V2FetchArguments { memory_id: memory_id.to_string() } } }
fn failure(code: &str, message: &str) -> V2MemoryFailure { V2MemoryFailure { code: code.to_owned(), message: message.to_owned(), retryable: false, recovery: None } }

fn parse_iso8601_ms(value: &str) -> Option<i64> {
    // Reuse the wire parser already pinned by the request-path bench clock.
    crate::dispatch::bench_clock_parse_iso8601_ms(value)
}

