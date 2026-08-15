//
//  LoginView.swift
//  CastReader
//
//  登录页：全球区 Google + Apple + 邮箱验证码；中国区手机号 + Apple。
//  既作 sheet（付费墙「登录账号同步 Pro」等入口），也作 RootAuthGate 的全屏硬登录墙。
//

import SwiftUI

enum LoginAction: Equatable {
    case phone
    case google
    case apple
    case expandEmail
    case sendEmailCode
    case verifyEmailCode
}

enum LoginConsentDecision: Equatable {
    case execute(LoginAction)
    case requestConsent
}

/// 中国区登录前的显式协议同意状态机。
///
/// pending action 只保存动作类型，不保存闭包或账号数据。用户在弹窗中同意后，
/// LoginView 才执行原先点下的登录方式；拒绝则清空，避免下一次误触发旧动作。
struct LoginConsentGate: Equatable {
    private(set) var hasAgreed = false
    private(set) var pendingAction: LoginAction?

    mutating func request(
        _ action: LoginAction,
        requiresExplicitConsent: Bool
    ) -> LoginConsentDecision {
        guard requiresExplicitConsent, !hasAgreed else {
            pendingAction = nil
            return .execute(action)
        }
        pendingAction = action
        return .requestConsent
    }

    mutating func setAgreement(_ agreed: Bool) {
        hasAgreed = agreed
        pendingAction = nil
    }

    mutating func acceptPendingAction() -> LoginAction? {
        hasAgreed = true
        defer { pendingAction = nil }
        return pendingAction
    }

    mutating func declinePendingAction() {
        pendingAction = nil
    }
}

struct LoginView: View {
    /// 作为根登录墙时为 true：展示价值主张（可听的内容源）。
    /// sheet 场景（付费墙「登录账号同步 Pro」等入口）保持原有的紧凑形态。
    var isRootGate = false

    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var net = NetworkReachability.shared
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 上次成功登录用的 provider，用于在按钮上打「上次登录」标签。
    /// 登出不清除——它只是个偏好提示，不含任何身份信息。
    @AppStorage("last_signin_provider") private var lastProvider = ""
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var showsPhoneSignIn = false
    @State private var consentGate = LoginConsentGate()
    @State private var showsConsentPrompt = false
    @State private var appleCoordinator: AppleSignInCoordinator?

