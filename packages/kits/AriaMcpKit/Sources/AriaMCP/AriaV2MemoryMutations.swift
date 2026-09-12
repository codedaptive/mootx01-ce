import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit

/// Strict request for the lower `Estate.mutate` authority. The v2 service
/// accepts only mutations that have a source-faithful lower implementation;
/// content and event-time replacement need their own lower verbs before they
/// can become executable here.
public struct AriaV2UpdateMemoryRequest: Sendable {
    public let memoryID: UUID
    public let mutation: String
    public let subject: String?
    public let sensitivity: AriaV2MemorySensitivity?
    public let exportability: AriaV2MemoryExportability?
    public let note: String?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "memory_id", "mutation", "subject", "sensitivity", "exportability", "note", "estate_id",
        ])
        memoryID = try decoder.requireUUID("memory_id")
        mutation = try decoder.requireString("mutation")
        subject = try decoder.optionalString("subject")
        sensitivity = try decoder.optionalString("sensitivity").map {
            try Self.enumValue($0, path: "sensitivity", type: AriaV2MemorySensitivity.self)
        }
        exportability = try decoder.optionalString("exportability").map {
            try Self.enumValue($0, path: "exportability", type: AriaV2MemoryExportability.self)
        }
        note = try decoder.optionalString("note")
        estateID = try decoder.optionalUUID("estate_id")
        try validatePayloadFields()
        try _ = lowerKind()
    }

    func lowerKind() throws -> MutationKind {
        switch mutation {
        case "confirm": return .confirm
        case "reject": return .reject
        case "contest": return .contest
        case "resolve": return .resolve
        case "supersede": return .supersede
        case "revive": return .revive
        case "accept": return .accept
        case "set_subject":
            guard let subject else { throw Self.missing("subject", for: mutation) }
            return .setSubject(try Self.subject(subject))
        case "correct_sensitivity":
            guard let sensitivity else { throw Self.missing("sensitivity", for: mutation) }
            return .correctSensitivity(sensitivity.locusValue)
        case "correct_exportability":
            guard let exportability else { throw Self.missing("exportability", for: mutation) }
            return .correctExportability(exportability.locusValue)
        default:
            throw AriaV2InvalidArgument(
                path: "mutation",
                message: "Unsupported mutation '\(mutation)'.",
                allowed: ["accept", "confirm", "contest", "correct_exportability", "correct_sensitivity", "reject", "resolve", "revive", "set_subject", "supersede"]
            ).jsonRPCError
        }
    }

    private func validatePayloadFields() throws {
        if subject != nil && mutation != "set_subject" {
            throw Self.onlyValid("subject", for: "set_subject")
        }
        if sensitivity != nil && mutation != "correct_sensitivity" {
            throw Self.onlyValid("sensitivity", for: "correct_sensitivity")
        }
        if exportability != nil && mutation != "correct_exportability" {
            throw Self.onlyValid("exportability", for: "correct_exportability")
        }
        if note != nil && mutation == "confirm" {
            throw AriaV2InvalidArgument(
                path: "note",
                message: "'note' is not accepted for mutation 'confirm' because the lower confirmation verb does not persist it."
            ).jsonRPCError
        }
    }
}

