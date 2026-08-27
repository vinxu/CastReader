//
//  CastReaderApp.swift
//  CastReader
//
//  Created by 许旭恒 on 1/7/26.
//

import SwiftUI
import UIKit

@MainActor
final class CastReaderAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        CloudStorageCenter.handleOAuthRedirect(
            url,
            sourceApplication: options[.sourceApplication] as? String
        )
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationLock.supportedOrientations
    }
}

/// Scene-scoped orientation policy used by reader integrations that cannot
/// provide a usable landscape layout. WeRead owns this lock only while its
/// reader is visible; every other CastReader surface keeps the app defaults.
@MainActor
enum AppOrientationLock {
    private struct Request {
        let orientations: UIInterfaceOrientationMask
        let order: UInt64
    }

    private static var requests: [String: Request] = [:]
    private static var requestOrder: UInt64 = 0
    private static var applicationRevision: UInt64 = 0

    static var supportedOrientations: UIInterfaceOrientationMask {
        requests.values.max(by: { $0.order < $1.order })?.orientations
            ?? defaultOrientations
    }

    static func lockPortrait(owner: String) {
        lock(.portrait, owner: owner, reason: "portrait")
    }

    /// Freeze the interface exactly where the user minimized the reader. This
    /// avoids an off-screen WKWebView receiving a rotation/reflow while its TTS
    /// session is owned by Mini Player.
    static func lockCurrent(owner: String) {
        lock(currentInterfaceOrientationMask(), owner: owner, reason: "current")
    }

    static func unlock(owner: String) {
        guard requests.removeValue(forKey: owner) != nil else { return }
        applyCurrentPolicy(reason: "unlock", owner: owner)
    }

    private static var defaultOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    private static func lock(
        _ orientations: UIInterfaceOrientationMask,
        owner: String,
        reason: String
    ) {
        requestOrder &+= 1
        requests[owner] = Request(orientations: orientations, order: requestOrder)
        applyCurrentPolicy(reason: reason, owner: owner)
    }

    private static func currentInterfaceOrientationMask() -> UIInterfaceOrientationMask {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    private static func applyCurrentPolicy(
        reason: String,
        owner: String
    ) {
        applicationRevision &+= 1
        let revision = applicationRevision
        let orientations = supportedOrientations
        // Update the delegate policy before asking UIKit to resolve geometry.
        // Dispatch one run-loop turn so the ReaderHost has an attached scene
        // even when it was presented while the device was already landscape.
        DispatchQueue.main.async {
            // A close/open or Mini Player expand can enqueue two policies in
            // one render pass. Never let the older geometry request win later.
            guard revision == applicationRevision else { return }
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState != .unattached }
            for scene in scenes {
                let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
                    ?? scene.windows.first?.rootViewController
                root?.setNeedsUpdateOfSupportedInterfaceOrientations()
                scene.requestGeometryUpdate(
                    UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
                ) { error in
                    ReaderRunLog.write(
                        "ORIENTATION \(reason) failed owner=\(owner) error=\(error.localizedDescription)"
                    )
                }
            }
            ReaderRunLog.write(
                "ORIENTATION \(reason) owner=\(owner) mask=\(orientations.rawValue)"
            )
        }
    }
}

/// 硬登录门：未登录时整个 App 只渲染登录页。
///
/// 对全部未登录用户生效，包括从旧版本升级上来的老用户——`AuthService.restore()`
/// 在 init 里同步跑完，登录过的人不会看到这道门闪一下。
///
/// MainTabView 只在登录后创建，所以常驻阅读器（ReaderHostView / KindleBookView）
/// 的生命周期不受影响；只有主动登出才会销毁它们，这与登出语义一致。
struct RootAuthGate: View {
    @ObservedObject private var auth = AuthService.shared

    /// UI 测试无法走真实的 Google/Apple 授权，所以它们需要一条绕过。沿用
    /// BoundLibraryOnboardingStore 既有的 launch-argument 约定。
    private let bypassesGate = ProcessInfo.processInfo.arguments
        .contains("-CastReaderSkipSignInGate")

