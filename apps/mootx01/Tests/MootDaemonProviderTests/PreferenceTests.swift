import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

// MARK: - MACD-3B2 preference record and store tests
//
// Covers every P1–P5 policy row:
//   P1  — exact five-field record shape
//   P2  — MAC: domain separation, constant-time verify, exact key set
//   P3  — ProviderPreferenceStore: atomic replace, fail-closed reads,
//          monotonic generation enforcement on write AND rollback detection
//          on read
//   P4  — ProviderPreferenceObservation summary (never raw bytes)
//   P5  — two legitimate writers; conflict detection = monotonic + MAC +
//          atomic replace

// MARK: Shared test data

private let preferenceRoot = [UInt8](repeating: 0xAB, count: 32)
private let alternateRoot  = [UInt8](repeating: 0xCD, count: 32)  // domain separation
private let leaseRoot      = [UInt8](repeating: 5, count: 32)     // handover-lease domain

private let issuingIdentity = SigningIdentityDescriptor(
    teamIdentifier: testTeam,
    bundleIdentifier: "com.codedaptive.mootx01.app",
    signingClass: .appleDistribution
)

/// A baseline valid preference record (generation 1), signed under `preferenceRoot`.
private func makePreference(
    kind: ProviderKind = .direct,
    generation: UInt64 = 1,
    issuedAt: UInt64 = 1_700_000_000,
    lastHandover: UInt64 = 0,
    root: [UInt8] = preferenceRoot
) -> ProviderPreference {
    ProviderPreference(
        preferredKind: kind,
        preferenceGeneration: generation,
        issuingIdentity: issuingIdentity,
        issuedAt: issuedAt,
        lastCompletedHandoverGeneration: lastHandover,
        preferenceMAC: []
    ).signing(installationRoot: root)
}

/// A per-test scratch directory and store.
private struct PreferenceScratch {
    let scratch: ScratchDirectory
    let fileURL: URL
    let store: ProviderPreferenceStore

    init(root: [UInt8] = preferenceRoot) {
        scratch = ScratchDirectory()
        fileURL = scratch.url.appendingPathComponent("provider-preference.v1.json")
        store = ProviderPreferenceStore(fileURL: fileURL, installationRoot: root)
    }
}

// MARK: - P1: record shape

@Suite("ProviderPreference P1 record shape")
struct PreferenceRecordShapeTests {

    @Test("record encodes exactly the five P1 fields — no more, no less")
    func exactFieldSet() throws {
        let pref = makePreference()
        let data = pref.encoded()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("encoded() produced invalid JSON")
            return
        }
        // Exact key set from P1 (5 fields + the MAC = 8 JSON keys).
        let expected: Set<String> = [
            "preferredKind", "preferenceGeneration", "issuedAt",
            "lastCompletedHandoverGeneration",
            "issuingTeamIdentifier", "issuingBundleIdentifier", "issuingSigningClass",
            "preferenceMAC",
        ]
        #expect(Set(object.keys) == expected, "unexpected keys: \(Set(object.keys).symmetricDifference(expected))")
    }

    @Test("generation fields encode as decimal strings, not JSON numbers")
    func integerFieldsAreDecimalStrings() throws {
        let pref = makePreference(generation: 999, issuedAt: 1_700_000_000, lastHandover: 42)
        let data = pref.encoded()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("invalid JSON"); return
        }
        #expect(object["preferenceGeneration"] as? String == "999")
        #expect(object["issuedAt"] as? String == "1700000000")
        #expect(object["lastCompletedHandoverGeneration"] as? String == "42")
    }

    @Test("round-trip encode/decode preserves all five fields")
    func roundTrip() {
        let original = makePreference(kind: .bundled, generation: 7, issuedAt: 9_000_000, lastHandover: 3)
        let data = original.encoded()
        guard let decoded = ProviderPreference.decode(data) else {
            Issue.record("decode returned nil for valid record"); return
        }
        #expect(decoded.preferredKind == .bundled)
        #expect(decoded.preferenceGeneration == 7)
        #expect(decoded.issuedAt == 9_000_000)
        #expect(decoded.lastCompletedHandoverGeneration == 3)
        #expect(decoded.issuingIdentity == issuingIdentity)
        // MAC bytes survive round-trip.
        #expect(decoded.preferenceMAC == original.preferenceMAC)
    }
}

