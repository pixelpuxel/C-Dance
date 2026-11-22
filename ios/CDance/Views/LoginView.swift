import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var store: AppStore
    @State private var username = ""
    @State private var password = ""
    @FocusState private var field: Field?

    private enum Field { case username, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 44)
                    VStack(spacing: 14) {
                        Text("S")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(width: 76, height: 76)
                            .background(CDanceTheme.accent, in: RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                        VStack(spacing: 7) {
                            Text("C-Dance").font(.largeTitle.bold())
                            Text("Melde dich mit deinem Benutzernamen an.")
                                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }

                    VStack(spacing: 12) {
                        LabeledField(title: "Benutzername", symbol: "person.fill") {
                            TextField("z. B. benutzer", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.asciiCapable)
                                .submitLabel(.next)
                                .focused($field, equals: .username)
                                .onSubmit { field = .password }
                        }
                        LabeledField(title: "Passwort", symbol: "lock.fill") {
                            SecureField("Passwort", text: $password)
                                .textContentType(.password)
                                .submitLabel(.go)
                                .focused($field, equals: .password)
                                .onSubmit { submit() }
                        }

                        Text("Es ist keine E-Mail-Adresse erforderlich.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: submit) {
                        Group {
                            if store.working { ProgressView().tint(.black) }
                            else { Text("Anmelden") }
                        }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(CDanceTheme.accent, in: RoundedRectangle(cornerRadius: 16))
                    .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || store.working)
                    .opacity(username.isEmpty || password.isEmpty ? 0.55 : 1)

                    Spacer(minLength: 24)
                    Label("Sichere Verbindung zu \(AppModeConfiguration.serverURL.host ?? "deinem Server")", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Ohne Server im Standalone-Modus nutzen") {
                        Task { await store.switchToStandalone() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
            }
            .background(CDanceTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Fertig") { field = nil } }
            }
        }
    }

    private func submit() {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty, !store.working else { return }
        field = nil
        Task { await store.login(username: name, password: password) }
    }
}

struct StandaloneOnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var showServer = false
    @State private var serverAddress = ""
    @FocusState private var focused: Field?
    private enum Field { case key, server }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("C-Dance").font(.largeTitle.bold())
                        Text("Filme direkt auf deinem Gerät erstellen")
                            .font(.title3.weight(.semibold))
                        Text("Im Standalone-Modus bleiben Prompts, Referenzbilder, Verlauf und Ergebnisse auf diesem Gerät. Nur die Generierungsanfrage wird direkt an BytePlus Ark gesendet.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Optional: Ark API-Key", systemImage: "key.fill").font(.headline)
                        HStack {
                            Group {
                                if showKey { TextField("Ark API-Key", text: $apiKey) }
                                else { SecureField("Ark API-Key", text: $apiKey) }
                            }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused, equals: .key)
                            Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        }
                        .padding(14).background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 14))
                        Text("Der Schlüssel wird im geschützten iOS-Schlüsselbund gespeichert. Du kannst diesen Schritt überspringen und die App erst ansehen.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    Button {
                        focused = nil
                        Task { await store.finishStandaloneOnboarding(apiKey: apiKey) }
                    } label: {
                        Text(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Erst einmal ansehen" : "Standalone starten")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain).foregroundStyle(.black)
                    .background(CDanceTheme.accent, in: RoundedRectangle(cornerRadius: 16))

                    DisclosureGroup("Mit eigenem Server verbinden", isExpanded: $showServer) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("https://mein-server.example", text: $serverAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .focused($focused, equals: .server)
                                .padding(14).background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 14))
                            Link("Eigenen Server einrichten", destination: URL(string: "https://github.com/pixelpuxel/CDance")!)
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Servermodus einrichten") {
                                focused = nil
                                Task { _ = await store.switchToServer(address: serverAddress) }
                            }
                            .buttonStyle(.borderedProminent).tint(CDanceTheme.accent).foregroundStyle(.black)
                        }.padding(.top, 12)
                    }
                    .font(.headline)
                }
                .padding(24)
            }
            .background(CDanceTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Fertig") { focused = nil } } }
        }
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            content
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(CDanceTheme.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
