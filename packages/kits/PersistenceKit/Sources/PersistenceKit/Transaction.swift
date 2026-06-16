// Transaction.swift
//
// Transaction protocol per DECISION_STORAGEKIT_DESIGN §5 (Q3).
// Read-committed default. No nested transactions. No savepoints
// in v1.0.

import Foundation

public enum IsolationLevel: Sendable {
    case readCommitted
    case repeatableRead
    case serializable
}

public protocol StorageTransaction: Sendable {
    var rowStore: any RowStore { get }
    var blobStore: any BlobStore { get }
    var auditLog: any AuditLog { get }
}
