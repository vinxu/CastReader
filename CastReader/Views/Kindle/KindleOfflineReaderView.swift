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
        view.imageView.contentMode = .scaleAspectFit
        view.imageView.isAccessibilityElement = true
        view.imageView.accessibilityTraits = .image
        view.imageView.accessibilityLabel = AppLocalized("原页面")
        view.imageView.accessibilityIdentifier = "offlineBookZoomImage"
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        if AdaptiveLayout.isPad {
            view.pinchGestureRecognizer?.addTarget(context.coordinator, action: #selector(Coordinator.recoverStalledPinch(_:)))
        }
        return view
    }
    func updateUIView(_ view: Canvas, context: Context) {
        if view.imageView.image !== image { view.replaceImage(image) }
    }
    final class Canvas: UIScrollView {
        let imageView = UIImageView()
        private var viewport = CGSize.zero
        private var isRelayingOut = false
        func replaceImage(_ image: UIImage) {
            setZoomScale(1, animated: false)
            imageView.image = image
            viewport = .zero
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !isRelayingOut, bounds.size != viewport, bounds.width > 0,
                  let image = imageView.image else { return }
            isRelayingOut = true
            defer { isRelayingOut = false }
            let hadLayout = viewport != .zero
            let zoom = zoomScale
            let center = CGPoint(x: (contentOffset.x + viewport.width / 2) / max(1, contentSize.width),
                                 y: (contentOffset.y + viewport.height / 2) / max(1, contentSize.height))
            viewport = bounds.size
            setZoomScale(1, animated: false)
            let fitted = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: bounds.size))
            imageView.frame = CGRect(origin: .zero, size: fitted.size)
            contentSize = fitted.size
            setZoomScale(zoom, animated: false)
            centerImage()
            let offset = hadLayout
                ? CGPoint(x: center.x * contentSize.width - bounds.width / 2,
                          y: center.y * contentSize.height - bounds.height / 2)
                : CGPoint(x: -contentInset.left, y: -contentInset.top)
            setClampedOffset(offset)
        }
        func setClampedOffset(_ point: CGPoint) {
            contentOffset = CGPoint(
                x: min(max(-contentInset.left, point.x), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
                y: min(max(-contentInset.top, point.y), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
        }
        func centerImage() {
            let horizontal = max(0, (bounds.width - contentSize.width) / 2)
            let vertical = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        private var startZoom: CGFloat = 1
        private var startScale: CGFloat = 1
        private var anchor = CGPoint.zero
        private var needsRecovery = false
        @objc func recoverStalledPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view as? Canvas else { return }
            if gesture.state == .began {
                startZoom = view.zoomScale
                startScale = max(0.001, gesture.scale)
                anchor = gesture.location(in: view.imageView)
                needsRecovery = false
            }
            guard gesture.state == .changed || gesture.state == .ended else { return }
            let factor = gesture.scale / startScale
            if !needsRecovery {
                guard abs(factor - 1) > 0.01, abs(view.zoomScale - startZoom) < 0.001 else { return }
                needsRecovery = true
            }
            let location = gesture.location(in: view)
            view.setZoomScale(min(view.maximumZoomScale, max(view.minimumZoomScale, startZoom * factor)), animated: false)
            let point = view.imageView.convert(anchor, to: view)
            view.setClampedOffset(CGPoint(x: view.contentOffset.x + point.x - location.x,
                                         y: view.contentOffset.y + point.y - location.y))
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? Canvas)?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? Canvas)?.centerImage()
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
    @ObservedObject var model: KindleOfflineBookReaderModel
    var continueDownload: (() -> Void)? = nil

    var body: some View {
        KindleOfflineBookReaderContent(model: model, speech: model.speech, continueDownload: continueDownload)
            .tint(AppTheme.primary)
            .environment(\.readerOfflineAction, nil)
            .environment(\.readerAppearanceSource, .text)
            .navigationTitle(model.book.title).navigationBarTitleDisplayMode(.inline)
            .onDisappear { model.persistCurrentPosition() }
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showVoicePicker = false
    @State private var showPagePicker = false
    @State private var showRatePicker = false
    @State private var pageInput = ""
    @State private var originalPage = false
    @State private var enlargedImage: UIImage?
    @State private var showImageZoom = false
    @State private var refocus = 0

    private var playing: Bool { model.canPausePlayback }
    private var hasText: Bool { model.document?.paragraphs.contains { $0.type.isReadable && !$0.text.isEmpty } == true }
    private var voiceName: String { model.voices.first(where: { $0.id == model.voiceID })?.name ?? AppLocalized("本机声音") }
    private var rateLabel: String { String(format: "%.1f×", locale: AppLanguageManager.shared.locale, model.speechRate / Double(AVSpeechUtteranceDefaultSpeechRate)) }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            if hasText {
                Picker("阅读显示", selection: $originalPage) {
                    Text("朗读文本").tag(false)
                    Text("原页面").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 8)
                    .accessibilityIdentifier("offlineBookDisplayMode")
            }
            Divider()
            readingBody.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.reachedSavedEnd || model.book.status != .complete && model.pageIndex + 1 == model.book.pages.count {
                savedEndNotice
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { playbackBar }
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
        .sheet(isPresented: $showRatePicker) { ratePicker }
        .onChange(of: scenePhase) { _, phase in
            model.persistCurrentPosition()
            if phase == .active { refocus += 1 }
            saveDiagnostic()
        }
        .onChange(of: speech.state) { _, _ in saveDiagnostic() }
        .onChange(of: speech.activeRate) { _, _ in saveDiagnostic() }
        .onChange(of: model.speechRate) { _, _ in saveDiagnostic() }
        .onChange(of: model.loading) { _, _ in saveDiagnostic() }
        .onChange(of: model.preparingSpeech) { _, _ in saveDiagnostic() }
        .onChange(of: speech.callbackCount) { _, count in if count % 10 == 0 { saveDiagnostic() } }
    }

    private var pageHeader: some View {
        HStack(spacing: 8) {
            Label(model.book.status == .complete ? AppLocalized("离线阅读") : AppLocalized("离线阅读 · 部分"), systemImage: "arrow.down.circle.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.primary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .accessibilityLabel(model.book.status == .complete ? Text("整本离线") : Text("部分已保存"))
                .accessibilityIdentifier("offlineBookNetworkStatus")
            Spacer(minLength: 4)
            Button {
                pageInput = String(model.pageIndex + 1); showPagePicker = true
            } label: {
                Text("\(model.pageIndex + 1) / \(model.book.pages.count)").monospacedDigit()
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.subheadline).frame(minHeight: 44)
                .disabled(model.loading || model.book.pages.isEmpty)
                .accessibilityLabel("第 \(model.pageIndex + 1) / \(model.book.pages.count) 页")
                .accessibilityIdentifier("offlineBookPageStatus")
            Button(action: openImageZoom) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
            }.disabled(model.pageImage == nil)
                .accessibilityLabel("放大原页面").accessibilityIdentifier("offlineBookZoom")
        }.padding(.leading, 16).padding(.trailing, 4)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var readingBody: some View {
        VStack(spacing: 8) {
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                    Button(model.document == nil ? AppLocalized("重新读取本页") : AppLocalized("重试朗读")) {
                        if model.document == nil { model.retryPage() } else { model.play() }
                    }.buttonStyle(.bordered).accessibilityIdentifier("offlineBookRetry")
                }.padding(16).foregroundStyle(.red)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("offlineBookError")
            }
            if model.loading {
                ProgressView("正在读取本机页面…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document = model.document {
                if originalPage || !hasText { savedImage(document) }
                else { textPage(document) }
            } else { Spacer(minLength: 0) }
        }
    }

    private func textPage(_ document: ReadingDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(document.paragraphs.filter { $0.type != .image }) { paragraph in
                        Text(highlighted(paragraph))
                            .font(.system(size: appearance.textSize, design: appearance.usesSerif ? .serif : .default))
                            .lineSpacing(appearance.lineSpacing).id(paragraph.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("offlineBookParagraph.\(paragraph.id)")
                    }
                }.padding(20)
                    .frame(maxWidth: AdaptiveLayout.isPad ? AdaptiveLayout.readingWidth : .infinity)
                    .frame(maxWidth: .infinity)
            }.id(model.pageIndex)
            .task(id: speech.highlightedParagraphID) {
                await Task.yield()
                if !Task.isCancelled, scenePhase == .active,
                   let id = speech.highlightedParagraphID { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: refocus) { _, _ in
                if let id = speech.highlightedParagraphID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var savedEndNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.book.status == .complete ? AppLocalized("已读完整本书") : AppLocalized("已到已保存内容的末尾"))
                .font(.subheadline.weight(.semibold))
            if model.book.status != .complete, let continueDownload {
                Button("继续下载整本书") { model.pause(); continueDownload() }
                    .buttonStyle(.bordered).tint(AppTheme.primary)
                    .accessibilityIdentifier("offlineBookContinueDownload")
            } else if model.book.status == .complete {
                Button("从第一页重新阅读") { model.selectPage(0) }.buttonStyle(.bordered)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.primary.opacity(0.06))
            .accessibilityElement(children: .contain).accessibilityIdentifier("offlineBookEnd")
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func openImageZoom() {
        guard let image = model.pageImage else { return }
        model.pause(); enlargedImage = image; showImageZoom = true
    }

    @ViewBuilder private func savedImage(_ document: ReadingDocument) -> some View {
        if let image = model.pageImage {
            GeometryReader { geometry in
                let available = CGRect(origin: .zero, size: CGSize(width: max(1, geometry.size.width - 24), height: max(1, geometry.size.height - 16)))
                let fitted = AVMakeRect(aspectRatio: image.size, insideRect: available)
                Image(uiImage: image).resizable().frame(width: fitted.width, height: fitted.height)
                    .overlay {
                        let rects = originalHighlightRects(document, size: fitted.size)
                        ForEach(rects.indices, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 3).fill(.orange.opacity(0.4))
                                .frame(width: rects[index].width, height: rects[index].height)
                                .position(x: rects[index].midX, y: rects[index].midY)
                        }
                    }
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .onTapGesture(perform: openImageZoom)
                    .accessibilityLabel("已保存的第 \(model.pageIndex + 1) 页原图")
                    .accessibilityIdentifier("offlineBookSavedImage")
            }
        }
    }

    private var playbackBar: some View {
        VStack(spacing: 2) {
            Divider()
            if model.preparingSpeech {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在本机识别文字…") }
                    .font(.caption).padding(.top, 6).accessibilityIdentifier("offlineBookPreparing")
            } else if speech.errorCode != nil {
                Text("系统声音暂不可用，请切换本机声音后重试。").font(.caption).foregroundStyle(.red)
            } else {
                Text(LocalizedStringKey(playbackStatus))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.top, 6)
                    .accessibilityIdentifier("offlineBookSpeechStatus")
                    .accessibilityValue(speech.activeRate.map { String(format: "%.1f×", locale: AppLanguageManager.shared.locale, $0 / AVSpeechUtteranceDefaultSpeechRate) } ?? "")
            }
            if verticalSizeClass == .compact {
                HStack(spacing: 8) {
                    transportControls
                    voiceButton
                    refocusButton
                    rateButton
                }.font(.subheadline).padding(.horizontal, 16)
            } else {
                transportControls.padding(.horizontal, 20)
                HStack {
                    voiceButton
                    Spacer(minLength: 8)
                    refocusButton
                    Spacer(minLength: 8)
                    rateButton
                }.font(.subheadline).padding(.horizontal, 24)
            }
        }.padding(.bottom, 4).background(AppTheme.card).dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var transportControls: some View {
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
                    .frame(width: 52, height: 52).background(AppTheme.primary, in: Circle())
            }.disabled((model.loading || model.document == nil) && !playing)
                .accessibilityLabel(playing ? Text("暂停") : Text("播放")).accessibilityIdentifier("offlineBookPlay")
            Spacer(minLength: 0)
            transport("下一句", icon: "forward.end", id: "offlineBookNextSentence", disabled: speech.units.isEmpty || speech.currentUnitIndex + 1 >= speech.units.count) {
                model.pause(); speech.seek(to: speech.currentUnitIndex + 1, autoplay: false)
            }
            Spacer(minLength: 0)
            transport("下一页", icon: "chevron.right", id: "offlineBookNextPage", disabled: model.loading || model.pageIndex + 1 >= model.book.pages.count) {
                model.selectPage(model.pageIndex + 1)
            }
        }
    }

    private var voiceButton: some View {
        Button { showVoicePicker = true } label: {
            if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact {
                Image(systemName: "waveform").frame(width: 44, height: 44)
            } else { Label(voiceName, systemImage: "waveform").lineLimit(1) }
        }.frame(minHeight: 44).accessibilityLabel("本机声音").accessibilityValue(voiceName)
            .accessibilityIdentifier("offlineBookVoice")
    }

    private var refocusButton: some View {
        Button { refocus += 1 } label: { Image(systemName: "scope").frame(width: 44, height: 44) }
            .accessibilityLabel("回到朗读位置").accessibilityIdentifier("offlineBookRefocus")
    }

    private var rateButton: some View {
        Button { showRatePicker = true } label: {
            Text(rateLabel).monospacedDigit().fontWeight(.semibold).frame(minWidth: 54, minHeight: 44)
                .background(AppTheme.primary.opacity(0.08), in: Capsule())
        }.accessibilityLabel("朗读速度").accessibilityValue(rateLabel).accessibilityIdentifier("offlineBookRate")
    }

    private func transport(_ title: String, icon: String, id: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 20)).frame(width: 44, height: 48) }
            .disabled(disabled).accessibilityLabel(LocalizedStringKey(title)).accessibilityIdentifier(id)
    }

    private var ratePicker: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(rateLabel).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Slider(value: Binding(get: { model.speechRate }, set: { model.changeRate($0) }), in: 0.3...0.65, step: 0.05)
                        .frame(minHeight: 44)
                        .accessibilityLabel("朗读速度").accessibilityIdentifier("offlineBookRateSlider")
                    HStack { Text("更慢"); Spacer(); Text("更快") }.font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                        ForEach([0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65], id: \.self) { rate in
                            let label = String(format: "%.1f×", locale: AppLanguageManager.shared.locale, rate / Double(AVSpeechUtteranceDefaultSpeechRate))
                            Button { model.changeRate(rate); showRatePicker = false } label: {
                                Text(label).frame(maxWidth: .infinity, minHeight: 48)
                                    .foregroundStyle(AppTheme.primary)
                                    .background(abs(model.speechRate - rate) < 0.001 ? AppTheme.primary.opacity(0.15) : AppTheme.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(abs(model.speechRate - rate) < 0.001 ? .isSelected : [])
                        }
                    }
                }.padding(20)
            }.navigationTitle("朗读速度").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showRatePicker = false }.accessibilityIdentifier("offlineBookRateDone")
                } }
        }.presentationDetents([.height(390), .large])
    }

    private var voicePicker: some View {
        NavigationStack {
            List {
                Section { Text("这些声音由本机系统提供。选择常规声音可获得更自然的离线朗读。").font(.footnote).foregroundStyle(.secondary) }
                if model.voices.isEmpty {
                    if speech.units.isEmpty {
                        Text("播放时会在本机识别文字并匹配朗读声音。")
                    } else {
                        Text("本机尚无适合此书的声音，请联网准备系统声音后重新打开此书。")
                    }
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
                    Text("可阅读第 1–\(model.book.pages.count) 页")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.book.status != .complete {
                        Text("其余页面尚未下载").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("跳转页码").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { showPagePicker = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("跳转") {
                            guard let page = Int(pageInput), (1...max(1, model.book.pages.count)).contains(page) else { return }
                            model.selectPage(page - 1); showPagePicker = false
                        }.disabled(Int(pageInput).map { !(1...max(1, model.book.pages.count)).contains($0) } ?? true)
                            .accessibilityIdentifier("offlineBookPageGo")
                    }
                }
        }.presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
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
            "documentLanguage": model.document?.language ?? "", "recognizedLanguage": model.book.recognizedLanguage ?? "",
            "highlightStart": speech.highlightRange?.location ?? -1, "highlightLength": speech.highlightRange?.length ?? 0,
            "selectedSpeechRate": model.speechRate, "activeSpeechRate": speech.activeRate ?? -1,
            "scene": scenePhase == .active ? "active" : "background", "errorCode": speech.errorCode ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: root.appendingPathComponent("kindle-offline-book-speech.json"), options: .atomic)
        #endif
    }
}
