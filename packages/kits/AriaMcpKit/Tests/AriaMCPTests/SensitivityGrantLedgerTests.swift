import Testing
import Foundation
import LocusKit
@testable import AriaMCP

/// ADR-025 sensitivity unlock — the Grant Ledger. Fixed-timezone `Calendar`
/// injected everywhere a local-midnight boundary matters, so these tests are
/// deterministic regardless of the machine's timezone.
@Suite("SensitivityGrantLedger (ADR-025)")
struct SensitivityGrantLedgerTests {

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    // MARK: - Restricted: grant → visible → midnight expiry → redacted again

    @Test("restricted grant is live immediately after granting")
    func restrictedGrantIsLiveImmediately() async {
        let ledger = SensitivityGrantLedger()
        let now = date("2026-07-04T15:00:00Z")
        await ledger.grantRestricted(now: now, calendar: utcCalendar)
        #expect(await ledger.isRestrictedGranted(now: now))
    }

    @Test("restricted grant expires at the next local midnight, not before")
    func restrictedGrantExpiresAtNextMidnight() async {
        let ledger = SensitivityGrantLedger()
        let grantedAt = date("2026-07-04T15:00:00Z")
        await ledger.grantRestricted(now: grantedAt, calendar: utcCalendar)

        let justBeforeMidnight = date("2026-07-04T23:59:59Z")
        #expect(await ledger.isRestrictedGranted(now: justBeforeMidnight),
                "grant must still be live one second before midnight")

