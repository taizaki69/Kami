import SwiftUI
import UserNotifications

@main
struct KamiApp: App {
    @UIApplicationDelegateAdaptor(KamiAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(delegate.model)
                .preferredColorScheme(nil) // follow system; settings override later
        }
    }
}

@MainActor
final class KamiAppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    private var refreshObserver: NSObjectProtocol?
    private var chapterNotificationDelegate: ChapterNotificationDelegate?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        model.registerBackgroundUpdates()
        let handler = ChapterNotificationDelegate { [weak self] identifier in
            self?.model.openUpdatesNotification(identifier: identifier)
        }
        chapterNotificationDelegate = handler
        UNUserNotificationCenter.current().delegate = handler
        refreshObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.backgroundRefreshStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.automaticUpdates.reconcile() }
        }
        return true
    }
}

struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()
    @State private var selectedTab = 0
    @State private var updatesOpenID = UUID()

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(0)
            UpdatesView()
                .id(updatesOpenID)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(1)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(2)
            BrowseView()
                .tabItem { Label("Browse", systemImage: "safari") }
                .tag(3)
            ExtensionsView()
                .tabItem { Label("Extensions", systemImage: "puzzlepiece") }
                .tag(4)
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
        .onAppear { model.downloadsSceneChanged(sceneID: sceneID, active: scenePhase == .active); openNotification() }
        .onChange(of: scenePhase) { _, phase in model.downloadsSceneChanged(sceneID: sceneID, active: phase == .active); openNotification() }
        .onChange(of: model.notificationRouteToken) { _, _ in openNotification() }
        .onChange(of: model.libraryPresentation.isExclusive) { _, _ in openNotification() }
        .onDisappear { model.downloadsSceneChanged(sceneID: sceneID, active: false) }
    }
    private func openNotification() {
        if model.consumeUpdatesNotification(active: scenePhase == .active) {
            updatesOpenID = UUID(); selectedTab = 1
        }
    }
}
