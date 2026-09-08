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

    /// Column-style key names, shared with the Rust twin.
    enum CodingKeys: String, CodingKey {
        case action
        case profileID = "profile_id"
        case reason
    }

    /// Build a directive.
    public init(action: Action, profileID: String, reason: String? = nil) {
        self.action = action
        self.profileID = profileID
        self.reason = reason
    }

    /// `apply` with the one qualified profile.
    public static func apply(reason: String? = nil) -> RerankDirective {
        RerankDirective(action: .apply, profileID: CrossEncoderProfile.minilmL6.modelID, reason: reason)
    }

    /// `bypass` with the one qualified profile.
    public static func bypass(reason: String? = nil) -> RerankDirective {
        RerankDirective(action: .bypass, profileID: CrossEncoderProfile.minilmL6.modelID, reason: reason)
    }
}