    var body: some View {
        Group {
            if auth.isSignedIn || bypassesGate {
                MainTabView()
                    .id(auth.accountBoundaryID)
            } else {
                LoginView(isRootGate: true)
            }
        }
        .alert(
            AppLocalized("注销申请已提交"),
            isPresented: Binding(
                get: { auth.lastAccountDeletionReceipt != nil },
                set: { if !$0 { auth.dismissAccountDeletionReceipt() } }
            ),
            presenting: auth.lastAccountDeletionReceipt
        ) { _ in
            Button(AppLocalized("知道了")) {
                auth.dismissAccountDeletionReceipt()
            }
        } message: { receipt in
            Text(receipt.userFacingMessage)
        }
    }
}

/// Owns the asynchronous distribution bootstrap without touching any singleton
/// whose identity, cache namespace or endpoint depends on `ServiceRouting`.
/// `RouteReadyRoot` is not constructed until this coordinator publishes ready.
@MainActor
final class AppStartupCoordinator: ObservableObject {
    @Published private(set) var isReady = false

    private var didStart = false
    private var notificationObservers: [NSObjectProtocol] = []

    func start() async {
        guard !didStart else { return }
        didStart = true

        // Resolve the product/account region first. All owned compute is then
        // frozen to the same regional boundary; no authenticated payload may
        // select a different region from network location.
        let region = await AppRegion.prepareForCurrentProcess()
        _ = await ServiceRouting.bootstrapForCurrentProcess(
            appRegionResolution: region
        )
        _ = await ComputeRouting.bootstrapForCurrentProcess()
        _ = TTSEndpoint.freezeForCurrentProcess()
        _ = QuickReadEndpoint.freezeForCurrentProcess()

        // Everything below may capture the frozen route or its isolated storage
        // namespace. None of it may move above the bootstrap calls.
        _ = AudioPlaybackTemporaryFiles.prepare()
        installLifecycleObservers()

        let launchType = SystemActionStore.shared.peekPendingOrigin()?.launchType ?? "cold"
        ProductAnalytics.shared.startAppSession(launchType: launchType)
        AppFirstOpenService.shared.start()
        AdAttributionService.shared.start()
        AnalyticsLibrarySyncReceiptOutbox.shared.start()
        ProManager.shared.start()
        QuotaManager.shared.rollIfNewDay()
        VoiceCatalogService.shared.start()
        NetworkReachability.shared.start()
        YouTubeTranscriptService.resetWebsiteDataStoreIfNeeded()
        ResumeReminderManager.shared.start()

        isReady = true
    }

    private func installLifecycleObservers() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { _ in
                print("⚠️ Memory warning received")
                Task { @MainActor in
                    guard !AudioPlayerService.shared.hasActivePlayback else {
                        print("⚠️ Keeping active audio queue during memory warning")
                        return
                    }
                    AudioPlayerService.shared.clearQueue()
                }
            }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    ProductAnalytics.shared.didBecomeActive()
                    AppFirstOpenService.shared.start()
                    AdAttributionService.shared.didBecomeActive()
                    AnalyticsLibrarySyncReceiptOutbox.shared.start()
                    QuotaManager.shared.rollIfNewDay()
                    await AuthService.shared.refreshAppleCredentialState()
                    await ProManager.shared.refresh()
                    await VoiceCatalogService.shared.refreshIfStale()
                }
            }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    AdAttributionService.shared.didEnterBackground()
                    ProductAnalytics.shared.didEnterBackground()
                }
            }
        )
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// Constructing this view is the first permitted access to Visitor/Auth/UI
/// route-dependent state. SwiftUI only evaluates this branch after bootstrap.
struct RouteReadyRoot: View {
    @StateObject private var visitorService = VisitorService.shared

    var body: some View {
        RootAuthGate()
            .environmentObject(visitorService)
    }
}

@main
struct CastReaderApp: App {
    @UIApplicationDelegateAdaptor(CastReaderAppDelegate.self) private var appDelegate
    @StateObject private var startup = AppStartupCoordinator()
    @StateObject private var appLanguage = AppLanguageManager.shared
    @State private var pendingOpenURLs: [URL] = []

