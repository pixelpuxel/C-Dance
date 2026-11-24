import Photos
import UIKit

enum PhotoLibraryError: LocalizedError {
    case permission, saveFailed
    var errorDescription: String? { self == .permission ? "Bitte erlaube den Fotozugriff in den iOS-Einstellungen." : "Der Film konnte nicht in Fotos gespeichert werden." }
}

enum PhotoAlbumPreferences {
    private static let key = "cdance.additionalPhotoAlbumNames"

    static func load() -> [String] {
        normalized(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ names: [String]) {
        UserDefaults.standard.set(normalized(names), forKey: key)
    }

    static func availableAlbums(defaultAlbumName: String) -> [String] {
        normalized([defaultAlbumName] + load())
    }

    private static func normalized(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let comparisonKey = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(comparisonKey).inserted else { return nil }
            return name
        }
    }
}

enum PhotoLibraryService {
    /// Claims a pending automatic save before any network download starts.
    /// Previously the app downloaded every completed history image first and
    /// only then discovered that it had already been saved.
    static func beginAutomaticSave(generationID: String) async -> Bool {
        guard UserDefaults.standard.bool(forKey: "autoSavePhotos") else {
            await AutomaticPhotoSaveTracker.shared.abandon(generationID)
            return false
        }
        return await AutomaticPhotoSaveTracker.shared.claim(generationID)
    }

    static func cancelAutomaticSave(generationID: String) async {
        await AutomaticPhotoSaveTracker.shared.release(generationID)
    }

    static func prepare(albumName: String?) async throws {
        let level: PHAccessLevel = albumName == nil ? .addOnly : .readWrite
        let status = await PHPhotoLibrary.requestAuthorization(for: level)
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.permission }
        if let albumName, !albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await album(named: albumName)
        }
    }

    @discardableResult
    static func save(_ data: Data, albumName: String?) async throws -> String {
        try await prepare(albumName: albumName)
        let assetID = try await createAsset(from: data)
        if let albumName, !albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await addAsset(assetID, to: [albumName])
        }
        return assetID
    }

    /// Adds an already saved Photos asset to further albums. A new asset is
    /// only created when this generation has never been saved before and no
    /// matching asset can be recovered from the default CDance album.
    @discardableResult
    static func saveOrAddExisting(
        _ data: Data,
        generationID: String,
        albumNames: [String],
        sourceAlbumName: String?
    ) async throws -> String {
        let names = normalizedAlbumNames(albumNames)
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.permission }

        var assetID = await PhotoAssetLinkStore.shared.assetID(for: generationID)
        if let stored = assetID,
           PHAsset.fetchAssets(withLocalIdentifiers: [stored], options: nil).firstObject == nil {
            await PhotoAssetLinkStore.shared.remove(generationID: generationID)
            assetID = nil
        }

        if assetID == nil,
           let sourceAlbumName,
           !sourceAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            assetID = await findMatchingAsset(for: data, inAlbumNamed: sourceAlbumName)
        }

        if assetID == nil {
            assetID = try await createAsset(from: data)
        }
        guard let assetID else { throw PhotoLibraryError.saveFailed }
        await PhotoAssetLinkStore.shared.set(assetID: assetID, generationID: generationID)
        try await addAsset(assetID, to: names)
        return assetID
    }

    /// Saves a downloaded movie from a file URL. Photos rejects some valid
    /// movie containers when they are submitted as an in-memory data resource
    /// (PHPhotosErrorDomain 3300), while the same file is accepted through the
    /// file-URL API.
    @discardableResult
    static func saveOrAddExisting(
        fileURL: URL,
        generationID: String,
        albumNames: [String]
    ) async throws -> String {
        let names = normalizedAlbumNames(albumNames)
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.permission }

        var assetID = await PhotoAssetLinkStore.shared.assetID(for: generationID)
        if let stored = assetID,
           PHAsset.fetchAssets(withLocalIdentifiers: [stored], options: nil).firstObject == nil {
            await PhotoAssetLinkStore.shared.remove(generationID: generationID)
            assetID = nil
        }
        if assetID == nil {
            assetID = try await createVideoAsset(from: fileURL)
        }
        guard let assetID else { throw PhotoLibraryError.saveFailed }
        await PhotoAssetLinkStore.shared.set(assetID: assetID, generationID: generationID)
        try await addAsset(assetID, to: names)
        return assetID
    }

    @discardableResult
    static func saveAutomatically(_ data: Data, generationID: String, alreadyClaimed: Bool = false) async throws -> Bool {
        guard UserDefaults.standard.bool(forKey: "autoSavePhotos") else {
            await AutomaticPhotoSaveTracker.shared.abandon(generationID)
            return false
        }
        if !alreadyClaimed {
            guard await AutomaticPhotoSaveTracker.shared.claim(generationID) else { return false }
        }
        do {
            let useAlbum = UserDefaults.standard.bool(forKey: "autoSaveAlbum")
            let albumName = useAlbum ? (UserDefaults.standard.string(forKey: "albumName") ?? "CDance") : nil
            let assetID = try await save(data, albumName: albumName)
            await PhotoAssetLinkStore.shared.set(assetID: assetID, generationID: generationID)
            await AutomaticPhotoSaveTracker.shared.finish(generationID)
            return true
        } catch {
            await AutomaticPhotoSaveTracker.shared.release(generationID)
            throw error
        }
    }

    private static func album(named name: String) async throws -> PHAssetCollection {
        let options = PHFetchOptions(); options.predicate = NSPredicate(format: "title = %@", name)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject { return existing }
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges { identifier = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name).placeholderForCreatedAssetCollection.localIdentifier }
        guard let identifier, let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else { throw PhotoLibraryError.saveFailed }
        return result
    }

    private static func createAsset(from data: Data) async throws -> String {
        if isVideo(data) {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("CDance-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            do {
                try data.write(to: temporaryURL, options: .atomic)
                return try await createVideoAsset(from: temporaryURL)
            } catch is PhotoLibraryError {
                throw PhotoLibraryError.saveFailed
            } catch {
                throw PhotoLibraryError.saveFailed
            }
        }
        var assetID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                assetID = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw PhotoLibraryError.saveFailed
        }
        guard let assetID else { throw PhotoLibraryError.saveFailed }
        return assetID
    }

    private static func createVideoAsset(from fileURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw PhotoLibraryError.saveFailed }
        var assetID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: fileURL, options: nil)
                assetID = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw PhotoLibraryError.saveFailed
        }
        guard let assetID else { throw PhotoLibraryError.saveFailed }
        return assetID
    }

    private static func isVideo(_ data: Data) -> Bool {
        data.count >= 12 && String(data: data[4..<12], encoding: .ascii)?.contains("ftyp") == true
    }

    private static func addAsset(_ assetID: String, to albumNames: [String]) async throws {
        guard !albumNames.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard assets.firstObject != nil else { throw PhotoLibraryError.saveFailed }
        for albumName in albumNames {
            let collection = try await album(named: albumName)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: collection)?.addAssets(assets)
            }
        }
    }

    private static func normalizedAlbumNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? name : nil
        }
    }

    private static func findMatchingAsset(for data: Data, inAlbumNamed albumName: String) async -> String? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumName)
        guard let collection = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject else {
            return nil
        }

        let assetOptions = PHFetchOptions()
        assetOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        assetOptions.fetchLimit = 500
        let candidates = PHAsset.fetchAssets(in: collection, options: assetOptions)
        if isVideo(data) { return nil }
        let targetSize = UIImage(data: data)?.cgImage.map { ($0.width, $0.height) }
        let targetHash = ImagePerceptualHash.value(data)
        for index in 0..<candidates.count {
            let candidate = candidates.object(at: index)
            if let targetSize,
               (candidate.pixelWidth != targetSize.0 || candidate.pixelHeight != targetSize.1),
               (candidate.pixelWidth != targetSize.1 || candidate.pixelHeight != targetSize.0) {
                continue
            }
            guard let candidateData = await originalImageData(for: candidate) else { continue }
            if candidateData == data { return candidate.localIdentifier }
            if let targetHash,
               let candidateHash = ImagePerceptualHash.value(candidateData),
               (targetHash ^ candidateHash).nonzeroBitCount <= 1 {
                return candidate.localIdentifier
            }
        }
        return nil
    }

    private static func originalImageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .original
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

