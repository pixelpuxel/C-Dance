import SwiftUI

enum CDanceTheme {
    static let accent = Color(red: 0.76, green: 0.93, blue: 0.25)
    static let tint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.76, green: 0.93, blue: 0.25, alpha: 1)
            : UIColor(red: 0.34, green: 0.46, blue: 0.04, alpha: 1)
    })
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let background = Color(uiColor: .systemGroupedBackground)
}

@main
struct CDanceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var activationTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            rootContent
            .environmentObject(store)
            .task { await store.initialize() }
            .onOpenURL { url in
                Task {
                    if url.isFileURL {
                        await store.importSharedImage(from: url)
                    } else {
                        await store.importSharedImages()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cdanceDeviceToken)) { notification in
                guard let token = notification.object as? String else { return }
                Task { await store.registerDeviceToken(token) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cdanceNotificationOpened)) { notification in
                guard let generationID = notification.object as? String else { return }
                Task { await store.openGeneration(generationID) }
            }
            .onChange(of: scenePhase) { _, phase in
                activationTask?.cancel()
                if phase == .active {
                    activationTask = Task {
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["CDANCE_HISTORY_FIXTURE"] == "1" { return }
                        #endif
                        try? await Task.sleep(for: .milliseconds(650))
                        guard !Task.isCancelled else { return }
                        await store.importSharedImages()
                        guard store.authenticated else { return }
                        await store.reload(showActivity: false)
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(30)) }
                            catch { return }
                            guard !Task.isCancelled else { return }
                            await store.reload(showActivity: false)
                        }
                    }
                }
            }
            .alert(
                "Hinweis",
                isPresented: Binding(
                    get: { store.error != nil },
                    set: { if !$0 { store.error = nil } }
                )
            ) {
                Button("OK") { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CDANCE_DIFF_FIXTURE"] == "1" {
            HistoryDiffFixtureView()
        } else if ProcessInfo.processInfo.environment["CDANCE_REFERENCE_ZOOM_FIXTURE"] == "1" {
            ReferenceZoomFixtureView()
        } else if ProcessInfo.processInfo.environment["CDANCE_GALLERY_ZOOM_FIXTURE"] == "1" {
            GalleryZoomFixtureView()
        } else if ProcessInfo.processInfo.environment["CDANCE_CROP_FIXTURE"] == "1" {
            CropFixtureView()
        } else {
            regularContent
        }
        #else
        regularContent
        #endif
    }

    @ViewBuilder
    private var regularContent: some View {
        if !store.initialized {
            ProgressView("Daten werden geladen …")
                .tint(CDanceTheme.tint)
        } else if !store.onboardingCompleted {
            StandaloneOnboardingView()
        } else if store.authenticated {
            AuthenticatedRootView()
                .id(store.mode)
        } else {
            LoginView()
        }
    }
}

private struct AuthenticatedRootView: View {
    private struct Destination: Identifiable {
        let id: Int
        let title: String
        let symbol: String
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let destinations = [
        Destination(id: 0, title: "Erstellen", symbol: "sparkles"),
        Destination(id: 1, title: "Verlauf", symbol: "photo.stack.fill"),
        Destination(id: 2, title: "Bibliothek", symbol: "text.quote"),
        Destination(id: 4, title: "Favoriten & Sterne", symbol: "heart.text.square.fill"),
        Destination(id: 3, title: "Einstellungen", symbol: "gearshape.fill"),
    ]

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    List(destinations) { destination in
                        Button {
                            store.selectedTab = destination.id
                        } label: {
                            HStack(spacing: 12) {
                                Label(destination.title, systemImage: destination.symbol)
                                Spacer()
                                if destination.id == 1, store.activeGenerationCount > 0 {
                                    Text(store.activeGenerationCount, format: .number)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(CDanceTheme.accent, in: Capsule())
                                        .foregroundStyle(.black)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            store.selectedTab == destination.id
                                ? CDanceTheme.accent.opacity(0.22)
                                : Color.clear
                        )
                        .accessibilityAddTraits(store.selectedTab == destination.id ? .isSelected : [])
                    }
                    .navigationTitle("C-Dance")
                    .listStyle(.sidebar)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    selectedContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $store.selectedTab) {
                    GeneratorView()
                        .tabItem { Label("Erstellen", systemImage: "sparkles") }
                        .tag(0)
                    HistoryView()
                        .tabItem { Label("Verlauf", systemImage: "photo.stack.fill") }
                        .badge(store.activeGenerationCount)
                        .tag(1)
                    PromptLibraryView()
                        .tabItem { Label("Prompts", systemImage: "text.quote") }
                        .tag(2)
                    SettingsView()
                        .tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
                        .tag(3)
                }
            }
        }
        .tint(CDanceTheme.tint)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 0) {
                SyncStatusBanner()
                Spacer(minLength: 84)
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder private var selectedContent: some View {
        switch store.selectedTab {
        case 1: HistoryView()
        case 2: PromptLibraryView()
        case 4: GenerationAlbumsView()
        case 3: SettingsView()
        default: GeneratorView()
        }
    }
}

struct SyncStatusBanner: View {
    @EnvironmentObject private var store: AppStore
    @State private var refreshDismissed = false
    @GestureState private var dragOffset: CGFloat = 0

    @ViewBuilder var body: some View {
        if store.isRefreshing && store.dataLoaded && !refreshDismissed {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Daten werden aktualisiert …")
            }
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .offset(y: min(0, dragOffset))
            .gesture(
                DragGesture(minimumDistance: 5)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        guard value.translation.height < -12 else { return }
                        withAnimation(.easeOut(duration: 0.18)) { refreshDismissed = true }
                    }
            )
            .accessibilityHint("Nach oben wischen, um auszublenden")
            .accessibilityElement(children: .combine)
        } else if let message = store.syncError, store.dataLoaded {
            HStack(spacing: 9) {
                Image(systemName: "wifi.exclamationmark")
                Text("Aktualisierung fehlgeschlagen").lineLimit(1)
                Button("Erneut versuchen") { Task { await store.reload() } }
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.orange.opacity(0.16), in: Capsule())
            .accessibilityLabel("Aktualisierung fehlgeschlagen: \(message)")
        }
    }
}

struct InitialDataStateView: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let symbol: String

    var body: some View {
        ContentUnavailableView {
            if store.isRefreshing || store.syncError == nil {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Label(title, systemImage: symbol)
                }
            } else {
                Label("Daten nicht erreichbar", systemImage: "wifi.exclamationmark")
            }
        } description: {
            if let error = store.syncError {
                Text("\(title) konnten noch nicht geladen werden. \(error)")
            } else {
                Text("\(title) werden sicher vom Server geladen. Du kannst gleich weiterarbeiten.")
            }
        } actions: {
            if store.syncError != nil {
                Button("Erneut versuchen") { Task { await store.reload() } }
                    .buttonStyle(.borderedProminent)
                    .tint(CDanceTheme.accent)
                    .foregroundStyle(.black)
            }
        }
        .accessibilityLabel(store.syncError == nil ? "\(title) werden geladen" : "\(title) konnten nicht geladen werden")
    }
}
