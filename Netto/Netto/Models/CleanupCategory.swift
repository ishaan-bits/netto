import Foundation

enum CleanupCategory: String, CaseIterable, Sendable, Identifiable {
    case duplicatePhotos
    case similarPhotos
    case screenshots
    case largeVideos
    case duplicateContacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicatePhotos: return "Duplicates"
        case .similarPhotos: return "Similar"
        case .screenshots: return "Screenshots"
        case .largeVideos: return "Large Videos"
        case .duplicateContacts: return "Contacts"
        }
    }

    var systemImage: String {
        switch self {
        case .duplicatePhotos: return "photo.on.photo"
        case .similarPhotos: return "photo.stack"
        case .screenshots: return "camera.viewfinder"
        case .largeVideos: return "video"
        case .duplicateContacts: return "person.2"
        }
    }
}
