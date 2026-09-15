import XCTest

final class VoiceExploreUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private let publicID = "vl_083fdead97ec221573f3"
    private func launch(_ language: String = "en", fixtureDirectory: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderVoiceExploreFixture", "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-AppleLanguages", "(\(language))", "-interfaceLanguage", language]
        app.launchEnvironment["CASTREADER_VOICE_FIXTURE_DIRECTORY"] = (fixtureDirectory ?? Bundle(for: Self.self).resourceURL!.appendingPathComponent("VoiceDiscovery")).path
        app.launch()
        return app
    }

    func testWeeklyCollectionPreviewFavoriteAndLanguageIdentity() {
        let app = launch()
        let weekly = app.descendants(matching: .any).matching(identifier: "voiceEdition_weekly-stories").firstMatch
        XCTAssertTrue(weekly.waitForExistence(timeout: 20))
        attach(app, "voice-discovery-feed-en")
        XCTAssertTrue(app.buttons["presetVoiceSelect_am_fenrir"].exists)
        let featured = app.buttons["voiceFeaturedClones"]
        reveal(featured, in: app)
        XCTAssertTrue(app.staticTexts["voiceClonedSelectionNote"].exists)
        featured.tap()
        XCTAssertTrue(app.navigationBars["Curated voices"].waitForExistence(timeout: 5))
        let preview = app.buttons["voicePreview_\(publicID)"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        let playing = NSPredicate(format: "value ==[c] %@", "playing")
        expectation(for: playing, evaluatedWith: preview)
        waitForExpectations(timeout: 10)
        preview.tap()
        app.buttons["voiceFavorite_\(publicID)"].tap()
        XCTAssertTrue(app.navigationBars["Curated voices"].exists)
        app.buttons["voiceQuota_\(publicID)"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 hours per month")).firstMatch.exists)
        attach(app, "voice-discovery-monthly-allowance")
        app.alerts.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.segmentedControls.buttons["Favorites"].tap()
        XCTAssertTrue(app.buttons["presetVoiceSelect_\(publicID)"].waitForExistence(timeout: 5))
        app.buttons["Language"].tap()
        let search = app.searchFields["Search Languages"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Chinese")
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chinese")).firstMatch.tap()
        XCTAssertTrue(app.buttons["presetVoiceSelect_\(publicID)"].waitForExistence(timeout: 5))
        attach(app, "voice-discovery-favorite-chinese")
    }

    func testCompactChineseHeaderAndSearch() {
        let app = launch("zh-Hans")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceEdition_weekly-stories").firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["常规音色 · Pro 不限时"].exists)
        XCTAssertFalse(app.staticTexts["按成功生成的音频时长计量；试听和重复播放已生成的音频不扣额度。"].exists)
        attach(app, "voice-discovery-feed-zh")
        reveal(app.buttons["voiceTopic_stories"], in: app)
        attach(app, "voice-discovery-categories-zh")
        XCTAssertTrue(app.buttons["voiceTopic_stories"].waitForExistence(timeout: 5))
        app.buttons["voiceTopic_stories"].tap()
        let search = app.textFields["voiceSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Heart")
        XCTAssertTrue(app.buttons["presetVoiceSelect_af_heart"].waitForExistence(timeout: 5))
        attach(app, "voice-discovery-topic-search")
        app.buttons["presetVoiceSelect_af_heart"].tap()
        XCTAssertEqual(app.buttons["presetVoiceSelect_af_heart"].value as? String, "已选择")
    }

    func testNineLanguageVoiceDiscoveryAndAllowanceControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("CastReader/Localizable.xcstrings"))) as! [String: Any]
        let strings = catalog["strings"] as! [String: Any]
        func localized(_ key: String, _ language: String) throws -> String {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let locales = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let value = try XCTUnwrap(locales[language] as? [String: Any])
            let unit = try XCTUnwrap(value["stringUnit"] as? [String: Any])
            return try XCTUnwrap(unit["value"] as? String)
        }
        for language in ["en", "zh-Hans", "ja", "es", "fr", "de", "pt-BR", "it", "hi"] {
            let app = launch(language)
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceEdition_weekly-stories")
                .firstMatch.waitForExistence(timeout: 20), language)
            XCTAssertTrue(app.staticTexts[try localized("本周发现", language)].exists, language)
            attach(app, "release-voice-feed-" + language)
            let browse = app.buttons["voiceBrowseAll"]
            reveal(browse, in: app)
            XCTAssertTrue(browse.isHittable, language)
            browse.tap()
            let tabs = app.segmentedControls["voiceCatalogTabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 5), language)
            let regular = tabs.buttons[try localized("常规音色", language)]
            let curated = tabs.buttons[try localized("精选音色", language)]
            XCTAssertTrue(regular.isSelected, language)
            XCTAssertTrue(curated.isHittable, language)
            XCTAssertTrue(app.textFields["voiceSearchField"].isHittable, language)
            curated.tap()
            let note = app.staticTexts["voiceClonedSelectionNote"]
            XCTAssertTrue(note.waitForExistence(timeout: 5), language)
            XCTAssertEqual(note.label, try localized("克隆音色 · 多语言适用 · 生成消耗月额度", language))
            let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voicePreview_vl_")).firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 5), language)
            XCTAssertTrue(preview.isHittable, language)
            XCTAssertGreaterThanOrEqual(preview.frame.width, 44, language)
            XCTAssertGreaterThanOrEqual(preview.frame.height, 44, language)
            attach(app, "release-voice-curated-" + language)
            let quota = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voiceQuota_vl_")).firstMatch
            quota.tap()
            XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), language)
            attach(app, "release-voice-allowance-" + language)
            app.alerts.buttons.firstMatch.tap()
            XCTAssertTrue(curated.isSelected, language)
            app.terminate()
        }
    }

    func testReleaseStoreScreenshotsUseLiveLocalizedDiscovery() throws {
        guard ProcessInfo.processInfo.environment["CASTREADER_RELEASE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Opt-in App Store capture using the live public voice catalog")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("CastReader/Localizable.xcstrings"))) as! [String: Any]
        let strings = catalog["strings"] as! [String: Any]
        let url = URL(string: "https://api.castreader.ai/api/tts/mobile-catalog?region=international")!
        let data = try Data(contentsOf: url)
        let publicCatalog = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let edition = try XCTUnwrap(publicCatalog["discovery"] as? [String: Any])
        let modules = try XCTUnwrap(edition["modules"] as? [[String: Any]])
        let story = try XCTUnwrap(modules.first { ($0["id"] as? String) == "international-everyday" })
        let titles = try XCTUnwrap(story["title"] as? [String: String])
        for language in ["en", "zh-Hans", "ja", "es", "fr", "de", "pt-BR", "it", "hi"] {
            let code = language.split(separator: "-").first.map(String.init)!
            let title = try XCTUnwrap(titles[code], "Missing published editorial translation: \(language)")
            let app = XCUIApplication()
            app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
                "-CastReaderRegion", "global", "-CastReaderServiceRoute", "global",
                "-AppleLanguages", "(\(language))", "-interfaceLanguage", language,
                "-voice_browser_language_v1", code]
            app.launch()
            let entry = try XCTUnwrap(strings["音色"] as? [String: Any])
            let locales = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let localization = try XCTUnwrap(locales[language] as? [String: Any])
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
            let label = try XCTUnwrap(unit["value"] as? String)
            let tab = app.tabBars.buttons[label]
            XCTAssertTrue(tab.waitForExistence(timeout: 20), language)
            tab.tap()
            let voice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "presetVoiceSelect_")).firstMatch
            XCTAssertTrue(voice.waitForExistence(timeout: 30), language)
            if language == "en" { XCTAssertTrue(app.staticTexts[title].exists, language) }
            Thread.sleep(forTimeInterval: 3)
            attach(app, "appstore-voice-discovery-" + language)
            app.terminate()
        }
    }

    func testFullCatalogCanFindLastCommunityVoice() throws {
        #if targetEnvironment(simulator)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceScale-" + UUID().uuidString)
        let source = Bundle(for: Self.self).resourceURL!.appendingPathComponent("VoiceDiscovery")
        try FileManager.default.copyItem(at: source, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var voices = document["voices"] as! [[String: Any]]
        let template = try XCTUnwrap(voices.first { ($0["id"] as? String)?.hasPrefix("vl_") == true })
        for index in 0..<1317 {
            var voice = template
            voice["id"] = "vl_scale_\(index)"
            voice["name"] = "Scale Voice \(index)"
            voices.append(voice)
        }
        XCTAssertEqual(voices.count, 1606)
        document["voices"] = voices
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        let app = launch(fixtureDirectory: directory)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceEdition_weekly-stories").firstMatch.waitForExistence(timeout: 20))
        let browseAll = app.buttons["voiceBrowseAll"]
        reveal(browseAll, in: app); browseAll.tap()
        let tabs = app.segmentedControls["voiceCatalogTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Regular voices"].isSelected)
        tabs.buttons["Curated voices"].tap()
        XCTAssertTrue(app.staticTexts["voiceClonedSelectionNote"].exists)
        let search = app.textFields["voiceSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Scale Voice 1316")
        XCTAssertTrue(app.buttons["presetVoiceSelect_vl_scale_1316"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voiceQuota_vl_scale_1316"].exists)
        XCTAssertFalse(app.buttons["presetVoiceSelect_vl_scale_0"].exists)
        attach(app, "voice-full-catalog-last-result")
        tabs.buttons["Regular voices"].tap()
        XCTAssertFalse(app.buttons["presetVoiceSelect_vl_scale_1316"].exists)
        #else
        throw XCTSkip("Synthetic scale fixture is simulator only")
        #endif
    }

    func testProductionDiscoveryOnConnectedPhone() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real device test uses the public production catalog")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding"]
        app.launch()
        let voices = app.buttons.matching(NSPredicate(format: "label IN %@", ["音色", "Voice", "Voices"])).firstMatch
        XCTAssertTrue(voices.waitForExistence(timeout: 20)); voices.tap()
        let feature = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "voiceEdition_cn-everyday", "voiceEdition_international-everyday")).firstMatch
        XCTAssertTrue(feature.waitForExistence(timeout: 45))
        attach(app, "iphone-production-discovery")
        let featured = app.buttons["voiceFeaturedClones"]
        reveal(featured, in: app); featured.tap()
        let famous = app.buttons.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "voiceIdentity_cn-cloned-famous", "voiceIdentity_international-cloned-famous")).firstMatch
        XCTAssertTrue(famous.waitForExistence(timeout: 10)); famous.tap()
        XCTAssertTrue(app.staticTexts["voiceClonedSelectionNote"].exists)
        attach(app, "iphone-production-famous-group")
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voicePreview_vl_")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10)); preview.tap()
        expectation(for: NSPredicate(format: "value ==[c] %@", "playing"), evaluatedWith: preview)
        waitForExpectations(timeout: 35)
        attach(app, "iphone-production-original-preview")
        preview.tap()
        let quota = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voiceQuota_vl_")).firstMatch
        XCTAssertTrue(quota.exists); quota.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        attach(app, "iphone-production-monthly-quota")
        app.alerts.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let search = app.textFields["voiceSearchField"]
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Calm Narrator")
        XCTAssertTrue(app.buttons["presetVoiceSelect_vl_b5c9589c1370164a19fe"].waitForExistence(timeout: 10))
        attach(app, "iphone-production-full-catalog-search")
        #endif
    }

    func testEverydayCollectionRepeatedPreviewRemainsResponsive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-CastReaderVoicePreviewDiagnostics"]
        app.launch()
        let voices = app.buttons.matching(NSPredicate(format: "label IN %@", ["音色", "Voice", "Voices"])).firstMatch
        XCTAssertTrue(voices.waitForExistence(timeout: 20))
        voices.tap()
        let feature = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["voiceEdition_cn-everyday", "voiceEdition_international-everyday"])).firstMatch
        XCTAssertTrue(feature.waitForExistence(timeout: 45))
        for pass in 0..<3 {
            feature.tap()
            let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voicePreview_"))
            let first = previews.element(boundBy: 0)
            let second = previews.element(boundBy: 1)
            XCTAssertTrue(first.waitForExistence(timeout: 10))
            first.tap()
            expectation(for: NSPredicate(format: "value ==[c] %@", "playing"), evaluatedWith: first)
            waitForExpectations(timeout: 30)
            XCTAssertTrue(second.exists)
            second.tap()
            expectation(for: NSPredicate(format: "value ==[c] %@", "playing"), evaluatedWith: second)
            waitForExpectations(timeout: 30)
            XCTAssertEqual((first.value as? String)?.lowercased(), "stopped")
            second.tap()
            XCTAssertEqual((second.value as? String)?.lowercased(), "stopped")
            attach(app, "everyday-preview-stopped-\(pass)")
            // Leaving during playback must release the preview as well.
            first.tap()
            expectation(for: NSPredicate(format: "value ==[c] %@", "playing"), evaluatedWith: first)
            waitForExpectations(timeout: 30)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(feature.waitForExistence(timeout: 5))
            let feedPreview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voicePreview_")).firstMatch
            XCTAssertEqual((feedPreview.value as? String)?.lowercased(), "stopped")
        }
        // Capture a quiet interval after repeated navigation/audio allocations.
        Thread.sleep(forTimeInterval: 5)
        attach(app, "everyday-preview-idle")
    }

    @MainActor
    func testPublishedCuratedVoicesMatchJapaneseAndFrench() async throws {
        let url = URL(string: "https://api.castreader.ai/api/tts/mobile-catalog?contract=tts-voice-catalog-v1&region=international")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let catalog = (raw["data"] as? [String: Any]) ?? (raw["catalog"] as? [String: Any]) ?? raw
        let voices = catalog["voices"] as! [[String: Any]]
        let indexed = Dictionary(uniqueKeysWithValues: voices.map { ($0["id"] as! String, $0) })
        let modules = (catalog["discovery"] as! [String: Any])["modules"] as! [[String: Any]]
        let ids = modules.flatMap { $0["voiceIds"] as! [String] }
        for language in ["ja", "fr"] {
            let expected = ids.filter { indexed[$0]?["referenceLanguage"] as? String == language }
            XCTAssertFalse(expected.isEmpty)
            let app = XCUIApplication()
            app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
                "-CastReaderVoicePreviewDiagnostics", "-AppleLanguages", "(en)", "-interfaceLanguage", "en",
                "-voice_browser_language_v1", language]
            app.launch()
            let tab = app.buttons.matching(NSPredicate(format: "label IN %@", ["音色", "Voice", "Voices"])).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 20)); tab.tap()
            XCTAssertTrue(app.textFields["voiceSearchField"].waitForExistence(timeout: 20))
            let featured = app.buttons["voiceFeaturedClones"]
            reveal(featured, in: app); featured.tap()
            let first = try XCTUnwrap(expected.first)
            XCTAssertTrue(app.buttons["presetVoiceSelect_" + first].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["presetVoiceSelect_" + publicID].exists, "English-source recommendation must not leak into another language")
            let preview = app.buttons["voicePreview_" + first]
            preview.tap()
            let playing = expectation(for: NSPredicate(format: "value ==[c] %@", "playing"), evaluatedWith: preview)
            await fulfillment(of: [playing], timeout: 30)
            preview.tap()
            XCTAssertTrue(app.staticTexts["voiceClonedSelectionNote"].exists)
            attach(app, "published-curated-" + language)
            app.terminate()
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    func testFamiliarVoiceEntryLeadsToPersonalVoiceFlow() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceEdition_weekly-stories").firstMatch.waitForExistence(timeout: 20))
        let record = app.buttons["voiceFamiliarSelf"]
        reveal(record, in: app)
        XCTAssertTrue(app.buttons["voiceFamiliarFriend"].exists)
        record.tap()
        XCTAssertTrue(app.buttons["login.apple"].waitForExistence(timeout: 5) || app.buttons["login.email"].exists)
        attach(app, "voice-personal-recording-entry")
    }

    func testFamiliarVoicesShowThreeRowsAndOnlyShowCreationWhenEmpty() {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderFamiliarVoicesFixture", "-CastReaderSkipSignInGate",
            "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.buttons["voiceFamiliarSelect_Mia"].waitForExistence(timeout: 15))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voiceFamiliarSelect_"))
        XCTAssertEqual(rows.count, 3)
        XCTAssertLessThan(app.buttons["voiceFamiliarSelect_Mia"].frame.minY, app.buttons["voiceFamiliarSelect_Alex"].frame.minY)
        XCTAssertLessThan(app.buttons["voiceFamiliarSelect_Alex"].frame.minY, app.buttons["voiceFamiliarSelect_My voice"].frame.minY)
        XCTAssertFalse(app.buttons["voiceFamiliarSelect_Older voice"].exists)
        XCTAssertFalse(app.buttons["voiceFamiliarSelf"].exists)
        XCTAssertFalse(app.buttons["voiceFamiliarFriend"].exists)
        app.buttons["voiceFamiliarSelect_Mia"].tap()
        XCTAssertFalse((app.buttons["voiceFamiliarSelect_Mia"].value as? String ?? "").isEmpty)
        let preview = app.buttons["voiceFamiliarPreview_Alex"]
        preview.tap(); XCTAssertEqual((preview.value as? String)?.lowercased(), "playing")
        preview.tap(); XCTAssertEqual((preview.value as? String)?.lowercased(), "stopped")
        app.buttons["voiceFamiliarAll"].tap()
        XCTAssertEqual(app.staticTexts["familiarFixtureAction"].label, "all")
        attach(app, "familiar-three-recent-voices")
        app.buttons["Clear fixtures"].tap()
        XCTAssertTrue(app.buttons["voiceFamiliarSelf"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voiceFamiliarFriend"].exists)
        XCTAssertEqual(rows.count, 0)
        XCTAssertFalse(app.buttons["voiceFamiliarAll"].exists)
        attach(app, "familiar-empty-recording-actions")
    }

    func testOperatorIdentityGroupsNarrowFeaturedClones() throws {
        #if targetEnvironment(simulator)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceGroups-" + UUID().uuidString)
        let source = Bundle(for: Self.self).resourceURL!.appendingPathComponent("VoiceDiscovery")
        try FileManager.default.copyItem(at: source, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let voices = document["voices"] as! [[String: Any]]
        let cloneIDs = voices.compactMap { $0["id"] as? String }.filter { $0.hasPrefix("vl_") }
        XCTAssertEqual(cloneIDs.count, 6)
        var edition = document["discovery"] as! [String: Any]
        var modules = edition["modules"] as! [[String: Any]]
        modules[0]["voiceIds"] = ["am_fenrir"] + cloneIDs
        edition["modules"] = modules; document["discovery"] = edition
        let groups = [("famous", "Famous styles"), ("character", "Character voices"), ("narrators", "Natural narrators")]
        document["collections"] = groups.enumerated().map { index, group in
            ["id": group.0, "title": ["en": group.1], "theme": "character", "voiceIds": Array(cloneIDs[(index * 2)..<(index * 2 + 2)])] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        let app = launch(fixtureDirectory: directory)
        let featured = app.buttons["voiceFeaturedClones"]
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceEdition_weekly-stories").firstMatch.waitForExistence(timeout: 20))
        reveal(featured, in: app); featured.tap()
        XCTAssertTrue(app.buttons["voiceIdentity_famous"].waitForExistence(timeout: 5))
        app.buttons["voiceIdentity_famous"].tap()
        XCTAssertTrue(app.buttons["presetVoiceSelect_" + cloneIDs[0]].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["presetVoiceSelect_" + cloneIDs[1]].exists)
        XCTAssertFalse(app.buttons["presetVoiceSelect_" + cloneIDs[2]].exists)
        app.buttons["voiceIdentity_character"].tap()
        XCTAssertTrue(app.buttons["presetVoiceSelect_" + cloneIDs[2]].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["presetVoiceSelect_" + cloneIDs[0]].exists)
        XCTAssertTrue(app.staticTexts["voiceClonedSelectionNote"].exists)
        attach(app, "voice-featured-identity-groups")
        #else
        throw XCTSkip("Synthetic group fixture is simulator only")
        #endif
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
