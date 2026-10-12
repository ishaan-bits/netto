import Combine
import CoreGraphics
import Foundation
import Testing
@testable import Netto

// MARK: - Swipe Review (M4K/M4L): session semantics over the existing PhotoSelectionModel
//
// The swipe session is pure cursor/history logic; every decision is written through the
// *shared* selection exactly as the view does (`env.mutateSelection { model.decide(…) }`),
// so these tests prove the contract the screen depends on: keep deselects, delete selects,
// undo is an exact restore, decisions outlive the session, completion counts are honest —
// and none of it can reach the scanner or the deletion pipeline. No photo library, no
// network: the loader and PhotoKit are never touched.
//
// M4L adds the persistent review bar: the live count + "Review Cleanup" is available for the
// whole session (not only at completion), it hands off to the *existing* `ReviewSelectionView`
// with exactly the swiped selections, "Done" leaves with the selection
// intact, and with nothing selected the affordance is clearly unavailable.

@MainActor
struct SwipeReviewTests {
    // MARK: Session order (presentation, pure)

    @Test func itemsFollowGroupAndMemberOrderWithoutDuplicates() {
        let items = SwipeReviewPresentation.items(from: fixtureResult())

        // Exact groups first, then similar — the order the results list renders — each
        // group's members in their declared order; `e2` belongs to both groups and is
        // presented exactly once (first group wins), so a session can never repeat a photo.
        #expect(items.map(\.assetID) == ["e1", "e2", "e3", "n1"])
        #expect(items.map(\.groupOrdinal) == [1, 1, 1, 2])
        #expect(items.map(\.groupKind) == [
            .exactDuplicates, .exactDuplicates, .exactDuplicates, .nearDuplicates,
        ])
        // Recommended KEEPs are part of the session — swipe mode reaches the same selection
        // the grid does, not a filtered subset of it.
        #expect(items.map(\.isRecommended) == [true, false, false, true])
        // Only photos that exist in the analysis result — nothing else can enter the deck.
        #expect(Set(items.map(\.assetID)).isSubset(of: ["e1", "e2", "e3", "n1"]))
    }

    @Test func positionAndCountCopyIsExact() {
        #expect(SwipeReviewPresentation.positionText(current: 12, total: 47) == "12 of 47")
        #expect(SwipeReviewPresentation.positionAccessibilityLabel(current: 12, total: 47) == "Photo 12 of 47")
        #expect(SwipeReviewPresentation.reviewedCountText(47) == "47 photos reviewed")
        #expect(SwipeReviewPresentation.reviewedCountText(1) == "1 photo reviewed")
        #expect(SwipeReviewPresentation.selectedForCleanupText(5) == "5 photos selected for cleanup")
        #expect(SwipeReviewPresentation.selectedForCleanupText(1) == "1 photo selected for cleanup")
        #expect(SwipeReviewPresentation.groupContext(
            for: SwipeReviewItem(assetID: "x", groupKind: .nearDuplicates, groupOrdinal: 3, isRecommended: false)
        ) == "Similar photo · group 3")
        #expect(SwipeReviewPresentation.entryLabel == "Swipe Review")
        #expect(SwipeReviewPresentation.completionTitle == "You're all caught up.")
    }

    // MARK: Swipe semantics (spec 1–4)

    @Test func swipeRightKeepsASelectedPhotoByDeselectingIt() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        #expect(env.selection.isSelected("e2")) // default selection (e2 is not the KEEP)

        // Swipe right past the first photo (keep — already unselected, stays that way), then
        // right on the selected one: it leaves the cleanup set.
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        #expect(!env.selection.isSelected("e1"))
        env.mutateSelection { model.decide(.keep, selection: &$0) }

        #expect(!env.selection.isSelected("e2"))
        #expect(model.cursor == 2)
    }

    @Test func swipeLeftMarksAnUnselectedPhotoForCleanup() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        #expect(!env.selection.isSelected("e1")) // the recommended KEEP starts unselected

        env.mutateSelection { model.decide(.delete, selection: &$0) }

        #expect(env.selection.isSelected("e1"))
        #expect(env.selection.selectedCount == 3)
    }

    @Test func keepOnAPhotoTheUserAlreadyDeselectedLeavesItDeselected() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        env.mutateSelection { $0.setSelected(false, forAsset: "e2") } // user cleared it in the grid
        let model = SwipeReviewModel(items: [item("e2")])

        env.mutateSelection { model.decide(.keep, selection: &$0) }

        #expect(!env.selection.isSelected("e2"))
    }

    @Test func deleteOnAPhotoTheUserAlreadySelectedKeepsItSelected() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        env.mutateSelection { $0.setSelected(false, forAsset: "e3") } // user cleared it…
        env.mutateSelection { $0.setSelected(true, forAsset: "e3") }  // …then re-marked it
        let model = SwipeReviewModel(items: [item("e3")])

        env.mutateSelection { model.decide(.delete, selection: &$0) }

        #expect(env.selection.isSelected("e3"))
        #expect(env.selection.selectedCount == 2) // {e2, e3}: delete is a no-op on e3
    }

    // MARK: Undo (spec 5)

    @Test func undoRestoresThePreviousSelectionAndPosition() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        let before = env.selection

        env.mutateSelection { model.decide(.delete, selection: &$0) }
        #expect(env.selection.isSelected("e1"))
        #expect(model.cursor == 1)
        #expect(model.canUndo)

        env.mutateSelection { model.undo(selection: &$0) }

        #expect(model.cursor == 0)
        #expect(model.currentItem?.assetID == "e1") // back on the swiped photo
        #expect(env.selection == before) // exact restore, not a re-derivation
        #expect(!env.selection.isSelected("e1"))
        #expect(!model.canUndo)
    }

    @Test func undoAtTheStartAndDecideAtTheEndAreBoundaryNoOps() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: [item("e1")])
        let before = env.selection

        env.mutateSelection { model.undo(selection: &$0) } // nothing to undo yet
        #expect(env.selection == before)
        #expect(model.cursor == 0)

        env.mutateSelection { model.decide(.delete, selection: &$0) }
        let afterSwipe = env.selection
        env.mutateSelection { model.decide(.keep, selection: &$0) } // deck is finished
        #expect(env.selection == afterSwipe)
        #expect(model.cursor == 1)
        #expect(model.isComplete)
    }

    // MARK: Multiple swipes & exit (spec 6–7)

    @Test func multipleSwipesPreserveEveryDecision() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) } // e1 → marked
        env.mutateSelection { model.decide(.keep, selection: &$0) }   // e2 → cleared
        env.mutateSelection { model.decide(.delete, selection: &$0) } // e3 → marked

        #expect(model.cursor == 3)
        #expect(env.selection.isSelected("e1"))
        #expect(!env.selection.isSelected("e2"))
        #expect(env.selection.isSelected("e3"))
        #expect(!env.selection.isSelected("n1")) // untouched so far
        #expect(env.selection.selectedCount == 2)
    }

    @Test func exitingSwipeReviewPreservesEveryDecision() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) }
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        let decidedSelection = env.selection

        // Exit the screen (the session object goes away with it) and read the selection
        // exactly as Similar Photos does on return: every decision survived, no reset.
        let survived = env.selection
        #expect(survived == decidedSelection)
        #expect(env.selectionCount(for: .similarPhotos) == env.selection.selectedCount)
        #expect(env.selection.isSelected("e1"))
        #expect(!env.selection.isSelected("e2"))

        // A bare model constructed later starts fresh; the *screen* restores the persisted
        // session (cursor, history, decisions) over it on appear — covered in the
        // persistence suite below. Either way the shared selection is untouched.
        let fresh = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        #expect(fresh.cursor == 0)
        #expect(fresh.history.isEmpty)
        #expect(env.selection == decidedSelection)
    }

    // MARK: Completion (spec 8)

    @Test func completionCountsAreExact() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) } // e1 marked
        env.mutateSelection { model.decide(.delete, selection: &$0) } // e2 marked (already was)
        env.mutateSelection { model.decide(.keep, selection: &$0) }   // e3 cleared
        env.mutateSelection { model.decide(.keep, selection: &$0) }   // n1 cleared (already was)

        #expect(model.isComplete)
        #expect(model.currentItem == nil)
        #expect(model.reviewedCount == 4)
        #expect(SwipeReviewPresentation.reviewedCountText(model.reviewedCount) == "4 photos reviewed")
        // Selected = e1 + e2 (e3 cleared, n1 protected) — the live shared selection, not a
        // count owned by the session.
        #expect(env.selection.selectedCount == 2)
        #expect(SwipeReviewPresentation.selectedForCleanupText(env.selection.selectedCount)
                == "2 photos selected for cleanup")
        #expect(SwipeReviewPresentation.positionText(current: 4, total: 4) == "4 of 4")
    }

    // MARK: Review destination (spec 9)

    @Test func completionHandsOffToTheExistingReviewFlow() async {
        let env = makeReviewReadyEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) }
        #expect(model.isComplete == false)
        #expect(model.reviewedCount == 1)

        // The completion state's primary action targets the editable cleanup flow — the same
        // `SwipeCleanupSelectionView` entry the bottom Review Cleanup button uses, which
        // hands the checked Delete marks to the *existing* `ReviewSelectionView`. Swipe mode
        // builds no destination of its own.
        #expect(SwipeReviewPresentation.completionPrimaryDestination == .editableCleanup)
        #expect(SwipeReviewPresentation.completionPrimaryTitle == "Review Cleanup")
        #expect(SwipeReviewPresentation.completionSecondaryDestination == .dismissToSimilarPhotos)

        env.reviewDidAppear(from: .similarPhotos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.count == env.selection.selectedCount)
        #expect(plan.selectionSnapshot == env.selection.selectedIDs)
    }

    // MARK: Persistent review bar & completion (M4L)

    @Test func fiveDecisionsAcrossFivePhotosAreAllPreserved() {
        let env = makeEnv()
        let items = libraryDeck(count: 5)
        let model = SwipeReviewModel(items: items)
        // Exactly what `SwipeReviewView.onAppear` does: the deck enters the shared
        // selection's accepted set — admission alone selects nothing.
        env.mutateSelection { $0.admitLibraryAssets(Set(items.map(\.assetID))) }
        #expect(env.selection.selectedCount == 0)

        for _ in items {
            env.mutateSelection { model.decide(.delete, selection: &$0) }
        }

        #expect(model.cursor == 5)
        #expect(model.isComplete)
        // All five decisions preserved in the shared selection — no reset, no shadow copy.
        for assetID in items.map(\.assetID) {
            #expect(env.selection.isSelected(assetID))
        }
        #expect(env.selection.selectedCount == 5)
        #expect(SwipeReviewPresentation.selectedForCleanupText(env.selection.selectedCount)
                == "5 photos selected for cleanup")
    }

    @Test func midSessionReviewCleanupHandsExactSelectionsToTheExistingReviewFlow() async {
        let env = makeReviewReadyEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) } // e1 marked
        env.mutateSelection { model.decide(.keep, selection: &$0) }   // e2 cleared
        #expect(!model.isComplete) // the persistent bar — not only completion — is an entry
        #expect(env.selection.selectedIDs == ["e1", "e3"])
        // The bar shares the completion screen's primary destination: the editable cleanup.
        #expect(SwipeReviewPresentation.completionPrimaryDestination == .editableCleanup)
        #expect(SwipeReviewPresentation.completionPrimaryTitle == "Review Cleanup")

        // Same handoff the cleanup screen performs: only this session's Delete marks (e1 —
        // never-reviewed e3 is not a candidate, even though it is selected) enter the
        // *existing* review as the `.swipeReview` source.
        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))
        #expect(env.swipeCleanupCheckedIDs == ["e1"])
        env.reviewDidAppear(from: .swipeReview)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["e1"])
    }

    @Test func finishingTheLastPhotoReachesTheCompletionState() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        let items = SwipeReviewPresentation.items(from: result)
        let model = SwipeReviewModel(items: items)

        // First three decisions: a photo is still on screen, the session is live.
        env.mutateSelection { model.decide(.delete, selection: &$0) }
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        env.mutateSelection { model.decide(.delete, selection: &$0) }
        #expect(!model.isComplete)
        #expect(model.currentItem != nil)

        // The last photo decides → the completion screen's exact contract.
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        #expect(model.isComplete)
        #expect(model.currentItem == nil)
        #expect(model.reviewedCount == items.count)
        #expect(SwipeReviewPresentation.completionTitle == "You're all caught up.")
        #expect(SwipeReviewPresentation.selectedForCleanupText(env.selection.selectedCount)
                == "2 photos selected for cleanup")
        #expect(SwipeReviewPresentation.completionPrimaryTitle == "Review Cleanup")
        #expect(SwipeReviewPresentation.completionSecondaryTitle == "Done")
        // Both completion actions are offered only when there is something to review.
        #expect(SwipeReviewPresentation.reviewCleanupEnabled(selectedCount: env.selection.selectedCount))
    }

    @Test func completionSecondaryReturnsOutPreservingEverySelection() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) }
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        let decided = env.selection

        // The secondary action's contract: dismiss the session ("Done" — reachable from
        // Similar Photos *and* the dashboard card, so no hard-coded destination)
        // without touching the shared model — the screen underneath reads the exact
        // selections that were swiped, and the review-facing count agrees.
        #expect(SwipeReviewPresentation.completionSecondaryDestination == .dismissToSimilarPhotos)
        #expect(SwipeReviewPresentation.completionSecondaryTitle == "Done")
        #expect(env.selection == decided) // dismiss() mutates nothing
        #expect(env.selectionCount(for: .similarPhotos) == decided.selectedCount)
        #expect(env.selection.isSelected("e1"))
        #expect(!env.selection.isSelected("e2"))
    }

    @Test func reviewCleanupIsUnavailableWhileNothingIsSelected() {
        let env = makeEnv()
        let items = libraryDeck(count: 2)
        let model = SwipeReviewModel(items: items)
        env.mutateSelection { $0.admitLibraryAssets(Set(items.map(\.assetID))) }

        // Fresh session: zero selected → the bar's button is present but clearly
        // unavailable rather than opening an empty review.
        #expect(env.selection.selectedCount == 0)
        #expect(!SwipeReviewPresentation.reviewCleanupEnabled(selectedCount: env.selection.selectedCount))

        // A keep still leaves nothing to review → still unavailable.
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        #expect(env.selection.selectedCount == 0)
        #expect(!SwipeReviewPresentation.reviewCleanupEnabled(selectedCount: env.selection.selectedCount))

        // The first delete marks a photo → the same shared predicate enables the button.
        env.mutateSelection { model.decide(.delete, selection: &$0) }
        #expect(env.selection.selectedCount == 1)
        #expect(SwipeReviewPresentation.reviewCleanupEnabled(selectedCount: env.selection.selectedCount))
        // And the enabled gate covers every nonzero count the bar can show.
        #expect(SwipeReviewPresentation.reviewCleanupEnabled(selectedCount: 5))
    }

    // MARK: Scanner & deletion safety (spec 10–11)

    @Test func swipingNeverInvokesTheScanner() {
        let calls = CallCounter()
        let env = makeEnv(calls: calls)
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        for decision in [SwipeReviewModel.Decision.delete, .keep, .delete, .keep] {
            env.mutateSelection { model.decide(decision, selection: &$0) }
        }
        env.mutateSelection { model.undo(selection: &$0) }

        #expect(calls.count == 0)
        #expect(env.analysisState == .completed(result)) // result byte-identical, no rescan
        #expect(env.analysisState.isRunning == false)
    }

    @Test func swipingNeverReachesTheDeletionPipeline() {
        let deletion = CountingDeletionService()
        let env = makeEnv(deletionService: deletion)
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        for decision in [SwipeReviewModel.Decision.delete, .keep, .delete, .keep] {
            env.mutateSelection { model.decide(decision, selection: &$0) }
        }

        // Selection-only: the deletion state machine was never entered, the PhotoKit-backed
        // service was never called, and the analysis result is untouched.
        #expect(deletion.callCount == 0)
        #expect(env.deletionState == .noSelection)
        #expect(env.analysisState == .completed(result))
        #expect(Set(env.selection.memberIDs(inGroup: result.exactGroups[0].id)) == ["e1", "e2", "e3"])
    }

    // MARK: Single source of truth (spec 12)

    @Test func historySnapshotsTheSharedSelectionRatherThanShadowingIt() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: [item("e1")])

        // The photo is unselected when swiped (keep leaves it unselected)…
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        #expect(model.history == [SwipeReviewModel.HistoryEntry(assetID: "e1", wasSelected: false)])

        // …the grid changes the same shared selection while the session is still open…
        env.mutateSelection { $0.setSelected(true, forAsset: "e1") }
        #expect(env.selection.isSelected("e1"))

        // …and Undo restores what the *shared model* recorded at swipe time: the session
        // holds no selection of its own — it only ever reads and writes through the inout
        // selection the environment passes in.
        env.mutateSelection { model.undo(selection: &$0) }
        #expect(!env.selection.isSelected("e1"))
        #expect(model.cursor == 0)
    }

    // MARK: Lazy deck install (the dashboard card's path)

    @Test func deckInstallsIntoAnEmptySessionExactlyOnce() {
        let model = SwipeReviewModel(items: [])

        // An empty request never manufactures a deck — the empty state stays the empty state.
        model.installDeckIfNeeded([])
        #expect(model.items.isEmpty)

        model.installDeckIfNeeded(libraryDeck(count: 3))
        #expect(model.items.map(\.assetID) == ["lib1", "lib2", "lib3"])

        // A second install is refused: the session that exists is the session that stays.
        model.installDeckIfNeeded(libraryDeck(count: 5))
        #expect(model.items.count == 3)
    }

    @Test func installNeverClobbersAnInFlightSession() {
        let env = makeEnv()
        env.selection.admitLibraryAssets(["lib1", "lib2", "lib3"])
        let model = SwipeReviewModel(items: libraryDeck(count: 3))
        env.mutateSelection { model.decide(.delete, selection: &$0) }

        model.installDeckIfNeeded(libraryDeck(count: 9))

        // Deck, cursor, and history are untouched — a later catalog write cannot rewind
        // a review that is already under way.
        #expect(model.items.count == 3)
        #expect(model.cursor == 1)
        #expect(model.history.count == 1)
        #expect(model.canUndo)
    }

    // MARK: Shuffle (Phase D)

    @Test func shuffleAndSessionCopyIsExact() {
        #expect(SwipeReviewPresentation.shuffleButtonTitle == "Shuffle")
        #expect(SwipeReviewPresentation.shuffleAccessibilityID == "swipeShuffleButton")
        #expect(SwipeReviewPresentation.shuffleAccessibilityLabel
                == "Shuffle the photos you have not reviewed yet")
        #expect(SwipeReviewPresentation.newPassButtonTitle == "Start New Pass")
        #expect(SwipeReviewPresentation.newPassAccessibilityID == "swipeNewPassButton")
        #expect(SwipeReviewPresentation.remainingCount(cursor: 3, total: 5) == 2)
        #expect(SwipeReviewPresentation.remainingCount(cursor: 0, total: 0) == 0)
        #expect(SwipeReviewPresentation.remainingCount(cursor: 5, total: 5) == 0)
        // The gate: fewer than two remaining photos has nothing to shuffle.
        #expect(!SwipeReviewPresentation.shuffleEnabled(remaining: 0))
        #expect(!SwipeReviewPresentation.shuffleEnabled(remaining: 1))
        #expect(SwipeReviewPresentation.shuffleEnabled(remaining: 2))
        #expect(SwipeReviewPresentation.shuffleEnabled(remaining: 50))
    }

    @Test func shuffleReordersOnlyTheUnreviewedTail() {
        let items = libraryDeck(count: 6)
        let model = SwipeReviewModel(items: items)
        var selection = PhotoSelectionModel(result: fixtureResult())
        selection.admitLibraryAssets(Set(items.map(\.assetID)))

        // Two decisions pin the reviewed prefix.
        model.decide(.delete, selection: &selection) // lib1 marked
        model.decide(.keep, selection: &selection)   // lib2 cleared
        #expect(model.cursor == 2)

        var generator = SeededGenerator(seed: 42)
        model.shuffleRemaining(using: &generator)

        // The prefix is byte-identical — a reviewed photo can never re-enter the pass.
        #expect(Array(model.items.prefix(2)) == [items[0], items[1]])
        // The tail is a permutation of the unreviewed photos: same photos, new order, and
        // (with this seed) an order that actually differs from the original.
        let originalTail = Array(items.dropFirst(2).map(\.assetID))
        let shuffledTail = model.items.dropFirst(2).map(\.assetID)
        #expect(Set(shuffledTail) == Set(originalTail))
        #expect(shuffledTail != originalTail)
        // Decisions, cursor, and undo are untouched by the reorder.
        #expect(model.cursor == 2)
        #expect(model.canUndo)
        #expect(model.decisions == ["lib1": .delete, "lib2": .keep])
        #expect(model.deleteDecisionCount == 1)
        #expect(selection.isSelected("lib1"))
        #expect(!selection.isSelected("lib2"))
    }

    @Test func shufflingThenSwipingTheWholePassNeverRepeatsAPhoto() {
        let items = libraryDeck(count: 8)
        let model = SwipeReviewModel(items: items)
        var selection = PhotoSelectionModel(result: fixtureResult())
        selection.admitLibraryAssets(Set(items.map(\.assetID)))

        var generator = SeededGenerator(seed: 7)
        model.shuffleRemaining(using: &generator)

        var visited: [String] = []
        while let current = model.currentItem {
            visited.append(current.assetID)
            model.decide(.delete, selection: &selection)
        }

        #expect(visited.count == 8)
        #expect(Set(visited).count == 8) // every photo exactly once — no repeats in a pass
        #expect(model.isComplete)
    }

    @Test func shuffleWithZeroOrOneRemainingIsANoOp() {
        let items = libraryDeck(count: 3)
        let model = SwipeReviewModel(items: items)
        var selection = PhotoSelectionModel(result: fixtureResult())
        selection.admitLibraryAssets(Set(items.map(\.assetID)))
        for _ in 0..<2 {
            model.decide(.keep, selection: &selection)
        }
        #expect(model.remainingCount == 1)

        var generator = SeededGenerator(seed: 99)
        model.shuffleRemaining(using: &generator)

        // One photo left: the order is untouched and the decision state is intact.
        #expect(model.items == items)
        #expect(model.cursor == 2)
        #expect(model.canUndo)
    }

    // MARK: Start New Pass (Phase D)

    @Test func startNewPassResetsTheCursorAndKeepsEveryDecision() {
        let items = libraryDeck(count: 4)
        let model = SwipeReviewModel(items: items)
        var selection = PhotoSelectionModel(result: fixtureResult())
        selection.admitLibraryAssets(Set(items.map(\.assetID)))

        model.decide(.delete, selection: &selection) // lib1 marked
        model.decide(.keep, selection: &selection)   // lib2 cleared
        #expect(model.cursor == 2)

        // The view rebuilds the library deck from the current catalog for a new pass; the
        // model takes whatever it is given, resets position and undo, and keeps the log.
        model.startNewPass(items: items)

        #expect(model.cursor == 0)
        #expect(model.history.isEmpty)
        #expect(!model.canUndo) // honestly unavailable — the new pass has recorded nothing
        #expect(model.currentItem?.assetID == "lib1")
        #expect(model.decisions == ["lib1": .delete, "lib2": .keep])
        #expect(model.deleteDecisionCount == 1)
        #expect(selection.isSelected("lib1")) // the shared selection is untouched by the reset
        #expect(!selection.isSelected("lib2"))
    }

    @Test func undoAcrossAPriorPassRestoresThePriorDecision() {
        let items = [item("e1")]
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: items)

        // Pass 1 marks the photo Delete…
        model.decide(.delete, selection: &env.selection)
        // …pass 2 reviews it again and keeps it, overwriting the log entry…
        model.startNewPass(items: items)
        model.decide(.keep, selection: &env.selection)
        #expect(model.decisions == ["e1": .keep])
        #expect(model.deleteDecisionCount == 0)

        // …and Undo restores the *prior pass's* decision, not a blank slate.
        model.undo(selection: &env.selection)
        #expect(model.decisions == ["e1": .delete])
        #expect(model.deleteDecisionCount == 1)
        #expect(env.selection.isSelected("e1"))
        #expect(model.cursor == 0)
    }

    // MARK: Session persistence (Phase D)

    @Test func saveAndRestoreRoundTripsTheExactSession() {
        let env = makeEnv()
        let items = libraryDeck(count: 5)
        let model = SwipeReviewModel(items: items)
        env.mutateSelection { $0.admitLibraryAssets(Set(items.map(\.assetID))) }

        model.decide(.delete, selection: &env.selection)
        model.decide(.keep, selection: &env.selection)
        model.decide(.delete, selection: &env.selection)
        var generator = SeededGenerator(seed: 3)
        model.shuffleRemaining(using: &generator)
        env.saveSwipeSession(from: model)

        // A relaunch: a brand-new model (as the screen constructs on appear) adopts the
        // persisted session exactly — deck order, position, undo stack, decisions.
        let restored = SwipeReviewModel(items: [])
        let snapshot = env.restoreSwipeSession()
        #expect(snapshot != nil)
        if let snapshot {
            restored.restore(from: snapshot)
        }
        #expect(restored.items == model.items)
        #expect(restored.cursor == model.cursor)
        #expect(restored.history == model.history)
        #expect(restored.decisions == model.decisions)
        #expect(restored.deleteDecisionCount == model.deleteDecisionCount)
        #expect(restored.canUndo)

        // Undo still works after restoration: the cursor moves back, the stack shrinks, and
        // the shared selection reverts the last decision (lib3's Delete → unmarked).
        let beforeUndo = env.selection
        #expect(beforeUndo.isSelected("lib3"))
        restored.undo(selection: &env.selection)
        #expect(restored.cursor == 2)
        #expect(restored.history.count == 2)
        #expect(restored.canUndo)
        #expect(!env.selection.isSelected("lib3"))
        #expect(env.selection.isSelected("lib1"))
    }

    @Test func restoreClampsABrokenCursorAndDropsADetachedUndoStack() {
        let items = libraryDeck(count: 3)
        let broken = SwipeReviewSessionSnapshot(
            items: items,
            cursor: 99, // beyond the deck — hand-edited or truncated file territory
            history: [SwipeReviewHistoryEntry(assetID: "lib1", wasSelected: true, priorDecision: nil)],
            decisions: ["lib1": .delete, "lib2": .keep]
        )
        let model = SwipeReviewModel(items: [])

        model.restore(from: broken)

        #expect(model.cursor == items.count) // clamped, never off the end
        #expect(model.history.isEmpty) // detached from the cursor — dropped, never rewinding
        #expect(model.decisions == ["lib1": .delete, "lib2": .keep])
        #expect(model.deleteDecisionCount == 1) // recomputed from the log, not trusted blindly
    }

    @Test func restoreIgnoresAnEmptySnapshot() {
        let model = SwipeReviewModel(items: libraryDeck(count: 2))
        model.restore(from: SwipeReviewSessionSnapshot()) // no session saved at all
        #expect(model.items.count == 2)
        #expect(model.cursor == 0)
    }

    @Test func restoreThenReapplyDecisionsRebuildsTheMarksAfterARelaunch() {
        let env = makeEnv()
        let result = fixtureResult()
        let items = SwipeReviewPresentation.items(from: result)
        let model = SwipeReviewModel(items: items)
        env.selection = PhotoSelectionModel(result: result)

        model.decide(.delete, selection: &env.selection) // e1 marked
        model.decide(.keep, selection: &env.selection)   // e2 cleared
        env.saveSwipeSession(from: model)

        // Relaunch: the selection is rebuilt from deterministic defaults (nothing marked),
        // the session is restored, and the log is replayed onto the fresh selection —
        // exactly what the screen's onAppear does.
        var rebuilt = PhotoSelectionModel(result: result)
        let restored = SwipeReviewModel(items: [])
        if let snapshot = env.restoreSwipeSession() {
            restored.restore(from: snapshot)
        }
        restored.reapplyDecisions(to: &rebuilt)

        #expect(restored.cursor == 2)
        #expect(rebuilt.isSelected("e1"))
        #expect(!rebuilt.isSelected("e2"))
        #expect(restored.canUndo)
        // Idempotent: replaying the same log twice converges, never flips.
        restored.reapplyDecisions(to: &rebuilt)
        #expect(rebuilt.isSelected("e1"))
        #expect(!rebuilt.isSelected("e2"))
    }

    @Test func snapshotCodableRoundTripIsExact() throws {
        let items = libraryDeck(count: 3)
        let snapshot = SwipeReviewSessionSnapshot(
            items: items,
            cursor: 2,
            history: [
                SwipeReviewHistoryEntry(assetID: "lib1", wasSelected: false, priorDecision: nil),
                SwipeReviewHistoryEntry(assetID: "lib2", wasSelected: true, priorDecision: .keep),
            ],
            decisions: ["lib1": .delete, "lib2": .keep]
        )

        let decoded = try JSONDecoder().decode(
            SwipeReviewSessionSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded == snapshot)
    }

    @Test func fileStoreRoundTripsAndRejectsForeignSchemasAndCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swipe-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSwipeReviewSessionStore(directoryOverride: directory)
        let snapshot = SwipeReviewSessionSnapshot(
            items: libraryDeck(count: 2),
            cursor: 1,
            decisions: ["lib1": .delete]
        )

        // Round trip: save hands off to the write drain, so wait for the write, then load.
        store.save(snapshot)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.load() != snapshot, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.load() == snapshot)

        // Future schema: dropped whole — a fresh session, never a misread one.
        let foreign = """
        {"schemaVersion":999,"items":[],"cursor":0,"history":[],"decisions":{}}
        """
        try Data(foreign.utf8).write(to: directory.appendingPathComponent("session.json"))
        #expect(store.load() == nil)

        // Corrupt bytes: same contract — unreadable reads as "no session".
        try Data([0x00, 0x01, 0x02]).write(to: directory.appendingPathComponent("session.json"))
        #expect(store.load() == nil)
    }

    // MARK: Review Cleanup candidates (Phase D)

    @Test func cleanupCandidatesIncludeOnlySessionDeleteMarksStillSelectedAndPresent() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) } // e1 marked
        env.mutateSelection { model.decide(.keep, selection: &$0) }   // e2 cleared
        // e3 and n1 were never reviewed — e3 is selected by default but is NOT a candidate:
        // only this session's Delete marks qualify.
        #expect(env.selection.selectedIDs == ["e1", "e3"])

        #expect(model.cleanupCandidates(selection: env.selection).map(\.assetID) == ["e1"])

        // Unmarked in the shared selection since the swipe → not a candidate anymore.
        env.mutateSelection { $0.setSelected(false, forAsset: "e1") }
        #expect(model.cleanupCandidates(selection: env.selection).isEmpty)

        // Deleted from the catalog since the swipe → filtered by the available set.
        env.mutateSelection { $0.setSelected(true, forAsset: "e1") }
        #expect(model.cleanupCandidates(selection: env.selection, availableAssetIDs: ["e2", "e3"])
            .isEmpty)
        #expect(model.cleanupCandidates(selection: env.selection, availableAssetIDs: ["e1", "e3"])
            .map(\.assetID) == ["e1"])
    }

    @Test func cleanupCandidatesPreserveDeckOrder() {
        let env = makeEnv()
        let items = libraryDeck(count: 6)
        let model = SwipeReviewModel(items: items)
        env.mutateSelection { $0.admitLibraryAssets(Set(items.map(\.assetID))) }

        // Mark lib6, lib2, lib5 (out of order) — the candidate list follows the deck.
        model.decide(.keep, selection: &env.selection)   // lib1
        model.decide(.delete, selection: &env.selection) // lib2
        model.decide(.keep, selection: &env.selection)   // lib3
        model.decide(.keep, selection: &env.selection)   // lib4
        model.decide(.delete, selection: &env.selection) // lib5
        model.decide(.delete, selection: &env.selection) // lib6

        let candidates = model.cleanupCandidates(selection: env.selection)
        #expect(candidates.map(\.assetID) == ["lib2", "lib5", "lib6"])
    }

    @Test func largeDeckCleanupScopingIsExactAndNonMutating() {
        let env = makeEnv()
        let items = libraryDeck(count: 1_000)
        let model = SwipeReviewModel(items: items)
        env.mutateSelection { $0.admitLibraryAssets(Set(items.map(\.assetID))) }

        // Every second photo marked — the scoping must read the existing deck, never
        // rebuild or re-sort it (the "large library" contract).
        for (index, _) in items.enumerated() {
            model.decide(index.isMultiple(of: 2) ? .delete : .keep, selection: &env.selection)
        }
        #expect(model.deleteDecisionCount == 500)
        let deckBefore = model.items

        let candidates = model.cleanupCandidates(selection: env.selection)

        #expect(candidates.count == 500)
        let expectedIDs = items.enumerated()
            .filter { $0.offset.isMultiple(of: 2) }
            .map { $0.element.assetID }
        #expect(candidates.map(\.assetID) == expectedIDs)
        #expect(model.items == deckBefore) // scoping is a read — the deck never moves
        #expect(env.selection.selectedCount == 500)
    }

    // MARK: Review Cleanup selection state (Phase D)

    @Test func candidatesDefaultToCheckedWithExactCounts() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        model.decide(.delete, selection: &env.selection) // e1
        model.decide(.keep, selection: &env.selection)   // e2
        model.decide(.delete, selection: &env.selection) // e3

        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))

        #expect(env.swipeCleanupCandidates.map(\.assetID) == ["e1", "e3"])
        #expect(env.swipeCleanupCheckedIDs == ["e1", "e3"]) // default: everything checked
        #expect(env.swipeCleanupCheckedCount == 2)
        #expect(SwipeReviewPresentation.selectedOfTotalText(selected: 2, total: 2)
                == "2 of 2 selected")
        #expect(SwipeReviewPresentation.reviewButtonTitle(2) == "Review 2 Photos")
    }

    @Test func individualBulkAndReentrySelectionBehavior() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        model.decide(.delete, selection: &env.selection) // e1
        model.decide(.keep, selection: &env.selection)   // e2
        model.decide(.delete, selection: &env.selection) // e3

        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))

        // Individual toggle.
        env.setSwipeCleanupChecked("e1", checked: false)
        #expect(env.swipeCleanupCheckedIDs == ["e3"])
        #expect(env.swipeCleanupCheckedCount == 1)
        // A toggle for a non-candidate is refused, not silently stored.
        env.setSwipeCleanupChecked("n1", checked: false)
        #expect(env.swipeCleanupCheckedIDs == ["e3"])

        // Bulk.
        env.deselectAllSwipeCleanup()
        #expect(env.swipeCleanupCheckedCount == 0)
        #expect(!SwipeReviewPresentation.reviewCleanupEnabled(selectedCount: 0))
        env.selectAllSwipeCleanup()
        #expect(env.swipeCleanupCheckedIDs == ["e1", "e3"])

        // Re-entering preserves explicit choices…
        env.setSwipeCleanupChecked("e3", checked: false)
        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))
        #expect(env.swipeCleanupCheckedIDs == ["e1"])

        // …and the session keeps going: a later Delete mark (n1) joins already selected,
        // while e3's explicit "no" sticks — choices are keyed by asset, not by position.
        model.decide(.delete, selection: &env.selection) // n1 → marked (cursor 3 → 4)
        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))
        #expect(env.swipeCleanupCandidates.map(\.assetID) == ["e1", "e3", "n1"])
        #expect(env.swipeCleanupCheckedIDs == ["e1", "n1"])
        #expect(env.swipeCleanupCheckedCount == 2)
    }

    // MARK: Review Cleanup through the existing deletion pipeline (Phase D)

    @Test func confirmationDeletesExactlyTheCheckedSubset() async {
        let service = RecordingCleanupDeletionService(
            outcome: .succeeded(DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: []))
        )
        let env = makeReviewReadyEnv(deletionService: service)
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        model.decide(.delete, selection: &env.selection) // e1
        model.decide(.keep, selection: &env.selection)   // e2
        model.decide(.delete, selection: &env.selection) // e3

        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))
        env.setSwipeCleanupChecked("e3", checked: false) // the user unchecks e3

        env.reviewDidAppear(from: .swipeReview)
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["e1"]) // the plan is the checked subset only

        env.beginConfirmation()
        await env.confirmDeletion()

        // The service saw exactly the checked, still-selected, catalog-validated assets —
        // e3 was never in the plan and never in the execution context.
        #expect(service.executedSelectionIDs.count == 1)
        #expect(service.executedSelectionIDs.first == ["e1"])
        #expect(env.deletionState == .succeeded(DeletionSuccess(
            plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: []
        )))
    }

    @Test func uncheckingAfterThePlanIsBuiltStalesItBeforeAnyMutation() async {
        let service = RecordingCleanupDeletionService(
            outcome: .succeeded(DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: []))
        )
        let env = makeReviewReadyEnv(deletionService: service)
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        model.decide(.delete, selection: &env.selection)

        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))
        env.reviewDidAppear(from: .swipeReview)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        // The user unchecks the only candidate while the plan is on screen: the plan is
        // immediately stale — the same selectionChanged contract every other source uses.
        env.setSwipeCleanupChecked("e1", checked: false)
        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.selectionChanged])

        // Confirmation and execution refuse a stale plan — zero assets touched.
        env.beginConfirmation()
        await env.confirmDeletion()
        #expect(service.executedSelectionIDs.isEmpty)
    }

    @Test func unmarkingAfterThePlanIsBuiltStalesItThroughTheSharedSelection() async {
        let env = makeReviewReadyEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        model.decide(.delete, selection: &env.selection)

        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))
        env.reviewDidAppear(from: .swipeReview)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        // The grid unchecks the same photo while the swipe-cleanup plan is live: the
        // checked ∩ selected snapshot moved, so the plan stale-s immediately.
        env.mutateSelection { $0.setSelected(false, forAsset: "e1") }
        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.selectionChanged])
    }

    @Test func cleanupChoiceChangesNeverStaleAPlanFromAnotherSource() async {
        let env = makeReviewReadyEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        model.decide(.delete, selection: &env.selection)

        // Candidates exist, but the live plan came from the Similar Photos grid.
        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))
        env.reviewDidAppear(from: .similarPhotos)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.setSwipeCleanupChecked("e1", checked: false)
        env.selectAllSwipeCleanup()

        // A similar-photos plan only goes stale when the *shared selection* moves — cleanup
        // toggles are scoped to the swipe flow and must not fake staleness here.
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected the similarPhotos plan to stay ready, got \(env.deletionState)")
            return
        }
    }

    @Test func partialFailuresAreReportedHonestly() async {
        let service = RecordingCleanupDeletionService(
            // PhotoKit removed nothing that time — the remaining ID keeps the outcome
            // partial, and the state machine must say so rather than claim success.
            outcome: .succeeded(DeletionSuccess(
                plannedCount: 1, verifiedRemovedCount: 0, remainingIDs: ["e1"]
            ))
        )
        let env = makeReviewReadyEnv(deletionService: service)
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        model.decide(.delete, selection: &env.selection)

        env.enterSwipeCleanup(model.cleanupCandidates(selection: env.selection))
        env.reviewDidAppear(from: .swipeReview)
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .needsReview(let success) = env.deletionState else {
            Issue.record("expected needsReview for a partial outcome, got \(env.deletionState)")
            return
        }
        #expect(success.remainingIDs == ["e1"])
        #expect(!success.isFullyRemoved)
    }

    @Test func aCandidateMissingFromTheCatalogNeverEntersThePlan() async {
        let service = RecordingCleanupDeletionService(
            outcome: .succeeded(DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: []))
        )
        let env = makeReviewReadyEnv(deletionService: service)
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        model.decide(.delete, selection: &env.selection) // e1
        model.decide(.keep, selection: &env.selection)   // e2
        model.decide(.delete, selection: &env.selection) // e3

        // e3 vanished from the catalog between the swipe and the cleanup screen: the enter
        // pass filters it out against the live records, before any plan can see it.
        env.enterSwipeCleanup(
            model.cleanupCandidates(
                selection: env.selection,
                availableAssetIDs: ["e1", "e2", "n1"]
            )
        )
        #expect(env.swipeCleanupCheckedIDs == ["e1"])

        env.reviewDidAppear(from: .swipeReview)
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["e1"])

        env.beginConfirmation()
        await env.confirmDeletion()
        #expect(service.executedSelectionIDs.first == ["e1"])
    }

    // MARK: Thumbnail prefetch (M14)

    /// The warm-up order is the current photo first, then a bounded forward window —
    /// clamped at the deck's end, never backward, and safe on empty or out-of-range input.
    @Test func prefetchOrderIsCurrentFirstThenForwardAndBounded() {
        let ids = (0..<50).map { "p-\($0)" }

        let head = SwipeReviewPresentation.prefetchOrder(around: 0, in: ids)
        #expect(head.first == "p-0")
        #expect(head.count == SwipeReviewPresentation.swipePrefetchWindowCount)
        #expect(head == Array(ids.prefix(SwipeReviewPresentation.swipePrefetchWindowCount)))

        let mid = SwipeReviewPresentation.prefetchOrder(around: 10, in: ids)
        #expect(mid.first == "p-10")
        #expect(mid == Array(ids[10..<10 + SwipeReviewPresentation.swipePrefetchWindowCount]))
        // Forward only: no reviewed photo behind the cursor is ever warmed.
        #expect(!mid.contains("p-9"))

        let tail = SwipeReviewPresentation.prefetchOrder(around: 45, in: ids)
        #expect(tail == Array(ids[45...]))

        let empty = SwipeReviewPresentation.prefetchOrder(around: 0, in: [])
        #expect(empty.isEmpty)
        let negative = SwipeReviewPresentation.prefetchOrder(around: -3, in: ids)
        #expect(negative.isEmpty)
    }

    /// The prefetcher walks the window through the shared store in priority order — the
    /// current photo first — with two local-only tiers (M15): the low-resolution frame for
    /// the whole window, and the screen-sized final for the current photo and the next few.
    /// Never the large preview's network path, never full-resolution.
    @Test func thePrefetcherWarmsTheWindowThroughTheStoreCurrentFirst() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(loader: RecordingPrefetchLoader(log: log), capacity: 96)
        let prefetcher = SwipeThumbnailPrefetcher()
        let ids = ["current", "fwd-1", "fwd-2", "fwd-3"]

        prefetcher.warm(order: ids, store: store)

        let expected = ids.count * 2 // every id: low-res then screen-sized (within sharp count)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while log.requestedIDs().count < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        // Priority order survives the walk: per asset the fast low-resolution frame lands
        // first and the screen-sized final follows, the on-screen photo leading.
        let expectedIDs = ids.flatMap { [$0, $0] }
        let expectedSizes = ids.flatMap { _ in
            [SwipeReviewPresentation.swipeThumbnailLowResPixelSize,
             SwipeReviewPresentation.swipeThumbnailPixelSize]
        }
        #expect(log.requestedIDs() == expectedIDs)
        #expect(log.pixelSizes == expectedSizes)
        // Neither tier is the large preview's target; routine swipes never fetch it.
        #expect(SwipeReviewPresentation.swipeThumbnailPixelSize
            < SimilarPhotosPresentation.previewTargetPixelSize)
        #expect(log.pixelSizes.allSatisfy { $0 <= SwipeReviewPresentation.swipeThumbnailPixelSize })
    }

    /// Beyond the "next few", only the low-resolution tier is warmed — the screen-sized
    /// tier stays bounded to the prioritized head of the window (M15).
    @Test func theScreenSizedTierIsBoundedToThePrioritizedHeadOfTheWindow() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(loader: RecordingPrefetchLoader(log: log), capacity: 96)
        let prefetcher = SwipeThumbnailPrefetcher()
        let ids = (0..<10).map { "p-\($0)" }

        prefetcher.warm(order: ids, store: store)

        let expected = ids.count + SwipeReviewPresentation.swipeSharpPrefetchCount
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while log.requestedIDs().count < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(log.requestedIDs().count == expected)
        let sharpRequests = zip(log.requestedIDs(), log.pixelSizes)
            .filter { $0.1 == SwipeReviewPresentation.swipeThumbnailPixelSize }
        // Exactly the current photo and the next few get the sharp tier, in order.
        #expect(sharpRequests.map(\.0) == Array(ids.prefix(SwipeReviewPresentation.swipeSharpPrefetchCount)))
    }

    /// A new window (cursor advance, Shuffle, Start New Pass) supersedes the old walk:
    /// the remaining old IDs are never requested once the deck under the window changed.
    @Test func aNewWindowSupersedesTheOldWalk() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(
            loader: RecordingPrefetchLoader(log: log, delayNanoseconds: 30_000_000),
            capacity: 96
        )
        let prefetcher = SwipeThumbnailPrefetcher()

        prefetcher.warm(order: ["old-1", "old-2", "old-3", "old-4", "old-5"], store: store)
        prefetcher.warm(order: ["new-1", "new-2"], store: store)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !log.requestedIDs().contains("new-2"), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let requested = log.requestedIDs()
        #expect(requested.contains("new-1"))
        #expect(requested.contains("new-2"))
        // The superseded walk stopped early — its tail was never issued.
        #expect(!requested.contains("old-5"))
    }

    /// Cache-to-display integration (M15): a prefetched thumbnail is reused by the display
    /// path — the card's frame resolves from the warmed store without a second load, and
    /// without ever presenting a loading state over available pixels.
    @Test func aPrefetchedThumbnailIsReusedByTheDisplayPath() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(loader: RecordingPrefetchLoader(log: log), capacity: 96)
        let prefetcher = SwipeThumbnailPrefetcher()
        let model = SwipeCardFrameModel()

        prefetcher.warm(order: ["warm-me"], store: store)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while log.requestedIDs().count < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let loadsAfterWarm = log.requestedIDs().count

        model.prepare(assetID: "warm-me", store: store)
        let settle = ContinuousClock.now.advanced(by: .seconds(5))
        while model.phase.isDisplayable == false, ContinuousClock.now < settle {
            try? await Task.sleep(for: .milliseconds(5))
        }

        guard case .final = model.phase else {
            Issue.record("expected the warmed frame to display, got \(model.phase)")
            return
        }
        // The display path hit the cache: no further PhotoKit requests.
        #expect(log.requestedIDs().count == loadsAfterWarm)
    }

    /// A warm screen-sized key renders without entering a loading state at all (M15):
    /// "Loading photo…" never covers pixels that are already available.
    @Test func aCachedNextImageDoesNotEnterAnUnnecessaryLoadingState() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(loader: RecordingPrefetchLoader(log: log), capacity: 96)
        let prefetcher = SwipeThumbnailPrefetcher()
        let model = SwipeCardFrameModel()
        prefetcher.warm(order: ["next"], store: store)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while log.requestedIDs().count < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        var seen: [SwipeCardFrameModel.Phase] = [model.phase]
        let subscription = model.$phase.sink { seen.append($0) }
        defer { subscription.cancel() }

        model.prepare(assetID: "next", store: store)
        let settle = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.phase.isDisplayable, ContinuousClock.now < settle {
            try? await Task.sleep(for: .milliseconds(5))
        }

        guard case .final = model.phase else {
            Issue.record("expected final, got \(model.phase)")
            return
        }
        #expect(!seen.contains(.loading))
    }

    /// A low-resolution preview is only ever a temporary stand-in (M15): it shows while
    /// the screen-sized thumbnail prepares and is replaced by it the moment it lands.
    @Test func aLowResolutionPreviewIsReplacedByTheFinalThumbnail() async {
        let log = PrefetchCallLog()
        let loader = RecordingPrefetchLoader(log: log, delayNanoseconds: 20_000_000)
        let store = ThumbnailStore(loader: loader, capacity: 96)
        let model = SwipeCardFrameModel()

        // Only the low-resolution tier warm (the screen-sized load will take ~20 ms).
        _ = try? await store.image(
            for: "soft",
            targetPixelSize: SwipeReviewPresentation.swipeThumbnailLowResPixelSize
        )

        var seen: [SwipeCardFrameModel.Phase] = [model.phase]
        let subscription = model.$phase.sink { seen.append($0) }
        defer { subscription.cancel() }

        model.prepare(assetID: "soft", store: store)
        let settle = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < settle {
            if case .final = model.phase { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        guard case .final = model.phase else {
            Issue.record("expected the final screen-sized thumbnail, got \(model.phase)")
            return
        }
        // The temporary low-resolution frame appeared and was replaced — it never stood
        // as the final sharp image.
        let sawTemporary = seen.contains { phase in
            if case .temporary = phase { return true }
            return false
        }
        #expect(sawTemporary)
    }

    /// Stopping the prefetcher (the screen is going away) ends the walk; the store keeps
    /// whatever was already warmed.
    @Test func stoppingThePrefetcherEndsTheWalk() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(
            loader: RecordingPrefetchLoader(log: log, delayNanoseconds: 30_000_000),
            capacity: 96
        )
        let prefetcher = SwipeThumbnailPrefetcher()
        let ids = (1...10).map { "s-\($0)" }

        prefetcher.warm(order: ids, store: store)
        prefetcher.stop()

        try? await Task.sleep(for: .milliseconds(120))
        let requested = log.requestedIDs()
        // The walk stopped at cancellation — never the whole window.
        #expect(requested.count < ids.count)
    }

    // MARK: Frame identity & staleness (M15)

    /// Fast consecutive swipes never display an image belonging to the wrong asset: the
    /// frame model tags every phase with its asset, and each card's pixels carry their
    /// asset's identity.
    @Test func fastConsecutiveSwipesNeverDisplayAnotherAssetsFrame() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(loader: RecordingPrefetchLoader(log: log), capacity: 96)
        let model = SwipeCardFrameModel()

        model.prepare(assetID: "asset-a", store: store)
        model.prepare(assetID: "asset-b", store: store) // the swipe lands before A settles

        let settle = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.phase.isDisplayable, ContinuousClock.now < settle {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(model.assetID == "asset-b")
        guard case .final(let frame) = model.phase else {
            Issue.record("expected a final frame for asset-b, got \(model.phase)")
            return
        }
        #expect(pixelTone(frame) == referenceTone(for: "asset-b"))
        #expect(pixelTone(frame) != referenceTone(for: "asset-a"))
    }

    /// A stale callback from a previous cursor or deck generation can never overwrite the
    /// currently selected photo (M15): the late frame is discarded, not displayed.
    @Test func aStaleCallbackCannotOverwriteTheCurrentCursor() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(
            loader: RecordingPrefetchLoader(log: log, delayNanoseconds: 40_000_000),
            capacity: 96
        )
        let model = SwipeCardFrameModel()

        model.prepare(assetID: "slow-old", store: store)
        try? await Task.sleep(for: .milliseconds(5))
        model.prepare(assetID: "quick-new", store: store)

        let settle = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.phase.isDisplayable, ContinuousClock.now < settle {
            try? await Task.sleep(for: .milliseconds(5))
        }
        // Both loads have landed by now; the old one's late completion must be a no-op.
        try? await Task.sleep(for: .milliseconds(60))

        #expect(model.assetID == "quick-new")
        guard case .final(let frame) = model.phase else {
            Issue.record("expected a final frame for quick-new, got \(model.phase)")
            return
        }
        #expect(pixelTone(frame) == referenceTone(for: "quick-new"))
    }

    /// Shuffle, Undo, and session restoration keep the prefetch window aligned with the
    /// cursor (M15): the window always starts at the photo on screen, forward only.
    @Test func shuffleUndoAndRestorationKeepThePrefetchWindowAligned() {
        let deck = libraryDeck(count: 8)
        let ids = deck.map(\.assetID)
        let model = SwipeReviewModel(items: deck)
        var selection = PhotoSelectionModel()

        // Advance twice, then Undo: the window follows the cursor back.
        model.decide(.keep, selection: &selection)
        model.decide(.keep, selection: &selection)
        model.undo(selection: &selection)
        let afterUndo = SwipeReviewPresentation.prefetchOrder(around: model.cursor, in: ids)
        #expect(afterUndo.first == model.currentItem?.assetID)
        #expect(!afterUndo.dropFirst().contains(model.items[model.cursor - 1].assetID))

        // Shuffle re-orders only the unreviewed tail — the window still leads with the
        // current photo and still walks forward through the *new* order.
        var generator = SeededGenerator(seed: 42)
        model.shuffleRemaining(using: &generator)
        let afterShuffle = SwipeReviewPresentation.prefetchOrder(around: model.cursor, in: model.items.map(\.assetID))
        #expect(afterShuffle.first == model.currentItem?.assetID)

        // A restored session lands at its saved cursor — the window starts there.
        let restored = SwipeReviewModel(items: [])
        restored.restore(from: SwipeReviewSessionSnapshot(
            items: deck,
            cursor: 5,
            history: [],
            decisions: [:]
        ))
        let afterRestore = SwipeReviewPresentation.prefetchOrder(around: restored.cursor, in: ids)
        #expect(afterRestore.first == ids[5])
    }

    /// Request count and concurrent decoding stay bounded (M15): the walk issues exactly
    /// the window's two-tier requests, sequentially — one PhotoKit request at a time.
    @Test func theWalkKeepsRequestCountAndDecodingBounded() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(
            loader: RecordingPrefetchLoader(log: log, delayNanoseconds: 2_000_000),
            capacity: 96
        )
        let prefetcher = SwipeThumbnailPrefetcher()
        let ids = (0..<12).map { "b-\($0)" }

        prefetcher.warm(order: ids, store: store)
        let expected = ids.count + SwipeReviewPresentation.swipeSharpPrefetchCount
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while log.requestedIDs().count < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(log.requestedIDs().count == expected)
        #expect(log.maxConcurrentRequests == 1)
    }

    /// A failed or unavailable image request does not stall the deck (M15): the card
    /// settles into an honest unavailable state and the next card prepares normally.
    @Test func aFailedRequestDoesNotStallTheDeck() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(
            loader: RecordingPrefetchLoader(log: log, failingAssetIDs: ["broken"]),
            capacity: 96
        )
        let model = SwipeCardFrameModel()

        model.prepare(assetID: "broken", store: store)
        let settle = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.phase.isDisplayable, ContinuousClock.now < settle {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard case .unavailable = model.phase else {
            Issue.record("expected an honest unavailable state, got \(model.phase)")
            return
        }

        // The deck keeps working: the next card is a fresh generation and displays.
        model.prepare(assetID: "healthy", store: store)
        let settleNext = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < settleNext {
            if case .final = model.phase { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard case .final = model.phase else {
            Issue.record("expected the next card to display, got \(model.phase)")
            return
        }
    }

    /// The prefetch window remains capped and routine swipe display never requests
    /// full-resolution images (M15): the window is bounded, and every request the swipe
    /// path makes is a screen-sized (or smaller) local rendition.
    @Test func theWindowStaysCappedAndNeverRequestsFullResolutionImages() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(loader: RecordingPrefetchLoader(log: log), capacity: 96)
        let prefetcher = SwipeThumbnailPrefetcher()
        let ids = (0..<200).map { "f-\($0)" }

        let order = SwipeReviewPresentation.prefetchOrder(around: 0, in: ids)
        #expect(order.count == SwipeReviewPresentation.swipePrefetchWindowCount)

        prefetcher.warm(order: order, store: store)
        let expected = order.count + SwipeReviewPresentation.swipeSharpPrefetchCount
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while log.requestedIDs().count < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(log.requestedIDs().count == expected)
        #expect(log.pixelSizes.allSatisfy { $0 <= SwipeReviewPresentation.swipeThumbnailPixelSize })
        #expect(log.pixelSizes.allSatisfy { $0 < SimilarPhotosPresentation.previewTargetPixelSize })
    }

    /// Cache keys match between prefetch and display (M15): both go through the store at
    /// the same two rendition sizes — a warmed key is *the* key the card reads, and no
    /// third rendition is ever requested for routine swipe display.
    @Test func prefetchAndDisplayRequestTheSameRenditions() async {
        let log = PrefetchCallLog()
        let store = ThumbnailStore(loader: RecordingPrefetchLoader(log: log), capacity: 96)
        let prefetcher = SwipeThumbnailPrefetcher()
        let model = SwipeCardFrameModel()

        prefetcher.warm(order: ["shared"], store: store)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while log.requestedIDs().count < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        model.prepare(assetID: "shared", store: store)
        let settle = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.phase.isDisplayable, ContinuousClock.now < settle {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let renditions = Set(log.requests.map { $0.1 })
        let allShared = log.requests.allSatisfy { $0.0 == "shared" }
        #expect(renditions == [
            SwipeReviewPresentation.swipeThumbnailLowResPixelSize,
            SwipeReviewPresentation.swipeThumbnailPixelSize
        ])
        #expect(allShared)
    }
}

