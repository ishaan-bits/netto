import Combine
import SwiftUI

@MainActor
final class AppEnvironment: ObservableObject {
    let storageProvider: any StorageProviding
    let photoPermission: any PhotoLibraryPermissionServicing
    let contactsPermission: any ContactsPermissionServicing
    /// Review thumbnails: bounded, coalesced, pixel-capped (never full-resolution pixels).
    let thumbnails: ThumbnailStore

    @Published var flowState: AppFlowState = .launching
    @Published var prompt: PermissionPrompt = .none
    @Published var photoPermissionState: PermissionState = .notDetermined
    @Published var contactsPermissionState: PermissionState = .notDetermined
    @Published var storageSnapshot: StorageSnapshot?
    @Published var catalogState: CatalogScanState = .notStarted
    @Published var analysisState: PhotoAnalysisState = .notStarted
    @Published var selection = PhotoSelectionModel()

    private let makePhotoLibrary: @Sendable () throws -> any PhotoLibraryReading
    private var catalogTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    /// Bumped on every start and cancel. An in-flight run compares it before each state write,
    /// so a cancelled run can never overwrite a newer one's state.
    private var analysisGeneration = 0

    init(
        storageProvider: any StorageProviding = SystemStorageProvider(),
        photoPermission: any PhotoLibraryPermissionServicing = PhotoLibraryPermissionService(),
        contactsPermission: any ContactsPermissionServicing = ContactsPermissionService(),
        makePhotoLibrary: @escaping @Sendable () throws -> any PhotoLibraryReading = {
            try SystemPhotoLibrary()
        },
        thumbnailLoader: any PhotoThumbnailLoading = PhotoKitThumbnailLoader()
    ) {
        self.storageProvider = storageProvider
        self.photoPermission = photoPermission
        self.contactsPermission = contactsPermission
        self.makePhotoLibrary = makePhotoLibrary
        self.thumbnails = ThumbnailStore(loader: thumbnailLoader)
    }

    func bootstrap() async {
        photoPermissionState = photoPermission.currentStatus()
        contactsPermissionState = contactsPermission.currentStatus()
        storageSnapshot = await storageProvider.deviceStorage()
        flowState = .dashboard
    }

    func refreshStorage() async {
        storageSnapshot = await storageProvider.deviceStorage()
    }

    func refreshPermissions() {
        photoPermissionState = photoPermission.currentStatus()
        contactsPermissionState = contactsPermission.currentStatus()
    }

    func requestPhotoAccess() async {
        guard photoPermissionState == .notDetermined else {
            refreshPermissions()
            return
        }
        photoPermissionState = await photoPermission.requestAccess()
    }

    func requestContactsAccess() async {
        guard contactsPermissionState == .notDetermined else {
            refreshPermissions()
            return
        }
        contactsPermissionState = await contactsPermission.requestAccess()
    }

