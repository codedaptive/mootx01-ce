// DistillationCycle.swift
//
// Cluster assignment write-path and hourly distillation sweep for
// GeniusLocusKit. Implements the two halves of the distillation cycle
// described in DISTILLATION_DESIGN.md §5:
//
//   1. assignCluster — called by the app layer after every successful
//      capture to assign the new drawer to an existing open cluster
//      (if the nearest stored vector is within Hamming distance ≤ 64)
//      or seed a new single-member cluster.
//
//   2. runDistillationSweep — called by the distillationCycle closure
//      wired into DistillationSignal.spec. Queries open clusters with
//      member_count ≥ 3, runs the injected distillation function on
//      each, and handles the three outcomes: succeeded, held (SNR gate),
//      failed (confidence below threshold).
//
// NeuronKit is NOT a GeniusLocusKit dependency, so the distillation
// function is injected as a closure (DistillationInput → DistillationOutput).
// Both DistillationInput and DistillationOutput are defined in SubstrateML,
// which IS a GeniusLocusKit dependency. Callers at the app layer bridge
// NeuronKit.distillCluster or a test stub.

import EngramLib
import Foundation
import LocusKit
import OSLog
import PersistenceKit
import SubstrateML
import VectorKit

// MARK: - Cluster assignment and distillation sweep

public extension GeniusLocusKit {

    // MARK: - assignCluster

    /// Assign a freshly captured drawer to an existing open cluster or
    /// seed a new single-member cluster.
    ///
    /// Called by the app layer after every successful capture. The `engram`
    /// must already be stored in VectorKit under `modelID` by the capture
    /// flow. VectorKit is queried for the nearest stored vector; if the
    /// nearest neighbor (excluding the new drawer itself) is within Hamming
    /// distance ≤ 64 and belongs to an open cluster, the new drawer joins
    /// that cluster. Otherwise a new cluster is seeded.
    ///
    /// Silently returns when no VectorStore is registered (locus-only estates
    /// do not participate in cluster assignment).
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - engram: binary fingerprint of the captured drawer.
    ///   - drawerID: UUID string of the captured drawer.
    ///   - modelID: embedding model ID under which `engram` is stored
    ///     in VectorKit (the estate's prose embedding model).
    ///   - now: deterministic clock; stamped into `filed_at` / `updated_at`.
    func assignCluster(
        handle: EstateHandle,
        engram: Engram,
        drawerID: String,
        modelID: String,
        now: Date
    ) async throws {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard let vectorStore = vectorStores[handle] else {
            // Locus-only estate — no VectorStore, cluster assignment skipped.
            return
        }

        // Search for nearest prose-lane neighbor; limit=2 in case the new
        // drawer is already indexed and the first match is a self-hit.
        let matches = try await vectorStore.findNearest(
            probe: engram,
            modelID: modelID,
            limit: 2
        )
        let nearestMatch = matches.first { $0.itemID != drawerID }

        var joinedClusterID: String? = nil

        if let nearest = nearestMatch, nearest.distance <= 64 {
            // Nearest neighbor is within the consistency threshold.
            // Check if it belongs to an open cluster.
            joinedClusterID = try await findOpenCluster(
                containing: nearest.itemID,
                storage: storage
            )
        }

        if let clusterID = joinedClusterID {
            try await appendToCluster(
                clusterID: clusterID,
                drawerID: drawerID,
                now: now,
                storage: storage
            )
        } else {
            try await seedCluster(drawerID: drawerID, now: now, storage: storage)
        }
    }

    // MARK: - runDistillationSweep

