import Foundation

/// One compared pair with a distance ≤ threshold, canonicalized (`assetA < assetB`).
struct PairRelation: Sendable, Hashable {
    let assetA: String
    let assetB: String
    let distance: Float

    init(assetA: String, assetB: String, distance: Float) {
        self.distance = distance
        if assetA <= assetB {
            self.assetA = assetA
            self.assetB = assetB
        } else {
            self.assetA = assetB
            self.assetB = assetA
        }
    }
}

/// Turns per-bucket pair distances into near-duplicate groups, and fingerprints into exact
/// groups. Pure functions over injected data — no PhotoKit, no Vision, fully unit-testable.
enum SimilarityGrouping {
    // MARK: - Exact

    /// Groups assets that produced identical `ContentFingerprint`s. Fingerprints are only
    /// produced for byte-length collisions, so a `fingerprints` map entry means "content was
    /// read and hashed"; anything absent was either unique by length or unavailable, both of
    /// which are handled elsewhere.
    static func exactGroups(
        fingerprints: [String: ContentFingerprint],
        records: [String: PhotoAssetRecord]
    ) -> [PhotoSimilarityGroup] {
        var byFingerprint: [ContentFingerprint: [String]] = [:]
        for (assetID, fingerprint) in fingerprints {
            guard records[assetID] != nil else { continue }
            byFingerprint[fingerprint, default: []].append(assetID)
        }

        var groups: [PhotoSimilarityGroup] = []
        for (fingerprint, members) in byFingerprint where members.count > 1 {
            guard let group = makeGroup(
                kind: .exactDuplicates,
                memberIDs: members,
                evidence: .exactContent(
                    fingerprint: fingerprint.combinedDigestHex,
                    byteLength: fingerprint.totalBytes
                ),
                distances: nil,
                threshold: nil,
                records: records
            ) else { continue }
            groups.append(group)
        }
        return sorted(groups)
    }

    // MARK: - Near-duplicate

    /// Complete-linkage clustering over `relations`.
    ///
    /// Why complete-linkage instead of union-find / single-linkage: with single-linkage, one
    /// chain of loosely-related photos (A≈B, B≈C, … with A and C unrelated) collapses into one
    /// giant "similar" group — the classic transitive-closure failure that makes dedupe apps
    /// suggest deleting half a library. Complete-linkage only merges two clusters when *every*
    /// cross pair is itself a relation, so every pair inside a returned group is within
    /// `threshold` of every other pair: groups are cliques, evidence is exact, and no chain
    /// reactions occur.
    ///
    /// Determinism: relations are visited sorted by `(distance, assetA, assetB)`, so the result
    /// is identical across runs and across input orderings.
    static func nearGroups(
        relations: [PairRelation],
        threshold: Float,
        records: [String: PhotoAssetRecord]
    ) -> [PhotoSimilarityGroup] {
        var distanceByKey: [PairKey: Float] = [:]
        distanceByKey.reserveCapacity(relations.count)
        for relation in relations {
            distanceByKey[PairKey(relation.assetA, relation.assetB)] = relation.distance
        }

        let ordered = relations.sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.assetA != rhs.assetA { return lhs.assetA < rhs.assetA }
            return lhs.assetB < rhs.assetB
        }

        var clusters: [Set<String>] = []
        var clusterIndex: [String: Int] = [:]

        for relation in ordered {
            let indexA = clusterIndex[relation.assetA] ?? -1
            let indexB = clusterIndex[relation.assetB] ?? -1

            if indexA >= 0, indexB >= 0 {
                if indexA == indexB { continue }
                guard canMerge(
                    clusters[indexA], clusters[indexB],
                    distances: distanceByKey
                ) else { continue }
                merge(from: indexB, into: indexA, clusters: &clusters, clusterIndex: &clusterIndex)
                clusters[indexA].insert(relation.assetA)
                clusters[indexA].insert(relation.assetB)
            } else if indexA >= 0 {
                // A brand-new member must be checked against *every* resident, not just the one
                // end of this relation — otherwise the A≈B, B≈C chain would swallow C while
                // A≈C never holds, which is exactly the transitive-closure failure this
                // clustering exists to prevent.
                guard canAdd(relation.assetB, to: clusters[indexA], distances: distanceByKey)
                else { continue }
                clusters[indexA].insert(relation.assetB)
                clusterIndex[relation.assetB] = indexA
            } else if indexB >= 0 {
                guard canAdd(relation.assetA, to: clusters[indexB], distances: distanceByKey)
                else { continue }
                clusters[indexB].insert(relation.assetA)
                clusterIndex[relation.assetA] = indexB
            } else {
                clusters.append([relation.assetA, relation.assetB])
                let newIndex = clusters.count - 1
                clusterIndex[relation.assetA] = newIndex
                clusterIndex[relation.assetB] = newIndex
            }
        }

