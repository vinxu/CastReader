import AVFoundation
import SwiftUI

private struct KindleOfflinePageZoom: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Canvas {
        let view = Canvas()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1; view.maximumZoomScale = 5
        view.backgroundColor = UIColor(AppTheme.background)
        view.accessibilityIdentifier = "offlineBookZoomCanvas"
        view.accessibilityValue = "100%"
        view.addSubview(view.imageView)
        view.imageView.image = image
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return view
    }
    func updateUIView(_ view: Canvas, context: Context) {
        if view.imageView.image !== image { view.imageView.image = image; view.setNeedsLayout() }
    }
    final class Canvas: UIScrollView {
        let imageView = UIImageView()
        private var viewport = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != viewport, bounds.width > 0, let image = imageView.image else { return }
            viewport = bounds.size
            setZoomScale(1, animated: false)
            imageView.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                     height: bounds.width * image.size.height / max(1, image.size.width))
            contentSize = imageView.frame.size
            contentOffset = .zero
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? Canvas)?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.accessibilityValue = "\(Int(scrollView.zoomScale * 100))%"
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? Canvas else { return }
            if view.zoomScale > 1.01 { view.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: view.imageView)
                let size = CGSize(width: view.bounds.width / 2.5, height: view.bounds.height / 2.5)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: true)
            }
        }
    }
}

@MainActor
struct KindleOfflineBookReaderView: View {
    @StateObject private var model: KindleOfflineBookReaderModel
    private let continueDownload: (() -> Void)?

    init(book: KindleOfflineBook, scope: String, store: KindleOfflineBookStore = .shared,
         scopeValidator: (@MainActor () -> Bool)? = nil, continueDownload: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            scopeValidator: scopeValidator))
        self.continueDownload = continueDownload
    }

    var body: some View {
        KindleOfflineBookReaderContent(model: model, speech: model.speech, continueDownload: continueDownload)
            .tint(AppTheme.primary)
            .environment(\.readerOfflineAction, nil)
            .environment(\.readerAppearanceSource, .text)
            .navigationTitle(model.book.title).navigationBarTitleDisplayMode(.inline)
            .task { await model.open() }
            .onDisappear { model.close() }
    }
}

@MainActor
private struct KindleOfflineBookReaderContent: View {
    @ObservedObject var model: KindleOfflineBookReaderModel
    @ObservedObject var speech: SystemSpeechPlaybackService
    let continueDownload: (() -> Void)?
    @ObservedObject private var appearance = ReaderAppearanceSettings.shared
    @ObservedObject private var network = NetworkReachability.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showVoicePicker = false
    @State private var showPagePicker = false
    @State private var pageInput = ""
    @State private var originalPage = false
    @State private var enlargedImage: UIImage?
    @State private var showImageZoom = false
    @State private var refocus = 0

