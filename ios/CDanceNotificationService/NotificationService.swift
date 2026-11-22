import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: URLSessionDownloadTask?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttemptContent = content
        guard let rawURL = content.userInfo["media_url"] as? String,
              let url = URL(string: rawURL), url.scheme == "https" else {
            contentHandler(content)
            return
        }
        downloadTask = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, _ in
            guard let self, let temporaryURL else {
                contentHandler(content)
                return
            }
            let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
            let ext: String
            if mime.contains("quicktime") { ext = "mov" }
            else if mime.contains("video") { ext = "mp4" }
            else if mime.contains("png") { ext = "png" }
            else { ext = "jpg" }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("cdance-\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                let attachment = try UNNotificationAttachment(identifier: "cdance-result", url: destination)
                content.attachments = [attachment]
            } catch {
                // A text-only notification is still useful if the attachment cannot be prepared.
            }
            contentHandler(content)
        }
        downloadTask?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        downloadTask?.cancel()
        if let contentHandler, let bestAttemptContent { contentHandler(bestAttemptContent) }
    }
}
