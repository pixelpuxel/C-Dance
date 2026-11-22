import SwiftUI

@MainActor final class AppStore: ObservableObject {
    @Published private(set) var mode: AppMode = AppModeConfiguration.mode
    @Published private(set) var onboardingCompleted = AppModeConfiguration.onboardingCompleted
    @Published var authenticated = false
    @Published private(set) var initialized = false
    @Published var models: [ModelInfo] = []
    @Published var prompts: [PromptTemplate] = []
    @Published var referenceAssets: [ReferenceAsset] = []
    @Published var generations: [Generation] = []
    @Published var favoriteGenerationIDs: Set<String> = GenerationFavoritesStore.load() {
        didSet {
            guard favoriteGenerationIDs != oldValue else { return }
            GenerationFavoritesStore.save(favoriteGenerationIDs)
            guard !applyingRemotePreferences else { return }
            preferenceSyncPending = true
            schedulePreferenceSync()
        }
    }
    @Published var generationRatings: [String: Int] = GenerationRatingsStore.load() {
        didSet {
            guard generationRatings != oldValue else { return }
            GenerationRatingsStore.save(generationRatings)
            guard !applyingRemotePreferences else { return }
            preferenceSyncPending = true
            schedulePreferenceSync()
        }
    }
    @Published var error: String?
    @Published var working = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var syncError: String?
    @Published private(set) var lastSuccessfulRefresh: Date?
    @Published var selectedTab = 0
    @Published var selectedLibrarySection: LibrarySection = .prompts
    @Published var pendingEdit: EditRequest?
    @Published var pendingReference: ReferenceRequest?
    @Published var pendingSetup: SetupRequest?
    @Published var pendingMergedSetup: MergedSetupRequest?
    @Published var pendingGenerationID: String?
    @Published var pendingSharedReferences: [LocalReference] = []
    @Published var providerConfiguration: ProviderConfiguration?
    @Published private(set) var dataLoaded = false
    private var generationTasks: [String: Task<Void, Never>] = [:]
    private var thumbnailPrefetchTask: Task<Void, Never>?
    private var backgroundSyncRetryTask: Task<Void, Never>?
    private var preferenceSyncTask: Task<Void, Never>?
    private var preferenceSyncPending = false
    private var applyingRemotePreferences = false
    private var refreshInProgress = false
    private var dataLoadRevision = 0
    private var importingSharedImages = false
    private var initializationInProgress = false
    private var snapshotSaveTask: Task<Void, Never>?
    private var memoryWarningObserver: NSObjectProtocol?
    private var watchHistoryObserver: NSObjectProtocol?
    @AppStorage("autoSavePhotos") var autoSavePhotos = false
    @AppStorage("autoSaveAlbum") var autoSaveAlbum = false
    @AppStorage("albumName") var albumName = "C-Dance"
    @AppStorage("pushNotificationsEnabled") var pushNotificationsEnabled = true

