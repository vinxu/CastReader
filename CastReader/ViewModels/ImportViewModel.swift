//
//  ImportViewModel.swift
//  CastReader
//

import Foundation
import CommonCrypto

/// Result of EPUB upload for navigation to player
struct EPUBUploadResult: Identifiable {
    let id: String  // Same as bookId
    let bookId: String
    let title: String
    let mdUrl: String
    let coverUrl: String?
    let language: String  // 文档语言

    init(bookId: String, title: String, mdUrl: String, coverUrl: String?, language: String = "en") {
        self.id = bookId
        self.bookId = bookId
        self.title = title
        self.mdUrl = mdUrl
        self.coverUrl = coverUrl
        self.language = language
    }
}

/// Result of text upload for navigation to player
struct TextUploadResult: Identifiable {
    let id: String
    let documentId: String
    let title: String
    let mdUrl: String
    let language: String  // 文档语言

    init(documentId: String, title: String, mdUrl: String, language: String = "en") {
        self.id = documentId
        self.documentId = documentId
        self.title = title
        self.mdUrl = mdUrl
        self.language = language
    }
}

@MainActor
class ImportViewModel: ObservableObject {
    @Published var isUploading = false
    @Published var error: String?
    @Published var uploadSuccess = false
    @Published var epubUploadResult: EPUBUploadResult?  // For EPUB -> PlayerView navigation
    @Published var textUploadResult: TextUploadResult?  // For text -> PlayerView navigation

    /// Release builds emit no import diagnostics. Debug builds deliberately
    /// accept only compile-time categories, so a future edit cannot interpolate
    /// filenames, document IDs, COS object keys/URLs, response bodies or tokens.
    private func debugLog(_ category: StaticString) {
        #if DEBUG
        print("[Import] \(category)")
        #endif
    }

    /// Upload file - automatically detects EPUB vs PDF and uses appropriate upload method
    func uploadFile(_ url: URL) async {
        let filename = url.lastPathComponent.lowercased()

        if filename.hasSuffix(".epub") {
            await uploadEPUB(url)
        } else {
            await uploadPDF(url)
        }
    }

    /// Upload EPUB file - same flow as PDF (COS + notify), but backend processes synchronously
    private func uploadEPUB(_ url: URL) async {
        debugLog("epub.started")
        isUploading = true
        error = nil
        uploadSuccess = false
        epubUploadResult = nil

        do {
            // 安全作用域：document picker 来的 url 需申请；app 临时文件/本地拷贝返回 false 属正常，不当失败
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // Read file data
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            debugLog("epub.file-read")

            // Get STS credentials (same as PDF)
            debugLog("epub.sts-requested")
            let sts = try await APIService.shared.fetchSTSCredentials()
            debugLog("epub.sts-received")

            // Upload to COS (same as PDF)
            debugLog("epub.object-upload-started")
            let (key, _) = try await uploadToCOS(data: data, filename: filename, sts: sts)
            debugLog("epub.object-upload-completed")

            // Notify backend - EPUB is processed synchronously and returns document info
            debugLog("epub.notify-started")
            let response = try await APIService.shared.notifyUpload(
                filename: filename,
                filepath: key
            )

            if response.success, let doc = response.document {
                // EPUB processed synchronously - we have document info for playback
                epubUploadResult = EPUBUploadResult(
                    bookId: doc.id,
                    title: doc.name,
                    mdUrl: doc.mdUrl ?? "",
                    coverUrl: doc.thumbnail,
                    language: doc.language ?? "en"
                )
                uploadSuccess = true
                debugLog("epub.ready")
            } else if response.success {
                // Backend returned success but no document - treat as async (like PDF)
                uploadSuccess = true
                debugLog("epub.processing")
            } else {
                throw UploadError.uploadFailed
            }

        } catch {
            debugLog("epub.failed")
            self.error = error.localizedDescription
        }

        isUploading = false
        debugLog(uploadSuccess ? "epub.finished-success" : "epub.finished-failure")
    }

    /// Upload PDF file asynchronously - uploads to COS and notifies backend for async processing
    private func uploadPDF(_ url: URL) async {
        debugLog("pdf.started")
        isUploading = true
        error = nil
        uploadSuccess = false

        do {
            // 安全作用域：document picker 来的 url 需申请；app 临时文件/本地拷贝返回 false 属正常，不当失败
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // Read file data
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            debugLog("pdf.file-read")

            // Get STS credentials
            debugLog("pdf.sts-requested")
            let sts = try await APIService.shared.fetchSTSCredentials()
            debugLog("pdf.sts-received")

            // Upload to COS
            debugLog("pdf.object-upload-started")
            let (key, _) = try await uploadToCOS(data: data, filename: filename, sts: sts)
            debugLog("pdf.object-upload-completed")

            // Notify backend - use COS key as filepath (same as web)
            debugLog("pdf.notify-started")
            let response = try await APIService.shared.notifyUpload(
                filename: filename,
                filepath: key
            )
            uploadSuccess = true
            debugLog(response.success ? "pdf.notify-succeeded" : "pdf.notify-failed")

        } catch {
            debugLog("pdf.failed")
            self.error = error.localizedDescription
        }

        isUploading = false
        debugLog(uploadSuccess ? "pdf.finished-success" : "pdf.finished-failure")
    }

