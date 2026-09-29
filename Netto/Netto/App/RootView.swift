import Combine
import SwiftUI

@MainActor
final class AppEnvironment: ObservableObject {
    let storageProvider: any StorageProviding
    let photoPermission: any PhotoLibraryPermissionServicing
    let contactsPermission: any ContactsPermissionServicing

    @Published var flowState: AppFlowState = .launching
    @Published var prompt: PermissionPrompt = .none
    @Published var photoPermissionState: PermissionState = .notDetermined
    @Published var contactsPermissionState: PermissionState = .notDetermined
    @Published var storageSnapshot: StorageSnapshot?
    @Published var catalogState: CatalogScanState = .notStarted

    private var catalogTask: Task<Void, Never>?

    init(
        storageProvider: any StorageProviding = SystemStorageProvider(),
        photoPermission: any PhotoLibraryPermissionServicing = PhotoLibraryPermissionService(),
        contactsPermission: any ContactsPermissionServicing = ContactsPermissionService()
    ) {
        self.storageProvider = storageProvider
        self.photoPermission = photoPermission
        self.contactsPermission = contactsPermission
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

        let reading: SystemPhotoLibrary
        do {
            reading = try SystemPhotoLibrary()
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