    // 邮箱验证码流
    @State private var emailFlowExpanded = false
    @State private var email = ""
    @State private var otpCode = ""
    @State private var codeSent = false
    @State private var isSendingEmailCode = false
    @State private var resendCooldown = 0
    private let cooldownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        content
            // 宽屏（横屏 / iPad）不让内容拉满：50pt 高的按钮横跨整个屏幕会失衡，
            // 也超出舒适阅读宽度。限宽后居中。
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(AppTheme.background.ignoresSafeArea())
        .overlay {
            if auth.isWorking && !isSendingEmailCode {
                ProgressView().scaleEffect(1.2)
            }
        }
        // sheet 场景下已登录用户重新登录（如 Apple 无 email → 邮箱补登）时
        // isSignedIn 不发生 false→true 跳变，所以按 account 变化收面板。
        .onChange(of: auth.account) { acc in
            guard let acc else { return }
            lastProvider = acc.provider   // 供下次登录在按钮上打「上次登录」
            dismiss()
        }
        .onReceive(cooldownTimer) { _ in if resendCooldown > 0 { resendCooldown -= 1 } }
        .sheet(isPresented: $showsPhoneSignIn) {
            PhoneSignInView(hasAcceptedTerms: consentGate.hasAgreed)
        }
        .alert(AppLocalized("服务条款与隐私政策"), isPresented: $showsConsentPrompt) {
            Button(AppLocalized("不同意"), role: .cancel) {
                consentGate.declinePendingAction()
            }
            Button(AppLocalized("同意")) {
                guard let action = consentGate.acceptPendingAction() else { return }
                execute(action)
            }
        } message: {
            Text(AppLocalized("我已阅读并同意《服务条款》和《隐私政策》"))
        }
    }

    /// 竖屏用 Spacer 把内容撑成上中下三段；横屏（`verticalSizeClass == .compact`）
    /// 垂直空间不够，Spacer 会把内容挤扁甚至溢出，改成紧凑的可滚动布局。
    @ViewBuilder
    private var content: some View {
        if verticalSizeClass == .compact {
            ScrollView {
                VStack(spacing: 16) {
                    if !net.isOnline { offlineBanner }
                    if isRootGate { rootGateHeader } else { sheetHeader }
                    channelStack
                    errorText
                    termsFooter
                }
                .padding(.vertical, 12)
            }
        } else {
            VStack(spacing: 20) {
                if !net.isOnline { offlineBanner }
                Spacer()
                if isRootGate { rootGateHeader } else { sheetHeader }
                Spacer()
                channelStack
                errorText
                termsFooter
            }
        }
    }

    /// 手机号是中国区首选完整按钮；Google 与邮箱仅在全球版展示。
    /// Apple 在两套区域中都保持小图标入口。
    private var channelStack: some View {
        VStack(spacing: 14) {
            phoneButton
            googleButton
            secondaryChannelRow
            if AppRegion.current.showsEmailSignIn, emailFlowExpanded {
                emailSection
            }
        }
        .animation(.easeInOut(duration: 0.2), value: emailFlowExpanded)
    }

    @ViewBuilder
    private var errorText: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundColor(AppTheme.destructive)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: 页头

    /// 根登录墙：卖价值，不是解释功能。
    ///
    /// 首次打开的人还不知道 CastReader 是什么，「跨设备同步 Pro 订阅」这类
    /// 功能说明对他等于没说。这里讲竞品做不到的那件事——**听你已经买的书**
    /// （五个绑定书库），再用图标行给出内容源广度。
    private var rootGateHeader: some View {
        VStack(spacing: 14) {
            Image(systemName: "headphones")
                .font(.system(size: 48, weight: .semibold))
                .foregroundColor(AppTheme.primary)
            Text("你的书，现在能听了")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("连上 Kindle、微信读书，或导入 PDF、EPUB、网页")
                .font(.subheadline)
                .foregroundColor(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
            sourceChips
        }
    }

    /// 内容源图标行。名称是产品专名（Kindle / PDF 等），不进本地化表。
    private var sourceChips: some View {
        var sources: [(String, String)] = [
            ("book.closed", "Kindle"),
            ("book", AppLocalized("微信读书")),
            ("doc.richtext", "PDF"),
            ("globe", AppLocalized("网页")),
        ]
        if AppRegion.current.showsYouTubeEntry {
            sources.append(("play.rectangle", "YouTube"))
        }
        return HStack(spacing: 8) {
            ForEach(sources, id: \.1) { source in
                HStack(spacing: 4) {
                    Image(systemName: source.0).font(.system(size: 10, weight: .semibold))
                    Text(source.1).font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AppTheme.surface, in: Capsule())
                .foregroundColor(AppTheme.mutedForeground)
            }
        }
        .padding(.top, 2)
    }

    /// sheet 场景（付费墙里点「登录账号同步 Pro」等）：用户已经在用 App 了，
    /// 此处只需说明这次登录能带来什么，不要再卖一遍产品。
    private var sheetHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 56)).foregroundColor(AppTheme.primary)
            Text("登录 CastReader").font(.title2.weight(.bold))
            Text("跨设备同步 Pro 订阅、额度与历史")
                .font(.subheadline).foregroundColor(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: 离线兜底

    /// 提示而非封锁：NetworkReachability 只是 hint（captive portal 会误报），
    /// 按钮保持可点，用户坚持时仍可尝试。
    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").foregroundColor(AppTheme.mutedForeground)
            Text(AppLocalized("当前无网络，登录需要联网。请检查网络连接后重试。"))
                .font(.footnote).foregroundColor(AppTheme.mutedForeground)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var phoneButton: some View {
        if PhoneAuthService.shared.isAvailable {
            Button { request(.phone) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "iphone").font(.system(size: 18, weight: .bold))
                    Text(AppLocalized("使用手机号继续")).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(AppTheme.buttonPrimary)
                .foregroundColor(AppTheme.buttonPrimaryForeground)
                .cornerRadius(12)
            }
            .disabled(auth.isWorking)
            .accessibilityIdentifier("login.phone")
        }
    }

    // MARK: 按钮

    /// Google 只在全球产品体验展示；中国大陆登录页不暴露不可用入口。
    @ViewBuilder
    private var googleButton: some View {
        if AppRegion.current.showsGoogleSignIn && Constants.GoogleOAuth.isConfigured {
            Button { request(.google) } label: {
                HStack(spacing: 10) {
                    // Google 品牌规范要求用官方四色 G 标志，不能用通用图标代替。
                    // 资源取自 developers.google.com/identity/images/g-logo.png。
                    Image("GoogleLogo")
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text("使用 Google 继续").fontWeight(.semibold)
                    if isRootGate && lastProvider == "google" { lastLoginBadge }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                // 用前景色作底：浅色模式是黑底白字，深色模式自动反过来，
                // 两种模式下四色 G 都清晰。不用主题橙色——那是品牌强调色，
                // 满屏铺开会削弱它在别处（播放、Pro）的指示作用。
                .background(AppTheme.foreground)
                .foregroundColor(AppTheme.background)
                .cornerRadius(12)
            }
            .disabled(auth.isWorking)
        } else if AppRegion.current.showsGoogleSignIn {
            Text("Google 登录未配置（需填入 Constants.GoogleOAuth.clientID）")
                .font(.caption2).foregroundColor(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
        }
    }

    private var lastLoginBadge: some View {
        Text(AppLocalized("上次登录"))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(AppTheme.background.opacity(0.22), in: Capsule())
    }

    /// Apple 两区均展示；邮箱小图标仅作为全球区兜底通道。
    private var secondaryChannelRow: some View {
        HStack(spacing: 18) {
            AppleSignInIconButton(action: { request(.apple) })
            .disabled(auth.isWorking)
            .accessibilityIdentifier("login.apple")
            if AppRegion.current.showsEmailSignIn {
                emailIconButton
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 邮箱验证码的收起态：兜底通道（Google/Apple 都不可用时才需要），点开展成表单。
    private var emailIconButton: some View {
        Button { request(.expandEmail) } label: {
            Image(systemName: "envelope")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppTheme.foreground)
                .frame(width: 44, height: 44)
                .background(AppTheme.surface, in: Circle())
                .overlay(Circle().stroke(AppTheme.border))
                .lastUsedBubble(isRootGate && lastProvider == "email")
        }
        .disabled(auth.isWorking)
        .accessibilityLabel(Text(AppLocalized("使用邮箱验证码登录")))
        .accessibilityIdentifier("login.email")
    }

    // MARK: 邮箱验证码

    /// 第三条登录通道：不依赖第三方授权服务（Google 在部分网络不可用时，
    /// Apple 之外唯一的冗余通道）。后端未启用时报「暂未开放」，不阻塞其他通道。
    @ViewBuilder
    private var emailSection: some View {
        VStack(spacing: 10) {
                TextField(AppLocalized("邮箱地址"), text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(AppTheme.surface)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border))
                    .onChange(of: email) { _ in errorMessage = nil }

                if codeSent {
                    TextField(AppLocalized("验证码"), text: $otpCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .padding(14)
                        .background(AppTheme.surface)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border))
                        .onChange(of: otpCode) { _ in errorMessage = nil }

                    Button { request(.verifyEmailCode) } label: {
                        Text(AppLocalized("登录")).fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(auth.isWorking || otpCode.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button { request(.sendEmailCode) } label: {
                        if isSendingEmailCode {
                            sendingEmailCodeLabel(font: .caption.weight(.semibold))
                        } else {
                            Text(resendCooldown > 0
                                 ? String(format: AppLocalized("重新发送（%d 秒）"), resendCooldown)
                                 : AppLocalized("重新发送验证码"))
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .disabled(auth.isWorking || resendCooldown > 0)
                } else {
                    Button { request(.sendEmailCode) } label: {
                        if isSendingEmailCode {
                            sendingEmailCodeLabel(font: .body.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        } else {
                            Text(AppLocalized("发送验证码"))
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(auth.isWorking || email.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // 展开后 Apple 图标被这块表单顶掉了，留一条退路回到通道选择。
                Button {
                    withAnimation {
                        emailFlowExpanded = false
                        codeSent = false
                        otpCode = ""
                        errorMessage = nil
                    }
                } label: {
                    Text(AppLocalized("其他登录方式")).font(.caption.weight(.semibold))
                }
                .disabled(auth.isWorking)
            }
    }

    private func sendingEmailCodeLabel(font: Font) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(codeSent ? AppTheme.primary : AppTheme.primaryForeground)
            Text(AppLocalized("正在发送…"))
                .font(font)
        }
    }

    @ViewBuilder
    private var termsFooter: some View {
        if AppRegion.current == .cn {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    consentGate.setAgreement(!consentGate.hasAgreed)
                } label: {
                    Image(systemName: consentGate.hasAgreed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(
                            consentGate.hasAgreed ? AppTheme.primary : AppTheme.mutedForeground
                        )
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(AppLocalized("我已阅读并同意《服务条款》和《隐私政策》")))
                .accessibilityValue(consentGate.hasAgreed ? "checked" : "unchecked")
                .accessibilityIdentifier("login.chinaConsent")

                Text(chinaConsentAttributedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .font(.caption)
        } else {
            VStack(spacing: 4) {
                Text("继续即表示同意")
                HStack(spacing: 4) {
                    Link("服务条款", destination: URL(string: Constants.API.termsURL)!)
                    Text("与")
                    Link("隐私政策", destination: URL(string: Constants.API.privacyURL)!)
                }
            }
            .font(.caption2).foregroundColor(AppTheme.mutedForeground)
        }
    }

    /// 中国区协议说明只渲染一次；两个协议名称在原句中直接作为可点击链接。
    /// 使用本地化格式串组合，避免不同语言词序变化后依赖硬编码字符范围。
    private var chinaConsentAttributedText: AttributedString {
        let termsTitle = AppLocalized("服务条款")
        let privacyTitle = AppLocalized("隐私政策")
        let sentence = String(
            format: AppLocalized("我已阅读并同意《%@》和《%@》"),
            termsTitle,
            privacyTitle
        )
        var attributed = AttributedString(sentence)
        attributed.foregroundColor = AppTheme.mutedForeground

        let links: [(String, String)] = [
            (termsTitle, Constants.API.termsURL),
            (privacyTitle, Constants.API.privacyURL)
        ]
        for (title, urlString) in links {
            guard
                let range = attributed.range(of: title),
                let url = URL(string: urlString)
            else { continue }
            attributed[range].link = url
            attributed[range].foregroundColor = AppTheme.primaryText
            attributed[range].underlineStyle = .single
        }
        return attributed
    }

    // MARK: 动作

    private func request(_ action: LoginAction) {
        errorMessage = nil
        switch consentGate.request(
            action,
            requiresExplicitConsent: AppRegion.current == .cn
        ) {
        case .execute(let action):
            execute(action)
        case .requestConsent:
            showsConsentPrompt = true
        }
    }

    private func execute(_ action: LoginAction) {
        switch action {
        case .phone:
            showsPhoneSignIn = true
        case .google:
            signInGoogle()
        case .apple:
            signInApple()
        case .expandEmail:
            guard AppRegion.current.showsEmailSignIn else {
                emailFlowExpanded = false
                return
            }
            withAnimation { emailFlowExpanded = true }
        case .sendEmailCode:
            guard AppRegion.current.showsEmailSignIn else { return }
            sendEmailCode()
        case .verifyEmailCode:
            guard AppRegion.current.showsEmailSignIn else { return }
            verifyEmailCode()
        }
    }

    private func signInGoogle() {
        errorMessage = nil
        Task {
            do { try await auth.signInWithGoogle() }
            catch AuthError.cancelled {}
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func signInApple() {
        errorMessage = nil
        let session = AppleSignInCoordinator(
            onSuccess: { dismiss() },
            onError: { errorMessage = $0 }
        )
        appleCoordinator = session
        session.start()
    }

    private func sendEmailCode() {
        errorMessage = nil
        isSendingEmailCode = true
        Task {
            defer { isSendingEmailCode = false }
            do {
                try await auth.sendEmailOTP(to: email)
                codeSent = true
                resendCooldown = 60
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func verifyEmailCode() {
        errorMessage = nil
        Task {
            do {
                try await auth.signInWithEmailOTP(email: email, code: otpCode)
                dismiss()   // sheet 场景；根墙由 isSignedIn 切换，此处为 no-op
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
