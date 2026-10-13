# Netto — iOS Storage Cleaner

Netto finds what is wasting space on your iPhone — duplicate and similar photos,
screenshots, large videos, and duplicate contacts — and lets you review every candidate
before anything is removed. Scanning, analysis, and deletion all run on the device: there
is no backend, no cloud processing, and no third-party analytics.

## Core features

- **Storage dashboard** — storage and permission status up front, then four primary
  cleanup sections (**Image Cleanup**, **Video Cleanup**, **Duplicate Contacts**,
  **Swipe Cleanup**), each with live scan progress and a status line derived from real
  app state. Image Cleanup groups the four photo destinations (duplicates, similar
  shots, blurry, old screenshots) behind one row; Old Screenshots lists screenshots at
  least **90 days** old (oldest first, unknown dates never counted as old). Video
  Cleanup splits the library into **Recorded**, **Downloaded**, and a reported
  **other/unknown** count that is never guessed into a source, with the biggest measured
  videos reviewed first.
- **Premium scan animation** — the dashboard's scan core is a native SwiftUI visual: a
  luminous green centre, concentric rings, and a slow sweep that runs **only** while a
  scan is actually in flight and settles the moment it is paused, cancelled, failed, or
  finished. It shows the stage's **real** fraction (or no ring at all when a stage
  reports no denominator), respects Reduce Motion, and never invents a percentage, stage,
  or completion.
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
  existence immediately before mutating; what the Photos change block actually submitted
  is the record of what was removed (PhotoKit keeps Recently Deleted assets fetchable, so
  a post-delete re-fetch cannot be trusted for counting), and removed photos land in
  Recently Deleted.
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
- **Swipe Keep/Delete review mode** — a Tinder-style swipe session over the photo
  library (similarity deck or the whole library from the dashboard card): swipe to keep
  or mark for cleanup, with Undo and a persistent bottom bar showing the session's live
  Delete-mark count and a **Review Cleanup** handoff. Shuffle re-orders only the photos
  you have not reviewed yet (no repeats within a pass; **Start New Pass** on the
  completion screen resets position and keeps every decision), the session itself —
  deck order, position, undo history, and the decision log — persists through
  navigation and relaunch (asset identifiers and review state only, never pixels), and
  the handoff opens an **editable** list of exactly this session's Delete marks (all
  checked by default, individual toggles plus Select All / Deselect All) before entering
  the existing confirmation → deletion pipeline.
- **Deselect All / Reset to Recommended** — bulk selection controls, including restoring
  the engine's recommended selection exactly as presented.
- **Scan ETA** — a rolling-throughput estimate of remaining scan time shown alongside
  progress.
- **Home screen widget** — a WidgetKit extension (small and medium) renders the shared
  widget summary from the App Group: the last confirmed cleanup's estimated bytes
  (labelled as an estimate) with its day, or "Ready to clean" with the last scan's day,
  or a designed empty state that prompts back into the app — every state real content,
  never a fabricated number and never a blank box. It re-reads whatever the app last
  wrote (the app writes on launch, scan completion, and confirmed cleanup, then asks
  WidgetKit for a reload), refreshes on a one-hour timeline budget with staleness
  handled by labelling rather than polling, and tapping anywhere opens the app at the
  dashboard through the `netto://` deep link. It reads only that shared summary —
  never PhotoKit, Vision, or the deletion path.
- **Space-freed summary** — after a confirmed deletion whose committed Photos change
  is verified, a dedicated summary screen shows the count of confirmed removed assets
  and the estimated bytes freed (computed from the plan's measured sizes, always
  labeled as estimates; an unmeasurable item never fabricates a figure), discloses any
  partial removals honestly, and is gated so it can never appear before the deletion
  finishes, without explicit confirmation, or for a zero-removal outcome.

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
  pipeline: the other refuses to start, and both the similarity and sharpness `isRunning`
  flags falling to false drive the M10 queue. Video-size measurement is deliberately *not*
  part of this exclusivity: it is I/O-bound over its own bounded, thermal-aware batches
  and runs alongside passes (it used to refuse to start — and every pass start used to
  cancel an in-flight run — which starved the Video Cleanup screen forever; see M16).
  Catalog building and similarity analysis remain mutually exclusive as before.

### Interrupted-run resilience (Phase C)

Long scans are built to survive backgrounding, locking, expiration, and process death —
without ever claiming the system will keep scanning in the background:

- **Explicit lifecycle** — the app distinguishes active / inactive / background.
  Going inactive insurance-flushes the checkpoint batcher (one bounded write). Going
  background arms a short OS background task *only while work is actually in flight*;
  when the system reclaims it, every running pass pauses synchronously at the last
  deterministic moment: live progress is tagged, the checkpoint is written, a running
  video measurement checkpoints its landed bytes, tasks are cancelled, and ETA anchors
  drop — then the task is released. Returning to the foreground refreshes permissions
  and storage, and auto-resumes only work interrupted *in this session*; a checkpoint
  restored at launch waits for an explicit Resume tap.
- **One bounded, versioned checkpoint file** — a single `checkpoint.json` (schema v1)
  holds at most one pass's resume state: run sequence (monotonic, adopted across
  launches so a stale write can never overwrite newer state), kind (catalog / similarity
  / blur / video sizes), stage, processed evidence (reconcilable entries only — never
  pixels, full-resolution content, or contact data), blur calibration, and timestamps.
  Evidence flushes in bounded batches (256 entries or 3 s) off the main actor, with one
  synchronous write at the pause transition; corrupt, obsolete-schema, or
  unrecognizable-stage files degrade to "no checkpoint", never to a crash. A paused
  heavy pass always owns the file slot; video-size checkpoints can only fill an empty
  slot, never clobber heavier resume information.
