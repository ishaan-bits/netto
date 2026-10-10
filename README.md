# Netto — iOS Storage Cleaner

Netto finds what is wasting space on your iPhone — duplicate and similar photos,
screenshots, large videos, and duplicate contacts — and lets you review every candidate
before anything is removed. Scanning, analysis, and deletion all run on the device: there
is no backend, no cloud processing, and no third-party analytics.

## Core features

- **Storage dashboard** — storage and permission status up front; the entry point for
  every cleanup section, with live scan progress.
- **Similar / duplicate photo detection** — exact duplicates and near-duplicate shots
  found through content fingerprints, perceptual hashes, and Vision features, presented
  as reviewable groups.
- **Potentially Blurry detection** — an on-device sharpness pass scores every scanned
  photo on a small local thumbnail and flags candidates for review in three tabs
  (All Flagged / Likely Blurry / Borderline, with live counts). Classification uses
  multiple image signals (Laplacian variance, Tenengrad energy, luminance gates) with
  thresholds calibrated against a labelled synthetic corpus; every candidate is a
  suggestion for human review — nothing is preselected and nothing is auto-deleted.
- **Screenshot cleanup** — every screenshot in the library, selectable in bulk.
- **Large video cleanup** — videos ordered largest-first with measured sizes, so the
  biggest wins are reviewed first.
- **Duplicate contact detection** — contacts that look like duplicates (shared phone,
  email, or name + organization), merged with kept fields or deleted.
- **Safe Review → Confirm → Delete flow** — every section follows the same shape:
  scan (read-only) → review candidates and adjust the selection → an explicit
  confirmation dialog stating the exact count → only then does anything happen.
  Photos deletions go through a single service that revalidates authorization and asset
  existence immediately before mutating, and removed photos land in Recently Deleted.
  Contact merges/deletions go through the app's only contacts writer; a plan must be
  confirmed, and stale plans are discarded instead of executed. Review screens never
  mutate anything. Details in [ARCHITECTURE.md](ARCHITECTURE.md).
- **On-device processing** — analysis never leaves the phone (see Privacy).

## Bonus features

Beyond the core cleanup loop:

- **Persistent scan results** — completed scan snapshots survive relaunch, so results
  are restored instead of rescanned from scratch.
- **Incremental result updates after deletion** — after a confirmed deletion, the
  existing scan results update in place for exactly the removed assets (selections
  preserved, snapshot refreshed).
- **Large photo preview** — a full photo details/preview screen, with a progressive
  local-rendition fallback so previews keep working when PhotoKit's fast
  representation request fails.
- **Swipe Keep/Delete review mode** — a Tinder-style swipe session over the similar-photo
  deck: swipe to keep or mark for cleanup, with Undo, a persistent bottom bar showing
  "N photos selected for cleanup" and a live **Review Cleanup** handoff into the existing
  review flow, and a completion screen on finishing the deck. All decisions persist in the
  shared selection model across navigation.
- **Deselect All / Reset to Recommended** — bulk selection controls, including restoring
  the engine's recommended selection exactly as presented.
- **Scan ETA** — a rolling-throughput estimate of remaining scan time shown alongside
  progress.
- **Home screen widget** — a WidgetKit extension renders the shared scan summary from
  the App Group; it reads only that summary and never links PhotoKit, Vision, or the
  deletion path.
- **Space-freed confirmation** — a completed deletion shows how much space the confirmed
  removal actually reclaimed, computed from measured sizes and verified removals.

## Architecture & technologies

- **SwiftUI** — the entire UI, driven by observable app/feature state.
- **Swift Concurrency** — `async`/`await` and actors throughout the scan and analysis
  pipeline; no GCD callback stacks.
- **PhotoKit** — library enumeration, metadata reads, thumbnails, and asset mutation.
- **Vision** — feature-print extraction for photo similarity (only for candidates, see
  Performance).
