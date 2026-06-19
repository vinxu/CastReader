//
//  LoginView.swift
//  CastReader
//
//  登录页：Google（+ Apple，见 AuthService+Apple）。登录用于跨设备同步 Pro 与额度。
//

import SwiftUI

struct LoginView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 56)).foregroundColor(AppTheme.primary)
            Text("登录 CastReader").font(.title2.weight(.bold))
            Text("跨设备同步 Pro 订阅、额度与历史")
                .font(.subheadline).foregroundColor(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
            Spacer()

            VStack(spacing: 12) {
                googleButton
                appleButton
            }

            if let e = errorMessage {
                Text(e).font(.caption).foregroundColor(AppTheme.destructive).multilineTextAlignment(.center)
            }

            termsFooter
        }
        .padding(24)
        .background(AppTheme.background.ignoresSafeArea())
        .overlay { if auth.isWorking { ProgressView().scaleEffect(1.2) } }
        .onChange(of: auth.isSignedIn) { signedIn in if signedIn { dismiss() } }
    }

    // MARK: 按钮

    @ViewBuilder
    private var googleButton: some View {
        if Constants.GoogleOAuth.isConfigured {
            Button { signInGoogle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "globe").font(.system(size: 18, weight: .bold))
                    Text("使用 Google 继续").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding()
                .background(AppTheme.surface)
                .foregroundColor(AppTheme.foreground)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border))
                .cornerRadius(12)
            }
            .disabled(auth.isWorking)
        } else {
            Text("Google 登录未配置（需填入 Constants.GoogleOAuth.clientID）")
                .font(.caption2).foregroundColor(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
        }
    }

    /// Apple 登录按钮（实现见 AuthService+Apple / 此处占位由 Task D 接入）。
    @ViewBuilder
    private var appleButton: some View {
        AppleSignInButton(
            onSuccess: { dismiss() },
            onError: { errorMessage = $0 }
        )
        .frame(height: 50)
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

    private func signInGoogle() {
        errorMessage = nil
        Task {
            do { try await auth.signInWithGoogle() }
            catch AuthError.cancelled {}
            catch { errorMessage = error.localizedDescription }
        }
    }
}
