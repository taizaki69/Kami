import SwiftUI
import MihonCompatKit
import KamiCore

@MainActor
final class AppModel: ObservableObject {
    let store: LibraryStore
    let registry: SourceRegistry
    let storeClient: ExtensionStoreClient
    let admissionService: ExtensionAdmissionService

    @Published var library: [Manga] = []
    @Published var loading = false

    init() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kami", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dbPath = url.appendingPathComponent("kami.sqlite").path

        let store = (try? LibraryStore(path: dbPath)) ?? (try! LibraryStore(inMemory: true))
        self.store = store
        self.registry = SourceRegistry()
        self.storeClient = ExtensionStoreClient()
        self.admissionService = ExtensionAdmissionService(store: store)
        reloadLibrary()
    }

    func reloadLibrary() {
        Task {
            library = (try? await store.libraryManga()) ?? []
        }
    }

    func source(id: Int64) -> (any KamiSource)? {
        registry.source(id: id)
    }

    func toggleLibrary(_ manga: Manga) {
        guard let id = manga.id else { return }
        Task {
            try? await store.setLibrary(!manga.inLibrary, mangaId: id)
            reloadLibrary()
        }
    }
}
