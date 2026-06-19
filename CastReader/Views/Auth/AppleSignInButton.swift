//
//  AppleSignInButton.swift
//  CastReader
//
//  原生 SwiftUI Sign in with Apple 按钮。需 entitlement com.apple.developer.applesignin。
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
                    await MainActor.run { ok ? onSuccess() : onError(String(localized: "Apple 登录失败")) }
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
