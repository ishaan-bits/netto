import Combine
import CoreGraphics
import SwiftUI

// MARK: - Session model

/// The swipe-review session: which photo is on screen, in what order, and what was decided
/// before it. Deliberately owns **no selection** — every decision is written through the
/// caller's `PhotoSelectionModel` (the same value `AppEnvironment` publishes), so swipe mode
/// cannot fork a second source of truth; the model only tracks the cursor and the in-memory
/// undo history.
///
/// Ownership rules:
/// - Order is fixed at init from the caller's deck (the scanned catalog — no scanning, no
///   re-analysis).
/// - Each decision records the photo's selection state *before* the decision, so Undo is an
///   exact restore rather than a re-derivation.
/// - History is session-only memory: leaving the screen drops it and keeps the decisions.
/// - `decide` and `undo` are the only mutation paths; both are no-ops at the boundaries
///   (nothing to decide at the end, nothing to undo at the start).
@MainActor
final class SwipeReviewModel: ObservableObject {
    enum Decision: Equatable {
        case keep
        case delete
    }

    /// One swiped photo: what it was, and what its selection must return to if undone.
    struct HistoryEntry: Equatable {
        let assetID: String
        let wasSelected: Bool
    }

    @Published private(set) var items: [SwipeReviewItem]
    /// Index of the photo on screen; equals `items.count` once every photo has been swiped.
    @Published private(set) var cursor = 0
    @Published private(set) var history: [HistoryEntry] = []

    init(items: [SwipeReviewItem]) {
        self.items = items
    }

    var isComplete: Bool { cursor >= items.count }

    var currentItem: SwipeReviewItem? {
        cursor < items.count ? items[cursor] : nil
    }

    /// Photos decided so far — the completion screen's "N photos reviewed".
    var reviewedCount: Int { min(cursor, items.count) }

    var canUndo: Bool { !history.isEmpty }

    /// Applies one decision to the shared selection and advances. Keep deselects (the photo
    /// is kept), Delete selects it (marked for cleanup) — either way it is only a selection
    /// change; nothing here can reach the deletion pipeline.
    func decide(_ decision: Decision, selection: inout PhotoSelectionModel) {
        guard let item = currentItem else { return }
        history.append(
            HistoryEntry(assetID: item.assetID, wasSelected: selection.isSelected(item.assetID))
        )
        switch decision {
        case .keep:
            selection.setSelected(false, forAsset: item.assetID)
        case .delete:
            selection.setSelected(true, forAsset: item.assetID)
        }
        cursor += 1
    }

    /// Reverses the most recent decision: the cursor returns to that photo and its selection
    /// is restored to exactly what it was before the swipe. No-op when there is no history.
    func undo(selection: inout PhotoSelectionModel) {
        guard let entry = history.popLast() else { return }
        selection.setSelected(entry.wasSelected, forAsset: entry.assetID)
        cursor = max(0, cursor - 1)
    }
}

// MARK: - Swipe review screen

