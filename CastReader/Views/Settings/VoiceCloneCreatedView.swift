import SwiftUI

@MainActor
struct VoiceCloneCreatedView: View {
    let language: String
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var store = VoiceCloneStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var previewPlayer = VoiceClonePreviewPlayer.shared
    @State private var showLogin = false
    @State private var showPaywall = false
    @State private var showCreation = false
    @State private var pendingDelete: ClonedVoice?
    @State private var sessionReady = false

    var body: some View {
        Group {
            if !auth.isSignedIn {
                gate(title: "登录后创建声音", detail: "声音克隆需要安全的账号会话。", action: "登录") { showLogin = true }
            } else if !pro.serverPro {
                gate(title: "声音克隆需要 Pro", detail: "升级后可创建，并为中文或英语选择自己的声音。", action: "查看 Pro") { showPaywall = true }
            } else if !sessionReady {
                gate(title: "重新登录以启用声音克隆", detail: "需要建立安全的 CastReader 移动会话。", action: "重新登录") { showLogin = true }
            } else if store.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Button { beginCreation() } label: {
                            Label("创建新声音", systemImage: "mic.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.disabled(!store.canCreateNow)
                    } footer: {
                        if let next = store.nextCreateAt, next > Date() {
                            Text("下次可创建时间：\(next.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    Section("我的声音") {
                        if store.voices.isEmpty { Text("还没有创建的声音").foregroundStyle(.secondary) }
                        ForEach(store.voices) { voice in cloneRow(voice) }
                    }
                }.listStyle(.plain)
            }
        }
        .task(id: auth.isSignedIn) {
            guard auth.isSignedIn else { return }
            await pro.refreshServer()
            if pro.serverPro {
                sessionReady = await auth.ensureMobileSessionForVoiceClone()
                if sessionReady { await store.refresh() }
            }
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        .onChange(of: showLogin) { presented in
            guard !presented, auth.isSignedIn else { return }
            Task {
                sessionReady = await auth.ensureMobileSessionForVoiceClone()
                if sessionReady { await store.refresh() }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(analyticsTrigger: "voice_clone", analyticsSurface: "voice_clone")
        }
        .sheet(isPresented: $showCreation) { VoiceCloneCreationView(initialLanguage: language) }
        .alert("删除这个声音？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                guard let voice = pendingDelete else { return }
                pendingDelete = nil
                Task { await store.delete(voice) }
            }
        } message: { Text("删除后将无法继续使用这个声音。") }
        .alert("声音克隆", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func cloneRow(_ voice: ClonedVoice) -> some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(AppTheme.primary.opacity(0.14)).frame(width: 48, height: 48)
                Image(systemName: previewPlayer.playingVoiceId == voice.voiceId ? "waveform" : "mic.fill")
                    .foregroundStyle(AppTheme.primary)
                    .symbolEffect(.variableColor.iterative, isActive: previewPlayer.playingVoiceId == voice.voiceId)
                Button {
                    previewPlayer.toggle(voice, language: language)
                } label: {
                    ZStack {
                        Circle().fill(previewPlayer.playingVoiceId == voice.voiceId ? AppTheme.primary : AppTheme.surface)
                        if previewPlayer.loadingVoiceId == voice.voiceId {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: previewPlayer.playingVoiceId == voice.voiceId ? "stop.fill" : "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(previewPlayer.playingVoiceId == voice.voiceId ? .white : AppTheme.primary)
                        }
                    }
                    .frame(width: 23, height: 23)
                    .overlay(Circle().stroke(AppTheme.background, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(
                    previewPlayer.playingVoiceId == voice.voiceId ? "停止试听" : "试听"
                )))
            }

            Button {
                Task { await store.select(voice, for: language) }
            } label: {
                HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.displayName(for: voice)).font(.headline)
                        .foregroundStyle(AppTheme.foreground)
                    Text(cloneMetadata(voice)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settings.activeClonedVoiceID(for: language) == voice.voiceId {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.primary)
                }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = voice }
            } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
        }
        .disabled(store.deletingVoiceId != nil)
    }