    /// Query open clusters with member_count ≥ 3 and run the injected
    /// distillation function on each. Returns the count of produced factoids.
    ///
    /// Wired into DistillationSignal.spec(distillationCycle:) via the
    /// closure parameter in registerDefaultStandingSignals. The `distillFn`
    /// closure is provided by the app layer and wraps NeuronKit.distillCluster
    /// (or a test stub) so GeniusLocusKit avoids a NeuronKit dependency.
    ///
    /// Three outcomes per cluster:
    ///   - succeeded (conf ≥ 0.4): capture _distilled drawer, store
    ///     featureFingerprint in VectorKit's distillation lane, write M
    ///     _distilled_from tunnels, mark cluster 'distilled'.
    ///   - held (SNR < 2.0): mark cluster 'held' with reason.
    ///   - failed (conf < 0.4 or pipeline failure): mark cluster 'failed'.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - distillFn: pure distillation function injected by the app layer.
    ///   - now: deterministic clock.
    ///   - clusterID: when non-nil, sweep only the cluster with this UUID.
    ///     When nil (default), sweep all eligible clusters.
    ///   - includeHeld: when true, include clusters with `status = 'held'`
    ///     alongside `status = 'open'` clusters so SNR-gated clusters get
    ///     another distillation attempt now that more members may have arrived.
    ///     Defaults to false (only open clusters are swept).
    /// - Returns: count of factoids produced this sweep.
    func runDistillationSweep(
        handle: EstateHandle,
        distillFn: @escaping @Sendable (DistillationInput) -> DistillationOutput,
        now: Date,
        clusterID: String? = nil,
        includeHeld: Bool = false
    ) async throws -> Int {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard let vectorStore = vectorStores[handle] else {
            return 0
        }
        let estate = try estate(for: handle)

        // Build the status filter: always include 'open'; optionally also
        // 'held' when the caller wants another attempt on SNR-gated clusters.
        let eligibleStatuses: [TypedValue] = includeHeld
            ? [.text("open"), .text("held")]
            : [.text("open")]

        // Build the WHERE clause, optionally narrowing to a single cluster.
        let baseCondition: StoragePredicate = .and([
            .in(Column(table: "memory_clusters", name: "status"), eligibleStatuses),
            .gte(
                Column(table: "memory_clusters", name: "member_count"),
                .int(3)
            )
        ])
        let whereClause: StoragePredicate = if let targetID = clusterID {
            .and([
                baseCondition,
                .eq(Column(table: "memory_clusters", name: "id"), .text(targetID))
            ])
        } else {
            baseCondition
        }

        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: whereClause,
            orderBy: [],
            limit: nil,
            offset: nil
        )

        var factoidCount = 0

        for row in rows {
            guard let clusterID = stringValue(row["id"]) else { continue }
            guard let memberIDsData = jsonData(row["member_ids"]) else { continue }
            guard let memberIDs = try? JSONDecoder().decode(
                [String].self, from: memberIDsData
            ) else { continue }

            // Fetch the content, wing, and room for each member drawer.
            let memberDrawers = try await fetchDrawerRows(ids: memberIDs, storage: storage)
            guard !memberDrawers.isEmpty else { continue }

            let contents = memberDrawers.map { $0.content }
            let timestamps = memberDrawers.compactMap { $0.filedAt }

            let input = DistillationInput(
                memoryContents: contents,
                memoryTimestamps: timestamps.count == contents.count ? timestamps : nil,
                clusterID: clusterID,
                sourceIDs: memberIDs
            )

            let output = distillFn(input)

            if !output.succeeded && output.snr < 2.0 {
                // SNR gate: cluster not dense enough to distill yet.
                try await updateClusterStatus(
                    clusterID: clusterID,
                    status: "held",
                    snr: output.snr,
                    heldReason: output.failureReason ?? "SNR \(output.snr) < 2.0",
                    factoidID: nil,
                    now: now,
                    storage: storage
                )
            } else if output.succeeded && output.confidence >= 0.4 {
                // Success: produce the factoid and link the sources.
                let factoidID = try await captureFactoid(
                    output: output,
                    clusterID: clusterID,
                    estate: estate,
                    memberDrawers: memberDrawers,
                    vectorStore: vectorStore,
                    now: now
                )
                try await updateClusterStatus(
                    clusterID: clusterID,
                    status: "distilled",
                    snr: output.snr,
                    heldReason: nil,
                    factoidID: factoidID,
                    now: now,
                    storage: storage
                )
                factoidCount += 1
            } else {
                // Confidence below threshold or explicit pipeline failure.
                try await updateClusterStatus(
                    clusterID: clusterID,
                    status: "failed",
                    snr: output.snr,
                    heldReason: output.failureReason,
                    factoidID: nil,
                    now: now,
                    storage: storage
                )
            }
        }

        return factoidCount
    }
}

// MARK: - Private cluster storage helpers

private extension GeniusLocusKit {