    private var playing: Bool { model.preparingSpeech || speech.state == .speaking || speech.state == .preparing }
    private var hasText: Bool { model.document?.paragraphs.contains { $0.type.isReadable && !$0.text.isEmpty } == true }
    private var voiceName: String { model.voices.first(where: { $0.id == model.voiceID })?.name ?? "本机声音" }
    private var rateLabel: String { String(format: "%.1f×", model.speechRate / Double(AVSpeechUtteranceDefaultSpeechRate)) }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()
            readingBody
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            playbackBar
        }
        .background(AppTheme.background)
        .toolbar { ToolbarItem(placement: .primaryAction) { ReaderMoreButton() } }
        .environment(\.readerAppearanceSource, originalPage || !hasText ? .fixedLayout : .text)
        .sheet(isPresented: $showImageZoom) {
            NavigationStack {
                if let enlargedImage {
                    KindleOfflinePageZoom(image: enlargedImage)
                        .navigationTitle("原页面").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("关闭") { showImageZoom = false }.accessibilityIdentifier("offlineBookZoomClose")
                        } }
                }
            }
        }
        .sheet(isPresented: $showVoicePicker) { voicePicker }
        .sheet(isPresented: $showPagePicker) { pagePicker }
        .onChange(of: scenePhase) { _, phase in
            model.persistCurrentPosition()
            if phase == .active { refocus += 1 }
            saveDiagnostic()
        }
        .onChange(of: speech.state) { _, _ in saveDiagnostic() }
        .onChange(of: model.loading) { _, _ in saveDiagnostic() }
        .onChange(of: model.preparingSpeech) { _, _ in saveDiagnostic() }
        .onChange(of: speech.callbackCount) { _, count in if count % 10 == 0 { saveDiagnostic() } }
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: model.book.status == .complete ? "checkmark.circle" : "pause.circle")
                } else {
                    Label(model.book.status == .complete ? "整本离线" : "部分已保存", systemImage: "checkmark.circle")
                }
            }.font(.caption).foregroundStyle(AppTheme.primary)
                .accessibilityLabel(model.book.status == .complete ? "整本离线" : "部分已保存")
                .accessibilityIdentifier("offlineBookNetworkStatus")
            Spacer(minLength: 4)
            Button {
                pageInput = String(model.pageIndex + 1); showPagePicker = true
            } label: {
                Text(dynamicTypeSize.isAccessibilitySize ? "\(model.pageIndex + 1) / \(model.book.pages.count)" : "第 \(model.pageIndex + 1) / \(model.book.pages.count) 页")
                    .font(.subheadline.monospacedDigit()).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }.frame(minHeight: 44).disabled(model.loading || model.book.pages.isEmpty)
                .accessibilityLabel("第 \(model.pageIndex + 1) / \(model.book.pages.count) 页")
                .accessibilityIdentifier("offlineBookPageStatus")
        }.padding(.horizontal, 20).frame(minHeight: 44)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var readingBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.loading { ProgressView("正在读取本机页面…").frame(maxWidth: .infinity).padding(.top, 30) }
                    if let error = model.error {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                            Button(model.document == nil ? "重新读取本页" : "重试朗读") {
                                if model.document == nil { model.retryPage() } else { model.play() }
                            }.buttonStyle(.bordered).accessibilityIdentifier("offlineBookRetry")
                        }.foregroundStyle(.red).accessibilityElement(children: .contain).accessibilityIdentifier("offlineBookError")
                    }
                    if let document = model.document {
                        if hasText {
                            Picker("阅读显示", selection: $originalPage) {
                                Text("朗读文本").tag(false)
                                Text("原页面").tag(true)
                            }.pickerStyle(.segmented).accessibilityIdentifier("offlineBookDisplayMode")
                        }
                        if originalPage || !hasText {
                            savedImage(document)
                            if !hasText, !model.preparingSpeech {
                                Text("页面已保存在本机。点击播放即可离线识别并朗读。").font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(document.paragraphs.filter { $0.type != .image }) { paragraph in
                                Text(highlighted(paragraph))
                                    .font(.system(size: appearance.textSize, design: appearance.usesSerif ? .serif : .default))
                                    .lineSpacing(appearance.lineSpacing).id(paragraph.id)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("offlineBookParagraph.\(paragraph.id)")
                            }
                        }
                    }
                    if model.reachedSavedEnd || model.book.status != .complete && model.pageIndex + 1 == model.book.pages.count {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(model.book.status == .complete ? "已读完整本书" : "已到已保存内容的末尾",
                                  systemImage: model.book.status == .complete ? "checkmark.seal" : "arrow.down.circle")
                                .font(.headline)
                            if model.book.status != .complete {
                                Text("剩余页面尚未下载。联网继续保存后，可从这里接着读。").font(.footnote).foregroundStyle(.secondary)
                                if let continueDownload {
                                    Button("继续下载整本书") { model.pause(); continueDownload() }
                                        .buttonStyle(.borderedProminent).tint(AppTheme.primary)
                                        .accessibilityIdentifier("offlineBookContinueDownload")
                                }
                            } else {
                                Button("从第一页重新阅读") { model.selectPage(0) }.buttonStyle(.bordered)
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityElement(children: .contain).accessibilityIdentifier("offlineBookEnd")
                    }
                }.padding(20)
            }
            .id(model.pageIndex)
            .task(id: speech.highlightedParagraphID) {
                // A cached sentence can already be selected when this body
                // mounts. Restore its viewport as well as subsequent changes.
                await Task.yield()
                if !Task.isCancelled, scenePhase == .active, !originalPage,
                   let id = speech.highlightedParagraphID { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: originalPage) { _, showOriginal in if !showOriginal { refocus += 1 } }
            .onChange(of: refocus) { _, _ in
                if !originalPage, let id = speech.highlightedParagraphID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder private func savedImage(_ document: ReadingDocument) -> some View {
        if let image = model.pageImage {
            Button {
                model.pause(); enlargedImage = image; showImageZoom = true
            } label: { Label("放大原页面", systemImage: "plus.magnifyingglass") }
                .font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("offlineBookZoom")
            Image(uiImage: image).resizable().scaledToFit()
                .overlay {
                    GeometryReader { geometry in
                        let rects = originalHighlightRects(document, size: geometry.size)
                        ForEach(rects.indices, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 3).fill(.orange.opacity(0.4))
                                .frame(width: rects[index].width, height: rects[index].height)
                                .position(x: rects[index].midX, y: rects[index].midY)
                        }
                    }.allowsHitTesting(false)
                }
                .accessibilityLabel("已保存的第 \(model.pageIndex + 1) 页原图")
                .accessibilityIdentifier("offlineBookSavedImage")
        }
    }

    private var playbackBar: some View {
        VStack(spacing: 6) {
            Divider()
            if model.preparingSpeech {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在本机识别文字…") }
                    .font(.caption).padding(.top, 6).accessibilityIdentifier("offlineBookPreparing")
            } else if speech.errorCode != nil {
                Text("系统声音暂不可用，请切换本机声音后重试。").font(.caption).foregroundStyle(.red)
            } else {
                Text(dynamicTypeSize.isAccessibilitySize ? playbackStatus : "\(playbackStatus) · 本机朗读，无需网络")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.top, 6)
                    .accessibilityIdentifier("offlineBookSpeechStatus")
            }
            HStack(spacing: 0) {
                transport("上一页", icon: "chevron.left", id: "offlineBookPreviousPage", disabled: model.loading || model.pageIndex == 0) {
                    model.selectPage(model.pageIndex - 1)
                }
                Spacer(minLength: 0)
                transport("上一句", icon: "backward.end", id: "offlineBookPreviousSentence", disabled: speech.units.isEmpty || speech.currentUnitIndex == 0) {
                    model.pause(); speech.seek(to: speech.currentUnitIndex - 1, autoplay: false)
                }
                Spacer(minLength: 0)
                Button { if playing { model.pause() } else { model.play() } } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 58, height: 58).background(AppTheme.primary, in: Circle())
                }.disabled(model.loading || model.document == nil)
                    .accessibilityLabel(playing ? "暂停" : "播放").accessibilityIdentifier("offlineBookPlay")
                Spacer(minLength: 0)
                transport("下一句", icon: "forward.end", id: "offlineBookNextSentence", disabled: speech.units.isEmpty || speech.currentUnitIndex + 1 >= speech.units.count) {
                    model.pause(); speech.seek(to: speech.currentUnitIndex + 1, autoplay: false)
                }
                Spacer(minLength: 0)
                transport("下一页", icon: "chevron.right", id: "offlineBookNextPage", disabled: model.loading || model.pageIndex + 1 >= model.book.pages.count) {
                    model.selectPage(model.pageIndex + 1)
                }
            }.padding(.horizontal, 20)
            HStack {
                Button { showVoicePicker = true } label: {
                    if dynamicTypeSize.isAccessibilitySize { Image(systemName: "waveform").frame(width: 44, height: 44) }
                    else { Label(voiceName, systemImage: "waveform").lineLimit(1) }
                }.frame(minHeight: 44).accessibilityLabel("本机声音").accessibilityValue(voiceName)
                    .accessibilityIdentifier("offlineBookVoice")
                Spacer(minLength: 8)
                Button { refocus += 1 } label: { Image(systemName: "scope").frame(width: 44, height: 36) }
                    .accessibilityLabel("回到朗读位置").accessibilityIdentifier("offlineBookRefocus")
                Spacer(minLength: 8)
                Menu {
                    ForEach([0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65], id: \.self) { rate in
                        Button(String(format: "%.1f×", rate / Double(AVSpeechUtteranceDefaultSpeechRate))) { model.changeRate(rate) }
                    }
                } label: { Text(rateLabel).monospacedDigit().frame(minWidth: 44, minHeight: 36) }
                .accessibilityLabel("朗读速度").accessibilityValue(rateLabel).accessibilityIdentifier("offlineBookRate")
            }.font(.subheadline).padding(.horizontal, 24)
        }.padding(.bottom, 4).background(AppTheme.card).dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func transport(_ title: String, icon: String, id: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 20)).frame(width: 44, height: 48) }
            .disabled(disabled).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private var voicePicker: some View {
        NavigationStack {
            List {
                Section { Text("这些声音由本机系统提供。选择常规声音可获得更自然的离线朗读。").font(.footnote).foregroundStyle(.secondary) }
                if model.voices.isEmpty {
                    Text("本机尚无适合此书的声音，请联网准备系统声音后重新打开此书。")
                }
                ForEach(model.voices) { voice in
                    Button {
                        model.changeVoice(voice.id); showVoicePicker = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(voice.name); Text(voice.language).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if voice.id == model.voiceID { Image(systemName: "checkmark").foregroundStyle(AppTheme.primary) }
                        }
                    }
                }
            }.navigationTitle("本机声音").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showVoicePicker = false }.accessibilityIdentifier("offlineBookVoiceDone") } }
        }
    }

    private var pagePicker: some View {
        NavigationStack {
            Form {
                Section("跳转页码") {
                    TextField("页码", text: $pageInput).keyboardType(.numberPad).accessibilityIdentifier("offlineBookPageInput")
                    Text("可阅读第 1–\(model.book.pages.count) 页\(model.book.status == .complete ? "" : "，其余页面尚未下载")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("跳转") {
                    guard let page = Int(pageInput), (1...max(1, model.book.pages.count)).contains(page) else { return }
                    model.selectPage(page - 1); showPagePicker = false
                }.disabled(Int(pageInput).map { !(1...max(1, model.book.pages.count)).contains($0) } ?? true)
                    .accessibilityIdentifier("offlineBookPageGo")
            }.navigationTitle("跳转页码").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showPagePicker = false } } }
        }.presentationDetents([.medium, .large])
    }

    private var playbackStatus: String {
        switch speech.state {
        case .idle: return "点击播放开始朗读"
        case .preparing: return "正在准备声音"
        case .speaking: return "正在朗读"
        case .paused: return "已暂停"
        case .finished: return model.book.status == .complete && model.reachedSavedEnd ? "整本朗读完成" : "本页朗读完成"
        case .failed: return "播放失败"
        }
    }

    private func highlighted(_ paragraph: ReadingParagraph) -> AttributedString {
        var result = AttributedString(paragraph.text)
        guard paragraph.id == speech.highlightedParagraphID, let nsRange = speech.highlightRange,
              let range = Range(nsRange, in: paragraph.text),
              let start = AttributedString.Index(range.lowerBound, within: result),
              let end = AttributedString.Index(range.upperBound, within: result) else { return result }
        result[start..<end].backgroundColor = .orange.opacity(0.4)
        return result
    }

    private func originalHighlightRects(_ document: ReadingDocument, size: CGSize) -> [CGRect] {
        guard let index = document.paragraphs.firstIndex(where: { $0.id == speech.highlightedParagraphID }),
              let nsRange = speech.highlightRange else { return [] }
        let text = document.paragraphs[index].text
        guard let range = Range(nsRange, in: text) else { return [] }
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        return PhotoAnchorResolver(document: document, fitted: CGRect(origin: .zero, size: size))
            .rectsForCharRange(paragraphIndex: index, range: lower..<upper)
    }

    private func saveDiagnostic() {
        #if DEBUG
        let record: [String: Any] = ["version": 1, "bookID": model.book.id, "generation": model.book.generation.uuidString,
            "complete": model.book.status == .complete, "savedPages": model.book.pages.count,
            "page": model.pageIndex, "unit": speech.currentUnitIndex, "state": speech.state.rawValue,
            "rangeCallbacks": speech.callbackCount, "recognitionCount": model.recognitionCount,
            "preparingSpeech": model.preparingSpeech, "firstSpeechMilliseconds": speech.firstSpeechMilliseconds ?? -1,
            "voiceID": model.voiceID, "networkHint": network.isOnline,
            "scene": scenePhase == .active ? "active" : "background", "errorCode": speech.errorCode ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: root.appendingPathComponent("kindle-offline-book-speech.json"), options: .atomic)
        #endif
    }
}