    /// Builds the metadata catalog. Enumeration runs on a detached producer task; this loop only
    /// consumes ordered events, so the main actor stays responsive while the library is read.
    func startCatalogBuild() {
        catalogTask?.cancel()

        let reading: any PhotoLibraryReading
        do {
            reading = try makePhotoLibrary()
        } catch let error as PhotoLibraryReadError {
            catalogState = .failed(error.catalogFailure)
            return
        } catch {
            catalogState = .failed(.underlying("Photos access is required to read your library."))
            return
        }

        let builder = PhotoCatalogBuilder()
        catalogState = .running(.indeterminate)

        catalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in builder.makeScanStream(reading: reading) {
                    switch event {
                    case .progress(let progress):
                        if self.catalogState.isRunning {
                            self.catalogState = .running(progress)
                        }
                    case .completed(let result):
                        self.catalogState = .completed(result)
                    }
                }
            } catch is CancellationError {
                self.catalogState = .cancelled
            } catch let failure as CatalogScanFailure {
                self.catalogState = failure == .cancelled ? .cancelled : .failed(failure)
            } catch {
                self.catalogState = .failed(.underlying("Photos access is required to read your library."))
            }
        }
    }

    func cancelCatalogBuild() {
        catalogTask?.cancel()
        catalogTask = nil
        if catalogState.isRunning {
            catalogState = .cancelled
        }
    }

    // MARK: - Similarity analysis

    /// Runs the full review pipeline: metadata catalog read, then similarity analysis over it.
    ///
    /// Analysis reads only — no photo-library mutation of any kind exists in this app yet. The
    /// catalog phase reports through `analysisState`'s `preparing` stage so the review screen
    /// shows one continuous run; `catalogState` is updated to `.completed` when the read finishes
    /// (never left running: a standalone build is cancelled first, because two concurrent reads
    /// of the same library would only double the work).
    func startSimilarityAnalysis() {
        guard !analysisState.isRunning else { return }
        guard photoPermissionState.isUsable else {
            analysisState = .failed(.underlying("Photos access is required to read your library."))
            return
        }

        analysisTask?.cancel()
        analysisGeneration += 1
        let generation = analysisGeneration
        selection = PhotoSelectionModel()

        catalogTask?.cancel()
        catalogTask = nil
        if catalogState.isRunning {
            catalogState = .cancelled
        }

        let reading: any PhotoLibraryReading
        do {
            reading = try makePhotoLibrary()
        } catch let error as PhotoLibraryReadError {
            analysisState = .failed(Self.analysisFailure(for: error))
            return
        } catch {
            analysisState = .failed(.underlying("Photos access is required to read your library."))
            return
        }

        analysisState = .running(
            PhotoAnalysisProgress(stage: .preparing, completedUnits: 0, totalUnits: 0)
        )

        let builder = PhotoCatalogBuilder()
        let engine = PhotoSimilarityEngine()

        analysisTask = Task { [weak self] in
            guard let self else { return }

            // Stage A — metadata catalog read, reported as `preparing`.
            var built: CatalogScanResult?
            do {
                for try await event in builder.makeScanStream(reading: reading) {
                    guard self.isCurrentAnalysis(generation) else { return }
                    switch event {
                    case .progress(let progress):
                        self.analysisState = .running(PhotoAnalysisProgress(
                            stage: .preparing,
                            completedUnits: progress.enumeratedCount,
                            totalUnits: progress.totalCount
                        ))
                    case .completed(let result):
                        built = result
                        self.catalogState = .completed(result)
                    }
                }
            } catch is CancellationError {
                self.finishAnalysis(generation, as: .cancelled)
                return
            } catch let failure as CatalogScanFailure {
                self.finishAnalysis(
                    generation,
                    as: failure == .cancelled
                        ? .cancelled
                        : .failed(.underlying(failure.userMessage))
                )
                return
            } catch let failure as PhotoLibraryReadError {
                self.finishAnalysis(generation, as: .failed(Self.analysisFailure(for: failure)))
                return
            } catch {
                self.finishAnalysis(
                    generation,
                    as: .failed(.underlying("Photos access is required to read your library."))
                )
                return
            }

            // The stream can finish without `.completed` when it was cancelled mid-read.
            guard let built else {
                self.finishAnalysis(generation, as: .cancelled)
                return
            }
            guard self.isCurrentAnalysis(generation) else { return }

            // Stage B — similarity analysis over the catalog.
            var sawCompletion = false
            do {
                for try await event in engine.makeAnalysisStream(records: built.records) {
                    guard self.isCurrentAnalysis(generation) else { return }
                    switch event {
                    case .progress(let progress):
                        self.analysisState = .running(progress)
                    case .completed(let result):
                        sawCompletion = true
                        self.selection = PhotoSelectionModel(result: result)
                        self.analysisState = .completed(result)
                    }
                }
                if !sawCompletion {
                    self.finishAnalysis(generation, as: .cancelled)
                }
            } catch is CancellationError {
                self.finishAnalysis(generation, as: .cancelled)
            } catch let failure as PhotoAnalysisFailure {
                self.finishAnalysis(
                    generation,
                    as: failure == .cancelled ? .cancelled : .failed(failure)
                )
            } catch {
                self.finishAnalysis(
                    generation,
                    as: .failed(.underlying(String(describing: error)))
                )
            }
        }
    }

    /// Cancels the in-flight run. The generation bump makes any late write from the old run a
    /// no-op, so the state can never flip back after this returns.
    func cancelSimilarityAnalysis() {
        analysisGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        if analysisState.isRunning {
            analysisState = .cancelled
        }
    }

    private func isCurrentAnalysis(_ generation: Int) -> Bool {
        analysisGeneration == generation
    }

    private func finishAnalysis(_ generation: Int, as state: PhotoAnalysisState) {
        guard isCurrentAnalysis(generation) else { return }
        analysisState = state
    }

    private static func analysisFailure(for error: PhotoLibraryReadError) -> PhotoAnalysisFailure {
        switch error {
        case .accessDenied:
            return .underlying("Photos access is required to read your library.")
        case .underlying(let detail):
            return .underlying(detail)
        }
    }
}

struct RootView: View {
    @StateObject private var env = AppEnvironment()

    var body: some View {
        Group {
            switch env.flowState {
            case .launching:
                ProgressView("Starting Netto…")
            case .dashboard, .scanning, .resultsAvailable, .review,
                 .deleting, .deletionCompleted, .deletionFailed:
                DashboardView()
                    .environmentObject(env)
            }
        }
        .task {
            await env.bootstrap()
        }
    }
}