    /// Search open clusters for one whose member_ids JSON array contains
    /// `drawerID`. Returns the cluster's `id` string if found, nil otherwise.
    func findOpenCluster(
        containing drawerID: String,
        storage: any Storage
    ) async throws -> String? {
        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(
                Column(table: "memory_clusters", name: "status"),
                .text("open")
            ),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        for row in rows {
            guard let data = jsonData(row["member_ids"]),
                  let ids = try? JSONDecoder().decode([String].self, from: data),
                  ids.contains(drawerID)
            else { continue }
            return stringValue(row["id"])
        }
        return nil
    }

    /// Append `drawerID` to an existing cluster and increment member_count.
    /// No-ops if `drawerID` is already in the cluster.
    func appendToCluster(
        clusterID: String,
        drawerID: String,
        now: Date,
        storage: any Storage
    ) async throws {
        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(
                Column(table: "memory_clusters", name: "id"),
                .text(clusterID)
            ),
            orderBy: [], limit: 1, offset: nil
        )
        guard let row = rows.first,
              let data = jsonData(row["member_ids"])
        else { return }
        var ids = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        guard !ids.contains(drawerID) else { return }
        ids.append(drawerID)
        guard let updatedData = try? JSONEncoder().encode(ids) else { return }

        let currentCount = int64Value(row["member_count"]) ?? 0
        _ = try await storage.rowStore.update(
            table: "memory_clusters",
            values: [
                "member_ids": .json(updatedData),
                "member_count": .int(currentCount + 1),
                "updated_at": .timestamp(now)
            ],
            where: .eq(
                Column(table: "memory_clusters", name: "id"),
                .text(clusterID)
            )
        )
    }

    /// Insert a new single-member open cluster row.
    func seedCluster(drawerID: String, now: Date, storage: any Storage) async throws {
        let clusterID = UUID().uuidString
        guard let memberData = try? JSONEncoder().encode([drawerID]) else { return }
        _ = try await storage.rowStore.insert(
            table: "memory_clusters",
            values: [
                "id": .text(clusterID),
                "status": .text("open"),
                "snr": .null,
                "member_ids": .json(memberData),
                "member_count": .int(1),
                "factoid_id": .null,
                "held_reason": .null,
                "filed_at": .timestamp(now),
                "updated_at": .timestamp(now)
            ]
        )
    }

    /// Update a cluster's status, SNR, held_reason, and factoid_id after
    /// a sweep attempt.
    func updateClusterStatus(
        clusterID: String,
        status: String,
        snr: Float32,
        heldReason: String?,
        factoidID: String?,
        now: Date,
        storage: any Storage
    ) async throws {
        let values: [String: TypedValue] = [
            "status": .text(status),
            "snr": .float(Double(snr)),
            "updated_at": .timestamp(now),
            "held_reason": heldReason.map { .text($0) } ?? .null,
            "factoid_id": factoidID.map { .text($0) } ?? .null
        ]
        _ = try await storage.rowStore.update(
            table: "memory_clusters",
            values: values,
            where: .eq(
                Column(table: "memory_clusters", name: "id"),
                .text(clusterID)
            )
        )
    }

    // MARK: - Drawer query helpers

    /// Minimal projection of a drawers row used by the sweep.
    struct DrawerRow: Sendable {
        let id: String
        let content: String
        let wing: String
        let room: String
        let filedAt: Date?
    }

    /// Fetch content, wing, room, and filedAt for the given drawer UUIDs.
    func fetchDrawerRows(ids: [String], storage: any Storage) async throws -> [DrawerRow] {
        guard !ids.isEmpty else { return [] }
        let values = ids.map { TypedValue.text($0) }
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .in(Column(table: "drawers", name: "id"), values),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        return rows.compactMap { row in
            guard
                let id = stringValue(row["id"]),
                let content = stringValue(row["content"]),
                let wing = stringValue(row["wing"]),
                let room = stringValue(row["room"])
            else { return nil }
            return DrawerRow(
                id: id,
                content: content,
                wing: wing,
                room: room,
                filedAt: dateValue(row["filedAt"])
            )
        }
    }

    // MARK: - Factoid capture

    /// Capture the distilled factoid drawer, store its structural fingerprint
    /// in VectorKit's distillation lane, and write M _distilled_from tunnels.
    ///
    /// The factoid is an ordinary drawer in room "_distilled" with
    /// addedBy = "distillation-daemon" per DISTILLATION_DESIGN.md §0.
    /// The lineageID is set to the cluster UUID so recipes can trace a
    /// factoid back to its source cluster.
    ///
    /// Returns the factoid's UUID string.
    func captureFactoid(
        output: DistillationOutput,
        clusterID: String,
        estate: LocusKit.Estate,
        memberDrawers: [DrawerRow],
        vectorStore: VectorStore,
        now: Date
    ) async throws -> String {
        // Derive the estate's wing name from the manifest owner identifier.
        // Mirrors LocusKit.EstateVerbs.defaultWing() (private there).
        let manifest = try await estate.manifest
        let wing = manifest.ownerIdentifier.isEmpty
            ? "wing_default"
            : "wing_\(manifest.ownerIdentifier)"

        let lineageID = UUID(uuidString: clusterID) ?? UUID()

        // Capture the factoid as an ordinary drawer in "_distilled".
        // embeddingModelID = "distillation-features-v1": this is the lane
        // under which VectorKit will store the structural fingerprint below.
        // channel = .actuator: daemon-generated content (cookbook §2.4).
        // sourceType = .derived: inferred from existing content (Provenance §F13).
        // latticeAnchor "001": UDC Knowledge class — appropriate for synthesized
        // knowledge drawers per spec I-5 (udcCode must not be empty).
        let captureFrame = CaptureFrame(
            content: output.drawerContent,
            channel: .actuator,
            room: "_distilled",
            latticeAnchor: LatticeAnchor.udc("001"),
            addedBy: "distillation-daemon",
            embeddingModelID: "distillation-features-v1",
            sourceType: .derived,
            lineageID: lineageID
        )

        let factoid = try await estate.capture(captureFrame)
        let factoidID = factoid.id

        // Store the structural fingerprint in the distillation-features-v1 lane.
        // This is the second VectorKit lane, independent of the prose embedding
        // lane. It enables no-inference Hamming NN via findNearestDistilled.
        try await vectorStore.addVector(
            itemID: factoidID,
            engram: output.featureFingerprint,
            modelID: "distillation-features-v1",
            modelVersion: "1",
            filedAt: now
        )

        // Write M _distilled_from tunnels: factoid → each source drawer.
        // Direction: source = factoid (the synthesis), target = raw memory.
        // originClass = .derived: tunnel relationship inferred by the substrate.
        for sourceDrawer in memberDrawers {
            let tunnelFrame = TunnelCaptureFrame(
                sourceWing: wing,
                sourceRoom: "_distilled",
                targetWing: sourceDrawer.wing,
                targetRoom: sourceDrawer.room,
                label: "_distilled_from",
                addedBy: "distillation-daemon",
                sourceDrawerId: factoidID,
                targetDrawerId: sourceDrawer.id,
                kind: .references,
                originClass: .derived
            )
            _ = try await estate.capture(tunnelFrame)
        }

        return factoidID
    }

    // MARK: - TypedValue extraction helpers

    func stringValue(_ v: TypedValue?) -> String? {
        // Tolerate both forms a string-bearing column can take after a round
        // trip through storage. A column declared `.uuid` (e.g. memory_clusters
        // `id`) is written as `.text` but the SQLite backend's schema-hinted
        // read converts it back to `.uuid` — so a `.text`-only guard silently
        // returns nil for the cluster id on a SQLite estate, which made
        // findOpenCluster report "no cluster" on a real match and every capture
        // seed a fresh singleton (distillation never reached the ≥3 gate). The
        // InMemory backend returns `.text` and hid this. Accept both.
        switch v {
        case .text(let s): return s
        case .uuid(let u): return u.uuidString
        default: return nil
        }
    }

    func int64Value(_ v: TypedValue?) -> Int64? {
        guard case .int(let i) = v else { return nil }
        return i
    }

    func jsonData(_ v: TypedValue?) -> Data? {
        switch v {
        case .json(let d): return d
        case .blob(let d): return d
        default: return nil
        }
    }

    func dateValue(_ v: TypedValue?) -> Date? {
        guard case .timestamp(let d) = v else { return nil }
        return d
    }
}
