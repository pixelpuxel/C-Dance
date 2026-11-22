import SwiftUI
import PhotosUI

struct PromptLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: PromptTemplate?
    @State private var creating = false
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var referencePickerItem: PhotosPickerItem?
    @State private var referenceEditor: ReferenceEditorContext?
    @State private var referenceToDelete: ReferenceAsset?

    private var visiblePrompts: [PromptTemplate] {
        store.prompts.filter { prompt in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || prompt.name.localizedCaseInsensitiveContains(query)
                || prompt.text.localizedCaseInsensitiveContains(query)
                || prompt.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            return matchesSearch && (!favoritesOnly || prompt.favorite)
        }
    }

    private var visibleReferences: [ReferenceAsset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.referenceAssets }
        return store.referenceAssets.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.category?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Bibliothek", selection: $store.selectedLibrarySection) {
                    ForEach(LibrarySection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                Group {
                    if store.selectedLibrarySection == .prompts { promptContent }
                    else { referenceContent }
                }
            }
            .navigationTitle("Bibliothek")
            .searchable(text: $searchText, prompt: store.selectedLibrarySection == .prompts ? "Name, Text oder Tag" : "Referenzbilder durchsuchen")
            .toolbar {
                if store.selectedLibrarySection == .prompts {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { favoritesOnly.toggle() } label: {
                            Label("Favoriten", systemImage: favoritesOnly ? "star.fill" : "star")
                        }
                        .accessibilityValue(favoritesOnly ? "Nur Favoriten" : "Alle Prompts")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if searchText.isEmpty && !favoritesOnly { EditButton() }
                        Button { creating = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Neuen Prompt anlegen")
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        PhotosPicker(selection: $referencePickerItem, matching: .images) {
                            Label("Referenzbild hinzufügen", systemImage: "plus")
                        }
                    }
                }
            }
            .sheet(item: $editing) { PromptForm(prompt: $0) }
            .sheet(isPresented: $creating) { PromptForm(prompt: nil) }
            .sheet(item: $referenceEditor) { ReferenceAssetForm(context: $0) }
            .confirmationDialog(
                "Referenzbild löschen?",
                isPresented: Binding(
                    get: { referenceToDelete != nil },
                    set: { if !$0 { referenceToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Endgültig löschen", role: .destructive) {
                    guard let asset = referenceToDelete else { return }
                    Task { await deleteReference(asset) }
                }
                Button("Abbrechen", role: .cancel) { referenceToDelete = nil }
            } message: {
                Text("Das Bild wird aus dieser Bibliothek entfernt.")
            }
            .onChange(of: referencePickerItem) { _, item in
                guard let item else { return }
                Task { await prepareReference(item) }
            }
        }
    }

    @ViewBuilder private var promptContent: some View {
        if !store.dataLoaded {
            InitialDataStateView(title: "Deine Prompt-Bausteine", symbol: "text.quote")
        } else if store.prompts.isEmpty {
            ContentUnavailableView {
                Label("Keine Prompt-Bausteine", systemImage: "text.quote")
            } description: {
                Text("Speichere häufig verwendete Beschreibungen und kombiniere sie später im Generator.")
            } actions: {
                Button("Prompt anlegen") { creating = true }
                    .buttonStyle(.borderedProminent)
                    .tint(CDanceTheme.accent).foregroundStyle(.black)
            }
        } else if visiblePrompts.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(visiblePrompts) { prompt in
                    PromptRow(prompt: prompt) { editing = prompt }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { Task { await toggleFavorite(prompt) } } label: {
                                Label(prompt.favorite ? "Entfavorisieren" : "Favorit", systemImage: prompt.favorite ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { Task { await delete(prompt) } } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                            Button { Task { await copy(prompt) } } label: {
                                Label("Kopieren", systemImage: "doc.on.doc")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button("Bearbeiten", systemImage: "pencil") { editing = prompt }
                            Button("Kopieren", systemImage: "doc.on.doc") { Task { await copy(prompt) } }
                            Button("Löschen", systemImage: "trash", role: .destructive) { Task { await delete(prompt) } }
                        }
                }
                .onMove(perform: move)
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder private var referenceContent: some View {
        if !store.dataLoaded {
            InitialDataStateView(title: "Deine Referenzbilder", symbol: "photo.stack")
        } else if store.referenceAssets.isEmpty {
            ContentUnavailableView {
                Label("Keine Referenzbilder", systemImage: "photo.stack")
            } description: {
                Text("Lege häufig verwendete Gesichter, Personen oder Stile hier ab und füge sie später mit einem Tipp ein.")
            } actions: {
                PhotosPicker(selection: $referencePickerItem, matching: .images) {
                    Text("Referenzbild hinzufügen")
                }
                .buttonStyle(.borderedProminent)
                .tint(CDanceTheme.accent).foregroundStyle(.black)
            }
        } else if visibleReferences.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(visibleReferences) { asset in
                        ReferenceAssetCard(asset: asset) {
                            Task { await useReference(asset) }
                        } onRename: {
                            referenceEditor = ReferenceEditorContext(asset: asset, reference: nil)
                        } onDelete: {
                            referenceToDelete = asset
                        }
                    }
                }
                .padding()
                .padding(.bottom, 90)
            }
            .refreshable { await store.reload() }
        }
    }

    private func prepareReference(_ item: PhotosPickerItem) async {
        defer { referencePickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let normalized = UIImage.cdanceUploadJPEG(from: data),
              let preview = UIImage.referencePreview(from: normalized) else {
            store.error = "Das Bild konnte nicht gelesen werden."
            return
        }
        referenceEditor = ReferenceEditorContext(asset: nil, reference: LocalReference(data: normalized, preview: preview))
    }

    private func useReference(_ asset: ReferenceAsset) async {
        do {
            let data = try await APIClient.shared.thumbnailData(asset.image, maxSize: 768)
            guard let preview = UIImage(data: data) else { throw APIClientError.invalidImage }
            store.pendingReference = ReferenceRequest(image: asset.image, preview: preview)
            store.selectedTab = 0
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func deleteReference(_ asset: ReferenceAsset) async {
        referenceToDelete = nil
        await store.perform {
            try await APIClient.shared.deleteReferenceAsset(asset.id)
            store.referenceAssets.removeAll { $0.id == asset.id }
        }
    }

    private func copy(_ prompt: PromptTemplate) async {
        await store.perform {
            _ = try await APIClient.shared.copyPrompt(prompt.id)
            await store.reload()
        }
    }

    private func delete(_ prompt: PromptTemplate) async {
        await store.perform {
            try await APIClient.shared.deletePrompt(prompt.id)
            await store.reload()
        }
    }

    private func toggleFavorite(_ prompt: PromptTemplate) async {
        await store.perform {
            _ = try await APIClient.shared.savePrompt(
                prompt,
                name: prompt.name,
                text: prompt.text,
                description: prompt.description ?? "",
                category: prompt.category ?? "",
                tags: prompt.tags,
                favorite: !prompt.favorite
            )
            await store.reload()
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        store.prompts.move(fromOffsets: offsets, toOffset: destination)
        let reordered = store.prompts
        Task {
            for (index, var prompt) in reordered.enumerated() {
                prompt.sortOrder = index
                _ = try? await APIClient.shared.savePrompt(
                    prompt,
                    name: prompt.name,
                    text: prompt.text,
                    description: prompt.description ?? "",
                    category: prompt.category ?? "",
                    tags: prompt.tags,
                    favorite: prompt.favorite
                )
            }
            await store.reload()
        }
    }
}

private struct ReferenceEditorContext: Identifiable {
    let id = UUID()
    let asset: ReferenceAsset?
    let reference: LocalReference?
}

private struct ReferenceAssetCard: View {
    let asset: ReferenceAsset
    let onUse: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var preview: UIImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color(uiColor: .tertiarySystemGroupedBackground)
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .clipped()
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button("Umbenennen", systemImage: "pencil", action: onRename)
                    Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.65), in: Circle())
                }
                .padding(8)
                .accessibilityLabel("Referenzbild verwalten")
            }

            Text(asset.name)
                .font(.headline)
                .lineLimit(1)

            Button(action: onUse) {
                Label("Verwenden", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(CDanceTheme.accent)
            .foregroundStyle(.black)
            .disabled(preview == nil)
        }
        .padding(10)
        .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 18))
        .contextMenu {
            Button("Umbenennen", systemImage: "pencil", action: onRename)
            Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .task(id: asset.image.downloadURL) {
            do {
                let data = try await APIClient.shared.thumbnailData(asset.image, maxSize: 512)
                preview = UIImage(data: data)
                failed = preview == nil
            } catch {
                failed = true
            }
        }
    }
}