// MARK: - Helpers

@MainActor
private func waitForPlanReady(
    _ env: AppEnvironment,
    timeoutMilliseconds: Int = 5_000
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while env.deletionState.isBuildingPlan, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Two groups with one shared member (`e2`), so ordering, deduplication, and per-group
/// context all have something real to operate on. Default selection: everything except the
/// protected KEEPs (`e1`, `n1`) → `{e2, e3}`.
private func fixtureResult() -> PhotoAnalysisResult {
    PhotoAnalysisResult(
        exactGroups: [
            PhotoSimilarityGroup(
                kind: .exactDuplicates,
                memberAssetIDs: ["e1", "e2", "e3"],
                evidence: .exactContent(fingerprint: "f", byteLength: 100),
                recommendedBestAssetID: "e1",
                memberScores: [:]
            ),
        ],
        similarGroups: [
            PhotoSimilarityGroup(
                kind: .nearDuplicates,
                memberAssetIDs: ["e2", "n1"],
                evidence: .visualSimilarity(minDistance: 0.1, maxDistance: 0.4, threshold: 0.6),
                recommendedBestAssetID: "n1",
                memberScores: [:]
            ),
        ],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: 0.6,
        totalRecordCount: 4,
        candidateBucketCount: 2,
        candidatePairCount: 4
    )
}

private func item(_ assetID: String) -> SwipeReviewItem {
    SwipeReviewItem(assetID: assetID, groupKind: .exactDuplicates, groupOrdinal: 1, isRecommended: false)
}

/// The standalone library deck the dashboard's Swipe Review pushes: items outside every
/// group, marked `isLibraryItem` exactly as `SwipeReviewPresentation.items(from: catalog)`
/// builds them — the path the persistent review bar's zero-at-start state runs on.
private func libraryDeck(count: Int) -> [SwipeReviewItem] {
    (1...count).map { index in
        SwipeReviewItem(
            assetID: "lib\(index)",
            groupKind: .nearDuplicates,
            groupOrdinal: 0,
            isRecommended: false,
            isLibraryItem: true
        )
    }
}

@MainActor
private func makeEnv(
    calls: CallCounter? = nil,
    deletionService: any PhotoDeleting = CountingDeletionService(),
    sessionStore: any SwipeReviewSessionStore = InMemorySwipeReviewSessionStore()
) -> AppEnvironment {
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        makePhotoLibrary: {
            calls?.increment()
            return FakeLibrary(records: [])
        },
        deletionService: deletionService,
        // Completions in this suite must never touch the app's real persisted snapshot.
        scanSnapshotStore: InMemoryScanSnapshotStore(),
        // Likewise the session file: restoration tests read this store, never Application
        // Support, so results are deterministic and leave no files behind.
        swipeSessionStore: sessionStore
    )
    env.photoPermissionState = .authorized
    return env
}

