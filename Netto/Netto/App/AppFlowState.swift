import Foundation

enum AppFlowState: Sendable, Equatable {
    case launching
    case dashboard
    case scanning(ScanProgress)
    case resultsAvailable(ScanResultSummary)
    case review
    case deleting
    case deletionCompleted
    case deletionFailed(String)
}

enum PermissionPrompt: Sendable, Equatable {
    case none
    case photosPrePrompt
    case contactsPrePrompt
    case photosDenied
    case contactsDenied
    case photosLimited
}
