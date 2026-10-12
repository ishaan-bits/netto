import Combine
import CoreGraphics
import SwiftUI

// MARK: - Session model

/// The swipe-review session: which photo is on screen, in what order, and what was decided
/// before it. Deliberately owns **no selection** — every decision is written through the
/// caller's `PhotoSelectionModel` (the same value `AppEnvironment` publishes), so swipe mode
/// cannot fork a second source of truth; the model only tracks the cursor, the per-asset
/// decision log, and the in-memory undo history.
///
/// Ownership rules:
/// - Order is fixed at init from the caller's deck (the scanned catalog — no scanning, no
///   re-analysis) and only ever changes through Shuffle / Start New Pass (both documented
///   below).
/// - Each decision records the photo's selection state *before* the decision, so Undo is an
///   exact restore rather than a re-derivation.
/// - `decisions` is the authoritative session log ("this photo was swiped Delete/Keep") and
///   survives a new pass; Review Cleanup scopes itself to it. It is persisted with the deck,
///   cursor, and history, so a relaunch resumes exactly where the app left off.
/// - `decide`, `undo`, `shuffleRemaining`, `startNewPass`, and `restore` are the only
///   mutation paths; the boundaries are no-ops (nothing to decide at the end, nothing to
///   undo at the start, nothing to shuffle with fewer than two photos left).
@MainActor
final class SwipeReviewModel: ObservableObject {
    /// The decision a swipe records — a free, codable enum so snapshots stay plain data.
    typealias Decision = SwipeReviewDecision
    /// One undo-stack entry — codable for the persisted session.
    typealias HistoryEntry = SwipeReviewHistoryEntry

    @Published private(set) var items: [SwipeReviewItem]
    /// Index of the photo on screen; equals `items.count` once every photo has been swiped.
    @Published private(set) var cursor = 0
    @Published private(set) var history: [HistoryEntry] = []
    /// Asset identifier → the decision last swiped for it in this session. The source of
    /// truth for "what did this session mark" — kept across Start New Pass (which clears the
    /// cursor and undo stack but never what the user already decided).
    @Published private(set) var decisions: [String: Decision] = [:]
    /// O(1) count of Delete marks, maintained incrementally by decide/undo — the persistent
    /// bar and completion screen read this instead of filtering the whole deck per render.
    @Published private(set) var deleteDecisionCount = 0

    init(items: [SwipeReviewItem]) {
        self.items = items
    }

    /// Installs a deck into an empty session — the lazy path the dashboard's card uses, so
    /// the full item list is built once (on appear) instead of on every dashboard render.
    /// Refuses to touch a session that already has items: an in-flight review's cursor and
    /// history can never be clobbered by a later catalog write.
    func installDeckIfNeeded(_ newItems: [SwipeReviewItem]) {
        guard items.isEmpty, !newItems.isEmpty else { return }
        items = newItems
    }

    var isComplete: Bool { cursor >= items.count }

    var currentItem: SwipeReviewItem? {
        cursor < items.count ? items[cursor] : nil
    }

    /// Unreviewed photos still ahead — the Shuffle gate.
    var remainingCount: Int { SwipeReviewPresentation.remainingCount(cursor: cursor, total: items.count) }

    /// Photos decided so far — the completion screen's "N photos reviewed".
    var reviewedCount: Int { min(cursor, items.count) }

    var canUndo: Bool { !history.isEmpty }

    /// Applies one decision to the shared selection and advances. Keep deselects (the photo
    /// is kept), Delete selects it (marked for cleanup) — either way it is only a selection
    /// change; nothing here can reach the deletion pipeline. The decision is also logged in
    /// `decisions` (replacing any earlier one for this asset) and, if there was one, its
    /// predecessor rides along in the history entry so Undo can restore it exactly.
    func decide(_ decision: Decision, selection: inout PhotoSelectionModel) {
        guard let item = currentItem else { return }
        history.append(
            HistoryEntry(
                assetID: item.assetID,
                wasSelected: selection.isSelected(item.assetID),
                priorDecision: decisions[item.assetID]
            )
        )
        switch decision {
        case .keep:
            selection.setSelected(false, forAsset: item.assetID)
        case .delete:
            selection.setSelected(true, forAsset: item.assetID)
        }
        applyDecision(decision, toAsset: item.assetID)
        cursor += 1
    }

    /// Reverses the most recent decision: the cursor returns to that photo, its selection is
    /// restored to exactly what it was before the swipe, and its decision log entry reverts
    /// to whatever the asset carried before (or leaves the log when it carried nothing).
    /// No-op when there is no history.
    func undo(selection: inout PhotoSelectionModel) {
        guard let entry = history.popLast() else { return }
        selection.setSelected(entry.wasSelected, forAsset: entry.assetID)
        switch entry.priorDecision {
        case .some(let prior):
            applyDecision(prior, toAsset: entry.assetID)
        case .none:
            removeDecision(forAsset: entry.assetID)
        }
        cursor = max(0, cursor - 1)
    }

    /// Reorders only the *unreviewed* tail (from the cursor on) so decisions, position, and
    /// undo are untouched and no reviewed photo can re-enter the pass. Within one pass the
    /// cursor only moves forward through unique items, so a photo can never repeat — the
    /// only way to see reviewed photos again is Start New Pass (or, implicitly, undo).
    func shuffleRemaining<G: RandomNumberGenerator>(using generator: inout G) {
        guard remainingCount > 1 else { return }
        var tail = Array(items[cursor...])
        tail.shuffle(using: &generator)
        items.replaceSubrange(cursor..., with: tail)
    }

