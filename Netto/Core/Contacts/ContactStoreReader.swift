import Foundation
import Contacts

/// Why a contacts read could not produce records. User-facing wording lives in presentation;
/// this type never carries contact contents.
enum ContactReadError: Error, Sendable, Equatable {
    case accessDenied
    case failed(String)
    case cancelled
}

/// The read seam over contact enumeration. Implementations return lightweight records and
/// never expose `CNContact` to the rest of the app. Read-only by definition — this protocol
/// has no mutation surface whatsoever.
protocol ContactReading: Sendable {
    /// All visible contacts, in a deterministic (identifier-sorted) order.
    func readContacts() async throws -> [ContactRecord]
}

/// iOS 17 Contacts enumeration.
///
/// - Requests only the fields duplicate detection and review need: identifier, given/family
///   name, organization, phones, emails. Nothing else is fetched (no addresses, notes,
///   birthdays, photos, social profiles, …).
/// - `unifyResults` is on, so linked cards surface once under their unified identifier.
/// - Runs inside the calling task (off the main actor — the type is `nonisolated`), checks
///   cancellation between contacts, and returns plain values. The store never escapes this
///   method, so no non-`Sendable` object crosses an actor boundary.
struct ContactStoreReader: ContactReading {
    func readContacts() async throws -> [ContactRecord] {
        let status = ContactsPermissionService.map(
            CNContactStore.authorizationStatus(for: .contacts)
        )
        guard status.isUsable else { throw ContactReadError.accessDenied }

        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: Self.keys())
        request.unifyResults = true

        var records: [ContactRecord] = []
        var sawCancellation = false
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                records.append(Self.record(from: contact))
                if withUnsafeCurrentTask(body: { $0?.isCancelled }) == true {
                    sawCancellation = true
                    stop.pointee = true
                }
            }
        } catch let error as ContactReadError {
            throw error
        } catch {
            throw ContactReadError.failed(
                "Contacts could not be read on this iPhone. Try again in a moment."
            )
        }
        if sawCancellation || Task.isCancelled { throw ContactReadError.cancelled }

        // Deterministic output order independent of the store's own enumeration order.
        records.sort { $0.identifier < $1.identifier }
        return records
    }

    /// `CNContact` → lightweight value. The only point where framework objects become data.
    static func record(from contact: CNContact) -> ContactRecord {
        ContactRecord(
            identifier: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            organizationName: contact.organizationName,
            phoneNumbers: contact.phoneNumbers.map { labeled in
                .phone(label: labeled.label ?? "", value: labeled.value.stringValue)
            },
            emailAddresses: contact.emailAddresses.map { labeled in
                .email(label: labeled.label ?? "", value: labeled.value as String)
            }
        )
    }

    private static func keys() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
    }
}
