import Foundation
import UIKit
import UserNotifications

actor StandaloneService {
    static let shared = StandaloneService()

    private struct State: Codable {
        var prompts: [PromptTemplate] = []
        var referenceAssets: [ReferenceAsset] = []
        var generations: [Generation] = []
        var providerTasks: [String: String] = [:]
        var generationOptions: [String: GenerationOptions] = [:]
    }
    private struct GenerationOptions: Codable { let duration: Int; let generateAudio: Bool }

    private struct ArkRequest: Encodable {
        let model: String
        let content: [ArkContent]
        let resolution: String
        let ratio: String
        let duration: Int
        let generateAudio: Bool
        let outputFormat = "mp4"
        let watermark = false
        enum CodingKeys: String, CodingKey {
            case model, content, resolution, ratio, duration, watermark
            case generateAudio = "generate_audio"
            case outputFormat = "output_format"
        }
    }

    private struct ArkContent: Encodable {
        let type: String
        let text: String?
        let imageURL: ArkMediaURL?
        let role: String?
        enum CodingKeys: String, CodingKey { case type, text, role; case imageURL = "image_url"; case videoURL = "video_url" }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(type, forKey: .type)
            try values.encodeIfPresent(text, forKey: .text)
            try values.encodeIfPresent(role, forKey: .role)
            if type == "video_url" { try values.encodeIfPresent(imageURL, forKey: .videoURL) }
            else { try values.encodeIfPresent(imageURL, forKey: .imageURL) }
        }
    }
    private struct ArkMediaURL: Encodable { let url: String }

    private struct ArkCreateResponse: Decodable { let id: String }
    private struct ArkTaskResponse: Decodable {
        struct Content: Decodable { let videoURL: URL?; enum CodingKeys: String, CodingKey { case videoURL = "video_url" } }
        let id: String
        let status: String
        let content: Content?
    }

    private struct ArkErrorEnvelope: Decodable { struct Detail: Decodable { let code: String?; let message: String? }; let error: Detail }

    private let endpoint = URL(string: "https://ark.ap-southeast.bytepluses.com/api/v3/contents/generations/tasks")!
    private let root: URL
    private let imagesDirectory: URL
    private let stateURL: URL
    private let requestsDirectory: URL
    private var state: State
    private var running = Set<String>()
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }()

    init(root customRoot: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = customRoot ?? support.appendingPathComponent("CDance/Standalone", isDirectory: true)
        imagesDirectory = root.appendingPathComponent("Images", isDirectory: true)
        requestsDirectory = root.appendingPathComponent("Requests", isDirectory: true)
        stateURL = root.appendingPathComponent("state.json")
        let decoder = JSONDecoder.cdance()
        state = (try? Data(contentsOf: stateURL)).flatMap { try? decoder.decode(State.self, from: $0) } ?? State()
    }

    static var modelsResponse: ModelsResponse {
        let ratios = ["auto", "1:1", "4:3", "3:4", "16:9", "9:16", "3:2", "2:3", "21:9"]
        let models = [
            ModelInfo(id: "dreamina-seedance-2-5-260628", name: "Seedance 2.5", sizes: ["480p", "720p", "1080p", "4k"], defaultSize: "720p", maxReferenceImages: 30, aspectRatios: ratios),
            ModelInfo(id: "dreamina-seedance-2-5-flash-261115", name: "Seedance 2.5 Flash", sizes: ["480p", "720p"], defaultSize: "720p", maxReferenceImages: 10, aspectRatios: ratios),
            ModelInfo(id: "dreamina-seedance-2-0-260128", name: "Seedance 2.0", sizes: ["480p", "720p", "1080p"], defaultSize: "720p", maxReferenceImages: 9, aspectRatios: ratios),
            ModelInfo(id: "dreamina-seedance-2-0-fast-260128", name: "Seedance 2.0 Fast", sizes: ["480p", "720p", "1080p"], defaultSize: "720p", maxReferenceImages: 9, aspectRatios: ratios),
        ]
        return ModelsResponse(defaultModel: models[0].id, models: models)
    }

    func models() -> ModelsResponse { Self.modelsResponse }
    func prompts() -> [PromptTemplate] { state.prompts.sorted { $0.sortOrder < $1.sortOrder } }
    func referenceAssets() -> [ReferenceAsset] { state.referenceAssets.sorted { $0.updatedAt > $1.updatedAt } }
    func history() -> GenerationPage { GenerationPage(items: state.generations.sorted { $0.createdAt > $1.createdAt }, total: state.generations.count) }
    func providerConfiguration() -> ProviderConfiguration { ProviderConfiguration(configured: Keychain.providerAPIKey != nil, source: Keychain.providerAPIKey == nil ? "none" : "keychain", endpoint: endpoint.absoluteString, model: Self.modelsResponse.defaultModel) }
    func configureProvider(apiKey: String) throws -> ProviderConfiguration {
        let clean = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 12 else { throw APIClientError.server("Bitte einen gültigen Ark API-Key eingeben.") }
        Keychain.providerAPIKey = clean
        return providerConfiguration()
    }
    func removeProviderConfiguration() -> ProviderConfiguration { Keychain.providerAPIKey = nil; return providerConfiguration() }

    func generation(_ id: String) throws -> Generation {
        guard let value = state.generations.first(where: { $0.id == id }) else { throw APIClientError.server("Generation nicht gefunden.") }
        return value
    }

    func savePrompt(_ prompt: PromptTemplate?, name: String, text: String, description: String, category: String, tags: [String], favorite: Bool) throws -> PromptTemplate {
        let saved = PromptTemplate(id: prompt?.id ?? UUID().uuidString, name: name, text: text, description: description.isEmpty ? nil : description, category: category.isEmpty ? nil : category, tags: tags, favorite: favorite, sortOrder: prompt?.sortOrder ?? state.prompts.count)
        state.prompts.removeAll { $0.id == saved.id }; state.prompts.append(saved); try persist(); return saved
    }
    func deletePrompt(_ id: String) throws { state.prompts.removeAll { $0.id == id }; try persist() }
    func copyPrompt(_ id: String) throws -> PromptTemplate {
        guard let source = state.prompts.first(where: { $0.id == id }) else { throw APIClientError.server("Prompt-Baustein nicht gefunden.") }
        return try savePrompt(nil, name: source.name + " Kopie", text: source.text, description: source.description ?? "", category: source.category ?? "", tags: source.tags, favorite: source.favorite)
    }

    func saveReferenceAsset(name: String, reference: LocalReference) async throws -> ReferenceAsset {
        let data = try await data(for: reference)
        let image = try storeImage(data, role: "reference")
        let now = Date()
        let asset = ReferenceAsset(id: UUID().uuidString, name: name, category: nil, favorite: false, createdAt: now, updatedAt: now, image: image)
        state.referenceAssets.append(asset); try persist(); return asset
    }
    func deleteReferenceAsset(_ id: String) throws { state.referenceAssets.removeAll { $0.id == id }; try persist(); garbageCollect() }
    func renameReferenceAsset(_ id: String, name: String) throws -> ReferenceAsset {
        guard let index = state.referenceAssets.firstIndex(where: { $0.id == id }) else {
            throw APIClientError.server("Gespeichertes Referenzbild nicht gefunden.")
        }
        let source = state.referenceAssets[index]
        let renamed = ReferenceAsset(
            id: source.id,
            name: name,
            category: source.category,
            favorite: source.favorite,
            createdAt: source.createdAt,
            updatedAt: Date(),
            image: source.image
        )
        state.referenceAssets[index] = renamed
        try persist()
        return renamed
    }

    func createGeneration(prompt: String, finalPrompt: String, templateIDs: [String], references: [LocalReference], model: String, ratio: String, resolution: String, duration: Int, generateAudio: Bool, parentID: String?) async throws -> Generation {
        guard Keychain.providerAPIKey != nil else { throw APIClientError.server("Bitte zuerst unter Einstellungen deinen Ark API-Key hinterlegen.") }
        let effective = finalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effective.isEmpty else { throw APIClientError.server("Bitte einen Prompt eingeben oder Prompt-Bausteine auswählen.") }
        guard let capability = Self.modelsResponse.models.first(where: { $0.id == model }), capability.sizes.contains(resolution), capability.aspectRatios.contains(ratio) else { throw APIClientError.server("Modell, Auflösung oder Format wird nicht unterstützt.") }
        guard references.count <= capability.maxReferenceImages else { throw APIClientError.server("Dieses Modell unterstützt höchstens \(capability.maxReferenceImages) Referenzbilder.") }
        var links: [GenerationReference] = []
        for (index, reference) in references.enumerated() {
            let image: APIImage
            if let remote = reference.remote, isLocal(remote) { image = remote }
            else { image = try storeImage(try await data(for: reference), role: "reference") }
            links.append(GenerationReference(id: UUID().uuidString, position: index, purpose: "reference", image: image))
        }
        let templates = templateIDs.compactMap { id in state.prompts.first(where: { $0.id == id }) }.enumerated().map {
            GenerationPromptTemplate(id: $0.element.id, name: $0.element.name, text: $0.element.text, position: $0.offset)
        }
        let generation = Generation(id: UUID().uuidString, parentID: parentID, kind: parentID == nil ? "generate" : "edit", status: "queued", prompt: prompt, finalPrompt: effective, model: model, aspectRatio: ratio, resolution: resolution, errorMessage: nil, createdAt: Date(), images: [], references: links, promptTemplates: templates)
        state.generations.insert(generation, at: 0)
        state.generationOptions[generation.id] = GenerationOptions(duration: min(max(duration, 3), 30), generateAudio: generateAudio)
        try persist()
        if UserDefaults.standard.bool(forKey: "autoSavePhotos") {
            await AutomaticPhotoSaveTracker.shared.register(generation.id)
        }
        start(generation.id)
        return generation
    }

    func regenerate(_ id: String, variation: Bool = false) throws -> Generation {
        let source = try generation(id)
        guard Keychain.providerAPIKey != nil else { throw APIClientError.server("Bitte zuerst unter Einstellungen deinen Ark API-Key hinterlegen.") }
        var references = source.references
        if variation, let result = source.resultImage {
            references.removeAll { $0.image.id == result.id }
            references.insert(GenerationReference(id: UUID().uuidString, position: 0, purpose: "variation_source", image: result), at: 0)
        }
        references = references.enumerated().map { GenerationReference(id: UUID().uuidString, position: $0.offset, purpose: $0.element.purpose, image: $0.element.image) }
        let copy = Generation(id: UUID().uuidString, parentID: source.id, kind: variation ? "variation" : "regenerate", status: "queued", prompt: source.prompt, finalPrompt: source.finalPrompt, model: source.model, aspectRatio: source.aspectRatio, resolution: source.resolution, errorMessage: nil, createdAt: Date(), images: [], references: references, promptTemplates: source.promptTemplates)
        state.generations.insert(copy, at: 0); try persist(); start(copy.id); return copy
    }

    func deleteGeneration(_ id: String) throws { state.generations.removeAll { $0.id == id }; try persist(); garbageCollect() }

    func data(for image: APIImage) throws -> Data {
        guard isLocal(image), let filename = image.downloadURL.host else { throw APIClientError.invalidResponse }
        let url = imagesDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw APIClientError.invalidResponse }
        return data
    }

    func resumePendingGenerations() async {
        for generation in state.generations where generation.status == "queued" || generation.status == "processing" {
            if await StandaloneBackgroundTransfer.shared.contains(generationID: generation.id) {
                running.insert(generation.id)
            } else if state.providerTasks[generation.id] != nil {
                running.insert(generation.id)
                Task { await pollProviderTask(for: generation.id) }
            } else {
                start(generation.id)
            }
        }
    }

    private func start(_ id: String) {
        guard !running.contains(id) else { return }
        running.insert(id)
        Task { await process(id) }
    }

    private func process(_ id: String) async {
        guard var generation = state.generations.first(where: { $0.id == id }) else { return }
        generation = replacing(generation, status: "processing")
        replace(generation); try? persist()
        do {
            guard let key = Keychain.providerAPIKey else { throw APIClientError.server("Der Ark API-Key fehlt.") }
            let inputs = try generation.references.map { reference -> (String, String) in
                let data = try self.data(for: reference.image)
                return ("data:\(reference.image.mimeType);base64,\(data.base64EncodedString())", reference.image.mimeType)
            }
            var content = [ArkContent(type: "text", text: generation.finalPrompt, imageURL: nil, role: nil)]
            content.append(contentsOf: inputs.map {
                ArkContent(type: $0.1.hasPrefix("video/") ? "video_url" : "image_url", text: nil, imageURL: ArkMediaURL(url: $0.0), role: $0.1.hasPrefix("video/") ? "reference_video" : "reference_image")
            })
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"; request.timeoutInterval = 120
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let options = state.generationOptions[id] ?? GenerationOptions(duration: 5, generateAudio: true)
            let body = try encoder.encode(ArkRequest(
                model: generation.model,
                content: content,
                resolution: generation.resolution,
                ratio: generation.aspectRatio == "auto" ? "adaptive" : generation.aspectRatio,
                duration: options.duration,
                generateAudio: options.generateAudio
            ))
            try FileManager.default.createDirectory(at: requestsDirectory, withIntermediateDirectories: true)
            let bodyURL = requestsDirectory.appendingPathComponent("\(id).json")
            try body.write(to: bodyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var protectedURL = bodyURL; try? protectedURL.setResourceValues(values)
            StandaloneBackgroundTransfer.shared.enqueueGeneration(request: request, bodyFile: bodyURL, generationID: id)
        } catch {
            fail(id, error: error)
        }
    }

    func receiveProviderResponse(generationID id: String, data: Data, response: HTTPURLResponse?, error: Error?) async {
        if let error {
            if Self.isTransientBackgroundError(error) {
                scheduleRetry(id)
                return
            }
            try? FileManager.default.removeItem(at: requestsDirectory.appendingPathComponent("\(id).json"))
            fail(id, error: Self.backgroundError(error))
            return
        }
        try? FileManager.default.removeItem(at: requestsDirectory.appendingPathComponent("\(id).json"))
        guard let response else { fail(id, error: APIClientError.invalidResponse); return }
        guard 200..<300 ~= response.statusCode else { fail(id, error: providerError(status: response.statusCode, data: data)); return }
        do {
            let result = try JSONDecoder().decode(ArkCreateResponse.self, from: data)
            state.providerTasks[id] = result.id
            try persist()
            await pollProviderTask(for: id)
        } catch {
            fail(id, error: error)
        }
    }

    private func pollProviderTask(for generationID: String) async {
        guard let taskID = state.providerTasks[generationID], let key = Keychain.providerAPIKey else {
            fail(generationID, error: APIClientError.invalidResponse)
            return
        }
        let deadline = Date().addingTimeInterval(35 * 60)
        while Date() < deadline {
            do {
                var request = URLRequest(url: endpoint.appendingPathComponent(taskID))
                request.timeoutInterval = 90
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
                guard 200..<300 ~= http.statusCode else { throw providerError(status: http.statusCode, data: data) }
                let task = try JSONDecoder().decode(ArkTaskResponse.self, from: data)
                switch task.status {
                case "succeeded":
                    guard let url = task.content?.videoURL else { throw APIClientError.server("C-Dance hat keine Videodatei geliefert.") }
                    StandaloneBackgroundTransfer.shared.enqueueResult(url: url, generationID: generationID)
                    return
                case "failed", "cancelled", "expired":
                    throw APIClientError.server("Die Filmgenerierung ist beim Anbieter fehlgeschlagen.")
                default:
                    try await Task.sleep(for: .seconds(20))
                }
            } catch is CancellationError {
                running.remove(generationID)
                return
            } catch let error as URLError where Self.isTransientBackgroundError(error) {
                try? await Task.sleep(for: .seconds(5))
            } catch {
                fail(generationID, error: error)
                return
            }
        }
        fail(generationID, error: APIClientError.server("Die Filmgenerierung hat das maximale Zeitlimit überschritten."))
    }

    func receiveResult(generationID id: String, data: Data?, error: Error?) async {
        if let error {
            if Self.isTransientBackgroundError(error) {
                running.remove(id)
                return
            }
            fail(id, error: Self.backgroundError(error))
            return
        }
        guard let data, !data.isEmpty else { fail(id, error: APIClientError.invalidResponse); return }
        do {
            guard var generation = state.generations.first(where: { $0.id == id }) else { running.remove(id); return }
            let resultImage = try storeVideo(data, role: "result")
            generation = replacing(generation, status: "completed", images: [resultImage])
            state.providerTasks[id] = nil
            state.generationOptions[id] = nil
            replace(generation); try persist(); running.remove(id)
            try? await PhotoLibraryService.saveAutomatically(data, generationID: id)
            await notify(generation)
        } catch {
            fail(id, error: error)
        }
    }

    private func fail(_ id: String, error: Error) {
        guard let generation = state.generations.first(where: { $0.id == id }) else { running.remove(id); return }
        replace(replacing(generation, status: "failed", error: error.localizedDescription))
        state.providerTasks[id] = nil
        state.generationOptions[id] = nil
        try? persist(); running.remove(id)
        Task { await AutomaticPhotoSaveTracker.shared.abandon(id) }
    }

    private static func backgroundError(_ error: Error) -> Error {
        let value = error as NSError
        if value.domain == NSURLErrorDomain,
           [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut].contains(value.code) {
            return APIClientError.server("Die Hintergrundübertragung wurde unterbrochen. Bitte den Auftrag erneut einreichen.")
        }
        return error
    }

    private static func isTransientBackgroundError(_ error: Error) -> Bool {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut].contains(value.code)
    }

    private func scheduleRetry(_ id: String) {
        running.remove(id)
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard state.generations.contains(where: { $0.id == id && ($0.status == "queued" || $0.status == "processing") }) else { return }
            start(id)
        }
    }

    private func data(for reference: LocalReference) async throws -> Data {
        if let value = reference.data { guard let normalized = UIImage.cdanceUploadJPEG(from: value) else { throw APIClientError.invalidImage }; return normalized }
        if let remote = reference.remote {
            if isLocal(remote) { return try data(for: remote) }
            return try await APIClient.shared.remoteImageData(remote)
        }
        throw APIClientError.invalidImage
    }

    private func storeImage(_ data: Data, role: String) throws -> APIImage {
        guard let image = UIImage(data: data) else { throw APIClientError.invalidImage }
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        let filename = id + (mime == "image/png" ? ".png" : ".jpg")
        try data.write(to: imagesDirectory.appendingPathComponent(filename), options: .atomic)
        return APIImage(id: id, role: role, mimeType: mime, width: Int(image.size.width), height: Int(image.size.height), byteSize: data.count, downloadURL: URL(string: "cdance-local://\(filename)")!)
    }

    private func storeVideo(_ data: Data, role: String) throws -> APIImage {
        guard data.count > 12 else { throw APIClientError.invalidResponse }
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let filename = id + ".mp4"
        try data.write(to: imagesDirectory.appendingPathComponent(filename), options: .atomic)
        return APIImage(id: id, role: role, mimeType: "video/mp4", width: nil, height: nil, byteSize: data.count, downloadURL: URL(string: "cdance-local://\(filename)")!)
    }

    private func replace(_ generation: Generation) { state.generations.removeAll { $0.id == generation.id }; state.generations.insert(generation, at: 0) }
    private func replacing(_ source: Generation, status: String, images: [APIImage]? = nil, error: String? = nil) -> Generation {
        Generation(id: source.id, parentID: source.parentID, kind: source.kind, status: status, prompt: source.prompt, finalPrompt: source.finalPrompt, model: source.model, aspectRatio: source.aspectRatio, resolution: source.resolution, errorMessage: error, createdAt: source.createdAt, images: images ?? source.images, references: source.references, promptTemplates: source.promptTemplates)
    }
    private func persist() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try encoder.encode(state).write(to: stateURL, options: .atomic) }
    private func isLocal(_ image: APIImage) -> Bool { image.downloadURL.scheme == "cdance-local" }
    private func garbageCollect() {
        let retained = Set(state.generations.flatMap { $0.images + $0.references.map(\.image) }.map(\.downloadURL.host).compactMap { $0 } + state.referenceAssets.compactMap { $0.image.downloadURL.host })
        guard let files = try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where !retained.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }
    private func providerError(status: Int, data: Data) -> Error {
        let detail = try? JSONDecoder().decode(ArkErrorEnvelope.self, from: data).error
        let lower = "\(detail?.code ?? "") \(detail?.message ?? "")".lowercased()
        if status == 401 || status == 403 { return APIClientError.server("Der Ark API-Key ist ungültig oder nicht für Seedance freigeschaltet.") }
        if status == 429 { return APIClientError.server("Das Film-Limit ist gerade erreicht. Bitte kurz warten und erneut versuchen.") }
        if lower.contains("sensitive") || lower.contains("policy") { return APIClientError.server("Die Anfrage wurde durch die Inhaltsrichtlinien des Videoanbieters abgelehnt.") }
        if lower.contains("balance") || lower.contains("quota") { return APIClientError.server("Für die Filmgenerierung ist nicht genügend Guthaben oder Kontingent verfügbar.") }
        if status == 400 { return APIClientError.server("Seedance konnte diese Kombination aus Prompt, Referenzen und Einstellungen nicht verarbeiten.") }
        return APIClientError.server("Die Filmgenerierung ist beim Anbieter fehlgeschlagen (\(status)).")
    }
    private func notify(_ generation: Generation) async {
        guard UserDefaults.standard.bool(forKey: "pushNotificationsEnabled") else { return }
        let content = UNMutableNotificationContent(); content.title = "Film ist fertig"; content.body = "Deine C-Dance-Generierung ist abgeschlossen."; content.sound = .default
        content.userInfo = ["generation_id": generation.id]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "standalone-\(generation.id)", content: content, trigger: nil))
    }
}

final class StandaloneBackgroundTransfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = StandaloneBackgroundTransfer()
    static let identifier = "info.schreiber.cdance.standalone-generation"

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "CDance standalone background transfer"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 2_700
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()
    private var responseBodies: [Int: Data] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private var pendingCompletions = 0
    private var didFinishEventDelivery = false

    func enqueueGeneration(request: URLRequest, bodyFile: URL, generationID: String) {
        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = "generation:\(generationID)"
        task.resume()
    }

    func enqueueResult(url: URL, generationID: String) {
        let task = session.downloadTask(with: url)
        task.taskDescription = "result:\(generationID)"
        task.resume()
    }

    func contains(generationID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.contains { task in
                    task.taskDescription == "generation:\(generationID)" || task.taskDescription == "result:\(generationID)"
                })
            }
        }
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        didFinishEventDelivery = false
        _ = session
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = Self.generationID(from: downloadTask.taskDescription, prefix: "result:"),
              let data = try? Data(contentsOf: location) else { return }
        Task { await StandaloneService.shared.receiveResult(generationID: id, data: data, error: nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let description = task.taskDescription else { return }
        if let id = Self.generationID(from: description, prefix: "generation:") {
            let data = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
            pendingCompletions += 1
            Task {
                await StandaloneService.shared.receiveProviderResponse(
                    generationID: id,
                    data: data,
                    response: task.response as? HTTPURLResponse,
                    error: error
                )
                self.delegateQueue.addOperation { self.completedDelegateWork() }
            }
        } else if let id = Self.generationID(from: description, prefix: "result:"), let error {
            if Self.isTransient(error), let url = task.originalRequest?.url {
                enqueueResult(url: url, generationID: id)
                return
            }
            pendingCompletions += 1
            Task {
                await StandaloneService.shared.receiveResult(generationID: id, data: nil, error: error)
                self.delegateQueue.addOperation { self.completedDelegateWork() }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        didFinishEventDelivery = true
        completeBackgroundEventsIfPossible()
    }

    private func completedDelegateWork() {
        pendingCompletions = max(0, pendingCompletions - 1)
        completeBackgroundEventsIfPossible()
    }

    private func completeBackgroundEventsIfPossible() {
        guard didFinishEventDelivery, pendingCompletions == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    private static func generationID(from description: String?, prefix: String) -> String? {
        guard let description, description.hasPrefix(prefix) else { return nil }
        return String(description.dropFirst(prefix.count))
    }

    private static func isTransient(_ error: Error) -> Bool {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut].contains(value.code)
    }
}
