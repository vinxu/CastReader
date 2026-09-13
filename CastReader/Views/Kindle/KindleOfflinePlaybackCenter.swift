import Combine
import SwiftUI

/// The session outlives every entry screen. Collapsing never opens a new model,
/// reloads OCR, claims audio again, or changes the sleep timer.
@MainActor
final class KindleOfflinePlaybackCenter: ObservableObject {
    static let shared = KindleOfflinePlaybackCenter()
    @Published private(set) var model: KindleOfflineBookReaderModel?
    @Published private(set) var isPresented = false
    var beforeOpen: (() -> Void)?
    private var store: KindleOfflineBookStore?
    private var scope: String?
    private var openTask: Task<Void, Never>?
    private var continueDownload: (() -> Void)?
    private var pendingDownload: (() -> Void)?
    var showsMiniPlayer: Bool { model != nil && !isPresented }

    func open(book: KindleOfflineBook, scope: String, store: KindleOfflineBookStore = .shared,
              scopeValidator: @escaping @MainActor () -> Bool,
              continueDownload: (() -> Void)? = nil,
              makeModel: (() -> KindleOfflineBookReaderModel)? = nil) {
        guard scopeValidator() else { return }
        if let model, self.store === store, self.scope == scope,
           model.book.id == book.id, model.book.generation == book.generation {
            self.continueDownload = continueDownload
            expand()
            return
        }
        stop(preservingSleepTimer: true)
        beforeOpen?()
        let next = makeModel?() ?? KindleOfflineBookReaderModel(book: book, scope: scope,
            store: store, scopeValidator: scopeValidator)
        self.store = store; self.scope = scope; self.continueDownload = continueDownload
        model = next; isPresented = true
        next.onClosed = { [weak self, weak next] in
            guard let self, let next, self.model === next else { return }
            self.stop(preservingSleepTimer: true)
        }
        openTask = Task { @MainActor [weak self, weak next] in
            guard let self, let next, self.model === next, !Task.isCancelled else { return }
            await next.open()
        }
    }

    func minimize() {
        guard let model else { return }
        model.persistCurrentPosition()
        isPresented = false
    }

    func expand() { guard model != nil else { return }; isPresented = true }

    func stop(preservingSleepTimer: Bool = false) {
        let previous = model
        model = nil; isPresented = false
        openTask?.cancel(); openTask = nil
        store = nil; scope = nil; continueDownload = nil; pendingDownload = nil
        previous?.onClosed = nil
        previous?.close()
        if previous != nil, !preservingSleepTimer { AudioPlayerService.shared.sleepTimer.endPlaybackSession() }
    }

    func resumeDownload() {
        let action = continueDownload
        stop(preservingSleepTimer: true)
        action?()
    }

    /// The presenting download sheet must finish dismissing before its Kindle
    /// owner is closed. The sheet's onDismiss consumes this one-shot route.
    func prepareAfterDownload(book: KindleOfflineBook, scope: String, store: KindleOfflineBookStore,
                              scopeValidator: @escaping @MainActor () -> Bool) {
        pendingDownload = { [weak self] in
            self?.open(book: book, scope: scope, store: store, scopeValidator: scopeValidator,
                continueDownload: {
                    guard scopeValidator(), let source = book.sourceBook else { return }
                    KindlePlaybackCenter.shared.openOfflineDownload(book: source)
                })
        }
    }

    func presentAfterDownload(continueDownload: (() -> Void)? = nil) {
        let action = pendingDownload; pendingDownload = nil
        action?()
        if action != nil, let continueDownload { self.continueDownload = continueDownload }
    }
}

@MainActor
struct KindleOfflinePlaybackSurface: View {
    @ObservedObject var center: KindleOfflinePlaybackCenter
    var body: some View {
        if let model = center.model {
            NavigationStack {
                KindleOfflineBookReaderView(model: model, continueDownload: center.resumeDownload)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(action: center.minimize) {
                                Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("收起阅读器")
                            .accessibilityHint("继续播放，在迷你播放器中控制朗读")
                            .accessibilityIdentifier("offlineBookClose")
                        }
                    }
            }
            .id(ObjectIdentifier(model))
            .background(AppTheme.background.ignoresSafeArea())
            .offset(y: center.isPresented ? 0 : UIScreen.main.bounds.height * 2)
            .allowsHitTesting(center.isPresented)
            .accessibilityHidden(!center.isPresented)
        }
    }
}

@MainActor
struct KindleOfflineMiniPlayer: View {
    @ObservedObject var center: KindleOfflinePlaybackCenter
    var body: some View {
        if let model = center.model {
            KindleOfflineMiniPlayerBar(model: model, speech: model.speech,
                expand: center.expand, stop: { center.stop() })
        }
    }
}

@MainActor
private struct KindleOfflineMiniPlayerBar: View {
    @ObservedObject var model: KindleOfflineBookReaderModel
    @ObservedObject var speech: SystemSpeechPlaybackService
    let expand: () -> Void
    let stop: () -> Void
    private var playing: Bool { model.preparingSpeech || speech.state == .preparing || speech.state == .speaking }
    var body: some View {
        HStack(spacing: 2) {
            Button(action: expand) {
                HStack(spacing: 10) {
                    KindleOfflineCoverImage(book: model.book, width: 32, height: 44, load: model.localCoverData)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("离线 · 第 \(model.pageIndex + 1) 页")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("offlineMiniExpand")
            Button { if playing { model.pause() } else { model.play() } } label: {
                if model.preparingSpeech || speech.state == .preparing {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 44, height: 44)
                }
            }.buttonStyle(.plain).disabled(model.loading)
                .accessibilityLabel(playing ? AppLocalized("暂停") : AppLocalized("播放"))
                .accessibilityIdentifier("offlineMiniPlay")
            Button(action: stop) {
                Image(systemName: "xmark").font(.body).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("停止朗读")
                .accessibilityIdentifier("offlineMiniStop")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.blue.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}
