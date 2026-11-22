import SwiftUI
import WatchConnectivity

struct WatchHistoryItem: Codable, Identifiable, Hashable {
    let id: String
    var prompt: String
    var createdAt: Date
    var filename: String
}

@MainActor
final class WatchHistoryStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var items: [WatchHistoryItem] = []
    @Published private(set) var syncing = false

    private let session = WCSession.default
    private let fileManager = FileManager.default
    private lazy var directory: URL = {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CDanceWatch", isDirectory: true)
    }()
    private lazy var indexURL = directory.appendingPathComponent("history.json")

    override init() {
        super.init()
        load()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func requestSync() {
        guard session.activationState == .activated else { return }
        syncing = true
        if session.isReachable {
            session.sendMessage(["requestHistory": true], replyHandler: { _ in }, errorHandler: { _ in })
        }
        session.transferUserInfo(["requestHistory": true])
        Task {
            try? await Task.sleep(for: .seconds(2))
            syncing = false
        }
    }

    func image(for item: WatchHistoryItem) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent(item.filename).path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([WatchHistoryItem].self, from: data) else { return }
        items = decoded.filter { fileManager.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func receive(_ userInfo: [String: Any]) {
        guard userInfo["historyImage"] as? Bool == true,
              let id = userInfo["id"] as? String,
              let prompt = userInfo["prompt"] as? String,
              let timestamp = userInfo["createdAt"] as? TimeInterval,
              let data = userInfo["imageData"] as? Data,
              !data.isEmpty else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(id).jpg"
        guard (try? data.write(to: directory.appendingPathComponent(filename), options: .atomic)) != nil else { return }
        items.removeAll { $0.id == id }
        items.append(WatchHistoryItem(id: id, prompt: prompt, createdAt: Date(timeIntervalSince1970: timestamp), filename: filename))
        items.sort { $0.createdAt > $1.createdAt }
        save()
        syncing = false
    }

    private func applyManifest(_ context: [String: Any]) {
        guard let manifest = context["history"] as? [[String: Any]] else { return }
        let ids = Set(manifest.compactMap { $0["id"] as? String })
        let removed = items.filter { !ids.contains($0.id) }
        removed.forEach { try? fileManager.removeItem(at: directory.appendingPathComponent($0.filename)) }
        items.removeAll { !ids.contains($0.id) }
        for entry in manifest {
            guard let id = entry["id"] as? String,
                  let index = items.firstIndex(where: { $0.id == id }) else { continue }
            if let prompt = entry["prompt"] as? String { items[index].prompt = prompt }
            if let timestamp = entry["createdAt"] as? TimeInterval {
                items[index].createdAt = Date(timeIntervalSince1970: timestamp)
            }
        }
        items.sort { $0.createdAt > $1.createdAt }
        save()
    }

    private func save() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor in
            applyManifest(session.receivedApplicationContext)
            requestSync()
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in applyManifest(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let data = try? Data(contentsOf: file.fileURL) else { return }
        var payload = file.metadata ?? [:]
        payload["imageData"] = data
        Task { @MainActor in receive(payload) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in receive(userInfo) }
    }
}

@main
struct CDanceWatchApp: App {
    @StateObject private var store = WatchHistoryStore()

    var body: some Scene {
        WindowGroup {
            WatchGalleryView()
                .environmentObject(store)
        }
    }
}

struct WatchGalleryView: View {
    @EnvironmentObject private var store: WatchHistoryStore
    @Environment(\.scenePhase) private var scenePhase
    private let columns = [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)]

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Bilder", systemImage: "photo.stack")
                    } description: {
                        Text("Öffne CDance auf dem iPhone, um den Verlauf zu übertragen.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 5) {
                            ForEach(store.items) { item in
                                NavigationLink(value: item.id) {
                                    WatchThumbnail(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Verlauf")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.requestSync() } label: {
                        if store.syncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .accessibilityLabel("Verlauf aktualisieren")
                }
            }
            .navigationDestination(for: String.self) { id in
                WatchImagePager(initialID: id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.requestSync() }
        }
    }
}

struct WatchThumbnail: View {
    @EnvironmentObject private var store: WatchHistoryStore
    let item: WatchHistoryItem

    var body: some View {
        Group {
            if let image = store.image(for: item) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct WatchImagePager: View {
    @EnvironmentObject private var store: WatchHistoryStore
    @State private var selectedID: String

    init(initialID: String) { _selectedID = State(initialValue: initialID) }

    var body: some View {
        TabView(selection: $selectedID) {
            ForEach(store.items) { item in
                ZStack(alignment: .bottom) {
                    if let image = store.image(for: item) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                    Text(item.prompt)
                        .font(.caption2)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7)
                        .background(.ultraThinMaterial)
                }
                .tag(item.id)
            }
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle("Bild")
        .navigationBarTitleDisplayMode(.inline)
    }
}
