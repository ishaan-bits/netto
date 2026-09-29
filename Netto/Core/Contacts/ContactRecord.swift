import Foundation

/// A labeled value on a contact, copied out of `CNContact` at enumeration time.
///
/// Lightweight and immutable: the app never holds `CNContact` graphs after enumeration —
/// records are plain `Sendable` values the duplicate detector, plan builder, and UI all read.
struct ContactLabeledValue: Sendable, Hashable, Identifiable {
    /// The user's own label (e.g. "mobile"), empty when the value is unlabeled.
    let label: String
    /// The raw value exactly as stored (phone digits as typed, email as typed).
    let value: String
    /// Normalized form used for duplicate detection; `nil` when the value cannot be
    /// normalized (e.g. a phone with no digits). Never displayed — grouping uses this.
    let normalized: String?

    var id: String { "\(label)|\(value)" }

    private init(label: String, value: String, normalized: String?) {
        self.label = label
        self.value = value
        self.normalized = normalized
    }

    /// A phone value with its normalization computed by the shared policy.
    static func phone(label: String, value: String) -> ContactLabeledValue {
        ContactLabeledValue(
            label: label,
            value: value,
            normalized: ContactNormalization.phone(value)
        )
    }

    /// An email value with its normalization computed by the shared policy.
    static func email(label: String, value: String) -> ContactLabeledValue {
        ContactLabeledValue(
            label: label,
            value: value,
            normalized: ContactNormalization.email(value)
        )
    }
}

/// One contact exactly as Netto sees it after enumeration: only the fields duplicate
/// detection and review actually need.
///
/// A value snapshot — never a live `CNContact`. Nothing here is ever logged, printed, or
/// sent anywhere; the type exists purely so detection and review can run over plain data.
struct ContactRecord: Sendable, Hashable, Identifiable {
    /// The contact's identifier in the store (unified identifier under unified enumeration).
    let identifier: String
    let givenName: String
    let familyName: String
    let organizationName: String
    let phoneNumbers: [ContactLabeledValue]
    let emailAddresses: [ContactLabeledValue]

    var id: String { identifier }

    init(
        identifier: String,
        givenName: String = "",
        familyName: String = "",
        organizationName: String = "",
        phoneNumbers: [ContactLabeledValue] = [],
        emailAddresses: [ContactLabeledValue] = []
    ) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.organizationName = organizationName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
    }

    /// Display name for review UI: "Given Family", falling back to the organization, then to a
    /// neutral placeholder. Localization-safe (built from the stored name parts, never from a
    /// locale-dependent formatter, so it is identical across runs).
    var displayName: String {
        let joined = [givenName, familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !joined.isEmpty { return joined }
        let org = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !org.isEmpty { return org }
        return "(No name)"
    }

    /// True when the record has no grouping-relevant field at all (no name, org, phone, or
    /// email). Such records can never be part of any group and are excluded from indexes.
    var isEmptyForGrouping: Bool {
        ContactNormalization.name(givenName, familyName) == nil
            && ContactNormalization.organization(organizationName) == nil
            && phoneNumbers.allSatisfy { $0.normalized == nil }
            && emailAddresses.allSatisfy { $0.normalized == nil }
    }

    /// Canonical single-record content: exactly the fields duplicate detection and merge
    /// decisions depend on, in fixed order. The basis for per-contact identity signatures
    /// (plan drift detection) and the dataset signature — any change to any of these fields
    /// changes the digest.
    var canonicalFields: String {
        let phones = phoneNumbers
            .map { "\($0.label):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        let emails = emailAddresses
            .map { "\($0.label):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        return [
            identifier,
            givenName,
            familyName,
            organizationName,
            phones,
            emails,
        ].joined(separator: "|")
    }
}
