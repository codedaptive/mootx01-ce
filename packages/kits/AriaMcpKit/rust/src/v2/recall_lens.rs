//! Typed v2 recall and lens request foundation.
//!
//! The current Rust recipe and lens implementations are legacy runners whose
//! completed semantics are private to `recipe_tools` and `lens_tools` and
//! whose public products are rendered text/JSON.  This module intentionally
//! does not call them.  It preserves the frozen request grammar and the
//! selected-estate authority boundary so a later direct lower adapter can be
//! admitted without reintroducing a v1 parse/re-render seam.

use std::collections::BTreeMap;

use genius_locus_kit::EstateHandle;
use locus_kit::filter::{Filter, RecallFrame};
use serde::Serialize;
use serde_json::{json, Value};
use uuid::Uuid;

use super::codec::{
    optional_integer, optional_uuid, strict_object, V2DecodeResult, V2InvalidArgument,
};
use crate::jsonrpc::JsonValue;

pub const LIST_LENSES_TOOL: &str = "moot_list_lenses";
pub const LIST_RECIPES_TOOL: &str = "moot_list_recipes";
pub const RECALL_PRECISE_TOOL: &str = "moot_recall_precise";

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum V2RecallLensOperation {
    ListLenses,
    ListRecipes,
    RecallPrecise,
    RecallTemporal,
    RecallConnected,
    RecallShaped,
    RecallDistilled,
    RecallVague,
    RecallWalk,
    LensKeystones,
    LensConstellation,
    LensFreeAssociation,
    LensThemeWeather,
    LensLatentThemes,
    LensBias,
    LensDrift,
    LensNodeMotion,
    LensCohesion,
    LensContradiction,
    LensTrustSynthesis,
    LensPartialCue,
    LensAnticipate,
    LensSuccessors,
    LensOverlap,
    LensDivergence,
    LensAssociations,
    LensConcepts,
    LensApriori,
    LensMoment,
    LensRhythm,
    LensPrecedence,
    LensComplexity,
}

impl V2RecallLensOperation {
    pub const fn tool_name(self) -> &'static str {
        match self {
            Self::ListLenses => LIST_LENSES_TOOL,
            Self::ListRecipes => LIST_RECIPES_TOOL,
            Self::RecallPrecise => RECALL_PRECISE_TOOL,
            Self::RecallTemporal => "moot_recall_temporal",
            Self::RecallConnected => "moot_recall_connected",
            Self::RecallShaped => "moot_recall_shaped",
            Self::RecallDistilled => "moot_recall_distilled",
            Self::RecallVague => "moot_recall_vague",
            Self::RecallWalk => "moot_recall_walk",
            Self::LensKeystones => "moot_lens_keystones",
            Self::LensConstellation => "moot_lens_constellation",
            Self::LensFreeAssociation => "moot_lens_free_association",
            Self::LensThemeWeather => "moot_lens_theme_weather",
            Self::LensLatentThemes => "moot_lens_latent_themes",
            Self::LensBias => "moot_lens_bias",
            Self::LensDrift => "moot_lens_drift",
            Self::LensNodeMotion => "moot_lens_node_motion",
            Self::LensCohesion => "moot_lens_cohesion",
            Self::LensContradiction => "moot_lens_contradiction",
            Self::LensTrustSynthesis => "moot_lens_trust_synthesis",
            Self::LensPartialCue => "moot_lens_partial_cue",
            Self::LensAnticipate => "moot_lens_anticipate",
            Self::LensSuccessors => "moot_lens_successors",
            Self::LensOverlap => "moot_lens_overlap",
            Self::LensDivergence => "moot_lens_divergence",
            Self::LensAssociations => "moot_lens_associations",
            Self::LensConcepts => "moot_lens_concepts",
            Self::LensApriori => "moot_lens_apriori",
            Self::LensMoment => "moot_lens_moment",
            Self::LensRhythm => "moot_lens_rhythm",
            Self::LensPrecedence => "moot_lens_precedence",
            Self::LensComplexity => "moot_lens_complexity",
        }
    }

    pub const fn effect_is_read(self) -> bool {
        true
    }
}

/// The exact selected-estate proof consumed by a future direct adapter.
#[derive(Debug, Clone, PartialEq)]
pub struct V2RecallLensAdmission {
    pub estate_id: Uuid,
    pub estate_handle: EstateHandle,
    pub caller_binding: String,
    pub authorization_generation: String,
    /// The caller's already-authorized recall scope. Lower adapters retain
    /// this frame instead of reconstructing an unscoped estate recall.
    pub authorization_frame: RecallFrame,
    pub now_millis: i64,
}

pub trait V2RecallLensAuthority: Send + Sync {
    fn admit(
        &self,
        operation: V2RecallLensOperation,
        requested_estate_id: Option<Uuid>,
    ) -> Result<V2RecallLensAdmission, ()>;
    fn revalidate(&self, admission: &V2RecallLensAdmission) -> Result<(), ()>;
}