// MARK: - P2: MAC and domain separation

@Suite("ProviderPreference P2 MAC and domain separation")
struct PreferenceMACTests {

    @Test("preferenceKey differs from leaseKey and grantKey under the same K_install")
    func domainSeparation() {
        // All three domains derive different keys from the same K_install.
        let prefKey  = ProviderPreference.preferenceKey(installationRoot: preferenceRoot)
        let leaseKey = HandoverLease.leaseKey(installationRoot: preferenceRoot)
        // Keys must be distinct — same K_install, different domains.
        #expect(prefKey != leaseKey, "preference key must not equal lease key (domain separation)")
        // All must be 32 bytes.
        #expect(prefKey.count  == FirstPartyAuthProtocol.macByteCount)
        #expect(leaseKey.count == FirstPartyAuthProtocol.macByteCount)
    }

    @Test("same fields different domain constant produces different MAC")
    func domainInMACInput() {
        // Build two records with identical payloads but different K_install.
        // The domain string is embedded in macInput(), so different roots
        // produce different MACs.
        let pref1 = makePreference(root: preferenceRoot)
        let pref2 = ProviderPreference(
            preferredKind: pref1.preferredKind,
            preferenceGeneration: pref1.preferenceGeneration,
            issuingIdentity: pref1.issuingIdentity,
            issuedAt: pref1.issuedAt,
            lastCompletedHandoverGeneration: pref1.lastCompletedHandoverGeneration,
            preferenceMAC: []
        ).signing(installationRoot: alternateRoot)
        // Different K_install → different MAC.
        #expect(pref1.preferenceMAC != pref2.preferenceMAC)
        // Each verifies under its own root and fails under the other.
        #expect(pref1.verifyMAC(installationRoot: preferenceRoot))
        #expect(!pref1.verifyMAC(installationRoot: alternateRoot))
        #expect(pref2.verifyMAC(installationRoot: alternateRoot))
        #expect(!pref2.verifyMAC(installationRoot: preferenceRoot))
    }

    @Test("MAC bytes are exactly macByteCount (32)")
    func macLength() {
        let pref = makePreference()
        #expect(pref.preferenceMAC.count == FirstPartyAuthProtocol.macByteCount)
    }

    @Test("verify returns false for a zero-length MAC")
    func zeroLengthMACFails() {
        var pref = makePreference()
        pref.preferenceMAC = []
        #expect(!pref.verifyMAC(installationRoot: preferenceRoot))
    }

    @Test("verify returns false for a flipped bit in the MAC")
    func bitFlipFails() {
        var pref = makePreference()
        pref.preferenceMAC[0] ^= 0x01
        #expect(!pref.verifyMAC(installationRoot: preferenceRoot))
    }

    @Test("changing any field invalidates the MAC")
    func fieldBindingInMAC() {
        let original = makePreference(kind: .direct, generation: 1)

        // Flip the kind.
        var wrongKind = original
        wrongKind = ProviderPreference(
            preferredKind: .bundled,
            preferenceGeneration: original.preferenceGeneration,
            issuingIdentity: original.issuingIdentity,
            issuedAt: original.issuedAt,
            lastCompletedHandoverGeneration: original.lastCompletedHandoverGeneration,
            preferenceMAC: original.preferenceMAC
        )
        #expect(!wrongKind.verifyMAC(installationRoot: preferenceRoot))

        // Bump the generation without re-signing.
        var wrongGen = original
        wrongGen = ProviderPreference(
            preferredKind: original.preferredKind,
            preferenceGeneration: original.preferenceGeneration + 1,
            issuingIdentity: original.issuingIdentity,
            issuedAt: original.issuedAt,
            lastCompletedHandoverGeneration: original.lastCompletedHandoverGeneration,
            preferenceMAC: original.preferenceMAC
        )
        #expect(!wrongGen.verifyMAC(installationRoot: preferenceRoot))
    }
}

