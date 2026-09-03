// AdornmentOperationalStatus.swift
//
// Typed host-to-MCP projection for the resident adornment miner. AriaMCP
// deliberately does not import AdornmentLib: the product composition maps its
// concrete engine/lifecycle state into this value at the boundary.

import Foundation

/// Current operating state of the configured adornment miner.
public enum AdornmentMinerState: String, Sendable, Equatable {
    case disabled
    case idle
    case pending
    case blocked
}

/// Operational snapshot appended to `moot_estate_status` when a host provides
/// one. Optional counters stay absent when the miner is disabled or could not
/// be constructed; zero is reserved for a real observed zero.
public struct AdornmentOperationalStatus: Sendable, Equatable {
    public let state: AdornmentMinerState
    public let identity: String?
    public let detail: String?
    public let pendingPairs: Int?
    public let logicalRequests: UInt64?
    public let requestAttempts: UInt64?
    public let processStarts: UInt64?
    public let launchFailures: UInt64?
    public let boundedRecycles: UInt64?
    public let idleReaps: UInt64?
    public let unexpectedExits: UInt64?
    public let crashRetries: UInt64?
    public let perPromptFailures: UInt64?
    public let activeChildren: Int?
    public let requestsInActiveChildren: UInt64?

    public init(
        state: AdornmentMinerState,
        identity: String? = nil,
        detail: String? = nil,
        pendingPairs: Int? = nil,
        logicalRequests: UInt64? = nil,
        requestAttempts: UInt64? = nil,
        processStarts: UInt64? = nil,
        launchFailures: UInt64? = nil,
        boundedRecycles: UInt64? = nil,
        idleReaps: UInt64? = nil,
        unexpectedExits: UInt64? = nil,
        crashRetries: UInt64? = nil,
        perPromptFailures: UInt64? = nil,
        activeChildren: Int? = nil,
        requestsInActiveChildren: UInt64? = nil
    ) {
        self.state = state
        self.identity = identity
        self.detail = detail
        self.pendingPairs = pendingPairs
        self.logicalRequests = logicalRequests
        self.requestAttempts = requestAttempts
        self.processStarts = processStarts
        self.launchFailures = launchFailures
        self.boundedRecycles = boundedRecycles
        self.idleReaps = idleReaps
        self.unexpectedExits = unexpectedExits
        self.crashRetries = crashRetries
        self.perPromptFailures = perPromptFailures
        self.activeChildren = activeChildren
        self.requestsInActiveChildren = requestsInActiveChildren
    }
}

/// Async because the concrete product provider reads actor-owned engine and
/// estate state. The closure is immutable and `Sendable`, matching the other
/// host injection seams on `ToolDispatcher`.
public typealias AdornmentOperationalStatusProvider =
    @Sendable () async -> AdornmentOperationalStatus
