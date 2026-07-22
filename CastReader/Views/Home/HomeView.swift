//
//  HomeView.swift
//  CastReader
//
//  首页 = 长内容批注本：顶部「继续看」（最近批注材料）+ 6 个场景入口（论文/书籍/报告/合同/教材/说明书）。
//  点场景 → 场景导入面板（场景只决定 content_type，不限制来源）→ 用户选择朗读/解读打开方式。
//  通用导入由底部 ➕ 触发（scenario=nil，默认朗读，可在面板内选场景）。剪贴板快捷卡片仍由 MainTabView 的 sheet 承载。
//

import SwiftUI
import StoreKit
import UIKit
import UniformTypeIdentifiers
#if DEBUG
import AVFoundation
import Combine
import WebKit
#endif

/// 导入来源（场景入口 + ➕ 通用导入共用）。场景只改变排序，不再限制来源能力。
enum ImportSource: String, Identifiable, CaseIterable {
    case camera, photoLibrary, file, url, text
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .camera: return "拍照"
        case .photoLibrary: return "上传图片"
        case .file: return "上传文件"
        case .url: return "输入网址"
        case .text: return "粘贴文本"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .camera: return "拍摄纸质内容或屏幕"
        case .photoLibrary: return "选择截图或图片"
        case .file: return "PDF、DOCX、EPUB、TXT"
        case .url: return "网页、文档站、文章链接"
        case .text: return "粘贴或输入一段文本"
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

    /// ➕ 通用导入：以 URL / 文件优先，兼容拍摄、图片、文本。
    static let general: [ImportSource] = [.url, .file, .camera, .photoLibrary, .text]

    /// 各场景推荐来源排序。所有场景都支持全部来源，只是按最自然的使用方式排序。
    static func sources(for ct: ExplainContentType) -> [ImportSource] {
        switch ct {
        case .paper:    return [.file, .url, .text, .camera, .photoLibrary]
        case .book:     return [.file, .text, .url, .camera, .photoLibrary]
        case .report:   return [.file, .url, .camera, .photoLibrary, .text]
        case .contract: return [.file, .camera, .photoLibrary, .text, .url]
        case .study:    return [.file, .camera, .photoLibrary, .url, .text]
        case .manual:   return [.url, .file, .text, .camera, .photoLibrary]
        }
    }

    var analyticsSource: AnalyticsContentSource {
        switch self {
        case .camera: return .camera
        case .photoLibrary: return .photoLibrary
        case .file: return .file
        case .url: return .url
        case .text: return .text
        }
    }

    var analyticsFormat: AnalyticsContentFormat {
        switch self {
        case .camera, .photoLibrary: return .photo
        case .url: return .web
        case .text: return .text
        case .file: return .unknown
        }
    }
}

/// ➕（底部中间）→ HomeView 通用导入的跨视图触发器（MainTabView 持有并注入）。
/// ➕ 只负责打开快速导入面板；真正的来源选择与 present 仍在 HomeView。
final class ImportRouter: ObservableObject {
    @Published var generalToken = 0
    @Published var hideMainChrome = false
    func openQuickImport() { generalToken += 1 }
}

struct HomeView: View {
    let shareInboxUnreadCount: Int
    let onOpenShareInbox: () -> Void

    @EnvironmentObject private var coordinator: PlayerCoordinator
    @EnvironmentObject private var importRouter: ImportRouter
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var auth = AuthService.shared
    @StateObject private var captureVM = CaptureFlowViewModel()
    @StateObject private var importVM = ImportViewModel()
    @ObservedObject private var kindleStore = KindleLibraryStore.shared

    init(shareInboxUnreadCount: Int = 0, onOpenShareInbox: @escaping () -> Void = {}) {
        self.shareInboxUnreadCount = shareInboxUnreadCount
        self.onOpenShareInbox = onOpenShareInbox
    }

    /// 所有 sheet 合并到单一入口，避免「同一 View 多个 .sheet」互相抢 present。
    private enum HomeSheet: Identifiable {
        case importPanel(ImportPanel)
        case text
        case url
        case proDetails
        case loginForAnnualPurchase

        var id: String {
            switch self {
            case .importPanel(let panel): return "import-\(panel.id)"
            case .text: return "text"
            case .url: return "url"
            case .proDetails: return "pro-details"
            case .loginForAnnualPurchase: return "pro-login"
            }
        }
    }

    // 导入流程状态
    @State private var importScenario: String?      // 本次导入要附加的场景 content_type（nil = 通用）
    @State private var importMode: ReaderMode = .read
    @State private var importAnalyticsContext: AnalyticsContentContext?
    @State private var activeSheet: HomeSheet?

    @State private var imagePickerRequest: ImagePickerRequest?
    @State private var showFileImporter = false
    @State private var notice: String?
    @State private var isProcessingPDF = false
    @State private var isLoadingProProducts = false
    @State private var didAttemptProProductLoad = false
    @State private var isPurchasingAnnual = false
    @State private var pendingAnnualPurchaseAfterLogin = false
    @State private var didTrackHomeProCardImpression = false
#if DEBUG
    @State private var showKindleProbe = false
    @State private var showWeReadProbe = false
#endif

    private let scenarioColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !continueRecords.isEmpty { continueSection }
                    scenarioSection
                    KindleHomeSection(store: kindleStore)
                    if showsWeReadModule {
                        WeReadHomeSection()
                    }
                    if !pro.isPro { homeProCard }
                }
                .padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("CastReader")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenShareInbox) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: shareInboxUnreadCount > 0 ? "tray.full" : "tray")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(AppTheme.foreground)
                                .frame(width: 30, height: 30)
                            if shareInboxUnreadCount > 0 {
                                Circle()
                                    .fill(AppTheme.primary)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(AppTheme.background, lineWidth: 1.5))
                                    .offset(x: 1, y: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("contentInboxButton")
                    .accessibilityLabel(Text(AppLocalized("内容接收箱")))
                }
            }
            .overlay { if captureVM.isProcessing || importVM.isUploading || isProcessingPDF { processingOverlay } }
        }
        .navigationViewStyle(.stack)
        // ➕（底部）→ 快速导入面板。默认通用导入，也可在面板里选择场景。
        .onChange(of: importRouter.generalToken) { _ in
            activeSheet = .importPanel(.general)
        }
        .sheet(item: $activeSheet, onDismiss: handleHomeSheetDismissed) { sheet in
            switch sheet {
            case .importPanel(let panel):
                ImportOptionsSheet(panel: panel) { scenario, mode, source in
                    beginImport(source, scenario: scenario, mode: mode)
                }
            case .text:
                TextInputSheet { title, text in
                    activeSheet = nil
                    let doc = DocumentBuilder.fromPlainText(text, title: title)
                    if !doc.isEmpty { finishImport(doc) }
                    else { failImport(stage: "parse", code: "empty_content") }
                }
            case .url:
                URLInputSheet { urlString in
                    activeSheet = nil
                    if let doc = makeWebDocument(urlString) { finishImport(doc) }
                    else {
                        failImport(stage: "validation", code: "invalid_url")
                        notice = AppLocalized("网址无效")
                    }
                }
            case .proDetails:
                PaywallView(
                    analyticsTrigger: "home_pro_card_secondary",
                    analyticsSurface: "home_pro_card"
                )
            case .loginForAnnualPurchase:
                LoginView()
            }
        }
        .task { await loadHomeProProductsIfNeeded() }
#if DEBUG
        .sheet(isPresented: $showKindleProbe) {
            KindleBackgroundProbeSheet()
        }
#endif
        .fullScreenCover(item: $imagePickerRequest) { request in
            CameraView(
                sourceType: request.sourceType,
                onImage: { image in
                    imagePickerRequest = nil
                    Task {
                        await captureVM.process(image: image)
                        if let doc = captureVM.document {
                            finishImport(doc)
                            captureVM.reset()
                        } else {
                            failImport(stage: "ocr", code: captureVM.error == nil ? "empty_content" : "recognition_failed")
                        }
                    }
                },
                onCancel: { imagePickerRequest = nil }
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

    // MARK: - 首页 Pro 卡片

    private var homeProCard: some View {
        let yearly = pro.yearly
        let loading = isLoadingProProducts || (!didAttemptProProductLoad && yearly == nil)
        return HomeProUpsellCard(
            annualDisplayPrice: yearly?.displayPrice,
            weeklyDisplayPrice: yearly.map { HomeProPricing.weeklyDisplayPrice(for: $0) },
            isLoadingProducts: loading,
            isPurchasing: isPurchasingAnnual || pro.purchaseInFlight,
            onPrimaryAction: handleHomeProPrimaryAction,
            onShowPlans: { activeSheet = .proDetails }
        )
        .onAppear(perform: trackHomeProCardImpressionIfNeeded)
    }

    @MainActor
    private func loadHomeProProductsIfNeeded() async {
        guard !pro.isPro else { return }
        if pro.yearly != nil {
            didAttemptProProductLoad = true
            return
        }
        guard !isLoadingProProducts else { return }
        isLoadingProProducts = true
        await pro.loadProducts()
        isLoadingProProducts = false
        didAttemptProProductLoad = true
    }

    private func handleHomeProPrimaryAction() {
        let action = HomeProPurchaseContract.primaryAction(
            isPro: pro.isPro,
            hasYearlyProduct: pro.yearly != nil,
            hasEmailAccount: auth.hasEmailAccount,
            isLoadingProducts: isLoadingProProducts || (!didAttemptProProductLoad && pro.yearly == nil),
            isPurchaseInFlight: isPurchasingAnnual || pro.purchaseInFlight
        )
        switch action {
        case .none:
            break
        case .requireLogin:
            pendingAnnualPurchaseAfterLogin = true
            activeSheet = .loginForAnnualPurchase
        case .purchaseYearly:
            purchaseAnnualProduct()
        case .showPlans:
            activeSheet = .proDetails
        }
    }

    private func handleHomeSheetDismissed() {
        guard pendingAnnualPurchaseAfterLogin else { return }
        pendingAnnualPurchaseAfterLogin = false
        guard auth.hasEmailAccount, !pro.isPro else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            purchaseAnnualProduct()
        }
    }

    private func purchaseAnnualProduct() {
        guard !pro.isPro,
              !isPurchasingAnnual,
              !pro.purchaseInFlight,
              auth.hasEmailAccount,
              let yearly = pro.yearly else { return }
        isPurchasingAnnual = true
        Task { @MainActor in
            _ = await pro.purchase(yearly, analyticsTrigger: "home_pro_card_yearly")
            isPurchasingAnnual = false
        }
    }

    private func trackHomeProCardImpressionIfNeeded() {
        guard !didTrackHomeProCardImpression, !pro.isPro else { return }
        didTrackHomeProCardImpression = true
        ProductAnalytics.shared.track(
            .paywallShown,
            context: AnalyticsEventContext(
                productArea: .billing,
                surface: "home_pro_card",
                entryPoint: "home_pro_card_impression"
            ),
            properties: .init(
                trigger: "home_pro_card_impression",
                entitlementState: "free",
                hadMeaningfulReading: ProductAnalytics.shared.hadMeaningfulReading
            )
        )
    }

    // MARK: - 继续看

    private var showsWeReadModule: Bool {
        WeReadAvailability.isAvailable(
            appLanguage: appLanguage.selectedLanguage,
            systemLanguageCode: Locale.autoupdatingCurrent.language.languageCode?.identifier,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        )
    }

    private var continueRecords: [HistoryRecord] {
        history.records.filter { HomeContinueContract.includes($0.sourceKind) }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("继续看").font(.headline).foregroundColor(AppTheme.foreground)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(continueRecords.prefix(8)) { rec in
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
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("解读场景").font(.headline).foregroundColor(AppTheme.foreground)
                    Text("选择导入和解读时使用的内容视角").font(.caption).foregroundColor(AppTheme.mutedForeground)
                }
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ExplainContentType.allCases) { ct in
                        Button {
                            activeSheet = .importPanel(.scenario(ct))
                        } label: {
                            ScenarioPill(ct: ct)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("scenario-\(ct.rawValue)")
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, -2)
        }
    }

#if DEBUG
    private var weReadProbeSection: some View {
        Button {
            showWeReadProbe = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.primary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("微信读书 Web 测试")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(AppTheme.foreground)
                        Text("临时")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(AppTheme.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AppTheme.primary.opacity(0.10))
                            .clipShape(Capsule())
                    }
                    Text("以电脑端模式测试登录、书架与阅读页")
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.mutedForeground.opacity(0.7))
            }
            .padding(14)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("weReadDesktopProbeButton")
    }

    private var kindleProbeSection: some View {
        Button {
            showKindleProbe = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "ladybug")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.primary.opacity(0.12))
                    .cornerRadius(11)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kindle 后台滚动测试")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                    Text("Debug only：测试锁屏后 WebView 是否还能滚动")
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.mutedForeground.opacity(0.7))
            }
            .padding(14)
            .background(AppTheme.surface)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }
#endif

    // MARK: - 导入触发

    /// 从导入面板进入具体来源。先收起面板，再 present 下一个 modal，避免双层冲突。
    private func beginImport(_ src: ImportSource, scenario: ExplainContentType?, mode: ReaderMode) {
        importScenario = scenario?.rawValue
        importMode = mode
        importAnalyticsContext = ProductAnalytics.shared.beginContentIntent(
            source: src.analyticsSource,
            format: src.analyticsFormat,
            entryPoint: scenario == nil ? "quick_import" : "scenario_import",
            intendedMode: mode == .read ? "read" : "explain"
        )
        activeSheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            trigger(src)
        }
    }

    /// 触发选中的导入来源。
    private func trigger(_ src: ImportSource) {
        switch src {
        case .camera:       DispatchQueue.main.async { imagePickerRequest = ImagePickerRequest(sourceType: .camera) }
        case .photoLibrary: DispatchQueue.main.async { imagePickerRequest = ImagePickerRequest(sourceType: .photoLibrary) }
        case .file:         DispatchQueue.main.async { showFileImporter = true }
        case .url:          DispatchQueue.main.async { activeSheet = .url }
        case .text:         DispatchQueue.main.async { activeSheet = .text }
        }
    }

    /// 落地：打开方式与场景正交。场景只注入 ExplainVM，朗读/解读由用户在入口选择。
    private func finishImport(_ doc: ReadingDocument) {
        let scenario = importScenario
        let mode = importMode
        let analyticsContext = importAnalyticsContext
        let shouldAutoplay = scenario != nil || mode == .explain
        coordinator.open(
            doc,
            mode: mode,
            autoplay: shouldAutoplay,
            scenario: scenario,
            analyticsContext: analyticsContext
        )
        importScenario = nil
        importMode = .read
        importAnalyticsContext = nil
    }

    private func failImport(stage: String, code: String) {
        guard let context = importAnalyticsContext else { return }
        ProductAnalytics.shared.contentFailed(context, stage: stage, code: code)
        importAnalyticsContext = nil
    }

    private func reopen(_ rec: HistoryRecord) {
        Task {
            if let doc = await history.reopen(rec) {
                let context = ProductAnalytics.shared.beginContentIntent(
                    source: .history,
                    format: AnalyticsContentFormat(doc.sourceKind),
                    entryPoint: "history_resume",
                    intendedMode: "read"
                )
                coordinator.open(doc, analyticsContext: context)
            }
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
                    if let doc = captureVM.document {
                        finishImport(doc)
                        captureVM.reset()
                    } else {
                        failImport(stage: "ocr", code: captureVM.error == nil ? "empty_content" : "recognition_failed")
                    }
                }
            } else {
                failImport(stage: "file_read", code: "unreadable_image")
                notice = AppLocalized("无法读取图片")
            }
        } else if ext == "pdf" {
            guard let data = try? Data(contentsOf: url) else {
                failImport(stage: "file_read", code: "pdf_read_failed")
                notice = AppLocalized("无法读取该 PDF")
                return
            }
            let title = url.deletingPathExtension().lastPathComponent
            let scenario = importScenario
            let mode = importMode
            isProcessingPDF = true
            Task {
                defer { isProcessingPDF = false }
                let doc = await DocumentBuilder.fromPDFWithOCR(
                    data: data,
                    fallbackTitle: title
                )
                importScenario = scenario
                importMode = mode
                if let doc { finishImport(doc) }
                else {
                    failImport(stage: "parse", code: "pdf_parse_or_ocr_failed")
                    notice = AppLocalized("无法读取该 PDF")
                }
            }
        } else if ["txt", "text", "md", "markdown"].contains(ext) {
            if let doc = DocumentBuilder.fromTextFile(url: url) { finishImport(doc) }
            else {
                failImport(stage: "parse", code: "text_parse_failed")
                notice = AppLocalized("无法读取文本文件")
            }
        } else if ext == "docx" {
            // DOCX 本地渲染（WebView 内 mammoth 保排版）——不上传后端。
            if let data = try? Data(contentsOf: url) {
                // 标题：DOCX 内嵌标题（core.xml/首段）优先，回退文件名。
                let title = DocumentBuilder.docxTitle(data: data) ?? url.deletingPathExtension().lastPathComponent
                finishImport(ReadingDocument(title: title, sourceKind: .docx, paragraphs: [], fileData: data))
            } else {
                failImport(stage: "file_read", code: "docx_read_failed")
                notice = AppLocalized("无法读取该文件")
            }
        } else if ext == "epub" {
            // EPUB 原生解析（ZIPFoundation + SwiftSoup，含内嵌图片）——不上传、不走 WebView。
            // 大书 4000+ 段解析较重，后台线程做，避免卡 UI。data 已在安全作用域内同步读出。
            if let data = try? Data(contentsOf: url) {
                let title = url.deletingPathExtension().lastPathComponent
                let scenario = importScenario   // 捕获当前入口状态（detached 解析期间 finishImport 仍按它走）
                let mode = importMode
                Task {
                    let doc = await Task.detached(priority: .userInitiated) {
                        DocumentBuilder.fromEPUB(data: data, title: title)
                    }.value
                    importScenario = scenario
                    importMode = mode
                    if let doc { finishImport(doc) }
                    else {
                        failImport(stage: "parse", code: "epub_parse_failed")
                        notice = AppLocalized("无法解析该 EPUB")
                    }
                }
            } else {
                failImport(stage: "file_read", code: "epub_read_failed")
                notice = AppLocalized("无法读取该文件")
            }
        } else {
            // 其他未知格式 → 暂仍走后端处理
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tmp)
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
                Task {
                    await importVM.uploadFile(tmp)
                    notice = importVM.error ?? AppLocalized("已上传，处理完成后在「文库」查看")
                }
            } catch {
                failImport(stage: "file_read", code: "copy_failed")
                notice = String(format: AppLocalized("无法读取文件：%@"), error.localizedDescription)
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
                Text(importVM.isUploading ? AppLocalized("上传中…") : AppLocalized("识别中…")).foregroundColor(.white).font(.subheadline)
            }
            .padding(24).background(.ultraThinMaterial).cornerRadius(16)
        }
    }
}

// MARK: - 导入面板

private struct ImagePickerRequest: Identifiable, Equatable {
    let sourceType: UIImagePickerController.SourceType
    let id = UUID()
}

private enum ImportPanel: Identifiable, Equatable {
    case general
    case scenario(ExplainContentType)

    var id: String {
        switch self {
        case .general: return "general"
        case .scenario(let ct): return ct.rawValue
        }
    }

    var fixedScenario: ExplainContentType? {
        switch self {
        case .general: return nil
        case .scenario(let ct): return ct
        }
    }
}

private struct ImportOptionsSheet: View {
    let panel: ImportPanel
    var onPick: (ExplainContentType?, ReaderMode, ImportSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedScenario: ExplainContentType?
    @State private var selectedMode: ReaderMode

    init(panel: ImportPanel, onPick: @escaping (ExplainContentType?, ReaderMode, ImportSource) -> Void) {
        self.panel = panel
        self.onPick = onPick
        _selectedScenario = State(initialValue: panel.fixedScenario)
        _selectedMode = State(initialValue: panel.fixedScenario == nil ? .read : .explain)
    }

    private var activeScenario: ExplainContentType? {
        panel.fixedScenario ?? selectedScenario
    }

    private var sources: [ImportSource] {
        if let activeScenario { return ImportSource.sources(for: activeScenario) }
        return ImportSource.general
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if panel.fixedScenario == nil { scenarioPicker }
                    modePicker
                    if activeScenario != nil || selectedMode == .explain {
                        depthPicker
                    }
                    sourceList
                }
                .padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(LocalizedStringKey(panel.fixedScenario == nil ? "快速导入" : "选择来源"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: activeScenario?.icon ?? "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.primary.opacity(0.12))
                    .cornerRadius(12)

                VStack(alignment: .leading, spacing: 4) {
                    Text(activeScenario?.displayName ?? AppLocalized("快速导入"))
                        .font(.headline)
                        .foregroundColor(AppTheme.foreground)
                    Text(activeScenario?.subtitle ?? AppLocalized("先导入内容，也可以指定一个解读场景"))
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let activeScenario {
                VStack(alignment: .leading, spacing: 6) {
                    Label(activeScenario.importSuitable, systemImage: "tray.and.arrow.down")
                    Label(activeScenario.importFocus, systemImage: "sparkles")
                }
                .font(.caption)
                .foregroundColor(AppTheme.mutedForeground)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.surface)
                .cornerRadius(12)
            }
        }
    }

    private var scenarioPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("解读场景")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.foreground)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ScenarioChip(
                        title: AppLocalized("通用"),
                        icon: "text.alignleft",
                        selected: selectedScenario == nil
                    ) {
                        selectedScenario = nil
                        selectedMode = .read
                    }

                    ForEach(ExplainContentType.allCases) { ct in
                        ScenarioChip(
                            title: ct.displayName,
                            icon: ct.icon,
                            selected: selectedScenario == ct
                        ) {
                            selectedScenario = ct
                            selectedMode = .explain
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("要朗读还是解读？")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.foreground)
            Picker("要朗读还是解读？", selection: $selectedMode) {
                ForEach(ReaderMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var depthPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("解读深度")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.foreground)
            Picker("解读深度", selection: $settings.explainDepth) {
                ForEach(QuickreadDepth.allCases) { depth in
                    Text(depth.displayName).tag(depth.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导入方式")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.foreground)

            ForEach(sources) { source in
                ImportSourceRow(
                    source: source,
                    recommended: source == sources.first
                ) {
                    onPick(activeScenario, selectedMode, source)
                }
            }
        }
    }
}

private struct ScenarioChip: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(selected ? AppTheme.primaryForeground : AppTheme.foreground)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(selected ? AppTheme.primary : AppTheme.surface)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selected ? Color.clear : AppTheme.foreground.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

private struct ImportSourceRow: View {
    let source: ImportSource
    let recommended: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: source.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.primary.opacity(0.12))
                    .cornerRadius(11)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(source.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(AppTheme.foreground)
                        if recommended {
                            Text("推荐")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(AppTheme.primary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(AppTheme.primary.opacity(0.12))
                                .cornerRadius(8)
                        }
                    }
                    Text(source.detail)
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.mutedForeground.opacity(0.7))
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppTheme.surface)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppTheme.foreground.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(source.label))
    }
}

