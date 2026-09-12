import SwiftUI

@MainActor
struct KindleOfflineDownloadView: View {
    @ObservedObject var model: KindleBookViewModel
    @ObservedObject var download: KindleOfflineDownloadCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.offlineSourceBook.title).font(.headline)
                    Text("将整本书的页面图片保存到这台 iPhone。保存后可以离线阅读；点击播放时，在手机本机准备并朗读文字，无需联网。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    if let book = download.book {
                        Label(book.status == .complete ? "整本已保存" : "整本下载尚未完成",
                              systemImage: book.status == .complete ? "checkmark.circle.fill" : "arrow.down.circle")
                        Text("已保存 \(book.pages.count) 页 · \(ByteCountFormatter.string(fromByteCount: Int64(book.byteCount), countStyle: .file))")
                            .accessibilityIdentifier("offlineDownloadProgress")
                        if book.status != .complete {
                            ProgressView(value: book.downloadFraction) {
                                Text(book.downloadFraction, format: .percent.precision(.fractionLength(0)))
                            }
                        }
                    }
                    if download.isRunning {
                        HStack { ProgressView(); Text(download.phase) }
                        Button("暂停下载") { download.pause() }.accessibilityIdentifier("offlineDownloadPause")
                    } else if download.book?.status != .complete {
                        Button(download.book?.pages.isEmpty == false ? "继续下载整本书" : "保存整本书到手机") {
                            guard let scope = KindleOfflineContext.currentScope,
                                  let boundary = AccountContentIsolation.captureBoundaryToken() else { return }
                            download.start(source: model, scope: scope) {
                                AccountContentIsolation.isCurrent(boundary) && KindleOfflineContext.currentScope == scope
                            }
                        }.accessibilityIdentifier("offlineDownloadStart")
                    }
                    if let error = download.error { Text(error).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    Text("下载时请保持此页面在前台。锁屏或退出会暂停，已保存内容会保留；回到这里可以继续。")
                }
                if let book = download.book, !book.pages.isEmpty, let scope = KindleOfflineContext.currentScope {
                    Section {
                        NavigationLink(book.status == .complete ? "打开离线书籍" : "阅读已保存内容") {
                            KindleOfflineBookReaderView(book: book, scope: scope, store: download.store)
                        }.accessibilityIdentifier("offlineDownloadOpenBook").disabled(download.isRunning)
                    }
                }
                Section {
                    NavigationLink("本机离线书籍") { KindleOfflineLibraryView() }.disabled(download.isRunning)
                }
            }
            .navigationTitle("离线保存整本书").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                if let scope = KindleOfflineContext.currentScope {
                    await download.refresh(sourceBookID: model.offlineSourceBook.id, scope: scope)
                }
            }
        }
        .onDisappear { download.pause() }
        .onChange(of: scenePhase) { if $0 != .active { download.pause() } }
        .interactiveDismissDisabled(download.isRunning)
    }
}