/// One-at-a-time review of the photo library: swipe right (or tap Keep) to keep a photo,
/// swipe left (or tap Delete) to mark it for cleanup, with Undo for the last decision.
/// Entered directly from the dashboard's top-level Swipe Review card — no dependency on
/// Similar Photos, its screens, or its similarity groups.
///
/// Two hard boundaries this screen enforces:
/// - **Selection only.** Every decision flows through `env.mutateSelection` → the existing
///   `PhotoSelectionModel` (the deck is admitted into it on appear, so library photos accept
///   marks without a second selection store); the Review screen at the end is the *existing*
///   `ReviewSelectionView`, which is still the only path that can start a deletion. Nothing
///   on this screen deletes, rescans, or rebuilds a plan.
/// - **One photo loaded at a time.** The preview is the M4J `PhotoPreviewModel` driven by the
///   environment's loader (uncached, released on close or on reaching the completion state) —
///   no second PhotoKit loader, no whole-library prefetch.
///
/// A persistent bottom bar (live count + "Review Cleanup") is on screen for the whole
/// session — finishing the deck is not a precondition for reviewing — and the completion
/// screen repeats the same handoff with "Done" as the way out — neutral because the deck
/// is entered from both Similar Photos *and* the dashboard card, and a hard-coded
/// destination would lie for one of them. Both
/// preserve the shared selection exactly: this screen never instantiates or resets it.
///
/// Exiting early (back gesture / system back) simply pops the stack: decisions already live
/// in the shared selection, so every selection count updates immediately.
struct SwipeReviewView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var model: SwipeReviewModel
    /// The M4J preview lifecycle, re-opened per photo; its bitmap is released on close.
    @StateObject private var preview = PhotoPreviewModel()
    @State private var dragOffset: CGSize = .zero
    /// Drives the skeleton's shimmer sweep; only ever animated when Reduce Motion is off.
    @State private var shimmerSwept = false

    init(items: [SwipeReviewItem]) {
        _model = StateObject(wrappedValue: SwipeReviewModel(items: items))
    }

    var body: some View {
        content
            .background(NettoColor.background.ignoresSafeArea())
            .navigationTitle(SwipeReviewPresentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .nettoAppear()
            .onAppear {
                admitDeck()
                openCurrent()
            }
            .onChange(of: model.currentItem?.assetID) { _, _ in openCurrent() }
            .onDisappear { preview.close() }
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

    /// Loads the photo now on screen — one preview request at a time, through the same
    /// loader policy as Photo Details. Re-opening cancels the previous load; reaching the
    /// completion state closes it entirely and releases the bitmap.
    private func openCurrent() {
        guard let item = model.currentItem else {
            preview.close()
            return
        }
        preview.open(assetID: item.assetID, using: env.thumbnailLoader)
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
        }
    }

    // MARK: Photo card

    private func photoCard(_ item: SwipeReviewItem) -> some View {
        previewStack
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

    /// The preview box itself: same letterboxed, aspect-fit, rounded presentation as Photo
    /// Details, including the interim-frame, skeleton, and unavailable states.
    @ViewBuilder
    private var previewStack: some View {
        ZStack {
            Color.black

            switch preview.stage {
            case .idle:
                Color.black

            case .loading:
                if let image = preview.image {
                    previewImage(image)
                } else {
                    skeleton
                }

            case .ready:
                if let image = preview.image {
                    previewImage(image)
                } else {
                    skeleton
                }

            case .unavailable(let error):
                failureState(error)
            }
        }
        .contentShape(Rectangle())
    }

    private func previewImage(_ image: CGImage) -> some View {
        Image(image, scale: 1, orientation: .up, label: Text("Photo preview"))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// Loading skeleton. Under Reduce Motion the shimmer sweep (a repeating motion) is
    /// replaced by a static placeholder with the loading caption — same information, no motion.
    private var skeleton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .padding(Theme.Spacing.lg)

            if reduceMotion {
                Text(SimilarPhotosPresentation.previewLoadingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                shimmeringSweep
                Text(SimilarPhotosPresentation.previewLoadingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, Theme.Spacing.xl)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(SimilarPhotosPresentation.previewLoadingMessage)
    }

    /// One soft highlight sweeping left-to-right over the placeholder. Decoration only —
    /// never rendered when Reduce Motion is on (the branch above isn't taken then).
    private var shimmeringSweep: some View {
        RoundedRectangle(cornerRadius: NettoLayout.Radius.control, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .padding(Theme.Spacing.lg)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.16), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: geo.size.width * (shimmerSwept ? 1.2 : -0.7))
                    .clipped()
                }
                .clipped()
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmerSwept = true
                }
            }
    }

    /// The existing Photo Details unavailable state — same symbol, copy, and uncached retry —
    /// so a preview that cannot load never degrades into a broken generic image.
    private func failureState(_ error: PhotoContentError) -> some View {
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
            Button {
                preview.retry()
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
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SimilarPhotosPresentation.previewUnavailableTitle)
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
        settleDrag()
    }

    private func performUndo() {
        guard model.canUndo else { return }
        env.mutateSelection { selection in
            model.undo(selection: &selection)
        }
        settleDrag()
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

    /// The bottom action area shown for the whole swipe session: the live count out of the
    /// *shared* selection, then the handoff into the existing `ReviewSelectionView` — the
    /// identical destination the Similar Photos bottom bar and the completion screen use.
    /// Always visible while swiping, clearly unavailable (disabled) while nothing is
    /// selected. It reads `env.selection` directly; there is no local copy to drift, fork,
    /// or reset when navigating away and back.
    private var reviewCleanupBar: some View {
        let enabled = SwipeReviewPresentation.reviewCleanupEnabled(
            selectedCount: env.selection.selectedCount
        )
        return VStack(spacing: Theme.Spacing.sm) {
            Text(SwipeReviewPresentation.selectedForCleanupText(env.selection.selectedCount))
                .font(NettoType.secondaryBody.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(NettoColor.brandDeep)
                .nettoCount(env.selection.selectedCount)
                .accessibilityIdentifier(SwipeReviewPresentation.selectedCountAccessibilityID)

            NavigationLink {
                ReviewSelectionView()
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
                Text(SwipeReviewPresentation.selectedForCleanupText(env.selection.selectedCount))
                    .font(NettoType.secondaryBody.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(NettoColor.brandDeep)
                    .nettoCount(env.selection.selectedCount)
                    .accessibilityIdentifier(SwipeReviewPresentation.selectedCountAccessibilityID)
            }

            reviewCleanupButton
            doneButton

            Spacer(minLength: NettoLayout.Spacing.xl)
        }
        .padding(.horizontal, NettoLayout.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Into the *existing* review flow — the identical destination the Similar Photos bottom
    /// bar and the persistent swipe-time bar use. The review screen prepares its plan from
    /// the shared selection on appear; swipe mode adds no deletion surface of its own. Gated
    /// by the same predicate as the persistent bar, so "nothing selected" reads identically
    /// on both screens.
    private var reviewCleanupButton: some View {
        let enabled = SwipeReviewPresentation.reviewCleanupEnabled(
            selectedCount: env.selection.selectedCount
        )
        return NavigationLink {
            ReviewSelectionView()
        } label: {
            Text(SwipeReviewPresentation.completionPrimaryTitle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(NettoPrimaryButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(SwipeReviewPresentation.reviewCleanupAccessibilityID)
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
    .environmentObject(PreviewData.environment(analysis: .completed(PreviewData.result)))
}