    /// Starts a fresh pass over `newItems`: the cursor and undo stack reset, the deck takes
    /// the new order, and **every prior decision stays** — a new pass is "review again", not
    /// "forget what I marked". Undo is honestly unavailable until the new pass records a
    /// decision (the button reads disabled, never lies).
    func startNewPass(items newItems: [SwipeReviewItem]) {
        items = newItems
        cursor = 0
        history = []
    }

    /// Adopts a persisted snapshot exactly as written — the relaunch / navigation-return
    /// path. Corrupt input is sanitized defensively rather than crashing: the cursor is
    /// clamped into the deck, and an undo stack that doesn't line up with the cursor (it can
    /// only happen in a hand-edited or truncated file) is dropped instead of rewinding the
    /// session to a photo it doesn't describe.
    func restore(from snapshot: SwipeReviewSessionSnapshot) {
        guard !snapshot.items.isEmpty else { return }
        items = snapshot.items
        cursor = min(max(0, snapshot.cursor), snapshot.items.count)
        history = snapshot.history.count == cursor ? snapshot.history : []
        decisions = snapshot.decisions
        deleteDecisionCount = decisions.values.reduce(0) { $0 + ($1 == .delete ? 1 : 0) }
    }

    /// The session exactly as it is right now, for persistence.
    func sessionSnapshot() -> SwipeReviewSessionSnapshot {
        SwipeReviewSessionSnapshot(
            items: items,
            cursor: cursor,
            history: history,
            decisions: decisions
        )
    }

    /// Replays the decision log onto a freshly built shared selection (after the deck has
    /// been admitted), so Keep/Delete marks survive a relaunch: each asset lands in exactly
    /// the state its last decision recorded, regardless of the deterministic defaults the
    /// selection was rebuilt from. Idempotent — replaying the same log twice converges.
    func reapplyDecisions(to selection: inout PhotoSelectionModel) {
        for (assetID, decision) in decisions {
            selection.setSelected(decision == .delete, forAsset: assetID)
        }
    }

    /// The cleanup candidates this session offers, in deck order — Delete-marked photos that
    /// are still marked in the shared selection and still present in the catalog (when one
    /// is given). See `SwipeReviewPresentation.cleanupCandidates`.
    func cleanupCandidates(
        selection: PhotoSelectionModel,
        availableAssetIDs: Set<String>? = nil
    ) -> [SwipeReviewItem] {
        SwipeReviewPresentation.cleanupCandidates(
            items: items,
            decisions: decisions,
            selection: selection,
            availableAssetIDs: availableAssetIDs
        )
    }

    private func applyDecision(_ decision: Decision, toAsset assetID: String) {
        if let existing = decisions[assetID], existing == decision { return }
        if decision == .delete { deleteDecisionCount += 1 }
        if decisions[assetID] == .delete { deleteDecisionCount -= 1 }
        decisions[assetID] = decision
    }

    private func removeDecision(forAsset assetID: String) {
        guard let existing = decisions.removeValue(forKey: assetID) else { return }
        if existing == .delete { deleteDecisionCount -= 1 }
    }
}

// MARK: - Thumbnail prefetch

/// Warms the shared `ThumbnailStore` with the swipe card's frames ahead of the cursor
/// (M14/M15): a bounded forward window — the current photo first — through the same
/// store the card reads, so the frame on screen is a cache hit the instant the card
/// appears and swiping never waits on PhotoKit for a first look. Two tiers:
///
/// - the **low-resolution** tier (`swipeThumbnailLowResPixelSize`) covers the whole
///   window — small, fast, the temporary frame while the sharp one prepares;
/// - the **screen-sized** tier (`swipeThumbnailPixelSize`) covers the current photo and
///   the next few (`swipeSharpPrefetchCount`) — the final sharp frame, prioritized.
///
/// Both are local-only renditions — never the full-resolution preview path, never a
/// network fetch — and no pixels ever enter the persisted session snapshot. The walk is
/// sequential in priority order (current first), so request concurrency stays bounded and
/// the store's own in-flight coalescing deduplicates against the card's own reads.
///
/// Every warm-up supersedes the previous one (the window moves with the cursor; Shuffle /
/// Start New Pass reorder the deck mid-window), so the old walk is cancelled before the
/// new one starts. A superseded walk's already-issued loads are harmless: the store is
/// keyed by asset ID, so a completed load is either the right photo's frame or an eviction
/// candidate — never a stale display — and it is never the *card's* request, which lives
/// in `SwipeCardFrameModel` and is not cancelled by the walk.
@MainActor
final class SwipeThumbnailPrefetcher: ObservableObject {
    private var warmTask: Task<Void, Never>?

    /// Warms `order` (already prioritized: the current photo first, then forward). A
    /// repeated order is absorbed by the store's cache; a new order supersedes the old walk.
    func warm(order: [String], store: ThumbnailStore) {
        warmTask?.cancel()
        guard !order.isEmpty else { return }
        let lowRes = SwipeReviewPresentation.swipeThumbnailLowResPixelSize
        let sharp = SwipeReviewPresentation.swipeThumbnailPixelSize
        let sharpCount = SwipeReviewPresentation.swipeSharpPrefetchCount
        warmTask = Task {
            for (offset, assetID) in order.enumerated() {
                guard !Task.isCancelled else { return }
                // Per asset: the fast low-resolution frame first, then — for the current
                // photo and the next few — the screen-sized final. Order is priority.
                _ = try? await store.image(for: assetID, targetPixelSize: lowRes)
                guard !Task.isCancelled else { return }
                if offset < sharpCount {
                    _ = try? await store.image(for: assetID, targetPixelSize: sharp)
                }
            }
        }
    }

