import Foundation
import ImageIO
import UIKit

private enum CDanceDateParser {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension JSONDecoder {
    /// The backend emits RFC 3339 timestamps with microseconds. Apple's
    /// `.iso8601` strategy only became tolerant of those on newer OS releases,
    /// so parse both fractional and plain timestamps explicitly for iOS/iPadOS 17+.
    static func cdance() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = CDanceDateParser.fractional.date(from: value) { return date }
            if let date = CDanceDateParser.standard.date(from: value) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Ungültiger ISO-8601-Zeitstempel: \(value)"
            )
        }
        return decoder
    }
}

enum AppMode: String, Codable, CaseIterable, Identifiable {
    case standalone
    case server

    var id: String { rawValue }
    var title: String { self == .standalone ? "Standalone" : "Eigener Server" }
}

enum AppModeConfiguration {
    static let modeKey = "cdance.appMode"
    static let onboardingKey = "cdance.onboardingCompleted"
    static let serverURLKey = "cdance.serverURL"
    static let defaultServerURL = URL(string: "https://seadance.vps2.schreiber.info/api/v1")!

    static var mode: AppMode {
        get {
            if let value = UserDefaults.standard.string(forKey: modeKey), let mode = AppMode(rawValue: value) { return mode }
            let migrated: AppMode = Keychain.token == nil ? .standalone : .server
            UserDefaults.standard.set(migrated.rawValue, forKey: modeKey)
            if migrated == .server { UserDefaults.standard.set(true, forKey: onboardingKey) }
            return migrated
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var onboardingCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingKey) }
    }

    static var serverURL: URL {
        get { UserDefaults.standard.url(forKey: serverURLKey) ?? defaultServerURL }
        set { UserDefaults.standard.set(newValue, forKey: serverURLKey) }
    }

    static func normalizedServerURL(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let host = components.host, !host.isEmpty else { return nil }
        let localHosts = ["localhost", "127.0.0.1", "::1"]
        guard components.scheme == "https"
                || (components.scheme == "http" && localHosts.contains(host.lowercased())) else { return nil }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty || path == "api" || path == "v1" {
            path = "api/v1"
        } else if path.hasSuffix("/api") {
            path += "/v1"
        } else if path != "api/v1" && !path.hasSuffix("/api/v1") {
            path += "/api/v1"
        }
        components.path = "/" + path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct APIImage: Codable, Identifiable, Hashable {
    let id: String
    let role: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let byteSize: Int
    let downloadURL: URL
    var isVideo: Bool { mimeType.hasPrefix("video/") }
    enum CodingKeys: String, CodingKey { case id, role, width, height; case mimeType = "mime_type"; case byteSize = "byte_size"; case downloadURL = "download_url" }
}

struct GenerationReference: Codable, Identifiable, Hashable { let id: String; let position: Int; let purpose: String; let image: APIImage }

struct GenerationPromptTemplate: Codable, Hashable {
    let id: String?
    let name: String
    let text: String
    let position: Int
    var stableID: String { id ?? "\(position)-\(name)" }
}

struct Generation: Codable, Identifiable, Hashable {
    let id: String
    let parentID: String?
    let kind: String
    let status: String
    let prompt: String
    let finalPrompt: String
    let model: String
    let aspectRatio: String
    let resolution: String
    let errorMessage: String?
    let createdAt: Date
    let images: [APIImage]
    let references: [GenerationReference]
    var promptTemplates: [GenerationPromptTemplate] = []
    var favorite: Bool? = nil
    var rating: Int? = nil
    var resultImage: APIImage? { images.first(where: { $0.role == "result" }) }
    enum CodingKeys: String, CodingKey { case id, kind, status, prompt, model, resolution, images, references, favorite, rating; case parentID = "parent_id"; case finalPrompt = "final_prompt"; case aspectRatio = "aspect_ratio"; case errorMessage = "error_message"; case createdAt = "created_at"; case promptTemplates = "prompt_templates" }
}

struct GenerationPage: Codable { let items: [Generation]; let total: Int }

struct PromptTemplate: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var text: String
    var description: String?
    var category: String?
    var tags: [String]
    var favorite: Bool
    var sortOrder: Int
    enum CodingKeys: String, CodingKey { case id, name, text, description, category, tags, favorite; case sortOrder = "sort_order" }
}

struct ReferenceAsset: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String?
    let favorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let image: APIImage
    enum CodingKeys: String, CodingKey {
        case id, name, category, favorite, image
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct SeedreamLibraryItem: Codable, Identifiable, Hashable {
    let id: String
    let generationID: String
    let sourceImageID: String
    let prompt: String
    let finalPrompt: String
    let createdAt: Date
    let image: APIImage
    enum CodingKeys: String, CodingKey {
        case id, prompt, image
        case generationID = "generation_id"
        case sourceImageID = "source_image_id"
        case finalPrompt = "final_prompt"
        case createdAt = "created_at"
    }
}

struct SeedreamLibraryPage: Codable {
    let items: [SeedreamLibraryItem]
    let total: Int
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case prompts
    case references

    var id: String { rawValue }
    var title: String { self == .prompts ? "Prompts" : "Referenzbilder" }
}

struct ModelInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let sizes: [String]
    let defaultSize: String
    let maxReferenceImages: Int
    let aspectRatios: [String]
    enum CodingKeys: String, CodingKey { case id, name, sizes; case defaultSize = "default_size"; case maxReferenceImages = "max_reference_images"; case aspectRatios = "aspect_ratios" }
}

