import Foundation
import Testing
@testable import Netto

// MARK: Motion system
//
// Motion is defined once in `NettoMotion`: `Kind` is *how* something moves, `Purpose` is *why*.
// These tests pin the mapping, so a screen can never silently drift onto another screen's
// curve (a selection toggle adopting a navigation spring, for example).

struct MotionSystemTests {
    @Test func purposeInventoryIsTheNineIntents() {
        let names = Set(NettoMotion.Purpose.allCases.map { "\($0)" })
        #expect(names == [
            "hierarchy",
            "navigation",
            "stateChange",
            "selection",
            "progress",
            "success",
            "destructive",
            "loading",
            "reveal"
        ])
    }

    @Test func everyPurposeMapsToItsKind() {
        #expect(NettoMotion.kind(for: .hierarchy) == .standard)
        #expect(NettoMotion.kind(for: .navigation) == .emphasized)
        #expect(NettoMotion.kind(for: .stateChange) == .standard)
        #expect(NettoMotion.kind(for: .selection) == .quick)
        #expect(NettoMotion.kind(for: .progress) == .standard)
        #expect(NettoMotion.kind(for: .success) == .spring)
        #expect(NettoMotion.kind(for: .destructive) == .slow)
        #expect(NettoMotion.kind(for: .loading) == .ambient)
        #expect(NettoMotion.kind(for: .reveal) == .emphasized)
    }

    @Test func everyKindAndPurposeProducesAnAnimationWithAndWithoutReduceMotion() {
        let kinds: [NettoMotion.Kind] = [.quick, .standard, .emphasized, .spring, .slow, .ambient]
        #expect(kinds.count == 6)

        for kind in kinds {
            _ = NettoMotion.animation(for: kind, reduceMotion: false)
            _ = NettoMotion.animation(for: kind, reduceMotion: true)
        }
        for purpose in NettoMotion.Purpose.allCases {
            _ = NettoMotion.animation(for: purpose, reduceMotion: false)
            _ = NettoMotion.animation(for: purpose, reduceMotion: true)
        }
    }
}
