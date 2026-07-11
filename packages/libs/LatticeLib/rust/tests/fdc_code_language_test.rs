use lattice_lib::{detect_code_language, Fdc, FdcContentKind};
use serde::Deserialize;

#[derive(Deserialize)]
struct Fixture {
    version: String,
    vectors: Vec<Vector>,
}

#[derive(Deserialize)]
struct Vector {
    name: String,
    input: String,
    identifier: String,
    qid: String,
}

#[test]
fn code_language_conformance() {
    let fixture: Fixture =
        serde_json::from_str(include_str!("fixtures/fdc_code_language_conformance.json")).unwrap();
    assert_eq!(fixture.version, "1.0.0");
    for vector in fixture.vectors {
        let language = detect_code_language(&vector.input)
            .unwrap_or_else(|| panic!("{} must resolve", vector.name));
        assert_eq!(language.identifier, vector.identifier, "{}", vector.name);
        assert_eq!(language.wikidata_qid, vector.qid, "{}", vector.name);
        let anchor = Fdc::encode_anchor(&vector.input);
        assert_eq!(anchor.0.as_deref(), Some("005"), "{}", vector.name);
        assert_eq!(
            anchor.1.as_deref(),
            Some(vector.qid.as_str()),
            "{}",
            vector.name
        );
    }
}

#[test]
fn explicit_code_kind_classifies_short_ambiguous_snippet() {
    let anchor = Fdc::encode_anchor_for_content_no_record("x += 1", FdcContentKind::Code);
    assert_eq!(anchor, (Some("005".to_string()), None));
}

#[test]
fn syntax_heavy_source_is_programming_but_shell_transcripts_remain_operational() {
    let source = "if (value != nil) { result = value; return result; }";
    let shell = "```bash\ngit worktree prune\nrm -f .git/index.lock\n```";
    assert_eq!(Fdc::encode(source).as_deref(), Some("005"));
    assert_eq!(Fdc::encode(shell).as_deref(), Some("000"));
    assert_eq!(
        Fdc::encode_anchor_for_content_no_record(shell, FdcContentKind::Code)
            .0
            .as_deref(),
        Some("005")
    );
}

#[test]
fn unlabeled_source_fences_classify_without_turning_prose_into_typescript() {
    let fenced_json = "```\n{\"name\": \"Ada\", \"active\": true}\n```";
    let prose = "The interface should feel natural and modern for every user.";
    assert_eq!(Fdc::encode(fenced_json).as_deref(), Some("005"));
    assert_eq!(detect_code_language(prose), None);
    assert_ne!(Fdc::encode(prose).as_deref(), Some("005"));
}
