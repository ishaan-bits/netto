import Foundation

/// Why a pair of contacts was grouped. Human-readable evidence only — there is deliberately
/// no numeric "confidence score": each reason is a fact the detector literally observed.
enum ContactDuplicateReason: String, Sendable, Comparable, CaseIterable {
    case sharedPhone = "Same phone number"
    case sharedEmail = "Same email address"
    case sharedNameOrganization = "Same name and organization"

    static func < (lhs: ContactDuplicateReason, rhs: ContactDuplicateReason) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One likely-duplicate group: the contacts the detector believes may be the same person.
///
/// Never "definitely the same person" — the UI always says *likely*. Members are sorted and
/// deduplicated; `id` is a stable digest of the member set, so the same group produces the
/// same id on every run and across launches.
struct ContactDuplicateGroup: Sendable, Hashable, Identifiable {
    let id: String
    /// Sorted, deduplicated member identifiers.
    let memberIDs: [String]
    /// Sorted, deduplicated reasons — every reason is evidence that holds *somewhere inside
    /// this group*, never a generic label.
    let reasons: [ContactDuplicateReason]

    var memberCount: Int { memberIDs.count }
}

/// Deterministic local duplicate detection over lightweight records.
///
/// ## How it works (and its bounds)
/// 1. **Candidate indexes** are built in O(F) where F is the total number of indexed field
///    values (phones + emails + names): `phoneKey → ids`, `email → ids`,
///    `nameKey → ids`. Empty values are never indexed; a record with no grouping-relevant
///    field is excluded entirely.
/// 2. **Bounded pair enumeration**: only keys shared by **2…`maxKeyCardinality`** contacts
///    generate candidate pairs — C(k, 2) ≤ 1225 per key. Keys shared by more contacts than
///    the cap cannot distinguish duplicates (a mass-shared switchboard or broadcast address)
///    and are skipped entirely, which is what keeps this from ever degenerating into an
///    all-pairs scan of the address book. Name pairs additionally require the same
///    organization, so two unrelated "John Smith"s at different companies are never paired.
/// 3. **Union-find** merges pairs into connected components. A contact therefore appears in
///    exactly one group (components are disjoint by construction), and cross-group
///    contamination is impossible.
/// 4. **Determinism**: keys are enumerated in sorted order, members and reasons are sorted,
///    and group ids are digests of the sorted member set — the same records always produce
///    byte-identical groups, in the same order.
///
/// Complexity: O(F + P·α) where F is indexed fields, P ≤ keys × C(cap, 2) the bounded pair
/// count, and α the inverse-Ackermann union-find factor. Never O(n²) over the contact list.
struct ContactDuplicateDetector: Sendable {
    /// A key shared by more contacts than this is too common to pair on (see bounds above).
    static let maxKeyCardinality = 50

    func findDuplicates(in records: [ContactRecord]) -> [ContactDuplicateGroup] {
        let index = ContactCandidateIndex(records: records)
        var union = UnionFind()

        // Sorted key order: pair enumeration order is fixed, so the component and reason
        // computation is reproducible.
        for key in index.phoneKeys.sorted() {
            addEdges(ids: index.ids(forPhoneKey: key), reason: .sharedPhone, into: &union)
        }
        for key in index.emailKeys.sorted() {
            addEdges(ids: index.ids(forEmailKey: key), reason: .sharedEmail, into: &union)
        }
        for nameKey in index.nameKeys.sorted() {
            for orgKey in index.orgKeys(forNameKey: nameKey).sorted() {
                addEdges(
                    ids: index.ids(forNameKey: nameKey, orgKey: orgKey),
                    reason: .sharedNameOrganization,
                    into: &union
                )
            }
        }

        // Components with ≥ 2 members, sorted for stable output.
        let components = union.components().filter { $0.count > 1 }
        let groups = components.map { members -> ContactDuplicateGroup in
            let sortedMembers = members.sorted()
            return ContactDuplicateGroup(
                id: ContactDigest.groupID(for: sortedMembers),
                memberIDs: sortedMembers,
                reasons: union.reasons(in: sortedMembers).sorted()
            )
        }
        return groups.sorted { lhs, rhs in
            for (l, r) in zip(lhs.memberIDs, rhs.memberIDs) where l != r {
                return l < r
            }
            return lhs.memberIDs.count < rhs.memberIDs.count
        }
    }

