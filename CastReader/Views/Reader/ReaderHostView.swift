//
//  ReaderHostView.swift
//  CastReader
//
//  阅读宿主：持有 ReadAloud / Explain 两个 VM，顶部切换「朗读 / 解读」，底部对应控制条。
//

import SwiftUI

enum ReaderMode: String, CaseIterable, Identifiable {
    case read = "朗读"
    case explain = "解读"
    var id: String { rawValue }
}

struct ReaderHostView: View {
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    @ObservedObject var coordinator: PlayerCoordinator
    let document: ReadingDocument

    private var mode: ReaderMode { coordinator.mode }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controls
        }
        .background(AppTheme.background.ignoresSafeArea())
        .onChange(of: coordinator.mode) { newMode in
            if newMode == .read {
                explainVM.deactivate()
                readVM.activate()       // 切回朗读：重新接管音频回调（onPlaybackComplete）
            } else {
                readVM.deactivate()
                explainVM.activate()    // 切到解读：接管音频回调
            }
        }
        // 收起阅读器（minimize）不停播放，由 Mini Player 接管；真正停止只在 Mini Player ✕（coordinator.close）。
        .sheet(isPresented: paywallBinding) { PaywallView() }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Button { coordinator.minimize() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.foreground)
            }
            Text(document.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundColor(AppTheme.foreground)
            Spacer(minLength: 8)
            Picker("", selection: $coordinator.mode) {
                ForEach(ReaderMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch document.sourceKind {
        case .web, .docx, .epub:
            WebReaderView(document: document, readVM: readVM, explainVM: explainVM, mode: mode)
        case .pdf:
            PDFReaderView(document: document, readVM: readVM, explainVM: explainVM, mode: mode)
        case .photo:
            PhotoReaderCanvas(document: document, readVM: readVM, explainVM: explainVM, mode: mode)
        case .text:
            TextReaderView(document: document, readVM: readVM, explainVM: explainVM, mode: mode)
        }
    }

    // MARK: 控制条

    @ViewBuilder
    private var controls: some View {
        if mode == .read {
            ReadControlBar(vm: readVM)
        } else {
            ExplainControlBar(vm: explainVM)
        }
    }

    private var paywallBinding: Binding<Bool> {
        Binding(
            get: { readVM.showPaywall || explainVM.showPaywall },
            set: { newValue in
                if !newValue { readVM.showPaywall = false; explainVM.showPaywall = false }
            }
        )
    }
}

// MARK: - 朗读控制条

private struct ReadControlBar: View {
    @ObservedObject var vm: ReadAloudViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 24) {
            Button { vm.skipBackward() } label: {
                Image(systemName: "gobackward.15").font(.system(size: 20))
            }
            Button { vm.togglePlayPause() } label: {
                Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(AppTheme.primary)
            }
            Button { vm.skipForward() } label: {
                Image(systemName: "goforward.15").font(.system(size: 20))
            }
            Spacer()
            Menu {
                ForEach(AudioPlayerService.speedOptions, id: \.self) { s in
                    Button {
                        vm.setSpeed(Double(s))
                    } label: {
                        Text(String(format: "%.2gx", s)) + Text(abs(Double(s) - settings.speed) < 0.01 ? "  ✓" : "")
                    }
                }
            } label: {
                Text(String(format: "%.2gx", settings.speed))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(AppTheme.surfaceVariant)
                    .cornerRadius(8)
            }
        }
        .foregroundColor(AppTheme.foreground)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}