    /// Stops the walk (the screen is going away) without touching the store: warmed frames
    /// stay resident for the next appearance, bounded by the store's own limits.
    func stop() {
        warmTask?.cancel()
        warmTask = nil
    }
}

// MARK: - Card frame

/// The lifecycle of one swipe card's image (M15), backed by the shared `ThumbnailStore`.
///
/// The card shows the **screen-sized local thumbnail** — the same rendition the prefetcher
/// warms, at the same cache key — as its final sharp frame. The low-resolution thumbnail of
/// the same photo may show as a *temporary* frame while the screen-sized one prepares; it
/// is never the final image. The slow network-enabled `previewImage` path (Photo Details'
/// explicit open) is not used here: routine swipes never download originals, and a photo
/// with no local rendition reports an honest unavailable state instead of hanging on one.
///
/// Ownership rules:
/// - A warm key renders **without a loading state**: `prepare` peeks the store first and
///   only publishes `.loading` when nothing cached is available, so "Loading photo…" never
///   covers pixels that are already there.
/// - Every frame is tagged with its asset ID and every async continuation re-checks the
///   generation, so a fast swipe, Shuffle, Undo, or session restore can never show one
///   photo's pixels for another, and a stale callback can never overwrite the current card.
/// - A failed request is a terminal, honest state for *this card* — the deck itself keeps
///   working (the next `prepare` is a fresh generation).
@MainActor
final class SwipeCardFrameModel: ObservableObject {
    /// The loading contract (M15-R1) — every state a card can be in, and none of them
    /// replaces a valid frame with an error while a request that can still succeed is in
    /// flight.
    enum Phase: Equatable {
        case idle
        /// The local fast path is in flight. `temporary` is the warm low-resolution frame
        /// of the *same* photo shown while the sharp one prepares (never the final).
        case preparing(temporary: CGImage?)
        /// The local rendition is not on device (iCloud-backed) and the permitted
        /// network-enabled request is in flight — an honest, non-blocking download state.
        /// Any temporary frame stays visible while it runs.
        case downloading(temporary: CGImage?)
        /// The final, screen-sized frame — the sharp image the card keeps.
        case final(CGImage)
        /// A transient failure (iCloud download failed, timeout, PhotoKit hiccup): retry is
        /// meaningful, nothing is poisoned, and `visible` keeps any frame already on screen.
        case retryable(PhotoContentError, visible: CGImage?)
        /// A genuine terminal failure for this session: the asset no longer exists, or
        /// Photos access is off. Shown only after such a failure, never for a transient one.
        case unavailable(PhotoContentError)
    }

    @Published private(set) var phase: Phase = .idle
    private(set) var assetID: String?
    private var generation = 0
    private var isRequestInFlight = false

