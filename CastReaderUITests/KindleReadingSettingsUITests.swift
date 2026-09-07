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
                        form.swipeUp()
                    }
                    let name = "Kindle-settings-\(description.language)-\(appearance)-AXXXL-footnote-footer"
                    attachScreen(app, name: name, includeHierarchy: true)
                    XCTAssertTrue(footer.exists, "Missing complete localized footnote description")
                    XCTAssertEqual(footer.label, description.text)
                    XCTAssertTrue(
                        isTextFullyVisibleInForm(footer, form: form, app: app),
                        "Footer must fit fully below navigation and above the measured safe-content bottom: footer=\(footer.frame), form=\(form.frame), screen=\(app.frame), bottomProbe=\(effectiveAppearance.frame)"
                    )
                    XCTAssertTrue(app.buttons["kindleReadingSettingsDone"].isHittable)
                    app.terminate()
                }
            }
        }
    }

    private func isTextFullyVisibleInForm(_ text: XCUIElement, form: XCUIElement, app: XCUIApplication) -> Bool {
        let bottomProbe = app.otherElements["kindleFixtureColorScheme"]
        guard text.exists, form.exists, bottomProbe.exists else { return false }
        let frame = text.frame
        let visibleForm = form.frame.intersection(app.frame)
        guard !visibleForm.isNull, !visibleForm.isEmpty else { return false }
        let top = max(visibleForm.minY, app.navigationBars.firstMatch.frame.maxY)
        // The DEBUG fixture's 1-point appearance probe is anchored to the
        // settings view's safe-content bottom, outside the scrolling Form.
        // Use that measured edge: run6 observed maxY=840 on an 874-point
        // screen (34-point inset), so a fixed 44-point margin rejects visible
        // text. Keep this stricter than merely accepting the screen's bottom.
        let probeFrame = bottomProbe.frame
        guard probeFrame.height > 0, probeFrame.height <= 2,
              probeFrame.minY >= top, probeFrame.maxY <= visibleForm.maxY else { return false }
        let bottom = min(visibleForm.maxY, probeFrame.maxY)
        return frame.width > 0 && frame.height > 0 &&
            frame.minX >= visibleForm.minX && frame.maxX <= visibleForm.maxX &&
            frame.minY >= top && frame.maxY <= bottom
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
                XCTAssertTrue(nativeSwitch.waitForExistence(timeout: 5))
                for _ in 0..<5 {
                    if isControlFullyVisible(nativeSwitch, in: app) { break }
                    app.collectionViews.firstMatch.swipeUp()
                }
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
