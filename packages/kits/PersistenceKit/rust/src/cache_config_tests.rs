//! Tests for EstateCacheConfig and the cache_config field on EstateConfiguration.
//! Mirrors EstateCacheConfigTests.swift — both ports must agree.

use crate::cache_config::EstateCacheConfig;
use crate::storage::{BackendConfiguration, EstateConfiguration};

// MARK: — EstateCacheConfig::disabled

#[test]
fn disabled_constant_shape() {
    let config = EstateCacheConfig::disabled();
    assert!(!config.enabled);
    assert_eq!(config.ceiling_bytes, 0);
    assert_eq!(config.sensitivity_threshold, 0);
}

// MARK: — Threshold clamp

#[test]
fn threshold_clamped_above_secret() {
    let config = EstateCacheConfig::new(true, 1_000, 5);
    assert_eq!(config.sensitivity_threshold, 2);
}

#[test]
fn threshold_clamped_at_secret() {
    let config = EstateCacheConfig::new(true, 1_000, 3);
    assert_eq!(config.sensitivity_threshold, 2);
}

#[test]
fn threshold_at_max_legal_unchanged() {
    let config = EstateCacheConfig::new(true, 1_000, 2);
    assert_eq!(config.sensitivity_threshold, 2);
}

#[test]
fn threshold_at_zero_unchanged() {
    let config = EstateCacheConfig::new(true, 1_000, 0);
    assert_eq!(config.sensitivity_threshold, 0);
}

// MARK: — Ceiling clamp

#[test]
fn ceiling_clamped_negative() {
    let config = EstateCacheConfig::new(true, -1, 1);
    assert_eq!(config.ceiling_bytes, 0);
}

#[test]
fn ceiling_at_zero_unchanged() {
    let config = EstateCacheConfig::new(true, 0, 1);
    assert_eq!(config.ceiling_bytes, 0);
}

#[test]
fn ceiling_positive_preserved() {
    let config = EstateCacheConfig::new(true, 10_485_760, 1);
    assert_eq!(config.ceiling_bytes, 10_485_760);
}

// MARK: — Enabled flag

#[test]
fn enabled_flag_true_preserved() {
    let config = EstateCacheConfig::new(true, 1_000, 1);
    assert!(config.enabled);
}

#[test]
fn enabled_flag_false_preserved() {
    let config = EstateCacheConfig::new(false, 1_000, 1);
    assert!(!config.enabled);
}

// MARK: — EstateConfiguration integration

#[test]
fn estate_configuration_default_cache_disabled() {
    let id = uuid::Uuid::new_v4();
    let config = EstateConfiguration::new(id, BackendConfiguration::InMemory);
    assert!(!config.cache_config.enabled);
    assert_eq!(config.cache_config.ceiling_bytes, 0);
    assert_eq!(config.cache_config.sensitivity_threshold, 0);
}

#[test]
fn estate_configuration_explicit_cache_preserves_fields() {
    let cache = EstateCacheConfig::new(true, 5_000_000, 1);
    let id = uuid::Uuid::new_v4();
    let mut config = EstateConfiguration::new(id, BackendConfiguration::InMemory);
    config.cache_config = cache;
    assert!(config.cache_config.enabled);
    assert_eq!(config.cache_config.ceiling_bytes, 5_000_000);
    assert_eq!(config.cache_config.sensitivity_threshold, 1);
}

#[test]
fn estate_configuration_disabled_matches_disabled_constructor() {
    let id = uuid::Uuid::new_v4();
    let config = EstateConfiguration::new(id, BackendConfiguration::InMemory);
    let disabled = EstateCacheConfig::disabled();
    assert_eq!(config.cache_config.enabled, disabled.enabled);
    assert_eq!(config.cache_config.ceiling_bytes, disabled.ceiling_bytes);
    assert_eq!(config.cache_config.sensitivity_threshold, disabled.sensitivity_threshold);
}
