//
//  YouTubeTranscriptServiceTests.swift
//  CastReaderTests
//
//  Network-free tests for the extraction envelope, failure mapping and the
//  native trust boundary around WebKit callbacks.
//

import Foundation
import WebKit
import XCTest
@testable import CastReader

final class YouTubeTranscriptServiceTests: XCTestCase {
    private let videoID = "dQw4w9WgXcQ"
    private let token = "request-token-a"

    @MainActor
    func testOptInLiveExtractionForInjectedPublicURL() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "CASTREADER_RUN_LIVE_YOUTUBE_TESTS"
            ] == "1",
            "Set CASTREADER_RUN_LIVE_YOUTUBE_TESTS=1 for the live probe."
        )
        let rawURL = ProcessInfo.processInfo.environment[
            "CASTREADER_YOUTUBE_LIVE_URL"
        ] ?? "https://m.youtube.com/watch?v=wpb-DrbhEiY&pp=iggCQAE%3D&ra=m"
        let reference = try XCTUnwrap(YouTubeURLParser.parse(rawURL))
        let document: YouTubeTranscriptDocument
        do {
            document = try await YouTubeTranscriptService.shared.extract(
                reference,
                preferredLanguage: "zh-CN"
            )
        } catch let failure as YouTubeTranscriptFailure {
            XCTFail("live extraction failed with product reason: \(failure.rawValue)")
            return
        } catch {
            XCTFail("live extraction failed with unexpected error: \(error)")
            return
        }

        XCTAssertEqual(document.metadata.videoId, reference.videoId)
        XCTAssertFalse(document.cues.isEmpty)
        XCTAssertFalse(document.paragraphs.isEmpty)
        if let expectedLanguage = ProcessInfo.processInfo.environment[
            "CASTREADER_YOUTUBE_EXPECTED_LANGUAGE"
        ]?.lowercased(), !expectedLanguage.isEmpty {
            XCTAssertTrue(
                document.track.languageCode.lowercased().hasPrefix(expectedLanguage),
                "expected cue language \(expectedLanguage), got \(document.track.languageCode)"
            )
        }
    }

    func testMainFrameNavigationAllowsOnlyOfficialEmbedDocument() throws {
        let reference = YouTubeVideoReference(videoId: videoID, startSeconds: 45)
        let allowed = [
            try XCTUnwrap(reference.embedURL(preferredLanguage: "zh-CN")).absoluteString,
            "https://www.youtube.com/embed/\(videoID)/?origin=https%3A%2F%2Fcom.same.castreader&cc_load_policy=1&mute=1&autoplay=1&playsinline=1&enablejsapi=1",
        ]
        for rawValue in allowed {
            XCTAssertTrue(
                YouTubeTranscriptSecurityPolicy.allowsMainFrameNavigation(
                    URL(string: rawValue),
                    expectedVideoID: videoID
                ),
                "should allow \(rawValue)"
            )
        }

        let rejected = [
            "https://www.youtube.com/watch?v=\(videoID)",
            "http://www.youtube.com/embed/\(videoID)",
            "https://youtube.com/embed/\(videoID)",
            "https://m.youtube.com/embed/\(videoID)",
            "https://www.youtube.com:443/embed/\(videoID)",
            "https://user@www.youtube.com/embed/\(videoID)",
            "https://www.youtube.com/embed/aaaaaaaaaaa?enablejsapi=1&playsinline=1&autoplay=1&mute=1&cc_load_policy=1&origin=https%3A%2F%2Fcom.same.castreader",
            "https://www.youtube.com/embed/\(videoID)/extra?enablejsapi=1&playsinline=1&autoplay=1&mute=1&cc_load_policy=1&origin=https%3A%2F%2Fcom.same.castreader",
            "https://www.youtube.com/embed/\(videoID)?enablejsapi=1&playsinline=1&autoplay=1&mute=1&cc_load_policy=1",
            "https://www.youtube.com/embed/\(videoID)?enablejsapi=1&playsinline=1&autoplay=1&mute=1&cc_load_policy=1&origin=https%3A%2F%2Fevil.example",
            "https://www.youtube.com/embed/\(videoID)?enablejsapi=1&playsinline=1&autoplay=1&mute=1&cc_load_policy=1&origin=https%3A%2F%2Fcom.same.castreader&unexpected=1",
            "https://www.youtube.com.evil.example/embed/\(videoID)?enablejsapi=1&playsinline=1&autoplay=1&mute=1&cc_load_policy=1&origin=https%3A%2F%2Fcom.same.castreader",
            "https://consent.youtube.com/m?continue=https://www.youtube.com/watch?v=\(videoID)",
        ]
        for rawValue in rejected {
            XCTAssertFalse(
                YouTubeTranscriptSecurityPolicy.allowsMainFrameNavigation(
                    URL(string: rawValue),
                    expectedVideoID: videoID
                ),
                "should reject \(rawValue)"
            )
        }
    }

    func testRejectedRedirectMapsConsentAndLoginSeparately() {
        for rawValue in [
            "https://consent.youtube.com/m?continue=https://www.youtube.com/watch?v=\(videoID)",
            "https://consent.google.com/m?continue=https://www.youtube.com/watch?v=\(videoID)",
        ] {
            XCTAssertEqual(
                YouTubeTranscriptSecurityPolicy.rejectedNavigationFailure(
                    for: URL(string: rawValue)
                ),
                .restricted,
                "a consent wall is an access restriction, not a parsing timeout"
            )
        }
        XCTAssertEqual(
            YouTubeTranscriptSecurityPolicy.rejectedNavigationFailure(
                for: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube")
            ),
            .restricted
        )
        for rawValue in [
            "https://www.google.com/sorry/index?continue=https://www.youtube.com/watch?v=\(videoID)",
            "https://www.google.com/recaptcha/api2/anchor?continue=https://www.youtube.com/watch?v=\(videoID)",
            "https://www.youtube.com/sorry/index?continue=/watch?v=\(videoID)",
            "https://www.youtube.com/signin?action_handle_signin=true",
            "https://www.youtube.com/verify?next=/watch?v=\(videoID)",
        ] {
            XCTAssertEqual(
                YouTubeTranscriptSecurityPolicy.rejectedNavigationFailure(
                    for: URL(string: rawValue)
                ),
                .restricted,
                "challenge/login redirects must not masquerade as timeout or unavailable"
            )
        }
        XCTAssertEqual(
            YouTubeTranscriptSecurityPolicy.rejectedNavigationFailure(
                for: URL(string: "https://evil.example.com/watch?v=\(videoID)")
            ),
            .unavailable
        )
    }

    func testHTTPRateLimitIsRetryableAndNotVideoUnavailable() {
        XCTAssertNil(YouTubeTranscriptHTTPPolicy.failure(for: 200))
        XCTAssertEqual(YouTubeTranscriptHTTPPolicy.failure(for: 401), .restricted)
        XCTAssertEqual(YouTubeTranscriptHTTPPolicy.failure(for: 404), .unavailable)
        XCTAssertEqual(YouTubeTranscriptHTTPPolicy.failure(for: 429), .network)
        XCTAssertEqual(YouTubeTranscriptHTTPPolicy.failure(for: 503), .network)
    }

    @MainActor
    func testAdapterBudgetLeavesNativeDeliveryAndTeardownGrace() {
        XCTAssertEqual(
            YouTubeTranscriptService.defaultExtractionTimeout,
            42
        )
        XCTAssertEqual(
            YouTubeTranscriptService.adapterBudgetMilliseconds(for: 42),
            34_500
        )
        XCTAssertEqual(
            YouTubeTranscriptService.adapterBudgetMilliseconds(for: 25),
            17_500
        )
        XCTAssertEqual(
            YouTubeTranscriptService.adapterBudgetMilliseconds(for: 15),
            7_500
        )
        XCTAssertEqual(
            YouTubeTranscriptService.adapterBudgetMilliseconds(for: .infinity),
            34_500
        )
    }

    func testNativeStageTimelineUsesMonotonicPrivacySafeCheckpoints() {
        var timeline = YouTubeTranscriptStageTimeline(
            startedAtNanoseconds: 5_000_000_000
        )
        let first = timeline.record(
            .requestStarted,
            nowNanoseconds: 5_250_000_000
        )
        let clockMovedBackwards = timeline.record(
            .navigationStarted,
            nowNanoseconds: 5_125_000_000
        )
        let later = timeline.record(
            .navigationStarted,
            nowNanoseconds: 5_900_000_000
        )

        XCTAssertEqual(first.elapsedMilliseconds, 250)
        XCTAssertEqual(clockMovedBackwards.elapsedMilliseconds, 250)
        XCTAssertEqual(later.elapsedMilliseconds, 900)
        for stage in YouTubeTranscriptNativeStage.allCases {
            XCTAssertFalse(stage.rawValue.contains("youtube.com"))
            XCTAssertFalse(stage.rawValue.contains(videoID))
            XCTAssertFalse(stage.rawValue.contains(token))
        }
    }

    func testOfficialEmbedURLKeepsCanonicalWatchURLSeparate() throws {
        let reference = YouTubeVideoReference(videoId: videoID, startSeconds: 90)
        XCTAssertEqual(
            reference.canonicalURLString,
            "https://www.youtube.com/watch?v=\(videoID)&t=90s"
        )
        let components = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(reference.embedURL(preferredLanguage: "zh-CN")),
                resolvingAgainstBaseURL: false
            )
        )
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.youtube.com")
        XCTAssertEqual(components.path, "/embed/\(videoID)")
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        XCTAssertEqual(query["enablejsapi"], "1")
        XCTAssertEqual(query["playsinline"], "1")
        XCTAssertEqual(query["autoplay"], "1")
        XCTAssertEqual(query["mute"], "1")
        XCTAssertEqual(query["cc_load_policy"], "1")
        XCTAssertEqual(query["cc_lang_pref"], "zh-CN")
        XCTAssertEqual(query["origin"], "https://com.same.castreader")
        XCTAssertEqual(query["start"], "90")
    }

    @MainActor
    func testExtractionStartsOfficialEmbedWithRequiredIdentityHeaders() async {
        var capturedRequest: URLRequest?
        let service = YouTubeTranscriptService(
            vendoredBridgeLoader: { "void 0;" },
            pageLoader: { _, request in capturedRequest = request }
        )
        let reference = YouTubeVideoReference(
            videoId: videoID,
            startSeconds: 45
        )
        let extraction = Task { @MainActor in
            try await service.extract(
                reference,
                preferredLanguage: "zh_CN",
                timeout: 5
            )
        }
        await waitForNavigationStarts(1) { capturedRequest == nil ? 0 : 1 }
        let request = capturedRequest
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Referer"), "https://com.same.castreader")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept-Language"), "zh-CN")
        XCTAssertEqual(request?.url?.host, "www.youtube.com")
        XCTAssertEqual(request?.url?.path, "/embed/\(videoID)")
        XCTAssertFalse(request?.url?.absoluteString.contains("/watch") ?? true)
        service.cancel()
        await assertCancelled(extraction)
    }

    @MainActor
    func testAllExtractionScriptsRunInPageWorldAtDocumentStartInOrder() {
        let bridgeFixture = "window.__vendoredBridgeInstalled = true;"
        let scripts = YouTubeTranscriptService.documentStartScripts(
            vendoredBridge: bridgeFixture,
            expectedVideoID: videoID,
            requestToken: token,
            preferredLanguage: "en"
        )
        XCTAssertEqual(scripts.count, 2)
        for script in scripts {
            XCTAssertEqual(script.injectionTime, .atDocumentStart)
            XCTAssertTrue(script.isForMainFrameOnly)
        }
        XCTAssertTrue(scripts[0].source.contains(bridgeFixture))
        XCTAssertTrue(scripts[1].source.contains("var EXPECTED_VIDEO_ID = \"\(videoID)\""))
        XCTAssertTrue(scripts[1].source.contains("var REQUEST_TOKEN = \"\(token)\""))
        XCTAssertTrue(scripts[1].source.contains("ADAPTER_BUDGET_MS = 34500"))
        XCTAssertTrue(scripts[1].source.contains("terminalPlayabilityError"))
        XCTAssertFalse(scripts.contains { $0.source.contains("media.pause()") })

        let customBudgetScripts = YouTubeTranscriptService.documentStartScripts(
            vendoredBridge: bridgeFixture,
            expectedVideoID: videoID,
            requestToken: token,
            preferredLanguage: "en",
            timeout: 25
        )
        XCTAssertTrue(
            customBudgetScripts[1].source.contains("ADAPTER_BUDGET_MS = 17500")
        )
    }

    func testMessageFrameRequiresMainOfficialEmbedHTTPSDocument() throws {
        let embedURL = try XCTUnwrap(
            YouTubeVideoReference(videoId: videoID, startSeconds: nil)
                .embedURL(preferredLanguage: "en")
        ).absoluteString
        let legal = YouTubeTranscriptMessageFrame(
            isMainFrame: true,
            securityScheme: "https",
            securityHost: "www.youtube.com",
            securityPort: 443,
            requestURL: embedURL
        )
        XCTAssertTrue(
            YouTubeTranscriptSecurityPolicy.allowsMessageFrame(
                legal,
                expectedVideoID: videoID
            )
        )

        let rejected = [
            YouTubeTranscriptMessageFrame(
                isMainFrame: false,
                securityScheme: legal.securityScheme,
                securityHost: legal.securityHost,
                securityPort: legal.securityPort,
                requestURL: legal.requestURL
            ),
            YouTubeTranscriptMessageFrame(
                isMainFrame: true,
                securityScheme: "http",
                securityHost: legal.securityHost,
                securityPort: 80,
                requestURL: legal.requestURL
            ),
            YouTubeTranscriptMessageFrame(
                isMainFrame: true,
                securityScheme: "https",
                securityHost: "evil.example.com",
                securityPort: 443,
                requestURL: legal.requestURL
            ),
            YouTubeTranscriptMessageFrame(
                isMainFrame: true,
                securityScheme: "https",
                securityHost: legal.securityHost,
                securityPort: 444,
                requestURL: legal.requestURL
            ),
            YouTubeTranscriptMessageFrame(
                isMainFrame: true,
                securityScheme: "https",
                securityHost: legal.securityHost,
                securityPort: 443,
                requestURL: "https://www.youtube.com/watch?v=\(videoID)"
            ),
        ]
        for frame in rejected {
            XCTAssertFalse(
                YouTubeTranscriptSecurityPolicy.allowsMessageFrame(
                    frame,
                    expectedVideoID: videoID
                )
            )
        }
    }

    func testEnvelopeIdentityRejectsLateOrCrossVideoCallbacks() {
        XCTAssertTrue(
            YouTubeTranscriptSecurityPolicy.allowsEnvelope(
                requestToken: token,
                requestVideoID: videoID,
                videoID: videoID,
                expectedToken: token,
                expectedVideoID: videoID
            )
        )
        XCTAssertFalse(
            YouTubeTranscriptSecurityPolicy.allowsEnvelope(
                requestToken: "older-request-token",
                requestVideoID: videoID,
                videoID: videoID,
                expectedToken: token,
                expectedVideoID: videoID
            ),
            "a callback from the previous single-flight request must be ignored"
        )
        XCTAssertFalse(
            YouTubeTranscriptSecurityPolicy.allowsEnvelope(
                requestToken: token,
                requestVideoID: "aaaaaaaaaaa",
                videoID: videoID,
                expectedToken: token,
                expectedVideoID: videoID
            )
        )
        XCTAssertFalse(
            YouTubeTranscriptSecurityPolicy.allowsEnvelope(
                requestToken: token,
                requestVideoID: videoID,
                videoID: "aaaaaaaaaaa",
                expectedToken: token,
                expectedVideoID: videoID
            )
        )
    }

    func testAdapterEmbedsOpaqueRequestTokenAndNoDuplicateVTTCueField() {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: videoID,
            requestToken: token,
            preferredLanguage: "zh-CN"
        )
        XCTAssertTrue(source.contains("var REQUEST_TOKEN = \"\(token)\""))
        XCTAssertTrue(source.contains("requestToken: REQUEST_TOKEN"))
        XCTAssertTrue(source.contains("var PREFERRED_LANGUAGE = \"zh-CN\""))
        XCTAssertFalse(
            source.contains("startMs: startMs,\n                startMs: startMs")
        )
    }

    func testJapaneseTTSRequestOmitsLegacyVoiceCode() throws {
        let data = try JSONEncoder().encode(
            TTSRequest(
                input: "字幕を読み上げます",
                voice: "jf_alpha",
                language: "ja",
                includeVoiceCode: false
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["voice"] as? String, "jf_alpha")
        XCTAssertEqual(object["language"] as? String, "ja")
        XCTAssertNil(object["voice_code"])
    }

    func testTTSRequestKeepsLegacyVoiceCodeByDefault() throws {
        let data = try JSONEncoder().encode(
            TTSRequest(
                input: "legacy request body",
                voice: "jf_alpha",
                speed: 1.25,
                language: "ja-JP"
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "input",
            "language",
            "model",
            "response_format",
            "return_timestamps",
            "speed",
            "stream",
            "voice",
            "voice_code",
        ])
        XCTAssertEqual(object["input"] as? String, "legacy request body")
        XCTAssertEqual(object["language"] as? String, "ja-JP")
        XCTAssertEqual(object["model"] as? String, "kokoro")
        XCTAssertEqual(object["response_format"] as? String, "mp3")
        XCTAssertEqual(object["return_timestamps"] as? Bool, true)
        XCTAssertEqual(object["speed"] as? Double, 1.25)
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertEqual(object["voice"] as? String, "jf_alpha")
        XCTAssertEqual(object["voice_code"] as? String, "jf_alpha")
    }

    func testYouTubeVoiceCodePolicyIsSourceAndLanguageScoped() {
        XCTAssertFalse(
            YouTubeTTSRequestPolicy.includeVoiceCode(
                sourceKind: .youtube,
                language: "ja-JP"
            )
        )
        XCTAssertFalse(
            YouTubeTTSRequestPolicy.includeVoiceCode(
                sourceKind: .youtube,
                language: "fr-FR"
            )
        )
        XCTAssertFalse(
            YouTubeTTSRequestPolicy.includeVoiceCode(
                sourceKind: .youtube,
                language: "ko-KR"
            )
        )
        XCTAssertTrue(
            YouTubeTTSRequestPolicy.includeVoiceCode(
                sourceKind: .youtube,
                language: "en-US"
            )
        )
        XCTAssertTrue(
            YouTubeTTSRequestPolicy.includeVoiceCode(
                sourceKind: .youtube,
                language: "zh-Hans"
            )
        )
        XCTAssertTrue(
            YouTubeTTSRequestPolicy.includeVoiceCode(
                sourceKind: .text,
                language: "ja-JP"
            )
        )
    }

    func testPersistentYouTubeAudioQuotaPolicy() {
        XCTAssertTrue(
            YouTubePersistentAudioQuotaPolicy.isQuotaExempt(
                sourceKind: .youtube,
                persistentCacheHit: true
            )
        )
        XCTAssertTrue(
            YouTubePersistentAudioQuotaPolicy.canStart(
                sourceKind: .youtube,
                persistentCacheHit: true,
                isPro: false,
                hasListenQuota: false
            )
        )
        XCTAssertFalse(
            YouTubePersistentAudioQuotaPolicy.shouldAccount(
                sourceKind: .youtube,
                persistentCacheHit: true
            )
        )

        XCTAssertFalse(
            YouTubePersistentAudioQuotaPolicy.canStart(
                sourceKind: .youtube,
                persistentCacheHit: false,
                isPro: false,
                hasListenQuota: false
            )
        )
        XCTAssertTrue(
            YouTubePersistentAudioQuotaPolicy.shouldAccount(
                sourceKind: .youtube,
                persistentCacheHit: false
            )
        )

        XCTAssertFalse(
            YouTubePersistentAudioQuotaPolicy.canStart(
                sourceKind: .text,
                persistentCacheHit: true,
                isPro: false,
                hasListenQuota: false
            )
        )
        XCTAssertTrue(
            YouTubePersistentAudioQuotaPolicy.shouldAccount(
                sourceKind: .text,
                persistentCacheHit: true
            )
        )
    }

    func testEnvelopeDecodesAndBuildsCacheSafeDocument() throws {
        let storyboardSpec =
            "https://i.ytimg.com/sb/\(videoID)/storyboard3_L$L/M$N.jpg" +
            "|160#90#100#5#5#1000#M$M.jpg#signature"
        let body = try makeBody(
            cues: [
                ["text": "  Hello\nworld  ", "startMs": 0, "durationMs": 900],
                ["text": "Hello world", "startMs": 0, "durationMs": 900],
                ["text": "Second cue", "startMs": 1_000, "durationMs": 800],
            ],
            captionTrack: [
                "id": "en|manual|English|0",
                "name": "English",
                "languageCode": "en-US",
                "kind": "manual",
                "vssId": ".en",
                "index": 0,
            ],
            extra: [
                "title": "Fixture title",
                "thumbnailURL": "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
                "channel": "Fixture channel",
                "durationSeconds": 12.5,
                "storyboardSpec": storyboardSpec,
                "transcriptSource": "json3",
            ]
        )
        XCTAssertEqual(
            YouTubeTranscriptEnvelopeDecoder.requestToken(from: body),
            token
        )
        let envelope = try YouTubeTranscriptEnvelopeDecoder.decode(body)
        let reference = YouTubeVideoReference(videoId: videoID, startSeconds: 45)
        let extractedAt = Date(timeIntervalSince1970: 123)
        let document = try YouTubeTranscriptEnvelopeDecoder.document(
            from: envelope,
            reference: reference,
            preferredLanguage: "fr",
            extractedAt: extractedAt
        )

        XCTAssertEqual(document.metadata.videoId, videoID)
        XCTAssertEqual(document.metadata.title, "Fixture title")
        XCTAssertEqual(document.metadata.channelName, "Fixture channel")
        XCTAssertEqual(document.metadata.durationMs, 12_500)
        XCTAssertEqual(
            document.metadata.sourceURL,
            "https://www.youtube.com/watch?v=\(videoID)&t=45s"
        )
        XCTAssertEqual(document.track.baseURL, "en|manual|English|0")
        XCTAssertFalse(document.track.baseURL.contains("expire="))
        XCTAssertEqual(document.track.languageCode, "en-US")
        XCTAssertEqual(document.cues.count, 2, "normalized duplicates are removed natively")
        XCTAssertEqual(document.cues[0].text, "Hello world")
        XCTAssertEqual(document.paragraphs.first?.startMs, 0)
        XCTAssertNotNil(document.storyboard)
        XCTAssertEqual(
            document.artworkSchemaVersion,
            YouTubeArtworkCacheSchema.current
        )
        XCTAssertEqual(document.extractedAt, extractedAt)
    }

    func testTranscriptPanelFallbackUsesDetectedCueLanguageAndIndependentIdentity() throws {
        let body = try makeBody(
            cues: [[
                "text": "这是一段用于验证字幕实际语言的中文内容，不能错误地使用英语音色。",
                "startMs": 0,
                "durationMs": 2_000,
            ]],
            captionTrack: [
                "id": "en|manual|English|0",
                "name": "English",
                "languageCode": "en-US",
                "kind": "manual",
                "index": 0,
            ],
            extra: ["transcriptSource": "transcript_bridge"]
        )
        let envelope = try YouTubeTranscriptEnvelopeDecoder.decode(body)
        let document = try YouTubeTranscriptEnvelopeDecoder.document(
            from: envelope,
            reference: YouTubeVideoReference(videoId: videoID, startSeconds: nil),
            preferredLanguage: "en"
        )

        XCTAssertEqual(document.track.languageCode, "zh")
        XCTAssertEqual(
            document.track.baseURL,
            "transcript-bridge:\(videoID):zh"
        )
        XCTAssertNil(document.track.name)
        XCTAssertNil(document.track.kind)
    }

    func testUnboundTranscriptSourcesUseActualCueLanguageAndIndependentIdentity() throws {
        let chineseText = Array(
            repeating: "这是一段英文视频被页面翻译成中文后的字幕内容",
            count: 4
        ).joined(separator: "，")

        for (source, prefix) in [
            ("transcript_endpoint", "transcript-endpoint"),
            ("transcript_fetch_capture", "transcript-capture"),
        ] {
            let body = try makeBody(
                cues: [[
                    "text": chineseText,
                    "startMs": 0,
                    "durationMs": 2_000,
                ]],
                captionTrack: [
                    "id": "en|manual|English|0",
                    "name": "English",
                    "languageCode": "en-US",
                    "kind": "manual",
                    "index": 0,
                ],
                extra: ["transcriptSource": source]
            )
            let document = try YouTubeTranscriptEnvelopeDecoder.document(
                from: YouTubeTranscriptEnvelopeDecoder.decode(body),
                reference: YouTubeVideoReference(
                    videoId: videoID,
                    startSeconds: nil
                ),
                preferredLanguage: "zh-CN"
            )

            XCTAssertEqual(document.track.languageCode, "zh")
            XCTAssertEqual(
                document.track.baseURL,
                "\(prefix):\(videoID):zh"
            )
        }
    }

    func testCandidateBoundEnglishTrackRejectsChineseTranslatedBody() throws {
        let translatedText = Array(
            repeating: "这是被 YouTube 页面自动翻译成中文的字幕，不能冒充英文原始字幕",
            count: 5
        ).joined(separator: "。")
        let body = try makeBody(
            cues: [[
                "text": translatedText,
                "startMs": 0,
                "durationMs": 4_000,
            ]],
            captionTrack: [
                "id": "en|manual|English|0",
                "name": "English",
                "languageCode": "en",
                "kind": "manual",
                "index": 0,
            ],
            extra: ["transcriptSource": "json3"]
        )

        XCTAssertThrowsError(
            try YouTubeTranscriptEnvelopeDecoder.document(
                from: YouTubeTranscriptEnvelopeDecoder.decode(body),
                reference: YouTubeVideoReference(
                    videoId: videoID,
                    startSeconds: nil
                ),
                preferredLanguage: "zh-CN"
            )
        ) { error in
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .captionAccess)
        }
    }

    func testCachedTranscriptLanguageValidationRejectsStaleMislabeledBody() throws {
        let translatedText = Array(
            repeating: "缓存中的正文实际上是中文翻译，但旧版本把轨道标记成英文",
            count: 5
        ).joined(separator: "。")
        let cues = [YouTubeTranscriptCue(
            text: translatedText,
            startMs: 0,
            durationMs: 4_000
        )]
        let document = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: videoID,
                title: "Fixture",
                channelName: nil,
                sourceURL: "https://www.youtube.com/watch?v=\(videoID)",
                thumbnailURL: nil,
                durationMs: 4_000
            ),
            track: YouTubeCaptionTrack(
                baseURL: ".en",
                languageCode: "en",
                name: "English",
                kind: "manual"
            ),
            cues: cues
        )

        XCTAssertThrowsError(
            try YouTubeTranscriptContentLanguagePolicy.validatedPlaybackLanguage(
                for: document
            )
        ) { error in
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .captionAccess)
        }
    }

    func testCachedTranscriptLanguageValidationAcceptsMatchingEnglishBody() throws {
        let englishText = Array(
            repeating: "Artificial intelligence is reshaping the global chip industry",
            count: 5
        ).joined(separator: ". ")
        let document = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: videoID,
                title: "Fixture",
                channelName: nil,
                sourceURL: "https://www.youtube.com/watch?v=\(videoID)",
                thumbnailURL: nil,
                durationMs: 4_000
            ),
            track: YouTubeCaptionTrack(
                baseURL: ".en",
                languageCode: "en",
                name: "English",
                kind: "manual"
            ),
            cues: [YouTubeTranscriptCue(
                text: englishText,
                startMs: 0,
                durationMs: 4_000
            )]
        )

        XCTAssertEqual(
            try YouTubeTranscriptContentLanguagePolicy.validatedPlaybackLanguage(
                for: document
            ),
            "en"
        )
    }

    func testTranscriptPanelFallbackDoesNotRelabelKoreanAsEnglish() throws {
        let body = try makeBody(
            cues: [[
                "text": "안녕하세요 오늘은 자막 언어를 정확하게 확인합니다",
                "startMs": 0,
                "durationMs": 2_000,
            ]],
            captionTrack: [
                "id": "en|manual|English|0",
                "languageCode": "en-US",
                "kind": "manual",
                "index": 0,
            ],
            extra: ["transcriptSource": "transcript_bridge"]
        )
        let document = try YouTubeTranscriptEnvelopeDecoder.document(
            from: YouTubeTranscriptEnvelopeDecoder.decode(body),
            reference: YouTubeVideoReference(videoId: videoID, startSeconds: nil),
            preferredLanguage: "en"
        )

        XCTAssertEqual(document.track.languageCode, "ko")
        XCTAssertThrowsError(
            try YouTubeTranscriptLanguagePolicy.playbackLanguage(
                for: document.track.languageCode
            )
        ) { error in
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .unsupportedLanguage)
        }
    }

    func testTranscriptPanelFallbackRejectsMultipleCuesWithoutATimeline() throws {
        let body = try makeBody(
            cues: [
                [
                    "text": "0:011 second[Music]",
                    "startMs": 0,
                    "durationMs": 0,
                ],
                [
                    "text": "0:1818 secondsCaption text",
                    "startMs": 0,
                    "durationMs": 0,
                ],
            ],
            captionTrack: [
                "id": "en|manual|English|0",
                "languageCode": "en-US",
            ],
            extra: ["transcriptSource": "transcript_bridge"]
        )

        XCTAssertThrowsError(
            try YouTubeTranscriptEnvelopeDecoder.document(
                from: YouTubeTranscriptEnvelopeDecoder.decode(body),
                reference: YouTubeVideoReference(videoId: videoID, startSeconds: nil),
                preferredLanguage: "en"
            )
        ) { error in
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .malformedResponse)
        }
    }

    func testFailureClassifierCoversProductFailureSurface() throws {
        let cases: [(extra: [String: Any], expected: YouTubeTranscriptFailure)] = [
            (["isLive": true], .live),
            (["playability": [
                "status": "LOGIN_REQUIRED",
                "classification": "sign_in_required",
            ]], .restricted),
            ([
                "ok": false,
                "playability": [
                    "status": "LOGIN_REQUIRED",
                    "classification": "sign_in_required",
                ],
                "error": ["code": "youtube_verification_required"],
            ], .youtubeAccessLimited),
            (["playability": [
                "status": "UNPLAYABLE",
                "classification": "geo_restricted",
            ]], .unavailable),
            (["playability": [
                "status": "UNPLAYABLE",
                "classification": "private",
            ]], .unavailable),
            ([
                "ok": false,
                "playability": [
                    "status": "UNPLAYABLE",
                    "classification": "unavailable",
                ],
                "error": ["code": "restricted_video"],
            ], .restricted),
            (["ok": false, "error": ["code": "captions_unavailable"]], .noCaptions),
            (["ok": false, "error": ["code": "transcript_timeout"]], .timeout),
            (["ok": false, "error": ["code": "fetch_timeout"]], .timeout),
            (["ok": false, "error": ["code": "adapter_timeout"]], .timeout),
            (["ok": false, "error": ["code": "player_timeout"]], .timeout),
            ([
                "ok": false,
                "playability": [
                    "status": "UNPLAYABLE",
                    "classification": "unknown",
                ],
                "error": ["code": "player_bootstrap_failed"],
            ], .playerBootstrapFailed),
            (["ok": false, "error": ["code": "network"]], .network),
            (["ok": false, "error": ["code": "fetch_failed"]], .network),
            (["ok": false, "error": ["code": "transcript_empty"]], .captionAccess),
            (["ok": false, "error": ["code": "transcript_access_failed"]], .captionAccess),
            (["ok": false, "error": ["code": "transcript_access_rejected"]], .captionAccess),
            (["ok": false, "error": ["code": "adapter_exception"]], .malformedResponse),
        ]

        for item in cases {
            let body = try makeBody(
                cues: [],
                captionTrack: nil,
                extra: item.extra
            )
            let envelope = try YouTubeTranscriptEnvelopeDecoder.decode(body)
            XCTAssertEqual(
                YouTubeTranscriptEnvelopeClassifier.failure(for: envelope),
                item.expected,
                "failed for \(item.extra)"
            )
        }

        let unknownEmptyEnvelope = try YouTubeTranscriptEnvelopeDecoder.decode(
            makeBody(cues: [], captionTrack: nil, extra: ["ok": false])
        )
        XCTAssertEqual(
            YouTubeTranscriptEnvelopeClassifier.failure(for: unknownEmptyEnvelope),
            .malformedResponse,
            "an unexplained empty envelope is not proof that captions do not exist"
        )

        let inaccessibleKnownTrack = try YouTubeTranscriptEnvelopeDecoder.decode(
            makeBody(
                cues: [],
                captionTrack: ["id": "en|manual", "languageCode": "en"],
                extra: ["ok": false]
            )
        )
        XCTAssertEqual(
            YouTubeTranscriptEnvelopeClassifier.failure(for: inaccessibleKnownTrack),
            .captionAccess,
            "an exposed caption track with no readable cues is an access failure"
        )
    }

    func testMalformedEnvelopeAndCueAreRejected() throws {
        XCTAssertThrowsError(
            try YouTubeTranscriptEnvelopeDecoder.decode("{not-json")
        ) { error in
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .malformedResponse)
        }
        XCTAssertNil(
            YouTubeTranscriptEnvelopeDecoder.requestToken(
                from: ["requestToken": token]
            ),
            "the WebKit contract accepts a JSON string only"
        )

        let body = try makeBody(
            cues: [["text": "Bad", "startMs": -1, "durationMs": 0]],
            captionTrack: [
                "id": "en|manual|English|0",
                "languageCode": "en",
            ]
        )
        let envelope = try YouTubeTranscriptEnvelopeDecoder.decode(body)
        XCTAssertThrowsError(
            try YouTubeTranscriptEnvelopeDecoder.document(
                from: envelope,
                reference: YouTubeVideoReference(videoId: videoID, startSeconds: nil),
                preferredLanguage: "en"
            )
        ) { error in
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .malformedResponse)
        }
    }

    func testThumbnailMustBeCredentialFreeHTTPS() throws {
        for rejected in [
            "http://i.ytimg.com/image.jpg",
            "https://user@i.ytimg.com/image.jpg",
            "data:image/png;base64,AA==",
        ] {
            let body = try makeBody(
                cues: [["text": "Cue", "startMs": 0, "durationMs": 1]],
                captionTrack: ["id": "en|manual", "languageCode": "en"],
                extra: ["thumbnailURL": rejected]
            )
            let document = try YouTubeTranscriptEnvelopeDecoder.document(
                from: YouTubeTranscriptEnvelopeDecoder.decode(body),
                reference: YouTubeVideoReference(videoId: videoID, startSeconds: nil),
                preferredLanguage: "en"
            )
            XCTAssertNil(document.metadata.thumbnailURL, "should reject \(rejected)")
        }
    }

    @MainActor
    func testNewestRequestCancelsPreviousAndExplicitCancelTearsDown() async {
        let service = YouTubeTranscriptService(
            vendoredBridgeLoader: { "void 0;" },
            pageLoader: { _, _ in }
        )
        let firstReference = YouTubeVideoReference(
            videoId: videoID,
            startSeconds: nil
        )
        let secondReference = YouTubeVideoReference(
            videoId: "aaaaaaaaaaa",
            startSeconds: nil
        )

        let first = Task { @MainActor in
            try await service.extract(
                firstReference,
                preferredLanguage: "en",
                timeout: 25
            )
        }
        await waitForActiveVideo(videoID, service: service)
        XCTAssertEqual(service.activeVideoIDForTesting, videoID)

        let second = Task { @MainActor in
            try await service.extract(
                secondReference,
                preferredLanguage: "en",
                timeout: 25
            )
        }
        await waitForActiveVideo(secondReference.videoId, service: service)
        do {
            _ = try await first.value
            XCTFail("the newest request must cancel the previous continuation")
        } catch {
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .cancelled)
        }
        XCTAssertEqual(service.activeVideoIDForTesting, secondReference.videoId)

        service.cancel()
        do {
            _ = try await second.value
            XCTFail("explicit cancel must resume the active continuation")
        } catch {
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .cancelled)
        }
        XCTAssertNil(service.activeVideoIDForTesting)
    }

    // MARK: Caption language switching

    func testEnvelopeCarriesAvailableTracksForThePicker() throws {
        let body = try makeBody(
            cues: [["text": "Hello world", "startMs": 0, "durationMs": 900]],
            captionTrack: [
                "id": ".en",
                "languageCode": "en",
                "kind": "manual",
                "index": 0,
            ],
            extra: [
                "transcriptSource": "json3",
                "availableTracks": [
                    ["id": ".en", "languageCode": "en", "kind": "manual", "index": 0],
                    ["id": "a.de", "languageCode": "de", "kind": "asr", "index": 1],
                    // Duplicate language + kind collapses into the first entry.
                    ["id": "dupe", "languageCode": "en-GB", "kind": "manual", "index": 2],
                    // Unsupported languages stay listed but are not playable.
                    ["id": ".vi", "languageCode": "vi", "kind": "manual", "index": 3],
                ],
            ]
        )
        let document = try YouTubeTranscriptEnvelopeDecoder.document(
            from: try YouTubeTranscriptEnvelopeDecoder.decode(body),
            reference: YouTubeVideoReference(videoId: videoID, startSeconds: nil),
            preferredLanguage: "en"
        )

        let tracks = try XCTUnwrap(document.availableTracks)
        XCTAssertEqual(tracks.map(\.languageCode), ["en", "de", "vi"])
        XCTAssertTrue(tracks[1].isAutomatic)
        XCTAssertFalse(tracks[0].isAutomatic)
        XCTAssertTrue(tracks[0].isPlayable)
        XCTAssertFalse(
            tracks[2].isPlayable,
            "Vietnamese has no TTS voice, so the picker must not offer it"
        )
        XCTAssertTrue(tracks[0].matches(document.track))
    }

    func testMissingAvailableTracksStaysUnknownRatherThanEmpty() throws {
        let body = try makeBody(
            cues: [["text": "Hello world", "startMs": 0, "durationMs": 900]],
            captionTrack: ["id": ".en", "languageCode": "en", "kind": "manual", "index": 0],
            extra: ["transcriptSource": "json3"]
        )
        let document = try YouTubeTranscriptEnvelopeDecoder.document(
            from: try YouTubeTranscriptEnvelopeDecoder.decode(body),
            reference: YouTubeVideoReference(videoId: videoID, startSeconds: nil),
            preferredLanguage: "en"
        )

        XCTAssertNil(document.availableTracks)
        XCTAssertEqual(
            document.switchableTracks.count,
            1,
            "an unknown list degrades to the current track only"
        )
    }

    func testRequestedTrackRejectsAnotherLanguagesTranscript() throws {
        // The transcript panel is not bound to the pinned candidate: asking for
        // German and receiving the page's English transcript must fail loudly
        // instead of narrating English words as the German track.
        let body = try makeBody(
            cues: [
                ["text": "This is clearly an English sentence about weather.", "startMs": 0, "durationMs": 900],
                ["text": "Another English sentence follows right after it.", "startMs": 1_000, "durationMs": 900],
            ],
            captionTrack: ["id": ".de", "languageCode": "de", "kind": "manual", "index": 0],
            extra: ["transcriptSource": "transcript_bridge"]
        )
        let envelope = try YouTubeTranscriptEnvelopeDecoder.decode(body)
        let reference = YouTubeVideoReference(videoId: videoID, startSeconds: nil)

        XCTAssertThrowsError(
            try YouTubeTranscriptEnvelopeDecoder.document(
                from: envelope,
                reference: reference,
                preferredLanguage: "de",
                requestedTrack: YouTubeTrackRequest(
                    id: ".de",
                    languageCode: "de",
                    isAutomatic: false
                )
            )
        ) { error in
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .trackUnavailable)
        }
    }

    func testRequestedTrackAcceptsMatchingLanguage() throws {
        let body = try makeBody(
            cues: [["text": "Guten Morgen, hier ist das Wetter für heute.", "startMs": 0, "durationMs": 900]],
            captionTrack: ["id": ".de", "languageCode": "de", "kind": "manual", "index": 0],
            extra: ["transcriptSource": "json3"]
        )
        let document = try YouTubeTranscriptEnvelopeDecoder.document(
            from: try YouTubeTranscriptEnvelopeDecoder.decode(body),
            reference: YouTubeVideoReference(videoId: videoID, startSeconds: nil),
            preferredLanguage: "de",
            requestedTrack: YouTubeTrackRequest(
                id: ".de",
                languageCode: "de",
                isAutomatic: false
            )
        )

        XCTAssertEqual(document.track.languageCode, "de")
        XCTAssertEqual(document.selectedForLanguage, "de")
    }

    func testAdapterPinsTheRequestedTrackAndFailsClosed() {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: videoID,
            requestToken: token,
            preferredLanguage: "en",
            requestedTrack: YouTubeTrackRequest(
                id: "a.de",
                languageCode: "de",
                isAutomatic: true
            )
        )

        XCTAssertTrue(source.contains("var REQUESTED_TRACK_ID = \"a.de\""))
        XCTAssertTrue(source.contains("var REQUESTED_TRACK_LANGUAGE = \"de\""))
        XCTAssertTrue(source.contains("var REQUESTED_TRACK_KIND = \"asr\""))
        XCTAssertTrue(source.contains("function pinRequestedTrack"))
        XCTAssertTrue(
            source.contains("requested_track_unavailable"),
            "an unmatched request must terminate instead of falling back"
        )
        XCTAssertTrue(source.contains("envelope.availableTracks = availableTrackEnvelopes"))
    }

    func testAdapterWithoutRequestedTrackKeepsRankedFallback() {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: videoID,
            requestToken: token,
            preferredLanguage: "en"
        )

        XCTAssertTrue(source.contains("var REQUESTED_TRACK_ID = \"\""))
        XCTAssertTrue(source.contains("var REQUESTED_TRACK_LANGUAGE = \"\""))
    }

    func testTrackOptionNormalizationBoundsUntrustedPageInput() {
        let flood = (0..<80).map { index in
            YouTubeCaptionTrackOption(
                id: "id-\(index)",
                languageCode: "lang\(index)",
                name: "Track \(index)",
                kind: "manual"
            )
        }
        XCTAssertEqual(
            YouTubeCaptionTrackOption.normalized(flood).count,
            YouTubeCaptionTrackOption.maximumOptionCount
        )

        let malformed = [
            YouTubeCaptionTrackOption(id: "", languageCode: "en", kind: "manual"),
            YouTubeCaptionTrackOption(id: "ok", languageCode: "  ", kind: "manual"),
            YouTubeCaptionTrackOption(id: "en1", languageCode: "EN_US", kind: "manual"),
            YouTubeCaptionTrackOption(id: "en2", languageCode: "en-GB", kind: "manual"),
            YouTubeCaptionTrackOption(id: "en3", languageCode: "en", kind: "asr"),
        ]
        let normalized = YouTubeCaptionTrackOption.normalized(malformed)
        XCTAssertEqual(normalized.map(\.id), ["en1", "en3"])
        XCTAssertEqual(normalized[0].languageCode, "en-us")
        XCTAssertTrue(normalized[1].isAutomatic)
    }

    // MARK: Warm session

    func testAdapterInstallsWarmEntryPointGuardedByRequestToken() {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: videoID,
            requestToken: token,
            preferredLanguage: "en"
        )

        XCTAssertTrue(source.contains("window.__crYtExtractTrack = warmExtractTrack"))
        XCTAssertTrue(source.contains("installWarmTrackExtractor({"))
        XCTAssertTrue(
            source.contains("if (requestToken !== REQUEST_TOKEN) return false;"),
            "page script must not be able to drive the follow-up entry point"
        )
        XCTAssertTrue(
            source.contains("WARM_FETCH_TIMEOUT_MS"),
            "warm fetches run after the extraction budget is spent and need their own ceiling"
        )
        XCTAssertTrue(source.contains("'warm_session_miss'"))
    }

    func testWarmSessionMissClassifiesAsRetryableCaptionAccess() throws {
        let body = try makeBody(
            cues: [],
            captionTrack: nil,
            extra: [
                "ok": false,
                "followUpToken": "follow-up-1",
                "error": [
                    "code": "warm_session_miss",
                    "message": "The warm document could not serve this caption track.",
                ],
            ]
        )
        let envelope = try YouTubeTranscriptEnvelopeDecoder.decode(body)

        XCTAssertEqual(envelope.followUpToken, "follow-up-1")
        XCTAssertEqual(
            YouTubeTranscriptEnvelopeClassifier.failure(for: envelope),
            .captionAccess,
            "a warm miss must stay retryable so the caller falls back to a full bootstrap"
        )
    }

    func testFollowUpTokenIsAbsentOnOrdinaryEnvelopes() throws {
        let body = try makeBody(
            cues: [["text": "Hello world", "startMs": 0, "durationMs": 900]],
            captionTrack: ["id": ".en", "languageCode": "en", "kind": "manual", "index": 0],
            extra: ["transcriptSource": "json3"]
        )

        XCTAssertNil(YouTubeTranscriptEnvelopeDecoder.followUpToken(from: body))
        XCTAssertEqual(
            YouTubeTranscriptEnvelopeDecoder.requestToken(from: body),
            token
        )
        XCTAssertNil(try YouTubeTranscriptEnvelopeDecoder.decode(body).followUpToken)
    }

    @MainActor
    func testReleaseWarmSessionIsSafeWithoutOne() {
        let service = YouTubeTranscriptService(
            vendoredBridgeLoader: { "" },
            pageLoader: { _, _ in }
        )
        service.releaseWarmSession()
        XCTAssertNil(service.warmSessionVideoIDForTesting)
    }

    func testPickerOrdersPlayableFirstAndSearchesLocalizedNames() {
        let options = [
            YouTubeCaptionTrackOption(id: ".vi", languageCode: "vi", name: "Tiếng Việt", kind: "manual"),
            YouTubeCaptionTrackOption(id: ".de", languageCode: "de", name: "Deutsch", kind: "manual"),
            YouTubeCaptionTrackOption(id: "a.ja", languageCode: "ja", name: "日本語", kind: "asr"),
        ]
        let ordered = YouTubeCaptionLanguagePickerPolicy.ordered(options)
        XCTAssertEqual(ordered.map(\.languageCode), ["de", "ja", "vi"])

        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(
            YouTubeCaptionLanguagePickerPolicy.filtered(ordered, query: "germ", locale: locale)
                .map(\.languageCode),
            ["de"],
            "search matches the localized display name, not only the raw code"
        )
        XCTAssertEqual(
            YouTubeCaptionLanguagePickerPolicy.filtered(ordered, query: " JA ", locale: locale)
                .map(\.languageCode),
            ["ja"]
        )
        XCTAssertEqual(
            YouTubeCaptionLanguagePickerPolicy.filtered(ordered, query: "日本語", locale: locale)
                .map(\.languageCode),
            ["ja"],
            "the page's own track name stays searchable"
        )
        XCTAssertTrue(
            YouTubeCaptionLanguagePickerPolicy
                .filtered(ordered, query: "klingon", locale: locale)
                .isEmpty
        )
    }

    func testPickerRefusesUncachedLanguagesWhileOffline() {
        let german = YouTubeCaptionTrackOption(
            id: ".de",
            languageCode: "de",
            name: "Deutsch",
            kind: "manual"
        )
        // Offline + not on disk: tapping could only end in a network timeout.
        XCTAssertFalse(
            YouTubeCaptionLanguagePickerPolicy.isSelectable(
                german,
                isCurrent: false,
                hasTranscript: false,
                isOnline: false
            )
        )
        // Offline but already cached: the switch never touches the network.
        XCTAssertTrue(
            YouTubeCaptionLanguagePickerPolicy.isSelectable(
                german,
                isCurrent: false,
                hasTranscript: true,
                isOnline: false
            )
        )
        XCTAssertTrue(
            YouTubeCaptionLanguagePickerPolicy.isSelectable(
                german,
                isCurrent: false,
                hasTranscript: false,
                isOnline: true
            )
        )
        XCTAssertFalse(
            YouTubeCaptionLanguagePickerPolicy.isSelectable(
                german,
                isCurrent: true,
                hasTranscript: true,
                isOnline: true
            ),
            "the language already playing is not a switch target"
        )
        XCTAssertFalse(
            YouTubeCaptionLanguagePickerPolicy.isSelectable(
                YouTubeCaptionTrackOption(id: ".vi", languageCode: "vi", kind: "manual"),
                isCurrent: false,
                hasTranscript: true,
                isOnline: true
            ),
            "a cached transcript cannot make an unsupported language narratable"
        )
    }

    private func makeBody(
        cues: [[String: Any]],
        captionTrack: [String: Any]?,
        extra: [String: Any] = [:]
    ) throws -> String {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "requestToken": token,
            "ok": true,
            "requestVideoId": videoID,
            "videoId": videoID,
            "captionLanguage": "en",
            "cues": cues,
            "isLive": false,
            "playability": [
                "status": "OK",
                "classification": "playable",
            ],
            "diagnostics": [],
        ]
        if let captionTrack { object["captionTrack"] = captionTrack }
        for (key, value) in extra { object[key] = value }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    @MainActor
    private func waitForNavigationStarts(
        _ expectedCount: Int,
        count: () -> Int
    ) async {
        for _ in 0..<200 {
            if count() >= expectedCount { return }
            await Task.yield()
        }
        XCTFail("navigation did not start \(expectedCount) time(s)")
    }

    @MainActor
    private func assertCancelled(
        _ task: Task<YouTubeTranscriptDocument, Error>
    ) async {
        do {
            _ = try await task.value
            XCTFail("the pending extraction should have been cancelled")
        } catch {
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .cancelled)
        }
    }

    @MainActor
    private func waitForActiveVideo(
        _ videoID: String,
        service: YouTubeTranscriptService
    ) async {
        for _ in 0..<100 where service.activeVideoIDForTesting != videoID {
            await Task.yield()
        }
    }
}
