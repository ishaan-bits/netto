import Foundation

struct StorageSnapshot: Sendable, Equatable {
    let totalCapacity: Int64
    let availableCapacity: Int64

    /// A failed read yields all zeros — such a snapshot must never be rendered as a
    /// fabricated "0 GB of 0 GB" measurement.
    var isAvailable: Bool { totalCapacity > 0 }

    var usedCapacity: Int64 {
        max(0, totalCapacity - availableCapacity)
    }

    var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(usedCapacity) / Double(totalCapacity)
    }

    var freeFraction: Double {
        max(0, 1 - usedFraction)
    }

    func formattedUsed() -> String {
        ByteFormat.string(usedCapacity)
    }

    func formattedFree() -> String {
        ByteFormat.string(availableCapacity)
    }

    func formattedTotal() -> String {
        ByteFormat.string(totalCapacity)
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 GB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }
}
