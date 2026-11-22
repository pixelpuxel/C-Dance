import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: Generation?
    @State private var pendingDeletion: Generation?
    @State private var showFavorites = false
    @State private var selecting = ProcessInfo.processInfo.environment["CDANCE_HISTORY_SELECTION_FIXTURE"] == "1"
    @State private var selectedIDs: Set<String> = []
    @State private var diffSelection: HistoryDiffSelection?
    @State private var shareURLs: [URL] = []
    @State private var showingShare = false
    @State private var showingAlbumPicker = ProcessInfo.processInfo.environment["CDANCE_ALBUM_PICKER_FIXTURE"] == "1"
    @State private var selectionWorking = false
    @State private var selectionMessage: String?
    @State private var searchText = ""
    @State private var filter: HistoryFilter = .all
    @AppStorage("historyViewMode") private var viewModeRaw = HistoryViewMode.cards.rawValue
    @AppStorage("historySortOrder") private var sortOrderRaw = HistorySortOrder.newest.rawValue

    private var cardColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 12)]
        }
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }
    private var photoColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 105, maximum: 150), spacing: 2)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 2), count: 5)
    }

    private var viewMode: HistoryViewMode { HistoryViewMode(rawValue: viewModeRaw) ?? .cards }
    private var sortOrder: HistorySortOrder { HistorySortOrder(rawValue: sortOrderRaw) ?? .newest }
    private var favoriteGenerationIDs: Set<String> {
        get { store.favoriteGenerationIDs }
        nonmutating set { store.favoriteGenerationIDs = newValue }
    }
    private var generationRatings: [String: Int] {
        get { store.generationRatings }
        nonmutating set { store.generationRatings = newValue }
    }
    private var favoriteBinding: Binding<Set<String>> {
        Binding(get: { store.favoriteGenerationIDs }, set: { store.favoriteGenerationIDs = $0 })
    }
    private var ratingsBinding: Binding<[String: Int]> {
        Binding(get: { store.generationRatings }, set: { store.generationRatings = $0 })
    }

    private var visibleGenerations: [Generation] {
        let filtered = store.generations.filter { generation in
            let matchesFilter = filter.matches(generation)
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty || generation.finalPrompt.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesSearch
        }
        return filtered.sorted(by: sortOrder.areInIncreasingOrder)
    }

    private var selectedGenerations: [Generation] {
        visibleGenerations.filter { selectedIDs.contains($0.id) }
    }

    private var photoAlbums: [String] {
        PhotoAlbumPreferences.availableAlbums(defaultAlbumName: store.albumName)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !store.dataLoaded {
                    InitialDataStateView(title: "Dein Verlauf", symbol: "photo.stack")
                } else if store.generations.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Filme", systemImage: "film")
                    } description: {
                        Text("Deine erzeugten Filme und laufenden Aufträge erscheinen hier.")
                    } actions: {
                        Button("Film erstellen") { store.selectedTab = 0 }
                            .buttonStyle(.borderedProminent)
                            .tint(CDanceTheme.accent)
                            .foregroundStyle(.black)
                    }
                } else if visibleGenerations.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ScrollView {
                        if store.activeGenerationCount > 0 { activeQueueBanner }
                        historyContent
                    }
                    .background(CDanceTheme.background)
                    .refreshable { await store.reload() }
                }
            }
            .navigationTitle("Verlauf")
            .searchable(text: $searchText, prompt: "Prompts durchsuchen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showFavorites = true } label: {
                        Label("Favoriten", systemImage: favoriteGenerationIDs.isEmpty ? "heart" : "heart.fill")
                    }
                    .accessibilityLabel("Favoritenalbum mit \(favoriteGenerationIDs.count) Bildern öffnen")
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarLeading)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "Fertig" : "Auswählen") {
                        selecting.toggle()
                        if !selecting { selectedIDs.removeAll() }
                    }
                    .disabled(!visibleGenerations.contains { $0.status == "completed" && $0.resultImage != nil })
                }
                if selecting, selectedIDs.count == 2 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            let selected = visibleGenerations.filter { selectedIDs.contains($0.id) }
                            guard selected.count == 2 else { return }
                            diffSelection = HistoryDiffSelection(left: selected[0], right: selected[1])
                        } label: {
                            Label("Diff", systemImage: "arrow.left.arrow.right")
                        }
                        .accessibilityHint("Vergleicht Prompt, Referenzbilder und Einstellungen")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Ansicht") {
                            Picker("Ansicht", selection: $viewModeRaw) {
                                ForEach(HistoryViewMode.allCases) { mode in
                                    Label(mode.title, systemImage: mode.symbol).tag(mode.rawValue)
                                }
                            }
                        }

                        Section("Sortierung") {
                            Picker("Sortierung", selection: $sortOrderRaw) {
                                ForEach(HistorySortOrder.allCases) { order in
                                    Label(order.title, systemImage: order.symbol).tag(order.rawValue)
                                }
                            }
                        }

                        Section("Status") {
                            Picker("Status", selection: $filter) {
                                ForEach(HistoryFilter.allCases) { item in
                                    Label(item.title, systemImage: item.symbol).tag(item)
                                }
                            }
                        }
                    } label: {
                        Label("Verlauf anpassen", systemImage: historyMenuSymbol)
                    }
                }
            }
            .sheet(item: $selection) { generation in
                HistoryGenerationSheet(
                    generation: generation,
                    gallery: visibleGenerations.filter { $0.status == "completed" && $0.resultImage != nil },
                    favoriteGenerationIDs: favoriteBinding,
                    generationRatings: ratingsBinding,
                    onEdit: { selectedGeneration, image in
                        store.pendingEdit = EditRequest(generation: selectedGeneration, image: image)
                        store.selectedTab = 0
                    },
                    onReference: { _, api, preview in
                        store.pendingReference = ReferenceRequest(image: api, preview: preview)
                        store.selectedTab = 0
                    }
                )
            }
            .sheet(isPresented: $showFavorites) {
                FavoriteAlbumView(
                    generations: store.generations,
                    favoriteGenerationIDs: favoriteBinding,
                    generationRatings: ratingsBinding
                )
                .environmentObject(store)
            }
            .sheet(item: $diffSelection) { selection in
                HistoryDiffMergeView(left: selection.left, right: selection.right) { request in
                    store.pendingMergedSetup = request
                    selectedIDs.removeAll()
                    selecting = false
                    diffSelection = nil
                    store.selectedTab = 0
                }
                .environmentObject(store)
            }
            .sheet(isPresented: $showingShare, onDismiss: clearSelectionShareFiles) {
                ShareSheet(items: shareURLs.map { $0 as Any })
            }
            .sheet(isPresented: $showingAlbumPicker) {
                PhotoAlbumSelectionSheet(
                    albums: photoAlbums,
                    initiallySelected: store.autoSaveAlbum ? [store.albumName] : []
                ) { albums in
                    Task { await saveSelectedGenerations(albumNames: albums) }
                }
            }
            .confirmationDialog("Bild dauerhaft löschen?", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible) {
                Button("Vom Server löschen", role: .destructive) {
                    guard let generation = pendingDeletion else { return }
                    Task { await delete(generation) }
                }
                Button("Abbrechen", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("Der History-Eintrag und seine nicht anderweitig verwendeten Bilddateien werden unwiderruflich entfernt.")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting { selectionBar }
            }
            .overlay {
                if selectionWorking {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                        ProgressView("Bilder werden vorbereitet …")
                            .padding(18)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .alert("Verlauf", isPresented: Binding(
                get: { selectionMessage != nil },
                set: { if !$0 { selectionMessage = nil } }
            )) {
                Button("OK") { selectionMessage = nil }
            } message: {
                Text(selectionMessage ?? "")
            }
            .onAppear { openPendingGeneration() }
            .onChange(of: store.pendingGenerationID) { _, _ in openPendingGeneration() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                HistoryDecodedImageCache.shared.removeAll()
            }
        }
    }

    private var historyMenuSymbol: String {
        let usesDefaults = filter == .all && viewMode == .cards && sortOrder == .newest
        return usesDefaults ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
    }

    @ViewBuilder private var historyContent: some View {
        switch viewMode {
        case .cards:
            LazyVGrid(columns: cardColumns, spacing: 12) {
                ForEach(visibleGenerations) { generation in
                    selectableOverlay(for: generation) {
                        HistoryCard(
                            generation: generation,
                            favorite: favoriteGenerationIDs.contains(generation.id),
                            rating: generationRatings[generation.id, default: 0],
                            onToggleFavorite: { toggleFavorite(generation) },
                            onSetRating: { setRating($0, for: generation) },
                            onDelete: { pendingDeletion = generation },
                            action: { openOrSelect(generation) }
                        )
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 104)
        case .photos:
            LazyVGrid(columns: photoColumns, spacing: 2) {
                ForEach(visibleGenerations) { generation in
                    selectableOverlay(for: generation) {
                        HistoryPhotoTile(
                            generation: generation,
                            action: { openOrSelect(generation) }
                        )
                    }
                        .contextMenu {
                            if !selecting {
                            if generation.resultImage != nil {
                                Button(
                                    favoriteGenerationIDs.contains(generation.id) ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen",
                                    systemImage: favoriteGenerationIDs.contains(generation.id) ? "heart.slash" : "heart"
                                ) { toggleFavorite(generation) }
                                ratingMenu(for: generation)
                            }
                            Button("Dauerhaft löschen", systemImage: "trash", role: .destructive) {
                                pendingDeletion = generation
                            }
                            }
                        }
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 104)
        case .list:
            LazyVStack(spacing: 9) {
                ForEach(visibleGenerations) { generation in
                    selectableOverlay(for: generation) {
                        HistoryListRow(
                            generation: generation,
                            favorite: favoriteGenerationIDs.contains(generation.id),
                            rating: generationRatings[generation.id, default: 0],
                            onToggleFavorite: { toggleFavorite(generation) },
                            onSetRating: { setRating($0, for: generation) },
                            onOpen: { openOrSelect(generation) },
                            onDelete: { pendingDeletion = generation }
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 104)
        }
    }

    @ViewBuilder private func selectableOverlay<Content: View>(
        for generation: Generation,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .topLeading) {
            content()
            if selecting, generation.status == "completed", generation.resultImage != nil {
                Button { toggleSelection(generation) } label: {
                    Color.clear
                        .contentShape(Rectangle())
                        .overlay(alignment: .topLeading) {
                            Image(systemName: selectedIDs.contains(generation.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(selectedIDs.contains(generation.id) ? CDanceTheme.accent : .white, .black.opacity(0.72))
                                .padding(7)
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .buttonStyle(.plain)
                .accessibilityLabel(selectedIDs.contains(generation.id) ? "Auswahl aufheben" : "Bild auswählen")
            }
        }
    }

    private func openOrSelect(_ generation: Generation) {
        if selecting { toggleSelection(generation) }
        else { selection = generation }
    }

    private func toggleSelection(_ generation: Generation) {
        guard generation.status == "completed", generation.resultImage != nil else { return }
        if selectedIDs.contains(generation.id) { selectedIDs.remove(generation.id) }
        else { selectedIDs.insert(generation.id) }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedIDs.count) ausgewählt").font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                Section("Favoriten") {
                    Button("Hinzufügen", systemImage: "heart") { updateSelectedFavorites(add: true) }
                    Button("Entfernen", systemImage: "heart.slash") { updateSelectedFavorites(add: false) }
                }
                Section("Bewertung") {
                    ForEach(1...5, id: \.self) { rating in
                        Button("\(rating) Sterne", systemImage: "star.fill") { updateSelectedRating(rating) }
                    }
                    Button("Bewertung entfernen", systemImage: "star.slash") { updateSelectedRating(0) }
                }
            } label: {
                Label("Zuordnen", systemImage: "heart.text.square")
            }
            .disabled(selectedIDs.isEmpty)
            Button { Task { await shareSelectedGenerations() } } label: {
                Label("Teilen", systemImage: "square.and.arrow.up")
            }
            .disabled(selectedIDs.isEmpty || selectionWorking)
            Menu {
                Button("In Fotos sichern", systemImage: "square.and.arrow.down") {
                    let albums = store.autoSaveAlbum ? [store.albumName] : []
                    Task { await saveSelectedGenerations(albumNames: albums) }
                }
                if !photoAlbums.isEmpty {
                    Section("In Album sichern") {
                        Button("Mehrere Alben auswählen …", systemImage: "checklist") {
                            showingAlbumPicker = true
                        }
                        ForEach(photoAlbums, id: \.self) { album in
                            Button(album, systemImage: "rectangle.stack.badge.plus") {
                                Task { await saveSelectedGenerations(albumNames: [album]) }
                            }
                        }
                    }
                }
            } label: {
                Label("Fotos", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(selectedIDs.isEmpty || selectionWorking)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func updateSelectedFavorites(add: Bool) {
        if add { favoriteGenerationIDs.formUnion(selectedIDs) }
        else { favoriteGenerationIDs.subtract(selectedIDs) }
        selectedIDs.removeAll()
    }

    private func updateSelectedRating(_ rating: Int) {
        for id in selectedIDs {
            if rating > 0 { generationRatings[id] = rating }
            else { generationRatings[id] = nil }
        }
        selectedIDs.removeAll()
    }

    private func shareSelectedGenerations() async {
        selectionWorking = true
        defer { selectionWorking = false }
        clearSelectionShareFiles()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("C-Dance-Auswahl-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var urls: [URL] = []
            for (index, generation) in selectedGenerations.enumerated() {
                guard let image = generation.resultImage else { continue }
                let data = try await APIClient.shared.imageData(image)
                let fileExtension = image.mimeType.lowercased().contains("png") ? "png" : "jpg"
                let url = folder.appendingPathComponent("C-Dance-\(index + 1).\(fileExtension)")
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }
            guard !urls.isEmpty else { throw APIClientError.invalidImage }
            shareURLs = urls
            showingShare = true
        } catch {
            try? FileManager.default.removeItem(at: folder)
            selectionMessage = "Die ausgewählten Bilder konnten nicht vollständig vorbereitet werden: \(error.localizedDescription)"
        }
    }

    private func saveSelectedGenerations(albumNames: [String]) async {
        selectionWorking = true
        defer { selectionWorking = false }
        do {
            var saved = 0
            for generation in selectedGenerations {
                guard let image = generation.resultImage else { continue }
                let data = try await APIClient.shared.imageData(image)
                try await PhotoLibraryService.saveOrAddExisting(
                    data,
                    generationID: generation.id,
                    albumNames: albumNames,
                    sourceAlbumName: store.albumName
                )
                saved += 1
            }
            let destination = albumNames.isEmpty
                ? " in Fotos"
                : " in \(albumNames.count == 1 ? "das Album „\(albumNames[0])“" : "\(albumNames.count) Alben")"
            selectionMessage = saved == 1
                ? "Ein Bild wurde\(destination) gespeichert."
                : "\(saved) Bilder wurden\(destination) gespeichert."
        } catch {
            selectionMessage = "Nicht alle Bilder konnten gespeichert werden: \(error.localizedDescription)"
        }
    }

    private func clearSelectionShareFiles() {
        let folders = Set(shareURLs.map { $0.deletingLastPathComponent() })
        shareURLs.removeAll()
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private func openPendingGeneration() {
        guard let id = store.pendingGenerationID,
              let generation = store.generations.first(where: { $0.id == id }) else { return }
        selection = generation
        store.pendingGenerationID = nil
    }

    private func delete(_ generation: Generation) async {
        do {
            try await APIClient.shared.deleteGeneration(generation.id)
            store.generations.removeAll { $0.id == generation.id }
            favoriteGenerationIDs.remove(generation.id)
            generationRatings[generation.id] = nil
            await store.removeCachedImages(for: generation)
            if selection?.id == generation.id { selection = nil }
            pendingDeletion = nil
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func toggleFavorite(_ generation: Generation) {
        guard generation.status == "completed", generation.resultImage != nil else { return }
        if favoriteGenerationIDs.contains(generation.id) { favoriteGenerationIDs.remove(generation.id) }
        else { favoriteGenerationIDs.insert(generation.id) }
    }

    private func setRating(_ rating: Int, for generation: Generation) {
        guard generation.status == "completed", generation.resultImage != nil else { return }
        if rating > 0 { generationRatings[generation.id] = min(max(rating, 1), 5) }
        else { generationRatings[generation.id] = nil }
    }

    private func ratingMenu(for generation: Generation) -> some View {
        Menu("Bewertung", systemImage: "star") {
            Button("Keine Sterne", systemImage: generationRatings[generation.id, default: 0] == 0 ? "checkmark" : "star.slash") {
                setRating(0, for: generation)
            }
            ForEach(1...5, id: \.self) { rating in
                Button("\(rating) Sterne", systemImage: generationRatings[generation.id, default: 0] == rating ? "checkmark" : "star.fill") {
                    setRating(rating, for: generation)
                }
            }
        }
    }

    private var activeQueueBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(store.activeGenerationCount == 1 ? "1 Auftrag läuft" : "\(store.activeGenerationCount) Aufträge laufen")
                    .font(.headline)
                Text("Du kannst die App weiter benutzen.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Neu") { store.selectedTab = 0 }.font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(CDanceTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

private struct HistoryDiffSelection: Identifiable {
    let id = UUID()
    let left: Generation
    let right: Generation
}

enum PromptMergeChoice: String, CaseIterable, Identifiable {
    case left
    case right
    case both
    case neither

    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: "A"
        case .right: "B"
        case .both: "Beide"
        case .neither: "Keine"
        }
    }
}

struct PromptDiffHunk: Identifiable, Equatable {
    let id: Int
    let left: String
    let right: String
    let isCommon: Bool
}

enum PromptDiffEngine {
    private enum Operation {
        case common(String)
        case removed(String)
        case added(String)
    }

    static func hunks(left: String, right: String) -> [PromptDiffHunk] {
        let leftTokens = sections(left)
        let rightTokens = sections(right)
        let operations = diff(leftTokens, rightTokens)
        var result: [PromptDiffHunk] = []
        var common = ""
        var removed = ""
        var added = ""

        func appendCommon() {
            guard !common.isEmpty else { return }
            result.append(PromptDiffHunk(id: result.count, left: common, right: common, isCommon: true))
            common = ""
        }
        func appendChange() {
            guard !removed.isEmpty || !added.isEmpty else { return }
            result.append(PromptDiffHunk(id: result.count, left: removed, right: added, isCommon: false))
            removed = ""
            added = ""
        }

        for operation in operations {
            switch operation {
            case .common(let token):
                appendChange()
                common += token
            case .removed(let token):
                appendCommon()
                removed += token
            case .added(let token):
                appendCommon()
                added += token
            }
        }
        appendCommon()
        appendChange()
        return result
    }

    static func mergedPrompt(hunks: [PromptDiffHunk], choices: [Int: PromptMergeChoice]) -> String {
        hunks.map { hunk in
            guard !hunk.isCommon else { return hunk.left }
            switch choices[hunk.id, default: .left] {
            case .left: return hunk.left
            case .right: return hunk.right
            case .both: return joinAlternatives(hunk.left, hunk.right)
            case .neither: return ""
            }
        }.joined()
    }

    private static func joinAlternatives(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        let needsSeparator = left.last?.isWhitespace != true && right.first?.isWhitespace != true
        return left + (needsSeparator ? " " : "") + right
    }

    private static func sections(_ text: String) -> [String] {
        // A prompt diff is easier to understand when complete thoughts stay together.
        // Preserve all whitespace so choosing A or B can recreate the original verbatim.
        let pattern = #"(?s).*?(?:[.!?;](?=\s|$)|\n+|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            let section = String(text[tokenRange])
            return section.isEmpty ? nil : section
        }
    }

    private static func diff(_ left: [String], _ right: [String]) -> [Operation] {
        var lengths = Array(repeating: Array(repeating: 0, count: right.count + 1), count: left.count + 1)
        if !left.isEmpty, !right.isEmpty {
            for leftIndex in stride(from: left.count - 1, through: 0, by: -1) {
                for rightIndex in stride(from: right.count - 1, through: 0, by: -1) {
                    if left[leftIndex] == right[rightIndex] {
                        lengths[leftIndex][rightIndex] = lengths[leftIndex + 1][rightIndex + 1] + 1
                    } else {
                        lengths[leftIndex][rightIndex] = max(lengths[leftIndex + 1][rightIndex], lengths[leftIndex][rightIndex + 1])
                    }
                }
            }
        }

        var operations: [Operation] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < left.count || rightIndex < right.count {
            if leftIndex < left.count, rightIndex < right.count, left[leftIndex] == right[rightIndex] {
                operations.append(.common(left[leftIndex]))
                leftIndex += 1
                rightIndex += 1
            } else if leftIndex < left.count,
                      (rightIndex == right.count || lengths[leftIndex + 1][rightIndex] >= lengths[leftIndex][rightIndex + 1]) {
                operations.append(.removed(left[leftIndex]))
                leftIndex += 1
            } else if rightIndex < right.count {
                operations.append(.added(right[rightIndex]))
                rightIndex += 1
            }
        }
        return operations
    }
}

enum DiffReferenceSide: String { case left, right }

enum DiffReferenceMatch: String {
    case same
    case similar
    case onlyLeft
    case onlyRight

    var title: String {
        switch self {
        case .same: "Gleich"
        case .similar: "Ähnlich"
        case .onlyLeft: "Nur A"
        case .onlyRight: "Nur B"
        }
    }
}

struct DiffReferenceCandidate: Identifiable {
    let id: String
    let generationID: String
    let reference: GenerationReference
    let side: DiffReferenceSide
}

struct DiffReferenceGroup: Identifiable {
    let id: String
    let left: DiffReferenceCandidate?
    let right: DiffReferenceCandidate?
    let match: DiffReferenceMatch

    var candidates: [DiffReferenceCandidate] { [left, right].compactMap { $0 } }
}

enum ReferenceDiffEngine {
    static func candidates(left: Generation, right: Generation) -> [DiffReferenceCandidate] {
        let leftCandidates = left.references.sorted { $0.position < $1.position }.map { reference in
            DiffReferenceCandidate(
                id: "left-\(reference.id)-\(reference.image.id)",
                generationID: left.id,
                reference: reference,
                side: .left
            )
        }
        let rightCandidates = right.references.sorted { $0.position < $1.position }.map { reference in
            DiffReferenceCandidate(
                id: "right-\(reference.id)-\(reference.image.id)",
                generationID: right.id,
                reference: reference,
                side: .right
            )
        }
        return leftCandidates + rightCandidates
    }

    static func groups(
        left: Generation,
        right: Generation,
        fingerprints: [String: UInt64] = [:]
    ) -> [DiffReferenceGroup] {
        let allCandidates = candidates(left: left, right: right)
        let leftCandidates = allCandidates.filter { $0.side == .left }
        let rightCandidates = allCandidates.filter { $0.side == .right }
        var unusedRight = Set(rightCandidates.map(\.id))
        var result: [DiffReferenceGroup] = []

        for leftCandidate in leftCandidates {
            let available = rightCandidates.filter { unusedRight.contains($0.id) }
            let exact = available.first { $0.reference.image.id == leftCandidate.reference.image.id }
            let visuallyClosest = available.compactMap { rightCandidate -> (DiffReferenceCandidate, Int)? in
                guard let leftHash = fingerprints[leftCandidate.id],
                      let rightHash = fingerprints[rightCandidate.id] else { return nil }
                return (rightCandidate, (leftHash ^ rightHash).nonzeroBitCount)
            }.min { $0.1 < $1.1 }
            let metadataMatch = available.first {
                likelySameMetadata(leftCandidate.reference.image, $0.reference.image)
            }

            let paired: DiffReferenceCandidate?
            let match: DiffReferenceMatch
            if let exact {
                paired = exact
                match = .same
            } else if let visuallyClosest, visuallyClosest.1 <= 6 {
                paired = visuallyClosest.0
                match = visuallyClosest.1 <= 1 ? .same : .similar
            } else if let metadataMatch {
                paired = metadataMatch
                match = .same
            } else {
                paired = nil
                match = .onlyLeft
            }

            if let paired { unusedRight.remove(paired.id) }
            result.append(DiffReferenceGroup(
                id: "pair-\(leftCandidate.id)-\(paired?.id ?? "none")",
                left: leftCandidate,
                right: paired,
                match: match
            ))
        }

        for rightCandidate in rightCandidates where unusedRight.contains(rightCandidate.id) {
            result.append(DiffReferenceGroup(
                id: "right-only-\(rightCandidate.id)",
                left: nil,
                right: rightCandidate,
                match: .onlyRight
            ))
        }
        return result
    }

    static func perceptualHash(_ data: Data) -> UInt64? {
        ImagePerceptualHash.value(data)
    }

    private static func likelySameMetadata(_ left: APIImage, _ right: APIImage) -> Bool {
        left.width == right.width
            && left.height == right.height
            && left.byteSize == right.byteSize
            && left.mimeType == right.mimeType
    }
}

private enum DiffSettingsSource: String, CaseIterable, Identifiable {
    case left
    case right
    var id: String { rawValue }
    var title: String { self == .left ? "A" : "B" }
}

struct HistoryDiffMergeView: View {
    @Environment(\.dismiss) private var dismiss
    let left: Generation
    let right: Generation
    let onApply: (MergedSetupRequest) -> Void

    private let hunks: [PromptDiffHunk]
    @State private var choices: [Int: PromptMergeChoice]
    @State private var referenceGroups: [DiffReferenceGroup]
    @State private var selectedReferenceIDs: Set<String>
    @State private var matchingReferences = false
    @State private var settingsSource: DiffSettingsSource = .left

    init(left: Generation, right: Generation, onApply: @escaping (MergedSetupRequest) -> Void) {
        self.left = left
        self.right = right
        self.onApply = onApply
        let leftPrompt = left.finalPrompt.isEmpty ? left.prompt : left.finalPrompt
        let rightPrompt = right.finalPrompt.isEmpty ? right.prompt : right.finalPrompt
        let calculatedHunks = PromptDiffEngine.hunks(left: leftPrompt, right: rightPrompt)
        let calculatedGroups = ReferenceDiffEngine.groups(left: left, right: right)
        hunks = calculatedHunks
        _choices = State(initialValue: Dictionary(uniqueKeysWithValues: calculatedHunks.filter { !$0.isCommon }.map { ($0.id, .left) }))
        _referenceGroups = State(initialValue: calculatedGroups)
        _selectedReferenceIDs = State(initialValue: Set(
            calculatedGroups.compactMap(\.left).prefix(10).map(\.id)
        ))
    }

    private var mergedPrompt: String {
        PromptDiffEngine.mergedPrompt(hunks: hunks, choices: choices)
    }

    private var selectedSettings: Generation { settingsSource == .left ? left : right }
    private var referenceCandidates: [DiffReferenceCandidate] { referenceGroups.flatMap(\.candidates) }
    private var selectedReferenceImages: [APIImage] {
        var seen = Set<String>()
        return referenceCandidates.compactMap { candidate in
            guard selectedReferenceIDs.contains(candidate.id),
                  seen.insert(candidate.reference.image.id).inserted else { return nil }
            return candidate.reference.image
        }.prefix(10).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    comparisonHeader
                    promptDiffCard
                    promptMergeCard
                    referencesCard
                    settingsCard
                    mergedPreviewCard
                }
                .padding(16)
            }
            .background(CDanceTheme.background)
            .navigationTitle("Prompt-Diff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let request = MergedSetupRequest(
                        prompt: mergedPrompt,
                        references: selectedReferenceImages,
                        model: selectedSettings.model,
                        aspectRatio: selectedSettings.aspectRatio,
                        resolution: selectedSettings.resolution
                    )
                    dismiss()
                    onApply(request)
                } label: {
                    Label("In Erstellen übernehmen", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(CDanceTheme.accent)
                .foregroundStyle(.black)
                .padding(16)
                .background(.bar)
            }
            .task(id: "\(left.id)-\(right.id)") { await matchReferenceImages() }
        }
    }

    private var comparisonHeader: some View {
        HStack(spacing: 10) {
            comparisonLabel("A", generation: left, color: .red)
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            comparisonLabel("B", generation: right, color: .green)
        }
    }

    private func comparisonLabel(_ label: String, generation: Generation, color: Color) -> some View {
        HStack(spacing: 9) {
            if let resultImage = generation.resultImage {
                HistoryThumbnail(generationID: generation.id, image: resultImage, maxPixelSize: 160)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "photo")
                    .frame(width: 54, height: 54)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.headline).foregroundStyle(color)
                Text(generation.createdAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var promptDiffCard: some View {
        diffCard(title: "Prompt-Unterschiede", symbol: "text.page.badge.magnifyingglass") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(hunks) { hunk in
                    if hunk.isCommon {
                        diffLine(prefix: " ", text: hunk.left, color: .secondary.opacity(0.08))
                    } else {
                        if !hunk.left.isEmpty { diffLine(prefix: "−", text: hunk.left, color: .red.opacity(0.18)) }
                        if !hunk.right.isEmpty { diffLine(prefix: "+", text: hunk.right, color: .green.opacity(0.18)) }
                    }
                }
            }
        }
    }

    private func diffLine(prefix: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(prefix).fontWeight(.bold).frame(width: 14)
            Text(text.isEmpty ? "∅" : text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(color, in: RoundedRectangle(cornerRadius: 6))
    }

    private var promptMergeCard: some View {
        diffCard(title: "Prompt zusammenstellen", symbol: "arrow.triangle.merge") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    mergePresetButton("A komplett", choice: .left)
                    mergePresetButton("B komplett", choice: .right)
                    mergePresetButton("Nur Gleiches", choice: .neither)
                    mergePresetButton("A + B", choice: .both)
                }
            }
            .font(.caption)

            ForEach(hunks.filter { !$0.isCommon }) { hunk in
                VStack(alignment: .leading, spacing: 7) {
                    if !hunk.left.isEmpty { diffLine(prefix: "A", text: hunk.left, color: .red.opacity(0.14)) }
                    if !hunk.right.isEmpty { diffLine(prefix: "B", text: hunk.right, color: .green.opacity(0.14)) }
                    Picker("Übernehmen", selection: choiceBinding(for: hunk.id)) {
                        ForEach(PromptMergeChoice.allCases) { choice in Text(choice.title).tag(choice) }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(9)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func mergePresetButton(_ title: String, choice: PromptMergeChoice) -> some View {
        Button(title) {
            for hunk in hunks where !hunk.isCommon { choices[hunk.id] = choice }
        }
        .buttonStyle(.bordered)
    }

    private func choiceBinding(for id: Int) -> Binding<PromptMergeChoice> {
        Binding(get: { choices[id, default: .left] }, set: { choices[id] = $0 })
    }

    private var referencesCard: some View {
        diffCard(title: "Referenzbilder", symbol: "photo.on.rectangle.angled") {
            HStack {
                Text(referenceSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Auswahl") {
                    Button("Bilder aus A") { selectReferences(from: left) }
                    Button("Bilder aus B") { selectReferences(from: right) }
                    Button("Alle Bilder") { selectedReferenceIDs = Set(referenceCandidates.prefix(10).map(\.id)) }
                    Button("Keine Bilder") { selectedReferenceIDs.removeAll() }
                }
            }
            if matchingReferences {
                Label("Bildinhalte werden verglichen …", systemImage: "photo.badge.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if referenceCandidates.isEmpty {
                Text("Beide Aufträge wurden ohne Referenzbilder erstellt.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(referenceGroups) { group in referenceGroup(group) }
                    }
                }
            }
            if selectedReferenceIDs.count >= 10 {
                Text("Maximal 10 Referenzbilder können übernommen werden.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var referenceSummary: String {
        let same = referenceGroups.filter { $0.match == .same }.count
        let similar = referenceGroups.filter { $0.match == .similar }.count
        let onlyLeft = referenceGroups.filter { $0.match == .onlyLeft }.count
        let onlyRight = referenceGroups.filter { $0.match == .onlyRight }.count
        var parts = ["\(same) gleich"]
        if similar > 0 { parts.append("\(similar) ähnlich") }
        parts.append("\(onlyLeft) nur A")
        parts.append("\(onlyRight) nur B")
        return parts.joined(separator: " · ")
    }

    private func referenceGroup(_ group: DiffReferenceGroup) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                if let left = group.left { referenceTile(left, label: "A", color: .red) }
                if let right = group.right { referenceTile(right, label: "B", color: .green) }
            }
            Text(group.match.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(referenceMatchColor(group.match))
        }
        .padding(6)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain)
    }

    private func referenceTile(_ candidate: DiffReferenceCandidate, label: String, color: Color) -> some View {
        Button {
            if selectedReferenceIDs.contains(candidate.id) {
                selectedReferenceIDs.remove(candidate.id)
            } else if selectedReferenceIDs.count < 10 {
                selectedReferenceIDs.insert(candidate.id)
            }
        } label: {
            VStack(spacing: 5) {
                HistoryReferenceThumbnail(
                    generationID: candidate.generationID,
                    reference: candidate.reference,
                    size: 76,
                    maxPixelSize: 180
                )
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selectedReferenceIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(selectedReferenceIDs.contains(candidate.id) ? CDanceTheme.accent : .white, .black.opacity(0.7))
                            .padding(5)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(label)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(color, in: Capsule())
                            .padding(4)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Referenz \(label), \(selectedReferenceIDs.contains(candidate.id) ? "ausgewählt" : "nicht ausgewählt")")
    }

    private func referenceMatchColor(_ match: DiffReferenceMatch) -> Color {
        switch match {
        case .same: .green
        case .similar: .orange
        case .onlyLeft: .red
        case .onlyRight: .green
        }
    }

    private func selectReferences(from generation: Generation) {
        selectedReferenceIDs = Set(
            referenceCandidates.filter { $0.generationID == generation.id }.prefix(10).map(\.id)
        )
    }

    private func matchReferenceImages() async {
        guard !referenceCandidates.isEmpty else { return }
        matchingReferences = true
        let candidates = referenceCandidates
        let fingerprints = await withTaskGroup(of: (String, UInt64?).self) { group in
            for candidate in candidates {
                group.addTask {
                    let data = try? await APIClient.shared.thumbnailData(candidate.reference.image, maxSize: 160)
                    return (candidate.id, data.flatMap(ReferenceDiffEngine.perceptualHash))
                }
            }
            var values: [String: UInt64] = [:]
            for await (id, fingerprint) in group {
                if let fingerprint { values[id] = fingerprint }
            }
            return values
        }
        referenceGroups = ReferenceDiffEngine.groups(left: left, right: right, fingerprints: fingerprints)
        matchingReferences = false
    }

    private var settingsCard: some View {
        diffCard(title: "Ausgabe-Einstellungen", symbol: "slider.horizontal.3") {
            Picker("Einstellungen übernehmen", selection: $settingsSource) {
                ForEach(DiffSettingsSource.allCases) { source in Text("Von \(source.title)").tag(source) }
            }
            .pickerStyle(.segmented)
            settingRow("Modell", left.model, right.model)
            settingRow("Format", left.aspectRatio, right.aspectRatio)
            settingRow("Auflösung", left.resolution, right.resolution)
        }
    }

    private func settingRow(_ title: String, _ leftValue: String, _ rightValue: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(leftValue).frame(maxWidth: .infinity, alignment: .leading)
                .padding(6).background(leftValue == rightValue ? Color.clear : Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            Text(rightValue).frame(maxWidth: .infinity, alignment: .leading)
                .padding(6).background(leftValue == rightValue ? Color.clear : Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        }
        .font(.caption)
    }

    private var mergedPreviewCard: some View {
        diffCard(title: "Neuer Prompt", symbol: "doc.badge.plus") {
            Text(mergedPrompt.isEmpty ? "Der neue Prompt ist leer." : mergedPrompt)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func diffCard<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

#if DEBUG
struct HistoryDiffFixtureView: View {
    private static func image(_ id: String, role: String, byteSize: Int) -> APIImage {
        APIImage(
            id: id,
            role: role,
            mimeType: "image/jpeg",
            width: 600,
            height: 800,
            byteSize: byteSize,
            downloadURL: URL(string: "https://example.invalid/\(id).jpg")!
        )
    }

    private static func reference(_ id: String, position: Int, signature: Int) -> GenerationReference {
        GenerationReference(
            id: "fixture-\(id)",
            position: position,
            purpose: "reference",
            image: image(id, role: "reference", byteSize: signature)
        )
    }

    private static let left = Generation(
        id: "fixture-a",
        parentID: nil,
        kind: "generate",
        status: "completed",
        prompt: "Zeige eine Frau in einem roten Kleid vor einer hellen Wand.",
        finalPrompt: "Zeige eine Frau in einem roten Kleid vor einer hellen Wand.",
        model: "Seedance 2.5",
        aspectRatio: "3:4",
        resolution: "2K",
        errorMessage: nil,
        createdAt: Date().addingTimeInterval(-60),
        images: [image("result-a", role: "result", byteSize: 90)],
        references: [
            reference("a-gesicht", position: 0, signature: 10),
            reference("a-kleidung", position: 1, signature: 20),
            reference("nur-a", position: 2, signature: 30)
        ]
    )

    private static let right = Generation(
        id: "fixture-b",
        parentID: nil,
        kind: "generate",
        status: "completed",
        prompt: "Zeige eine Frau in einem blauen Kleid vor einer dunklen Wand.",
        finalPrompt: "Zeige eine Frau in einem blauen Kleid vor einer dunklen Wand.",
        model: "Seedance 2.5",
        aspectRatio: "1:1",
        resolution: "4K",
        errorMessage: nil,
        createdAt: Date(),
        images: [image("result-b", role: "result", byteSize: 91)],
        references: [
            reference("b-gesicht", position: 0, signature: 10),
            reference("b-kleidung", position: 1, signature: 20),
            reference("nur-b", position: 2, signature: 40)
        ]
    )

    var body: some View {
        HistoryDiffMergeView(left: Self.left, right: Self.right) { _ in }
    }
}
#endif

private struct HistoryCard: View {
    let generation: Generation
    let favorite: Bool
    let rating: Int
    let onToggleFavorite: () -> Void
    let onSetRating: (Int) -> Void
    let onDelete: () -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: statusSymbol)
                    Text(statusTitle)
                    Spacer()
                    if generation.parentID != nil { Image(systemName: "arrow.triangle.branch") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)

                Text(generation.finalPrompt.isEmpty ? "Ohne Beschreibung" : generation.finalPrompt)
                    .font(.subheadline).foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)

                Text(generation.createdAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(11)
        }
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(minWidth: 0, maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: action)
        .overlay(alignment: .topTrailing) {
            Button(action: onDelete) {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.62))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("History-Eintrag löschen")
        }
        .contextMenu {
            if generation.resultImage != nil {
                Button(favorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen", systemImage: favorite ? "heart.slash" : "heart", action: onToggleFavorite)
                RatingContextMenu(rating: rating, onSetRating: onSetRating)
            }
            Button("Dauerhaft löschen", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityLabel("\(statusTitle), \(generation.finalPrompt)")
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    @ViewBuilder private var preview: some View {
        if let image = generation.resultImage {
            HistoryThumbnail(generationID: generation.id, image: image, maxPixelSize: 384)
        } else if generation.status == "failed" {
            placeholder(symbol: "exclamationmark.triangle", title: "Fehlgeschlagen")
        } else {
            placeholder(symbol: nil, title: generation.status == "queued" ? "Wartet" : "Wird erstellt")
        }
    }

    private func placeholder(symbol: String?, title: String?) -> some View {
        ZStack {
            Color(uiColor: .tertiarySystemGroupedBackground)
            VStack(spacing: 9) {
                if generation.status == "queued" || generation.status == "processing" { ProgressView() }
                if let symbol { Image(systemName: symbol).font(.title2) }
                if let title { Text(title).font(.subheadline.weight(.medium)) }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch generation.status {
        case "completed": "Fertig"
        case "failed": "Fehlgeschlagen"
        case "processing": "Wird erstellt"
        default: "Wartet"
        }
    }
    private var statusSymbol: String {
        switch generation.status {
        case "completed": "checkmark.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        case "processing": "sparkles"
        default: "clock.fill"
        }
    }
    private var statusColor: Color {
        switch generation.status {
        case "completed": .green
        case "failed": .red
        default: .secondary
        }
    }
    private var accessibilityHint: String {
        "Öffnet Prompt, Bilder, Einstellungen und Aktionen"
    }
}

private struct HistoryPhotoTile: View {
    let generation: Generation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Color(uiColor: .tertiarySystemGroupedBackground)
                if let image = generation.resultImage {
                    HistoryThumbnail(generationID: generation.id, image: image, maxPixelSize: 128)
                } else if generation.status == "failed" {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(statusTitle): \(generation.finalPrompt)")
        .accessibilityHint("Öffnet die Detailansicht")
    }

    private var statusTitle: String {
        switch generation.status {
        case "completed": "Fertig"
        case "failed": "Fehlgeschlagen"
        case "processing": "Wird erstellt"
        default: "Wartet"
        }
    }

}

private struct HistoryListRow: View {
    @EnvironmentObject private var store: AppStore
    let generation: Generation
    let favorite: Bool
    let rating: Int
    let onToggleFavorite: () -> Void
    let onSetRating: (Int) -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var activeAction: HistoryQuickAction?
    @State private var shareImage: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onOpen) {
                ZStack {
                    Color(uiColor: .tertiarySystemGroupedBackground)
                    if let image = generation.resultImage {
                        HistoryThumbnail(generationID: generation.id, image: image, maxPixelSize: 192)
                    } else if generation.status == "failed" {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3).foregroundStyle(.red)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 82, height: 82)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bilddetails öffnen")

            VStack(alignment: .leading, spacing: 7) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: statusSymbol)
                            Text(statusTitle)
                            Spacer(minLength: 4)
                            Text(generation.resolution)
                            Text(generation.aspectRatio == "auto" ? "Auto" : generation.aspectRatio)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)

                        HStack(alignment: .bottom, spacing: 8) {
                            Text(generation.finalPrompt.isEmpty ? "Ohne Beschreibung" : generation.finalPrompt)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2, reservesSpace: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)

                            if !generation.references.isEmpty {
                                HistoryReferenceInline(generation: generation)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    ForEach(HistoryQuickAction.allCases) { action in
                        quickActionButton(action)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            if hasResult {
                Button(favorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen", systemImage: favorite ? "heart.slash" : "heart", action: onToggleFavorite)
                RatingContextMenu(rating: rating, onSetRating: onSetRating)
            }
            Button("Dauerhaft löschen", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .sheet(item: $shareImage) { image in ShareSheet(items: [image]) }
    }

    private func quickActionButton(_ action: HistoryQuickAction) -> some View {
        Button {
            run(action)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(action == .setup ? CDanceTheme.accent : Color(uiColor: .tertiarySystemGroupedBackground))
                if activeAction == action {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: action.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(action == .setup ? .black : .primary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
        }
        .buttonStyle(.plain)
        .disabled(activeAction != nil || (!hasResult && action.requiresResult))
        .opacity(!hasResult && action.requiresResult ? 0.35 : 1)
        .accessibilityLabel(action.title)
    }

    private var hasResult: Bool { generation.status == "completed" && generation.resultImage != nil }

    private func run(_ action: HistoryQuickAction) {
        switch action {
        case .setup:
            store.pendingSetup = SetupRequest(generation: generation)
            store.selectedTab = 0
        case .variation, .repeatRequest:
            Task { await enqueue(action) }
        case .edit, .reference, .share, .photos:
            Task { await performImageAction(action) }
        }
    }

    private func enqueue(_ action: HistoryQuickAction) async {
        activeAction = action
        defer { activeAction = nil }
        do {
            let created = action == .variation
                ? try await APIClient.shared.variation(generation.id)
                : try await APIClient.shared.regenerate(generation.id)
            store.monitor(created)
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func performImageAction(_ action: HistoryQuickAction) async {
        guard let apiImage = generation.resultImage else { return }
        activeAction = action
        defer { activeAction = nil }
        do {
            let data = try await APIClient.shared.imageData(apiImage)
            guard let image = await Task.detached(priority: .userInitiated, operation: {
                UIImage.referencePreview(from: data, maxPixelSize: 4_096)
            }).value else { throw APIClientError.invalidImage }
            switch action {
            case .edit:
                store.pendingEdit = EditRequest(generation: generation, image: image)
                store.selectedTab = 0
            case .reference:
                store.pendingReference = ReferenceRequest(image: apiImage, preview: image)
                store.selectedTab = 0
            case .share:
                shareImage = image
            case .photos:
                try await PhotoLibraryService.saveOrAddExisting(
                    data,
                    generationID: generation.id,
                    albumNames: store.autoSaveAlbum ? [store.albumName] : [],
                    sourceAlbumName: store.albumName
                )
            default:
                break
            }
        } catch {
            store.error = error.localizedDescription
        }
    }

    private var statusTitle: String {
        switch generation.status {
        case "completed": "Fertig"
        case "failed": "Fehlgeschlagen"
        case "processing": "Wird erstellt"
        default: "Wartet"
        }
    }

    private var statusSymbol: String {
        switch generation.status {
        case "completed": "checkmark.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        case "processing": "sparkles"
        default: "clock.fill"
        }
    }

    private var statusColor: Color {
        switch generation.status {
        case "completed": .green
        case "failed": .red
        default: .secondary
        }
    }
}

private struct HistoryReferenceInline: View {
    let generation: Generation

    private var references: [GenerationReference] {
        generation.references.sorted { $0.position < $1.position }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(references.prefix(2))) { reference in
                HistoryReferenceThumbnail(generationID: generation.id, reference: reference)
            }

            if references.count > 2 {
                Text("+\(references.count - 2)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(references.count) Referenzbilder verwendet")
    }
}

private struct HistoryReferenceThumbnail: View {
    let generationID: String
    let reference: GenerationReference
    var size: CGFloat = 36
    var maxPixelSize: CGFloat = 96
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemGroupedBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: size >= 60 ? 12 : 9))
        .task(id: reference.image.downloadURL) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        if let data = try? await APIClient.shared.thumbnailData(reference.image, maxSize: Int(maxPixelSize)),
           let decoded = await Self.decode(data, maxPixelSize: maxPixelSize) {
            image = decoded
            return
        }

        guard let refreshed = try? await APIClient.shared.generation(generationID),
              let current = refreshed.references.first(where: { $0.image.id == reference.image.id })
                ?? refreshed.references.first(where: { $0.position == reference.position }),
              let data = try? await APIClient.shared.thumbnailData(current.image, maxSize: Int(maxPixelSize)) else { return }
        image = await Self.decode(data, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        await Task.detached(priority: .utility) {
            UIImage.referencePreview(from: data, maxPixelSize: maxPixelSize)
        }.value
    }
}

private enum HistoryQuickAction: String, CaseIterable, Identifiable {
    case setup, edit, variation, repeatRequest, reference, share, photos
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setup: "Setup bearbeiten"
        case .edit: "Bild bearbeiten"
        case .variation: "Variation erstellen"
        case .repeatRequest: "Wiederholen"
        case .reference: "Als Referenz verwenden"
        case .share: "Teilen"
        case .photos: "In Fotos sichern"
        }
    }
    var symbol: String {
        switch self {
        case .setup: "slider.horizontal.3"
        case .edit: "pencil.and.outline"
        case .variation: "wand.and.stars"
        case .repeatRequest: "arrow.clockwise"
        case .reference: "photo.badge.plus"
        case .share: "square.and.arrow.up"
        case .photos: "square.and.arrow.down"
        }
    }
    var requiresResult: Bool {
        switch self {
        case .setup, .repeatRequest: false
        default: true
        }
    }
}

enum GenerationFavoritesStore {
    private static var key: String { "cdance.favoriteGenerationIDs.\(AppModeConfiguration.mode.rawValue)" }

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }
}

enum GenerationRatingsStore {
    // v2 deliberately starts independently from the briefly conflated favorite/rating store.
    private static var key: String { "cdance.generationRatings.v2.\(AppModeConfiguration.mode.rawValue)" }

    static func load() -> [String: Int] {
        if let stored = UserDefaults.standard.dictionary(forKey: key) {
            return stored.reduce(into: [:]) { result, item in
                if let value = item.value as? Int, 1...5 ~= value { result[item.key] = value }
            }
        }
        return [:]
    }

    static func save(_ ratings: [String: Int]) {
        UserDefaults.standard.set(ratings, forKey: key)
    }
}

private struct RatingContextMenu: View {
    let rating: Int
    let onSetRating: (Int) -> Void

    var body: some View {
        Menu("Bewertung", systemImage: "star") {
            Button("Keine Sterne", systemImage: rating == 0 ? "checkmark" : "star.slash") {
                onSetRating(0)
            }
            ForEach(1...5, id: \.self) { value in
                Button("\(value) Sterne", systemImage: rating == value ? "checkmark" : "star.fill") {
                    onSetRating(value)
                }
            }
        }
    }
}

private struct FavoriteGalleryPresentation: Identifiable {
    let id = UUID()
    let generationID: String
    let image: UIImage
}

struct GenerationAlbumsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        FavoriteAlbumView(
            generations: store.generations,
            favoriteGenerationIDs: Binding(
                get: { store.favoriteGenerationIDs },
                set: { store.favoriteGenerationIDs = $0 }
            ),
            generationRatings: Binding(
                get: { store.generationRatings },
                set: { store.generationRatings = $0 }
            ),
            showsCloseButton: false
        )
    }
}

private struct FavoriteAlbumView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let generations: [Generation]
    @Binding var favoriteGenerationIDs: Set<String>
    @Binding var generationRatings: [String: Int]
    var showsCloseButton = true

    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var galleryPresentation: FavoriteGalleryPresentation?
    @State private var shareURLs: [URL] = []
    @State private var showingShare = false
    @State private var showingAlbumPicker = false
    @State private var working = false
    @State private var message: String?
    @State private var albumRating = 0

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 3)]

    private var favorites: [Generation] {
        generations
            .filter {
                let rating = generationRatings[$0.id, default: 0]
                let belongsToAlbum = albumRating == 0
                    ? favoriteGenerationIDs.contains($0.id)
                    : rating == albumRating
                return belongsToAlbum
                    && $0.status == "completed" && $0.resultImage != nil
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var selectedGenerations: [Generation] {
        favorites.filter { selectedIDs.contains($0.id) }
    }

    private var photoAlbums: [String] {
        PhotoAlbumPreferences.availableAlbums(defaultAlbumName: store.albumName)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                albumPicker
                if favorites.isEmpty {
                    ContentUnavailableView {
                        Label(albumRating == 0 ? "Noch keine Favoriten" : "Keine Filme in diesem Album", systemImage: albumRating == 0 ? "heart" : "star")
                    } description: {
                        Text(albumRating == 0
                             ? "Tippe im Verlauf oder in der Ergebnisansicht auf das Herz."
                             : "Vergib einem Bild die entsprechende Anzahl Sterne oder wähle oben ein anderes Album.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(favorites) { generation in favoriteTile(generation) }
                        }
                        .padding(3)
                        .padding(.bottom, selecting ? 76 : 0)
                    }
                }
            }
            .background(CDanceTheme.background)
            .navigationTitle("Alben")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Schließen") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selecting ? "Fertig" : "Auswählen") {
                        selecting.toggle()
                        if !selecting { selectedIDs.removeAll() }
                    }
                    .disabled(favorites.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { exportBar }
            }
            .overlay {
                if working {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                        ProgressView("Bilder werden vorbereitet …")
                            .padding(18)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .fullScreenCover(item: $galleryPresentation) { presentation in
                HistoryGalleryViewer(
                    generations: favorites,
                    initialGenerationID: presentation.generationID,
                    initialImage: presentation.image,
                    favoriteGenerationIDs: favoriteGenerationIDs,
                    onToggleFavorite: { generation in
                        if favoriteGenerationIDs.contains(generation.id) { favoriteGenerationIDs.remove(generation.id) }
                        else { favoriteGenerationIDs.insert(generation.id) }
                    },
                    generationRatings: generationRatings,
                    onSetRating: { generation, rating in
                        if rating > 0 { generationRatings[generation.id] = rating }
                        else { generationRatings[generation.id] = nil }
                    },
                    onSelection: { _ in },
                    showsPageIndicator: true,
                    onOpenSetup: { generation in
                        store.pendingSetup = SetupRequest(generation: generation)
                        store.selectedTab = 0
                        galleryPresentation = nil
                        if showsCloseButton { dismiss() }
                    }
                )
            }
            .sheet(isPresented: $showingShare, onDismiss: clearShareFiles) {
                ShareSheet(items: shareURLs.map { $0 as Any })
            }
            .sheet(isPresented: $showingAlbumPicker) {
                PhotoAlbumSelectionSheet(
                    albums: photoAlbums,
                    initiallySelected: store.autoSaveAlbum ? [store.albumName] : []
                ) { albums in
                    Task { await saveSelected(albumNames: albums) }
                }
            }
            .alert("Favoriten", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func favoriteTile(_ generation: Generation) -> some View {
        Button {
            if selecting {
                if selectedIDs.contains(generation.id) { selectedIDs.remove(generation.id) }
                else { selectedIDs.insert(generation.id) }
            } else {
                Task { await open(generation) }
            }
        } label: {
            ZStack {
                Color(uiColor: .tertiarySystemGroupedBackground)
                if let image = generation.resultImage {
                    HistoryThumbnail(generationID: generation.id, image: image, maxPixelSize: 256)
                }
                if selecting {
                    Color.black.opacity(selectedIDs.contains(generation.id) ? 0.12 : 0.02)
                    Image(systemName: selectedIDs.contains(generation.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selectedIDs.contains(generation.id) ? CDanceTheme.accent : .white, .black.opacity(0.65))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(7)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !selecting {
                Button(
                    favoriteGenerationIDs.contains(generation.id) ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen",
                    systemImage: favoriteGenerationIDs.contains(generation.id) ? "heart.slash" : "heart"
                ) {
                    if favoriteGenerationIDs.contains(generation.id) { favoriteGenerationIDs.remove(generation.id) }
                    else { favoriteGenerationIDs.insert(generation.id) }
                }
                RatingContextMenu(rating: generationRatings[generation.id, default: 0]) { rating in
                    if rating > 0 { generationRatings[generation.id] = rating }
                    else { generationRatings[generation.id] = nil }
                }
            }
        }
        .accessibilityLabel(selecting ? "Favorit auswählen" : "Favorit öffnen")
    }

    private var albumPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                albumButton(title: "Favoriten", rating: 0)
                ForEach(1...5, id: \.self) { rating in
                    albumButton(title: "\(rating) ★", rating: rating)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(CDanceTheme.background)
    }

    private func albumButton(title: String, rating: Int) -> some View {
        Button {
            albumRating = rating
            selectedIDs.removeAll()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(albumRating == rating ? .black : .primary)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(albumRating == rating ? CDanceTheme.accent : CDanceTheme.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rating == 0 ? "Favoritenalbum" : "Album mit \(rating) Sternen")
    }

    private var exportBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedIDs.count) ausgewählt")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                Section("Favoriten") {
                    Button("Zu Favoriten hinzufügen", systemImage: "heart") {
                        updateSelectedFavorites(add: true)
                    }
                    Button("Aus Favoriten entfernen", systemImage: "heart.slash") {
                        updateSelectedFavorites(add: false)
                    }
                }
                Section("Bewertung") {
                    ForEach(1...5, id: \.self) { rating in
                        Button("\(rating) Sterne", systemImage: "star.fill") {
                            updateSelectedRating(rating)
                        }
                    }
                    Button("Bewertung entfernen", systemImage: "star.slash", role: .destructive) {
                        updateSelectedRating(0)
                    }
                }
            } label: {
                Label("Zuordnen", systemImage: "heart.text.square")
            }
            .disabled(selectedIDs.isEmpty || working)
            Button { Task { await shareSelected() } } label: {
                Label("Teilen", systemImage: "square.and.arrow.up")
            }
            .disabled(selectedIDs.isEmpty || working)
            Menu {
                Button("In Fotos sichern", systemImage: "square.and.arrow.down") {
                    let albums = store.autoSaveAlbum ? [store.albumName] : []
                    Task { await saveSelected(albumNames: albums) }
                }
                if !photoAlbums.isEmpty {
                    Section("In Album sichern") {
                        Button("Mehrere Alben auswählen …", systemImage: "checklist") {
                            showingAlbumPicker = true
                        }
                        ForEach(photoAlbums, id: \.self) { album in
                            Button(album, systemImage: "rectangle.stack.badge.plus") {
                                Task { await saveSelected(albumNames: [album]) }
                            }
                        }
                    }
                }
            } label: {
                Label("Fotos", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(selectedIDs.isEmpty || working)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func updateSelectedFavorites(add: Bool) {
        if add { favoriteGenerationIDs.formUnion(selectedIDs) }
        else { favoriteGenerationIDs.subtract(selectedIDs) }
        selectedIDs.removeAll()
    }

    private func updateSelectedRating(_ rating: Int) {
        for id in selectedIDs {
            if rating > 0 { generationRatings[id] = min(max(rating, 1), 5) }
            else { generationRatings[id] = nil }
        }
        selectedIDs.removeAll()
    }

    private func open(_ generation: Generation) async {
        guard let apiImage = generation.resultImage else { return }
        do {
            let data = try await APIClient.shared.imageData(apiImage)
            guard let image = await Task.detached(priority: .userInitiated, operation: {
                UIImage.referencePreview(from: data, maxPixelSize: 4_096)
            }).value else { throw APIClientError.invalidImage }
            galleryPresentation = FavoriteGalleryPresentation(generationID: generation.id, image: image)
        } catch {
            message = error.localizedDescription
        }
    }

    private func shareSelected() async {
        working = true
        defer { working = false }
        clearShareFiles()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("C-Dance-Favoriten-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var urls: [URL] = []
            for (index, generation) in selectedGenerations.enumerated() {
                guard let image = generation.resultImage else { continue }
                let data = try await APIClient.shared.imageData(image)
                let fileExtension = image.mimeType.lowercased().contains("png") ? "png" : "jpg"
                let url = folder.appendingPathComponent("C-Dance-\(index + 1).\(fileExtension)")
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }
            guard !urls.isEmpty else { throw APIClientError.invalidImage }
            shareURLs = urls
            showingShare = true
        } catch {
            try? FileManager.default.removeItem(at: folder)
            message = "Die ausgewählten Bilder konnten nicht vollständig vorbereitet werden: \(error.localizedDescription)"
        }
    }

    private func saveSelected(albumNames: [String]) async {
        working = true
        defer { working = false }
        do {
            var saved = 0
            for generation in selectedGenerations {
                guard let image = generation.resultImage else { continue }
                let data = try await APIClient.shared.imageData(image)
                try await PhotoLibraryService.saveOrAddExisting(
                    data,
                    generationID: generation.id,
                    albumNames: albumNames,
                    sourceAlbumName: store.albumName
                )
                saved += 1
            }
            let destination = albumNames.isEmpty
                ? " in Fotos"
                : " in \(albumNames.count == 1 ? "das Album „\(albumNames[0])“" : "\(albumNames.count) Alben")"
            message = saved == 1
                ? "Ein Bild wurde\(destination) gespeichert."
                : "\(saved) Bilder wurden\(destination) gespeichert."
        } catch {
            message = "Nicht alle Bilder konnten gespeichert werden: \(error.localizedDescription)"
        }
    }

    private func clearShareFiles() {
        let folders = Set(shareURLs.map { $0.deletingLastPathComponent() })
        shareURLs.removeAll()
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }
}

private struct PhotoAlbumSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let albums: [String]
    let onSave: ([String]) -> Void
    @State private var selectedAlbums: Set<String>

    init(albums: [String], initiallySelected: [String], onSave: @escaping ([String]) -> Void) {
        self.albums = albums
        self.onSave = onSave
        _selectedAlbums = State(initialValue: Set(initiallySelected.filter(albums.contains)))
    }

    var body: some View {
        NavigationStack {
            List(albums, id: \.self) { album in
                Button {
                    if selectedAlbums.contains(album) { selectedAlbums.remove(album) }
                    else { selectedAlbums.insert(album) }
                } label: {
                    HStack {
                        Label(album, systemImage: "rectangle.stack")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selectedAlbums.contains(album) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedAlbums.contains(album) ? CDanceTheme.accent : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Fotoalben auswählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zuordnen") {
                        onSave(albums.filter(selectedAlbums.contains))
                        dismiss()
                    }
                    .disabled(selectedAlbums.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct HistoryThumbnail: View {
    let generationID: String
    let image: APIImage
    let maxPixelSize: Int
    @State private var loadedImage: UIImage?
    @State private var failed = false

    private var sharedPixelSize: Int { max(384, maxPixelSize) }
    private var memoryCacheKey: NSString {
        "\(image.id)|\(image.byteSize)|\(image.width ?? 0)x\(image.height ?? 0)|\(sharedPixelSize)" as NSString
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: .tertiarySystemGroupedBackground)
                if let loadedImage {
                    Image(uiImage: loadedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("Neu laden").font(.caption)
                    }.foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .clipped()
        .contentShape(Rectangle())
        .task(id: image.downloadURL) { await load() }
    }

    private func load() async {
        failed = false
        if let cached = HistoryDecodedImageCache.shared.image(for: memoryCacheKey) {
            loadedImage = cached
            return
        }
        do {
            let data = try await APIClient.shared.thumbnailData(image, maxSize: sharedPixelSize)
            loadedImage = await Self.decode(data, maxPixelSize: CGFloat(sharedPixelSize))
            failed = loadedImage == nil
            if let loadedImage { HistoryDecodedImageCache.shared.store(loadedImage, for: memoryCacheKey) }
            return
        } catch {}

        guard let refreshed = try? await APIClient.shared.generation(generationID),
              let current = refreshed.resultImage,
              let data = try? await APIClient.shared.thumbnailData(current, maxSize: sharedPixelSize),
              let decoded = await Self.decode(data, maxPixelSize: CGFloat(sharedPixelSize)) else {
            failed = true
            return
        }
        loadedImage = decoded
        HistoryDecodedImageCache.shared.store(decoded, for: memoryCacheKey)
    }

    private nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        await Task.detached(priority: .utility) {
            UIImage.referencePreview(from: data, maxPixelSize: maxPixelSize)
        }.value
    }
}

private final class HistoryDecodedImageCache {
    static let shared = HistoryDecodedImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func image(for key: NSString) -> UIImage? { cache.object(forKey: key) }

    func store(_ image: UIImage, for key: NSString) {
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        cache.setObject(image, forKey: key, cost: pixels * 4)
    }

    func removeAll() { cache.removeAllObjects() }
}

private struct HistoryGenerationSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let generation: Generation
    let gallery: [Generation]
    @Binding var favoriteGenerationIDs: Set<String>
    @Binding var generationRatings: [String: Int]
    let onEdit: (Generation, UIImage) -> Void
    let onReference: (Generation, APIImage, UIImage) -> Void
    @State private var selectedGenerationID: String

    init(
        generation: Generation,
        gallery: [Generation],
        favoriteGenerationIDs: Binding<Set<String>>,
        generationRatings: Binding<[String: Int]>,
        onEdit: @escaping (Generation, UIImage) -> Void,
        onReference: @escaping (Generation, APIImage, UIImage) -> Void
    ) {
        self.generation = generation
        self.gallery = gallery
        _favoriteGenerationIDs = favoriteGenerationIDs
        _generationRatings = generationRatings
        self.onEdit = onEdit
        self.onReference = onReference
        _selectedGenerationID = State(initialValue: generation.id)
    }

    private var current: Generation {
        store.generations.first(where: { $0.id == selectedGenerationID })
            ?? gallery.first(where: { $0.id == selectedGenerationID })
            ?? generation
    }

    private var detailPages: [Generation] {
        let pages = gallery.filter { $0.status == "completed" && $0.resultImage != nil }
        return pages.isEmpty ? [generation] : pages
    }

    @ViewBuilder var body: some View {
        if current.status == "completed", current.resultImage != nil {
            NavigationStack {
                TabView(selection: $selectedGenerationID) {
                    ForEach(detailPages) { page in
                        ResultView(
                            generation: page,
                            galleryGenerations: detailPages,
                            onGallerySelection: { selectedGenerationID = $0.id },
                            favoriteGenerationIDs: favoriteGenerationIDs,
                            onToggleFavorite: toggleFavorite,
                            generationRatings: generationRatings,
                            onSetRating: setRating,
                            showsNavigationChrome: false,
                            onEdit: { onEdit(page, $0) },
                            onReference: { onReference(page, $0, $1) }
                        )
                        .tag(page.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityHint("Nach links oder rechts wischen, um zwischen Ergebnissen zu wechseln")
                .navigationTitle("Ergebnis")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { toggleFavorite(current) } label: {
                            Image(systemName: favoriteGenerationIDs.contains(current.id) ? "heart.fill" : "heart")
                                .foregroundStyle(favoriteGenerationIDs.contains(current.id) ? .red : .primary)
                        }
                        .accessibilityLabel(favoriteGenerationIDs.contains(current.id) ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }.fontWeight(.semibold)
                    }
                }
            }
        } else {
            GenerationDetailsView(generation: current)
        }
    }

    private func toggleFavorite(_ selected: Generation) {
        if favoriteGenerationIDs.contains(selected.id) { favoriteGenerationIDs.remove(selected.id) }
        else { favoriteGenerationIDs.insert(selected.id) }
    }

    private func setRating(_ selected: Generation, _ rating: Int) {
        if rating > 0 { generationRatings[selected.id] = min(max(rating, 1), 5) }
        else { generationRatings[selected.id] = nil }
    }
}

private struct GenerationDetailsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let generation: Generation

    @State private var retrying = false
    @State private var referencesExpanded = true
    @State private var zoomTarget: ZoomTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    actions
                    promptCard
                    referencesCard
                    metadataCard
                }
                .padding(16)
            }
            .background(CDanceTheme.background)
            .navigationTitle("Auftragsdetails")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
            .fullScreenCover(item: $zoomTarget) { target in
                ZoomableImageViewer(target: target) {
                    guard let apiImage = target.apiImage else { return }
                    store.pendingReference = ReferenceRequest(image: apiImage, preview: target.image)
                    dismiss()
                    store.selectedTab = 0
                }
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.headline)
                .foregroundStyle(statusColor)
            if generation.status == "failed" {
                Text(generation.errorMessage ?? "C-Dance konnte diesen Auftrag nicht abschließen.")
                    .font(.body)
                Text("Du kannst unten erst Prompt, Bilder und Einstellungen prüfen und verändern, bevor du einen neuen Auftrag startest.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Der Auftrag läuft im Hintergrund. Du kannst sein vollständiges Setup bereits ansehen oder als neuen Entwurf bearbeiten.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                store.pendingSetup = SetupRequest(generation: generation)
                dismiss()
                store.selectedTab = 0
            } label: {
                Label("Setup bearbeiten", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(CDanceTheme.accent)
            .foregroundStyle(.black)

            if generation.status == "failed" {
                Button { Task { await retry() } } label: {
                    if retrying {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Label("Unverändert erneut einreihen", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(retrying)
            }
        }
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Prompt", systemImage: "text.quote").font(.headline)
            if !generation.prompt.isEmpty, generation.prompt != generation.finalPrompt {
                Text("Eigene Eingabe").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(generation.prompt).textSelection(.enabled)
                Divider()
            }
            Text("Finaler Prompt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(generation.finalPrompt.isEmpty ? "Kein Prompt gespeichert" : generation.finalPrompt)
                .textSelection(.enabled)
            if !generation.promptTemplates.isEmpty {
                Divider()
                Text("Verwendete Prompt-Bausteine").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(generation.promptTemplates.sorted(by: { $0.position < $1.position }), id: \.stableID) { template in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name).font(.subheadline.weight(.semibold))
                        Text(template.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var referencesCard: some View {
        if !generation.references.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup(isExpanded: $referencesExpanded) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(generation.references.sorted(by: { $0.position < $1.position })) { reference in
                                ReferenceImageButton(generationID: generation.id, reference: reference) { image, apiImage in
                                    zoomTarget = ZoomTarget(image: image, apiImage: apiImage, title: "Referenzbild \(reference.position + 1)")
                                }
                            }
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Label("Original- und Referenzbilder (\(generation.references.count))", systemImage: "photo.on.rectangle")
                        .font(.headline).frame(minHeight: 44)
                }
                Text("Antippen zum Vergrößern und Zoomen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var metadataCard: some View {
        VStack(spacing: 12) {
            LabeledContent("Modell", value: generation.model)
            LabeledContent("Format", value: generation.aspectRatio == "auto" ? "Smart / Auto" : generation.aspectRatio)
            LabeledContent("Auflösung", value: generation.resolution)
            LabeledContent("Erstellt", value: generation.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Typ", value: generation.kind == "edit" ? "Bearbeitung" : "Generierung")
            if let parentID = generation.parentID {
                LabeledContent("Ausgangsgeneration", value: String(parentID.prefix(8)))
            }
            LabeledContent("Auftrags-ID", value: String(generation.id.prefix(8)))
        }
        .font(.subheadline)
        .padding(16)
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func retry() async {
        retrying = true
        defer { retrying = false }
        do {
            let retry = try await APIClient.shared.regenerate(generation.id)
            store.monitor(retry)
            dismiss()
        } catch {
            store.error = error.localizedDescription
        }
    }

    private var statusTitle: String {
        switch generation.status {
        case "failed": "Generierung fehlgeschlagen"
        case "processing": "Film wird erstellt"
        default: "Auftrag wartet"
        }
    }

    private var statusSymbol: String {
        switch generation.status {
        case "failed": "exclamationmark.triangle.fill"
        case "processing": "sparkles"
        default: "clock.fill"
        }
    }

    private var statusColor: Color { generation.status == "failed" ? .red : .orange }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, active, completed, failed
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "Alle"; case .active: "In Arbeit"; case .completed: "Fertig"; case .failed: "Fehlgeschlagen" }
    }
    var symbol: String {
        switch self { case .all: "square.grid.2x2"; case .active: "clock"; case .completed: "checkmark.circle"; case .failed: "exclamationmark.triangle" }
    }
    func matches(_ generation: Generation) -> Bool {
        switch self {
        case .all: true
        case .active: generation.status == "queued" || generation.status == "processing"
        case .completed: generation.status == "completed"
        case .failed: generation.status == "failed"
        }
    }
}

private enum HistoryViewMode: String, CaseIterable, Identifiable {
    case cards, photos, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cards: "Kartenansicht"
        case .photos: "Foto-Raster"
        case .list: "Zeilenansicht"
        }
    }
    var symbol: String {
        switch self {
        case .cards: "square.grid.2x2"
        case .photos: "square.grid.3x3"
        case .list: "list.bullet.rectangle"
        }
    }
}

enum HistorySortOrder: String, CaseIterable, Identifiable {
    case newest, oldest, status, resolution, prompt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Neueste zuerst"
        case .oldest: "Älteste zuerst"
        case .status: "Nach Status"
        case .resolution: "Nach Auflösung"
        case .prompt: "Prompt A–Z"
        }
    }
    var shortTitle: String {
        switch self {
        case .newest: "Neueste"
        case .oldest: "Älteste"
        case .status: "Status"
        case .resolution: "Auflösung"
        case .prompt: "A–Z"
        }
    }
    var symbol: String {
        switch self {
        case .newest: "calendar.badge.clock"
        case .oldest: "calendar"
        case .status: "checklist"
        case .resolution: "rectangle.expand.vertical"
        case .prompt: "textformat.abc"
        }
    }

    func areInIncreasingOrder(_ lhs: Generation, _ rhs: Generation) -> Bool {
        switch self {
        case .newest:
            lhs.createdAt > rhs.createdAt
        case .oldest:
            lhs.createdAt < rhs.createdAt
        case .status:
            statusRank(lhs.status) == statusRank(rhs.status)
                ? lhs.createdAt > rhs.createdAt
                : statusRank(lhs.status) < statusRank(rhs.status)
        case .resolution:
            lhs.resolution == rhs.resolution
                ? lhs.createdAt > rhs.createdAt
                : lhs.resolution.localizedStandardCompare(rhs.resolution) == .orderedAscending
        case .prompt:
            lhs.finalPrompt == rhs.finalPrompt
                ? lhs.createdAt > rhs.createdAt
                : lhs.finalPrompt.localizedCaseInsensitiveCompare(rhs.finalPrompt) == .orderedAscending
        }
    }

    private func statusRank(_ status: String) -> Int {
        switch status {
        case "processing": 0
        case "queued": 1
        case "completed": 2
        case "failed": 3
        default: 4
        }
    }
}
