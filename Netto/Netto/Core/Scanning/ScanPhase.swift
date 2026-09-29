import Foundation

enum ScanStage: String, Sendable, Equatable {
    case preparing
    case cataloging
    case fingerprinting
    case grouping
    case analyzingVideos
    case analyzingContacts
    case finalizing
}

struct ScanProgress: Sendable, Equatable {
    let stage: ScanStage
    let completedUnits: Int64
    let totalUnits: Int64

    var fraction: Double {
        guard totalUnits > 0 else { return 0 }
        return Double(completedUnits) / Double(totalUnits)
    }

    var isActive: Bool { totalUnits > 0 && completedUnits < totalUnits }

    static let indeterminate = ScanProgress(stage: .preparing, completedUnits: 0, totalUnits: 0)
}

enum ScanFailure: Error, Sendable, Equatable {
    case photoLibraryUnavailable
    case contactsUnavailable
    case cancelled
    case underlying(String)

    var userMessage: String {
        switch self {
        case .photoLibraryUnavailable:
            return "Photos access is required to scan your library."
        case .contactsUnavailable:
            return "Contacts access is required to scan your contacts."
        case .cancelled:
            return "Scan cancelled."
        case .underlying(let detail):
            return detail
        }
    }
}

enum ScanPhase: Sendable, Equatable {
    case idle
    case scanning(ScanProgress)
    case cancelled
    case completed(ScanResultSummary)
    case empty
    case failed(ScanFailure)

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}
