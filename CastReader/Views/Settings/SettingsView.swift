//
//  SettingsView.swift
//  CastReader
//
//  设置：播放（语速/自动播放/自动滚动）、音色（按语言，Pro 锁）、解读（语言/深度）、外观（高亮色）、TTS 引擎、Pro。
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var quota = QuotaManager.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var showPaywall = false
    @State private var showLogin = false
    @State private var showClearHistory = false

    private let explainLanguages: [(String, String)] = [
        ("", String(localized: "跟随原文")), ("en", "English"), ("zh", "中文"), ("ja", "日本語"),
        ("es", "Español"), ("fr", "Français"), ("pt", "Português"), ("it", "Italiano"), ("hi", "हिन्दी")
    ]
    private let palette = ["#FD5F01", "#FFD400", "#34C759", "#0A84FF", "#FF2D55", "#AF52DE"]

    var body: some View {
        NavigationView {
            Form {
                accountSection
                proSection
                playbackSection
                voiceSection
                explainSection
                appearanceSection
                dataSection
                #if DEBUG
                debugSection
                #endif
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(isPresented: $showLogin) { LoginView() }
            .alert("清除全部历史记录？", isPresented: $showClearHistory) {
                Button("清除全部", role: .destructive) { HistoryStore.shared.clearAll() }
                Button("取消", role: .cancel) {}
            } message: { Text("将删除文库中全部本地历史，此操作不可撤销。") }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 账号

    @ViewBuilder
    private var accountSection: some View {
        Section("账号") {
            if let acc = auth.account {
                HStack(spacing: 12) {
                    avatar(acc)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(acc.displayName).font(.headline)
                        if let email = acc.email, !email.isEmpty {
                            Text(email).font(.caption).foregroundColor(AppTheme.mutedForeground)
                        }
                    }
                    Spacer()
                }
                Button(role: .destructive) { auth.signOut() } label: { Text("退出登录") }
            } else {
                Button { showLogin = true } label: {
                    Label("登录 / 注册", systemImage: "person.crop.circle")
                }
                Text("登录后 Pro 与额度跨设备同步")
                    .font(.caption2).foregroundColor(AppTheme.mutedForeground)
            }
        }
    }

    private func avatar(_ acc: UserAccount) -> some View {
        Group {
            if let s = acc.pictureURL, let url = URL(string: s) {
                CachedAsyncImage(url: url) { initialCircle(acc) }
            } else {
                initialCircle(acc)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private func initialCircle(_ acc: UserAccount) -> some View {
        ZStack {
            Circle().fill(AppTheme.primary.opacity(0.15))
            Text(acc.initial).font(.headline).foregroundColor(AppTheme.primary)
        }
    }

    // MARK: Pro

    private var proSection: some View {
        Section {
            NavigationLink {
                UpgradeView()
            } label: {
                HStack {
                    Image(systemName: pro.isPro ? "crown.fill" : "crown")
                        .foregroundColor(AppTheme.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(pro.isPro ? "CastReader Pro" : "升级到 Pro")).font(.headline)
                        if pro.isPro {
                            Text(LocalizedStringKey(pro.serverPlan == "yearly" ? "年度订阅" : (pro.serverPlan == "monthly" ? "月度订阅" : "已解锁")))
                                .font(.caption).foregroundColor(AppTheme.mutedForeground)
                        } else {
                            Text("今日朗读剩余 \(Int(quota.listenRemaining / 60)) 分钟 · 解读 \(quota.explainRemaining) 次")
                                .font(.caption).foregroundColor(AppTheme.mutedForeground)
                        }
                    }
                }
            }
            if pro.isPro {
                Button("管理订阅") { Task { await pro.openManageSubscriptions() } }
            }
        }
    }

    // MARK: 播放

    private var playbackSection: some View {
        Section("播放") {
            VStack(alignment: .leading) {
                HStack {
                    Text("语速")
                    Spacer()
                    Text(String(format: "%.2gx", settings.speed)).foregroundColor(AppTheme.mutedForeground)
                }
                Slider(value: Binding(
                    get: { settings.speed },
                    set: { newValue in
                        if !pro.isPro && newValue > AppSettings.freeMaxSpeed {
                            settings.speed = AppSettings.freeMaxSpeed
                            showPaywall = true
                        } else {
                            settings.speed = newValue
                        }
                    }), in: AppSettings.minSpeed...AppSettings.maxSpeed, step: 0.25)
                if !pro.isPro {
                    Text("免费版语速上限 2.0x").font(.caption2).foregroundColor(AppTheme.mutedForeground)
                }
            }
            Toggle("自动播放", isOn: $settings.autoPlay)
            Toggle("自动滚动", isOn: $settings.autoScroll)
        }
    }

    // MARK: 音色

    private var voiceSection: some View {
        Section("音色") {
            voicePicker(title: "英文", language: "en", selection: $settings.voiceEN)
            voicePicker(title: "中文", language: "zh", selection: $settings.voiceZH)
        }
    }

    private func voicePicker(title: LocalizedStringKey, language: String, selection: Binding<String>) -> some View {
        Menu {
            ForEach(VoiceCatalog.voices(for: language)) { v in
                Button {
                    if v.isPro && !pro.isPro { showPaywall = true }
                    else { selection.wrappedValue = v.code }
                } label: {
                    HStack {
                        Text(v.name)
                        if v.isPro && !pro.isPro { Image(systemName: "lock.fill") }
                        if selection.wrappedValue == v.code { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(VoiceCatalog.displayName(for: selection.wrappedValue))
                    .foregroundColor(AppTheme.mutedForeground)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundColor(AppTheme.mutedForeground)
            }
        }
    }

    // MARK: 解读

    private var explainSection: some View {
        Section("解读") {
            Picker("讲解语言", selection: $settings.explainLanguage) {
                ForEach(explainLanguages, id: \.0) { Text($0.1).tag($0.0) }
            }
            Picker("讲解深度", selection: $settings.explainDepth) {
                ForEach(QuickreadDepth.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: 外观

    private var appearanceSection: some View {
        Section("高亮颜色") {
            HStack(spacing: 14) {
                ForEach(palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hexString: hex))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(AppTheme.foreground, lineWidth: settings.highlightColorHex == hex ? 2 : 0))
                        .onTapGesture { settings.highlightColorHex = hex }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: 数据（历史管理——「清除全部」下沉到此，避免文库列表页误触）

    private var dataSection: some View {
        Section {
            Button(role: .destructive) { showClearHistory = true } label: {
                Label("清除全部历史记录", systemImage: "trash")
            }
        } header: {
            Text("数据")
        } footer: {
            Text("删除文库中全部本地历史。历史仅保存在本机，不会上传或同步到云端。")
        }
    }

    #if DEBUG
    // MARK: 调试（仅 DEBUG，发布构建不含）

    private var debugSection: some View {
        Section {
            Toggle("模拟 Pro 解锁", isOn: $pro.debugForcePro)
        } header: {
            Text("调试")
        } footer: {
            Text("开发期默认解锁全部能力。测试真实付费 / 跨平台权益时请关闭，并在 Xcode 中运行（StoreKit 本地配置才会生效）。")
        }
    }
    #endif
}
