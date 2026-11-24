import SwiftUI
import AVKit

struct ResultView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let generation: Generation
    let galleryGenerations: [Generation]
    let onGallerySelection: (Generation) -> Void
    let favoriteGenerationIDs: Set<String>
    let onToggleFavorite: (Generation) -> Void
    let generationRatings: [String: Int]
    let onSetRating: (Generation, Int) -> Void
    let showsNavigationChrome: Bool
    let onEdit: (UIImage) -> Void
    let onReference: (APIImage, UIImage) -> Void

    @State private var image: UIImage?
    @State private var previewImage: UIImage?
    @State private var isLoadingImage = false
    @State private var imageLoadFailed = false
    @State private var share = false
    @State private var details = true
    @State private var activeAction: String?
    @State private var confirmation: String?
    @State private var zoomTarget: ZoomTarget?
    @State private var galleryPresentation: GalleryPresentation?
    @State private var gallerySelectionID: String?
    @State private var videoURL: URL?

    init(
        generation: Generation,
        galleryGenerations: [Generation] = [],
        onGallerySelection: @escaping (Generation) -> Void = { _ in },
        favoriteGenerationIDs: Set<String> = [],
        onToggleFavorite: @escaping (Generation) -> Void = { _ in },
        generationRatings: [String: Int] = [:],
        onSetRating: @escaping (Generation, Int) -> Void = { _, _ in },
        showsNavigationChrome: Bool = true,
        onEdit: @escaping (UIImage) -> Void,
        onReference: @escaping (APIImage, UIImage) -> Void
    ) {
        self.generation = generation
        self.galleryGenerations = galleryGenerations
        self.onGallerySelection = onGallerySelection
        self.favoriteGenerationIDs = favoriteGenerationIDs
        self.onToggleFavorite = onToggleFavorite
        self.generationRatings = generationRatings
        self.onSetRating = onSetRating
        self.showsNavigationChrome = showsNavigationChrome
        self.onEdit = onEdit
        self.onReference = onReference
    }

    var body: some View {
        Group {
            if showsNavigationChrome {
                NavigationStack {
                    content
                        .navigationTitle("Ergebnis")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { navigationToolbar }
                }
            } else {
                content
            }
        }
        .sheet(isPresented: $share) {
            if let videoURL { ShareSheet(items: [videoURL]) }
            else if let image { ShareSheet(items: [image]) }
        }
        .fullScreenCover(item: $zoomTarget) { target in
            ZoomableImageViewer(target: target) {
                if let api = target.apiImage {
                    dismiss()
                    onReference(api, target.image)
                }
            }
        }
        .fullScreenCover(item: $galleryPresentation, onDismiss: applyGallerySelection) { presentation in
            HistoryGalleryViewer(
                generations: fullScreenGenerations,
                initialGenerationID: presentation.generationID,
                initialImage: presentation.image,
                favoriteGenerationIDs: favoriteGenerationIDs,
                onToggleFavorite: onToggleFavorite,
                generationRatings: generationRatings,
                onSetRating: onSetRating,
                onSelection: { gallerySelectionID = $0 },
                showsPageIndicator: false,
                onOpenSetup: { selected in
                    store.pendingSetup = SetupRequest(generation: selected)
                    store.selectedTab = 0
                    galleryPresentation = nil
                    dismiss()
                }
            )
        }
    }

    private var content: some View {
            ScrollView {
                VStack(spacing: 16) {
                    imageCard
                    primaryActions
                    secondaryActions
                    informationCard
                }
                .padding(16)
            }
            .background(CDanceTheme.background)
    }

    @ToolbarContentBuilder private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { onToggleFavorite(generation) } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? .red : .primary)
            }
            .accessibilityLabel(isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Fertig") { dismiss() }.fontWeight(.semibold)
        }
    }

    private var imageCard: some View {
        VStack(spacing: 0) {
            Group {
                if generation.resultImage?.isVideo == true, let videoURL {
                    ZStack(alignment: .bottomTrailing) {
                        VideoPlayer(player: AVPlayer(url: videoURL))
                            .frame(maxWidth: .infinity)
                            .aspectRatio(Self.videoAspectRatio(for: generation.aspectRatio), contentMode: .fit)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded { openFilmGallery() })
                            .accessibilityLabel("Erzeugter Film im Vollbild öffnen")
                        Button { openFilmGallery() } label: {
                            Label("Vollbild", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(.black.opacity(0.68), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }
                } else if let displayedImage = image ?? previewImage {
                    ZStack {
                        Button {
                            if galleryGenerations.count > 1 {
                                gallerySelectionID = generation.id
                                galleryPresentation = GalleryPresentation(generationID: generation.id, image: displayedImage)
                            } else {
                                zoomTarget = ZoomTarget(image: displayedImage, apiImage: generation.resultImage, title: "Ergebnis")
                            }
                        } label: {
                            Image(uiImage: displayedImage)
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottomTrailing) {
                                    Label("Vergrößern", systemImage: "arrow.up.left.and.arrow.down.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(.black.opacity(0.68), in: Capsule())
                                        .padding(10)
                                }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Erzeugtes Bild vergrößern")

                        if image == nil && isLoadingImage {
                            ProgressView()
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                                .accessibilityLabel("Bild in voller Auflösung wird geladen")
                        }
                    }
                } else {
                    ZStack {
                        Color(uiColor: .tertiarySystemGroupedBackground)
                        if imageLoadFailed {
                            Button {
                                Task { await load() }
                            } label: {
                                Label("Bild erneut laden", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        } else {
                            ProgressView(generation.resultImage?.isVideo == true ? "Film wird geladen …" : "Bild wird geladen …")
                        }
                    }
                    .frame(minHeight: 360)
                }
            }
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .task(id: generation.resultImage?.id) { await load() }
    }

    private static func videoAspectRatio(for ratio: String) -> CGFloat {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 16 / 9 }
        return CGFloat(parts[0]) / CGFloat(parts[1])
    }

    private var fullScreenGenerations: [Generation] {
        galleryGenerations.contains(where: { $0.id == generation.id }) ? galleryGenerations : [generation]
    }

    private func openFilmGallery() {
        gallerySelectionID = generation.id
        galleryPresentation = GalleryPresentation(generationID: generation.id, image: image ?? previewImage)
    }

    private var primaryActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weiterarbeiten").font(.headline)
            ActionButton(title: "Setup bearbeiten", subtitle: "Prompt, Referenzen und Einstellungen laden", symbol: "slider.horizontal.3", prominent: true) {
                store.pendingSetup = SetupRequest(generation: generation)
                store.selectedTab = 0
                dismiss()
            }
            promptRegenerationMenu
            HStack(spacing: 10) {
                ActionButton(title: "Bearbeiten", subtitle: "Markieren & Prompt", symbol: "pencil.and.outline") {
                    guard let image else { return }
                    dismiss()
                    onEdit(image)
                }
                ActionButton(title: "Variation", subtitle: "Neue Variante", symbol: "wand.and.stars", loading: activeAction == "variation") {
                    Task {
                        await enqueue("variation", successMessage: "Variation wurde eingereiht.") {
                            try await APIClient.shared.variation(generation.id)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                ActionButton(title: "Wiederholen", subtitle: "Gleicher Request", symbol: "arrow.clockwise", loading: activeAction == "regenerate") {
                    Task {
                        await enqueue("regenerate", successMessage: "Wiederholung wurde eingereiht.") {
                            try await APIClient.shared.regenerate(generation.id)
                        }
                    }
                }
                ActionButton(title: "Als Referenz", subtitle: "Für neues Bild", symbol: "photo.badge.plus") {
                    guard let api = generation.resultImage, let image else { return }
                    dismiss()
                    onReference(api, image)
                }
            }
        }
    }

    private var promptRegenerationMenu: some View {
        Menu {
            Button("Leerer Prompt", systemImage: "square.and.pencil") {
                guard let apiImage = generation.resultImage, let image else { return }
                store.pendingReference = ReferenceRequest(image: apiImage, preview: image, startsNewDraft: true)
                store.selectedTab = 0
                dismiss()
            }

            if store.prompts.isEmpty {
                Button("Prompt-Baustein anlegen", systemImage: "plus.circle") {
                    store.selectedLibrarySection = .prompts
                    store.selectedTab = 2
                    dismiss()
                }
            } else {
                ForEach(availablePrompts) { prompt in
                    Button {
                        Task { await regenerate(with: prompt) }
                    } label: {
                        Label(prompt.name, systemImage: prompt.favorite ? "star.fill" : "text.quote")
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                if activeAction?.hasPrefix("prompt-") == true {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "text.quote").font(.title3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mit Prompt neu erstellen").font(.subheadline.weight(.semibold))
                    Text(store.prompts.isEmpty ? "Leeren Prompt verwenden" : "Gespeicherten oder leeren Prompt wählen")
                        .font(.caption).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .foregroundStyle(.black)
            .background(CDanceTheme.accent, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(activeAction != nil || image == nil || generation.resultImage == nil)
        .accessibilityHint("Öffnet die Auswahl eines gespeicherten oder leeren Prompts")
    }

    private var availablePrompts: [PromptTemplate] {
        store.prompts.sorted {
            if $0.favorite != $1.favorite { return $0.favorite && !$1.favorite }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { share = true } label: {
                    Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered).disabled(image == nil && videoURL == nil)

                Button { Task { await save() } } label: {
                    if activeAction == "save" {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Label("In Fotos", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.bordered).disabled((image == nil && videoURL == nil) || activeAction == "save")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Bewertung").font(.caption).foregroundStyle(.secondary)
                StarRatingControl(rating: generationRating, expanded: true) { onSetRating(generation, $0) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var generationRating: Int { generationRatings[generation.id, default: 0] }
    private var isFavorite: Bool { favoriteGenerationIDs.contains(generation.id) }

    private var informationCard: some View {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: $details) {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Modell", value: generation.model)
                    LabeledContent("Format", value: generation.aspectRatio == "auto" ? "Smart / Auto" : generation.aspectRatio)
                    LabeledContent("Auflösung", value: generation.resolution)
                    LabeledContent("Erstellt", value: generation.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .padding(.top, 12)
            } label: {
                Label("Einstellungen", systemImage: "info.circle")
                    .font(.headline).frame(minHeight: 44)
            }

            if !generation.references.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(generation.references.count) Referenzbilder", systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .frame(minHeight: 44)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(generation.references.sorted(by: { $0.position < $1.position })) { reference in
                                ReferenceImageButton(generationID: generation.id, reference: reference) { loadedImage, currentAPIImage in
                                    zoomTarget = ZoomTarget(
                                        image: loadedImage,
                                        apiImage: currentAPIImage,
                                        title: "Referenzbild \(reference.position + 1)"
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func load() async {
        guard let api = generation.resultImage else { return }
        isLoadingImage = true
        imageLoadFailed = false
        defer { isLoadingImage = false }

        if api.isVideo {
            do {
                async let file = APIClient.shared.mediaFileURL(api)
                async let thumbnail = APIClient.shared.thumbnailData(api, maxSize: 1_024)
                videoURL = try await file
                if let data = try? await thumbnail {
                    image = UIImage(data: data)
                }
            } catch {
                guard !Task.isCancelled, !AppStore.isCancellation(error) else { return }
                imageLoadFailed = true
                store.error = "Der Ergebnisfilm konnte nicht geladen werden. Bitte aktualisiere den Verlauf."
            }
            return
        }

        if image == nil,
           let cachedPreviewData = await APIClient.shared.cachedThumbnailData(api) {
            previewImage = await Task.detached(priority: .userInitiated) {
                UIImage.referencePreview(from: cachedPreviewData, maxPixelSize: 1_024)
            }.value
        }

        do {
            let data = try await APIClient.shared.imageData(api)
            try Task.checkCancellation()
            image = await Task.detached(priority: .userInitiated) {
                UIImage.referencePreview(from: data, maxPixelSize: 2_048)
            }.value
        } catch {
            guard !Task.isCancelled, !AppStore.isCancellation(error) else { return }
            do {
                let refreshed = try await APIClient.shared.generation(generation.id)
                guard let current = refreshed.resultImage else { throw APIClientError.invalidImage }
                let data = try await APIClient.shared.imageData(current)
                try Task.checkCancellation()
                image = await Task.detached(priority: .userInitiated) {
                    UIImage.referencePreview(from: data, maxPixelSize: 2_048)
                }.value
            } catch {
                guard !Task.isCancelled, !AppStore.isCancellation(error) else { return }
                // A cached preview remains useful even if the full-resolution
                // request temporarily fails. Only interrupt the user when no
                // image can be shown at all.
                guard previewImage == nil else { return }
                imageLoadFailed = true
                store.error = "Der Ergebnisfilm konnte nicht geladen werden. Bitte aktualisiere den Verlauf."
            }
        }
    }

    private func enqueue(
        _ name: String,
        successMessage: String,
        request: () async throws -> Generation
    ) async {
        guard activeAction == nil else { return }
        activeAction = name
        do {
            let generation = try await request()
            store.monitor(generation)
            confirmation = successMessage
            activeAction = nil
        } catch {
            activeAction = nil
            store.error = error.localizedDescription
        }
    }

    private func regenerate(with prompt: PromptTemplate) async {
        guard let apiImage = generation.resultImage, let image else { return }
        await enqueue(
            "prompt-\(prompt.id)",
            successMessage: "„\(prompt.name)“ wurde zur Neuerstellung eingereiht."
        ) {
            try await APIClient.shared.generate(
                prompt: "",
                finalPrompt: prompt.text,
                templateIDs: [prompt.id],
                references: [LocalReference(remote: apiImage, preview: image)],
                model: generation.model,
                ratio: generation.aspectRatio,
                resolution: generation.resolution,
                parentID: generation.id
            )
        }
    }

    private func save() async {
        guard let api = generation.resultImage else { return }
        activeAction = "save"
        do {
            if api.isVideo {
                let fileURL = try await APIClient.shared.mediaFileURL(api)
                try await PhotoLibraryService.saveOrAddExisting(
                    fileURL: fileURL,
                    generationID: generation.id,
                    albumNames: store.autoSaveAlbum ? [store.albumName] : []
                )
            } else {
                let data = try await APIClient.shared.imageData(api)
                try await PhotoLibraryService.saveOrAddExisting(
                    data,
                    generationID: generation.id,
                    albumNames: store.autoSaveAlbum ? [store.albumName] : [],
                    sourceAlbumName: store.albumName
                )
            }
            confirmation = "In Fotos gespeichert."
        } catch {
            store.error = error.localizedDescription
        }
        activeAction = nil
    }

    private func applyGallerySelection() {
        defer { gallerySelectionID = nil }
        guard let gallerySelectionID,
              gallerySelectionID != generation.id,
              let selected = galleryGenerations.first(where: { $0.id == gallerySelectionID }) else { return }
        onGallerySelection(selected)
    }
}

private struct GalleryPresentation: Identifiable {
    let id = UUID()
    let generationID: String
    let image: UIImage?
}

private struct StarRatingControl: View {
    let rating: Int
    var expanded = false
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: expanded ? 8 : 3) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    onChange(value == rating ? 0 : value)
                } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                        .font(expanded ? .title2 : .body)
                        .foregroundStyle(value <= rating ? .yellow : .secondary)
                        .frame(maxWidth: expanded ? .infinity : nil)
                        .frame(width: expanded ? nil : 28, height: expanded ? 44 : 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) von 5 Sternen")
            }
        }
        .frame(maxWidth: expanded ? .infinity : nil)
        .accessibilityElement(children: .contain)
    }
}

enum GalleryDismissPolicy {
    static let activationDistance: CGFloat = 70
    static let dismissalDistance: CGFloat = 240
    static let directionalRatio: CGFloat = 1.4

    static func presentationOffset(for translation: CGSize) -> CGFloat {
        let horizontal = abs(translation.width)
        let vertical = translation.height
        guard vertical > activationDistance, vertical > horizontal * directionalRatio else { return 0 }
        return min((vertical - activationDistance) * 0.65, 260)
    }

    static func shouldDismiss(translation: CGSize) -> Bool {
        translation.height > dismissalDistance
            && translation.height > abs(translation.width) * directionalRatio
    }
}

struct HistoryGalleryViewer: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let generations: [Generation]
    let initialGenerationID: String
    let initialImage: UIImage?
    let favoriteGenerationIDs: Set<String>
    let onToggleFavorite: (Generation) -> Void
    let generationRatings: [String: Int]
    let onSetRating: (Generation, Int) -> Void
    let onSelection: (String) -> Void
    let showsPageIndicator: Bool
    let onOpenSetup: (Generation) -> Void

    @State private var selectionID: String
    @State private var images: [String: UIImage]
    @State private var videos: [String: URL] = [:]
    @State private var failedIDs: Set<String> = []
    @State private var favorites: Set<String>
    @State private var ratings: [String: Int]
    @State private var shareItem: ShareMediaItem?
    @State private var controlsVisible: Bool
    @State private var savingToPhotos = false
    @State private var galleryMessage: String?
    @State private var zoomedGenerationIDs: Set<String> = []
    @GestureState private var dismissOffset: CGFloat = 0

    init(
        generations: [Generation],
        initialGenerationID: String,
        initialImage: UIImage?,
        favoriteGenerationIDs: Set<String>,
        onToggleFavorite: @escaping (Generation) -> Void,
        generationRatings: [String: Int],
        onSetRating: @escaping (Generation, Int) -> Void,
        onSelection: @escaping (String) -> Void,
        showsPageIndicator: Bool,
        onOpenSetup: @escaping (Generation) -> Void
    ) {
        self.generations = generations
        self.initialGenerationID = initialGenerationID
        self.initialImage = initialImage
        self.favoriteGenerationIDs = favoriteGenerationIDs
        self.onToggleFavorite = onToggleFavorite
        self.generationRatings = generationRatings
        self.onSetRating = onSetRating
        self.onSelection = onSelection
        self.showsPageIndicator = showsPageIndicator
        self.onOpenSetup = onOpenSetup
        _selectionID = State(initialValue: initialGenerationID)
        _images = State(initialValue: initialImage.map { [initialGenerationID: $0] } ?? [:])
        _favorites = State(initialValue: favoriteGenerationIDs)
        _ratings = State(initialValue: generationRatings)
        let initialIsVideo = generations.first(where: { $0.id == initialGenerationID })?.resultImage?.isVideo == true
        _controlsVisible = State(initialValue: !initialIsVideo)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectionID) {
                ForEach(generations) { generation in
                    GalleryImagePage(
                        image: images[generation.id],
                        videoURL: videos[generation.id],
                        isVideo: generation.resultImage?.isVideo == true,
                        failed: failedIDs.contains(generation.id),
                        title: "Ergebnisfilm",
                        onClose: { dismiss() },
                        onSingleTap: {
                            guard generation.resultImage?.isVideo == true else { dismiss(); return }
                            withAnimation(.easeInOut(duration: 0.18)) { controlsVisible.toggle() }
                        },
                        onZoomChanged: { zoomed in
                            if zoomed { zoomedGenerationIDs.insert(generation.id) }
                            else { zoomedGenerationIDs.remove(generation.id) }
                        }
                    )
                    .tag(generation.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: showsPageIndicator ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .scrollDisabled(zoomedGenerationIDs.contains(selectionID))
            .offset(y: dismissOffset)
            .simultaneousGesture(dismissGesture)
            .background(.black)
            .navigationTitle(positionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black.opacity(0.82), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar(controlsVisible ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let currentGeneration else { return }
                        onOpenSetup(currentGeneration)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Mit Setup in Erstellen öffnen")
                }
            }
            .task(id: selectionID) { await loadSelection() }
            .onChange(of: selectionID) { _, newValue in
                onSelection(newValue)
                let isVideo = generations.first(where: { $0.id == newValue })?.resultImage?.isVideo == true
                withAnimation(.easeInOut(duration: 0.18)) { controlsVisible = !isVideo }
            }
            .onAppear { onSelection(selectionID) }
            .safeAreaInset(edge: .bottom) {
                if controlsVisible { galleryControls.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.value])
            }
            .alert("Hinweis", isPresented: Binding(
                get: { galleryMessage != nil },
                set: { if !$0 { galleryMessage = nil } }
            )) {
                Button("OK") { galleryMessage = nil }
            } message: {
                Text(galleryMessage ?? "")
            }
        }
    }

    private var currentGeneration: Generation? {
        generations.first { $0.id == selectionID }
    }

    private var galleryControls: some View {
        HStack(spacing: 20) {
            Button {
                guard let currentGeneration else { return }
                if favorites.contains(currentGeneration.id) { favorites.remove(currentGeneration.id) }
                else { favorites.insert(currentGeneration.id) }
                onToggleFavorite(currentGeneration)
            } label: {
                Image(systemName: isCurrentFavorite ? "heart.fill" : "heart")
            }
            .tint(isCurrentFavorite ? .red : .white)
            .accessibilityLabel(isCurrentFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")

            StarRatingControl(rating: currentRating) { rating in
                guard let currentGeneration else { return }
                setRating(rating, for: currentGeneration)
            }

            Button {
                if let video = videos[selectionID] { shareItem = ShareMediaItem(value: video) }
                else if let image = images[selectionID] { shareItem = ShareMediaItem(value: image) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .tint(.white)
            .disabled(images[selectionID] == nil && videos[selectionID] == nil)
            .accessibilityLabel("Film teilen")

            Button { Task { await saveCurrentToPhotos() } } label: {
                if savingToPhotos { ProgressView().tint(.white) }
                else { Image(systemName: "square.and.arrow.down") }
            }
            .tint(.white)
            .disabled(currentGeneration?.resultImage == nil || savingToPhotos)
            .accessibilityLabel("In Fotos sichern")
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.82))
    }

    private var currentRating: Int { ratings[selectionID, default: 0] }
    private var isCurrentFavorite: Bool { favorites.contains(selectionID) }

    private func setRating(_ rating: Int, for generation: Generation) {
        if rating > 0 { ratings[generation.id] = min(max(rating, 1), 5) }
        else { ratings[generation.id] = nil }
        onSetRating(generation, rating)
    }

    private func saveCurrentToPhotos() async {
        guard let generation = currentGeneration, let apiImage = generation.resultImage else { return }
        savingToPhotos = true
        defer { savingToPhotos = false }
        do {
            let albums = store.autoSaveAlbum ? [store.albumName] : []
            if apiImage.isVideo {
                let fileURL: URL
                if let loadedURL = videos[generation.id] {
                    fileURL = loadedURL
                } else {
                    fileURL = try await APIClient.shared.mediaFileURL(apiImage)
                }
                try await PhotoLibraryService.saveOrAddExisting(
                    fileURL: fileURL,
                    generationID: generation.id,
                    albumNames: albums
                )
            } else {
                let data = try await APIClient.shared.imageData(apiImage)
                try await PhotoLibraryService.saveOrAddExisting(
                    data,
                    generationID: generation.id,
                    albumNames: albums,
                    sourceAlbumName: store.albumName
                )
            }
            galleryMessage = apiImage.isVideo ? "Der Film wurde in Fotos gespeichert." : "Das Bild wurde in Fotos gespeichert."
        } catch {
            galleryMessage = error.localizedDescription
        }
    }

    private var positionTitle: String {
        guard let index = generations.firstIndex(where: { $0.id == selectionID }) else { return "Ergebnis" }
        return "\(index + 1) von \(generations.count)"
    }

    private func loadSelection() async {
        if images[selectionID] == nil,
           !failedIDs.contains(selectionID),
           let generation = generations.first(where: { $0.id == selectionID }) {
            await loadImage(for: generation)
        }
        guard !Task.isCancelled else { return }
        await prefetchNeighbors()
    }

    private func trimImages(around currentID: String) {
        guard images.count > 3,
              let currentIndex = generations.firstIndex(where: { $0.id == currentID }) else { return }
        let nearest = images.keys.sorted { left, right in
            let leftIndex = generations.firstIndex(where: { $0.id == left }) ?? .max
            let rightIndex = generations.firstIndex(where: { $0.id == right }) ?? .max
            return abs(leftIndex - currentIndex) < abs(rightIndex - currentIndex)
        }
        for id in nearest.dropFirst(3) { images[id] = nil }
    }

    private func loadImage(for generation: Generation) async {
        guard images[generation.id] == nil,
              !failedIDs.contains(generation.id),
              let apiImage = generation.resultImage else { return }
        do {
            if apiImage.isVideo {
                videos[generation.id] = try await APIClient.shared.mediaFileURL(apiImage)
                if images[generation.id] == nil,
                   let thumbnail = try? await APIClient.shared.thumbnailData(apiImage, maxSize: 1_024) {
                    images[generation.id] = UIImage(data: thumbnail)
                }
                return
            }
            let data = try await APIClient.shared.imageData(apiImage)
            guard !Task.isCancelled else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                UIImage.referencePreview(from: data, maxPixelSize: 2_048)
            }.value
            guard !Task.isCancelled, let decoded else { return }
            images[generation.id] = decoded
            trimImages(around: selectionID)
        } catch {
            guard !Task.isCancelled else { return }
            failedIDs.insert(generation.id)
        }
    }

    private func prefetchNeighbors() async {
        guard let currentIndex = generations.firstIndex(where: { $0.id == selectionID }) else { return }
        for index in [currentIndex - 1, currentIndex + 1] where generations.indices.contains(index) {
            guard !Task.isCancelled else { return }
            await loadImage(for: generations[index])
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 36)
            .updating($dismissOffset) { value, state, _ in
                guard !zoomedGenerationIDs.contains(selectionID) else { return }
                state = GalleryDismissPolicy.presentationOffset(for: value.translation)
            }
            .onEnded { value in
                guard !zoomedGenerationIDs.contains(selectionID) else { return }
                if GalleryDismissPolicy.shouldDismiss(translation: value.translation) { dismiss() }
            }
    }
}

private struct GalleryImagePage: View {
    let image: UIImage?
    let videoURL: URL?
    let isVideo: Bool
    let failed: Bool
    let title: String
    let onClose: () -> Void
    let onSingleTap: () -> Void
    let onZoomChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black
            if isVideo, let videoURL {
                VideoPlayer(player: AVPlayer(url: videoURL))
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded(onSingleTap))
                    .accessibilityLabel("Ergebnisfilm")
            } else if let image {
                PannableZoomImage(
                    image: image,
                    accessibilityTitle: title,
                    onSingleTap: onClose,
                    onZoomChanged: onZoomChanged
                )
                .accessibilityHint("Mit zwei Fingern an der gewünschten Stelle zoomen und das vergrößerte Bild mit einem Finger verschieben")
            } else if failed {
                ContentUnavailableView(isVideo ? "Film nicht ladbar" : "Bild nicht ladbar", systemImage: isVideo ? "film" : "photo.badge.exclamationmark")
                    .foregroundStyle(.white)
            } else {
                ProgressView(isVideo ? "Film wird geladen …" : "Bild wird geladen …").tint(.white).foregroundStyle(.white)
            }
        }
        .background(.black)
    }
}

private struct ShareMediaItem: Identifiable {
    let id = UUID()
    let value: Any
}

struct ZoomTarget: Identifiable {
    let id = UUID()
    let image: UIImage
    let apiImage: APIImage?
    let title: String
}

struct ReferenceImageButton: View {
    let generationID: String
    let reference: GenerationReference
    let action: (UIImage, APIImage) -> Void
    @State private var image: UIImage?
    @State private var currentAPIImage: APIImage?
    @State private var failed = false
    @State private var opening = false

    var body: some View {
        Button {
            if currentAPIImage != nil { Task { await openFullSize() } }
            else { Task { await load() } }
        } label: {
            ZStack {
                Color(uiColor: .tertiarySystemGroupedBackground)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    VStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text("Neu laden").font(.caption2)
                    }.foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                if opening { Color.black.opacity(0.35); ProgressView().tint(.white) }
                if image != nil {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.65), in: Circle())
                        .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 104, height: 104).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Referenzbild \(reference.position + 1) vergrößern")
        .task(id: reference.image.downloadURL) { await load() }
    }

    private func load() async {
        failed = false
        currentAPIImage = reference.image
        do {
            let data = try await APIClient.shared.thumbnailData(reference.image, maxSize: 320)
            image = UIImage(data: data)
            failed = image == nil
            return
        } catch {}

        guard let refreshed = try? await APIClient.shared.generation(generationID),
              let currentReference = refreshed.references.first(where: { $0.image.id == reference.image.id })
                ?? refreshed.references.first(where: { $0.position == reference.position }),
              let data = try? await APIClient.shared.thumbnailData(currentReference.image, maxSize: 320),
              let loaded = UIImage(data: data) else {
            failed = true
            return
        }
        currentAPIImage = currentReference.image
        image = loaded
    }

    private func openFullSize() async {
        guard let currentAPIImage else { return }
        opening = true
        defer { opening = false }
        if let data = try? await APIClient.shared.imageData(currentAPIImage),
           let fullImage = await Task.detached(priority: .userInitiated, operation: {
               UIImage.referencePreview(from: data, maxPixelSize: 4_096)
           }).value {
            action(fullImage, currentAPIImage)
            return
        }
        guard let refreshed = try? await APIClient.shared.generation(generationID),
              let currentReference = refreshed.references.first(where: { $0.image.id == reference.image.id })
                ?? refreshed.references.first(where: { $0.position == reference.position }),
              let data = try? await APIClient.shared.imageData(currentReference.image),
              let fullImage = await Task.detached(priority: .userInitiated, operation: {
                  UIImage.referencePreview(from: data, maxPixelSize: 4_096)
              }).value else {
            failed = true
            return
        }
        self.currentAPIImage = currentReference.image
        action(fullImage, currentReference.image)
    }
}

struct ZoomableImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let target: ZoomTarget
    let onUseAsReference: () -> Void
    var body: some View {
        NavigationStack {
            PannableZoomImage(image: target.image, accessibilityTitle: target.title)
            .background(.black)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black.opacity(0.82), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                if target.apiImage != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Als Referenz") { dismiss(); onUseAsReference() }
                    }
                }
            }
        }
    }
}

enum ZoomViewportGeometry {
    static func fittedSize(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
        let scale = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func centeringInsets(contentSize: CGSize, viewportSize: CGSize) -> UIEdgeInsets {
        UIEdgeInsets(
            top: max(0, (viewportSize.height - contentSize.height) / 2),
            left: max(0, (viewportSize.width - contentSize.width) / 2),
            bottom: max(0, (viewportSize.height - contentSize.height) / 2),
            right: max(0, (viewportSize.width - contentSize.width) / 2)
        )
    }
}

private final class ZoomScrollView: UIScrollView {
    var onLayout: ((ZoomScrollView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

private struct PannableZoomImage: UIViewRepresentable {
    let image: UIImage
    let accessibilityTitle: String
    var onSingleTap: (() -> Void)? = nil
    var onZoomChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = false
        scrollView.bounces = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.isDirectionalLockEnabled = false
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 1

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = accessibilityTitle
        imageView.accessibilityHint = "Mit zwei Fingern zoomen und das vergrößerte Bild mit einem Finger verschieben"
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped(_:)))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.scrollView = scrollView
        scrollView.onLayout = { [weak coordinator = context.coordinator] scrollView in
            guard let coordinator, let image = coordinator.imageView.image else { return }
            coordinator.layout(in: scrollView, imageSize: image.size, resetZoom: false)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        let imageChanged = context.coordinator.imageView.image !== image
        context.coordinator.imageView.image = image
        context.coordinator.imageView.accessibilityLabel = accessibilityTitle
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.layout(in: scrollView, imageSize: image.size, resetZoom: imageChanged)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        var onSingleTap: (() -> Void)?
        var onZoomChanged: ((Bool) -> Void)?
        private var lastBoundsSize: CGSize = .zero
        private var lastImageSize: CGSize = .zero
        private var reportedZoomed = false

        func layout(in scrollView: UIScrollView, imageSize: CGSize, resetZoom: Bool) {
            guard scrollView.bounds.size != .zero else { return }
            guard resetZoom || scrollView.bounds.size != lastBoundsSize || imageSize != lastImageSize else {
                updateInsets(in: scrollView)
                return
            }
            lastBoundsSize = scrollView.bounds.size
            lastImageSize = imageSize
            let wasZoomed = !resetZoom && scrollView.zoomScale > scrollView.minimumZoomScale
            let previousZoom = scrollView.zoomScale
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            let fittedSize = ZoomViewportGeometry.fittedSize(imageSize: imageSize, viewportSize: scrollView.bounds.size)
            imageView.transform = .identity
            imageView.frame = CGRect(origin: .zero, size: fittedSize)
            scrollView.contentSize = fittedSize
            if wasZoomed { scrollView.setZoomScale(previousZoom, animated: false) }
            updateInsets(in: scrollView)
            reportZoomState(scrollView)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updateInsets(in: scrollView)
            reportZoomState(scrollView)
        }

        private func reportZoomState(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            guard zoomed != reportedZoomed else { return }
            reportedZoomed = zoomed
            DispatchQueue.main.async { [weak self] in self?.onZoomChanged?(zoomed) }
        }

        private func updateInsets(in scrollView: UIScrollView) {
            scrollView.contentInset = ZoomViewportGeometry.centeringInsets(
                contentSize: scrollView.contentSize,
                viewportSize: scrollView.bounds.size
            )
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let point = recognizer.location(in: imageView)
            let targetScale: CGFloat = 2.5
            let size = CGSize(width: scrollView.bounds.width / targetScale, height: scrollView.bounds.height / targetScale)
            scrollView.zoom(to: CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            ), animated: true)
        }

        @objc func singleTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onSingleTap?()
        }
    }
}

#if DEBUG
struct GalleryZoomFixtureView: View {
    @State private var zoomed = false

    private let fixture: UIImage = {
        let size = CGSize(width: 900, height: 1_600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bands: [(UIColor, String)] = [
                (.systemTeal, "KOPF"),
                (.systemIndigo, "MITTE"),
                (.systemOrange, "FÜSSE"),
            ]
            let height = size.height / CGFloat(bands.count)
            for (index, band) in bands.enumerated() {
                band.0.setFill()
                context.fill(CGRect(x: 0, y: CGFloat(index) * height, width: size.width, height: height))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 92, weight: .black),
                    .foregroundColor: UIColor.white,
                ]
                let textSize = band.1.size(withAttributes: attributes)
                band.1.draw(
                    at: CGPoint(x: (size.width - textSize.width) / 2,
                                y: CGFloat(index) * height + (height - textSize.height) / 2),
                    withAttributes: attributes
                )
            }
        }
    }()

    var body: some View {
        ZStack(alignment: .top) {
            PannableZoomImage(
                image: fixture,
                accessibilityTitle: "Gestentestbild",
                onZoomChanged: { zoomed = $0 }
            )
            Text(zoomed ? "Zoom aktiv – Seitenwechsel gesperrt" : "An gewünschter Stelle aufziehen")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(.top, 18)
        }
        .background(.black)
    }
}

struct ReferenceZoomFixtureView: View {
    private let target: ZoomTarget = {
        let size = CGSize(width: 900, height: 1_200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemMint.setFill()
            context.fill(CGRect(x: 90, y: 120, width: 720, height: 960))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 76, weight: .black),
                .foregroundColor: UIColor.black,
            ]
            let text = "REFERENZBILD"
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
        return ZoomTarget(image: image, apiImage: nil, title: "Referenzbild")
    }()

    var body: some View {
        ZoomableImageViewer(target: target) {}
    }
}
#endif

private struct ActionButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    var prominent = false
    var loading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if loading { ProgressView().tint(prominent ? .black : .primary) }
                else { Image(systemName: symbol).font(.title3) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? .black : .primary)
        .background(prominent ? CDanceTheme.accent : CDanceTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .disabled(loading)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