        var groups: [PhotoSimilarityGroup] = []
        for cluster in clusters where cluster.count > 1 {
            let members = Array(cluster)
            let distances = intraClusterDistances(members, distances: distanceByKey)
            let minDistance = distances.min() ?? 0
            let maxDistance = distances.max() ?? 0
            guard let group = makeGroup(
                kind: .nearDuplicates,
                memberIDs: members,
                evidence: .visualSimilarity(
                    minDistance: minDistance,
                    maxDistance: maxDistance,
                    threshold: threshold
                ),
                distances: distances,
                threshold: threshold,
                records: records
            ) else { continue }
            groups.append(group)
        }
        return sorted(groups)
    }

    // MARK: - Internals

    struct PairKey: Hashable {
        let a: String
        let b: String
        init(_ first: String, _ second: String) {
            if first <= second { a = first; b = second } else { a = second; b = first }
        }
    }

    static func canMerge(
        _ lhs: Set<String>,
        _ rhs: Set<String>,
        distances: [PairKey: Float]
    ) -> Bool {
        for x in lhs {
            for y in rhs {
                guard distances[PairKey(x, y)] != nil else { return false }
            }
        }
        return true
    }

    /// `true` when `member` has a relation to every resident of `cluster`.
    static func canAdd(
        _ member: String,
        to cluster: Set<String>,
        distances: [PairKey: Float]
    ) -> Bool {
        for resident in cluster where distances[PairKey(member, resident)] == nil {
            return false
        }
        return true
    }

    /// Folds `source` into `target`, repointing every member. The source slot is left as an
    /// empty set; empty clusters are filtered when groups are built.
    static func merge(
        from source: Int,
        into target: Int,
        clusters: inout [Set<String>],
        clusterIndex: inout [String: Int]
    ) {
        guard source != target else { return }
        for member in clusters[source] {
            clusterIndex[member] = target
            clusters[target].insert(member)
        }
        clusters[source].removeAll()
    }

    static func intraClusterDistances(
        _ members: [String],
        distances: [PairKey: Float]
    ) -> [Float] {
        var result: [Float] = []
        guard members.count > 1 else { return result }
        for firstIndex in 0..<members.count {
            for secondIndex in (firstIndex + 1)..<members.count {
                if let distance = distances[PairKey(members[firstIndex], members[secondIndex])] {
                    result.append(distance)
                }
            }
        }
        return result
    }

    static func makeGroup(
        kind: PhotoSimilarityGroupKind,
        memberIDs: [String],
        evidence: PhotoAnalysisEvidence,
        distances: [Float]?,
        threshold: Float?,
        records: [String: PhotoAssetRecord]
    ) -> PhotoSimilarityGroup? {
        let members = memberIDs.sorted()
        guard members.count > 1 else { return nil }

        var scores: [String: PhotoAssetQualityScore] = [:]
        var memberRecords: [PhotoAssetRecord] = []
        for member in members {
            guard let record = records[member] else {
                // A member without catalog metadata cannot be scored; drop the whole group rather
                // than emit a recommendation we cannot back.
                return nil
            }
            scores[member] = BestPhotoScoring.score(for: record)
            memberRecords.append(record)
        }
        guard let best = BestPhotoScoring.recommendedBestID(in: memberRecords) else { return nil }

        return PhotoSimilarityGroup(
            kind: kind,
            memberAssetIDs: members,
            evidence: evidence,
            recommendedBestAssetID: best,
            memberScores: scores
        )
    }

    static func sorted(_ groups: [PhotoSimilarityGroup]) -> [PhotoSimilarityGroup] {
        groups.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.memberAssetIDs.joined(separator: ",") < rhs.memberAssetIDs.joined(
                separator: ","
            )
        }
    }
}