/// An environment whose catalog and permissions are complete enough for the existing review
/// flow to prepare a plan — the handoff target of the completion state's "Review Cleanup".
@MainActor
private func makeReviewReadyEnv(
    deletionService: any PhotoDeleting = CountingDeletionService(),
    sessionStore: any SwipeReviewSessionStore = InMemorySwipeReviewSessionStore()
) -> AppEnvironment {
    let records = ["e1", "e2", "e3", "n1"].map { makeRecord(id: $0) }
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        photoPermission: FakePermissionService(.authorized),
        sizeProvider: FakeSizeProvider(),
        deletionService: deletionService,
        scanSnapshotStore: InMemoryScanSnapshotStore(),
        swipeSessionStore: sessionStore
    )
    env.photoPermissionState = .authorized
    env.catalogState = .completed(CatalogScanResult(
        records: records,
        libraryAssetCount: records.count,
        accessLevel: .authorized
    ))
    return env
}

/// Call counter for the injected library factory. Only ever touched from the main actor
/// (the factory is invoked synchronously inside `AppEnvironment`), so an unchecked box is
/// safe here.
private final class CallCounter: @unchecked Sendable {
    private var calls = 0

    func increment() { calls += 1 }
    var count: Int { calls }
}

/// Counts executions so "no PhotoKit deletion from Swipe Review" is an assertion, not an
/// inference from state alone.
private final class CountingDeletionService: PhotoDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func execute(
        _ confirmed: ConfirmedDeletionPlan,
        in context: PlanExecutionContext
    ) async -> DeletionOutcome {
        recordCall()
        return .succeeded(DeletionSuccess(plannedCount: 0, verifiedRemovedCount: 0, remainingIDs: []))
    }

    // Synchronous so `NSLock` (unavailable in async contexts) can be used safely.
    private func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class FakePermissionService: PhotoLibraryPermissionServicing, @unchecked Sendable {
    private let state: PermissionState

    init(_ state: PermissionState) {
        self.state = state
    }

    func currentStatus() -> PermissionState { state }
    func requestAccess() async -> PermissionState { state }
}