private extension ExplainContentType {
    var importSuitable: LocalizedStringKey {
        switch self {
        case .paper: return "论文、arXiv、DOI 页面、学术 PDF"
        case .book: return "EPUB、PDF 长文、书摘或章节"
        case .report: return "研报、行业报告、数据分析文章"
        case .contract: return "合同、条款、协议、报价和 SLA"
        case .study: return "教材、课件、学习资料、习题讲义"
        case .manual: return "GitHub 文档、API 文档、产品手册、帮助中心"
        }
    }

    var importFocus: LocalizedStringKey {
        switch self {
        case .paper: return "关注研究问题、方法、实验和贡献"
        case .book: return "关注核心观点、概念关系和转折"
        case .report: return "关注结论、关键数据、假设和风险"
        case .contract: return "关注权利义务、金额期限和风险条款"
        case .study: return "关注定义、知识点、例题和易错点"
        case .manual: return "关注步骤、参数、限制和警告"
        }
    }
}

// MARK: - 场景卡片

private struct ScenarioPill: View {
    let ct: ExplainContentType

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ct.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.primary)
            Text(ct.displayName)
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.foreground)
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(AppTheme.surface)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
        )
    }
}

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

    var body: some View {
        Button(action: action) {
            ContinueCardContent(record: record)
        }
        .buttonStyle(.plain)
    }
}

private struct ContinueCardContent: View {
    let record: HistoryRecord