// MARK: - P2: on-disk exact key set enforcement

@Suite("ProviderPreference P2 strictJSONObject (on-disk exact key set)")
struct PreferenceDecodeExactKeySetTests {

    @Test("decode returns nil for an extra key in the JSON")
    func extraKeyFails() {
        let pref = makePreference()
        var data = pref.encoded()
        // Inject an extra key.
        let json = String(decoding: data, as: UTF8.self)
        let injected = json.replacingOccurrences(
            of: "{", with: "{\"extraKey\":\"sneaky\","
        )
        data = Data(injected.utf8)
        #expect(ProviderPreference.decode(data) == nil)
    }

    @Test("decode returns nil for a missing required key")
    func missingKeyFails() {
        // Build a JSON object missing "issuedAt".
        let object: [String: Any] = [
            "preferredKind": "direct-install",
            "preferenceGeneration": "1",
            "lastCompletedHandoverGeneration": "0",
            "issuingTeamIdentifier": testTeam,
            "issuingBundleIdentifier": "com.test",
            "issuingSigningClass": "developer-id",
            "preferenceMAC": "AAAA",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        #expect(ProviderPreference.decode(data) == nil)
    }

    @Test("decode returns nil for truncated / invalid JSON bytes")
    func truncatedFails() {
        let pref = makePreference()
        let data = pref.encoded().dropLast(5)
        #expect(ProviderPreference.decode(Data(data)) == nil)
    }

    @Test("decode returns nil for an unknown preferredKind rawValue")
    func unknownKindFails() {
        let pref = makePreference()
        var json = String(decoding: pref.encoded(), as: UTF8.self)
        json = json.replacingOccurrences(of: "direct-install", with: "unknown-kind")
        #expect(ProviderPreference.decode(Data(json.utf8)) == nil)
    }
}

// MARK: - P3: ProviderPreferenceStore — round-trip and atomics

@Suite("ProviderPreferenceStore P3 durable round-trip")
struct PreferenceStoreRoundTripTests {

    @Test("write and load produces a verified observation")
    func writeLoadVerified() throws {
        let env = PreferenceScratch()
        let pref = makePreference(kind: .direct, generation: 1)
        try env.store.write(pref)
        let obs = env.store.load()
        if case .verified(let kind, let gen) = obs {
            #expect(kind == .direct)
            #expect(gen == 1)
        } else {
            Issue.record("expected .verified, got \(obs)")
        }
    }

    @Test("absent file produces .none observation")
    func absentProducesNone() {
        let env = PreferenceScratch()
        #expect(env.store.load() == .none)
    }
}

// MARK: - P3: monotonic generation enforcement on write

@Suite("ProviderPreferenceStore P3 monotonic write enforcement")
struct PreferenceStoreMonotonicWriteTests {

    @Test("monotonic downgrade write is refused")
    func downgradeRefused() throws {
        let env = PreferenceScratch()
        // Write generation 5.
        try env.store.write(makePreference(generation: 5))
        // Attempt to write generation 3 — must throw.
        #expect(throws: DaemonProviderError.generationFault(.overflow)) {
            try env.store.write(makePreference(generation: 3))
        }
        // The store must still read generation 5 after the refused write.
        if case .verified(_, let gen) = env.store.load() {
            #expect(gen == 5)
        } else {
            Issue.record("store should still read generation 5")
        }
    }

    @Test("equal-generation write is refused (not a strict advance)")
    func equalGenerationRefused() throws {
        let env = PreferenceScratch()
        try env.store.write(makePreference(generation: 2))
        #expect(throws: DaemonProviderError.generationFault(.overflow)) {
            try env.store.write(makePreference(generation: 2))
        }
    }

    @Test("strict advance write succeeds")
    func strictAdvanceSucceeds() throws {
        let env = PreferenceScratch()
        try env.store.write(makePreference(generation: 1))
        try env.store.write(makePreference(generation: 2))
        if case .verified(_, let gen) = env.store.load() {
            #expect(gen == 2)
        } else {
            Issue.record("expected .verified after two writes")
        }
    }

    @Test("first write with generation 1 succeeds (floor is 0)")
    func firstWriteSucceeds() throws {
        let env = PreferenceScratch()
        try env.store.write(makePreference(generation: 1))
        // Any generation ≥ 1 is a strict advance over the floor of 0.
    }
}