public struct AriaV2WithdrawMemoryRequest: Sendable {
    public let memoryID: UUID
    public let reason: String?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["memory_id", "reason", "estate_id"])
        memoryID = try decoder.requireUUID("memory_id")
        reason = try decoder.optionalString("reason")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2EraseMemoryRequest: Sendable {
    public let memoryID: UUID
    public let confirmation: Bool
    public let reason: String?
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["memory_id", "confirmation", "reason", "estate_id"])
        memoryID = try decoder.requireUUID("memory_id")
        confirmation = try decoder.requireBoolean("confirmation")
        guard confirmation else {
            throw AriaV2InvalidArgument(
                path: "confirmation",
                message: "Argument 'confirmation' must be true.",
                correction: "Set confirmation to the boolean true to erase a memory."
            ).jsonRPCError
        }
        reason = try decoder.optionalString("reason")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2ConfirmMemoryRequest: Sendable {
    public let memoryID: UUID
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["memory_id", "estate_id"])
        memoryID = try decoder.requireUUID("memory_id")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2MoveMemoryRequest: Sendable {
    public let memoryID: UUID
    public let wing: String
    public let room: String
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["memory_id", "wing", "room", "estate_id"])
        memoryID = try decoder.requireUUID("memory_id")
        wing = try AriaV2UpdateMemoryRequest.nonEmpty(try decoder.requireString("wing"), path: "wing")
        room = try AriaV2UpdateMemoryRequest.nonEmpty(try decoder.requireString("room"), path: "room")
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2LinkMemoriesRequest: Sendable {
    public let fromID: UUID
    public let toID: UUID
    public let relationship: String
    public let confidence: String?
    public let evidence: String?
    /// False files an ACTIVE edge — the default, because a caller asked for
    /// this link. True files it `.proposed` instead: the adjudication path,
    /// where the caller judged a borderline candidate and records a reviewable
    /// proposal rather than an immediately-active edge. The user settles it
    /// through moot_review_tunnel.
    public let proposed: Bool
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "from_id", "to_id", "relationship", "confidence", "evidence", "proposed", "estate_id",
        ])
        fromID = try decoder.requireUUID("from_id")
        toID = try decoder.requireUUID("to_id")
        guard fromID != toID else {
            throw AriaV2InvalidArgument(path: "to_id", message: "from_id and to_id must differ.").jsonRPCError
        }
        relationship = try AriaV2UpdateMemoryRequest.nonEmpty(try decoder.requireString("relationship"), path: "relationship")
        confidence = try decoder.optionalString("confidence")
        evidence = try decoder.optionalString("evidence")
        proposed = try decoder.optionalBoolean("proposed") ?? false
        estateID = try decoder.optionalUUID("estate_id")
        try _ = lowerKind()
    }

    fileprivate func lowerKind() throws -> TunnelKind {
        switch relationship {
        case "relates", "references": return .references
        case "precedes", "blocks": return .blocks
        case "contradicts": return .contradicts
        case "supports", "validates": return .validates
        case "refines", "elaborates": return .elaborates
        case "exemplifies", "covers": return .covers
        case "extends", "derives_from": return .derivesFrom
        case "supersedes": return .supersedes
        case "responds_to": return .respondsTo
        default:
            throw AriaV2InvalidArgument(
                path: "relationship",
                message: "Unsupported relationship '\(relationship)'.",
                allowed: ["blocks", "contradicts", "covers", "derives_from", "elaborates", "exemplifies", "extends", "precedes", "references", "refines", "relates", "responds_to", "supersedes", "supports", "validates"]
            ).jsonRPCError
        }
    }
}

public struct AriaV2ReviewTunnelRequest: Sendable {
    public enum Decision: String, Sendable {
        case accept
        case reject
        case endorse
    }

    /// The reviewer identity recorded in the review ledger. Defaults to
    /// `"user"`; model reviewers pass their own id (e.g. "claude").
    ///
    /// Edge activation is user-only, so this is the argument the `accept`
    /// gate reads. A model that wants to express a view uses `endorse` or
    /// `reject`, both of which are reopenable; only a user settles an edge.
    public static let userReviewer = "user"

    public let tunnelID: UUID
    public let decision: Decision
    public let note: String?
    public let reviewedBy: String
    public let estateID: UUID?

    /// True when the reviewer is the user rather than a model. Promotion of a
    /// proposal to an active edge requires this; see `Decision.accept`.
    public var isUserReviewer: Bool { reviewedBy == Self.userReviewer }

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(
            arguments, allowedKeys: ["tunnel_id", "decision", "note", "reviewed_by", "estate_id"])
        tunnelID = try decoder.requireUUID("tunnel_id")
        let rawDecision = try decoder.requireString("decision")
        guard let decision = Decision(rawValue: rawDecision) else {
            throw AriaV2InvalidArgument(path: "decision", message: "Unsupported review decision '\(rawDecision)'.", allowed: Decision.all).jsonRPCError
        }
        self.decision = decision
        note = try decoder.optionalString("note")
        reviewedBy = try Self.nonEmptyReviewer(decoder.optionalString("reviewed_by"))
        estateID = try decoder.optionalUUID("estate_id")
        // Edge activation is user-only. Models endorse or reject; neither
        // settles the edge, so a machine can never ratify another machine's
        // inference. Checked at decode so the refusal names the argument.
        guard decision != .accept || reviewedBy == Self.userReviewer else {
            throw AriaV2InvalidArgument(
                path: "reviewed_by",
                message: "Edge activation is user-only: decision 'accept' requires reviewed_by "
                    + "'user'. Model reviewers use 'endorse' or 'reject'.",
                allowed: [Self.userReviewer]).jsonRPCError
        }
    }

    /// An explicitly empty `reviewed_by` is a caller error, not a silent
    /// fallback to the user identity — that would turn a typo into an edge
    /// activation.
    private static func nonEmptyReviewer(_ raw: String?) throws -> String {
        guard let raw else { return userReviewer }
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AriaV2InvalidArgument(
                path: "reviewed_by",
                message: "Argument 'reviewed_by' must be a non-empty string.").jsonRPCError
        }
        return raw
    }
}