private struct FakeSizeProvider: AssetSizeProviding {
    func sizes(for localIdentifiers: [String]) async -> [String: Int64] { [:] }
}

private struct FakeStorage: StorageProviding {
    func deviceStorage() async -> StorageSnapshot {
        StorageSnapshot(totalCapacity: 100, availableCapacity: 60)
    }
}

private struct FakeLibrary: PhotoLibraryReading {
    let accessLevel: PermissionState = .authorized
    let records: [PhotoAssetRecord]

    func assetCount() throws -> Int {
        records.count
    }

    func records(in range: Range<Int>) throws -> [PhotoAssetRecord] {
        let lower = max(0, range.lowerBound)
        let upper = min(range.upperBound, records.count)
        guard lower < upper else { return [] }
        return Array(records[lower..<upper])
    }
}

private func makeRecord(id: String) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: .image,
        mediaSubtypes: [],
        pixelWidth: 1000,
        pixelHeight: 1000,
        creationDate: Date(timeIntervalSince1970: 1_750_000_000),
        modificationDate: nil,
        duration: 0,
        isFavorite: false,
        isHidden: false,
        sourceType: .library,
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil
    )
}

/// Deterministic generator (splitmix64) so shuffle tests assert exact behavior instead of
/// probabilistic behavior — one seed, one order, on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// In-memory session store so restoration tests are deterministic and leave no files on
/// disk — the same seam `scanSnapshotStore` provides for checkpoint tests.
private final class InMemorySwipeReviewSessionStore: SwipeReviewSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SwipeReviewSessionSnapshot?

    func load() -> SwipeReviewSessionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ snapshot: SwipeReviewSessionSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        stored = snapshot
    }
}

