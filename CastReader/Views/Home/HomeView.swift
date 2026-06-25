//
//  HomeView.swift
//  CastReader
//
//  首页 = 长内容批注本：顶部「继续看」（最近批注材料）+ 6 个场景入口（论文/书籍/报告/合同/教材/说明书）。
//  点场景 → 写入 scenario → 触发该场景主入口（文件/拍照/网址）→ 落地后自动进「解读」（划重点+批注）。
//  通用导入由底部 ➕ 触发（scenario=null，零回归）。剪贴板快捷卡片仍由 MainTabView 的 sheet 承载。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 导入来源（场景主入口 + ➕ 通用导入共用）。
enum ImportSource: String, Identifiable, CaseIterable {
    case camera, photoLibrary, file, url, text
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .camera: return "拍照"
        case .photoLibrary: return "上传图片"
        case .file: return "上传文件"
        case .url: return "输入网址"
        case .text: return "输入文字"
        }
    }
    var icon: String {
        switch self {
        case .camera: return "camera"
        case .photoLibrary: return "photo.on.rectangle"
        case .file: return "doc.badge.plus"
        case .url: return "link"
        case .text: return "text.cursor"
        }
    }

    /// ➕ 通用导入：5 种方式全列。
    static let general: [ImportSource] = [.camera, .file, .url, .text, .photoLibrary]

    /// 各场景主要来源（PRD §1「主要来源」列）。
    static func sources(for ct: ExplainContentType) -> [ImportSource] {
        switch ct {
        case .paper:    return [.file, .url]
        case .book:     return [.file]
        case .report:   return [.file, .url]
        case .contract: return [.file, .camera]
        case .study:    return [.file, .camera]
        case .manual:   return [.file, .camera]
        }
    }
}

/// ➕（底部中间）→ HomeView 通用导入的跨视图触发器（MainTabView 持有并注入）。
/// ➕ 用原生 Menu 列来源、锚定到按钮；选中后把来源经此交给 HomeView 真正 present（文件选择器/相机/输入框在 HomeView）。
final class ImportRouter: ObservableObject {
    @Published var generalToken = 0
    var chosenSource: ImportSource?   // ➕ 菜单选中的来源（通用导入 scenario=nil）
    func pick(_ source: ImportSource) { chosenSource = source; generalToken += 1 }
}

