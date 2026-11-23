import XCTest
import UIKit
@testable import CDance

final class CDanceTests:XCTestCase{
    func testLiveServerPayloadsDecodeInTheApp() async throws {
        let integrationToken = ProcessInfo.processInfo.environment["CDANCE_INTEGRATION_TOKEN"]
            ?? UserDefaults.standard.string(forKey: "cdance.integrationToken")
        guard let token = integrationToken,
              !token.isEmpty else {
            throw XCTSkip("Nur für den geschützten Ende-zu-Ende-Test gegen den Live-Server.")
        }
        async let models: ModelsResponse = liveResponse("models", token: token)
        async let prompts: [PromptTemplate] = liveResponse("prompts", token: token)
        async let assets: [ReferenceAsset] = liveResponse("reference-assets", token: token)
        async let history: GenerationPage = liveResponse("generations?limit=100", token: token)
        async let provider: ProviderConfiguration = liveResponse("provider/config", token: token)
        let result = try await (models, prompts, assets, history, provider)

        XCTAssertFalse(result.0.models.isEmpty)
        XCTAssertTrue(result.4.configured)
        XCTAssertFalse(result.4.endpoint.isEmpty)
    }

    func testLiveExpiredSessionRefreshesAllParallelStartupRequests() async throws {
        let integrationSession = ProcessInfo.processInfo.environment["CDANCE_INTEGRATION_SESSION_TOKEN"]
            ?? UserDefaults.standard.string(forKey: "cdance.integrationSessionToken")
        guard let integrationSession, !integrationSession.isEmpty else {
            throw XCTSkip("Nur für den geschützten Sitzungs-Erneuerungstest gegen den Live-Server.")
        }
        let previousMode = AppModeConfiguration.mode
        AppModeConfiguration.mode = .server
        defer { AppModeConfiguration.mode = previousMode }

        let credentials = TestAPICredentials(accessToken: "absichtlich-abgelaufen", sessionToken: integrationSession)
        let client = APIClient(credentials: credentials)
        await client.configureServerURL(AppModeConfiguration.defaultServerURL)

        async let models = client.models()
        async let prompts = client.prompts()
        async let assets = client.referenceAssets()
        async let history = client.history()
        async let provider = client.providerConfiguration()
        let responses = try await (models, prompts, assets, history, provider)

        XCTAssertFalse(responses.0.models.isEmpty)
        XCTAssertFalse(responses.4.source.isEmpty)
        XCTAssertNotEqual(credentials.accessToken, "absichtlich-abgelaufen")
    }

    func testParallelExpiredRequestsPerformOnlyOneSessionRefresh() async throws {
        let previousMode = AppModeConfiguration.mode
        defer {
            AppModeConfiguration.mode = previousMode
            RefreshMockURLProtocol.reset()
        }

        AppModeConfiguration.mode = .server
        RefreshMockURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshMockURLProtocol.self]
        let credentials = TestAPICredentials(accessToken: "expired-access-token", sessionToken: "valid-session-token")
        let client = APIClient(session: URLSession(configuration: configuration), credentials: credentials)
        await client.configureServerURL(URL(string: "https://cdance.test/api/v1")!)

        async let first = client.models()
        async let second = client.models()
        async let third = client.models()
        async let fourth = client.models()
        async let fifth = client.models()
        let responses = try await [first, second, third, fourth, fifth]