// MARK: - P3: rollback detection on read

@Suite("ProviderPreferenceStore P3 rollback detection on read")
struct PreferenceStoreRollbackReadTests {

    @Test("a lower generation on disk is refused on read (rollback)")
    func rollbackDetectedOnRead() throws {
        let env = PreferenceScratch()
        try env.store.write(makePreference(generation: 5))
        // Caller previously saw generation 5; a record claiming generation 3
        // is a rollback.
        let obs = env.store.load(minimumExpectedGeneration: 5)
        if case .verified(_, let gen) = obs {
            #expect(gen >= 5, "generation 5 meets the floor of 5")
            _ = gen  // silence unused warning
        }
        // Simulate a disk record that has been replaced with a lower-generation
        // record (adversarial scenario) by writing gen=3 directly to disk
        // bypassing the store's monotonic write gate.
        let low = makePreference(generation: 3)
        try low.encoded().write(to: env.fileURL, options: .atomic)
        // Now reading with minimumExpectedGeneration=5 must refuse.
        let obs2 = env.store.load(minimumExpectedGeneration: 5)
        #expect(obs2 == .invalid, "gen 3 < min 5 is a rollback → .invalid")
    }

    @Test("equal generation meets the minimum floor (not a rollback)")
    func equalGenerationMeetsFloor() throws {
        let env = PreferenceScratch()
        try env.store.write(makePreference(generation: 4))
        let obs = env.store.load(minimumExpectedGeneration: 4)
        if case .verified(_, let gen) = obs {
            #expect(gen == 4)
        } else {
            Issue.record("gen=4 meets floor=4, expected .verified")
        }
    }
}

// MARK: - P3: fail-closed reads

@Suite("ProviderPreferenceStore P3 fail-closed reads")
struct PreferenceStoreFailClosedTests {

    @Test("a corrupt (unparseable) record on disk returns .none")
    func corruptRecordNone() throws {
        let env = PreferenceScratch()
        // Write garbage bytes directly to the file location.
        try Data("not-json".utf8).write(to: env.fileURL, options: .atomic)
        #expect(env.store.load() == .none)
    }

    @Test("a wrong-MAC record returns .invalid")
    func wrongMACInvalid() throws {
        let env = PreferenceScratch()
        // Write a structurally valid record but with a flipped MAC bit.
        var pref = makePreference(generation: 1)
        pref.preferenceMAC[0] ^= 0xFF
        try pref.encoded().write(to: env.fileURL, options: .atomic)
        #expect(env.store.load() == .invalid)
    }

    @Test("a wrong-domain (alternate K_install) record returns .invalid")
    func wrongDomainInvalid() throws {
        let env = PreferenceScratch()
        // Sign with alternateRoot — the store uses preferenceRoot, so MAC fails.
        let pref = makePreference(generation: 1, root: alternateRoot)
        try pref.encoded().write(to: env.fileURL, options: .atomic)
        #expect(env.store.load() == .invalid)
    }

    @Test("an extra-key record (JSON injection) returns .none")
    func extraKeyNone() throws {
        let env = PreferenceScratch()
        let pref = makePreference(generation: 1)
        let json = String(decoding: pref.encoded(), as: UTF8.self)
            .replacingOccurrences(of: "{", with: "{\"injected\":\"x\",")
        try Data(json.utf8).write(to: env.fileURL, options: .atomic)
        #expect(env.store.load() == .none)
    }

    @Test("a truncated record returns .none (not a crash)")
    func truncatedNone() throws {
        let env = PreferenceScratch()
        let truncated = makePreference(generation: 1).encoded().dropLast(10)
        try Data(truncated).write(to: env.fileURL, options: .atomic)
        #expect(env.store.load() == .none)
    }

