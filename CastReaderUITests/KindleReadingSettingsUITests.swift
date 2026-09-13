import XCTest

final class KindleReadingSettingsUITests: XCTestCase {
    override func tearDown() {
        let app = XCUIApplication()
        if app.state == .runningForeground {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Kindle-settings-at-teardown"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Kindle-settings-accessibility-at-teardown"
            tree.lifetime = .keepAlways
            add(tree)
        }
        super.tearDown()
    }
    func testAllNineLanguagesInLightAndDark() {
        verifySettings(largeText: false)
    }

    func testAllNineLanguagesInLightAndDarkWithAccessibilityText() {
        verifySettings(largeText: true)
    }

    func testLongFootnoteDescriptionsAreReachableWithAccessibilityText() {
        continueAfterFailure = false
        let originalAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = originalAppearance }
        // These three descriptions were not fully visible in the switch-only
        // captures. Match the entire localized footer, including its ending;
        // finding or hitting a partially visible StaticText is insufficient.
        let descriptions: [(language: String, text: String)] = [
            ("en", "Only clearly identified superscript footnote references are skipped. Body numbers and footnote text are kept."),
            ("zh-Hans", "仅跳过可明确识别的上标脚注编号，保留正文数字和脚注内容。"),
            ("pt-BR", "Somente referências de notas em sobrescrito claramente identificadas são ignoradas. Os números do texto e o conteúdo das notas são mantidos.")
        ]
        for description in descriptions {
            for appearance in ["Light", "Dark"] {
                XCTContext.runActivity(named: "Full footnote footer: \(description.language) \(appearance) AXXXL") { _ in
                    XCUIDevice.shared.appearance = appearance == "Dark" ? .dark : .light
                    let app = XCUIApplication()
                    app.launchArguments = [
                        "-CastReaderKindleSettingsFixture", "-AppleLanguages", "(\(description.language))",
                        "-interfaceLanguage", description.language, "-CastReaderFixtureAppearance", appearance,
                        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
                    ]
                    app.launch()
                    let effectiveAppearance = app.otherElements["kindleFixtureColorScheme"]
                    XCTAssertTrue(effectiveAppearance.waitForExistence(timeout: 15))
                    XCTAssertEqual(effectiveAppearance.value as? String, appearance.lowercased())
                    let form = app.collectionViews.firstMatch
                    XCTAssertTrue(form.waitForExistence(timeout: 15))
                    let footer = app.staticTexts.matching(NSPredicate(format: "label == %@", description.text)).firstMatch
                    // SwiftUI can omit an offscreen footer from the current AX
                    // tree, so scroll the actual Form even before it exists.
                    for _ in 0..<6 {
                        if isTextFullyVisibleInForm(footer, form: form, app: app) { break }
                        if footer.exists, let viewport = footerViewport(form: form, app: app),
                           footer.frame.height > viewport.height { break }
                        form.swipeUp()
                    }
                    let name = "Kindle-settings-\(description.language)-\(appearance)-AXXXL-footnote-footer"
                    attachScreen(app, name: name, includeHierarchy: true)
                    XCTAssertTrue(footer.exists, "Missing complete localized footnote description")
                    XCTAssertEqual(footer.label, description.text)
                    if let viewport = footerViewport(form: form, app: app), footer.frame.height > viewport.height {
                        // At maximum Dynamic Type on an SE, the full paragraph
                        // is taller than the viewport. Prove that both ends
                        // are readable by scrolling, keeping the full label.
                        XCTAssertTrue(scrollFooterEdge(footer, topEdge: true, form: form, app: app))
                        attachScreen(app, name: name + "-start", includeHierarchy: true)
                        XCTAssertTrue(scrollFooterEdge(footer, topEdge: false, form: form, app: app))
                        attachScreen(app, name: name + "-end", includeHierarchy: true)
                        XCTAssertEqual(footer.label, description.text)
                    } else {
                        XCTAssertTrue(
                            isTextFullyVisibleInForm(footer, form: form, app: app),
                            "Footer must fit fully below navigation and above the measured safe-content bottom: footer=\(footer.frame), form=\(form.frame), screen=\(app.frame), bottomProbe=\(effectiveAppearance.frame)"
                        )
                    }
                    XCTAssertTrue(app.buttons["kindleReadingSettingsDone"].isHittable)
                    app.terminate()
                }
            }
        }
    }

    private func isTextFullyVisibleInForm(_ text: XCUIElement, form: XCUIElement, app: XCUIApplication) -> Bool {
        guard text.exists, let viewport = footerViewport(form: form, app: app) else { return false }
        let frame = text.frame
        return frame.width > 0 && frame.height > 0 &&
            frame.minX >= viewport.minX && frame.maxX <= viewport.maxX &&
            frame.minY >= viewport.minY - 0.5 && frame.maxY <= viewport.maxY + 0.5
    }

    private func scrollFooterEdge(_ text: XCUIElement, topEdge: Bool, form: XCUIElement, app: XCUIApplication) -> Bool {
        for _ in 0..<10 {
            guard text.exists, let viewport = footerViewport(form: form, app: app) else { return false }
            let frame = text.frame
            let edge = topEdge ? frame.minY : frame.maxY
            let edgeBand = min(100, viewport.height / 3)
            let lower = topEdge ? viewport.minY : viewport.maxY - edgeBand
            let upper = topEdge ? viewport.minY + edgeBand : viewport.maxY
            if frame.width > 0, frame.minX >= viewport.minX, frame.maxX <= viewport.maxX,
               edge >= lower, edge <= upper { return true }
            let target = topEdge ? viewport.minY + 8 : viewport.maxY - 8
            let distance = min(180, max(-180, target - edge))
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
        }
        return false
    }

    private func footerViewport(form: XCUIElement, app: XCUIApplication) -> CGRect? {
        let bottomProbe = app.otherElements["kindleFixtureColorScheme"]
        guard form.exists, bottomProbe.exists else { return nil }
        let visibleForm = form.frame.intersection(app.frame)
        guard !visibleForm.isNull, !visibleForm.isEmpty else { return nil }
        let top = max(visibleForm.minY, app.navigationBars.firstMatch.frame.maxY)
        // The DEBUG fixture's 1-point appearance probe is anchored to the
        // settings view's safe-content bottom, outside the scrolling Form.
        // Use that measured edge: run6 observed maxY=840 on an 874-point
        // screen (34-point inset), so a fixed 44-point margin rejects visible
        // text. Keep this stricter than merely accepting the screen's bottom.
        let probeFrame = bottomProbe.frame
        guard probeFrame.height > 0, probeFrame.height <= 2,
              probeFrame.minY >= top, probeFrame.maxY <= visibleForm.maxY else { return nil }
        let bottom = min(visibleForm.maxY, probeFrame.maxY)
        return CGRect(x: visibleForm.minX, y: top, width: visibleForm.width, height: bottom - top)
    }

    private func isControlFullyVisible(_ control: XCUIElement, in app: XCUIApplication) -> Bool {
        guard control.exists, control.isHittable else { return false }
        let frame = control.frame
        let screen = app.frame
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        return frame.width > 0 && frame.height > 0 &&
            frame.minX >= screen.minX && frame.maxX <= screen.maxX &&
            frame.minY >= max(screen.minY + 44, navigationBottom) &&
            frame.maxY <= screen.maxY - 44
    }

    private func attachScreen(_ app: XCUIApplication, name: String, includeHierarchy: Bool = false) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if includeHierarchy {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = name + "-accessibility"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
    }

    private func verifySettings(largeText: Bool) {
        continueAfterFailure = false
        let originalAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = originalAppearance }
        let locales = ["en", "zh-Hans", "ja", "es", "fr", "de", "pt-BR", "it", "hi"]
        // Check the full localized phrase: Japanese correctly shares the word
        // 脚注 with Chinese, so a substring-based fallback check rejects valid UI.
        let footnoteLabels = [
            "en": "Skip footnote reference numbers",
            "zh-Hans": "跳过脚注引用编号",
            "ja": "脚注の参照番号をスキップ",
            "es": "Omitir números de referencia a notas",
            "fr": "Ignorer les numéros d’appel de note",
            "de": "Fußnotenverweise überspringen",
            "pt-BR": "Ignorar números de referência de notas",
            "it": "Salta i numeri di richiamo delle note",
            "hi": "फ़ुटनोट संदर्भ संख्याएँ छोड़ें"
        ]
        for language in locales {
            for appearance in ["Light", "Dark"] {
                XCUIDevice.shared.appearance = appearance == "Dark" ? .dark : .light
                XCTAssertEqual(XCUIDevice.shared.appearance, appearance == "Dark" ? .dark : .light)
                let app = XCUIApplication()
                app.launchArguments = [
                    "-CastReaderKindleSettingsFixture", "-AppleLanguages", "(\(language))",
                    "-interfaceLanguage", language, "-CastReaderFixtureAppearance", appearance,
                ]
                if largeText {
                    app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                }
                app.launch()
                let effectiveAppearance = app.otherElements["kindleFixtureColorScheme"]
                XCTAssertTrue(effectiveAppearance.waitForExistence(timeout: 15))
                XCTAssertEqual(effectiveAppearance.value as? String, appearance.lowercased())
                let increase = app.buttons["kindleFontIncrease"]
                let decrease = app.buttons["kindleFontDecrease"]
                XCTAssertTrue(increase.waitForExistence(timeout: 15))
                XCTAssertTrue(increase.isHittable)
                XCTAssertTrue(decrease.isHittable)
                XCTAssertGreaterThanOrEqual(increase.frame.height, 44)
                XCTAssertGreaterThanOrEqual(decrease.frame.width, 44)
                increase.tap()
                XCTAssertEqual(app.staticTexts["kindleFontValue"].label, "7")
                decrease.tap()
                XCTAssertEqual(app.staticTexts["kindleFontValue"].label, "6")
                let caseName = "Kindle-settings-\(language)-\(appearance)-\(largeText ? "AXXXL" : "normal")"
                attachScreen(app, name: caseName + "-font-controls")
                let toggle = app.switches["kindleSkipFootnotes"]
                // SwiftUI exposes a row-sized Switch containing the actual
                // native control. The row can be hittable while the control
                // sits below the screen in a long accessibility-size label.
                let nativeSwitch = toggle.descendants(matching: .switch).firstMatch
                for _ in 0..<8 {
                    if isControlFullyVisible(nativeSwitch, in: app) { break }
                    // A full swipe can overshoot this control on an SE-size
                    // screen. Move toward the measured visible center and
                    // correct in either direction without relaxing visibility.
                    let form = app.collectionViews.firstMatch
                    let top = max(app.frame.minY + 44, app.navigationBars.firstMatch.frame.maxY)
                    let bottom = app.frame.maxY - 44
                    // Form may not create the offscreen switch until it is
                    // scrolled into view, especially with Japanese AXXXL text.
                    let frame = nativeSwitch.exists ? nativeSwitch.frame : .zero
                    let distance = frame.height > 0
                        ? min(180, max(-180, (top + bottom) / 2 - frame.midY)) : -180
                    let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
                }
                XCTAssertTrue(nativeSwitch.waitForExistence(timeout: 5))
                attachScreen(app, name: caseName + "-before-toggle", includeHierarchy: true)
                XCTAssertTrue(isControlFullyVisible(nativeSwitch, in: app), "Native switch is not fully visible: \(nativeSwitch.frame)")
                XCTAssertEqual(nativeSwitch.value as? String, "1", "Each fixture must begin enabled")
                // One semantic tap on the native control; no blind retry that
                // could hide a broken control or undo a successful toggle.
                nativeSwitch.tap()
                let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: nativeSwitch)
                let changeResult = XCTWaiter.wait(for: [changed], timeout: 5)
                // Capture before assertions/defer restores system appearance,
                // so a failed Dark case retains its actual rendered evidence.
                attachScreen(app, name: caseName, includeHierarchy: true)
                XCTAssertEqual(changeResult, .completed)
                XCTAssertEqual(toggle.value as? String, "0", "The row and native control must report the same state")
                XCTAssertTrue(app.buttons["kindleReadingSettingsDone"].isHittable)
                XCTAssertEqual(toggle.label, footnoteLabels[language], "Unexpected footnote label for \(language)")
                if language != "zh-Hans" {
                    XCTAssertFalse(app.staticTexts["阅读设置"].exists)
                    XCTAssertFalse(app.staticTexts["Kindle 字号"].exists)
                }
                app.terminate()
            }
        }
    }
}