        XCTAssertEqual(responses.count, 5)
        XCTAssertEqual(RefreshMockURLProtocol.refreshCount, 1)
        XCTAssertEqual(RefreshMockURLProtocol.successfulModelCount, 5)
        XCTAssertEqual(credentials.accessToken, "fresh-access-token")
    }

    private func liveResponse<T: Decodable>(_ path: String, token: String) async throws -> T {
        let url = APIClient.resolveURL(baseURL: AppModeConfiguration.defaultServerURL, path: path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Live-Endpunkt \(path)")
        let decoder = JSONDecoder.cdance()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            XCTFail("Live-Endpunkt \(path) passt nicht zum App-Modell: \(error)")
            throw error
        }
    }

    func testServerAddressNormalizationAddsAPIVersion() {
        XCTAssertEqual(AppModeConfiguration.normalizedServerURL("cdance.schreiber.info")?.absoluteString, "https://cdance.schreiber.info/api/v1")
        XCTAssertEqual(AppModeConfiguration.normalizedServerURL("https://example.org/custom")?.absoluteString, "https://example.org/custom/api/v1")
        XCTAssertEqual(AppModeConfiguration.normalizedServerURL("https://example.org/api")?.absoluteString, "https://example.org/api/v1")
        XCTAssertEqual(AppModeConfiguration.normalizedServerURL("https://example.org/api/v1/")?.absoluteString, "https://example.org/api/v1")
        XCTAssertEqual(AppModeConfiguration.normalizedServerURL("http://localhost:8000")?.absoluteString, "http://localhost:8000/api/v1")
        XCTAssertNil(AppModeConfiguration.normalizedServerURL("http://example.org"))
    }

    func testServerTimestampsWithMicrosecondsDecodeOnEverySupportedOS() throws {
        let payload = Data(#"{"items":[{"id":"g","parent_id":null,"kind":"generate","status":"completed","prompt":"p","final_prompt":"p","model":"m","aspect_ratio":"auto","resolution":"2K","error_message":null,"created_at":"2026-10-08T10:36:26.653551Z","images":[],"references":[],"prompt_templates":[]}],"total":1}"#.utf8)
        let page = try JSONDecoder.cdance().decode(GenerationPage.self, from: payload)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].id, "g")
    }

    func testServerHistoryLoadsEveryPageInsteadOfOnlyNewestHundred() async throws {
        let previousMode = AppModeConfiguration.mode
        defer {
            AppModeConfiguration.mode = previousMode
            HistoryPaginationMockURLProtocol.reset()
        }
        AppModeConfiguration.mode = .server
        HistoryPaginationMockURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HistoryPaginationMockURLProtocol.self]
        let client = APIClient(
            session: URLSession(configuration: configuration),
            credentials: TestAPICredentials(accessToken: "token", sessionToken: nil)
        )
        await client.configureServerURL(URL(string: "https://cdance.test/api/v1")!)

        let history = try await client.history()

        XCTAssertEqual(history.total, 235)
        XCTAssertEqual(history.items.count, 235)
        XCTAssertEqual(Set(history.items.map(\.id)).count, 235)
        XCTAssertEqual(HistoryPaginationMockURLProtocol.requestedOffsets, [0, 100, 200])
    }

    func testStandaloneModelsMatchDocumentedSeedanceCapabilities() {
        let response = StandaloneService.modelsResponse
        XCTAssertEqual(response.defaultModel, "dreamina-seedance-2-5-260628")
        XCTAssertEqual(response.models.first?.name, "Seedance 2.5")
        XCTAssertNotNil(response.models.first(where: { $0.id == "dreamina-seedance-2-5-flash-261115" }))
        XCTAssertEqual(response.models.first(where: { $0.id == "dreamina-seedance-2-5-260628" })?.maxReferenceImages, 30)
        XCTAssertEqual(response.models.first(where: { $0.id == "dreamina-seedance-2-5-flash-261115" })?.maxReferenceImages, 10)
        XCTAssertEqual(response.models.first?.sizes, ["480p", "720p", "1080p", "4k"])
    }

    func testStandalonePromptPersistenceSurvivesServiceRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CDanceStandaloneTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = StandaloneService(root: directory)
        let saved = try await first.savePrompt(nil, name: "Test", text: "Ein Prompt", description: "", category: "", tags: ["lokal"], favorite: true)
        let second = StandaloneService(root: directory)
        let restored = await second.prompts()
        XCTAssertEqual(restored.first?.id, saved.id)
        XCTAssertEqual(restored.first?.text, "Ein Prompt")
    }

    func testImageCacheKeepsDownloadedImageAndInvalidatesChangedMetadata() async throws {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CDanceImageCacheTests-\(UUID().uuidString)")
        let url = try XCTUnwrap(URL(string: "https://example.invalid/image"))
        let original = APIImage(id: id, role: "result", mimeType: "image/jpeg", width: 100, height: 100, byteSize: 3, downloadURL: url)
        let changed = APIImage(id: id, role: "result", mimeType: "image/jpeg", width: 100, height: 100, byteSize: 4, downloadURL: url)
        let originalData = Data([1, 2, 3])
        let changedData = Data([4, 5, 6, 7])

        let firstLaunch = ImageDiskCache(directory: directory)
        await firstLaunch.store(originalData, for: original, variant: "test")

        let secondLaunch = ImageDiskCache(directory: directory)
        let cachedOriginal = await secondLaunch.data(for: original, variant: "test")
        XCTAssertEqual(cachedOriginal, originalData)

        await secondLaunch.store(changedData, for: changed, variant: "test")
        let invalidatedOriginal = await secondLaunch.data(for: original, variant: "test")
        let cachedChange = await secondLaunch.data(for: changed, variant: "test")
        XCTAssertNil(invalidatedOriginal)
        XCTAssertEqual(cachedChange, changedData)
        await secondLaunch.removeAll()
    }

    func testSmallerHistoryThumbnailReusesLargerCachedVariant() async throws {
        let image = APIImage(
            id: UUID().uuidString,
            role: "result",
            mimeType: "image/jpeg",
            width: 1_024,
            height: 1_024,
            byteSize: 4,
            downloadURL: URL(string: "https://example.invalid/history.jpg")!
        )
        let cached = Data([0xFF, 0xD8, 0xFF, 0xD9])
        await ImageDiskCache.shared.store(cached, for: image, variant: "thumbnail-384")

        let client = APIClient(credentials: TestAPICredentials(accessToken: "token", sessionToken: nil))
        let reused = try await client.thumbnailData(image, maxSize: 128)

        XCTAssertEqual(reused, cached)
        await ImageDiskCache.shared.remove(imageIDs: [image.id])
    }

    func testExpiredImageURLIsRefreshedWithoutReloadingHistory() async throws {
        let previousMode = AppModeConfiguration.mode
        AppModeConfiguration.mode = .server
        defer {
            AppModeConfiguration.mode = previousMode
            ExpiredImageMockURLProtocol.reset()
        }
        ExpiredImageMockURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExpiredImageMockURLProtocol.self]
        let client = APIClient(
            session: URLSession(configuration: configuration),
            credentials: TestAPICredentials(accessToken: "valid-access-token", sessionToken: nil)
        )
        await client.configureServerURL(URL(string: "https://cdance.test/api/v1")!)
        let image = APIImage(
            id: ExpiredImageMockURLProtocol.imageID,
            role: "result",
            mimeType: "image/jpeg",
            width: 100,
            height: 100,
            byteSize: 4,
            downloadURL: URL(string: "https://files.test/content?token=expired")!
        )

        let data = try await client.imageData(image)

        XCTAssertEqual(data, ExpiredImageMockURLProtocol.expectedImageData)
        XCTAssertEqual(ExpiredImageMockURLProtocol.refreshCount, 1)
        await ImageDiskCache.shared.remove(imageIDs: [image.id])
    }

    func testResultPreviewUsesLargestCachedThumbnail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CDancePreviewCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageDiskCache(directory: directory)
        let image = APIImage(
            id: UUID().uuidString,
            role: "result",
            mimeType: "image/jpeg",
            width: 2_048,
            height: 2_048,
            byteSize: 4,
            downloadURL: URL(string: "https://example.invalid/result.jpg")!
        )
        let small = Data([1, 2])
        let large = Data([1, 2, 3, 4])
        await cache.store(small, for: image, variant: "thumbnail-384")
        await cache.store(large, for: image, variant: "thumbnail-1024")

        let preview = await cache.bestThumbnailData(for: image)

        XCTAssertEqual(preview, large)
    }

    func testHistorySortOrdersUseDateStatusAndPrompt() {
        func generation(_ id: String, status: String, prompt: String, age: TimeInterval) -> Generation {
            Generation(id: id, parentID: nil, kind: "generate", status: status, prompt: prompt, finalPrompt: prompt, model: "m", aspectRatio: "auto", resolution: "2K", errorMessage: nil, createdAt: Date().addingTimeInterval(age), images: [], references: [])
        }
        let items = [
            generation("old", status: "completed", prompt: "Zebra", age: -100),
            generation("new", status: "failed", prompt: "Apfel", age: 0),
            generation("active", status: "processing", prompt: "Mitte", age: -50)
        ]

        XCTAssertEqual(items.sorted(by: HistorySortOrder.newest.areInIncreasingOrder).map(\.id), ["new", "active", "old"])
        XCTAssertEqual(items.sorted(by: HistorySortOrder.oldest.areInIncreasingOrder).map(\.id), ["old", "active", "new"])
        XCTAssertEqual(items.sorted(by: HistorySortOrder.status.areInIncreasingOrder).map(\.id), ["active", "old", "new"])
        XCTAssertEqual(items.sorted(by: HistorySortOrder.prompt.areInIncreasingOrder).map(\.id), ["new", "active", "old"])
    }

    func testPromptDiffCanTakeEitherSideOrOnlyCommonText() {
        let left = "Eine Frau im roten Kleid. Die Person steht vor einer hellen Wand. Die Beleuchtung ist weich."
        let right = "Eine Frau im blauen Kleid. Die Person steht vor einer dunklen Wand. Die Beleuchtung ist weich."
        let hunks = PromptDiffEngine.hunks(left: left, right: right)
        let changed = hunks.filter { !$0.isCommon }

        XCTAssertFalse(changed.isEmpty)
        XCTAssertTrue(changed.contains { $0.left.contains("roten") })
        XCTAssertTrue(changed.contains { $0.right.contains("blauen") })
        XCTAssertEqual(
            PromptDiffEngine.mergedPrompt(
                hunks: hunks,
                choices: Dictionary(uniqueKeysWithValues: changed.map { ($0.id, PromptMergeChoice.left) })
            ),
            left
        )
        XCTAssertEqual(
            PromptDiffEngine.mergedPrompt(
                hunks: hunks,
                choices: Dictionary(uniqueKeysWithValues: changed.map { ($0.id, PromptMergeChoice.right) })
            ),
            right
        )
        let commonOnly = PromptDiffEngine.mergedPrompt(
            hunks: hunks,
            choices: Dictionary(uniqueKeysWithValues: changed.map { ($0.id, PromptMergeChoice.neither) })
        )
        XCTAssertFalse(commonOnly.contains("roten"))
        XCTAssertFalse(commonOnly.contains("blauen"))
        XCTAssertTrue(commonOnly.contains("Die Beleuchtung ist weich."))
        XCTAssertFalse(commonOnly.contains("Kleid"))
    }

    func testPromptDiffKeepsChangedSentencesTogether() {
        let hunks = PromptDiffEngine.hunks(
            left: "Eine Person trägt einen roten Mantel. Der Hintergrund bleibt weiß.",
            right: "Eine Person trägt einen blauen Mantel. Der Hintergrund bleibt weiß."
        )
        let changed = try! XCTUnwrap(hunks.first(where: { !$0.isCommon }))

        XCTAssertEqual(changed.left, "Eine Person trägt einen roten Mantel.")
        XCTAssertEqual(changed.right, "Eine Person trägt einen blauen Mantel.")
        XCTAssertEqual(hunks.filter(\.isCommon).map(\.left).joined(), " Der Hintergrund bleibt weiß.")
    }

    func testReferenceDiffSeparatesCommonAndUniqueImages() {
        func image(_ id: String, byteSize: Int) -> APIImage {
            APIImage(
                id: id,
                role: "reference",
                mimeType: "image/jpeg",
                width: 100,
                height: 100,
                byteSize: byteSize,
                downloadURL: URL(string: "https://example.invalid/\(id).jpg")!
            )
        }
        func generation(_ id: String, images: [APIImage]) -> Generation {
            let references = images.enumerated().map {
                GenerationReference(id: "\(id)-\($0.offset)", position: $0.offset, purpose: "reference", image: $0.element)
            }
            return Generation(
                id: id,
                parentID: nil,
                kind: "generate",
                status: "completed",
                prompt: id,
                finalPrompt: id,
                model: "m",
                aspectRatio: "auto",
                resolution: "2K",
                errorMessage: nil,
                createdAt: Date(),
                images: [],
                references: references
            )
        }

        let groups = ReferenceDiffEngine.groups(
            left: generation("A", images: [image("shared", byteSize: 10), image("left", byteSize: 20)]),
            right: generation("B", images: [image("shared", byteSize: 10), image("right", byteSize: 30)])
        )

        XCTAssertEqual(groups.filter { $0.match == .same }.count, 1)
        XCTAssertEqual(groups.filter { $0.match == .onlyLeft }.count, 1)
        XCTAssertEqual(groups.filter { $0.match == .onlyRight }.count, 1)
        XCTAssertEqual(groups.first(where: { $0.match == .same })?.left?.reference.image.id, "shared")
        XCTAssertEqual(groups.first(where: { $0.match == .same })?.right?.reference.image.id, "shared")
    }

    func testReferenceDiffPairsVisuallyEqualImagesWithDifferentIDs() {
        func generation(_ id: String, imageID: String, byteSize: Int) -> Generation {
            let image = APIImage(
                id: imageID,
                role: "reference",
                mimeType: "image/jpeg",
                width: 100,
                height: 100,
                byteSize: byteSize,
                downloadURL: URL(string: "https://example.invalid/\(imageID).jpg")!
            )
            return Generation(
                id: id,
                parentID: nil,
                kind: "generate",
                status: "completed",
                prompt: id,
                finalPrompt: id,
                model: "m",
                aspectRatio: "auto",
                resolution: "2K",
                errorMessage: nil,
                createdAt: Date(),
                images: [],
                references: [GenerationReference(id: "ref-\(id)", position: 0, purpose: "reference", image: image)]
            )
        }
        let left = generation("A", imageID: "left-upload", byteSize: 10)
        let right = generation("B", imageID: "right-upload", byteSize: 11)
        let candidates = ReferenceDiffEngine.candidates(left: left, right: right)
        let fingerprints = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, UInt64(0xAA55AA55AA55AA55)) })

        let groups = ReferenceDiffEngine.groups(left: left, right: right, fingerprints: fingerprints)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].match, .same)
        XCTAssertEqual(groups[0].left?.reference.image.id, "left-upload")
        XCTAssertEqual(groups[0].right?.reference.image.id, "right-upload")
    }

    func testReferenceFingerprintRecognizesReencodedImageContent() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        let highQuality = try XCTUnwrap(image.jpegData(compressionQuality: 1.0))
        let compressed = try XCTUnwrap(image.jpegData(compressionQuality: 0.45))
        let first = try XCTUnwrap(ReferenceDiffEngine.perceptualHash(highQuality))
        let second = try XCTUnwrap(ReferenceDiffEngine.perceptualHash(compressed))

        XCTAssertLessThanOrEqual((first ^ second).nonzeroBitCount, 6)
    }

    func testPhotoAlbumPreferencesTrimAndDeduplicateNames() {
        let original = PhotoAlbumPreferences.load()
        defer { PhotoAlbumPreferences.save(original) }

        PhotoAlbumPreferences.save(["  Portraits  ", "portraits", "Entwürfe", ""])

        XCTAssertEqual(PhotoAlbumPreferences.load(), ["Portraits", "Entwürfe"])
        XCTAssertEqual(
            PhotoAlbumPreferences.availableAlbums(defaultAlbumName: "CDance"),
            ["CDance", "Portraits", "Entwürfe"]
        )
    }

    func testPhotoAssetLinkStorePersistsAndRemovesExistingPhotosIdentifier() async throws {
        let suiteName = "CDanceTests.PhotoAssetLinkStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "links"

        let store = PhotoAssetLinkStore(defaults: defaults, key: key)
        await store.set(assetID: "photos-asset-1", generationID: "generation-1")
        let storedAssetID = await store.assetID(for: "generation-1")
        XCTAssertEqual(storedAssetID, "photos-asset-1")

        let restoredStore = PhotoAssetLinkStore(defaults: defaults, key: key)
        let restoredAssetID = await restoredStore.assetID(for: "generation-1")
        XCTAssertEqual(restoredAssetID, "photos-asset-1")
        await restoredStore.remove(generationID: "generation-1")
        let removedAssetID = await restoredStore.assetID(for: "generation-1")
        XCTAssertNil(removedAssetID)
    }

    func testGenerationSelectsResultImage(){let image=APIImage(id:"1",role:"result",mimeType:"image/png",width:10,height:10,byteSize:100,downloadURL:URL(string:"https://example.com/image.png")!);let generation=Generation(id:"g",parentID:nil,kind:"generate",status:"completed",prompt:"p",finalPrompt:"p",model:"m",aspectRatio:"1:1",resolution:"2K",errorMessage:nil,createdAt:Date(),images:[image],references:[]);XCTAssertEqual(generation.resultImage?.id,"1")}

    func testReferenceImageIsNeverPresentedAsGeneratedResult() {
        let image=APIImage(id:"reference",role:"reference",mimeType:"image/png",width:10,height:10,byteSize:100,downloadURL:URL(string:"https://example.com/reference.png")!)
        let generation=Generation(id:"g",parentID:nil,kind:"generate",status:"failed",prompt:"p",finalPrompt:"p",model:"m",aspectRatio:"1:1",resolution:"2K",errorMessage:"Fehlgeschlagen",createdAt:Date(),images:[image],references:[])
        XCTAssertNil(generation.resultImage)
    }

    func testAPIURLPreservesVersionPrefix() {
        let baseURL = URL(string: "https://cdance.schreiber.info/api/v1")!
        XCTAssertEqual(
            APIClient.resolveURL(baseURL: baseURL, path: "/auth/login").absoluteString,
            "https://cdance.schreiber.info/api/v1/auth/login"
        )
        XCTAssertEqual(
            APIClient.resolveURL(baseURL: baseURL, path: "/generations?limit=100").absoluteString,
            "https://cdance.schreiber.info/api/v1/generations?limit=100"
        )
    }

    func testProviderConfigurationAcceptsOlderServerResponses() throws {
        let decoder = JSONDecoder()
        let short = try decoder.decode(
            ProviderConfiguration.self,
            from: Data(#"{"configured":true}"#.utf8)
        )
        XCTAssertTrue(short.configured)
        XCTAssertEqual(short.source, "server")
        XCTAssertEqual(short.endpoint, "")

        let wrapped = try decoder.decode(
            ProviderConfiguration.self,
            from: Data(#"{"data":{"api_key_configured":true,"model":"cdance"}}"#.utf8)
        )
        XCTAssertTrue(wrapped.configured)
        XCTAssertEqual(wrapped.model, "cdance")
    }

    func testGeneratorDraftKeepsPromptAndReferenceImage() throws {
        let draft = GeneratorDraft(references: [.init(data: Data([1, 2, 3]), remote: nil, previewData: Data([4, 5]))], selectedTemplateIDs: ["template"], freeText: "Zusatz", finalPrompt: "Final", selectedModel: "model", ratio: "4:3", resolution: "2K", editingParent: nil)
        let restored = try JSONDecoder().decode(GeneratorDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored.finalPrompt, "Final")
        XCTAssertEqual(restored.references.first?.data, Data([1, 2, 3]))
        XCTAssertEqual(restored.selectedTemplateIDs, ["template"])
    }

    func testBatchPlannerCreatesOneRequestPerInputWithSharedSetupReferences() {
        let first = LocalReference(data: Data([1]), preview: UIImage())
        let second = LocalReference(data: Data([2]), preview: UIImage())
        let sharedStyle = LocalReference(data: Data([3]), preview: UIImage())
        let sharedComposition = LocalReference(data: Data([4]), preview: UIImage())

        let groups = BatchGenerationPlanner.referenceGroups(
            batchMode: true,
            batchInputs: [first, second],
            commonReferences: [sharedStyle, sharedComposition]
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].map(\.id), [first.id, sharedStyle.id, sharedComposition.id])
        XCTAssertEqual(groups[1].map(\.id), [second.id, sharedStyle.id, sharedComposition.id])
    }

    func testBatchPlannerKeepsSingleImageWorkflowUnchanged() {
        let reference = LocalReference(data: Data([1]), preview: UIImage())
        let groups = BatchGenerationPlanner.referenceGroups(
            batchMode: false,
            batchInputs: [],
            commonReferences: [reference]
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].map(\.id), [reference.id])
    }

    func testSharedImagesAreInsertedBeforeExistingReferences() {
        let sharedFirst = LocalReference(data: Data([1]), preview: UIImage())
        let sharedSecond = LocalReference(data: Data([2]), preview: UIImage())
        let existing = LocalReference(data: Data([3]), preview: UIImage())

        let merged = SharedReferenceImport.prepend(
            [sharedFirst, sharedSecond],
            to: [existing],
            limit: 10
        )

        XCTAssertEqual(merged.map(\.id), [sharedFirst.id, sharedSecond.id, existing.id])
    }

    func testSharedImageInsertionRespectsReferenceLimit() {
        let sharedFirst = LocalReference(data: Data([1]), preview: UIImage())
        let sharedSecond = LocalReference(data: Data([2]), preview: UIImage())
        let existing = (0..<9).map { LocalReference(data: Data([UInt8($0 + 10)]), preview: UIImage()) }

        let merged = SharedReferenceImport.prepend(
            [sharedFirst, sharedSecond],
            to: existing,
            limit: 10
        )

        XCTAssertEqual(merged.count, 10)
        XCTAssertEqual(merged.first?.id, sharedFirst.id)
        XCTAssertEqual(merged.dropFirst().first?.id, sharedSecond.id)
        XCTAssertFalse(merged.contains { $0.id == existing.last?.id })
    }

    func testOpeningSharedImageImportsItAtTheFront() async throws {
        let existing = LocalReference(data: Data([9]), preview: UIImage())
        let store = await MainActor.run { () -> AppStore in
            let store = AppStore()
            store.pendingSharedReferences = [existing]
            store.selectedTab = 3
            return store
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        let input = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CDance-Share-\(UUID().uuidString).jpg")
        try input.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        await store.importSharedImage(from: url)

        let result = await MainActor.run { (store.pendingSharedReferences, store.selectedTab) }
        XCTAssertEqual(result.0.count, 2)
        XCTAssertNotEqual(result.0.first?.id, existing.id)
        XCTAssertEqual(result.0.last?.id, existing.id)
        XCTAssertEqual(result.1, 0)
    }

    func testReferenceReplacementKeepsPositionAndOtherImages() {
        let first = LocalReference(data: Data([1]), preview: UIImage())
        let oldSecond = LocalReference(data: Data([2]), preview: UIImage())
        let third = LocalReference(data: Data([3]), preview: UIImage())
        let replacement = LocalReference(data: Data([4]), preview: UIImage())

        let updated = ReferenceReplacementPlanner.replacing(
            referenceID: oldSecond.id,
            with: replacement,
            in: [first, oldSecond, third]
        )

        XCTAssertEqual(updated.map(\.id), [first.id, replacement.id, third.id])
        XCTAssertEqual(updated.count, 3)
    }

    func testReferenceReorderingMovesInBothDirections() {
        let first = LocalReference(data: Data([1]), preview: UIImage())
        let second = LocalReference(data: Data([2]), preview: UIImage())
        let third = LocalReference(data: Data([3]), preview: UIImage())

        let movedRight = ReferenceOrderPlanner.moving(
            referenceID: first.id,
            toward: third.id,
            in: [first, second, third]
        )
        XCTAssertEqual(movedRight.map(\.id), [second.id, third.id, first.id])

        let movedLeft = ReferenceOrderPlanner.moving(
            referenceID: third.id,
            toward: first.id,
            in: [first, second, third]
        )
        XCTAssertEqual(movedLeft.map(\.id), [third.id, first.id, second.id])
    }

    @MainActor func testActiveGenerationCountIncludesQueueAndProcessing() {
        let store = AppStore()
        func generation(_ id: String, _ status: String) -> Generation {
            Generation(id:id,parentID:nil,kind:"generate",status:status,prompt:"p",finalPrompt:"p",model:"m",aspectRatio:"auto",resolution:"2K",errorMessage:nil,createdAt:Date(),images:[],references:[])
        }
        store.generations = [generation("queued", "queued"), generation("processing", "processing"), generation("done", "completed")]
        XCTAssertEqual(store.activeGenerationCount, 2)
    }

    func testExpectedNetworkCancellationIsNotPresentedAsAnError() {
        XCTAssertTrue(AppStore.isCancellation(CancellationError()))
        XCTAssertTrue(AppStore.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(AppStore.isCancellation(URLError(.timedOut)))
        XCTAssertTrue(AppStore.isTransientNetworkError(URLError(.networkConnectionLost)))
        XCTAssertTrue(AppStore.isTransientNetworkError(URLError(.notConnectedToInternet)))
        XCTAssertFalse(AppStore.isTransientNetworkError(URLError(.badServerResponse)))
    }

    @MainActor func testSuccessfulUserActionClearsStaleError() async {
        let store = AppStore()
        store.error = "Alter Verbindungsfehler"

        await store.perform {}

        XCTAssertNil(store.error)
        XCTAssertFalse(store.working)
    }

    func testPushPayloadRoutesOnlyValidGenerationIDs() {
        let id = UUID().uuidString
        XCTAssertEqual(PushNotificationRouter.generationID(from: ["generation_id": id]), id)
        XCTAssertNil(PushNotificationRouter.generationID(from: ["generation_id": "not-an-id"]))
        XCTAssertNil(PushNotificationRouter.generationID(from: [:]))
    }

    func testPNGReferenceIsNormalizedToJPEG() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60), format: format)
        let png = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }.pngData()
        let jpeg = try XCTUnwrap(png.flatMap { UIImage.cdanceUploadJPEG(from: $0) })
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(UIImage(data: jpeg)?.size, CGSize(width: 80, height: 60))
    }

    func testMarkupRendererBurnsSelectedColorIntoImage() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let stroke = MarkStroke(tool: .pen, color: .green, points: [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)])
        let rendered = try XCTUnwrap(MarkupRenderer.render(image: source, strokes: [stroke], canvasSize: source.size))
        let cgImage = try XCTUnwrap(rendered.cgImage)
        let data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = CFDataGetBytePtr(data)
        let offset = 50 * cgImage.bytesPerRow + 50 * 4
        XCTAssertGreaterThan(Int(bytes?[offset + 1] ?? 0), Int(bytes?[offset] ?? 0))
        XCTAssertEqual(rendered.size, source.size)
    }

    func testCropRendererUsesZoomAndOffset() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        }

        let cropped = try XCTUnwrap(CropRenderer.crop(
            image: source,
            canvasSize: CGSize(width: 200, height: 200),
            zoom: 2,
            offset: CGSize(width: -100, height: 0),
            cropRect: CGRect(x: 100, y: 50, width: 100, height: 100)
        ))

        XCTAssertEqual(cropped.size, CGSize(width: 100, height: 100))
        let cgImage = try XCTUnwrap(cropped.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.translateBy(x: -50, y: -50)
        context.draw(cgImage, in: CGRect(origin: .zero, size: cropped.size))
        XCTAssertGreaterThan(Int(pixel[2]), Int(pixel[0]))
    }

    func testEveryCropHandleChangesItsExpectedEdge() {
        let source = CGRect(x: 100, y: 100, width: 200, height: 200)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let translation = CGSize(width: 20, height: 30)

        let expected: [CropHandle: CGRect] = [
            .topLeft: CGRect(x: 120, y: 130, width: 180, height: 170),
            .top: CGRect(x: 100, y: 130, width: 200, height: 170),
            .topRight: CGRect(x: 100, y: 130, width: 220, height: 170),
            .right: CGRect(x: 100, y: 100, width: 220, height: 200),
            .bottomRight: CGRect(x: 100, y: 100, width: 220, height: 230),
            .bottom: CGRect(x: 100, y: 100, width: 200, height: 230),
            .bottomLeft: CGRect(x: 120, y: 100, width: 180, height: 230),
            .left: CGRect(x: 120, y: 100, width: 180, height: 200),
        ]

        for handle in CropHandle.allCases {
            XCTAssertEqual(
                CropInteractionGeometry.adjustedRect(
                    source,
                    handle: handle,
                    translation: translation,
                    bounds: bounds,
                    minimumLength: 64
                ),
                expected[handle],
                "Falsche Geometrie für \(handle)"
            )
        }
    }

    func testCropHitTestingFindsEveryVisibleHandle() {
        let rect = CGRect(x: 80, y: 120, width: 240, height: 360)

        for handle in CropHandle.allCases {
            let position = CropInteractionGeometry.handlePosition(handle, in: rect)
            XCTAssertEqual(
                CropInteractionGeometry.closestHandle(
                    to: CGPoint(x: position.x + 18, y: position.y - 12),
                    in: rect,
                    maximumDistance: 54
                ),
                handle,
                "Griff wird nicht zuverlässig getroffen: \(handle)"
            )
        }

        XCTAssertNil(
            CropInteractionGeometry.closestHandle(
                to: CGPoint(x: rect.midX, y: rect.midY),
                in: rect,
                maximumDistance: 54
            )
        )

        XCTAssertEqual(
            CropInteractionGeometry.closestHandle(
                to: CGPoint(x: rect.minX + 78, y: rect.minY + 20),
                in: rect,
                maximumDistance: 54
            ),
            .top
        )
        XCTAssertEqual(
            CropInteractionGeometry.closestHandle(
                to: CGPoint(x: rect.maxX - 18, y: rect.minY + 105),
                in: rect,
                maximumDistance: 54
            ),
            .right
        )
        XCTAssertEqual(
            CropInteractionGeometry.closestHandle(
                to: CGPoint(x: rect.minX + 90, y: rect.maxY - 22),
                in: rect,
                maximumDistance: 54
            ),
            .bottom
        )
        XCTAssertEqual(
            CropInteractionGeometry.closestHandle(
                to: CGPoint(x: rect.minX + 24, y: rect.maxY - 110),
                in: rect,
                maximumDistance: 54
            ),
            .left
        )
    }

    func testCropRendererLimitsLargeInputBeforeRendering() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 5_000, height: 100), format: format).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 5_000, height: 100))
        }

        let cropped = try XCTUnwrap(CropRenderer.crop(
            image: source,
            canvasSize: CGSize(width: 500, height: 100),
            zoom: 1,
            offset: .zero,
            cropRect: CGRect(x: 0, y: 45, width: 500, height: 10)
        ))

        XCTAssertLessThanOrEqual(max(cropped.size.width, cropped.size.height), 4_096)
    }

    func testZoomViewportUsesActualImageAreaAndCentersOnlyShortAxis() {
        let fitted = ZoomViewportGeometry.fittedSize(
            imageSize: CGSize(width: 400, height: 200),
            viewportSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(fitted, CGSize(width: 200, height: 100))

        let zoomed = CGSize(width: fitted.width * 3, height: fitted.height * 3)
        let insets = ZoomViewportGeometry.centeringInsets(
            contentSize: zoomed,
            viewportSize: CGSize(width: 200, height: 400)
        )
        XCTAssertEqual(insets.left, 0)
        XCTAssertEqual(insets.right, 0)
        XCTAssertEqual(insets.top, 50)
        XCTAssertEqual(insets.bottom, 50)
    }

    func testGalleryDismissRequiresLongDirectedDrag() {
        XCTAssertEqual(GalleryDismissPolicy.presentationOffset(for: CGSize(width: 0, height: 69)), 0)
        XCTAssertFalse(GalleryDismissPolicy.shouldDismiss(translation: CGSize(width: 0, height: 120)))
        XCTAssertFalse(GalleryDismissPolicy.shouldDismiss(translation: CGSize(width: 210, height: 250)))
        XCTAssertTrue(GalleryDismissPolicy.shouldDismiss(translation: CGSize(width: 20, height: 260)))
    }
}