struct HomeView: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @EnvironmentObject private var importRouter: ImportRouter
    @ObservedObject private var history = HistoryStore.shared
    @StateObject private var captureVM = CaptureFlowViewModel()
    @StateObject private var importVM = ImportViewModel()

    /// 文字/网址输入合并到单一 .sheet(item:)，避免「同一 View 多个 .sheet(isPresented:)」只present一个的 SwiftUI 坑。
    enum InputSheet: Int, Identifiable { case text, url; var id: Int { rawValue } }

    // 导入流程状态
    @State private var importScenario: String?      // 本次导入要附加的场景 content_type（nil = 通用）
    @State private var inputSheet: InputSheet?

    @State private var showCamera = false
    @State private var cameraSource: UIImagePickerController.SourceType = .camera
    @State private var showFileImporter = false
    @State private var notice: String?

    private let scenarioColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !history.records.isEmpty { continueSection }
                    scenarioSection
                }
                .padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("CastReader")
            .overlay { if captureVM.isProcessing || importVM.isUploading { processingOverlay } }
        }
        .navigationViewStyle(.stack)
        // ➕（底部）选了来源 → 通用导入（scenario=nil）。来源选择由 ➕ 原生 Menu 承载，锚定到按钮。
        .onChange(of: importRouter.generalToken) { _ in
            if let src = importRouter.chosenSource {
                importScenario = nil
                trigger(src)
                importRouter.chosenSource = nil
            }
        }
        .sheet(item: $inputSheet) { sheet in
            switch sheet {
            case .text:
                TextInputSheet { title, text in
                    inputSheet = nil
                    let doc = DocumentBuilder.fromPlainText(text, title: title)
                    if !doc.isEmpty { finishImport(doc) }
                }
            case .url:
                URLInputSheet { urlString in
                    inputSheet = nil
                    if let doc = makeWebDocument(urlString) { finishImport(doc) }
                    else { notice = String(localized: "网址无效") }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(
                sourceType: cameraSource,
                onImage: { image in
                    showCamera = false
                    Task {
                        await captureVM.process(image: image)
                        if let doc = captureVM.document { finishImport(doc); captureVM.reset() }
                    }
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
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

    // MARK: - 继续看

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("继续看").font(.headline).foregroundColor(AppTheme.foreground)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(history.records.prefix(8)) { rec in
                        ContinueCard(record: rec) { reopen(rec) }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, -2)
        }
    }

    // MARK: - 场景入口

    private var scenarioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("自动划重点 · 写批注").font(.headline).foregroundColor(AppTheme.foreground)
                Text("选一个场景，AI 在你的原文上划重点、写批注").font(.caption).foregroundColor(AppTheme.mutedForeground)
            }
            LazyVGrid(columns: scenarioColumns, spacing: 14) {
                ForEach(ExplainContentType.allCases) { ct in
                    let sources = ImportSource.sources(for: ct)
                    if sources.count == 1 {
                        // 单来源：直接触发（无需选择）。
                        Button {
                            importScenario = ct.rawValue
                            trigger(sources[0])
                        } label: { ScenarioCard(ct: ct) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("scenario-\(ct.rawValue)")
                    } else {
                        // 多来源：原生 Menu —— 系统自动锚定到卡片、箭头指向它，符合当前 iOS UI。
                        Menu {
                            ForEach(sources) { src in
                                Button {
                                    importScenario = ct.rawValue
                                    trigger(src)
                                } label: { Label(src.label, systemImage: src.icon) }
                            }
                        } label: { ScenarioCard(ct: ct) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("scenario-\(ct.rawValue)")
                    }
                }
            }
        }
    }

    // MARK: - 导入触发

    /// 触发选中的导入来源。异步一帧：让来源 Menu 完全收起后再 present 下一个 modal，避免双层冲突。
    private func trigger(_ src: ImportSource) {
        switch src {
        case .camera:       cameraSource = .camera; DispatchQueue.main.async { showCamera = true }
        case .photoLibrary: cameraSource = .photoLibrary; DispatchQueue.main.async { showCamera = true }
        case .file:         DispatchQueue.main.async { showFileImporter = true }
        case .url:          DispatchQueue.main.async { inputSheet = .url }
        case .text:         DispatchQueue.main.async { inputSheet = .text }
        }
    }

    /// 落地：有场景 → 进「解读」并自动开播；通用导入 → 默认朗读（零回归）。
    private func finishImport(_ doc: ReadingDocument) {
        if let sc = importScenario {
            coordinator.open(doc, mode: .explain, autoplay: true, scenario: sc)
        } else {
            coordinator.open(doc)
        }
        importScenario = nil
    }

    private func reopen(_ rec: HistoryRecord) {
        Task {
            if let doc = await history.reopen(rec) { coordinator.open(doc) }
        }
    }

    // MARK: - 文件处理

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
                    if let doc = captureVM.document { finishImport(doc); captureVM.reset() }
                }
            } else { notice = String(localized: "无法读取图片") }
        } else if ext == "pdf" {
            // PDFKit 原生渲染（保排版）：保留 PDF 字节给 PDFView，按句记录 page+range 供高亮。
            if let doc = DocumentBuilder.fromPDFNative(url: url) { finishImport(doc) }
            else { notice = String(localized: "无法读取该 PDF（可能是扫描件无文字层，请用「拍摄」）") }
        } else if ["txt", "text", "md", "markdown"].contains(ext) {
            if let doc = DocumentBuilder.fromTextFile(url: url) { finishImport(doc) }
            else { notice = String(localized: "无法读取文本文件") }
        } else if ext == "docx" {
            // DOCX 本地渲染（WebView 内 mammoth 保排版）——不上传后端。
            if let data = try? Data(contentsOf: url) {
                // 标题：DOCX 内嵌标题（core.xml/首段）优先，回退文件名。
                let title = DocumentBuilder.docxTitle(data: data) ?? url.deletingPathExtension().lastPathComponent
                finishImport(ReadingDocument(title: title, sourceKind: .docx, paragraphs: [], fileData: data))
            } else { notice = String(localized: "无法读取该文件") }
        } else if ext == "epub" {
            // EPUB 原生解析（ZIPFoundation + SwiftSoup，含内嵌图片）——不上传、不走 WebView。
            // 大书 4000+ 段解析较重，后台线程做，避免卡 UI。data 已在安全作用域内同步读出。
            if let data = try? Data(contentsOf: url) {
                let title = url.deletingPathExtension().lastPathComponent
                let scenario = importScenario   // 捕获当前场景（detached 解析期间 finishImport 仍按它走）
                Task {
                    let doc = await Task.detached(priority: .userInitiated) {
                        DocumentBuilder.fromEPUB(data: data, title: title)
                    }.value
                    importScenario = scenario
                    if let doc { finishImport(doc) }
                    else { notice = String(localized: "无法解析该 EPUB") }
                }
            } else { notice = String(localized: "无法读取该文件") }
        } else {
            // 其他未知格式 → 暂仍走后端处理
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

// MARK: - 场景卡片

private struct ScenarioCard: View {
    let ct: ExplainContentType

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: ct.icon)
                .font(.system(size: 22))
                .foregroundColor(AppTheme.primary)
                .frame(width: 46, height: 46)
                .background(AppTheme.primary.opacity(0.12))
                .cornerRadius(12)
            Text(ct.displayName).font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.foreground)
            Text(ct.subtitle)
                .font(.caption2).foregroundColor(AppTheme.mutedForeground)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(14)
        .background(AppTheme.surface)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .contentShape(Rectangle())
    }
}

// MARK: - 继续看卡片

private struct ContinueCard: View {
    let record: HistoryRecord
    let action: () -> Void

    private let cardWidth: CGFloat = 168

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 封面：固定 16:9，scaledToFill 裁切填充（不拉伸）；只圆上角由整卡 clip 实现。
                CoverThumbnail(record: record, cornerRadius: 0)
                    .frame(width: cardWidth, height: cardWidth * 9 / 16)
                Text(record.title)
                    .font(.caption.weight(.semibold)).foregroundColor(AppTheme.foreground)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(width: cardWidth - 20, height: 38, alignment: .topLeading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(width: cardWidth)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.foreground.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
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
