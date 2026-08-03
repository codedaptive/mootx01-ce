//! The `sensitivity_advisory:` line on `moot_memory_search` and
//! `moot_memory_get` — proof that its presence depends on GRANT STATE ALONE.
//!
//! The advisory once carried a second condition: an estate-contents probe that
//! issued an explicit exact `Filter::Sensitivity(Restricted)` /
//! `Filter::Sensitivity(Secret)` recall. Per `BitmapEvaluator::insert_defaults`,
//! an explicit sensitivity filter SUPPRESSES the default
//! `SensitivityAtMost(Elevated)` ceiling, so that probe saw straight through the
//! gate it was reporting on. Advisory presence then told any ungranted caller
//! whether the estate held restricted or secret rows — an estate-wide existence
//! oracle reachable from ordinary read tools.
//!
//! The regression test is `*_indistinguishable_between_estates_*`: two estates
//! that differ ONLY in whether a restricted row exists must produce identical
//! advisory behaviour for a caller holding no grant. Against the pre-fix code
//! that assertion fails, because the clean estate emitted no advisory at all.
//!
//! NOTHING here asserts that the advisory correlates with sensitive-row
//! existence. Such a test would re-pin the oracle.
//!
//! Swift peer: `Tests/AriaMCPTests/SensitivityAdvisoryTests.swift`.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::{dispatch_tool, wall_now},
    estate_registry::EstateRegistry,
    interface_tools,
    jsonrpc::JsonValue,
    sensitivity_grant_ledger::SensitivityGrantLedger,
    surfaced_recall_ledger::SurfacedRecallLedger,
};

/// The exact search-tool advisory. Byte-identical to the Swift port's literal
/// in `SensitivityAdvisoryTests.searchAdvisory`; pinning it in both ports is
/// what keeps the two wordings from drifting apart.
const SEARCH_ADVISORY: &str = "sensitivity_advisory: a sensitivity tier gate is in effect — \
     run `mootx01 unlock private` to include restricted memories, \
     `mootx01 unlock secret` for secret memories.";

/// The exact get-tool advisory. Search and get keep distinct phrasings.
const GET_ADVISORY: &str = "sensitivity_advisory: a sensitivity tier gate is in effect on this estate — \
     run `mootx01 unlock private` to include restricted memories, \
     `mootx01 unlock secret` for secret memories.";