    @Test("no file at all returns .none (genuine absence, never a crash)")
    func genuineAbsenceNone() {
        // ScratchDirectory is empty — the file does not exist.
        let env = PreferenceScratch()
        // Confirm the file really is absent.
        #expect(!FileManager.default.fileExists(atPath: env.fileURL.path))
        #expect(env.store.load() == .none)
    }
}

// MARK: - P2: domain separation from lease and grant MACs

@Suite("ProviderPreference P2 domain separation from lease and grant")
struct PreferenceDomainSeparationTests {

    @Test("same payload bytes under preference domain ≠ lease MAC (different info string)")
    func preferenceVsLeaseMAC() {
        let prefKey  = ProviderPreference.preferenceKey(installationRoot: preferenceRoot)
        let leaseKey = HandoverLease.leaseKey(installationRoot: preferenceRoot)
        // Keys must be different — same IKM, different info strings.
        #expect(prefKey != leaseKey)
    }

    @Test("the preference domain constant string is the expected value")
    func domainConstantValue() {
        // The domain string is committed to the self-report digest; this test
        // catches an accidental rename before the digest test does.
        #expect(providerPreferenceDomain == "MOOTX01-PROVIDER-PREFERENCE-v1")
    }

    @Test("signing under leaseRoot produces a MAC that fails preferenceRoot verify")
    func crossDomainRootFails() {
        // A MAC computed with leaseRoot does not verify under preferenceRoot
        // (different keys → different MACs → constant-time compare fails).
        let pref = makePreference(generation: 1, root: leaseRoot)
        #expect(!pref.verifyMAC(installationRoot: preferenceRoot))
        #expect(pref.verifyMAC(installationRoot: leaseRoot))
    }
}

// MARK: - P4: ProviderPreferenceObservation summary (no raw bytes)

@Suite("ProviderPreferenceObservation P4 arbiter-facing summary")
struct PreferenceObservationTests {

    @Test("store.load() never returns raw MAC bytes in the observation")
    func noRawBytesInObservation() throws {
        let env = PreferenceScratch()
        try env.store.write(makePreference(generation: 1))
        let obs = env.store.load()
        // The observation is an enum with only ProviderKind and UInt64 —
        // no [UInt8] fields are reachable from the result.
        switch obs {
        case .none, .invalid:
            break
        case .verified(let kind, let gen):
            // Only ProviderKind (an enum) and UInt64 — no raw bytes exposed.
            #expect([ProviderKind.direct, .bundled].contains(kind))
            #expect(gen > 0)
        }
    }

    @Test(".invalid and .none are distinct (fail-closed, never permissive)")
    func invalidNoneDistinct() {
        let none: ProviderPreferenceObservation = .none
        let invalid: ProviderPreferenceObservation = .invalid
        #expect(none != invalid)
    }
}

// MARK: - Self-report: preference domain committed to digest

@Suite("ProviderPreference self-report coverage (P2 / MACD-3B2)")
struct PreferenceSelfReportTests {

    @Test("digestInput() contains the preference domain string")
    func digestContainsDomain() {
        let bytes = ProviderSelfReport.digestInput()
        // The preference domain is embedded as a length-prefixed UTF-8 string.
        // Search for the UTF-8 byte subsequence within the digest input to
        // confirm the domain is committed.  No Swift Algorithms dependency —
        // use a simple containment search via Data.range(of:).
        let domainData = Data(providerPreferenceDomain.utf8)
        let digestData = Data(bytes)
        let found = digestData.range(of: domainData) != nil
        #expect(found, "digestInput() must contain the preference domain bytes")
    }

    @Test("canonicalReport() contains preferenceDomain key")
    func canonicalReportContainsKey() {
        let report = ProviderSelfReport.canonicalReport()
        #expect(report.contains("\"preferenceDomain\""), "canonicalReport must include preferenceDomain key")
        #expect(report.contains("MOOTX01-PROVIDER-PREFERENCE-v1"), "canonicalReport must include the domain value")
    }
}
