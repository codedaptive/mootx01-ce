import GeniusLocusKit

/// One dispatch's `chest_diversity` override (ADR-027 D3). Task-local
/// ownership prevents session bleed and keeps concurrently suspended Swift
/// calls independent, the same shape as `AriaV2Withheld`.
actor AriaV2ChestDiversityCall {
    /// `nil` = not given on this call, the estate preference decides;
    /// `true` / `false` = "on" / "off" was given and overrides it.
    var value: Bool?
    func configure(_ raw: JSONValue?) {
        switch raw {
        case .string("on"): value = true
        case .string("off"): value = false
        default: value = nil   // any other value is ignored, fail-open
        }
    }
}

enum AriaV2ChestDiversity {
    @TaskLocal static var call: AriaV2ChestDiversityCall?

    /// The override for the current call, `nil` when none was given.
    static var value: Bool? { get async { await call?.value } }
}
