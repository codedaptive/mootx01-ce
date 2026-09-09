// RerankDirective.swift
//
// The cross-encoder portion of a recall strategy decision, carried on the
// recall request. It lives in CorpusKit so GeniusLocusKit (which consumes
// it) and the ARIA surfaces (which will one day construct it) share one
// type. The directive says WHETHER to rerank and WITH WHICH packaged
// profile; it carries no benchmark type, gold answer, expected identifier
// or difficulty guess. An absent directive means bypass.
//
// Mirror: rust/src/encoder/rerank_directive.rs.

import Foundation

/// Whether the recall request asks for cross-encoder reranking.
public struct RerankDirective: Sendable, Equatable, Codable {

    /// The execution contract requested for the stage.  Generic applies retain
    /// the historical best-effort behavior; transcript recall is fail-closed.
    public enum Requirement: String, Sendable, Equatable, Codable {
        case generic = "best_effort"
        case strictTranscript = "strict_transcript"
    }

    /// The requested action.
    public enum Action: String, Sendable, Equatable, Codable {
        /// Leave the recall order as fused; the stage does not run.
        case bypass
        /// Run the pair scorer over the head of the final pool and fuse.
        case apply
    }

    /// Bypass or apply.
    public let action: Action
    /// The packaged profile to apply (`CrossEncoderProfile.modelID`). The
    /// stage degrades with reason `profile_unknown` when it names a profile
    /// this build does not package.
    public let profileID: String
    /// Optional diagnostic code from whoever decided; echoed in the recall
    /// report, never interpreted.
    public let reason: String?
    /// Whether an unavailable stage may degrade or must report unavailability.
    public let requirement: Requirement

    /// Column-style key names, shared with the Rust twin.
    enum CodingKeys: String, CodingKey {
        case action
        case profileID = "profile_id"
        case reason
        case requirement
    }

    /// Build a directive.
    public init(
        action: Action,
        profileID: String,
        reason: String? = nil,
        requirement: Requirement = .generic
    ) {
        self.action = action
        self.profileID = profileID
        self.reason = reason
        self.requirement = requirement
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        action = try values.decode(Action.self, forKey: .action)
        profileID = try values.decode(String.self, forKey: .profileID)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        requirement = try values.decodeIfPresent(Requirement.self, forKey: .requirement) ?? .generic
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(action, forKey: .action)
        try values.encode(profileID, forKey: .profileID)
        try values.encodeIfPresent(reason, forKey: .reason)
        if requirement != .generic {
            try values.encode(requirement, forKey: .requirement)
        }
    }

    /// `apply` with the one qualified profile.
    public static func apply(reason: String? = nil) -> RerankDirective {
        RerankDirective(action: .apply, profileID: CrossEncoderProfile.minilmL6.modelID, reason: reason)
    }

    /// `bypass` with the one qualified profile.
    public static func bypass(reason: String? = nil) -> RerankDirective {
        RerankDirective(action: .bypass, profileID: CrossEncoderProfile.minilmL6.modelID, reason: reason)
    }

    /// The transcript recipe's fail-closed classifier requirement.
    public static func strictTranscript() -> RerankDirective {
        RerankDirective(
            action: .apply,
            profileID: CrossEncoderProfile.minilmL6.modelID,
            requirement: .strictTranscript)
    }
}
