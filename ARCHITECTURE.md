# Netto — Architecture

iPhone-only (iOS 17+), fully on-device, SwiftUI + Swift 6 strict concurrency. No external
dependencies, no network, no backend.

Core loop: **SCAN → REVIEW → CLEAN**. Nothing is deleted without explicit user approval on a
final review screen.

---

## 1. Modules

Single app target, folder-based modules (no SPM packages — avoids over-engineering for an app of
this size while keeping boundaries visible).

```
Netto/
  App/            Entry point, root flow state, environment composition
  Core/
    Permissions/  Photos + Contacts permission services (protocols + live impls)
    Storage/      Device storage snapshot provider
    Scanning/     Scan phases, progress, result summary (state types)
    Photos/       Asset catalog (done), sizing policy, photo + screenshot selection models,
                  screenshot + video dataset filters, dataset-bound selection model,
                  video size-resolution state + video preview loader, thumbnail store, and
                  Content/Photos/Analysis/ similarity engine
                  (done: candidate buckets, fingerprinting, descriptors, grouping, scoring)
    Contacts/     Duplicate contacts: normalization + match keys, duplicate detector with
                  documented bounds, dataset + scan state, group selection, action plan +
                  merge planner, contacts action state machine, mutation service, and the
                  store reader/backing (the only Contacts write API calls) (§16)
    Deletion/     Safe photo deletion pipeline: plan/validator/state machine + the only
                  Photos mutation code in the app (§7)
  Models/         Shared value types (CleanupCategory)
  Features/
    Dashboard/    Storage + permission status + scan entry + catalog verification
    Photos/SimilarPhotos/  Review UI: phase dispatch, group list, detail sheet,
                  selection bar, destructive review + confirmation (DeletionPresentation) ← done
    Screenshots/  Screenshots cleanup: phase dispatch, selection grid, shared review entry ← done
    Videos/       Large videos cleanup: phase dispatch, measured-size list (largest first),
                  video preview, shared review entry ← done
    Contacts/     Duplicate contacts cleanup: phase dispatch, group list, group detail with
                  selection, review + confirmation (shared destructive-review pattern) ← done
    Review/       (reserved; the cleanup confirmation lives under SimilarPhotos)
  UI/Theme/       Design tokens: color, spacing, radius
  Resources/      PrivacyInfo.xcprivacy
NettoTests/       Unit tests for pure logic (Swift Testing)
```

Rules of thumb applied throughout:

- Feature UI never talks to PhotoKit/Contacts directly; it goes through a `Core` service.
- `Core/…/Deletion` is the only layer permitted to mutate Photos or Contacts.
- Protocols exist only at real boundaries to allow fakes in tests — not for every type. Each is a
  genuine external-system seam:
  `StorageProviding`, `PhotoLibraryPermissionServicing`, `ContactsPermissionServicing`,
  `PhotoLibraryReading` (chunked enumeration: progress, ordering, cancellation from a fake),
  `AssetSizeProviding` (sizing step), `PhotoMutationBacking` + `PhotoDeleting` (deletion
  execution seam: fresh authorization read, existence revalidation, exact-id mutation — faked
  in tests so no test ever mutates a real library), `ContactReading` (read-only contact
  enumeration: lightweight records, never `CNContact`), `ContactMutationBacking` +
  `ContactMutating` (the contacts mutation seam: fresh authorization, fresh field reads for
  revalidation/verification, exact-request application — faked in tests so no test ever
  writes a real contact), and the similarity engine's four seams —
  `ContentFingerprinting`, `PhotoThumbnailLoading`, `PhotoFeatureExtracting`, and
  `PhotoAnalysisStageObserving` — because each talks to a system whose failure and timing the
  tests must control (PhotoKit, Vision, and the stage/abort instrumentation respectively).

## 2. Dependency composition

`AppEnvironment` (MainActor, `ObservableObject`) is the single composition root. It owns service
instances (injectable in tests) and published UI state. Views receive it via `.environmentObject`.
No singletons, no global mutable state.

## 3. State management

Explicit enums instead of boolean soup:

- `AppFlowState` — `launching / dashboard / scanning(ScanProgress) / resultsAvailable /
  review / deleting / deletionCompleted / deletionFailed(String)`
- `ScanPhase` — `idle / scanning(ScanProgress) / cancelled / completed(ScanResultSummary) /
  empty / failed(ScanFailure)`
- `CatalogScanState` — `notStarted / running(CatalogScanProgress) / completed(CatalogScanResult) /
  cancelled / failed(CatalogScanFailure)`
- `PhotoAnalysisState` — `notStarted / running(PhotoAnalysisProgress) /
  completed(PhotoAnalysisResult) / cancelled / failed(PhotoAnalysisFailure)`
- `SimilarPhotosPhase` — **derived, never stored**: the pure `(permission, catalog, analysis)`
  mapping that decides what the review screen renders (§13.1)
- `ScreenshotsPhase` — **derived, never stored**: the pure `(permission, catalog)` mapping for
  the screenshots screen — analysis state never participates (§14)
- `VideosPhase` — **derived, never stored**: the pure `(permission, catalog, resolution)`
  mapping for the Large Videos screen — analysis state never participates (§15)
- `VideoSizeResolution` — **stored, but explicit**: `idle / measuring(Measurement) /
  settled(Measurement)` over one dataset fingerprint; bytes are only what the size provider
  actually resolved (unknown ≠ zero), and every batch write is generation-guarded (§15)
- `DeletionState` — the explicit deletion machine (§7): `noSelection / preparingPlan /
  resolvingSizes / readyForReview(DeletionPlan) / planStale(DeletionPlan, [PlanStalenessReason]) /
  awaitingConfirmation(DeletionPlan) / deleting(DeletionPlan) / succeeded(DeletionSuccess) /
  needsReview(DeletionSuccess) / failed(String) / permissionRequired(PermissionState)`. Every
  change passes `DeletionState.canTransition(from:to:)`; illegal sequences (deleting without
  confirmation, a result without execution, re-executing a finished plan) are assertion
  failures, and `noSelection` is the one universal safe reset (it removes capability only).
- `DeletionReviewPhase` — **derived, never stored**: the pure `DeletionState` → review-screen
  projection (§13.5)
- `ContactScanState` — **stored, but explicit**: `notStarted / running / completed(ContactDataset) /
  cancelled / failed(String)` over one contacts scan; the dataset carries the records plus the
  detector's groups (§16)
- `ContactsPhase` — **derived, never stored**: the pure `(permission, scan)` mapping the
  Duplicate Contacts screen and its dashboard status render from (§16.2)
- `ContactActionState` — the explicit contacts action machine (§16.5): `noSelection /
  preparingPlan / readyForReview(ContactActionPlan) / planStale(…) / awaitingConfirmation(…) /
  executing(…) / succeeded(ContactMutationSuccess) / needsReview(ContactMutationSuccess) /
  failed(String) / permissionRequired(PermissionState)`. Every change passes
  `ContactActionState.canTransition(from:to:)`; illegal sequences (mutating without
  confirmation, re-running a finished plan) are assertion-level unrepresentable, and
  `noSelection` is the universal safe reset — mirroring `DeletionState` for the same reasons.
- `PermissionState` — `notDetermined / authorized / limited / denied / restricted`
- `PermissionPrompt` — pre-prompt and denied/limited sheet routing
- `ScanProgress` — `stage + completedUnits + totalUnits` (fraction is derived, clamped by use)
- `CatalogScanProgress` — `enumeratedCount + totalCount` for the catalog stage

`ScanFailure` and `CatalogScanFailure` carry user-facing messages; errors never surface as raw
`Error` text.

## 4. Scan pipeline

```
PhotoKit fetch (metadata only, chunked)          ← IMPLEMENTED: Core/Photos
  → candidate bucketing by cheap keys             ← IMPLEMENTED: Core/Photos/Analysis (§5.2)
      (aspect ratio + temporal chains, capped bucket size)
  → two-phase exact fingerprint (length, then SHA-256 on collisions only)  ← §5.3
  → bounded thumbnail requests (≤ 256 px, orientation baked in)           ← §5.6
  → descriptor extraction (Vision feature print, or 16×16 CPU grid when
      Vision's inference stack is unavailable — chosen once per run)      ← §5.4
  → in-bucket pair comparison, relations ≤ threshold
  → exact groups by fingerprint + near groups by complete-linkage         ← §5.3/§5.5
  → best-photo scoring (documented heuristic, recommendation only)       ← §4.4
  → PhotoAnalysisResult
  → review UI: phases, group list, thumbnails, selection model           ← §13 (this milestone)
  → [later] exact DeletionPlan → confirm → mutation
```

### 4.1 Catalog stage (implemented)

`PhotoCatalogBuilder` turns PhotoKit into `[PhotoAssetRecord]` and does nothing else.

- **Metadata only.** The reader (`SystemPhotoLibrary`) uses `PHFetchResult<PHAsset>` and copies
  scalar properties. It never requests image data, thumbnails, `PHAssetResourceManager`
  payloads, or `PHContentEditingInput`s. Screenshot detection is
  `PHAssetMediaSubtypePhotoScreenshot` only — no filename or OCR heuristics.
- **No `PHAsset` retention.** Records hold `localIdentifier` + lightweight fields; an asset is
  re-fetched by id when a thumbnail or deletion needs it.
- **Chunked.** `chunkSize` (default 512) index ranges, so memory stays flat and cancellation has a
  predictable tick. Out-of-bounds ranges are clamped, so a library that shrinks mid-scan yields a
  shorter result rather than a trap.
- **Ordered.** `PHFetchOptions.sortDescriptors = [creationDate descending]`, applied by PhotoKit.
  Progress events come from that single loop, so they arrive in order and `.completed` is always
  last.
- **Cancellable.** `makeScanStream` returns an `AsyncThrowingStream`; the enumeration itself runs
  on a `Task.detached` producer. Cancelling the consumer terminates the stream, which cancels the
  producer via `onTermination`, and the producer checks `Task.isCancelled` between chunks. Failure
  mode is `CatalogScanFailure.cancelled`, never a hung continuation.
