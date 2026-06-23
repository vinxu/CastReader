//
//  HomeView.swift
//  CastReader
//
//  首页：三大入口「拍摄 / 上传文件 / 输入文本」→ 进入阅读宿主（朗读/解读）。
//  图片走 OCR；PDF/TXT 本地即时解析；EPUB/DOCX 等走后端处理，进「文库」。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @StateObject private var captureVM = CaptureFlowViewModel()
    @StateObject private var importVM = ImportViewModel()
    @State private var showCamera = false
    @State private var showCaptureDialog = false
    @State private var cameraSource: UIImagePickerController.SourceType = .camera
    @State private var pendingCameraSource: UIImagePickerController.SourceType?
    @State private var showTextInput = false
    @State private var showURLInput = false
    @State private var showFileImporter = false
    @State private var notice: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    EntryCard(icon: "camera.viewfinder", title: String(localized: "拍摄 / 相册"), subtitle: String(localized: "拍照或从相册选图，识别文字"),
                              color: AppTheme.primary) { showCaptureDialog = true }
                    EntryCard(icon: "doc.badge.plus", title: String(localized: "上传文件"), subtitle: String(localized: "PDF / TXT / 图片 / EPUB"),
                              color: AppTheme.primaryDark) { showFileImporter = true }
                    EntryCard(icon: "link", title: String(localized: "输入网址"), subtitle: String(localized: "打开网页，朗读或解读"),
                              color: AppTheme.primary) { showURLInput = true }
                    EntryCard(icon: "text.cursor", title: String(localized: "输入文本"), subtitle: String(localized: "粘贴或输入一段文字"),
                              color: AppTheme.foreground) { showTextInput = true }
                }
                .padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("CastReader")
            .overlay { if captureVM.isProcessing || importVM.isUploading { processingOverlay } }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showCaptureDialog, onDismiss: {
            // sheet 关闭后再开相机/相册，避免两层 modal 同时 present 冲突
            if let src = pendingCameraSource { pendingCameraSource = nil; cameraSource = src; showCamera = true }
        }) {
            photoSourceSheet
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(
                sourceType: cameraSource,
                onImage: { image in
                    showCamera = false
                    Task {
                        await captureVM.process(image: image)
                        if let doc = captureVM.document { coordinator.open(doc); captureVM.reset() }
                    }
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showTextInput) {
            TextInputSheet { title, text in
                showTextInput = false
                let doc = DocumentBuilder.fromPlainText(text, title: title)
                if !doc.isEmpty { coordinator.open(doc) }
            }
        }
        .sheet(isPresented: $showURLInput) {
            URLInputSheet { urlString in
                showURLInput = false
                if let doc = makeWebDocument(urlString) { coordinator.open(doc) }
                else { notice = String(localized: "网址无效") }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: supportedTypes, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                handleImportedFile(url)
            }
        }
        .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(notice ?? "") }
        .alert("识别失败", isPresented: Binding(get: { captureVM.error != nil }, set: { if !$0 { captureVM.error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(captureVM.error ?? "") }
    }

    /// 照片来源选择（替代 confirmationDialog；底部小卡片，位置/样式可控）。
    private var photoSourceSheet: some View {
        VStack(spacing: 0) {
            Text("照片来源")
                .font(.headline)
                .foregroundColor(AppTheme.foreground)
                .padding(.top, 22).padding(.bottom, 14)
            Divider()
            sourceRow(String(localized: "拍照"), "camera") { pendingCameraSource = .camera; showCaptureDialog = false }
            Divider()
            sourceRow(String(localized: "从相册选择"), "photo.on.rectangle") { pendingCameraSource = .photoLibrary; showCaptureDialog = false }
            Spacer()
        }
        .presentationDetents([.height(210)])
        .presentationDragIndicator(.visible)
    }

    private func sourceRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 26)
                Text(title)
                Spacer()
            }
            .font(.body)
            .foregroundColor(AppTheme.foreground)
            .padding(.horizontal, 24).padding(.vertical, 17)
            .contentShape(Rectangle())
        }
    }

    private var supportedTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .image, .text]
        if let epub = UTType("org.idpf.epub-container") { types.append(epub) }
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") { types.append(docx) }
        types.append(.data)
        return types
    }

    private func handleImportedFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()

        if ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff"].contains(ext) {
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                Task {
                    await captureVM.process(image: img)
                    if let doc = captureVM.document { coordinator.open(doc); captureVM.reset() }
                }
            } else { notice = String(localized: "无法读取图片") }
        } else if ext == "pdf" {
            // PDFKit 原生渲染（保排版）：保留 PDF 字节给 PDFView，按句记录 page+range 供高亮。
            if let doc = DocumentBuilder.fromPDFNative(url: url) { coordinator.open(doc) }
            else { notice = String(localized: "无法读取该 PDF（可能是扫描件无文字层，请用「拍摄」）") }
        } else if ["txt", "text", "md", "markdown"].contains(ext) {
            if let doc = DocumentBuilder.fromTextFile(url: url) { coordinator.open(doc) }
            else { notice = String(localized: "无法读取文本文件") }
        } else if ext == "docx" {
            // DOCX 本地渲染（WebView 内 mammoth 保排版）——不上传后端。
            if let data = try? Data(contentsOf: url) {
                let title = url.deletingPathExtension().lastPathComponent
                coordinator.open(ReadingDocument(title: title, sourceKind: .docx, paragraphs: [], fileData: data))
            } else { notice = String(localized: "无法读取该文件") }
        } else if ext == "epub" {
            // EPUB 原生解析（ZIPFoundation + SwiftSoup，含内嵌图片）——不上传、不走 WebView。
            // 大书 4000+ 段解析较重，后台线程做，避免卡 UI。data 已在安全作用域内同步读出。
            if let data = try? Data(contentsOf: url) {
                let title = url.deletingPathExtension().lastPathComponent
                Task {
                    let doc = await Task.detached(priority: .userInitiated) {
                        DocumentBuilder.fromEPUB(data: data, title: title)
                    }.value
                    if let doc { coordinator.open(doc) }
                    else { notice = String(localized: "无法解析该 EPUB") }
                }
            } else { notice = String(localized: "无法读取该文件") }
        } else {
            // EPUB 等 → 暂仍走后端处理（EPUB 本地化为后续里程碑）
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tmp)
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
                Task {
                    await importVM.uploadFile(tmp)
                    notice = importVM.error ?? String(localized: "已上传，处理完成后在「文库」查看")
                }
            } catch {
                notice = String(localized: "无法读取文件：\(error.localizedDescription)")
            }
        }
    }

    /// 由用户输入的网址构建 web 源文档（WebView 直接加载，保留原网页排版）。
    private func makeWebDocument(_ raw: String) -> ReadingDocument? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        return ReadingDocument(title: host, sourceKind: .web, paragraphs: [], sourceURL: s)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(importVM.isUploading ? String(localized: "上传中…") : String(localized: "识别中…")).foregroundColor(.white).font(.subheadline)
            }
            .padding(24).background(.ultraThinMaterial).cornerRadius(16)
        }
    }
}

private struct EntryCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(color)
                    .cornerRadius(16)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundColor(AppTheme.foreground)
                    Text(subtitle).font(.subheadline).foregroundColor(AppTheme.mutedForeground)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(AppTheme.mutedForeground)
            }
            .padding(16)
            .background(AppTheme.surface)
            .cornerRadius(18)
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }
}

/// 简单文本输入面板。
private struct TextInputSheet: View {
    var onSubmit: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationView {
            Form {
                Section("标题（可选）") { TextField("未命名", text: $title) }
                Section("内容") { TextEditor(text: $text).frame(minHeight: 220) }
            }
            .navigationTitle("输入文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") { onSubmit(title, text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// 网址输入面板。
private struct URLInputSheet: View {
    var onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    var body: some View {
        NavigationView {
            Form {
                Section("网址") {
                    TextField("https://example.com/article", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("输入网址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("打开") { onSubmit(url) }
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
