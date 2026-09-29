import Foundation

protocol StorageProviding: Sendable {
    func deviceStorage() async -> StorageSnapshot
}

struct SystemStorageProvider: StorageProviding {
    func deviceStorage() async -> StorageSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let home = URL(fileURLWithPath: NSHomeDirectory())
                let keys: Set<URLResourceKey> = [
                    .volumeTotalCapacityKey,
                    .volumeAvailableCapacityForImportantUsageKey,
                ]
                let values = try? home.resourceValues(forKeys: keys)
                let total = Int64(values?.volumeTotalCapacity ?? 0)
                let available = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
                continuation.resume(returning: StorageSnapshot(
                    totalCapacity: total,
                    availableCapacity: max(0, available)
                ))
            }
        }
    }
}