- **Access-aware.** `.authorized` and `.limited` are carried on `CatalogScanResult.accessLevel` so
  the UI can say plainly what was and was not scanned.
- **Burst metadata.** `representsBurst` / `burstIdentifier` are recorded (available since iOS 8 on
  iOS, despite the macOS-only availability annotation in the header) because best-photo scoring
  needs them later.

The catalog stage (`Core/Photos`, outside `Analysis/`) never imports Vision, never decodes an
image, and never calls a mutation API. Vision is confined to `Core/Photos/Analysis/PhotoFeatureExtractor`.

### 4.2 Sizes: deferred, never fabricated

**iOS 17 exposes no public, cheap, exact per-asset byte count.** `PHAssetResource.dataSize` is
iOS 27+ (verified against the iOS 27 SDK: it is an `@available(iOS 27)` extension member), and
getting a size any other way means retrieving content. So:

- `PhotoAssetRecord.sizeInBytes` is `nil` at catalog time. `nil` means *unknown*, never `0`.
- Enumeration is forbidden from writing it. There is no fallback estimate anywhere in the app.
- Sizes are resolved later by `AssetSizeProviding`, for an explicitly selected, bounded subset on
  the way to Review — **after** analysis, **before** confirmation. Device storage
  (`StorageProviding` / `StorageSnapshot`) is a separate measurement of the volume and is never
  mixed with asset size.

`PhotoKitAssetSizeProvider` (iOS 17 path) requests `PHContentEditingInput` with
`isNetworkAccessAllowed = false` — which downloads nothing — and stats `fullSizeImageURL` plus the
`AVURLAsset` URL, summing both so a Live Photo's still and movie both count. An asset whose data
is only in iCloud yields no local URL and is reported as unknown rather than guessed.

The Large Videos screen (§15) is the one place that measures a whole media class up front —
sorting by size *is* the feature. It uses the same `AssetSizeProviding` seam read-only, in
bounded sequential batches with a generation guard (§15.4), never as part of plan building, and
applies the same rule: unknown stays unknown (`nil` ≠ `0`), a video that never resolved sorts
after every measured one and renders "Size unavailable".

### 4.3 Resource scope policy

`AssetResourceScope` is the single, documented answer to "which resources make up an asset's
size":

| Counted | Not counted |
|---|---|
| `photo`, `video` | `adjustmentData`, `adjustmentBasePhoto`, `adjustmentBaseVideo`, `adjustmentBasePairedVideo` |
| `fullSizePhoto`, `fullSizeVideo` | `audio` |
| `pairedVideo`, `fullSizePairedVideo` | `photoProxy` |
| `alternatePhoto` (RAW alongside JPEG) | |

Edit instructions and their intermediates are excluded because they are not user content and would
double count against the render that replaced them. The policy is written now — and unit-tested —
even though iOS 17 cannot apply it directly, so adopting `dataSize` when available is a mechanical
change rather than a redesign.

Key properties of the analysis stages — now implemented and enforced by
`Core/Photos/Analysis` (details in §5):

- **No O(n²).** Pairwise comparison happens only inside buckets whose keys already match
  (identical pixel dimensions + close capture time). Comparisons per asset are bounded by bucket
  size (64), not library size (§5.2, tested at n=600).
- **No full-res decoding of the library.** PhotoKit delivers ≤ 256 px thumbnails sized for
  analysis, one asset at a time inside a bounded task group.
- **Bounded concurrency.** A fixed-width worker pool (not one Task per asset) keeps peak memory
  flat and lets the CPU sit at useful utilization on an A-series chip.
- **Cancellable + progress.** Every stage checks cancellation; progress is reported through
  `PhotoAnalysisProgress` via an `AsyncThrowingStream`, with `.completed` always last (§5.7).
- **Incremental (future).** Fingerprints (8–32 bytes/asset) will be cached in a local store keyed
  by `localIdentifier + modificationDate`; unchanged assets are skipped on rescan. Cache holds
  only derived data — never copies of user photos.
- **Main actor stays free.** All enumeration, decoding, and descriptor work runs off the main
  actor; the UI only receives progress snapshots and final results.

### 4.4 Best-photo scoring (documented, implemented, overridable)

`BestPhotoScoring` produces a *recommended* "keep" per group, in priority order:

1. Favorited (the user already marked it)
2. Not a burst member (burst metadata from `representsBurst` / `burstIdentifier`)
3. Higher pixel count (resolution)
4. Has adjustments → edited wins (the render is what the user chose)
5. Newer capture date as final tiebreak (`nil` sorts oldest; then smallest `localIdentifier` for
   run-to-run determinism)

Deliberately **not** in the heuristic: `sizeInBytes` (unavailable on iOS 17, §4.2) and sharpness
(no blur detection this milestone — a Laplacian pass can be added later without changing the
group model). This is a recommendation surfaced as a default; the user can flip any selection. We
do not claim any photo is universally "best".

## 5. Photo similarity analysis engine (implemented)

`Core/Photos/Analysis` turns `[PhotoAssetRecord]` into a `PhotoAnalysisResult`: **exact
duplicate** groups (bit-identical content) and **near duplicate** groups (visually similar),
plus an honest list of assets it could not analyze and why. Analysis only — it never mutates the
library, never enables network access, and never retains full-resolution pixels.

Pure logic (bucketing, fingerprint keys, descriptor math, grouping, scoring) is a set of pure
functions over injected data; PhotoKit and Vision sit behind four seams (`ContentFingerprinting`,
`PhotoThumbnailLoading`, `PhotoFeatureExtracting`, `PhotoAnalysisStageObserving`), so the entire
pipeline is unit-tested without a photo library, permissions, or a working Vision backend.

### 5.1 Stage sequence and progress

`preparing → generatingCandidates → fingerprinting → (extractingFeatures ↔ comparing) × buckets
→ grouping → finalizing`.

- Progress per stage is monotonic; `.completedUnits` reaches `totalUnits` on every determinate
  stage, and `.completed` is always the last event. `generatingCandidates` is indeterminate
  (total 0 → `fraction == nil`) because bucketing is one synchronous metadata pass.
- The extraction/comparison pair **interleaves per bucket** rather than running as two global
  phases. That bounds live memory: at most `maxConcurrentWorkers × maxBucketSize` feature prints
  exist at once, instead of one print for the whole library.
- Every stage transition goes through a single locked reporter; tests assert exact stage order
  (with one worker), monotonicity, and completion totals.

### 5.2 Candidate reduction: why there is no O(n²)

`CandidateBuckets.make` partitions eligible image records using only catalog metadata:

- **Aspect key**: `round((max/min) / 0.01)` — ratios within ~1% share a key, so small crops can
  still match while landscape/portrait never meet.
- **Temporal chains**: creation dates further apart than 600 s (10 min) start a new chain —
  burst frames, Live Photo stills, and double-shoots all sit well inside that window.
- **Bucket cap (64)**: oversized chains are split at the largest internal gap, preferring a cut
  near the midpoint; a gap never overrides the cap (`gapAwareSplitIndex`), so no bucket can
  exceed `maxBucketSize`.
- **Partition, not filter**: every eligible record lands in exactly one bucket — nothing is
  dropped silently. Invalid dimensions (≤ 1 px) are excluded with a reason; non-image,
  non-video media is `.notAnalyzable`; videos are fingerprinted (§5.3) but never visually
  bucketed.

Comparisons are then only `Σ size(bucket)·(size(bucket)-1)/2` — bounded by `maxBucketSize`, not
library size: at most `n × 64` pairs, asserted for n=600 (well under 25% of `n(n-1)/2`, ~10% for
the uniform-timestamp case the test uses). Relation collection also drops pairs already proven
byte-identical, so exact pairs are never compared twice.

### 5.3 Exact duplicates: two-phase content fingerprinting

Fingerprinting reads content only where cheap evidence already collides:

1. **Phase 1 — length.** One `PHContentEditingInput` request per *image* records computes
   `ContentByteKey` (still bytes, paired-video bytes) by stat-ing `fullSizeImageURL` /
   `audiovisualAsset` URLs — file-attribute reads, no content. Live Photos sum both files; a Live
   Photo whose paired video cannot be resolved locally (iCloud-only) is
   `.contentUnreadable` rather than a still-only key that could false-match a plain photo of the
   same scene.
2. **Phase 2 — hash.** SHA-256 streams only the byte-length collisions, chunked through
   `ContentHasher` (never a whole file in memory), cancellable mid-stream.

Provenance rule: `canHandleAdjustmentData = { _ in false }`, `version = .current`,
`isNetworkAccessAllowed = false` — matching the visible content the user sees, and matching
`AssetSizeProvider`. Results group by `(digest, bytes)`; evidence carries the digest and byte
count. Phase-1 stats alone make progress reach its total (one unit per eligible asset, counted
once), with phase-2 work folded in — never double-counted.

The live implementation sits behind the `ContentFingerprinting` seam as an injectable
`ContentResolution` closure (live: one `requestContentEditingInput` per image). The decision
core — `resolveContent(info:imageURL:videoURL:)` — is a pure function over those inputs, tested
without a library: cancelled → `CancellationError`, cloud flag → `.contentOnlyInICloud`,
`PHContentEditingInputErrorKey` → `.permissionUnavailable` / `.assetNotFound` /
`.contentOnlyInICloud` / `.contentUnreadable` by documented `PHPhotosError` code (foreign
domains pass through untouched), Live Photo without paired video / video without URL /
zero-byte file → `.contentUnreadable`. Two invariants are enforced and tested: cancellation
propagates as `CancellationError` (never downgraded into an "unavailable" verdict), and an
unreadable asset yields `.unavailable(reason)` — never a byte key, because a key would claim
"unique" for content nobody saw.

Exact-fingerprint pairs are excluded from the near-duplicate relations: byte-identical content
is reported exactly once, as an exact group.

### 5.4 Descriptors: dual backend, one per run

Near-duplicate detection compares descriptor vectors with Euclidean distance (L2) on
`FeaturePrint`, per descriptor family — kinds are never mixed inside a run. Even a hostile
extractor that returns prints from the *other* family cannot corrupt grouping: cross-family
`distance(to:)` throws `kindMismatch`, the comparison loop drops the pair, and the run reports
neither a fabricated relation nor an unavailable-inflation (tested).

