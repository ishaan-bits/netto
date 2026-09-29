import Foundation
import Testing
@testable import Netto

// MARK: Deterministic local duplicate detection

struct ContactDuplicateDetectorTests {
    private let detector = ContactDuplicateDetector()

    // MARK: Fixture expectations

    @Test func fixtureSetProducesExactlyTheFourExpectedGroups() {
        let groups = detector.findDuplicates(in: ContactFixture.records)

        #expect(groups.count == ContactFixture.expectedGroupCount)

        let memberSets = Set(groups.map { Set($0.memberIDs) })
        #expect(memberSets == [
            ["fixture-contact-01", "fixture-contact-02"], // strict phone match
            ["fixture-contact-03", "fixture-contact-04"], // national-tolerance phone match
            ["fixture-contact-05", "fixture-contact-06"], // shared email
            ["fixture-contact-07", "fixture-contact-08"], // shared name + organization
        ])
    }

    @Test func fixtureGroupsCarryTheEvidenceThatActuallyMatched() {
        let groups = detector.findDuplicates(in: ContactFixture.records)
        let byMembers = Dictionary(
            uniqueKeysWithValues: groups.map { (Set($0.memberIDs), $0) }
        )

        #expect(
            byMembers[["fixture-contact-01", "fixture-contact-02"]]?.reasons == [.sharedPhone]
        )
        #expect(
            byMembers[["fixture-contact-03", "fixture-contact-04"]]?.reasons == [.sharedPhone]
        )
        #expect(
            byMembers[["fixture-contact-05", "fixture-contact-06"]]?.reasons == [.sharedEmail]
        )
        #expect(
            byMembers[["fixture-contact-07", "fixture-contact-08"]]?.reasons
                == [.sharedNameOrganization]
        )
    }

    @Test func unrelatedSinglesAndEmptyRecordsNeverAppearInAnyGroup() {
        let grouped = Set(
            detector.findDuplicates(in: ContactFixture.records).flatMap(\.memberIDs)
        )
        #expect(grouped.isDisjoint(with: [
            "fixture-contact-09",
            "fixture-contact-10",
            "fixture-contact-11",
        ]))
    }

    // MARK: Signal rules

    @Test func namePairsRequireTheSameOrganization() {
        let records = [
            ContactRecord(identifier: "a", givenName: "John", familyName: "Smith", organizationName: "Acme"),
            ContactRecord(identifier: "b", givenName: "John", familyName: "Smith", organizationName: "Globex"),
            ContactRecord(identifier: "c", givenName: "John", familyName: "Smith", organizationName: "Acme"),
        ]
        let groups = detector.findDuplicates(in: records)
        #expect(groups.count == 1)
        #expect(Set(groups[0].memberIDs) == ["a", "c"])
        #expect(groups[0].reasons == [.sharedNameOrganization])
    }

    @Test func namePairingWithoutOrganizationIsSkippedEntirely() {
        let records = [
            ContactRecord(identifier: "a", givenName: "John", familyName: "Smith"),
            ContactRecord(identifier: "b", givenName: "John", familyName: "Smith"),
        ]
        #expect(detector.findDuplicates(in: records).isEmpty)
    }

    @Test func phonesMatchAcrossFormattingAndTheNationalRule() {
        let records = [
            ContactRecord(identifier: "a", phoneNumbers: [.phone(label: "m", value: "+1 (555) 010-1234")]),
            ContactRecord(identifier: "b", phoneNumbers: [.phone(label: "m", value: "1 555 010 1234")]),
            ContactRecord(identifier: "c", phoneNumbers: [.phone(label: "m", value: "(555) 010-7777")]),
            ContactRecord(identifier: "d", phoneNumbers: [.phone(label: "m", value: "+15550107777")]),
            ContactRecord(identifier: "e", phoneNumbers: [.phone(label: "m", value: "5550199999")]),
        ]
        let groups = detector.findDuplicates(in: records)
        #expect(groups.count == 2)
        #expect(Set(groups.map { Set($0.memberIDs) }) == [
            ["a", "b"],
            ["c", "d"],
        ])
    }

    @Test func emailsMatchCaseAndWhitespaceInsensitivelyButNeverStripPlusTags() {
        let records = [
            ContactRecord(identifier: "a", emailAddresses: [.email(label: "w", value: " Owen.Blake@Example.com ")]),
            ContactRecord(identifier: "b", emailAddresses: [.email(label: "w", value: "owen.blake@example.com")]),
            ContactRecord(identifier: "c", emailAddresses: [.email(label: "w", value: "owen.blake+x@example.com")]),
        ]
        let groups = detector.findDuplicates(in: records)
        #expect(groups.count == 1)
        #expect(Set(groups[0].memberIDs) == ["a", "b"])
    }

    // MARK: Bounds and structure

    @Test func recordsWithNoGroupingFieldAreExcludedFromIndexes() {
        let records = [
            ContactRecord(identifier: "empty"),
            ContactRecord(identifier: "a", givenName: "Solo", familyName: "Person"),
        ]
        #expect(detector.findDuplicates(in: records).isEmpty)
    }

    @Test func aKeySharedByMoreThanTheCapIsSkippedRatherThanPaired() {
        var records: [ContactRecord] = []
        for index in 0...(ContactDuplicateDetector.maxKeyCardinality + 1) {
            records.append(
                ContactRecord(
                    identifier: String(format: "id-%03d", index),
                    phoneNumbers: [.phone(label: "m", value: "+1 555 010 0000")]
                )
            )
        }
        #expect(detector.findDuplicates(in: records).isEmpty)

        // One contact fewer than the cap still pairs everything into one group.
        var underCap: [ContactRecord] = []
        for index in 0..<ContactDuplicateDetector.maxKeyCardinality {
            underCap.append(
                ContactRecord(
                    identifier: String(format: "id-%03d", index),
                    phoneNumbers: [.phone(label: "m", value: "+1 555 010 0000")]
                )
            )
        }
        let groups = detector.findDuplicates(in: underCap)
        #expect(groups.count == 1)
        #expect(groups[0].memberCount == ContactDuplicateDetector.maxKeyCardinality)
    }

    @Test func everyContactBelongsToAtMostOneGroupEvenInTransitiveChains() {
        // a—b share a phone, b—c share an email, c—d share a name+org: one component.
        let records = [
            ContactRecord(
                identifier: "a",
                givenName: "Ana",
                familyName: "Zed",
                phoneNumbers: [.phone(label: "m", value: "+1 555 010 1000")],
                emailAddresses: [.email(label: "w", value: "chain@example.com")]
            ),
            ContactRecord(
                identifier: "b",
                givenName: "Unrelated",
                familyName: "Name",
                phoneNumbers: [.phone(label: "m", value: "+1 555 010 1000")],
                emailAddresses: [.email(label: "w", value: "chain@example.com")]
            ),
            ContactRecord(
                identifier: "c",
                givenName: "Cara",
                familyName: "Yun",
                organizationName: "Acme",
                emailAddresses: [.email(label: "w", value: "chain@example.com")]
            ),
            ContactRecord(
                identifier: "d",
                givenName: "Cara",
                familyName: "Yun",
                organizationName: "Acme"
            ),
        ]
        let groups = detector.findDuplicates(in: records)
        #expect(groups.count == 1)
        #expect(Set(groups[0].memberIDs) == ["a", "b", "c", "d"])
        #expect(Set(groups[0].reasons) == [.sharedPhone, .sharedEmail, .sharedNameOrganization])

        // Disjointness: no identifier appears twice across groups.
        let all = detector.findDuplicates(in: records + records.map {
            ContactRecord(identifier: $0.identifier + "-other", givenName: "Other", familyName: "Other")
        })
        let ids = all.flatMap(\.memberIDs)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: Determinism

    @Test func identicalInputAlwaysProducesByteIdenticalGroups() {
        let forward = detector.findDuplicates(in: ContactFixture.records)
        let reversed = detector.findDuplicates(in: ContactFixture.records.reversed())
        #expect(forward == reversed)

        let shuffled = detector.findDuplicates(in: ContactFixture.records.shuffled())
        #expect(forward == shuffled)
    }

    @Test func groupIDsAreStableDigestsOfTheMemberSet() {
        let groups = detector.findDuplicates(in: ContactFixture.records)
        let rebuilt = detector.findDuplicates(in: ContactFixture.records)
        #expect(groups.map(\.id) == rebuilt.map(\.id))
        for group in groups {
            #expect(group.id == ContactDigest.groupID(for: group.memberIDs))
        }
    }

    @Test func groupsAreSortedDeterministically() {
        let groups = detector.findDuplicates(in: ContactFixture.records)
        for (lhs, rhs) in zip(groups, groups.dropFirst()) {
            let lhsKey = lhs.memberIDs.joined(separator: ",")
            let rhsKey = rhs.memberIDs.joined(separator: ",")
            #expect(lhsKey < rhsKey || (lhsKey == rhsKey && lhs.memberCount <= rhs.memberCount))
        }
        for group in groups {
            #expect(group.memberIDs == group.memberIDs.sorted())
            #expect(group.reasons == group.reasons.sorted())
        }
    }
}