- **Contacts** — normalization, duplicate detection, merging, and deletion.
- **AVFoundation / AVKit** — video metadata, size measurement, and preview playback.
- Services sit behind protocols with in-memory fakes for testing; the project is
  generated with [xcodegen](https://github.com/yonaskolb/XcodeGen) from `project.yml`
  (the committed `Netto.xcodeproj` is kept in sync). Module-level design notes live in
  [ARCHITECTURE.md](ARCHITECTURE.md).

## Performance approach

Similar-photo detection is built to avoid comparing every photo against every other
photo:

- **Metadata-first candidate reduction** — photos are bucketed by cheap metadata (size,
  dimensions, dates) before any pixel work, so most of the library never reaches the
  expensive stages.
- **Bounded concurrency** — image decoding and feature extraction run under a
  concurrency cap, keeping memory and thermals in check on large libraries.
- **Perceptual prefiltering** — a perceptual hash prunes obviously-different pairs.
- **Vision only for candidates** — Vision feature prints are computed for the surviving
  candidate pairs, not the whole library.
- **No O(n²) full-library comparison** — the pipeline is designed so pair count grows
  with bucket density, not library size.

### Scan runtime (large libraries)

Scans of tens of thousands of assets additionally run under four load-shaping rules:

- **No expensive setup or bookkeeping on the main actor** — the PhotoKit reader for a
  catalog build or similarity scan is created in a detached task; catalog progress/ETA
  writes are coalesced to at most 4/second (plus immediate writes when the asset total
  is first known and on completion), never at a higher frequency than before; snapshot
  persistence runs off the main actor; deletion invalidation work is awaited off it.
- **One asset lookup, shared across stages** — a session-scoped LRU cache (512 entries)
  of resolved `PHAsset` references is shared by the loader's asset requests, so
  cataloging, fingerprinting, the sharpness pass, and previews each pay the PhotoKit
  fetch once per asset instead of once per stage; deletion invalidates exactly the
  removed IDs. Rendition bytes were already shared through the persistent
  `ThumbnailStore`.
- **Thermal-aware bounded concurrency** — every bounded pool (similarity workers,
  fingerprint thumbnails, sharpness workers, per-batch size measurement) scales its cap
  by the device thermal state (nominal ×1, fair ×0.75, serious ×0.5, critical ×0.25,
  floor 1), and critical pressure pauses batch workers until it eases. Each pool floors
  at 1, so progress continues at every level.
- **One heavy pass at a time** — a similarity run or sharpness pass owns the analysis
  pipeline: the other refuses to start, video-size measurement refuses to start (and an
  in-flight measurement yields, keeping its partial progress as a settled snapshot), and
  both the similarity and sharpness `isRunning` flags falling to false resume it.
  Catalog building and similarity analysis remain mutually exclusive as before.

## Privacy

- Photos and contacts are read, analyzed, and mutated **on-device only**.
- No backend, no cloud, no network API: the app has no network client, no analytics,
  and no third-party dependencies.
- `PrivacyInfo.xcprivacy` is included; Info.plist usage strings state exactly what is
  read and that data stays on the device.

## Requirements

- iOS 17.0+ (iPhone)
- Xcode 27 (iOS 27 SDK)
- Optional: [xcodegen](https://github.com/yonaskolb/XcodeGen) if you regenerate the
  project file

## Building & running

```sh
xcodegen generate   # optional — regenerates Netto.xcodeproj from project.yml (committed)
open Netto.xcodeproj
```

Select the `Netto` scheme and run (⌘R) on a simulator or device. Tests run with ⌘U or:

```sh
xcodebuild test -project Netto.xcodeproj -scheme Netto \
  -destination 'platform=iOS Simulator,name=<your simulator>'
```

### Debug launch arguments (DEBUG builds)

| Argument | Effect |
| --- | --- |
| `-fixtureLibrary` | Serves a synthetic six-video photo library instead of PhotoKit |
| `-fixtureContacts` | Serves synthetic contacts instead of the store (reads only) |
| `-seedFixtureContacts` | Seeds the fixture contacts into the simulator's store (idempotent) |
| `-wipeFixtureContacts` | Removes previously seeded fixture contacts |
| `-resetScanSnapshot` | Clears the persisted scan snapshot on launch |

These exist so the whole pipeline can be exercised in Simulator against deterministic data.

## Project structure

```
Netto/
  App/            Entry point, root flow state, environment composition, fixtures
  Core/           Services behind protocols: Permissions, Storage, Scanning, Photos
                  (analysis, selection, deletion), Contacts, Deletion (the only code
                  that mutates Photos or Contacts)
  Models/         Shared value types
  Features/       UI per section: Dashboard, Photos/SimilarPhotos (details, swipe
                  review, review), Blur, Screenshots, Videos, Contacts, Review
  UI/             Brand, DesignSystem, Theme — design tokens and shared components
  Resources/      PrivacyInfo.xcprivacy
NettoWidget/      WidgetKit extension (renders the App Group scan summary only)
NettoTests/       Unit tests for pure logic (Swift Testing)
NettoUITests/     XCUITest suites: dashboard layout QA, end-to-end scan validation
project.yml       xcodegen manifest
ARCHITECTURE.md   Design document: modules, state machines, safety model, validation notes
```

## Testing & verification

- **Unit suite** — 46 files, 692 Swift Testing cases across 68 suites covering the pure
  logic: contact normalization and matching, similarity grouping, plan construction and
  its confirmation boundary, state machines, the mutation service's
  revalidation/verification behavior, scan snapshot persistence, ETA estimation,
  selection persistence across navigation, the photo-preview fallback ladder, the blur
  pipeline (engine flow, instrumentation, review-tab presentation), the labelled
  blur-classification corpus (14 categories × 3 sizes × 2 delivery paths), and the
  widget summary. Tests use fakes and fixtures — they never mutate a real photo library
  or the contacts store.
- **Scan-runtime coverage (Phase B)** — 18 cases over the large-library hardening: the
  shared `PHAsset` reference cache (hit/miss accounting, LRU bounds, targeted
  invalidation, loader reuse across stage and mode requests, `.shared` as the process
  default), `ThumbnailStore` deletion invalidation (every size of a removed asset, no-op
  for unknown IDs), the thermal concurrency policy (width scaling per thermal state,
  the critical-pressure pause, cancellation through it) plus its effective width
  wiring in both engines, a repeat engine run fetching **zero** additional asset
  references, and the analysis-pipeline coordination (video measurement refusing to
  start or resume while a pass owns the pipeline, resuming when it finishes, an
  in-flight measurement yielding to a similarity start).
- **UI suites** — 5 XCUITest cases covering dashboard layout QA and an end-to-end scan
  validation run against fixture data in Simulator.
- **Recent verification** — full suites green on the Phase B worktree: the unit run
  reports "692 tests in 68 suites passed", plus 5/5 UI cases, and a clean
  `build-for-testing` with 0 errors and
  251 warnings, all inside the pre-existing UI-test-target baseline (the unit/app
  targets are warning-free). One case, `cancellationPropagatesOutOfTheLoader` in
  `PhotoKitThumbnailLoaderTests`, is cancelled when run inside the full suite but
  passes in isolation; this is a pre-existing Swift Testing suite-context quirk,
  reproduced unchanged on the Phase A commit, and is listed under Known limitations.
- **Benchmark, bounded honestly** — `BlurScanBenchmarkTests` self-seeds a Simulator
  library and A/B-measures the blur scan's delivery paths with stage-level
  instrumentation. Simulator PhotoKit timing is not representative of devices, so the
  benchmark is used only for relative comparisons, never as a device-performance claim.
  Post-Phase-B single run over 1 000 seeded photos (before = pre-M7 delivery path,
  after = production path): `after wall=9.54s request=6.236s ticks=38 width=4` versus
  the pre-Phase-B baseline for the same production path `wall=9.80s request=6.120s
  ticks=40 width=4` — i.e. no regression, within simulator run-to-run noise; Phase B's
  wins are structural (fewer main-actor writes, fewer PhotoKit asset fetches,
  thermal-scaled caps), which this metric does not isolate. Within a run, both engine
  paths now share the process asset-reference cache, so request-time deltas between
  before/after are not a pure A/B.
- **On-device profiling procedure** (required before any device-performance claim):
  install on an iPhone 17 Pro with a large real library; in Instruments, profile a
  full scan with Time Profiler + Animation Hitches + CPU (thermal column) + Allocations;
  record scan wall time from the dashboard, main-thread CPU % during the scan, hitch
  count during the scan, sustained CPU %, thermal state, and peak memory. Repeat on the
  pre-Phase-B build for the comparison; the matrix has not been run yet (see Known
  limitations).

## Known limitations

- **Simulator PhotoKit libraries may not contain real image backing files**, so
  previews, fingerprints, sizes, and playback measured in Simulator are not
  representative. **Real-device testing is required for final validation**; the
  real-device validation matrix has not been performed. Photos imported via
  `simctl addmedia` can additionally surface as cloud-only placeholders.
- Simulated validation against the fixture data above covers flow and logic, but not
  real-world library scale or hardware performance.
- **Blur verdicts are calibrated on a procedural synthetic corpus, not on labelled
  real-device photographs** — accuracy on real libraries is unverified until a device
  corpus re-validates the thresholds. Known behaviours: very smooth content (blank
  skies, gradients) can read as likely blurry by every measured signal; whole-frame
  intentional defocus is indistinguishable from accidental blur at thumbnail scale; the
   result is in-memory for the session only. The classifier never acts on its own —
   candidates are for explicit human review.
- **Scan-runtime tradeoffs (Phase B)** — the asset-reference LRU is session-scoped
  (512 entries): it bounds memory and lookup cost but does not persist across launches.
  Thermal scaling reacts to the reported thermal state, not to per-request latency; at
  critical pressure the scan deliberately slows instead of failing. Video-size
  measurement yields to a similarity or sharpness pass and resumes only when a pass's
  `isRunning` flag flips to false (an explicit resume also works); if the app is
  backgrounded or killed while yielded, measurement restarts from persisted partial
  results on the next session.
- **One skipped test** — `cancellationPropagatesOutOfTheLoader` in
  `PhotoKitThumbnailLoaderTests` reports as cancelled when executed in the full-suite
  context but passes when run alone; the behaviour predates Phase B (reproduced on the
  Phase A commit) and is a Swift Testing suite-context quirk, not a suppressed failure.
- **The Phase B benchmark comparison is not isolated** — within one
  `BlurScanBenchmarkTests` run, the before and after engine paths now share the process
  asset-reference cache, so per-path request times are no longer independent; the
  simulator numbers above only rule out regressions, they do not measure the cache's
  benefit. The device procedure under Testing & verification is the intended
  measurement.

## Credits / AI development note

AI tools were used during development where appropriate (implementation, review, and
test authoring). Behavior claimed in this README is backed by the test suites and
Simulator verification described above.