macro_rules! args {
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

/// Every advisory line in a reply, in order. Comparing THIS between two replies
/// is the indistinguishability check — comparing whole bodies would fail on
/// unrelated differences (row ids, hit counts).
fn advisories(body: &str) -> Vec<&str> {
    body.lines()
        .filter(|l| l.starts_with("sensitivity_advisory: "))
        .collect()
}

fn seed(registry: &EstateRegistry, content: &str, sensitivity: &str) -> String {
    let subject: String = content.chars().take(120).collect();
    let a = args![
        "content" => content,
        "subject" => subject.as_str(),
        "location" => "advisory-tests",
        "sensitivity" => sensitivity
    ];
    let result = dispatch_tool("moot_file_memory", &a, registry, &SurfacedRecallLedger::new())
        .expect("file_memory must succeed");
    content_text(&result)
        .lines()
        .next()
        .and_then(|l| l.strip_prefix("filed memory "))
        .expect("file_memory reply must lead with the filed id")
        .to_owned()
}

/// A pair of estates identical in every respect the advisory could legitimately
/// depend on, differing ONLY in whether a restricted row and a secret row
/// exist. Both carry the same visible row, so both can be searched and fetched
/// the same way. `new_inmemory_bare` is used so neither estate carries the
/// default wing-hint drawers.
struct EstatePair {
    clean: EstateRegistry,
    sensitive: EstateRegistry,
    clean_visible_id: String,
    sensitive_visible_id: String,
}

fn make_estate_pair() -> EstatePair {
    let clean = EstateRegistry::new_inmemory_bare();
    let sensitive = EstateRegistry::new_inmemory_bare();

    // The one row both estates share — ordinary, admitted by the default gate.
    let clean_visible_id = seed(&clean, "advisory-marker ordinary visible content", "normal");
    let sensitive_visible_id =
        seed(&sensitive, "advisory-marker ordinary visible content", "normal");

    // The ONLY difference between the two estates.
    seed(&sensitive, "advisory-marker classified briefing", "restricted");
    seed(&sensitive, "advisory-marker top secret payload", "secret");

    EstatePair { clean, sensitive, clean_visible_id, sensitive_visible_id }
}

fn search(registry: &EstateRegistry, ledger: &SensitivityGrantLedger) -> String {
    let result = interface_tools::dispatch(
        "moot_memory_search",
        &args!["query" => "advisory-marker"],
        registry,
        &SurfacedRecallLedger::new(),
        ledger,
        "",
        "",
        None,
        None,
    )
    .expect("memory_search must not throw");
    content_text(&result).to_owned()
}

fn get(registry: &EstateRegistry, id: &str, ledger: &SensitivityGrantLedger) -> String {
    let result = interface_tools::dispatch(
        "moot_memory_get",
        &args!["id" => id],
        registry,
        &SurfacedRecallLedger::new(),
        ledger,
        "",
        "",
        None,
        None,
    )
    .expect("memory_get must not throw");
    content_text(&result).to_owned()
}

// ---------------------------------------------------------------------------
// No grant, no sensitive rows → advisory present
// ---------------------------------------------------------------------------

/// The case that proves the oracle is gone. Pre-fix, an estate with no
/// restricted or secret rows emitted NO advisory, and that silence was the
/// disclosure.
#[test]
fn search_advisory_present_on_clean_estate_without_grant() {
    let pair = make_estate_pair();
    let body = search(&pair.clean, &SensitivityGrantLedger::new());
    assert_eq!(
        advisories(&body),
        vec![SEARCH_ADVISORY],
        "the gate is in effect, so the advisory must be emitted verbatim regardless of contents; got: {body}"
    );
}

#[test]
fn get_advisory_present_on_clean_estate_without_grant() {
    let pair = make_estate_pair();
    let body = get(&pair.clean, &pair.clean_visible_id, &SensitivityGrantLedger::new());
    assert_eq!(advisories(&body), vec![GET_ADVISORY], "got: {body}");
}

// ---------------------------------------------------------------------------
// The regression test: indistinguishability
// ---------------------------------------------------------------------------

/// Two estates differing ONLY in whether restricted/secret rows exist must
/// produce IDENTICAL advisory behaviour for an ungranted caller. This is the
/// assertion that fails against the pre-fix code.
#[test]
fn search_advisory_indistinguishable_between_estates_without_grant() {
    let pair = make_estate_pair();
    let clean_body = search(&pair.clean, &SensitivityGrantLedger::new());
    let sensitive_body = search(&pair.sensitive, &SensitivityGrantLedger::new());

    assert_eq!(
        advisories(&clean_body),
        advisories(&sensitive_body),
        "advisory behaviour must not distinguish an estate with sensitive rows from one without"
    );
    assert_eq!(
        advisories(&clean_body),
        vec![SEARCH_ADVISORY],
        "and both must be the real advisory, not a shared absence"
    );

    // The gate itself still works: the restricted/secret bodies never leak.
    assert!(!sensitive_body.contains("classified briefing"));
    assert!(!sensitive_body.contains("top secret payload"));
}

#[test]
fn get_advisory_indistinguishable_between_estates_without_grant() {
    let pair = make_estate_pair();
    let clean_body = get(&pair.clean, &pair.clean_visible_id, &SensitivityGrantLedger::new());
    let sensitive_body =
        get(&pair.sensitive, &pair.sensitive_visible_id, &SensitivityGrantLedger::new());

    assert_eq!(
        advisories(&clean_body),
        advisories(&sensitive_body),
        "fetching a visible row must disclose nothing about other rows' existence"
    );
    assert_eq!(advisories(&clean_body), vec![GET_ADVISORY]);
}

/// The mission's fourth case, stated directly: a successful by-id fetch of an
/// ordinary row must carry no signal about what else the estate holds. The
/// reply differs from the clean estate's ONLY in the row's own fields.
#[test]
fn get_of_visible_row_discloses_nothing_about_other_rows() {
    let pair = make_estate_pair();
    let clean_body = get(&pair.clean, &pair.clean_visible_id, &SensitivityGrantLedger::new());
    let sensitive_body =
        get(&pair.sensitive, &pair.sensitive_visible_id, &SensitivityGrantLedger::new());

    for body in [&clean_body, &sensitive_body] {
        assert!(body.contains("ordinary visible content"));
        assert!(!body.contains("classified briefing"));
        assert!(!body.contains("top secret payload"));
    }

    // Normalise away the row's own identity; what remains must match
    // line-for-line between the two estates. Per-row provenance fields
    // legitimately differ (timestamps, lineage uuid); the SHAPE is what must
    // not vary.
    fn shape(body: &str, id: &str) -> Vec<String> {
        body.lines()
            .map(|l| l.replace(id, "<id>"))
            .filter(|l| {
                !l.starts_with("filed_at: ")
                    && !l.starts_with("event_time: ")
                    && !l.starts_with("lineage: ")
            })
            .collect()
    }
    assert_eq!(
        shape(&clean_body, &pair.clean_visible_id),
        shape(&sensitive_body, &pair.sensitive_visible_id),
        "the two replies must be indistinguishable apart from the row's own provenance"
    );
}

// ---------------------------------------------------------------------------
// Live grant → advisory absent
// ---------------------------------------------------------------------------

#[test]
fn search_advisory_absent_under_live_grant_in_both_estates() {
    let pair = make_estate_pair();
    let clean_ledger = SensitivityGrantLedger::new();
    let sensitive_ledger = SensitivityGrantLedger::new();
    clean_ledger.grant_restricted(wall_now(), 0);
    sensitive_ledger.grant_restricted(wall_now(), 0);

    assert!(
        advisories(&search(&pair.clean, &clean_ledger)).is_empty(),
        "under a live grant the ceiling is lifted and no advisory applies"
    );
    assert!(advisories(&search(&pair.sensitive, &sensitive_ledger)).is_empty());
}

#[test]
fn get_advisory_absent_under_live_grant_in_both_estates() {
    let pair = make_estate_pair();
    let clean_ledger = SensitivityGrantLedger::new();
    let sensitive_ledger = SensitivityGrantLedger::new();
    clean_ledger.grant_restricted(wall_now(), 0);
    sensitive_ledger.grant_restricted(wall_now(), 0);

    assert!(advisories(&get(&pair.clean, &pair.clean_visible_id, &clean_ledger)).is_empty());
    assert!(advisories(&get(
        &pair.sensitive,
        &pair.sensitive_visible_id,
        &sensitive_ledger
    ))
    .is_empty());
}

/// A secret-tier grant lifts the ceiling too, so it must also suppress the
/// advisory — the condition is "a grant is live", not "the restricted grant
/// specifically".
#[test]
fn search_advisory_absent_under_live_secret_grant() {
    let pair = make_estate_pair();
    let ledger = SensitivityGrantLedger::new();
    ledger.grant_secret(wall_now());

    assert!(advisories(&search(&pair.sensitive, &ledger)).is_empty());
}
