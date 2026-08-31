import SwiftUI
import UIKit

@MainActor
struct VoiceCloneCreatedView: View {
    let language: String
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var store = VoiceCloneStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var previewPlayer = VoiceClonePreviewPlayer.shared
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    @State private var showLogin = false
    @State private var showPaywall = false
    @State private var showCreation = false
    @State private var pendingDelete: ClonedVoice?
    @State private var pendingRename: ClonedVoice?
    @State private var pendingGiftAlias: ClonedVoice?
    @State private var pendingGiftRemoval: ClonedVoice?
    @State private var giftSharePayload: VoiceGiftSharePayload?
    @State private var preparingRenameVoiceID: String?
    @State private var sessionReady: Bool
    @State private var sessionCheckCompleted: Bool

    init(language: String) {
        self.language = language
        // Switching away from the Created tab destroys this view. Seed the new
        // instance from the route-local session so returning to the tab does not
        // briefly replace already-loaded voices with a sign-in gate.
        let hasPersistedSession = MobileSessionStore.persistedSessionToken(
            for: ServiceRouting.current
        ) != nil
        _sessionReady = State(initialValue: hasPersistedSession)
        _sessionCheckCompleted = State(initialValue: hasPersistedSession)
    }

    var body: some View {
        Group {
            if !auth.isSignedIn {
                gate(title: "登录后创建声音", detail: "声音克隆需要安全的账号会话。", action: "登录") { showLogin = true }
            } else {
                createdContent
            }
        }
        .task(id: auth.accountBoundaryID) {
            guard auth.isSignedIn else {
                sessionReady = false
                sessionCheckCompleted = true
                return
            }
            sessionReady = false
            sessionCheckCompleted = false
            await pro.refreshServer()
            sessionReady = await auth.ensureMobileSessionForVoiceClone()
            sessionCheckCompleted = true
            if sessionReady { await store.refresh() }
        }
        .onChange(of: auth.accountBoundaryID) { _ in
            pendingRename = nil
            pendingGiftAlias = nil
            pendingGiftRemoval = nil
            giftSharePayload = nil
            pendingDelete = nil
            preparingRenameVoiceID = nil
            showCreation = false
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, sessionReady else { return }
            Task { await store.refresh() }
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        .onChange(of: showLogin) { presented in
            guard !presented, auth.isSignedIn else { return }
            Task {
                sessionReady = await auth.ensureMobileSessionForVoiceClone()
                sessionCheckCompleted = true
                if sessionReady { await store.refresh() }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                reason: AppLocalized("免费版可创建并试听自己的声音。Pro 可将自己的声音用于朗读和解读，每月 120 分钟。"),
                analyticsTrigger: "voice_clone_apply",
                analyticsSurface: "voice_clone_created"
            )
        }
        .sheet(isPresented: $showCreation) { VoiceCloneCreationView(language: language) }
        .sheet(item: $pendingRename) { voice in
            VoiceCloneRenameView(voiceID: voice.voiceId)
        }
        .sheet(item: $pendingGiftAlias) { voice in
            VoiceGiftAliasView(voice: voice)
        }
        .sheet(item: $giftSharePayload) { payload in
            VoiceGiftShareSheet(payload: payload)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-CastReaderOpenVoiceCloneCreation") {
                showCreation = true
            }
            #endif
        }
        .alert("删除这个声音？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                guard let voice = pendingDelete else { return }
                pendingDelete = nil
                Task { await store.delete(voice) }
            }
        } message: { Text("删除后将无法继续使用这个声音。") }
        .alert("移除这个朗读者声音？", isPresented: Binding(
            get: { pendingGiftRemoval != nil },
            set: { if !$0 { pendingGiftRemoval = nil } }
        )) {
            Button("取消", role: .cancel) { pendingGiftRemoval = nil }
            Button("移除访问", role: .destructive) {
                guard let voice = pendingGiftRemoval else { return }
                pendingGiftRemoval = nil
                Task { await store.removeGiftAccess(voice) }
            }
        } message: {
            Text("只会从你的朗读者列表移除，不会删除对方创建的声音。")
        }
        .alert("声音克隆", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    /// This view is hosted by VoiceBrowserView's ScrollView. Keeping one stable
    /// stack here avoids rebuilding a nested List and lets cached voices remain
    /// visible while the server refresh runs in the background.
    private var createdContent: some View {
        LazyVStack(spacing: 0) {
            clonePolicySummary

            if sessionCheckCompleted, !sessionReady {
                Button { showLogin = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(AppTheme.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("重新登录以更新声音")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.foreground)
                            Text("已创建的声音会保留显示")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedForeground)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedForeground)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 20)
            }

            if let refreshError = store.refreshErrorMessage, sessionReady {
                Button {
                    Task { await store.refresh() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(AppTheme.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("声音列表暂未更新")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.foreground)
                            Text(String(
                                format: AppLocalized("%@ · 点击重试"),
                                refreshError
                            ))
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedForeground)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.primary.opacity(0.07))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if store.voiceGiftEnabled {
                voiceGiftInvitationAction
            }

            createVoiceAction

            voiceSectionHeader(
                title: AppLocalized("我的声音"),
                count: store.ownedVoices.count,
                showsProBadge: true
            )

            if store.ownedVoices.isEmpty {
                HStack(spacing: 10) {
                    if !sessionCheckCompleted || store.isLoading {
                        ProgressView().controlSize(.small)
                        Text("正在载入声音…")
                    } else {
                        Text("还没有创建的声音")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            } else {
                ForEach(store.ownedVoices) { voice in
                    cloneRow(voice)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    Divider().padding(.leading, 82)
                }
            }

            if store.voiceGiftEnabled {
                voiceSectionHeader(
                    title: AppLocalized("我的朗读者"),
                    count: store.giftedVoices.count,
                    showsProBadge: false
                )
                if store.giftedVoices.isEmpty {
                    Text("朋友完成授权后，他的声音会自动出现在这里。")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                } else {
                    ForEach(store.giftedVoices) { voice in
                        cloneRow(voice)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        Divider().padding(.leading, 82)
                    }
                }

                if !store.pendingGiftInvitations.isEmpty {
                    voiceSectionHeader(
                        title: VoiceGiftInviterUIContract.pendingSectionTitle,
                        count: store.pendingGiftInvitations.filter(\.isPending).count,
                        showsProBadge: false
                    )
                    ForEach(store.pendingGiftInvitations.filter(\.isPending)) { invitation in
                        pendingInvitationRow(invitation)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var voiceGiftInvitationAction: some View {
        Button {
            beginGiftInvitation()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(VoiceGiftInviterUIContract.primaryTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(VoiceGiftInviterUIContract.primaryBenefit)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(VoiceGiftInviterUIContract.primaryControlNote)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if store.isCreatingGiftInvitation {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [AppTheme.primary, AppTheme.primary.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.isCreatingGiftInvitation)
        .accessibilityIdentifier(VoiceGiftInviterUIContract.primaryActionIdentifier)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func voiceSectionHeader(
        title: String,
        count: Int,
        showsProBadge: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppTheme.primary.opacity(0.12))
                    )
            }
            if showsProBadge {
                Label("PRO", systemImage: "crown.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppTheme.primary.opacity(0.12))
                    )
                    .accessibilityIdentifier("voiceCloneProBadge")
            }
            Spacer()
            if store.isLoading, !store.voices.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在更新声音")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private func pendingInvitationRow(_ invitation: VoiceGiftInvitation) -> some View {
        Button {
            presentShare(for: invitation)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.title3)
                    .foregroundStyle(AppTheme.primary)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.primary.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(invitation.isClaimed ? "朋友正在录制" : "等待朋友录制")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.foreground)
                    Text("再次分享邀请链接")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedForeground)
                }
                Spacer()
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(AppTheme.primary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.surface)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            VoiceGiftInviterUIContract.pendingActionIdentifier(for: invitation.id)
        )
    }

    @ViewBuilder
    private var clonePolicySummary: some View {
        Group {
            if pro.isPro {
                proQuotaCard
            } else {
                freePolicyCard
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var proQuotaCard: some View {
        let quota = store.quotaPresentation
        return Group {
            if let remaining = quota.remainingSeconds,
               let used = quota.usedSeconds,
               let progress = quota.progress {
                let remainingPercent = quota.limitSeconds > 0
                    ? Int((Double(remaining) / Double(quota.limitSeconds) * 100).rounded())
                    : 0
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("克隆音色额度")
                                .font(.subheadline.weight(.semibold))
                            Text(quotaResetText(quota.resetAt))
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedForeground)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 4)

                        GeometryReader { proxy in
                            let consumedWidth = proxy.size.width * CGFloat(progress)
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(AppTheme.mutedForeground.opacity(0.14))
                                if progress > 0 {
                                    Capsule()
                                        .fill(AppTheme.primary.opacity(0.82))
                                        .frame(width: max(6, consumedWidth))
                                }
                            }
                        }
                        .frame(width: 92, height: 8)

                        Text(
                            store.isQuotaBlocked
                                ? AppLocalized("已用完")
                                : String(
                                    format: AppLocalized("%d%% 剩余"),
                                    max(0, remainingPercent)
                                )
                        )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(store.isQuotaBlocked ? AppTheme.destructive : AppTheme.mutedForeground)
                            .monospacedDigit()
                            .fixedSize()
                    }

                    HStack {
                        Text(
                            String(
                                format: AppLocalized("已使用 %@ 分钟"),
                                formattedMinutes(used)
                            )
                        )
                        Spacer()
                        Text(
                            String(
                                format: AppLocalized("剩余 %@ / %@ 分钟"),
                                formattedMinutes(remaining),
                                formattedMinutes(quota.limitSeconds)
                            )
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedForeground)
                    .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("克隆音色额度")
                .accessibilityValue(String(
                    format: AppLocalized("已使用 %@ 分钟，剩余 %@ 分钟，%@"),
                    formattedMinutes(used),
                    formattedMinutes(remaining),
                    quotaResetText(quota.resetAt)
                ))
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("克隆音色额度")
                            .font(.subheadline.weight(.semibold))
                        Text("正在同步本月用量…")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedForeground)
                    }
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.72), lineWidth: 1)
                )
        )
        .accessibilityIdentifier("voiceCloneQuotaCard")
    }