- **Idempotent resume** — every entry carries the asset id *and its exact modification
  date*: deleted or re-exported assets are measured again (an asset the interrupted run
  never judged is new work — nothing is marked analyzed without evidence), and a changed
  asset's cached evidence is discarded. A fresh start (or an explicit cancel) discards
  interrupted state so a straggler flush can never resurrect it; completion releases the
  file kind-aware. Similarity resumes rebuild their own catalog as Stage A; a blur or
  video resume with no fresh catalog chains a catalog rebuild first (that rebuild owns
  no checkpoint of its own) and then resumes with the carried payload.
- **Honest surfaces** — `.paused` is a distinct state from running / completed /
  cancelled / failed: the dashboard shows the saved stage and percentage with a Resume
  action and **no live countdown** (a paused ETA would be a lie), and the ETA estimator
  resets on pause so foregrounding re-anchors from real post-resume samples.
- **PhotoKit request lifetimes** — pending photo requests resolve exactly once
  (success, failure, cancellation, timeout, or late callback — whichever lands first;
  the rest become no-ops), timeouts and cancellations are distinguished from unavailable
  content, and a resumed pass issues fresh requests rather than reusing a timed-out one.

### Swipe Review & editable cleanup (Phase D)

The swipe session and its cleanup handoff are durable, scoped, and reuse the existing
deletion safety net rather than adding a second one:

- **Shuffle without losing place** — the Shuffle button (top of the review, and the
  only way order changes mid-pass) re-orders *only the unreviewed tail* of the deck:
  the reviewed prefix, the cursor, the undo stack, and every Keep/Delete decision are
  untouched, so a reviewed photo can never re-enter the pass. With fewer than two
  photos remaining the button is visibly disabled instead of pretending to act. Within
  one pass the cursor only moves forward through unique items, so photos never repeat;
  **Start New Pass** (completion screen) resets cursor and undo, keeps the decision log,
  and rebuilds a library deck from the current catalog (group sessions keep their deck).
- **Session persistence** — after every decision, undo, shuffle, and new pass, the
  session is saved through a `SwipeReviewSessionStore` seam (asset identifiers and
  review state only — no pixels, no thumbnails) as one small JSON document
  (`<Application Support>/SwipeReview/session.json`, schema-versioned, atomic writes,
  bursts coalesced off the main actor so the file only ever holds a state that actually
  existed). Restoring on the next appear reconciles the deck against the catalog *as it
  is now*: photos deleted since the session left drop out (with their history and
  decisions), the cursor keeps its position relative to the photos that remain, a
  deck that vanished entirely reads as no session, and corrupt or future-schema files
  degrade to "fresh session", never to a crash. The decision log is then replayed onto
  the shared selection, so Keep/Delete marks survive a relaunch.
- **Editable Review Cleanup** — the persistent bar and the completion screen hand off
  to a candidate list scoped to *this session's* Delete marks, in deck order: Kept
  photos and photos never reviewed are excluded even if the shared selection carries
  them, assets deleted from the catalog since the swipe are filtered out before any
  plan can see them, and everything eligible is checked by default. Individual toggles
  plus Select All / Deselect All update the live "N of M selected" count; explicit
  choices are keyed by asset and survive navigating back into the list, while a photo
  marked Delete since the last visit joins already selected. The screen selects only —
  it never deletes and never builds a plan.
- **The existing pipeline, unchanged** — the handoff enters the same
  `ReviewSelectionView` → confirm → `PhotoDeleting` flow every other feature uses, as a
  new `.swipeReview` source whose plan is built from the *checked ∩ still-selected*
  set and validated (asset existence, sizes, authorization, session, dataset
  fingerprint) immediately before execution — so unchecking a photo, unmarking it in
  the grid, or deleting it behind the app's back stale or refuse the plan rather than
  deleting something the user no longer sees selected. Partial failures, permission
  losses, and vanished assets report honestly through the same outcome states as
  everywhere else. Swipe Review itself still never deletes anything.

### Space Freed Summary verification (Phase E)

The summary screen existed but never appeared after a real cleanup: PhotoKit keeps a
trashed asset (one moved to Recently Deleted) fetchable by its local identifier until it
purges it ~30 days later, so the service's post-delete re-fetch reported every planned
asset as "still present". A successful deletion therefore degraded into a phantom
partial failure with zero confirmed removals — nothing was pruned from the scan
results, and the summary (gated on at least one confirmed removal) was suppressed.

- **The change block is the submission of record** — the Photos change block fetches
  exactly the plan's identifiers and hands them to `deleteAssets`; which identifiers
  that in-block fetch actually returned is returned to the service as the committed
  submission. An identifier counts as confirmed removed exactly when it entered the
  committed change; one the block could not see (an external change mid-flight) is
  reported as still present, never as removed.
- **The post-commit library read is corroboration, not counting** — the service still
  re-reads the library after the commit and refuses to claim success if that read
  fails, but its per-asset results are deliberately ignored: they cannot distinguish
  "moved to Recently Deleted" from "still active", and counting them is exactly what
  suppressed the summary.
- **Unchanged safety path** — the pre-mutation gates (non-empty plan, fresh
  authorization, selection/session/dataset/authorization staleness, live existence
  revalidation) are untouched; the summary is still built only after the outcome is
  applied, the results are pruned, and storage is refreshed; an empty in-block fetch
  commits nothing and reports zero removals (no summary, honest review state); the
  system delete-confirmation dialog Photos presents per deletion remains the user's
  second, independent confirmation.

### Device responsiveness & widget reliability (M8)

Reported on a physical iPhone 17 Pro: the home-screen widget showed only the blank
skeleton; the Videos screen sat at "0 of 7,061" for seconds and crawled; a full-library
blur analysis over ~34 000 photos streamed "Preparing…" for a long time; the whole app
was choppy. The video stall and blur choppiness were confirmed in code; the widget
failure's *mechanism* still needs device logs to confirm (see Known limitations).

