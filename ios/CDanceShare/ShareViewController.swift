import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private enum ShareError: Error {
        case missingImageData
    }

    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "Bilder werden für C-Dance vorbereitet …"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        openButton.setTitle("In C-Dance öffnen", for: .normal)
        openButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        openButton.isHidden = true
        openButton.addTarget(self, action: #selector(openApp), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [statusLabel, openButton])
        stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        Task { await importImages() }
    }

    private func importImages() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.info.schreiber.cdance") else {
            showFailure("Der gemeinsame App-Speicher ist nicht verfügbar."); return
        }
        let folder = root.appendingPathComponent("Incoming", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { showFailure("Das Bild konnte nicht vorbereitet werden."); return }
        var imported = 0
        let batchTimestamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
        for (index, provider) in providers.enumerated() {
            do {
                let data = try await imageData(from: provider)
                let filename = String(format: "%020lld-%03d-%@", batchTimestamp, index, UUID().uuidString)
                let url = folder.appendingPathComponent(filename).appendingPathExtension("image")
                try data.write(to: url, options: Data.WritingOptions.atomic)
                imported += 1
            } catch { continue }
        }
        await MainActor.run {
            statusLabel.text = imported == 1 ? "Bild wurde zu C-Dance hinzugefügt." : "\(imported) Bilder wurden zu C-Dance hinzugefügt."
            if imported > 0 { openHostApp(automatic: true) }
        }
    }

    private func imageData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? ShareError.missingImageData)
                }
            }
        }
    }

    private func showFailure(_ message: String) {
        Task { @MainActor in statusLabel.text = message }
    }

    @objc private func openApp() {
        openHostApp(automatic: false)
    }

    private func openHostApp(automatic: Bool) {
        guard let url = URL(string: "cdance://import") else { return }
        openButton.isEnabled = false
        extensionContext?.open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self else { return }
                if opened {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else if !self.openHostAppThroughResponderChain(url, automatic: automatic) {
                    self.showOpenFailure(automatic: automatic)
                }
            }
        }
    }

    /// `NSExtensionContext.open` is rejected by iOS for regular share extensions.
    /// The active host application's responder is nevertheless present in the
    /// extension's responder chain. Use the modern scene-aware URL API there;
    /// the deprecated `openURL:` selector is force-rejected since iOS 18.
    @MainActor
    private func openHostAppThroughResponderChain(_ url: URL, automatic: Bool) -> Bool {
        var responder: UIResponder? = self
        while let currentResponder = responder {
            if let application = currentResponder as? UIApplication {
                application.open(url, options: [:]) { [weak self] opened in
                    Task { @MainActor in
                        guard let self else { return }
                        if opened {
                            self.extensionContext?.completeRequest(returningItems: nil)
                        } else {
                            self.showOpenFailure(automatic: automatic)
                        }
                    }
                }
                return true
            }
            responder = currentResponder.next
        }
        return false
    }

    @MainActor
    private func showOpenFailure(automatic: Bool) {
        openButton.isEnabled = true
        openButton.isHidden = false
        statusLabel.text = automatic
            ? "Das Bild ist vorbereitet. Tippe zum Öffnen auf C-Dance."
            : "C-Dance konnte nicht automatisch geöffnet werden."
    }
}
