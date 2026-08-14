//
//  LoginView.swift
//  CastReader
//
//  登录页：Google + Apple（见 AuthService+Apple）+ 邮箱验证码（better-auth email-otp）。
//  既作 sheet（付费墙「登录邮箱同步 Pro」等入口），也作 RootAuthGate 的全屏硬登录墙。
//

import SwiftUI

struct LoginView: View {
    /// 作为根登录墙时为 true：展示价值主张（可听的内容源）。
    /// sheet 场景（付费墙「登录邮箱同步 Pro」等入口）保持原有的紧凑形态。
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
            PhoneSignInView()
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

    /// 手机号（中国区）、Google 与 Apple 都使用等高的完整按钮；Apple 不能降级
    /// 成更小的次要入口，否则会触发 App Store 4.8 的等价登录选项风险。
    private var channelStack: some View {
        VStack(spacing: 14) {
            phoneButton
            googleButton
            appleButton
            if emailFlowExpanded {
                emailSection
            } else {
                emailSecondaryChannel
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
        let sources: [(String, String)] = [
            ("book.closed", "Kindle"),
            ("book", AppLocalized("微信读书")),
            ("doc.richtext", "PDF"),
            ("globe", AppLocalized("网页")),
            ("play.rectangle", "YouTube"),
        ]
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

    /// sheet 场景（付费墙里点「登录邮箱同步 Pro」等）：用户已经在用 App 了，
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
        if AppRegion.current.showsPhoneSignIn {
            Button { showsPhoneSignIn = true } label: {
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

    /// Google 登录保留为完整可选通道，中国区也不移除。
    @ViewBuilder
    private var googleButton: some View {
        if Constants.GoogleOAuth.isConfigured {
            Button { signInGoogle() } label: {
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
        } else {
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

    private var appleButton: some View {
        AppleSignInButton(
            onSuccess: { dismiss() },
            onError: { errorMessage = $0 }
        )
        .frame(height: 50)
        .disabled(auth.isWorking)
        .accessibilityIdentifier("login.apple")
    }

    /// 邮箱验证码保留为兜底入口，展开后原地显示表单。
    private var emailSecondaryChannel: some View {
        HStack {
            emailIconButton
        }
        .frame(maxWidth: .infinity)
    }

    /// 邮箱验证码的收起态：兜底通道（Google/Apple 都不可用时才需要），点开展成表单。
    private var emailIconButton: some View {
        Button { withAnimation { emailFlowExpanded = true } } label: {
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

                    Button { verifyEmailCode() } label: {
                        Text(AppLocalized("登录")).fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(auth.isWorking || otpCode.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button { sendEmailCode() } label: {
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
                    Button { sendEmailCode() } label: {
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

    private var termsFooter: some View {
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

    // MARK: 动作

    private func signInGoogle() {
        errorMessage = nil
        Task {
            do { try await auth.signInWithGoogle() }
            catch AuthError.cancelled {}
            catch { errorMessage = error.localizedDescription }
        }
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
