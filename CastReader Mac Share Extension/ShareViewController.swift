import AppKit
import UniformTypeIdentifiers
import os

/// Native macOS presentation; durable, account-scoped storage is shared with
/// the iOS extension and the containing app. No credentials leave the app.
final class ShareViewController: NSViewController {
    private static let log = Logger(subsystem: "com.same.castreader", category: "MacShare")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private var importing = false
    private var completed = false
    private let boundary = AccountContentScopeBridge.crossProcessBoundaryToken
    private enum ImportError: Error { case unsupported, tooLarge, accountChanged }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 240))
        let title = NSTextField(labelWithString: localized("share_title"))
        title.font = .boldSystemFont(ofSize: 20)
        status.stringValue = localized("share_detail")
        saveButton.title = localized("share_save")
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("castreaderShareSave")
        let cancel = NSButton(title: localized("share_cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let stack = NSStackView(views: [title, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        preferredContentSize = view.frame.size
    }

    private func localized(_ key: String) -> String {
        let selected = UserDefaults(suiteName: ShareInboxStore.appGroup)?.string(forKey: "interfaceLanguage")
        let bundle = selected.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    @objc private func cancel() {
        completed = true
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func save() {
        guard !importing, !completed else { return }
        importing = true
        saveButton.isEnabled = false
        status.stringValue = localized("share_importing")
        Task { @MainActor in
            do {
                let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
                Self.log.info("Import items=\(items.count) attachments=\(items.flatMap { $0.attachments ?? [] }.count)")
                var saved = false
                for provider in items.flatMap({ $0.attachments ?? [] }) {
                    if try await importItem(provider) { saved = true; break }
                }
                guard saved else { throw ImportError.unsupported }
                completed = true
                status.stringValue = localized("share_saved")
                // Select the containing binary explicitly: an existing Safari
                // host may register the same public castreader:// scheme.
                let appURL = Bundle.main.bundleURL.deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([URL(string: "castreader://share-inbox")!],
                    withApplicationAt: appURL, configuration: configuration) { _, _ in }
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                Self.log.error("Import failed category=\(String(describing: type(of: error)), privacy: .public) code=\((error as NSError).code)")
                guard !completed else { return }
                status.stringValue = localized("share_failed")
                saveButton.isEnabled = true
                importing = false
            }
        }
    }

    private func checkBoundary() throws {
        guard !completed, boundary == AccountContentScopeBridge.crossProcessBoundaryToken else {
            throw ImportError.accountChanged
        }
    }

    private func load(_ provider: NSItemProvider, _ type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: ImportError.unsupported) }
            }
        }
    }

    private func importItem(_ provider: NSItemProvider) async throws -> Bool {
        let types = [UTType.fileURL.identifier, UTType.pdf.identifier, "org.idpf.epub-container",
                     "org.openxmlformats.wordprocessingml.document", UTType.url.identifier,
                     UTType.plainText.identifier, UTType.html.identifier, UTType.image.identifier]
        for type in types where provider.hasItemConformingToTypeIdentifier(type) {
            guard let item = try? await load(provider, type) else { continue }
            Self.log.info("Loaded representation type=\(type, privacy: .public) class=\(String(describing: Swift.type(of: item)), privacy: .public)")
            try checkBoundary()
            if let url = ShareInboxLinkExtractor.providerURL(from: item, typeIdentifier: type) {
                if url.isFileURL {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let ext = url.pathExtension.lowercased()
                    guard supportedExtensions.contains(ext) else { continue }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 100 * 1024 * 1024 else { throw ImportError.tooLarge }
                    try enqueue(try Data(contentsOf: url, options: .mappedIfSafe), ext: ext,
                                title: url.deletingPathExtension().lastPathComponent)
                    return true
                }
                if try saveURL(url) { return true }
            }
            if let text = (item as? String) ?? (item as? NSString).map(String.init) {
                if let url = ShareInboxLinkExtractor.firstWebURL(in: text), try saveURL(url) { return true }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                try enqueue(Data(text.utf8), ext: type == UTType.html.identifier ? "html" : "txt", title: provider.suggestedName ?? "")
                return true
            }
            if let image = item as? NSImage, let data = image.tiffRepresentation {
                try enqueue(data, ext: "tiff", title: provider.suggestedName ?? "")
                return true
            }
            if let data = item as? Data {
                let ext = [UTType.pdf.identifier: "pdf", "org.idpf.epub-container": "epub",
                           "org.openxmlformats.wordprocessingml.document": "docx",
                           UTType.image.identifier: "png", UTType.html.identifier: "html",
                           UTType.plainText.identifier: "txt"][type]
                guard let ext else { continue }
                try enqueue(data, ext: ext, title: provider.suggestedName ?? "")
                return true
            }
        }
        return false
    }

    private func saveURL(_ url: URL) throws -> Bool {
        guard ShareInboxLinkExtractor.isReadableWebURL(url) else { return false }
        try checkBoundary()
        if let video = YouTubeURLParser.parse(url.absoluteString) {
            return YouTubePendingLinkStore.enqueue(video.canonicalURLString, entry: .share)
        }
        try ShareInboxStore.enqueue(kind: .url, mode: .read, title: url.host ?? "", sourceURL: url.absoluteString)
        return true
    }

    private let supportedExtensions: Set<String> = ["pdf", "epub", "docx", "txt", "text", "md", "markdown", "html", "htm",
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff"]
    private func enqueue(_ data: Data, ext: String, title: String) throws {
        try checkBoundary()
        guard data.count <= 100 * 1024 * 1024 else { throw ImportError.tooLarge }
        let kind: ShareInboxKind
        switch ext {
        case "pdf": kind = .pdf
        case "epub": kind = .epub
        case "docx": kind = .docx
        case "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff": kind = .image
        default: kind = .text
        }
        try ShareInboxStore.enqueue(kind: kind, mode: .read, title: title,
            fallbackTitle: title.isEmpty ? (kind == .image ? .image : (kind == .text ? .text : .document)) : nil,
            payload: data, payloadExtension: ext)
    }
}
