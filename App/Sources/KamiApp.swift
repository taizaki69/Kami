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
    }
}