/// Every non-estate argument is decoded to its frozen schema type before a
/// lower adapter can see it.  Camel-case lens keys are deliberately retained.
#[derive(Debug, Clone, PartialEq)]
pub enum V2RecallLensValue {
    String(String),
    Integer(usize),
    Bool(bool),
    Uuid(Uuid),
    Array(Vec<JsonValue>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct V2RecallLensRequest {
    pub operation: V2RecallLensOperation,
    pub estate_id: Option<Uuid>,
    pub values: BTreeMap<String, V2RecallLensValue>,
}

impl V2RecallLensRequest {
    pub fn decode(operation: V2RecallLensOperation, value: &JsonValue) -> V2DecodeResult<Self> {
        let grammar = grammar(operation);
        let object = strict_object(value, grammar.allowed.iter().copied())?;
        for key in grammar.required {
            if !object.contains_key(*key) {
                return Err(V2InvalidArgument::new(format!("$.{key}"), "is required"));
            }
        }
        let estate_id = optional_uuid(object, "estate_id")?;
        let mut values = BTreeMap::new();
        for key in grammar.strings {
            if let Some(value) = object.get(*key) {
                let string = value.as_str().ok_or_else(|| {
                    V2InvalidArgument::new(format!("$.{key}"), "must be a string")
                })?;
                values.insert(
                    (*key).to_owned(),
                    V2RecallLensValue::String(string.to_owned()),
                );
            }
        }
        for key in grammar.positive_integers {
            if let Some(value) = optional_integer(object, key)? {
                let value = usize::try_from(value)
                    .ok()
                    .filter(|value| *value >= 1)
                    .ok_or_else(|| {
                        V2InvalidArgument::new(
                            format!("$.{key}"),
                            "must be an integer of at least 1",
                        )
                    })?;
                values.insert((*key).to_owned(), V2RecallLensValue::Integer(value));
            }
        }
        for key in grammar.uuids {
            if object.contains_key(*key) {
                values.insert(
                    (*key).to_owned(),
                    V2RecallLensValue::Uuid(super::codec::required_uuid(object, key)?),
                );
            }
        }
        for key in grammar.arrays {
            if let Some(value) = object.get(*key) {
                let array = value.as_array().ok_or_else(|| {
                    V2InvalidArgument::new(format!("$.{key}"), "must be an array")
                })?;
                values.insert((*key).to_owned(), V2RecallLensValue::Array(array.to_vec()));
            }
        }
        for key in grammar.bools {
            if let Some(value) = object.get(*key) {
                let value = match value {
                    JsonValue::Bool(value) => *value,
                    _ => {
                        return Err(V2InvalidArgument::new(
                            format!("$.{key}"),
                            "must be a boolean",
                        ))
                    }
                };
                values.insert((*key).to_owned(), V2RecallLensValue::Bool(value));
            }
        }
        // Validate mode enum value for moot_lens_partial_cue at decode time so
        // an unknown value produces an INVALID_PARAMS transport fault rather than
        // a generic operational refusal at execution time.
        if operation == V2RecallLensOperation::LensPartialCue {
            if let Some(V2RecallLensValue::String(mode)) = values.get("mode") {
                match mode.as_str() {
                    "feelsLike" | "aboutThis" | "fromThen" => {}
                    _ => return Err(V2InvalidArgument::new(
                        "$.mode",
                        "must be one of: feelsLike, aboutThis, fromThen",
                    )
                    .allowed(["feelsLike".to_owned(), "aboutThis".to_owned(), "fromThen".to_owned()])
                    .correction("Use \"feelsLike\", \"aboutThis\", or \"fromThen\".")),
                }
            }
        }
        Ok(Self {
            operation,
            estate_id,
            values,
        })
    }
}

struct Grammar {
    allowed: &'static [&'static str],
    required: &'static [&'static str],
    strings: &'static [&'static str],
    positive_integers: &'static [&'static str],
    uuids: &'static [&'static str],
    arrays: &'static [&'static str],
    bools: &'static [&'static str],
}