    func uploadText(_ text: String, title: String) async {
        debugLog("text.started")
        isUploading = true
        error = nil
        textUploadResult = nil

        do {
            let filename = "text_\(Date().timeIntervalSince1970).txt"
            guard let data = text.data(using: .utf8) else {
                throw UploadError.invalidData
            }

            // Get STS credentials
            debugLog("text.sts-requested")
            let sts = try await APIService.shared.fetchSTSCredentials()

            // Upload to COS
            debugLog("text.object-upload-started")
            let (key, _) = try await uploadToCOS(data: data, filename: filename, sts: sts)
            debugLog("text.object-upload-completed")

            // Notify backend - use COS key as filepath (same as web)
            debugLog("text.notify-started")
            let response = try await APIService.shared.notifyUpload(
                filename: filename,
                filepath: key
            )

            if response.success, let doc = response.document, let mdUrl = doc.mdUrl, !mdUrl.isEmpty {
                // Server processed synchronously - we have mdUrl for playback
                textUploadResult = TextUploadResult(
                    documentId: doc.id,
                    title: title.isEmpty ? doc.name : title,
                    mdUrl: mdUrl,
                    language: doc.language ?? "en"
                )
                debugLog("text.ready")
            } else if response.success {
                // Backend returned success but no mdUrl - treat as async
                debugLog("text.processing")
                self.error = "Processing... Please check Library later."
            } else {
                throw UploadError.uploadFailed
            }

        } catch {
            debugLog("text.failed")
            self.error = error.localizedDescription
        }

        isUploading = false
        debugLog(textUploadResult == nil ? "text.finished-failure" : "text.finished-success")
    }

    /// Upload image for OCR - same flow as PDF (COS + notify), backend processes asynchronously
    func uploadImage(imageData: Data, filename: String) async {
        debugLog("image.started")
        isUploading = true
        error = nil
        uploadSuccess = false

        do {
            // Get STS credentials
            debugLog("image.sts-requested")
            let sts = try await APIService.shared.fetchSTSCredentials()
            debugLog("image.sts-received")

            // Upload to COS
            debugLog("image.object-upload-started")
            let (key, _) = try await uploadToCOS(data: imageData, filename: filename, sts: sts)
            debugLog("image.object-upload-completed")

            // Notify backend - OCR is processed asynchronously like PDF
            debugLog("image.notify-started")
            let response = try await APIService.shared.notifyUpload(
                filename: filename,
                filepath: key
            )
            uploadSuccess = true
            debugLog(response.success ? "image.notify-succeeded" : "image.notify-failed")

        } catch {
            debugLog("image.failed")
            self.error = error.localizedDescription
        }

        isUploading = false
        debugLog(uploadSuccess ? "image.finished-success" : "image.finished-failure")
    }

    private func uploadToCOS(data: Data, filename: String, sts: STSCredentials) async throws -> (key: String, fullUrl: String) {
        // Clean up prefix - remove trailing slash if present
        let cleanPrefix = sts.prefix.hasSuffix("/") ? String(sts.prefix.dropLast()) : sts.prefix
        let key = "\(cleanPrefix)/\(UUID().uuidString)_\(filename)"
        let host = sts.uploadHost

        // URL encode the key for the URL
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw UploadError.invalidURL
        }
        let urlString = "https://\(host)/\(encodedKey)"

        guard let url = URL(string: urlString) else {
            debugLog("object-upload.invalid-url")
            throw UploadError.invalidURL
        }

        // Generate COS signature
        let httpMethod = "put"
        let uriPathname = "/\(key)"

        // Time range for signature (valid for 1 hour)
        let startTime = Int(Date().timeIntervalSince1970)
        let endTime = startTime + 3600
        let keyTime = "\(startTime);\(endTime)"

        // Headers to sign (sorted alphabetically)
        let contentType = "application/octet-stream"
        let signedHeaders = [
            "content-type": contentType,
            "host": host,
            "x-cos-security-token": sts.sessionToken
        ]
        let headerList = signedHeaders.keys.sorted().joined(separator: ";")
        let headerString = signedHeaders.keys.sorted().map { key in
            "\(key.lowercased())=\(urlEncode(signedHeaders[key]!))"
        }.joined(separator: "&")

        // Generate signature
        let signKey = hmacSHA1(key: sts.secretAccessKey, data: keyTime)
        let httpString = "\(httpMethod)\n\(uriPathname)\n\n\(headerString)\n"
        let httpStringSha1 = sha1Hash(httpString)
        let stringToSign = "sha1\n\(keyTime)\n\(httpStringSha1)\n"
        let signature = hmacSHA1(key: signKey, data: stringToSign)

        let authorization = "q-sign-algorithm=sha1&q-ak=\(sts.accessKeyId)&q-sign-time=\(keyTime)&q-key-time=\(keyTime)&q-header-list=\(headerList)&q-url-param-list=&q-signature=\(signature)"

        debugLog("object-upload.request-signed")

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(sts.sessionToken, forHTTPHeaderField: "x-cos-security-token")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        debugLog("object-upload.request-started")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            debugLog("object-upload.invalid-response")
            throw UploadError.uploadFailed
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            debugLog("object-upload.http-failure")
            throw UploadError.uploadFailed
        }

        debugLog("object-upload.succeeded")

        return (key, urlString)
    }

    // MARK: - COS Signature Helpers

    private func hmacSHA1(key: String, data: String) -> String {
        let keyData = key.data(using: .utf8)!
        let dataData = data.data(using: .utf8)!

        var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        keyData.withUnsafeBytes { keyBytes in
            dataData.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       keyBytes.baseAddress, keyData.count,
                       dataBytes.baseAddress, dataData.count,
                       &result)
            }
        }

        return result.map { String(format: "%02x", $0) }.joined()
    }

    private func sha1Hash(_ string: String) -> String {
        let data = string.data(using: .utf8)!
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
        }

        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

enum UploadError: Error, LocalizedError {
    case accessDenied
    case invalidData
    case invalidURL
    case uploadFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Cannot access the selected file"
        case .invalidData: return "Invalid file data"
        case .invalidURL: return "Invalid upload URL"
        case .uploadFailed: return "Upload failed"
        }
    }
}