enum ImagePerceptualHash {
    static func value(_ data: Data) -> UInt64? {
        guard let cgImage = UIImage(data: data)?.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: 64)
        guard let context = CGContext(
            data: &pixels,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        return pixels.enumerated().reduce(into: UInt64(0)) { hash, item in
            if Int(item.element) >= average { hash |= UInt64(1) << UInt64(item.offset) }
        }
    }
}

actor PhotoAssetLinkStore {
    static let shared = PhotoAssetLinkStore()

    private let defaults: UserDefaults
    private let key: String
    private var links: [String: String]

    init(defaults: UserDefaults = .standard, key: String = "cdance.photoAssetIdentifiersByGenerationID") {
        self.defaults = defaults
        self.key = key
        links = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func assetID(for generationID: String) -> String? { links[generationID] }

    func set(assetID: String, generationID: String) {
        links[generationID] = assetID
        defaults.set(links, forKey: key)
    }

    func remove(generationID: String) {
        links[generationID] = nil
        defaults.set(links, forKey: key)
    }
}

actor AutomaticPhotoSaveTracker {
    static let shared = AutomaticPhotoSaveTracker()

    private let defaults = UserDefaults.standard
    private let pendingKey = "cdance.autoSave.pendingGenerationIDs"
    private let savedKey = "cdance.autoSave.savedGenerationIDs"
    private var pending: Set<String>
    private var saved: Set<String>
    private var inProgress = Set<String>()

    init() {
        pending = Set(defaults.stringArray(forKey: pendingKey) ?? [])
        saved = Set(defaults.stringArray(forKey: savedKey) ?? [])
    }

    func register(_ generationID: String) {
        guard !saved.contains(generationID) else { return }
        pending.insert(generationID)
        persist()
    }

    func claim(_ generationID: String) -> Bool {
        guard pending.contains(generationID), !saved.contains(generationID), !inProgress.contains(generationID) else { return false }
        inProgress.insert(generationID)
        return true
    }

    func finish(_ generationID: String) {
        inProgress.remove(generationID)
        pending.remove(generationID)
        saved.insert(generationID)
        if saved.count > 500 { saved = Set(saved.suffix(500)) }
        persist()
    }

    func release(_ generationID: String) { inProgress.remove(generationID) }

    func abandon(_ generationID: String) {
        inProgress.remove(generationID)
        pending.remove(generationID)
        persist()
    }

    private func persist() {
        defaults.set(Array(pending), forKey: pendingKey)
        defaults.set(Array(saved), forKey: savedKey)
    }
}