private extension AriaV2ReviewTunnelRequest.Decision {
    static let all = ["accept", "endorse", "reject"]
}

/// Direct typed mutation adapter. It never invokes a legacy runner or parses
/// a legacy result. The selected surface supplies the context and is still
/// responsible for registering these operations.
public struct AriaV2MemoryMutations: Sendable {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public let context: AriaV2MemoryOperationContext

    public init(kit: GeniusLocusKit, handle: EstateHandle, context: AriaV2MemoryOperationContext) {
        self.kit = kit
        self.handle = handle
        self.context = context
    }

    public func update(arguments: JSONValue) async throws -> JSONValue { try await update(.init(arguments: arguments)) }
    public func withdraw(arguments: JSONValue) async throws -> JSONValue { try await withdraw(.init(arguments: arguments)) }
    public func erase(arguments: JSONValue) async throws -> JSONValue { try await erase(.init(arguments: arguments)) }
    public func confirm(arguments: JSONValue) async throws -> JSONValue { try await confirm(.init(arguments: arguments)) }
    public func move(arguments: JSONValue) async throws -> JSONValue { try await move(.init(arguments: arguments)) }
    public func link(arguments: JSONValue) async throws -> JSONValue { try await link(.init(arguments: arguments)) }
    public func review(arguments: JSONValue) async throws -> JSONValue { try await review(.init(arguments: arguments)) }

    public func update(_ request: AriaV2UpdateMemoryRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        // Rule: dereference fires for every outcome EXCEPT NotFound.
        // NotFound (absent or above-ceiling) means the caller was never entitled
        // to name this row — no reward trace.  Any other resolution failure
        // (estate not open, coordinator unavailability) still fires the dereference:
        // the caller demonstrated entitlement at recall time, and a backend
        // failure does not revoke it.  The same rule applies if the lower kit
        // then fails after the ceiling is cleared — the entitlement stands.
        let storedID: String
        do {
            storedID = try await gatedStoredMemoryID(request.memoryID)
        } catch is MemoryNotFoundError {
            return notFoundRefusal("moot_update_memory")
        } catch {
            // Non-NotFound resolution failure.  Dereference fires before returning.
            await context.usageLedger.recordDereferenced(
                [request.memoryID], estateID: context.estateID,
                callerID: context.serverIdentity, at: context.now())
            return unavailable("moot_update_memory")
        }
        // Ceiling cleared.  Dereference fires before the lower-kit call so that
        // a write failure unrelated to sensitivity still records the entitlement.
        await context.usageLedger.recordDereferenced(
            [request.memoryID], estateID: context.estateID,
            callerID: context.serverIdentity, at: context.now())
        do {
            try await kit.mutate(handle, .init(
                rowID: storedID,
                kind: try request.lowerKind(),
                payload: request.note
            ))
            return success(tool: "moot_update_memory", data: .object([
                "memory_id": .string(id(request.memoryID)), "mutation": .string(request.mutation),
            ]), text: "Updated memory \(id(request.memoryID)).")
        } catch { return refusal("moot_update_memory", verb: request.mutation, error: error) }
    }

