import Foundation
import Testing
@testable import Netto

// MARK: - The shared widget contract: encoding, decoding, and the consistency rule

struct WidgetSummaryTests {
    /// Fixed instant used as every test's `updatedAt` — deterministic across runs.
    private let fixedDay = Date(timeIntervalSince1970: 1_759_000_000)

    private func makeSummary(
        status: WidgetSummary.Status,
        estimateBytes: Int64? = nil,
        isEstimated: Bool = false,
        updatedAt: Date? = nil
    ) throws -> WidgetSummary {
        try #require(WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: status,
            estimateBytes: estimateBytes,
            isEstimated: isEstimated,
            updatedAt: updatedAt ?? fixedDay
        ))
    }

    // MARK: Encoding (mandated area 1)

    @Test func encodingCarriesEveryContractField() throws {
        let summary = try makeSummary(
            status: .lastCleanup,
            estimateBytes: 1_400_000_000,
            isEstimated: true
        )

        let data = try JSONEncoder().encode(summary)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == WidgetSummary.currentSchemaVersion)
        #expect(object["status"] as? String == "lastCleanup")
        #expect(object["estimateBytes"] as? Int == 1_400_000_000)
        #expect(object["isEstimated"] as? Bool == true)
        #expect(object["updatedAt"] != nil)
        // The contract is exactly these five fields — nothing about scans, photos, or
        // selections may ever ride along into the shared container.
        #expect(Set(object.keys) == [
            "schemaVersion", "status", "estimateBytes", "isEstimated", "updatedAt"
        ])
    }

    @Test func encodingRoundTripsThroughTheSharedDocument() throws {
        let summary = try makeSummary(
            status: .lastCleanup,
            estimateBytes: 2_500,
            isEstimated: true
        )
        let decoded = try JSONDecoder().decode(
            WidgetSummary.self,
            from: JSONEncoder().encode(summary)
        )
        #expect(decoded == summary)
    }

    // MARK: Decoding (mandated area 2)

    @Test func decodingTheMinimalDocumentProducesAScanReadySummary() throws {
        // A scan-ready document legitimately omits `estimateBytes` entirely (the encoder
        // never writes the key for `nil`), so the reader must accept its absence. Dates
        // in the shared document are seconds since Apple's reference date (2001-01-01),
        // matching `JSONEncoder`'s default strategy the store uses on both sides.
        let stamp = Date(timeIntervalSince1970: 1_759_000_000).timeIntervalSinceReferenceDate
        let json = #"{"schemaVersion":1,"status":"scanReady","isEstimated":false,"updatedAt":\#(stamp)}"#
        let decoded = try JSONDecoder().decode(WidgetSummary.self, from: Data(json.utf8))

        #expect(decoded.status == .scanReady)
        #expect(decoded.estimateBytes == nil)
        #expect(decoded.isEstimated == false)
        #expect(decoded.updatedAt == Date(timeIntervalSince1970: 1_759_000_000))
    }

    @Test func decodingAFullCleanupDocumentProducesTheSameSummary() throws {
        let summary = try makeSummary(
            status: .lastCleanup,
            estimateBytes: 987_654_321,
            isEstimated: true
        )
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(summary)
        )
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(WidgetSummary.self, from: data) == summary)
    }

    // MARK: Unsupported schema (mandated area 5)

    @Test func unsupportedSchemaVersionIsRejectedOnWrite() {
        #expect(WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion + 1,
            status: .empty,
            estimateBytes: nil,
            isEstimated: false,
            updatedAt: fixedDay
        ) == nil)
    }

    @Test func unsupportedSchemaVersionIsRejectedOnRead() {
        let json = #"{"schemaVersion":99,"status":"empty","isEstimated":false,"updatedAt":1759000000}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WidgetSummary.self, from: Data(json.utf8))
        }
    }

    // MARK: Values that would fabricate a figure

    @Test func valuesThatWouldFabricateAFigureAreRejectedOnWrite() {
        let preEpoch = Date(timeIntervalSince1970: 0)
        // A cleanup status with no positive measured figure.
        #expect(WidgetSummary(
            schemaVersion: 1, status: .lastCleanup,
            estimateBytes: nil, isEstimated: true, updatedAt: fixedDay
        ) == nil)
        #expect(WidgetSummary(
            schemaVersion: 1, status: .lastCleanup,
            estimateBytes: -1, isEstimated: true, updatedAt: fixedDay
        ) == nil)
        // A figure that is not labelled an estimate.
        #expect(WidgetSummary(
            schemaVersion: 1, status: .lastCleanup,
            estimateBytes: 10, isEstimated: false, updatedAt: fixedDay
        ) == nil)
        // A figure without a cleanup to hang it on.
        #expect(WidgetSummary(
            schemaVersion: 1, status: .scanReady,
            estimateBytes: 10, isEstimated: true, updatedAt: fixedDay
        ) == nil)
        #expect(WidgetSummary(
            schemaVersion: 1, status: .empty,
            estimateBytes: 10, isEstimated: true, updatedAt: fixedDay
        ) == nil)
        // A timestamp from before the epoch is corruption, not history.
        #expect(WidgetSummary(
            schemaVersion: 1, status: .empty,
            estimateBytes: nil, isEstimated: false, updatedAt: preEpoch
        ) == nil)
    }

    @Test func inconsistentDocumentIsRejectedOnRead() {
        let scanReadyWithFigure = """
        {"schemaVersion":1,"status":"scanReady","estimateBytes":12345,\
        "isEstimated":true,"updatedAt":1759000000}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WidgetSummary.self, from: Data(scanReadyWithFigure.utf8))
        }
        let cleanupWithoutFigure = #"{"schemaVersion":1,"status":"lastCleanup","isEstimated":true,"updatedAt":1759000000}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WidgetSummary.self, from: Data(cleanupWithoutFigure.utf8))
        }
    }

    // MARK: Staleness (mandated area 7)

    @Test func stalenessTurnsExactlySevenDaysOld() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        let fresh = try makeSummary(
            status: .scanReady,
            updatedAt: now.addingTimeInterval(-WidgetSummary.staleAfter)
        )
        #expect(!fresh.isStale(relativeTo: now))

        let justStale = try makeSummary(
            status: .scanReady,
            updatedAt: now.addingTimeInterval(-WidgetSummary.staleAfter - 1)
        )
        #expect(justStale.isStale(relativeTo: now))

        let skewedIntoTheFuture = try makeSummary(
            status: .scanReady,
            updatedAt: now.addingTimeInterval(60)
        )
        #expect(!skewedIntoTheFuture.isStale(relativeTo: now))
    }
}
