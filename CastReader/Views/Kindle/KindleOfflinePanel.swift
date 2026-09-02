//
//  KindleOfflinePanel.swift
//  CastReader
//
//  Kindle-first UI for the provider-neutral offline reading package.
//

import SwiftUI

struct KindleOfflinePanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: KindleBookViewModel
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var network = NetworkReachability.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introCard

                    if let summary = model.offlineCacheSummary {
                        readyCard(summary)
                    }

                    if model.isOfflineCaching {
                        progressCard
                    }

                    if let error = model.offlineCacheError, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.destructive)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.destructive.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    actions
                }
                .padding(20)
            }
            .background(AppTheme.background)
            .navigationTitle(AppLocalized("离线朗读"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(AppTheme.primary)
                Text(AppLocalized("Pro 功能"))
                    .font(.subheadline.weight(.semibold))
            }
            Text(AppLocalized("缓存当前 Kindle 页面组"))
                .font(.headline)
            Text(AppLocalized("保存当前页和 Kindle 已准备的后续页面（最多 13 页），包括原页图片、文字位置和当前音色。下载不会自动翻书，也不会改变 Kindle 阅读进度。"))
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.border, lineWidth: 0.5))
    }

    private func readyCard(_ summary: OfflineReadingCacheSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AppLocalized("可以离线朗读"), systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(AppTheme.primary)
            HStack(spacing: 18) {
                metric(value: "\(summary.pageCount)", label: AppLocalized("页"))
                metric(value: "\(summary.readableParagraphCount)", label: AppLocalized("朗读段"))
                metric(value: Self.byteText(summary.byteSize), label: AppLocalized("空间"))
            }
            Text(AppLocalized("离线包使用下载时选择的音色；倍速可随时调整。更换音色需要联网重新下载。"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedForeground)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.offlineCacheStatusText)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int((model.offlineCacheProgress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedForeground)
            }
            ProgressView(value: model.offlineCacheProgress)
                .tint(AppTheme.primary)
            Text(AppLocalized("请保持此页面打开，iOS 暂不支持在锁屏后继续生成离线音频。"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedForeground)
        }
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var actions: some View {
        if model.isOfflinePlayback {
            Button {
                dismiss()
                model.exitOfflinePlayback()
            } label: {
                Label(AppLocalized("返回在线 Kindle"), systemImage: "wifi")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
            .disabled(model.isOfflineCaching || model.isOfflineRemoving)
            .disabled(!network.isOnline)
        } else if model.offlineCacheSummary != nil {
            Button {
                dismiss()
                model.openOfflinePackage(autoplay: false)
            } label: {
                Label(AppLocalized("打开离线版本"), systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
            .disabled(model.isOfflineCaching || model.isOfflineRemoving)
        }

        Button {
            guard pro.isPro else {
                dismiss()
                model.presentOfflineProPaywall()
                return
            }
            model.cacheCurrentKindlePageGroup()
        } label: {
            Label(
                model.offlineCacheSummary == nil ? AppLocalized("下载当前页面组") : AppLocalized("更新离线页面组"),
                systemImage: "arrow.down.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(
            model.isOfflineCaching || model.isOfflineRemoving
                || model.isOfflinePlayback || !network.isOnline
        )

        if model.offlineCacheSummary != nil {
            Button(role: .destructive) {
                model.removeOfflinePackage()
            } label: {
                Text(AppLocalized("删除离线内容"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(model.isOfflineCaching || model.isOfflineRemoving)
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(AppTheme.mutedForeground)
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