    public func withdraw(_ request: AriaV2WithdrawMemoryRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        // Same rule as update(_:): MemoryNotFoundError → no dereference;
        // any other resolution failure or lower-kit failure → dereference fires.
        let storedID: String
        do {
            storedID = try await gatedStoredMemoryID(request.memoryID)
        } catch is MemoryNotFoundError {
            return notFoundRefusal("moot_withdraw_memory")
        } catch {
            await context.usageLedger.recordDereferenced(
                [request.memoryID], estateID: context.estateID,
                callerID: context.serverIdentity, at: context.now())
            return unavailable("moot_withdraw_memory")
        }
        await context.usageLedger.recordDereferenced(
            [request.memoryID], estateID: context.estateID,
            callerID: context.serverIdentity, at: context.now())
        do {
            try await kit.withdraw(handle, .init(rowID: storedID, reason: request.reason))
            return success(tool: "moot_withdraw_memory", data: .object(["memory_id": .string(id(request.memoryID))]), text: "Withdrew memory \(id(request.memoryID)).")
        } catch { return unavailable("moot_withdraw_memory") }
    }

    public func erase(_ request: AriaV2EraseMemoryRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        do {
            let storedID = try await gatedStoredMemoryID(request.memoryID)
            let expungeOutcome = try await kit.expunge(handle, .init(
                rowID: storedID,
                reason: request.reason ?? "",
                confirmation: request.confirmation
            ), now: context.now())
            // D1: a partial erasure is a COMPLETED operation with a partial verdict,
            // not a failure. isError stays false — the rows that were erased ARE gone.
            // The outcome field uses the closed vocabulary `erased` / `erased_partially`
            // so the caller can branch without parsing the text. D8: ids lowercased.
            let refusedIDs = expungeOutcome.refusedSiblingIDs.map { $0.lowercased() }
            let isPartial = !refusedIDs.isEmpty
            let text = isPartial
                ? "Partially erased memory \(id(request.memoryID)); \(refusedIDs.count) sibling(s) refused by the audit gate."
                : "Erased memory \(id(request.memoryID))."
            return success(tool: "moot_erase_memory", data: .object([
                "memory_id": .string(id(request.memoryID)),
                "outcome": .string(isPartial ? "erased_partially" : "erased"),
                "refused_sibling_memory_ids": .array(refusedIDs.map { .string($0) }),
            ]), text: text)
        } catch is MemoryNotFoundError {
            return notFoundRefusal("moot_erase_memory")
        } catch { return unavailable("moot_erase_memory") }
    }

    public func confirm(_ request: AriaV2ConfirmMemoryRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        // Same rule as update(_:): MemoryNotFoundError → no dereference;
        // any other resolution failure or lower-kit failure → dereference fires.
        let storedID: String
        do {
            storedID = try await gatedStoredMemoryID(request.memoryID)
        } catch is MemoryNotFoundError {
            return notFoundRefusal("moot_confirm_memory")
        } catch {
            await context.usageLedger.recordDereferenced(
                [request.memoryID], estateID: context.estateID,
                callerID: context.serverIdentity, at: context.now())
            return unavailable("moot_confirm_memory")
        }
        await context.usageLedger.recordDereferenced(
            [request.memoryID], estateID: context.estateID,
            callerID: context.serverIdentity, at: context.now())
        do {
            try await kit.mutate(handle, .init(rowID: storedID, kind: .confirm))
            return success(tool: "moot_confirm_memory", data: .object([
                "memory_id": .string(id(request.memoryID)), "mutation": .string("confirm"),
            ]), text: "Confirmed memory \(id(request.memoryID)).")
        } catch { return unavailable("moot_confirm_memory") }
    }

    public func move(_ request: AriaV2MoveMemoryRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        // Same rule as update(_:): MemoryNotFoundError → no dereference;
        // any other resolution failure or lower-kit failure → dereference fires.
        let storedID: String
        do {
            storedID = try await gatedStoredMemoryID(request.memoryID)
        } catch is MemoryNotFoundError {
            return notFoundRefusal("moot_move_memory")
        } catch {
            await context.usageLedger.recordDereferenced(
                [request.memoryID], estateID: context.estateID,
                callerID: context.serverIdentity, at: context.now())
            return unavailable("moot_move_memory")
        }
        await context.usageLedger.recordDereferenced(
            [request.memoryID], estateID: context.estateID,
            callerID: context.serverIdentity, at: context.now())
        do {
            try await kit.reanchor(handle, .init(rowID: storedID, toRoom: request.room, toWing: request.wing))
            return success(tool: "moot_move_memory", data: .object([
                "memory_id": .string(id(request.memoryID)),
                "placement": .object(["wing": .string(request.wing), "room": .string(request.room)]),
            ]), text: "Moved memory \(id(request.memoryID)).")
        } catch { return unavailable("moot_move_memory") }
    }

