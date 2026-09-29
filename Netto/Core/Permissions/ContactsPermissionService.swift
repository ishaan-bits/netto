import Foundation
import Contacts

protocol ContactsPermissionServicing: Sendable {
    func currentStatus() -> PermissionState
    func requestAccess() async -> PermissionState
}

struct ContactsPermissionService: ContactsPermissionServicing {
    func currentStatus() -> PermissionState {
        Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    func requestAccess() async -> PermissionState {
        do {
            let granted = try await CNContactStore().requestAccess(for: .contacts)
            return granted ? .authorized : .denied
        } catch {
            return Self.map(CNContactStore.authorizationStatus(for: .contacts))
        }
    }

    static func map(_ status: CNAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        default:
            if #available(iOS 18.0, *), status == .limited {
                return .limited
            }
            return .notDetermined
        }
    }
}
