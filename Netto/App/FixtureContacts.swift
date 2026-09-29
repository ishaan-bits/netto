import Foundation
import Contacts

#if DEBUG

/// Deterministic, personal-data-free contact fixtures — previews, tests, and simulator
/// validation only. Names are invented, emails use the reserved `example.com` domain, and
/// phones use the reserved fictional `+1 555 010-xxxx` range: nothing here is a real person.
///
/// The set deliberately contains four likely-duplicate groups (shared phone in strict and
/// national formats, shared email, shared name + organization), two unrelated singles, and
/// one record with no grouping-relevant field at all.
enum ContactFixture {
    static let records: [ContactRecord] = [
        // Group 1 — same phone, different formatting (strict international match).
        ContactRecord(
            identifier: "fixture-contact-01",
            givenName: "Mara",
            familyName: "Voss",
            phoneNumbers: [.phone(label: "mobile", value: "+1 (555) 010-1234")],
            emailAddresses: [.email(label: "home", value: "mara.voss@example.com")]
        ),
        ContactRecord(
            identifier: "fixture-contact-02",
            givenName: "Mara",
            familyName: "Voss",
            phoneNumbers: [.phone(label: "work", value: "+1 555 010 1234")],
            emailAddresses: [.email(label: "home", value: "m.voss@example.com")]
        ),
        // Group 2 — same phone via the national-format tolerance rule.
        ContactRecord(
            identifier: "fixture-contact-03",
            givenName: "Iris",
            familyName: "Vale",
            phoneNumbers: [.phone(label: "mobile", value: "+15550107777")]
        ),
        ContactRecord(
            identifier: "fixture-contact-04",
            givenName: "Iris",
            familyName: "Vale",
            phoneNumbers: [.phone(label: "mobile", value: "(555) 010-7777")]
        ),
        // Group 3 — same email across differently-spelled names.
        ContactRecord(
            identifier: "fixture-contact-05",
            givenName: "Owen",
            familyName: "Blake",
            organizationName: "Brightlabs",
            emailAddresses: [.email(label: "work", value: "owen.blake@example.com")]
        ),
        ContactRecord(
            identifier: "fixture-contact-06",
            givenName: "O.",
            familyName: "Blake",
            organizationName: "Brightlabs",
            emailAddresses: [.email(label: "work", value: "owen.blake@example.com")]
        ),
        // Group 4 — same name + organization, no shared phone or email.
        ContactRecord(
            identifier: "fixture-contact-07",
            givenName: "Tess",
            familyName: "Rivera",
            organizationName: "Brightlabs",
            phoneNumbers: [.phone(label: "mobile", value: "+1 555 010 4242")]
        ),
        ContactRecord(
            identifier: "fixture-contact-08",
            givenName: "Tess",
            familyName: "Rivera",
            organizationName: "Brightlabs",
            phoneNumbers: [.phone(label: "mobile", value: "+1 555 010 9999")]
        ),
        // Unrelated singles — must never appear in any group.
        ContactRecord(
            identifier: "fixture-contact-09",
            givenName: "Jules",
            familyName: "Marion",
            phoneNumbers: [.phone(label: "mobile", value: "+1 555 010 0101")],
            emailAddresses: [.email(label: "home", value: "jules@example.com")]
        ),
        ContactRecord(
            identifier: "fixture-contact-10",
            givenName: "Ren",
            familyName: "Otis",
            organizationName: "Otis & Co",
            phoneNumbers: [.phone(label: "work", value: "+1 555 010 0202")]
        ),
        // No name, no org, no phone, no email — excluded from every index.
        ContactRecord(identifier: "fixture-contact-11"),
    ]

    /// The four groups the fixture set must produce, in detector order.
    static let expectedGroupCount = 4
}

/// Serves `ContactFixture.records` instead of the real store — previews, tests, and the
/// `-fixtureContacts` launch argument. Read-only; mutation over fixture identifiers fails the
/// real backing's existence revalidation with zero mutation (exactly like `-fixtureLibrary`).
struct FixtureContactReader: ContactReading {
    func readContacts() async throws -> [ContactRecord] {
        ContactFixture.records
    }
}

#endif

#if DEBUG && targetEnvironment(simulator)

/// Seeds the **simulator's** contact store (never a device, never the user's real Contacts)
/// with `ContactFixture.records` so the full read → detect → review → merge/delete → verify
/// pipeline can run against a real `CNContactStore` end-to-end in Simulator.
///
/// Guardrails:
/// - Compiled only for DEBUG **simulator** builds — it cannot exist in a shipped app.
/// - Explicit opt-in via the `-seedFixtureContacts` launch argument (or `-wipeFixtureContacts`
///   to clean up); it never runs otherwise.
/// - Idempotent: previously seeded identifiers are stored in `UserDefaults` and deleted
///   before reseeding, so repeated runs never accumulate duplicates of the duplicates.
/// - Only ever touches contacts it created itself.
enum ContactFixtureSeeder {
    private static let idsKey = "netto.fixtureContacts.seededIDs"

    /// Deletes any previously seeded contacts, then creates the fixture set.
    static func seed() throws {
        let store = CNContactStore()
        try wipeExistingSeeds(in: store)

        let saveRequest = CNSaveRequest()
        var created: [CNMutableContact] = []
        for record in ContactFixture.records where !record.isEmptyForGrouping {
            let contact = CNMutableContact()
            contact.givenName = record.givenName
            contact.familyName = record.familyName
            contact.organizationName = record.organizationName
            contact.phoneNumbers = record.phoneNumbers.map {
                CNLabeledValue(
                    label: $0.label.isEmpty ? nil : $0.label,
                    value: CNPhoneNumber(stringValue: $0.value)
                )
            }
            contact.emailAddresses = record.emailAddresses.map {
                CNLabeledValue(label: $0.label.isEmpty ? nil : $0.label, value: $0.value as NSString)
            }
            saveRequest.add(contact, toContainerWithIdentifier: nil)
            created.append(contact)
        }
        try store.execute(saveRequest)
        // Identifiers are assigned by the store during the save.
        UserDefaults.standard.set(created.map(\.identifier), forKey: idsKey)
    }

    /// Removes only the contacts this seeder created.
    static func wipe() throws {
        try wipeExistingSeeds(in: CNContactStore())
    }

    private static func wipeExistingSeeds(in store: CNContactStore) throws {
        let previous = UserDefaults.standard.stringArray(forKey: idsKey) ?? []
        guard !previous.isEmpty else { return }
        let fetchKeys: [CNKeyDescriptor] = [CNContactIdentifierKey] as [CNKeyDescriptor]
        let existing = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(withIdentifiers: previous),
            keysToFetch: fetchKeys
        )
        guard !existing.isEmpty else {
            UserDefaults.standard.removeObject(forKey: idsKey)
            return
        }
        let saveRequest = CNSaveRequest()
        for contact in existing {
            if let mutable = contact.mutableCopy() as? CNMutableContact {
                saveRequest.delete(mutable)
            }
        }
        try store.execute(saveRequest)
        UserDefaults.standard.removeObject(forKey: idsKey)
    }
}

#endif