struct ModelsResponse: Codable { let defaultModel: String; let models: [ModelInfo]; enum CodingKeys: String, CodingKey { case models; case defaultModel = "default_model" } }
struct ProviderConfiguration: Codable, Equatable {
    let configured: Bool
    let source: String
    let endpoint: String
    let model: String

    init(configured: Bool, source: String, endpoint: String, model: String) {
        self.configured = configured
        self.source = source
        self.endpoint = endpoint
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case configured, source, endpoint, model, data, configuration
        case apiKeyConfigured = "api_key_configured"
        case hasAPIKey = "has_api_key"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? values.decode(ProviderConfiguration.self, forKey: .data) {
            self = nested
            return
        }
        if let nested = try? values.decode(ProviderConfiguration.self, forKey: .configuration) {
            self = nested
            return
        }
        let configured = try values.decodeIfPresent(Bool.self, forKey: .configured)
            ?? values.decodeIfPresent(Bool.self, forKey: .apiKeyConfigured)
            ?? values.decodeIfPresent(Bool.self, forKey: .hasAPIKey)
            ?? false
        self.configured = configured
        self.source = try values.decodeIfPresent(String.self, forKey: .source)
            ?? (configured ? "server" : "missing")
        self.endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        self.model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(configured, forKey: .configured)
        try values.encode(source, forKey: .source)
        try values.encode(endpoint, forKey: .endpoint)
        try values.encode(model, forKey: .model)
    }
}
struct TokenResponse: Codable {
    let accessToken: String
    let sessionToken: String
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case sessionToken = "session_token" }
}

struct LocalReference: Identifiable {
    let id = UUID()
    var data: Data? = nil
    var remote: APIImage? = nil
    var preview: UIImage
}

struct MarkupEditContext: Identifiable {
    let id = UUID()
    let image: UIImage
    let referenceID: UUID
}

extension UIImage {
    static func referencePreview(from data: Data, maxPixelSize: CGFloat = 512) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: image)
    }

    static func cdanceUploadJPEG(from data: Data, maxDimension: CGFloat = 4_096) -> Data? {
        // Decode only the pixels that can actually be uploaded. UIImage(data:)
        // may otherwise expand a very large HEIC/JPEG to hundreds of MB.
        guard let image = referencePreview(from: data, maxPixelSize: maxDimension) else { return nil }
        return image.cdanceUploadJPEG(maxDimension: maxDimension)
    }

    func cdanceUploadJPEG(maxDimension: CGFloat = 4_096) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let targetSize = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return normalized.jpegData(compressionQuality: 0.92)
    }
}

struct EditRequest: Identifiable { let id = UUID(); let generation: Generation; let image: UIImage }
struct ReferenceRequest: Identifiable {
    let id = UUID()
    let image: APIImage
    let preview: UIImage
    let startsNewDraft: Bool

    init(image: APIImage, preview: UIImage, startsNewDraft: Bool = false) {
        self.image = image
        self.preview = preview
        self.startsNewDraft = startsNewDraft
    }
}
struct SetupRequest: Identifiable { let id = UUID(); let generation: Generation }
struct MergedSetupRequest: Identifiable {
    let id = UUID()
    let prompt: String
    let references: [APIImage]
    let model: String
    let aspectRatio: String
    let resolution: String
}

struct GeneratorDraft: Codable {
    struct Reference: Codable {
        let data: Data?
        let remote: APIImage?
        let previewData: Data
    }

    let references: [Reference]
    let selectedTemplateIDs: [String]
    let freeText: String
    let finalPrompt: String
    let selectedModel: String
    let ratio: String
    let resolution: String
    let editingParent: Generation?
}

enum GeneratorDraftStore {
    private static func fileURL(for mode: AppMode) -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return directory.appendingPathComponent("CDance", isDirectory: true).appendingPathComponent("generator-draft-\(mode.rawValue).json")
    }

    private static var legacyFileURL: URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return directory.appendingPathComponent("CDance", isDirectory: true).appendingPathComponent("generator-draft.json")
    }

    static func load(for mode: AppMode) -> GeneratorDraft? {
        guard let fileURL = fileURL(for: mode) else { return nil }
        if mode == .server, !FileManager.default.fileExists(atPath: fileURL.path),
           let legacyFileURL, FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try? FileManager.default.moveItem(at: legacyFileURL, to: fileURL)
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(GeneratorDraft.self, from: data)
    }

    static func save(_ draft: GeneratorDraft, for mode: AppMode) {
        guard let fileURL = fileURL(for: mode) else { return }
        guard let data = try? JSONEncoder().encode(draft) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A failed draft write must never interrupt image generation.
        }
    }
}