    init() {
        // Freeze the install classification before this version writes any
        // application defaults. Existing containers are instrumentation
        // backfills; only a clean container is a fresh install.
        AppFirstOpenService.prepareInitialState()
        CloudTemporaryFileJanitor.removeAbandonedImports()

        // App Store upgrades keep UserDefaults from earlier Debug/internal
        // installs. Production must discard those testing-only region/route
        // values before any endpoint-capturing singleton freezes the process.
        AppRegion.discardDisallowedOverride()
        ServiceRouting.discardDisallowedLocalOverride()
        ServiceRouting.migratePersistedAliases()

        #if DEBUG
        // UI tests must not inherit a service-route override written by an earlier
        // run. This flag is intentionally unavailable in release builds and runs
        // before the process snapshot is frozen.
        if ProcessInfo.processInfo.arguments.contains("-CastReaderResetServiceRouteState") {
            ServiceRouting.overrideRoute = nil
            ServiceRouting.clearBackendConfiguration()
        }

        // Seed a writable persisted region for the root-login recovery UI test.
        // Unlike `-CastReaderRegion`, this does not remain the highest-priority
        // process argument, so the picker can genuinely change AppRegion.current.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-CastReaderSeedRegionOverride"),
           index + 1 < arguments.count,
           let region = AppRegion(rawValue: arguments[index + 1]) {
            AppRegion.overrideRegion = region
        }

        if arguments.contains("-CastReaderResetGoogleDriveBinding") {
            // Reset the disclosure synchronously so the very first rendered
            // add-content flow cannot race the asynchronous Keychain cleanup.
            CloudPrivacyAcknowledgementStore.reset(.googleDrive)
            Task { @MainActor in
                await CloudStorageCenter.shared.resetGoogleDriveLocalStateForDeviceTesting()
                print("GoogleDriveOAuth local_binding_reset_complete")
            }
        }

        if arguments.contains("-CastReaderForceGoogleDriveOAuth") {
            // The verification demo must show the pre-authorization disclosure
            // on every take, but it must not mutate credentials mid-session.
            CloudPrivacyAcknowledgementStore.reset(.googleDrive)
        }
        #endif

    }

    var body: some Scene {
        WindowGroup {
            Group {
                if startup.isReady {
                    RouteReadyRoot()
                        .environment(\.locale, appLanguage.locale)
                } else {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                        .accessibilityIdentifier("distribution_bootstrap")
                }
            }
            .task {
                await startup.start()
            }
            .onOpenURL { url in
                if startup.isReady {
                    handleOpenURL(url)
                } else {
                    pendingOpenURLs.append(url)
                }
            }
            .onChange(of: startup.isReady) { _, isReady in
                guard isReady, !pendingOpenURLs.isEmpty else { return }
                let urls = pendingOpenURLs
                pendingOpenURLs.removeAll()
                for url in urls {
                    handleOpenURL(url)
                }
            }
        }
    }

    private func handleOpenURL(_ url: URL) {
        if CloudStorageCenter.isOAuthRedirectURL(url) {
            _ = CloudStorageCenter.handleOAuthRedirect(url)
        } else if StudyBoostDeepLink.matches(url) {
            StudyBoostRouter.shared.open()
        } else if url.scheme == "castreader", url.host == "youtube" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let rawURL = components?.queryItems?
                .first(where: { $0.name == "url" })?.value {
                let entryValue = components?.queryItems?
                    .first(where: { $0.name == "entry" })?.value
                let entry = entryValue.flatMap(YouTubeListenEntry.init(rawValue:)) ?? .scheme
                _ = YouTubeRouteCenter.shared.open(rawURL, entry: entry)
            }
        } else if let systemAction = SystemAction.from(url: url) {
            SystemActionStore.shared.enqueue(systemAction, origin: .deepLink)
        } else if url.scheme == "castreader", url.host == "share-inbox" {
            NotificationCenter.default.post(name: .castReaderShareInboxChanged, object: nil)
        }
    }
}
