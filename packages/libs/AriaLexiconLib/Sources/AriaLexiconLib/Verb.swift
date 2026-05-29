// Verb.swift
//
// A verb is an action on the data. There are nine, fixed at nine by
// spec invariant I-7; new domain operations compose these rather than
// extending the vocabulary. The verbs partition into three flows by
// who initiates them.

/// One of the nine actions the substrate supports.
public enum Verb: String, CaseIterable, Sendable, Codable {
    case capture
    case reanchor
    case mutate
    case withdraw
    case expunge
    case recall
    case propose
    case associate
    case learn

    /// Who initiates the verb.
    public var flow: Flow {
        switch self {
        case .capture, .reanchor, .mutate, .withdraw, .expunge, .recall:
            return .callerDriven
        case .propose, .associate:
            return .substrateDriven
        case .learn:
            return .groundingDriven
        }
    }
}

/// Who initiates a verb. Caller-driven verbs are invoked synchronously
/// by the application. Substrate-driven verbs are emitted by the Brain
/// layer's standing signals, not called directly. The grounding-driven
/// verb brings authoritative external reference in.
public enum Flow: String, CaseIterable, Sendable, Codable {
    case callerDriven
    case substrateDriven
    case groundingDriven
}