- **Widget: a bounded watchdog guarantees branded content** — the extension's only
  rendering path was `await store.load()` then deliver; a hung read (broken extension
  process, App Group container miss on a debug install) never calls WidgetKit's
  completion, and WidgetKit's contract for that is the blank skeleton. The load now
  races a 2-second watchdog (`NettoWidgetProvider.loadEntry`): whichever settles first
  delivers exactly once, and a timeout delivers the designed empty-state entry — branded
  pixels instead of silence. Proven by tests: a store whose `load` never returns still
  produces a branded entry within the watchdog budget; a responsive store still wins the
  race.
- **Widget: the store pipeline is diagnosable from the device** —
  `FileWidgetSummaryStore` and the provider log every load/save outcome to
  `Logger(subsystem: "com.ishaanparimal.netto", category: "widget")` (container
  missing, file absent, corrupt file, delivered status, watchdog timeout) — category
  and status names only, never photo data. Capture steps are under Known limitations.
- **Video sizes: progress advances through failures** — the size provider returned a
  bare size map, so a batch of iCloud-only or unreadable videos contributed nothing:
  the counter sat at "0 of N" for seconds (one full 32-asset pass) and then stalled for
  the whole library if nothing was downloadable. The provider now resolves every
  requested identifier to `.measured` or `.unavailable` (`VideoSizeOutcome`), the
  measurement loop counts attempts, and the UI surfaces unavailable sizes as their own
  figure ("2 unavailable", with a "download in iCloud Photos" hint in the
  partial-results banner) — never folded into measured, never zero.
