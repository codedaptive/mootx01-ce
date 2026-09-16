//! The same synthetic Python-oracle representations are consumed by Swift.
use context_distill_lib::complete_content::{
    CompleteContentReducer, CompleteContentResult, REPEAT_LEGEND, VISIBLE_NOTICE,
};
use context_distill_lib::digest::estimate_tokens;

#[test]
fn complete_reference_expansion_is_bounded_by_shared_settings_vector() {
    let vector: serde_json::Value = serde_json::from_str(include_str!(
        "../../Tests/ContextDistillLibTests/Vectors/reference-expansion-limits.json"
    ))
    .unwrap();
    let definition_bytes = vector["definition_bytes"].as_u64().unwrap() as usize;
    let repeat_count = vector["repeat_count"].as_u64().unwrap() as usize;
    let body = format!(
        "[[TSREF:1 DEFINE]] {}\n{}",
        "x".repeat(definition_bytes),
        "[[TSREF:1 REPEAT]]\n".repeat(repeat_count)
    );
    let source = format!("{VISIBLE_NOTICE}{REPEAT_LEGEND}{body}");

    let result = CompleteContentReducer::distill(&source, |s| s.len() as u64).unwrap();
    let error = result.reference_expansion_error.unwrap();

    assert_eq!(result.text, source);
    assert_eq!(error.code, vector["error_code"].as_str().unwrap());
    assert_eq!(error.message, vector["error_message"].as_str().unwrap());
    assert_eq!(error.max_bytes as u64, vector["max_bytes"]);
    assert_eq!(error.max_ratio as u64, vector["max_ratio"]);
    assert!(error.attempted_bytes <= error.max_bytes + definition_bytes);
    assert!(!result.visible_refs);
}

#[test]
fn complete_form_v6_shared_python_goldens() {
    let document: serde_json::Value = serde_json::from_str(include_str!(
        "../../Tests/ContextDistillLibTests/Vectors/complete-form-v6.json"
    ))
    .unwrap();
    for vector in document["vectors"].as_array().unwrap() {
        let source = vector["source"].as_str().unwrap();
        let count = |s: &str| {
            if vector["counter"] == "utf8" {
                s.len() as u64
            } else {
                estimate_tokens(s)
            }
        };
        let got = CompleteContentReducer::distill(source, count).unwrap();
        let expected: CompleteContentResult = serde_json::from_value(vector.clone()).unwrap();
        assert_eq!(got, expected, "{} / {}", vector["name"], vector["counter"]);
        assert!(got.output_tokens <= got.original_tokens);
        assert_eq!(CompleteContentReducer::distill(source, count).unwrap(), got);
    }
}

#[test]
fn reserved_visible_grammar_is_validated() {
    for body in [
        "[[TSREF:1 REPEAT]]\n",
        "[[TSREF:1 DEFINE]] value\n[[TSREF:1 DEFINE]] other\n",
        "[[TSREF:1 DEFINE]] - [[123-link]] body\nentry 999: [[TSREF:1 REPEAT]]\n",
    ] {
        let source = format!("{VISIBLE_NOTICE}{REPEAT_LEGEND}{body}");
        assert!(CompleteContentReducer::distill(&source, |s| s.len() as u64).is_err());
    }
}

#[test]
fn constant_counter_never_accepts_a_transform() {
    let source = format!("{}\n", "Long prose with useful details. ".repeat(25)).repeat(8);
    assert_eq!(
        CompleteContentReducer::distill(&source, |_| 1)
            .unwrap()
            .text,
        source
    );
}

#[test]
fn unicode_decimal_clocks_and_arbitrary_integer_fields() {
    let source = format!(
        "## Transcript\n{}",
        "[٠٠:٠١] The spoken phrase.\n".repeat(80)
    );
    let result = CompleteContentReducer::distill(&source, |s| s.len() as u64).unwrap();
    assert!(result.text.contains("1 The spoken phrase."));
    let source = format!(
        "## Transcript\n{}",
        "[999999999999999999999999999999999999999999:00] The spoken phrase.\n".repeat(80)
    );
    let result = CompleteContentReducer::distill(&source, |s| s.len() as u64).unwrap();
    assert!(result
        .text
        .contains("59999999999999999999999999999999999999999940 The spoken phrase."));
}
