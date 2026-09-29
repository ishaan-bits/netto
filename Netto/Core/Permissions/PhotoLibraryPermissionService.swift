import Foundation
import Photos

protocol PhotoLibraryPermissionServicing: Sendable {
    func currentStatus() -> PermissionState
    func requestAccess() async -> PermissionState
}

struct PhotoLibraryPermissionService: PhotoLibraryPermissionServicing {
    func currentStatus() -> PermissionState {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> PermissionState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.map(status)
    }

    static func map(_ status: PHAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .notDetermined
        }
    }
}