    private let cardWidth: CGFloat = 168
    private var coverHeight: CGFloat { cardWidth * 9 / 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverThumbnail(record: record, contentMode: record.sourceKind == .kindle ? .fit : .fill, cornerRadius: 0)
                .frame(width: cardWidth, height: coverHeight)
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

#if DEBUG
// MARK: - Kindle Background Probe (Debug only)

private struct KindleBackgroundProbeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @StateObject private var model = KindleBackgroundProbeModel()
    @State private var notice: String?
    @State private var showDebugTools = false

    var body: some View {
        NavigationView {
            VStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open Kindle, tap Start Probe, then lock the phone. Logs show whether JS/native scrolling survives background.")
                        .font(.caption2)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(1)
                    TextField("https://read.amazon.com/kindle-library", text: $model.urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Load") { model.load() }
                            .buttonStyle(.bordered)
                        Button(showDebugTools ? "Hide Debug" : "Debug Tools") {
                            showDebugTools.toggle()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if !model.cachedPages.isEmpty {
                            Text("Cached \(model.cachedPages.count)")
                                .font(.caption2)
                                .foregroundColor(AppTheme.mutedForeground)
                        }
                    }
                    .controlSize(.small)
                    if showDebugTools {
                        HStack {
                            Button(model.isRunning ? "Running" : "Start Probe") { model.start() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isRunning)
                            Button("Stop") { model.stop() }
                                .buttonStyle(.bordered)
                                .disabled(!model.isRunning)
                        }
                        .controlSize(.small)
                    }
                    HStack {
                        Button {
                            model.startContinuousRead()
                        } label: {
                            Label(model.isContinuousReading ? "Reading Kindle..." : "Start Continuous Read", systemImage: "speaker.wave.2.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isContinuousReading || model.isPreparingDocument)

                        Button {
                            model.stopContinuousRead()
                        } label: {
                            Label("Stop Read", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.isContinuousReading)
                    }
                    .controlSize(.small)
                    HStack {
                        Button {
                            model.startContinuousExplain()
                        } label: {
                            Label(model.isContinuousExplaining ? "Explaining Kindle..." : "Start Continuous Explain", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isContinuousExplaining || model.isPreparingDocument)

                        Button {
                            model.stopContinuousExplain()
                        } label: {
                            Label("Stop Explain", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.isContinuousExplaining)
                    }
                    .controlSize(.small)
                    if model.isContinuousReading || !model.continuousStatus.isEmpty {
                        Text(model.continuousStatus)
                            .font(.caption)
                            .foregroundColor(AppTheme.mutedForeground)
                    }
                    if let issue = model.continuousIssue {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: issue.icon)
                                    .foregroundColor(AppTheme.primary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(issue.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(AppTheme.foreground)
                                    Text(issue.message)
                                        .font(.caption2)
                                        .foregroundColor(AppTheme.mutedForeground)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if issue.canRetry {
                                Button {
                                    model.retryContinuousPipeline()
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.primary.opacity(0.08))
                        .cornerRadius(10)
                    }
                    if showDebugTools {
                        HStack {
                            Button {
                                openCurrentKindlePage(mode: .read)
                            } label: {
                                Label("Read Current Page", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isPreparingDocument)

                            Button {
                                openCurrentKindlePage(mode: .explain)
                            } label: {
                                Label("Explain Current Page", systemImage: "sparkles")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isPreparingDocument)
                        }
                        .controlSize(.small)
                        HStack {
                            Button {
                                Task { await model.prefetchNextPages(count: 3) }
                            } label: {
                                Label("Prefetch Next 3", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isPreparingDocument || model.isPrefetching)

                            if model.isPrefetching {
                                ProgressView()
                            }
                            Text("Cached \(model.cachedPages.count)")
                                .font(.caption)
                                .foregroundColor(AppTheme.mutedForeground)
                        }
                        .controlSize(.small)
                        HStack {
                            Button {
                                openCachedKindlePages(mode: .read)
                            } label: {
                                Label("Read Cached Pages", systemImage: "rectangle.stack.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isPreparingDocument || model.isPrefetching)

                            Button {
                                openCachedKindlePages(mode: .explain)
                            } label: {
                                Label("Explain Cached Pages", systemImage: "text.badge.star")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isPreparingDocument || model.isPrefetching)
                        }
                        .controlSize(.small)
                    }
                    if model.isPreparingDocument {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(model.prepareStatus)
                                .font(.caption)
                                .foregroundColor(AppTheme.mutedForeground)
                        }
                    }
                }
                .padding(.horizontal)

                ZStack {
                    KindleProbeWebView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if (model.isContinuousReading || model.isContinuousExplaining),
                       let document = model.nativePlaybackDocument {
                        KindleProbeNativePlaybackSurface(
                            document: document,
                            pageKey: model.nativePlaybackPageKey,
                            paragraphIndex: model.nativePlaybackParagraphIndex,
                            wordIndex: model.nativePlaybackWordIndex,
                            marks: model.nativePlaybackMarks,
                            status: model.continuousStatus
                        )
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.04))
                .cornerRadius(12)
                .padding(.horizontal)

                if showDebugTools && !model.cachedPages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.cachedPages) { page in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(page.key.prefix(8))
                                        .font(.caption2.monospaced().weight(.semibold))
                                    Text("\(page.paragraphCount) paras")
                                        .font(.caption2)
                                    Text("\(page.charCount) chars")
                                        .font(.caption2)
                                }
                                .foregroundColor(AppTheme.foreground)
                                .padding(8)
                                .background(AppTheme.surface)
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 54)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(model.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(AppTheme.mutedForeground)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: showDebugTools ? 120 : 72)
                    .background(AppTheme.surface)
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .onChange(of: model.logLines.count) { count in
                        guard count > 0 else { return }
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("WKWebView Probe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.stop()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            model.load()
        }
        .onDisappear {
            model.stop()
        }
        .alert("Kindle", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func openCurrentKindlePage(mode: ReaderMode) {
        Task {
            do {
                let doc = try await model.captureCurrentPageDocument()
                model.stop()
                coordinator.open(
                    doc,
                    mode: mode,
                    autoplay: true,
                    scenario: mode == .explain ? ExplainContentType.book.rawValue : nil
                )
                dismiss()
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func openCachedKindlePages(mode: ReaderMode) {
        Task {
            do {
                if model.cachedPages.isEmpty {
                    try await model.ensureCurrentPageCached()
                }
                guard let doc = model.makeCachedKindleDocument() else {
                    notice = AppLocalized("还没有可朗读的 Kindle 页面")
                    return
                }
                model.stop()
                coordinator.open(
                    doc,
                    mode: mode,
                    autoplay: true,
                    scenario: mode == .explain ? ExplainContentType.book.rawValue : nil
                )
                dismiss()
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}

private struct KindleProbeNativePlaybackSurface: View {
    let document: ReadingDocument
    let pageKey: String
    let paragraphIndex: Int
    let wordIndex: Int?
    let marks: [KindleProbeNativeMark]
    let status: String

    private var image: UIImage? {
        guard let data = document.imageData else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        GeometryReader { geo in
            if let image {
                playbackContent(image: image, size: geo.size)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text("Preparing Kindle page...")
                        .font(.caption)
                }
                .foregroundColor(AppTheme.mutedForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.background)
            }
        }
        .background(AppTheme.background)
    }

    private func playbackContent(image: UIImage, size: CGSize) -> some View {
        let width = max(size.width, 1)
        let imageHeight = width * max(image.size.height, 1) / max(image.size.width, 1)
        let fitted = CGRect(x: 0, y: 0, width: width, height: imageHeight)

        return ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: width, height: imageHeight)

                    KindleProbeNativePlaybackOverlay(
                        document: document,
                        fitted: fitted,
                        paragraphIndex: paragraphIndex,
                        wordIndex: wordIndex,
                        marks: marks
                    )

                    ForEach(document.paragraphs.filter { $0.type.isReadable }) { para in
                        if let bbox = para.bboxNorm {
                            let rect = ReadingGeometry.displayRect(forNorm: bbox, in: fitted)
                            Color.clear
                                .frame(width: 1, height: 1)
                                .position(x: width / 2, y: rect.midY)
                                .id(Self.anchorID(para.id))
                        }
                    }
                }
                .frame(width: width, height: imageHeight)
            }
            .background(Color.white)
            .onAppear {
                scrollToCurrentParagraph(proxy)
            }
            .onChange(of: paragraphIndex) { _ in
                scrollToCurrentParagraph(proxy)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    Text(pageKey.prefix(8))
                        .font(.caption2.monospaced().weight(.semibold))
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                .foregroundColor(AppTheme.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(8)
            }
        }
    }

    private func scrollToCurrentParagraph(_ proxy: ScrollViewProxy) {
        guard paragraphIndex >= 0 else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(Self.anchorID(paragraphIndex), anchor: UnitPoint(x: 0.5, y: 0.32))
        }
    }

    private static func anchorID(_ paragraphID: Int) -> String {
        "kindle-native-para-\(paragraphID)"
    }
}

private struct KindleProbeNativePlaybackOverlay: View {
    let document: ReadingDocument
    let fitted: CGRect
    let paragraphIndex: Int
    let wordIndex: Int?
    let marks: [KindleProbeNativeMark]

    var body: some View {
        let resolver = PhotoAnchorResolver(document: document, fitted: fitted)
        ZStack(alignment: .topLeading) {
            if paragraphIndex >= 0,
               paragraphIndex < document.paragraphs.count,
               let bbox = document.paragraphs[paragraphIndex].bboxNorm {
                let rect = ReadingGeometry.displayRect(forNorm: bbox, in: fitted)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.orange.opacity(0.32), lineWidth: 2)
                    .frame(width: rect.width + 8, height: rect.height + 8)
                    .position(x: rect.midX, y: rect.midY)
            }

            if let wordIndex, paragraphIndex >= 0 {
                let rects = resolver.rectsForWord(paragraphIndex: paragraphIndex, wordIndex: wordIndex)
                ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.orange.opacity(0.42))
                        .frame(width: rect.width + 5, height: rect.height + 3)
                        .position(x: rect.midX, y: rect.midY)
                }
            }

            ForEach(marks) { mark in
                let rects = mark.rectsNorm.map { ReadingGeometry.displayRect(forNorm: $0, in: fitted) }
                if !rects.isEmpty {
                    MarkInkView(
                        rects: rects,
                        action: mark.action,
                        seed: mark.seed,
                        n: mark.n,
                        weight: mark.weight
                    )
                }
            }
        }
        .frame(width: fitted.width, height: fitted.height)
    }
}

private struct KindleProbeNativeMark: Identifiable, Equatable {
    let id: String
    let paragraphIndex: Int
    let rectsNorm: [CGRect]
    let action: String
    let n: Int?
    let weight: String?
    let seed: UInt64
}

private struct KindlePipelineIssue: Identifiable, Equatable {
    enum Kind: String {
        case waitingForMorePages
        case sourceNotReady
        case pageFailed
        case ended
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    let canRetry: Bool

    var icon: String {
        switch kind {
        case .waitingForMorePages: return "arrow.down.doc"
        case .sourceNotReady: return "rectangle.connected.to.line.below"
        case .pageFailed: return "exclamationmark.triangle"
        case .ended: return "checkmark.circle"
        }
    }
}

private enum KindlePipelineMode: String {
    case read
    case explain
}

private struct KindleSourceDiscovery {
    let candidates: [String]
    let reason: String
    let heldKeys: Int
    let currentKey: String
    let bestKey: String
    let recentKeys: String
}

@MainActor
private final class KindleBackgroundProbeModel: NSObject, ObservableObject {
    @Published var urlString = "https://read.amazon.com/kindle-library"
    @Published var loadToken = 0
    @Published var isRunning = false
    @Published var logLines: [String] = []
    @Published var isPreparingDocument = false
    @Published var isPrefetching = false
    @Published var prepareStatus = ""
    @Published var cachedPages: [KindleCachedPage] = []
    @Published var isContinuousReading = false
    @Published var isContinuousExplaining = false
    @Published var continuousStatus = ""
    @Published var nativePlaybackDocument: ReadingDocument?
    @Published var nativePlaybackPageKey = ""
    @Published var nativePlaybackParagraphIndex = -1
    @Published var nativePlaybackWordIndex: Int?
    @Published var nativePlaybackMarks: [KindleProbeNativeMark] = []
    @Published var continuousIssue: KindlePipelineIssue?

    weak var webView: WKWebView?

    private let audio = AudioPlayerService.shared
    private let settings = AppSettings.shared
    private var timer: DispatchSourceTimer?
    private var audioPlayer: AVAudioPlayer?
    private var continuousTask: Task<Void, Never>?
    private var continuousCancellables = Set<AnyCancellable>()
    private var continuousReadRunID = UUID()
    private var continuousReadPrefetchTask: Task<Void, Never>?
    private var continuousPendingReadPrefetch: (pageKey: String, runID: UUID)?
    private var continuousReadPageKeys = Set<String>()
    private var continuousLastReadSourceReason = ""
    private var activeContinuousPage: CapturedPage?
    private var continuousPreparedPages: [String: CapturedPage] = [:]
    private var continuousPreparingPageKeys = Set<String>()
    private var continuousSegmentPageKeys: [String: String] = [:]
    private var continuousSegmentsByPageParagraph: [String: [Int: [AudioSegment]]] = [:]
    private var continuousAlignCache: [String: [Int?]] = [:]
    private var continuousVisualKeysByPageKey: [String: String] = [:]
    private var continuousVisualSeekInFlight = Set<String>()
    private var continuousPlayingPageKey = ""
    private var continuousLastParagraphKey = ""
    private var continuousLastWordKey = ""
    private var continuousLastWordIndexByParagraph: [String: Int] = [:]
    private var continuousLastHighlightMismatch = ""
    private var continuousExplainBlocks: [Int: KindleExplainBlock] = [:]
    private var continuousFiredMarkKeys = Set<String>()
    private var continuousExplainPrevSummary: String?
    private var continuousExplainNextAudioIndex = 0
    private var continuousExplainRunID = UUID()
    private var continuousPrefetchTask: Task<Void, Never>?
    private var continuousPendingPrefetch: (pageKey: String, runID: UUID)?
    private var continuousExplainedPageKeys = Set<String>()
    private var continuousLastExplainSourceReason = ""
    private let continuousReadPrefetchTarget = 2
    private let continuousExplainPrefetchTarget = 3
    private var nativeTicks = 0
    private var capturedImageKeys = Set<String>()
    private var imageCaptureInFlight = Set<String>()

    static let messageHandler = "kindleProbe"

    struct KindleCachedPage: Identifiable, Equatable {
        let id: String
        let key: String
        let title: String
        let paragraphCount: Int
        let charCount: Int
        let capturedAt: Date
        let document: ReadingDocument
    }

    private struct CapturedPage {
        let key: String
        let title: String
        let document: ReadingDocument
    }

    private struct KindleExplainBlock {
        let pageKey: String
        let pageTitle: String
        let index: Int
        let audioIndex: Int
        let segments: [AudioSegment]
        let marks: [KindleExplainMark]
        let duration: Double
    }

    private struct KindleExplainMark {
        let event: QuickreadEvent
        let paragraphIndex: Int
        let rects: [CGRect]
        let seed: UInt64
    }

    private struct KindleResolvedMark {
        let paragraphIndex: Int
        let rects: [CGRect]
    }

    enum CaptureError: LocalizedError {
        case webViewMissing
        case invalidPayload
        case noImage(String)
        case badImageData

        var errorDescription: String? {
            switch self {
            case .webViewMissing: return AppLocalized("Kindle 页面还没有准备好")
            case .invalidPayload: return AppLocalized("无法读取 Kindle 当前页")
            case .noImage(let reason): return String(format: AppLocalized("未找到 Kindle 页面图片：%@"), reason)
            case .badImageData: return AppLocalized("无法解析 Kindle 页面图片")
            }
        }
    }

    static let bootstrapScript = """
    (function() {
      if (window.__crBgProbeInstalled) return;
      window.__crBgProbeInstalled = true;
      window.__crBgProbe = { jsTicks: 0, nativeTicks: 0, lastTarget: '', running: false, timer: null };
      window.__crBgProbe.softScrollBlockedUntil = window.__crBgProbe.softScrollBlockedUntil || {};
      window.__crBgImageProbe = window.__crBgImageProbe || {
        installed: false,
        idx: 0,
        urlToKey: new Map(),
        keyToLiveUrl: new Map(),
        keyToLiveImg: new Map()
      };
      function installImageProbe() {
        if (window.__crBgImageProbe.installed) return;
        window.__crBgImageProbe.installed = true;
        var originalCreate = URL.createObjectURL.bind(URL);
        var originalRevoke = URL.revokeObjectURL.bind(URL);
        function evictIfNeeded() {
          while (window.__crBgImageProbe.keyToLiveUrl.size > 24) {
            var oldest = window.__crBgImageProbe.keyToLiveUrl.keys().next().value;
            if (!oldest) break;
            var liveUrl = window.__crBgImageProbe.keyToLiveUrl.get(oldest);
            window.__crBgImageProbe.keyToLiveUrl.delete(oldest);
            window.__crBgImageProbe.keyToLiveImg.delete(oldest);
            for (var pair of Array.from(window.__crBgImageProbe.urlToKey.entries())) {
              if (pair[1] === oldest) window.__crBgImageProbe.urlToKey.delete(pair[0]);
            }
            try { if (liveUrl) originalRevoke(liveUrl); } catch (e) {}
          }
        }
        function writeImageState() {
          try {
            var urls = {};
            window.__crBgImageProbe.urlToKey.forEach(function(key, url) { urls[url] = key; });
            var pairs = [];
            window.__crBgImageProbe.keyToLiveUrl.forEach(function(url, key) { pairs.push([key, url]); });
            document.documentElement.setAttribute('data-cr-kindle-blob-keys', JSON.stringify(urls));
            document.documentElement.setAttribute('data-cr-kindle-blob-live-urls', JSON.stringify(pairs));
          } catch (e) {}
        }
        async function contentKey(blob) {
          var size = blob.size || 0;
          var head = await blob.slice(0, 256).arrayBuffer();
          var buf = new ArrayBuffer(8 + head.byteLength);
          var view = new DataView(buf);
          view.setUint32(0, Math.floor(size / 0x100000000), false);
          view.setUint32(4, size >>> 0, false);
          new Uint8Array(buf, 8).set(new Uint8Array(head));
          var digest = await crypto.subtle.digest('SHA-256', buf);
          var bytes = new Uint8Array(digest);
          var hex = '';
          for (var i = 0; i < 8; i++) hex += bytes[i].toString(16).padStart(2, '0');
          return hex;
        }
        URL.createObjectURL = function(obj) {
          var url = originalCreate(obj);
          try {
            if (obj instanceof Blob && obj.type && obj.type.indexOf('image/') === 0) {
              var idx = window.__crBgImageProbe.idx++;
              contentKey(obj).then(function(key) {
                window.__crBgImageProbe.urlToKey.set(url, key);
                if (!window.__crBgImageProbe.keyToLiveUrl.has(key)) {
                  var liveUrl = originalCreate(obj);
                  window.__crBgImageProbe.keyToLiveUrl.set(key, liveUrl);
                  var liveImg = new Image();
                  liveImg.src = liveUrl;
                  window.__crBgImageProbe.keyToLiveImg.set(key, liveImg);
                } else {
                  var existing = window.__crBgImageProbe.keyToLiveUrl.get(key);
                  window.__crBgImageProbe.keyToLiveUrl.delete(key);
                  window.__crBgImageProbe.keyToLiveUrl.set(key, existing);
                  var existingImg = window.__crBgImageProbe.keyToLiveImg.get(key);
                  if (existingImg) {
                    window.__crBgImageProbe.keyToLiveImg.delete(key);
                    window.__crBgImageProbe.keyToLiveImg.set(key, existingImg);
                  }
                }
                evictIfNeeded();
                writeImageState();
                try {
                  window.webkit.messageHandlers.\(messageHandler).postMessage(JSON.stringify({
                    kind: 'imageBlob',
                    idx: idx,
                    key: key,
                    size: obj.size || 0,
                    type: obj.type || '',
                    heldKeys: window.__crBgImageProbe.keyToLiveUrl.size,
                    url: location.href
                  }));
                } catch (e) {}
              }).catch(function() {});
            }
          } catch (e) {}
          return url;
        };
        window.__crBgProbeOriginalCreateObjectURL = originalCreate;
      }
      installImageProbe();
      function allProbeWindows() {
        var wins = [];
        function add(win, depth) {
          if (!win || depth > 5 || wins.indexOf(win) >= 0) return;
          wins.push(win);
          try {
            for (var i = 0; i < win.frames.length; i++) add(win.frames[i], depth + 1);
          } catch (e) {}
        }
        add(window, 0);
        return wins;
      }
      function probeForWindow(win) {
        try { return win && win.__crBgImageProbe ? win.__crBgImageProbe : null; } catch (e) { return null; }
      }
      function probeForImage(img) {
        try {
          var win = img && img.ownerDocument ? img.ownerDocument.defaultView : window;
          return probeForWindow(win) || probeForWindow(window);
        } catch (e) {
          return probeForWindow(window);
        }
      }
      function keyForImage(img) {
        try {
          var probe = probeForImage(img);
          return probe && probe.urlToKey ? (probe.urlToKey.get(img.src) || '') : '';
        } catch (e) { return ''; }
      }
      function keyForBlobUrl(url, preferredWin) {
        if (!url) return '';
        var wins = preferredWin ? [preferredWin].concat(allProbeWindows()) : allProbeWindows();
        for (var i = 0; i < wins.length; i++) {
          try {
            var probe = probeForWindow(wins[i]);
            var key = probe && probe.urlToKey ? (probe.urlToKey.get(url) || '') : '';
            if (key) return key;
          } catch (e) {}
        }
        return '';
      }
      function probeForBlobUrl(url, preferredWin) {
        var key = keyForBlobUrl(url, preferredWin);
        var wins = preferredWin ? [preferredWin].concat(allProbeWindows()) : allProbeWindows();
        for (var i = 0; i < wins.length; i++) {
          try {
            var probe = probeForWindow(wins[i]);
            if (!probe) continue;
            if (key && probe.keyToLiveUrl && probe.keyToLiveUrl.has(key)) return probe;
            if (probe.urlToKey && probe.urlToKey.has(url)) return probe;
          } catch (e) {}
        }
        return probeForWindow(preferredWin || window);
      }
      function liveUrlForKey(probe, key, fallbackUrl) {
        try {
          if (probe && key && probe.keyToLiveUrl && probe.keyToLiveUrl.has(key)) {
            return probe.keyToLiveUrl.get(key);
          }
        } catch (e) {}
        return fallbackUrl || '';
      }
      function blobUrlFromBackground(el) {
        try {
          var bg = getComputedStyle(el).backgroundImage || '';
          var idx = bg.indexOf('blob:');
          if (idx < 0) return '';
          var end = bg.indexOf(')', idx);
          if (end < 0) end = bg.length;
          return bg.slice(idx, end).trim().replace(/^["']|["']$/g, '');
        } catch (e) {
          return '';
        }
      }
      function heldKeyCount() {
        var total = 0;
        var wins = allProbeWindows();
        for (var i = 0; i < wins.length; i++) {
          var probe = probeForWindow(wins[i]);
          if (probe && probe.keyToLiveUrl) total += probe.keyToLiveUrl.size || 0;
        }
        return total;
      }
      function recentKeys(maxCount) {
        var keys = [];
        var wins = allProbeWindows();
        for (var i = 0; i < wins.length; i++) {
          var probe = probeForWindow(wins[i]);
          if (!probe || !probe.keyToLiveUrl) continue;
          try {
            keys = keys.concat(Array.from(probe.keyToLiveUrl.keys()));
          } catch (e) {}
        }
        return keys.slice(-maxCount);
      }
      function frameOffsetForDocument(doc) {
        var x = 0, y = 0;
        try {
          var win = doc && doc.defaultView ? doc.defaultView : null;
          while (win && win !== window) {
            var frame = win.frameElement;
            if (!frame) break;
            var r = frame.getBoundingClientRect();
            x += r.left || 0;
            y += r.top || 0;
            win = win.parent;
          }
        } catch (e) {}
        return { x: x, y: y };
      }
      function rectInTopViewport(el) {
        try {
          var r = el.getBoundingClientRect();
          var off = frameOffsetForDocument(el.ownerDocument || document);
          return {
            left: (r.left || 0) + off.x,
            top: (r.top || 0) + off.y,
            right: (r.right || 0) + off.x,
            bottom: (r.bottom || 0) + off.y,
            width: r.width || 0,
            height: r.height || 0
          };
        } catch (e) {
          return { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
        }
      }
      function ensureLiveImage(probe, key, liveUrl) {
        if (!probe || !key || !liveUrl) return null;
        try {
          var img = probe.keyToLiveImg ? probe.keyToLiveImg.get(key) : null;
          if (!img || img.src !== liveUrl) {
            img = new Image();
            try { img.decoding = 'async'; } catch (e) {}
            img.src = liveUrl;
            if (probe.keyToLiveImg) probe.keyToLiveImg.set(key, img);
          }
          return img;
        } catch (e) { return null; }
      }
      function ensureImageForBlobUrl(url, key, preferredWin) {
        if (!url && !key) return null;
        var probe = probeForBlobUrl(url, preferredWin);
        var resolvedKey = key || keyForBlobUrl(url, preferredWin);
        var liveUrl = liveUrlForKey(probe, resolvedKey, url);
        if (resolvedKey) return ensureLiveImage(probe, resolvedKey, liveUrl);
        try {
          var img = new Image();
          try { img.decoding = 'async'; } catch (e) {}
          img.src = liveUrl;
          return img;
        } catch (e) {
          return null;
        }
      }
      function visibleArea(el) {
        try {
          var r = rectInTopViewport(el);
          var w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
          var h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
          return w * h;
        } catch (e) { return 0; }
      }
      function labelFor(el) {
        if (!el) return 'null';
        if (el === document.scrollingElement) return 'document.scrollingElement';
        var id = el.id ? '#' + el.id : '';
        var cls = '';
        try {
          cls = typeof el.className === 'string'
            ? '.' + el.className.trim().replace(/\\s+/g, '.').slice(0, 80)
            : '';
        } catch (e) {}
        return (el.tagName || 'node').toLowerCase() + id + cls;
      }
      function pushCandidate(list, el, prefix) {
        if (!el) return;
        try {
          var ch = el.clientHeight || 0;
          var sh = el.scrollHeight || 0;
          var delta = sh - ch;
          if (delta < 30) return;
          var area = visibleArea(el);
          var st = getComputedStyle(el);
          var overflowHint = /(auto|scroll|overlay)/.test((st.overflowY || '') + (st.overflow || ''));
          var score = delta + area / 1000 + (overflowHint ? 5000 : 0);
          list.push({ el: el, score: score, label: (prefix || '') + labelFor(el), delta: delta, area: Math.round(area) });
        } catch (e) {}
      }
      function collectFromRoot(root, list, prefix, depth) {
        if (!root || depth > 4) return;
        var doc = root.nodeType === 9 ? root : null;
        if (doc) {
          pushCandidate(list, doc.scrollingElement, prefix || '');
          pushCandidate(list, doc.body, prefix || '');
        }
        var all = [];
        try { all = Array.from((doc || root).querySelectorAll('*')); } catch (e) { all = []; }
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          pushCandidate(list, el, prefix || '');
          if (el.shadowRoot) collectFromRoot(el.shadowRoot, list, (prefix || '') + labelFor(el) + '::shadow ', depth + 1);
          if (el.tagName === 'IFRAME') {
            try {
              if (el.contentDocument) collectFromRoot(el.contentDocument, list, (prefix || '') + 'iframe ', depth + 1);
            } catch (e) {}
          }
        }
      }
      function findScrollTarget() {
        var list = [];
        collectFromRoot(document, list, '', 0);
        list.sort(function(a, b) { return b.score - a.score; });
        return list[0] || { el: document.scrollingElement || document.documentElement || document.body, label: 'fallback', delta: 0, area: 0 };
      }
      function readTargetState(t) {
        var el = t && t.el ? t.el : (document.scrollingElement || document.documentElement || document.body);
        return {
          y: Math.round(el ? el.scrollTop || 0 : window.scrollY || 0),
          h: Math.round(el ? el.scrollHeight || 0 : document.documentElement.scrollHeight || 0),
          ch: Math.round(el ? el.clientHeight || 0 : innerHeight || 0),
          target: t ? t.label : 'unknown',
          delta: t ? Math.round(t.delta || 0) : 0,
          area: t ? Math.round(t.area || 0) : 0
        };
      }
      function collectBlobImages(root, out, depth) {
        if (!root || depth > 5) return;
        var doc = root.nodeType === 9 ? root : null;
        var scope = doc || root;
        try {
          Array.from(scope.querySelectorAll('img')).forEach(function(img) {
            if (img && img.src && img.src.indexOf('blob:') === 0) out.push(img);
          });
        } catch (e) {}
        var all = [];
        try { all = Array.from(scope.querySelectorAll('*')); } catch (e) { all = []; }
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (el.shadowRoot) collectBlobImages(el.shadowRoot, out, depth + 1);
          if (el.tagName === 'IFRAME') {
            try {
              if (el.contentDocument) collectBlobImages(el.contentDocument, out, depth + 1);
            } catch (e) {}
          }
        }
      }
      function allBlobImages() {
        var imgs = [];
        collectBlobImages(document, imgs, 0);
        var seen = new Set();
        return imgs.filter(function(img) {
          if (!img || seen.has(img)) return false;
          seen.add(img);
          return true;
        });
      }
      function collectBlobBackgrounds(root, out, depth) {
        if (!root || depth > 5) return;
        var doc = root.nodeType === 9 ? root : null;
        var scope = doc || root;
        var all = [];
        try { all = Array.from(scope.querySelectorAll('*')); } catch (e) { all = []; }
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          var url = blobUrlFromBackground(el);
          if (url) out.push({ el: el, url: url });
          if (el.shadowRoot) collectBlobBackgrounds(el.shadowRoot, out, depth + 1);
          if (el.tagName === 'IFRAME') {
            try {
              if (el.contentDocument) collectBlobBackgrounds(el.contentDocument, out, depth + 1);
            } catch (e) {}
          }
        }
      }
      function allBlobBackgrounds() {
        var items = [];
        collectBlobBackgrounds(document, items, 0);
        var seen = new Set();
        return items.filter(function(item) {
          if (!item || !item.el || !item.url) return false;
          var token = item.url + '@' + Math.round(rectInTopViewport(item.el).left) + ',' + Math.round(rectInTopViewport(item.el).top);
          if (seen.has(token)) return false;
          seen.add(token);
          return true;
        });
      }
      function blobCandidateFromImage(img) {
        if (!img || !img.complete || !(img.naturalWidth > 0)) return null;
        var rect = rectInTopViewport(img);
        var visW = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
        var visH = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
        var visible = Math.round(visW * visH);
        return {
          kind: 'dom-img',
          el: img,
          img: img,
          key: keyForImage(img),
          rect: rect,
          nw: img.naturalWidth || 0,
          nh: img.naturalHeight || 0,
          visible: visible
        };
      }
      function backgroundImageRect(el, img) {
        var r = rectInTopViewport(el);
        var nw = img && img.naturalWidth ? img.naturalWidth : 0;
        var nh = img && img.naturalHeight ? img.naturalHeight : 0;
        if (!(nw > 0 && nh > 0 && r.width > 0 && r.height > 0)) return r;
        try {
          var st = getComputedStyle(el);
          var size = st.backgroundSize || '';
          if (size.indexOf('contain') >= 0) {
            var scale = Math.min(r.width / nw, r.height / nh);
            var w = nw * scale;
            var h = nh * scale;
            return { left: r.left + (r.width - w) / 2, top: r.top + (r.height - h) / 2, right: r.left + (r.width + w) / 2, bottom: r.top + (r.height + h) / 2, width: w, height: h };
          }
          if (size.indexOf('cover') >= 0) {
            var coverScale = Math.max(r.width / nw, r.height / nh);
            var cw = nw * coverScale;
            var ch = nh * coverScale;
            return { left: r.left + (r.width - cw) / 2, top: r.top + (r.height - ch) / 2, right: r.left + (r.width + cw) / 2, bottom: r.top + (r.height + ch) / 2, width: cw, height: ch };
          }
        } catch (e) {}
        return r;
      }
      function blobCandidateFromBackground(item) {
        if (!item || !item.el || !item.url) return null;
        var preferredWin = null;
        try { preferredWin = item.el.ownerDocument.defaultView; } catch (e) {}
        var key = keyForBlobUrl(item.url, preferredWin);
        var img = ensureImageForBlobUrl(item.url, key, preferredWin);
        if (!img || !img.complete || !(img.naturalWidth > 0)) return null;
        var rect = backgroundImageRect(item.el, img);
        var visW = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
        var visH = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
        var visible = Math.round(visW * visH);
        return {
          kind: 'bg-blob',
          el: item.el,
          img: img,
          key: key,
          rect: rect,
          nw: img.naturalWidth || 0,
          nh: img.naturalHeight || 0,
          visible: visible
        };
      }
      function allBlobCandidates() {
        var candidates = [];
        var imgs = allBlobImages();
        for (var i = 0; i < imgs.length; i++) {
          var imgCand = blobCandidateFromImage(imgs[i]);
          if (imgCand) candidates.push(imgCand);
        }
        var bgs = allBlobBackgrounds();
        for (var j = 0; j < bgs.length; j++) {
          var bgCand = blobCandidateFromBackground(bgs[j]);
          if (bgCand) candidates.push(bgCand);
        }
        return candidates;
      }
      function bestKindleBlobCandidate() {
        var candidates = allBlobCandidates();
        var best = null;
        var bestScore = -1;
        for (var i = 0; i < candidates.length; i++) {
          var c = candidates[i];
          var area = (c.nw || 0) * (c.nh || 0);
          var score = (c.visible || 0) > 0 ? (c.visible + 100000000) : area;
          if (score > bestScore) { bestScore = score; best = c; }
        }
        return best;
      }
      function blobCandidateForKey(key) {
        key = String(key || '');
        if (!key) return null;
        var candidates = allBlobCandidates();
        for (var i = 0; i < candidates.length; i++) {
          if (String(candidates[i].key || '') === key) return candidates[i];
        }
        return null;
      }
      function scrollBlobCandidateIntoView(candidate) {
        if (!candidate || !candidate.el) return false;
        var el = candidate.el;
        try {
          if (el.scrollIntoView) {
            el.scrollIntoView({ block: 'center', inline: 'nearest' });
          }
        } catch (e) {
          try { el.scrollIntoView(false); } catch (_) {}
        }
        try {
          var r = rectInTopViewport(el);
          var center = (r.top + r.bottom) * 0.5;
          var target = innerHeight * 0.38;
          var delta = center - target;
          if (Math.abs(delta) > 24) {
            var list = [];
            collectFromRoot(el.ownerDocument || document, list, '', 0);
            list.sort(function(a, b) { return b.score - a.score; });
            for (var i = 0; i < Math.min(list.length, 8); i++) {
              var se = list[i].el;
              try {
                se.scrollTop = (se.scrollTop || 0) + delta;
                if (se.scrollBy) se.scrollBy(0, delta);
              } catch (e) {}
            }
            try { window.scrollBy(0, delta); } catch (e) {}
          }
        } catch (e) {}
        return true;
      }
      function imageProbeState() {
        var imgs = allBlobImages();
        var bgs = allBlobBackgrounds();
        var candidates = allBlobCandidates();
        var best = bestKindleBlobCandidate();
        var loaded = candidates.length;
        var rows = [];
        for (var i = 0; i < candidates.length; i++) {
          var c = candidates[i];
          rows.push(c.kind + ':' + (c.key ? c.key.slice(0, 8) : '?') + ':' + c.nw + 'x' + c.nh + ':v' + c.visible);
        }
        var recent = recentKeys(5);
        return {
          blobImgs: imgs.length + bgs.length,
          blobLoaded: loaded,
          heldKeys: heldKeyCount(),
          recentKeys: recent.map(function(k) { return String(k).slice(0, 8); }).join(','),
          bestKey: best && best.key ? best.key : '',
          bestNat: best ? (best.nw + 'x' + best.nh) : '',
          bestBox: best ? (Math.round(best.rect.width) + 'x' + Math.round(best.rect.height) + '@' + Math.round(best.rect.left) + ',' + Math.round(best.rect.top)) : '',
          bestVisible: best ? best.visible : 0,
          imgRows: rows.slice(0, 5).join('|')
        };
      }
      function bestKindleBlobImage() {
        var candidate = bestKindleBlobCandidate();
        return candidate ? candidate.img : null;
      }
      function newestLiveBlobPair() {
        var wins = allProbeWindows();
        for (var i = wins.length - 1; i >= 0; i--) {
          try {
            var probe = probeForWindow(wins[i]);
            var pairs = probe && probe.keyToLiveUrl ? Array.from(probe.keyToLiveUrl.entries()) : [];
            if (pairs.length > 0) return { key: pairs[pairs.length - 1][0], url: pairs[pairs.length - 1][1], probe: probe };
          } catch (e) {}
        }
        var docs = [document];
        try {
          for (var f = 0; f < window.frames.length; f++) {
            if (window.frames[f].document) docs.push(window.frames[f].document);
          }
        } catch (e) {}
        for (var d = docs.length - 1; d >= 0; d--) {
          try {
            var raw = docs[d].documentElement.getAttribute('data-cr-kindle-blob-live-urls') ||
                      docs[d].documentElement.getAttribute('data-castreader-kindle-blob-live-urls');
            var attrPairs = raw ? JSON.parse(raw) : [];
            if (Array.isArray(attrPairs) && attrPairs.length > 0) {
              var pair = attrPairs[attrPairs.length - 1];
              return { key: pair[0], url: pair[1], probe: probeForWindow(docs[d].defaultView) || probeForWindow(window) };
            }
          } catch (e) {}
        }
        return null;
      }
      function newestLoadedLiveBlobImage() {
        var wins = allProbeWindows();
        for (var w = wins.length - 1; w >= 0; w--) {
          try {
            var probe = probeForWindow(wins[w]);
            var pairs = probe && probe.keyToLiveUrl ? Array.from(probe.keyToLiveUrl.entries()) : [];
            for (var i = pairs.length - 1; i >= 0; i--) {
              var key = pairs[i][0];
              var liveUrl = pairs[i][1];
              var img = ensureLiveImage(probe, key, liveUrl);
              if (img && img.complete && img.naturalWidth > 0) return { key: key, img: img };
            }
          } catch (e) {}
        }
        var pair = newestLiveBlobPair();
        if (pair && pair.key && pair.url) {
          var fallbackImg = ensureLiveImage(pair.probe || probeForWindow(window), pair.key, pair.url);
          if (fallbackImg && fallbackImg.complete && fallbackImg.naturalWidth > 0) {
            return { key: pair.key, img: fallbackImg };
          }
        }
        return null;
      }
      function readerFallbackRect() {
        var selectors = [
          '#kindleReader_content',
          '#kindle-reader-content',
          '.kindleReader_content',
          '.kg-fullpage',
          '.kg-book',
          '.kg-reader',
          '[class*="kg-"]'
        ];
        for (var i = 0; i < selectors.length; i++) {
          var el = null;
          try { el = document.querySelector(selectors[i]); } catch (e) {}
          if (!el) continue;
          try {
            var r = rectInTopViewport(el);
            if (r.width > innerWidth * 0.35 && r.height > innerHeight * 0.35) return r;
          } catch (e) {}
        }
        return {
          left: Math.max(0, innerWidth * 0.05),
          top: Math.max(0, innerHeight * 0.14),
          width: innerWidth * 0.9,
          height: innerHeight * 0.72,
          right: innerWidth * 0.95,
          bottom: innerHeight * 0.86
        };
      }
      function drawImageSnapshot(img, maxWidth, quality, key, source) {
        var maxW = maxWidth || 360;
        var jpegQuality = quality || 0.72;
        var nw = img.naturalWidth || img.width || 1;
        var nh = img.naturalHeight || img.height || 1;
        var scale = nw > maxW ? maxW / nw : 1;
        var canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(nw * scale));
        canvas.height = Math.max(1, Math.round(nh * scale));
        var ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
        var dataUrl = canvas.toDataURL('image/jpeg', jpegQuality);
        var titleEl = document.querySelector('#kindle-reader-title, [id*="reader-title"], [class*="reader-title"], [aria-label^="Book"]');
        var rawTitle = titleEl ? (titleEl.textContent || titleEl.getAttribute('aria-label') || '') : '';
        var title = rawTitle.trim() || document.title || 'Kindle Page';
        return {
          ok: true,
          key: key || '',
          natural: nw + 'x' + nh,
          rendered: canvas.width + 'x' + canvas.height,
          title: title,
          thumb: dataUrl,
          image: dataUrl,
          source: source || 'dom-img',
          url: location.href
        };
      }
      window.__crBgProbeImageSnapshot = function(maxWidth, quality) {
        var candidate = bestKindleBlobCandidate();
        try {
          if (candidate && candidate.img) {
            return JSON.stringify(drawImageSnapshot(candidate.img, maxWidth, quality, candidate.key || '', candidate.kind || 'dom-img'));
          }
          var live = newestLoadedLiveBlobImage();
          if (!live) {
            var pair = newestLiveBlobPair();
            var reason = pair && pair.url ? 'live-url-not-loaded' : 'no-blob-image';
            return JSON.stringify({ ok: false, reason: reason, heldKeys: heldKeyCount(), url: location.href });
          }
          return JSON.stringify(drawImageSnapshot(live.img, maxWidth, quality, live.key, 'live-url'));
        } catch (e) {
          return JSON.stringify({ ok: false, reason: String(e), url: location.href });
        }
      };
      window.__crBgProbeLiveKeys = function() {
        try {
          var keys = [];
          var seen = {};
          var wins = allProbeWindows();
          for (var w = 0; w < wins.length; w++) {
            var probe = probeForWindow(wins[w]);
            if (!probe || !probe.keyToLiveUrl) continue;
            var probeKeys = Array.from(probe.keyToLiveUrl.keys());
            for (var i = 0; i < probeKeys.length; i++) {
              var key = String(probeKeys[i] || '');
              if (!key || seen[key]) continue;
              seen[key] = true;
              keys.push(key);
            }
          }
          var candidate = bestKindleBlobCandidate();
          var im = imageProbeState();
          return JSON.stringify({
            ok: true,
            keys: keys,
            current: candidate && candidate.key ? candidate.key : '',
            heldKeys: heldKeyCount(),
            recentKeys: im.recentKeys,
            bestKey: im.bestKey,
            bestNat: im.bestNat,
            bestBox: im.bestBox,
            bestVisible: im.bestVisible,
            imgRows: im.imgRows,
            url: location.href
          });
        } catch (e) {
          return JSON.stringify({ ok: false, reason: String(e), heldKeys: heldKeyCount(), url: location.href });
        }
      };
      window.__crBgProbeFocusKey = function(key) {
        try {
          key = String(key || '');
          var before = bestKindleBlobCandidate();
          var beforeKey = before && before.key ? before.key : '';
          var candidate = blobCandidateForKey(key);
          if (!candidate) {
            var miss = state('focusKey');
            miss.ok = false;
            miss.reason = 'key-not-in-dom';
            miss.focusedKey = key;
            miss.beforeKey = beforeKey;
            miss.afterKey = beforeKey;
            return JSON.stringify(miss);
          }
          scrollBlobCandidateIntoView(candidate);
          var after = bestKindleBlobCandidate();
          var afterKey = after && after.key ? after.key : '';
          var s = state('focusKey');
          s.ok = true;
          s.reason = afterKey === key ? 'focused' : 'focused-not-best';
          s.focusedKey = key;
          s.beforeKey = beforeKey;
          s.afterKey = afterKey;
          return JSON.stringify(s);
        } catch (e) {
          return JSON.stringify({ ok: false, reason: String(e), focusedKey: String(key || ''), heldKeys: heldKeyCount(), url: location.href });
        }
      };
      window.__crBgProbeImageSnapshotForKey = function(key, maxWidth, quality) {
        try {
          key = String(key || '');
          var wins = allProbeWindows();
          for (var w = 0; w < wins.length; w++) {
            var probe = probeForWindow(wins[w]);
            if (!probe || !probe.keyToLiveUrl || !probe.keyToLiveUrl.has(key)) continue;
            var liveUrl = probe.keyToLiveUrl.get(key);
            var img = ensureLiveImage(probe, key, liveUrl);
            if (!img || !img.complete || !(img.naturalWidth > 0)) {
              return JSON.stringify({ ok: false, reason: 'live-url-not-loaded', key: key, heldKeys: heldKeyCount(), url: location.href });
            }
            return JSON.stringify(drawImageSnapshot(img, maxWidth, quality, key, 'live-key'));
          }
          return JSON.stringify({ ok: false, reason: 'key-not-held', key: key, heldKeys: heldKeyCount(), url: location.href });
        } catch (e) {
          return JSON.stringify({ ok: false, reason: String(e), key: key || '', heldKeys: heldKeyCount(), url: location.href });
        }
      };
      window.__crBgProbeShowOCRHighlight = function(rect, expectedKey) {
        var candidate = bestKindleBlobCandidate();
        if (!rect) return 'no-rect';
        expectedKey = String(expectedKey || '');
        if (expectedKey && (!candidate || !candidate.key || candidate.key !== expectedKey)) {
          var existing = document.getElementById('castreader-kindle-live-word');
          if (existing) existing.style.display = 'none';
          return 'page-mismatch:' + (candidate && candidate.key ? candidate.key : 'none');
        }
        var r = candidate ? candidate.rect : readerFallbackRect();
        var div = document.getElementById('castreader-kindle-live-word');
        if (!div) {
          div = document.createElement('div');
          div.id = 'castreader-kindle-live-word';
          div.setAttribute('data-castreader-overlay', 'kindle-live-word');
          Object.assign(div.style, {
            position: 'fixed',
            pointerEvents: 'none',
            zIndex: '2147483646',
            backgroundColor: 'rgba(253,95,1,0.36)',
            borderRadius: '3px',
            transition: 'left 0.05s, top 0.05s, width 0.05s, height 0.05s'
          });
          document.documentElement.appendChild(div);
        }
        var x = Number(rect.x || 0);
        var y = Number(rect.y || 0);
        var w = Number(rect.w || rect.width || 0);
        var h = Number(rect.h || rect.height || 0);
        window.__crBgProbe.activeHighlightExpectedKey = expectedKey;
        var left = r.left + x * r.width - 2;
        var top = r.top + (1 - y - h) * r.height - 1;
        var width = Math.max(1, w * r.width + 4);
        var height = Math.max(1, h * r.height + 2);
        Object.assign(div.style, {
          left: left + 'px',
          top: top + 'px',
          width: width + 'px',
          height: height + 'px',
          display: 'block'
        });
        return 'ok';
      };
      window.__crBgProbeClearOCRHighlight = function() {
        var div = document.getElementById('castreader-kindle-live-word');
        if (div) div.style.display = 'none';
        return 'ok';
      };
      window.__crBgProbeShowOCRMarks = function(rects) {
        var candidate = bestKindleBlobCandidate();
        if (!rects) return 'no-rects';
        var r = candidate ? candidate.rect : readerFallbackRect();
        var container = document.getElementById('castreader-kindle-live-marks');
        if (!container) {
          container = document.createElement('div');
          container.id = 'castreader-kindle-live-marks';
          container.setAttribute('data-castreader-overlay', 'kindle-live-marks');
          Object.assign(container.style, {
            position: 'fixed',
            left: '0px',
            top: '0px',
            width: '0px',
            height: '0px',
            pointerEvents: 'none',
            zIndex: '2147483645'
          });
          document.documentElement.appendChild(container);
        }
        container.textContent = '';
        for (var i = 0; i < rects.length; i++) {
          var item = rects[i] || {};
          var rect = item.rect || item;
          var x = Number(rect.x || 0);
          var y = Number(rect.y || 0);
          var w = Number(rect.w || rect.width || 0);
          var h = Number(rect.h || rect.height || 0);
          var action = String(item.action || 'underline');
          var div = document.createElement('div');
          div.setAttribute('data-castreader-mark', action);
          var common = {
            position: 'fixed',
            pointerEvents: 'none',
            left: (r.left + x * r.width - 3) + 'px',
            top: (r.top + (1 - y - h) * r.height - 2) + 'px',
            width: Math.max(2, w * r.width + 6) + 'px',
            height: Math.max(2, h * r.height + 4) + 'px',
            boxSizing: 'border-box'
          };
          Object.assign(div.style, common);
          if (action === 'circle') {
            Object.assign(div.style, {
              border: '3px solid rgba(253,95,1,0.92)',
              borderRadius: '999px',
              backgroundColor: 'rgba(253,95,1,0.04)'
            });
          } else if (action === 'highlight') {
            Object.assign(div.style, {
              backgroundColor: 'rgba(253,95,1,0.28)',
              borderRadius: '4px'
            });
          } else {
            Object.assign(div.style, {
              height: '4px',
              top: (r.top + (1 - y) * r.height - 3) + 'px',
              backgroundColor: 'rgba(253,95,1,0.95)',
              borderRadius: '999px',
              transform: 'rotate(-0.4deg)'
            });
          }
          container.appendChild(div);
        }
        return 'ok';
      };
      window.__crBgProbeClearOCRMarks = function() {
        var div = document.getElementById('castreader-kindle-live-marks');
        if (div) div.textContent = '';
        return 'ok';
      };
      function state(kind) {
        var target = findScrollTarget();
        var ts = readTargetState(target);
        var im = imageProbeState();
        window.__crBgProbe.lastTarget = ts.target;
        return {
          kind: kind,
          jsTicks: window.__crBgProbe.jsTicks,
          nativeTicks: window.__crBgProbe.nativeTicks,
          y: ts.y,
          h: ts.h,
          ch: ts.ch,
          target: ts.target,
          delta: ts.delta,
          area: ts.area,
          blobImgs: im.blobImgs,
          blobLoaded: im.blobLoaded,
          heldKeys: im.heldKeys,
          recentKeys: im.recentKeys,
          bestKey: im.bestKey,
          bestNat: im.bestNat,
          bestBox: im.bestBox,
          bestVisible: im.bestVisible,
          imgRows: im.imgRows,
          ready: document.readyState,
          url: location.href
        };
      }
      window.__crBgProbeScroll = function(delta) {
        window.__crBgProbe.nativeTicks += 1;
        var list = [];
        collectFromRoot(document, list, '', 0);
        list.sort(function(a, b) { return b.score - a.score; });
        var tried = [];
        for (var i = 0; i < Math.min(list.length, 12); i++) {
          var item = list[i];
          var se = item.el;
          try {
            var before = se.scrollTop || 0;
            se.scrollTop = before + delta;
            if (se.scrollBy) se.scrollBy(0, delta);
            tried.push(item.label + ':' + before + '>' + (se.scrollTop || 0));
          } catch (e) {
            tried.push(item.label + ':err');
          }
        }
        try { window.scrollBy(0, delta); } catch (e) {}
        try {
          var pageKey = delta >= 0 ? 'PageDown' : 'PageUp';
          document.dispatchEvent(new KeyboardEvent('keydown', { key: pageKey, code: pageKey, bubbles: true }));
          document.dispatchEvent(new KeyboardEvent('keyup', { key: pageKey, code: pageKey, bubbles: true }));
        } catch (e) {}
        try {
          var x = Math.floor(innerWidth * 0.5);
          var y1 = Math.floor(innerHeight * (delta >= 0 ? 0.72 : 0.28));
          var y2 = Math.floor(innerHeight * (delta >= 0 ? 0.28 : 0.72));
          var el = document.elementFromPoint(x, y1) || document.body;
          el.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 1, pointerType: 'touch', clientX: x, clientY: y1, bubbles: true }));
          el.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, pointerType: 'touch', clientX: x, clientY: y2, bubbles: true }));
          el.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1, pointerType: 'touch', clientX: x, clientY: y2, bubbles: true }));
          el.dispatchEvent(new WheelEvent('wheel', { deltaY: delta, bubbles: true, cancelable: true }));
        } catch (e) {}
        var s = state('nativeTick');
        s.tried = tried.slice(0, 5).join(' | ');
        return JSON.stringify(s);
      };
      window.__crBgProbeScrollSoft = function(delta, expectedKey) {
        window.__crBgProbe.nativeTicks += 1;
        expectedKey = String(expectedKey || '');
        var beforeCandidate = bestKindleBlobCandidate();
        var beforeKey = beforeCandidate && beforeCandidate.key ? beforeCandidate.key : '';
        if (expectedKey && beforeKey && beforeKey !== expectedKey) {
          return JSON.stringify({ kind: 'softScrollBlocked', ok: false, reason: 'before-mismatch', expectedKey: expectedKey, beforeKey: beforeKey, afterKey: beforeKey });
        }
        var list = [];
        collectFromRoot(document, list, '', 0);
        list.sort(function(a, b) { return b.score - a.score; });
        var tried = [];
        for (var i = 0; i < Math.min(list.length, 8); i++) {
          var item = list[i];
          var se = item.el;
          try {
            var before = se.scrollTop || 0;
            se.scrollTop = before + delta;
            if (se.scrollBy) se.scrollBy(0, delta);
            tried.push(item.label + ':' + before + '>' + (se.scrollTop || 0));
          } catch (e) {
            tried.push(item.label + ':err');
          }
        }
        try { window.scrollBy(0, delta); } catch (e) {}
        try {
          var x = Math.floor(innerWidth * 0.5), y = Math.floor(innerHeight * 0.62);
          var el = document.elementFromPoint(x, y) || document.body;
          el.dispatchEvent(new WheelEvent('wheel', { deltaY: delta, bubbles: true, cancelable: true }));
        } catch (e) {}
        var afterCandidate = bestKindleBlobCandidate();
        var afterKey = afterCandidate && afterCandidate.key ? afterCandidate.key : '';
        var reverted = false;
        function reverseSoftScroll(kind, lateKey) {
          reverted = true;
          for (var j = 0; j < Math.min(list.length, 8); j++) {
            var back = list[j].el;
            try {
              back.scrollTop = Math.max(0, (back.scrollTop || 0) - delta);
              if (back.scrollBy) back.scrollBy(0, -delta);
            } catch (e) {}
          }
          try { window.scrollBy(0, -delta); } catch (e) {}
          try {
            var bx = Math.floor(innerWidth * 0.5), by = Math.floor(innerHeight * 0.62);
            var bel = document.elementFromPoint(bx, by) || document.body;
            bel.dispatchEvent(new WheelEvent('wheel', { deltaY: -delta, bubbles: true, cancelable: true }));
          } catch (e) {}
          if (expectedKey) window.__crBgProbe.softScrollBlockedUntil[expectedKey] = Date.now() + 1800;
          if (Date.now() - (window.__crBgProbe.lastSoftScrollLogAt || 0) > 900) {
            window.__crBgProbe.lastSoftScrollLogAt = Date.now();
            try {
              window.webkit.messageHandlers.\(messageHandler).postMessage(JSON.stringify({
                kind: kind,
                ok: false,
                expectedKey: expectedKey,
                beforeKey: beforeKey,
                afterKey: lateKey || afterKey,
                reverted: true,
                delta: delta,
                reason: 'page-changed'
              }));
            } catch (e) {}
          }
        }
        if (expectedKey && afterKey && afterKey !== expectedKey) {
          reverseSoftScroll('softScrollReverted', afterKey);
        } else if (expectedKey) {
          setTimeout(function() {
            try {
              if (window.__crBgProbe.activeHighlightExpectedKey !== expectedKey) return;
              var lateCandidate = bestKindleBlobCandidate();
              var lateKey = lateCandidate && lateCandidate.key ? lateCandidate.key : '';
              if (lateKey && lateKey !== expectedKey) {
                reverseSoftScroll('softScrollLateRevert', lateKey);
              }
            } catch (e) {}
          }, 160);
        }
        var s = state('softScroll');
        s.tried = tried.slice(0, 5).join(' | ');
        s.expectedKey = expectedKey;
        s.beforeKey = beforeKey;
        s.afterKey = afterKey;
        s.reverted = reverted;
        s.delta = delta;
        return JSON.stringify(s);
      };
      window.__crBgProbeScrollOCRRectIntoComfort = function(rect, expectedKey) {
        rect = rect || {};
        expectedKey = String(expectedKey || '');
        var candidate = bestKindleBlobCandidate();
        var beforeKey = candidate && candidate.key ? candidate.key : '';
        if (expectedKey && beforeKey && beforeKey !== expectedKey) {
          return JSON.stringify({ kind: 'paragraphScroll', ok: false, reason: 'before-mismatch', expectedKey: expectedKey, beforeKey: beforeKey, afterKey: beforeKey, needed: false, delta: 0 });
        }
        if (!candidate || !candidate.rect) {
          return JSON.stringify({ kind: 'paragraphScroll', ok: false, reason: 'no-candidate', expectedKey: expectedKey, beforeKey: beforeKey, afterKey: beforeKey, needed: false, delta: 0 });
        }
        var r = candidate.rect;
        var x = Number(rect.x || 0);
        var y = Number(rect.y || 0);
        var w = Number(rect.w || rect.width || 0);
        var h = Number(rect.h || rect.height || 0);
        var top = r.top + (1 - y - h) * r.height;
        var bottom = top + h * r.height;
        var center = (top + bottom) * 0.5;
        var upper = innerHeight * 0.22;
        var lower = innerHeight * 0.70;
        var target = innerHeight * 0.34;
        var needed = top < upper || bottom > lower;
        var delta = needed ? center - target : 0;
        if (Math.abs(delta) < 18) {
          needed = false;
          delta = 0;
        }
        if (!needed) {
          return JSON.stringify({ kind: 'paragraphScroll', ok: true, reason: 'in-comfort', expectedKey: expectedKey, beforeKey: beforeKey, afterKey: beforeKey, needed: false, delta: 0, top: Math.round(top), bottom: Math.round(bottom) });
        }
        delta = Math.max(-160, Math.min(160, delta));
        var raw = window.__crBgProbeScrollSoft ? window.__crBgProbeScrollSoft(delta, expectedKey) : JSON.stringify({ ok: false, reason: 'missing-soft-scroll' });
        var result = {};
        try { result = JSON.parse(raw || '{}'); } catch (e) { result = { ok: false, reason: 'bad-soft-scroll-result' }; }
        result.kind = 'paragraphScroll';
        result.expectedKey = expectedKey;
        result.beforeKey = beforeKey;
        result.needed = true;
        result.delta = delta;
        result.top = Math.round(top);
        result.bottom = Math.round(bottom);
        result.target = Math.round(target);
        return JSON.stringify(result);
      };
      window.__crBgProbeStart = function() {
        if (window.__crBgProbe.timer) clearInterval(window.__crBgProbe.timer);
        window.__crBgProbe.running = true;
        window.__crBgProbe.timer = setInterval(function() {
          if (!window.__crBgProbe.running) return;
          window.__crBgProbe.jsTicks += 1;
          try { window.__crBgProbeScroll(70); } catch (e) {}
          try {
            window.webkit.messageHandlers.\(messageHandler).postMessage(JSON.stringify(state('jsTick')));
          } catch (e) {}
        }, 1000);
        try {
          window.webkit.messageHandlers.\(messageHandler).postMessage(JSON.stringify(state('started')));
        } catch (e) {}
      };
      window.__crBgProbeStop = function() {
        window.__crBgProbe.running = false;
        if (window.__crBgProbe.timer) clearInterval(window.__crBgProbe.timer);
        window.__crBgProbe.timer = null;
        try {
          window.webkit.messageHandlers.\(messageHandler).postMessage(JSON.stringify(state('stopped')));
        } catch (e) {}
      };
      window.__crBgProbeState = function() {
        return JSON.stringify(state('state'));
      };
      /*
      setInterval(function() {
        window.__crBgProbe.jsTicks += 1;
        try { window.__crBgProbeScroll(70); } catch (e) {}
        try {
          window.webkit.messageHandlers.\(messageHandler).postMessage(JSON.stringify(state('jsTick')));
        } catch (e) {}
      }, 1000);
      */
    })();
    """

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func load() {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        urlString = raw
        loadToken += 1
        appendLog("load \(raw)")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        nativeTicks = 0
        capturedImageKeys.removeAll()
        imageCaptureInFlight.removeAll()
        resetLogFile()
        appendLog("probe START, appState=\(appStateText), file=\(logFileURL.path)")
        startAudioLoop()
        startProbeScript()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in
            self?.nativeTick()
        }
        t.resume()
        timer = t
    }

    func stop() {
        if isContinuousReading {
            stopContinuousRead()
        }
        if isContinuousExplaining {
            stopContinuousExplain()
        }
        guard isRunning || timer != nil || audioPlayer != nil else { return }
        appendLog("probe STOP")
        isRunning = false
        timer?.cancel()
        timer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        webView?.evaluateJavaScript("window.__crBgProbeStop && window.__crBgProbeStop()")
    }

    func captureCurrentPageDocument() async throws -> ReadingDocument {
        try await captureCurrentPage(shouldCache: true).document
    }

    func ensureCurrentPageCached() async throws {
        let key = try await currentBestKey()
        if key.isEmpty || !cachedPages.contains(where: { $0.key == key }) {
            _ = try await captureCurrentPage(shouldCache: true)
        }
    }

    func makeCachedKindleDocument() -> ReadingDocument? {
        let pages = cachedPages
        guard !pages.isEmpty else { return nil }
        var paras: [ReadingParagraph] = []
        var nextID = 0
        for (pageIndex, page) in pages.enumerated() {
            if let imageData = page.document.imageData {
                paras.append(ReadingParagraph(
                    id: nextID,
                    text: "",
                    type: .image,
                    pageIndex: pageIndex,
                    imageData: imageData
                ))
                nextID += 1
            }
            for para in page.document.paragraphs where para.type.isReadable && SpeechTextSanitizer.containsSpeakableContent(para.text) {
                paras.append(ReadingParagraph(
                    id: nextID,
                    text: para.text,
                    type: para.type,
                    words: para.words,
                    bboxNorm: para.bboxNorm,
                    pageIndex: pageIndex
                ))
                nextID += 1
            }
        }
        guard paras.contains(where: { $0.type.isReadable && SpeechTextSanitizer.containsSpeakableContent($0.text) }) else {
            return nil
        }
        let title = pages.first?.title.replacingOccurrences(of: " · \(pages.first?.key.prefix(8) ?? "")", with: "") ?? "Kindle"
        var doc = ReadingDocument(
            title: "\(title) · Kindle",
            sourceKind: .kindle,
            language: pages.first?.document.language ?? Constants.TTS.defaultLanguage,
            paragraphs: paras,
            sourceURL: urlString
        )
        doc.createdAt = Date()
        appendLog("KINDLE document pages=\(pages.count) paras=\(paras.count) chars=\(doc.fullText.count)")
        return doc
    }

    @discardableResult
    private func captureCurrentPage(shouldCache: Bool) async throws -> CapturedPage {
        guard !isPreparingDocument else { throw CaptureError.invalidPayload }
        isPreparingDocument = true
        prepareStatus = AppLocalized("Capturing Kindle page...")
        defer {
            isPreparingDocument = false
            prepareStatus = ""
        }

        installProbeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let payload = try await waitForCurrentImagePayload(maxWidth: 1200, quality: 0.9)
        guard payload["ok"] as? Bool == true else {
            throw CaptureError.noImage(payload["reason"] as? String ?? "?")
        }
        return try await makeCapturedPage(from: payload, shouldCache: shouldCache, logPrefix: "KINDLE capture")
    }

    private func captureLivePage(key: String, shouldCache: Bool) async throws -> CapturedPage {
        let payload = try await waitForImagePayload(key: key, maxWidth: 1200, quality: 0.9)
        guard payload["ok"] as? Bool == true else {
            throw CaptureError.noImage(payload["reason"] as? String ?? "?")
        }
        return try await makeCapturedPage(from: payload, shouldCache: shouldCache, logPrefix: "KINDLE live capture")
    }

    private func captureVisiblePageForMatch() async throws -> CapturedPage {
        let payload = try await waitForCurrentImagePayload(maxWidth: 900, quality: 0.82, timeoutMs: 1800)
        guard payload["ok"] as? Bool == true else {
            throw CaptureError.noImage(payload["reason"] as? String ?? "?")
        }
        let source = payload["source"] as? String ?? ""
        guard source != "live-url" else {
            throw CaptureError.noImage("no-visible-kindle-image")
        }
        return try await makeCapturedPage(from: payload, shouldCache: false, logPrefix: "KINDLE visual capture")
    }

    private func makeCapturedPage(from payload: [String: Any], shouldCache: Bool, logPrefix: String) async throws -> CapturedPage {
        let dataURL = payload["image"] as? String ?? payload["thumb"] as? String
        guard let dataURL, let imageData = Self.decodeDataURL(dataURL), let image = UIImage(data: imageData) else {
            throw CaptureError.badImageData
        }
        let titleRaw = payload["title"] as? String ?? "Kindle Page"
        let rawKey = payload["key"] as? String ?? ""
        let key = rawKey.isEmpty ? Self.stableImageKey(imageData) : rawKey
        let title = cleanKindleTitle(titleRaw, key: key)
        appendLog("\(logPrefix) key=\(key.prefix(8)) source=\(payload["source"] as? String ?? "?") title=\(title) bytes=\(imageData.count)")

        prepareStatus = AppLocalized("Recognizing Kindle text...")
        var doc = try await OCRService.shared.recognizeImportedImage(image: image.fixedOrientation(), title: title)
        doc.sourceKind = .kindle
        if let url = payload["url"] as? String {
            doc.sourceURL = url
        }
        appendLog("KINDLE OCR paragraphs=\(doc.paragraphs.count) chars=\(doc.fullText.count)")
        let page = CapturedPage(key: key, title: title, document: doc)
        if shouldCache { cache(page) }
        return page
    }

    private func contentMatchTokens(_ text: String, limit: Int = 150) -> [String] {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let cleaned = folded.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        let stopWords: Set<String> = [
            "the", "and", "that", "with", "for", "you", "your", "this", "from", "are",
            "was", "were", "but", "not", "have", "has", "had", "his", "her", "she",
            "him", "they", "them", "their", "there", "then", "than", "into", "out",
            "its", "our", "one", "all", "can", "could", "would", "should"
        ]
        let words = cleaned
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        if words.count >= 12 {
            return Array(words.prefix(limit))
        }

        let compact = folded
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        guard compact.count >= 4 else { return Array(words.prefix(limit)) }
        var grams: [String] = []
        let chars = Array(compact)
        for idx in 0..<(chars.count - 2) {
            grams.append(String(chars[idx...idx + 2]))
            if grams.count >= limit { break }
        }
        return grams
    }

    private func contentMatchScore(target: [String], visible: [String]) -> Double {
        guard !target.isEmpty, !visible.isEmpty else { return 0 }
        let targetPairs = Set(adjacentPairs(target))
        let visiblePairSet = Set(adjacentPairs(visible))
        if !targetPairs.isEmpty, !visiblePairSet.isEmpty {
            let pairHits = targetPairs.intersection(visiblePairSet).count
            let pairBase = max(1, min(targetPairs.count, visiblePairSet.count))
            let pairScore = Double(pairHits) / Double(pairBase)
            if pairScore >= 0.28 { return pairScore }
        }

        let visibleSet = Set(visible)
        let targetSet = Set(target)
        let targetHits = target.filter { visibleSet.contains($0) }.count
        let visibleHits = visible.filter { targetSet.contains($0) }.count
        let targetScore = Double(targetHits) / Double(max(1, target.count))
        let visibleScore = Double(visibleHits) / Double(max(1, visible.count))
        return max(targetScore, visibleScore)
    }

    private func adjacentPairs(_ tokens: [String]) -> [String] {
        guard tokens.count > 1 else { return [] }
        return (0..<(tokens.count - 1)).map { "\(tokens[$0]) \(tokens[$0 + 1])" }
    }

    func prefetchNextPages(count: Int) async {
        guard !isPrefetching else { return }
        isPrefetching = true
        defer { isPrefetching = false }
        appendLog("KINDLE prefetch start count=\(count)")
        do {
            var lastKey = try await currentBestKey()
            if lastKey.isEmpty {
                let page = try await captureCurrentPage(shouldCache: true)
                lastKey = page.key
            } else if !cachedPages.contains(where: { $0.key == lastKey }) {
                let page = try await captureCurrentPage(shouldCache: true)
                lastKey = page.key
            }
            for i in 0..<count {
                prepareStatus = AppLocalized("Loading next Kindle page...")
                let nextKey = try await advanceUntilNewKey(previousKey: lastKey)
                guard !nextKey.isEmpty else {
                    appendLog("KINDLE prefetch stop no next key")
                    break
                }
                if cachedPages.contains(where: { $0.key == nextKey }) {
                    appendLog("KINDLE prefetch skip cached key=\(nextKey.prefix(8))")
                    lastKey = nextKey
                    continue
                }
                let page = try await captureCurrentPage(shouldCache: true)
                lastKey = page.key
                appendLog("KINDLE prefetch page \(i + 1)/\(count) key=\(page.key.prefix(8)) paras=\(page.document.paragraphs.count) chars=\(page.document.fullText.count)")
            }
        } catch {
            appendLog("KINDLE prefetch error \(error.localizedDescription)")
        }
        prepareStatus = ""
    }

    func startContinuousRead() {
        guard !isContinuousReading else { return }
        if isContinuousExplaining {
            stopContinuousExplain()
        }
        continuousReadRunID = UUID()
        let runID = continuousReadRunID
        isContinuousReading = true
        continuousStatus = AppLocalized("Preparing Kindle read aloud...")
        clearContinuousIssue()
        resetContinuousReadState(keepAudio: true)
        continuousReadPageKeys.removeAll()
        continuousLastReadSourceReason = ""
        continuousReadPrefetchTask?.cancel()
        continuousReadPrefetchTask = nil
        continuousPendingReadPrefetch = nil
        continuousExplainBlocks.removeAll()
        continuousFiredMarkKeys.removeAll()
        continuousCancellables.removeAll()
        resetLogFile()
        appendLog("KINDLE continuous START")
        installProbeIfNeeded()

        audio.clearQueue()
        audio.setPlaybackRate(Float(settings.effectiveSpeed(isPro: ProManager.shared.isPro)))
        audio.moreSegmentsExpected = true
        audio.setBook(
            id: "kindle-\(urlString.hashValue)",
            title: "Kindle",
            chapterTitle: nil,
            coverUrl: nil
        )
        audio.onPlaybackComplete = { [weak self] in
            Task { @MainActor in
                await self?.handleContinuousReadQueueDrained(runID: runID)
            }
        }

        audio.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.updateContinuousHighlight(time: time)
            }
            .store(in: &continuousCancellables)

        audio.$currentSegment
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segment in
                self?.handleContinuousSegmentChanged(segment)
            }
            .store(in: &continuousCancellables)

        continuousTask = Task { [weak self] in
            await self?.prepareAndPlayVisiblePage(clearQueue: false, reason: "initial", runID: runID)
        }
    }

    func stopContinuousRead() {
        guard isContinuousReading || continuousTask != nil else { return }
        appendLog("KINDLE continuous STOP")
        continuousReadRunID = UUID()
        isContinuousReading = false
        continuousStatus = ""
        clearContinuousIssue()
        continuousTask?.cancel()
        continuousTask = nil
        continuousReadPrefetchTask?.cancel()
        continuousReadPrefetchTask = nil
        continuousPendingReadPrefetch = nil
        continuousCancellables.removeAll()
        resetContinuousReadState(keepAudio: false)
        continuousReadPageKeys.removeAll()
        continuousLastReadSourceReason = ""
        audio.moreSegmentsExpected = false
        audio.onPlaybackComplete = nil
        Task { await TTSService.shared.cancelCurrentRequest() }
        audio.clearQueue()
        audio.clearBook()
        webView?.evaluateJavaScript("window.__crBgProbeClearOCRHighlight && window.__crBgProbeClearOCRHighlight()")
        webView?.evaluateJavaScript("window.__crBgProbeClearOCRMarks && window.__crBgProbeClearOCRMarks()")
    }

    private func resetContinuousReadState(keepAudio: Bool) {
        activeContinuousPage = nil
        continuousPreparedPages.removeAll()
        continuousPreparingPageKeys.removeAll()
        continuousSegmentPageKeys.removeAll()
        continuousSegmentsByPageParagraph.removeAll()
        continuousAlignCache.removeAll()
        continuousVisualKeysByPageKey.removeAll()
        continuousVisualSeekInFlight.removeAll()
        continuousPlayingPageKey = ""
        continuousLastParagraphKey = ""
        continuousLastWordKey = ""
        continuousLastWordIndexByParagraph.removeAll()
        continuousLastHighlightMismatch = ""
        continuousExplainPrevSummary = nil
        nativePlaybackDocument = nil
        nativePlaybackPageKey = ""
        nativePlaybackParagraphIndex = -1
        nativePlaybackWordIndex = nil
        nativePlaybackMarks = []
        if !keepAudio {
            continuousTask = nil
        }
    }

    private func showNativePlaybackPage(_ page: CapturedPage, paragraphIndex: Int, wordIndex: Int?, reason: String) {
        let didChangePage = nativePlaybackPageKey != page.key
        nativePlaybackDocument = page.document
        nativePlaybackPageKey = page.key
        nativePlaybackParagraphIndex = paragraphIndex
        nativePlaybackWordIndex = wordIndex
        if didChangePage {
            nativePlaybackMarks = []
        }
        if didChangePage {
            appendLog("KINDLE native page key=\(page.key.prefix(8)) reason=\(reason) p=\(paragraphIndex)")
        }
    }

    private func setContinuousIssue(kind: KindlePipelineIssue.Kind, title: String, message: String, canRetry: Bool) {
        continuousIssue = KindlePipelineIssue(kind: kind, title: title, message: message, canRetry: canRetry)
        appendLog("KINDLE pipeline issue kind=\(kind.rawValue) title=\(title)")
    }

    private func clearContinuousIssue() {
        continuousIssue = nil
    }

    private func setSourceBlockedIssue(mode: KindlePipelineMode, reason: String) {
        let prefix = mode == .read ? AppLocalized("Kindle read aloud") : AppLocalized("Kindle explain")
        switch reason {
        case "anchor-not-held":
            setContinuousIssue(
                kind: .sourceNotReady,
                title: AppLocalized("Kindle source is out of sync"),
                message: AppLocalized("\(prefix) is waiting because the original Kindle page no longer contains the current playback page. Keep the book page open, scroll near the current content, then tap Retry."),
                canRetry: true
            )
        case "app-not-active":
            setContinuousIssue(
                kind: .waitingForMorePages,
                title: AppLocalized("Need the Kindle page open to load more"),
                message: AppLocalized("\(prefix) can keep playing buffered audio in the background, but loading new Kindle pages requires the app to be open. Reopen the reader and tap Retry."),
                canRetry: true
            )
        case "source-at-tail", "no-new-after-anchor":
            setContinuousIssue(
                kind: .ended,
                title: AppLocalized("No more loaded Kindle pages"),
                message: AppLocalized("\(prefix) reached the end of the loaded Kindle content. If this is not the end of the book, scroll the Kindle page slightly so it loads more content, then tap Retry."),
                canRetry: true
            )
        default:
            setContinuousIssue(
                kind: .waitingForMorePages,
                title: AppLocalized("Waiting for more Kindle pages"),
                message: AppLocalized("\(prefix) could not find a new loaded Kindle page yet. Keep the Kindle reader open, let the page finish loading, or scroll the source page a little, then tap Retry. Reason: \(reason)"),
                canRetry: true
            )
        }
    }

    func retryContinuousPipeline() {
        clearContinuousIssue()
        if isContinuousExplaining {
            let runID = continuousExplainRunID
            Task { [weak self] in
                await self?.handleContinuousExplainQueueDrained(runID: runID)
            }
        } else if isContinuousReading {
            let runID = continuousReadRunID
            Task { [weak self] in
                await self?.handleContinuousReadQueueDrained(runID: runID)
            }
        }
    }

    private func prepareAndPlayVisiblePage(clearQueue: Bool, reason: String, runID: UUID) async {
        guard isContinuousReadActive(runID) else { return }
        do {
            if clearQueue {
                audio.clearQueue()
                audio.moreSegmentsExpected = true
            }
            continuousSegmentsByPageParagraph.removeAll()
            continuousSegmentPageKeys.removeAll()
            continuousAlignCache.removeAll()
            continuousLastParagraphKey = ""
            continuousLastWordKey = ""
            continuousLastWordIndexByParagraph.removeAll()
            continuousStatus = AppLocalized("Capturing Kindle page...")

            let page = try await captureCurrentPage(shouldCache: true)
            guard !Task.isCancelled, isContinuousReadActive(runID) else { return }
            activeContinuousPage = page
            continuousPreparedPages[page.key] = page
            continuousVisualKeysByPageKey[page.key] = page.key
            continuousPlayingPageKey = page.key
            showNativePlaybackPage(page, paragraphIndex: -1, wordIndex: nil, reason: reason)
            audio.setBook(
                id: "kindle-\(page.key)",
                title: page.title,
                chapterTitle: AppLocalized("Kindle"),
                coverUrl: nil
            )
            appendLog("KINDLE continuous page reason=\(reason) key=\(page.key.prefix(8)) paras=\(page.document.readableParagraphs.count)")
            continuousStatus = AppLocalized("Generating Kindle audio...")

            let readable = page.document.readableParagraphs
            guard !readable.isEmpty else {
                appendLog("KINDLE continuous page empty, advancing")
                await handleContinuousReadQueueDrained(runID: runID)
                return
            }

            for paragraph in readable {
                guard !Task.isCancelled, isContinuousReadActive(runID) else { return }
                let text = SpeechTextSanitizer.sanitizedForTTS(paragraph.text)
                guard SpeechTextSanitizer.containsSpeakableContent(text) else { continue }
                continuousStatus = AppLocalized("Generating paragraph \(paragraph.id + 1)/\(page.document.paragraphs.count)...")
                try await TTSService.shared.generateTTSForParagraph(
                    paragraphIndex: paragraph.id,
                    text: text,
                    voice: settings.voice(for: page.document.language),
                    speed: 1.0,
                    language: page.document.language
                ) { [weak self] segment in
                    await MainActor.run {
                        self?.appendContinuousSegment(segment, pageKey: page.key)
                    }
                }
            }

            guard !Task.isCancelled, isContinuousReadActive(runID) else { return }
            audio.moreSegmentsExpected = true
            continuousReadPageKeys.insert(page.key)
            continuousStatus = AppLocalized("Reading Kindle page...")
            let segmentCount = continuousSegmentsByPageParagraph[page.key]?.values.flatMap { $0 }.count ?? 0
            appendLog("KINDLE continuous page ready key=\(page.key.prefix(8)) segments=\(segmentCount)")
            scheduleContinuousReadPrefetch(after: page.key, runID: runID)
        } catch {
            guard isContinuousReadActive(runID) else { return }
            audio.moreSegmentsExpected = false
            continuousStatus = AppLocalized("Kindle read failed: \(error.localizedDescription)")
            appendLog("KINDLE continuous error \(error.localizedDescription)")
            setContinuousIssue(
                kind: .pageFailed,
                title: AppLocalized("Kindle read preparation failed"),
                message: error.localizedDescription,
                canRetry: true
            )
        }
    }

    private func appendContinuousSegment(_ segment: AudioSegment, pageKey: String) {
        guard isContinuousReading else { return }
        continuousSegmentsByPageParagraph[pageKey, default: [:]][segment.paragraphIndex, default: []].append(segment)
        continuousSegmentPageKeys[segmentSignature(segment)] = pageKey
        continuousAlignCache.removeValue(forKey: alignCacheKey(pageKey: pageKey, paragraphIndex: segment.paragraphIndex))
        audio.loadSegment(segment)
        appendLog("KINDLE continuous segment key=\(pageKey.prefix(8)) p=\(segment.paragraphIndex) s=\(segment.segmentIndex) ts=\(segment.timestamps.count) dur=\(String(format: "%.2f", segment.duration))")
    }

    private func handleContinuousSegmentChanged(_ segment: AudioSegment?) {
        guard isContinuousReading, let segment else { return }
        let signature = segmentSignature(segment)
        guard let pageKey = continuousSegmentPageKeys[signature] else {
            appendLog("KINDLE segment missing pageKey p=\(segment.paragraphIndex) s=\(segment.segmentIndex)")
            return
        }
        let didPageSwitch = pageKey != continuousPlayingPageKey
        if didPageSwitch {
            continuousPlayingPageKey = pageKey
            continuousAlignCache.removeAll()
            continuousLastWordKey = ""
            continuousLastWordIndexByParagraph.removeAll()
            if let page = continuousPreparedPages[pageKey] {
                activeContinuousPage = page
                audio.setBook(
                    id: "kindle-\(page.key)",
                    title: page.title,
                    chapterTitle: AppLocalized("Kindle"),
                    coverUrl: nil
                )
            }
            appendLog("KINDLE playback page switch key=\(pageKey.prefix(8)) p=\(segment.paragraphIndex)")
        }

        let paragraphKey = "\(pageKey)#\(segment.paragraphIndex)"
        let didParagraphSwitch = paragraphKey != continuousLastParagraphKey
        if didParagraphSwitch {
            continuousLastParagraphKey = paragraphKey
            appendLog("KINDLE paragraph switch key=\(pageKey.prefix(8)) p=\(segment.paragraphIndex)")
        }

        if didPageSwitch || didParagraphSwitch,
           let page = continuousPreparedPages[pageKey] ?? activeContinuousPage {
            showNativePlaybackPage(
                page,
                paragraphIndex: segment.paragraphIndex,
                wordIndex: nil,
                reason: didPageSwitch ? "playback-switch" : "paragraph-switch"
            )
        }

        guard didPageSwitch || didParagraphSwitch else { return }
        Task { [weak self] in
            if didPageSwitch {
                await MainActor.run {
                    guard let self else { return }
                    self.scheduleContinuousReadPrefetch(after: pageKey, runID: self.continuousReadRunID)
                }
            }
        }
    }

    private func segmentSignature(_ segment: AudioSegment) -> String {
        "\(segment.paragraphIndex)#\(segment.segmentIndex)#\(Int(segment.duration * 1000))#\(segment.audioData.count)#\(segment.text.prefix(24))"
    }

    private func alignCacheKey(pageKey: String, paragraphIndex: Int) -> String {
        "\(pageKey)#\(paragraphIndex)"
    }

    private func advanceContinuousPage() async {
        await handleContinuousReadQueueDrained(runID: continuousReadRunID)
    }

    private func handleContinuousReadQueueDrained(runID: UUID) async {
        guard isContinuousReadActive(runID) else { return }
        let anchorKey = !continuousPlayingPageKey.isEmpty
            ? continuousPlayingPageKey
            : (activeContinuousPage?.key ?? "")
        guard !anchorKey.isEmpty else {
            continuousStatus = AppLocalized("Kindle page state is not ready.")
            audio.moreSegmentsExpected = false
            setContinuousIssue(
                kind: .sourceNotReady,
                title: AppLocalized("Kindle page is not ready"),
                message: AppLocalized("Open a Kindle book page, keep it visible for a moment, then retry."),
                canRetry: true
            )
            return
        }

        clearContinuousIssue()
        if continuousReadPrefetchTask != nil {
            continuousPendingReadPrefetch = (anchorKey, runID)
            continuousStatus = AppLocalized("Preparing more Kindle pages...")
            audio.moreSegmentsExpected = true
            appendLog("KINDLE read queue drained while prefetch active after=\(anchorKey.prefix(8))")
            return
        }
        continuousStatus = AppLocalized("Loading more Kindle pages...")
        audio.moreSegmentsExpected = true
        let prepared = await prefetchLivePagesAfter(
            anchorKey,
            limit: continuousReadPrefetchTarget,
            runID: runID
        )
        guard isContinuousReadActive(runID) else { return }
        if prepared <= 0 {
            audio.moreSegmentsExpected = false
            continuousStatus = AppLocalized("Waiting for Kindle to load more pages.")
            setSourceBlockedIssue(mode: .read, reason: continuousLastReadSourceReason.isEmpty ? "no-candidates" : continuousLastReadSourceReason)
        } else {
            clearContinuousIssue()
            continuousStatus = AppLocalized("Reading Kindle page...")
        }
    }

    private func scheduleContinuousReadPrefetch(after pageKey: String, runID: UUID) {
        guard isContinuousReadActive(runID), !pageKey.isEmpty else { return }
        if continuousReadPrefetchTask != nil {
            continuousPendingReadPrefetch = (pageKey, runID)
            appendLog("KINDLE read prefetch busy after=\(pageKey.prefix(8)) pending=1")
            return
        }
        startContinuousReadPrefetch(after: pageKey, runID: runID)
    }

    private func startContinuousReadPrefetch(after pageKey: String, runID: UUID) {
        guard isContinuousReadActive(runID), !pageKey.isEmpty else { return }
        audio.moreSegmentsExpected = true
        continuousReadPrefetchTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.prefetchLivePagesAfter(pageKey, limit: self.continuousReadPrefetchTarget, runID: runID)
        }
    }

    @discardableResult
    private func prefetchLivePagesAfter(_ pageKey: String, limit: Int, runID: UUID) async -> Int {
        guard isContinuousReadActive(runID), limit > 0 else { return 0 }
        var preparedCount = 0
        defer {
            if isContinuousReadActive(runID) {
                continuousReadPrefetchTask = nil
                if let pending = continuousPendingReadPrefetch, pending.runID == runID {
                    continuousPendingReadPrefetch = nil
                    if pending.pageKey != pageKey {
                        appendLog("KINDLE read prefetch drain pending after=\(pending.pageKey.prefix(8))")
                        scheduleContinuousReadPrefetch(after: pending.pageKey, runID: pending.runID)
                    }
                } else if continuousPendingReadPrefetch?.runID == runID {
                    continuousPendingReadPrefetch = nil
                }
            }
        }
        do {
            let discovery = await discoverSourceCandidates(after: pageKey, targetAhead: limit, mode: .read, runID: runID)
            let candidates = discovery.candidates
            guard !candidates.isEmpty else {
                audio.moreSegmentsExpected = false
                continuousLastReadSourceReason = discovery.reason
                appendLog("KINDLE read prefetch empty after=\(pageKey.prefix(8)) reason=\(discovery.reason)")
                return preparedCount
            }
            for key in candidates {
                guard isContinuousReadActive(runID), !Task.isCancelled else { return preparedCount }
                if isKnownReadPageKey(key) { continue }
                continuousPreparingPageKeys.insert(key)
                do {
                    defer { continuousPreparingPageKeys.remove(key) }
                    let page = try await captureLivePage(key: key, shouldCache: true)
                    guard isContinuousReadActive(runID), !Task.isCancelled else { return preparedCount }
                    continuousPreparedPages[page.key] = page
                    try await enqueuePreparedPage(page, reason: "live-prefetch")
                    preparedCount += 1
                    continuousLastReadSourceReason = ""
                    clearContinuousIssue()
                }
            }
            audio.moreSegmentsExpected = false
            appendLog("KINDLE read prefetch filled after=\(pageKey.prefix(8)) count=\(preparedCount)")
            return preparedCount
        } catch {
            guard isContinuousReadActive(runID) else { return preparedCount }
            appendLog("KINDLE live prefetch error \(error.localizedDescription)")
            audio.moreSegmentsExpected = false
            setContinuousIssue(
                kind: .pageFailed,
                title: AppLocalized("Kindle page preparation failed"),
                message: error.localizedDescription,
                canRetry: true
            )
            return preparedCount
        }
    }

    private func livePrefetchCandidates(from keys: [String], after pageKey: String, limit: Int) -> [String] {
        orderedLiveCandidates(from: keys, after: pageKey, limit: limit) { key in
            isKnownReadPageKey(key)
        }.keys
    }

    private func isContinuousReadActive(_ runID: UUID) -> Bool {
        isContinuousReading && continuousReadRunID == runID
    }

    private func isKnownReadPageKey(_ pageKey: String) -> Bool {
        guard !pageKey.isEmpty else { return false }
        return continuousReadPageKeys.contains(pageKey)
            || continuousPreparedPages[pageKey] != nil
            || continuousPreparingPageKeys.contains(pageKey)
            || hasEnqueuedReadAudio(for: pageKey)
    }

    private func hasEnqueuedReadAudio(for pageKey: String) -> Bool {
        continuousSegmentPageKeys.values.contains(pageKey)
    }

    private func orderedLiveCandidates(
        from keys: [String],
        after pageKey: String,
        limit: Int,
        isKnown: (String) -> Bool
    ) -> (keys: [String], reason: String) {
        var ordered: [String] = []
        var seen = Set<String>()
        for key in keys where !key.isEmpty && !seen.contains(key) {
            seen.insert(key)
            ordered.append(key)
        }
        guard !ordered.isEmpty else { return ([], "empty-live-keys") }

        let scan: [String]
        if pageKey.isEmpty {
            scan = ordered
        } else if let anchorIndex = ordered.lastIndex(of: pageKey) {
            let next = ordered.index(after: anchorIndex)
            scan = next < ordered.endIndex ? Array(ordered[next..<ordered.endIndex]) : []
        } else {
            return ([], "anchor-not-held")
        }
        guard !scan.isEmpty else { return ([], "source-at-tail") }

        var result: [String] = []
        var skippedKnown = 0
        for key in scan {
            guard key != pageKey,
                  !isKnown(key),
                  !result.contains(key) else {
                if key != pageKey, isKnown(key) { skippedKnown += 1 }
                continue
            }
            result.append(key)
            if result.count >= limit { break }
        }
        if result.isEmpty, skippedKnown > 0 {
            return ([], "new-keys-already-buffered")
        }
        return (result, result.isEmpty ? "no-new-after-anchor" : "ok")
    }

    private func isKnownPipelinePageKey(_ pageKey: String, mode: KindlePipelineMode) -> Bool {
        switch mode {
        case .read:
            return isKnownReadPageKey(pageKey)
        case .explain:
            return isKnownExplainPageKey(pageKey)
        }
    }

    private func isPipelineActive(_ mode: KindlePipelineMode, runID: UUID) -> Bool {
        switch mode {
        case .read:
            return isContinuousReadActive(runID)
        case .explain:
            return isContinuousExplainActive(runID)
        }
    }

    private func sourceCandidates(
        from payload: [String: Any],
        after pageKey: String,
        targetAhead: Int,
        mode: KindlePipelineMode
    ) -> (keys: [String], reason: String) {
        let keys = payload["keys"] as? [String] ?? []
        return orderedLiveCandidates(from: keys, after: pageKey, limit: targetAhead) { key in
            isKnownPipelinePageKey(key, mode: mode)
        }
    }

    private func sourceDiscoverySnapshot(
        payload: [String: Any],
        candidates: [String],
        reason: String
    ) -> KindleSourceDiscovery {
        KindleSourceDiscovery(
            candidates: candidates,
            reason: reason,
            heldKeys: payload["heldKeys"] as? Int ?? -1,
            currentKey: payload["current"] as? String ?? "",
            bestKey: payload["bestKey"] as? String ?? "",
            recentKeys: payload["recentKeys"] as? String ?? ""
        )
    }

    private func logSourceDiscovery(
        mode: KindlePipelineMode,
        stage: String,
        after pageKey: String,
        targetAhead: Int,
        snapshot: KindleSourceDiscovery,
        payload: [String: Any] = [:]
    ) {
        appendLog(
            "KINDLE source \(mode.rawValue) \(stage) after=\(pageKey.prefix(8)) target=\(targetAhead) candidates=\(snapshot.candidates.map { String($0.prefix(8)) }.joined(separator: ",")) held=\(snapshot.heldKeys) current=\(snapshot.currentKey.prefix(8)) best=\(snapshot.bestKey.prefix(8)) recent=\(snapshot.recentKeys) reason=\(snapshot.reason)"
        )
        if let tried = payload["tried"] as? String, !tried.isEmpty {
            appendLog("KINDLE source \(mode.rawValue) \(stage) tried=\(tried)")
        }
        if let rows = payload["imgRows"] as? String, !rows.isEmpty {
            appendLog("KINDLE source \(mode.rawValue) \(stage) rows=\(rows)")
        }
    }

    private func discoverSourceCandidates(
        after pageKey: String,
        targetAhead: Int,
        mode: KindlePipelineMode,
        runID: UUID
    ) async -> KindleSourceDiscovery {
        guard isPipelineActive(mode, runID: runID), targetAhead > 0 else {
            return KindleSourceDiscovery(candidates: [], reason: "inactive", heldKeys: -1, currentKey: "", bestKey: "", recentKeys: "")
        }

        var lastSnapshot = KindleSourceDiscovery(candidates: [], reason: "not-started", heldKeys: -1, currentKey: "", bestKey: "", recentKeys: "")
        do {
            let initialPayload = try await liveKeysPayload()
            if initialPayload["ok"] as? Bool == true {
                let selection = sourceCandidates(from: initialPayload, after: pageKey, targetAhead: targetAhead, mode: mode)
                let snapshot = sourceDiscoverySnapshot(payload: initialPayload, candidates: selection.keys, reason: selection.reason)
                lastSnapshot = snapshot
                logSourceDiscovery(mode: mode, stage: "initial", after: pageKey, targetAhead: targetAhead, snapshot: snapshot, payload: initialPayload)
                if !snapshot.candidates.isEmpty { return snapshot }
            } else {
                let reason = initialPayload["reason"] as? String ?? "live-keys-failed"
                let snapshot = sourceDiscoverySnapshot(payload: initialPayload, candidates: [], reason: reason)
                lastSnapshot = snapshot
                logSourceDiscovery(mode: mode, stage: "initial", after: pageKey, targetAhead: targetAhead, snapshot: snapshot, payload: initialPayload)
            }

            guard UIApplication.shared.applicationState == .active else {
                return KindleSourceDiscovery(
                    candidates: [],
                    reason: "app-not-active",
                    heldKeys: lastSnapshot.heldKeys,
                    currentKey: lastSnapshot.currentKey,
                    bestKey: lastSnapshot.bestKey,
                    recentKeys: lastSnapshot.recentKeys
                )
            }

            if !pageKey.isEmpty {
                do {
                    let focusPayload = try await focusKindleSource(on: pageKey)
                    let postFocusPayload = try await liveKeysPayload()
                    let selection = sourceCandidates(from: postFocusPayload, after: pageKey, targetAhead: targetAhead, mode: mode)
                    let focusReason = focusPayload["reason"] as? String
                    let snapshot = sourceDiscoverySnapshot(
                        payload: postFocusPayload,
                        candidates: selection.keys,
                        reason: selection.keys.isEmpty ? "\(focusReason ?? "focus")/\(selection.reason)" : selection.reason
                    )
                    logSourceDiscovery(mode: mode, stage: "focus", after: pageKey, targetAhead: targetAhead, snapshot: snapshot, payload: focusPayload)
                    if !snapshot.candidates.isEmpty { return snapshot }
                } catch {
                    appendLog("KINDLE source \(mode.rawValue) focus error after=\(pageKey.prefix(8)) \(error.localizedDescription)")
                }
            }

            for attempt in 1...4 {
                guard isPipelineActive(mode, runID: runID), !Task.isCancelled else {
                    return KindleSourceDiscovery(candidates: [], reason: "cancelled", heldKeys: -1, currentKey: "", bestKey: "", recentKeys: "")
                }
                do {
                    let scrollPayload = try await scrollKindle(delta: 520 + attempt * 120, soft: false)
                    try await Task.sleep(nanoseconds: 650_000_000)
                    let payload = try await liveKeysPayload()
                    let selection = sourceCandidates(from: payload, after: pageKey, targetAhead: targetAhead, mode: mode)
                    let reason = selection.keys.isEmpty ? selection.reason : "scroll-\(attempt)"
                    let snapshot = sourceDiscoverySnapshot(payload: payload, candidates: selection.keys, reason: reason)
                    logSourceDiscovery(mode: mode, stage: "scroll\(attempt)", after: pageKey, targetAhead: targetAhead, snapshot: snapshot, payload: scrollPayload)
                    lastSnapshot = snapshot
                    if !snapshot.candidates.isEmpty { return snapshot }
                } catch {
                    appendLog("KINDLE source \(mode.rawValue) scroll error after=\(pageKey.prefix(8)) attempt=\(attempt) \(error.localizedDescription)")
                    lastSnapshot = KindleSourceDiscovery(candidates: [], reason: error.localizedDescription, heldKeys: -1, currentKey: "", bestKey: "", recentKeys: "")
                }
            }
            return lastSnapshot
        } catch {
            appendLog("KINDLE source \(mode.rawValue) discovery error after=\(pageKey.prefix(8)) \(error.localizedDescription)")
            return KindleSourceDiscovery(candidates: [], reason: error.localizedDescription, heldKeys: -1, currentKey: "", bestKey: "", recentKeys: "")
        }
    }

    private func enqueuePreparedPage(_ page: CapturedPage, reason: String) async throws {
        let readable = page.document.readableParagraphs
        guard !readable.isEmpty else {
            appendLog("KINDLE enqueue skip empty key=\(page.key.prefix(8)) reason=\(reason)")
            return
        }
        continuousReadPageKeys.insert(page.key)
        appendLog("KINDLE enqueue page reason=\(reason) key=\(page.key.prefix(8)) paras=\(readable.count)")
        for paragraph in readable {
            guard !Task.isCancelled, isContinuousReading else { return }
            let text = SpeechTextSanitizer.sanitizedForTTS(paragraph.text)
            guard SpeechTextSanitizer.containsSpeakableContent(text) else { continue }
            try await TTSService.shared.generateTTSForParagraph(
                paragraphIndex: paragraph.id,
                text: text,
                voice: settings.voice(for: page.document.language),
                speed: 1.0,
                language: page.document.language
            ) { [weak self] segment in
                await MainActor.run {
                    self?.appendContinuousSegment(segment, pageKey: page.key)
                }
            }
        }
        let segmentCount = continuousSegmentsByPageParagraph[page.key]?.values.flatMap { $0 }.count ?? 0
        appendLog("KINDLE enqueue ready key=\(page.key.prefix(8)) segments=\(segmentCount)")
    }

    private func ensureVisiblePageContent(_ pageKey: String, preferForward: Bool) async {
        guard isContinuousReading, UIApplication.shared.applicationState == .active else { return }
        guard let targetPage = continuousPreparedPages[pageKey] ?? activeContinuousPage else { return }
        if continuousVisualSeekInFlight.contains(pageKey) { return }
        continuousVisualSeekInFlight.insert(pageKey)
        defer { continuousVisualSeekInFlight.remove(pageKey) }

        do {
            let current = try await currentBestKey()
            if let visualKey = continuousVisualKeysByPageKey[pageKey], !visualKey.isEmpty, visualKey == current {
                return
            }

            let targetTokens = contentMatchTokens(targetPage.document.fullText)
            guard !targetTokens.isEmpty else {
                appendLog("KINDLE visual content skip empty target=\(pageKey.prefix(8))")
                return
            }

            appendLog("KINDLE visual content seek target=\(pageKey.prefix(8)) current=\(current.prefix(8))")
            var bestScore = 0.0
            var bestKey = current
            for attempt in 0...10 {
                guard isContinuousReading, UIApplication.shared.applicationState == .active else { return }
                if attempt > 0 {
                    try await scrollKindle(delta: visualSeekDelta(attempt: attempt, preferForward: preferForward), soft: false)
                    try await Task.sleep(nanoseconds: 420_000_000)
                }

                let state = (try? await statePayload()) ?? [:]
                let visibleKey = state["bestKey"] as? String ?? ""
                do {
                    let visiblePage = try await captureVisiblePageForMatch()
                    let score = contentMatchScore(
                        target: targetTokens,
                        visible: contentMatchTokens(visiblePage.document.fullText)
                    )
                    let visualKey = visibleKey.isEmpty ? visiblePage.key : visibleKey
                    if score > bestScore {
                        bestScore = score
                        bestKey = visualKey
                    }
                    appendLog("KINDLE visual content attempt=\(attempt) target=\(pageKey.prefix(8)) visible=\(visualKey.prefix(8)) score=\(String(format: "%.2f", score))")
                    if score >= 0.34 {
                        continuousVisualKeysByPageKey[pageKey] = visualKey
                        continuousLastHighlightMismatch = ""
                        appendLog("KINDLE visual content match target=\(pageKey.prefix(8)) visual=\(visualKey.prefix(8)) score=\(String(format: "%.2f", score))")
                        return
                    }
                } catch {
                    appendLog("KINDLE visual content capture miss attempt=\(attempt) \(error.localizedDescription)")
                }
            }
            appendLog("KINDLE visual content no-match target=\(pageKey.prefix(8)) best=\(bestKey.prefix(8)) score=\(String(format: "%.2f", bestScore))")
        } catch {
            appendLog("KINDLE visual content error \(error.localizedDescription)")
        }
    }

    private func visualSeekDelta(attempt: Int, preferForward: Bool) -> Int {
        guard attempt > 0 else { return 0 }
        let primary = preferForward ? 1 : -1
        let direction = attempt <= 6 ? primary : -primary
        let localAttempt = attempt <= 6 ? attempt : attempt - 6
        return direction * (220 + min(localAttempt, 5) * 45)
    }

    @discardableResult
    private func scrollKindle(delta: Int, soft: Bool) async throws -> [String: Any] {
        guard let webView else { throw CaptureError.webViewMissing }
        let fn = soft ? "__crBgProbeScrollSoft" : "__crBgProbeScroll"
        let js = """
        (function() {
          \(Self.bootstrapScript)
          if (!window.\(fn)) return JSON.stringify({ ok: false, reason: 'missing-scroll' });
          return window.\(fn)(\(delta));
        })();
        """
        return try await evaluateJSON(webView: webView, js: js)
    }

    private func focusKindleSource(on pageKey: String) async throws -> [String: Any] {
        guard let webView else { throw CaptureError.webViewMissing }
        let safeKey = pageKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let js = """
        (function() {
          \(Self.bootstrapScript)
          if (!window.__crBgProbeFocusKey) return JSON.stringify({ ok: false, reason: 'missing-focus-key' });
          return window.__crBgProbeFocusKey("\(safeKey)");
        })();
        """
        return try await evaluateJSON(webView: webView, js: js)
    }

    private func scrollContinuousParagraphIntoView(pageKey: String, paragraphIndex: Int) async {
        guard isContinuousReading, UIApplication.shared.applicationState == .active else { return }
        guard let page = continuousPreparedPages[pageKey] ?? activeContinuousPage,
              paragraphIndex >= 0,
              paragraphIndex < page.document.paragraphs.count,
              let rect = normalizedParagraphRect(page.document.paragraphs[paragraphIndex]) else { return }
        let visualKey = continuousVisualKeysByPageKey[pageKey] ?? pageKey
        do {
            let payload = try await scrollKindleRectIntoComfort(rect: rect, expectedKey: visualKey)
            let needed = payload["needed"] as? Bool ?? false
            let delta = payload["delta"] as? Double ?? 0
            let reason = payload["reason"] as? String ?? ""
            let before = payload["beforeKey"] as? String ?? ""
            let after = payload["afterKey"] as? String ?? ""
            let reverted = payload["reverted"] as? Bool ?? false
            appendLog("KINDLE paragraph scroll key=\(pageKey.prefix(8)) visual=\(visualKey.prefix(8)) p=\(paragraphIndex) needed=\(needed) delta=\(String(format: "%.0f", delta)) before=\(before.prefix(8)) after=\(after.prefix(8)) reverted=\(reverted) reason=\(reason)")
            if reason == "before-mismatch" {
                await ensureVisiblePageContent(pageKey, preferForward: false)
            }
        } catch {
            appendLog("KINDLE paragraph scroll error key=\(pageKey.prefix(8)) p=\(paragraphIndex) \(error.localizedDescription)")
        }
    }

    private func scrollKindleRectIntoComfort(rect: CGRect, expectedKey: String) async throws -> [String: Any] {
        guard let webView else { throw CaptureError.webViewMissing }
        let safeKey = expectedKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let js = String(
            format:
            """
            (function() {
              %@;
              if (!window.__crBgProbeScrollOCRRectIntoComfort) return JSON.stringify({ ok: false, reason: 'missing-paragraph-scroll' });
              return window.__crBgProbeScrollOCRRectIntoComfort({x:%.6f,y:%.6f,w:%.6f,h:%.6f}, "%@");
            })();
            """,
            Self.bootstrapScript,
            rect.origin.x,
            rect.origin.y,
            rect.width,
            rect.height,
            safeKey
        )
        return try await evaluateJSON(webView: webView, js: js)
    }

    private func normalizedParagraphRect(_ paragraph: ReadingParagraph) -> CGRect? {
        if let bbox = paragraph.bboxNorm, bbox.width > 0, bbox.height > 0 {
            return clampNormalizedRect(bbox)
        }
        var union: CGRect?
        for word in paragraph.words where word.bboxNorm.width > 0 && word.bboxNorm.height > 0 {
            union = union.map { $0.union(word.bboxNorm) } ?? word.bboxNorm
        }
        guard let union else { return nil }
        return clampNormalizedRect(union)
    }

    private func clampNormalizedRect(_ rect: CGRect) -> CGRect {
        let minX = max(0, min(1, rect.minX))
        let minY = max(0, min(1, rect.minY))
        let maxX = max(minX, min(1, rect.maxX))
        let maxY = max(minY, min(1, rect.maxY))
        return CGRect(x: minX, y: minY, width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
    }

    private func updateContinuousHighlight(time: Double) {
        guard isContinuousReading, let segment = audio.currentSegment else { return }
        let pageKey = continuousSegmentPageKeys[segmentSignature(segment)] ?? continuousPlayingPageKey
        guard let page = continuousPreparedPages[pageKey] ?? activeContinuousPage else { return }
        guard segment.paragraphIndex >= 0, segment.paragraphIndex < page.document.paragraphs.count else { return }
        let paragraph = page.document.paragraphs[segment.paragraphIndex]
        guard !paragraph.words.isEmpty else { return }

        if !segment.timestamps.isEmpty,
           let localIndex = timestampIndex(for: time, in: segment),
           let ocrWordIndex = alignedOCRWordIndex(
                paragraph: paragraph,
                pageKey: pageKey,
                paragraphIndex: segment.paragraphIndex,
                segment: segment,
                localTimestampIndex: localIndex
           ) {
            showContinuousHighlight(pageKey: pageKey, paragraphIndex: segment.paragraphIndex, wordIndex: ocrWordIndex, paragraph: paragraph)
            return
        }

        let segments = continuousSegmentsByPageParagraph[pageKey]?[segment.paragraphIndex] ?? [segment]
        let segPos = segments.firstIndex(where: { $0.id == segment.id }) ?? max(0, segment.segmentIndex)
        let progress = max(0, min(1, time / max(segment.duration, 0.01)))
        if let idx = ReadAloudViewModel.photoWordIndex(
            wordCount: paragraph.words.count,
            segPos: segPos,
            segCount: max(segments.count, segPos + 1),
            segProgress: progress
        ) {
            showContinuousHighlight(pageKey: pageKey, paragraphIndex: segment.paragraphIndex, wordIndex: idx, paragraph: paragraph)
        }
    }

    private func timestampIndex(for time: Double, in segment: AudioSegment) -> Int? {
        var localIndex: Int?
        for (idx, ts) in segment.timestamps.enumerated() {
            if time + 0.02 >= ts.startTime {
                localIndex = idx
            } else {
                break
            }
        }
        return localIndex
    }

    private func alignedOCRWordIndex(
        paragraph: ReadingParagraph,
        pageKey: String,
        paragraphIndex: Int,
        segment: AudioSegment,
        localTimestampIndex: Int
    ) -> Int? {
        let segments = continuousSegmentsByPageParagraph[pageKey]?[paragraphIndex] ?? [segment]
        let cacheKey = alignCacheKey(pageKey: pageKey, paragraphIndex: paragraphIndex)
        if continuousAlignCache[cacheKey] == nil {
            let map = OCRWordAligner.mapTimestampWords(in: paragraph, segments: segments)
            continuousAlignCache[cacheKey] = map
            let hit = map.compactMap { $0 }.count
            if !map.isEmpty {
                appendLog("KINDLE align key=\(pageKey.prefix(8)) p=\(paragraphIndex) hit=\(hit)/\(map.count)")
            }
        }
        let globalIndex = segments
            .prefix { $0.id != segment.id }
            .reduce(0) { $0 + $1.timestamps.count } + localTimestampIndex
        guard let map = continuousAlignCache[cacheKey],
              globalIndex >= 0,
              globalIndex < map.count else {
            return nil
        }
        return map[globalIndex]
    }

    private func showContinuousHighlight(pageKey: String, paragraphIndex: Int, wordIndex: Int, paragraph: ReadingParagraph) {
        guard wordIndex >= 0, wordIndex < paragraph.words.count else { return }
        let paragraphKey = "\(pageKey)#\(paragraphIndex)"
        if let last = continuousLastWordIndexByParagraph[paragraphKey], wordIndex < last {
            let mismatchKey = "\(paragraphKey)#\(wordIndex)<\(last)"
            if mismatchKey != continuousLastHighlightMismatch {
                continuousLastHighlightMismatch = mismatchKey
                appendLog("KINDLE highlight skip backwards key=\(pageKey.prefix(8)) p=\(paragraphIndex) word=\(wordIndex)<\(last)")
            }
            return
        }
        continuousLastWordIndexByParagraph[paragraphKey] = wordIndex

        let key = "\(pageKey)#\(paragraphIndex)#\(wordIndex)"
        guard key != continuousLastWordKey else { return }
        continuousLastWordKey = key

        if let page = continuousPreparedPages[pageKey] ?? activeContinuousPage,
           nativePlaybackPageKey != pageKey {
            showNativePlaybackPage(page, paragraphIndex: paragraphIndex, wordIndex: wordIndex, reason: "highlight")
        } else {
            nativePlaybackParagraphIndex = paragraphIndex
            nativePlaybackWordIndex = wordIndex
        }
    }

    func startContinuousExplain() {
        guard !isContinuousExplaining else { return }
        if isContinuousReading {
            stopContinuousRead()
        }
        continuousExplainRunID = UUID()
        let runID = continuousExplainRunID
        isContinuousExplaining = true
        continuousStatus = AppLocalized("Preparing Kindle explain...")
        activeContinuousPage = nil
        continuousPreparedPages.removeAll()
        continuousPreparingPageKeys.removeAll()
        continuousSegmentPageKeys.removeAll()
        continuousSegmentsByPageParagraph.removeAll()
        continuousAlignCache.removeAll()
        continuousVisualKeysByPageKey.removeAll()
        continuousVisualSeekInFlight.removeAll()
        continuousPlayingPageKey = ""
        continuousExplainBlocks.removeAll()
        continuousFiredMarkKeys.removeAll()
        continuousLastWordKey = ""
        continuousLastWordIndexByParagraph.removeAll()
        continuousLastHighlightMismatch = ""
        continuousExplainPrevSummary = nil
        continuousExplainNextAudioIndex = 0
        continuousExplainedPageKeys.removeAll()
        continuousLastExplainSourceReason = ""
        clearContinuousIssue()
        continuousPrefetchTask?.cancel()
        continuousPrefetchTask = nil
        continuousPendingPrefetch = nil
        nativePlaybackDocument = nil
        nativePlaybackPageKey = ""
        nativePlaybackParagraphIndex = -1
        nativePlaybackWordIndex = nil
        nativePlaybackMarks = []
        continuousCancellables.removeAll()
        resetLogFile()
        appendLog("KINDLE continuous EXPLAIN start")
        installProbeIfNeeded()

        audio.clearQueue()
        audio.setPlaybackRate(Float(settings.effectiveSpeed(isPro: ProManager.shared.isPro)))
        audio.moreSegmentsExpected = true
        audio.setBook(id: "kindle-explain-\(urlString.hashValue)", title: "Kindle", chapterTitle: AppLocalized("解读"), coverUrl: nil)
        audio.onPlaybackComplete = { [weak self] in
            Task { @MainActor in
                await self?.handleContinuousExplainQueueDrained(runID: runID)
            }
        }

        audio.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.updateContinuousExplainMarks(time: time)
            }
            .store(in: &continuousCancellables)

        audio.$currentSegment
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segment in
                self?.handleContinuousExplainSegmentChanged(segment)
            }
            .store(in: &continuousCancellables)

        continuousTask = Task { [weak self] in
            await self?.prepareAndExplainVisiblePage(clearQueue: false, reason: "initial", runID: runID)
        }
    }

    func stopContinuousExplain() {
        appendLog("KINDLE continuous EXPLAIN stop")
        continuousExplainRunID = UUID()
        isContinuousExplaining = false
        continuousStatus = ""
        continuousTask?.cancel()
        continuousTask = nil
        continuousPrefetchTask?.cancel()
        continuousPrefetchTask = nil
        continuousPendingPrefetch = nil
        continuousCancellables.removeAll()
        activeContinuousPage = nil
        continuousPreparedPages.removeAll()
        continuousPreparingPageKeys.removeAll()
        continuousSegmentPageKeys.removeAll()
        continuousSegmentsByPageParagraph.removeAll()
        continuousAlignCache.removeAll()
        continuousVisualKeysByPageKey.removeAll()
        continuousVisualSeekInFlight.removeAll()
        continuousPlayingPageKey = ""
        continuousExplainBlocks.removeAll()
        continuousFiredMarkKeys.removeAll()
        continuousLastWordKey = ""
        continuousLastWordIndexByParagraph.removeAll()
        continuousLastHighlightMismatch = ""
        continuousExplainPrevSummary = nil
        continuousExplainNextAudioIndex = 0
        continuousExplainedPageKeys.removeAll()
        continuousLastExplainSourceReason = ""
        clearContinuousIssue()
        nativePlaybackDocument = nil
        nativePlaybackPageKey = ""
        nativePlaybackParagraphIndex = -1
        nativePlaybackWordIndex = nil
        nativePlaybackMarks = []
        audio.moreSegmentsExpected = false
        audio.onPlaybackComplete = nil
        audio.onSegmentComplete = nil
        Task { await TTSService.shared.cancelCurrentRequest() }
        audio.clearQueue()
        audio.clearBook()
        webView?.evaluateJavaScript("window.__crBgProbeClearOCRHighlight && window.__crBgProbeClearOCRHighlight()")
        webView?.evaluateJavaScript("window.__crBgProbeClearOCRMarks && window.__crBgProbeClearOCRMarks()")
    }

    private func prepareAndExplainVisiblePage(clearQueue: Bool, reason: String, runID: UUID) async {
        guard isContinuousExplainActive(runID) else { return }
        do {
            if clearQueue {
                audio.clearQueue()
                audio.moreSegmentsExpected = true
                continuousExplainBlocks.removeAll()
                continuousFiredMarkKeys.removeAll()
                continuousPreparedPages.removeAll()
                continuousSegmentPageKeys.removeAll()
                continuousSegmentsByPageParagraph.removeAll()
                continuousPlayingPageKey = ""
                continuousExplainNextAudioIndex = 0
            }
            nativePlaybackMarks = []
            nativePlaybackWordIndex = nil
            continuousStatus = AppLocalized("Capturing Kindle page...")
            try? await webView?.evaluateJavaScript("window.__crBgProbeClearOCRMarks && window.__crBgProbeClearOCRMarks()")

            let page = try await captureCurrentPage(shouldCache: true)
            guard isContinuousExplainActive(runID), !Task.isCancelled else { return }
            activeContinuousPage = page
            continuousPreparedPages[page.key] = page
            continuousPlayingPageKey = page.key
            showNativePlaybackPage(page, paragraphIndex: -1, wordIndex: nil, reason: reason)
            appendLog("KINDLE explain page reason=\(reason) key=\(page.key.prefix(8)) paras=\(page.document.readableParagraphs.count) chars=\(page.document.fullText.count)")
            audio.setBook(id: "kindle-explain-\(page.key)", title: page.title, chapterTitle: AppLocalized("解读"), coverUrl: nil)

            let didPrepare = try await prepareKindleExplainPage(page: page, reason: reason, runID: runID, updatesStatus: true)
            guard isContinuousExplainActive(runID), !Task.isCancelled else { return }
            if didPrepare {
                scheduleContinuousExplainPrefetch(after: page.key, runID: runID)
            } else {
                appendLog("KINDLE explain empty page, requesting pipeline refill")
                await handleContinuousExplainQueueDrained(runID: runID)
            }
            continuousStatus = AppLocalized("Explaining Kindle page...")
        } catch {
            guard isContinuousExplainActive(runID) else { return }
            audio.moreSegmentsExpected = false
            continuousStatus = AppLocalized("Kindle explain failed: \(error.localizedDescription)")
            appendLog("KINDLE explain error \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func prepareKindleExplainPage(page: CapturedPage, reason: String, runID: UUID, updatesStatus: Bool) async throws -> Bool {
        guard isContinuousExplainActive(runID), !Task.isCancelled else { return false }
        let readable = page.document.readableParagraphs
        guard !readable.isEmpty else { return false }

        if updatesStatus {
            continuousStatus = AppLocalized("Planning Kindle explanation...")
        }
        let planBox = KindlePlanBlock0Box()
        let request = buildKindlePlanRequest(page: page)
        let done = try await QuickReadService.shared.extractPlan(
            request,
            onStage: { [weak self] stage in
                Task { @MainActor in
                    guard let self, self.isContinuousExplainActive(runID), updatesStatus else { return }
                    self.continuousStatus = self.friendlyKindleStage(stage)
                }
            },
            onBlock0: { block in
                planBox.set(block)
            }
        )
        guard isContinuousExplainActive(runID), !Task.isCancelled else { return false }
        guard let block0 = planBox.value else { throw QuickReadError.noBlock0 }
        let jobId = block0.job_id
        let language = block0.output_language ?? settings.explainLangOrNil ?? page.document.language
        let total = max(1, done.total_blocks ?? block0.total_blocks)
        appendLog("KINDLE explain plan reason=\(reason) key=\(page.key.prefix(8)) job=\(jobId) total=\(total) lang=\(language)")

        var pageNarrations: [String] = []
        for blockIndex in 0..<total {
            guard isContinuousExplainActive(runID), !Task.isCancelled else { return false }
            if updatesStatus {
                continuousStatus = AppLocalized("Preparing explanation \(blockIndex + 1)/\(total)...")
            }
            let section = blockIndex == 0
                ? block0.block_0
                : try await QuickReadService.shared.extractBlock(jobId: jobId, blockIdx: blockIndex)
            pageNarrations.append(section.text)
            let audioIndex = nextContinuousExplainAudioIndex()
            let block = try await prepareKindleExplainBlock(
                section: section,
                blockIndex: blockIndex,
                audioIndex: audioIndex,
                jobId: jobId,
                language: language,
                page: page
            )
            guard isContinuousExplainActive(runID), !Task.isCancelled else { return false }
            continuousExplainBlocks[block.audioIndex] = block
            for segment in block.segments {
                continuousSegmentPageKeys[segmentSignature(segment)] = page.key
                audio.loadSegment(segment)
            }
            appendLog("KINDLE explain block=\(blockIndex) audio=\(block.audioIndex) key=\(page.key.prefix(8)) segs=\(block.segments.count) marks=\(block.marks.count) dur=\(String(format: "%.2f", block.duration))")
        }

        guard isContinuousExplainActive(runID), !Task.isCancelled else { return false }
        continuousExplainPrevSummary = cleanedKindleSummary(done.page_summary)
            ?? makeKindleContinuitySummary(pageNarrations)
        continuousExplainedPageKeys.insert(page.key)
        appendLog("KINDLE explain summary key=\(page.key.prefix(8)) len=\(continuousExplainPrevSummary?.count ?? 0)")
        return true
    }

    private func isContinuousExplainActive(_ runID: UUID) -> Bool {
        isContinuousExplaining && continuousExplainRunID == runID
    }

    private func nextContinuousExplainAudioIndex() -> Int {
        let index = continuousExplainNextAudioIndex
        continuousExplainNextAudioIndex += 1
        return index
    }

    private func handleContinuousExplainQueueDrained(runID: UUID) async {
        guard isContinuousExplainActive(runID) else { return }
        let anchorKey = !continuousPlayingPageKey.isEmpty
            ? continuousPlayingPageKey
            : (activeContinuousPage?.key ?? "")
        guard !anchorKey.isEmpty else {
            continuousStatus = AppLocalized("Kindle page state is not ready.")
            audio.moreSegmentsExpected = false
            setContinuousIssue(
                kind: .sourceNotReady,
                title: AppLocalized("Kindle page is not ready"),
                message: AppLocalized("Open a Kindle book page, keep it visible for a moment, then retry."),
                canRetry: true
            )
            return
        }

        clearContinuousIssue()
        if continuousPrefetchTask != nil {
            continuousPendingPrefetch = (anchorKey, runID)
            continuousStatus = AppLocalized("Preparing more Kindle pages...")
            audio.moreSegmentsExpected = true
            appendLog("KINDLE explain queue drained while prefetch active after=\(anchorKey.prefix(8))")
            return
        }
        continuousStatus = AppLocalized("Loading more Kindle pages...")
        audio.moreSegmentsExpected = true
        let prepared = await prefetchExplainPagesAfter(
            anchorKey,
            targetAhead: continuousExplainPrefetchTarget,
            runID: runID
        )
        guard isContinuousExplainActive(runID) else { return }
        if prepared <= 0 {
            audio.moreSegmentsExpected = false
            continuousStatus = AppLocalized("Waiting for Kindle to load more pages.")
            setSourceBlockedIssue(mode: .explain, reason: continuousLastExplainSourceReason.isEmpty ? "no-candidates" : continuousLastExplainSourceReason)
        } else {
            clearContinuousIssue()
            continuousStatus = AppLocalized("Explaining Kindle page...")
        }
    }

    private func prepareKindleExplainBlock(
        section: QuickreadSection,
        blockIndex: Int,
        audioIndex: Int,
        jobId: String,
        language: String,
        page: CapturedPage
    ) async throws -> KindleExplainBlock {
        var segments: [AudioSegment] = []
        try await TTSService.shared.generateTTSForParagraph(
            paragraphIndex: audioIndex,
            text: section.text,
            voice: settings.voice(for: language),
            speed: 1.0,
            language: language
        ) { segment in
            segments.append(segment)
        }

        var timeline: [ComposeTimestamp] = []
        var offset = 0.0
        for segment in segments {
            let segTimestamps = segment.timestamps.isEmpty
                ? TTSService.shared.synthesizeTimestamps(text: segment.text, duration: kindleSegmentDuration(segment))
                : segment.timestamps
            for ts in segTimestamps {
                timeline.append(ComposeTimestamp(word: ts.word, start: ts.startTime + offset, end: ts.endTime + offset))
            }
            offset += kindleSegmentDuration(segment)
        }

        let duration = offset
        let composed = try? await QuickReadService.shared.composeBlock(
            jobId: jobId,
            blockIdx: blockIndex,
            timestamps: timeline,
            duration: duration
        )
        let timedMarks = ensureKindleMarkTiming(composed?.events ?? section.events, duration: duration)
        let marks = timedMarks.enumerated().compactMap { markIndex, event -> KindleExplainMark? in
            guard let resolved = resolveKindleMark(event: event, in: page.document) else { return nil }
            let seed = "\(page.key)-\(blockIndex)-\(markIndex)-\(event.action)-\(event.text ?? "")".stableSeed
            return KindleExplainMark(
                event: event,
                paragraphIndex: resolved.paragraphIndex,
                rects: resolved.rects,
                seed: seed
            )
        }
        appendLog("KINDLE explain prepare block=\(blockIndex) rawMarks=\((composed?.events ?? section.events).count) placed=\(marks.count) timeline=\(timeline.count)")
        return KindleExplainBlock(
            pageKey: page.key,
            pageTitle: page.title,
            index: blockIndex,
            audioIndex: audioIndex,
            segments: segments,
            marks: marks,
            duration: duration
        )
    }

    private func advanceContinuousExplainPage(runID: UUID) async {
        await handleContinuousExplainQueueDrained(runID: runID)
    }

    private func handleContinuousExplainSegmentChanged(_ segment: AudioSegment?) {
        guard isContinuousExplaining, let segment else { return }
        guard let block = continuousExplainBlocks[segment.paragraphIndex] else {
            appendLog("KINDLE explain segment missing block audio=\(segment.paragraphIndex)")
            return
        }

        let didPageSwitch = block.pageKey != continuousPlayingPageKey
        if didPageSwitch {
            continuousPlayingPageKey = block.pageKey
            nativePlaybackMarks = []
            if let page = continuousPreparedPages[block.pageKey] {
                activeContinuousPage = page
                audio.setBook(
                    id: "kindle-explain-\(page.key)",
                    title: page.title,
                    chapterTitle: AppLocalized("解读"),
                    coverUrl: nil
                )
                showNativePlaybackPage(page, paragraphIndex: -1, wordIndex: nil, reason: "explain-playback-switch")
            }
            appendLog("KINDLE explain playback page switch key=\(block.pageKey.prefix(8)) audio=\(block.audioIndex) block=\(block.index)")
            scheduleContinuousExplainPrefetch(after: block.pageKey, runID: continuousExplainRunID)
        }
    }

    private func scheduleContinuousExplainPrefetch(after pageKey: String, runID: UUID) {
        guard isContinuousExplainActive(runID), !pageKey.isEmpty else { return }
        if continuousPrefetchTask != nil {
            continuousPendingPrefetch = (pageKey, runID)
            appendLog("KINDLE explain prefetch busy after=\(pageKey.prefix(8)) pending=1")
            return
        }
        startContinuousExplainPrefetch(after: pageKey, runID: runID)
    }

    private func startContinuousExplainPrefetch(after pageKey: String, runID: UUID) {
        guard isContinuousExplainActive(runID), !pageKey.isEmpty else { return }
        guard ProManager.shared.isPro else {
            appendLog("KINDLE explain prefetch skip free-user after=\(pageKey.prefix(8))")
            return
        }
        audio.moreSegmentsExpected = true
        continuousPrefetchTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.prefetchExplainPagesAfter(
                pageKey,
                targetAhead: self.continuousExplainPrefetchTarget,
                runID: runID
            )
        }
    }

    @discardableResult
    private func prefetchExplainPagesAfter(_ pageKey: String, targetAhead: Int, runID: UUID) async -> Int {
        guard isContinuousExplainActive(runID), targetAhead > 0 else { return 0 }
        var preparedCount = 0
        defer {
            if isContinuousExplainActive(runID) {
                continuousPrefetchTask = nil
                if let pending = continuousPendingPrefetch, pending.runID == runID {
                    continuousPendingPrefetch = nil
                    if pending.pageKey != pageKey {
                        appendLog("KINDLE explain prefetch drain pending after=\(pending.pageKey.prefix(8))")
                        scheduleContinuousExplainPrefetch(after: pending.pageKey, runID: pending.runID)
                    }
                } else if continuousPendingPrefetch?.runID == runID {
                    continuousPendingPrefetch = nil
                }
            }
        }
        do {
            let discovery = await discoverSourceCandidates(after: pageKey, targetAhead: targetAhead, mode: .explain, runID: runID)
            guard isContinuousExplainActive(runID), !Task.isCancelled else { return preparedCount }
            let candidates = discovery.candidates
            guard !candidates.isEmpty else {
                audio.moreSegmentsExpected = false
                continuousLastExplainSourceReason = discovery.reason
                appendLog("KINDLE explain prefetch empty after=\(pageKey.prefix(8)) reason=\(discovery.reason)")
                return preparedCount
            }

            for key in candidates {
                guard isContinuousExplainActive(runID), !Task.isCancelled else { return preparedCount }
                if hasPreparedExplainAudio(for: key) || continuousPreparingPageKeys.contains(key) {
                    continue
                }
                continuousPreparingPageKeys.insert(key)
                do {
                    defer { continuousPreparingPageKeys.remove(key) }
                    let page: CapturedPage
                    if let cached = continuousPreparedPages[key] {
                        page = cached
                    } else {
                        page = try await captureLivePage(key: key, shouldCache: true)
                        guard isContinuousExplainActive(runID), !Task.isCancelled else { return preparedCount }
                        continuousPreparedPages[page.key] = page
                        appendLog("KINDLE explain prefetch page key=\(page.key.prefix(8)) paras=\(page.document.readableParagraphs.count) chars=\(page.document.fullText.count)")
                    }

                    let didPrepare = try await prepareKindleExplainPage(page: page, reason: "prefetch", runID: runID, updatesStatus: false)
                    guard isContinuousExplainActive(runID), !Task.isCancelled else { return preparedCount }
                    if didPrepare {
                        preparedCount += 1
                        continuousLastExplainSourceReason = ""
                        clearContinuousIssue()
                        appendLog("KINDLE explain prefetch ready key=\(page.key.prefix(8)) buffered=\(preparedCount)/\(targetAhead)")
                        if preparedCount >= targetAhead {
                            break
                        }
                    }
                }
            }
            audio.moreSegmentsExpected = false
            if preparedCount == 0 {
                appendLog("KINDLE explain prefetch no readable candidate after=\(pageKey.prefix(8))")
            } else {
                appendLog("KINDLE explain prefetch filled after=\(pageKey.prefix(8)) count=\(preparedCount)")
            }
            return preparedCount
        } catch {
            guard isContinuousExplainActive(runID) else { return preparedCount }
            audio.moreSegmentsExpected = false
            appendLog("KINDLE explain prefetch error \(error.localizedDescription)")
            setContinuousIssue(
                kind: .pageFailed,
                title: AppLocalized("Kindle page preparation failed"),
                message: error.localizedDescription,
                canRetry: true
            )
            return preparedCount
        }
    }

    private func hasPreparedExplainAudio(for pageKey: String) -> Bool {
        continuousExplainedPageKeys.contains(pageKey) || hasEnqueuedExplainAudio(for: pageKey)
    }

    private func hasEnqueuedExplainAudio(for pageKey: String) -> Bool {
        continuousExplainBlocks.values.contains { $0.pageKey == pageKey }
    }

    private func isKnownExplainPageKey(_ pageKey: String) -> Bool {
        guard !pageKey.isEmpty else { return false }
        return continuousExplainedPageKeys.contains(pageKey)
            || hasEnqueuedExplainAudio(for: pageKey)
            || continuousPreparingPageKeys.contains(pageKey)
    }

    private func liveExplainPrefetchCandidates(from keys: [String], after pageKey: String, limit: Int) -> [String] {
        orderedLiveCandidates(from: keys, after: pageKey, limit: limit) { key in
            isKnownExplainPageKey(key)
        }.keys
    }

    private func updateContinuousExplainMarks(time: Double) {
        guard isContinuousExplaining, let segment = audio.currentSegment else { return }
        let audioIndex = segment.paragraphIndex
        guard let block = continuousExplainBlocks[audioIndex] else { return }
        let offset = block.segments
            .prefix { $0.id != segment.id }
            .reduce(0.0) { $0 + kindleSegmentDuration($1) }
        let blockTime = offset + time
        var changed = false
        for (idx, mark) in block.marks.enumerated() {
            let at = mark.event.at ?? 0
            let key = "\(audioIndex)#\(idx)"
            if at <= blockTime + 0.05, !continuousFiredMarkKeys.contains(key) {
                continuousFiredMarkKeys.insert(key)
                changed = true
            }
        }
        if changed {
            renderContinuousExplainMarks()
        }
    }

    private func renderContinuousExplainMarks() {
        var items: [[String: Any]] = []
        var nativeMarks: [KindleProbeNativeMark] = []
        var latestParagraph = nativePlaybackParagraphIndex
        let currentPageKey = nativePlaybackPageKey
        for audioIndex in continuousExplainBlocks.keys.sorted() {
            guard let block = continuousExplainBlocks[audioIndex],
                  block.pageKey == currentPageKey else { continue }
            for (markIndex, mark) in block.marks.enumerated() where continuousFiredMarkKeys.contains("\(audioIndex)#\(markIndex)") {
                let id = "\(currentPageKey)#\(audioIndex)#\(markIndex)"
                nativeMarks.append(KindleProbeNativeMark(
                    id: id,
                    paragraphIndex: mark.paragraphIndex,
                    rectsNorm: mark.rects,
                    action: mark.event.action,
                    n: mark.event.n,
                    weight: mark.event.weight,
                    seed: mark.seed
                ))
                latestParagraph = mark.paragraphIndex
                for rect in mark.rects {
                    items.append([
                        "action": normalizedKindleMarkAction(mark.event.action),
                        "rect": [
                            "x": rect.origin.x,
                            "y": rect.origin.y,
                            "w": rect.width,
                            "h": rect.height
                        ]
                    ])
                }
            }
        }
        nativePlaybackMarks = nativeMarks
        if latestParagraph >= 0 {
            nativePlaybackParagraphIndex = latestParagraph
            nativePlaybackWordIndex = nil
        }

        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__crBgProbeShowOCRMarks && window.__crBgProbeShowOCRMarks(\(json))") { [weak self] value, error in
            Task { @MainActor in
                if let error {
                    self?.appendLog("KINDLE marks error \(error.localizedDescription)")
                } else if let result = value as? String, result != "ok" {
                    self?.appendLog("KINDLE marks \(result)")
                }
            }
        }
    }

    private func resolveKindleMark(event: QuickreadEvent, in document: ReadingDocument) -> KindleResolvedMark? {
        guard let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let hit = MarkAnchoring.locate(markText: text, in: document, near: nil),
              hit.paragraphIndex >= 0,
              hit.paragraphIndex < document.paragraphs.count else {
            return nil
        }
        let paragraph = document.paragraphs[hit.paragraphIndex]
        var indexes = OCRWordAligner.wordIndexes(overlapping: hit.range, in: paragraph)
        if indexes.count > 24 {
            indexes = Array(indexes.prefix(24))
            let markHash = KindleListeningAnchorResolver.pageTextHash(paragraphTexts: [text])
            appendLog("KINDLE mark clipped chars=\(text.count) hash=\(markHash.prefix(12)) words=24")
        }
        guard !indexes.isEmpty else { return nil }
        let rects = indexes.compactMap { idx -> CGRect? in
            guard idx >= 0, idx < paragraph.words.count else { return nil }
            return paragraph.words[idx].bboxNorm
        }
        let lineRects = groupKindleLineRects(rects)
        guard !lineRects.isEmpty else { return nil }
        return KindleResolvedMark(paragraphIndex: hit.paragraphIndex, rects: lineRects)
    }

    private func groupKindleLineRects(_ rects: [CGRect]) -> [CGRect] {
        let sorted = rects.sorted {
            if abs($0.midY - $1.midY) > 0.012 { return $0.midY > $1.midY }
            return $0.minX < $1.minX
        }
        var groups: [(midY: CGFloat, rect: CGRect)] = []
        for rect in sorted {
            if let last = groups.indices.last,
               abs(groups[last].midY - rect.midY) <= max(0.014, min(groups[last].rect.height, rect.height) * 0.85) {
                let merged = groups[last].rect.union(rect)
                groups[last] = (midY: (groups[last].midY + rect.midY) / 2, rect: merged)
            } else {
                groups.append((midY: rect.midY, rect: rect))
            }
        }
        return groups.map(\.rect)
    }

    private func ensureKindleMarkTiming(_ marks: [QuickreadEvent], duration: Double) -> [QuickreadEvent] {
        guard !marks.isEmpty else { return [] }
        return marks.enumerated().map { idx, mark in
            var m = mark
            if m.at == nil {
                m.at = duration * (Double(idx + 1) / Double(marks.count + 1))
            }
            return m
        }
    }

    private func buildKindlePlanRequest(page: CapturedPage) -> ExtractPlanRequest {
        let readable = page.document.readableParagraphs
        let fullText = readable.map(\.text).joined(separator: "\n\n")
        let paras = readable.map { QuickreadParagraphDTO(text: $0.text, type: quickreadType($0.type)) }
        return ExtractPlanRequest(
            source_url: page.document.sourceURL ?? urlString,
            title: page.title,
            lang: settings.explainLangOrNil,
            depth: settings.explainDepth,
            text: fullText,
            fullText: fullText,
            paragraphs: paras,
            prev_summary: continuousExplainPrevSummary,
            content_type: ExplainContentType.book.rawValue
        )
    }

    private func cleanedKindleSummary(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(900))
    }

    private func makeKindleContinuitySummary(_ narrations: [String]) -> String? {
        let text = narrations
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        return String(compact.suffix(900))
    }

    private func quickreadType(_ type: ReadingParagraphType) -> String {
        switch type {
        case .paragraph: return "paragraph"
        case .heading: return "heading"
        case .blockquote: return "blockquote"
        case .code: return "code"
        case .list: return "list"
        case .caption, .image: return "caption"
        }
    }

    private func kindleSegmentDuration(_ segment: AudioSegment) -> Double {
        if segment.duration > 0.01 { return segment.duration }
        return segment.timestamps.last?.endTime ?? 0
    }

    private func normalizedKindleMarkAction(_ action: String) -> String {
        switch action {
        case "circle": return "circle"
        case "highlight": return "highlight"
        default: return "underline"
        }
    }

    private func friendlyKindleStage(_ stage: String) -> String {
        switch stage {
        case "extract": return AppLocalized("Reading Kindle page...")
        case "compose": return AppLocalized("Preparing explanation...")
        default: return stage
        }
    }

    private func cache(_ page: CapturedPage) {
        guard !page.key.isEmpty else { return }
        guard !cachedPages.contains(where: { $0.key == page.key }) else {
            appendLog("KINDLE cache hit key=\(page.key.prefix(8))")
            return
        }
        cachedPages.append(KindleCachedPage(
            id: page.key,
            key: page.key,
            title: page.title,
            paragraphCount: page.document.paragraphs.count,
            charCount: page.document.fullText.count,
            capturedAt: Date(),
            document: page.document
        ))
        if cachedPages.count > 12 {
            cachedPages.removeFirst(cachedPages.count - 12)
        }
        appendLog("KINDLE cache add key=\(page.key.prefix(8)) total=\(cachedPages.count)")
    }

    private func captureCurrentImagePayload(maxWidth: Int, quality: Double) async throws -> [String: Any] {
        guard let webView else { throw CaptureError.webViewMissing }
        let js = """
        (function() {
          \(Self.bootstrapScript)
          if (!window.__crBgProbeImageSnapshot) {
            return JSON.stringify({ ok: false, reason: 'missing-snapshot' });
          }
          return window.__crBgProbeImageSnapshot(\(maxWidth), \(quality));
        })();
        """
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let raw = value as? String,
                    let data = raw.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continuation.resume(throwing: CaptureError.invalidPayload)
                    return
                }
                continuation.resume(returning: obj)
            }
        }
    }

    private func waitForCurrentImagePayload(maxWidth: Int, quality: Double, timeoutMs: Int = 5000) async throws -> [String: Any] {
        let started = Date()
        var lastPayload: [String: Any] = [:]
        while Date().timeIntervalSince(started) * 1000 < Double(timeoutMs) {
            let payload = try await captureCurrentImagePayload(maxWidth: maxWidth, quality: quality)
            if payload["ok"] as? Bool == true { return payload }
            lastPayload = payload
            let reason = payload["reason"] as? String ?? "?"
            appendLog("KINDLE capture wait reason=\(reason) held=\(payload["heldKeys"] as? Int ?? -1)")
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return lastPayload.isEmpty
            ? ["ok": false, "reason": "capture-timeout"]
            : lastPayload
    }

    private func waitForImagePayload(key: String, maxWidth: Int, quality: Double, timeoutMs: Int = 5000) async throws -> [String: Any] {
        let started = Date()
        var lastPayload: [String: Any] = [:]
        while Date().timeIntervalSince(started) * 1000 < Double(timeoutMs) {
            let payload = try await captureImagePayload(key: key, maxWidth: maxWidth, quality: quality)
            if payload["ok"] as? Bool == true { return payload }
            lastPayload = payload
            let reason = payload["reason"] as? String ?? "?"
            appendLog("KINDLE live capture wait key=\(key.prefix(8)) reason=\(reason) held=\(payload["heldKeys"] as? Int ?? -1)")
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return lastPayload.isEmpty
            ? ["ok": false, "reason": "capture-timeout", "key": key]
            : lastPayload
    }

    private func captureImagePayload(key: String, maxWidth: Int, quality: Double) async throws -> [String: Any] {
        guard let webView else { throw CaptureError.webViewMissing }
        let safeKey = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let js = """
        (function() {
          \(Self.bootstrapScript)
          if (!window.__crBgProbeImageSnapshotForKey) {
            return JSON.stringify({ ok: false, reason: 'missing-key-snapshot', key: "\(safeKey)" });
          }
          return window.__crBgProbeImageSnapshotForKey("\(safeKey)", \(maxWidth), \(quality));
        })();
        """
        return try await evaluateJSON(webView: webView, js: js)
    }

    private func liveKeysPayload() async throws -> [String: Any] {
        guard let webView else { throw CaptureError.webViewMissing }
        let js = """
        (function() {
          \(Self.bootstrapScript)
          if (!window.__crBgProbeLiveKeys) {
            return JSON.stringify({ ok: false, reason: 'missing-live-keys' });
          }
          return window.__crBgProbeLiveKeys();
        })();
        """
        return try await evaluateJSON(webView: webView, js: js)
    }

    private func currentBestKey() async throws -> String {
        let payload = try await statePayload()
        return payload["bestKey"] as? String ?? ""
    }

    private func statePayload() async throws -> [String: Any] {
        guard let webView else { throw CaptureError.webViewMissing }
        let js = """
        (function() {
          \(Self.bootstrapScript)
          if (!window.__crBgProbeState) return JSON.stringify({ ok: false, reason: 'missing-state' });
          return window.__crBgProbeState();
        })();
        """
        return try await evaluateJSON(webView: webView, js: js)
    }

    private func advanceUntilNewKey(previousKey: String) async throws -> String {
        guard let webView else { throw CaptureError.webViewMissing }
        var candidate = ""
        for attempt in 1...8 {
            let delta = 360 + attempt * 40
            let js = """
            (function() {
              \(Self.bootstrapScript)
              if (!window.__crBgProbeScroll) return JSON.stringify({ ok: false, reason: 'missing-scroll' });
              return window.__crBgProbeScroll(\(delta));
            })();
            """
            _ = try? await evaluateJSON(webView: webView, js: js)
            try await Task.sleep(nanoseconds: 650_000_000)
            let state = try await statePayload()
            candidate = state["bestKey"] as? String ?? ""
            let held = state["heldKeys"] as? Int ?? -1
            appendLog("KINDLE advance attempt=\(attempt) prev=\(previousKey.prefix(8)) best=\(candidate.prefix(8)) held=\(held)")
            if !candidate.isEmpty, candidate != previousKey {
                return candidate
            }
        }
        return candidate == previousKey ? "" : candidate
    }

    private func advanceUntilNewExplainKey(previousKey: String) async throws -> String {
        guard let webView else { throw CaptureError.webViewMissing }
        var candidate = ""
        for attempt in 1...10 {
            let delta = 380 + attempt * 60
            let js = """
            (function() {
              \(Self.bootstrapScript)
              if (!window.__crBgProbeScroll) return JSON.stringify({ ok: false, reason: 'missing-scroll' });
              return window.__crBgProbeScroll(\(delta));
            })();
            """
            _ = try? await evaluateJSON(webView: webView, js: js)
            try await Task.sleep(nanoseconds: 700_000_000)
            let state = try await statePayload()
            candidate = state["bestKey"] as? String ?? ""
            let held = state["heldKeys"] as? Int ?? -1
            let known = isKnownExplainPageKey(candidate)
            appendLog("KINDLE explain advance attempt=\(attempt) prev=\(previousKey.prefix(8)) best=\(candidate.prefix(8)) held=\(held) known=\(known)")
            if !candidate.isEmpty, candidate != previousKey, !known {
                return candidate
            }
        }
        return ""
    }

    private func evaluateJSON(webView: WKWebView, js: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let raw = value as? String,
                    let data = raw.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continuation.resume(throwing: CaptureError.invalidPayload)
                    return
                }
                continuation.resume(returning: obj)
            }
        }
    }

    private static func decodeDataURL(_ dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        return Data(base64Encoded: base64)
    }

    private static func stableImageKey(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for byte in data.prefix(4096) {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        hash ^= UInt64(data.count)
        return String(format: "ios%016llx", hash)
    }

    private func cleanKindleTitle(_ raw: String, key: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let badTitles = ["", "Kindle Cloud Reader", "Amazon Kindle", "Kindle"]
        let base = badTitles.contains(trimmed) ? "Kindle Page" : trimmed
        if key.isEmpty { return base }
        return "\(base) · \(String(key.prefix(8)))"
    }

    func handleScriptMessage(_ body: Any) {
        guard let raw = body as? String else {
            appendLog("js message non-string")
            return
        }
        appendProbePayload(raw, prefix: "JS")
    }

    private func installProbeIfNeeded() {
        webView?.evaluateJavaScript(Self.bootstrapScript) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.appendLog("install error \(error.localizedDescription)")
                } else {
                    self?.appendLog("install ok")
                }
            }
        }
    }

