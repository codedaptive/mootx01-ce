// EstateCacheConfigTests.swift
//
// Tests for EstateCacheConfig and the cacheConfig field on EstateConfiguration.
// Verifies: default is disabled, threshold clamp, ceiling clamp, and that
// EstateConfiguration preserves the supplied config.

import Foundation
import Testing
@testable import PersistenceKit

@Suite("EstateCacheConfigTests")
struct EstateCacheConfigTests {

    // MARK: — EstateCacheConfig.disabled

    @Test("default disabled constant has enabled=false, ceiling=0, threshold=0")
    func disabledConstantShape() {
        let config = EstateCacheConfig.disabled
        #expect(config.enabled == false)
        #expect(config.ceilingBytes == 0)
        #expect(config.sensitivityThreshold == 0)
    }

    // MARK: — Threshold clamp

    @Test("threshold clamped from 5 to 2 (Secret-exclusion invariant)")
    func thresholdClampedAboveSecret() {
        let config = EstateCacheConfig(enabled: true, ceilingBytes: 1_000, sensitivityThreshold: 5)
        #expect(config.sensitivityThreshold == 2)
    }

    @Test("threshold clamped from 3 to 2 (Secret level exactly)")
    func thresholdClampedAtSecret() {
        let config = EstateCacheConfig(enabled: true, ceilingBytes: 1_000, sensitivityThreshold: 3)
        #expect(config.sensitivityThreshold == 2)
    }

    @Test("threshold of 2 is unchanged (maximum legal value)")
    func thresholdAtMaxLegal() {
        let config = EstateCacheConfig(enabled: true, ceilingBytes: 1_000, sensitivityThreshold: 2)
        #expect(config.sensitivityThreshold == 2)
    }

    @Test("threshold of 0 is unchanged")
    func thresholdAtZero() {
        let config = EstateCacheConfig(enabled: true, ceilingBytes: 1_000, sensitivityThreshold: 0)
        #expect(config.sensitivityThreshold == 0)
    }

    // MARK: — Ceiling clamp

    @Test("negative ceiling clamped to 0")
    func ceilingClampedNegative() {
        let config = EstateCacheConfig(enabled: true, ceilingBytes: -1, sensitivityThreshold: 1)
        #expect(config.ceilingBytes == 0)
    }

    @Test("ceiling of 0 is unchanged")
    func ceilingAtZero() {
        let config = EstateCacheConfig(enabled: true, ceilingBytes: 0, sensitivityThreshold: 1)
        #expect(config.ceilingBytes == 0)
    }

    @Test("positive ceiling preserved exactly")
    func ceilingPositivePreserved() {
        let config = EstateCacheConfig(enabled: true, ceilingBytes: 10_485_760, sensitivityThreshold: 1)
        #expect(config.ceilingBytes == 10_485_760)
    }

    // MARK: — Enabled flag

    @Test("enabled flag preserved true")
    func enabledFlagTrue() {
        let config = EstateCacheConfig(enabled: true, ceilingBytes: 1_000, sensitivityThreshold: 1)
        #expect(config.enabled == true)
    }

    @Test("enabled flag preserved false")
    func enabledFlagFalse() {
        let config = EstateCacheConfig(enabled: false, ceilingBytes: 1_000, sensitivityThreshold: 1)
        #expect(config.enabled == false)
    }

    // MARK: — EstateConfiguration integration

    @Test("EstateConfiguration default cacheConfig is disabled")
    func estateConfigurationDefaultCacheDisabled() {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        #expect(config.cacheConfig.enabled == false)
        #expect(config.cacheConfig.ceilingBytes == 0)
        #expect(config.cacheConfig.sensitivityThreshold == 0)
    }

    @Test("EstateConfiguration with explicit enabled cacheConfig preserves all fields")
    func estateConfigurationExplicitCachePreservesFields() {
        let cache = EstateCacheConfig(enabled: true, ceilingBytes: 5_000_000, sensitivityThreshold: 1)
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory, cacheConfig: cache)
        #expect(config.cacheConfig.enabled == true)
        #expect(config.cacheConfig.ceilingBytes == 5_000_000)
        #expect(config.cacheConfig.sensitivityThreshold == 1)
    }

    @Test("EstateConfiguration with disabled cacheConfig matches disabled constant")
    func estateConfigurationWithDisabledMatchesConstant() {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory, cacheConfig: .disabled)
        #expect(config.cacheConfig.enabled == EstateCacheConfig.disabled.enabled)
        #expect(config.cacheConfig.ceilingBytes == EstateCacheConfig.disabled.ceilingBytes)
        #expect(config.cacheConfig.sensitivityThreshold == EstateCacheConfig.disabled.sensitivityThreshold)
    }
}
