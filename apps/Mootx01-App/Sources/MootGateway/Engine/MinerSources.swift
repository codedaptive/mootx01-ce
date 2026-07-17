import Foundation
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Contacts)
import Contacts
#endif

// MARK: - Concrete miner sources  (M-ING-2 Part 2)
//
// Two layers per source, split for testability and TCC hygiene:
//   1. PURE MAPPERS (sample struct → MinedFact) — deterministic, fixture-
//      tested on any host with no permissions.
//   2. LIVE READERS — the only code that touches EventKit/Contacts and thus
//      the only code that can trigger a TCC consent prompt. Never called by
//      tests; first live run happens in an attended session (ruling D6
//      family: no surprise dialogs). HealthKit is iOS-only and lands with
//      the iOS leg — not compiled here.
//
// Subjects encode sample identity (the MinerEngine idempotency contract):
// stable per real-world item, so daily re-mining converges.

/// One calendar event, framework-free.
public struct CalendarEventSample: Sendable, Equatable {
    public let eventID: String
    public let title: String
    public let start: Date
    public init(eventID: String, title: String, start: Date) {
        self.eventID = eventID
        self.title = title
        self.start = start
    }
}

/// One contact birthday, framework-free.
public struct BirthdaySample: Sendable, Equatable {
    public let contactID: String
    public let name: String
    public let month: Int
    public let day: Int
    public init(contactID: String, name: String, month: Int, day: Int) {
        self.contactID = contactID
        self.name = name
        self.month = month
        self.day = day
    }
}

public enum MinerMappers {
    /// calendar.event.<id> — scheduled — "<title> at <ISO8601>"
    public static func fact(_ s: CalendarEventSample) -> MinedFact {
        // Formatter built per call: ISO8601DateFormatter is not Sendable and
        // mapping volume is tiny (daily pulls), so no shared instance.
        MinedFact(
            subject: "calendar.event.\(s.eventID)",
            predicate: "scheduled",
            object: "\(s.title) at \(ISO8601DateFormatter().string(from: s.start))"
        )
    }

    /// contact.birthday.<id> — hasBirthday — "<name> on <MM-DD>"
    public static func fact(_ s: BirthdaySample) -> MinedFact {
        MinedFact(
            subject: "contact.birthday.\(s.contactID)",
            predicate: "hasBirthday",
            object: String(format: "%@ on %02d-%02d", s.name, s.month, s.day)
        )
    }
}

/// Calendar source: injectable reader (fixtures in tests, live in the app).
public struct CalendarMiner: MinerSource {
    public let sourceID = "calendar"
    let reader: @Sendable () async throws -> [CalendarEventSample]
    let statusReader: @Sendable () async -> MinerAuthorizationStatus
    let authorizationRequester: @Sendable () async -> MinerAuthorizationStatus

    public init(
        reader: @escaping @Sendable () async throws -> [CalendarEventSample],
        statusReader: @escaping @Sendable () async -> MinerAuthorizationStatus = { .authorized },
        authorizationRequester: @escaping @Sendable () async -> MinerAuthorizationStatus = { .authorized }
    ) {
        self.reader = reader
        self.statusReader = statusReader
        self.authorizationRequester = authorizationRequester
    }

    public func collect() async throws -> [MinedFact] {
        let status = await authorizationStatus()
        guard status == .authorized else {
            throw MinerSourceError.authorizationRequired(status)
        }
        return try await reader().map(MinerMappers.fact)
    }

    public func authorizationStatus() async -> MinerAuthorizationStatus {
        await statusReader()
    }

    public func requestAuthorization() async -> MinerAuthorizationStatus {
        await authorizationRequester()
    }

    #if canImport(EventKit)
    /// LIVE reader: day-ahead window (now → +7d). First call prompts for
    /// calendar consent — attended sessions only.
    public static func live(daysAhead: Int = 7) -> CalendarMiner {
        let status: @Sendable () async -> MinerAuthorizationStatus = {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .notDetermined: return .notDetermined
            case .authorized, .fullAccess: return .authorized
            case .denied, .restricted, .writeOnly: return .denied
            @unknown default: return .unavailable
            }
        }
        return CalendarMiner(reader: {
            let store = EKEventStore()
            let end = Date().addingTimeInterval(TimeInterval(daysAhead) * 86_400)
            let predicate = store.predicateForEvents(withStart: Date(), end: end, calendars: nil)
            return store.events(matching: predicate).map {
                CalendarEventSample(
                    // calendarItemIdentifier is the deterministic fallback
                    // for recurring events whose eventIdentifier is absent.
                    eventID: $0.eventIdentifier ?? $0.calendarItemIdentifier,
                    title: $0.title ?? "untitled",
                    start: $0.startDate
                )
            }
        }, statusReader: status, authorizationRequester: {
            do {
                _ = try await EKEventStore().requestFullAccessToEvents()
            } catch {
                return .denied
            }
            return await status()
        })
    }
    #endif
}

/// Birthday source: injectable reader, same shape.
public struct BirthdayMiner: MinerSource {
    public let sourceID = "birthdays"
    let reader: @Sendable () async throws -> [BirthdaySample]
    let statusReader: @Sendable () async -> MinerAuthorizationStatus
    let authorizationRequester: @Sendable () async -> MinerAuthorizationStatus

    public init(
        reader: @escaping @Sendable () async throws -> [BirthdaySample],
        statusReader: @escaping @Sendable () async -> MinerAuthorizationStatus = { .authorized },
        authorizationRequester: @escaping @Sendable () async -> MinerAuthorizationStatus = { .authorized }
    ) {
        self.reader = reader
        self.statusReader = statusReader
        self.authorizationRequester = authorizationRequester
    }

    public func collect() async throws -> [MinedFact] {
        let status = await authorizationStatus()
        guard status == .authorized else {
            throw MinerSourceError.authorizationRequired(status)
        }
        return try await reader().map(MinerMappers.fact)
    }

    public func authorizationStatus() async -> MinerAuthorizationStatus {
        await statusReader()
    }

    public func requestAuthorization() async -> MinerAuthorizationStatus {
        await authorizationRequester()
    }

    #if canImport(Contacts)
    /// LIVE reader: all contacts with a birthday. First call prompts for
    /// contacts consent — attended sessions only.
    public static func live() -> BirthdayMiner {
        let status: @Sendable () async -> MinerAuthorizationStatus = {
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .notDetermined: return .notDetermined
            case .authorized: return .authorized
            case .denied, .restricted, .limited: return .denied
            @unknown default: return .unavailable
            }
        }
        return BirthdayMiner(reader: {
            let store = CNContactStore()
            let keys = [CNContactIdentifierKey, CNContactGivenNameKey,
                        CNContactFamilyNameKey, CNContactBirthdayKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var samples: [BirthdaySample] = []
            try store.enumerateContacts(with: request) { contact, _ in
                guard let b = contact.birthday, let m = b.month, let d = b.day else { return }
                samples.append(BirthdaySample(
                    contactID: contact.identifier,
                    name: "\(contact.givenName) \(contact.familyName)"
                        .trimmingCharacters(in: .whitespaces),
                    month: m, day: d
                ))
            }
            return samples
        }, statusReader: status, authorizationRequester: {
            do {
                _ = try await CNContactStore().requestAccess(for: .contacts)
            } catch {
                return .denied
            }
            return await status()
        })
    }
    #endif
}
