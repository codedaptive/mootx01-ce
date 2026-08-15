// ResidentIndexBudgetTests.swift
//
// Covers ResidentIndexBudget.resolveCeiling and the EstateConfiguration.residentIndexBudget
// field — including the default value and queueSibling propagation.
//
// This file owns the PersistenceKit half of the Part 3 cross-port agreement test (behaviour d):
// the ceiling-resolution formula is asserted against fixed literal inputs so the Rust twin
// (storage.rs ResidentIndexBudget::resolve_ceiling) is forced to agree on the same numbers.
// A formula divergence becomes a failing test in whichever port disagrees.
//
// No storage is opened here — all tests are pure struct/enum method calls.

import Testing
import Foundation
import PersistenceKit

@Suite("ResidentIndexBudget")
struct ResidentIndexBudgetTests {

    // MARK: - resolveCeiling — cross-port agreement literals (behaviour d)

    /// Cross-port literal: 0.25 × 8 GiB = 2,147,483,648 bytes exactly.
    ///
    /// The Rust twin (storage.rs) asserts the same literal for the same inputs.
    /// Passing physicalMemoryBytes explicitly keeps the result machine-independent:
    /// tests run identically on a 16 GiB dev laptop and a 128 GiB build host.
    @Test("systemFraction 0.25 resolves to 2 GiB against 8 GiB physical memory")
    func systemFractionResolves8GiBLiteral() {
        // 8 GiB in bytes: 8 × 1024^3 = 8_589_934_592.
        // 8_589_934_592 × 0.25 = 2_147_483_648.
        // Both Swift and Rust must produce 2_147_483_648 for these inputs.
        let ceiling = ResidentIndexBudget.systemFraction(0.25)
            .resolveCeiling(physicalMemoryBytes: 8_589_934_592)
        #expect(ceiling == 2_147_483_648)
    }

    // MARK: - unbounded case

    /// .unbounded always returns nil — no admission check is applied.
    /// This is the explicit user opt-out that reproduces pre-RS-01 behaviour.
    @Test("unbounded resolveCeiling returns nil regardless of physical memory")
    func unboundedReturnsNil() {
        let withMemory = ResidentIndexBudget.unbounded
            .resolveCeiling(physicalMemoryBytes: 8_589_934_592)
        let noMemory = ResidentIndexBudget.unbounded
            .resolveCeiling(physicalMemoryBytes: 0)
        #expect(withMemory == nil)
        #expect(noMemory == nil)
    }

    // MARK: - explicit bytes case

    /// .bytes(N) returns N regardless of host memory.
    ///
    /// The explicit ceiling is honoured even when physicalMemoryBytes == 0 (undetectable
    /// RAM). Discarding an explicitly-configured ceiling because detection failed would
    /// give the operator no cap at all — the opposite of their intent.
    @Test("explicit bytes ceiling is honoured regardless of physical memory")
    func explicitBytesHonoured() {
        let ceiling8GiB = ResidentIndexBudget.bytes(1_024)
            .resolveCeiling(physicalMemoryBytes: 8_589_934_592)
        let ceilingZero = ResidentIndexBudget.bytes(1_024)
            .resolveCeiling(physicalMemoryBytes: 0)
        #expect(ceiling8GiB == 1_024)
        #expect(ceilingZero == 1_024)
    }

    // MARK: - undetectable memory

    /// When physicalMemoryBytes == 0 the host RAM is undetectable. .systemFraction
    /// returns nil rather than guessing a ceiling — a wrong guess would refuse every
    /// estate on an unknown platform, silently degrading all queries to table-scan.
    @Test("systemFraction returns nil when physical memory is undetectable (bytes = 0)")
    func systemFractionUndetectableMemory() {
        let ceiling = ResidentIndexBudget.systemFraction(0.25)
            .resolveCeiling(physicalMemoryBytes: 0)
        #expect(ceiling == nil)
    }

    // MARK: - EstateConfiguration default and field propagation

    /// The default EstateConfiguration carries .systemFraction(0.25) per spec RS-01.
    /// Existing call sites that omit residentIndexBudget at init time receive this budget.
    @Test("EstateConfiguration default residentIndexBudget is systemFraction(0.25)")
    func defaultBudgetIsSystemFraction() {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        #expect(config.residentIndexBudget == .systemFraction(0.25))
    }

    /// queueSibling carries the parent's residentIndexBudget to the derived sibling config.
    ///
    /// A queue estate must honour the same cap as its parent estate — the operator
    /// set the cap at the estate level, not per-file. Checked for both the SQLite and
    /// InMemory backends (the only two that produce a sibling without throwing).
    @Test("queueSibling propagates residentIndexBudget — SQLite backend")
    func queueSiblingCarriesBudgetSQLite() throws {
        let url = URL(fileURLWithPath: "/tmp/budget-propagation-\(UUID().uuidString).sqlite")
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url),
            residentIndexBudget: .bytes(99_999)
        )
        let sibling = try config.queueSibling(filename: "queue.sqlite")
        #expect(sibling.residentIndexBudget == .bytes(99_999))
    }

    @Test("queueSibling propagates residentIndexBudget — InMemory backend")
    func queueSiblingCarriesBudgetInMemory() throws {
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory,
            residentIndexBudget: .unbounded
        )
        let sibling = try config.queueSibling(filename: "queue.sqlite")
        #expect(sibling.residentIndexBudget == .unbounded)
    }
}