    /// Prepares the frame for `assetID` through the shared store. Idempotent while a
    /// request for the same card is in flight or a final frame exists; a settled *failure*
    /// re-attempts on revisit (transient failures must never stick). Safe for a new card
    /// at any time — the generation guard discards everything the old card started.
    func prepare(assetID: String, store: ThumbnailStore) {
        if self.assetID == assetID {
            if case .final = phase { return }
            if isRequestInFlight { return }
        }
        let changedAsset = self.assetID != assetID
        let carriedFrame = changedAsset ? nil : phase.visibleFrame
        generation += 1
        let generation = generation
        self.assetID = assetID
        isRequestInFlight = true
        // Identity-critical reset: when the card changes, the previous photo's pixels
        // leave the screen immediately (a frame is never shown for the wrong asset).
        // A re-attempt of the *same* card drops its stale failure but keeps its own
        // pixels visible. A fresh card from idle resets nothing — a warm key resolves
        // before any loading state is published.
        switch phase {
        case .retryable, .unavailable:
            phase = .preparing(temporary: carriedFrame)
        default:
            if changedAsset, carriedFrame == nil, self.phase.visibleFrame != nil {
                phase = .preparing(temporary: nil)
            } else if changedAsset, case .final = phase {
                phase = .preparing(temporary: nil)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            // A warm screen-sized key answers here before any loading state is published.
            if let sharp = await store.peekCached(
                assetID: assetID,
                targetPixelSize: SwipeReviewPresentation.swipeThumbnailPixelSize
            ) {
                guard self.generation == generation else { return }
                self.isRequestInFlight = false
                self.phase = .final(sharp)
                return
            }
            guard self.generation == generation else { return }
            // The temporary tier: a warm low-resolution frame of the same photo, kept
            // visible while the sharp one prepares and while any download runs.
            let temporary = await store.peekCached(
                assetID: assetID,
                targetPixelSize: SwipeReviewPresentation.swipeThumbnailLowResPixelSize
            )
            guard self.generation == generation else { return }
            self.phase = .preparing(temporary: temporary)

            do {
                let sharp = try await Self.loadFinalFrame(
                    assetID: assetID,
                    store: store,
                    onFallback: { [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.phase = .downloading(temporary: temporary)
                    }
                )
                guard self.generation == generation else { return }
                self.isRequestInFlight = false
                self.phase = .final(sharp)
            } catch {
                guard self.generation == generation else { return }
                self.isRequestInFlight = false
                if error is CancellationError || Task.isCancelled { return }
                let contentError = Self.contentError(for: error)
                if Self.isTerminal(contentError) {
                    self.phase = .unavailable(contentError)
                } else {
                    // Transient: retryable, and any frame already on screen stays.
                    self.phase = .retryable(contentError, visible: temporary)
                }
            }
        }
    }

    /// The frame pipeline: local-first, then — only when the local rendition is genuinely
    /// missing and the failure is the kind a download can fix — the permitted
    /// network-enabled request. Prefetch never reaches this; it stays local-only.
    private static func loadFinalFrame(
        assetID: String,
        store: ThumbnailStore,
        onFallback: @escaping @MainActor () -> Void
    ) async throws -> CGImage {
        do {
            return try await store.image(
                for: assetID,
                targetPixelSize: SwipeReviewPresentation.swipeThumbnailPixelSize,
                policy: .localOnly
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            let contentError = contentError(for: error)
            guard PhotoKitThumbnailLoader.isPreviewFallbackCandidate(contentError) else {
                throw error
            }
            onFallback()
            return try await store.image(
                for: assetID,
                targetPixelSize: SwipeReviewPresentation.swipeThumbnailPixelSize,
                policy: .allowNetwork
            )
        }
    }

    /// Retries the current card after a transient failure (one fresh request chain; any
    /// visible frame is kept on screen). No-op for a final frame or an in-flight request.
    func retry(store: ThumbnailStore) {
        guard let assetID else { return }
        if case .final = phase { return }
        guard !isRequestInFlight else { return }
        prepare(assetID: assetID, store: store)
    }

    /// Releases the frame state. Safe to call repeatedly; the store keeps whatever it has.
    func close() {
        generation += 1
        assetID = nil
        isRequestInFlight = false
        phase = .idle
    }

    private static func contentError(for error: any Error) -> PhotoContentError {
        (error as? PhotoContentError) ?? .unavailable
    }

    /// Only a genuine terminal failure may claim permanent unavailability: the asset is
    /// gone, or Photos access is off. Everything else (iCloud, timeout, framework hiccups)
    /// is transient and retryable — never labelled permanent.
    static func isTerminal(_ error: PhotoContentError) -> Bool {
        switch error {
        case .assetNotFound, .permissionDenied: return true
        case .onlyInICloud, .unavailable: return false
        }
    }
}

extension SwipeCardFrameModel.Phase {
    /// A settled outcome (frame or failure) — no request is running for it.
    var isSettled: Bool {
        switch self {
        case .final, .retryable, .unavailable: return true
        case .idle, .preparing, .downloading: return false
        }
    }

    /// A valid frame that must stay on screen while sharper work continues.
    var visibleFrame: CGImage? {
        switch self {
        case .final(let image): return image
        case .preparing(let temporary), .downloading(let temporary): return temporary
        case .retryable(_, let visible): return visible
        case .idle, .unavailable: return nil
        }
    }
}

/// Renders one card's frame state (M15-R1): the screen-sized frame when it exists, the
/// temporary low-resolution frame while anything sharper prepares or downloads, an honest
/// non-blocking download state for iCloud-backed photos, and — only after a genuine
/// terminal failure — the error card. A valid frame is never replaced by an error while a
/// request that can still succeed is in flight; a transient failure keeps any frame it
/// already had and offers Retry inline.
struct SwipeCardFrameView: View {
    let phase: SwipeCardFrameModel.Phase
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.black
            switch phase {
            case .idle:
                skeleton

            case .preparing(let temporary):
                if let temporary {
                    frameImage(temporary)
                } else {
                    skeleton
                }

            case .downloading(let temporary):
                if let temporary {
                    frameImage(temporary)
                        .overlay(alignment: .bottom) { downloadingChip }
                } else {
                    downloadingState
                }

            case .final(let image):
                frameImage(image)

            case .retryable(_, let visible):
                if let visible {
                    // The photo is on screen; the transient failure is a chip, not an
                    // error card — and never a blank.
                    frameImage(visible)
                        .overlay(alignment: .bottom) { retryChip }
                } else {
                    retryableState
                }

            case .unavailable(let error):
                unavailable(error)
            }
        }
        .contentShape(Rectangle())
    }

    private func frameImage(_ image: CGImage) -> some View {
        Image(image, scale: 1, orientation: .up, label: Text("Photo preview"))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }

    /// Loading skeleton. Under Reduce Motion the shimmer sweep (a repeating motion) is
    /// replaced by a static placeholder with the loading caption — same information, no motion.
    private var skeleton: some View {
        SwipeCardSkeleton(message: SimilarPhotosPresentation.previewLoadingMessage)
    }

    /// The honest iCloud download state: progress copy, no promise of instant rendering,
    /// bounded by the request's own timeout (which lands in a retryable state).
    private var downloadingState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.75))
            Text(SwipeReviewPresentation.downloadMessage)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            ProgressView()
                .tint(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SwipeReviewPresentation.downloadMessage)
    }

    /// Non-blocking status over a visible frame while a download runs.
    private var downloadingChip: some View {
        statusChip(SwipeReviewPresentation.downloadShortMessage, systemImage: "icloud.and.arrow.down")
    }

    /// Non-blocking retry over a visible frame after a transient failure.
    private var retryChip: some View {
        Button(action: onRetry) {
            Label(SwipeReviewPresentation.retryChipTitle, systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(Theme.Spacing.sm)
        .accessibilityLabel("Try loading the photo again")
    }

    private func statusChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .padding(Theme.Spacing.sm)
            .allowsHitTesting(false)
    }

    /// A transient failure with no frame to keep: the retryable message (never the
    /// permanent one) with a functional Try Again.
    private var retryableState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.75))
            Text(SwipeReviewPresentation.transientFailureMessage)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            retryButton
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func unavailable(_ error: PhotoContentError) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: SimilarPhotosPresentation.previewFailureSymbol(for: error))
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.75))
            Text(SimilarPhotosPresentation.previewUnavailableTitle)
                .font(.headline)
                .foregroundStyle(.white)
            Text(SimilarPhotosPresentation.previewUnavailableMessage(for: error))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            retryButton
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SimilarPhotosPresentation.previewUnavailableTitle)
    }

    private var retryButton: some View {
        Button {
            onRetry()
        } label: {
            Text("Try Again")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(.white.opacity(0.16), in: Capsule())
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Try loading the photo again")
    }
}