/// Records the execution context every confirmation passed to the service, so "only the
/// checked subset is deleted" is an assertion about what the pipeline actually saw.
private final class RecordingCleanupDeletionService: PhotoDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [Set<String>] = []
    private let outcome: DeletionOutcome

    init(outcome: DeletionOutcome) {
        self.outcome = outcome
    }

    func execute(
        _ confirmed: ConfirmedDeletionPlan,
        in context: PlanExecutionContext
    ) async -> DeletionOutcome {
        record(context.selectionIDs)
        return outcome
    }

    // Synchronous so `NSLock` (unavailable in async contexts) can be used safely.
    private func record(_ selectionIDs: Set<String>) {
        lock.lock()
        contexts.append(selectionIDs)
        lock.unlock()
    }

    var executedSelectionIDs: [Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        return contexts
    }
}

// MARK: - Thumbnail prefetch helpers (M14/M15)

/// Request recorder shared with the prefetch loader: asset IDs in request order, the exact
/// target pixel size each request asked for (the no-full-resolution proof), and a
/// concurrency gauge (the bounded-decoding proof).
private final class PrefetchCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private var sizes: [Int] = []
    private var active = 0
    private var peakActive = 0

    func record(assetID: String, targetPixelSize: Int) {
        lock.lock()
        defer { lock.unlock() }
        ids.append(assetID)
        sizes.append(targetPixelSize)
    }

    func beginRequest() {
        lock.lock()
        defer { lock.unlock() }
        active += 1
        peakActive = max(peakActive, active)
    }

    func endRequest() {
        lock.lock()
        defer { lock.unlock() }
        active -= 1
    }

    func requestedIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    var pixelSizes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sizes
    }

    /// The (assetID, pixelSize) pairs in request order — the cache-key match proof.
    var requests: [(String, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return Array(zip(ids, sizes))
    }

    /// The most requests ever in flight at once — the bounded-decoding proof.
    var maxConcurrentRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakActive
    }
}