    private func quotaResetText(_ resetAt: Date?) -> String {
        guard let resetAt else { return AppLocalized("每月自动恢复") }
        let formatter = DateFormatter()
        formatter.locale = appLanguage.locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return String(
            format: AppLocalized("%@ 恢复"),
            formatter.string(from: resetAt)
        )
    }

    private var freePolicyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.primary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("免费版可创建并试听多个自己的声音")
                    .font(.subheadline.weight(.semibold))
                Text("升级 Pro 后可用于朗读和解读，每月 120 分钟。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedForeground)
            }
            Spacer(minLength: 0)
            Button("查看 Pro") { showPaywall = true }
                .font(.caption.weight(.semibold))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.primary.opacity(0.07))
        )
    }

    private var createVoiceAction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { beginCreation() } label: {
                HStack(spacing: 13) {
                    ZStack {
                        Circle()
                            .fill(createButtonAvailable ? Color.white.opacity(0.19) : AppTheme.destructive.opacity(0.10))
                            .frame(width: 42, height: 42)
                        Image(systemName: createButtonAvailable ? "mic.badge.plus" : "exclamationmark.lock.fill")
                            .font(.system(size: 18, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(createButtonTitle)
                            .font(.headline)
                        Text(createButtonSubtitle)
                            .font(.caption)
                            .opacity(0.86)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(createButtonAvailable ? Color.white : AppTheme.destructive)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .background(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(
                            createButtonAvailable
                                ? LinearGradient(
                                    colors: [AppTheme.primary, Color(red: 1, green: 0.39, blue: 0.05)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                : LinearGradient(
                                    colors: [AppTheme.destructive.opacity(0.09), AppTheme.destructive.opacity(0.04)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(
                                    createButtonAvailable
                                        ? Color.white.opacity(0.10)
                                        : AppTheme.destructive.opacity(0.20),
                                    lineWidth: 1
                                )
                        )
                        .shadow(
                            color: createButtonAvailable ? AppTheme.primary.opacity(0.25) : Color.clear,
                            radius: 14,
                            y: 7
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(store.isCreating)
            .accessibilityIdentifier("voiceCloneCreateButton")

            Text(creationAvailabilityDetail)
                .font(.caption)
                .foregroundStyle(sessionReady ? AppTheme.mutedForeground : AppTheme.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private var createButtonTitle: LocalizedStringKey {
        if !sessionReady {
            return sessionCheckCompleted ? "重新连接后创建" : "正在确认创建资格"
        }
        return "创建新声音"
    }

    private var createButtonSubtitle: LocalizedStringKey {
        if !sessionReady {
            return sessionCheckCompleted ? "点击更新登录状态" : "请稍候"
        }
        return "按住录制，约 10 秒完成"
    }

    private var createButtonAvailable: Bool {
        sessionReady
    }

    private var creationAvailabilityDetail: String {
        if !sessionReady {
            return sessionCheckCompleted
                ? AppLocalized("登录状态需要更新，点击按钮重新连接后创建。")
                : AppLocalized("请稍候")
        }
        return AppLocalized("录制一段清晰语音，即可创建一个可跨语言使用的个人音色。")
    }

    private func formattedMinutes(_ seconds: Int) -> String {
        let minutes = Double(max(0, seconds)) / 60
        let format = seconds % 60 == 0 ? "%.0f" : "%.1f"
        return String(
            format: format,
            locale: appLanguage.locale,
            minutes
        )
    }

    private func cloneRow(_ voice: ClonedVoice) -> some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                ClonedVoiceAvatarView(
                    voice: voice,
                    size: 50,
                    isAnimating: previewPlayer.playingVoiceId == voice.voiceId
                )
                Button {
                    previewPlayer.toggle(voice)
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
                .disabled(!voice.access.capabilities.canPreview)
                .accessibilityLabel(Text(LocalizedStringKey(
                    previewPlayer.playingVoiceId == voice.voiceId ? "停止试听" : "试听"
                )))
            }

            Button {
                applyVoice(voice)
            } label: {
                HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(store.displayName(for: voice))
                            .font(.headline)
                            .foregroundStyle(AppTheme.foreground)
                        Text("PRO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppTheme.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AppTheme.primary.opacity(0.12))
                            )
                    }
                    Text(cloneMetadata(voice)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settings.activeClonedVoiceID(for: language) == voice.voiceId {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.primary)
                } else if !pro.isPro {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voiceCloneApplyButton_\(voice.voiceId)")
            .accessibilityHint(
                pro.isPro
                    ? AppLocalized("用于当前朗读语言")
                    : AppLocalized("需要 Pro 才能用于朗读和解读")
            )

            if voice.access.kind == .owner,
               voice.access.capabilities.canRename
                    || voice.access.capabilities.canDelete {
                Menu {
                    if voice.access.capabilities.canRename {
                        Button("修改名称", systemImage: "pencil") {
                            prepareRename(voice)
                        }
                    }
                    if voice.access.capabilities.canDelete {
                        Button("删除", systemImage: "trash", role: .destructive) {
                            pendingDelete = voice
                        }
                    }
                } label: {
                    if preparingRenameVoiceID == voice.voiceId {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 36, height: 36)
                            .accessibilityLabel("正在更新声音")
                    } else {
                        Image(systemName: "ellipsis").frame(width: 36, height: 36)
                    }
                }
                .disabled(preparingRenameVoiceID != nil)
            } else if voice.access.capabilities.canEditAlias
                        || voice.access.capabilities.canRemoveAccess {
                Menu {
                    if voice.access.capabilities.canEditAlias {
                        Button("修改私有备注", systemImage: "pencil") {
                            pendingGiftAlias = voice
                        }
                    }
                    if voice.access.capabilities.canRemoveAccess {
                        Button("移除访问", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                            pendingGiftRemoval = voice
                        }
                    }
                } label: {
                    if store.mutatingGiftVoiceID == voice.voiceId {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "ellipsis").frame(width: 36, height: 36)
                    }
                }
                .disabled(store.mutatingGiftVoiceID != nil)
            }
        }
        .disabled(store.deletingVoiceId != nil || store.mutatingGiftVoiceID != nil)
    }

    /// Identity metadata is optional to the core create/TTS contract, so a
    /// successful creation can briefly appear before its display identity is
    /// backfilled. Editing must remain discoverable for every active voice.
    /// Refresh once before opening the editor rather than hiding the action;
    /// names still stay server-authoritative and consistent across clients.
    private func prepareRename(_ voice: ClonedVoice) {
        guard preparingRenameVoiceID == nil else { return }
        if voice.identity != nil {
            pendingRename = voice
            return
        }
        preparingRenameVoiceID = voice.voiceId
        Task {
            await store.refresh()
            defer { preparingRenameVoiceID = nil }
            guard let refreshed = store.voice(withID: voice.voiceId),
                  refreshed.identity != nil else {
                store.errorMessage = VoiceCloneError.identityUnavailable.localizedDescription
                return
            }
            pendingRename = refreshed
        }
    }

    private func applyVoice(_ voice: ClonedVoice) {
        guard pro.isPro else {
            showPaywall = true
            return
        }
        Task { await store.select(voice, for: language) }
    }

    private func cloneMetadata(_ voice: ClonedVoice) -> String {
        if voice.access.kind == .gifted {
            let donor = voice.access.donor?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = donor.flatMap { $0.isEmpty ? nil : $0 }
                .map { String(format: AppLocalized("来自 %@"), $0) }
                ?? AppLocalized("朋友授权的声音")
            let status: String
            switch voice.access.status?.lowercased() {
            case "expired": status = AppLocalized("授权已过期")
            case "revoked", "cancelled": status = AppLocalized("授权已收回")
            case nil, "active", "fulfilled": status = AppLocalized("可用于朗读和解读")
            default: status = AppLocalized("这个朗读者声音暂时无法使用，请刷新声音列表后重试")
            }
            return "\(source) · \(status)"
        }
        let reference = store.referenceLanguage(for: voice)
        let recording = reference == "zh" ? AppLocalized("中文样本") :
            (reference == "en" ? AppLocalized("英语样本") : AppLocalized("录音样本"))
        let count = VoiceCloneLanguageSupport.languages(for: voice).count
        let languageSupport = String(
            format: AppLocalized("可用于全部 %lld 种支持语言"),
            Int64(count)
        )
        return "\(recording) · \(languageSupport)"
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
        Task {
            guard await auth.ensureMobileSessionForVoiceClone() else {
                store.errorMessage = VoiceCloneError.sessionUnavailable.localizedDescription
                return
            }
            showCreation = true
        }
    }

    private func beginGiftInvitation() {
        guard auth.isSignedIn else {
            showLogin = true
            return
        }
        guard VoiceGiftFeature.isRegionEligible() else {
            store.errorMessage = VoiceCloneError.giftUnavailableInRegion.localizedDescription
            return
        }
        guard store.voiceGiftEnabled else {
            store.errorMessage = VoiceCloneError.giftAccessUnavailable.localizedDescription
            return
        }
        Task {
            guard await auth.ensureMobileSessionForVoiceClone() else {
                store.errorMessage = VoiceCloneError.sessionUnavailable.localizedDescription
                return
            }
            guard let invitation = await store.createGiftInvitation() else { return }
            presentShare(for: invitation)
        }
    }

    private func presentShare(for invitation: VoiceGiftInvitation) {
        guard let url = VoiceGiftInvitationURLValidator.validatedURL(
            invitation.invitationURL
        ) else {
            store.errorMessage = VoiceCloneError.invalidResponse.localizedDescription
            return
        }
        giftSharePayload = VoiceGiftSharePayload(
            id: invitation.id,
            url: url
        )
    }
}

private struct VoiceGiftSharePayload: Identifiable {
    let id: String
    let url: URL
}

/// Frozen inviter-side MVP contract. The primary action stays recipient-free:
/// one tap creates an open invitation and immediately hands its URL to the
/// system share sheet. Pending requests remain discoverable as secondary rows.
enum VoiceGiftInviterUIContract {
    static let primaryActionIdentifier = "voiceGiftInviteButton"
    static let pendingActionIdentifierPrefix = "voiceGiftPending_"

    static let primaryTitleKey = "邀请朋友录制声音"
    static let primaryBenefitKey = "朋友授权后，你可用他的声音朗读和解读 Kindle、文件与网页，直到他撤回。"
    static let primaryControlNoteKey = "点击后直接分享链接，无需填写邮箱。"
    static let pendingSectionTitleKey = "待回应邀请"

    static var primaryTitle: String { localized(primaryTitleKey) }
    static var primaryBenefit: String { localized(primaryBenefitKey) }
    static var primaryControlNote: String { localized(primaryControlNoteKey) }
    static var pendingSectionTitle: String { localized(pendingSectionTitleKey) }

    static func pendingActionIdentifier(for requestID: String) -> String {
        pendingActionIdentifierPrefix + requestID
    }

    private static func localized(_ key: String) -> String {
        AppLocalized(String.LocalizationValue(stringLiteral: key))
    }
}

enum VoiceGiftShareContract {
    static func activityItems(for url: URL) -> [Any] {
        // Keep the invitation as one HTTPS item. Supplying a separate String
        // and URL makes some share destinations materialize the URL as a
        // `.url` attachment beside the message instead of one tappable link.
        [url]
    }
}

private struct VoiceGiftShareSheet: UIViewControllerRepresentable {
    let payload: VoiceGiftSharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: VoiceGiftShareContract.activityItems(for: payload.url),
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

@MainActor
private struct VoiceGiftAliasView: View {
    let voice: ClonedVoice
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VoiceCloneStore.shared
    @State private var alias: String

    init(voice: ClonedVoice) {
        self.voice = voice
        _alias = State(initialValue: voice.access.recipientAlias ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：妈妈讲故事", text: $alias)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("私有备注")
                } footer: {
                    Text("只有你能看到这个备注，不会修改朗读者创建的声音名称。")
                }
            }
            .navigationTitle("修改私有备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if await store.updateGiftAlias(voice, to: alias) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(store.mutatingGiftVoiceID != nil)
                }
            }
        }
    }
}

struct ClonedVoiceAvatarView: View {
    let voice: ClonedVoice
    var size: CGFloat = 50
    var isAnimating = false

    var body: some View {
        avatarContent
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 1))
            .overlay {
                if isAnimating, remoteAvatarURL != nil {
                    Circle()
                        .fill(Color.black.opacity(0.24))
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let remoteAvatarURL {
            AsyncImage(url: remoteAvatarURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    stylizedAvatar
                }
            }
        } else {
            stylizedAvatar
        }
    }

    private var stylizedAvatar: some View {
        ZStack {
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: isAnimating ? "waveform" : symbolName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(foreground)
                .symbolEffect(.variableColor.iterative, isActive: isAnimating)
        }
    }

    private var remoteAvatarURL: URL? {
        voice.presentation?.avatar?.remoteURL
    }

    private var resolvedAvatarStyle: VoiceCloneAvatarPresentation? {
        if let style = voice.presentation?.avatar?.resolvedStyle {
            return style
        }
        guard let avatar = voice.identity?.avatar,
              avatar.isSupported else { return nil }
        return avatar
    }

    private var colors: [Color] {
        if let avatar = resolvedAvatarStyle {
            return [
                Color(hexString: avatar.backgroundStart),
                Color(hexString: avatar.backgroundEnd),
            ]
        }
        let seed = voice.voiceId.unicodeScalars.reduce(0) {
            ($0 &* 31 &+ Int($1.value)) % 4
        }
        switch seed {
        case 0:
            return [Color(red: 0.21, green: 0.68, blue: 1.00), Color(red: 0.16, green: 0.38, blue: 0.94)]
        case 1:
            return [Color(red: 0.47, green: 0.55, blue: 1.00), Color(red: 0.34, green: 0.25, blue: 0.84)]
        case 2:
            return [Color(red: 0.12, green: 0.74, blue: 0.75), Color(red: 0.05, green: 0.43, blue: 0.75)]
        default:
            return [Color(red: 0.33, green: 0.64, blue: 0.98), Color(red: 0.25, green: 0.32, blue: 0.78)]
        }
    }

    private var foreground: Color {
        guard let value = resolvedAvatarStyle?.foreground else { return .white }
        return Color(hexString: value)
    }

    private var symbolName: String {
        switch resolvedAvatarStyle?.glyph {
        case .waveBars: return "waveform"
        case .wavePulse: return "waveform.path.ecg"
        case .waveOrbit: return "dot.radiowaves.left.and.right"
        case .waveRipple: return "wave.3.right"
        case nil: return "person.fill"
        }
    }
}

@MainActor
private struct VoiceCloneRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VoiceCloneStore.shared
    let voiceID: String
    @State private var name = ""
    @State private var validationMessage: String?

    private var voice: ClonedVoice? { store.voice(withID: voiceID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "声音名称",
                        text: $name,
                        prompt: Text(voice.map(store.displayName(for:)) ?? AppLocalized("我的声音"))
                    )
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .accessibilityIdentifier("voiceCloneNameField")

                    HStack {
                        if let validationMessage {
                            Text(validationMessage)
                                .foregroundStyle(AppTheme.destructive)
                        } else {
                            Text("创建成功后可随时修改，不影响声音使用")
                                .foregroundStyle(AppTheme.mutedForeground)
                        }
                        Spacer()
                        Text("\(name.count)/\(VoiceCloneNameValidator.maximumGraphemes)")
                            .monospacedDigit()
                            .foregroundStyle(
                                name.count > VoiceCloneNameValidator.maximumGraphemes
                                    ? AppTheme.destructive
                                    : AppTheme.mutedForeground
                            )
                    }
                    .font(.caption)
                }

                if voice?.identity?.customName != nil {
                    Section {
                        Button("恢复默认名称") {
                            Task {
                                if await store.rename(voiceID, to: nil) { dismiss() }
                            }
                        }
                        .disabled(store.renamingVoiceId != nil)
                    }
                }
            }
            .navigationTitle("修改名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(store.renamingVoiceId != nil || name.isEmpty)
                }
            }
            .overlay {
                if store.renamingVoiceId == voiceID {
                    ZStack {
                        Color.black.opacity(0.08).ignoresSafeArea()
                        ProgressView().controlSize(.large)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(store.renamingVoiceId == voiceID)
        .onAppear { name = voice?.identity?.customName ?? "" }
        .onChange(of: name) { _ in validationMessage = nil }
    }

    private func save() {
        do {
            _ = try VoiceCloneNameValidator.normalized(name)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        Task {
            if await store.rename(voiceID, to: name) { dismiss() }
        }
    }
}

@MainActor
private struct VoiceCloneCreationView: View {
    private enum Phase: Equatable { case introduction, ready, creating, complete }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceCloneRecorder()
    @ObservedObject private var store = VoiceCloneStore.shared
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var previewPlayer = VoiceClonePreviewPlayer.shared
    let language: String
    @State private var phase: Phase = .introduction
    @State private var isHolding = false
    @State private var cancelArmed = false
    @State private var pendingReleaseAction: Bool?
    @State private var submissionStarted = false
    @State private var isPreparingRecorder = false
    @State private var showPaywall = false
    @State private var showRename = false
    @State private var selectedRecordingLanguage: String?

    private var recordingLanguage: String {
        selectedRecordingLanguage
            ?? VoiceCloneRecordingPrompt.languageCode(for: appLanguage.selectedLanguage)
    }

    private var recordingLanguageSelection: Binding<String> {
        Binding(
            get: { recordingLanguage },
            set: { selectedRecordingLanguage = VoiceCatalog.normalizedLanguage($0) }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                switch phase {
                case .introduction: introduction
                case .ready: recordingScreen
                case .creating: creatingScreen
                case .complete: completeScreen
                }
            }
            .navigationTitle("声音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(store.isCreating)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(store.isCreating || recorder.state == .recording)
        .onDisappear { recorder.cancelRecording() }
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                reason: AppLocalized("免费版可创建并试听自己的声音。Pro 可将自己的声音用于朗读和解读，每月 120 分钟。"),
                analyticsTrigger: "voice_clone_apply",
                analyticsSurface: "voice_clone_complete"
            )
        }
        .sheet(isPresented: $showRename) {
            if let voiceID = store.lastCreatedVoiceID {
                VoiceCloneRenameView(voiceID: voiceID)
            }
        }
    }

    private var introduction: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 72)
            Text("克隆我的声音")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(AppTheme.foreground)
            Spacer().frame(height: 76)

            VStack(alignment: .leading, spacing: 34) {
                instructionRow(
                    icon: "mic.fill",
                    title: "录制自己的声音",
                    detail: "选择一种录音语言，录制一次即可生成可跨语言使用的声音。"
                )
                instructionRow(
                    icon: "house.fill",
                    title: "找一处安静的地方",
                    detail: "使用自然语气和日常说话习惯，保持手机距离稳定。"
                )
                instructionRow(
                    icon: "text.book.closed.fill",
                    title: "自由朗读或自然说话",
                    detail: "可以朗读示例，也可以用录音语言自然说一段自己的内容，无需逐字一致。"
                )
            }
            .padding(.horizontal, 34)

            Spacer()

            Text("继续即表示你确认录制的是本人声音，并同意仅在 App 内用于生成语音。")
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.bottom, 18)

            Text("所有用户均可创建和试听声音；Pro 可用于朗读和解读，每个会员周期 120 分钟。")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)

            Button { prepareRecordingStep() } label: {
                ZStack {
                    Text("确认录制")
                        .font(.headline)
                        .opacity(isPreparingRecorder ? 0 : 1)
                    if isPreparingRecorder {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 58)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
            .disabled(isPreparingRecorder)
            .accessibilityIdentifier("voiceCloneIntroConfirmButton")
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
    }

    private func instructionRow(
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(AppTheme.foreground)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recordingScreen: some View {
        ZStack(alignment: .bottom) {
            if recorder.state == .recording {
                VoiceCloneRecordingGlow(level: recorder.level)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            VStack(spacing: 0) {
                Spacer().frame(height: 58)
                Text(
                    recorder.state == .recording
                        ? AppLocalized("录音中，请自然说话…")
                        : AppLocalized("请开始说话")
                )
                    .font(.system(size: 31, weight: .bold))

                recordingLanguagePicker
                    .padding(.horizontal, 30)
                    .padding(.top, 22)

                Text("你可以朗读下面的示例，也可以自然说一段自己的内容，无需逐字一致。")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text("示例文本（可选）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedForeground)
                    Text(recordingExampleText)
                        .font(.system(size: recordingLanguage == "zh" ? 25 : 21, weight: .medium))
                        .lineSpacing(8)
                        .foregroundStyle(AppTheme.foreground)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30)
                    .padding(.top, 30)

                Spacer()

                if let error = recorder.errorMessage ?? store.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(recorder.state == .recording ? Color.white : AppTheme.destructive)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }

                if recorder.state == .recording {
                    VStack(spacing: 6) {
                        Text(
                            cancelArmed
                                ? AppLocalized("松手取消")
                                : AppLocalized("松手完成，上移取消")
                        )
                            .font(.subheadline.weight(.medium))
                        Text(String(
                            format: AppLocalized("%.1f 秒 · 至少 3 秒"),
                            locale: appLanguage.locale,
                            recorder.duration
                        ))
                            .font(.footnote.monospacedDigit())
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.bottom, 10)
                    recordingWaveform
                        .padding(.horizontal, 26)
                        .padding(.bottom, 22)
                }

                if canRetryOriginalRecording {
                    failedRecordingActions
                        .padding(.horizontal, 24)
                        .padding(.bottom, 26)
                } else {
                    holdControl
                        .padding(.horizontal, 24)
                        .padding(.bottom, 26)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: recorder.state)
    }

    private var recordingWaveform: some View {
        VoiceCloneLiveWaveform(samples: recorder.waveformSamples)
        .frame(height: 94)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("实时录音音量")
        .accessibilityValue(recordingLevelDescription)
        .accessibilityIdentifier("voiceCloneRecordingWaveform")
    }

    private var recordingLevelDescription: String {
        switch recorder.level {
        case ..<0.22: return AppLocalized("较小")
        case ..<0.66: return AppLocalized("适中")
        default: return AppLocalized("较大")
        }
    }

    private var recordingLanguagePicker: some View {
        Menu {
            Picker("录音语言", selection: recordingLanguageSelection) {
                ForEach(VoiceCloneRecordingPrompt.selectableLanguages, id: \.self) { code in
                    Text(VoiceCloneRecordingPrompt.displayName(for: code, locale: appLanguage.locale))
                        .tag(code)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(AppTheme.primary)
                Text("录音语言")
                    .foregroundStyle(AppTheme.foreground)
                Spacer()
                Text(VoiceCloneRecordingPrompt.displayName(
                    for: recordingLanguage,
                    locale: appLanguage.locale
                ))
                    .foregroundStyle(AppTheme.mutedForeground)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedForeground)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.surface)
            )
        }
        .disabled(recorder.state != .idle || submissionStarted)
        .accessibilityIdentifier("voiceCloneRecordingLanguagePicker")
    }

    private var canRetryOriginalRecording: Bool {
        recorder.state == .recorded
            && recorder.canSubmit
            && recorder.recordingURL != nil
            && store.errorMessage != nil
            && !submissionStarted
    }

    private var failedRecordingActions: some View {
        VStack(spacing: 12) {
            Button("重试原录音") {
                submitRecording()
            }
            .font(.headline)
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("voiceCloneRetryOriginalRecordingButton")

            Button("重新录制") {
                store.errorMessage = nil
                recorder.replaceRecording()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.primary)
            .accessibilityIdentifier("voiceCloneReplaceRecordingButton")
        }
    }

    private var holdControlForeground: Color {
        if cancelArmed { return AppTheme.destructive }
        return recorder.state == .recording ? .white : AppTheme.foreground
    }

    private var holdControlBackground: Color {
        if recorder.state == .recording {
            return cancelArmed ? Color.white.opacity(0.88) : Color.white.opacity(0.13)
        }
        return AppTheme.surface
    }

    private var holdControlBorder: Color {
        recorder.state == .recording ? Color.white.opacity(0.26) : Color.clear
    }

    private var holdControlShadow: Color {
        recorder.state == .recording ? Color.clear : Color.black.opacity(0.09)
    }

    private var holdControlText: LocalizedStringKey {
        if cancelArmed { return "松手取消" }
        if recorder.state == .recording { return "松手完成" }
        return "按住录制"
    }

    private var holdControlIcon: String {
        cancelArmed ? "xmark" : "mic.fill"
    }

    private var holdControl: some View {
        HStack(spacing: 10) {
            Image(systemName: holdControlIcon)
            Text(holdControlText)
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(holdControlForeground)
        .frame(maxWidth: .infinity)
        .frame(height: 68)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(holdControlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(holdControlBorder, lineWidth: 1)
                )
                .shadow(color: holdControlShadow, radius: 18, y: 5)
        )
        .scaleEffect(isHolding ? 0.985 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: recorder.state)
        .animation(.easeOut(duration: 0.12), value: cancelArmed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isHolding {
                        isHolding = true
                        cancelArmed = false
                        pendingReleaseAction = nil
                        beginHoldRecording()
                    }
                    cancelArmed = value.translation.height < -70
                }
                .onEnded { value in
                    let shouldCancel = value.translation.height < -70
                    isHolding = false
                    cancelArmed = false
                    if recorder.state == .recording {
                        finishHoldRecording(cancel: shouldCancel)
                    } else {
                        pendingReleaseAction = shouldCancel
                    }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("按住录制，松手发送，上移取消")
        .accessibilityIdentifier("voiceCloneHoldButton")
    }

    private var creatingScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(AppTheme.primary.opacity(0.12)).frame(width: 118, height: 118)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(AppTheme.primary)
                    .symbolEffect(.variableColor.iterative)
            }
            Text("正在生成你的声音").font(.title2.bold())
            Text("正在安全上传录音并提取音色，通常只需十几秒。")
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
            ProgressView().controlSize(.large).tint(AppTheme.primary)
            Spacer()
        }
    }

    private var completeScreen: some View {
        VStack(spacing: 22) {
            Spacer()
            if let voice = lastCreatedVoice {
                ClonedVoiceAvatarView(voice: voice, size: 88)
                Text(store.displayName(for: voice))
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if voice.identity != nil {
                    Button("修改名称") { showRename = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                        .accessibilityIdentifier("voiceCloneCompleteRenameButton")
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 82))
                    .foregroundStyle(AppTheme.primary)
            }
            Text("声音已创建").font(.largeTitle.bold())
            Text(completeDetail)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 42)
            Spacer()
            Button(
                pro.isPro
                    ? AppLocalized("立即使用")
                    : AppLocalized("试听我的声音")
            ) {
                completePrimaryAction()
            }
                .font(.headline)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("voiceCloneCompleteButton")
                .padding(.horizontal, 24)
            if !pro.isPro {
                Button("升级 Pro 后用于朗读和解读") { showPaywall = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)
                    .padding(.bottom, 24)
            } else {
                Spacer().frame(height: 24)
            }
        }
    }

    private var lastCreatedVoice: ClonedVoice? {
        guard let voiceID = store.lastCreatedVoiceID else { return nil }
        return store.voice(withID: voiceID)
    }

    private var completeDetail: String {
        if pro.isPro {
            return AppLocalized("这个声音可用于全部支持的朗读语言。Pro 每月包含 120 分钟克隆音色朗读和解读额度。")
        }
        return AppLocalized("这个声音可跨语言试听。免费版不能将克隆音色用于朗读和解读，升级 Pro 后每月可使用 120 分钟。")
    }

    private func completePrimaryAction() {
        guard let voiceID = store.lastCreatedVoiceID,
              let voice = store.voices.first(where: { $0.voiceId == voiceID }) else {
            dismiss()
            return
        }
        if pro.isPro {
            Task {
                if await store.select(voice, for: language) { dismiss() }
            }
        } else {
            previewPlayer.toggle(voice)
        }
    }

    private var recordingExampleText: String {
        VoiceCloneRecordingPrompt.text(for: recordingLanguage)
    }

    private func prepareRecordingStep() {
        guard !isPreparingRecorder else { return }
        isPreparingRecorder = true
        Task { @MainActor in
            let granted = await recorder.preparePermission()
            isPreparingRecorder = false
            if granted { phase = .ready }
        }
    }

    private func beginHoldRecording() {
        store.errorMessage = nil
        Task { @MainActor in
            let started = await recorder.startRecording()
            guard started else {
                isHolding = false
                pendingReleaseAction = nil
                return
            }
            if let shouldCancel = pendingReleaseAction {
                pendingReleaseAction = nil
                finishHoldRecording(cancel: shouldCancel)
            }
        }
    }

    private func finishHoldRecording(cancel: Bool) {
        if cancel {
            recorder.cancelRecording()
            return
        }
        recorder.stopRecording()
        guard recorder.canSubmit, !submissionStarted else { return }
        submitRecording()
    }

    private func submitRecording() {
        guard recorder.canSubmit,
              let url = recorder.recordingURL else { return }
        let language = recordingLanguage
        store.errorMessage = nil
        submissionStarted = true
        phase = .creating
        Task { @MainActor in
            let succeeded = await store.create(
                recordingURL: url,
                referenceLanguage: language,
                // The on-screen script is optional guidance. Speaker-only
                // creation must never claim that natural speech matched it.
                referenceText: nil,
                consentConfirmed: true
            )
            submissionStarted = false
            switch VoiceCloneCreationSubmissionOutcome(succeeded: succeeded) {
            case .completed:
                phase = .complete
            case .retryOriginalRecording:
                // Keep the exact WAV and selected language available so a
                // transient upload or worker failure can be retried unchanged.
                phase = .ready
            }
        }
    }
}

/// A Voice Memos-style rolling waveform. The newest microphone sample enters
/// from the right and every existing bar advances one position to the left.
private struct VoiceCloneLiveWaveform: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            let count = VoiceCloneWaveformGeometry.barCount(for: size.width)
            let spacing = VoiceCloneWaveformGeometry.spacing
            let barWidth = VoiceCloneWaveformGeometry.barWidth(
                availableWidth: size.width,
                count: count
            )
            let waveformWidth = barWidth * CGFloat(count) + spacing * CGFloat(count - 1)
            let originX = (size.width - waveformWidth) / 2
            let visibleSamples = VoiceCloneWaveformGeometry.visibleSamples(
                samples,
                count: count
            )

            for index in 0..<count {
                let height = VoiceCloneWaveformGeometry.height(
                    energy: visibleSamples[index],
                    availableHeight: size.height
                )
                let rect = CGRect(
                    x: originX + CGFloat(index) * (barWidth + spacing),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(.white.opacity(0.96))
                )
            }
        }
    }
}

