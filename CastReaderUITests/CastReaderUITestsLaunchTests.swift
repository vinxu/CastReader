//
//  CastReaderUITestsLaunchTests.swift
//  CastReaderUITests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest

class CastReaderUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        // Language and appearance configurations are covered by dedicated UI tests.
        // Running this generic launch test for every Xcode-generated configuration
        // creates hundreds of redundant launches on Xcode 26.
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate"]
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A connection probe for the authorized physical release device. No login
    /// bypass, account reset, generated audio, or synthetic content is enabled.
    func testAuthorizedDeviceHomeWithoutAuthenticationBypass() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_DEVICE_RELEASE_ACCEPTANCE"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipLibraryOnboarding", "-CastReaderRegion", "global",
                               "-interfaceLanguage", "en", "-auto_play", "NO"]
        app.launch()
        let home = app.buttons["plusImportButton"]
        let ready = NSPredicate { _, _ in
            home.isHittable || app.buttons["readerMinimizeButton"].isHittable
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: 30), .completed)
        if !home.isHittable { app.buttons["readerMinimizeButton"].tap() }
        XCTAssertTrue(home.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "authorized-device-normal-home"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
