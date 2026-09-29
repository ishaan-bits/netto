import Foundation
import Testing
@testable import Netto

private func makeRecord(
    id: String,
    isFavorite: Bool = false,
    representsBurst: Bool = false,
    pixelWidth: Int = 4032,
    pixelHeight: Int = 3024,
    creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
    hasAdjustments: Bool = false
) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: .image,
        mediaSubtypes: [],
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        creationDate: creationDate,
        modificationDate: nil,
        duration: 0,
        isFavorite: isFavorite,
        isHidden: false,
        sourceType: [.library],
        hasAdjustments: hasAdjustments,
        representsBurst: representsBurst,
        burstIdentifier: nil
    )
}

private func best(_ records: [PhotoAssetRecord]) -> String? {
    BestPhotoScoring.recommendedBestID(in: records)
}

struct BestPhotoScoringTests {
    @Test func favoritedBeatsEverythingElse() {
        let plainHighRes = makeRecord(id: "plain", pixelWidth: 8000, pixelHeight: 6000)
        let favoriteLowRes = makeRecord(id: "fav", isFavorite: true, pixelWidth: 1000, pixelHeight: 1000)
        #expect(best([plainHighRes, favoriteLowRes]) == "fav")
    }

    @Test func nonBurstBeatsBurst() {
        let burst = makeRecord(id: "burst", representsBurst: true)
        let still = makeRecord(id: "still")
        #expect(best([burst, still]) == "still")
    }

    @Test func higherPixelCountBeatsLower() {
        let small = makeRecord(id: "small", pixelWidth: 1000, pixelHeight: 1000)
        let large = makeRecord(id: "large", pixelWidth: 4000, pixelHeight: 3000)
        #expect(best([small, large]) == "large")
    }

    @Test func editedBeatsUnedited() {
        let original = makeRecord(id: "original")
        let edited = makeRecord(id: "edited", hasAdjustments: true)
        #expect(best([original, edited]) == "edited")
    }

    @Test func newerCaptureBeatsOlder() {
        let older = makeRecord(id: "older", creationDate: Date(timeIntervalSince1970: 1_600_000_000))
        let newer = makeRecord(id: "newer", creationDate: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(best([older, newer]) == "newer")
    }

    @Test func missingCreationDateRanksOldest() {
        let undated = makeRecord(id: "undated", creationDate: nil)
        let dated = makeRecord(id: "dated", creationDate: Date(timeIntervalSince1970: 1_000_000_000))
        #expect(best([undated, dated]) == "dated")
    }

    @Test func fullTieBreaksToSmallestIdentifierDeterministically() {
        let first = makeRecord(id: "b-same")
        let second = makeRecord(id: "a-same")
        #expect(best([first, second]) == "a-same")
        #expect(best([second, first]) == "a-same")
    }

    @Test func recommendationIsStableAcrossInputOrdering() {
        let records = [
            makeRecord(id: "c"),
            makeRecord(id: "a", isFavorite: true),
            makeRecord(id: "b", representsBurst: true),
        ]
        let forward = best(records)
        let reversed = best(records.reversed())
        let shuffled = best([records[1], records[2], records[0]])
        #expect(forward == "a")
        #expect(reversed == "a")
        #expect(shuffled == "a")
    }

    @Test func decisiveChainOrderIsRespected() {
        // favorite (low res, unedited, old) still beats a newer, bigger, edited non-favorite —
        // favorites are the first and most decisive criterion.
        let rich = makeRecord(
            id: "rich",
            pixelWidth: 8000,
            pixelHeight: 6000,
            creationDate: Date(timeIntervalSince1970: 1_800_000_000),
            hasAdjustments: true
        )
        let favorite = makeRecord(
            id: "favorite",
            isFavorite: true,
            pixelWidth: 640,
            pixelHeight: 480,
            creationDate: Date(timeIntervalSince1970: 1_000_000_000)
        )
        #expect(best([rich, favorite]) == "favorite")
        #expect(
            BestPhotoScoring.outranks(
                BestPhotoScoring.score(for: favorite),
                BestPhotoScoring.score(for: rich)
            )
        )
    }

    @Test func scoreCarriesNoFabricatedSize() {
        // The score type has no size field at all: sizeInBytes is unknown at analysis time.
        let record = makeRecord(id: "a")
        let score = BestPhotoScoring.score(for: record)
        #expect(score.localIdentifier == "a")
        #expect(score.pixelCount == 4032 * 3024)
        #expect(score.creationDate != nil)
    }
}