enum VoiceCloneWaveformGeometry {
    static let spacing: CGFloat = 2.5

    static func barCount(for width: CGFloat) -> Int {
        max(72, min(104, Int(width / 4)))
    }

    static func barWidth(availableWidth: CGFloat, count: Int) -> CGFloat {
        let spaces = spacing * CGFloat(max(0, count - 1))
        return max(1.2, min(1.8, (availableWidth - spaces) / CGFloat(max(1, count))))
    }

    /// Right-aligns the available history. Empty positions at the beginning of
    /// a recording remain at the baseline; when a new sample arrives, every
    /// visible historical sample moves exactly one bar toward the left.
    static func visibleSamples(_ samples: [Double], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let recent = samples.suffix(count).map { CGFloat(min(1, max(0, $0))) }
        return Array(repeating: 0, count: count - recent.count) + recent
    }

    static func height(
        energy: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let clampedEnergy = min(1, max(0, energy))
        guard clampedEnergy > 0.01 else { return 5 }
        let maximum = max(8, availableHeight * 0.78)
        let responsiveHeight = 5 + pow(clampedEnergy, 0.68) * (maximum - 5)
        return min(maximum, responsiveHeight)
    }
}

/// The light field changes its radius inside the full-screen canvas. It never
/// scales a clipped view, so the transparent outer edge stays soft at the top.
private struct VoiceCloneRecordingGlow: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            let energy = CGFloat(min(1, max(0, level)))

            Canvas { context, size in
                context.addFilter(.blur(radius: 18))
                let center = CGPoint(
                    x: size.width / 2,
                    y: size.height * (1.09 - 0.045 * energy)
                )
                let radius = max(
                    size.width * (1.02 + 0.25 * energy),
                    size.height * (0.54 + 0.20 * energy)
                )
                let gradient = Gradient(stops: [
                    .init(color: Color(red: 0.01, green: 0.27, blue: 1.00), location: 0),
                    .init(color: Color(red: 0.00, green: 0.52, blue: 1.00), location: 0.36),
                    .init(color: Color(red: 0.12, green: 0.77, blue: 1.00).opacity(0.92), location: 0.62),
                    .init(color: Color(red: 0.48, green: 0.88, blue: 1.00).opacity(0.34), location: 0.80),
                    .init(color: .clear, location: 0.96),
                ])
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        gradient,
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.easeOut(duration: 0.075), value: energy)
        }
    }
}