private struct ReferenceAssetForm: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let context: ReferenceEditorContext
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(context: ReferenceEditorContext) {
        self.context = context
        _name = State(initialValue: context.asset?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let preview = context.reference?.preview {
                    Section {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Zum Beispiel: Gesicht Frau", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                } header: {
                    Text("Bezeichnung")
                } footer: {
                    Text("Unter diesem Namen erscheint das Bild in der Schnellwahl und Bibliothek.")
                }
            }
            .navigationTitle(context.asset == nil ? "Referenzbild sichern" : "Referenzbild umbenennen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(cleanName.isEmpty || store.working)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { nameFocused = false }
                }
            }
            .onAppear { nameFocused = true }
        }
        .interactiveDismissDisabled(store.working)
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() async {
        await store.perform {
            if let asset = context.asset {
                let saved = try await APIClient.shared.renameReferenceAsset(asset, name: cleanName)
                if let index = store.referenceAssets.firstIndex(where: { $0.id == asset.id }) {
                    store.referenceAssets[index] = saved
                }
            } else if let reference = context.reference {
                let saved = try await APIClient.shared.saveReferenceAsset(name: cleanName, reference: reference)
                store.referenceAssets.insert(saved, at: 0)
            }
            dismiss()
        }
    }
}

private struct PromptRow: View {
    let prompt: PromptTemplate
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: prompt.favorite ? "star.fill" : "text.quote")
                    .foregroundStyle(prompt.favorite ? .yellow : .secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(prompt.name).font(.headline).foregroundStyle(.primary)
                        if let category = prompt.category, !category.isEmpty {
                            Text(category).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                        }
                    }
                    Text(prompt.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    if !prompt.tags.isEmpty {
                        Text(prompt.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption).foregroundStyle(.tint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}

private struct PromptForm: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let prompt: PromptTemplate?
    @State private var name: String
    @State private var text: String
    @State private var description: String
    @State private var category: String
    @State private var tags: String
    @State private var favorite: Bool
    @FocusState private var focusedField: Field?

    private enum Field { case name, text, description, category, tags }

    init(prompt: PromptTemplate?) {
        self.prompt = prompt
        _name = State(initialValue: prompt?.name ?? "")
        _text = State(initialValue: prompt?.text ?? "")
        _description = State(initialValue: prompt?.description ?? "")
        _category = State(initialValue: prompt?.category ?? "")
        _tags = State(initialValue: prompt?.tags.joined(separator: ", ") ?? "")
        _favorite = State(initialValue: prompt?.favorite ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Prompt") {
                    TextField("Name", text: $name).focused($focusedField, equals: .name)
                    TextField("Prompt-Text", text: $text, axis: .vertical)
                        .lineLimit(7...14).focused($focusedField, equals: .text)
                }
                Section("Organisation") {
                    TextField("Beschreibung (optional)", text: $description, axis: .vertical)
                        .focused($focusedField, equals: .description)
                    TextField("Kategorie", text: $category).focused($focusedField, equals: .category)
                    TextField("Tags, mit Komma getrennt", text: $tags)
                        .textInputAutocapitalization(.never).focused($focusedField, equals: .tags)
                    Toggle("Als Favorit markieren", isOn: $favorite)
                }
            }
            .navigationTitle(prompt == nil ? "Neuer Prompt" : "Prompt bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.working)
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Fertig") { focusedField = nil } }
            }
        }
        .interactiveDismissDisabled(store.working)
    }

    private func save() async {
        await store.perform {
            _ = try await APIClient.shared.savePrompt(
                prompt,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description,
                category: category,
                tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                favorite: favorite
            )
            await store.reload()
            dismiss()
        }
    }
}