- **`.visionFeaturePrint`** — `VNGenerateImageFeaturePrintRequest` (revision 2) on the ≤ 256 px
  thumbnail. Native, on-device, robust to re-encodes. Threshold (provisional): **0.2**.
- **`.cpuGrid`** — pure CoreGraphics: draw the thumbnail into 16×16 RGB, mean-center each
  channel (brightness invariance), append the three channel means ×0.5 (so solid red ≠ solid
  blue), L2-normalize → 771 floats. Threshold (synthetic-calibrated): **0.15**.

`VisionPhotoFeatureExtractor.prepare()` runs one throwaway feature print and **latches** the
backend for the whole run: a good probe → Vision for every asset; a failing probe → CPU grid.
Per-asset Vision failure *after* a good probe marks only that asset `.visionFailed` — the run
continues. The chosen `descriptorKind` and `visionAvailable` are reported in the result.
Failure reasons name the family that actually ran: a Vision-run failure is `.visionFailed`, a
CPU-fallback failure is `.cpuDescriptorFailed` (asserted), and a `prepare()` cancelled mid-probe
latches `.cpuGrid` (the safe, fully functional family) rather than a half-probed state.
`VNGenerateImageFeaturePrintRequestRevision2` is iOS 17 in the installed SDK — exactly the
deployment target, no availability guard needed.