- **Video sizes: the first increment lands in about a second** — the sequential batch
  size dropped from 32 to 8 (two waves at the provider's default width of 4), so the
  counter moves within about a second of starting instead of after a full 32-asset pass.
- **Videos screen: the signature and the sorted list are cached** —
  `VideoDataset.signature` (O(videos log videos), a large joined string) and the
  resolved largest-first record list used to recompute on every Videos/dashboard render
  and once per measurement tick; on a 7k-video library that was main-actor work per
  selection toggle. The environment now caches both (`videoDatasetSignature`,
  `settledVideoRecords`), invalidated exactly when the catalog or measurement changes.
- **Blur analysis: PhotoKit callbacks leave the main queue** — the analysis thumbnail
  handler (classification + orientation re-render) ran on the main queue PhotoKit
  delivers to; at 34k photos that constant traffic starved the UI even though the heavy
  measurement ran elsewhere. The handler now hops to a utility queue before resolving.
  The preview path is unchanged on purpose (its frames exist to be shown).
- **Blur analysis: per-asset XPC status reads and cache misses stop paying** — every
  asset-reference cache miss re-read `PHPhotoLibrary.authorizationStatus` (an XPC round
  trip to the Photos daemon); a positive-only memo removes that per-asset cost, and an
  empty fetch still re-checks live status so a revocation is never misreported as "this
  photo was deleted". The shared `PHAsset` reference cache grew from 512 to 2 048
  entries — the working set of a full-library pass at phone scale (a 34k run missed
  entirely at 512, paying a `PHAsset.fetchAssets` round trip per photo).
- **Checkpoint flushes and the blur seed leave the caller** — the O(n log n) identifier
  sorts over every accumulated evidence entry used to run inside `setProgress` (the
  main actor, every ~3 s) and engine-worker threads; they now run in the detached flush
  task, leaving only an O(1) copy-on-write state handoff on the caller. The
  tap-to-start blur seed walk (every catalog record against every saved verdict)
  similarly moved off the main actor.

### Large Videos: instant inventory (M9)

On an iCloud-only iPhone library the Large Videos screen remained stuck at "0 of N"
after M8's outcome accounting. Root cause, confirmed in code: the size provider
measured every asset through `requestContentEditingInput` and awaited its callback in
an unbounded continuation — for a cloud-only video (network access disabled) PhotoKit
can delay that callback indefinitely, so the first batch never completed and the screen
never left "0 of N". Even when the callback arrived, it was slow enough that a
7 000-video cloud-only pass crawled.

- **Plain videos measure through `requestAVAsset`** — with network access disabled this
  API answers promptly for both a local video (an `AVURLAsset` whose file URL is stat-ed
  for exact bytes) and a cloud-only one (nil — the honest unavailable outcome, at
  callback speed). Live Photos and photos keep the content-editing-input measurement
  (still + paired video, per `AssetResourceScope`), now also deadline-bounded — which
  incidentally bounds the same hang risk on the photo-sizing path used at deletion
  review.
- **Every PhotoKit callback races a hard deadline** — a first-answer-wins box
  (`OneShotValue` + `PhotoKitAssetSizeProvider.withDeadline`, 5 s default) means a
  pathological callback yields `.unavailable` instead of hanging the pass; a late answer
  is dropped without a double resume. The whole library always finishes.
- **Enumerate first; measure second** — the Videos screen renders the full inventory as
  soon as the catalog is complete: every video listed immediately, sizes filling in as
  they measure, a summary of the real counts (`N videos total` / `Y sizes unavailable —
  stored in iCloud or unavailable locally` / `Z videos sorted by known size`), and a
  compact progress panel with cancel while measurement runs. An idle screen offers
  "Measure Sizes" instead of blocking. Unknown sizes stay after every measured one —
  never ranked, never zero — and rows say so.
- **Cached inventory, coalesced updates** — `AppEnvironment.videoRecordsForDisplay`
  (replacing the settled-only cache) serves the resolved, largest-first list and
  rebuilds only when the catalog or measurement changes, never per render; measurement
  publishes its state at most ~4×/second (the settled state always publishes), so a
  fast pass over thousands of cloud-only videos cannot storm the main actor.

### Analysis coordination & widget delivery (M10)

Two failures from a fresh iPhone 17 Pro recording: the Similar Photos screen's
"Analyze Photo Library" button did nothing while a sharpness pass was running (2 731 /
33 949 photos in), and the home-screen widget stayed a blank skeleton despite M8's
watchdog.

- **One coordinator, never a silent drop (Part A)** — `AppEnvironment` now owns a
  one-slot queue (`pendingAnalysisRequest`). Requesting the pass that is not currently
  running no longer returns silently: the request is queued, the requesting screen
  (Similar Photos, Potentially Blurry, and the dashboard's Similar Photos card) shows
  an explicit "queued" state with two actions — **Start Now (cancels the running pass)**
  and **Remove from Queue** — and the queued pass starts itself automatically when the
  running pass reaches a terminal state (completion, failure, or cancel) or when a
  deletion leaves `.deleting`. Same-request taps are no-ops; a different request
  replaces the slot (latest intent wins). A paused pass still owns the pipeline — the
  queue waits for its own resume-and-finish rather than racing a foreground resume.
  Checkpoint safety: every terminal write now releases its checkpoint slot *before*
  the state flip that may drive the queue, so the queued pass's `beginCheckpointRun`
  always finds the slot free; the generation guards make a superseded run's late write
  both state- and queue-safe (the queue is spent exactly once).
- **Blur responsiveness (Part A)** — the sharpness engine already runs a bounded,
  thermal-scaled worker pool (`ScanConcurrencyPolicy`, M4B) with 250 ms progress
  coalescing; the device symptom was the silent-ignore above, not an unbounded scan, so
  the engine is unchanged. PhotoKit callbacks stay off the main queue (M8) and the
  coordinator keeps exactly one heavy pass on the cores at a time.
- **Widget delivery (Part B)** — the data path was re-traced end to end: matching App
  Group entitlements on both targets, a correctly embedded extension, a writer on
  scan/cleanup/launch-repair, and a provider that renders designed branded content for
  *every* load outcome (missing, corrupt, unsupported schema, hung read via the
  watchdog) within a 2 s bound. A *persistent blank skeleton* therefore means the
  extension never delivered any entry at all — which the repo alone cannot prove or
  fix further; the remaining suspects (extension process crash at launch, system-side
  budget/redaction, a stale pre-M8 widget configuration) need the device's Console
  logs (capture steps under Known limitations). What could be hardened in code, was:
  the store's file I/O now runs on a detached utility task and the provider's
  load/watchdog racers are both `Task.detached`, so neither can inherit — and be
  starved by — whatever actor context WidgetKit invokes the provider on. That actor
  coupling was the one remaining way the M8 design could still end with no completion
  and a blank skeleton.
- **Fallbacks pinned by tests** — the empty-state copy ("No estimate yet" / "Open
  Netto and scan your library to see cleanup estimates.") is asserted across all four
  unusable-store outcomes, and a source-tree test asserts both entitlement files
  declare the store's exact App Group, so provisioning drift fails the suite instead
  of the home screen.

### Dashboard IA: four primary sections (M11, trimmed in M12)

The dashboard previously showed a flat grid of cards, one per destination. It is now
organised around the things a person actually does — Image Cleanup, Video Cleanup,
Duplicate Contacts, Swipe Cleanup — with the photo destinations grouped behind the
Image Cleanup row and the biggest measured videos surfaced inside Video Cleanup. (A
fifth "Large Files" section shipped briefly in M11 and was removed in M12; its honest
size-measurement behaviour now lives entirely in Video Cleanup, which shares the same
measurement pipeline.)

- **Every status is derived, never stored** — `DashboardCleanupPresentation.status(for:)`
  is the single pure mapping from app state (permission, catalog, analysis, blur,
  contacts, video measurement) to the one-line status each section shows. A section
  reports a real count, real progress, or the real blocking reason — never a
  placeholder, and never a confident `0` while something harder (permission, scan,
  failure) stands in the way (`worstStatus` ranks blockers above counts).
- **Old Screenshots, defined transparently** — the 90-day threshold lives in pure
  presentation code (`OldScreenshotsPresentation`), computed against the completed
  catalog; a screenshot with no known creation date is reported as an honest unknown
  count rather than being guessed old or young, and eligible items are ordered oldest
  first. The threshold is stated in the UI, not just the code.
- **Video sources are classified, not guessed** — `VideoSourceClassification` maps each
  video's PhotoKit source evidence to Recorded, Downloaded, or other/unknown; the
  other/unknown bucket is surfaced as its own count rather than folded into a guess.
  Video Cleanup orders the biggest measured videos first and never ranks an unknown
  size as zero (measurement state is shared with the video inventory, keyed to the
  catalog generation so a rebuild invalidates it).
- **No analysis starts on open** — the sections and hubs read existing state only;
  requesting a pass is still an explicit user action through the M10 coordinator, whose
  one-slot queue, checkpoint safety, and deletion-confirmation contract are unchanged.

### Premium scan animation (M12)

The dashboard's scan card grew a proper scan core in native SwiftUI — a luminous green
centre, concentric rings, and a slow sweep — replacing the previous pulsing icon tile.
The animation is a pure function of real state, so it cannot out-say the app.

- **`ScanCorePresentation` decides, `ScanCoreView` draws** — `phase(for:)` is a single
  pure, tested mapping from `DashboardPresentation.ScanStatus` to a small phase set
  (resting / running / paused / finished / cancelled / failed). The view renders that
  phase and nothing more, so the animation and the copy can never disagree about what
  the app is doing.
- **Real progress only** — the sweep turns **only** while a run is in flight; a paused,
  terminal, or resting core is still. The progress ring shows the stage's **real**
  fraction and is simply absent when a stage reports no denominator (catalog
  enumeration, measuring) — never a fabricated ring at a made-up position.
- **Every scan state is covered** — idle/ready, starting + catalog enumeration,
  active analysis with real progress, finishing, paused/queued, cancellation, failure,
  and successful completion all map to a distinct, honest visual.
- **Reduce Motion and lifecycle respected** — under Reduce Motion the sweep never spins
  and the rings never pulse (a static, legible mark instead). The repeating animation is
  gated on the scene being active and is stopped on disappear, so nothing outlives the
  card. No timers, no per-asset animation tasks, and nothing is published into app-wide
  state — only local `@State` driving the existing `NettoMotion` curves.
- **Nothing was measured on a physical iPhone** — the animation's frame rate, battery,
  and thermal behaviour were not profiled on device; validation is Simulator and code
  inspection only.

### Unified Image Cleanup session (M13)

The duplicate/similar and sharpness analyses now run as **one user-visible session over
one photo catalog**: a single Analyze tap starts both pipelines **concurrently**, each
with its own honest progress, results, and lifecycle. Before M13 the two were separate
runs that queued behind each other, so a scan only ever advanced one of them.

- **One tap, two pipelines, one catalog** — `startImageAnalysis()` is the single entry
  every Analyze button calls. With both pipelines idle it claims both checkpoint channels,
  enumerates the library **once**, then launches the similarity and sharpness passes
  **concurrently** over the same snapshot. With exactly one pipeline still running (the
  other failed or was cancelled mid-session) it starts only the idle one through that
  pipeline's own entry point, which queues it behind the running pass rather than racing
  it. Repeated taps are idempotent for the active session.
- **The shared read outlives a single cancel** — the one `PHAsset.fetchAssets`
  enumeration lives in `catalogTask`, not either pipeline's task, so cancelling one
  pipeline's *work* leaves the read standing for the other. The read is only abandoned
  when the whole session is (pause, deletion, a superseding session). Similarity may reach
  `.completed` and become reviewable while the sharpness pass is still running — completion,
  failure, or cancellation of one never touches the other.
- **Bounded shared worker budget** — both engines report how many heavy passes are active
  through `AnalysisConcurrencyBudget`, and `ScanConcurrencyPolicy.sharedWidth` splits the
  thermal-scaled worker width between them. One pass keeps its full width; two concurrent
  passes each get half (floor of 1), so the pair never does more concurrent work than one
  pass used to alone — no doubled thermal load on a phone.
- **Per-kind checkpoints** — each pipeline owns its own checkpoint file
  (`checkpoint-similarity.json`, `checkpoint-blur.json`), writer, and accumulator
  (`CheckpointChannels`), so an interruption to one is resumable without the other, and a
  relaunch restores *every* interrupted pass. Resume re-runs the two together when both
  were interrupted, or routes a single one to the pass that owns it.
- **Deletion preserves unrelated in-flight work** — deleting assets while a pass is
  running no longer cancels it. The confirmed removals are recorded and reconciled out of
  the result the moment it lands (`removingAssets`), so work for every *surviving* asset
  is kept and the pass never reports a just-deleted asset as removed. Only a standalone
  catalog read is still abandoned (it would complete with pre-mutation records). The
  dashboard's cancel stops **both** pipelines — cancelling only similarity would orphan
  the sharpness pass, and the next Analyze would queue behind that orphan.
- **Performance is honest, not claimed** — because the primary scan now includes the
  sharpness pass, it fully settles noticeably longer on a large library than the old
  similarity-only scan (the scan card reaches "Finished" once similarity completes, while
  the sharpness row keeps reporting real counted progress). No wall-clock figure is
  claimed for a physical device; the Simulator end-to-end validation is the only timing
  evidence, and it is not representative of device performance.

### Video Cleanup: measurement that actually runs (M16)

On a real device the Video Cleanup screen showed "0 bytes measured · 7,113 size
unavailable" for every video, with no progress panel ever appearing — while several
gigabytes sat on the phone. Root cause, proven in code and in a captured recording:
video-size measurement was *refused* while any analysis pass ran and *cancelled* by every
pass start (`prepareSimilarityRun`/`prepareBlurRun`), and only a visible screen's
observer restarted it — so a chain of passes (fingerprinting → blur, M10's queue) kept
it parked at `.idle` forever, and the summary line still claimed a measurement that
never ran.

- **Measurement coexists with analysis passes** — the two analysis-state guards in
  `resumeVideoSizeMeasurement` and the cancels in both prepare functions are gone:
  sizing is I/O-bound over its own bounded, thermal-aware batches, so it runs
  alongside a pass instead of being starved by one. Cancelled only by the user
  (Rescan, the progress panel), backgrounding, dataset change, and deletion.
- **An ordered probe ladder replaces the single-path provider** —
  `PhotoKitAssetSizeProvider` now asks five probes in order, first answer wins, every
  step deadline-bounded, network access disabled everywhere (nothing is ever downloaded
  to measure): `requestAVAsset(.current)` → stat; `requestAVAsset(.original)` → stat
  (the edited-video answer); `PHAssetResource.dataSize` (iOS 27+ Photos metadata —
  synchronous and sandbox-independent); `requestContentEditingInput` → stat —
  *skipped when a probe already proved the content is remote*, because that callback has
  been observed to stall for such assets (the deadline is a backstop, not the strategy);
  and `requestImageDataAndOrientation` → byte count for photos with no file URL at all.
  A measured zero is never a size; a genuinely empty file ends `.unavailable`. Probes are
  injectable (`Probes`), so the ladder and the batching engine are tested with scripted
  answers and no PhotoKit. Validated end-to-end on the iOS 27 simulator's seeded library
  (3/3 videos and a photo measured, including through the Photos-metadata path).
- **Attempted vs untouched, honestly named** — `Measurement` now carries the ids the run
  *attempted* and could not measure (`unavailableIDs`, seeded across a resumed run,
  never persisted — a relaunch retries them). The screen only says "Size unavailable —
  not stored locally" (warning) for those; a row nothing has tried yet says "Size not
  measured yet". The unknowns' section says "Sizes not measured yet" until a failure is
  proven, then "iCloud / size unavailable"; the summary line says "sizes not measured
  yet" instead of the old fabricated "0 bytes measured · N size unavailable"; and the
  dashboard status line splits "unavailable" from still-"pending" sizes.
- **The yield tests inverted** — the three tests that *encoded* the starvation (measurement
  refused while a pass runs; started only after a terminal flip; cancelled by a pass
  start) now assert the opposite: measurement runs alongside a pass, settles while a
  pass is still running, and keeps filling when similarity starts.

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
| `-resetScanSnapshot` | Clears the persisted scan snapshot and checkpoint file on launch |

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
logos/            Approved Netto brand assets (SVG masters, app-icon sources, brand
                  README with palette/typography/export rules; Plus Jakarta Sans is
                  used as vector outlines under SIL OFL 1.1, license included)
project.yml       xcodegen manifest
ARCHITECTURE.md   Design document: modules, state machines, safety model, validation notes
```

## Brand

The two-leaf Netto identity lives in `logos/` (hand-rebuilt SVG masters; the brand
README there documents the palette, gradient axes, typography and export rules) and is
wired into the app as:

- **App icon** — `AppIcon.png` is a full-bleed 1024 render of the glass app-icon master,
  drawn from the exact SVG geometry (base gradient, glow, vignette, sheen, leaf shadows,
  brand-leaf gradients), flattened RGB with no alpha per the brand README's iOS export
  rules. Dark and tinted reference renders ship alongside the SVG sources in
  `logos/Netto-Brand-Assets/`.
- **In-app mark** — `NettoLogo` and the variant imagesets (light/dark/green symbol,
  horizontal/stacked/tagline lockups, wordmark) are the SVG masters, so every surface
  renders the same approved vectors at any size.
- **Vector symbol + motion** — `NettoBrandSymbol` draws the two leaves as live geometry
  (exact path data and gradient axes) with the brand's motion: a staggered leaf reveal on
  appear and a slow idle drift, both collapsing to simple fades under Reduce Motion. The
  dashboard header and the design-system gallery use it; the gallery shows every style,
  lockup, and the motion controls.

## Testing & verification

- **Unit suite** — 49 files, 838 Swift Testing cases across 83 suites covering the pure
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
- **Interrupted-run coverage (Phase C)** — 46 cases over checkpoint persistence and
  resume: the checkpoint file (round-trips including exact dates, first-launch, corrupt
  and future-schema discard, kind-aware single-slot writes with run-sequence ordering
  and adoption), the evidence accumulator (carry restores payload and progress, foreign
  run sequences can never be smuggled in, blur calibration stamped only during a blur
  run, batched and forced flushes), paused presentation (scan card, status copy, Resume
  CTA, saved percentage, no live countdown), lifecycle (background expiration →
  synchronous pause + checkpoint + released task, foreground auto-resume completing
  without duplicates, relaunch restoring paused without auto-starting, unusable
  checkpoints dropped, no background task when idle), engine-level checkpoint capture
  and reuse for the similarity pass (seed reuse needs strictly fewer requests,
  modification-date changes invalidate the evidence, deleted assets reconcile away,
  a fresh start supersedes and cancel never resurrects) and the sharpness pass (seed
  reuse at zero requests, calibration mismatch re-measures everything, candidates
  without scores re-measure while other verdicts are reused, the chained catalog
  rebuild path resumes with the carried payload), video sizes (a restored checkpoint
  seeds the next measurement and wins over the provider, expiration mid-measurement
  persists exactly what landed and foregrounding measures only the remainder, a paused
  heavy pass's checkpoint keeps the file slot), and ETA reset semantics (reset drops
  every sample; a countdown reappears only from fresh post-reset observations).
- **Swipe Review & cleanup coverage (Phase D)** — 23 cases over the session and its
  cleanup handoff: shuffle (tail-only reorder with the prefix, decisions, and undo
  intact; a full pass after a shuffle visiting every photo exactly once; the disabled
  one-or-none-remaining boundary; seeded, deterministic order), Start New Pass (cursor
  and undo reset, every decision kept, undo restoring a *prior pass's* decision),
  persistence (exact round-trip of deck order, cursor, undo stack, and decision log
  through the store seam; a corrupt cursor clamped and a detached undo stack dropped;
  empty snapshots ignored; the decision log replayed onto a rebuilt selection
  idempotently; snapshot Codable round-trip; the file store round-tripping through its
  write drain and dropping future-schema and corrupt files), cleanup candidates (only
  this session's Delete marks, still selected and still in the catalog, in deck order;
  a 1 000-photo deck scoping 500 candidates without touching the deck), selection
  state (default-checked with exact counts, individual/bulk toggles, choices surviving
  re-entry while a new mark joins selected), and the deletion pipeline as the
  `.swipeReview` source (confirmation executing exactly the checked subset,
  unchecking or unmarking after the plan was built stale-ing it before any mutation,
  another source's plan left alone by cleanup toggles, partial failures reported as
  `needsReview`, and a catalog-missing candidate never entering the plan).
- **Space-freed summary coverage (Phase E)** — the summary presentation tests (accurate
  confirmed counts and measured bytes with the "Estimated space freed" label, partial
  success counting only confirmed removals with its disclosure, failed/cancelled
  deletions never showing success, zero-confirmed removals suppressed by the builder
  itself, unknown sizes shown as a bare count with no fabricated figure, duplicate plan
  entries never double-counted, dismissal returning to the dashboard without touching
  results, recreation never repeating a deletion or the success event, scan-snapshot
  persistence intact alongside the summary, a second cleanup presenting a fresh summary
  over the dismissed one) plus the device-shaped pipeline: a `DeviceShapedBacking` that
  keeps deleted assets fetchable by identifier (PhotoKit's Recently Deleted semantics)
  driven through the real `PhotoDeletionService` proves a committed change verifies as
  full success — the submission-of-record accounting, not the ambiguous re-fetch,
  decides what was removed — with an in-block gap still reported as a partial honestly.
- **Home-screen widget coverage** — 8 cases over the extension's two untested layers:
  the provider's context-free mapping (the placeholder is a real `.scanReady` status
  with no figure and no digit in its headline; an entry carries exactly its summary and
  date; the timeline asks for one refresh an hour later and carries exactly its entry;
  a summary saved through the real file store arrives as the labelled-estimate entry;
  a missing file arrives as the designed empty state) and rendered-pixel proof that
  `NettoWidgetEntryView` is never a blank box: `ImageRenderer` snapshots of the real
  view in both families across the empty, scan-ready, last-cleanup, and stale variants
  all draw real ink, and the pixels change with the model rather than rendering
  something static.
- **UI suites** — 5 XCUITest cases covering dashboard layout QA and an end-to-end scan
  validation run against fixture data in Simulator.
- **Recent verification (M13)** — after unifying the Image Cleanup session, the full unit
  suite reported **843 tests in 83 suites, 0 failures** (the pre-existing
  `cancellationPropagatesOutOfTheLoader` suite-context skip is unchanged), plus one clean
  app build with **no warnings**. Five new unit cases pin the M13 contracts: one Analyze
  tap starts both pipelines concurrently, cancelling one leaves the other running, the
  concurrency budget is idempotent per kind, the shared width halves across two passes,
  and a relaunch restores both interrupted pipelines independently. Real-library UI
  validation (Simulator, ~42k photos) was run against the M12 baseline for a non-regression
  comparison: the cancel-and-restart flow and the full scan reaching a terminal state both
  pass, with two findings folded in — the dashboard's cancel now stops both pipelines
  (previously it orphaned the sharpness pass), and the full-scan case accepts the sharpness
  row's honest in-progress message once the similarity side has completed (the sharpness
  pass is now part of the primary scan and outlasts it). The scan card reaches "Finished"
  when similarity completes (~143 s on the 42k Simulator library, vs ~86 s for the old
  similarity-only scan); the sharpness pass then continues for several more minutes — a real
  cost of running both, reported here rather than dressed up as a device claim.

- **Recent verification (M12)** — after removing Large Files and adding the scan-core
  animation, a full-suite run reported **838 tests in 83 suites, 0 failures** (the
  pre-existing `cancellationPropagatesOutOfTheLoader` suite-context skip is unchanged),
  plus one clean build of the app with no warnings and all 5 UI cases passing (dashboard
  layout QA and the end-to-end scan reaching a terminal state). Large Files' section,
  view, and its 3 phase/sorting unit cases were removed (Video Cleanup keeps the shared
  size-measurement pipeline untouched); 10 new unit cases (`ScanCorePresentationTests`)
  pin the scan core's state→visual mapping — resting/paused/terminal cores never sweep,
  an indeterminate stage draws no progress ring, a measured fraction is passed through
  (and clamped) exactly, and only an in-flight run ever moves.
- **Recent verification (M11)** — after the dashboard-IA restructuring, a full-suite
  run reported **836 tests: 835 passed, 0 failed, 1 skipped** (the skip is the
  pre-existing `cancellationPropagatesOutOfTheLoader` suite-context quirk, unchanged),
  plus one clean build of the app with no warnings. The 26 new unit cases
  (`CleanupSectionsTests`) pin the section contract (all present, in order), the
  worst-blocker ranking, the Old Screenshots rule (90-day default, oldest-first,
  unknown-date never old, custom threshold), and the video-source classification (never
  a guess); the 5 UI cases were updated to the new section identifiers and assert the
  sections in fixed vertical order with no overlap, plus the end-to-end scan reaching
  the Image Cleanup destinations.
- **Recent verification (M10)** — after the coordination + widget work, a full-suite
  run reported **"805 tests in 79 suites passed"** (14 new: the queue's start-once /
  cancel / failure / replace / paused / deletion contracts in both directions, the
  queued phase mappings, the designed widget fallback copy across every unusable store
  outcome, and the two-target App Group assertion), plus one clean build of the app,
  widget extension, and test target with no warnings. The two admission tests that
  previously pinned the silent-refusal rule were rewritten to pin the queue rule
  (same no-clobber guarantees, plus the acknowledged queue).
- **Recent verification (M9)** — focused video suites after the large-videos fix:
  `VideoDatasetTests`, `VideosFlowTests`, `VideoCheckpointFlowTests`, and the new
  `VideoSizeDeadlineTests` — **80 tests across 4 suites green** (11 new: inventory
  summary honesty, mixed local/cloud counts and ordering, the inventory rendering
  during measurement with cache invalidation, and the PhotoKit callback-deadline race),
  plus one clean build of the app, widget extension, and test target. The last
  *full-suite* run (M8 work) reported "780 tests in 78 suites passed"; the M9 cases
  were verified focused, not in a new full-suite run. One case,
  `cancellationPropagatesOutOfTheLoader` in
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
- **Home-screen widget on a physical device** — the widget's data pipeline (the app
  writing the shared summary to the App Group container), timeline policy, and pixel
  rendering (every state, both families) are verified in Simulator and unit tests; the
  widget has not been installed and visually confirmed on a physical iPhone from this
  build. **The root cause of a device-only blank widget is not confirmed** — the code
  paths are unit-covered, and the M8 watchdog guarantees branded empty-state content
  even when the store read hangs, but confirming *why* a device renders the skeleton
  requires the device's own logs: attach the iPhone, open Console.app (or run
  `xcrun devicectl list devices` and then `log stream` against the device) with the
  predicate `subsystem == "com.ishaanparimal.netto"`, filter on the `widget` category,
  and look for `shared container unavailable` (missing App Group entitlement on the
  debug install), `summary absent` (the app never wrote), `summary rejected` (corrupt
  or incompatible file), or `store read timed out` (the watchdog fired). Debug-build
  widget extensions on device occasionally render blank until the widget is removed
  and re-added (a WidgetKit/dyld-install quirk outside the app's control) — a
  Release/App Store build is the meaningful device check.
- **Blur verdicts are calibrated on a procedural synthetic corpus, not on labelled
  real-device photographs** — accuracy on real libraries is unverified until a device
  corpus re-validates the thresholds. Known behaviours: very smooth content (blank
  skies, gradients) can read as likely blurry by every measured signal; whole-frame
  intentional defocus is indistinguishable from accidental blur at thumbnail scale; the
   result is in-memory for the session only. The classifier never acts on its own —
   candidates are for explicit human review.
- **Scan-runtime tradeoffs (Phase B)** — the asset-reference LRU is session-scoped
  (2 048 entries since M8): it bounds memory and lookup cost but does not persist
  across launches.
  Thermal scaling reacts to the reported thermal state, not to per-request latency; at
  critical pressure the scan deliberately slows instead of failing. Video-size
  measurement yields to a similarity or sharpness pass and resumes only when a pass's
  `isRunning` flag flips to false (an explicit resume also works); if the app is
  backgrounded or killed while yielded, measurement restarts from persisted partial
  results on the next session.
- **Interrupted-run checkpointing (Phase C)** — checkpoints store resume *evidence*, not
  finished results (a completed scan persists through the separate scan snapshot). A
  resumed catalog restarts enumeration from the first asset — per-asset offsets are not
  persisted — so it re-reads the library, though it never duplicates records and never
  re-issues analysis work that already has surviving evidence. Checkpoint entries
  compare exact modification dates through JSON-encoded `Date`s; the worst case for a
  precision round-trip mismatch is one entry's evidence being dropped, which recomputes
  that asset rather than corrupting anything. Video-size batches are cancellable as a
  whole; since M9 each asset's PhotoKit callback is additionally bounded by a hard
  deadline (whose answer is an honest "unavailable"). None of this scans
  in the background: the OS background task exists only to *save* a resumable checkpoint
  before expiration, never to keep analyzing.
- **Swipe Review session persistence (Phase D)** — the session restores when the Swipe
  Review screen next appears (deck order, position, undo, and decisions), not on the
  dashboard itself, which shows only aggregate counts. A **Start New Pass** over a
  similarity-group session keeps that session's original deck (only library decks
  rebuild from the current catalog, picking up newly scanned photos); group membership
  changes are reconciled on restore (deleted photos leave the deck), but newly formed
  groups are not injected mid-session. The session file holds one session — entering
  Swipe Review over a different deck replaces it.
- **Deletion verification semantics (Phase E)** — what the Photos change block submitted
  is the record of what moved to Recently Deleted; if the Photos framework committed a
  change yet silently dropped a submitted asset (without failing the commit or the
  follow-up library read), that asset would be counted as removed. Photos' documented
  failure modes are a thrown error or a completion that never fires (an OS-level hang
  that leaves the app in its deleting state), neither of which this accounting can
  mask. A system delete-confirmation dialog also appears per Photos deletion, after
  Netto's own confirmation. Real-device validation of the end-to-end deletion flow
  (including this summary) has not been performed — see the device-matrix limitation
  above.
- **Large Videos sizing (Phase M9)** — the `requestAVAsset`-based local/cloud
  classification and the 5-second callback deadline are verified by unit tests over the
  race primitives and the flow, not against a real iCloud-only library on a physical
  device; the actual PhotoKit callback latencies on such a library have not been
  measured. Cloud-only videos are reported with their sizes unavailable (never zero,
  never downloaded); the only way to rank them largest-first is to download them in
  Photos first and re-measure — Netto never initiates that download.
- **Home-screen widget can still show a blank skeleton on device (M10, unresolved
  without logs)** — the repo-side data path is complete and every store outcome renders
  designed branded content within a 2 s watchdog bound (unit-tested, and both racers are
  now detached from any caller actor). A *persistent* skeleton therefore means the
  extension never delivered an entry at all, which is one of: the extension process
  crashing at launch, a system-side refresh budget/redaction, or a stale widget
  configuration placed before M8. Distinguishing them needs the device's Console:
  `log stream --predicate 'subsystem == "com.ishaanparimal.netto"'` (category `widget`
  shows summary load/save/deliver/timeout lines; a `NettoWidget` crash report in
  Settings → Privacy & Security → Analytics → Crash Logs would confirm the first
  suspect). Removing and re-adding the widget from the gallery after a fresh install is
  also worth doing to rule out the stale-configuration suspect.
- **Scan-core animation performance is unmeasured on a physical device (M12)** — the
  animation's frame rate, battery draw, and thermal behaviour were not profiled on a real
  iPhone; validation is Simulator runs and code inspection only. The core is a single
  48 px view whose repeating motion is gated on an in-flight run, an active scene, and
  Reduce Motion being off (it is removed from the hierarchy the moment a scan pauses,
  finishes, fails, is cancelled, or the app backgrounds), with no timers and no per-asset
  tasks — a reasoned basis for expecting it to be cheap, but not a measurement. Real-device
  validation of the scan animation, like the rest of the device matrix, has not been
  performed.
- **The unified session's real-device cost is unmeasured (M13)** — the primary scan now
  runs the similarity and sharpness pipelines concurrently, so it fully settles noticeably
  longer on a large library than the old similarity-only scan (the scan card reaches
  "Finished" when similarity completes, while the sharpness row keeps reporting real
  counted progress for several more minutes on a ~42k Simulator library). The shared worker
  budget keeps the *combined* concurrency at or below what one pass used alone, which bounds
  thermal load but does not make the added sharpness work free. No wall-clock figure is
  claimed for a physical device; the Simulator timing above is not representative, and
  device-profiled timing of the unified session (Time Profiler + thermal + hitches) has not
  been performed.
- **One skipped test** — `cancellationPropagatesOutOfTheLoader` in
  `PhotoKitThumbnailLoaderTests` reports as cancelled when executed in the full-suite
  context but passes when run alone; the behaviour predates Phase B (reproduced on the
  Phase A commit) and is a Swift Testing suite-context quirk, not a suppressed failure.
- **The scan-validation UI tests are timing-sensitive under load** — across back-to-back
  full-suite runs on one warm simulator, `testFullScanReachesTerminalStateWithRealProgress`
  and `testCancelStopsScanAndSecondRunWorks` each failed once with an element-snapshot
  query timeout while the 90 s fixture scan was in flight; each passed in isolation and
  in the final full-suite run (5/5). Treat a single UI failure as a flake to rerun, not
  as a pass.
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
