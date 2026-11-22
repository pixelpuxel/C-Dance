import SwiftUI

struct SettingsView: View {
    private enum FocusedField { case apiKey, albumName, additionalAlbum, serverAddress }
    @EnvironmentObject private var store: AppStore
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var showRemoveConfirmation = false
    @State private var checkingPhotoPermission = false
    @State private var changingPushSetting = false
    @State private var additionalAlbumName = ""
    @State private var additionalAlbums = PhotoAlbumPreferences.load()
    @State private var serverAddress = (AppModeConfiguration.serverURL == AppModeConfiguration.defaultServerURL && Keychain.token == nil) ? "" : AppModeConfiguration.serverURL.absoluteString
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Aktiv", value: store.mode.title)
                    if store.mode == .standalone {
                        TextField("Serveradresse", text: $serverAddress)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .serverAddress)
                        Link("Eigenen Server einrichten", destination: URL(string: "https://github.com/pixelpuxel/CDance")!)
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Zum Servermodus wechseln") {
                            focusedField = nil
                            Task { _ = await store.switchToServer(address: serverAddress) }
                        }
                    } else {
                        Button("Zum Standalone-Modus wechseln") { Task { await store.switchToStandalone() } }
                    }
                } header: {
                    Text("Betriebsart")
                } footer: {
                    Text(store.mode == .standalone ? "Standalone speichert deine Inhalte lokal und ruft C-Dance direkt mit deinem Ark-Schlüssel auf." : "Der Servermodus verwendet Anmeldung, Warteschlange, Web-App und serverseitige Speicherung wie bisher.")
                }

                Section {
                    connectionStatus
                    if store.providerConfiguration?.configured != true { keyEditor }
                    if store.providerConfiguration?.source == "database" {
                        Button("API-Key ersetzen") { focusedField = .apiKey }
                        if focusedField == .apiKey { keyEditor }
                        Button("API-Key entfernen", role: .destructive) { showRemoveConfirmation = true }
                    }
                } header: {
                    Text("C-Dance-Verbindung")
                } footer: {
                    Text(store.mode == .standalone ? "Der Schlüssel bleibt im geschützten iOS-Schlüsselbund und wird nur für direkte Anfragen an BytePlus Ark verwendet." : "Der Schlüssel wird verschlüsselt auf dem Server und zusätzlich im geschützten iOS-Schlüsselbund gespeichert. So ist beim Wechsel zu Standalone keine zweite Eingabe nötig.")
                }

                Section {
                    Toggle("Automatisch in Fotos sichern", isOn: $store.autoSavePhotos)
                        .disabled(checkingPhotoPermission)
                    Toggle("Eigenes Album verwenden", isOn: $store.autoSaveAlbum)
                        .disabled(!store.autoSavePhotos || checkingPhotoPermission)
                    if store.autoSavePhotos && store.autoSaveAlbum {
                        TextField("Albumname", text: $store.albumName)
                            .focused($focusedField, equals: .albumName)
                            .submitLabel(.done)
                            .onSubmit { focusedField = nil }
                    }
                    if checkingPhotoPermission {
                        Label("Fotozugriff wird geprüft …", systemImage: "photo.badge.checkmark")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Speichern")
                } footer: {
                    Text("Beim ersten Speichern fragt iOS nach dem Zugriff auf deine Fotomediathek. Das Album wird bei Bedarf automatisch erstellt.")
                }

                Section {
                    ForEach(additionalAlbums, id: \.self) { album in
                        Label(album, systemImage: "rectangle.stack.badge.plus")
                    }
                    .onDelete { offsets in
                        additionalAlbums.remove(atOffsets: offsets)
                        PhotoAlbumPreferences.save(additionalAlbums)
                    }
                    HStack {
                        TextField("Weiteres Album", text: $additionalAlbumName)
                            .focused($focusedField, equals: .additionalAlbum)
                            .submitLabel(.done)
                            .onSubmit(addAdditionalAlbum)
                        Button(action: addAdditionalAlbum) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(additionalAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Album hinzufügen")
                    }
                } header: {
                    Text("Alben für Mehrfachauswahl")
                } footer: {
                    Text("Diese Alben erscheinen beim Auswählen mehrerer Bilder unter Fotos. Das Album wird beim ersten Speichern in der Fotos-App angelegt.")
                }

                Section {
                    Toggle("Fertige Filme melden", isOn: Binding(
                        get: { store.pushNotificationsEnabled },
                        set: { enabled in
                            changingPushSetting = true
                            Task {
                                await store.setPushNotifications(enabled)
                                changingPushSetting = false
                            }
                        }
                    ))
                    .disabled(changingPushSetting)
                    if changingPushSetting {
                        Label("Mitteilungen werden eingerichtet …", systemImage: "bell.badge")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Mitteilungen")
                } footer: {
                    Text(store.mode == .standalone ? "Standalone-Mitteilungen erscheinen, wenn iOS die laufende App nicht beendet hat. Für garantierte Hintergrundverarbeitung steht der Servermodus bereit." : "Sobald ein Film fertig ist, erhältst du eine Mitteilung. Antippen öffnet direkt den Ergebnisfilm.")
                }

                if let configuration = store.providerConfiguration {
                    Section("Technische Angaben") {
                        LabeledContent("Version", value: appVersion)
                        LabeledContent("Modell", value: configuration.model)
                        LabeledContent("API", value: store.mode == .standalone ? "BytePlus Ark (direkt)" : AppModeConfiguration.serverURL.host ?? "Server")
                        Link(destination: store.mode == .standalone ? URL(string: "https://docs.byteplus.com/en/docs/ModelArk/1824121")! : AppModeConfiguration.serverURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")) {
                            Label("API-Dokumentation öffnen", systemImage: "safari")
                        }
                        DisclosureGroup("Provider-Endpunkt") {
                            Text(configuration.endpoint).font(.caption).textSelection(.enabled)
                        }
                    }
                }

                if store.mode == .server {
                    Section { Button("Abmelden", role: .destructive) { Task { await store.logout() } } }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .navigationTitle("Einstellungen")
            .refreshable { await store.reload() }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Fertig") { focusedField = nil } }
            }
            .onChange(of: store.autoSavePhotos) { _, enabled in
                if enabled { Task { await preparePhotoSaving() } }
            }
            .onChange(of: store.autoSaveAlbum) { _, enabled in
                if enabled && store.autoSavePhotos { Task { await preparePhotoSaving() } }
            }
            .confirmationDialog("API-Key entfernen?", isPresented: $showRemoveConfirmation) {
                Button("API-Key entfernen", role: .destructive) { Task { await store.removeProvider() } }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Neue Filme können erst wieder erstellt werden, nachdem ein gültiger Schlüssel gespeichert wurde.")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }

    private func preparePhotoSaving() async {
        checkingPhotoPermission = true
        defer { checkingPhotoPermission = false }
        do {
            try await PhotoLibraryService.prepare(albumName: store.autoSaveAlbum ? store.albumName : nil)
        } catch {
            store.autoSavePhotos = false
            store.error = error.localizedDescription
        }
    }

    private func addAdditionalAlbum() {
        let name = additionalAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        additionalAlbums = PhotoAlbumPreferences.load()
        if !additionalAlbums.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            additionalAlbums.append(name)
        }
        PhotoAlbumPreferences.save(additionalAlbums)
        additionalAlbumName = ""
        focusedField = nil
    }

    private var connectionStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: store.providerConfiguration?.configured == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(store.providerConfiguration?.configured == true ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.providerConfiguration?.configured == true ? "C-Dance ist bereit" : "Einrichtung erforderlich")
                    .font(.headline)
                Text(store.providerConfiguration?.configured == true ? (store.mode == .standalone ? "Filme werden direkt über BytePlus Ark erzeugt." : "Filme können serverseitig erzeugt werden.") : "Hinterlege einmalig deinen Ark API-Key.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Group {
                    if showKey { TextField("Ark API-Key", text: $apiKey) }
                    else { SecureField("Ark API-Key", text: $apiKey) }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .apiKey)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }

                Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                    .accessibilityLabel(showKey ? "Schlüssel verbergen" : "Schlüssel anzeigen")
            }
            Button {
                Task {
                    if await store.configureProvider(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        apiKey = ""
                        focusedField = nil
                    }
                }
            } label: {
                if store.working { ProgressView().frame(maxWidth: .infinity) }
                else { Text(store.mode == .standalone ? "Sicher auf diesem Gerät speichern" : "Sicher auf dem Server speichern").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .tint(CDanceTheme.accent).foregroundStyle(.black)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 || store.working)
        }
    }
}