Why this exists (measured in this repo's simulator): Vision's inference stack is unavailable in
the iOS Simulator — `VNGenerateImageFeaturePrintRequest` fails with `NSOSStatusErrorDomain -1
"Failed to create espresso context."` and face detection with `com.apple.Vision 9 "Could not
create inference context"`, while geometric requests (`VNDetectRectanglesRequest`) succeed.
Rather than crash, fake it, or assume hardware behaves like the simulator, the engine probes
once per run and reports which family it used.

Calibration evidence for 0.15 (printed by `FeaturePrintTests`): brightness-perturbed pair
≈ 0.126, contrast-perturbed ≈ 0.133, unrelated pairs ≈ 1.12–1.25, solid red vs solid blue
≈ 1.20 — the threshold separates. Vision's 0.2 is based on synthetic vectors only and is on the
device-validation list.

### 5.5 Grouping: complete-linkage cliques, not union-find

- **Exact groups**: by identical `ContentFingerprint`; deterministic member ordering.
- **Near groups**: greedy **complete-linkage** over relations sorted by
  `(distance, assetA, assetB)`. Two clusters merge only if *every* cross pair is itself a
  relation; a new member joins only if it relates to *every* resident. Every returned group is
  therefore a clique: all pairwise distances ≤ threshold, evidence is exact min/max distance,
  and the A≈B, B≈C chain can never swallow an unrelated C. Union-find/single-linkage would do
  exactly that — the classic transitive-closure failure that makes dedupe apps suggest deleting
  half a library.
- Groups carry `memberScores` plus `recommendedBestAssetID` (§4.4) — a recommendation, never a
  deletion decision. A member without catalog metadata drops the whole group rather than emit an
  unbacked recommendation.
- Sorting everywhere (groups, members, unavailable reasons) makes results byte-identical across
  runs — asserted by test.

### 5.6 Thumbnails, orientation, and iCloud

- `.aspectFit` inside a `thumbnailMaxPixelSize × thumbnailMaxPixelSize` box (default 256 px),
  `.highQualityFormat` (exactly one callback, no degraded-then-final double fire),
  `.version = .current`. Full-resolution pixels are never decoded.
- Orientation is baked into the pixels once at the boundary (`normalizedCGImage`), so Vision and
  the CPU descriptor see identical upright geometry — an EXIF-rotated still plus its rotation
  would otherwise stop matching each other.
- `isNetworkAccessAllowed = false` everywhere: an iCloud-only asset surfaces as
  `PhotoContentError.onlyInICloud` → unavailable reason, never a surprise download. Availability
  is per path: an asset can fail content fingerprinting (no exact verdict) yet still join a
  visual group from its thumbnail, with visual evidence — reported, not hidden.
- Requests run through `PendingPhotoRequest`: exactly-once continuation, PhotoKit cancellation
  on task cancel, no callback races. `PHAsset`s are fetched by id and never retained.
- Every fetch begins with a permission **status read** (`PHPhotoLibrary.authorizationStatus`,
  never a request): access off → `.permissionDenied`, identifier not visible (deleted, or
  outside limited access) → `.assetNotFound`. Without the pre-check an empty fetch would
  misreport every asset as "deleted" when the real answer is "Photos access is off".
  `PHImageErrorKey` NSErrors are mapped through the documented `PHPhotosError` codes
  (iOS 15+, verified in the installed SDK headers); foreign error domains pass through
  unchanged.
- Both live seams are injectable — the loader takes an `ImageRequest` closure, the fingerprinter
  a `ContentResolution` closure — so tests exercise the *production* mapping/options code with
  no photo library, no permissions, and no iCloud.

### 5.7 Bounded concurrency, cancellation, and the abort seam

- **Fixed worker width** (`maxConcurrentWorkers`, default 4) via `BoundedWorkers`: strided
  workers over a `withThrowingTaskGroup`; the first child error cancels the group and rethrows.
  Never a Task per asset.
- **Cancellation** is checked at every stage boundary and inside worker loops; the stream
  producer runs on `Task.detached` with `onTermination` → cancel, so consumer cancellation ends
  the run promptly (PhotoKit in-flight requests are cancelled through the bridge). The
  `analyze(records:)` convenience maps this to `PhotoAnalysisFailure.cancelled`.
- **Abort seam**: `PhotoAnalysisStageObserving.analysisStageWillBegin` is `throws`, and the
  reporter propagates it from whichever task reported — so a test can deterministically kill the
  run *at any stage* and assert: no `.completed` event, an error surfaces, and
  `analysisDidFinish()` still runs (via `defer`).
- Shared state (lengths, fingerprints, relations, unavailable reasons) lives in one locked box
  per run; unavailable reasons are first-reason-wins.

### 5.8 Instrumentation

`SignpostStageObserver` emits one `os_signpost` interval per stage (static per-stage names —
`OSSignposter` messages are `StaticString`) plus an event on entry, and calls `analysisDidFinish`
on teardown. Measuring real-device cost is a device-validation item, not a claimed number.

`AnalysisMetrics`, injected per run, is the device-validation hook: seven durations
(candidates, fingerprint, thumbnail, descriptor, comparison, grouping, total) and six counters
(considered, fingerprinted, described, unavailable, exact groups, similar groups) behind one
lock, recorded as monotonic-clock deltas that cannot materially move what they measure. It emits
exactly **one `os.Logger` summary line per run** — cancelled runs included, because cancellation
timings are precisely what a device session wants to see — with `privacy: .public` on counts and
seconds only (never asset content). Tests inject an instance and read `snapshot()`: a completed
run must have all seven durations plus counters agreeing with the result envelope, and an
aborted run must still record `.total` while success-only counters stay unset (both asserted).

### 5.9 Limitations and device-validation items

Nothing below is estimated or faked; each is either a documented boundary or an open device test:

1. **Vision on hardware** — presumed working where the simulator fails espresso-context; verify
   feature prints on a real iPhone, including an `available-vision` run of the extractor tests.
2. **Thresholds** — 0.2 (Vision) and 0.15 (CPU grid) are synthetic-calibrated; recalibrate on a
   real library (near-dupes, re-encodes, crops) before trusting review suggestions.
3. **Edited-asset provenance** — confirm `PHContentEditingInput.fullSizeImageURL` under
   `canHandleAdjustmentData = false` yields rendered (visible) content for edited assets; if a
   device shows originals, exact fingerprinting must treat `hasAdjustments` assets specially.
4. **`requestContentEditingInput` cost** at whole-library scale (called once per image for
   length stats) — measure with signposts; only length collisions trigger a second, streaming
   read.
5. **No fingerprint cache yet** — every run re-reads lengths (and hashes collisions). The cache
   is designed (keyed by `localIdentifier + modificationDate`, derived data only) but not built.
6. **Similarity scope** — near-matches require same aspect bucket + capture times within 10 min;
   a re-cropped screenshot from last month will not be offered. Exact detection has no such
   limit.
7. **Videos** — exact duplicates only; no visual/video-frame analysis this milestone. No blur
   detection, no compression analysis.
8. **No UI** — the engine has no screen; surfacing groups in the dashboard/review flow is a
   later milestone, along with deletion.
9. **Device validation: NOT PERFORMED** — no physical iPhone was connected during this
   milestone; every result above is a simulator result and is reported as such. Items 1–4
   (Vision on hardware, threshold recalibration, edited-asset provenance, whole-library
   `requestContentEditingInput` cost) remain open, plus the live-library checklist: real asset
   fetches at scale, the permission prompt and limited-access mode, iCloud-only assets, Live
   Photos and videos end-to-end, and a controlled test set (2 exact duplicates, 2 near
   duplicates, 2 unrelated, 1 Live Photo, 1 video, 1 edited asset, 1 iCloud-only asset). No
   performance number has been measured or is claimed.

## 6. Memory strategy

- Thumbnails requested at analysis size only; released as soon as the fingerprint is computed
  (no image retained beyond its asset's processing step). The analysis engine's
  extract/compare interleave further bounds this: at most `workers × maxBucketSize` feature
  prints are alive at once (§5.1), and SHA-256 hashes stream from disk chunk by chunk instead of
  buffering a file.
- Result models store `PHAsset` identifiers + lightweight metadata, not `UIImage`s. Grid cells
  request their own small thumbnails from PhotoKit with cancellation on reuse.
- Video preview uses `AVPlayer` + SwiftUI `VideoPlayer` (AVKit) for one asset at a time;
  playback never triggers a download (the preview loader is network-off) and never loads a
  whole file into memory, and the player is released when the preview closes.
- Byte sizes are never derived from decoding or buffering content. They come from stat-ing a
  local content URL for a bounded, user-selected subset (§4.2) — a metadata/file-attribute read,
  not a content read.

## 7. Deletion safety model (implemented — photos, screenshots, videos)

Deletion is strictly separated from analysis, and the pipeline is explicit about every
hand-off:

```
ANALYSIS (read-only) → SELECTION (in-memory) → PLAN (immutable snapshot)
→ CONFIRMATION (explicit, destructive) → MUTATION (Core/Deletion only) → VERIFICATION
```

**The plan (`DeletionPlan`, Core/Deletion).** Selecting photos never mutates anything. The
plan is an immutable value built from the reviewed selection: exactly the selected stable
local identifiers (sorted, deduped — set semantics make duplicates impossible), each asset's
media classification, exact byte sizes where measured (`nil` = unknown, **never** coerced to
zero), a category label (exact beats similar, deterministic), plus the creation context used
to detect staleness: the authorization status at creation, the app session token, and a
structural fingerprint of the dataset the selection came from — the analysis result for the
similar-photos source, the screenshot subset of the catalog for the screenshots source (§14),
the video subset for the videos source (§15).
The mutation service does not accept raw
identifiers — only a `ConfirmedDeletionPlan` obtained through `DeletionPlan.confirmed()`,
which refuses an empty plan by type.

**Sizes.** Sizes resolve only for the reviewed subset through `AssetSizeProviding`, after
enumeration. The summary distinguishes three states: **exact** (every item measured — the
total is real), **partial** (measured bytes are a lower bound — the UI says "at least … · N
sizes unavailable"), and **fully unresolved** (UI says "Measured size unavailable", never
"0 GB"). Confirmation copy never promises that device free space will change: iOS moves
deleted items to Recently Deleted and reclaims space on its own schedule.

**Staleness (`DeletionPlanValidator`, pure).** Before any mutation, the plan is compared —
in a fixed, deterministic reason order — against the current context: session token,
analysis fingerprint, selection set, and **freshly read** authorization. Any mismatch means
`.planStale`: the plan goes back for review, nothing is touched. A missing asset is the
special `.assetsMissing` reason: if even one planned identifier no longer resolves in the
library, the whole plan is stale — the set is never silently shrunk to what remains.

**Fresh authorization, checked in the mutation path itself.** Immediately before mutating,
the service re-reads `PHPhotoLibrary` authorization status (a plan's stored result is never
trusted), verifies it still permits read-write, and confirms the live library still contains
exactly the planned identifiers — all inside the same final pre-mutation path. If
authorization changed (e.g. limited → denied, or any other state change), the plan is
invalidated; if the fresh status does not permit deletion, a structured permission error is
returned with **zero mutations** and no automatic re-prompt. The pipeline never requests
broader access on its own.

**Mutation + verification.** The delete runs in `PHPhotoLibrary.performChanges` inside
`Core/Deletion` (the only Photos write code in the app) with exactly the plan's identifiers —
re-fetched by identifier inside the change block, so no other asset can enter the request.
Cancellation returns `.cancelled`, PhotoKit errors map to `.mutationFailed`. After the
request, identifiers are re-fetched and compared: all gone → `.succeeded`; some remain →
`needsReview` with the remaining ids (never reported as full success); verification itself
failing → `.failed` with a message that does not claim success.

**State machine.** `DeletionState` (§3) gates the whole flow: `readyForReview →
awaitingConfirmation → deleting → succeeded/needsReview/failed/…`, with every transition
checked by `canTransition`. Confirmation is reversible (dialog cancel returns to review) and
mandatory — there is no edge into `deleting` from any other state, and a finished plan can
never re-enter execution. Changing the selection after review immediately stales the plan
(`selectionChanged`). Starting a new analysis resets the deletion state (plans are bound to
their dataset), and analysis cannot start while a deletion is executing.

**Outcome handling.** One handler maps `DeletionOutcome` to states: success/partial reset
selection, invalidate the analysis generation, mark catalog + analysis `notStarted` (the
library changed, so nothing read before may be reused), and refresh the storage snapshot;
stale → plan review again; permission → Settings recovery; failures → friendly messages
(PhotoKit's raw error text never reaches the UI); cancellation → back to review with the
plan intact.

**Current state:** implemented for photos — review screen → confirmation dialog → PhotoKit
deletion → post-verification, all unit-tested against fakes (no test mutates a real library).
Contacts merge/delete remains a separate, unimplemented workflow with its own confirmation,
never batched with photo deletion.

**Device validation: NOT PERFORMED** (no physical iPhone connected; simulator cannot host a
real mutating photo-library session) — the on-device deletion matrix in §10 remains pending.

## 8. Permission model

- Pre-prompt sheet explains *why* before the system dialog (Photos / Contacts copy in
  `PermissionPrimingView`, Info.plist usage strings match).
- Photos: full, **limited**, denied, restricted, notDetermined are all first-class states.
  Limited access is treated as usable (we scan what's visible) and surfaced honestly in the UI.
- Denied/restricted rows deep-link to Settings via `UIApplication.openSettingsURLString`.
- Re-checked on every foreground (`refreshPermissions()`), so returning from Settings updates UI.
- Every code path tolerates unavailable permission: no crash, empty result or explicit state.

## 9. Storage dashboard

`SystemStorageProvider` reads `volumeTotalCapacity` and
`volumeAvailableCapacityForImportantUsage` from the home volume URL — real system values, computed
off the main actor. Used = total − available. Refreshable via pull-to-refresh. No faked numbers.

## 10. Testing strategy

- **Unit tests (Swift Testing, `NettoTests`)** cover pure logic: storage math, byte formatting,
  permission-status mapping, progress/phase transitions, emptiness detection. These run in CI/sim
  with no permissions required.
- The catalog stage is tested against a `PhotoLibraryReading` fake: ordering, chunk boundaries,
  monotonic progress, cancellation between chunks, denied access, a library that shrinks
  mid-scan, and limited-vs-full access are all exercised without a photo library. Screenshot
  classification, `sizeInBytes` staying nil, `resolvingSize` immutability, cache-key identity, and
  `AssetResourceScope` partitioning every known resource type are covered as pure tests.
- The similarity engine is tested against injected seams (`ContentFingerprinting`,
  `PhotoThumbnailLoading`, `PhotoFeatureExtracting`, `PhotoAnalysisStageObserving`) over a stub
  photo library: candidate-bucket splitting and caps, length/hash fingerprinting, descriptor
  math and threshold boundaries (bit-exact at 0.25), complete-linkage clique rules and chain
  rejection, exact-vs-near double-reporting, unavailable reasons (iCloud, unreadable content,
  per-asset Vision failure, non-analyzable media), exact duplicate videos, stage order,
  monotonic per-stage progress, abort at every stage via the throwing observer, consumer
  cancellation, determinism across runs, and the candidate-pair bound at n=600. The Vision
  extractor's probe/latch behaviour runs in the simulator against the real (failing) backend;
  its CPU-grid fallback path is covered the same way.
- The live PhotoKit seams are exercised without a library through their injectables:
  `PendingPhotoRequest`'s exactly-once/cancellation state machine (double callbacks, late
  callbacks after success, pre-cancelled tasks, cancel-action invoked exactly once, no hangs);
  the thumbnail loader's request-option policy, `PHImage` callback → error-vocabulary mapping
  (cancelled / in-cloud / `PHPhotosError` codes / foreign domains), orientation baking, and
  permission-vs-not-found classification of a real fetch; the fingerprinter's `resolveContent`
  decision core (cancelled, cloud flag, error codes, missing everything, Live Photo pairing,
  zero-byte files, byte counts, same-length files hashing differently), and the
  `ContentFingerprinting` contract (unreadable → `.unavailable`, never a key; cancellation
  propagates; streaming digest equals `ContentHasher` direct output); plus the engine's
   permission/asset-not-found/CPU-fallback reason mapping, a hostile mixed-kind extractor that
   must not corrupt grouping, and `AnalysisMetrics` completeness on success and
   `.total`-on-abort.
- The review layer is tested as pure logic + orchestration: `PhotoSelectionModel` (deterministic
  defaults, cross-group protection of recommendations, exact outcomes of the three labelled
  group actions, unknown-id rejection, `GroupSelectionState`/counts, inert empty model, init
  from a result); the full `SimilarPhotosPresentation` mapping (permission gating even over a
  finished result, running-analysis and running-catalog precedence, zero-record → emptyLibrary,
  catalog idle/empty, failure messages, cancelled states, clamped/nil bar fractions, every
  stage's copy, summary counts, limited-access notice); `ThumbnailStore` (cache hits,
  size-partitioned keys, negative caching with the original error on first failure, cancellation
  never cached, LRU and byte-budget eviction, concurrent-request coalescing); and
  `AppEnvironment` orchestration against an injected factory — permission fail-fast without
  touching the library, factory-failure message mapping, empty and distinct-library runs
  through the **real** engine, selection reset on start / persistence across unrelated state
  changes, cancellation beating a late completion (generation guard), and the denied-access
  catalog path.
- The deletion pipeline is tested end-to-end against fakes — no test ever mutates a real photo
  library. Planner/plan: exact id set with deterministic order and dedupe, empty selection and
  missing-record refusals (the plan never silently shrinks), `nil` sizes staying `nil`,
  exact-vs-partial-vs-unresolved summaries, category precedence (exact wins), and
  analysis-signature sensitivity to membership changes. Validator: staleness in both
  authorization directions plus session/analysis/selection drift, in the documented reason
  order. Confirmation boundary: a non-empty plan confirms with identical contents; an empty
  plan can never reach the mutation type. State machine: every legal edge, no path into
  `deleting` without confirmation, results require execution, finished plans are dead, and
  `noSelection` is a universal safe reset. `DeletionPresentation`: phase mapping for every
  state, destructive titles naming count, size wording per completeness (never zero, never an
  unqualified promise), category parts summing to the count, and raw error text never reaching
  the user. Service (lock-guarded fake `PhotoMutationBacking`): exact plan identifiers only,
  fresh authorization read on every execution, empty/selection/session refusals, fresh-deny
  with zero mutations, authorization-change staleness in both directions, vanished-asset
  staleness for the whole plan, localized-description propagation, cancellation, full vs
  partial post-verification, and post-verify failures never claimed as success.
  `AppEnvironment` orchestration: confirmation gating (no confirmation ⇒ service never
  called), every outcome mapped, success resetting selection + invalidating analysis + storage
  refresh, analysis-start invalidation, and plan preparation guarded during deletion.
- The screenshots pipeline is tested as pure logic + orchestration, with `analysisState`
  deliberately `.notStarted` to prove the feature never waits on it: `ScreenshotDataset`
  (subtype-only filter in catalog order, id dedupe, order-independent membership-sensitive
  signature), `ScreenshotSelectionModel` (dataset-scoped toggle, select-all covering exactly
  the dataset, reconcile dropping vanished selections, reset), the full
  `ScreenshotsPresentation` mapping (permission gating over a finished catalog, analysis
  invisibility by construction, scan/running/failed/empty phases, limited notice, dashboard
  status copy), and `AppEnvironment` orchestration — prepare-without-analysis, similar-photos
  still gated on analysis, deterministic plan order, partial/unresolved sizes never zero,
  source-gated staleness (screenshot mutations stale only screenshot plans, and vice versa),
  cross-source review entry (a foreign plan or in-flight build is dropped, a same-source plan
  is kept), confirmation gating with zero service calls, execution context stamped with the
  screenshot dataset fingerprint, dataset-change invalidation (selection drift vs
  signature-only drift), catalog-gone reset, superseded builds discarded, stale-plan
  repreparation, and deletion success clearing the screenshot selection and catalog.
- The large-videos pipeline is tested the same way: `VideoDatasetTests` (media-type-only
  filter, id dedupe, order-independent membership-sensitive signature, size resolution,
  the documented sort policy proven deterministic across fixed-seed shuffles and stable at
  20k records), `VideosFlowTests` (prepare with analysis untouched, dataset-scoped selection,
  source-gated staleness and cross-source review entry, confirmation gating, noun-aware
  destructive copy, and the full measurement state machine — 32-batch sizing of a 70-video
  dataset, partial settle with `nil` never zero, cancel keeping measured bytes while late
  generation-stale batches are discarded, resume measuring only unknowns, settled-start
  no-op, permission/catalog gates, catalog-rebuild measurement drop, post-deletion reset),
  and `VideoPreviewTests` (seam invocation, local-only/current request options, the pure
  result mapping — cancellation, in-cloud, Photos-error translation, file-backed requirement —
  plus the preview model's loading/ready/unavailable state machine with a generation guard
  proven by out-of-order scripted responses, and player release on close).
- The duplicate-contacts pipeline is tested as pure logic + orchestration against fakes — no
  test ever reads or writes a real contact store: `ContactNormalizationTests` (strict phone
  keys ignoring formatting and leading plus, the national-format tolerance rule bounded to
  bare 10-digit and long international forms, trunk-zero/country variants never rewritten
  into false matches, unusable phones yielding nil or no keys, Indic-digit folding with
  fullwidth digits outside the policy, email trim/lowercase keeping plus-tags, name keys
  collapsing case but keeping diacritics, empty values never indexed);
  `ContactDuplicateDetectorTests` (the fixture set producing exactly its four expected
  groups with the evidence that actually matched, name pairs requiring the same
  organization, the cardinality cap skipping a mass-shared key rather than pairing it,
  transitive chains landing in one group, byte-identical groups across input orders, stable
  digest group ids, unrelated singles and fieldless records excluded);
  `ContactActionPlanTests` (merge union deduped on the same keys detection used,
  destination-wins conflicts recorded not dropped, empty-destination fill, snapshot items,
  deterministic plan identity, the confirmation boundary rejecting empty/invalid plans,
  staleness reasons in the documented session/dataset/selection/authorization order, and
  the full transition table incl. everything bypassing confirmation); the mutation service
  against a fake `ContactMutationBacking` (exact plan identifiers verified gone, merge
  decisions applied then sources removed, fresh authorization every run, fresh-deny and
  context-drift stopping before any store read, missing/drifted live contacts reported
  stale and never shrunk, store failure / silent non-application / partial removal reported
  as failure or `needsReview` — never success, verification failures incl. read failures
  never claiming success); and `ContactsFlowTests` (the `AppEnvironment` orchestration:
  fixture scan computing its four groups, cancellation staying cancelled, scan-start
  idempotence, permission gating, a fresh scan dropping selection and prepared plan, group
  open + snapshot preparation, merge precondition refusals, foreign-choice plans rebuilt
  never reused, confirmation gating with zero service calls, every outcome mapped to its
  state, and the universal reset on dismissal).
  **Current total: 432 tests in 43 suites** (zero compiler warnings other than the allowed
  `appintentsmetadataprocessor` notice).
- **On-device matrix** (real iPhone, real library): empty library, small, 10k+ library,
  screenshots, large videos, exact dupes, near-dupes, no dupes, limited Photos access, denied
  Photos/Contacts, cancellation mid-scan, deletion failure, empty selection, changed selection
  before confirm. Measured with signposts (`os_signpost`) rather than promised time estimates.
  **Status: NOT PERFORMED (no device connected) — §5.9 item 9.**
- Fakes for permission/storage providers allow driving every `AppFlowState` in tests.

## 11. Tradeoffs & decisions

| Decision | Why |
|---|---|
| One target, folder modules | Project size doesn't justify SPM package overhead; boundaries still enforced by convention + imports |
| XcodeGen (`project.yml`) | Project file is reproducible/merge-friendly; regenerated with `xcodegen generate` |
| Swift 6 language mode, strict concurrency | Catches data-race bugs in the scan pipeline at compile time — critical since scanning is concurrent |
| Swift Testing (`import Testing`) | Modern, fast, native to Xcode 16+; no third-party dependency |
| Two-phase exact fingerprint (length, then SHA-256) | Content is read only for byte-length collisions; streaming hash keeps memory flat and cost near metadata-only, while still catching every exact duplicate |
| Metadata candidate buckets (aspect + 10-min chains, cap 64) | Near-dupes only exist inside plausible candidates; comparisons scale as `n × bucketCap`, never `n²`, with no ML needed to form buckets |
| Complete-linkage grouping, not union-find | Groups are provable cliques (every pair within threshold); single-linkage's A≈B, B≈C chains would swallow unrelated photos and suggest deleting them |
| Dual descriptor: Vision feature print, CPU 16×16 grid fallback | Vision's inference stack is unavailable in this repo's simulator (espresso-context failure, §5.4); a per-run probe latches one backend so distances are always comparable, and the engine runs everywhere instead of crashing or faking results |
| Descriptors on ≤ 256 px thumbnails, orientation baked in | Full-resolution pixels are never decoded; normalization makes Vision and CPU grids see the same upright geometry |
| Permission status read before every fetch | An empty fetch alone would misreport every asset as deleted when the real answer is "Photos access is off"; the pre-check keeps `.permissionDenied` and `.assetNotFound` distinguishable |
| ObservableObject/`@Published` (not `@Observable`) | Already working under Swift 6; migration optional and low-value |
| No persistence framework yet | Cache will use a small SQLite/JSON file store; adding SwiftData would be speculative before scan exists |
| Selection is its own model, not fields on analysis results | Analysis says "these photos belong together", selection says "the user wants this one considered" — keeping them apart means neither can corrupt the other, and the future cleanup layer consumes a plain id set |
| Review screen state derived by one pure phase function | The dashboard status line, review header, and every placeholder render from the same tested mapping instead of hand-rolled conditionals drifting apart |
| Thumbnail store bounds by count *and* bytes | Entry count alone would let detail-sized images blow the budget; 96 entries / 48 MB keeps review scrolling flat in memory |

## 12. Out of scope (enforced)

No payments/subscriptions/paywalls, no email cleaning, no cache/junk clearing, no login, no cloud
sync, no iPad/Watch/Mac targets, no external AI APIs, no network calls of any kind.
`PrivacyInfo.xcprivacy` declares no tracking, no collected data, no required-reason APIs.

Deletion scope (this milestone): **photos, screenshots, and videos only**, one asset at a time
from an explicit review. Still out of scope: contacts/calendar deletion, delete-all, automatic
or background cleanup, cloud sync of any kind.

## 13. Similar photos review UI (implemented)

`Features/Photos/SimilarPhotos/` surfaces the analysis result and hosts the final deletion
review. Analysis and selection remain read-only: no `PHPhotoLibrary.performChanges`,
`PHAssetChangeRequest`, or `PHAssetCollectionChangeRequest` exists anywhere outside
`Core/Deletion`; the review UI's only direct writes are to the in-memory selection model, and
its destructive action funnels through the confirmation + mutation pipeline in §7.

### 13.1 One derived phase, no stored UI state

`SimilarPhotosPresentation.phase(permission:catalog:analysis:)` is the single pure mapping from
the three real state machines to `SimilarPhotosPhase` (`permissionRequired / permissionDenied /
buildingCatalog / analyzing / results / idle / emptyLibrary / cancelled / failed`). Views store
nothing but the open detail sheet. Ordering rules (documented at the function): permission gates
everything — a result from an earlier grant must not render after revocation; a running analysis
outranks everything; then a running catalog build; then analysis outcomes; then catalog
outcomes; then the resting states. A completed run over a zero-record catalog maps to
`emptyLibrary`, because "nothing was visible" must never read as "no duplicates". The dashboard
status line uses the same function, so entry-point copy and screen content cannot diverge.

### 13.2 Selection model, separate from analysis

`PhotoSelectionModel` (Core/Photos) answers only *"which photos has the user marked for
cleanup?"* — a `Set<String>` of asset ids, never conflated with `PhotoAnalysisResult` (which
carries no selection; the model carries no analysis). Defaults are deterministic: every group
member starts selected **except** any asset recommended as the keep in at least one group it
belongs to. Group actions do exactly their labels and only touch that group's members —
"select all except recommended" even deselects a recommendation the user had overridden, so
its outcome is reproducible; per-asset overrides always win afterwards; unknown ids are
ignored rather than silently entering the cleanup set. `GroupSelectionState`
(`none / some(selected:total:) / all`) is what each row renders. The default selection is
rebuilt only when a new run completes; it survives unrelated state changes.

### 13.3 Thumbnail pipeline

`ThumbnailStore` (actor, Core/Photos) is the single door to review thumbnails:

- **Bounded twice**: at most 96 entries *and* 48 MB resident (LRU evicted until both hold), so
  neither a long strip scroll nor repeated detail sheets can grow memory without limit.
- **Coalesced**: concurrent requests for one `pixelSize|assetID` key share a single in-flight
  load; strip (96 px) and detail (300 px) budgets are partitioned by key and can never serve
  each other's bitmap.
- **Negatively cached**: a failed thumbnail (deleted/iCloud-only/permission) is remembered so
  scrolling does not hammer PhotoKit; cancellation is never cached because it says nothing
  about the asset.
- The seam underneath is the existing `PhotoThumbnailLoading` / `PhotoKitThumbnailLoader`
  (local-only, no network, orientation baked, `.current` version). `PhotoThumbnailView` requests
  `pointSize × displayScale` pixels — never full-resolution — and renders explicit
  loading/ready/failed states, so a missing thumbnail degrades to a placeholder, not a blank
  cell. Cells use sibling (never nested) buttons: tap opens the detail sheet, the corner control
  toggles selection.

### 13.4 Orchestration & screens

`AppEnvironment.startSimilarityAnalysis()` runs catalog read → engine stream as one visible
run: permission is checked first (fail fast, factory untouched), a standalone catalog build is
cancelled so the library is never read twice at once, catalog progress is reported through
`analysisState`'s `preparing` stage (single continuous progress UI) with `catalogState` written
to `.completed` when the read finishes, and `analysisGeneration` invalidates cancelled runs so
no late event can overwrite newer state. `cancelSimilarityAnalysis()` bumps the generation and
lands `.cancelled` synchronously.

Screens (Dashboard → "Similar Photos"):

- Non-results phases: permission priming (Allow), denied (Open Settings), idle (Analyze Photo
  Library), building/analysing (honest stage copy + determinate bar only when the stage reports
  a real total + Cancel), cancelled, failed (message + Try Again), empty library.
- Results: lazy list of exact groups then similar groups. Group header carries the evidence
  numbers recorded by analysis (content byte length, or distance range vs threshold) — no
  re-derivation, no fabrication; horizontal **lazy** strip of per-asset cells; "KEEP" badge on
  the recommendation; group `Menu` with the three labelled actions; selection summary per row;
  bottom safe-area bar with "N photos selected · Nothing is deleted yet" and the Review link
  (disabled at zero).
- Detail sheet: 300 px thumbnail plus the metadata the analysis already recorded (creation
  date, resolution from pixel count, favorite/edited/burst), recommended badge, one
  select/keep toggle.
- `ReviewSelectionView` (the destructive review): renders the immutable plan — count,
  category summary, size wording chosen by completeness (exact / "at least" + unavailable
  count / "size unavailable", never a fabricated total), one thumbnail row per planned item
  with measured size or "Size unavailable", and honesty facts (Recently Deleted, only the
  listed items are touched, storage may not change right away). `Change Selection` pops back;
  the red `Delete N Photos` button only opens a system confirmation dialog — the dialog's
  confirm action is the sole path into `AppEnvironment.confirmDeletion()`. Building, deleting,
  stale ("Review Again"), success/partial, failure, and permission (Settings deep link)
  phases each render explicitly.
- Limited access shows a standing notice ("only the photos you selected for Netto are
  analyzed"); assets the engine could not analyze are surfaced as a count with reasons, never
  silently dropped.

### 13.5 Deletion presentation (derived, never stored)

`DeletionPresentation` (Features/Photos/SimilarPhotos) is the pure projection from
`DeletionState` to `DeletionReviewPhase` (`empty / building / ready(plan) / stale(reasons) /
deleting / succeeded / needsReview / failed / permissionRequired`) plus every fact the screen
displays: the destructive title names the exact action and count ("Delete 12 Photos"), size
wording is chosen by completeness, category summary parts always add up to the plan count,
stale copy calls out vanished assets, success copy names Recently Deleted, and outcome error
text is mapped to friendly messages — raw PhotoKit error strings never reach the UI. All of
it is unit-tested as pure functions.

### 13.6 Previews and honesty

Previews run on `PreviewData`: deterministic `CGImage`s synthesized from the asset id (a stable
hash — no personal photos, stable across launches), fixture groups/results including a
8-member group to exercise strip scrolling, and an `AppEnvironment` whose library factory
always throws, so tapping Analyze in a preview lands on the honest failure state. Byte totals
appear only where sizes were actually measured (§7); no screen claims space savings, and the
only destructive control is gated behind explicit confirmation.

## 14. Screenshots cleanup (implemented)

`Features/Screenshots/` is the SCREENSHOTS milestone: discover → select → review → confirm →
delete, built entirely on the existing pipeline. It adds no deletion path, no PhotoKit
enumeration, and no identification heuristic of its own.

### 14.1 Identification: subtype only, catalog only

A screenshot is whatever the catalog already recorded as one: `PhotoLibraryProvider` bridges
`PHAssetMediaSubtype.photoScreenshot` into `PhotoMediaSubtypes.screenshot` (the only bridge,
unchanged), `PhotoAssetRecord.isScreenshot` exposes it, and `ScreenshotDataset` (Core/Photos)
filters `CatalogScanResult.records` by that flag — in catalog order, deduplicated by set
semantics. There is no filename/OCR/Vision/EXIF/date/dimension guessing anywhere. The
dataset's structural fingerprint (`ScreenshotDataset.signature` — membership + count,
order-independent) is what screenshot plans are validated against.

### 14.2 One derived phase — permission + catalog, never analysis

`ScreenshotsPresentation.phase(permission:catalog:)` maps to `ScreenshotsPhase`
(`permissionRequired / permissionDenied / buildingCatalog / scanRequired / failed / empty /
results`). Analysis state is not a parameter: a running or failed similarity analysis changes
nothing on this screen, and screenshots never wait for it. Permission gates everything (a
finished result must not render after revocation). The dashboard's Screenshots section shows
`statusText` from the same mapping.

### 14.3 Dataset-bound selection

`ScreenshotSelectionModel` (Core/Photos) is `datasetIDs` + `selectedIDs`: mutations are
validated against the dataset it was last reconciled with (unknown ids are ignored),
`selectAll` covers exactly the dataset, and `reconcile(with:)` — run whenever the catalog
completes (`noteCatalogCompleted`) and whenever the screen appears
(`synchronizeScreenshotDataset`) — drops selections whose assets left the dataset instead of
carrying them into a plan. A missing dataset (catalog reset, deletion success) clears both sets.

### 14.4 Same pipeline, source-aware orchestration

`DeletionSelectionSource { similarPhotos, screenshots }` tags which selection a plan came from:

- `prepareDeletionPlan(from:)` guards catalog `.completed` for both sources, requires
  completed analysis only for `.similarPhotos`, and stamps the plan with the source's dataset
  fingerprint — the screenshot signature flows through the existing
  `DeletionPlanner.makePlan(analysisSignature:)` override (default `nil` keeps the
  similar-photos path byte-identical). Sizes still resolve through `AssetSizeProviding` for the
  reviewed subset only; exact/partial/unresolved wording is unchanged (`nil` never becomes 0).
- The prepare self-check and `confirmDeletion` build `PlanExecutionContext` from the *source's*
  selection and fingerprint (`currentDatasetSignature`), so a screenshot plan is invalidated by
  screenshot-selection/dataset drift — and unaffected by similar-photos changes, and vice
  versa: `mutateScreenshotSelection` / `mutateSelection` stale only same-source plans.
- `synchronizeScreenshotDataset` stales a prepared screenshot plan the moment the dataset
  diverges: a shrunk selection → `.selectionChanged`; an unchanged selection over a changed
  dataset → `.analysisChanged`.
- Everything downstream is shared unchanged: `DeletionPlanValidator` → confirmation dialog →
  `PhotoDeletionService` (sole mutation boundary; fresh authorization, existence
  revalidation, post-verification) → `resetLibraryStateAfterDeletion` (which now also clears
  the screenshot selection). Exactly one production mutation boundary, still
  `PhotoDeletionService` only.
- `ReviewSelectionView` takes a `source` (default `.similarPhotos` — the similar-photos link is
  untouched) and prepares / re-prepares from it; the empty-state copy names screenshots when
  the source is screenshots. On appear it calls `reviewDidAppear(from:)`: a live plan that
  already belongs to the source is kept (re-entering a review never re-resolves sizes), while
  any foreign state — a plan, stale record, failure, permission notice, or in-flight build from
  the *other* selection — is discarded through the universal `noSelection` reset (an in-flight
  build is invalidated first so it can never land) before this source prepares, so one
  source's review can never display or confirm the other source's plan.

### 14.5 Screen

Dashboard section (status from the same phase mapping) → `ScreenshotsView`: adaptive
`LazyVGrid` of bounded `PhotoThumbnailView` cells (100 pt, same `ThumbnailStore` as the review
strip — never full resolution), tap toggles selection with a checkmark and `.isSelected`
trait, a `Select All` / `Deselect All` toolbar action (dataset-scoped), and a bottom bar
("N of M screenshots selected · Nothing is deleted yet") with the Review link (disabled at
zero) into the shared review. Non-results phases reuse the shared `PhaseMessage`; limited
access shows a standing notice, and the empty state distinguishes "no screenshots" from "none
among the photos you granted Netto" under limited access.

### 14.6 Validation and its limits

Simulator: the DEBUG `-fixtureLibrary` launch argument (`AppEnvironment.live()`) swaps the
`PhotoLibraryReading` seam for `FixturePhotoLibrary` (thumbnails and sizes injected through
the existing seams), so the whole flow — scan, grid, selection, select-all, review, sizes,
confirmation, staleness — can be exercised where the Simulator's real Photos library contains
no screenshot-flagged assets. Fixture identifiers never exist in Photos, so a confirmed
deletion over them stops at the service's existence revalidation with **zero mutation** — the
same guard real runs rely on. Unit tests cover the dataset filter and signature, the
dataset-bound selection, every phase mapping, and the orchestration (prepare without
analysis, source-gated staleness, cross-source review entry, confirmation gating, execution
context fingerprints, dataset invalidation, superseded builds, post-deletion reset).

**Simulator validation: PERFORMED.** The fixture build was driven end-to-end in Simulator as a
single automated UI test — permission grant → Build Catalog → 10-cell grid → tap-select →
Select All / Deselect All with zero-selection gating → shared review (exact count, measurement
wording, "Size unavailable" row, recovery footers) → destructive confirmation dialog →
zero-mutation stale outcome ("Some planned photos are no longer available") → reprepare with
the selection preserved → dashboard status and catalog lines — with every state captured as a
test attachment. The UI-test harness existed only for this validation run and was removed
before commit, so the committed test surface remains the unit suite (the harness is described
in the validation report and can be re-added). What Simulator validation **cannot** show:
interaction with real screenshot-flagged assets or a real Photos mutation.
**Real-device validation (real screenshot flags, real deletion of real screenshots): NOT
PERFORMED — no device connected (§5.9 item 9).**

## 15. Large videos cleanup (implemented)

`Features/Videos/` is the LARGE VIDEOS milestone: discover → measure → sort largest-first →
select → preview/play → review → confirm → delete, built entirely on the existing pipeline. It
adds no deletion path, no PhotoKit enumeration, and no size heuristic of its own.

### 15.1 Identification: media type only, catalog only

A video is whatever the catalog already recorded as one: `PhotoLibraryProvider` bridges
`PHAsset.mediaType == .video` (the only bridge, unchanged), `PhotoAssetRecord.isVideo` exposes
it, and `VideoDataset` (Core/Photos) filters `CatalogScanResult.records` by that flag — catalog
order, set-semantics dedupe, no second enumeration. Size, duration, resolution, filename, and
date never decide whether something is a video. The dataset's structural fingerprint
(`VideoDataset.signature` — membership + count, order-independent) is what video plans are
validated against.

### 15.2 One derived phase — permission + catalog + measurement, never analysis

`VideosPresentation.phase(permission:catalog:resolution:)` maps to `VideosPhase`
(`permissionRequired / permissionDenied / buildingCatalog / scanRequired / failed / empty /
measuringVideos / results`). Analysis state is not a parameter: a running or failed similarity
analysis changes nothing on this screen. Size measurement is an *input*, not a phase of its own
(§15.4): `.idle` and a foreign-dataset measurement both render `measuringVideos(measured: 0)`
with honest "sizes not measured yet" copy — bytes are never mixed across catalogs — `.measuring`
shows live progress, and `.settled` resolves the sorted, size-embedded results. The dashboard's
Large Videos status (`statusText`) and the limited-access notice derive from the same mapping.

### 15.3 Dataset-bound selection (shared model)

`DatasetSelectionModel` (Core/Photos) is the generalized `datasetIDs` + `selectedIDs` model the
screenshots milestone introduced — `ScreenshotSelectionModel` is now a typealias of it, so both
features share one tested implementation. `mutateVideoSelection` validates against the dataset
the model was last reconciled with (unknown ids are ignored), `selectAll` covers exactly the
video dataset, and `synchronizeVideoDataset()` — run whenever the catalog completes
(`noteCatalogCompleted`) and whenever the screen appears — drops selections whose assets left
the dataset instead of carrying them into a plan. A missing dataset (catalog reset, deletion
success) clears both sets.

### 15.4 Size measurement: read-only, bounded, generation-guarded

Sorting by size *is* the feature, so the videos screen measures the whole video dataset — the
one place that does — strictly read-only and never as part of plan building (§4.2):

- `VideoSizeResolution` (Core/Photos) is the stored but explicit state:
  `idle / measuring(Measurement) / settled(Measurement)`. `Measurement` carries the dataset
  signature it belongs to, `bytes: [String: Int64]` (only values the provider actually
  resolved — `nil` never enters), `measuredCount`, `total`, and `isPartial`.
- `startVideoSizeResolution()` runs from `.idle` only — a settled state requires the explicit
  `resumeVideoSizeMeasurement()` — in sequential batches of `measurementBatchSize` (32) through
  the existing `AssetSizeProviding` seam: network off, local-URL stat-ing, no full-file reads.
  A `videoSizeGeneration` counter is bumped on every start/cancel, so late batches from a
  superseded run land as discarding no-ops, and cancel settles keeping what was already
  measured.
- Unknown stays unknown: a video whose bytes never resolved keeps `nil`, sorts after every
  measured video (measured before unknown — `nil` ≠ `0` — then bytes desc, newer creationDate
  first, then id asc; fully deterministic), renders "Size unavailable", and counts as *pending*
  in the copy, never as zero bytes.
- Measurement never touches selection, the deletion machine, or a prepared plan;
  `VideosView.onDisappear` cancels in-flight work.

### 15.5 Screen

Dashboard section (`statusText`) → `VideosView`: list rows (64 pt `PhotoThumbnailView` with a
play badge, duration, pixel dimensions, date, measured size or "Size unavailable", select
button) ordered largest-first once settled, plus a partial-measurement banner with "Measure
Sizes" when the provider couldn't resolve everything. Tapping a row opens a full-screen
preview cover: `VideoPreviewModel` owns the `AVPlayer`, created through the `VideoPreviewLoading`
seam — `PhotoKitVideoPreviewLoader` runs one `requestAVAsset(forVideo:)` with
`isNetworkAccessAllowed = false`, `version = .current`, `.highQualityFormat` (via
`PendingPhotoRequest`, so the continuation resumes exactly once) and accepts only a file-backed
`AVURLAsset`. Playback autoplays when ready; loading / ready / unavailable are distinct states
with PhotoKit-aware copy (`onlyInICloud` never silently downloads), and `close()` releases the
player when the cover dismisses.

### 15.6 Same pipeline, source-aware orchestration

`DeletionSelectionSource.videos` joins the existing source-aware path — everything §14.4
describes applies with the video dataset in place of the screenshot one:

- `prepareDeletionPlan(from:)` guards catalog `.completed` for videos with analysis at
  `.notStarted` (videos never wait for analysis), and stamps the video signature through the
  same `DeletionPlanner.makePlan(analysisSignature:)` override.
- `PlanExecutionContext`, validator staleness, `synchronizeVideoDataset` (selection drift →
  `.selectionChanged`, signature-only drift → `.analysisChanged`), and cross-source review
  entry behave exactly as §14.4: video mutations stale only video plans, and vice versa.
- Confirmation copy is noun-aware through `DeletionPresentation.noun(for:)`: a plan whose items
  are all videos says "Delete 2 Videos" / "Keep Videos", anything else says Photos — existing
  photo-plan copy is unchanged, proven by the pre-existing assertions.
- `resetLibraryStateAfterDeletion` clears the video selection and size resolution. Exactly one
  production mutation boundary, still `PhotoDeletionService` only — deleting videos reuses the
  same `PHAssetChangeRequest.deleteAssets` call on video `PHAsset`s: zero new mutation code,
  zero new enumeration.

### 15.7 Validation and its limits

Unit tests: `VideoDatasetTests` (filter/signature/resolve, the documented sort policy across
input orders with a fixed-seed shuffle, `nil` never sorts as zero, 20k-record determinism
bound), `VideosFlowTests` (prepare without analysis, cross-source gating and review entry,
dataset invalidation, confirmation gating, noun-aware destructive copy, and the measurement
state machine: 70-asset batching of 32/32/6, partial settle, cancel keeping measured bytes
with late batches discarded, resume measuring only the unknowns, settled no-op start,
permission/catalog gates, catalog-rebuild signature drop, post-deletion reset), and
`VideoPreviewTests` (loader seam, request options local-only/current, the pure result mapping —
cancellation/in-cloud/Photos-errors/file-backed requirement — preview state machine with a
generation guard proven by out-of-order scripted responses, and player release on close).

Simulator: the DEBUG `-fixtureLibrary` launch argument exposes `FixturePhotoLibrary`'s six
fixture videos (five with known sizes, `fixture-video-06-nosize` unknown) through the same
seams. A confirmed deletion over fixture ids stops at the service's existence revalidation with
**zero mutation**.

**Simulator validation: PERFORMED.** The fixture build was driven end-to-end in Simulator as a
single automated UI test — permission grant → Build Catalog → honest dashboard idle status →
swipe to the Large Videos section → the six fixture videos rendered largest-first (byte-level
ordering verified from the rendered rows: sizes strictly non-increasing, `fixture-video-06-nosize`
last with "Size unavailable") → partial-measurement banner ("5 of 6 sizes measured" +
Measure Sizes) → two rows selected ("2 of 6 videos selected") → Review ("Delete 2 Videos",
exact count, "2 items selected for deletion") → confirmation dialog ("Delete 2 videos?") →
confirm → zero-mutation stale outcome → "Review Again" reprepare with the selection preserved →
"Change Selection" back to the list with selection intact — with every state captured as a test
attachment (eight screenshots in the validation report). On iOS 27 the `.confirmationDialog`
renders as a tap-outside-dismiss popover showing only the destructive button: the platform omits
the `role: .cancel` "Keep Videos" label (the cancel role *replaces* the default dismiss action
and popovers dismiss by tap-outside), so the test asserts the destructive action and
scope-dismisses via the sheet rather than requiring the cancel label — `Keep Videos` remains in
the product code. The UI-test harness existed only for this validation run and was removed
before commit, so the committed test surface remains the unit suite (the harness is described
in the validation report and can be re-added). What Simulator validation **cannot** show:
real Photos video sizes, real HEVC playback, or a real Photos mutation.

**Real-device validation (real video sizes, real playback, real deletion of real videos): NOT
PERFORMED — no device connected (§5.9 item 9).**

## 16. Duplicate contacts cleanup (implemented)

`Features/Contacts/` is the DUPLICATE CONTACTS milestone: a purely local scan → group list →
group detail → review → confirm → merge/delete flow over the contacts store. It adds no
Photos code and no network of any kind; detection and every decision run on-device.

### 16.1 Identification: normalization with a documented policy

`ContactNormalization` (Core/Contacts) is pure, total, locale-independent, and identical
across runs:

- **Phones** are formatting-insensitive but never country-code-assuming. Separators are
  stripped and Unicode digits in the ASCII+Indic ranges fold to ASCII; a leading `+` is kept
  as the international marker. Every phone yields a **strict key** (`s:` + digits, leading
  `+` ignored), so `+91 98765 43210` and `919876543210` match as pure formatting. A bounded
  **national-tolerance key** (`n:`) is added only where it is well-defined: a bare exactly
  10-digit number yields its digits, and a `+`-number longer than 10 digits yields its last
  10 digits — which is what lets `(98765) 43210` pair with `+91 98765 43210` without ever
  claiming arbitrary numbers are equivalent. Trunk-zero and other country arrangements are
  deliberately not rewritten (they simply do not match); fewer than 4 digits is meaningless →
  `nil`.
- **Emails** must be exactly one address shape (one `@`, non-empty sides), then trimmed and
  lowercased. Plus-tags are never stripped — they change delivery identity.
- **Names / organization** are trimmed, whitespace-collapsed, lowercased; diacritics are
  **kept** (fuzzy accent folding could merge unrelated people, and every group here is only
  ever "likely"). Empty results are `nil` and never indexed as `""`.

### 16.2 Detection: bounded, disjoint, deterministic

`ContactDuplicateDetector` builds three exact-key indexes (phone → ids, email → ids,
name → org → ids) in one O(F) pass, then enumerates candidate pairs **only for keys shared
by 2…50 contacts** (`maxKeyCardinality`) — a mass-shared switchboard number or broadcast
address is skipped rather than paired, which is what keeps the detector from ever
degenerating into an all-pairs scan of the address book. Name pairs additionally require the
same organization, so two unrelated "John Smith"s at different companies never pair.
Union-find merges pairs into connected components: every contact lands in at most one group
(disjoint by construction), components of ≥2 become `ContactDuplicateGroup`s with sorted
members, sorted evidence `reasons` (each reason is a fact the detector observed — there is
deliberately no numeric confidence score), and a stable digest id over the sorted member set.
Sorted key order makes output byte-identical across runs and input orders.

### 16.3 One derived phase — permission + scan

`ContactsPresentation.phase(permission:scan:)` maps to `ContactsPhase`
(`permissionRequired / permissionDenied / scanRequired / scanning / failed / empty /
noDuplicates / results`). The dashboard's Duplicate Contacts status is `statusText` from the
same mapping — actual state only, with no invented counts and no "space freed" (contacts
have no storage-savings value and none is ever shown).

### 16.4 Dataset, scan, and a group-bound selection

`ContactScanState` is the stored machine (`notStarted / running / completed(dataset) /
cancelled / failed`); a scan generation counter makes late completions of superseded scans
no-ops, and cancellation stays cancelled. `ContactDataset` carries the lightweight records
plus the groups — no `CNContact` graph ever escapes the reader (`ContactStoreReader` fetches
only identifier, names, organization, phones, emails; unified cards surface once; records are
sorted by identifier so store enumeration order cannot leak into results).

`ContactGroupSelection` is bound to exactly one group: `begin` adopts its members as the
dataset, unknown identifiers are ignored (a selection can never point outside its group),
nothing is ever pre-selected, and no "master" contact is pre-chosen — a merge destination
must be an explicitly selected member. `synchronizeContactDataset` (screen appear, scan
complete, scan-state change) reconciles vanished members away and stales any prepared plan
whose selection or dataset fingerprint no longer matches.

### 16.5 Plan, merge policy, and the confirmation boundary

`ContactActionPlan` is an immutable snapshot: every grouping-relevant field of every involved
contact (with per-field digests), the exact removal order, and — for a merge — a fully
precomputed `ContactMergePlan`. Merge policy (`ContactMergePlanner`, pure):

- **Phones / emails**: union. The destination keeps everything it has; source values whose
  match key is not already present are appended with their original labels, deduplicated on
  the *same keys detection grouped on*, so a national-format variant the detector paired does
  not reappear as a second entry.
- **Names / organization**: the destination's non-empty value wins; a differing non-empty
  source value becomes a recorded `ContactMergeConflict` — shown in review, never silently
  dropped. An empty destination field is filled from the first source (sorted order) that has
  one.

Only `ConfirmedContactActionPlan` (produced by the structurally-checked `confirmed()` —
non-empty plan, internally valid merge) can reach the mutation service; raw identifiers from
UI code have no path to Contacts writes. `ContactActionState` mirrors the Photos
`DeletionState` design: every transition goes through `canTransition`, so mutating without
confirmation, executing a stale plan, or re-running a finished plan are unrepresentable, and
`noSelection` is the universal safe reset. Staleness reasons are checked in the documented
order — session, dataset, selection, authorization — plus live per-contact revalidation
(missing or field-drifted contacts stale the *whole* plan; it is never shrunk to fit).

### 16.6 Mutation path: revalidate, apply exactly, verify

`ContactMutationService` runs one final pre-mutation path with no way to mutate earlier:
structural guard → **fresh** authorization read (never a cached one) → authorization-must-
permit → pure context staleness (session/dataset/selection/authorization) → re-fetch every
planned contact (missing/drifted → stale, zero mutation) → apply exactly the plan's request →
post-mutation verification against the live store (deletions gone; merge destination present
with every appended value). `ContactStoreMutationBacking` is the only place in the app that
calls Contacts write APIs; merges are one atomic save request. Outcomes are distinct cases of
`ContactActionOutcome` — a partial result maps to `needsReview` (never `succeeded`), a
verification failure deliberately does not claim success, and permission/stale/rejected paths
report zero contact changes.

### 16.7 Screen

Dashboard section (status from the phase mapping) → `DuplicateContactsView`: phase dispatch
(permission priming copy, scan entry with the on-device promise, cancellable scan, empty /
no-duplicates states, `Rescan` once results exist) and the group list
("N groups of likely duplicates" header, per-group evidence, a footer stating Netto can't be
certain — nothing changes until you review and confirm, accessibility id per row for the
validation harness). `ContactGroupDetailView`: evidence section with per-reason labels,
member rows (tap toggles selection; a "Keep" star sets the merge destination and is disabled
until the member is selected), and a bottom bar ("N of M selected / Nothing is changed yet",
Merge enabled only with ≥2 selected + destination, prominent destructive Delete).
`ContactReviewView` builds the plan for exactly the choice it was opened with (a delete plan
can never show under a merge review): summary + exact count, "To be deleted"/"To be merged"
rows with roles, merge transparency sections (added values, kept as-is, "Different values
kept"), safety labels ("deleted contacts are removed immediately — this cannot be undone
from Netto"; "only the contacts listed above are touched"), `Change Selection` vs the
destructive action → confirmation dialog naming the exact count → executing copy → result
states (`Deleted`/`Merged`, `Some contacts remain`, failure, permission) with `Done`
returning through the universal reset.

### 16.8 Fixtures, validation, and its limits

Three DEBUG **simulator-only** launch arguments (`AppEnvironment.live()`): `-fixtureContacts`
swaps `ContactReading` for the synthetic `FixtureContactReader` (reads only — a mutation over
fixture identifiers stops at the service's existence revalidation with **zero mutation**);
`-seedFixtureContacts` seeds the simulator's real `CNContactStore` with the fixture set and
`-wipeFixtureContacts` removes it. Seeding is idempotent (created identifiers are tracked and
wiped before reseeding — repeated runs never accumulate) and only ever touches contacts it
created itself. The fixture set is personal-data-free: invented names, reserved `example.com`
emails, the reserved fictional `+1 555 010-xxxx` range, and deliberately contains four
likely-duplicate groups (shared phone in strict and national formats, shared email across
differently-spelled names, shared name + organization), two unrelated singles, and one record
with no grouping-relevant field (never seeded).

Unit tests (`ContactNormalizationTests`, `ContactDuplicateDetectorTests`,
`ContactActionPlanTests`, `ContactMutationServiceTests`, `ContactsFlowTests` — enumerated in
§10) cover the policy, the detector's bounds and determinism, the merge policy, the state
machine's transition table, the confirmation boundary, the service's revalidate → apply →
verify path against a fake backing, and the `AppEnvironment` orchestration. No test reads or
writes a real contact store.

**Simulator validation: PERFORMED.** The fixture build was driven end-to-end in Simulator as
a single automated UI test against the **real seeded contacts store** — dashboard section →
scan finding exactly **4 groups** in the live store → group detail (both members selected,
"2 of 2 selected") → delete review (exact count, "cannot be undone from Netto" copy) →
confirmation dialog ("Delete 2 contacts?" — on iOS 27 the `.confirmationDialog` renders as a
tap-outside-dismiss popover showing only the destructive action, the platform omitting the
`role: .cancel` label; "Go Back" remains in the product code) → confirmed delete verified by
a fresh scan finding exactly **3 groups** (the deleted pair gone from the live store) → next
group → selection + Keep destination → merge review ("1 contact will be merged into …",
Kept-as-is, and the "Different values kept" conflict transparency) → confirmation → fresh
scan finding exactly **2 groups** (the merged pair collapsed to one contact) → honest
dashboard after — twelve states captured as test attachments. The run surfaced and fixed a
real defect: `.accessibilityIdentifier("contactReviewList")` applied *after*
`.safeAreaInset` propagated outward and overwrote the inset action buttons' own identifiers
(the list was marked, but the destructive button reported the list's id) — the modifier now
sits on the `List` itself, before the inset. The UI-test harness existed only for this
validation run and was removed before commit, so the committed test surface remains the unit
suite (the harness is described here and can be re-added). What Simulator validation
**cannot** show: iCloud-synced contacts, linked-card behavior beyond the store's Simulator
unification, or changes arriving from other devices.

**Real-device validation (real iCloud contacts, a real device's store): NOT PERFORMED — no
device connected (§5.9 item 9).**