const LIST: Grammar = Grammar {
    allowed: &["verbose", "estate_id"],
    required: &[],
    strings: &[],
    positive_integers: &[],
    uuids: &[],
    arrays: &[],
    bools: &["verbose"],
};
const PRECISE: Grammar = Grammar {
    allowed: &[
        "query",
        "limit",
        "pool",
        "composition",
        "filter",
        "wing",
        "estate_id",
    ],
    required: &["query"],
    strings: &["query", "composition", "filter", "wing"],
    positive_integers: &["limit", "pool"],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const TEMPORAL: Grammar = Grammar {
    allowed: &[
        "query",
        "window",
        "from",
        "to",
        "limit",
        "pool",
        "grab",
        "filter",
        "wing",
        "estate_id",
    ],
    required: &["query"],
    strings: &["query", "window", "from", "to", "grab", "filter", "wing"],
    positive_integers: &["limit", "pool"],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const CONNECTED: Grammar = Grammar {
    allowed: &["query", "limit", "depth", "filter", "wing", "estate_id"],
    required: &["query"],
    strings: &["query", "filter", "wing"],
    positive_integers: &["limit", "depth"],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const SHAPED: Grammar = Grammar {
    // frontier_k: candidate-pool depth override added to match Swift AriaV2SelectedCatalog.
    // The shaped-recall engine clamps the value to [64, 256]; absent uses the default formula.
    allowed: &["query", "preset", "limit", "filter", "wing", "frontier_k", "estate_id"],
    required: &["query"],
    strings: &["query", "preset", "filter", "wing"],
    positive_integers: &["limit", "frontier_k"],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const RECALL: Grammar = Grammar {
    allowed: &["query", "limit", "filter", "wing", "estate_id"],
    required: &["query"],
    strings: &["query", "filter", "wing"],
    positive_integers: &["limit"],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const KEYSTONES: Grammar = Grammar {
    allowed: &["wing", "topK", "keystoneOnly", "estate_id"],
    required: &["wing"],
    strings: &["wing", "topK", "keystoneOnly"],
    positive_integers: &[],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const WING: Grammar = Grammar {
    allowed: &["wing", "estate_id"],
    required: &["wing"],
    strings: &["wing"],
    positive_integers: &[],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const ASSOCIATION: Grammar = Grammar {
    allowed: &["wing", "seed_memory_id", "walkLength", "k", "estate_id"],
    required: &["wing", "seed_memory_id"],
    strings: &["wing", "walkLength", "k"],
    positive_integers: &[],
    uuids: &["seed_memory_id"],
    arrays: &[],
    bools: &[],
};
const ESTATE: Grammar = Grammar {
    allowed: &["estate_id"],
    required: &[],
    strings: &[],
    positive_integers: &[],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const BIAS: Grammar = Grammar {
    allowed: &["reference", "estate_id"],
    required: &[],
    strings: &[],
    positive_integers: &[],
    uuids: &[],
    arrays: &["reference"],
    bools: &[],
};
const DRIFT: Grammar = Grammar {
    allowed: &["splitAt", "estate_id"],
    required: &["splitAt"],
    strings: &["splitAt"],
    positive_integers: &[],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const MEMORY: Grammar = Grammar {
    allowed: &["memory_id", "estate_id"],
    required: &["memory_id"],
    strings: &[],
    positive_integers: &[],
    uuids: &["memory_id"],
    arrays: &[],
    bools: &[],
};
const DATASET: Grammar = Grammar {
    allowed: &["dataset_id", "estate_id"],
    required: &[],
    strings: &[],
    positive_integers: &[],
    uuids: &["dataset_id"],
    arrays: &[],
    bools: &[],
};
const LIMIT: Grammar = Grammar {
    allowed: &["limit", "estate_id"],
    required: &[],
    strings: &[],
    positive_integers: &["limit"],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const ANCHOR: Grammar = Grammar {
    allowed: &["anchor_memory_id", "limit", "estate_id", "mode"],
    required: &["anchor_memory_id"],
    strings: &["mode"],
    positive_integers: &["limit"],
    uuids: &["anchor_memory_id"],
    arrays: &[],
    bools: &[],
};
const ANTICIPATE: Grammar = Grammar {
    allowed: &["targetKind", "limit", "estate_id"],
    required: &["targetKind"],
    strings: &["targetKind"],
    positive_integers: &["limit"],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const SUCCESSORS: Grammar = Grammar {
    allowed: &["wing", "anchor_memory_id", "limit", "estate_id"],
    required: &["wing", "anchor_memory_id"],
    strings: &["wing"],
    positive_integers: &["limit"],
    uuids: &["anchor_memory_id"],
    arrays: &[],
    bools: &[],
};
const COMPARISON: Grammar = Grammar {
    allowed: &["comparison_estate_id", "estate_id"],
    required: &["comparison_estate_id"],
    strings: &[],
    positive_integers: &[],
    uuids: &["comparison_estate_id"],
    arrays: &[],
    bools: &[],
};
const ASSOCIATIONS: Grammar = Grammar {
    allowed: &["dataset_id", "limit", "estate_id"],
    required: &[],
    strings: &[],
    positive_integers: &["limit"],
    uuids: &["dataset_id"],
    arrays: &[],
    bools: &[],
};
const CONCEPTS: Grammar = Grammar {
    allowed: &["recall_limit", "limit", "estate_id"],
    required: &[],
    strings: &[],
    positive_integers: &["recall_limit", "limit"],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const MOMENT: Grammar = Grammar {
    allowed: &[
        "windowStart",
        "windowEnd",
        "comparison_windows",
        "estate_id",
    ],
    required: &["windowStart", "windowEnd"],
    strings: &["windowStart", "windowEnd", "comparison_windows"],
    positive_integers: &[],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const RHYTHM: Grammar = Grammar {
    allowed: &[
        "bit",
        "bucketSeconds",
        "bucketCount",
        "endingAt",
        "estate_id",
    ],
    required: &["bit", "bucketSeconds", "bucketCount", "endingAt"],
    strings: &["bit", "bucketSeconds", "bucketCount", "endingAt"],
    positive_integers: &[],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const PRECEDENCE: Grammar = Grammar {
    allowed: &[
        "windowStart",
        "windowEnd",
        "targetField",
        "targetValue",
        "estate_id",
    ],
    required: &["windowStart", "windowEnd", "targetField", "targetValue"],
    strings: &["windowStart", "windowEnd", "targetField", "targetValue"],
    positive_integers: &[],
    uuids: &[],
    arrays: &[],
    bools: &[],
};
const COMPLEXITY: Grammar = Grammar {
    allowed: &["fieldA", "fieldB", "dataset_id", "estate_id"],
    required: &["fieldA"],
    strings: &["fieldA", "fieldB"],
    positive_integers: &[],
    uuids: &["dataset_id"],
    arrays: &[],
    bools: &[],
};

fn grammar(operation: V2RecallLensOperation) -> &'static Grammar {
    match operation {
        V2RecallLensOperation::ListLenses | V2RecallLensOperation::ListRecipes => &LIST,
        V2RecallLensOperation::RecallPrecise => &PRECISE,
        V2RecallLensOperation::RecallTemporal => &TEMPORAL,
        V2RecallLensOperation::RecallConnected => &CONNECTED,
        V2RecallLensOperation::RecallShaped => &SHAPED,
        V2RecallLensOperation::RecallDistilled
        | V2RecallLensOperation::RecallVague
        | V2RecallLensOperation::RecallWalk => &RECALL,
        V2RecallLensOperation::LensKeystones => &KEYSTONES,
        V2RecallLensOperation::LensConstellation => &WING,
        V2RecallLensOperation::LensFreeAssociation => &ASSOCIATION,
        V2RecallLensOperation::LensThemeWeather
        | V2RecallLensOperation::LensLatentThemes
        | V2RecallLensOperation::LensContradiction => &ESTATE,
        V2RecallLensOperation::LensBias => &BIAS,
        V2RecallLensOperation::LensDrift => &DRIFT,
        V2RecallLensOperation::LensNodeMotion => &MEMORY,
        V2RecallLensOperation::LensCohesion => &DATASET,
        V2RecallLensOperation::LensTrustSynthesis | V2RecallLensOperation::LensApriori => &LIMIT,
        V2RecallLensOperation::LensPartialCue => &ANCHOR,
        V2RecallLensOperation::LensAnticipate => &ANTICIPATE,
        V2RecallLensOperation::LensSuccessors => &SUCCESSORS,
        V2RecallLensOperation::LensOverlap | V2RecallLensOperation::LensDivergence => &COMPARISON,
        V2RecallLensOperation::LensAssociations => &ASSOCIATIONS,
        V2RecallLensOperation::LensConcepts => &CONCEPTS,
        V2RecallLensOperation::LensMoment => &MOMENT,
        V2RecallLensOperation::LensRhythm => &RHYTHM,
        V2RecallLensOperation::LensPrecedence => &PRECEDENCE,
        V2RecallLensOperation::LensComplexity => &COMPLEXITY,
    }
}

/// Deliberately compact typed output envelope.  The lower adapter must return
/// operation-owned rows; it cannot submit a v1 rendered blob for reparsing.
#[derive(Debug, Clone, PartialEq)]
pub struct V2RecallLensResult {
    pub operation: V2RecallLensOperation,
    pub rows: Vec<BTreeMap<String, JsonValue>>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2RecallLensError {
    Unavailable,
    OutcomeUnverified(V2RecallLensOperation),
    /// An argument value was rejected after decode. Carries enough diagnostic
    /// context to produce an INVALID_PARAMS JSON-RPC error with the same
    /// information the decode path raises. Fields are owned strings so that
    /// the error can be propagated across the trait boundary without a lifetime.
    InvalidArgument { path: String, message: String },
}

pub trait V2RecallLensLower: Send + Sync {
    fn execute(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, V2RecallLensError>;
}

/// The operation-specific v2 projection for the first extracted lower recipe.
/// Each row comes from the typed drawer and match values, never a rendered v1
/// response.  `results` deliberately uses the S1 row vocabulary documented by
/// the frozen recall output schema.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct V2PreciseRecallData {
    pub results: Vec<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum V2PreciseRecallFailure {
    Invalid(V2InvalidArgument),
    Unavailable,
}

/// Execute the typed core used by the v1 precise renderer and project its
/// direct lower-kit output for v2.  This is intentionally narrow: `pool` is
/// a frozen string selector, but the existing Rust core accepts a numeric
/// pool; accepting and silently reinterpreting that selector would not be
/// source-faithful, so it remains unavailable until a typed selector exists.
pub fn execute_precise_recall(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &EstateHandle,
    request: &V2RecallLensRequest,
    now_millis: i64,
) -> Result<V2PreciseRecallData, V2PreciseRecallFailure> {
    if request.operation != V2RecallLensOperation::RecallPrecise {
        return Err(V2PreciseRecallFailure::Unavailable);
    }
    let query = request_string(request, "query")?;
    let limit = request_positive_integer(request, "limit").unwrap_or(20);
    let pool = request_positive_integer(request, "pool")
        .unwrap_or(cognition_kit::PRECISE_DEFAULT_POOL)
        .min(500);
    let base_filter = precise_filter(request.optional_string("filter"))?;
    let filter = match request.optional_string("wing") {
        Some(wing) => Filter::All(vec![base_filter, Filter::InWing(wing.to_owned())]),
        None => base_filter,
    };
    let composition = request.optional_string("composition");
    let mut counted_frame = locus_kit::filter::RecallFrame::new(vec![filter.clone()]);
    counted_frame.hydration_level = locus_kit::filter::HydrationLevel::BitmapOnly;
    counted_frame.limit = Some(pool.max(limit));
    counted_frame.ordering = locus_kit::filter::Ordering::ByCaptureTimeDesc;
    super::report_withheld::recall(coordinator, handle, counted_frame, now_millis)
        .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    if let Some(composition) = composition {
        if !neuron_kit::composition_grid::is_known(composition) {
            return Err(V2PreciseRecallFailure::Invalid(
                V2InvalidArgument::new(
                    "$.composition",
                    "is not a known precise-recall composition",
                )
                .allowed(
                    neuron_kit::composition_grid::names()
                        .iter()
                        .map(|name| (*name).to_owned()),
                )
                .correction("use one of the documented composition names"),
            ));
        }
    }
    let all_drawers = coordinator
        .all_drawers(handle)
        .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    let parent_ids = all_drawers
        .iter()
        .map(|drawer| drawer.parent_node_id.clone())
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    let node_names = coordinator.resolve_drawer_node_names(handle, &parent_ids);
    let matches = crate::recipe_tools::execute_precise_recall_typed(
        coordinator,
        handle,
        query,
        filter,
        limit,
        pool,
        composition,
        now_millis,
        &node_names,
    )
    .map_err(|_| V2PreciseRecallFailure::Unavailable)?;

    // Match the existing source-family containment gate before projection.
    let contents = matches
        .iter()
        .map(|matched| matched.content.as_str())
        .collect::<Vec<_>>();
    if neuron_kit::has_distinctive_tokens(query)
        && !neuron_kit::containment_satisfied(query, &contents)
    {
        return Ok(V2PreciseRecallData {
            results: Vec::new(),
            capabilities: None,
        });
    }

    let by_id = all_drawers
        .iter()
        .map(|drawer| (drawer.id.as_str(), drawer))
        .collect::<BTreeMap<_, _>>();
    let mut results = Vec::with_capacity(matches.len().min(50));
    for matched in matches.iter().take(50) {
        let drawer = by_id
            .get(matched.id.as_str())
            .ok_or(V2PreciseRecallFailure::Unavailable)?;
        let mut row = v2_candidate_from_drawer(drawer);
        row.score = Some(matched.score);
        row.room = Some(matched.room.clone());
        results.push(crate::result_composer::structured_row_object(&row));
    }
    let capabilities = match crate::recall_discrimination::classify(
        &matches
            .iter()
            .map(|matched| matched.score)
            .collect::<Vec<_>>(),
    ) {
        crate::recall_discrimination::DiscriminationLevel::Low => {
            Some(json!({"discrimination":"low"}))
        }
        crate::recall_discrimination::DiscriminationLevel::Medium => {
            Some(json!({"discrimination":"medium"}))
        }
        _ => None,
    };
    Ok(V2PreciseRecallData {
        results,
        capabilities,
    })
}

impl V2RecallLensRequest {
    fn optional_string(&self, key: &str) -> Option<&str> {
        match self.values.get(key) {
            Some(V2RecallLensValue::String(value)) => Some(value),
            _ => None,
        }
    }
}

fn request_string<'a>(
    request: &'a V2RecallLensRequest,
    key: &str,
) -> Result<&'a str, V2PreciseRecallFailure> {
    request.optional_string(key).ok_or_else(|| {
        V2PreciseRecallFailure::Invalid(V2InvalidArgument::new(format!("$.{key}"), "is required"))
    })
}

fn request_positive_integer(request: &V2RecallLensRequest, key: &str) -> Option<usize> {
    match request.values.get(key) {
        Some(V2RecallLensValue::Integer(value)) => Some(*value),
        _ => None,
    }
}

fn precise_filter(raw: Option<&str>) -> Result<Filter, V2PreciseRecallFailure> {
    match raw {
        None | Some("currentlyBelieve") => Ok(Filter::CurrentlyBelieve),
        Some("unconfirmed") => Ok(Filter::Unconfirmed),
        Some("userConfirmed") => Ok(Filter::UserConfirmed),
        Some("exportable") => Ok(Filter::Exportable),
        Some("contained") => Ok(Filter::Contained),
        Some(value) => Err(V2PreciseRecallFailure::Invalid(
            V2InvalidArgument::new("$.filter", "is not a supported recall filter")
                .allowed(
                    [
                        "currentlyBelieve",
                        "unconfirmed",
                        "userConfirmed",
                        "exportable",
                        "contained",
                    ]
                    .into_iter()
                    .map(str::to_owned),
                )
                .correction(format!("use a documented filter instead of '{value}'")),
        )),
    }
}

pub struct V2RecallLensService<A, L> {
    authority: A,
    lower: L,
}
impl<A, L> V2RecallLensService<A, L> {
    pub fn new(authority: A, lower: L) -> Self {
        Self { authority, lower }
    }
}
impl<A: V2RecallLensAuthority, L: V2RecallLensLower> V2RecallLensService<A, L> {
    pub fn execute(
        &self,
        request: V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, V2RecallLensError> {
        let operation = request.operation;
        let admission = self
            .authority
            .admit(operation, request.estate_id)
            .map_err(|_| V2RecallLensError::Unavailable)?;
        let result = self
            .lower
            .execute(&admission, &request)
            .map_err(|_| V2RecallLensError::Unavailable)?;
        if result.operation != operation {
            return Err(V2RecallLensError::Unavailable);
        }
        self.authority
            .revalidate(&admission)
            .map_err(|_| V2RecallLensError::OutcomeUnverified(operation))?;
        Ok(result)
    }
}

/// Shared compact projection used by the six direct recipe adapters. Each
/// result is built from typed drawer/match values, never from a v1 response.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct V2RecipeRecallData {
    pub results: Vec<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "capabilities")]
    pub metadata: Option<Value>,
}

fn recall_filter(request: &V2RecallLensRequest) -> Result<Filter, V2PreciseRecallFailure> {
    precise_filter(request.optional_string("filter"))
}

fn scoped_filter(request: &V2RecallLensRequest) -> Result<Filter, V2PreciseRecallFailure> {
    let filter = recall_filter(request)?;
    Ok(match request.optional_string("wing") {
        Some(wing) => Filter::All(vec![filter, Filter::InWing(wing.to_owned())]),
        None => filter,
    })
}

fn recipe_drawers(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &EstateHandle,
) -> Result<BTreeMap<String, locus_kit::drawer::Drawer>, V2PreciseRecallFailure> {
    coordinator
        .all_drawers(handle)
        .map_err(|_| V2PreciseRecallFailure::Unavailable)
        .map(|drawers| {
            drawers
                .into_iter()
                .map(|drawer| (drawer.id.clone(), drawer))
                .collect()
        })
}

fn recipe_nodes(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &EstateHandle,
    drawers: &BTreeMap<String, locus_kit::drawer::Drawer>,
) -> std::collections::HashMap<String, (String, String)> {
    let parents = drawers
        .values()
        .map(|drawer| drawer.parent_node_id.clone())
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    coordinator.resolve_drawer_node_names(handle, &parents)
}

fn recipe_row(
    drawer: &locus_kit::drawer::Drawer,
    room: Option<String>,
    score: Option<f64>,
    retrieval_source: Option<String>,
) -> Value {
    let mut row = v2_candidate_from_drawer(drawer);
    row.room = room;
    row.score = score;
    row.retrieval_source = retrieval_source;
    crate::result_composer::structured_row_object(&row)
}

/// V2 projections fail closed on raw provenance sensitivity. The shared v1
/// composer intentionally treats an unknown packed raw as normal for legacy
/// compatibility; do not use that tolerant accessor as a v2 disclosure gate.
pub fn v2_candidate_from_drawer(drawer: &locus_kit::drawer::Drawer) -> crate::result_composer::CandidateRowData {
    let mut row = crate::result_composer::candidate_from_drawer(drawer);
    match v2_raw_provenance_sensitivity(drawer) {
        0 | 16 => row,
        32 => {
            row.subject = Some(crate::result_composer::RESTRICTED_MARKER.to_owned());
            clear_v2_body_fields(&mut row);
            row
        }
        48 => {
            row.subject = Some(crate::result_composer::SECRET_MARKER.to_owned());
            clear_v2_body_fields(&mut row);
            row
        }
        _ => {
            row.subject = None;
            clear_v2_body_fields(&mut row);
            row
        }
    }
}

pub(crate) fn v2_raw_provenance_sensitivity(drawer: &locus_kit::drawer::Drawer) -> i64 {
    (drawer.provenance >> 30) & 0x3f
}

fn v2_may_attach_body_representation(drawer: &locus_kit::drawer::Drawer) -> bool {
    matches!(v2_raw_provenance_sensitivity(drawer), 0 | 16)
}

fn clear_v2_body_fields(row: &mut crate::result_composer::CandidateRowData) {
    row.best_span = None;
    row.ssc_facts = None;
    row.distilled = None;
    row.representation = None;
    row.content = None;
    row.extents = None;
    row.exemplars = None;
}

fn recipe_query<'a>(request: &'a V2RecallLensRequest) -> Result<&'a str, V2PreciseRecallFailure> {
    request_string(request, "query")
}

pub fn execute_temporal_recall(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &EstateHandle,
    request: &V2RecallLensRequest,
    now_millis: i64,
) -> Result<V2RecipeRecallData, V2PreciseRecallFailure> {
    if request.operation != V2RecallLensOperation::RecallTemporal {
        return Err(V2PreciseRecallFailure::Unavailable);
    }
    let drawers = recipe_drawers(coordinator, handle)?;
    let nodes = recipe_nodes(coordinator, handle, &drawers);
    let mode = cognition_kit::TemporalWindowMode::parse(request.optional_string("window"))
        .map_err(|message| {
            V2PreciseRecallFailure::Invalid(V2InvalidArgument::new("$.window", message))
        })?;
    let grab =
        cognition_kit::TemporalGrab::parse(request.optional_string("grab")).map_err(|message| {
            V2PreciseRecallFailure::Invalid(V2InvalidArgument::new("$.grab", message))
        })?;
    let output = crate::recipe_tools::execute_temporal_recall_typed(
        coordinator,
        handle,
        recipe_query(request)?,
        scoped_filter(request)?,
        request_positive_integer(request, "limit").unwrap_or(20),
        request_positive_integer(request, "pool")
            .unwrap_or(cognition_kit::TEMPORAL_DEFAULT_POOL)
            .min(500),
        mode,
        grab,
        request.optional_string("from"),
        request.optional_string("to"),
        now_millis,
        &nodes,
    )
    .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    let results = output
        .matches
        .iter()
        .filter_map(|matched| {
            drawers.get(&matched.id).map(|drawer| {
                let mut row = recipe_row(drawer, Some(matched.room.clone()), None, None);
                if let Some(event_time) = &matched.event_time {
                    row.as_object_mut()
                        .expect("fixed recall row")
                        .insert("eventTime".to_owned(), json!(event_time));
                }
                row
            })
        })
        .collect();
    let metadata = output.windows.first().map(|window| {
        let mut temporal = serde_json::Map::from_iter([
            ("mode".to_owned(), json!(output.mode.as_str())),
            ("source".to_owned(), json!(output.window_source)),
            ("grab".to_owned(), json!(output.grab.as_str())),
            ("from".to_owned(), json!(window.start)),
            ("to".to_owned(), json!(window.end)),
        ]);
        if output.applied_pad != 0 {
            temporal.insert("widenedDays".to_owned(), json!(output.applied_pad));
        }
        json!({"temporal": temporal})
    });
    Ok(V2RecipeRecallData { results, metadata })
}

pub fn execute_connected_recall(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &EstateHandle,
    request: &V2RecallLensRequest,
    now_millis: i64,
) -> Result<V2RecipeRecallData, V2PreciseRecallFailure> {
    if request.operation != V2RecallLensOperation::RecallConnected {
        return Err(V2PreciseRecallFailure::Unavailable);
    }
    let drawers = recipe_drawers(coordinator, handle)?;
    let mut counted_frame = locus_kit::filter::RecallFrame::new(vec![scoped_filter(request)?]);
    counted_frame.hydration_level = locus_kit::filter::HydrationLevel::Full;
    counted_frame.limit = Some(request_positive_integer(request, "limit").unwrap_or(20).max(20));
    super::report_withheld::recall(coordinator, handle, counted_frame, now_millis)
        .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    let matches = crate::recipe_tools::execute_connected_recall_typed(
        coordinator,
        handle,
        recipe_query(request)?,
        request.optional_string("wing").unwrap_or(""),
        scoped_filter(request)?,
        request_positive_integer(request, "limit").unwrap_or(20),
        now_millis,
    )
    .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    let results = matches
        .iter()
        .filter_map(|matched| {
            drawers.get(&matched.id).map(|drawer| {
                recipe_row(
                    drawer,
                    Some(matched.room.clone()),
                    None,
                    Some(matched.source.clone()),
                )
            })
        })
        .collect();
    Ok(V2RecipeRecallData {
        results,
        metadata: None,
    })
}

pub fn execute_shaped_recall(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &EstateHandle,
    request: &V2RecallLensRequest,
    now_millis: i64,
) -> Result<V2RecipeRecallData, V2PreciseRecallFailure> {
    if request.operation != V2RecallLensOperation::RecallShaped {
        return Err(V2PreciseRecallFailure::Unavailable);
    }
    let drawers = recipe_drawers(coordinator, handle)?;
    let mut counted_frame = locus_kit::filter::RecallFrame::new(vec![scoped_filter(request)?]);
    counted_frame.hydration_level = locus_kit::filter::HydrationLevel::Full;
    counted_frame.limit = Some(request_positive_integer(request, "limit").unwrap_or(20));
    counted_frame.ordering = locus_kit::filter::Ordering::ByCaptureTimeDesc;
    super::report_withheld::recall(coordinator, handle, counted_frame, now_millis)
        .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    let nodes = recipe_nodes(coordinator, handle, &drawers);
    let preset = request.optional_string("preset").unwrap_or("balanced");
    if !genius_locus_kit::recall::RecallShape::PRESET_NAMES.contains(&preset) {
        // Presets are a closed set, so the refusal carries it. Composition, the
        // sibling check in this file, already did; this one did not, leaving a
        // caller with a name to guess rather than a list to pick from.
        return Err(V2PreciseRecallFailure::Invalid(
            V2InvalidArgument::new("$.preset", "is not a known shaped-recall preset")
                .allowed(
                    genius_locus_kit::recall::RecallShape::PRESET_NAMES
                        .iter()
                        .map(|name| (*name).to_owned()),
                )
                .correction("use one of the documented preset names"),
        ));
    }
    // frontier_k: thread candidate-pool depth override through to the engine when supplied.
    // Absent means the engine default formula; the engine clamps to [64, 256] regardless.
    let frontier_k = request_positive_integer(request, "frontier_k");
    let output = crate::recipe_tools::execute_shaped_recall_typed(
        coordinator,
        handle,
        recipe_query(request)?,
        preset,
        scoped_filter(request)?,
        request_positive_integer(request, "limit").unwrap_or(20),
        now_millis,
        &nodes,
        frontier_k,
    )
    .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    let results = output
        .matches
        .iter()
        .filter_map(|matched| {
            drawers.get(&matched.id).map(|drawer| {
                recipe_row(
                    drawer,
                    Some(matched.room.clone()),
                    Some(matched.score),
                    None,
                )
            })
        })
        .collect();
    Ok(V2RecipeRecallData {
        results,
        metadata: None,
    })
}

pub fn execute_distilled_recall(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &EstateHandle,
    request: &V2RecallLensRequest,
    now_millis: i64,
) -> Result<V2RecipeRecallData, V2PreciseRecallFailure> {
    if request.operation != V2RecallLensOperation::RecallDistilled {
        return Err(V2PreciseRecallFailure::Unavailable);
    }
    let drawers = recipe_drawers(coordinator, handle)?;
    let mut input = cognition_kit::DistilledRecallInput::with_limit(
        recipe_query(request)?,
        request_positive_integer(request, "limit").unwrap_or(20),
    );
    input.filter = scoped_filter(request)?;
    let mut counted_frame = locus_kit::filter::RecallFrame::new(vec![input.filter.clone()]);
    counted_frame.hydration_level = locus_kit::filter::HydrationLevel::Full;
    counted_frame.limit = Some(request_positive_integer(request, "limit").unwrap_or(20));
    super::report_withheld::recall(coordinator, handle, counted_frame, now_millis)
        .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    let output = crate::recipe_tools::execute_distilled_recall_typed(
        &input,
        coordinator,
        handle,
        now_millis,
    )
    .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    // The savings figure covers only the rows this response emits with a
    // distilled body: a withheld body (restricted, secret or unknown
    // provenance) or a dropped row counts on neither side, so the published
    // numbers describe the payload as sent (ARIA_V2_CONTRACT.md, "Distilled
    // recall savings"). The recipe carries the per-match pair; the surface sums.
    let mut original_tokens: i64 = 0;
    let mut distilled_tokens: i64 = 0;
    let results = output
        .matches
        .iter()
        .filter_map(|matched| {
            drawers.get(&matched.id).map(|drawer| {
                let mut row = recipe_row(drawer, None, Some(matched.score), None);
                if v2_may_attach_body_representation(drawer) {
                    let object = row.as_object_mut().expect("fixed recall row");
                    object.insert("distilled".to_owned(), json!(matched.text));
                    object.insert("representation".to_owned(), json!("distilled"));
                    original_tokens += matched.original_token_count;
                    distilled_tokens += matched.token_count;
                }
                row
            })
        })
        .collect();
    // Skim is not applied on this surface today; the key stays absent.
    let savings = cognition_kit::measure_distilled_savings(original_tokens, distilled_tokens, None);
    let discrimination = format!("{:?}", output.discrimination).to_lowercase();
    let mut capabilities = serde_json::Map::new();
    if matches!(discrimination.as_str(), "low" | "medium") {
        capabilities.insert("discrimination".to_owned(), json!(discrimination));
    }
    capabilities.insert(
        "distillation".to_owned(),
        serde_json::to_value(&savings).expect("DistilledSavings serialises to plain JSON"),
    );
    Ok(V2RecipeRecallData { results, metadata: Some(Value::Object(capabilities)) })
}

pub fn execute_vague_recall(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &EstateHandle,
    request: &V2RecallLensRequest,
) -> Result<V2RecipeRecallData, V2PreciseRecallFailure> {
    if request.operation != V2RecallLensOperation::RecallVague {
        return Err(V2PreciseRecallFailure::Unavailable);
    }
    let limit = request_positive_integer(request, "limit")
        .unwrap_or(20)
        .min(50);
    let output = crate::recipe_tools::execute_vague_recall_typed(
        coordinator,
        handle,
        recipe_query(request)?,
        limit,
        limit,
        limit,
    )
    .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    super::report_withheld::record(output.withheld_by_sensitivity);
    let results = output
        .vague_hits
        .iter()
        .map(|drawer| {
            let mut row = recipe_row(drawer, None, None, None);
            row.as_object_mut()
                .expect("fixed recall row")
                .insert("tier".to_owned(), json!("summary"));
            row
        })
        .chain(output.constituents.iter().map(|drawer| {
            let mut row = recipe_row(drawer, None, None, None);
            row.as_object_mut()
                .expect("fixed recall row")
                .insert("tier".to_owned(), json!("original"));
            row
        }))
        .collect();
    Ok(V2RecipeRecallData {
        results,
        metadata: None,
    })
}

pub fn execute_walk_recall(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &EstateHandle,
    request: &V2RecallLensRequest,
    now_millis: i64,
) -> Result<V2RecipeRecallData, V2PreciseRecallFailure> {
    if request.operation != V2RecallLensOperation::RecallWalk {
        return Err(V2PreciseRecallFailure::Unavailable);
    }
    let drawers = recipe_drawers(coordinator, handle)?;
    let nodes = recipe_nodes(coordinator, handle, &drawers);
    let output = crate::recipe_tools::execute_walk_recall_typed(
        coordinator,
        handle,
        recipe_query(request)?,
        scoped_filter(request)?,
        request_positive_integer(request, "limit").unwrap_or(20),
        now_millis,
        &nodes,
    )
    .map_err(|_| V2PreciseRecallFailure::Unavailable)?;
    let results = output
        .matches
        .iter()
        .filter_map(|matched| {
            drawers.get(&matched.id).map(|drawer| {
                recipe_row(
                    drawer,
                    Some(matched.room.clone()),
                    Some(matched.score),
                    None,
                )
            })
        })
        .collect();
    let stage = match output.stage {
        cognition_kit::WalkStage::Stage1SessionHybrid => "stage1_session_hybrid",
        cognition_kit::WalkStage::Stage2PreciseHamming => "stage2_precise_hamming",
    };
    Ok(V2RecipeRecallData {
        results,
        metadata: Some(json!({"walk": {"stage": stage, "stoppedEarly": output.stopped_early}})),
    })
}