    private func cloneMetadata(_ voice: ClonedVoice) -> String {
        let reference = store.referenceLanguage(for: voice)
        let recording = reference == "zh" ? AppLocalized("中文录制") :
            (reference == "en" ? AppLocalized("英语录制") : AppLocalized("多语言"))
        let target = language == "zh" ? AppLocalized("用于中文") : AppLocalized("用于英语")
        return "\(recording) · \(target)"
    }

    private func gate(title: LocalizedStringKey, detail: LocalizedStringKey, action: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "waveform.badge.mic")
        } description: { Text(detail) } actions: {
            Button(action, action: perform).buttonStyle(.borderedProminent).tint(AppTheme.primary)
        }
    }

    private func beginCreation() {
        guard auth.isSignedIn else { showLogin = true; return }
        guard pro.serverPro else { showPaywall = true; return }
        guard store.canCreateNow else {
            store.errorMessage = VoiceCloneError.creationLimit(store.nextCreateAt).localizedDescription
            return
        }
        Task {
            guard await auth.ensureMobileSessionForVoiceClone() else {
                store.errorMessage = VoiceCloneError.sessionUnavailable.localizedDescription
                return
            }
            showCreation = true
        }
    }
}

@MainActor
private struct VoiceCloneCreationView: View {
    let initialLanguage: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceCloneRecorder()
    @ObservedObject private var store = VoiceCloneStore.shared
    @State private var consent = false
    @State private var recordingLanguage: String

    init(initialLanguage: String) {
        self.initialLanguage = initialLanguage
        _recordingLanguage = State(initialValue: VoiceBrowserLanguage.primary.contains(initialLanguage) ? initialLanguage : "en")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("录音语言", selection: $recordingLanguage) {
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                    .disabled(recorder.state == .recording || recorder.state == .recorded || recorder.state == .playing)
                    Text("请自然朗读下面这段话").font(.headline)
                    Text(recordingScript)
                        .padding(16).background(AppTheme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button(action: recordAction) {
                            Label(recordTitle, systemImage: recorder.state == .recording ? "stop.fill" : "mic.fill")
                        }.buttonStyle(.borderedProminent).tint(AppTheme.primary)
                        if recorder.state == .recorded || recorder.state == .playing {
                            Button(action: recorder.togglePlayback) {
                                Label(
                                    LocalizedStringKey(recorder.state == .playing ? "停止试听" : "试听"),
                                    systemImage: recorder.state == .playing ? "stop.circle" : "play.circle"
                                )
                            }
                            Button("重录", action: recorder.replaceRecording)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(recorder.duration, 30), total: 30)
                        Text("\(recorder.duration, specifier: "%.1f") 秒 · 需 3–30 秒 · 不超过 4 MB")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("我确认这是我本人的声音，并授权 CastReader 用它生成语音。", isOn: $consent)
                    if store.isCreating { ProgressView(value: store.uploadProgress) { Text("正在创建声音") } }
                    if let error = recorder.errorMessage { Text(error).font(.caption).foregroundStyle(AppTheme.destructive) }
                    Button { submit() } label: { Text("创建声音").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(AppTheme.primary)
                        .disabled(!recorder.canSubmit || !consent || store.isCreating)
                }.padding()
            }
            .navigationTitle("创建声音").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .interactiveDismissDisabled(store.isCreating)
        }
    }

    private var recordTitle: LocalizedStringKey { recorder.state == .recording ? "停止录音" : "开始录音" }
    private var recordingScript: String {
        if recordingLanguage == "zh" {
            return AppLocalized("今天的天气很舒服。我正在用清晰、自然的声音录制一段样本，让 CastReader 更准确地还原我的声音。")
        }
        return AppLocalized("Today is a pleasant day. I am recording this sample in a clear, natural voice so CastReader can reproduce my voice accurately.")
    }
    private func recordAction() {
        if recorder.state == .recording { recorder.stopRecording() }
        else { Task { await recorder.startRecording() } }
    }
    private func submit() {
        guard let url = recorder.recordingURL else { return }
        Task {
            if await store.create(
                recordingURL: url,
                referenceLanguage: recordingLanguage,
                consentConfirmed: consent
            ) { dismiss() }
        }
    }
}
