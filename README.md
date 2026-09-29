# Netto

An on-device iOS cleanup app: find duplicate and similar photos, screenshots, large videos,
and duplicate contacts — review what you're about to remove, then confirm. Everything runs on
the iPhone; nothing is uploaded anywhere.

## What it cleans up

| Section | What it finds | What you can do |
| --- | --- | --- |
| Similar Photos | Exact duplicates and near-duplicate shots (content fingerprints + Vision features) | Select and delete the photos you don't want |
| Screenshots | All screenshots in your library | Select and delete them |
| Large Videos | Videos ordered largest-first, with measured sizes | Preview, select, and delete them |
| Duplicate Contacts | Entries that look like duplicates (shared phone, email, or name + organization) | Merge kept fields into one contact, or delete |

The Dashboard shows storage and permission status up front and is the entry point for every
section.

## How a cleanup runs

Every section follows the same shape:

1. **Scan** — read-only analysis. Nothing is changed.
2. **Review** — see the candidates, change your selection, inspect one item up close.
3. **Clean** — an explicit confirmation dialog states the exact count. Only after you confirm
   does anything happen.

Safety properties the code enforces (documented in detail in [ARCHITECTURE.md](ARCHITECTURE.md)):

- Photos deletions go through a single service that revalidates authorization and asset
  existence immediately before mutating, and maps results honestly (deleted / not-found /
  permission-denied are never conflated). Photos land in Recently Deleted, so deletions are
  recoverable in the Photos app.
- Contact merges and deletions go through a single backing type — the only place in the app
  that writes to the contacts store. A plan must be confirmed before it can execute; a plan
  whose selection has gone stale is discarded instead of executed. Contacts removal is
  immediate and is **not** recoverable from within Netto, which is why the confirmation states
  that explicitly.
- Review screens never mutate anything; the confirmation boundary is the only path to a write.

## Privacy

- Photos and contacts are read and analyzed on-device. The app has no network client, no
  analytics, and no third-party dependencies.
- `PrivacyInfo.xcprivacy` is included; the Info.plist usage strings state exactly what is read
  and that data stays on the device.

## Requirements

- iOS 17.0+ (iPhone)
- Xcode with the iOS 27 SDK (the project is generated with [xcodegen](https://github.com/yonaskolb/XcodeGen))

## Building

```sh
xcodegen generate   # regenerates Netto.xcodeproj from project.yml (already committed)
open Netto.xcodeproj
```

Select the `Netto` scheme and run on a device or simulator.

## Testing

```sh
xcodebuild test -project Netto.xcodeproj -scheme Netto \
  -destination 'platform=iOS Simulator,name=<your simulator>'
```

The unit suite (`NettoTests/`, Swift Testing) covers the pure logic: normalization and
duplicate matching, plan construction and its confirmation boundary, the state machines, the
mutation service's revalidation/verification behavior, and every phase mapping. Tests use
fakes and fixtures — they never mutate a real photo library or the contacts store.

### Debug launch arguments (DEBUG builds)

| Argument | Effect |
| --- | --- |
| `-fixtureLibrary` | Serves a synthetic six-video photo library instead of PhotoKit |
| `-fixtureContacts` | Serves synthetic contacts instead of the store (reads only) |
| `-seedFixtureContacts` | Seeds the fixture contacts into the simulator's store (idempotent) |
| `-wipeFixtureContacts` | Removes previously seeded fixture contacts |

These exist so the whole pipeline can be exercised in Simulator against deterministic data.

## Project layout

```
Netto/
  App/            Entry point, root flow state, environment composition, fixtures
  Core/           Services behind protocols: Permissions, Storage, Scanning, Photos,
                  Contacts, Deletion (the only code that mutates Photos or Contacts)
  Models/         Shared value types
  Features/       UI per section: Dashboard, Photos/SimilarPhotos, Screenshots, Videos,
                  Contacts, Review
  UI/Theme/       Design tokens
  Resources/      PrivacyInfo.xcprivacy
NettoTests/       Unit tests for pure logic (Swift Testing)
project.yml       xcodegen manifest
ARCHITECTURE.md   Design document: modules, state machines, safety model, validation notes
```

## Status and limitations

- Implemented and unit-tested: similar photos, screenshots, large videos, duplicate contacts,
  and the shared deletion/confirmation flows.
- Simulator validation was performed for each feature against the fixture data described
  above. What Simulator validation cannot show — real photo sizes, real HEVC playback, real
  store mutations — requires a real device; the real-device validation matrix has not been
  performed.
