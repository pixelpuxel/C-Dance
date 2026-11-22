import CryptoKit
import Foundation

actor ImageDiskCache {
    static let shared = ImageDiskCache()

    private struct Entry: Codable {
        let imageID: String
        let variant: String
        let filename: String
        let byteSize: Int
        var lastAccess: Date
    }

    private let fileManager = FileManager.default
    private let directory: URL
    private let indexURL: URL
    private let memory = NSCache<NSString, NSData>()
    private var entries: [String: Entry]
    private let maximumDiskBytes = 750 * 1_024 * 1_024

    init(directory customDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = customDirectory ?? support.appendingPathComponent("CDance/ImageCache", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
        // Encoded image data shares the process memory with decoded UIKit images.
        // Keep this deliberately small so a long history cannot trigger a jetsam.
        memory.totalCostLimit = 32 * 1_024 * 1_024
        memory.countLimit = 80
    }

    func data(for image: APIImage, variant: String) -> Data? {
        let key = cacheKey(for: image, variant: variant)
        if let cached = memory.object(forKey: key as NSString) {
            touch(key)
            return cached as Data
        }
        guard let entry = entries[key],
              let data = try? Data(contentsOf: directory.appendingPathComponent(entry.filename)),
              !data.isEmpty else {
            removeEntry(key)
            return nil
        }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        touch(key)
        return data
    }

    /// Returns the largest thumbnail that is already available locally.
    /// Result screens can use it immediately while the full-resolution image
    /// continues loading, without starting another network request.
    func bestThumbnailData(for image: APIImage) -> Data? {
        let knownSizes = [1024, 768, 512, 384, 320, 256, 192, 128, 96, 64]
        for size in knownSizes {
            if let data = data(for: image, variant: "thumbnail-\(size)") {
                return data
            }
        }
        return nil
    }

    func store(_ data: Data, for image: APIImage, variant: String) {
        guard !data.isEmpty else { return }
        prepareDirectory()
        let key = cacheKey(for: image, variant: variant)
        for (oldKey, entry) in entries where entry.imageID == image.id && entry.variant == variant && oldKey != key {
            removeEntry(oldKey)
        }
        let filename = "\(key).image"
        do {
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            entries[key] = Entry(imageID: image.id, variant: variant, filename: filename, byteSize: data.count, lastAccess: Date())
            memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            trimIfNeeded()
            saveIndex()
        } catch {
            // A cache failure must never prevent the image from being displayed.
        }
    }

    func remove(imageIDs: Set<String>) {
        guard !imageIDs.isEmpty else { return }
        for (key, entry) in entries where imageIDs.contains(entry.imageID) {
            removeEntry(key)
        }
        saveIndex()
    }

    func removeAll() {
        memory.removeAllObjects()
        entries.removeAll()
        try? fileManager.removeItem(at: directory)
    }

    func releaseMemory() {
        memory.removeAllObjects()
    }

    private func cacheKey(for image: APIImage, variant: String) -> String {
        let identity = "\(image.id)|\(image.byteSize)|\(image.width ?? 0)x\(image.height ?? 0)|\(image.mimeType)|\(variant)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func prepareDirectory() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    private func touch(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.lastAccess = Date()
        entries[key] = entry
    }

    private func removeEntry(_ key: String) {
        memory.removeObject(forKey: key as NSString)
        if let entry = entries.removeValue(forKey: key) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry.filename))
        }
    }

    private func trimIfNeeded() {
        var total = entries.values.reduce(0) { $0 + $1.byteSize }
        guard total > maximumDiskBytes else { return }
        for (key, entry) in entries.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            removeEntry(key)
            total -= entry.byteSize
            if total <= maximumDiskBytes { break }
        }
    }

    private func saveIndex() {
        prepareDirectory()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

struct LocalAppSnapshot: Codable {
    let mode: AppMode
    let models: [ModelInfo]
    let prompts: [PromptTemplate]
    let referenceAssets: [ReferenceAsset]
    let generations: [Generation]
    let providerConfiguration: ProviderConfiguration?
    let savedAt: Date
}

enum LocalAppSnapshotStore {
    private static func fileURL(for mode: AppMode) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("CDance", isDirectory: true).appendingPathComponent("app-snapshot-\(mode.rawValue).json")
    }

    private static var legacyFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("CDance", isDirectory: true).appendingPathComponent("app-snapshot.json")
    }

    static func load(for mode: AppMode) -> LocalAppSnapshot? {
        let target = fileURL(for: mode)
        guard let data = try? Data(contentsOf: target) else {
            // Snapshots created before the two modes existed always belonged to
            // the original server workflow. Never migrate them into standalone.
            guard mode == .server,
                  let legacyData = try? Data(contentsOf: legacyFileURL),
                  let legacy = decodeLegacy(legacyData) else { return nil }
            save(legacy)
            try? FileManager.default.removeItem(at: legacyFileURL)
            return legacy
        }
        let decoder = JSONDecoder.cdance()
        guard let snapshot = try? decoder.decode(LocalAppSnapshot.self, from: data), snapshot.mode == mode else { return nil }
        return snapshot
    }

    static func save(_ snapshot: LocalAppSnapshot) {
        let fileURL = fileURL(for: snapshot.mode)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // The server remains authoritative if local persistence is unavailable.
        }
    }

    static func remove(for mode: AppMode) {
        try? FileManager.default.removeItem(at: fileURL(for: mode))
        if mode == .server { try? FileManager.default.removeItem(at: legacyFileURL) }
    }

    private static func decodeLegacy(_ data: Data) -> LocalAppSnapshot? {
        struct LegacySnapshot: Codable {
            let models: [ModelInfo]
            let prompts: [PromptTemplate]
            let referenceAssets: [ReferenceAsset]
            let generations: [Generation]
            let providerConfiguration: ProviderConfiguration?
            let savedAt: Date
        }
        let decoder = JSONDecoder.cdance()
        guard let legacy = try? decoder.decode(LegacySnapshot.self, from: data) else { return nil }
        // During the first standalone builds both modes briefly shared this legacy
        // file. A local URL proves that the last writer was standalone, so that
        // payload must never be shown as cached server history.
        let containsStandaloneImages = legacy.generations.contains { generation in
            (generation.images + generation.references.map(\.image)).contains {
                $0.downloadURL.scheme == "cdance-local"
            }
        } || legacy.referenceAssets.contains { $0.image.downloadURL.scheme == "cdance-local" }
        guard !containsStandaloneImages else { return nil }
        return LocalAppSnapshot(
            mode: .server,
            models: legacy.models,
            prompts: legacy.prompts,
            referenceAssets: legacy.referenceAssets,
            generations: legacy.generations,
            providerConfiguration: legacy.providerConfiguration,
            savedAt: legacy.savedAt
        )
    }
}