    public func link(_ request: AriaV2LinkMemoriesRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        do {
            // Gate both endpoints through the sensitivity ceiling before writing any edge.
            // An absent or above-ceiling endpoint refuses with notFoundRefusal so the
            // caller cannot distinguish the two cases (oracle-closure). The proposed
            // path is gated identically — a proposed edge to a restricted row is refused
            // exactly like an active one. gatedDrawer returns a fully-hydrated Drawer so
            // parentNodeId is available for placement without a second estate call.
            let source = try await gatedDrawer(request.fromID)
            let target = try await gatedDrawer(request.toID)
            let estate = try await kit.estate(for: handle)
            let names = try await estate.resolveNodeNames(parentNodeIds: [source.parentNodeId, target.parentNodeId])
            guard let sourcePlacement = names[source.parentNodeId], let targetPlacement = names[target.parentNodeId] else {
                return unavailable("moot_link_memories")
            }
            let tunnel = try await estate.capture(.init(
                sourceWing: sourcePlacement.wing, sourceRoom: sourcePlacement.room,
                targetWing: targetPlacement.wing, targetRoom: targetPlacement.room,
                label: request.evidence ?? request.relationship, addedBy: context.serverIdentity,
                sourceDrawerId: source.id, targetDrawerId: target.id,
                kind: try request.lowerKind(), originClass: .derived,
                // Active unless the caller asked for the adjudication path.
                lifecycle: request.proposed ? .proposed : .active
            ))
            guard let tunnelID = UUID(uuidString: tunnel.id) else { return unavailable("moot_link_memories") }
            return success(tool: "moot_link_memories", data: .object([
                "tunnel_id": .string(id(tunnelID)), "from_id": .string(id(request.fromID)),
                "to_id": .string(id(request.toID)), "kind": .string(request.relationship),
                // The caller must be able to tell an active edge from a
                // proposal it just filed, without a second read.
                "lifecycle": .string(request.proposed ? "proposed" : "active"),
            ]), text: request.proposed
                ? "Proposed a link between memories \(id(request.fromID)) and \(id(request.toID)); review it with moot_review_tunnel."
                : "Linked memories \(id(request.fromID)) and \(id(request.toID)).")
        } catch is MemoryNotFoundError {
            // An absent or above-ceiling endpoint (oracle-closure: both produce the
            // same refusal so neither can be distinguished from the other).
            return notFoundRefusal("moot_link_memories")
        } catch { return unavailable("moot_link_memories") }
    }