    private func startProbeScript() {
        let js = """
        (function() {
          \(Self.bootstrapScript)
          if (window.__crBgProbeStart) { window.__crBgProbeStart(); return 'started'; }
          return 'missing-start';
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] value, error in
            Task { @MainActor in
                if let error {
                    self?.appendLog("start script error \(error.localizedDescription)")
                } else {
                    self?.appendLog("start script \(String(describing: value))")
                }
            }
        }
    }

    private func nativeTick() {
        nativeTicks += 1
        if let scrollView = webView?.scrollView {
            let oldY = scrollView.contentOffset.y
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let newY = min(maxY, oldY + 160)
            if maxY > 0 {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newY), animated: false)
                appendLog("NATIVE UIScrollView y=\(Int(oldY))>\(Int(newY))/\(Int(scrollView.contentSize.height))")
            } else {
                appendLog("NATIVE UIScrollView no-scroll size=\(Int(scrollView.contentSize.width))x\(Int(scrollView.contentSize.height))")
            }
        }
        let js = "window.__crBgProbeScroll ? window.__crBgProbeScroll(120) : 'missing probe'"
        webView?.evaluateJavaScript(js) { [weak self] value, error in
            Task { @MainActor in
                if let error {
                    self?.appendLog("NATIVE tick \(self?.nativeTicks ?? 0) error \(error.localizedDescription)")
                } else if let raw = value as? String {
                    self?.appendProbePayload(raw, prefix: "NATIVE")
                } else {
                    self?.appendLog("NATIVE tick \(self?.nativeTicks ?? 0) value=\(String(describing: value))")
                }
            }
        }
    }

    private func appendProbePayload(_ raw: String, prefix: String) {
        guard
            let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            appendLog("\(prefix) \(raw)")
            return
        }
        let kind = obj["kind"] as? String ?? "?"
        let jsTicks = obj["jsTicks"] as? Int ?? -1
        let native = obj["nativeTicks"] as? Int ?? -1
        let y = obj["y"] as? Int ?? -1
        let h = obj["h"] as? Int ?? -1
        let ch = obj["ch"] as? Int ?? -1
        let target = obj["target"] as? String ?? "?"
        let tried = obj["tried"] as? String ?? ""
        let ready = obj["ready"] as? String ?? "?"
        let url = (obj["url"] as? String ?? "").replacingOccurrences(of: "https://", with: "")
        let blobImgs = obj["blobImgs"] as? Int ?? -1
        let blobLoaded = obj["blobLoaded"] as? Int ?? -1
        let heldKeys = obj["heldKeys"] as? Int ?? -1
        let bestKey = obj["bestKey"] as? String ?? ""
        let bestNat = obj["bestNat"] as? String ?? ""
        let bestBox = obj["bestBox"] as? String ?? ""
        let recentKeys = obj["recentKeys"] as? String ?? ""
        let imgRows = obj["imgRows"] as? String ?? ""
        let expectedKey = obj["expectedKey"] as? String ?? ""
        let beforeKey = obj["beforeKey"] as? String ?? ""
        let afterKey = obj["afterKey"] as? String ?? ""
        let reason = obj["reason"] as? String ?? ""
        let reverted = obj["reverted"] as? Bool ?? false
        let flow = expectedKey.isEmpty && beforeKey.isEmpty && afterKey.isEmpty && reason.isEmpty && !reverted
            ? ""
            : " flow=exp:\(expectedKey.prefix(8)) before:\(beforeKey.prefix(8)) after:\(afterKey.prefix(8)) rev:\(reverted) reason:\(reason)"
        if !bestKey.isEmpty {
            captureVisibleImageIfNeeded(bestKey)
        }
        appendLog("\(prefix) \(kind) js=\(jsTicks) native=\(native) y=\(y)/\(h) ch=\(ch) target=\(target.prefix(40)) img=\(blobLoaded)/\(blobImgs) held=\(heldKeys) best=\(bestKey.prefix(8)) \(bestNat) \(bestBox)\(flow) recent=\(recentKeys.prefix(48)) rows=\(imgRows.prefix(80)) tried=\(tried.prefix(60)) ready=\(ready) \(url.prefix(24))")
    }

    private func captureVisibleImageIfNeeded(_ key: String) {
        guard !capturedImageKeys.contains(key), !imageCaptureInFlight.contains(key) else { return }
        imageCaptureInFlight.insert(key)
        let js = "window.__crBgProbeImageSnapshot ? window.__crBgProbeImageSnapshot() : JSON.stringify({ok:false,reason:'missing-snapshot'})"
        webView?.evaluateJavaScript(js) { [weak self] value, error in
            Task { @MainActor in
                guard let self else { return }
                self.imageCaptureInFlight.remove(key)
                if let error {
                    self.appendLog("IMAGE capture error \(error.localizedDescription)")
                    return
                }
                guard
                    let raw = value as? String,
                    let data = raw.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.appendLog("IMAGE capture invalid payload")
                    return
                }
                guard obj["ok"] as? Bool == true else {
                    self.appendLog("IMAGE capture skipped \(obj["reason"] as? String ?? "?")")
                    return
                }
                let actualKey = obj["key"] as? String ?? key
                guard let dataURL = obj["thumb"] as? String,
                      let comma = dataURL.firstIndex(of: ",") else {
                    self.appendLog("IMAGE capture no thumb key=\(actualKey.prefix(8))")
                    return
                }
                let base64 = String(dataURL[dataURL.index(after: comma)...])
                guard let imageData = Data(base64Encoded: base64) else {
                    self.appendLog("IMAGE capture bad base64 key=\(actualKey.prefix(8))")
                    return
                }
                do {
                    let dir = self.logFileURL.deletingLastPathComponent().appendingPathComponent("kindle-probe-images")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let stamp = Self.fileTimestampFormatter.string(from: Date())
                    let safeKey = actualKey.isEmpty ? "nokey" : actualKey
                    let url = dir.appendingPathComponent("\(stamp)-\(safeKey.prefix(12)).jpg")
                    try imageData.write(to: url, options: .atomic)
                    self.capturedImageKeys.insert(actualKey)
                    self.appendLog("IMAGE saved key=\(actualKey.prefix(8)) natural=\(obj["natural"] as? String ?? "?") file=\(url.lastPathComponent)")
                } catch {
                    self.appendLog("IMAGE save error \(error.localizedDescription)")
                }
            }
        }
    }

    private func startAudioLoop() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            appendLog("audio session active")
        } catch {
            appendLog("audio session error \(error.localizedDescription)")
            return
        }
        do {
            let player = try AVAudioPlayer(data: Self.makeToneWav(), fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0.02
            player.prepareToPlay()
            let ok = player.play()
            audioPlayer = player
            appendLog("debug audio loop \(ok ? "ON" : "play returned false")")
        } catch {
            appendLog("audio player error \(error.localizedDescription)")
        }
    }

    private static func makeToneWav() -> Data {
        let sampleRate = 44_100
        let seconds = 1
        let samples = sampleRate * seconds
        let dataSize = samples * 2
        var data = Data()

        func appendString(_ s: String) {
            data.append(s.data(using: .ascii)!)
        }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendLE(UInt32(36 + dataSize))
        appendString("WAVE")
        appendString("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        appendString("data")
        appendLE(UInt32(dataSize))

        for i in 0..<samples {
            let phase = Double(i) / Double(sampleRate) * 2.0 * Double.pi * 220.0
            let sample = Int16(sin(phase) * 600.0)
            appendLE(sample)
        }
        return data
    }

    @objc private func appDidEnterBackground() {
        appendLog("APP didEnterBackground")
    }

    @objc private func appWillEnterForeground() {
        appendLog("APP willEnterForeground")
    }

    private var appStateText: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private var logFileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("kindle-background-probe.log")
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter
    }()

    private func resetLogFile() {
        let url = logFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let header = "CastReader Kindle WKWebView probe \(ISO8601DateFormatter().string(from: Date()))\n"
        try? Data(header.utf8).write(to: url, options: .atomic)
    }

    private func appendLogFileLine(_ line: String) {
        let url = logFileURL
        let data = Data((line + "\n").utf8)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) [\(appStateText)] \(message)"
        #if DEBUG
        NSLog("CRDBG WKProbe %@", line)
        print("CRDBG WKProbe \(line)")
        appendLogFileLine(line)
        #endif
        logLines.append(line)
        if logLines.count > 120 {
            logLines.removeFirst(logLines.count - 120)
        }
    }
}

private final class KindlePlanBlock0Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PlanBlock0?
    var value: PlanBlock0? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ value: PlanBlock0) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private struct KindleProbeWebView: UIViewRepresentable {
    @ObservedObject var model: KindleBackgroundProbeModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: KindleBackgroundProbeModel.messageHandler)
        controller.addUserScript(WKUserScript(
            source: KindleBackgroundProbeModel.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedToken != model.loadToken else { return }
        context.coordinator.loadedToken = model.loadToken
        guard let url = URL(string: model.urlString) else { return }
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var model: KindleBackgroundProbeModel?
        var loadedToken = -1

        init(model: KindleBackgroundProbeModel) {
            self.model = model
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            Task { @MainActor [weak self] in
                self?.model?.handleScriptMessage(message.body)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self] in
                self?.model?.appendLog("webView didFinish \(webView.url?.absoluteString ?? "")")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor [weak self] in
                self?.model?.appendLog("webView didFail \(error.localizedDescription)")
            }
        }
    }
}
#endif
