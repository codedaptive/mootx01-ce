// novel_token_tagger_tests.rs — Layer-2a: NovelTokenTaggerChoice on Rust
//
// Verifies:
//   (a) EstateConfiguration::new defaults to Hmm
//   (b) EstateConfiguration::new_with_tagger(Hmm) succeeds
//   (c) EstateConfiguration::new_with_tagger(NlTagger) returns InvalidConfiguration
//   (d) NovelTokenTaggerChoice default is Hmm
//   (e) NovelTokenTaggerChoice enum cases are distinct
//   (f) StorageError::InvalidConfiguration exists and carries reason

use persistence_kit::{
    BackendConfiguration, EstateConfiguration, NovelTokenTaggerChoice, StorageError,
};
use uuid::Uuid;

// (a) default EstateConfiguration::new uses Hmm novel-token tagger.
// This confirms the cross-platform default and ensures existing Rust call
// sites get the correct HMM baseline.
#[test]
fn default_estate_config_uses_hmm() {
    let cfg = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    assert_eq!(
        cfg.novel_token_tagger,
        NovelTokenTaggerChoice::Hmm,
        "default novel_token_tagger must be Hmm"
    );
}

// (b) new_with_tagger(Hmm) succeeds and stores the choice.
#[test]
fn new_with_tagger_hmm_succeeds() {
    let result = EstateConfiguration::new_with_tagger(
        Uuid::new_v4(),
        BackendConfiguration::InMemory,
        NovelTokenTaggerChoice::Hmm,
    );
    assert!(result.is_ok(), "new_with_tagger(Hmm) should succeed");
    let cfg = result.unwrap();
    assert_eq!(cfg.novel_token_tagger, NovelTokenTaggerChoice::Hmm);
}

// (c) new_with_tagger(NlTagger) is rejected on Rust (no NaturalLanguage
// framework). Fail-closed: returns StorageError::InvalidConfiguration.
#[test]
fn new_with_tagger_nl_tagger_rejected_on_rust() {
    let result = EstateConfiguration::new_with_tagger(
        Uuid::new_v4(),
        BackendConfiguration::InMemory,
        NovelTokenTaggerChoice::NlTagger,
    );
    assert!(
        result.is_err(),
        "NlTagger must be rejected on Rust (no NaturalLanguage framework)"
    );
    match result.unwrap_err() {
        StorageError::InvalidConfiguration { reason } => {
            assert!(
                reason.contains("NaturalLanguage") || reason.contains("NlTagger") || reason.contains("non-Apple"),
                "Error reason should mention the NaturalLanguage constraint: {}",
                reason
            );
        }
        other => panic!("Expected InvalidConfiguration, got {:?}", other),
    }
}

// (d) NovelTokenTaggerChoice::default() is Hmm.
#[test]
fn novel_token_tagger_choice_default_is_hmm() {
    let choice = NovelTokenTaggerChoice::default();
    assert_eq!(choice, NovelTokenTaggerChoice::Hmm);
}

// (e) NovelTokenTaggerChoice enum cases are distinct.
#[test]
fn novel_token_tagger_choice_cases_are_distinct() {
    assert_ne!(
        NovelTokenTaggerChoice::Hmm,
        NovelTokenTaggerChoice::NlTagger
    );
}

// (f) StorageError::InvalidConfiguration exists and carries a reason.
#[test]
fn storage_error_invalid_configuration_variant_exists() {
    let err = StorageError::InvalidConfiguration {
        reason: "test reason".to_owned(),
    };
    match err {
        StorageError::InvalidConfiguration { reason } => {
            assert_eq!(reason, "test reason");
        }
        other => panic!("Expected InvalidConfiguration, got {:?}", other),
    }
}
