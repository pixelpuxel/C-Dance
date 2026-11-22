import Foundation
import WatchConnectivity

extension Notification.Name {
    static let cdanceWatchHistoryRequested = Notification.Name("cdanceWatchHistoryRequested")
}

@MainActor
final class WatchHistorySyncService: NSObject, WCSessionDelegate {
    static let shared = WatchHistorySyncService()

    private var session: WCSession?
    private var lastSignature = ""
    private var syncTask: Task<Void, Never>?
    private var transferredImageSignatures: Set<String> = []

    func activate() {
        guard WCSession.isSupported(), session == nil else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    func sync(_ generations: [Generation], force: Bool = false) {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }

        let entries = Array(generations
            .filter { $0.status == "completed" && $0.resultImage != nil }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(50))
        let signature = entries.map { generation in
            let image = generation.resultImage!
            return "\(generation.id):\(image.id):\(image.byteSize)"
        }.joined(separator: "|")
        guard force || signature != lastSignature else { return }
        lastSignature = signature

        let manifest: [[String: Any]] = entries.map {
            [
                "id": $0.id,
                "prompt": $0.finalPrompt,
                "createdAt": $0.createdAt.timeIntervalSince1970,
            ]
        }
        try? session.updateApplicationContext(["history": manifest])

        let wantedSignatures = Set(entries.compactMap { generation -> String? in
            guard let image = generation.resultImage else { return nil }
            return "\(generation.id):\(image.id):\(image.byteSize)"
        })
        transferredImageSignatures.formIntersection(wantedSignatures)
        let entriesToTransfer = entries.filter { generation in
            guard let image = generation.resultImage else { return false }
            let imageSignature = "\(generation.id):\(image.id):\(image.byteSize)"
            return force || !transferredImageSignatures.contains(imageSignature)
        }
        transferredImageSignatures.formUnion(entriesToTransfer.compactMap { generation in
            guard let image = generation.resultImage else { return nil }
            return "\(generation.id):\(image.id):\(image.byteSize)"
        })

        syncTask?.cancel()
        // This must not inherit MainActor: image IO for Watch transfers used to
        // block scene updates long enough for the iOS watchdog to terminate us.
        syncTask = Task.detached(priority: .utility) {
            for generation in entriesToTransfer {
                guard !Task.isCancelled, let image = generation.resultImage else { return }
                guard let data = try? await APIClient.shared.thumbnailData(image, maxSize: 384) else { continue }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CDanceWatchTransfer", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let fileURL = directory.appendingPathComponent("\(generation.id)-\(UUID().uuidString).jpg")
                guard (try? data.write(to: fileURL, options: .atomic)) != nil else { continue }
                session.transferFile(fileURL, metadata: [
                    "historyImage": true,
                    "id": generation.id,
                    "prompt": generation.finalPrompt,
                    "createdAt": generation.createdAt.timeIntervalSince1970,
                ])
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        NotificationCenter.default.post(name: .cdanceWatchHistoryRequested, object: nil)
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        NotificationCenter.default.post(name: .cdanceWatchHistoryRequested, object: nil)
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["requestHistory"] as? Bool == true else {
            replyHandler(["accepted": false])
            return
        }
        replyHandler(["accepted": true])
        NotificationCenter.default.post(name: .cdanceWatchHistoryRequested, object: nil)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo["requestHistory"] as? Bool == true else { return }
        NotificationCenter.default.post(name: .cdanceWatchHistoryRequested, object: nil)
    }
}
