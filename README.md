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
                  review, review), Screenshots, Videos, Contacts, Review
  UI/             Brand, DesignSystem, Theme — design tokens and shared components
  Resources/      PrivacyInfo.xcprivacy
NettoTests/       Unit tests for pure logic (Swift Testing)
NettoUITests/     XCUITest suites: dashboard layout QA, end-to-end scan validation
project.yml       xcodegen manifest
ARCHITECTURE.md   Design document: modules, state machines, safety model, validation notes
```

## Testing & verification

- **Unit suite** — 36 files, ~580 Swift Testing cases covering the pure logic: contact
  normalization and matching, similarity grouping, plan construction and its
  confirmation boundary, state machines, the mutation service's
  revalidation/verification behavior, scan snapshot persistence, ETA estimation,
  selection persistence across navigation, and the photo-preview fallback ladder.
  Tests use fakes and fixtures — they never mutate a real photo library or the
  contacts store.
- **UI suites** — XCUITest coverage for dashboard layout QA and an end-to-end scan
  validation run against fixture data in Simulator.
- **Recent verification** — focused suites green (Swipe Review + selection: 30/30;
  photo preview: 41/41) and a clean `build-for-testing` with zero warnings in the app
  and unit-test targets (only pre-existing warnings in the UI-test targets).

## Known limitations

- **Simulator PhotoKit libraries may not contain real image backing files**, so
  previews, fingerprints, sizes, and playback measured in Simulator are not
  representative. **Real-device testing is required for final validation**; the
  real-device validation matrix has not been performed.
- Simulated validation against the fixture data above covers flow and logic, but not
  real-world library scale or hardware performance.

## Credits / AI development note

AI tools were used during development where appropriate (implementation, review, and
test authoring). Behavior claimed in this README is backed by the test suites and
Simulator verification described above.
