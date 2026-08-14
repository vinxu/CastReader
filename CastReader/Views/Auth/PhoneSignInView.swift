//
//  PhoneSignInView.swift
//  CastReader
//
//  中国区手机号登录。
//
//  合规要点（国内应用商店会逐条检查）：
//  - 仅能从已完成协议确认的中国区登录页进入；这里再次防御性校验；
//  - 页面上不展示完整手机号以外的任何身份信息，日志与埋点不含号码；
//  - 提供明确的错误原因与重试路径。
//

import SwiftUI

struct PhoneSignInView: View {
    let hasAcceptedTerms: Bool

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthService.shared

    @State private var phone = ""
    @State private var code = ""
    @State private var countdown = PhoneResendCountdown()
    @State private var remainingSeconds = 0
    @State private var hasRequestedCode = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var isSending = false
    @FocusState private var focusedField: Field?

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum Field {
        case phone
        case code
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    phoneField
                    // Keep verification available independently of the send
                    // request. A user may already have a valid SMS while a
                    // resend is rate-limited or the gateway is temporarily
                    // unreachable.
                    codeField
                    if let noticeMessage { noticeBanner(noticeMessage) }
                    if let errorMessage { errorBanner(errorMessage) }
                    primaryButton
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(AppLocalized("手机号登录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("取消")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onReceive(ticker) { _ in
            remainingSeconds = countdown.remainingSeconds()
        }
        .onChange(of: auth.isSignedIn) { signedIn in
            if signedIn { dismiss() }
        }
        .task { focusedField = .phone }
    }

    // MARK: - 分区

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalized("用手机号登录"))
                .font(.title2.weight(.bold))
                .foregroundColor(AppTheme.foreground)
            Text(AppLocalized("登录后可在多台设备同步会员与免费额度。"))
                .font(.subheadline)
                .foregroundColor(AppTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var phoneField: some View {
        HStack(spacing: 10) {
            Text(ChinaPhoneNumber.countryCode)
                .font(.body.weight(.semibold))
                .foregroundColor(AppTheme.mutedForeground)
            TextField(AppLocalized("请输入手机号"), text: $phone)
                .keyboardType(.numberPad)
                .textContentType(.telephoneNumber)
                .focused($focusedField, equals: .phone)
                .onChange(of: phone) { newValue in
                    // 只保留数字，避免粘贴带进分隔符导致校验莫名失败。
                    let digits = newValue.filter(\.isNumber)
                    let trimmed = String(digits.prefix(11))
                    if trimmed != newValue { phone = trimmed }
                    errorMessage = nil
                }
                .accessibilityIdentifier("phoneSignIn.phoneField")
        }
        .padding(14)
        .background(AppTheme.surface)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border))
    }

    private var codeField: some View {
        HStack(spacing: 10) {
            TextField(AppLocalized("6 位验证码"), text: $code)
                .keyboardType(.numberPad)
                // 让系统从短信里自动填充，用户不必切出去看。
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .code)
                .onChange(of: code) { newValue in
                    let sanitized = PhoneVerificationCode.sanitize(newValue)
                    if sanitized != newValue { code = sanitized }
                    errorMessage = nil
                }
                .accessibilityIdentifier("phoneSignIn.codeField")

            Button {
                Task { await requestCode() }
            } label: {
                HStack(spacing: 6) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AppTheme.primaryText)
                    }
                    Text(resendTitle)
                        .lineLimit(1)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(canResend ? AppTheme.primaryText : AppTheme.mutedForeground)
            .disabled(!canResend)
            .accessibilityIdentifier("phoneSignIn.resend")
        }
        .padding(14)
        .background(AppTheme.surface)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border))
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundColor(AppTheme.destructive)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("phoneSignIn.error")
    }

    private func noticeBanner(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle.fill")
        }
        .foregroundColor(AppTheme.primaryText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.primary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("phoneSignIn.notice")
    }

    @ViewBuilder
    private var primaryButton: some View {
        VStack(spacing: 10) {
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 8) {
                    if auth.isWorking {
                        ProgressView().tint(AppTheme.buttonPrimaryForeground)
                    }
                    Text(AppLocalized("登录"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .background(primaryEnabled ? AppTheme.buttonPrimary : AppTheme.buttonPrimary.opacity(0.45))
                .foregroundColor(AppTheme.buttonPrimaryForeground)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(!primaryEnabled)
            .accessibilityIdentifier("phoneSignIn.primary")

            HStack(spacing: 12) {
                Link(AppLocalized("服务条款"), destination: URL(string: Constants.API.termsURL)!)
                Link(AppLocalized("隐私政策"), destination: URL(string: Constants.API.privacyURL)!)
            }
            .font(.caption)
            .foregroundColor(AppTheme.mutedForeground)
        }
    }

    // MARK: - 状态

    private var isPhoneValid: Bool {
        ChinaPhoneNumber.normalize(phone) != nil
    }

    /// The outcome of a prior send is deliberately not part of this gate, so an
    /// existing code remains usable after failure/rate-limit. Only an in-flight
    /// send pauses submission to avoid racing a challenge replacement.
    private var primaryEnabled: Bool {
        hasAcceptedTerms
            && isPhoneValid
            && PhoneVerificationCode.isComplete(code)
            && !auth.isWorking
            && !isSending
    }

    private var canResend: Bool {
        hasAcceptedTerms
            && isPhoneValid
            && remainingSeconds == 0
            && !auth.isWorking
            && !isSending
    }

    private var resendTitle: String {
        if remainingSeconds > 0 {
            return String(format: AppLocalized("%d 秒后重发"), remainingSeconds)
        }
        return hasRequestedCode
            ? AppLocalized("重新获取")
            : AppLocalized("获取验证码")
    }

    // MARK: - 动作

    private func requestCode() async {
        guard hasAcceptedTerms else {
            errorMessage = AppLocalized("请先阅读并同意服务条款和隐私政策")
            return
        }
        guard isPhoneValid else {
            errorMessage = PhoneAuthError.invalidPhone.errorDescription
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            let challenge = try await PhoneAuthService.shared.sendCode(phone: phone)
            countdown.start(seconds: challenge.resendAfterSeconds)
            remainingSeconds = countdown.remainingSeconds()
            hasRequestedCode = true
            errorMessage = nil
            // 后端未接通时告诉用户该输什么，否则会卡在等短信。
            noticeMessage = challenge.usedLocalFallback
                ? String(
                    format: AppLocalized("短信服务尚未开通，本次请输入体验验证码 %@"),
                    PhoneAuthService.LocalFallback.presetCode
                )
                : nil
            focusedField = .code
        } catch let error as PhoneAuthError {
            // 频控要按服务端给的秒数起倒计时，否则用户会反复点到再次被拒。
            if case .tooManyRequests(let retryAfter) = error, retryAfter > 0 {
                countdown.start(seconds: retryAfter)
                remainingSeconds = countdown.remainingSeconds()
            }
            errorMessage = error.errorDescription
        } catch {
            errorMessage = PhoneAuthError.network.errorDescription
        }
    }

    private func submit() async {
        guard hasAcceptedTerms else {
            errorMessage = AppLocalized("请先阅读并同意服务条款和隐私政策")
            return
        }
        guard isPhoneValid else {
            errorMessage = PhoneAuthError.invalidPhone.errorDescription
            return
        }
        guard PhoneVerificationCode.isComplete(code) else {
            errorMessage = PhoneAuthError.invalidCode.errorDescription
            return
        }
        do {
            try await auth.signInWithPhone(phone: phone, code: code)
            errorMessage = nil
        } catch let error as PhoneAuthError {
            errorMessage = error.errorDescription
            if error == .invalidCode || error == .codeExpired {
                code = ""
                focusedField = .code
            }
        } catch let error as AuthError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = PhoneAuthError.network.errorDescription
        }
    }
}
