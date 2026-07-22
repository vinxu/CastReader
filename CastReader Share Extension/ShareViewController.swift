import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let successImageView = UIImageView()
    private let saveButton = UIButton(type: .system)

    private enum L10n {
        static let appGroup = "group.com.same.castreader"
        static let languageKey = "interfaceLanguage"

        static func text(_ key: String) -> String {
            let selected = UserDefaults(suiteName: appGroup)?.string(forKey: languageKey)
            guard let selected, selected != "system",
                  let path = Bundle.main.path(forResource: selected, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
            }
            return bundle.localizedString(forKey: key, value: nil, table: nil)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureUI()
    }

    private func configureUI() {
        titleLabel.text = L10n.text("share_title")
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center

        detailLabel.text = L10n.text("share_detail")
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        successImageView.image = UIImage(systemName: "checkmark.circle.fill")
        successImageView.tintColor = .systemGreen
        successImageView.contentMode = .scaleAspectFit
        successImageView.isHidden = true
        successImageView.heightAnchor.constraint(equalToConstant: 52).isActive = true

        saveButton.setTitle(L10n.text("share_save"), for: .normal)
        saveButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        saveButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        saveButton.layer.cornerRadius = 12
        saveButton.backgroundColor = .label
        saveButton.setTitleColor(.systemBackground, for: .normal)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [successImageView, titleLabel, detailLabel, saveButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func saveTapped() { importSharedItem() }

    private func importSharedItem() {
        saveButton.isEnabled = false
        detailLabel.text = L10n.text("share_importing")

        Task { @MainActor in
            do {
                try await saveFirstSupportedAttachment()
                showSavedState()
                try? await Task.sleep(nanoseconds: 550_000_000)
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                detailLabel.text = L10n.text("share_failed")
                saveButton.isEnabled = true
            }
        }
    }

    private func showSavedState() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        successImageView.isHidden = false
        titleLabel.text = L10n.text("share_success_title")
        detailLabel.text = L10n.text("share_saved")
        saveButton.isHidden = true
    }

    private func saveFirstSupportedAttachment() async throws {
        let inputItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers: [NSItemProvider] = inputItems.flatMap { item in
            item.attachments ?? []
        }
        guard !providers.isEmpty else { throw ShareError.unsupported }

        for provider in providers {
            if let saved = try? await save(provider: provider), saved { return }
        }
        throw ShareError.unsupported
    }

    private func save(provider: NSItemProvider) async throws -> Bool {
        let fileTypes = [UTType.fileURL.identifier, UTType.pdf.identifier,
                         "org.idpf.epub-container",
                         "org.openxmlformats.wordprocessingml.document"]
        for type in fileTypes where provider.hasItemConformingToTypeIdentifier(type) {
            let item = try await load(provider, typeIdentifier: type)
            if let url = item as? URL { return try saveFile(url) }
            if let url = item as? NSURL { return try saveFile(url as URL) }
            if let data = item as? Data {
                let ext = extensionFor(typeIdentifier: type)
                let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                try ShareInboxStore.enqueue(kind: kindFor(extension: ext), mode: .read,
                                            title: suggested?.isEmpty == false ? suggested! : "",
                                            fallbackTitle: suggested?.isEmpty == false ? nil : .document,
                                            payload: data, payloadExtension: ext)
                return true
            }
        }

        // A browser can expose both a page URL and a preview image. Prefer the URL so CastReader
        // keeps the live article structure; image OCR is the fallback for image-only shares.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try await load(provider, typeIdentifier: UTType.url.identifier)
            let url = (item as? URL)
                ?? (item as? NSURL).map { $0 as URL }
                ?? (item as? String).flatMap(URL.init(string:))
                ?? (item as? NSString).flatMap { URL(string: String($0)) }
            if let url {
                if url.isFileURL { return try saveFile(url) }
                return try saveWebURL(url)
            }
        }

        for type in [UTType.plainText.identifier, UTType.html.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
            let item = try await load(provider, typeIdentifier: type)
            let text = (item as? String) ?? (item as? NSString).map(String.init)
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let sharedURL = ShareInboxLinkExtractor.firstWebURL(in: text) {
                    return try saveWebURL(sharedURL)
                }
                let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                try ShareInboxStore.enqueue(kind: .text, mode: .read,
                                            title: suggested?.isEmpty == false ? suggested! : "",
                                            fallbackTitle: suggested?.isEmpty == false ? nil : .text,
                                            payload: Data(text.utf8), payloadExtension: type == UTType.html.identifier ? "html" : "txt")
                return true
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let item = try await load(provider, typeIdentifier: UTType.image.identifier)
            let data: Data?
            if let image = item as? UIImage { data = image.jpegData(compressionQuality: 0.92) }
            else if let url = item as? URL { data = try? Data(contentsOf: url) }
            else { data = item as? Data }
            if let data {
                let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                try ShareInboxStore.enqueue(kind: .image, mode: .read,
                                            title: suggested?.isEmpty == false ? suggested! : "",
                                            fallbackTitle: suggested?.isEmpty == false ? nil : .image,
                                            payload: data, payloadExtension: "jpg")
                return true
            }
        }
        return false
    }

    private func saveWebURL(_ url: URL) throws -> Bool {
        guard ShareInboxLinkExtractor.isReadableWebURL(url) else { return false }
        let title = url.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        try ShareInboxStore.enqueue(
            kind: .url,
            mode: .read,
            title: title,
            fallbackTitle: title.isEmpty ? .document : nil,
            sourceURL: url.absoluteString
        )
        return true
    }

    private func saveFile(_ url: URL) throws -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard ["pdf", "epub", "docx", "txt", "text", "md", "markdown", "html", "htm",
               "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff"].contains(ext) else {
            return false
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 100 * 1024 * 1024 else { throw ShareError.tooLarge }
        try ShareInboxStore.enqueue(kind: kindFor(extension: ext), mode: .read,
                                    title: url.deletingPathExtension().lastPathComponent,
                                    payload: data, payloadExtension: ext)
        return true
    }

    private func load(_ provider: NSItemProvider, typeIdentifier: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: ShareError.unsupported) }
            }
        }
    }

    private func extensionFor(typeIdentifier: String) -> String {
        switch typeIdentifier {
        case UTType.pdf.identifier: return "pdf"
        case "org.idpf.epub-container": return "epub"
        case "org.openxmlformats.wordprocessingml.document": return "docx"
        default: return "dat"
        }
    }

    private func kindFor(extension ext: String) -> ShareInboxKind {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "epub": return .epub
        case "docx": return .docx
        case "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff": return .image
        default: return .text
        }
    }

    private enum ShareError: Error { case unsupported, tooLarge }
}
