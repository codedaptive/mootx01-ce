// EstateAdminCacheTests.swift
//
// Dual-Path Intake P1 verify line: the live admin engine now provisions
// estates with the hot cache ON by default — the backing storage wraps the
// tested CachingRowStore LRU tier instead of the bare row store. Also covers
// the environment-driven override resolver. All against SCRATCH estates.

import Testing
import Foundation
import PersistenceKit
@testable import MootManager

private func makeScratchEstatesDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-cache-\(UUID().uuidString)", isDirectory: true)
}

private func req(
    name: String = "CacheScratch",
    kind: String = "GLK",
    backend: String = "InMemory",
    owner: String = "cache-tests"
) -> EstateAdminRequest {
    EstateAdminRequest(
        estateName: name,
        kind: kind,
        backend: backend,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: "None",
        owner: owner
    )
}

@Suite("EstateAdmin — hot cache (Dual-Path Intake P1)")
struct EstateAdminCacheTests {

    // MARK: - Live estate wraps CachingRowStore (cache ON)

    @Test("provision with cache ON → SQLite backing storage wraps CachingRowStore")
    func sqliteLiveEstateIsCaching() async throws {
        try await withIntellectusLock {
            // Explicit cache-ON config (the live default), independent of the
            // ambient process environment so the test is deterministic.
            let admin = EstateAdmin(
                estatesDirectory: makeScratchEstatesDir(),
                cacheConfig: EstateCacheConfig(
                    enabled: true, ceilingBytes: 64 * 1024 * 1024,
                    sensitivityThreshold: 2)
            )
            let result = try await admin.provision(req(backend: "SQLite"))
            let uuid = try #require(result.estateUUID)
            // The previously-dark CachingRowStore path is now lit for the live
            // estate: its backing storage's rowStore IS a CachingRowStore.
            #expect(await admin.backingStorageIsCaching(for: uuid) == true)
        }
    }

    @Test("provision with cache ON → InMemory backing storage wraps CachingRowStore")
    func inMemoryLiveEstateIsCaching() async throws {
        try await withIntellectusLock {
            let admin = EstateAdmin(
                estatesDirectory: makeScratchEstatesDir(),
                cacheConfig: EstateCacheConfig(
                    enabled: true, ceilingBytes: 8 * 1024 * 1024,
                    sensitivityThreshold: 2)
            )
            let result = try await admin.provision(req(backend: "InMemory"))
            let uuid = try #require(result.estateUUID)
            #expect(await admin.backingStorageIsCaching(for: uuid) == true)
        }
    }

    // MARK: - Override: cache OFF reverts to bare row store

    @Test("provision with cache OFF → backing storage does NOT wrap CachingRowStore")
    func cacheDisabledRevertsToBareStore() async throws {
        try await withIntellectusLock {
            let admin = EstateAdmin(
                estatesDirectory: makeScratchEstatesDir(),
                cacheConfig: .disabled
            )
            let result = try await admin.provision(req(backend: "SQLite"))
            let uuid = try #require(result.estateUUID)
            #expect(await admin.backingStorageIsCaching(for: uuid) == false)
        }
    }

    // MARK: - Default resolver is cache-ON

    @Test("resolveCacheConfig default (no env override) is enabled")
    func resolverDefaultIsEnabled() {
        // In a normal test process MOOTX01_ESTATE_CACHE is unset → cache ON.
        // (If a CI runner sets it to 0 the assertion below would flip; the
        // resident host ships with it unset, which is the contract we encode.)
        if ProcessInfo.processInfo.environment["MOOTX01_ESTATE_CACHE"] == nil {
            let cfg = EstateAdmin.resolveCacheConfig()
            #expect(cfg.enabled)
            #expect(cfg.ceilingBytes > 0)
            // Secret-exclusion clamp holds: threshold never exceeds 2.
            #expect(cfg.sensitivityThreshold <= 2)
        }
    }
}