    init() {
        #if DEBUG
        if let integrationToken = ProcessInfo.processInfo.environment["CDANCE_INTEGRATION_TOKEN"],
           !integrationToken.isEmpty {
            AppModeConfiguration.mode = .server
            AppModeConfiguration.onboardingCompleted = true
            Keychain.token = integrationToken
            mode = .server
            onboardingCompleted = true
            pushNotificationsEnabled = false
            if ProcessInfo.processInfo.environment["CDANCE_INTEGRATION_SETTINGS"] == "1" {
                selectedTab = 3
            }
        } else if ProcessInfo.processInfo.environment["CDANCE_SIMULATOR_USERNAME"]?.isEmpty == false,
                  ProcessInfo.processInfo.environment["CDANCE_SIMULATOR_PASSWORD"]?.isEmpty == false {
            // UI smoke tests can exercise the real login and startup flow without
            // embedding test credentials in the app or repository.
            AppModeConfiguration.mode = .server
            AppModeConfiguration.onboardingCompleted = true
            mode = .server
            onboardingCompleted = true
            selectedTab = 1
            pushNotificationsEnabled = false
        }
        #endif
        WatchHistorySyncService.shared.activate()
        watchHistoryObserver = NotificationCenter.default.addObserver(
            forName: .cdanceWatchHistoryRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                WatchHistorySyncService.shared.sync(self.generations, force: true)
            }
        }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.thumbnailPrefetchTask?.cancel()
                self?.thumbnailPrefetchTask = nil
                await ImageDiskCache.shared.releaseMemory()
            }
        }
    }

    deinit {
        snapshotSaveTask?.cancel()
        backgroundSyncRetryTask?.cancel()
        preferenceSyncTask?.cancel()
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
        if let watchHistoryObserver { NotificationCenter.default.removeObserver(watchHistoryObserver) }
    }

    func initialize() async {
        guard !initialized, !initializationInProgress else { return }
        initializationInProgress = true
        defer { initializationInProgress = false }

        #if DEBUG
        if ProcessInfo.processInfo.environment["CDANCE_HISTORY_FIXTURE"] == "1" {
            await loadHistoryFixture()
            return
        }
        #endif
        mode = AppModeConfiguration.mode
        onboardingCompleted = AppModeConfiguration.onboardingCompleted
        await APIClient.shared.configureServerURL(AppModeConfiguration.serverURL)
        await importSharedImages()
        if mode == .standalone {
            authenticated = onboardingCompleted
            initialized = true
            guard onboardingCompleted else { return }
            await StandaloneService.shared.resumePendingGenerations()
            do { _ = try await loadData() } catch { syncError = error.localizedDescription }
            await configurePushIfNeeded()
            return
        }
        var signedIn = await APIClient.shared.isAuthenticated
        #if DEBUG
        if !signedIn,
           let username = ProcessInfo.processInfo.environment["CDANCE_SIMULATOR_USERNAME"],
           let password = ProcessInfo.processInfo.environment["CDANCE_SIMULATOR_PASSWORD"],
           !username.isEmpty, !password.isEmpty {
            do {
                try await APIClient.shared.login(username: username, password: password)
                signedIn = await APIClient.shared.isAuthenticated
            } catch {
                self.error = "Simulator-Anmeldung fehlgeschlagen: \(error.localizedDescription)"
            }
        }
        #endif
        if signedIn {
            if let snapshot = await Task.detached(priority: .userInitiated, operation: { LocalAppSnapshotStore.load(for: .server) }).value {
                apply(snapshot)
                authenticated = true
                initialized = true
            }
            do {
                _ = try await loadData()
            } catch where Self.isCancellation(error) {
                return
            } catch {
                if dataLoaded { scheduleBackgroundSyncRetry() }
                else { syncError = error.localizedDescription }
            }
        }
        authenticated = signedIn
        initialized = true
        if signedIn {
            if preferenceSyncPending { schedulePreferenceSync() }
            await configurePushIfNeeded()
            if let generationID = PushNotificationRouter.consumePending() { await openGeneration(generationID) }
        }
    }

    func finishStandaloneOnboarding(apiKey: String?) async {
        dataLoadRevision += 1
        AppModeConfiguration.mode = .standalone
        AppModeConfiguration.onboardingCompleted = true
        mode = .standalone; onboardingCompleted = true; authenticated = true
        loadLocalPreferencesForCurrentMode()
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { providerConfiguration = try await APIClient.shared.configureProvider(apiKey: apiKey) }
            catch { self.error = error.localizedDescription }
        }
        do { _ = try await loadData() } catch { self.error = error.localizedDescription }
        await configurePushIfNeeded()
    }

    func switchToStandalone() async {
        dataLoadRevision += 1
        thumbnailPrefetchTask?.cancel(); generationTasks.values.forEach { $0.cancel() }; generationTasks.removeAll()
        AppModeConfiguration.mode = .standalone; AppModeConfiguration.onboardingCompleted = true
        mode = .standalone; onboardingCompleted = true; authenticated = true
        loadLocalPreferencesForCurrentMode()
        resetVisibleData()
        if let snapshot = await Task.detached(priority: .userInitiated, operation: {
            LocalAppSnapshotStore.load(for: .standalone)
        }).value {
            apply(snapshot)
        }
        await StandaloneService.shared.resumePendingGenerations()
        do { _ = try await loadData() } catch { self.error = error.localizedDescription }
    }

    func switchToServer(address: String) async -> Bool {
        error = nil
        guard let url = AppModeConfiguration.normalizedServerURL(address) else { error = "Bitte eine gültige HTTPS-Serveradresse eingeben."; return false }
        do {
            try await APIClient.shared.validateServer(at: url)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        dataLoadRevision += 1
        thumbnailPrefetchTask?.cancel(); generationTasks.values.forEach { $0.cancel() }; generationTasks.removeAll()
        if AppModeConfiguration.serverURL != url {
            await APIClient.shared.clearServerSession()
        }
        AppModeConfiguration.serverURL = url; AppModeConfiguration.mode = .server; AppModeConfiguration.onboardingCompleted = true
        await APIClient.shared.configureServerURL(url)
        mode = .server; onboardingCompleted = true
        loadLocalPreferencesForCurrentMode()
        resetVisibleData()
        let signedIn = await APIClient.shared.validateServerSession()
        authenticated = signedIn
        if signedIn {
            if let snapshot = await Task.detached(priority: .userInitiated, operation: {
                LocalAppSnapshotStore.load(for: .server)
            }).value {
                apply(snapshot)
            }
            do { _ = try await loadData() } catch where Self.isCancellation(error) {
                return true
            } catch { self.error = error.localizedDescription }
        }
        if signedIn { error = nil }
        return true
    }
    func importSharedImages() async {
        guard !importingSharedImages else { return }
        importingSharedImages = true
        defer { importingSharedImages = false }
        let payloads: [Data] = await Task.detached {
            guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.info.schreiber.cdance") else { return [] }
            let folder = root.appendingPathComponent("Incoming", isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
            return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                try? FileManager.default.removeItem(at: url)
                return data
            }
        }.value
        for data in payloads {
            if let normalized = UIImage.cdanceUploadJPEG(from: data),
               let preview = UIImage.referencePreview(from: normalized) {
                pendingSharedReferences.append(LocalReference(data: normalized, preview: preview))
            }
        }
        if !payloads.isEmpty { selectedTab = 0 }
    }

    func importSharedImage(from url: URL) async {
        let data: Data? = await Task.detached(priority: .userInitiated) {
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard let data,
              let normalized = UIImage.cdanceUploadJPEG(from: data),
              let preview = UIImage.referencePreview(from: normalized) else {
            error = "Das geteilte Bild konnte nicht geöffnet werden."
            return
        }
        pendingSharedReferences.insert(LocalReference(data: normalized, preview: preview), at: 0)
        selectedTab = 0
    }
    func login(username: String, password: String) async {
        await perform {
            try await APIClient.shared.login(username: username, password: password)
            _ = try await loadData()
            authenticated = true
            if preferenceSyncPending { schedulePreferenceSync() }
            initialized = true
            await configurePushIfNeeded()
            if let generationID = PushNotificationRouter.consumePending() { await openGeneration(generationID) }
        }
    }
    func logout() async {
        backgroundSyncRetryTask?.cancel()
        backgroundSyncRetryTask = nil
        preferenceSyncTask?.cancel()
        preferenceSyncTask = nil
        thumbnailPrefetchTask?.cancel()
        thumbnailPrefetchTask = nil
        if let token = UserDefaults.standard.string(forKey: "apnsDeviceToken") {
            try? await APIClient.shared.unregisterDevice(token: token)
        }
        await APIClient.shared.logout()
        LocalAppSnapshotStore.remove(for: .server)
        await ImageDiskCache.shared.removeAll()
        authenticated = false
        dataLoaded = false
        generations = []
        prompts = []
        referenceAssets = []
        models = []
        syncError = nil
        lastSuccessfulRefresh = nil
        WatchHistorySyncService.shared.sync([], force: true)
    }
    func reload(showActivity: Bool = true) async {
        guard authenticated, !refreshInProgress else { return }
        refreshInProgress = true
        if showActivity { isRefreshing = true }
        defer {
            refreshInProgress = false
            if showActivity { isRefreshing = false }
        }

        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let complete = try await loadData()
                syncError = nil
                if !complete { scheduleBackgroundSyncRetry() }
                return
            } catch where Self.isCancellation(error) {
                return
            } catch {
                lastError = error
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
        }

        if dataLoaded {
            // A cached, usable view must not turn into a failure screen because
            // of a brief radio handoff or simultaneous refresh on another device.
            syncError = nil
            scheduleBackgroundSyncRetry()
        } else {
            syncError = lastError?.localizedDescription ?? "Die Serverdaten konnten noch nicht geladen werden."
        }
    }
    func configureProvider(apiKey: String) async -> Bool { var saved=false;await perform { providerConfiguration=try await APIClient.shared.configureProvider(apiKey:apiKey);saved=true };return saved }
    func removeProvider() async { await perform { providerConfiguration=try await APIClient.shared.removeProviderConfiguration() } }
    func configurePushIfNeeded() async {
        guard authenticated, pushNotificationsEnabled else { return }
        do {
            try await PushNotificationService.enable(registerRemote: mode == .server)
            if mode == .server, let token = UserDefaults.standard.string(forKey: "apnsDeviceToken") {
                try await APIClient.shared.registerDevice(token: token)
            }
        } catch let error as PushPermissionError {
            pushNotificationsEnabled = false
            self.error = error.localizedDescription
        } catch where Self.isCancellation(error) {
            return
        } catch where Self.isTransientNetworkError(error) {
            syncError = "Die Verbindung wurde kurz unterbrochen."
        } catch {
            self.error = "Push-Nachrichten konnten nicht eingerichtet werden: \(error.localizedDescription)"
        }
    }

    func setPushNotifications(_ enabled: Bool) async {
        pushNotificationsEnabled = enabled
        if enabled {
            await configurePushIfNeeded()
        } else if let token = UserDefaults.standard.string(forKey: "apnsDeviceToken") {
            try? await APIClient.shared.unregisterDevice(token: token)
        }
    }

    func registerDeviceToken(_ token: String) async {
        guard authenticated, pushNotificationsEnabled else { return }
        do { try await APIClient.shared.registerDevice(token: token) }
        catch where Self.isCancellation(error) || Self.isTransientNetworkError(error) { return }
        catch { self.error = "Das Gerät konnte nicht für Push-Nachrichten registriert werden: \(error.localizedDescription)" }
    }

    func openGeneration(_ generationID: String) async {
        guard authenticated else {
            PushNotificationRouter.storePending(generationID)
            return
        }
        do {
            let generation = try await APIClient.shared.generation(generationID)
            upsert(generation)
            pendingGenerationID = generationID
            selectedTab = 1
        } catch where Self.isCancellation(error) {
            return
        } catch where Self.isTransientNetworkError(error) {
            syncError = "Die Verbindung wurde kurz unterbrochen."
        } catch {
            self.error = "Das fertige Bild konnte nicht geöffnet werden: \(error.localizedDescription)"
        }
    }
    func awaitResult(_ initial: Generation, status: ((String) -> Void)? = nil) async -> Generation? {
        var current = initial
        for _ in 0..<220 {
            if Task.isCancelled { return nil }
            if current.status == "completed" {
                status?("Fertig")
                await autoSave(current)
                return current
            }
            if current.status == "failed" {
                await AutomaticPhotoSaveTracker.shared.abandon(current.id)
                error = current.errorMessage ?? "Die Filmgenerierung ist fehlgeschlagen."
                status?("Fehlgeschlagen")
                return nil
            }
            status?(current.status == "queued" ? "Auftrag wartet…" : "C-Dance erstellt den Film…")
            do {
                try await Task.sleep(for: .seconds(1.5))
                current = try await APIClient.shared.generation(current.id)
                upsert(current)
            } catch where Self.isCancellation(error) {
                return nil
            } catch where Self.isTransientNetworkError(error) {
                syncError = "Die Verbindung wurde kurz unterbrochen. Der Auftrag läuft weiter."
                try? await Task.sleep(for: .seconds(2))
                continue
            } catch {
                self.error = error.localizedDescription
                return nil
            }
        }
        error = "Die Generierung läuft im Hintergrund weiter. Du findest sie im Verlauf."
        return nil
    }
    func upsert(_ generation: Generation) {
        generations.removeAll { $0.id == generation.id }
        generations.insert(generation, at: 0)
        persistSnapshot()
    }
    var activeGenerationCount: Int { generations.filter { $0.status == "queued" || $0.status == "processing" }.count }
    func monitor(_ generation: Generation) {
        upsert(generation)
        guard generationTasks[generation.id] == nil else { return }
        generationTasks[generation.id] = Task { [weak self] in
            guard let self else { return }
            if self.autoSavePhotos {
                await AutomaticPhotoSaveTracker.shared.register(generation.id)
            }
            _ = await self.awaitResult(generation)
            self.generationTasks[generation.id] = nil
        }
    }
    func perform(_ operation: () async throws -> Void) async {
        // A previous bootstrap or refresh error must not survive a new user
        // action. Otherwise a successful request can still present the stale
        // alert and make the action look as if it failed.
        error = nil
        working = true
        defer { working = false }
        do {
            try await operation()
            error = nil
        } catch where Self.isCancellation(error) {
            return
        } catch where Self.isTransientNetworkError(error) {
            syncError = "Die Verbindung wurde kurz unterbrochen."
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    nonisolated static func isTransientNetworkError(_ error: Error) -> Bool {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
        ].contains(value.code)
    }

    @discardableResult private func loadData() async throws -> Bool {
        let expectedMode = mode
        let expectedRevision = dataLoadRevision
        let previouslyKnownGenerations = generations
        async let m = try? APIClient.shared.models()
        async let p = try? APIClient.shared.prompts()
        async let a = try? APIClient.shared.referenceAssets()
        async let h = try? APIClient.shared.history()
        async let c = try? APIClient.shared.providerConfiguration()
        let (modelsResponse, promptsResponse, assets, historyResponse, configuration) = await (m, p, a, h, c)
        guard expectedRevision == dataLoadRevision,
              expectedMode == mode,
              expectedMode == AppModeConfiguration.mode else { throw CancellationError() }

        var loadedSections = 0
        if let modelsResponse { models = modelsResponse.models; loadedSections += 1 }
        if let promptsResponse { prompts = promptsResponse; loadedSections += 1 }
        if let assets { referenceAssets = assets; loadedSections += 1 }
        if let historyResponse {
            generations = historyResponse.items
            reconcileGenerationPreferences()
            loadedSections += 1
        }
        if let configuration { providerConfiguration = configuration; loadedSections += 1 }
        guard loadedSections > 0 else { throw APIClientError.invalidResponse }

        dataLoaded = true
        syncError = nil
        lastSuccessfulRefresh = Date()
        persistSnapshot()
        if historyResponse != nil {
            let currentGenerationIDs = Set(generations.map(\.id))
            let removedImageIDs = Set(previouslyKnownGenerations
                .filter { !currentGenerationIDs.contains($0.id) }
                .flatMap { $0.images.map(\.id) + $0.references.map(\.image.id) })
            let retainedImageIDs = Set(generations.flatMap { $0.images.map(\.id) + $0.references.map(\.image.id) }
                + referenceAssets.map(\.image.id))
            await ImageDiskCache.shared.remove(imageIDs: removedImageIDs.subtracting(retainedImageIDs))
        }
        scheduleThumbnailPrefetch()
        for generation in generations where generation.status == "queued" || generation.status == "processing" {
            monitor(generation)
        }
        let completed = generations.filter { $0.status == "completed" && $0.resultImage != nil }
        Task { [weak self] in
            guard let self else { return }
            for generation in completed { await self.autoSave(generation) }
        }
        return loadedSections == 5
    }

    private func scheduleBackgroundSyncRetry() {
        guard authenticated else { return }
        backgroundSyncRetryTask?.cancel()
        backgroundSyncRetryTask = Task { [weak self] in
            guard let self else { return }
            for delay in [2.0, 5.0, 12.0, 30.0] {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard !Task.isCancelled, self.authenticated else { return }
                guard !self.refreshInProgress else { continue }
                self.refreshInProgress = true
                do {
                    let complete = try await self.loadData()
                    self.refreshInProgress = false
                    if complete { return }
                } catch where Self.isCancellation(error) {
                    self.refreshInProgress = false
                    return
                } catch {
                    self.refreshInProgress = false
                    continue
                }
            }
        }
    }

    private func reconcileGenerationPreferences() {
        guard mode == .server,
              generations.contains(where: { $0.favorite != nil || $0.rating != nil }) else { return }

        let validIDs = Set(generations.map(\.id))
        let remoteFavorites = Set(generations.filter { $0.favorite == true }.map(\.id))
        let remoteRatings = generations.reduce(into: [String: Int]()) { result, generation in
            if let rating = generation.rating, 1...5 ~= rating { result[generation.id] = rating }
        }
        let migrationKey = "cdance.serverGenerationPreferencesMigrated.\(AppModeConfiguration.serverURL.absoluteString)"

        if !UserDefaults.standard.bool(forKey: migrationKey) {
            let migratedFavorites = remoteFavorites.union(favoriteGenerationIDs.intersection(validIDs))
            var migratedRatings = remoteRatings
            for (id, rating) in generationRatings where validIDs.contains(id) && migratedRatings[id] == nil {
                migratedRatings[id] = rating
            }
            applyPreferences(favorites: migratedFavorites, ratings: migratedRatings)
            UserDefaults.standard.set(true, forKey: migrationKey)
            if migratedFavorites != remoteFavorites || migratedRatings != remoteRatings {
                preferenceSyncPending = true
                schedulePreferenceSync()
            }
        } else if !preferenceSyncPending {
            applyPreferences(favorites: remoteFavorites, ratings: remoteRatings)
        }
    }

    private func applyPreferences(favorites: Set<String>, ratings: [String: Int]) {
        applyingRemotePreferences = true
        favoriteGenerationIDs = favorites
        generationRatings = ratings
        applyingRemotePreferences = false
    }

    private func loadLocalPreferencesForCurrentMode() {
        applyPreferences(
            favorites: GenerationFavoritesStore.load(),
            ratings: GenerationRatingsStore.load()
        )
        preferenceSyncPending = false
    }

    private func schedulePreferenceSync() {
        guard mode == .server, authenticated else { return }
        preferenceSyncTask?.cancel()
        preferenceSyncTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }

            for delay in [0.0, 1.0, 3.0, 8.0, 20.0] {
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                }
                guard !Task.isCancelled, self.mode == .server, self.authenticated else { return }
                do {
                    let desiredFavorites = self.favoriteGenerationIDs
                    let desiredRatings = self.generationRatings
                    var refreshed = self.generations
                    for index in refreshed.indices {
                        let generation = refreshed[index]
                        let favorite = desiredFavorites.contains(generation.id)
                        let rating = desiredRatings[generation.id, default: 0]
                        guard generation.favorite != favorite || (generation.rating ?? 0) != rating else { continue }
                        refreshed[index] = try await APIClient.shared.updateGenerationPreference(
                            generation.id,
                            favorite: favorite,
                            rating: rating
                        )
                    }
                    self.generations = refreshed
                    self.preferenceSyncPending = false
                    self.persistSnapshot()
                    return
                } catch where Self.isCancellation(error) {
                    return
                } catch {
                    continue
                }
            }
        }
    }
    private func resetVisibleData() {
        isRefreshing = false
        dataLoaded = false; generations = []; prompts = []; referenceAssets = []; models = []
        providerConfiguration = nil; syncError = nil; lastSuccessfulRefresh = nil; error = nil
        pendingEdit = nil; pendingReference = nil; pendingSetup = nil; pendingMergedSetup = nil; pendingGenerationID = nil
        pendingSharedReferences = []
    }
    func removeCachedImages(for generation: Generation) async {
        let candidates = Set(generation.images.map(\.id) + generation.references.map(\.image.id))
        let retained = Set(generations.flatMap { $0.images.map(\.id) + $0.references.map(\.image.id) }
            + referenceAssets.map(\.image.id))
        await ImageDiskCache.shared.remove(imageIDs: candidates.subtracting(retained))
        persistSnapshot()
    }
    private func apply(_ snapshot: LocalAppSnapshot) {
        guard snapshot.mode == mode else { return }
        models = snapshot.models
        prompts = snapshot.prompts
        referenceAssets = snapshot.referenceAssets
        generations = snapshot.generations
        providerConfiguration = snapshot.providerConfiguration
        dataLoaded = true
        lastSuccessfulRefresh = snapshot.savedAt
        WatchHistorySyncService.shared.sync(generations)
        scheduleThumbnailPrefetch()
        for generation in generations where generation.status == "queued" || generation.status == "processing" {
            monitor(generation)
        }
    }
    private func persistSnapshot() {
        let snapshot = LocalAppSnapshot(
            mode: mode,
            models: models,
            prompts: prompts,
            referenceAssets: referenceAssets,
            generations: generations,
            providerConfiguration: providerConfiguration,
            savedAt: Date()
        )
        // Polling several active generations can otherwise start many JSON writes
        // at once. Keep only the newest pending snapshot.
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            LocalAppSnapshotStore.save(snapshot)
        }
        WatchHistorySyncService.shared.sync(generations)
    }
    private func scheduleThumbnailPrefetch() {
        thumbnailPrefetchTask?.cancel()
        var unique: [String: APIImage] = [:]
        for generation in generations {
            if let result = generation.resultImage { unique[result.id] = result }
            for reference in generation.references { unique[reference.image.id] = reference.image }
        }
        for asset in referenceAssets { unique[asset.image.id] = asset.image }
        // Visible rows load themselves from the persistent disk cache. Prefetch only
        // the newest items; warming an entire large history wastes memory and radio.
        let images = Array(unique.values.prefix(40))
        thumbnailPrefetchTask = Task(priority: .utility) {
            for image in images {
                guard !Task.isCancelled else { return }
                _ = try? await APIClient.shared.thumbnailData(image, maxSize: 384)
            }
        }
    }
    private func autoSave(_ generation: Generation) async {
        guard autoSavePhotos, let image = generation.resultImage else { return }
        guard await PhotoLibraryService.beginAutomaticSave(generationID: generation.id) else { return }
        do {
            let data = try await APIClient.shared.imageData(image)
            try await PhotoLibraryService.saveAutomatically(data, generationID: generation.id, alreadyClaimed: true)
        } catch {
            await PhotoLibraryService.cancelAutomaticSave(generationID: generation.id)
            if Self.isTransientNetworkError(error) {
                syncError = "Der fertige Film wird bei der nächsten Verbindung automatisch gespeichert."
            } else if !(error is APIClientError) {
                self.error = error.localizedDescription
            }
        }
    }

    #if DEBUG
    private func loadHistoryFixture() async {
        var fixtureGenerations: [Generation] = []
        let prompts = [
            "Realistische Graphitzeichnung auf weißem Hintergrund mit feinen Konturen und weichen Grauabstufungen.",
            "Ändere ausschließlich die Kleidung und erhalte Gesicht, Haltung, Perspektive und Bildausschnitt.",
            "Erstelle eine hochwertige Studioaufnahme mit natürlichem Licht und ruhigem Hintergrund.",
            "Ganzkörperansicht, klare Details, harmonische Proportionen und sachliche Darstellung."
        ]
        for index in 0..<25 {
            let status = index == 6 ? "failed" : (index == 2 ? "processing" : "completed")
            var images: [APIImage] = []
            var references: [GenerationReference] = []
            if status == "completed" {
                let apiImage = APIImage(
                    id: "fixture-image-\(index)", role: "result", mimeType: "image/jpeg",
                    width: 400, height: 400, byteSize: 8_000 + index,
                    downloadURL: URL(string: "https://example.invalid/fixture-\(index).jpg")!
                )
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400))
                let preview = renderer.image { context in
                    UIColor(hue: CGFloat(index % 12) / 12, saturation: 0.38, brightness: 0.78, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
                    let text = "\(index + 1)" as NSString
                    text.draw(at: CGPoint(x: 24, y: 22), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 72, weight: .bold),
                        .foregroundColor: UIColor.white
                    ])
                }
                if let data = preview.jpegData(compressionQuality: 0.85) {
                    await ImageDiskCache.shared.store(data, for: apiImage, variant: "thumbnail-512")
                }
                images = [apiImage]
                references = [GenerationReference(id: "fixture-reference-\(index)", position: 0, purpose: "reference", image: apiImage)]
            }
            fixtureGenerations.append(Generation(
                id: "fixture-generation-\(index)", parentID: index.isMultiple(of: 4) ? "parent" : nil,
                kind: index.isMultiple(of: 3) ? "edit" : "generate", status: status,
                prompt: prompts[index % prompts.count], finalPrompt: prompts[index % prompts.count],
                model: "cdance", aspectRatio: index.isMultiple(of: 2) ? "auto" : "4:3",
                resolution: index.isMultiple(of: 3) ? "4K" : "2K",
                errorMessage: status == "failed" ? "Die Generierung wurde vom Anbieter abgelehnt." : nil,
                createdAt: Date().addingTimeInterval(TimeInterval(-index * 900)), images: images, references: references
            ))
        }
        generations = fixtureGenerations
        referenceAssets = fixtureGenerations.prefix(8).compactMap { generation in
            guard let image = generation.images.first else { return nil }
            return ReferenceAsset(
                id: "fixture-asset-\(generation.id)",
                name: generation.id.hasSuffix("0") ? "Gesicht Frau" : "Referenz \(generation.id.suffix(2))",
                category: "Test",
                favorite: true,
                createdAt: generation.createdAt,
                updatedAt: generation.createdAt,
                image: image
            )
        }
        models = [ModelInfo(id: "dreamina-seedance-2-5-260628", name: "Seedance 2.5", sizes: ["480p", "720p", "1080p", "4k"], defaultSize: "720p", maxReferenceImages: 30, aspectRatios: ["auto", "16:9", "9:16"])]
        dataLoaded = true
        onboardingCompleted = true
        authenticated = true
        initialized = true
        if ProcessInfo.processInfo.environment["CDANCE_GENERATOR_FIXTURE"] == "1" {
            selectedTab = 0
        } else if ProcessInfo.processInfo.environment["CDANCE_SETTINGS_FIXTURE"] == "1" {
            selectedTab = 3
        } else {
            selectedTab = ProcessInfo.processInfo.environment["CDANCE_LIBRARY_FIXTURE"] == "1" ? 2 : 1
        }
        if selectedTab == 2 { selectedLibrarySection = .references }
        if ProcessInfo.processInfo.environment["CDANCE_RESULT_FIXTURE"] == "1" {
            pendingGenerationID = generations.first(where: { $0.status == "completed" && !$0.references.isEmpty })?.id
        }
        if ProcessInfo.processInfo.environment["CDANCE_SYNC_FIXTURE"] == "1" {
            isRefreshing = true
        }
    }
    #endif
}
