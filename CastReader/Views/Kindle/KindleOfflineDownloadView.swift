import SwiftUI

@MainActor
struct KindleOfflineDownloadView: View {
    @ObservedObject var model: KindleBookViewModel
    @ObservedObject var download: KindleOfflineDownloadCoordinator
    #if DEBUG
    var fixtureStart: (() -> Void)? = nil
    var fixtureScope: String? = nil
    #endif
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmStop = false
    @State private var closeAfterStopping = false

    private var scope: String? {
        #if DEBUG
        if let fixtureScope { return fixtureScope }
        #endif
        return KindleOfflineContext.currentScope
    }

    private var complete: Bool { download.book?.status == .complete && !download.isRunning }
    private var fraction: Double { complete ? 1 : min(0.99, download.book?.downloadFraction ?? 0) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text(model.offlineSourceBook.title)
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        .padding(.horizontal)
                    progressCard
                    if let error = download.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("offlineDownloadError")
                    }
                    if scope == nil {
                        Text("请先连接 Kindle 账号，再保存这本书。").font(.footnote).foregroundStyle(.secondary)
                    }
                    if !complete { foregroundNotice }
                }.padding(24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    Divider()
                    controls
                    if !download.isRunning { localReadingLinks }
                }.padding(.horizontal, 24).padding(.bottom, 12)
                    .frame(maxWidth: .infinity).background(AppTheme.background)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .background(AppTheme.background)
            .navigationTitle("保存整本书").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { requestStop(closing: true) } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
                    }.accessibilityLabel("关闭下载")
                        .accessibilityIdentifier("offlineDownloadClose")
                        .disabled(download.isStopping || download.activity == .restoring)
                }
            }
            .task {
                if let scope {
                    await download.refresh(sourceBookID: model.offlineSourceBook.id, scope: scope)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(download.isRunning)
        .alert("停止下载？", isPresented: $confirmStop) {
            Button("继续下载", role: .cancel) {}
            Button(closeAfterStopping ? AppLocalized("停止并关闭") : AppLocalized("取消本次下载"), role: .destructive) {
                let closing = closeAfterStopping
                Task { @MainActor in
                    await download.stopAndWait(reason: closing ? .closing : .user)
                    // A failed position restoration remains visible before exit.
                    if closing, download.error == nil { dismiss() }
                }
            }
        } message: {
            Text("已保存的页面会保留，下次可以继续。停止后会先恢复原阅读位置。")
        }
        .onDisappear { download.pause(reason: .closing) }
        .onChange(of: scenePhase) {
            if $0 != .active {
                confirmStop = false
                download.pause(reason: .background)
            }
        }
    }

    private var progressCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(AppTheme.primary.opacity(0.12), lineWidth: 7)
                Circle().trim(from: 0, to: fraction)
                    .stroke(AppTheme.primary, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
                Image(systemName: complete ? "checkmark" : download.isRunning ? "arrow.triangle.2.circlepath" : "book.closed")
                    .font(.system(size: 36, weight: .medium)).foregroundStyle(AppTheme.primary)
                    .symbolEffect(.pulse, options: .repeating, isActive: download.isRunning && !reduceMotion)
            }.frame(width: 112, height: 112).padding(.top, 8).accessibilityHidden(true)
            Text(LocalizedStringKey(statusTitle)).font(.title3.weight(.semibold))
                .accessibilityIdentifier("offlineDownloadStatus")
            if let book = download.book {
                VStack(spacing: 8) {
                    ProgressView(value: fraction).tint(AppTheme.primary)
                        .accessibilityIdentifier("offlineDownloadProgressBar")
                    HStack {
                        Text("已保存 \(book.pages.count) 页")
                        Spacer()
                        Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }.font(.subheadline)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(book.byteCount), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("offlineDownloadProgress")
            }
            if download.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(download.phase).lineLimit(2)
                }.font(.footnote).foregroundStyle(.secondary)
                if !download.isStopping, download.activity == .saving || download.activity == .preparing {
                    Text(remainingTime).font(.subheadline).monospacedDigit()
                        .accessibilityIdentifier("offlineDownloadEstimate")
                }
            } else {
                Text(complete ? AppLocalized("整本已保存到这台设备，可离线阅读和朗读。") : download.book?.lastError ?? AppLocalized("保存整本书的页面图片，朗读时再在本机识别文字。"))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(24).frame(maxWidth: .infinity)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var controls: some View {
        if download.isRunning {
            Button(download.activity == .restoring ? AppLocalized("正在恢复阅读位置…") : download.isStopping ? AppLocalized("正在停止下载…") : AppLocalized("取消下载")) {
                requestStop(closing: false)
            }.buttonStyle(.bordered).controlSize(.large)
                .disabled(download.isStopping || download.activity == .restoring)
                .accessibilityIdentifier("offlineDownloadCancel")
        } else if !complete {
            Button(download.book?.pages.isEmpty == false ? AppLocalized("继续下载整本书") : AppLocalized("开始保存整本书")) {
                #if DEBUG
                if let fixtureStart { fixtureStart(); return }
                #endif
                guard let scope,
                      let boundary = AccountContentIsolation.captureBoundaryToken() else { return }
                download.start(source: model, scope: scope) {
                    AccountContentIsolation.isCurrent(boundary) && KindleOfflineContext.currentScope == scope
                }
            }.buttonStyle(.borderedProminent).tint(AppTheme.primary).controlSize(.large)
                .disabled(scope == nil)
                .accessibilityIdentifier("offlineDownloadStart")
        }
    }

    private var foregroundNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("请保持此页面打开", systemImage: "iphone")
                .font(.subheadline.weight(.medium))
            Text("保存期间屏幕会保持唤醒，阅读操作暂时锁定。请不要锁屏或切到其他 App；离开后会暂停，已保存页面不会丢失。")
                .font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var localReadingLinks: some View {
        if let book = download.book, !book.pages.isEmpty, scope != nil {
            Button(book.status == .complete ? AppLocalized("打开离线书籍") : AppLocalized("阅读已保存内容")) {
                guard let scope else { return }
                KindleOfflinePlaybackCenter.shared.prepareAfterDownload(book: book, scope: scope,
                    store: download.store, scopeValidator: { scope == self.scope })
                dismiss()
            }
                .buttonStyle(.borderedProminent).tint(AppTheme.primary).controlSize(.large)
                .accessibilityIdentifier("offlineDownloadOpenBook")
        }
        Text("以后可从首页“已下载”直接打开，无需等待 Kindle 加载。")
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    private var statusTitle: String {
        if download.isStopping { return "正在停止下载" }
        if download.isRunning {
            switch download.activity {
            case .preparing: return "准备保存"
            case .verifying: return "正在检查完整性"
            case .restoring: return "正在恢复阅读位置"
            default: return "正在保存整本书"
            }
        }
        if complete { return "整本已保存" }
        if download.book?.pages.isEmpty == false { return "已保留下载进度" }
        return "将这本书带到离线"
    }

    private var remainingTime: String {
        guard let seconds = download.estimatedRemainingSeconds else { return AppLocalized("正在估算剩余时间…") }
        if seconds < 60 { return AppLocalized("预计还需约 \(seconds) 秒") }
        let minutes = seconds / 60, remainder = seconds % 60
        return remainder == 0 ? AppLocalized("预计还需约 \(minutes) 分钟") : AppLocalized("预计还需约 \(minutes) 分 \(remainder) 秒")
    }

    private func requestStop(closing: Bool) {
        guard download.isRunning else { if closing { dismiss() }; return }
        guard !download.isStopping, download.activity != .restoring else { return }
        closeAfterStopping = closing
        confirmStop = true
    }
}
