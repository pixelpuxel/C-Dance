import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct GeneratorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var references: [LocalReference] = []
    @State private var batchPickerItems: [PhotosPickerItem] = []
    @State private var batchInputs: [LocalReference] = []
    @State private var batchMode = false
    @State private var selectedTemplates: [PromptTemplate] = []
    @State private var freeText = ""
    @State private var finalPrompt = ""
    @State private var selectedModel = ""
    @State private var ratio = "auto"
    @State private var resolution = "720p"
    @State private var duration = 5
    @State private var generateAudio = true
    @State private var result: Generation?
    @State private var editingParent: Generation?
    @State private var markupContext: MarkupEditContext?
    @State private var showCamera = false
    @State private var showSeedreamLibrary = false
    @State private var generationStatus = ""
    @State private var submitting = false
    @State private var draftRestored = false
    @State private var restoringDraft = false
    @State private var showResetConfirmation = false
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var referenceToSave: LocalReference?
    @State private var referenceName = ""
    @State private var referenceZoomTarget: ZoomTarget?
    @State private var openingReferenceID: UUID?
    @State private var replacementPickerItem: PhotosPickerItem?
    @State private var referenceIDToReplace: UUID?
    @State private var showReplacementPicker = false
    @State private var draggedReferenceID: UUID?
    @FocusState private var promptFieldFocused: Bool

    private var model: ModelInfo? {
        store.models.first { $0.id == selectedModel } ?? store.models.first
    }

    private var canGenerate: Bool {
        store.dataLoaded
            && model != nil
            && !finalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!batchMode || (!batchInputs.isEmpty && references.count < (model?.maxReferenceImages ?? 10)))
            && !submitting
    }

    private var commonReferenceLimit: Int {
        max(0, (model?.maxReferenceImages ?? 10) - (batchMode ? 1 : 0))
    }

    private var saveReferenceAlertPresented: Binding<Bool> {
        Binding(
            get: { referenceToSave != nil },
            set: { presented in
                if !presented { referenceToSave = nil }
            }
        )
    }

    var body: some View { presentationContent }

    private var navigationContent: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if horizontalSizeClass == .regular, geometry.size.width >= 800 {
                            HStack(alignment: .top, spacing: 18) {
                                LazyVStack(spacing: 16) {
                                    statusNotices
                                    referencesCard
                                    promptCard
                                    if editingParent == nil { batchCard }
                                }
                                .frame(maxWidth: 720)
                                LazyVStack(spacing: 16) {
                                    outputCard
                                }
                                .frame(minWidth: 280, maxWidth: 360)
                            }
                            .frame(maxWidth: 1_100, alignment: .top)
                        } else {
                            LazyVStack(spacing: 16) {
                                statusNotices
                                referencesCard
                                promptCard
                                if editingParent == nil { batchCard }
                                outputCard
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                .background(CDanceTheme.background)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(editingParent == nil ? "Film erstellen" : "Film bearbeiten")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Entwurf leeren", systemImage: "trash", role: .destructive) {
                            showResetConfirmation = true
                        }
                        Button("Verlauf öffnen", systemImage: "film.stack") { store.selectedTab = 1 }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Weitere Aktionen")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { promptFieldFocused = false }
                }
            }
            .safeAreaInset(edge: .bottom) { generateBar }
        }
    }

    @ViewBuilder private var statusNotices: some View {
        if !store.dataLoaded { generatorLoadingNotice }
        if store.providerConfiguration?.configured != true { setupNotice }
        if store.activeGenerationCount > 0 { queueNotice }
        if let editingParent { editNotice(editingParent) }
    }

    private var generatorLoadingNotice: some View {
        HStack(spacing: 12) {
            if store.isRefreshing || store.syncError == nil {
                ProgressView()
            } else {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(store.syncError == nil ? "Einstellungen werden geladen" : "Serverdaten fehlen")
                    .font(.headline)
                Text(store.syncError == nil ? "Dein Entwurf bleibt erhalten und ist gleich vollständig nutzbar." : "Bitte erneut verbinden; dein Entwurf bleibt erhalten.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if store.syncError != nil {
                Button("Erneut") { Task { await store.reload() } }.font(.subheadline.weight(.semibold))
            }
        }
        .padding(14)
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var dialogsContent: some View {
        navigationContent
        .confirmationDialog("Entwurf wirklich leeren?", isPresented: $showResetConfirmation) {
            Button("Entwurf leeren", role: .destructive) { resetDraft() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Referenzbilder, Prompt und Ausgabeeinstellungen werden zurückgesetzt.")
        }
        .alert("Referenzbild speichern", isPresented: saveReferenceAlertPresented) {
            TextField("Name, z. B. Gesicht Frau", text: $referenceName)
            Button("Speichern") { Task { await saveReferenceShortcut() } }
                .disabled(referenceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Abbrechen", role: .cancel) { referenceToSave = nil }
        } message: {
            Text("Das Bild steht danach dauerhaft als Schnellwahl bereit.")
        }
    }

    private var observedContent: some View {
        dialogsContent
        .onAppear {
            restoreDraft()
            if selectedModel.isEmpty, let first = store.models.first {
                selectedModel = first.id
                resolution = first.defaultSize
            }
            consumeRequests()
        }
        .onDisappear { saveDraftNow() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveDraftNow() } }
        .onChange(of: store.pendingEdit?.id) { _, _ in consumeRequests() }
        .onChange(of: store.pendingReference?.id) { _, _ in consumeRequests() }
        .onChange(of: store.pendingSetup?.id) { _, _ in consumeRequests() }
        .onChange(of: store.pendingMergedSetup?.id) { _, _ in consumeRequests() }
        .onChange(of: store.pendingSharedReferences.count) { _, _ in consumeRequests() }
    }

    private var dataObservedContent: some View {
        observedContent
        .onChange(of: store.dataLoaded) { _, loaded in
            guard loaded else { return }
            restoreDraft()
            if selectedModel.isEmpty, let first = store.models.first {
                selectedModel = first.id
                resolution = first.defaultSize
            }
        }
        .onChange(of: pickerItems) { _, items in loadPickerItems(items) }
        .onChange(of: batchPickerItems) { _, items in loadBatchPickerItems(items) }
        .onChange(of: selectedTemplates) { _, _ in if !restoringDraft { compose(); scheduleDraftSave() } }
        .onChange(of: freeText) { _, _ in if !restoringDraft { compose(); scheduleDraftSave() } }
        .onChange(of: finalPrompt) { _, _ in scheduleDraftSave() }
    }

    private var draftObservedContent: some View {
        dataObservedContent
        .onChange(of: selectedModel) { _, newModel in updateOutputOptions(for: newModel); scheduleDraftSave() }
        .onChange(of: ratio) { _, _ in scheduleDraftSave() }
        .onChange(of: resolution) { _, _ in scheduleDraftSave() }
        .onChange(of: references.map(\.id)) { _, _ in scheduleDraftSave() }
        .onChange(of: editingParent?.id) { _, _ in scheduleDraftSave() }
    }

    private var presentationContent: some View {
        draftObservedContent
        .fullScreenCover(item: $referenceZoomTarget) { target in
            ZoomableImageViewer(target: target) {}
        }
        .sheet(item: $result) { generation in
            ResultView(
                generation: generation,
                onEdit: { image in startEdit(generation, image: image) },
                onReference: { image, preview in
                    references.append(LocalReference(remote: image, preview: preview))
                    result = nil
                }
            )
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in addReference(image) }
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showSeedreamLibrary) {
            SeedreamLibraryPicker(remainingCapacity: max(0, commonReferenceLimit - references.count)) { reference in
                guard references.count < commonReferenceLimit else { return }
                references.append(reference)
            }
        }
        .sheet(item: $markupContext) { context in
            MarkupEditorView(image: context.image) { data, instruction in
                applyMarkup(data, instruction: instruction, replacing: context.referenceID)
            }
        }
        .photosPicker(isPresented: $showReplacementPicker, selection: $replacementPickerItem, matching: .images)
        .onChange(of: replacementPickerItem) { _, item in replaceReference(with: item) }
    }

    private var setupNotice: some View {
        Button { store.selectedTab = 3 } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(.orange.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("C-Dance einrichten").font(.headline)
                    Text("API-Key sicher in den Einstellungen hinterlegen")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Öffnet die Einstellungen")
    }

    private var queueNotice: some View {
        Button { store.selectedTab = 1 } label: {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.activeGenerationCount == 1 ? "1 Film wird erstellt" : "\(store.activeGenerationCount) Filme werden erstellt")
                        .font(.headline)
                    Text("Du kannst weitere Aufträge hinzufügen.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(CDanceTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Öffnet den Verlauf mit allen laufenden Aufträgen")
    }

    private func editNotice(_ parent: Generation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars").font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bearbeitungsmodus").font(.headline)
                Text("Ausgangsbild \(parent.id.prefix(8))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Beenden") {
                editingParent = nil
                references.removeAll()
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private var referencesCard: some View {
        GeneratorCard(
            title: "Referenzbilder",
            subtitle: referenceSubtitle,
            symbol: "photo.on.rectangle.angled",
            headerAction: {
                store.selectedLibrarySection = .references
                store.selectedTab = 2
            }
        ) {
            if !store.referenceAssets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Schnellwahl").font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(store.referenceAssets) { asset in
                                SavedReferenceChip(asset: asset) { preview in
                                    guard references.count < commonReferenceLimit else { return }
                                    references.append(LocalReference(remote: asset.image, preview: preview))
                                } onDelete: {
                                    Task { await deleteReferenceShortcut(asset) }
                                }
                            }
                        }
                    }
                }
            }
            if references.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Bilder steuern Motiv, Stil und Komposition.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 92)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(references.enumerated()), id: \.element.id) { index, item in
                            referenceTile(item, index: index)
                                .onDrag {
                                    draggedReferenceID = item.id
                                    return NSItemProvider(object: item.id.uuidString as NSString)
                                }
                                .onDrop(
                                    of: [UTType.text],
                                    delegate: ReferenceReorderDropDelegate(
                                        targetID: item.id,
                                        references: $references,
                                        draggedReferenceID: $draggedReferenceID
                                    )
                                )
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: commonReferenceLimit, matching: .images) {
                    Label(references.isEmpty ? "Fotos" : "Weitere", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(CDanceTheme.accent)
                .foregroundStyle(.black)

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: {
                        Label("Kamera", systemImage: "camera")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if AppModeConfiguration.mode == .server {
                Button { showSeedreamLibrary = true } label: {
                    Label("Seedream Online durchsuchen", systemImage: "sparkles.rectangle.stack")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .disabled(references.count >= commonReferenceLimit)
                .accessibilityHint("Zeigt fertige Bilder aus deiner Seedream-Online-Bibliothek")
            }
        }
        .dropDestination(for: Data.self) { items, _ in
            for data in items {
                if let image = UIImage(data: data) { addReference(image) }
            }
            return !items.isEmpty
        }
    }

    private var batchCard: some View {
        GeneratorCard(
            title: "Batch-Modus",
            subtitle: batchMode ? "Ein gemeinsames Setup · mehrere Aufträge" : "Dasselbe Setup auf mehrere Bilder anwenden",
            symbol: "rectangle.stack.badge.plus"
        ) {
            Toggle(isOn: $batchMode) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mehrere Ausgangsbilder").font(.subheadline.weight(.semibold))
                    Text("Jedes Bild wird als eigener Auftrag in die Warteschlange gestellt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(CDanceTheme.accent)
            .onChange(of: batchMode) { _, enabled in
                if !enabled { batchInputs.removeAll(); batchPickerItems.removeAll() }
            }

            if batchMode {
                if batchInputs.isEmpty {
                    ContentUnavailableView(
                        "Batch-Bilder auswählen",
                        systemImage: "photo.stack",
                        description: Text("Prompt, Referenzen und Ausgabeeinstellungen oben gelten anschließend für jedes Bild.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 112)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(batchInputs.enumerated()), id: \.element.id) { index, item in
                                batchInputTile(item, index: index)
                            }
                        }
                    }
                }

                PhotosPicker(selection: $batchPickerItems, maxSelectionCount: 20, matching: .images) {
                    Label(batchInputs.isEmpty ? "Batch-Bilder wählen" : "Weitere Batch-Bilder", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(CDanceTheme.accent)
                .foregroundStyle(.black)

                if references.count >= (model?.maxReferenceImages ?? 10) {
                    Label("Bitte eine normale Referenz entfernen, damit jedes Batch-Bild noch Platz hat.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if !batchInputs.isEmpty {
                    Text("Es entstehen \(batchInputs.count) einzelne Aufträge. Das jeweilige Batch-Bild steht an erster Stelle, danach folgen die \(references.count) Referenzbilder des Setups.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func batchInputTile(_ item: LocalReference, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                let fullImage = item.data.flatMap(UIImage.init(data:)) ?? item.preview
                referenceZoomTarget = ZoomTarget(image: fullImage, apiImage: nil, title: "Batch-Bild \(index + 1)")
            } label: {
                Image(uiImage: item.preview)
                    .resizable().scaledToFill()
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .bottomLeading) {
                        Text("\(index + 1)")
                            .font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(7)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Batch-Bild \(index + 1) vergrößern")

            Button {
                batchInputs.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.7))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Batch-Bild \(index + 1) entfernen")
        }
    }

    private var referenceSubtitle: String {
        let maximum = commonReferenceLimit
        if batchMode {
            return references.isEmpty ? "Optional · bis zu \(maximum) gemeinsame Referenzen" : "\(references.count) von \(maximum) gemeinsamen Referenzen"
        }
        return references.isEmpty ? "Optional · bis zu \(maximum) Bilder" : "\(references.count) von \(maximum) ausgewählt"
    }

    private func referenceTile(_ item: LocalReference, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { openReference(item, index: index) } label: {
                Image(uiImage: item.preview)
                    .resizable().scaledToFill()
                    .frame(width: 116, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .bottomLeading) {
                        Text("\(index + 1)")
                            .font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(7)
                    }
                    .overlay {
                        if openingReferenceID == item.id {
                            Color.black.opacity(0.28)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            ProgressView().tint(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Referenzbild \(index + 1) vergrößern")
            .accessibilityHint("Öffnet das Bild groß mit Zoomfunktion")

            Menu {
                Button("Markieren", systemImage: "pencil.and.outline") {
                    beginMarkingReference(item)
                }
                Button("Nach links", systemImage: "arrow.left") { move(index, -1) }
                    .disabled(index == 0)
                Button("Nach rechts", systemImage: "arrow.right") { move(index, 1) }
                    .disabled(index == references.count - 1)
                Button("In Schnellwahl speichern", systemImage: "star") {
                    referenceName = ""
                    referenceToSave = item
                }
                Button("Ersetzen", systemImage: "arrow.triangle.2.circlepath") {
                    beginReplacingReference(item)
                }
                Divider()
                Button("Entfernen", systemImage: "trash", role: .destructive) { references.remove(at: index) }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Referenzbild \(index + 1) bearbeiten")
        }
        .contextMenu {
            Button("Markieren") { beginMarkingReference(item) }
            Button("Nach links") { move(index, -1) }.disabled(index == 0)
            Button("Nach rechts") { move(index, 1) }.disabled(index == references.count - 1)
            Button("In Schnellwahl speichern") {
                referenceName = ""
                referenceToSave = item
            }
            Button("Ersetzen") { beginReplacingReference(item) }
            Button("Entfernen", role: .destructive) { references.remove(at: index) }
        }
    }

    private func beginReplacingReference(_ reference: LocalReference) {
        referenceIDToReplace = reference.id
        replacementPickerItem = nil
        showReplacementPicker = true
    }

    private func replaceReference(with item: PhotosPickerItem?) {
        guard let item, let referenceIDToReplace else { return }
        Task {
            defer {
                replacementPickerItem = nil
                self.referenceIDToReplace = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let normalized = UIImage.cdanceUploadJPEG(from: data),
                      let preview = UIImage.referencePreview(from: normalized) else {
                    store.error = "Das ausgewählte Bild konnte nicht geladen werden."
                    return
                }
                let replacement = LocalReference(data: normalized, preview: preview)
                references = ReferenceReplacementPlanner.replacing(
                    referenceID: referenceIDToReplace,
                    with: replacement,
                    in: references
                )
            } catch {
                store.error = error.localizedDescription
            }
        }
    }

    private func openReference(_ item: LocalReference, index: Int) {
        if let data = item.data, let image = UIImage(data: data) {
            referenceZoomTarget = ZoomTarget(image: image, apiImage: nil, title: "Referenzbild \(index + 1)")
            return
        }

        guard let remote = item.remote else {
            referenceZoomTarget = ZoomTarget(image: item.preview, apiImage: nil, title: "Referenzbild \(index + 1)")
            return
        }

        openingReferenceID = item.id
        Task {
            let data = try? await APIClient.shared.imageData(remote)
            let image = data.flatMap(UIImage.init(data:)) ?? item.preview
            openingReferenceID = nil
            referenceZoomTarget = ZoomTarget(image: image, apiImage: nil, title: "Referenzbild \(index + 1)")
        }
    }

    private var promptCard: some View {
        GeneratorCard(title: "Bildbeschreibung", subtitle: "Bausteine kombinieren und frei ergänzen", symbol: "text.quote") {
            if store.prompts.isEmpty {
                Button { store.selectedTab = 2 } label: {
                    Label("Ersten Prompt-Baustein anlegen", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.prompts) { prompt in
                            templateChip(prompt)
                        }
                    }
                }
            }

            if !selectedTemplates.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(selectedTemplates.enumerated()), id: \.element.id) { index, prompt in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .frame(width: 24, height: 24)
                                .background(CDanceTheme.accent.opacity(0.2), in: Circle())
                            Text(prompt.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            Menu {
                                Button("Nach oben", systemImage: "arrow.up") { moveTemplate(index, -1) }.disabled(index == 0)
                                Button("Nach unten", systemImage: "arrow.down") { moveTemplate(index, 1) }.disabled(index == selectedTemplates.count - 1)
                                Button("Entfernen", systemImage: "xmark", role: .destructive) { selectedTemplates.remove(at: index) }
                            } label: {
                                Image(systemName: "line.3.horizontal").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("\(prompt.name) umsortieren")
                        }
                        if index < selectedTemplates.count - 1 { Divider().padding(.leading, 34) }
                    }
                }
                .padding(.horizontal, 10)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Eigene Anweisung").font(.subheadline.weight(.semibold))
                TextField("Was soll entstehen oder verändert werden?", text: $freeText, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($promptFieldFocused)
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            DisclosureGroup {
                TextEditor(text: $finalPrompt)
                    .focused($promptFieldFocused)
                    .frame(minHeight: 150)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Zusammengesetzter finaler Prompt")
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Finalen Prompt prüfen").font(.subheadline.weight(.semibold))
                        Text("Vor dem Senden frei bearbeitbar").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .tint(.primary)
        }
    }

    private func templateChip(_ prompt: PromptTemplate) -> some View {
        let selected = selectedTemplates.contains(prompt)
        return Button {
            if let index = selectedTemplates.firstIndex(of: prompt) {
                selectedTemplates.remove(at: index)
            } else {
                selectedTemplates.append(prompt)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : (prompt.favorite ? "star.fill" : "circle"))
                Text(prompt.name).lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).frame(minHeight: 38)
            .foregroundStyle(selected ? .black : .primary)
            .background(selected ? CDanceTheme.accent : Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Ausgewählt" : "Nicht ausgewählt")
    }

    private var outputCard: some View {
        GeneratorCard(title: "Ausgabe", subtitle: "Modell, Laufzeit, Format und Qualität", symbol: "slider.horizontal.3") {
            outputRow("Modell", icon: "cpu") {
                Picker("Modell", selection: $selectedModel) {
                    ForEach(store.models) { Text($0.name).tag($0.id) }
                }.labelsHidden()
            }
            Divider()
            outputRow("Format", icon: "aspectratio") {
                Picker("Format", selection: $ratio) {
                    ForEach(model?.aspectRatios ?? ["auto"], id: \.self) {
                        Text($0 == "auto" ? "Smart / Auto" : $0).tag($0)
                    }
                }.labelsHidden()
            }
            Divider()
            outputRow("Auflösung", icon: "sparkles.rectangle.stack") {
                Picker("Auflösung", selection: $resolution) {
                    ForEach(model?.sizes ?? ["720p"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            Divider()
            outputRow("Laufzeit", icon: "timer") {
                Picker("Laufzeit", selection: $duration) {
                    ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0) Sek.").tag($0) }
                }.labelsHidden()
            }
            Divider()
            Toggle(isOn: $generateAudio) {
                Label("Ton erzeugen", systemImage: "speaker.wave.2")
            }
        }
    }

    private func outputRow<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            Text(title)
            Spacer()
            content().pickerStyle(.menu).tint(.primary)
        }
        .frame(minHeight: 44)
    }

    private var generateBar: some View {
        VStack(spacing: 7) {
            if !generationStatus.isEmpty {
                HStack(spacing: 7) {
                    if submitting { ProgressView().controlSize(.small) }
                    Image(systemName: submitting ? "arrow.up.circle" : "checkmark.circle.fill")
                        .foregroundStyle(submitting ? Color.secondary : Color.green)
                    Text(generationStatus).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Button { Task { await generate() } } label: {
                HStack {
                    Image(systemName: batchMode ? "rectangle.stack.badge.plus" : (editingParent == nil ? "sparkles" : "wand.and.stars"))
                    Text(generateButtonTitle)
                    Spacer()
                    if store.activeGenerationCount > 0 {
                        Text("+ Warteschlange").font(.caption.weight(.semibold))
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canGenerate ? .black : .secondary)
            .background(canGenerate ? CDanceTheme.accent : Color(uiColor: .systemGray4), in: RoundedRectangle(cornerRadius: 16))
            .disabled(!canGenerate)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(.bar)
    }

    private var generateButtonTitle: String {
        if batchMode {
            return batchInputs.isEmpty ? "Batch-Bilder auswählen" : "\(batchInputs.count) Bilder einreihen"
        }
        return editingParent == nil ? "Film erstellen" : "Änderung erstellen"
    }

    private func compose() {
        finalPrompt = (selectedTemplates.map(\.text) + ([freeText].filter { !$0.isEmpty })).joined(separator: "\n\n")
    }

    private func move(_ index: Int, _ delta: Int) {
        let destination = index + delta
        guard references.indices.contains(destination) else { return }
        references.swapAt(index, destination)
    }

    private func moveTemplate(_ index: Int, _ delta: Int) {
        let destination = index + delta
        guard selectedTemplates.indices.contains(destination) else { return }
        selectedTemplates.swapAt(index, destination)
        compose()
    }

    private func generate() async {
        guard store.providerConfiguration?.configured == true else { store.selectedTab = 3; return }
        promptFieldFocused = false
        submitting = true
        let groups = BatchGenerationPlanner.referenceGroups(
            batchMode: batchMode,
            batchInputs: batchInputs,
            commonReferences: references
        )
        var submitted = 0
        var submittedBatchIDs: Set<UUID> = []
        var failures: [String] = []

        for (index, group) in groups.enumerated() {
            generationStatus = groups.count == 1
                ? "Referenzen werden hochgeladen …"
                : "Auftrag \(index + 1) von \(groups.count) wird eingereiht …"
            do {
                let generation = try await APIClient.shared.generate(
                    prompt: freeText,
                    finalPrompt: finalPrompt,
                    templateIDs: selectedTemplates.map(\.id),
                    references: group,
                    model: selectedModel,
                    ratio: ratio,
                    resolution: resolution,
                    duration: duration,
                    generateAudio: generateAudio,
                    parentID: editingParent?.id
                )
                store.monitor(generation)
                submitted += 1
                if batchMode, batchInputs.indices.contains(index) {
                    submittedBatchIDs.insert(batchInputs[index].id)
                }
            } catch {
                failures.append("Film \(index + 1): \(error.localizedDescription)")
            }
        }

        submitting = false
        if batchMode, submitted > 0 {
            batchInputs.removeAll { submittedBatchIDs.contains($0.id) }
            batchPickerItems.removeAll()
        }
        if failures.isEmpty {
            generationStatus = submitted == 1 ? "In die Warteschlange gestellt" : "\(submitted) Aufträge in die Warteschlange gestellt"
        } else {
            generationStatus = submitted == 0 ? "Batch konnte nicht gestartet werden" : "\(submitted) von \(groups.count) Aufträgen eingereiht"
            store.error = failures.joined(separator: "\n")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !submitting { generationStatus = "" }
        }
    }

    private func startEdit(_ generation: Generation, image: UIImage) {
        guard let apiImage = generation.resultImage else { return }
        editingParent = generation
        batchMode = false
        batchInputs.removeAll()
        batchPickerItems.removeAll()
        let source = LocalReference(remote: apiImage, preview: image)
        references = [source]
        selectedTemplates = []
        freeText = ""
        finalPrompt = ""
        result = nil
        markupContext = MarkupEditContext(image: image, referenceID: source.id)
    }

    private func beginMarkingReference(_ reference: LocalReference) {
        openingReferenceID = reference.id
        Task {
            let image: UIImage
            if let data = reference.data, let localImage = UIImage(data: data) {
                image = localImage
            } else if let remote = reference.remote,
                      let data = try? await APIClient.shared.imageData(remote),
                      let remoteImage = UIImage(data: data) {
                image = remoteImage
            } else {
                image = reference.preview
            }
            openingReferenceID = nil
            markupContext = MarkupEditContext(image: image, referenceID: reference.id)
        }
    }

    private func applyMarkup(_ data: Data, instruction: String, replacing referenceID: UUID) {
        guard let preview = UIImage(data: data),
              let index = references.firstIndex(where: { $0.id == referenceID }) else { return }
        references[index] = LocalReference(data: data, preview: preview)
        let cleanInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanInstruction.isEmpty { freeText = cleanInstruction }
        scheduleDraftSave()
    }

    private func consumeRequests() {
        if let request = store.pendingEdit {
            store.pendingEdit = nil
            startEdit(request.generation, image: request.image)
        }
        if let request = store.pendingReference {
            store.pendingReference = nil
            if request.startsNewDraft {
                startNewDraft(with: request)
            } else if references.count < commonReferenceLimit {
                references.append(LocalReference(remote: request.image, preview: request.preview))
            }
        }
        if let request = store.pendingSetup {
            store.pendingSetup = nil
            Task { await applySetup(request.generation) }
        }
        if let request = store.pendingMergedSetup {
            store.pendingMergedSetup = nil
            Task { await applyMergedSetup(request) }
        }
        if !store.pendingSharedReferences.isEmpty {
            references = SharedReferenceImport.prepend(
                store.pendingSharedReferences,
                to: references,
                limit: commonReferenceLimit
            )
            store.pendingSharedReferences.removeAll()
        }
    }

    private func startNewDraft(with request: ReferenceRequest) {
        restoringDraft = true
        references = [LocalReference(remote: request.image, preview: request.preview)]
        selectedTemplates = []
        freeText = ""
        finalPrompt = ""
        batchMode = false
        batchInputs.removeAll()
        batchPickerItems.removeAll()
        editingParent = nil
        result = nil
        markupContext = nil
        ratio = "auto"
        if let first = store.models.first {
            selectedModel = first.id
            resolution = first.defaultSize
        }
        restoringDraft = false
        scheduleDraftSave()
    }

    private func applySetup(_ original: Generation) async {
        let source = (try? await APIClient.shared.generation(original.id)) ?? original
        restoringDraft = true
        editingParent = nil
        selectedModel = source.model
        ratio = source.aspectRatio
        resolution = source.resolution
        freeText = source.prompt
        selectedTemplates = source.promptTemplates
            .sorted { $0.position < $1.position }
            .compactMap { snapshot in
                guard let id = snapshot.id else { return nil }
                return store.prompts.first { $0.id == id }
            }

        var restoredReferences: [LocalReference] = []
        for reference in source.references.sorted(by: { $0.position < $1.position }) {
            do {
                let data = try await APIClient.shared.thumbnailData(reference.image)
                if let preview = UIImage(data: data) {
                    restoredReferences.append(LocalReference(remote: reference.image, preview: preview))
                }
            } catch {
                // Keep restoring the remaining references and report one actionable message below.
            }
        }
        references = restoredReferences
        finalPrompt = source.finalPrompt
        await Task.yield()
        finalPrompt = source.finalPrompt
        restoringDraft = false
        scheduleDraftSave()
        if restoredReferences.count != source.references.count {
            store.error = "Nicht alle Referenzbilder konnten geladen werden. Bitte öffne den Auftrag erneut und versuche es noch einmal."
        }
    }

    private func applyMergedSetup(_ request: MergedSetupRequest) async {
        restoringDraft = true
        editingParent = nil
        batchMode = false
        batchInputs.removeAll()
        batchPickerItems.removeAll()
        selectedTemplates = []
        selectedModel = request.model
        ratio = request.aspectRatio
        resolution = request.resolution
        freeText = request.prompt
        finalPrompt = request.prompt

        var restoredReferences: [LocalReference] = []
        for image in request.references.prefix(model?.maxReferenceImages ?? 10) {
            if let data = try? await APIClient.shared.thumbnailData(image),
               let preview = UIImage(data: data) {
                restoredReferences.append(LocalReference(remote: image, preview: preview))
            }
        }
        references = restoredReferences
        await Task.yield()
        finalPrompt = request.prompt
        restoringDraft = false
        scheduleDraftSave()
        if restoredReferences.count != request.references.count {
            store.error = "Nicht alle ausgewählten Referenzbilder konnten geladen werden."
        }
    }

    private func addReference(_ image: UIImage) {
        guard references.count < commonReferenceLimit,
              let data = image.jpegData(compressionQuality: 0.94) else { return }
        references.append(LocalReference(data: data, preview: UIImage.referencePreview(from: data) ?? image))
    }

    private func saveReferenceShortcut() async {
        guard let referenceToSave else { return }
        let name = referenceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let saved = try await APIClient.shared.saveReferenceAsset(name: name, reference: referenceToSave)
            store.referenceAssets.insert(saved, at: 0)
            self.referenceToSave = nil
            referenceName = ""
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func deleteReferenceShortcut(_ asset: ReferenceAsset) async {
        do {
            try await APIClient.shared.deleteReferenceAsset(asset.id)
            store.referenceAssets.removeAll { $0.id == asset.id }
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func loadPickerItems(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   references.count < commonReferenceLimit,
                   let normalized = UIImage.cdanceUploadJPEG(from: data),
                   let preview = UIImage.referencePreview(from: normalized) {
                    references.append(LocalReference(data: normalized, preview: preview))
                }
            }
            pickerItems = []
        }
    }

    private func loadBatchPickerItems(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                guard batchInputs.count < 20 else { break }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let normalized = UIImage.cdanceUploadJPEG(from: data),
                   let preview = UIImage.referencePreview(from: normalized) {
                    batchInputs.append(LocalReference(data: normalized, preview: preview))
                }
            }
            batchPickerItems = []
        }
    }

    private func updateOutputOptions(for modelID: String) {
        guard let selected = store.models.first(where: { $0.id == modelID }) else { return }
        if !selected.sizes.contains(resolution) { resolution = selected.defaultSize }
        if !selected.aspectRatios.contains(ratio) { ratio = selected.aspectRatios.first ?? "auto" }
    }

    private func resetDraft() {
        references = []
        selectedTemplates = []
        freeText = ""
        finalPrompt = ""
        editingParent = nil
        batchMode = false
        batchInputs.removeAll()
        batchPickerItems.removeAll()
        ratio = "auto"
        if let first = store.models.first {
            selectedModel = first.id
            resolution = first.defaultSize
        }
        saveDraftNow()
    }

    private func restoreDraft() {
        guard !draftRestored, store.dataLoaded else { return }
        draftRestored = true
        guard let draft = GeneratorDraftStore.load(for: store.mode) else { return }
        restoringDraft = true
        references = draft.references.compactMap { reference in
            guard let preview = UIImage(data: reference.previewData) else { return nil }
            return LocalReference(data: reference.data, remote: reference.remote, preview: preview)
        }
        selectedTemplates = draft.selectedTemplateIDs.compactMap { id in store.prompts.first { $0.id == id } }
        freeText = draft.freeText
        finalPrompt = draft.finalPrompt
        selectedModel = draft.selectedModel
        ratio = draft.ratio
        resolution = draft.resolution
        editingParent = draft.editingParent
        Task { @MainActor in
            await Task.yield()
            finalPrompt = draft.finalPrompt
            restoringDraft = false
        }
    }

    private func scheduleDraftSave() {
        guard draftRestored else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            saveDraftNow()
        }
    }

    private func saveDraftNow() {
        guard draftRestored else { return }
        draftSaveTask?.cancel()
        let savedReferences = references.compactMap { reference -> GeneratorDraft.Reference? in
            guard let previewData = reference.preview.jpegData(compressionQuality: 0.82) else { return nil }
            return .init(data: reference.data, remote: reference.remote, previewData: previewData)
        }
        GeneratorDraftStore.save(.init(
            references: savedReferences,
            selectedTemplateIDs: selectedTemplates.map(\.id),
            freeText: freeText,
            finalPrompt: finalPrompt,
            selectedModel: selectedModel,
            ratio: ratio,
            resolution: resolution,
            editingParent: editingParent
        ), for: store.mode)
    }
}

enum SharedReferenceImport {
    static func prepend(_ incoming: [LocalReference], to existing: [LocalReference], limit: Int) -> [LocalReference] {
        guard limit > 0 else { return [] }
        return Array((incoming + existing).prefix(limit))
    }
}

enum BatchGenerationPlanner {
    static func referenceGroups(
        batchMode: Bool,
        batchInputs: [LocalReference],
        commonReferences: [LocalReference]
    ) -> [[LocalReference]] {
        guard batchMode else { return [commonReferences] }
        return batchInputs.map { [$0] + commonReferences }
    }
}

enum ReferenceReplacementPlanner {
    static func replacing(
        referenceID: UUID,
        with replacement: LocalReference,
        in references: [LocalReference]
    ) -> [LocalReference] {
        guard let index = references.firstIndex(where: { $0.id == referenceID }) else { return references }
        var updated = references
        updated[index] = replacement
        return updated
    }
}

enum ReferenceOrderPlanner {
    static func moving(
        referenceID: UUID,
        toward targetID: UUID,
        in references: [LocalReference]
    ) -> [LocalReference] {
        guard referenceID != targetID,
              let sourceIndex = references.firstIndex(where: { $0.id == referenceID }),
              let targetIndex = references.firstIndex(where: { $0.id == targetID }) else { return references }
        var updated = references
        updated.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        )
        return updated
    }
}

private struct ReferenceReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var references: [LocalReference]
    @Binding var draggedReferenceID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedReferenceID, draggedReferenceID != targetID else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            references = ReferenceOrderPlanner.moving(
                referenceID: draggedReferenceID,
                toward: targetID,
                in: references
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedReferenceID = nil
        return true
    }
}

private struct SavedReferenceChip: View {
    let asset: ReferenceAsset
    let onSelect: (UIImage) -> Void
    let onDelete: () -> Void
    @State private var preview: UIImage?
    @State private var failed = false

    var body: some View {
        Button {
            if let preview { onSelect(preview) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color(uiColor: .tertiarySystemGroupedBackground)
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFill()
                    } else if failed {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 82, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(asset.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(width: 82, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .disabled(preview == nil)
        .contextMenu {
            Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityLabel("Gespeichertes Referenzbild \(asset.name)")
        .accessibilityHint("Fügt das Bild als Referenz hinzu")
        .task(id: asset.image.downloadURL) {
            do {
                let data = try await APIClient.shared.thumbnailData(asset.image, maxSize: 256)
                preview = UIImage(data: data)
                failed = preview == nil
            } catch {
                failed = true
            }
        }
    }
}

private struct SeedreamLibraryPicker: View {
    @Environment(\.dismiss) private var dismiss
    let remainingCapacity: Int
    let onSelect: (LocalReference) -> Void

    @State private var query = ""
    @State private var items: [SeedreamLibraryItem] = []
    @State private var total = 0
    @State private var loading = true
    @State private var importingIDs: Set<String> = []
    @State private var selectedIDs: Set<String> = []
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 170), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if loading && items.isEmpty {
                    ProgressView("Seedream-Bilder werden geladen …")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, items.isEmpty {
                    ContentUnavailableView(
                        "Bibliothek nicht erreichbar",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(items) { item in
                                Button { select(item) } label: {
                                    SeedreamLibraryTile(
                                        item: item,
                                        selected: selectedIDs.contains(item.id),
                                        importing: importingIDs.contains(item.id)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(importingIDs.contains(item.id) || selectedIDs.count >= remainingCapacity)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .background(CDanceTheme.background)
            .navigationTitle("Seedream Online")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Prompt durchsuchen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Text("\(selectedIDs.count)/\(remainingCapacity)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: query) {
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let page = try await APIClient.shared.seedreamLibrary(query: query)
            guard !Task.isCancelled else { return }
            items = page.items
            total = page.total
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func select(_ item: SeedreamLibraryItem) {
        guard !selectedIDs.contains(item.id), selectedIDs.count < remainingCapacity else { return }
        importingIDs.insert(item.id)
        Task {
            do {
                let image = try await APIClient.shared.importSeedreamImage(item.sourceImageID)
                let data = try await APIClient.shared.thumbnailData(image, maxSize: 512)
                guard let preview = UIImage(data: data) else { throw APIClientError.invalidImage }
                selectedIDs.insert(item.id)
                onSelect(LocalReference(remote: image, preview: preview))
            } catch {
                errorMessage = error.localizedDescription
            }
            importingIDs.remove(item.id)
        }
    }
}

private struct SeedreamLibraryTile: View {
    let item: SeedreamLibraryItem
    let selected: Bool
    let importing: Bool
    @State private var preview: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Color(uiColor: .tertiarySystemGroupedBackground)
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    ProgressView()
                }
                if importing {
                    ProgressView().padding(7).background(.ultraThinMaterial, in: Circle()).padding(6)
                } else if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2).foregroundStyle(.black, CDanceTheme.accent)
                        .padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            Text(item.finalPrompt.isEmpty ? "Ohne Prompt" : item.finalPrompt)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(selected ? "Seedream-Bild ausgewählt" : "Seedream-Bild auswählen")
        .task(id: item.image.downloadURL) {
            guard let data = try? await APIClient.shared.thumbnailData(item.image, maxSize: 320) else { return }
            preview = UIImage(data: data)
        }
    }
}

private struct GeneratorCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let headerAction: (() -> Void)?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, symbol: String, headerAction: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.headerAction = headerAction
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(CDanceTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let headerAction {
                    Button(action: headerAction) {
                        Image(systemName: "photo.stack")
                            .font(.headline)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Referenzbild-Bibliothek öffnen")
                }
            }
            content
        }
        .padding(16)
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct CameraPicker: UIViewControllerRepresentable {
    let completion: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage) -> Void
        init(_ completion: @escaping (UIImage) -> Void) { self.completion = completion }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { completion(image) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}
