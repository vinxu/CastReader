//
//  YouTubeWebScriptsTests.swift
//  CastReaderTests
//
//  Static provenance and protocol-contract checks for the vendored YouTube
//  bridge and the native page-world adapter.
//

import CryptoKit
import Foundation
import JavaScriptCore
import XCTest
@testable import CastReader

final class YouTubeWebScriptsTests: XCTestCase {
    func testSubtitleProofIsAcceptedOnlyForTheExpectedVideo() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.subtitleProofTokenFunction)
        let extractor = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderSubtitleProofFromPlayerBody"
            )
        )
        let token = "video-bound-proof-token_1234567890"
        let body: [String: Any] = [
            "videoId": "wpb-DrbhEiY",
            "context": ["client": ["clientName": "WEB"]],
            "serviceIntegrityDimensions": ["poToken": token],
        ]

        let proof = extractor.call(withArguments: [body, "wpb-DrbhEiY"])
        XCTAssertEqual(proof?.forProperty("token")?.toString(), token)
        XCTAssertEqual(proof?.forProperty("videoId")?.toString(), "wpb-DrbhEiY")
        XCTAssertEqual(proof?.forProperty("clientName")?.toString(), "WEB")

        let staleProof = extractor.call(withArguments: [body, "dQw4w9WgXcQ"])
        XCTAssertTrue(staleProof?.isNull == true)

        let missingToken = extractor.call(withArguments: [[
            "videoId": "wpb-DrbhEiY",
            "serviceIntegrityDimensions": [:],
        ], "wpb-DrbhEiY"])
        XCTAssertTrue(missingToken?.isNull == true)
    }

    func testPlayerRequestBodyCorrelationRequiresExactExpectedVideo() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.subtitleProofTokenFunction)
        let videoIDReader = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderPlayerRequestVideoIDFromBody"
            )
        )
        let expected = "NHHPNMIK-fY"

        XCTAssertEqual(
            videoIDReader.call(withArguments: [[
                "videoId": expected,
                "context": ["client": ["clientName": "WEB_EMBEDDED_PLAYER"]],
            ], expected])?.toString(),
            expected
        )
        XCTAssertEqual(
            videoIDReader.call(withArguments: [
                #"{"videoId":"NHHPNMIK-fY"}"#,
                expected,
            ])?.toString(),
            expected
        )
        XCTAssertTrue(
            videoIDReader.call(withArguments: [[
                "videoId": "unrelated-video",
            ], expected])?.isNull == true
        )
        XCTAssertTrue(
            videoIDReader.call(withArguments: [
                #"{"context":{"client":{"clientName":"WEB"}}}"#,
                expected,
            ])?.isNull == true
        )
    }

    func testOfficialEmbedPreviewUsesTypedExactVideoEndpoint() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.embedPreviewFunction)
        let videoIDReader = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderOfficialEmbedPreviewVideoID"
            )
        )
        let expected = "NHHPNMIK-fY"
        let playerVars: [String: Any] = [
            "embedded_player_response": [
                "embedPreview": [
                    "thumbnailPreviewRenderer": [
                        "playButton": [
                            "buttonRenderer": [
                                "navigationEndpoint": [
                                    "watchEndpoint": ["videoId": expected],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        XCTAssertEqual(
            videoIDReader.call(withArguments: [playerVars, expected])?.toString(),
            expected
        )
        XCTAssertTrue(
            videoIDReader.call(withArguments: [
                playerVars,
                "different-video",
            ])?.isNull == true
        )
        XCTAssertTrue(
            videoIDReader.call(withArguments: [[
                "embedded_player_response": [
                    "embedPreview": [
                        "thumbnailPreviewRenderer": [
                            "watchOnYoutubeButton": ["videoId": expected],
                        ],
                    ],
                ],
            ], expected])?.isNull == true,
            "an unrelated watch link must never authorize bootstrap"
        )
    }

    func testOfficialCaptionTrackMatchesLanguageKindAndVSSID() throws {
        let context = try makeURLCapableJavaScriptContext()
        context.evaluateScript(YouTubeWebScripts.officialCaptionTrackFunction)
        let matcher = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderOfficialCaptionTrackMatch"
            )
        )
        let officialTracks: [[String: Any]] = [
            [
                "languageCode": "fr",
                "vss_id": ".fr",
                "url": "https://www.youtube.com/api/timedtext?v=wpb-DrbhEiY&lang=fr",
            ],
            [
                "languageCode": "en",
                "kind": "asr",
                "vss_id": "a.en",
                "url": "https://www.youtube.com/api/timedtext?v=wpb-DrbhEiY&lang=en&kind=asr",
            ],
            [
                "languageCode": "en",
                "vss_id": ".en",
                "url": "https://www.youtube.com/api/timedtext?v=wpb-DrbhEiY&lang=en",
            ],
        ]

        let manual = matcher.call(withArguments: [[
            "languageCode": "en",
            "vssId": ".en",
        ], officialTracks])
        XCTAssertEqual(manual?.forProperty("vss_id")?.toString(), ".en")
        XCTAssertNotEqual(manual?.forProperty("kind")?.toString(), "asr")

        let generated = matcher.call(withArguments: [[
            "languageCode": "en",
            "kind": "asr",
            "vssId": "a.en",
        ], officialTracks])
        XCTAssertEqual(generated?.forProperty("vss_id")?.toString(), "a.en")
        XCTAssertEqual(generated?.forProperty("kind")?.toString(), "asr")

        let unrelated = matcher.call(withArguments: [[
            "languageCode": "de",
            "vssId": ".de",
        ], officialTracks])
        XCTAssertTrue(unrelated?.isNull == true)
    }

    func testTrustedDecoratedCaptionURLIsSameOriginVideoScopedAndProofBearing() throws {
        let context = try makeURLCapableJavaScriptContext()
        context.evaluateScript(YouTubeWebScripts.officialCaptionTrackFunction)
        let validator = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderTrustedDecoratedCaptionURL"
            )
        )
        let videoID = "wpb-DrbhEiY"
        let valid = "https://www.youtube.com/api/timedtext?v=\(videoID)&lang=en&pot=video-proof-token&potc=1"

        XCTAssertEqual(
            validator.call(withArguments: [valid, videoID])?.toString(),
            valid
        )
        XCTAssertEqual(
            validator.call(withArguments: [["url": valid], videoID])?.toString(),
            valid,
            "the official player exposes decorated URLs on its track objects"
        )

        let rejected = [
            "http://www.youtube.com/api/timedtext?v=\(videoID)&pot=proof&potc=1",
            "https://m.youtube.com/api/timedtext?v=\(videoID)&pot=proof&potc=1",
            "https://www.youtube.com/api/timedtext/extra?v=\(videoID)&pot=proof&potc=1",
            "https://www.youtube.com/api/timedtext?v=stale-video&pot=proof&potc=1",
            "https://www.youtube.com/api/timedtext?v=\(videoID)&potc=1",
            "https://www.youtube.com/api/timedtext?v=\(videoID)&pot=&potc=1",
            "https://www.youtube.com/api/timedtext?v=\(videoID)&pot=proof",
            "https://www.youtube.com/api/timedtext?v=\(videoID)&pot=proof&potc=0",
        ]
        for rawURL in rejected {
            XCTAssertTrue(
                validator.call(withArguments: [rawURL, videoID])?.isNull == true,
                "must reject untrusted decorated caption URL: \(rawURL)"
            )
        }
    }

    func testCompletedLiveArchiveIsNotClassifiedAsAnActiveBroadcast() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.activeLiveBroadcastFunction)
        let classifier = try XCTUnwrap(
            context.objectForKeyedSubscript("castReaderIsActiveLiveBroadcast")
        )

        let endedArchive = classifier.call(withArguments: [
            ["isLiveContent": true],
            ["status": "OK"],
            [
                "startTimestamp": "2026-01-01T10:00:00Z",
                "endTimestamp": "2026-01-01T11:00:00Z",
                "isLiveNow": false,
            ],
        ])
        let upcomingBroadcast = classifier.call(withArguments: [
            ["isLiveContent": true],
            ["status": "LIVE_STREAM_OFFLINE"],
            ["startTimestamp": "2026-08-11T10:00:00Z"],
        ])
        let activeBroadcast = classifier.call(withArguments: [
            ["isLive": true],
            ["status": "OK"],
            ["isLiveNow": true],
        ])

        XCTAssertEqual(endedArchive?.toBool(), false)
        XCTAssertEqual(upcomingBroadcast?.toBool(), true)
        XCTAssertEqual(activeBroadcast?.toBool(), true)
    }

    func testPrivateReasonWinsWhenLoginStatusAndCopyAreAlsoPresent() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            YouTubeWebScripts.playabilityClassificationFunction
        )
        let classifier = try XCTUnwrap(
            context.objectForKeyedSubscript("playabilityClassification")
        )

        XCTAssertEqual(
            classifier.call(withArguments: [
                "LOGIN_REQUIRED",
                "This is a private video. Please sign in to continue.",
                false,
            ])?.toString(),
            "private"
        )
    }

    func testOnlyBotVerificationCanUsePublicTranscriptLoginFallback() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            YouTubeWebScripts.botVerificationChallengeFunction
        )
        let classifier = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderIsBotVerificationChallenge"
            )
        )

        XCTAssertEqual(
            classifier.call(withArguments: [[
                "status": "LOGIN_REQUIRED",
                "reason": "Sign in to confirm you’re not a bot",
            ]])?.toBool(),
            true
        )
        XCTAssertEqual(
            classifier.call(withArguments: [[
                "status": "LOGIN_REQUIRED",
                "reason": "请登录，以便我们确认你不是聊天机器人",
            ]])?.toBool(),
            true
        )
        for reason in [
            "Please sign in to view this video",
            "Members-only content",
            "This is a private video",
        ] {
            XCTAssertEqual(
                classifier.call(withArguments: [[
                    "status": "LOGIN_REQUIRED",
                    "reason": reason,
                ]])?.toBool(),
                false
            )
        }

        let documentClassifier = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderDocumentHasBotVerificationChallenge"
            )
        )
        XCTAssertEqual(
            documentClassifier.call(withArguments: [[
                "title": "YouTube",
                "body": [
                    "innerText": "Sign in to confirm you’re not a bot",
                ],
            ]])?.toBool(),
            true
        )
        XCTAssertEqual(
            documentClassifier.call(withArguments: [[
                "title": "YouTube",
                "body": ["innerText": "Please sign in to continue"],
            ]])?.toBool(),
            false
        )
        XCTAssertEqual(
            documentClassifier.call(withArguments: [[
                "title": "A robot documentary",
                "body": ["innerText": "Watch this public science video"],
            ]])?.toBool(),
            false,
            "ordinary page content mentioning a robot is not verification evidence"
        )

        let evidenceClassifier = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderHasBotVerificationChallengeEvidence"
            )
        )
        let mediaBlockedRuntime: [String: Any] = [
            "videoDetails": ["videoId": "wpb-DrbhEiY"],
            "playabilityStatus": [
                "status": "UNPLAYABLE",
                "reason": "Video unavailable",
            ],
        ]
        XCTAssertEqual(
            evidenceClassifier.call(withArguments: [[
                "playabilityStatus": [
                    "status": "LOGIN_REQUIRED",
                    "reason": "Sign in to confirm you’re not a bot",
                ],
            ], mediaBlockedRuntime, [
                "title": "YouTube",
                "body": ["innerText": ""],
            ]])?.toBool(),
            true,
            "the selected media-blocked runtime response must not erase the initial challenge"
        )
        XCTAssertEqual(
            evidenceClassifier.call(withArguments: [[
                "playabilityStatus": [
                    "status": "LOGIN_REQUIRED",
                    "reason": "Please sign in to continue",
                ],
            ], mediaBlockedRuntime, [
                "title": "YouTube",
                "body": ["innerText": ""],
            ]])?.toBool(),
            false
        )
    }

    func testInitialCaptionResponseWinsOverMediaBlockedRuntimeResponse() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.playerResponseSelectionFunction)
        let selector = try XCTUnwrap(
            context.objectForKeyedSubscript("castReaderSelectPlayerResponse")
        )
        let videoID = "captioned-video"
        let initial: [String: Any] = [
            "videoDetails": ["videoId": videoID],
            "playabilityStatus": ["status": "OK"],
            "captions": [
                "playerCaptionsTracklistRenderer": [
                    "captionTracks": [["languageCode": "en"]],
                ],
            ],
        ]
        let runtime: [String: Any] = [
            "videoDetails": ["videoId": videoID],
            "playabilityStatus": [
                "status": "UNPLAYABLE",
                "reason": "Video unavailable",
            ],
        ]

        let selected = selector.call(withArguments: [initial, runtime, videoID])
        XCTAssertEqual(
            selected?.forProperty("playabilityStatus")?
                .forProperty("status")?.toString(),
            "OK"
        )

        let staleInitial: [String: Any] = [
            "videoDetails": ["videoId": "previous-video"],
            "playabilityStatus": ["status": "OK"],
            "captions": initial["captions"] as Any,
        ]
        let matchingRuntime: [String: Any] = [
            "videoDetails": ["videoId": videoID],
            "playabilityStatus": ["status": "OK"],
        ]
        let selectedMatching = selector.call(
            withArguments: [staleInitial, matchingRuntime, videoID]
        )
        XCTAssertEqual(
            selectedMatching?.forProperty("videoDetails")?
                .forProperty("videoId")?.toString(),
            videoID
        )
    }

    func testExactRequestCorrelatedPlayerResponseCanHydrateWithoutVideoDetails() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.playerResponseSelectionFunction)
        let selector = try XCTUnwrap(
            context.objectForKeyedSubscript("castReaderSelectPlayerResponse")
        )
        let videoID = "NHHPNMIK-fY"
        let captured: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "captions": [
                "playerCaptionsTracklistRenderer": [
                    "captionTracks": [["languageCode": "en"]],
                ],
            ],
        ]
        let staleRuntime: [String: Any] = [
            "videoDetails": ["videoId": videoID],
            "playabilityStatus": ["status": "UNPLAYABLE"],
        ]

        let selected = selector.call(withArguments: [
            NSNull(),
            staleRuntime,
            videoID,
            captured,
            videoID,
        ])
        XCTAssertEqual(
            selected?.forProperty("playabilityStatus")?
                .forProperty("status")?.toString(),
            "OK"
        )
        XCTAssertEqual(
            selected?.forProperty("captions")?
                .forProperty("playerCaptionsTracklistRenderer")?
                .forProperty("captionTracks")?.toArray()?.count,
            1
        )

        let rejected = selector.call(withArguments: [
            NSNull(),
            NSNull(),
            videoID,
            captured,
            "different-video",
        ])
        XCTAssertTrue(rejected?.isNull == true)
    }

    func testInitialDataProvidesVideoScopedTranscriptFallbackEvidence() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.initialDataTranscriptFunction)
        let videoIDReader = try XCTUnwrap(
            context.objectForKeyedSubscript("castReaderInitialDataVideoID")
        )
        let transcriptReader = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderInitialDataHasTranscriptEndpoint"
            )
        )
        let endpointReader = try XCTUnwrap(
            context.objectForKeyedSubscript(
                "castReaderInitialDataTranscriptEndpoint"
            )
        )
        let videoID = "wpb-DrbhEiY"
        let fixture: [String: Any] = [
            "currentVideoEndpoint": [
                "watchEndpoint": ["videoId": videoID],
            ],
            "engagementPanels": [[
                "engagementPanelSectionListRenderer": [
                    "targetId": "engagement-panel-searchable-transcript",
                    "content": [
                        "continuationItemRenderer": [
                            "continuationEndpoint": [
                                "clickTrackingParams": "tracking-token",
                                "commandMetadata": [
                                    "webCommandMetadata": [
                                        "apiUrl": "/youtubei/v1/get_transcript",
                                    ],
                                ],
                                "getTranscriptEndpoint": [
                                    "params": "video-scoped-transcript-token",
                                ],
                            ],
                        ],
                    ],
                ],
            ]],
        ]

        XCTAssertEqual(
            videoIDReader.call(withArguments: [fixture])?.toString(),
            videoID
        )
        XCTAssertEqual(
            transcriptReader.call(withArguments: [fixture, videoID])?.toBool(),
            true
        )
        let endpoint = endpointReader.call(
            withArguments: [fixture, videoID]
        )?.toDictionary() as? [String: Any]
        XCTAssertEqual(endpoint?["params"] as? String, "video-scoped-transcript-token")
        XCTAssertEqual(endpoint?["clickTrackingParams"] as? String, "tracking-token")
        XCTAssertEqual(endpoint?["apiUrl"] as? String, "/youtubei/v1/get_transcript")
        XCTAssertEqual(
            transcriptReader.call(withArguments: [fixture, "other-video"])?.toBool(),
            false,
            "a stale SPA page must never authorize the requested video's fallback"
        )
        XCTAssertEqual(
            transcriptReader.call(withArguments: [[
                "currentVideoEndpoint": [
                    "watchEndpoint": ["videoId": videoID],
                ],
            ], videoID])?.toBool(),
            false
        )
    }

    func testTranscriptEndpointParserSupportsSegmentCueAndContinuationRenderers() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.initialDataTranscriptFunction)
        let cueReader = try XCTUnwrap(
            context.objectForKeyedSubscript("castReaderTranscriptRendererCues")
        )
        let continuationReader = try XCTUnwrap(
            context.objectForKeyedSubscript("castReaderTranscriptSegmentContinuation")
        )
        let fixture: [String: Any] = [
            "actions": [[
                "updateEngagementPanelAction": [
                    "content": [
                        "transcriptRenderer": [
                            "content": [
                                "transcriptSearchPanelRenderer": [
                                    "body": [
                                        "transcriptSegmentListRenderer": [
                                            "initialSegments": [
                                                ["transcriptSegmentRenderer": [
                                                    "snippet": ["runs": [["text": "第一句字幕"]]],
                                                    "startMs": "1200",
                                                    "endMs": "2700",
                                                ]],
                                                ["transcriptSectionHeaderRenderer": [
                                                    "title": ["simpleText": "章节"],
                                                ]],
                                                ["transcriptCueRenderer": [
                                                    "cue": ["simpleText": "Second cue"],
                                                    "startOffsetMs": "3000",
                                                    "durationMs": "900",
                                                ]],
                                            ],
                                            "continuations": [[
                                                "continuationItemRenderer": [
                                                    "continuationEndpoint": [
                                                        "clickTrackingParams": "next-click",
                                                        "getTranscriptEndpoint": [
                                                            "params": "next-page-token",
                                                        ],
                                                    ],
                                                ],
                                            ]],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ]],
        ]

        let cues = cueReader.call(withArguments: [fixture])?.toArray()
            as? [[String: Any]]
        XCTAssertEqual(cues?.count, 2)
        XCTAssertEqual(cues?.first?["text"] as? String, "第一句字幕")
        XCTAssertEqual(cues?.first?["startMs"] as? Int, 1_200)
        XCTAssertEqual(cues?.first?["durationMs"] as? Int, 1_500)
        XCTAssertEqual(cues?.last?["text"] as? String, "Second cue")

        let continuation = continuationReader.call(
            withArguments: [fixture]
        )?.toDictionary() as? [String: Any]
        XCTAssertEqual(continuation?["params"] as? String, "next-page-token")
        XCTAssertEqual(continuation?["clickTrackingParams"] as? String, "next-click")

        let nestedViewModelFixture: [String: Any] = [
            "frameworkUpdates": [
                "entityBatchUpdate": [
                    "mutations": [[
                        "payload": [
                            "transcriptSegmentViewModel": [
                                "segment": [
                                    "attributedString": [
                                        "content": "Nested 2026 cue",
                                    ],
                                    "startTimeMilliseconds": "4200",
                                    "endTimeMilliseconds": "5750",
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
        let nestedCues = cueReader.call(
            withArguments: [nestedViewModelFixture]
        )?.toArray() as? [[String: Any]]
        XCTAssertEqual(nestedCues?.count, 1)
        XCTAssertEqual(nestedCues?.first?["text"] as? String, "Nested 2026 cue")
        XCTAssertEqual(nestedCues?.first?["startMs"] as? Int, 4_200)
        XCTAssertEqual(nestedCues?.first?["durationMs"] as? Int, 1_550)
    }

    func testCaptionTracksComeFromTheSelectedPlayerResponseBeforeBridgeFallback() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.playerResponseSelectionFunction)
        let resolver = try XCTUnwrap(
            context.objectForKeyedSubscript("castReaderResolveCaptionTracks")
        )
        let response: [String: Any] = [
            "captions": [
                "playerCaptionsTracklistRenderer": [
                    "captionTracks": [[
                        "languageCode": "en",
                        "baseUrl": "https://www.youtube.com/api/timedtext?fixture=initial",
                    ]],
                ],
            ],
        ]
        let staleBridgeTracks: [[String: Any]] = [[
            "languageCode": "fr",
            "baseUrl": "https://www.youtube.com/api/timedtext?fixture=runtime",
        ]]

        let resolved = try XCTUnwrap(
            resolver.call(withArguments: [response, staleBridgeTracks])?.toArray()
                as? [[String: Any]]
        )
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?["languageCode"] as? String, "en")

        let fallback = try XCTUnwrap(
            resolver.call(withArguments: [[:], staleBridgeTracks])?.toArray()
                as? [[String: Any]]
        )
        XCTAssertEqual(fallback.first?["languageCode"] as? String, "fr")
    }

    func testTranscriptPanelClockParserRejectsAccessibilityDurations() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(YouTubeWebScripts.transcriptDOMCueFunction)
        let parser = try XCTUnwrap(
            context.objectForKeyedSubscript("castReaderTranscriptClockMilliseconds")
        )

        XCTAssertEqual(parser.call(withArguments: ["0:01"])?.toInt32(), 1_000)
        XCTAssertEqual(parser.call(withArguments: ["1:09"])?.toInt32(), 69_000)
        XCTAssertEqual(parser.call(withArguments: ["1:02:03"])?.toInt32(), 3_723_000)
        XCTAssertTrue(parser.call(withArguments: ["18 seconds"])?.isNull == true)
        XCTAssertTrue(parser.call(withArguments: ["1:60"])?.isNull == true)

        let cues = context.evaluateScript(
            #"""
            (function () {
              var timestamp = { textContent: '0:18' };
              var caption = { textContent: "We're no strangers to love" };
              var root = null;
              var segment = {
                matches: function () { return true; },
                closest: function () { return root; },
                querySelector: function (selector) {
                  return selector.indexOf('Timestamp') >= 0 ? timestamp : caption;
                }
              };
              root = {
                querySelector: function () { return segment; },
                querySelectorAll: function () { return [segment]; }
              };
              return castReaderTranscriptPanelCues(root);
            })();
            """#
        )?.toArray() as? [[String: Any]]
        XCTAssertEqual(cues?.count, 1)
        XCTAssertEqual(cues?.first?["startMs"] as? Int, 18_000)
        XCTAssertEqual(cues?.first?["text"] as? String, "We're no strangers to love")
    }

    func testVendoredBridgeProvenanceAndHash() throws {
        XCTAssertEqual(YouTubeWebScripts.sourceRepository, "readout-desktop")
        XCTAssertEqual(
            YouTubeWebScripts.sourcePath,
            "src/entrypoints/youtube-bridge.content.ts"
        )
        XCTAssertEqual(
            YouTubeWebScripts.sourceCommit,
            "92d22744839bfb34c6c4f5d7152192729074919f"
        )
        XCTAssertEqual(
            YouTubeWebScripts.vendoredBridgeSHA256,
            "877af9a72117d6c2afd0e303f74fe4bb03f5172e7c90ad9ac3788aeb77add02c"
        )

        let source = try XCTUnwrap(
            YouTubeWebScripts.loadVendoredBridge(),
            "WebAssets/YouTube/youtube-bridge.js must be bundled by the app target"
        )
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(digest, YouTubeWebScripts.vendoredBridgeSHA256)
    }

    func testVendoredBridgeContainsRequiredPageWorldProtocols() throws {
        let source = try XCTUnwrap(YouTubeWebScripts.loadVendoredBridge())
        let requiredTokens = [
            "__cr_yt_req__",
            "__cr_yt_res__",
            "__cr_yt_fetch_req__",
            "__cr_yt_fetch_res__",
            "__cr_yt_transcript_req__",
            "__cr_yt_transcript_res__",
            "crYtTracksVideoId",
            "crYtTracksOverride",
        ]
        for token in requiredTokens {
            XCTAssertTrue(source.contains(token), "missing bridge token: \(token)")
        }
        XCTAssertFalse(source.contains("chrome."))
        XCTAssertFalse(source.contains("browser.runtime"))
    }

    func testEarlyBootstrapPreservesVendoredSourceAndWaitsForBody() {
        let fixture = "window.__bridgeFixture = (window.__bridgeFixture || 0) + 1;"
        let source = YouTubeWebScripts.earlyBridgeBootstrap(fixture)
        XCTAssertTrue(source.contains(fixture))
        XCTAssertTrue(source.contains("setInterval(install, 25)"))
        XCTAssertTrue(source.contains("!document.body"))
        XCTAssertTrue(source.contains("crYtBridgeBootstrapError"))
    }

    func testExtractionAdapterContainsRequiredNativeContract() {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "fixture-video-id"
        )
        let requiredTokens = [
            "fixture-video-id",
            "__cr_yt_req__",
            "__cr_yt_res__",
            "__cr_yt_fetch_req__",
            "__cr_yt_fetch_res__",
            "__cr_yt_transcript_req__",
            "__cr_yt_transcript_res__",
            "webkit.messageHandlers.crYt",
            "JSON.stringify(envelope)",
            "selectBestTrack",
            "orderedTracks",
            "languageAliasMatches",
            "return 'zh-hans'",
            "return 'zh-hant'",
            "castReaderCaptionURLWithProof",
            "castReaderSubtitleProofFromPlayerBody",
            "castReaderPlayerRequestVideoIDFromBody",
            "captured exact-video player response transport=",
            "capturePlayerFetchResponse",
            "capturePlayerResponseText",
            "capturedPlayerResponseVideoID",
            "serviceIntegrityDimensions",
            "poToken",
            "potc",
            "subtitle proof required=",
            "captured video-scoped subtitle proof",
            "installEarlyPlayerXHRProofCapture",
            "officialPlayerSubtitleProof",
            "typeof player.w5",
            "castReaderOfficialCaptionTrackMatch",
            "castReaderTrustedDecoratedCaptionURL",
            "getOption('captions', 'tracklist'",
            "setOption('captions', 'track'",
            "official_timedtext_capture",
            "externalVideoId",
            "attestationResponseData",
            "ENGAGEMENT_TYPE_VIDEO_TRANSCRIPT_REQUEST",
            "direct transcript attestation available=",
            "timedtext track=",
            "parseJSON3",
            "parseWebVTT",
            "parseTimedtextXML",
            "dedupeCues",
            "meta[property=\"og:title\"]",
            "meta[property=\"og:image\"]",
            "highestResolutionThumbnail",
            "microformat.thumbnail",
            "maxresdefault",
            "sddefault",
            "captionLanguage",
            "captionTrack",
            "isLive",
            "castReaderIsActiveLiveBroadcast",
            "!liveDetails.endTimestamp",
            "playabilityClassification",
            "castReaderIsBotVerificationChallenge",
            "castReaderSelectPlayerResponse",
            "castReaderResolveCaptionTracks",
            "castReaderInitialDataVideoID",
            "castReaderInitialDataTranscriptEndpoint",
            "castReaderInitialDataHasTranscriptEndpoint",
            "castReaderTranscriptRendererCues",
            "castReaderTranscriptSegmentContinuation",
            "startTimeMilliseconds",
            "directTranscriptViaInitialData",
            "INNERTUBE_API_KEY",
            "/youtubei/v1/get_transcript",
            "requestInput.href",
            "transcript_fetch_capture",
            "transcript_endpoint",
            "responseTracks=",
            "bridgeTracks=",
            "initialDataVideo=",
            "using video-scoped initialData transcript fallback",
            "castReaderTranscriptPanelCues",
            "ytwTranscriptSegmentViewModelTimestamp",
            "ytAttributedStringHost[role=\"text\"]",
            "structured panel DOM cues=",
            "durationSeconds",
            "storyboardSpec",
            "ADAPTER_BUDGET_MS = 34500",
            "FAST_NO_CAPTION_MIN_ELAPSED_MS = 3500",
            "FAST_NO_CAPTION_STABILITY_MS = 1000",
            "FAST_NO_CAPTION_MIN_SAMPLES = 4",
            "playerDeadline = Math.min(startedAt + 9500",
            "while (Date.now() < playerDeadline)",
            "playerDeadline - Date.now()",
            "highConfidenceNoCaptionEvidence",
            "conclusivelyNoCaptions",
            "officialCaptionModuleState",
            "requestedOfficialCaptionModule",
            "typeof player.getOptions",
            "var options = player.getOptions();",
            "matching player has no hydrated caption tracks yet",
            "remainingBudget() < (hasTrustedOfficialURL ? 12000 : 25500)",
            "remainingBudget() - 2500",
            "Math.min(24000, remainingBudget() - 200)",
            "Math.min(6500, remainingBudget() - 300)",
            "terminalPlayabilityError",
            "retainRestrictedAccessEvidence",
            "retained sign-in/verification evidence",
            "code: 'live_video'",
            "code: 'restricted_video'",
            "'youtube_verification_required'",
            "code: 'unavailable_video'",
            "code: 'adapter_timeout'",
            "code: 'player_bootstrap_failed'",
            "player bootstrap failed ",
            "sawFetchTimeout",
            "sawFetchNetworkFailure",
            "abandoning timedtext candidates after uncorrelated fetch timeout",
            "'fetch_timeout'",
            "'fetch_failed'",
            "'transcript_access_rejected'",
            "'transcript_access_failed'",
            "public transcript succeeded despite generic login challenge",
            "runWhenBodyIsReady",
            "missing_document_body",
        ]
        for token in requiredTokens {
            XCTAssertTrue(source.contains(token), "missing adapter token: \(token)")
        }
        XCTAssertTrue(source.contains("/^\\/embed\\/([^/?]+)\\/?$/"))
        XCTAssertTrue(source.contains("var isEmbedSurface ="))
        XCTAssertTrue(
            source.contains("official embed surface: watch transcript lanes disabled")
        )
        XCTAssertTrue(source.contains("cues.length === 0 && !isEmbedSurface"))
        XCTAssertFalse(source.contains("code: 'player_timeout'"))
        XCTAssertFalse(source.contains("chrome."))
        XCTAssertFalse(source.contains("browser.runtime"))
        XCTAssertFalse(source.contains("24500"))
        XCTAssertFalse(source.contains("11000"))
        XCTAssertFalse(source.contains("attempt < 6"))

        let timeoutBranch = try? XCTUnwrap(
            source.range(of: "if (fetchError.indexOf('timeout') >= 0)")
        )
        if let timeoutBranch,
           let nextBranch = source.range(
               of: "} else if (!result.ok",
               range: timeoutBranch.upperBound..<source.endIndex
           ) {
            let body = source[timeoutBranch.lowerBound..<nextBranch.lowerBound]
            XCTAssertTrue(body.contains("break timedtextFormats;"))
        } else {
            XCTFail("missing timedtext timeout control-flow branch")
        }
    }

    func testEmbedBootstrapIsExactSingleShotAndPrefersCueing() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "NHHPNMIK-fY"
        )
        let start = try XCTUnwrap(
            source.range(of: "function maybeBootstrapOfficialEmbedPreview(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "function embedBootstrapDiagnostic()",
                range: start.upperBound..<source.endIndex
            )
        )
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(body.contains("castReaderOfficialEmbedPreviewVideoID("))
        XCTAssertTrue(body.contains("if (!isOfficialEmbedSurface() || embedBootstrapAttempted)"))
        let cueByID = try XCTUnwrap(body.range(of: "typeof player.cueVideoById"))
        let cueByVars = try XCTUnwrap(
            body.range(of: "typeof player.cueVideoByPlayerVars")
        )
        let exactButton = try XCTUnwrap(
            body.range(of: "exactOfficialEmbedPlayButton()")
        )
        XCTAssertLessThan(cueByID.lowerBound, cueByVars.lowerBound)
        XCTAssertLessThan(cueByVars.lowerBound, exactButton.lowerBound)
        XCTAssertEqual(
            body.components(separatedBy: "button.click();").count - 1,
            1,
            "the official overlay click must remain single-shot"
        )
        XCTAssertTrue(body.contains("embedCueAttemptedAt = Date.now();"))
        XCTAssertTrue(body.contains("Date.now() - embedCueAttemptedAt < 150"))
        XCTAssertTrue(body.contains("capturedPlayerResponse || resolvedPlayerVideoID(response)"))
        XCTAssertTrue(body.contains("if (!embedCueAttempted)"))
        XCTAssertTrue(body.contains("typeof officialPlayer.playVideo"))
        XCTAssertTrue(body.contains("embedBootstrapMethod = 'official_player_playVideo'"))
        XCTAssertEqual(
            body.components(separatedBy: "officialPlayer.playVideo();").count - 1,
            1,
            "the muted player bootstrap must remain single-shot"
        )
        let exactButtonFallback = try XCTUnwrap(
            body.range(of: "var button = exactOfficialEmbedPlayButton();")
        )
        let playerFallback = try XCTUnwrap(
            body.range(of: "officialPlayer.playVideo();")
        )
        XCTAssertLessThan(exactButtonFallback.lowerBound, playerFallback.lowerBound)

        let buttonStart = try XCTUnwrap(
            source.range(of: "function exactOfficialEmbedPlayButton()")
        )
        let buttonEnd = try XCTUnwrap(
            source.range(
                of: "function maybeBootstrapOfficialEmbedPreview(",
                range: buttonStart.upperBound..<source.endIndex
            )
        )
        let buttonBody = source[buttonStart.lowerBound..<buttonEnd.lowerBound]
        XCTAssertTrue(buttonBody.contains("#movie_player button.ytp-large-play-button"))
        XCTAssertTrue(buttonBody.contains("#player button.ytp-large-play-button"))
        XCTAssertTrue(buttonBody.contains("#movie_player button.ytmCuedOverlayPlayButton"))
        XCTAssertTrue(buttonBody.contains("#player button.ytmCuedOverlayPlayButton"))
        XCTAssertTrue(buttonBody.contains("button.closest('a[href]')"))
        XCTAssertFalse(buttonBody.contains("querySelector('button')"))
        XCTAssertFalse(buttonBody.contains("querySelectorAll('button')"))

        let waitStart = try XCTUnwrap(
            source.range(of: "async function waitForMatchingPlayer()")
        )
        let waitEnd = try XCTUnwrap(
            source.range(
                of: "function normalizedLanguage",
                range: waitStart.upperBound..<source.endIndex
            )
        )
        let waitBody = source[waitStart.lowerBound..<waitEnd.lowerBound]
        let bootstrap = try XCTUnwrap(
            waitBody.range(of: "maybeBootstrapOfficialEmbedPreview(expected);")
        )
        let snapshot = try XCTUnwrap(
            waitBody.range(of: "var synchronous = snapshot(null);")
        )
        XCTAssertLessThan(bootstrap.lowerBound, snapshot.lowerBound)
    }

    func testPlayingEmbedBootstrapIsMutedAndPausedAfterExactResponseCapture() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "NHHPNMIK-fY"
        )
        let pauseStart = try XCTUnwrap(
            source.range(of: "function pauseOfficialEmbedAfterHydration(")
        )
        let pauseEnd = try XCTUnwrap(
            source.range(
                of: "function maybeBootstrapOfficialEmbedPreview(",
                range: pauseStart.upperBound..<source.endIndex
            )
        )
        let pauseBody = source[pauseStart.lowerBound..<pauseEnd.lowerBound]
        XCTAssertTrue(pauseBody.contains("String(correlatedVideoID || '') !== expected"))
        XCTAssertTrue(pauseBody.contains("!isOfficialEmbedSurface()"))
        XCTAssertFalse(pauseBody.contains("!embedBootstrapAttempted"))
        XCTAssertTrue(pauseBody.contains("document.querySelector('#movie_player')"))
        XCTAssertTrue(pauseBody.contains("typeof player.mute === 'function'"))
        XCTAssertTrue(pauseBody.contains("player.pauseVideo();"))
        XCTAssertTrue(pauseBody.contains("setTimeout(pauseWhenReady, 50)"))

        let publishStart = try XCTUnwrap(
            source.range(of: "function publishCapturedPlayerResponse(")
        )
        let publishEnd = try XCTUnwrap(
            source.range(
                of: "function capturePlayerResponseText(",
                range: publishStart.upperBound..<source.endIndex
            )
        )
        let publishBody = source[publishStart.lowerBound..<publishEnd.lowerBound]
        let correlate = try XCTUnwrap(
            publishBody.range(of: "videoID !== expected")
        )
        let storeResponse = try XCTUnwrap(
            publishBody.range(of: "capturedPlayerResponse = response;")
        )
        let pause = try XCTUnwrap(
            publishBody.range(of: "pauseOfficialEmbedAfterHydration(videoID);")
        )
        XCTAssertLessThan(correlate.lowerBound, storeResponse.lowerBound)
        XCTAssertLessThan(storeResponse.lowerBound, pause.lowerBound)
    }

    func testPlayerResponseCaptureIsRequestBodyCorrelatedForFetchAndXHR() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "NHHPNMIK-fY"
        )
        XCTAssertTrue(source.contains("parsedURL.origin === location.origin"))
        XCTAssertTrue(source.contains("correlatedPlayerVideoID = capturePlayerRequestBody("))
        XCTAssertTrue(source.contains("capturePlayerFetchResponse(response, correlatedPlayerVideoID)"))
        XCTAssertTrue(source.contains("requestInput.clone().text()"))
        XCTAssertTrue(source.contains("!hasExplicitBody && requestInput"))
        XCTAssertTrue(source.contains("this.addEventListener('loadend'"))
        XCTAssertTrue(source.contains("'xhr'"))
        XCTAssertTrue(source.contains("capturedPlayerResponse,"))
        XCTAssertTrue(source.contains("capturedPlayerResponseVideoID"))
        XCTAssertTrue(source.contains("resolvedPlayerVideoID(response)"))

        let lateStart = try XCTUnwrap(
            source.range(of: "if (cues.length === 0 && !directLane.promise &&")
        )
        let lateEnd = try XCTUnwrap(
            source.range(
                of: "if (cues.length === 0 && !isEmbedSurface)",
                range: lateStart.upperBound..<source.endIndex
            )
        )
        let lateBranch = source[lateStart.lowerBound..<lateEnd.lowerBound]
        XCTAssertTrue(
            lateBranch.contains("!isEmbedSurface"),
            "Embed must never enter the watch-only late get_transcript lane"
        )
    }

    func testMatchingPlayerChecksSynchronousResponseBeforeWaitingForBridge() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        let functionStart = try XCTUnwrap(
            source.range(of: "async function waitForMatchingPlayer()")
        )
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "function normalizedLanguage",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let body = source[functionStart.lowerBound..<functionEnd.lowerBound]
        let synchronousRead = try XCTUnwrap(
            body.range(of: "var synchronous = snapshot(null);")
        )
        let bridgeWait = try XCTUnwrap(
            body.range(of: "var result = await fetchTracksOnce();")
        )

        XCTAssertLessThan(
            synchronousRead.lowerBound,
            bridgeWait.lowerBound,
            "an already hydrated exact-video response must bypass the 650 ms bridge wait"
        )
        XCTAssertTrue(body.contains("synchronous.tracks.length > 0"))
        XCTAssertTrue(body.contains("hasAuthoritativeInitialTerminal()"))
        XCTAssertTrue(body.contains("return synchronous;"))
    }

    func testAdapterDiagnosticsPrefixRelativeElapsedMillisecondsWithoutNewSecrets() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY",
            requestToken: "sensitive-fixture-token"
        )
        let functionStart = try XCTUnwrap(source.range(of: "function note(value)"))
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "function sleep(ms)",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let body = source[functionStart.lowerBound..<functionEnd.lowerBound]

        XCTAssertTrue(body.contains("Math.round(Date.now() - startedAt)"))
        XCTAssertTrue(body.contains("'+' + elapsedMilliseconds + 'ms ' + String(value)"))
        for forbidden in [
            "REQUEST_TOKEN",
            "EXPECTED_VIDEO_ID",
            "location.href",
            "document.cookie",
            "capturedSubtitleProof",
            "latestOfficialTimedtextURL",
        ] {
            XCTAssertFalse(
                body.contains(forbidden),
                "elapsed-time decoration must not append sensitive context: \(forbidden)"
            )
        }
        XCTAssertFalse(body.contains("sensitive-fixture-token"))
    }

    func testDirectTranscriptLaneOverlapsHydrationWithoutParallelVendoredFetches() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        let runStart = try XCTUnwrap(source.range(of: "async function run()"))
        let runBody = source[runStart.lowerBound...]
        let directStart = try XCTUnwrap(
            runBody.range(of: "note('starting direct transcript lane endpointInitially='")
        )
        let proofWait = try XCTUnwrap(
            runBody.range(of: "await waitForSubtitleProof(")
        )
        XCTAssertLessThan(
            directStart.lowerBound,
            proofWait.lowerBound,
            "the correlated direct endpoint wait must overlap proof/module hydration"
        )
        XCTAssertFalse(runBody.contains(
            "if (transcriptEndpointWasFound) {\n              note('starting direct transcript lane"
        ))
        XCTAssertTrue(runBody.contains(
            "if (cues.length === 0 && directLane.promise)"
        ))
        XCTAssertTrue(runBody.contains(
            "mergeDirectResult(await directLane.promise);"
        ))
        XCTAssertTrue(runBody.contains("adoptDirectIfSettled()"))
        XCTAssertTrue(source.contains("typeof shouldStop === 'function'"))

        let directJoin = try XCTUnwrap(
            runBody.range(of: "mergeDirectResult(await directLane.promise);")
        )
        let bridgeStart = try XCTUnwrap(
            runBody.range(of: "var fallbackPromise = transcriptViaMainWorld();")
        )
        XCTAssertLessThan(
            directJoin.lowerBound,
            bridgeStart.lowerBound,
            "the correlated direct request must settle before the uncorrelated bridge starts"
        )

        let directFunctionStart = try XCTUnwrap(
            source.range(of: "async function directTranscriptViaInitialData(")
        )
        let directFunctionEnd = try XCTUnwrap(
            source.range(
                of: "function transcriptViaMainWorld()",
                range: directFunctionStart.upperBound..<source.endIndex
            )
        )
        let directBody = source[
            directFunctionStart.lowerBound..<directFunctionEnd.lowerBound
        ]
        XCTAssertTrue(directBody.contains("window.fetch(apiURL.href"))
        XCTAssertTrue(directBody.contains(
            "waitForInitialDataTranscriptEndpoint(6000)"
        ))
        XCTAssertTrue(source.contains(
            "Promise.resolve(window.bgevmc.cr()).catch"
        ))
        XCTAssertFalse(
            directBody.contains("fetchViaMainWorld"),
            "the direct lane must not share the uncorrelated vendored fetch channel"
        )

        let timedtextStart = try XCTUnwrap(runBody.range(of: "timedtextFormats:"))
        let timedtextEnd = try XCTUnwrap(
            runBody.range(
                of: "if (cues.length === 0 && officialCaption",
                range: timedtextStart.upperBound..<runBody.endIndex
            )
        )
        let timedtextBody = runBody[timedtextStart.lowerBound..<timedtextEnd.lowerBound]
        XCTAssertFalse(timedtextBody.contains("Promise.all"))
        XCTAssertEqual(
            String(timedtextBody)
                .components(separatedBy: "await fetchViaMainWorld(").count - 1,
            1,
            "vendored timedtext candidates must remain one-at-a-time"
        )
    }

    func testFastNoCaptionGateRequiresCompletedExactVideoEvidence() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        let functionStart = try XCTUnwrap(
            source.range(of: "function highConfidenceNoCaptionEvidence(")
        )
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "async function waitForOfficialCaptionCandidate(",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let body = source[functionStart.lowerBound..<functionEnd.lowerBound]

        let requiredEvidence = [
            "initialDetails.videoId",
            "initialStatus.status",
            "!== 'OK'",
            "initialMetadata.isLive",
            "classification !== 'playable'",
            "sawBotVerificationChallenge",
            "sawSignInRequirement",
            "navigator.onLine === false",
            "document.readyState !== 'interactive'",
            "document.readyState !== 'complete'",
            "castReaderInitialDataVideoID(initialData) !== expected",
            "!Array.isArray(initialData.engagementPanels)",
            "castReaderInitialDataHasTranscriptEndpoint(initialData, expected)",
            "castReaderCaptionTracks(initial).length > 0",
            "playerState.tracks.length > 0",
            "bridgeResult.tracks.length > 0",
            "latestOfficialTimedtextURL",
            "officialTimedtextCaptureQueue.length > 0",
            "nativeCaptionTracks().length > 0",
            "officialState.ready && officialState.tracks.length === 0",
        ]
        for evidence in requiredEvidence {
            XCTAssertTrue(body.contains(evidence), "missing fast-fail evidence: \(evidence)")
        }
    }

    func testLateCaptionEvidenceRevokesFastNoCaptionDecision() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        let functionStart = try XCTUnwrap(
            source.range(of: "async function waitForMatchingPlayer()")
        )
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "function normalizedLanguage",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let body = source[functionStart.lowerBound..<functionEnd.lowerBound]

        XCTAssertTrue(body.contains("emptyEvidenceSince = null;"))
        XCTAssertTrue(body.contains("emptyEvidenceSamples = 0;"))
        XCTAssertTrue(body.contains("var finalBridgeResult = await fetchTracksOnce();"))
        XCTAssertTrue(body.contains("var finalSnapshot = snapshot(finalBridgeResult);"))
        XCTAssertTrue(
            body.contains("finalBridgeResult"),
            "the gate must re-read every positive source immediately before publishing no_captions"
        )

        let finalSnapshot = try XCTUnwrap(
            body.range(of: "var finalSnapshot = snapshot(finalBridgeResult);")
        )
        let finalCheck = try XCTUnwrap(
            body.range(
                of: "highConfidenceNoCaptionEvidence(",
                range: finalSnapshot.upperBound..<body.endIndex
            )
        )
        let markConclusive = try XCTUnwrap(
            body.range(of: "finalSnapshot.conclusivelyNoCaptions = true;")
        )
        XCTAssertLessThan(finalCheck.lowerBound, markConclusive.lowerBound)
    }

    func testExtractionExhaustionDoesNotGuessThatCaptionsAreUnavailable() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        let exhaustionStart = try XCTUnwrap(
            source.range(of: "} else if (!envelope.ok) {")
        )
        let exhaustionEnd = try XCTUnwrap(
            source.range(
                of: "postOnce(envelope);",
                range: exhaustionStart.upperBound..<source.endIndex
            )
        )
        let exhaustion = source[exhaustionStart.lowerBound..<exhaustionEnd.lowerBound]

        XCTAssertFalse(exhaustion.contains("player.tracks.length === 0"))
        XCTAssertFalse(exhaustion.contains("'captions_unavailable'"))
        XCTAssertTrue(exhaustion.contains("'transcript_access_failed'"))
        XCTAssertTrue(
            source.contains("if (player.conclusivelyNoCaptions)"),
            "only the strict exact-video evidence gate may publish no captions"
        )
    }

    func testOfficialCaptionCandidateWaitsForDecorationInsteadOfUsingFixedGracePeriod() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        let start = try XCTUnwrap(
            source.range(of: "async function waitForOfficialCaptionCandidate(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "function activateOfficialCaptionTrack",
                range: start.upperBound..<source.endIndex
            )
        )
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(
            body.contains("officialTimedtextURLForCandidate"),
            "the official track must be checked for YouTube's decorated timedtext URL"
        )
        XCTAssertTrue(
            body.contains("if (latest.url) return latest;"),
            "a proof-decorated official URL may complete the wait immediately"
        )
        XCTAssertFalse(
            body.contains("Date.now() - matchedAt >= 750"),
            "a matching defensive clone is not proof that subtitle PO decoration has settled"
        )
        XCTAssertTrue(
            body.contains("Date.now() >= deadline"),
            "an undecorated defensive clone must keep polling through the bounded deadline"
        )
    }

    func testOfficialCaptionFallbackDoesNotDiscardAnAlreadyCapturedTimedtextResponse() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        let start = try XCTUnwrap(
            source.range(of: "if (cues.length === 0 && officialCaption &&")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "if (cues.length === 0 && directLane.promise)",
                range: start.upperBound..<source.endIndex
            )
        )
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertFalse(
            body.contains("clearOfficialTimedtextCaptures();"),
            "the player may finish its valid decorated request before activation; clearing here loses the only readable response"
        )
        XCTAssertTrue(
            body.contains("waitForOfficialTimedtextCapture"),
            "the fallback must consume either an existing capture or the response triggered by activation"
        )
    }

    func testOfficialTimedtextRecoveryPreservesValidatedURLAndRetriesFormats() {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )

        XCTAssertTrue(source.contains("latestOfficialTimedtextURL = trustedURL"))
        XCTAssertTrue(source.contains("officialTimedtextResourceURL"))
        XCTAssertTrue(source.contains("officialTimedtextURLForCandidate"))
        XCTAssertTrue(source.contains("requestedLanguage !== urlLanguage"))
        XCTAssertTrue(source.contains("url.searchParams.get('tlang')"))
        XCTAssertTrue(source.contains("url.searchParams.delete('tlang')"))
        XCTAssertTrue(source.contains("mayRemoveMismatchedTranslation === false"))
        XCTAssertTrue(source.contains(
            "official timedtext capture rejected translated or mismatched URL"
        ))
        XCTAssertTrue(source.contains("cuesMatchCandidateLanguage"))
        XCTAssertTrue(source.contains("'direct transcript'"))
        XCTAssertTrue(source.contains("cue language mismatched candidate"))
        XCTAssertTrue(source.contains("official decorated URL recovered source="))
        XCTAssertTrue(source.contains("['json3', 'srv3', 'base_url']"))
        XCTAssertTrue(source.contains("URLWithoutFormat(rawURL)"))
        XCTAssertFalse(
            source.contains("note('official decorated URL recovered source=' +\n                    officialCaption.url"),
            "diagnostics must never expose the decorated URL or its PO token"
        )
    }

    func testOfficialCaptionActivationTurnsSubtitlesOnAndReadsBackState() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        let start = try XCTUnwrap(
            source.range(of: "function activateOfficialCaptionTrack")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "function fetchTracksOnce",
                range: start.upperBound..<source.endIndex
            )
        )
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(
            body.contains("toggleSubtitlesOn"),
            "setOption can be a no-op for an already selected defensive clone; the public player API must explicitly turn captions on"
        )
        XCTAssertTrue(
            body.contains("isSubtitlesOn"),
            "activation must be verified instead of returning true merely because setOption did not throw"
        )
        XCTAssertTrue(
            body.contains("subtitlesAreOn !== true"),
            "toggleSubtitlesOn is a toggle, so it must only run when captions are currently off"
        )
        XCTAssertTrue(
            body.contains("result.beforeSelected && result.beforeOn === true"),
            "reload must not abort a request just started by selecting or enabling captions"
        )
        XCTAssertTrue(
            body.contains("getOption('captions', 'track')"),
            "activation readback must confirm the expected official track is selected"
        )
        XCTAssertTrue(
            body.contains("activateOfficialNativeCaptionTrack"),
            "iOS native text-track mode must have an activation path when setOption is a no-op"
        )
    }

    func testOfficialCaptionProofDoesNotEndDecorationPollingEarly() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        let start = try XCTUnwrap(source.range(of: "var proof = capturedSubtitleProof"))
        let end = try XCTUnwrap(
            source.range(of: "break;", range: start.upperBound..<source.endIndex)
        )
        let proofBranch = source[start.lowerBound..<end.upperBound]

        XCTAssertTrue(proofBranch.contains("latest.proofReady = true;"))
        XCTAssertFalse(
            proofBranch.contains("return latest;"),
            "a player-request token is not evidence that the official track URL is decorated"
        )
    }

    func testNativeCaptionFallbackRejectsUnrelatedTracksAndWaitsForCompleteCues() throws {
        let source = YouTubeWebScripts.extractionAdapter(
            expectedVideoID: "wpb-DrbhEiY"
        )
        XCTAssertTrue(
            source.contains("normalizedKind !== 'captions' && normalizedKind !== 'subtitles'"),
            "metadata and chapter TextTracks must never become transcript input"
        )
        XCTAssertTrue(
            source.contains("castReaderTrustedDecoratedCaptionURL"),
            "a DOM track URL must retain exact-video and proof-token validation"
        )
        XCTAssertTrue(
            source.contains("latestNativeSnapshot.ready") &&
                source.contains("Date.now() - stableNativeSince >= 200"),
            "incrementally populated TextTrack cues must settle before acceptance"
        )
        XCTAssertTrue(
            source.contains("nativeCue.getCueAsHTML"),
            "native WebVTT markup must be reduced to visible cue text"
        )
    }

    @MainActor
    func testAdapterRunsTranscriptFallbackWhenRuntimeMasksInitialBotChallenge() throws {
        let result = try runAdapterFixture(
            initialReason: "Sign in to confirm you are not a bot",
            transcriptCues: [
                ["text": "第一句字幕", "startMs": 0, "durationMs": 1_200],
                ["text": "第二句字幕", "startMs": 1_200, "durationMs": 1_400],
            ],
            transcriptLog: ["fixture transcript bridge completed"]
        )
        let envelope = result.envelope
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        XCTAssertEqual(envelope["videoId"] as? String, "wpb-DrbhEiY")
        XCTAssertEqual(envelope["transcriptSource"] as? String, "transcript_bridge")
        XCTAssertEqual((envelope["cues"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(result.transcriptRequestCount, 1)
        XCTAssertEqual(
            (envelope["playability"] as? [String: Any])?["classification"] as? String,
            "playable"
        )
        let diagnostics = envelope["diagnostics"] as? [String]
        XCTAssertTrue(
            diagnostics?.contains(where: {
                $0.contains("public transcript succeeded despite generic login challenge")
            }) == true
        )
    }

    @MainActor
    func testBotFallbackFailureRemainsRestrictedInsteadOfTimeout() throws {
        let result = try runAdapterFixture(
            initialReason: "Sign in to confirm you are not a bot",
            transcriptCues: [],
            transcriptLog: ["transcript_timeout"]
        )
        XCTAssertEqual(result.transcriptRequestCount, 1)
        XCTAssertEqual(result.envelope["ok"] as? Bool, false)
        XCTAssertEqual(
            (result.envelope["error"] as? [String: Any])?["code"] as? String,
            "youtube_verification_required"
        )
        XCTAssertEqual(
            (result.envelope["playability"] as? [String: Any])?["status"] as? String,
            "LOGIN_REQUIRED"
        )
        XCTAssertEqual(
            (result.envelope["playability"] as? [String: Any])?["classification"] as? String,
            "sign_in_required"
        )
    }

    @MainActor
    func testGenericLoginWallStaysRestrictedWithoutOpeningTranscriptFallback() throws {
        let result = try runAdapterFixture(
            initialReason: "Please sign in to view this video",
            transcriptCues: [["text": "must not be used", "startMs": 0]],
            transcriptLog: []
        )
        XCTAssertEqual(result.transcriptRequestCount, 0)
        XCTAssertEqual(result.envelope["ok"] as? Bool, false)
        XCTAssertEqual(
            (result.envelope["error"] as? [String: Any])?["code"] as? String,
            "restricted_video"
        )
        XCTAssertEqual(
            (result.envelope["playability"] as? [String: Any])?["classification"] as? String,
            "sign_in_required"
        )
    }

    @MainActor
    func testChallengeHTMLWithoutPlayerIsRestrictedInsteadOfPlayerTimeout() throws {
        let result = try runAdapterFixture(
            initialReason: nil,
            hasRuntimeResponse: false,
            hasInitialDataEndpoint: false,
            documentText: "Our systems detected unusual traffic. Confirm you are not a robot.",
            transcriptCues: [],
            transcriptLog: []
        )
        XCTAssertEqual(result.transcriptRequestCount, 0)
        XCTAssertEqual(
            (result.envelope["error"] as? [String: Any])?["code"] as? String,
            "youtube_verification_required"
        )
        XCTAssertNotEqual(
            (result.envelope["error"] as? [String: Any])?["code"] as? String,
            "player_timeout"
        )
    }

    @MainActor
    func testAdapterWatchdogRetainsDocumentBotChallengeInsteadOfTimingOut() throws {
        let result = try runAdapterFixture(
            initialReason: nil,
            hasRuntimeResponse: false,
            hasInitialDataEndpoint: false,
            documentText: "Our systems detected unusual traffic. Confirm you are not a robot.",
            transcriptCues: [],
            transcriptLog: [],
            fireAdapterWatchdogBeforeMainRun: true
        )
        XCTAssertEqual(result.envelope["ok"] as? Bool, false)
        XCTAssertEqual(
            (result.envelope["error"] as? [String: Any])?["code"] as? String,
            "youtube_verification_required"
        )
        XCTAssertEqual(
            (result.envelope["playability"] as? [String: Any])?["classification"] as? String,
            "sign_in_required"
        )
        XCTAssertNotEqual(
            (result.envelope["error"] as? [String: Any])?["code"] as? String,
            "adapter_timeout"
        )

        let ordinaryRobotPage = try runAdapterFixture(
            initialReason: nil,
            hasRuntimeResponse: true,
            hasInitialDataEndpoint: false,
            documentText: "A robot documentary about warehouse automation.",
            transcriptCues: [],
            transcriptLog: [],
            fireAdapterWatchdogBeforeMainRun: true
        )
        XCTAssertEqual(
            (ordinaryRobotPage.envelope["error"] as? [String: Any])?["code"] as? String,
            "unavailable_video"
        )
        XCTAssertNotEqual(
            (ordinaryRobotPage.envelope["error"] as? [String: Any])?["code"] as? String,
            "restricted_video"
        )
    }

    func testExtractionAdapterIsSyntacticallyValidJavaScript() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            #"""
            var window = this;
            window.top = window;
            window.self = window;
            var navigator = { language: 'en' };
            var document = {
              body: { dataset: {} },
              documentElement: { lang: 'en' },
              addEventListener: function () {},
              removeEventListener: function () {},
              dispatchEvent: function () {},
              querySelector: function () { return null; },
              querySelectorAll: function () { return []; }
            };
            function setTimeout() { return 1; }
            function clearTimeout() {}
            """#
        )
        XCTAssertNil(context.exception)

        context.evaluateScript(
            YouTubeWebScripts.extractionAdapter(
                expectedVideoID: "wpb-DrbhEiY",
                requestToken: "fixture-token",
                preferredLanguage: "zh-CN",
                adapterBudgetMilliseconds: 34_500
            )
        )
        XCTAssertNil(
            context.exception,
            context.exception?.toString() ?? "adapter failed to parse"
        )
    }

    private struct AdapterFixtureResult {
        let envelope: [String: Any]
        let transcriptRequestCount: Int
    }

    @MainActor
    private func runAdapterFixture(
        initialReason: String?,
        hasRuntimeResponse: Bool = true,
        hasInitialDataEndpoint: Bool = true,
        documentText: String = "",
        transcriptCues: [[String: Any]],
        transcriptLog: [String],
        fireAdapterWatchdogBeforeMainRun: Bool = false
    ) throws -> AdapterFixtureResult {
        let initialResponse: Any
        if let initialReason {
            initialResponse = [
                "playabilityStatus": [
                    "status": "LOGIN_REQUIRED",
                    "reason": initialReason,
                ],
            ]
        } else {
            initialResponse = NSNull()
        }

        let runtimeResponse: Any = hasRuntimeResponse ? [
            "videoDetails": ["videoId": "wpb-DrbhEiY"],
            "playabilityStatus": [
                "status": "UNPLAYABLE",
                "reason": "Video unavailable",
            ],
        ] : NSNull()

        let initialData: Any = hasInitialDataEndpoint ? [
            "currentVideoEndpoint": [
                "watchEndpoint": ["videoId": "wpb-DrbhEiY"],
            ],
            "engagementPanels": [[
                "engagementPanelSectionListRenderer": [
                    "targetId": "engagement-panel-searchable-transcript",
                    "content": [
                        "continuationItemRenderer": [
                            "continuationEndpoint": [
                                "getTranscriptEndpoint": [
                                    "params": "fixture-transcript-token",
                                ],
                            ],
                        ],
                    ],
                ],
            ]],
        ] : NSNull()

        let transcriptPayload: [String: Any] = [
            "cues": transcriptCues,
            "log": transcriptLog,
        ]
        let initialResponseLiteral = try javaScriptJSONLiteral(initialResponse)
        let runtimeResponseLiteral = try javaScriptJSONLiteral(runtimeResponse)
        let initialDataLiteral = try javaScriptJSONLiteral(initialData)
        let documentTextLiteral = try javaScriptJSONLiteral(documentText)
        let transcriptPayloadLiteral = try javaScriptJSONLiteral(transcriptPayload)

        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            #"""
            var window = this;
            window.top = window;
            window.self = window;
            var navigator = { language: 'zh-CN' };
            var location = {
              href: 'https://www.youtube.com/watch?v=wpb-DrbhEiY',
              hostname: 'www.youtube.com',
              pathname: '/watch'
            };
            var __listeners = {};
            var __timers = {};
            var __nextTimer = 1;
            var __transcriptRequestCount = 0;
            function setTimeout(callback, delay) {
              var id = __nextTimer++;
              __timers[id] = { callback: callback, delay: Number(delay || 0) };
              return id;
            }
            function clearTimeout(id) { delete __timers[id]; }
            function __runShortTimers() {
              var ready = Object.keys(__timers).filter(function (id) {
                return __timers[id] && __timers[id].delay <= 50;
              });
              ready.forEach(function (id) {
                var timer = __timers[id];
                delete __timers[id];
                timer.callback();
              });
              return ready.length;
            }
            function Event(type) { this.type = type; }
            var runtimeResponse = \#(runtimeResponseLiteral);
            var moviePlayer = {
              getPlayerResponse: function () { return runtimeResponse; }
            };
            var document = {
              title: 'YouTube',
              body: {
                dataset: {},
                innerText: \#(documentTextLiteral),
                textContent: \#(documentTextLiteral)
              },
              documentElement: { lang: 'zh-CN' },
              addEventListener: function (name, callback) {
                (__listeners[name] || (__listeners[name] = [])).push(callback);
              },
              removeEventListener: function (name, callback) {
                __listeners[name] = (__listeners[name] || []).filter(function (item) {
                  return item !== callback;
                });
              },
              dispatchEvent: function (event) {
                (__listeners[event.type] || []).slice().forEach(function (callback) {
                  callback(event);
                });
                return true;
              },
              querySelector: function (selector) {
                return selector === '#movie_player' && runtimeResponse ? moviePlayer : null;
              },
              querySelectorAll: function () { return []; }
            };
            window.ytInitialPlayerResponse = \#(initialResponseLiteral);
            window.ytInitialData = \#(initialDataLiteral);
            window.webkit = {
              messageHandlers: {
                crYt: {
                  postMessage: function (payload) { window.__postedEnvelope = payload; }
                }
              }
            };
            document.addEventListener('__cr_yt_req__', function () {
              document.body.dataset.crYtTracks = '[]';
              document.body.dataset.crYtTracksVideoId = '';
              document.dispatchEvent(new Event('__cr_yt_res__'));
            });
            document.addEventListener('__cr_yt_transcript_req__', function () {
              __transcriptRequestCount += 1;
              document.body.dataset.crYtTranscript = JSON.stringify(
                \#(transcriptPayloadLiteral)
              );
              document.dispatchEvent(new Event('__cr_yt_transcript_res__'));
            });
            """#
        )
        XCTAssertNil(
            context.exception,
            context.exception?.toString() ?? "fixture setup failed"
        )

        context.evaluateScript(
            YouTubeWebScripts.extractionAdapter(
                expectedVideoID: "wpb-DrbhEiY",
                requestToken: "fixture-token",
                preferredLanguage: "zh-CN",
                adapterBudgetMilliseconds: 34_500
            )
        )
        XCTAssertNil(
            context.exception,
            context.exception?.toString() ?? "adapter failed to start"
        )

        if fireAdapterWatchdogBeforeMainRun {
            context.evaluateScript(
                #"""
                (function () {
                  var watchdogID = Object.keys(__timers).sort(function (lhs, rhs) {
                    return __timers[rhs].delay - __timers[lhs].delay;
                  })[0];
                  var timer = __timers[watchdogID];
                  window.__firedAdapterWatchdogDelay = timer.delay;
                  window.__transcriptCountBeforeWatchdog = __transcriptRequestCount;
                  delete __timers[watchdogID];
                  timer.callback();
                })();
                """#
            )
            XCTAssertNil(
                context.exception,
                context.exception?.toString() ?? "adapter watchdog fixture failed"
            )
            XCTAssertEqual(
                context.objectForKeyedSubscript("__firedAdapterWatchdogDelay")?.toInt32(),
                34_500
            )
            XCTAssertEqual(
                context.objectForKeyedSubscript("__transcriptCountBeforeWatchdog")?.toInt32(),
                0
            )
        }

        for _ in 0..<20
        where context.objectForKeyedSubscript("__postedEnvelope")?.isUndefined != false {
            context.evaluateScript("__runShortTimers();")
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        let payload = try XCTUnwrap(
            context.objectForKeyedSubscript("__postedEnvelope")?.toString(),
            "the adapter never posted its terminal envelope"
        )
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let transcriptRequestCount = Int(
            context.objectForKeyedSubscript("__transcriptRequestCount")?.toInt32() ?? 0
        )
        return AdapterFixtureResult(
            envelope: envelope,
            transcriptRequestCount: transcriptRequestCount
        )
    }

    private func javaScriptJSONLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func makeURLCapableJavaScriptContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            #"""
            var location = {
              href: 'https://www.youtube.com/watch?v=wpb-DrbhEiY',
              origin: 'https://www.youtube.com'
            };
            function URL(rawURL, baseURL) {
              var raw = String(rawURL || '');
              if (raw.charAt(0) === '/') {
                raw = String(baseURL || location.origin).replace(/\/$/, '') + raw;
              }
              var match = raw.match(/^(https?):\/\/([^\/?#]+)([^?#]*)(?:\?([^#]*))?(?:#.*)?$/);
              if (!match) throw new Error('Invalid URL');
              this.protocol = match[1] + ':';
              this.host = match[2];
              this.hostname = match[2].split(':')[0];
              this.origin = this.protocol + '//' + this.host;
              this.pathname = match[3] || '/';
              this.href = raw;
              var values = {};
              String(match[4] || '').split('&').forEach(function (pair) {
                if (!pair) return;
                var separator = pair.indexOf('=');
                var key = separator >= 0 ? pair.slice(0, separator) : pair;
                var value = separator >= 0 ? pair.slice(separator + 1) : '';
                try {
                  key = decodeURIComponent(key.replace(/\+/g, ' '));
                  value = decodeURIComponent(value.replace(/\+/g, ' '));
                } catch (error) {}
                (values[key] || (values[key] = [])).push(value);
              });
              this.searchParams = {
                get: function (key) {
                  var entries = values[String(key)] || [];
                  return entries.length > 0 ? entries[0] : null;
                }
              };
              this.toString = function () { return this.href; };
            }
            """#
        )
        try XCTUnwrap(
            context.exception == nil ? true : nil,
            context.exception?.toString() ?? "URL fixture failed to parse"
        )
        return context
    }
}