private final class RefreshMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "CDanceTests.RefreshMockURLProtocol")
    private static var storedRefreshCount = 0
    private static var storedSuccessfulModelCount = 0

    static var refreshCount: Int { queue.sync { storedRefreshCount } }
    static var successfulModelCount: Int { queue.sync { storedSuccessfulModelCount } }

    static func reset() {
        queue.sync {
            storedRefreshCount = 0
            storedSuccessfulModelCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let status: Int
        let data: Data

        if url.path.hasSuffix("/auth/refresh") {
            Self.queue.sync { Self.storedRefreshCount += 1 }
            Thread.sleep(forTimeInterval: 0.08)
            status = 200
            data = Data(#"{"access_token":"fresh-access-token","session_token":"valid-session-token"}"#.utf8)
        } else if request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access-token" {
            Self.queue.sync { Self.storedSuccessfulModelCount += 1 }
            status = 200
            data = Data(#"{"default_model":"cdance","models":[]}"#.utf8)
        } else {
            status = 401
            data = Data(#"{"error":{"code":"expired","message":"expired"}}"#.utf8)
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class HistoryPaginationMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "CDanceTests.HistoryPaginationMockURLProtocol")
    private static var storedOffsets: [Int] = []

    static var requestedOffsets: [Int] { queue.sync { storedOffsets } }
    static func reset() { queue.sync { storedOffsets = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let offset = components.queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(Int.init) ?? 0
        let end = min(offset + 100, 235)
        Self.queue.sync { Self.storedOffsets.append(offset) }

        let formatter = ISO8601DateFormatter()
        let items: [[String: Any]] = (offset..<end).map { index in
            [
                "id": "generation-\(index)",
                "kind": "generate",
                "status": "completed",
                "prompt": "Prompt \(index)",
                "final_prompt": "Prompt \(index)",
                "model": "model",
                "aspect_ratio": "auto",
                "resolution": "2K",
                "created_at": formatter.string(from: Date(timeIntervalSince1970: TimeInterval(10_000 - index))),
                "images": [],
                "references": [],
                "prompt_templates": [],
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["items": items, "total": 235])
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ExpiredImageMockURLProtocol: URLProtocol, @unchecked Sendable {
    static let imageID = "11111111-1111-1111-1111-111111111111"
    static let expectedImageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
    private static let queue = DispatchQueue(label: "CDanceTests.ExpiredImageMockURLProtocol")
    private static var storedRefreshCount = 0

    static var refreshCount: Int { queue.sync { storedRefreshCount } }
    static func reset() { queue.sync { storedRefreshCount = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let status: Int
        let contentType: String
        let data: Data

        if url.host == "files.test", url.query?.contains("token=fresh") == true {
            status = 200
            contentType = "image/jpeg"
            data = Self.expectedImageData
        } else if url.host == "files.test" {
            status = 401
            contentType = "application/json"
            data = Data(#"{"detail":{"code":"invalid_download_token","message":"expired"}}"#.utf8)
        } else if url.path.hasSuffix("/images/\(Self.imageID)") {
            Self.queue.sync { Self.storedRefreshCount += 1 }
            status = 200
            contentType = "application/json"
            data = Data(#"{"id":"11111111-1111-1111-1111-111111111111","role":"result","mime_type":"image/jpeg","width":100,"height":100,"byte_size":4,"download_url":"https://files.test/content?token=fresh"}"#.utf8)
        } else {
            status = 404
            contentType = "application/json"
            data = Data()
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TestAPICredentials: APIClientCredentials {
    var accessToken: String?
    var sessionToken: String?

    init(accessToken: String?, sessionToken: String?) {
        self.accessToken = accessToken
        self.sessionToken = sessionToken
    }
}