    public func review(_ request: AriaV2ReviewTunnelRequest) async throws -> JSONValue {
        try validateEstate(request.estateID)
        let tunnelID = id(request.tunnelID)
        do {
            let estate = try await kit.estate(for: handle)
            var storedTunnel: Tunnel?
            for candidate in AriaV2ArgumentDecoder.storageIdentitySpellings(request.tunnelID) where storedTunnel == nil {
                storedTunnel = try await estate.getTunnel(id: candidate)
            }
            // Two-part tunnel sensitivity gate (mirrors loadTunnels / visibleTunnels):
            // refuse when the tunnel's own sensitivity exceeds the ceiling, and refuse
            // when a known far-endpoint drawer exceeds the ceiling. A nil far endpoint
            // passes through (room-level connection, no drawer to check). A nonexistent
            // tunnel (storedTunnel == nil) is not gated here — the lower call throws
            // and the outer catch returns unavailable, which is byte-identical to the
            // above-ceiling refusal: both are mutation_unavailable.
            if let tunnel = storedTunnel {
                guard tunnel.adjectiveSensitivity.rawValue <= context.maximumSensitivity.rawValue else {
                    return unavailable("moot_review_tunnel")
                }
                let endpointIDs = [tunnel.sourceDrawerId, tunnel.targetDrawerId].compactMap { $0 }
                if !endpointIDs.isEmpty {
                    let endpoints = (try? await estate.getDrawers(ids: endpointIDs, hydrationLevel: .bitmapOnly)) ?? []
                    if endpoints.contains(where: { $0.adjectiveSensitivity.rawValue > context.maximumSensitivity.rawValue }) {
                        return unavailable("moot_review_tunnel")
                    }
                }
            }
            let storedTunnelID = storedTunnel?.id ?? request.tunnelID.uuidString
            let label = storedTunnel?.label ?? ""
            switch request.decision {
            case .endorse:
                let outcome = try await kit.endorseTunnel(in: handle, tunnelID: storedTunnelID, endorserID: request.reviewedBy, tierLens: tierLens(for: label), now: context.now())
                return success(tool: "moot_review_tunnel", data: .object([
                    "tunnel_id": .string(tunnelID), "new_endorser": .bool(outcome.newEndorser),
                    "distinct_endorsers": .integer(Int64(outcome.distinctEndorsers)), "contested": .bool(outcome.contested),
                ]), text: "Endorsed tunnel \(tunnelID).")
            case .reject where !request.isUserReviewer:
                // A MODEL rejection is an objection, not a verdict. It withdraws
                // only when no model endorsement stands; otherwise the tunnel
                // stays `.proposed` and is marked contested so the user sees a
                // disputed proposal rather than a silently buried one. Routing
                // this to respondToTunnel would give a machine the permanence of
                // a user rejection, whose pairs are never re-proposed.
                let outcome = try await kit.objectToTunnel(
                    in: handle, tunnelID: storedTunnelID, reviewerID: request.reviewedBy,
                    tierLens: tierLens(for: label), now: context.now())
                return success(tool: "moot_review_tunnel", data: .object([
                    "tunnel_id": .string(tunnelID), "withdrawn": .bool(outcome.withdrawn),
                    "contested": .bool(outcome.contested),
                ]), text: "Recorded an objection to tunnel \(tunnelID).")
            case .accept, .reject:
                // User verdicts only: `accept` is gated at decode, and a user
                // `reject` withdraws permanently — those pairs are never
                // re-proposed.
                try await estate.respondToTunnel(id: storedTunnelID, accept: request.decision == .accept, changedBy: request.reviewedBy, reason: request.note)
                return success(tool: "moot_review_tunnel", data: .object([
                    "tunnel_id": .string(tunnelID), "withdrawn": .bool(request.decision == .reject), "contested": .bool(false),
                ]), text: "Reviewed tunnel \(tunnelID).")
            }
        } catch { return unavailable("moot_review_tunnel") }
    }

    private func validateEstate(_ requested: UUID?) throws {
        guard (requested == nil || requested == context.estateID), context.estateID == handle.estateUUID else {
            throw AriaV2InvalidArgument(code: "estate_unavailable", path: "estate_id", message: "The selected estate is unavailable.").jsonRPCError
        }
    }

    /// Sentinel thrown when a memory is absent or above the caller's sensitivity
    /// ceiling. The caller sees a uniform `memory_not_found` refusal for both
    /// cases so neither can oracle the other.
    private struct MemoryNotFoundError: Error {}

    /// Resolve the physical storage ID through a sensitivity ceiling check.
    /// Delegates to `gatedDrawer` and returns the stored ID spelling.
    private func gatedStoredMemoryID(_ memoryID: UUID) async throws -> String {
        try await gatedDrawer(memoryID).id
    }

    /// Returns the `Drawer` whose stored identity matches `memoryID` and whose
    /// sensitivity adjective is at or below the caller's ceiling.
    /// Throws `MemoryNotFoundError` for absent IDs and for above-ceiling IDs alike
    /// (oracle-closure: the two cases are indistinguishable to the caller).
    ///
    /// Uses the lifecycle-agnostic `getDrawers(ids:hydrationLevel:)` — not
    /// `getDrawers(ids:matchingFrame:)` — so that write operations on
    /// non-active rows (e.g. reject on contested, confirm on active, withdraw
    /// on any state) are not excluded by lifecycle filters. Only the sensitivity
    /// adjective is gated here; lifecycle validity is enforced by the lower kit.
    ///
    /// `.structured` hydration is used (not `.bitmapOnly`) so that `parentNodeId`
    /// is available when the caller needs it for placement (e.g. `link`).
    /// This is the ONLY ceiling check for MEMORY target resolution — both
    /// `gatedStoredMemoryID` and `link` route through here. The `review` function
    /// applies its own separate two-part TUNNEL rule (Part 1: the tunnel's own
    /// sensitivity; Part 2: each far-endpoint drawer's sensitivity), mirroring
    /// `loadTunnels`. Those checks live in `review` and do not go through this
    /// helper.
    private func gatedDrawer(_ memoryID: UUID) async throws -> Drawer {
        let candidates = AriaV2ArgumentDecoder.storageIdentitySpellings(memoryID)
        let estate = try await kit.estate(for: handle)
        let rows = try await estate.getDrawers(ids: candidates, hydrationLevel: .structured)
        guard let match = rows.first(where: {
            AriaV2ArgumentDecoder.matchingStorageIdentity(memoryID, among: [$0.id]) != nil
        }) else {
            throw MemoryNotFoundError()
        }
        // Above-ceiling rows are treated as absent so the caller cannot
        // distinguish a restricted row from a missing one (oracle-closure).
        guard match.adjectiveSensitivity.rawValue <= context.maximumSensitivity.rawValue else {
            throw MemoryNotFoundError()
        }
        return match
    }

