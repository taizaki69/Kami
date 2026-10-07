import SwiftUI

@main
struct KamiApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
                .preferredColorScheme(nil) // follow system; settings override later
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            UpdatesView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            BrowseView()
                .tabItem { Label("Browse", systemImage: "safari") }
            ExtensionsView()
                .tabItem { Label("Extensions", systemImage: "puzzlepiece") }
        }
        .id(model.libraryPresentation.generation)
        .disabled(model.libraryPresentation.isExclusive)
        .overlay {
            if model.libraryPresentation.isExclusive {
                VStack(spacing: 12) {
                    ProgressView("Saving library changes…")
                    Button("Cancel") { model.cancelExclusiveLibraryChange() }
                }
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Library operation unavailable", isPresented: Binding(
            get: { model.libraryOperationError != nil },
            set: { if !$0 { model.libraryOperationError = nil } }
        )) {
            Button("OK", role: .cancel) { model.libraryOperationError = nil }
        } message: { Text(model.libraryOperationError ?? "") }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                ReadingSaveFailureBanner()
                if let notice = model.libraryRestoreNotice {
                    HStack {
                        Text(notice).font(.footnote)
                        Spacer()
                        Button("Dismiss") { model.libraryRestoreNotice = nil }
                    }.padding().background(.regularMaterial)
                }
            }
        }
        .onAppear { model.downloadsSceneChanged(sceneID: sceneID, active: scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in model.downloadsSceneChanged(sceneID: sceneID, active: phase == .active) }
        .onDisappear { model.downloadsSceneChanged(sceneID: sceneID, active: false) }
    }
}
