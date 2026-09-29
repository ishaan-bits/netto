import Foundation

enum PermissionKind: String, Sendable, CaseIterable {
    case photos
    case contacts

    var displayName: String {
        switch self {
        case .photos: return "Photos"
        case .contacts: return "Contacts"
        }
    }
}

enum PermissionState: Sendable, Equatable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    var isUsable: Bool {
        switch self {
        case .authorized, .limited: return true
        case .notDetermined, .denied, .restricted: return false
        }
    }

    var displayName: String {
        switch self {
        case .notDetermined: return "Not requested"
        case .authorized: return "Full access"
        case .limited: return "Limited access"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }
}