        let atMidnight = date("2026-07-05T00:00:00Z")
        #expect(!(await ledger.isRestrictedGranted(now: atMidnight)),
                "grant must be expired exactly at the next local midnight")

        let wellAfterMidnight = date("2026-07-05T09:00:00Z")
        #expect(!(await ledger.isRestrictedGranted(now: wellAfterMidnight)))
    }

    @Test("a restricted grant issued exactly at midnight lasts the full following day")
    func restrictedGrantAtMidnightLastsFullDay() async {
        let ledger = SensitivityGrantLedger()
        let grantedAt = date("2026-07-04T00:00:00Z")
        await ledger.grantRestricted(now: grantedAt, calendar: utcCalendar)
        #expect(await ledger.isRestrictedGranted(now: date("2026-07-04T23:59:59Z")))
        #expect(!(await ledger.isRestrictedGranted(now: date("2026-07-05T00:00:00Z"))))
    }

    // MARK: - Secret: fixed 30-minute grant, not sliding

    @Test("secret grant is live immediately after granting")
    func secretGrantIsLiveImmediately() async {
        let ledger = SensitivityGrantLedger()
        let now = date("2026-07-04T15:00:00Z")
        await ledger.grantSecret(now: now)
        #expect(await ledger.isSecretGranted(now: now))
    }

    @Test("secret grant expires exactly 30 minutes after the grant moment")
    func secretGrantExpiresAfter30Minutes() async {
        let ledger = SensitivityGrantLedger()
        let grantedAt = date("2026-07-04T15:00:00Z")
        await ledger.grantSecret(now: grantedAt)

        #expect(await ledger.isSecretGranted(now: grantedAt.addingTimeInterval(29 * 60)),
                "must still be live at 29 minutes")
        #expect(!(await ledger.isSecretGranted(now: grantedAt.addingTimeInterval(30 * 60))),
                "must be expired at exactly 30 minutes")
    }

    @Test("secret grant is FIXED, not sliding — a read under grant does not extend it")
    func secretGrantIsFixedNotSliding() async {
        let ledger = SensitivityGrantLedger()
        let grantedAt = date("2026-07-04T15:00:00Z")
        await ledger.grantSecret(now: grantedAt)

        // Simulate reads at 10 and 20 minutes in — neither is a re-grant call,
        // so checking liveness at those times must not itself extend anything.
        _ = await ledger.isSecretGranted(now: grantedAt.addingTimeInterval(10 * 60))
        _ = await ledger.isSecretGranted(now: grantedAt.addingTimeInterval(20 * 60))

        #expect(!(await ledger.isSecretGranted(now: grantedAt.addingTimeInterval(31 * 60))),
                "reads under the grant must never extend its fixed expiry")
    }

    // MARK: - Tier independence

    @Test("granting one tier does not grant the other")
    func tiersAreIndependent() async {
        let ledger = SensitivityGrantLedger()
        let now = date("2026-07-04T15:00:00Z")
        await ledger.grantRestricted(now: now, calendar: utcCalendar)
        #expect(await ledger.isRestrictedGranted(now: now))
        #expect(!(await ledger.isSecretGranted(now: now)), "secret must remain ungranted")

        let ledger2 = SensitivityGrantLedger()
        await ledger2.grantSecret(now: now)
        #expect(await ledger2.isSecretGranted(now: now))
        #expect(!(await ledger2.isRestrictedGranted(now: now)), "restricted must remain ungranted")
    }

    @Test("both tiers can be live simultaneously, independently timed")
    func bothTiersLiveSimultaneously() async {
        let ledger = SensitivityGrantLedger()
        let now = date("2026-07-04T15:00:00Z")
        await ledger.grantRestricted(now: now, calendar: utcCalendar)
        await ledger.grantSecret(now: now)
        #expect(await ledger.isRestrictedGranted(now: now))
        #expect(await ledger.isSecretGranted(now: now))

        // Secret expires first (30 min); restricted persists until midnight.
        let after31Min = now.addingTimeInterval(31 * 60)
        #expect(!(await ledger.isSecretGranted(now: after31Min)))
        #expect(await ledger.isRestrictedGranted(now: after31Min))
    }

    // MARK: - lock() drops everything immediately

    @Test("lock drops both tiers immediately, regardless of individual expiry")
    func lockDropsBothTiersImmediately() async {
        let ledger = SensitivityGrantLedger()
        let now = date("2026-07-04T15:00:00Z")
        await ledger.grantRestricted(now: now, calendar: utcCalendar)
        await ledger.grantSecret(now: now)
        await ledger.lock()
        #expect(!(await ledger.isRestrictedGranted(now: now)))
        #expect(!(await ledger.isSecretGranted(now: now)))
    }

    // MARK: - Fail-closed defaults

    @Test("a fresh ledger starts fully locked (fail closed)")
    func freshLedgerStartsLocked() async {
        let ledger = SensitivityGrantLedger()
        let now = date("2026-07-04T15:00:00Z")
        #expect(!(await ledger.isRestrictedGranted(now: now)))
        #expect(!(await ledger.isSecretGranted(now: now)))
        #expect(await ledger.liveTier(now: now) == nil)
        #expect(await ledger.ceilingFilter(now: now) == nil)
    }

    // MARK: - "Restart = locked" (daemon RAM state only)

    @Test("a new ledger instance (simulating daemon restart) is fully locked even after a prior grant")
    func newLedgerInstanceSimulatesRestartLocked() async {
        let ledger1 = SensitivityGrantLedger()
        let now = date("2026-07-04T15:00:00Z")
        await ledger1.grantSecret(now: now)
        #expect(await ledger1.isSecretGranted(now: now))

        // A daemon restart constructs a brand-new ToolDispatcher, hence a
        // brand-new ledger — there is no persistence path back to ledger1.
        let ledger2 = SensitivityGrantLedger()
        #expect(!(await ledger2.isSecretGranted(now: now)),
                "a fresh ledger instance must never see a prior instance's grants")
    }

    // MARK: - ceilingFilter / liveTier

    @Test("ceilingFilter is nil when nothing is granted")
    func ceilingFilterNilWhenUngranted() async {
        let ledger = SensitivityGrantLedger()
        #expect(await ledger.ceilingFilter(now: date("2026-07-04T15:00:00Z")) == nil)
    }

    @Test("ceilingFilter is sensitivityAtMost(.restricted) when only restricted is live")
    func ceilingFilterRestrictedTier() async {
        let ledger = SensitivityGrantLedger()
        let now = date("2026-07-04T15:00:00Z")
        await ledger.grantRestricted(now: now, calendar: utcCalendar)
        #expect(await ledger.liveTier(now: now) == .restricted)
        guard case .sensitivityAtMost(.restricted) = await ledger.ceilingFilter(now: now) else {
            Issue.record("expected sensitivityAtMost(.restricted)"); return
        }
    }

    @Test("ceilingFilter is sensitivityAtMost(.secret) when secret is live, even alongside restricted")
    func ceilingFilterSecretTierWins() async {
        let ledger = SensitivityGrantLedger()
        let now = date("2026-07-04T15:00:00Z")
        await ledger.grantRestricted(now: now, calendar: utcCalendar)
        await ledger.grantSecret(now: now)
        #expect(await ledger.liveTier(now: now) == .secret)
        guard case .sensitivityAtMost(.secret) = await ledger.ceilingFilter(now: now) else {
            Issue.record("expected sensitivityAtMost(.secret) — the wider tier"); return
        }
    }
}
