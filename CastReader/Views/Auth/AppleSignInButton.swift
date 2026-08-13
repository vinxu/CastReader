//
//  AppleSignInButton.swift
//  CastReader
//
//  原生 Sign in with Apple。需 entitlement com.apple.developer.applesignin。
//  提供两种形态：标准按钮（sheet 场景）与圆形图标按钮（登录墙的次要通道）。
//

import SwiftUI
import AuthenticationServices

struct AppleSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    var onSuccess: () -> Void
    var onError: (String) -> Void

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                Task {
                    let ok = await AuthService.shared.handleAppleAuthorization(authorization)
                    await MainActor.run { ok ? onSuccess() : onError(AppLocalized("Apple 登录失败")) }
                }
            case .failure(let error):
                let ns = error as NSError
                if ns.code == ASAuthorizationError.canceled.rawValue { return }
                onError(error.localizedDescription)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .cornerRadius(12)
    }
}

/// 圆形图标形态的 Apple 登录。
///
/// `SignInWithAppleButton` 的样式是固定的，做不成圆形图标，所以这里自己发起
/// `ASAuthorizationController`，授权结果仍交给 `AuthService.handleAppleAuthorization`
/// 处理（存档、换 backendUserId、刷 Pro 的逻辑完全共用）。
///
/// 按 Apple 品牌规范：纯黑/纯白 Apple 标志、周围留足空白、不加描边以外的装饰。
struct AppleSignInIconButton: View {
    var onSuccess: () -> Void
    var onError: (String) -> Void
    /// 上次登录用的就是 Apple：描主色边提示（图标放不下文字标签）。
    var isLastUsed = false

    /// 必须持有 coordinator：`ASAuthorizationController` 只弱引用 delegate，
    /// 不留强引用的话面板还没弹出来它就被释放了，回调永远不来。
    @State private var coordinator: AppleSignInCoordinator?

    var body: some View {
        Button {
            let session = AppleSignInCoordinator(onSuccess: onSuccess, onError: onError)
            coordinator = session
            session.start()
        } label: {
            Image(systemName: "apple.logo")
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(AppTheme.foreground)
                .frame(width: 44, height: 44)
                .background(AppTheme.surface, in: Circle())
                .overlay(Circle().stroke(AppTheme.border))
                .lastUsedBubble(isLastUsed)
        }
        .accessibilityLabel(Text(AppLocalized("使用 Apple 登录")))
    }
}

final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate,
                                    ASAuthorizationControllerPresentationContextProviding {
    private let onSuccess: () -> Void
    private let onError: (String) -> Void

    init(onSuccess: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.onSuccess = onSuccess
        self.onError = onError
        super.init()
    }

    func start() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            let ok = await AuthService.shared.handleAppleAuthorization(authorization)
            ok ? onSuccess() : onError(AppLocalized("Apple 登录失败"))
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        // 用户主动取消不是错误，不弹提示。
        guard (error as NSError).code != ASAuthorizationError.canceled.rawValue else { return }
        onError(error.localizedDescription)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
