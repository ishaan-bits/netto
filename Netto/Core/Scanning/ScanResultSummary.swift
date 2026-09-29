import Foundation

struct ScanResultSummary: Sendable, Equatable {
    let duplicatePhotoGroups: Int
    let similarPhotoGroups: Int
    let screenshotCount: Int
    let largeVideoCount: Int
    let duplicateContactGroups: Int
    let potentialFreedBytes: Int64
    let scannedAssetCount: Int
    let duration: TimeInterval

    var isEmpty: Bool {
        duplicatePhotoGroups == 0
            && similarPhotoGroups == 0
            && screenshotCount == 0
            && largeVideoCount == 0
            && duplicateContactGroups == 0
    }

    static let zero = ScanResultSummary(
        duplicatePhotoGroups: 0,
        similarPhotoGroups: 0,
        screenshotCount: 0,
        largeVideoCount: 0,
        duplicateContactGroups: 0,
        potentialFreedBytes: 0,
        scannedAssetCount: 0,
        duration: 0
    )
}
