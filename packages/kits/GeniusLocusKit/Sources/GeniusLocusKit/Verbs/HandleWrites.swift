import Foundation
import LocusKit

/// Handle-scoped writes for consumers that own estate enrichment and metadata.
/// GLK validates the mount and resolves the handle before invoking the named
/// LocusKit operation. These methods retain the lower operation's semantics;
/// caller-specific sensitivity checks belong to the access surface.
public extension GeniusLocusKit {
    /// Persist one manifest key/value pair through `Estate.setMeta(key:value:)`.
    /// Refuses a stale, quiesced, or draining handle before writing. The owning
    /// consumer supplies its metadata namespace and serialization format.
    func setMeta(in handle: EstateHandle, key: String, value: String) async throws {
        try requireMounted(handle, verb: "setMeta")
        let estate = try estate(for: handle)
        do {
            try await estate.setMeta(key: key, value: value)
        } catch {
            throw remap(verb: "setMeta", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    /// Store a drawer's subject, producer version, and generation timestamp.
    /// Returns the number of updated rows (zero when absent), preserving
    /// `Estate.setSubjectRepresentation(drawerId:subject:pipelineVersion:at:)`
    /// semantics. Refuses stale, quiesced, or draining handles before writing.
    @discardableResult
    func setSubjectRepresentation(
        in handle: EstateHandle,
        drawerId: String,
        subject: String,
        pipelineVersion: String,
        at generatedAt: Date
    ) async throws -> Int {
        try requireMounted(handle, verb: "setSubjectRepresentation")
        let estate = try estate(for: handle)
        do {
            return try await estate.setSubjectRepresentation(
                drawerId: drawerId, subject: subject,
                pipelineVersion: pipelineVersion, at: generatedAt)
        } catch {
            throw remap(verb: "setSubjectRepresentation", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    /// Write or clear one drawer's SSC facts and return the number of rows
    /// updated (zero when absent). Delegates to `Estate.setSSCFacts(_:for:)`.
    /// Refuses a stale, quiesced, or draining handle before writing.
    @discardableResult
    func setSSCFacts(in handle: EstateHandle, _ facts: String?, for drawerId: String) async throws -> Int {
        try requireMounted(handle, verb: "setSSCFacts")
        let estate = try estate(for: handle)
        do {
            return try await estate.setSSCFacts(facts, for: drawerId)
        } catch {
            throw remap(verb: "setSSCFacts", estateID: handle.estateUUID.uuidString, error: error)
        }
    }
}
