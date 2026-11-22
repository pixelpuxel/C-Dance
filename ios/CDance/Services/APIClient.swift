import Foundation
import AVFoundation
import Security
import UIKit

enum APIClientError: LocalizedError {
    case invalidResponse, invalidImage, server(String), notAuthenticated
    var errorDescription: String? { switch self { case .invalidResponse: "Der Server hat keine gültige C-Dance-Antwort gesendet."; case .invalidImage: "Die Mediendatei konnte nicht verarbeitet werden."; case .server(let message): message; case .notAuthenticated: "Bitte erneut anmelden." } }
}

protocol APIClientCredentials: AnyObject {
    var accessToken: String? { get set }
    var sessionToken: String? { get set }
}

actor APIClient {
    static let shared = APIClient()
    #if DEBUG
    var baseURL = URL(string: "http://localhost:8000/api/v1")!
    #else
    var baseURL = URL(string: "https://seadance.vps2.schreiber.info/api/v1")!
    #endif
    private let decoder = JSONDecoder.cdance()
    private let encoder = JSONEncoder()
    private let session: URLSession
    private let credentials: APIClientCredentials?
    private var refreshTask: Task<TokenResponse?, Never>?

    init(session: URLSession = .shared, credentials: APIClientCredentials? = nil) {
        self.session = session
        self.credentials = credentials
    }

    var isAuthenticated: Bool { AppModeConfiguration.mode == .standalone || authenticationToken != nil }
    var hasServerSession: Bool { authenticationToken != nil }

    private var authenticationToken: String? {
        #if DEBUG
        if let token = ProcessInfo.processInfo.environment["CDANCE_INTEGRATION_TOKEN"], !token.isEmpty {
            return token
        }
        #endif
        return credentials?.accessToken ?? Keychain.token
    }

    private var authenticationSessionToken: String? { credentials?.sessionToken ?? Keychain.sessionToken }

    private func storeAuthentication(accessToken: String?, sessionToken: String?) {
        if let credentials {
            credentials.accessToken = accessToken
            credentials.sessionToken = sessionToken
        } else {
            Keychain.token = accessToken
            Keychain.sessionToken = sessionToken
        }
    }

    func configureServerURL(_ url: URL) { baseURL = url }

    func validateServer(at url: URL) async throws {
        var request = URLRequest(url: Self.resolveURL(baseURL: url, path: "/setup/status"))
        request.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
            guard 200..<300 ~= http.statusCode else {
                throw APIClientError.server("Unter dieser Adresse wurde keine CDance-API gefunden (HTTP \(http.statusCode)).")
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["setup_required"] is Bool else {
                throw APIClientError.server("Die Adresse antwortet, aber nicht mit einer kompatiblen CDance-API. Bitte die Serveradresse ohne Web- oder Dokumentationspfad eingeben.")
            }
        } catch let error as APIClientError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                throw APIClientError.server("Der Servername konnte nicht gefunden werden. Bitte die Adresse prüfen.")
            case .cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                throw APIClientError.server("Der Server ist momentan nicht erreichbar. Bitte Netzwerk und Server prüfen.")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed:
                throw APIClientError.server("Die HTTPS-Verbindung des Servers ist nicht vertrauenswürdig.")
            default:
                throw APIClientError.server("Die Serververbindung ist fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    func validateServerSession() async -> Bool {
        guard let token = authenticationToken else { return false }
        var request = URLRequest(url: url("/auth/me"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await send(request, retryAfterRefresh: true),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else {
            storeAuthentication(accessToken: nil, sessionToken: nil)
            return false
        }
        return true
    }

    func clearServerSession() {
        storeAuthentication(accessToken: nil, sessionToken: nil)
    }

    func login(username: String, password: String) async throws {
        let result: TokenResponse = try await request("/auth/login", method: "POST", body: ["username": username, "password": password], authenticated: false)
        storeAuthentication(accessToken: result.accessToken, sessionToken: result.sessionToken)
    }

    func logout() async {
        if let sessionToken = authenticationSessionToken {
            let _: EmptyResponse? = try? await request("/auth/logout", method: "POST", body: ["session_token": sessionToken], authenticated: false)
        }
        storeAuthentication(accessToken: nil, sessionToken: nil)
    }
    func models() async throws -> ModelsResponse { if AppModeConfiguration.mode == .standalone { return await StandaloneService.shared.models() }; return try await request("/models") }
    func prompts() async throws -> [PromptTemplate] { if AppModeConfiguration.mode == .standalone { return await StandaloneService.shared.prompts() }; return try await request("/prompts") }
    func referenceAssets() async throws -> [ReferenceAsset] { if AppModeConfiguration.mode == .standalone { return await StandaloneService.shared.referenceAssets() }; return try await request("/reference-assets") }
    func history() async throws -> GenerationPage {
        if AppModeConfiguration.mode == .standalone { return await StandaloneService.shared.history() }

        // The server deliberately caps one response at 100 generations. Fetching
        // only that first page made older entries disappear locally and caused
        // their already downloaded images to be evicted from the disk cache.
        let pageSize = 100
        var offset = 0
        var total = 0
        var generations: [Generation] = []
        var knownIDs = Set<String>()

        repeat {
            let page: GenerationPage = try await request("/generations?limit=\(pageSize)&offset=\(offset)")
            total = page.total
            guard !page.items.isEmpty else { break }
            offset += page.items.count
            for generation in page.items where knownIDs.insert(generation.id).inserted {
                generations.append(generation)
            }
        } while offset < total

        generations.sort { $0.createdAt > $1.createdAt }
        return GenerationPage(items: generations, total: total)
    }
    func providerConfiguration() async throws -> ProviderConfiguration {
        if AppModeConfiguration.mode == .standalone { return await StandaloneService.shared.providerConfiguration() }
        return try await providerRequest()
    }
    func configureProvider(apiKey: String) async throws -> ProviderConfiguration {
        let clean = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if AppModeConfiguration.mode == .standalone { return try await StandaloneService.shared.configureProvider(apiKey: clean) }
        let configuration = try await providerRequest(method: "PUT", apiKey: clean, fallbackConfigured: true)
        Keychain.providerAPIKey = clean
        return configuration
    }
    func removeProviderConfiguration() async throws -> ProviderConfiguration {
        if AppModeConfiguration.mode == .standalone { return await StandaloneService.shared.removeProviderConfiguration() }
        let configuration = try await providerRequest(method: "DELETE", fallbackConfigured: false)
        Keychain.providerAPIKey = nil
        return configuration
    }
    func generation(_ id: String) async throws -> Generation { if AppModeConfiguration.mode == .standalone { return try await StandaloneService.shared.generation(id) }; return try await request("/generations/\(id)") }
    func updateGenerationPreference(_ id: String, favorite: Bool, rating: Int) async throws -> Generation {
        guard AppModeConfiguration.mode == .server else { return try await StandaloneService.shared.generation(id) }
        return try await request(
            "/generations/\(id)/preference",
            method: "PUT",
            body: GenerationPreferenceRequest(
                favorite: favorite,
                rating: min(max(rating, 0), 5)
            )
        )
    }
    func regenerate(_ id: String) async throws -> Generation { if AppModeConfiguration.mode == .standalone { return try await StandaloneService.shared.regenerate(id) }; return try await request("/generations/\(id)/regenerate", method: "POST", body: Optional<[String:String]>.none) }
    func variation(_ id: String) async throws -> Generation { if AppModeConfiguration.mode == .standalone { return try await StandaloneService.shared.regenerate(id, variation: true) }; return try await request("/generations/\(id)/variation", method: "POST", body: Optional<[String:String]>.none) }
    func deleteGeneration(_ id: String) async throws { if AppModeConfiguration.mode == .standalone { try await StandaloneService.shared.deleteGeneration(id); return }; let _: DeleteGenerationResponse = try await request("/generations/\(id)", method: "DELETE", body: Optional<[String:String]>.none) }
    func deletePrompt(_ id: String) async throws { if AppModeConfiguration.mode == .standalone { try await StandaloneService.shared.deletePrompt(id); return }; let _: EmptyResponse = try await request("/prompts/\(id)", method: "DELETE", body: Optional<[String:String]>.none) }
    func copyPrompt(_ id: String) async throws -> PromptTemplate { if AppModeConfiguration.mode == .standalone { return try await StandaloneService.shared.copyPrompt(id) }; return try await request("/prompts/\(id)/copy", method: "POST", body: Optional<[String:String]>.none) }
    func deleteReferenceAsset(_ id: String) async throws { if AppModeConfiguration.mode == .standalone { try await StandaloneService.shared.deleteReferenceAsset(id); return }; let _: EmptyResponse = try await request("/reference-assets/\(id)", method: "DELETE", body: Optional<[String:String]>.none) }
    func renameReferenceAsset(_ asset: ReferenceAsset, name: String) async throws -> ReferenceAsset {
        if AppModeConfiguration.mode == .standalone { return try await StandaloneService.shared.renameReferenceAsset(asset.id, name: name) }
        do {
            return try await request("/reference-assets/\(asset.id)", method: "PUT", body: ["name": name])
        } catch {
            // Older self-hosted backends do not yet expose the rename endpoint.
            // Re-create the library entry with the same pixels so renaming still
            // works while those installations are being updated.
            let data = try await imageData(asset.image)
            guard let normalized = UIImage.cdanceUploadJPEG(from: data),
                  let preview = UIImage.referencePreview(from: normalized) else { throw error }
            let replacement = try await saveReferenceAsset(
                name: name,
                reference: LocalReference(data: normalized, remote: asset.image, preview: preview)
            )
            try await deleteReferenceAsset(asset.id)
            return replacement
        }
    }

    func registerDevice(token: String) async throws {
        if AppModeConfiguration.mode == .standalone { return }
        let payload = DeviceRegistrationPayload(deviceToken: token, environment: Self.apnsEnvironment, bundleID: "info.schreiber.cdance")
        let _: DeviceRegistrationResult = try await request("/devices", method: "POST", body: payload)
    }

    func unregisterDevice(token: String) async throws {
        if AppModeConfiguration.mode == .standalone { return }
        let payload = DeviceRegistrationPayload(deviceToken: token, environment: Self.apnsEnvironment, bundleID: "info.schreiber.cdance")
        let _: DeviceRegistrationResult = try await request("/devices/current", method: "DELETE", body: payload)
    }

    func saveReferenceAsset(name: String, reference: LocalReference) async throws -> ReferenceAsset {
        if AppModeConfiguration.mode == .standalone { return try await StandaloneService.shared.saveReferenceAsset(name: name, reference: reference) }
        let data = try await uploadData(for: reference)
        let files = [MultipartFile(name: "image", filename: "referenz.jpg", mime: "image/jpeg", data: data)]
        return try await multipart("/reference-assets", fields: ["name": name], files: files)
    }

    func savePrompt(_ prompt: PromptTemplate?, name: String, text: String, description: String, category: String, tags: [String], favorite: Bool) async throws -> PromptTemplate {
        if AppModeConfiguration.mode == .standalone { return try await StandaloneService.shared.savePrompt(prompt, name: name, text: text, description: description, category: category, tags: tags, favorite: favorite) }
        let body = PromptPayload(name: name, text: text, description: description.isEmpty ? nil : description, category: category.isEmpty ? nil : category, tags: tags, favorite: favorite, sortOrder: prompt?.sortOrder ?? 0)
        return try await request(prompt.map { "/prompts/\($0.id)" } ?? "/prompts", method: prompt == nil ? "POST" : "PUT", body: body)
    }

    func generate(prompt: String, finalPrompt: String, templateIDs: [String], references: [LocalReference], model: String, ratio: String, resolution: String, duration: Int = 5, generateAudio: Bool = true, parentID: String? = nil) async throws -> Generation {
        if AppModeConfiguration.mode == .standalone { return try await StandaloneService.shared.createGeneration(prompt: prompt, finalPrompt: finalPrompt, templateIDs: templateIDs, references: references, model: model, ratio: ratio, resolution: resolution, duration: duration, generateAudio: generateAudio, parentID: parentID) }
        // Always submit the selected pixels, not a database id. A result may have
        // been cached on the device after its source generation was removed or a
        // mode was changed. Uploading the data makes the visible selection the
        // source of truth and also preserves the exact order of mixed references.
        let parameters = jsonObjectString(["duration": duration, "generate_audio": generateAudio])
        var fields = ["prompt": prompt, "final_prompt": finalPrompt, "template_ids": jsonString(templateIDs), "image_ids": "[]", "model": model, "aspect_ratio": ratio, "resolution": resolution, "parameters": parameters]
        if let parentID { fields["parent_id"] = parentID }
        var files: [MultipartFile] = []
        for (index, item) in references.enumerated() {
            files.append(try await uploadFile(for: item, index: index))
        }
        return try await multipart(parentID == nil ? "/generate" : "/edit", fields: fields, files: files)
    }

    private func uploadFile(for reference: LocalReference, index: Int) async throws -> MultipartFile {
        if let remote = reference.remote, remote.isVideo {
            let data = try await imageData(remote)
            let ext = remote.mimeType == "video/quicktime" ? "mov" : "mp4"
            return MultipartFile(name: "reference_images", filename: "reference-\(index + 1).\(ext)", mime: remote.mimeType, data: data)
        }
        let data = try await uploadData(for: reference)
        return MultipartFile(name: "reference_images", filename: "reference-\(index + 1).jpg", mime: "image/jpeg", data: data)
    }

    private func uploadData(for reference: LocalReference) async throws -> Data {
        if let data = reference.data,
           let normalized = UIImage.cdanceUploadJPEG(from: data) {
            return normalized
        }
        if let remote = reference.remote,
           let full = try? await imageData(remote),
           let normalized = UIImage.cdanceUploadJPEG(from: full) {
            return normalized
        }
        // The full-size server object can disappear after the user selected it.
        // The preview is retained locally, so the action still works instead of
        // submitting a stale id and failing with "Referenzbild nicht gefunden".
        if let preview = reference.preview.cdanceUploadJPEG() { return preview }
        throw APIClientError.invalidImage
    }

    private func providerRequest(
        method: String = "GET",
        apiKey: String? = nil,
        fallbackConfigured: Bool? = nil
    ) async throws -> ProviderConfiguration {
        var request = URLRequest(url: url("/provider/config"))
        request.httpMethod = method
        if let apiKey {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(["api_key": apiKey])
        }
        guard let token = authenticationToken else { throw APIClientError.notAuthenticated }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request, retryAfterRefresh: true)
        try validate(response, data: data)
        if let configuration = try? decoder.decode(ProviderConfiguration.self, from: data) {
            return configuration
        }
        if let fallbackConfigured {
            return ProviderConfiguration(
                configured: fallbackConfigured,
                source: fallbackConfigured ? "server" : "missing",
                endpoint: "",
                model: ""
            )
        }
        throw APIClientError.server("Der Server hat die CDance-Konfiguration in einem unbekannten Format gesendet. Bitte Backend-Version prüfen.")
    }

    func imageData(_ image: APIImage) async throws -> Data {
        if let cached = await ImageDiskCache.shared.data(for: image, variant: "full") { return cached }
        let data: Data
        if image.downloadURL.scheme == "cdance-local" { data = try await StandaloneService.shared.data(for: image) }
        else { data = try await remoteImageData(image) }
        await ImageDiskCache.shared.store(data, for: image, variant: "full")
        return data
    }

    func cachedThumbnailData(_ image: APIImage) async -> Data? {
        await ImageDiskCache.shared.bestThumbnailData(for: image)
    }

    func remoteImageData(_ image: APIImage) async throws -> Data {
        try await remoteImageData(image, thumbnailSize: nil)
    }

    func thumbnailData(_ image: APIImage, maxSize: Int = 512) async throws -> Data {
        let normalizedSize = min(max(maxSize, 64), 1024)
        let variant = "thumbnail-\(normalizedSize)"
        if let cached = await ImageDiskCache.shared.data(for: image, variant: variant) { return cached }
        // A larger thumbnail already on disk is also a valid source for a
        // smaller presentation. This lets cards, rows and photo grids share
        // their downloaded pixels instead of requesting the same image again.
        let knownSizes = [64, 96, 128, 192, 256, 320, 384, 512, 768, 1024]
        for cachedSize in knownSizes where cachedSize > normalizedSize {
            if let cached = await ImageDiskCache.shared.data(
                for: image,
                variant: "thumbnail-\(cachedSize)"
            ) {
                return cached
            }
        }
        if image.isVideo {
            let fileURL = try await mediaFileURL(image)
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: normalizedSize, height: normalizedSize)
            let result = try await generator.image(at: .zero).image
            guard let data = UIImage(cgImage: result).jpegData(compressionQuality: 0.86) else { throw APIClientError.invalidImage }
            await ImageDiskCache.shared.store(data, for: image, variant: variant)
            return data
        }
        if image.downloadURL.scheme == "cdance-local" {
            let full = try await StandaloneService.shared.data(for: image)
            guard let source = UIImage.referencePreview(from: full, maxPixelSize: CGFloat(normalizedSize)), let data = source.jpegData(compressionQuality: 0.86) else { throw APIClientError.invalidImage }
            await ImageDiskCache.shared.store(data, for: image, variant: variant)
            return data
        }
        await acquireThumbnailSlot()
        let data: Data
        do {
            data = try await remoteImageData(image, thumbnailSize: normalizedSize)
            releaseThumbnailSlot()
        } catch {
            releaseThumbnailSlot()
            throw error
        }
        await ImageDiskCache.shared.store(data, for: image, variant: variant)
        return data
    }

    func mediaFileURL(_ image: APIImage) async throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("C-Dance/Media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = image.mimeType == "video/quicktime" ? "mov" : "mp4"
        let target = directory.appendingPathComponent("\(image.id)-\(image.byteSize).\(ext)")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let data = try await imageData(image)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var protected = target; try? protected.setResourceValues(values)
        return target
    }

    private var activeThumbnailDownloads = 0
    private var thumbnailDownloadWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireThumbnailSlot() async {
        if activeThumbnailDownloads < 3 {
            activeThumbnailDownloads += 1
            return
        }
        await withCheckedContinuation { thumbnailDownloadWaiters.append($0) }
    }

    private func releaseThumbnailSlot() {
        if thumbnailDownloadWaiters.isEmpty {
            activeThumbnailDownloads = max(0, activeThumbnailDownloads - 1)
        } else {
            thumbnailDownloadWaiters.removeFirst().resume()
        }
    }

    private func remoteImageData(_ image: APIImage, thumbnailSize: Int?) async throws -> Data {
        func downloadURL(for image: APIImage) throws -> URL {
            guard let thumbnailSize else { return image.downloadURL }
            guard var components = URLComponents(url: image.downloadURL, resolvingAgainstBaseURL: false) else {
                throw APIClientError.invalidResponse
            }
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "thumbnail" }
            items.append(URLQueryItem(name: "thumbnail", value: String(thumbnailSize)))
            components.queryItems = items
            guard let url = components.url else { throw APIClientError.invalidResponse }
            return url
        }

        let firstURL = try downloadURL(for: image)
        let (firstData, firstResponse) = try await session.data(from: firstURL)
        guard let firstHTTP = firstResponse as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        if firstHTTP.statusCode == 200 { return firstData }

        // Download URLs are intentionally short lived. A persisted history can
        // therefore contain an expired URL even though the image still exists.
        // Refresh just this image instead of reloading the entire history.
        if firstHTTP.statusCode == 401, AppModeConfiguration.mode == .server {
            let refreshed: APIImage = try await request("/images/\(image.id)")
            let refreshedURL = try downloadURL(for: refreshed)
            let (data, response) = try await session.data(from: refreshedURL)
            guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
            guard http.statusCode == 200 else {
                try validate(response, data: data)
                throw APIClientError.invalidResponse
            }
            return data
        }

        try validate(firstResponse, data: firstData)
        throw APIClientError.invalidResponse
    }

    private func request<T: Decodable, B: Encodable>(_ path: String, method: String = "GET", body: B? = Optional<[String:String]>.none, authenticated: Bool = true) async throws -> T {
        var request = URLRequest(url: url(path)); request.httpMethod = method
        if authenticated { guard let token = authenticationToken else { throw APIClientError.notAuthenticated }; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try encoder.encode(body) }
        let (data, response) = try await send(request, retryAfterRefresh: authenticated)
        try validate(response, data: data)
        if data.isEmpty, T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.server("Der Server antwortet nicht im erwarteten CDance-Format. Bitte Serveradresse und Backend-Version prüfen.")
        }
    }

    private func multipart<T: Decodable>(_ path: String, fields: [String:String], files: [MultipartFile]) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"; var data = Data()
        for (key, value) in fields { data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n") }
        for file in files { data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.mime)\r\n\r\n"); data.append(file.data); data.append("\r\n") }
        data.append("--\(boundary)--\r\n")
        var request = URLRequest(url: url(path)); request.httpMethod = "POST"; request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); guard let token = authenticationToken else { throw APIClientError.notAuthenticated }; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.httpBody = data
        let (responseData, response) = try await send(request, retryAfterRefresh: true)
        try validate(response, data: responseData)
        return try decoder.decode(T.self, from: responseData)
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard http.statusCode != 401 else { throw APIClientError.notAuthenticated }
        guard 200..<300 ~= http.statusCode else { let message = (try? decoder.decode(ErrorEnvelope.self, from: data).error.message) ?? "Serverfehler (\(http.statusCode))."; throw APIClientError.server(message) }
    }
    private func send(_ original: URLRequest, retryAfterRefresh: Bool) async throws -> (Data, URLResponse) {
        var request = original
        var result = try await session.data(for: request)
        if retryAfterRefresh, (result.1 as? HTTPURLResponse)?.statusCode == 401, await refreshAccessToken() {
            request.setValue("Bearer \(authenticationToken ?? "")", forHTTPHeaderField: "Authorization")
            result = try await session.data(for: request)
        }
        return result
    }
    private func url(_ path: String) -> URL { Self.resolveURL(baseURL: baseURL, path: path) }
    static func resolveURL(baseURL: URL, path: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            preconditionFailure("Ungültige API-Basis-URL")
        }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, requestPath].filter { !$0.isEmpty }.joined(separator: "/")
        components.percentEncodedQuery = parts.count == 2 ? String(parts[1]) : nil
        guard let url = components.url else { preconditionFailure("Ungültiger API-Pfad") }
        return url
    }
    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
    private func jsonString(_ values: [String]) -> String { String(data: try! encoder.encode(values), encoding: .utf8)! }
    private func jsonObjectString(_ values: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: values), encoding: .utf8)!
    }
    private func refreshAccessToken() async -> Bool {
        let task: Task<TokenResponse?, Never>
        let ownsTask: Bool
        if let current = refreshTask {
            task = current
            ownsTask = false
        } else {
            guard let sessionToken = authenticationSessionToken else { return false }
            var request = URLRequest(url: url("/auth/refresh")); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try? encoder.encode(["session_token": sessionToken])
            task = Task { [session, decoder] () -> TokenResponse? in
                guard let (data, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return try? decoder.decode(TokenResponse.self, from: data)
            }
            refreshTask = task
            ownsTask = true
        }
        let result = await task.value
        if ownsTask { refreshTask = nil }
        guard let result else { return false }
        // Every waiter stores the result before it is allowed to retry its
        // request. Otherwise a waiter can observe task completion a fraction
        // earlier than the task owner updates the Keychain.
        storeAuthentication(accessToken: result.accessToken, sessionToken: result.sessionToken)
        return true
    }
}