/// The card's loading skeleton (M15): shown only when no frame of the current photo is
/// available yet. Reduce Motion swaps the shimmer sweep for a static placeholder with the
/// same caption — same information, no motion.
struct SwipeCardSkeleton: View {
    let message: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerSwept = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .padding(Theme.Spacing.lg)

            if reduceMotion {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                sweep
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, Theme.Spacing.xl)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(message)
    }

    private var sweep: some View {
        RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .padding(Theme.Spacing.lg)
            .scaleEffect(x: shimmerSwept ? 1.4 : 0.6)
            .opacity(shimmerSwept ? 0 : 0.9)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: false),
                value: shimmerSwept
            )
            .onAppear { shimmerSwept = true }
    }
}

// MARK: - Swipe review screen

/// One-at-a-time review of the photo library: swipe right (or tap Keep) to keep a photo,
/// swipe left (or tap Delete) to mark it for cleanup, with Undo for the last decision and a
/// Shuffle button that re-orders only the photos still unreviewed. Entered directly from the
/// dashboard's top-level Swipe Review card — no dependency on Similar Photos, its screens,
/// or its similarity groups.
///
/// Three hard boundaries this screen enforces:
/// - **Selection only.** Every decision flows through `env.mutateSelection` → the existing
///   `PhotoSelectionModel` (the deck is admitted into it on appear, so library photos accept
///   marks without a second selection store); the Review Cleanup button opens a scoped,
///   editable list of this session's Delete marks and only *that* flow's confirmation can
///   reach the existing deletion pipeline. Nothing on this screen deletes, rescans, or
///   rebuilds a plan.
/// - **One photo loaded at a time.** The card's image is the shared `ThumbnailStore`'s
///   screen-sized local thumbnail (M15) — the same rendition the bounded window
///   prefetcher warms ahead of the cursor — with the low-resolution thumbnail of the same
///   photo only ever as a temporary stand-in while the sharp one prepares. Routine swipes
///   never use the network-enabled Photo Details preview path and never fetch
///   full-resolution originals; a photo with no local rendition reports an honest
///   unavailable state.
/// - **Session durability.** Deck order, cursor, undo history, and the decision log persist
///   through `env.saveSwipeSession` / `env.restoreSwipeSession` (asset identifiers and
///   review state only — never pixels), so leaving the screen, navigating back, or relaunching
///   the app resumes exactly where the review stopped.
///
/// A persistent bottom bar (live count + "Review Cleanup") is on screen for the whole
/// session — finishing the deck is not a precondition for reviewing — and the completion
/// screen repeats the same handoff with "Done" as the way out — neutral because the deck
/// is entered from both Similar Photos *and* the dashboard card, and a hard-coded
/// destination would lie for one of them. Both
/// preserve the shared selection exactly: this screen never instantiates or resets it.
///
/// Exiting early (back gesture / system back) simply pops the stack: decisions already live
/// in the shared selection, so every selection count updates immediately — and the session
/// itself is restored from its persisted snapshot the next time the screen appears.
struct SwipeReviewView: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var model: SwipeReviewModel
    /// The card frame lifecycle (M15): the shared store's screen-sized thumbnail is the
    /// final image; the low-resolution frame is only ever a temporary stand-in.
    @StateObject private var frameModel = SwipeCardFrameModel()
    /// Keeps the frame window warm ahead of the cursor (M14/M15).
    @StateObject private var prefetcher = SwipeThumbnailPrefetcher()
    @State private var dragOffset: CGSize = .zero
    /// An explicitly supplied deck (previews). Production passes `nil` and the deck is built
    /// from the completed catalog on appear — the dashboard's card must not construct every
    /// swipe item on each of its own renders.
    private let presetItems: [SwipeReviewItem]?

    init(items: [SwipeReviewItem]? = nil) {
        presetItems = items
        _model = StateObject(wrappedValue: SwipeReviewModel(items: items ?? []))
    }

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle(SwipeReviewPresentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .nettoAppear()
            .onAppear {
                restoreSessionFromStoreIfPossible()
                installDeckFromCatalogIfNeeded()
                admitDeck()
                openCurrent()
            }
            .onChange(of: env.catalogState) { _, _ in
                // A scan finishing while the empty state is showing fills the deck in place;
                // a session that already has items (in flight, done, or mid-review) keeps
                // its deck — a later catalog write can never clobber cursor or history.
                // Admission runs only on the empty→non-empty transition: a progress tick
                // must never rebuild the admission set (O(library) per coalesced tick).
                let wasEmpty = model.items.isEmpty
                installDeckFromCatalogIfNeeded()
                if wasEmpty, !model.items.isEmpty {
                    admitDeck()
                }
            }
            .onChange(of: model.currentItem?.assetID) { _, _ in openCurrent() }
            .onDisappear {
                frameModel.close()
                prefetcher.stop()
            }
    }

    /// Adopts the persisted session, if any, exactly once per screen instance (the guard on
    /// an empty model means a screen that already has its deck — live, restored, or preset —
    /// never re-adopts and never re-clobbers). The snapshot is reconciled against the
    /// catalog as it is *now* first, so photos deleted since the deck was built leave the
    /// session instead of surfacing as un-decidable ghosts; the deck is then admitted and
    /// the decision log replayed onto the shared selection so every mark is live again.
    private func restoreSessionFromStoreIfPossible() {
        guard presetItems == nil, model.items.isEmpty else { return }
        let availableAssetIDs: Set<String>? = {
            guard case .completed(let catalog) = env.catalogState else { return nil }
            return Set(catalog.records.lazy.map(\.localIdentifier))
        }()
        guard let snapshot = env.restoreSwipeSession(),
              let reconciled = SwipeReviewPresentation.reconciled(
                  snapshot,
                  availableAssetIDs: availableAssetIDs
              )
        else { return }
        model.restore(from: reconciled)
        admitDeck()
        env.mutateSelection { model.reapplyDecisions(to: &$0) }
    }

    /// Installs the deck from the completed catalog, exactly once per session, and only when
    /// no explicit deck was supplied. No-op for an empty (not-yet-scanned) library — and,
    /// via `shouldInstallDeck`, no-op for every render once a session exists: a 30,000-photo
    /// library is mapped exactly once, never per render.
    private func installDeckFromCatalogIfNeeded() {
        guard SwipeReviewPresentation.shouldInstallDeck(
            presetItemsSupplied: presetItems != nil,
            sessionIsEmpty: model.items.isEmpty
        ) else { return }
        guard case .completed(let catalog) = env.catalogState else { return }
        model.installDeckIfNeeded(SwipeReviewPresentation.items(from: catalog))
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            emptyState
        } else if model.isComplete {
            completionView
        } else if let item = model.currentItem {
            reviewView(item)
        }
    }

    /// The deck enters the shared selection's accepted set the first time the screen shows,
    /// so Keep/Delete can mark library photos the analysis never grouped. Admission selects
    /// nothing — it only widens which identifiers the model accepts decisions for.
    private func admitDeck() {
        guard !model.items.isEmpty else { return }
        env.mutateSelection { selection in
            selection.admitLibraryAssets(Set(model.items.lazy.map(\.assetID)))
        }
    }

    /// Shown when no scan exists yet (empty catalog) — the honest counterpart of a deck that
    /// would otherwise look like an instantly-finished session. The body tells the user to
    /// scan, so the action comes with it (U2); `startCatalogBuild` is the catalog-only entry
    /// point this state is defined by.
    private var emptyState: some View {
        PhaseMessage(
            systemImage: "photo.on.rectangle.angled",
            title: "No photos to review yet",
            message: "Netto reads your photo library during a scan. Scan your library, then come back to swipe through your photos.",
            buttonTitle: "Scan Library"
        ) {
            env.startCatalogBuild()
        }
    }

    /// Prepares the frame for the photo now on screen — through the shared `ThumbnailStore`,
    /// the same rendition the prefetcher warms (M15). A warm key renders immediately with
    /// no loading state; a cold key shows the temporary low-resolution frame if one is
    /// resident, then the screen-sized final. The frame window is kept warm here too: it
    /// follows the cursor by construction (M14).
    private func openCurrent() {
        guard let item = model.currentItem else {
            frameModel.close()
            prefetcher.stop()
            return
        }
        frameModel.prepare(assetID: item.assetID, store: env.thumbnails)
        warmUpcomingThumbnails()
    }

    /// Warms the instant-frame window: the current photo first, then the bounded forward
    /// window (M14). Called on every card change and after Shuffle / Start New Pass, which
    /// reorder the deck without moving the current photo — so the window must be re-walked
    /// even though `currentItem` did not change.
    private func warmUpcomingThumbnails() {
        prefetcher.warm(
            order: SwipeReviewPresentation.prefetchOrder(
                around: model.cursor,
                in: model.items.map(\.assetID)
            ),
            store: env.thumbnails
        )
    }

    // MARK: Review state

    private func reviewView(_ item: SwipeReviewItem) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            header(item)
            photoCard(item)
            actionRow
            undoRow
            Text("Nothing is deleted here — Delete marks a photo for cleanup.")
                .font(NettoType.caption)
                .foregroundStyle(NettoColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Persistent bottom action area: the live count plus the handoff into the existing
        // review flow, on screen for the whole session — finishing the deck is not a
        // precondition for reviewing what has been marked.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            reviewCleanupBar
        }
    }

    private func header(_ item: SwipeReviewItem) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(
                SwipeReviewPresentation.positionText(
                    current: model.cursor + 1,
                    total: model.items.count
                )
            )
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(NettoColor.textPrimary)
            .accessibilityLabel(
                SwipeReviewPresentation.positionAccessibilityLabel(
                    current: model.cursor + 1,
                    total: model.items.count
                )
            )

            Text(SwipeReviewPresentation.groupContext(for: item))
                .font(.caption)
                .foregroundStyle(NettoColor.textSecondary)

            // Shuffle — re-orders only the unreviewed tail, so it can be tapped at any point
            // in the pass without losing a single decision or re-showing a reviewed photo.
            // Clearly disabled once fewer than two photos remain: there is nothing to
            // re-order, and pretending otherwise would be a lie.
            Button {
                shuffleRemaining()
            } label: {
                Label(
                    SwipeReviewPresentation.shuffleButtonTitle,
                    systemImage: "shuffle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoTertiaryButtonStyle())
            .disabled(!SwipeReviewPresentation.shuffleEnabled(remaining: model.remainingCount))
            .opacity(SwipeReviewPresentation.shuffleEnabled(remaining: model.remainingCount) ? 1 : 0.4)
            .accessibilityLabel(SwipeReviewPresentation.shuffleAccessibilityLabel)
            .accessibilityIdentifier(SwipeReviewPresentation.shuffleAccessibilityID)
            .padding(.top, Theme.Spacing.xs)
        }
    }

    // MARK: Photo card

    private func photoCard(_ item: SwipeReviewItem) -> some View {
        previewStack(assetID: item.assetID)
            .frame(maxWidth: .infinity)
            .frame(height: SimilarPhotosPresentation.previewBoxHeight)
            .clipShape(RoundedRectangle(cornerRadius: NettoLayout.Radius.card, style: .continuous))
            .overlay(alignment: .topLeading) { recommendedBadge(item) }
            .overlay(alignment: .top) { decisionIndicators }
            .offset(x: dragOffset.width)
            .accessibilityIdentifier(SwipeReviewPresentation.cardAccessibilityID)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.isRecommended ? "Photo, recommended to keep" : "Photo")
            // `simultaneousGesture` so the preview's Try Again button keeps receiving taps.
            .simultaneousGesture(swipeGesture)
    }

    /// The preview box itself (M15): the shared-store frame state — the screen-sized local
    /// thumbnail as the final sharp image, the low-resolution frame as a temporary stand-in
    /// while it prepares, the skeleton only when nothing is available, and the honest
    /// unavailable state when no local rendition exists. The slow network-enabled preview
    /// path (Photo Details' explicit open) is deliberately not used for routine swipes.
    private func previewStack(assetID: String) -> some View {
        SwipeCardFrameView(
            phase: frameModel.phase,
            onRetry: { frameModel.retry(store: env.thumbnails) }
        )
    }

    private func recommendedBadge(_ item: SwipeReviewItem) -> some View {
        Group {
            if item.isRecommended {
                Label("Best", systemImage: "star.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(NettoColor.success, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(Theme.Spacing.sm)
            }
        }
    }

    // MARK: Gesture feedback

    /// KEEP (right) / DELETE (left) chips riding on top of the card during a drag, ramping in
    /// with the translation — direct manipulation feedback, not an autonomous animation, so
    /// Reduce Motion only removes the rotation.
    private var decisionIndicators: some View {
        let progress = min(abs(dragOffset.width) / SwipeReviewPresentation.indicatorRampWidth, 1)
        return HStack {
            if dragOffset.width < 0 {
                indicatorChip(
                    SwipeReviewPresentation.deleteIndicatorLabel,
                    tint: NettoColor.destructive,
                    rotation: -8
                )
                .opacity(progress)
            }
            Spacer()
            if dragOffset.width > 0 {
                indicatorChip(
                    SwipeReviewPresentation.keepIndicatorLabel,
                    tint: NettoColor.success,
                    rotation: 8
                )
                .opacity(progress)
            }
        }
        .padding(Theme.Spacing.lg)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func indicatorChip(_ text: String, tint: Color, rotation: Double) -> some View {
        Text(text)
            .font(.caption.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(tint, in: Capsule())
            .rotationEffect(.degrees(reduceMotion ? 0 : rotation))
    }

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let width = value.translation.width
                if width > SwipeReviewPresentation.commitThreshold {
                    commit(.keep)
                } else if width < -SwipeReviewPresentation.commitThreshold {
                    commit(.delete)
                } else {
                    // A flick that never crossed the threshold is a look, not a decision.
                    settleDrag()
                }
            }
    }

    // MARK: Actions

    private func commit(_ decision: SwipeReviewModel.Decision) {
        guard !model.isComplete else { return }
        env.mutateSelection { selection in
            model.decide(decision, selection: &selection)
        }
        persistSession()
        settleDrag()
    }

    private func performUndo() {
        guard model.canUndo else { return }
        env.mutateSelection { selection in
            model.undo(selection: &selection)
        }
        persistSession()
        settleDrag()
    }

    /// Shuffle: only the unreviewed tail re-orders. Decisions, cursor, and undo history are
    /// untouched by construction, so persisting afterwards captures a session that is still
    /// exactly where it was — just in a different order. The instant-frame window is
    /// re-walked: the deck it was warming just changed under it (M14).
    private func shuffleRemaining() {
        var generator = SystemRandomNumberGenerator()
        model.shuffleRemaining(using: &generator)
        persistSession()
        warmUpcomingThumbnails()
    }

    /// Start New Pass: rebuild a library deck from the *current* catalog (so photos added
    /// since the deck was built join this pass, and confirmed removals are gone), reshuffle
    /// everything, and reset position and undo — while every prior decision keeps standing.
    /// A group session keeps its own deck (group membership only exists in the analysis the
    /// deck came from). The instant-frame window is re-walked over the fresh deck (M14).
    private func startNewPass() {
        var deck = model.items
        if presetItems == nil, model.items.first?.isLibraryItem == true,
           case .completed(let catalog) = env.catalogState {
            deck = SwipeReviewPresentation.items(from: catalog)
        }
        model.startNewPass(items: deck)
        var generator = SystemRandomNumberGenerator()
        model.shuffleRemaining(using: &generator)
        persistSession()
        warmUpcomingThumbnails()
    }

    /// Persists deck order, cursor, undo history, and the decision log after every mutation.
    /// Called only from explicit actions (never from a render), so a 30,000-photo session
    /// costs at most one snapshot write per user action — off the main actor for the file
    /// store (see `FileSwipeReviewSessionStore`).
    private func persistSession() {
        env.saveSwipeSession(from: model)
    }

    private func settleDrag() {
        withAnimation(NettoMotion.animation(for: .standard, reduceMotion: reduceMotion)) {
            dragOffset = .zero
        }
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                commit(.delete)
            } label: {
                Text(SwipeReviewPresentation.deleteButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoSecondaryButtonStyle())
            .accessibilityLabel(SwipeReviewPresentation.deleteAccessibilityLabel)
            .accessibilityIdentifier(SwipeReviewPresentation.deleteAccessibilityID)

            Button {
                commit(.keep)
            } label: {
                Text(SwipeReviewPresentation.keepButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .accessibilityLabel(SwipeReviewPresentation.keepAccessibilityLabel)
            .accessibilityIdentifier(SwipeReviewPresentation.keepAccessibilityID)
        }
    }

    /// Always on screen, disabled until there is a decision to reverse — a stable layout and
    /// an obvious safety net without introducing a second row that jumps in and out.
    private var undoRow: some View {
        Button {
            performUndo()
        } label: {
            Label(SwipeReviewPresentation.undoButtonTitle, systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(NettoTertiaryButtonStyle())
        .disabled(!model.canUndo)
        .opacity(model.canUndo ? 1 : 0.4)
        .accessibilityIdentifier(SwipeReviewPresentation.undoAccessibilityID)
    }

    // MARK: Persistent review bar

    /// The bottom action area shown for the whole swipe session: the live count of *this
    /// session's* Delete marks (decisions — not the whole shared selection, which can carry
    /// untouched group defaults), then the handoff into the editable cleanup screen. Always
    /// visible while swiping, clearly unavailable (disabled) while nothing is marked. It
    /// reads the model's O(1) mark count; there is no local copy to drift, fork, or reset
    /// when navigating away and back.
    private var reviewCleanupBar: some View {
        let selectedCount = model.deleteDecisionCount
        let enabled = SwipeReviewPresentation.reviewCleanupEnabled(selectedCount: selectedCount)
        return VStack(spacing: Theme.Spacing.sm) {
            Text(SwipeReviewPresentation.selectedForCleanupText(selectedCount))
                .font(NettoType.secondaryBody.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(NettoColor.brandDeep)
                .nettoCount(selectedCount)
                .accessibilityIdentifier(SwipeReviewPresentation.selectedCountAccessibilityID)

            NavigationLink {
                SwipeCleanupSelectionView(model: model)
            } label: {
                Text(SwipeReviewPresentation.completionPrimaryTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NettoPrimaryButtonStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityIdentifier(SwipeReviewPresentation.reviewCleanupAccessibilityID)
        }
        .frame(maxWidth: .infinity)
        .nettoFloatingBar()
    }

    // MARK: Completion

    private var completionView: some View {
        VStack(spacing: NettoLayout.Spacing.lg) {
            Spacer(minLength: NettoLayout.Spacing.xl)

            ZStack {
                Circle()
                    .fill(NettoColor.success.opacity(0.16))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(NettoColor.success)
                    .nettoSuccessPop(true)
            }
            .accessibilityHidden(true)

            Text(SwipeReviewPresentation.completionTitle)
                .font(NettoType.sectionTitle)
                .foregroundStyle(NettoColor.textPrimary)
                .multilineTextAlignment(.center)

            VStack(spacing: Theme.Spacing.xs) {
                Text(SwipeReviewPresentation.reviewedCountText(model.reviewedCount))
                    .font(NettoType.secondaryBody.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(NettoColor.textSecondary)
                Text(SwipeReviewPresentation.selectedForCleanupText(model.deleteDecisionCount))
                    .font(NettoType.secondaryBody.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(NettoColor.brandDeep)
                    .nettoCount(model.deleteDecisionCount)
                    .accessibilityIdentifier(SwipeReviewPresentation.selectedCountAccessibilityID)
            }

            reviewCleanupButton
            newPassButton
            doneButton

            Spacer(minLength: NettoLayout.Spacing.xl)
        }
        .padding(.horizontal, NettoLayout.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Into the *editable* cleanup screen — the identical destination the persistent
    /// swipe-time bar uses. The cleanup screen scopes the list to this session's Delete
    /// marks and only hands a checked subset to the existing review flow; gated by the same
    /// predicate as the persistent bar, so "nothing marked" reads identically on both.
    private var reviewCleanupButton: some View {
        let enabled = SwipeReviewPresentation.reviewCleanupEnabled(
            selectedCount: model.deleteDecisionCount
        )
        return NavigationLink {
            SwipeCleanupSelectionView(model: model)
        } label: {
            Text(SwipeReviewPresentation.completionPrimaryTitle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(NettoPrimaryButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(SwipeReviewPresentation.reviewCleanupAccessibilityID)
    }

    /// "Start New Pass": reshuffle the whole deck (a library deck is rebuilt from the current
    /// catalog first, so newly scanned photos join) and review again. Decisions all stand —
    /// only position and undo history reset, visibly: Undo reads disabled until the new pass
    /// has a decision to reverse.
    private var newPassButton: some View {
        Button {
            startNewPass()
        } label: {
            Text(SwipeReviewPresentation.newPassButtonTitle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(NettoSecondaryButtonStyle())
        .accessibilityIdentifier(SwipeReviewPresentation.newPassAccessibilityID)
    }

    /// Leaves the swipe session (back gesture / this button both end at the same stack pop).
    /// The action itself performs no mutation: every decision already lives in the shared
    /// selection, so the screen underneath — Similar Photos or wherever the session was
    /// entered from — reads the exact counts that were swiped.
    private var doneButton: some View {
        Button(SwipeReviewPresentation.completionSecondaryTitle) {
            dismiss()
        }
        .buttonStyle(NettoSecondaryButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(SwipeReviewPresentation.doneAccessibilityID)
    }
}

// MARK: - Previews

#Preview("Swipe Review") {
    NavigationStack {
        SwipeReviewView(items: SwipeReviewPresentation.items(from: PreviewData.result))
    }
    .environment(PreviewData.environment(analysis: .completed(PreviewData.result)))
}