private struct RecordingPrefetchLoader: PhotoThumbnailLoading {
    let log: PrefetchCallLog
    var delayNanoseconds: UInt64 = 0
    var failingAssetIDs: Set<String> = []

    func thumbnail(
        for assetID: String,
        targetPixelSize: Int,
        mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage {
        log.record(assetID: assetID, targetPixelSize: targetPixelSize)
        log.beginRequest()
        defer { log.endRequest() }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if failingAssetIDs.contains(assetID) {
            throw PhotoContentError.unavailable
        }
        return Self.tonedImage(side: targetPixelSize, tone: Self.tone(for: assetID))
    }

    /// A deterministic per-asset gray level — the frame's identity. Two assets' frames
    /// are distinguishable by `pixelTone`, so "which photo is on screen" is assertable.
    /// FNV-1a over the identifier (String.hashValue is per-process random).
    static func tone(for assetID: String) -> CGFloat {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in assetID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return CGFloat(hash % 200 + 20) / 255.0
    }

    static func tonedImage(side: Int, tone: CGFloat) -> CGImage {
        let dimension = max(1, side)
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("test image context must be creatable")
        }
        context.setFillColor(CGColor(red: tone, green: tone, blue: tone, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        guard let image = context.makeImage() else {
            preconditionFailure("test image must render")
        }
        return image
    }
}

/// Reads a test frame's gray level — the per-asset identity used to prove the card shows
/// the right photo's pixels (and never a stale callback's).
private func pixelTone(_ image: CGImage) -> UInt8? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    return data.first
}

/// The expected identity byte for an asset's frame, compared through the *same render
/// path* the loader uses — so the assertion is immune to color-conversion rounding.
private func referenceTone(for assetID: String) -> UInt8? {
    let reference = RecordingPrefetchLoader.tonedImage(
        side: 2,
        tone: RecordingPrefetchLoader.tone(for: assetID)
    )
    return pixelTone(reference)
}