private struct PromptPayload: Encodable { let name, text: String; let description, category: String?; let tags: [String]; let favorite: Bool; let sortOrder: Int; enum CodingKeys: String, CodingKey { case name,text,description,category,tags,favorite; case sortOrder = "sort_order" } }
private struct ErrorEnvelope: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
private struct EmptyResponse: Codable {}
private struct GenerationPreferenceRequest: Encodable {
    let favorite: Bool
    let rating: Int
}
private struct DeviceRegistrationResult: Codable { let registered: Bool }
private struct DeviceRegistrationPayload: Codable {
    let deviceToken: String
    let environment: String
    let bundleID: String
    enum CodingKeys: String, CodingKey { case environment; case deviceToken = "device_token"; case bundleID = "bundle_id" }
}
private struct DeleteGenerationResponse: Codable { let deleted: Bool }
private struct MultipartFile { let name, filename, mime: String; let data: Data }
private extension Data { mutating func append(_ string: String) { append(string.data(using: .utf8)!) } }

enum Keychain {
    private static let service = "info.schreiber.cdance"
    static var token: String? { get { value("access-token") } set { set(newValue, account: "access-token") } }
    static var sessionToken: String? { get { value("session-token") } set { set(newValue, account: "session-token") } }
    static var providerAPIKey: String? { get { value("provider-api-key") } set { set(newValue, account: "provider-api-key") } }
    private static func value(_ account: String) -> String? { let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true]; var result: AnyObject?; guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let data=result as? Data else{return nil}; return String(data:data,encoding:.utf8) }
    private static func set(_ value: String?, account: String) { let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]; SecItemDelete(query as CFDictionary); if let value { var item=query;item[kSecValueData as String]=value.data(using:.utf8)!;SecItemAdd(item as CFDictionary,nil) } }
}
