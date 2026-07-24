import Foundation

public enum StorageHealth: Sendable, Equatable {
    case healthy
    case empty
    case readFailed(String)
    case decodeFailed(String)
    case writeFailed(String)

    public var isFailure: Bool {
        switch self {
        case .readFailed, .decodeFailed, .writeFailed: return true
        case .healthy, .empty: return false
        }
    }
}

public struct StorageDiagnostic: Sendable, Equatable {
    public let health: StorageHealth
    public let location: String
    public let byteCount: Int
    public let lastSavedAt: Date?
    public let backupLocation: String?

    public init(
        health: StorageHealth,
        location: String,
        byteCount: Int = 0,
        lastSavedAt: Date? = nil,
        backupLocation: String? = nil
    ) {
        self.health = health
        self.location = location
        self.byteCount = byteCount
        self.lastSavedAt = lastSavedAt
        self.backupLocation = backupLocation
    }
}