    private func addEdges(
        ids: [String],
        reason: ContactDuplicateReason,
        into union: inout UnionFind
    ) {
        let sorted = ids.sorted()
        guard sorted.count >= 2, sorted.count <= Self.maxKeyCardinality else { return }
        for left in 0..<(sorted.count - 1) {
            for right in (left + 1)..<sorted.count {
                union.union(sorted[left], sorted[right], reason: reason)
            }
        }
    }
}

// MARK: - Candidate index

/// Exact-key indexes over the three grouping signals. Built once per scan; every lookup is
/// O(1). Values are identifier arrays — never `CNContact` graphs.
struct ContactCandidateIndex: Sendable {
    private var phones: [String: [String]] = [:]
    private var emails: [String: [String]] = [:]
    /// nameKey → orgKey → ids (nested so name+org pairing only ever compares within one org).
    private var names: [String: [String: [String]]] = [:]

    init(records: [ContactRecord]) {
        for record in records {
            guard !record.isEmptyForGrouping else { continue }
            for phone in record.phoneNumbers {
                for key in ContactNormalization.phoneMatchKeys(phone.value) {
                    append(record.identifier, to: &phones, key: key)
                }
            }
            for emailValue in record.emailAddresses {
                guard let key = ContactNormalization.email(emailValue.value) else { continue }
                append(record.identifier, to: &emails, key: key)
            }
            if let nameKey = ContactNormalization.name(record.givenName, record.familyName),
               let orgKey = ContactNormalization.organization(record.organizationName) {
                append(record.identifier, to: &names[nameKey, default: [:]], key: orgKey)
            }
        }
    }

    var phoneKeys: Dictionary<String, [String]>.Keys { phones.keys }
    var emailKeys: Dictionary<String, [String]>.Keys { emails.keys }
    var nameKeys: Dictionary<String, [String: [String]]>.Keys { names.keys }

    func ids(forPhoneKey key: String) -> [String] { phones[key] ?? [] }
    func ids(forEmailKey key: String) -> [String] { emails[key] ?? [] }
    func orgKeys(forNameKey key: String) -> Dictionary<String, [String]>.Keys {
        (names[key] ?? [:]).keys
    }
    func ids(forNameKey name: String, orgKey: String) -> [String] {
        (names[name] ?? [:])[orgKey] ?? []
    }

    private func append(_ id: String, to array: inout [String: [String]], key: String) {
        if array[key]?.contains(id) != true {
            array[key, default: []].append(id)
        }
    }
}

// MARK: - Union-find with reasons

/// Disjoint-set forest over contact identifiers. Components are disjoint by construction, so
/// no contact can ever land in two groups; each edge records *why* it exists so a group's
/// reasons are the real evidence found inside it.
private struct UnionFind {
    private var parent: [String: String] = [:]
    private var edgeReasons: [String: Set<ContactDuplicateReason>] = [:]

    mutating func union(_ a: String, _ b: String, reason: ContactDuplicateReason) {
        let rootA = find(a)
        let rootB = find(b)
        // Deterministic attachment: lexicographically smaller id becomes the root.
        let newRoot = min(rootA, rootB)
        let oldRoot = max(rootA, rootB)
        if newRoot != oldRoot {
            parent[oldRoot] = newRoot
            edgeReasons[newRoot, default: []].formUnion(edgeReasons[oldRoot] ?? [])
            edgeReasons[oldRoot] = nil
        }
        edgeReasons[newRoot, default: []].insert(reason)
    }

    /// Root lookup with path compression (mutates — call only through an owned variable).
    private mutating func find(_ id: String) -> String {
        if parent[id] == nil {
            parent[id] = id
            return id
        }
        guard let next = parent[id] else { return id }
        if next == id { return id }
        let root = find(next)
        parent[id] = root
        return root
    }

    /// Root lookup without mutation, for read-only queries.
    private func root(of id: String) -> String {
        var current = id
        while let next = parent[current], next != current {
            current = next
        }
        return current
    }

    mutating func components() -> [[String]] {
        var grouped: [String: [String]] = [:]
        // Snapshot first: `find` mutates `parent`, which cannot overlap a live key iteration.
        for id in Array(parent.keys) {
            grouped[find(id), default: []].append(id)
        }
        return Array(grouped.values)
    }

    /// The edge reasons accumulated inside the group containing `members`.
    func reasons(in members: [String]) -> Set<ContactDuplicateReason> {
        guard let first = members.first else { return [] }
        return edgeReasons[root(of: first)] ?? []
    }
}
