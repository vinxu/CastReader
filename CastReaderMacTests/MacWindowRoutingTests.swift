import XCTest
import UIKit
import SwiftUI
import WebKit
@testable import CastReader

@MainActor
final class MacWindowRoutingTests: XCTestCase {
    func testSidebarKeepsPageStateAndOnlyLaysOutTheSelectedController() {
        let container = MacSidebarPageController()
        container.loadViewIfNeeded()
        container.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        var built: [Int] = []
        func page(_ tab: Int) -> AnyView { built.append(tab); return AnyView(Text("Page \(tab)")) }
        container.select(0, content: page)
        let home = container.pages[0]
        XCTAssertEqual(built, [0], "Unvisited pages must not be built during a click")
        container.select(3, content: page)
        let library = container.pages[3]
        for tab in [0, 3, 0, 3, 0] { container.select(tab, content: page) }
        XCTAssertTrue(container.pages[0] === home)
        XCTAssertTrue(container.pages[3] === library)
        XCTAssertEqual(container.children.count, 1)
        XCTAssertTrue(container.children.first === home)
        XCTAssertNil(library?.view.superview, "Inactive content cannot cause layout feedback")
        XCTAssertNil(library?.parent)
        XCTAssertEqual(home?.view.frame.size, container.view.bounds.size)
        XCTAssertEqual(container.selectedTab, 0)
    }

    func testMinimizedWeReadIgnoresNavigationHeightAndAppliesOnlySettledViewport() async throws {
        let web = WKWebView()
        let original = CGSize(width: 1024, height: 598)
        let container = WebReaderContainerView(webView: web, isWeRead: true,
            isKobo: false, initialSurfaceSize: original, loadAction: {})
        let originalFrame = web.frame
        container.setReaderPresented(false)
        container.bounds.size.height = 578
        container.layoutSubviews()
        XCTAssertEqual(web.frame, originalFrame, "Minimizing must not repaginate the hidden provider")
        container.setReaderPresented(true)
        container.layoutSubviews()
        XCTAssertEqual(web.frame, originalFrame, "Intermediate expand geometry must not reach WebKit")
        container.bounds.size = original
        container.layoutSubviews()
        try await Task.sleep(for: .milliseconds(750))
        container.layoutSubviews()
        XCTAssertEqual(web.frame, originalFrame)
        container.bounds.size = CGSize(width: 900, height: 550)
        container.layoutSubviews()
        XCTAssertEqual(web.frame.size, CGSize(width: 900, height: 550), "Visible window resizing must still work")
        container.setReaderPresented(false)
        container.setReaderPresented(true)
        container.setReaderPresented(false)
        container.bounds.size.height = 500
        try await Task.sleep(for: .milliseconds(750))
        container.layoutSubviews()
        XCTAssertEqual(web.frame.height, 550, "A stale expand callback must not resize a minimized reader")
    }

    func testShareBeforeWindowAttachmentWaitsForDestinationFocusAndIsConsumedOnce() {
        let registry = ReaderSceneRegistry.shared
        let destination = ReaderSceneContext()
        let other = ReaderSceneContext()
        let a = UIWindow()
        let b = UIWindow()
        defer {
            registry.disconnected(destination)
            registry.disconnected(other)
        }
        destination.handleOpenURL(URL(string: "castreader://share-inbox")!)
        XCTAssertFalse(destination.takePendingShareInboxRequest(isActive: true))
        destination.window = a
        other.window = b
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: b)
        XCTAssertFalse(destination.takePendingShareInboxRequest(isActive: true))
        XCTAssertFalse(other.takePendingShareInboxRequest(isActive: true))
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: a)
        XCTAssertFalse(destination.takePendingShareInboxRequest(isActive: false))
        XCTAssertTrue(destination.takePendingShareInboxRequest(isActive: true))
        XCTAssertFalse(destination.takePendingShareInboxRequest(isActive: true))
    }

    func testFinderImportFollowsFocusedReaderAndIgnoresAuxiliaryWindows() {
        let registry = ReaderSceneRegistry.shared
        let first = ReaderSceneContext()
        let second = ReaderSceneContext()
        let a = UIWindow()
        let b = UIWindow()
        let auxiliary = UIWindow()
        first.window = a
        second.window = b
        defer {
            registry.disconnected(first)
            registry.disconnected(second)
        }
        let file = URL(fileURLWithPath: "/tmp/mac-window-routing.txt")
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: b)
        XCTAssertTrue(second.isKeyWindow)
        XCTAssertFalse(first.isKeyWindow)
        registry.openFile(file)
        XCTAssertEqual(second.pendingFileURLs, [file])
        XCTAssertTrue(first.pendingFileURLs.isEmpty)

        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: auxiliary)
        XCTAssertTrue(registry.presentationContext === second)
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: a)
        XCTAssertTrue(registry.presentationContext === first)
        registry.openFile(file)
        XCTAssertEqual(first.pendingFileURLs, [file])

        registry.disconnected(first)
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: b)
        XCTAssertTrue(registry.presentationContext === second)
    }
}
