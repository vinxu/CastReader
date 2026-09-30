//
//  AppleSignInButton.swift
//  CastReader
//
//  原生 Sign in with Apple。需 entitlement com.apple.developer.applesignin。
//  使用系统标准按钮；带动作入口的版本保留登录页统一的协议同意流程。
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

/// 系统负责 Apple 标志、完整标题和本地化；点击先进入与其他登录方式相同的
/// consent gate，再由现有 AppleSignInCoordinator 发起授权。
struct AppleSignInActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    var action: () -> Void

    var body: some View {
        NativeAppleSignInActionButton(
            style: colorScheme == .dark ? .white : .black,
            action: action
        )
        // ASAuthorizationAppleIDButton 的样式只能在初始化时设置。
        .id(colorScheme)
    }
}

private struct NativeAppleSignInActionButton: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let style: ASAuthorizationAppleIDButton.Style
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: style)
        button.cornerRadius = 12
        button.accessibilityIdentifier = "login.apple"
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        button.isEnabled = isEnabled
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}

final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate,
                                    ASAuthorizationControllerPresentationContextProviding {
    private let onSuccess: () -> Void
    private let onError: (String) -> Void

    private weak var presentationWindow: UIWindow?

    init(presentationWindow: UIWindow? = nil, onSuccess: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.presentationWindow = presentationWindow
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
        presentationWindow ?? ASPresentationAnchor()
    }
}
