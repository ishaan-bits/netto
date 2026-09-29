import Foundation

/// Deterministic, collision-resistant-enough hashing for signatures and ids.
///
/// FNV-1a over UTF-8 — pure, stable across runs and launches (unlike `hashValue`, which is
/// seeded per-process). Used only as a fingerprint: every caller keeps the *inputs* canonical
/// and sorted before hashing, so equal content always hashes equal.
enum ContactDigest {
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0000_01B3
        }
        return hash
    }

    static func hex(_ string: String) -> String {
        String(fnv1a(string), radix: 16)
    }

    /// Stable group identity: a digest of the sorted member identifiers. The same member set
    /// always produces the same id, in any input order, on any run.
    static func groupID(for sortedMemberIDs: [String]) -> String {
        "g-" + hex(sortedMemberIDs.joined(separator: "\u{1}"))
    }
}

/// Everything the Duplicate Contacts screen can be showing, derived — never stored.
enum ContactScanState: Sendable, Equatable {
    case notStarted
    case running
    case completed(ContactDataset)
    case cancelled
    /// The read or detection failed; carries a user-facing message (never raw error text
    /// about contact contents).
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// The result of one contacts scan: lightweight records plus the duplicate groups found over
/// them. No `CNContact` graph is retained — only these values.
struct ContactDataset: Sendable, Equatable {
    let records: [ContactRecord]
    let groups: [ContactDuplicateGroup]

    static let empty = ContactDataset(records: [], groups: [])

    func record(for id: String) -> ContactRecord? {
        records.first { $0.identifier == id }
    }

    func group(for id: String) -> ContactDuplicateGroup? {
        groups.first { $0.id == id }
    }

    var identifiers: Set<String> {
        Set(records.lazy.map(\.identifier))
    }

    /// Content fingerprint over *every* record's grouping-relevant fields — membership,
    /// names, organizations, phones, and emails. Any change to any contact the app can see
    /// (including changes made outside Netto) produces a different signature, so a plan
    /// stamped with the old one is stale. Order-independent (records sorted by id), no time
    /// or randomness.
    static func signature(for records: [ContactRecord]) -> String {
        let canonical = records
            .sorted { $0.identifier < $1.identifier }
            .map(\.canonicalFields)
            .joined(separator: "\n")
        return "c1-contacts|\(records.count)|\(ContactDigest.hex(canonical))"
    }

    static func signature(in dataset: ContactDataset) -> String {
        signature(for: dataset.records)
    }
}