    private func success(tool: String, data: JSONValue, text: String) -> JSONValue {
        AriaV2Envelope.success(tool: tool, effect: .write, data: data, meta: ["completeness": .string("incomplete")], compactText: text)
    }

    private func unavailable(_ tool: String) -> JSONValue {
        AriaV2Envelope.refusal(tool: tool, error: .init(code: "mutation_unavailable", message: "The requested mutation is unavailable in the selected estate.", retryable: false))
    }

    /// Returned when a memory ID resolves to nothing admissible — either absent
    /// or above the caller's sensitivity ceiling. The wording is identical in
    /// both cases so the caller cannot oracle which condition applies.
    private func notFoundRefusal(_ tool: String) -> JSONValue {
        AriaV2Envelope.refusal(tool: tool, error: .init(
            code: "memory_not_found",
            message: "No authorized memory matched the requested reference.",
            retryable: false))
    }

    /// A GATE REFUSAL is the estate saying no for a stated reason the caller
    /// can act on — "cannot reject an active memory; contest or withdraw it
    /// first" — and it is not the same thing as the estate being unavailable.
    /// Collapsing both into one message leaves the caller with no idea whether
    /// to change the call or give up.
    ///
    /// The phrase comes from the same translator the v1 surface used, which was
    /// private to ToolDispatcher and therefore unreachable from here. When the
    /// error is not a recognised gate transition nothing is invented: it falls
    /// through to the generic refusal, so an internal failure never leaks its
    /// wording to a caller.
    private func refusal(_ tool: String, verb: String, error: any Error) -> JSONValue {
        guard let phrase = ToolDispatcher.describeGateRejection(
            verb: verb, reason: String(describing: error)) else {
            return unavailable(tool)
        }
        return AriaV2Envelope.refusal(
            tool: tool,
            error: .init(code: "gate_refused", message: phrase, retryable: false))
    }

    private func id(_ value: UUID) -> String { AriaV2ArgumentDecoder.canonicalUUID(value) }

    private func tierLens(for label: String) -> ContradictionTier {
        if label.hasPrefix("dcp: ") { return .typedProven }
        if label.hasPrefix("tier2:") { return .lexicalStructural }
        return .lexicalValue
    }
}

fileprivate extension AriaV2UpdateMemoryRequest {
    static func nonEmpty(_ value: String, path: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AriaV2InvalidArgument(path: path, message: "Argument '\(path)' must not be empty.").jsonRPCError
        }
        return trimmed
    }

    static func subject(_ value: String) throws -> String {
        guard value.unicodeScalars.count <= DrawerStore.subjectLengthContract else {
            throw AriaV2InvalidArgument(path: "subject", message: "Argument 'subject' exceeds the subject length contract.").jsonRPCError
        }
        let result = try nonEmpty(value, path: "subject")
        return result
    }

    static func enumValue<T: RawRepresentable>(_ value: String, path: String, type: T.Type) throws -> T where T.RawValue == String {
        guard let result = T(rawValue: value) else {
            throw AriaV2InvalidArgument(path: path, message: "Unsupported \(path) '\(value)'.").jsonRPCError
        }
        return result
    }

    static func missing(_ field: String, for mutation: String) -> JSONRPCError {
        AriaV2InvalidArgument(path: field, message: "mutation '\(mutation)' requires '\(field)'.").jsonRPCError
    }

    static func onlyValid(_ field: String, for mutation: String) -> JSONRPCError {
        AriaV2InvalidArgument(path: field, message: "'\(field)' is only valid for mutation '\(mutation)'.").jsonRPCError
    }
}
