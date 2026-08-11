//
//  YouTubeWebScripts.swift
//  CastReader
//
//  Page-world scripts used by the native YouTube transcript extractor.
//  The vendored bridge is intentionally kept byte-for-byte identical to its
//  upstream build; native-specific adaptation lives in this separate script.
//

import Foundation

enum YouTubeWebScripts {
    static let sourceRepository = "readout-desktop"
    static let sourcePath = "src/entrypoints/youtube-bridge.content.ts"
    static let sourceCommit = "92d22744839bfb34c6c4f5d7152192729074919f"
    static let vendoredBridgeSHA256 =
        "877af9a72117d6c2afd0e303f74fe4bb03f5172e7c90ad9ac3788aeb77add02c"

    static let messageHandlerName = "crYt"

    /// `isLiveContent` and a broadcast start time remain on completed live
    /// archives. Only active/upcoming broadcasts should be rejected; an
    /// archive with an end timestamp is an ordinary captioned VOD.
    static let activeLiveBroadcastFunction = #"""
    function castReaderIsActiveLiveBroadcast(details, status, liveDetails) {
      details = details || {};
      status = status || {};
      liveDetails = liveDetails || {};
      var normalizedStatus = String(status.status || '').toUpperCase();
      var hasLiveProvenance = Boolean(details.isLiveContent || liveDetails.startTimestamp);
      return Boolean(details.isLive || liveDetails.isLiveNow ||
        normalizedStatus === 'LIVE_STREAM_OFFLINE' ||
        (hasLiveProvenance && !liveDetails.endTimestamp));
    }
    """#

    static let playabilityClassificationFunction = #"""
    function playabilityClassification(status, reason, isLive) {
      var normalizedStatus = String(status || '').toUpperCase();
      var detail = (String(status || '') + ' ' + String(reason || '')).toLowerCase();
      if (isLive && (detail.indexOf('offline') >= 0 || detail.indexOf('upcoming') >= 0)) {
        return 'live_offline';
      }
      if (normalizedStatus === 'OK') return 'playable';
      if (detail.indexOf('age') >= 0) return 'age_restricted';
      // Private-video reasons commonly also say “Please sign in”. The more
      // specific product taxonomy must win over the generic login wall.
      if (detail.indexOf('private') >= 0) return 'private';
      if (detail.indexOf('sign in') >= 0 || detail.indexOf('login') >= 0 ||
          normalizedStatus === 'LOGIN_REQUIRED') return 'sign_in_required';
      if (detail.indexOf('member') >= 0) return 'membership_required';
      if (detail.indexOf('country') >= 0 || detail.indexOf('region') >= 0) {
        return 'geo_restricted';
      }
      if (detail.indexOf('removed') >= 0 || detail.indexOf('deleted') >= 0) return 'removed';
      if (normalizedStatus === 'UNPLAYABLE' || normalizedStatus === 'ERROR') return 'unavailable';
      return 'unknown';
    }
    """#

    static let botVerificationChallengeFunction = #"""
    function castReaderIsBotVerificationText(value) {
      var reason = String(value || '').toLowerCase();
      return /not\s+(?:a\s+)?(?:bot|robot)|confirm[^.]{0,80}(?:bot|robot)|(?:bot|robot)[^.]{0,80}confirm|unusual\s+traffic[^.]{0,160}(?:bot|robot)|(?:captcha|recaptcha)|(?:\u4e0d\u662f|\u4e26\u975e)[^\u3002]{0,40}(?:\u673a\u5668\u4eba|\u6a5f\u5668\u4eba|\u6a5f\u68b0\u4eba)|(?:\u786e\u8ba4|\u78ba\u8a8d|\u9a8c\u8bc1|\u9a57\u8b49)[^\u3002]{0,80}(?:\u673a\u5668\u4eba|\u6a5f\u5668\u4eba|\u6a5f\u68b0\u4eba)/.test(reason);
    }

    function castReaderIsBotVerificationChallenge(playability) {
      playability = playability || {};
      var status = String(playability.status || '').toUpperCase();
      if (status !== 'LOGIN_REQUIRED') return false;
      var reason = String(playability.reason || '').toLowerCase();
      return castReaderIsBotVerificationText(reason) ||
        /\b(?:bot|robot)\b|\u673a\u5668\u4eba|\u6a5f\u5668\u4eba|\u6a5f\u68b0\u4eba/.test(reason);
    }

    function castReaderPlayerResponseHasBotVerificationChallenge(response) {
      var status = response && response.playabilityStatus || {};
      var reason = status.reason;
      if (!reason && Array.isArray(status.messages)) reason = status.messages.join(' ');
      return castReaderIsBotVerificationChallenge({
        status: status.status,
        reason: reason
      });
    }

    function castReaderDocumentHasBotVerificationChallenge(root) {
      try {
        root = root || document;
        var body = root && root.body;
        var text = String(root && root.title || '') + ' ' +
          String(body && (body.innerText || body.textContent) || '');
        return castReaderIsBotVerificationText(text.slice(0, 50000));
      } catch (error) {
        return false;
      }
    }

    function castReaderHasBotVerificationChallengeEvidence(
      initialResponse,
      selectedResponse,
      root
    ) {
      return castReaderPlayerResponseHasBotVerificationChallenge(initialResponse) ||
        castReaderPlayerResponseHasBotVerificationChallenge(selectedResponse) ||
        castReaderDocumentHasBotVerificationChallenge(root);
    }
    """#

    /// YouTube can expose two player responses at once. The initial document
    /// response still contains public caption tracks while the live player can
    /// become `UNPLAYABLE` after CastReader deliberately blocks media loads.
    /// Rank both responses instead of allowing that media-block side effect to
    /// turn a captioned video into a false unavailable result.
    static let playerResponseSelectionFunction = #"""
    function castReaderCaptionTracks(response) {
      var tracks = response && response.captions &&
        response.captions.playerCaptionsTracklistRenderer &&
        response.captions.playerCaptionsTracklistRenderer.captionTracks;
      return Array.isArray(tracks) ? tracks : [];
    }

    function castReaderResolveCaptionTracks(response, bridgeTracks) {
      var responseTracks = castReaderCaptionTracks(response);
      if (responseTracks.length > 0) return responseTracks;
      return Array.isArray(bridgeTracks) ? bridgeTracks : [];
    }

    function castReaderPlayerResponseScore(response, expectedVideoID) {
      if (!response || typeof response !== 'object') return -1000000;
      var details = response.videoDetails || {};
      var actualVideoID = String(details.videoId || '');
      var expected = String(expectedVideoID || '');
      var score = 0;
      if (expected) {
        if (actualVideoID === expected) score += 1000;
        else if (actualVideoID) score -= 1000;
      }
      var status = String(response.playabilityStatus &&
        response.playabilityStatus.status || '').toUpperCase();
      if (status === 'OK') score += 100;
      if (castReaderCaptionTracks(response).length > 0) score += 50;
      if (actualVideoID) score += 10;
      return score;
    }

    function castReaderSelectPlayerResponse(initialResponse, runtimeResponse, expectedVideoID) {
      var candidates = [initialResponse, runtimeResponse];
      var selected = null;
      var selectedScore = -1000001;
      candidates.forEach(function (candidate) {
        var score = castReaderPlayerResponseScore(candidate, expectedVideoID);
        if (score > selectedScore) {
          selected = candidate;
          selectedScore = score;
        }
      });
      return selected;
    }
    """#

    /// YouTube's WEB client binds subtitle delivery to a short-lived,
    /// video-scoped proof-of-origin token. The page generates that token for
    /// its own `/youtubei/v1/player` request. CastReader only observes that
    /// same-page request, verifies the requested video ID, and reuses the
    /// ephemeral proof for the matching caption URL; it is never persisted or
    /// sent to native code.
    static let subtitleProofTokenFunction = #"""
    function castReaderSubtitleProofFromPlayerBody(body, expectedVideoID) {
      var payload = body;
      if (typeof payload === 'string') {
        if (!payload || payload.length > 2 * 1024 * 1024) return null;
        try { payload = JSON.parse(payload); } catch (error) { return null; }
      }
      if (!payload || typeof payload !== 'object') return null;

      var videoID = String(payload.videoId || '');
      var expected = String(expectedVideoID || '');
      if (!videoID || (expected && videoID !== expected)) return null;

      var dimensions = payload.serviceIntegrityDimensions || {};
      var token = String(dimensions.poToken || '').trim();
      if (token.length < 16 || token.length > 16384 || /\s/.test(token)) return null;

      var client = payload.context && payload.context.client || {};
      var clientName = String(client.clientName || 'WEB').trim().toUpperCase();
      if (!/^[A-Z0-9_]{2,64}$/.test(clientName)) clientName = 'WEB';
      return { token: token, videoId: videoID, clientName: clientName };
    }

    function castReaderCaptionTrackRequiresProof(rawURL) {
      try {
        var url = new URL(String(rawURL || ''), location.href);
        return url.searchParams.getAll('exp').some(function (value) {
          return String(value || '').split(',').some(function (experiment) {
            var normalized = experiment.trim().toLowerCase();
            return normalized === 'xpe' || normalized === 'xpv';
          });
        });
      } catch (error) {
        return false;
      }
    }

    function castReaderCaptionURLWithProof(rawURL, format, proof) {
      var formatted = format === 'base_url' ? URLWithoutFormat(rawURL) :
        URLWithFormat(rawURL, format);
      if (!proof || !proof.token) return formatted;
      try {
        var url = new URL(formatted, location.href);
        if (url.protocol !== 'https:') return formatted;
        url.searchParams.set('pot', proof.token);
        url.searchParams.set('potc', '1');
        url.searchParams.set('c', proof.clientName ||
          url.searchParams.get('c') || 'WEB');
        return url.href;
      } catch (error) {
        return formatted;
      }
    }
    """#

    /// The public player API returns the same caption-track objects that its
    /// captions module decorates after YouTube's short-lived subtitles proof
    /// has resolved. Keep matching and URL validation separate so neither a
    /// stale SPA player nor an unrelated page request can become transcript
    /// input.
    static let officialCaptionTrackFunction = #"""
    function castReaderOfficialCaptionTrackMatch(rawTrack, officialTracks) {
      if (!rawTrack || !Array.isArray(officialTracks)) return null;

      function normalizedLanguage(value) {
        return String(value || '').trim().toLowerCase().replace(/_/g, '-');
      }
      function normalizedKind(track) {
        return String(track && track.kind || '').trim().toLowerCase() === 'asr' ?
          'asr' : 'manual';
      }
      function vssID(track) {
        return String(track && (track.vssId || track.vss_id) || '').trim();
      }

      var rawLanguage = normalizedLanguage(rawTrack.languageCode);
      if (!rawLanguage) return null;
      var rawKind = normalizedKind(rawTrack);
      var matching = officialTracks.filter(function (track) {
        return track && normalizedLanguage(track.languageCode) === rawLanguage &&
          normalizedKind(track) === rawKind;
      });
      if (matching.length === 0) return null;

      var rawVSSID = vssID(rawTrack);
      if (rawVSSID) {
        var exact = matching.find(function (track) {
          return vssID(track) === rawVSSID;
        });
        if (exact) return exact;
      }
      return matching.length === 1 ? matching[0] : null;
    }

    function castReaderTrustedDecoratedCaptionURL(rawValue, expectedVideoID) {
      var rawURL = typeof rawValue === 'string' ? rawValue :
        rawValue && (rawValue.url || rawValue.baseUrl);
      var expected = String(expectedVideoID || '').trim();
      if (!rawURL || !expected) return null;
      try {
        var url = new URL(String(rawURL), location.href);
        if (url.protocol !== 'https:' || url.origin !== location.origin ||
            url.pathname !== '/api/timedtext' ||
            url.searchParams.get('v') !== expected) return null;
        var token = String(url.searchParams.get('pot') || '').trim();
        if (!token || token.length > 16384 || /\s/.test(token) ||
            url.searchParams.get('potc') !== '1') return null;
        return url.href;
      } catch (error) {
        return null;
      }
    }
    """#

    /// The player response may intentionally omit `videoDetails` during a
    /// generic anti-bot login challenge even though the canonical watch page's
    /// initial data is already scoped to the expected video and exposes its
    /// transcript continuation. These helpers provide independently testable
    /// matching evidence without trusting arbitrary page text.
    static let initialDataTranscriptFunction = #"""
    function castReaderInitialDataVideoID(initialData) {
      try {
        var endpoint = initialData && initialData.currentVideoEndpoint;
        return endpoint && endpoint.watchEndpoint &&
          endpoint.watchEndpoint.videoId || null;
      } catch (error) {
        return null;
      }
    }

    function castReaderInitialDataTranscriptEndpoint(initialData, expectedVideoID) {
      var initialVideoID = castReaderInitialDataVideoID(initialData);
      var expected = String(expectedVideoID || '');
      if (!initialVideoID || (expected && initialVideoID !== expected)) return null;

      function endpointFromContinuation(value) {
        var continuation = value && value.continuationEndpoint;
        var endpoint = continuation && continuation.getTranscriptEndpoint;
        var params = String(endpoint && endpoint.params || '').trim();
        if (!params) return null;
        var metadata = continuation.commandMetadata &&
          continuation.commandMetadata.webCommandMetadata || {};
        return {
          params: params,
          clickTrackingParams: String(continuation.clickTrackingParams || '').trim() || null,
          apiUrl: String(metadata.apiUrl || '/youtubei/v1/get_transcript')
        };
      }

      function visitContinuationItems(value, depth) {
        if (!value || typeof value !== 'object' || depth > 24) return null;
        if (value.continuationItemRenderer) {
          var endpoint = endpointFromContinuation(value.continuationItemRenderer);
          if (endpoint) return endpoint;
        }
        var keys = Object.keys(value);
        for (var index = 0; index < keys.length; index += 1) {
          var key = keys[index];
          var child = value[key];
          if (Array.isArray(child)) {
            for (var childIndex = 0; childIndex < child.length; childIndex += 1) {
              var nested = visitContinuationItems(child[childIndex], depth + 1);
              if (nested) return nested;
            }
          } else {
            var nestedValue = visitContinuationItems(child, depth + 1);
            if (nestedValue) return nestedValue;
          }
        }
        return null;
      }

      var panels = initialData && initialData.engagementPanels;
      if (!Array.isArray(panels)) return null;
      var transcriptPanels = panels.filter(function (panel) {
        var renderer = panel && panel.engagementPanelSectionListRenderer || {};
        return String(renderer.targetId || '').toLowerCase().indexOf('transcript') >= 0;
      });
      var candidates = transcriptPanels.length > 0 ? transcriptPanels : panels;
      return visitContinuationItems(candidates, 0);
    }

    function castReaderInitialDataHasTranscriptEndpoint(initialData, expectedVideoID) {
      return Boolean(castReaderInitialDataTranscriptEndpoint(initialData, expectedVideoID));
    }

    function castReaderTranscriptRendererText(value) {
      if (!value) return '';
      if (typeof value === 'string') return value.replace(/\s+/g, ' ').trim();
      if (typeof value.simpleText === 'string') {
        return value.simpleText.replace(/\s+/g, ' ').trim();
      }
      if (Array.isArray(value.runs)) {
        return value.runs.map(function (run) {
          return run && typeof run.text === 'string' ? run.text : '';
        }).join('').replace(/\s+/g, ' ').trim();
      }
      if (typeof value.content === 'string') {
        return value.content.replace(/\s+/g, ' ').trim();
      }
      if (value.content && typeof value.content === 'object') {
        return castReaderTranscriptRendererText(value.content);
      }
      return '';
    }

    function castReaderTranscriptRendererCues(response) {
      var cues = [];
      var visitedNodes = 0;
      function add(textValue, startValue, durationValue, endValue) {
        var text = castReaderTranscriptRendererText(textValue);
        var startMs = Number(startValue);
        var durationMs = Number(durationValue);
        var endMs = Number(endValue);
        if (!Number.isFinite(durationMs) && Number.isFinite(endMs) &&
            Number.isFinite(startMs)) {
          durationMs = Math.max(0, endMs - startMs);
        }
        if (!text || !Number.isFinite(startMs)) return false;
        cues.push({
          text: text,
          startMs: startMs,
          durationMs: Number.isFinite(durationMs) ? durationMs : 0
        });
        return true;
      }
      function visit(value, depth) {
        if (!value || typeof value !== 'object' || depth > 40 ||
            visitedNodes > 400000 || cues.length >= 200000) return;
        visitedNodes += 1;
        if (value.transcriptCueRenderer) {
          var cue = value.transcriptCueRenderer;
          add(cue.cue, cue.startOffsetMs, cue.durationMs, null);
          return;
        }
        if (value.transcriptSegmentRenderer) {
          var segment = value.transcriptSegmentRenderer;
          add(segment.snippet || segment.text, segment.startMs,
            segment.durationMs, segment.endMs);
          return;
        }
        if (value.transcriptSegmentViewModel) {
          var model = value.transcriptSegmentViewModel;
          var modelCandidates = [
            model,
            model && model.segment,
            model && model.content,
            model && model.transcriptSegment
          ].filter(function (candidate) {
            return candidate && typeof candidate === 'object';
          });
          var addedViewModelCue = false;
          modelCandidates.forEach(function (candidate) {
            addedViewModelCue = add(
              candidate.snippet || candidate.text || candidate.content ||
                candidate.attributedString,
              candidate.startMs !== undefined ? candidate.startMs :
                (candidate.startTimeMs !== undefined ? candidate.startTimeMs :
                  candidate.startTimeMilliseconds),
              candidate.durationMs !== undefined ? candidate.durationMs :
                candidate.durationMilliseconds,
              candidate.endMs !== undefined ? candidate.endMs :
                (candidate.endTimeMs !== undefined ? candidate.endTimeMs :
                  candidate.endTimeMilliseconds)
            ) || addedViewModelCue;
          });
          if (!addedViewModelCue) visit(model, depth + 1);
          return;
        }
        Object.keys(value).forEach(function (key) {
          var child = value[key];
          if (Array.isArray(child)) {
            child.forEach(function (item) { visit(item, depth + 1); });
          } else {
            visit(child, depth + 1);
          }
        });
      }
      visit(response, 0);
      return cues;
    }

    function castReaderTranscriptSegmentContinuation(response) {
      var result = null;
      function endpointFromItem(value) {
        var continuation = value && value.continuationEndpoint;
        var endpoint = continuation && continuation.getTranscriptEndpoint;
        var params = String(endpoint && endpoint.params || '').trim();
        if (!params) return null;
        return {
          params: params,
          clickTrackingParams: String(continuation.clickTrackingParams || '').trim() || null
        };
      }
      function visitSegmentList(value, depth, inSegmentList) {
        if (result || !value || typeof value !== 'object' || depth > 36) return;
        var inside = inSegmentList || Boolean(value.transcriptSegmentListRenderer);
        if (inside && value.continuationItemRenderer) {
          result = endpointFromItem(value.continuationItemRenderer);
          if (result) return;
        }
        Object.keys(value).some(function (key) {
          var child = value[key];
          if (Array.isArray(child)) {
            child.some(function (item) {
              visitSegmentList(item, depth + 1, inside);
              return Boolean(result);
            });
          } else {
            visitSegmentList(child, depth + 1, inside);
          }
          return Boolean(result);
        });
      }
      visitSegmentList(response, 0, false);
      return result;
    }
    """#

    /// Reads the current 2026 transcript view-model through its public light
    /// DOM nodes. YouTube's timedtext endpoint can answer 200 with an empty
    /// body, while the panel still contains timestamped public captions. The
    /// vendored bridge's `innerText` fallback cannot safely split newer rows
    /// whose accessibility duration is concatenated with caption text.
    static let transcriptDOMCueFunction = #"""
    function castReaderTranscriptClockMilliseconds(value) {
      var match = String(value || '').trim().match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
      if (!match) return null;
      var first = parseInt(match[1], 10);
      var second = parseInt(match[2], 10);
      var third = match[3] === undefined ? null : parseInt(match[3], 10);
      if (second >= 60 || (third !== null && third >= 60)) return null;
      var totalSeconds = third === null ? first * 60 + second :
        first * 3600 + second * 60 + third;
      return totalSeconds * 1000;
    }

    function castReaderTranscriptPanelCues(root) {
      root = root || document;
      var segmentSelector =
        'ytd-transcript-segment-renderer, transcript-segment-view-model';
      var first = root.querySelector(segmentSelector);
      if (!first) return [];
      var scope = first.closest &&
        first.closest('ytd-engagement-panel-section-list-renderer');
      scope = scope || root;
      return Array.from(scope.querySelectorAll(segmentSelector)).map(function (segment) {
        var modern = segment.matches('transcript-segment-view-model');
        var timestampNode = modern ? segment.querySelector(
          '.ytwTranscriptSegmentViewModelTimestamp, [class*="Timestamp"]'
        ) : segment.querySelector(
          '.segment-timestamp, #timestamp, yt-formatted-string.segment-timestamp'
        );
        var textNode = modern ? segment.querySelector(
          'span.ytAttributedStringHost[role="text"], ' +
          '[class*="AttributedString"][role="text"], .segment-text, #segment-text'
        ) : segment.querySelector(
          '.segment-text, #segment-text, yt-formatted-string.segment-text'
        );
        var startMs = castReaderTranscriptClockMilliseconds(
          timestampNode && timestampNode.textContent
        );
        var text = String(textNode && textNode.textContent || '')
          .replace(/\s+/g, ' ').trim();
        if (startMs === null || !text) return null;
        return { text: text, startMs: startMs, durationMs: 0 };
      }).filter(Boolean);
    }
    """#

    /// Loads the exact compiled bridge copied into the app's WebAssets folder.
    /// The second candidate keeps unit-test and preview bundles convenient
    /// without weakening the production subdirectory contract.
    static func loadVendoredBridge(bundle: Bundle = .main) -> String? {
        let candidates = [
            bundle.url(
                forResource: "youtube-bridge",
                withExtension: "js",
                subdirectory: "WebAssets/YouTube"
            ),
            bundle.url(
                forResource: "youtube-bridge",
                withExtension: "js",
                subdirectory: "YouTube"
            ),
        ]

        for case let url? in candidates {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                return source
            }
        }
        return nil
    }

    /// YouTube's desktop document can take longer than the product's entire
    /// extraction budget to reach WebKit's `.atDocumentEnd` phase. Install the
    /// unmodified bridge as soon as `<body>` exists instead, preserving its
    /// byte-for-byte vendored payload while giving it time to intercept the
    /// page's transcript request.
    static func earlyBridgeBootstrap(_ vendoredSource: String) -> String {
        #"""
        (function () {
          'use strict';
          var installed = false;
          var timer = null;
          function install() {
            if (installed || !document.body) return;
            installed = true;
            if (timer) clearInterval(timer);
            try {
              \#(vendoredSource)
            } catch (error) {
              document.body.dataset.crYtBridgeBootstrapError = String(error);
            }
          }
          install();
          if (!installed) timer = setInterval(install, 25);
          document.addEventListener('DOMContentLoaded', install, { once: true });
        })();
        """#
    }

    /// Native adapter injected after `youtube-bridge.js`, in
    /// `WKContentWorld.page`, main frame only. It emits exactly one JSON string
    /// through `webkit.messageHandlers.crYt` and never touches extension APIs.
    ///
    /// The expected video ID is supplied by the native URL parser. Requiring a
    /// matching player response prevents a YouTube SPA navigation from
    /// returning the previous video's tracks or transcript.
    static func extractionAdapter(
        expectedVideoID: String,
        requestToken: String = "",
        preferredLanguage: String = "",
        requestedTrack: YouTubeTrackRequest? = nil,
        adapterBudgetMilliseconds: Int = 34_500
    ) -> String {
        let expectedVideoIDLiteral = javaScriptStringLiteral(expectedVideoID)
        let requestTokenLiteral = javaScriptStringLiteral(requestToken)
        let preferredLanguageLiteral = javaScriptStringLiteral(preferredLanguage)
        let requestedTrackIDLiteral = javaScriptStringLiteral(requestedTrack?.id ?? "")
        let requestedTrackLanguageLiteral = javaScriptStringLiteral(
            requestedTrack?.languageCode ?? ""
        )
        let requestedTrackKindLiteral = javaScriptStringLiteral(requestedTrack?.kind ?? "")
        let boundedAdapterBudget = min(
            max(adapterBudgetMilliseconds, 1_000),
            298_500
        )

        return #"""
        (function () {
          'use strict';

          var EXPECTED_VIDEO_ID = \#(expectedVideoIDLiteral);
          var REQUEST_TOKEN = \#(requestTokenLiteral);
          var PREFERRED_LANGUAGE = \#(preferredLanguageLiteral);
          // Set only when the user explicitly picked a caption language. In
          // that mode the adapter must return that track or nothing at all.
          var REQUESTED_TRACK_ID = \#(requestedTrackIDLiteral);
          var REQUESTED_TRACK_LANGUAGE = \#(requestedTrackLanguageLiteral);
          var REQUESTED_TRACK_KIND = \#(requestedTrackKindLiteral);
          var posted = false;
          var diagnostics = [];
          var startedAt = Date.now();
          var watchdog = null;
          var sawBotVerificationChallenge = false;
          var sawSignInRequirement = false;
          var ADAPTER_BUDGET_MS = \#(boundedAdapterBudget);
          var directTranscriptFetchInFlight = false;
          var transcriptFetchCaptureQueue = [];
          var transcriptFetchCaptureWaiters = [];
          var officialTimedtextCaptureQueue = [];
          var officialTimedtextCaptureWaiters = [];
          var latestOfficialTimedtextURL = null;
          var capturedSubtitleProof = null;
          var subtitleProofWaiters = [];
          var requestedOfficialCaptionModule = false;
          // A missing track during page bootstrap is not evidence that the
          // video has no captions. The fast negative path below is armed only
          // after exact-video player/initial-data/module evidence has remained
          // consistently empty across this stability window.
          var FAST_NO_CAPTION_MIN_ELAPSED_MS = 3500;
          var FAST_NO_CAPTION_STABILITY_MS = 1000;
          var FAST_NO_CAPTION_MIN_SAMPLES = 4;
          // Warm follow-ups run long after the extraction budget is spent, so
          // they carry their own per-request ceiling. Native's own follow-up
          // timeout stays the outer bound.
          var WARM_FETCH_TIMEOUT_MS = 5000;

          function publishTranscriptFetchCapture(value) {
            var waiter = transcriptFetchCaptureWaiters.shift();
            if (waiter) {
              waiter(value);
              return;
            }
            transcriptFetchCaptureQueue.push(value);
            if (transcriptFetchCaptureQueue.length > 8) {
              transcriptFetchCaptureQueue.shift();
            }
          }

          function clearTranscriptFetchCaptures() {
            transcriptFetchCaptureQueue = [];
          }

          function waitForTranscriptFetchCapture(timeoutMs) {
            if (transcriptFetchCaptureQueue.length > 0) {
              return Promise.resolve(transcriptFetchCaptureQueue.shift());
            }
            return new Promise(function (resolve) {
              var settled = false;
              var timer = setTimeout(function () {
                if (settled) return;
                settled = true;
                var index = transcriptFetchCaptureWaiters.indexOf(finish);
                if (index >= 0) transcriptFetchCaptureWaiters.splice(index, 1);
                resolve(null);
              }, Math.max(100, timeoutMs));
              function finish(value) {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                resolve(value);
              }
              transcriptFetchCaptureWaiters.push(finish);
            });
          }

          function publishOfficialTimedtextCapture(value) {
            try {
              var trustedURL = value && castReaderTrustedDecoratedCaptionURL(
                value.url,
                EXPECTED_VIDEO_ID
              );
              if (trustedURL) {
                value.url = trustedURL;
                latestOfficialTimedtextURL = trustedURL;
              } else if (value) {
                delete value.url;
              }
            } catch (error) {}
            var waiter = officialTimedtextCaptureWaiters.shift();
            if (waiter) {
              waiter(value);
              return;
            }
            officialTimedtextCaptureQueue.push(value);
            if (officialTimedtextCaptureQueue.length > 8) {
              officialTimedtextCaptureQueue.shift();
            }
          }

          function waitForOfficialTimedtextCapture(timeoutMs) {
            if (officialTimedtextCaptureQueue.length > 0) {
              return Promise.resolve(officialTimedtextCaptureQueue.shift());
            }
            return new Promise(function (resolve) {
              var settled = false;
              var timer = setTimeout(function () {
                if (settled) return;
                settled = true;
                var index = officialTimedtextCaptureWaiters.indexOf(finish);
                if (index >= 0) officialTimedtextCaptureWaiters.splice(index, 1);
                resolve(null);
              }, Math.max(100, timeoutMs));
              function finish(value) {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                resolve(value || null);
              }
              officialTimedtextCaptureWaiters.push(finish);
            });
          }

          function publishSubtitleProof(proof) {
            if (!proof || !proof.token) return;
            capturedSubtitleProof = proof;
            var waiters = subtitleProofWaiters.splice(0, subtitleProofWaiters.length);
            waiters.forEach(function (waiter) { waiter(proof); });
          }

          function captureSubtitleProofFromBody(body) {
            var proof = castReaderSubtitleProofFromPlayerBody(
              body,
              EXPECTED_VIDEO_ID
            );
            if (!proof) return;
            var wasMissing = !capturedSubtitleProof;
            publishSubtitleProof(proof);
            if (wasMissing) note('captured video-scoped subtitle proof');
          }

          function waitForSubtitleProof(timeoutMs) {
            if (capturedSubtitleProof) return Promise.resolve(capturedSubtitleProof);
            return new Promise(function (resolve) {
              var settled = false;
              var timer = setTimeout(function () {
                if (settled) return;
                settled = true;
                var index = subtitleProofWaiters.indexOf(finish);
                if (index >= 0) subtitleProofWaiters.splice(index, 1);
                resolve(null);
              }, Math.max(50, timeoutMs));
              function finish(value) {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                resolve(value || null);
              }
              subtitleProofWaiters.push(finish);
            });
          }

          \#(subtitleProofTokenFunction)
          \#(officialCaptionTrackFunction)

          function captureOfficialTimedtextFetch(response, parsedURL) {
            if (!response || !parsedURL) return;
            var trustedURL = castReaderTrustedDecoratedCaptionURL(
              parsedURL.href,
              EXPECTED_VIDEO_ID
            );
            if (!trustedURL) return;
            response.clone().text().then(function (body) {
              if (body.length > 20 * 1024 * 1024) {
                publishOfficialTimedtextCapture({
                  ok: false,
                  status: Number(response.status || 0),
                  bytes: body.length,
                  text: '',
                  error: 'response_too_large',
                  url: trustedURL,
                  transport: 'fetch'
                });
                return;
              }
              publishOfficialTimedtextCapture({
                ok: Boolean(response.ok),
                status: Number(response.status || 0),
                bytes: body.length,
                text: body,
                error: null,
                url: trustedURL,
                transport: 'fetch'
              });
            }).catch(function () {
              publishOfficialTimedtextCapture({
                ok: false,
                status: Number(response.status || 0),
                bytes: 0,
                text: '',
                error: 'capture_failed',
                url: trustedURL,
                transport: 'fetch'
              });
            });
          }

          // Install before the vendored bridge reaches `document.body`. Its
          // older UI fallback arms its own fetch listener after the first
          // transcript click, so a synchronous get_transcript request can be
          // missed. This passive page-world tap captures only that same-origin
          // public transcript response and never reads cookies or credentials.
          (function installEarlyTranscriptFetchCapture() {
            var upstreamFetch = typeof window.fetch === 'function' ?
              window.fetch.bind(window) : null;
            if (!upstreamFetch) return;
            window.fetch = async function () {
              var args = Array.prototype.slice.call(arguments);
              var requestURL = '';
              try {
                var requestInput = args[0];
                requestURL = typeof requestInput === 'string' ? requestInput :
                  String(requestInput && (
                    requestInput.url || requestInput.href
                  ) || requestInput || '');
              } catch (error) {}
              var parsedURL = null;
              try { parsedURL = new URL(requestURL, location.href); } catch (error) {}
              if (parsedURL && parsedURL.pathname === '/youtubei/v1/player') {
                try {
                  var requestOptions = args[1];
                  if (requestOptions && requestOptions.body !== undefined) {
                    captureSubtitleProofFromBody(requestOptions.body);
                  }
                  var requestInput = args[0];
                  if (requestInput && typeof requestInput.clone === 'function') {
                    requestInput.clone().text().then(captureSubtitleProofFromBody)
                      .catch(function () {});
                  }
                } catch (error) {}
              }
              var response = await upstreamFetch.apply(window, args);
              try {
                captureOfficialTimedtextFetch(response, parsedURL);
                if (parsedURL && !directTranscriptFetchInFlight &&
                    parsedURL.origin === location.origin &&
                    parsedURL.pathname === '/youtubei/v1/get_transcript') {
                  response.clone().text().then(function (body) {
                    if (body.length > 20 * 1024 * 1024) {
                      publishTranscriptFetchCapture({
                        ok: false,
                        status: response.status,
                        bytes: body.length,
                        json: null,
                        error: 'response_too_large'
                      });
                      return;
                    }
                    var json = null;
                    try { json = JSON.parse(body); } catch (error) {}
                    publishTranscriptFetchCapture({
                      ok: response.ok,
                      status: response.status,
                      bytes: body.length,
                      json: json,
                      error: json ? null : 'invalid_json'
                    });
                  }).catch(function () {
                    publishTranscriptFetchCapture({
                      ok: false,
                      status: response.status,
                      bytes: 0,
                      json: null,
                      error: 'capture_failed'
                    });
                  });
                }
              } catch (error) {}
              return response;
            };
          })();

          // Innertube still uses XMLHttpRequest for some player builds. Hook
          // only the request body of the video-scoped player call so the same
          // ephemeral subtitle proof is available regardless of transport.
          (function installEarlyPlayerXHRProofCapture() {
            var XHR = window.XMLHttpRequest;
            if (!XHR || !XHR.prototype) return;
            var upstreamOpen = XHR.prototype.open;
            var upstreamSend = XHR.prototype.send;
            if (typeof upstreamOpen !== 'function' ||
                typeof upstreamSend !== 'function') return;
            var requestURLKey = '__crYtPlayerRequestURL_' +
              String(REQUEST_TOKEN || '').slice(0, 12);
            var responseCaptureKey = '__crYtTimedtextCapture_' +
              String(REQUEST_TOKEN || '').slice(0, 12);
            XHR.prototype.open = function (method, url) {
              try { this[requestURLKey] = String(url || ''); } catch (error) {}
              return upstreamOpen.apply(this, arguments);
            };
            XHR.prototype.send = function (body) {
              try {
                var parsedURL = new URL(String(this[requestURLKey] || ''), location.href);
                if (parsedURL.pathname === '/youtubei/v1/player') {
                  captureSubtitleProofFromBody(body);
                }
                if (!this[responseCaptureKey] &&
                    castReaderTrustedDecoratedCaptionURL(
                      parsedURL.href,
                      EXPECTED_VIDEO_ID
                    )) {
                  this[responseCaptureKey] = true;
                  var request = this;
                  this.addEventListener('loadend', function () {
                    try {
                      var responseURL = String(
                        request.responseURL || request[requestURLKey] || ''
                      );
                      if (!castReaderTrustedDecoratedCaptionURL(
                          responseURL,
                          EXPECTED_VIDEO_ID
                      )) return;
                      var trustedURL = castReaderTrustedDecoratedCaptionURL(
                        responseURL,
                        EXPECTED_VIDEO_ID
                      );
                      if (!trustedURL) return;
                      var responseText = '';
                      try {
                        if (typeof request.responseText === 'string') {
                          responseText = request.responseText;
                        } else if (typeof request.response === 'string') {
                          responseText = request.response;
                        } else if (request.responseType === 'json' && request.response) {
                          responseText = JSON.stringify(request.response);
                        }
                      } catch (error) {}
                      var status = Number(request.status || 0);
                      if (responseText.length > 20 * 1024 * 1024) {
                        publishOfficialTimedtextCapture({
                          ok: false,
                          status: status,
                          bytes: responseText.length,
                          text: '',
                          error: 'response_too_large',
                          url: trustedURL,
                          transport: 'xhr'
                        });
                        return;
                      }
                      publishOfficialTimedtextCapture({
                        ok: status >= 200 && status < 300,
                        status: status,
                        bytes: responseText.length,
                        text: responseText,
                        error: null,
                        url: trustedURL,
                        transport: 'xhr'
                      });
                    } catch (error) {}
                  });
                }
              } catch (error) {}
              return upstreamSend.apply(this, arguments);
            };
          })();

          \#(activeLiveBroadcastFunction)
          \#(playabilityClassificationFunction)
          \#(botVerificationChallengeFunction)
          \#(playerResponseSelectionFunction)
          \#(initialDataTranscriptFunction)
          \#(transcriptDOMCueFunction)

          function remainingBudget() {
            return Math.max(0, ADAPTER_BUDGET_MS - (Date.now() - startedAt));
          }

          function note(value) {
            if (diagnostics.length >= 80) return;
            var elapsedMilliseconds = Math.max(
              0,
              Math.round(Date.now() - startedAt)
            );
            diagnostics.push(
              ('+' + elapsedMilliseconds + 'ms ' + String(value)).slice(0, 240)
            );
          }

          function sleep(ms) {
            return new Promise(function (resolve) { setTimeout(resolve, ms); });
          }

          function cleanText(value) {
            return String(value || '').replace(/\s+/g, ' ').trim();
          }

          function textFromRuns(value) {
            if (!value) return '';
            if (typeof value.simpleText === 'string') return cleanText(value.simpleText);
            if (Array.isArray(value.runs)) {
              return cleanText(value.runs.map(function (run) { return run && run.text || ''; }).join(''));
            }
            return '';
          }

          function metaContent(selector) {
            var node = document.querySelector(selector);
            return node ? cleanText(node.getAttribute('content') || node.getAttribute('href') || '') : '';
          }

          function postOnce(envelope) {
            if (posted) return;
            posted = true;
            if (watchdog) clearTimeout(watchdog);
            envelope.diagnostics = diagnostics.slice();
            try {
              var handler = window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.crYt;
              if (handler && typeof handler.postMessage === 'function') {
                handler.postMessage(JSON.stringify(envelope));
              }
            } catch (error) {
              // There is intentionally no second post path: native owns timeout handling.
            }
          }

          // Native owns a slightly longer timeout. Always publish a classified
          // envelope first so slow page-world hooks cannot turn a known
          // no-caption/restricted result into a generic native timeout.
          watchdog = setTimeout(function () {
            var response = readPlayerResponse();
            var metadata = metadataFrom(
              response,
              playerVideoID(response) || initialDataVideoID() || getURLVideoID()
            );
            var envelope = makeEnvelope(metadata);
            if (!retainRestrictedAccessEvidence(
                envelope,
                response,
                'adapter watchdog'
            )) {
              envelope.error = terminalPlayabilityError(metadata) || {
                code: 'adapter_timeout',
                message: 'YouTube transcript extraction exceeded its adapter budget.'
              };
            }
            note('adapter watchdog fired');
            postOnce(envelope);
          }, ADAPTER_BUDGET_MS);

          function getURLVideoID() {
            try {
              var queryID = new URL(location.href).searchParams.get('v');
              if (queryID) return queryID;
            } catch (error) {}
            var shorts = String(location.pathname || '').match(/^\/shorts\/([^/?]+)/);
            if (shorts) return shorts[1];
            if (String(location.hostname || '').toLowerCase() === 'youtu.be') {
              var shortLink = String(location.pathname || '').match(/^\/([^/?]+)/);
              if (shortLink) return shortLink[1];
            }
            return null;
          }

          // A LOGIN_REQUIRED anti-bot response can omit videoDetails and
          // captionTracks while the same canonical watch document still has a
          // video-scoped transcript continuation in ytInitialData. Treat that
          // endpoint as matching-page evidence, never as caption text itself.
          function initialDataVideoID() {
            return castReaderInitialDataVideoID(window.ytInitialData);
          }

          function initialDataHasTranscriptEndpoint() {
            return castReaderInitialDataHasTranscriptEndpoint(
              window.ytInitialData,
              EXPECTED_VIDEO_ID || getURLVideoID()
            );
          }

          function readPlayerResponse() {
            var runtime = null;
            try {
              var player = document.querySelector('#movie_player');
              if (player && typeof player.getPlayerResponse === 'function') {
                var response = player.getPlayerResponse();
                if (response && typeof response === 'object') runtime = response;
              }
            } catch (error) {}
            var initial = window.ytInitialPlayerResponse;
            var selected = castReaderSelectPlayerResponse(
              initial && typeof initial === 'object' ? initial : null,
              runtime,
              EXPECTED_VIDEO_ID || getURLVideoID()
            );
            if (hasBotVerificationChallengeEvidence(selected)) {
              sawBotVerificationChallenge = true;
              sawSignInRequirement = true;
            }
            if (hasGenericSignInRequirementEvidence(selected)) {
              sawSignInRequirement = true;
            }
            return selected;
          }

          function hasBotVerificationChallengeEvidence(selectedResponse) {
            return castReaderHasBotVerificationChallengeEvidence(
              window.ytInitialPlayerResponse,
              selectedResponse,
              document
            );
          }

          function hasGenericSignInRequirementEvidence(selectedResponse) {
            return [window.ytInitialPlayerResponse, selectedResponse].some(
              function (response) {
                var status = response && response.playabilityStatus || {};
                return playabilityClassification(
                  status.status,
                  playabilityReason(status),
                  false
                ) === 'sign_in_required';
              }
            );
          }

          function playerVideoID(response) {
            return response && response.videoDetails && response.videoDetails.videoId || null;
          }

          function officialPlayerSubtitleProof() {
            try {
              var player = document.querySelector('#movie_player');
              if (!player || typeof player.w5 !== 'function') return null;
              var response = typeof player.getPlayerResponse === 'function' ?
                player.getPlayerResponse() : null;
              var actualVideoID = playerVideoID(response);
              if (!actualVideoID && typeof player.getVideoData === 'function') {
                var videoData = player.getVideoData() || {};
                actualVideoID = String(videoData.video_id || videoData.videoId || '');
              }
              var expectedVideoID = EXPECTED_VIDEO_ID || getURLVideoID();
              if (!actualVideoID ||
                  (expectedVideoID && actualVideoID !== expectedVideoID)) return null;
              var token = player.w5();
              var context = ytcfgValue('INNERTUBE_CONTEXT') || {};
              var client = context.client || {};
              return castReaderSubtitleProofFromPlayerBody({
                videoId: actualVideoID,
                context: { client: { clientName: client.clientName || 'WEB' } },
                serviceIntegrityDimensions: { poToken: token }
              }, expectedVideoID);
            } catch (error) {
              return null;
            }
          }

          async function waitForOfficialPlayerSubtitleProof(maximumWaitMs) {
            var deadline = Date.now() + Math.max(0, maximumWaitMs);
            while (Date.now() <= deadline) {
              var proof = officialPlayerSubtitleProof();
              if (proof) return proof;
              if (Date.now() >= deadline) break;
              await sleep(Math.min(100, deadline - Date.now()));
            }
            return null;
          }

          function officialPlayerForExpectedVideo() {
            try {
              var player = document.querySelector('#movie_player');
              if (!player) return null;
              var response = typeof player.getPlayerResponse === 'function' ?
                player.getPlayerResponse() : null;
              var actualVideoID = playerVideoID(response);
              if (!actualVideoID && typeof player.getVideoData === 'function') {
                var videoData = player.getVideoData() || {};
                actualVideoID = String(videoData.video_id || videoData.videoId || '');
              }
              var expectedVideoID = EXPECTED_VIDEO_ID || getURLVideoID();
              if (!actualVideoID ||
                  (expectedVideoID && actualVideoID !== expectedVideoID)) return null;
              return player;
            } catch (error) {
              return null;
            }
          }

          function officialPlayerCaptionTracks(player) {
            if (!player || typeof player.getOption !== 'function') return [];
            try {
              var tracks = player.getOption('captions', 'tracklist', {
                includeAsr: true
              });
              return Array.isArray(tracks) ? tracks : [];
            } catch (error) {
              return [];
            }
          }

          function officialCaptionModuleState() {
            var player = officialPlayerForExpectedVideo();
            if (!player || typeof player.getOptions !== 'function') {
              return { ready: false, tracks: [] };
            }
            try {
              if (!requestedOfficialCaptionModule) {
                requestedOfficialCaptionModule = true;
                if (typeof player.createSubtitlesModuleIfNeeded === 'function') {
                  player.createSubtitlesModuleIfNeeded();
                }
                if (typeof player.loadModule === 'function') {
                  player.loadModule('captions');
                }
              }
              var options = player.getOptions();
              if (!Array.isArray(options)) {
                return { ready: false, tracks: [] };
              }
              var hasCaptionNamespace = options.some(function (option) {
                var name = String(option || '').toLowerCase();
                return name === 'captions' || name === 'subtitles';
              });
              if (!hasCaptionNamespace) {
                // `getOptions()` is the official module inventory. Once the
                // exact-video player exposes a stable inventory with no
                // captions namespace, an empty track list is meaningful.
                return { ready: true, tracks: [] };
              }
              if (typeof player.getOption !== 'function') {
                return { ready: false, tracks: [] };
              }
              var tracks = player.getOption('captions', 'tracklist', {
                includeAsr: true
              });
              return {
                ready: Array.isArray(tracks),
                tracks: Array.isArray(tracks) ? tracks : []
              };
            } catch (error) {
              return { ready: false, tracks: [] };
            }
          }

          function highConfidenceNoCaptionEvidence(playerState, bridgeResult) {
            var expected = EXPECTED_VIDEO_ID || getURLVideoID();
            var initial = window.ytInitialPlayerResponse;
            var initialDetails = initial && initial.videoDetails || {};
            var initialStatus = initial && initial.playabilityStatus || {};
            if (!expected || String(initialDetails.videoId || '') !== expected ||
                String(initialStatus.status || '').toUpperCase() !== 'OK') {
              return false;
            }

            var initialMetadata = metadataFrom(initial, initialDetails.videoId);
            if (initialMetadata.isLive ||
                !initialMetadata.playability ||
                initialMetadata.playability.classification !== 'playable' ||
                sawBotVerificationChallenge || sawSignInRequirement ||
                hasBotVerificationChallengeEvidence(playerState && playerState.response) ||
                hasGenericSignInRequirementEvidence(playerState && playerState.response)) {
              return false;
            }
            if (typeof navigator !== 'undefined' && navigator.onLine === false) {
              return false;
            }
            if (!document || (document.readyState !== 'interactive' &&
                document.readyState !== 'complete')) {
              return false;
            }

            var initialData = window.ytInitialData;
            if (!initialData ||
                castReaderInitialDataVideoID(initialData) !== expected ||
                !Array.isArray(initialData.engagementPanels) ||
                castReaderInitialDataHasTranscriptEndpoint(initialData, expected)) {
              return false;
            }
            if (castReaderCaptionTracks(initial).length > 0 ||
                !playerState || !playerState.matched ||
                playerState.tracks.length > 0 ||
                bridgeResult && Array.isArray(bridgeResult.tracks) &&
                  bridgeResult.tracks.length > 0) {
              return false;
            }

            // A proof-decorated URL/capture or a native TextTrack is positive
            // caption evidence even when the player-response arrays are late.
            if (latestOfficialTimedtextURL ||
                officialTimedtextCaptureQueue.length > 0 ||
                nativeCaptionTracks().length > 0) {
              return false;
            }
            var officialState = officialCaptionModuleState();
            return officialState.ready && officialState.tracks.length === 0;
          }

          async function waitForOfficialCaptionCandidate(
              trackCandidates,
              maximumWaitMs,
              shouldStop
          ) {
            var expectedVideoID = EXPECTED_VIDEO_ID || getURLVideoID();
            var deadline = Date.now() + Math.max(0, maximumWaitMs);
            var latest = {
              player: null,
              candidate: null,
              track: null,
              url: null,
              officialTrackCount: 0,
              proofReady: false
            };
            while (Date.now() <= deadline) {
              if (typeof shouldStop === 'function' && shouldStop()) return latest;
              var player = officialPlayerForExpectedVideo();
              if (player) {
                latest.player = player;
                try {
                  if (typeof player.createSubtitlesModuleIfNeeded === 'function') {
                    player.createSubtitlesModuleIfNeeded();
                  }
                  if (typeof player.loadModule === 'function') {
                    player.loadModule('captions');
                  }
                } catch (error) {}
                var officialTracks = officialPlayerCaptionTracks(player);
                latest.officialTrackCount = officialTracks.length;
                for (var index = 0; index < trackCandidates.length; index += 1) {
                  var candidate = trackCandidates[index];
                  var officialTrack = castReaderOfficialCaptionTrackMatch(
                    candidate && candidate.track,
                    officialTracks
                  );
                  if (!officialTrack) continue;
                  latest.candidate = candidate;
                  latest.track = officialTrack;
                  latest.url = officialTimedtextURLForCandidate(
                    officialTrack,
                    candidate
                  );
                  if (latest.url) return latest;

                  // `tracklist` exposes a defensive clone which deliberately
                  // omits the private decorated URL. Do not treat the first
                  // clone as proof that asynchronous PO decoration has
                  // finished. Poll the player proof for the full caller budget;
                  // once it resolves, the ordinary timedtext path can use it
                  // directly. Otherwise the caller will force an official
                  // captions-module reload after this bounded wait.
                  var proof = capturedSubtitleProof ||
                    officialPlayerSubtitleProof();
                  if (proof) {
                    publishSubtitleProof(proof);
                    latest.proofReady = true;
                  }
                  break;
                }
              }
              if (Date.now() >= deadline) break;
              await sleep(Math.min(100, deadline - Date.now()));
            }
            return latest;
          }

          function activateOfficialCaptionTrack(value) {
            var player = value && value.player || officialPlayerForExpectedVideo();
            var track = value && value.track;
            var result = {
              requested: false,
              beforeSelected: false,
              beforeOn: null,
              trackChanged: false,
              toggledOn: false,
              selected: false,
              subtitlesOn: null,
              reloadRequested: false,
              nativeMatched: false,
              nativeChanged: false
            };
            if (!player || !track || typeof player.setOption !== 'function') {
              return result;
            }
            try {
              var requestedTrack = value && value.candidate &&
                value.candidate.track || track;
              var beforeTrack = player.getOption('captions', 'track');
              result.beforeSelected = Boolean(castReaderOfficialCaptionTrackMatch(
                requestedTrack,
                beforeTrack ? [beforeTrack] : []
              ));
              if (typeof player.isSubtitlesOn === 'function') {
                result.beforeOn = Boolean(player.isSubtitlesOn());
              }

              if (!result.beforeSelected) {
                player.setOption('captions', 'track', track);
                result.trackChanged = true;
                result.requested = true;
              }

              // `setOption(track)` is intentionally a silent no-op when the
              // same track is already loaded. Re-read after selection because
              // selecting a new track may itself turn subtitles on; calling a
              // toggle based on stale state would immediately turn them off.
              var subtitlesAreOn = typeof player.isSubtitlesOn === 'function'
                ? Boolean(player.isSubtitlesOn())
                : null;
              if (subtitlesAreOn !== true &&
                  typeof player.toggleSubtitlesOn === 'function') {
                player.toggleSubtitlesOn(true);
                result.toggledOn = true;
                result.requested = true;
              } else if (subtitlesAreOn !== true &&
                         typeof player.toggleSubtitles === 'function') {
                player.toggleSubtitles(true);
                result.toggledOn = true;
                result.requested = true;
              }

              // A reload immediately after selecting/toggling can abort the
              // request those operations just started. Reload only when both
              // operations were already no-ops. In iOS native text-track mode
              // YouTube may ignore reload; the caller also reads TextTrack.cues.
              if (result.beforeSelected && result.beforeOn === true) {
                player.setOption('captions', 'reload', true);
                result.reloadRequested = true;
                result.requested = true;
              }

              var currentTrack = player.getOption('captions', 'track');
              result.selected = Boolean(castReaderOfficialCaptionTrackMatch(
                requestedTrack,
                currentTrack ? [currentTrack] : []
              ));
              if (typeof player.isSubtitlesOn === 'function') {
                result.subtitlesOn = Boolean(player.isSubtitlesOn());
              }
              if (!result.selected || result.subtitlesOn !== true) {
                var nativeActivation = activateOfficialNativeCaptionTrack(
                  value && value.candidate
                );
                result.nativeMatched = nativeActivation.matched;
                result.nativeChanged = nativeActivation.changed;
                result.requested = result.requested || nativeActivation.matched;
              }
              return result;
            } catch (error) {
              return result;
            }
          }

          function nativeCaptionMatchScore(
              kind,
              language,
              label,
              identity,
              mode,
              requestedTrack,
              totalTrackCount
          ) {
            var normalizedKind = String(kind || '').toLowerCase();
            if (normalizedKind !== 'captions' && normalizedKind !== 'subtitles') {
              return null;
            }
            var wantedLanguage = languageAlias(requestedTrack &&
              requestedTrack.languageCode);
            var nativeLanguage = languageAlias(language);
            var wantedLabel = cleanText(textFromRuns(
              requestedTrack && requestedTrack.name
            )).toLowerCase();
            var nativeLabel = cleanText(label || '').toLowerCase();
            var score = 20;
            if (wantedLanguage) {
              if (nativeLanguage === wantedLanguage) {
                score -= 10;
              } else if (nativeLanguage &&
                         baseLanguage(nativeLanguage) === baseLanguage(wantedLanguage) &&
                         (nativeLanguage.indexOf('-') < 0 ||
                          wantedLanguage.indexOf('-') < 0)) {
                score -= 5;
              } else if (!nativeLanguage && wantedLabel &&
                         nativeLabel === wantedLabel) {
                score -= 4;
              } else if (!nativeLanguage && Number(totalTrackCount) === 1) {
                score += 8;
              } else {
                return null;
              }
            }
            if (wantedLabel && nativeLabel === wantedLabel) score -= 3;
            var wantedIdentity = String(requestedTrack && (
              requestedTrack.vssId || requestedTrack.vss_id ||
              requestedTrack.captionId
            ) || '').toLowerCase();
            var nativeIdentity = String(identity || '').toLowerCase();
            if (wantedIdentity && nativeIdentity &&
                nativeIdentity.indexOf(wantedIdentity) >= 0) score -= 3;
            if (String(mode || '').toLowerCase() === 'showing') score -= 1;
            return score;
          }

          function nativeCaptionTracks() {
            var result = [];
            var videos = Array.from(document.querySelectorAll('video'));
            videos.forEach(function (video, videoIndex) {
              var tracks = null;
              try { tracks = video.textTracks; } catch (error) {}
              if (!tracks) return;
              for (var index = 0; index < tracks.length; index += 1) {
                var track = tracks[index];
                var kind = String(track && track.kind || '').toLowerCase();
                if (kind !== 'captions' && kind !== 'subtitles') continue;
                result.push({
                  track: track,
                  videoIndex: videoIndex,
                  trackIndex: index
                });
              }
            });
            return result;
          }

          function activateOfficialNativeCaptionTrack(candidate) {
            var requestedTrack = candidate && candidate.track || {};
            var tracks = nativeCaptionTracks();
            var selected = null;
            var selectedScore = Number.POSITIVE_INFINITY;
            tracks.forEach(function (item) {
              var track = item.track;
              var score = nativeCaptionMatchScore(
                track.kind,
                track.language,
                track.label,
                track.id,
                track.mode,
                requestedTrack,
                tracks.length
              );
              if (score !== null && score < selectedScore) {
                selected = item;
                selectedScore = score;
              }
            });
            if (!selected) return { matched: false, changed: false };
            var changed = false;
            tracks.forEach(function (item) {
              try {
                var wantedMode = item === selected ? 'showing' : 'disabled';
                if (item.track.mode !== wantedMode) {
                  item.track.mode = wantedMode;
                  changed = true;
                }
              } catch (error) {}
            });
            return { matched: true, changed: changed };
          }

          function officialNativeCaptionSnapshot(candidate) {
            var requestedTrack = candidate && candidate.track || {};
            var tracks = nativeCaptionTracks();
            var elements = Array.from(document.querySelectorAll(
              'video track[src], track[src]'
            )).filter(function (element) {
              var kind = String(element.kind ||
                element.getAttribute('kind') || 'subtitles').toLowerCase();
              return kind === 'captions' || kind === 'subtitles';
            });
            var snapshot = {
              trackCount: tracks.length,
              showingCount: 0,
              cueCount: 0,
              cues: [],
              trackKey: null,
              ready: false,
              url: null
            };
            var bestScore = Number.POSITIVE_INFINITY;
            tracks.forEach(function (item) {
              var nativeTrack = item.track;
              var mode = String(nativeTrack.mode || '').toLowerCase();
              if (mode === 'showing') snapshot.showingCount += 1;
              var score = nativeCaptionMatchScore(
                nativeTrack.kind,
                nativeTrack.language,
                nativeTrack.label,
                nativeTrack.id,
                mode,
                requestedTrack,
                tracks.length
              );
              if (score === null) return;
              var nativeCues = null;
              try { nativeCues = nativeTrack.cues; } catch (error) {}
              if (!nativeCues || nativeCues.length === 0) return;
              var cues = [];
              for (var cueIndex = 0; cueIndex < nativeCues.length; cueIndex += 1) {
                var nativeCue = nativeCues[cueIndex];
                var cueText = '';
                try {
                  if (nativeCue && typeof nativeCue.getCueAsHTML === 'function') {
                    var cueFragment = nativeCue.getCueAsHTML();
                    cueText = cleanText(cueFragment && cueFragment.textContent || '');
                  }
                } catch (error) {}
                if (!cueText) {
                  cueText = cleanText(decodeEntities(
                    String(nativeCue && nativeCue.text || '')
                      .replace(/<[^>]+>/g, '')
                  ));
                }
                var start = Number(nativeCue && nativeCue.startTime);
                var end = Number(nativeCue && nativeCue.endTime);
                if (!cueText || !Number.isFinite(start)) continue;
                cues.push({
                  text: cueText,
                  startMs: Math.max(0, Math.round(start * 1000)),
                  durationMs: Number.isFinite(end) && end >= start ?
                    Math.round((end - start) * 1000) : 0
                });
              }
              if (cues.length === 0 ||
                  (score > bestScore ||
                   score === bestScore && cues.length <= snapshot.cueCount)) return;
              bestScore = score;
              snapshot.cues = cues;
              snapshot.cueCount = cues.length;
              snapshot.trackKey = [
                item.videoIndex,
                item.trackIndex,
                languageAlias(nativeTrack.language),
                cleanText(nativeTrack.label || '')
              ].join('|');
              var matchingElement = elements.find(function (element) {
                try { return element.track === nativeTrack; } catch (error) { return false; }
              });
              snapshot.ready = Boolean(matchingElement &&
                Number(matchingElement.readyState) === 2);
            });

            var bestURLScore = Number.POSITIVE_INFINITY;
            elements.forEach(function (element) {
              var trustedURL = officialTimedtextURLForCandidate(
                element.src || element.getAttribute('src'),
                candidate
              );
              if (!trustedURL) return;
              var elementScore = nativeCaptionMatchScore(
                element.kind || element.getAttribute('kind') || 'subtitles',
                element.srclang || element.getAttribute('srclang'),
                element.label || element.getAttribute('label'),
                element.id || element.getAttribute('id'),
                element.track && element.track.mode,
                requestedTrack,
                elements.length
              );
              if (elementScore !== null && elementScore < bestURLScore) {
                bestURLScore = elementScore;
                snapshot.url = trustedURL;
              }
            });
            return snapshot;
          }

          function fetchTracksOnce() {
            return new Promise(function (resolve) {
              var settled = false;
              var timer = null;
              function finish(value) {
                if (settled) return;
                settled = true;
                if (timer) clearTimeout(timer);
                document.removeEventListener('__cr_yt_res__', onResult);
                if (document.body) delete document.body.dataset.crYtTracksPending;
                resolve(value);
              }
              function onResult() {
                var tracks = [];
                var videoID = null;
                try {
                  tracks = JSON.parse(document.body.dataset.crYtTracks || '[]');
                  if (!Array.isArray(tracks)) tracks = [];
                  videoID = document.body.dataset.crYtTracksVideoId || null;
                } catch (error) {
                  tracks = [];
                }
                finish({ tracks: tracks, playerVideoId: videoID });
              }
              if (!document.body) {
                finish({ tracks: [], playerVideoId: null });
                return;
              }
              document.addEventListener('__cr_yt_res__', onResult);
              document.body.dataset.crYtTracksPending = '1';
              document.dispatchEvent(new Event('__cr_yt_req__'));
              timer = setTimeout(function () {
                finish({ tracks: [], playerVideoId: null });
              }, Math.max(100, Math.min(650, remainingBudget())));
            });
          }

          async function waitForMatchingPlayer() {
            var expected = EXPECTED_VIDEO_ID || getURLVideoID();
            var last = {
              tracks: [],
              playerVideoId: null,
              response: null,
              matched: false,
              conclusivelyNoCaptions: false
            };
            var emptyEvidenceSince = null;
            var emptyEvidenceSamples = 0;

            function snapshot(bridgeResult) {
              bridgeResult = bridgeResult || { tracks: [], playerVideoId: null };
              var response = readPlayerResponse();
              var responseVideoID = playerVideoID(response);
              var pageVideoID = initialDataVideoID();
              var actual = responseVideoID || bridgeResult.playerVideoId || pageVideoID;
              return {
                tracks: castReaderResolveCaptionTracks(response, bridgeResult.tracks),
                playerVideoId: actual,
                response: response,
                matched: Boolean(actual && (!expected || actual === expected)),
                conclusivelyNoCaptions: false
              };
            }

            function hasReadyTracksOrTerminal(state) {
              if (!state.matched) return false;
              var currentMetadata = metadataFrom(
                state.response,
                state.playerVideoId
              );
              return state.tracks.length > 0 ||
                Boolean(terminalPlayabilityError(currentMetadata));
            }

            function hasAuthoritativeInitialTerminal() {
              var initial = window.ytInitialPlayerResponse;
              var initialVideoID = playerVideoID(initial);
              if (!initialVideoID || (expected && initialVideoID !== expected)) {
                return false;
              }
              return Boolean(terminalPlayabilityError(
                metadataFrom(initial, initialVideoID)
              ));
            }

            // Slow cellular page bootstrap can legitimately exceed 4.5 s.
            // Cap player discovery so the complete transcript-panel bridge
            // still fits inside the adapter budget.
            var playerDeadline = Math.min(startedAt + 9500, startedAt + ADAPTER_BUDGET_MS);
            var attempt = 0;
            while (Date.now() < playerDeadline) {
              if (attempt > 0) {
                var retryDelay = Math.min(
                  250,
                  Math.max(0, playerDeadline - Date.now()),
                  remainingBudget()
                );
                if (retryDelay > 0) await sleep(retryDelay);
                if (Date.now() >= playerDeadline) break;
              }
              attempt += 1;

              // The inline initial player response is often complete before
              // the vendored bridge has attached to `document.body`. Consult
              // it first so a known track or terminal playability result never
              // pays the bridge's per-attempt 650 ms timeout.
              var synchronous = snapshot(null);
              if (!synchronous.matched &&
                  castReaderDocumentHasBotVerificationChallenge(document)) {
                note('document exposes an explicit bot-verification challenge');
                return synchronous;
              }
              if (synchronous.tracks.length > 0 ||
                  hasAuthoritativeInitialTerminal()) {
                note('player resolved synchronously attempt=' + attempt +
                  ' tracks=' + synchronous.tracks.length);
                return synchronous;
              }

              var result = await fetchTracksOnce();
              // The vendored bridge can observe the media-blocked runtime
              // player before it notices ytInitialPlayerResponse. Resolve the
              // tracks from the same scored response used for playability and
              // metadata so its valid signed timedtext URLs are not discarded.
              last = snapshot(result);
              var pageVideoID = initialDataVideoID();
              note('player attempt=' + attempt + ' expected=' +
                (expected || 'n/a') + ' actual=' +
                (last.playerVideoId || 'n/a') +
                ' tracks=' + last.tracks.length +
                ' responseTracks=' + castReaderCaptionTracks(last.response).length +
                ' bridgeTracks=' + result.tracks.length +
                ' initialDataVideo=' + (pageVideoID || 'n/a') +
                ' transcriptEndpoint=' + initialDataHasTranscriptEndpoint());
              if (!last.matched && castReaderDocumentHasBotVerificationChallenge(document)) {
                note('document exposes an explicit bot-verification challenge');
                return last;
              }
              if (last.matched) {
                if (hasReadyTracksOrTerminal(last)) {
                  return last;
                }
                if (attempt >= 3 && initialDataHasTranscriptEndpoint()) {
                  note('using video-scoped initialData transcript fallback');
                  return last;
                }

                if (highConfidenceNoCaptionEvidence(last, result)) {
                  if (emptyEvidenceSince === null) {
                    emptyEvidenceSince = Date.now();
                    emptyEvidenceSamples = 1;
                  } else {
                    emptyEvidenceSamples += 1;
                  }
                  var emptyStableFor = Date.now() - emptyEvidenceSince;
                  if (Date.now() - startedAt >= FAST_NO_CAPTION_MIN_ELAPSED_MS &&
                      emptyEvidenceSamples >= FAST_NO_CAPTION_MIN_SAMPLES &&
                      emptyStableFor >= FAST_NO_CAPTION_STABILITY_MS) {
                    // One final bridge + synchronous snapshot closes the race
                    // with a track that arrived while the official module was
                    // being sampled. Any positive signal revokes this fast path.
                    var finalBridgeResult = await fetchTracksOnce();
                    var finalSnapshot = snapshot(finalBridgeResult);
                    if (highConfidenceNoCaptionEvidence(
                        finalSnapshot,
                        finalBridgeResult
                    )) {
                      finalSnapshot.conclusivelyNoCaptions = true;
                      note('high-confidence no-caption evidence stableMs=' +
                        emptyStableFor + ' samples=' + emptyEvidenceSamples);
                      return finalSnapshot;
                    }
                  }
                } else {
                  emptyEvidenceSince = null;
                  emptyEvidenceSamples = 0;
                }
                note('matching player has no hydrated caption tracks yet');
              } else {
                emptyEvidenceSince = null;
                emptyEvidenceSamples = 0;
              }
            }
            return last;
          }

          function normalizedLanguage(value) {
            return String(value || '').toLowerCase().replace(/_/g, '-');
          }

          function baseLanguage(value) {
            return normalizedLanguage(value).split('-')[0];
          }

          function languageAlias(value) {
            var normalized = normalizedLanguage(value);
            if (/^zh-(?:cn|sg|hans)(?:-|$)/.test(normalized)) return 'zh-hans';
            if (/^zh-(?:tw|hk|mo|hant)(?:-|$)/.test(normalized)) return 'zh-hant';
            return normalized;
          }

          function languageMatches(track, wanted) {
            var trackLanguage = normalizedLanguage(track && track.languageCode);
            var wantedLanguage = normalizedLanguage(wanted);
            return Boolean(trackLanguage && wantedLanguage &&
              (trackLanguage === wantedLanguage ||
               baseLanguage(trackLanguage) === baseLanguage(wantedLanguage)));
          }

          function languageAliasMatches(track, wanted) {
            var trackLanguage = languageAlias(track && track.languageCode);
            var wantedLanguage = languageAlias(wanted);
            return Boolean(trackLanguage && wantedLanguage &&
              trackLanguage === wantedLanguage);
          }

          function isASR(track) {
            return String(track && track.kind || '').toLowerCase() === 'asr';
          }

          function orderedTracks(tracks, uiLanguage) {
            if (!Array.isArray(tracks)) return [];
            return tracks.map(function (track, index) {
              var rank = 10;
              if (languageAliasMatches(track, uiLanguage)) rank = isASR(track) ? 1 : 0;
              else if (languageMatches(track, uiLanguage)) rank = isASR(track) ? 3 : 2;
              else if (languageAliasMatches(track, 'en')) rank = isASR(track) ? 5 : 4;
              else if (languageMatches(track, 'en')) rank = isASR(track) ? 7 : 6;
              else rank = isASR(track) ? 9 : 8;
              return { track: track, index: index, rank: rank };
            }).sort(function (left, right) {
              return left.rank - right.rank || left.index - right.index;
            });
          }

          function selectBestTrack(tracks, uiLanguage) {
            var ordered = orderedTracks(tracks, uiLanguage);
            return ordered.length > 0 ? ordered[0].track : null;
          }

          // Explicit language switch. The ranked fallback chain exists for the
          // first open, where the app is guessing; once the user has named a
          // language, quietly narrating a different one is worse than failing,
          // so an unmatched request collapses the candidate set to empty.
          function pinRequestedTrack(candidates) {
            if (!REQUESTED_TRACK_ID && !REQUESTED_TRACK_LANGUAGE) return candidates;
            var exact = null;
            var loose = null;
            candidates.forEach(function (candidate) {
              var identity = trackEnvelope(candidate.track, candidate.index);
              if (!identity) return;
              if (REQUESTED_TRACK_ID && identity.id === REQUESTED_TRACK_ID) {
                if (!exact) exact = candidate;
                return;
              }
              if (!loose && REQUESTED_TRACK_LANGUAGE &&
                  languageAliasMatches(candidate.track, REQUESTED_TRACK_LANGUAGE) &&
                  (!REQUESTED_TRACK_KIND || identity.kind === REQUESTED_TRACK_KIND)) {
                loose = candidate;
              }
            });
            var pinned = exact || loose;
            if (!pinned) {
              note('requested track missing id=' + String(REQUESTED_TRACK_ID || '') +
                ' lang=' + String(REQUESTED_TRACK_LANGUAGE || '') +
                ' kind=' + String(REQUESTED_TRACK_KIND || ''));
              return [];
            }
            note('pinned requested track index=' + pinned.index +
              ' match=' + (exact ? 'id' : 'language'));
            return [pinned];
          }

          function availableTrackEnvelopes(candidates) {
            return candidates.slice(0, 40).map(function (candidate) {
              return trackEnvelope(candidate.track, candidate.index);
            }).filter(Boolean);
          }

          // --- Warm session -------------------------------------------------
          // After a successful extraction the page still holds everything a
          // second language needs: the video-scoped proof, the track list and
          // the player metadata. Native keeps this document alive and asks for
          // further tracks through the entry point below, which skips the whole
          // page bootstrap that dominates extraction time.
          var warmState = null;

          function installWarmTrackExtractor(state) {
            if (!state || !Array.isArray(state.tracks) || state.tracks.length === 0) {
              note('warm install skipped tracks=' +
                (state && state.tracks ? state.tracks.length : 'nil'));
              return;
            }
            warmState = state;
            window.__crYtExtractTrack = warmExtractTrack;
            note('warm install ok tracks=' + state.tracks.length);
          }

          function postFollowUp(envelope) {
            envelope.diagnostics = diagnostics.slice(-40);
            try {
              var handler = window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.crYt;
              if (handler && typeof handler.postMessage === 'function') {
                handler.postMessage(JSON.stringify(envelope));
              }
            } catch (error) {
              // Native owns follow-up timeouts, exactly as it does for postOnce.
            }
          }

          function warmSelectCandidate(trackId, languageCode, kind) {
            var candidates = orderedTracks(
              warmState.tracks,
              languageCode || PREFERRED_LANGUAGE
            );
            var exact = null;
            var loose = null;
            candidates.forEach(function (candidate) {
              var identity = trackEnvelope(candidate.track, candidate.index);
              if (!identity) return;
              if (trackId && identity.id === trackId) {
                if (!exact) exact = candidate;
                return;
              }
              if (!loose && languageCode &&
                  languageAliasMatches(candidate.track, languageCode) &&
                  (!kind || identity.kind === kind)) {
                loose = candidate;
              }
            });
            return exact || loose;
          }

          async function warmFetchCues(candidate) {
            var baseURL = candidate.track && candidate.track.baseUrl;
            if (!baseURL) return null;
            if (castReaderCaptionTrackRequiresProof(baseURL) && !capturedSubtitleProof) {
              return null;
            }
            var formats = ['json3', 'srv3', 'base_url'];
            for (var index = 0; index < formats.length; index += 1) {
              var url = castReaderCaptionURLWithProof(
                baseURL,
                formats[index],
                capturedSubtitleProof
              );
              // The adapter's own budget is long spent by now, so this lane
              // carries its own timeout instead of deriving one from it.
              var result = await fetchViaMainWorld(url, WARM_FETCH_TIMEOUT_MS);
              if (!result.ok || !result.text) continue;
              var cues = dedupeCues(parseTimedtextResponse(result.text));
              if (cues.length === 0) continue;
              if (!cuesMatchCandidateLanguage(cues, candidate)) continue;
              return { cues: cues, source: formats[index] };
            }
            return null;
          }

          async function warmExtractTrack(
            requestToken,
            followUpToken,
            trackId,
            languageCode,
            kind
          ) {
            // Only native knows this extraction's token, so page script cannot
            // drive the entry point even though it is reachable on `window`.
            if (requestToken !== REQUEST_TOKEN) return false;
            if (!followUpToken || typeof followUpToken !== 'string') return false;
            if (!warmState) {
              // Reachable but not armed. Answer immediately so native falls
              // back now instead of waiting out its follow-up timeout.
              note('warm invoke without state posted=' + String(posted));
              postFollowUp({
                schemaVersion: 1,
                requestToken: REQUEST_TOKEN,
                followUpToken: followUpToken,
                ok: false,
                requestVideoId: EXPECTED_VIDEO_ID || null,
                videoId: EXPECTED_VIDEO_ID || null,
                cues: [],
                isLive: false,
                error: {
                  code: 'warm_session_miss',
                  message: 'Warm state was never installed on this document.'
                }
              });
              return true;
            }

            var envelope = makeEnvelope(warmState.metadata);
            envelope.followUpToken = followUpToken;
            envelope.availableTracks = warmState.availableTracks || null;
            try {
              var candidate = warmSelectCandidate(trackId, languageCode, kind);
              if (!candidate) {
                envelope.error = {
                  code: 'requested_track_unavailable',
                  message: 'The requested caption track is not offered for this video.'
                };
                postFollowUp(envelope);
                return true;
              }
              var fetched = await warmFetchCues(candidate);
              if (!fetched) {
                // A warm miss is not a product error: native discards the warm
                // session and retries through the full bootstrap path.
                envelope.error = {
                  code: 'warm_session_miss',
                  message: 'The warm document could not serve this caption track.'
                };
                postFollowUp(envelope);
                return true;
              }
              envelope.cues = fetched.cues;
              envelope.ok = fetched.cues.length > 0;
              envelope.transcriptSource = fetched.source;
              envelope.captionTrack = trackEnvelope(
                candidate.track,
                candidate.index
              );
              envelope.captionLanguage = candidate.track.languageCode || null;
            } catch (error) {
              envelope.ok = false;
              envelope.cues = [];
              envelope.error = {
                code: 'warm_session_miss',
                message: 'Warm caption fetch raised: ' + String(error)
              };
            }
            postFollowUp(envelope);
            return true;
          }

          // Fast script-level guard for results that are not intrinsically
          // bound to one caption candidate (get_transcript, transcript panel,
          // passive captures). NaturalLanguage performs the authoritative
          // native validation; this guard is deliberately conservative and
          // only rejects clear cross-script mismatches such as Chinese cues
          // being returned for an English source track.
          function coarseCueLanguage(cues) {
            var counts = { cjk: 0, kana: 0, hangul: 0, devanagari: 0, latin: 0 };
            var seen = 0;
            var input = Array.isArray(cues) ? cues : [];
            for (var cueIndex = 0; cueIndex < input.length && seen < 4000;
                 cueIndex += 1) {
              var text = String(input[cueIndex] && input[cueIndex].text || '');
              for (var character of text) {
                if (seen >= 4000) break;
                var value = character.codePointAt(0);
                if (!Number.isFinite(value)) continue;
                if ((value >= 0x4E00 && value <= 0x9FFF) ||
                    (value >= 0x3400 && value <= 0x4DBF)) counts.cjk += 1;
                else if ((value >= 0x3040 && value <= 0x30FF)) counts.kana += 1;
                else if (value >= 0xAC00 && value <= 0xD7AF) counts.hangul += 1;
                else if (value >= 0x0900 && value <= 0x097F) counts.devanagari += 1;
                else if ((value >= 0x0041 && value <= 0x005A) ||
                         (value >= 0x0061 && value <= 0x007A) ||
                         (value >= 0x00C0 && value <= 0x024F)) counts.latin += 1;
                else continue;
                seen += 1;
              }
            }
            if (seen < 16) return null;
            if (counts.kana / seen > 0.10) return 'ja';
            if (counts.hangul / seen > 0.10) return 'ko';
            if (counts.devanagari / seen > 0.10) return 'hi';
            if (counts.cjk / seen > 0.15) return 'zh';
            return null;
          }

          function cuesMatchCandidateLanguage(cues, candidate) {
            var detected = coarseCueLanguage(cues);
            var requested = baseLanguage(
              candidate && candidate.track && candidate.track.languageCode
            );
            return !detected || !requested || detected === requested;
          }

          function trackEnvelope(track, index) {
            if (!track) return null;
            var name = textFromRuns(track.name);
            var kind = isASR(track) ? 'asr' : 'manual';
            var languageCode = String(track.languageCode || '');
            var identity = String(track.vssId ||
              [languageCode, kind, name, String(index)].join('|'));
            return {
              id: identity,
              name: name || null,
              languageCode: languageCode || null,
              kind: kind,
              vssId: track.vssId || null,
              index: index
            };
          }

          function officialTimedtextURLForCandidate(
              rawURL,
              candidate,
              mayRemoveMismatchedTranslation
          ) {
            var trustedURL = castReaderTrustedDecoratedCaptionURL(
              rawURL,
              EXPECTED_VIDEO_ID || getURLVideoID()
            );
            var requestedTrack = candidate && candidate.track;
            if (!trustedURL || !requestedTrack) return null;
            try {
              var url = new URL(trustedURL, location.href);
              var requestedLanguage = languageAlias(requestedTrack.languageCode);
              var urlLanguage = languageAlias(url.searchParams.get('lang'));
              if (!requestedLanguage || !urlLanguage ||
                  requestedLanguage !== urlLanguage) return null;
              var translatedLanguage = languageAlias(
                url.searchParams.get('tlang')
              );
              if (translatedLanguage && translatedLanguage !== requestedLanguage) {
                // v1 reads an actual caption track; it does not silently turn
                // YouTube's UI auto-translation into that source track. A
                // captured response is already translated and must be ignored.
                // A proof-bearing URL that we have not fetched yet can safely
                // request its original `lang` by dropping only `tlang` while
                // preserving the exact PO-token/client tuple.
                if (mayRemoveMismatchedTranslation === false) return null;
                url.searchParams.delete('tlang');
              }

              var urlKind = String(url.searchParams.get('kind') || '')
                .trim().toLowerCase();
              if (isASR(requestedTrack)) {
                if (urlKind !== 'asr') return null;
              } else if (urlKind === 'asr') {
                return null;
              }
              return url.href;
            } catch (error) {
              return null;
            }
          }

          function officialTimedtextResourceURL(candidate) {
            try {
              if (!window.performance ||
                  typeof window.performance.getEntriesByType !== 'function') {
                return null;
              }
              var entries = window.performance.getEntriesByType('resource');
              for (var index = entries.length - 1; index >= 0; index -= 1) {
                var trustedURL = officialTimedtextURLForCandidate(
                  entries[index] && entries[index].name,
                  candidate
                );
                if (trustedURL) return trustedURL;
              }
            } catch (error) {}
            return null;
          }

          function fetchViaMainWorld(url, timeoutOverrideMs) {
            return new Promise(function (resolve) {
              var settled = false;
              var timer = null;
              function finish(value) {
                if (settled) return;
                settled = true;
                if (timer) clearTimeout(timer);
                document.removeEventListener('__cr_yt_fetch_res__', onResult);
                resolve(value);
              }
              function onResult() {
                try {
                  var result = JSON.parse(document.body.dataset.crYtFetchResult || '{}');
                  finish({
                    ok: Boolean(result.ok),
                    status: Number(result.status || 0),
                    text: typeof result.text === 'string' ? result.text : '',
                    headers: result.headers || {},
                    error: result.error || null
                  });
                } catch (error) {
                  finish({ ok: false, status: 0, text: '', error: 'invalid_fetch_result' });
                }
              }
              if (!document.body) {
                finish({ ok: false, status: 0, text: '', error: 'missing_body' });
                return;
              }
              document.addEventListener('__cr_yt_fetch_res__', onResult);
              document.body.dataset.crYtFetchUrl = String(url || '');
              document.dispatchEvent(new Event('__cr_yt_fetch_req__'));
              timer = setTimeout(function () {
                finish({ ok: false, status: 0, text: '', error: 'fetch_timeout' });
              }, timeoutOverrideMs && timeoutOverrideMs > 0
                ? timeoutOverrideMs
                : Math.max(250, Math.min(1700, remainingBudget() - 2500)));
            });
          }

          function URLWithFormat(rawURL, format) {
            try {
              var url = new URL(rawURL, location.href);
              url.searchParams.delete('fmt');
              url.searchParams.set('fmt', format);
              return url.href;
            } catch (error) {
              var separator = String(rawURL).indexOf('?') >= 0 ? '&' : '?';
              return String(rawURL).replace(/([?&])fmt=[^&]*/g, '$1').replace(/[?&]$/, '') +
                separator + 'fmt=' + encodeURIComponent(format);
            }
          }

          function URLWithoutFormat(rawURL) {
            try {
              var url = new URL(rawURL, location.href);
              url.searchParams.delete('fmt');
              return url.href;
            } catch (error) {
              return String(rawURL || '')
                .replace(/([?&])fmt=[^&]*/g, '$1')
                .replace(/[?&]$/, '');
            }
          }

          function decodeEntities(value) {
            var textarea = document.createElement('textarea');
            textarea.innerHTML = String(value || '');
            return textarea.value;
          }

          function parseClock(value) {
            var match = String(value || '').trim().match(/^(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})/);
            if (!match) return null;
            var hours = parseInt(match[1] || '0', 10);
            var minutes = parseInt(match[2] || '0', 10);
            var seconds = parseInt(match[3] || '0', 10);
            var millis = parseInt(String(match[4] || '0').padEnd(3, '0').slice(0, 3), 10);
            return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis;
          }

          function parseJSON3(text) {
            try {
              var parsed = JSON.parse(text);
              var events = Array.isArray(parsed.events) ? parsed.events : [];
              return events.map(function (event) {
                var segments = Array.isArray(event.segs) ? event.segs : [];
                var cueText = cleanText(segments.map(function (segment) {
                  return segment && segment.utf8 || '';
                }).join('').replace(/\n/g, ' '));
                return {
                  text: cueText,
                  startMs: Number(event.tStartMs),
                  durationMs: Number(event.dDurationMs || 0)
                };
              }).filter(function (cue) {
                return cue.text && Number.isFinite(cue.startMs);
              });
            } catch (error) {
              return [];
            }
          }

          function parseWebVTT(text) {
            if (String(text).indexOf('-->') < 0) return [];
            var normalized = String(text).replace(/\r\n?/g, '\n');
            var cues = [];
            normalized.split(/\n\n+/).forEach(function (block) {
              var lines = block.trim().split('\n');
              var timestampIndex = lines.findIndex(function (line) {
                return line.indexOf('-->') >= 0;
              });
              if (timestampIndex < 0) return;
              var sides = lines[timestampIndex].split('-->');
              var startMs = parseClock(sides[0]);
              var endMs = parseClock(sides[1]);
              if (startMs === null) return;
              var cueText = cleanText(decodeEntities(lines.slice(timestampIndex + 1)
                .map(function (line) { return line.replace(/<[^>]+>/g, ''); })
                .join(' ')));
              if (!cueText) return;
              cues.push({
                text: cueText,
                startMs: startMs,
                durationMs: endMs !== null && endMs >= startMs ? endMs - startMs : 0
              });
            });
            return cues;
          }

          function parseTimedtextXML(text) {
            try {
              var xml = new DOMParser().parseFromString(String(text), 'text/xml');
              if (xml.querySelector('parsererror')) return [];
              var textNodes = Array.from(xml.getElementsByTagName('text'));
              var paragraphNodes = Array.from(xml.getElementsByTagName('p'));
              var nodes = textNodes.length > 0 ? textNodes : paragraphNodes;
              return nodes.map(function (node) {
                var isParagraph = String(node.tagName || '').toLowerCase() === 'p';
                var rawStart = Number(node.getAttribute(isParagraph ? 't' : 'start') || 0);
                var rawDuration = Number(node.getAttribute(isParagraph ? 'd' : 'dur') || 0);
                return {
                  text: cleanText(node.textContent || ''),
                  startMs: Math.round(isParagraph ? rawStart : rawStart * 1000),
                  durationMs: Math.round(isParagraph ? rawDuration : rawDuration * 1000)
                };
              }).filter(function (cue) {
                return cue.text && Number.isFinite(cue.startMs);
              });
            } catch (error) {
              return [];
            }
          }

          function parseTimedtextResponse(text) {
            var source = String(text || '');
            var trimmed = source.trimStart();
            var cues = [];
            if (trimmed.charAt(0) === '{') cues = parseJSON3(source);
            if (cues.length === 0 && source.indexOf('-->') >= 0) cues = parseWebVTT(source);
            if (cues.length === 0 && source.indexOf('<') >= 0) cues = parseTimedtextXML(source);
            return cues;
          }

          function ytcfgValue(key) {
            try {
              var config = window.ytcfg;
              if (config && typeof config.get === 'function') {
                var value = config.get(key);
                if (value !== undefined && value !== null) return value;
              }
              if (config && config.data_ && config.data_[key] !== undefined) {
                return config.data_[key];
              }
            } catch (error) {}
            return null;
          }

          async function waitForInitialDataTranscriptEndpoint(maximumWaitMs) {
            var deadline = Date.now() + Math.max(0, Math.min(
              maximumWaitMs,
              remainingBudget() - 500
            ));
            while (Date.now() <= deadline) {
              var endpoint = castReaderInitialDataTranscriptEndpoint(
                window.ytInitialData,
                EXPECTED_VIDEO_ID || getURLVideoID()
              );
              if (endpoint) return endpoint;
              if (Date.now() >= deadline) break;
              await sleep(Math.min(100, deadline - Date.now()));
            }
            return null;
          }

          function transcriptAPIErrorStatus(json) {
            var error = json && json.error || {};
            return cleanText(error.status || error.message || '') || null;
          }

          async function transcriptAttestation(videoID) {
            var candidates = [];
            try {
              if (window.attmp && typeof window.attmp.s === 'function') {
                candidates.push({ owner: window.attmp, fn: window.attmp.s });
              }
              if (window.yt && window.yt.aba &&
                  typeof window.yt.aba.att === 'function') {
                candidates.push({ owner: window.yt.aba, fn: window.yt.aba.att });
              }
            } catch (error) {}

            async function attempt() {
              for (var index = 0; index < candidates.length; index += 1) {
                try {
                  var candidate = candidates[index];
                  var result = await Promise.race([
                    Promise.resolve(candidate.fn.call(
                      candidate.owner,
                      'ENGAGEMENT_TYPE_VIDEO_TRANSCRIPT_REQUEST',
                      { encryptedVideoId: videoID },
                      2200
                    )),
                    sleep(Math.min(2300, Math.max(100, remainingBudget() - 900)))
                      .then(function () { return null; })
                  ]);
                  if (result && typeof result === 'object' &&
                      result.webResponse && !result.error) return result;
                } catch (error) {}
              }
              return null;
            }

            var result = await attempt();
            if (result) return result;
            try {
              if (remainingBudget() > 1300 && window.bgevmc &&
                  typeof window.bgevmc.cr === 'function') {
                var refreshBudgetMs = Math.min(
                  800,
                  Math.max(100, remainingBudget() - 1200)
                );
                await Promise.race([
                  Promise.resolve(window.bgevmc.cr()).catch(function () {
                    return null;
                  }),
                  sleep(refreshBudgetMs)
                ]);
                await sleep(Math.min(180, Math.max(0, remainingBudget() - 700)));
                result = await attempt();
              }
            } catch (error) {}
            return result || null;
          }

          async function directTranscriptViaInitialData(selectedTrack) {
            var endpoint = await waitForInitialDataTranscriptEndpoint(6000);
            if (!endpoint) {
              note('direct transcript endpoint unavailable after hydration wait');
              return {
                cues: [],
                endpointFound: false,
                status: 0,
                accessRejected: false,
                timedOut: false,
                networkFailed: false
              };
            }

            var apiKey = String(ytcfgValue('INNERTUBE_API_KEY') || '').trim();
            var context = ytcfgValue('INNERTUBE_CONTEXT');
            if (!apiKey || !context || typeof context !== 'object') {
              note('direct transcript config missing key=' + Boolean(apiKey) +
                ' context=' + Boolean(context && typeof context === 'object'));
              return {
                cues: [],
                endpointFound: true,
                status: 0,
                accessRejected: false,
                timedOut: false,
                networkFailed: false
              };
            }

            var apiURL = null;
            try {
              apiURL = new URL(endpoint.apiUrl || '/youtubei/v1/get_transcript', location.origin);
              if (apiURL.origin !== location.origin ||
                  apiURL.pathname !== '/youtubei/v1/get_transcript') {
                throw new Error('unexpected_transcript_endpoint');
              }
              apiURL.searchParams.set('key', apiKey);
              apiURL.searchParams.set('prettyPrint', 'false');
            } catch (error) {
              note('direct transcript endpoint rejected');
              return {
                cues: [],
                endpointFound: true,
                status: 0,
                accessRejected: true,
                timedOut: false,
                networkFailed: false
              };
            }

            var contextClient = context.client && typeof context.client === 'object' ?
              context.client : {};
            var clientName = ytcfgValue('INNERTUBE_CONTEXT_CLIENT_NAME') ||
              contextClient.clientName || '';
            var clientVersion = ytcfgValue('INNERTUBE_CONTEXT_CLIENT_VERSION') ||
              ytcfgValue('INNERTUBE_CLIENT_VERSION') || contextClient.clientVersion || '';
            var visitorData = ytcfgValue('VISITOR_DATA') || contextClient.visitorData || '';
            var pageCL = ytcfgValue('PAGE_CL');
            var pageLabel = ytcfgValue('PAGE_BUILD_LABEL');
            var headers = {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'X-Goog-AuthUser': '0',
              'X-Youtube-Bootstrap-Logged-In': 'false'
            };
            if (clientName !== '') headers['X-YouTube-Client-Name'] = String(clientName);
            if (clientVersion !== '') headers['X-YouTube-Client-Version'] = String(clientVersion);
            if (visitorData !== '') headers['X-Goog-Visitor-Id'] = String(visitorData);
            if (pageCL !== null && pageCL !== undefined && Number.isFinite(Number(pageCL))) {
              headers['X-YouTube-Page-CL'] = String(pageCL);
            }
            if (pageLabel) headers['X-YouTube-Page-Label'] = String(pageLabel);

            var allCues = [];
            var visitedParams = new Set();
            var current = endpoint;
            var page = 0;
            var latestStatus = 0;
            var exactVideoID = EXPECTED_VIDEO_ID || getURLVideoID() || '';
            var attestation = exactVideoID ?
              await transcriptAttestation(exactVideoID) : null;
            note('direct transcript attestation available=' + Boolean(attestation));
            while (current && page < 6 && remainingBudget() > 1200) {
              var params = String(current.params || '').trim();
              if (!params || visitedParams.has(params)) break;
              visitedParams.add(params);
              page += 1;

              var requestContext = Object.assign({}, context, {
                client: Object.assign({}, contextClient, {
                  originalUrl: location.origin + '/watch?v=' +
                    encodeURIComponent(EXPECTED_VIDEO_ID || getURLVideoID() || '')
                })
              });
              if (current.clickTrackingParams) {
                requestContext.clickTracking = {
                  clickTrackingParams: current.clickTrackingParams
                };
              }
              if (attestation) {
                requestContext.request = Object.assign(
                  {},
                  requestContext.request || {},
                  { attestationResponseData: attestation }
                );
              }
              var requestBody = {
                context: requestContext,
                params: params,
                externalVideoId: exactVideoID
              };
              if (selectedTrack && selectedTrack.languageCode) {
                requestBody.languageCode = String(selectedTrack.languageCode);
              }
              if (selectedTrack && isASR(selectedTrack)) {
                requestBody.kind = 'asr';
              }
              var controller = typeof AbortController === 'function' ?
                new AbortController() : null;
              var timeoutMs = Math.max(500, Math.min(4500, remainingBudget() - 700));
              var timeout = controller ? setTimeout(function () {
                controller.abort();
              }, timeoutMs) : null;
              var response = null;
              var body = '';
              try {
                directTranscriptFetchInFlight = true;
                response = await window.fetch(apiURL.href, {
                  method: 'POST',
                  credentials: 'same-origin',
                  headers: headers,
                  body: JSON.stringify(requestBody),
                  signal: controller ? controller.signal : undefined
                });
                latestStatus = Number(response.status || 0);
                body = await response.text();
              } catch (error) {
                var aborted = Boolean(controller && controller.signal.aborted);
                note('direct transcript page=' + page +
                  (aborted ? ' timeout' : ' network failure'));
                return {
                  cues: dedupeCues(allCues),
                  endpointFound: true,
                  status: latestStatus,
                  accessRejected: false,
                  timedOut: aborted,
                  networkFailed: !aborted
                };
              } finally {
                directTranscriptFetchInFlight = false;
                if (timeout) clearTimeout(timeout);
              }

              note('direct transcript page=' + page + ' status=' + latestStatus +
                ' bytes=' + body.length);
              var json = null;
              try { json = JSON.parse(body); } catch (error) {}
              if (!response.ok) {
                var apiStatus = transcriptAPIErrorStatus(json);
                if (apiStatus) note('direct transcript apiError=' + apiStatus.slice(0, 80));
                return {
                  cues: dedupeCues(allCues),
                  endpointFound: true,
                  status: latestStatus,
                  accessRejected: latestStatus === 400 || latestStatus === 401 ||
                    latestStatus === 403,
                  timedOut: false,
                  networkFailed: latestStatus === 0 || latestStatus === 408 ||
                    latestStatus === 429 || latestStatus >= 500
                };
              }
              if (!json || typeof json !== 'object') {
                return {
                  cues: dedupeCues(allCues),
                  endpointFound: true,
                  status: latestStatus,
                  accessRejected: false,
                  timedOut: false,
                  networkFailed: false
                };
              }

              var pageCues = castReaderTranscriptRendererCues(json);
              note('direct transcript page=' + page + ' cues=' + pageCues.length);
              allCues = allCues.concat(pageCues);
              current = castReaderTranscriptSegmentContinuation(json);
            }
            return {
              cues: dedupeCues(allCues),
              endpointFound: true,
              status: latestStatus,
              accessRejected: false,
              timedOut: false,
              networkFailed: false
            };
          }

          function transcriptViaMainWorld() {
            return new Promise(function (resolve) {
              var settled = false;
              var timer = null;
              function finish(value) {
                if (settled) return;
                settled = true;
                if (timer) clearTimeout(timer);
                document.removeEventListener('__cr_yt_transcript_res__', onResult);
                resolve(value);
              }
              function onResult() {
                try {
                  var result = JSON.parse(document.body.dataset.crYtTranscript || '{"cues":[],"log":[]}');
                  finish({
                    cues: Array.isArray(result.cues) ? result.cues : [],
                    log: Array.isArray(result.log) ? result.log : []
                  });
                } catch (error) {
                  finish({ cues: [], log: ['invalid_transcript_result'] });
                }
              }
              document.addEventListener('__cr_yt_transcript_res__', onResult);
              document.dispatchEvent(new Event('__cr_yt_transcript_req__'));
              timer = setTimeout(function () {
                finish({ cues: [], log: ['transcript_timeout'] });
              }, Math.max(100, Math.min(24000, remainingBudget() - 200)));
            });
          }

          function dedupeCues(input) {
            var seen = new Set();
            return (Array.isArray(input) ? input : []).map(function (raw) {
              return {
                text: cleanText(String(raw && raw.text || '').replace(/\n/g, ' ')),
                startMs: Math.max(0, Math.round(Number(raw && raw.startMs || 0))),
                durationMs: Math.max(0, Math.round(Number(raw && raw.durationMs || 0)))
              };
            }).filter(function (cue) {
              if (!cue.text || !Number.isFinite(cue.startMs)) return false;
              var key = String(cue.startMs) + '|' + cue.text;
              if (seen.has(key)) return false;
              seen.add(key);
              return true;
            }).sort(function (left, right) { return left.startMs - right.startMs; });
          }

          function playabilityReason(status) {
            if (!status) return null;
            if (status.reason) return cleanText(status.reason) || null;
            if (Array.isArray(status.messages)) return cleanText(status.messages.join(' ')) || null;
            if (status.errorScreen && status.errorScreen.playerErrorMessageRenderer) {
              var renderer = status.errorScreen.playerErrorMessageRenderer;
              return textFromRuns(renderer.reason) || textFromRuns(renderer.subreason) || null;
            }
            return null;
          }

          function highestResolutionThumbnail(response) {
            response = response || {};
            var details = response.videoDetails || {};
            var microformat = response.microformat &&
              response.microformat.playerMicroformatRenderer || {};
            var candidates = [];
            function append(list) {
              if (!Array.isArray(list)) return;
              list.forEach(function(candidate) {
                if (candidate && candidate.url) candidates.push(candidate);
              });
            }
            append(details.thumbnail && details.thumbnail.thumbnails);
            append(microformat.thumbnail && microformat.thumbnail.thumbnails);
            var ogURL = metaContent('meta[property="og:image"]');
            if (ogURL) candidates.push({ url: ogURL });

            function score(candidate) {
              var width = Number(candidate.width);
              var height = Number(candidate.height);
              if (Number.isFinite(width) && Number.isFinite(height) &&
                  width > 0 && height > 0) return width * height;
              var url = String(candidate.url || '').toLowerCase();
              if (url.indexOf('maxresdefault') >= 0) return 1280 * 720;
              if (url.indexOf('sddefault') >= 0) return 640 * 480;
              if (url.indexOf('hqdefault') >= 0) return 480 * 360;
              if (url.indexOf('mqdefault') >= 0) return 320 * 180;
              return 1;
            }
            candidates.sort(function(lhs, rhs) {
              return score(rhs) - score(lhs);
            });
            return candidates.length ? String(candidates[0].url || '') : '';
          }

          function metadataFrom(response, videoID) {
            response = response || {};
            var details = response.videoDetails || {};
            var microformat = response.microformat &&
              response.microformat.playerMicroformatRenderer || {};
            var status = response.playabilityStatus || {};
            var reason = playabilityReason(status);
            var liveDetails = microformat.liveBroadcastDetails || {};
            var isLive = castReaderIsActiveLiveBroadcast(details, status, liveDetails);

            var title = metaContent('meta[property="og:title"]') ||
              cleanText(details.title) ||
              cleanText(document.title).replace(/\s*-\s*YouTube\s*$/, '') || null;
            var thumbnailURL = highestResolutionThumbnail(response);
            var channel = cleanText(details.author) ||
              metaContent('meta[itemprop="author"]') ||
              metaContent('link[itemprop="name"]') ||
              cleanText((document.querySelector('#owner-name a, ytd-channel-name a') || {}).textContent) || null;

            var duration = Number(details.lengthSeconds);
            if (!Number.isFinite(duration) || duration < 0) {
              var video = document.querySelector('#movie_player video, video');
              duration = video && Number.isFinite(video.duration) ? video.duration : NaN;
            }

            var storyboards = response.storyboards || {};
            var storyboardSpec = storyboards.playerStoryboardSpecRenderer &&
              storyboards.playerStoryboardSpecRenderer.spec ||
              storyboards.playerLiveStoryboardSpecRenderer &&
              storyboards.playerLiveStoryboardSpecRenderer.spec || null;

            return {
              videoId: videoID || playerVideoID(response) || getURLVideoID(),
              title: title,
              thumbnailURL: thumbnailURL || null,
              channel: channel,
              isLive: isLive,
              durationSeconds: Number.isFinite(duration) ? duration : null,
              storyboardSpec: storyboardSpec,
              playability: {
                status: String(status.status || 'UNKNOWN'),
                reason: reason,
                classification: playabilityClassification(status.status, reason, isLive)
              }
            };
          }

          function makeEnvelope(metadata) {
            return {
              schemaVersion: 1,
              requestToken: REQUEST_TOKEN,
              ok: false,
              requestVideoId: EXPECTED_VIDEO_ID || null,
              videoId: metadata.videoId || null,
              title: metadata.title || null,
              thumbnailURL: metadata.thumbnailURL || null,
              channel: metadata.channel || null,
              captionLanguage: null,
              captionTrack: null,
              // null = the track list was never read; [] = the page said there
              // are none. The language picker must not confuse the two.
              availableTracks: null,
              transcriptSource: null,
              cues: [],
              isLive: Boolean(metadata.isLive),
              durationSeconds: metadata.durationSeconds,
              storyboardSpec: metadata.storyboardSpec || null,
              playability: metadata.playability,
              error: null,
              diagnostics: []
            };
          }

          // YouTube can replace its initial LOGIN_REQUIRED response after the
          // media-blocking runtime player reports UNPLAYABLE. Latch and re-read
          // challenge evidence before every terminal path so neither the
          // adapter watchdog nor an exception can turn a known access wall
          // into a misleading timeout/malformed-response message.
          function retainRestrictedAccessEvidence(envelope, selectedResponse, source) {
            var hasBotVerificationChallenge = sawBotVerificationChallenge ||
              hasBotVerificationChallengeEvidence(selectedResponse);
            var hasSignInRequirement = hasBotVerificationChallenge ||
              sawSignInRequirement ||
              hasGenericSignInRequirementEvidence(selectedResponse);
            if (!hasSignInRequirement) return false;
            sawBotVerificationChallenge = sawBotVerificationChallenge ||
              hasBotVerificationChallenge;
            sawSignInRequirement = true;
            envelope.playability = {
              status: 'LOGIN_REQUIRED',
              reason: hasBotVerificationChallenge ?
                'YouTube requires bot verification.' :
                'YouTube requires sign-in.',
              classification: 'sign_in_required'
            };
            envelope.error = {
              code: 'restricted_video',
              message: hasBotVerificationChallenge ?
                'YouTube requires verification before exposing this public transcript.' :
                'This video requires YouTube access that CastReader does not request.'
            };
            note(String(source || 'terminal path') +
              ' retained sign-in/verification evidence');
            return true;
          }

          function terminalPlayabilityError(metadata) {
            var classification = metadata && metadata.playability &&
              metadata.playability.classification || 'unknown';
            if (metadata && metadata.isLive) {
              return { code: 'live_video', message: 'Live videos are not supported.' };
            }
            if (['age_restricted', 'sign_in_required', 'membership_required']
                .indexOf(classification) >= 0) {
              return {
                code: 'restricted_video',
                message: 'This video requires YouTube access that CastReader does not request.'
              };
            }
            if (['geo_restricted', 'removed', 'unavailable', 'private', 'live_offline']
                .indexOf(classification) >= 0) {
              return { code: 'unavailable_video', message: 'This video is unavailable.' };
            }
            return null;
          }

          async function run() {
            if (window.top !== window.self) return;

            var player = await waitForMatchingPlayer();
            var metadata = metadataFrom(player.response, player.playerVideoId);
            var envelope = makeEnvelope(metadata);
            var terminalError = terminalPlayabilityError(metadata);
            var hasBotVerificationChallenge =
              hasBotVerificationChallengeEvidence(player.response);
            var hasSignInRequirement = hasBotVerificationChallenge ||
              hasGenericSignInRequirementEvidence(player.response);
            var botVerificationError = {
              code: 'restricted_video',
              message: 'YouTube requires verification before exposing this public transcript.'
            };
            var mayUsePublicTranscriptDespiteLogin = Boolean(
              player.matched &&
              hasBotVerificationChallenge &&
              initialDataHasTranscriptEndpoint()
            );
            if ((terminalError || hasSignInRequirement) &&
                !mayUsePublicTranscriptDespiteLogin) {
              if (hasSignInRequirement) {
                envelope.playability = {
                  status: 'LOGIN_REQUIRED',
                  reason: 'YouTube requires sign-in or verification.',
                  classification: 'sign_in_required'
                };
                envelope.error = botVerificationError;
              } else {
                envelope.error = terminalError;
              }
              postOnce(envelope);
              return;
            }
            if (!player.matched) {
              envelope.error = hasSignInRequirement ? botVerificationError : {
                  code: 'player_timeout',
                  message: 'YouTube player did not reach the requested video in time.'
                };
              postOnce(envelope);
              return;
            }
            if (player.conclusivelyNoCaptions) {
              envelope.error = {
                code: 'captions_unavailable',
                message: 'No caption tracks were exposed by the completed player.'
              };
              postOnce(envelope);
              return;
            }

            var uiLanguage = normalizedLanguage(PREFERRED_LANGUAGE || document.documentElement.lang ||
              navigator.language || 'en');
            var rankedCandidates = orderedTracks(player.tracks, uiLanguage);
            // Publish the list before any fetch is attempted. A video whose
            // captions cannot be read still tells the picker what it carries,
            // and a later retry can then target a different track directly.
            envelope.availableTracks = availableTrackEnvelopes(rankedCandidates);
            var trackCandidates = pinRequestedTrack(rankedCandidates);
            if (rankedCandidates.length > 0 && trackCandidates.length === 0) {
              // Fail here rather than continuing with an empty candidate set:
              // the transcript-panel and endpoint lanes are not bound to a
              // candidate and would happily return the page's default language.
              envelope.error = {
                code: 'requested_track_unavailable',
                message: 'The requested caption track is not offered for this video.'
              };
              postOnce(envelope);
              return;
            }
            var preferredCandidate = trackCandidates.length > 0 ? trackCandidates[0] : null;
            var successfulCandidate = null;
            var cues = [];
            var sawFetchTimeout = false;
            var sawFetchNetworkFailure = false;
            var sawTranscriptAccessRejected = false;
            var transcriptEndpointWasFound = initialDataHasTranscriptEndpoint();
            var directLane = {
              promise: null,
              settled: false,
              result: null,
              merged: false
            };

            function candidateCues(input, candidate, source) {
              var normalizedCues = dedupeCues(input);
              if (normalizedCues.length === 0) return normalizedCues;
              if (cuesMatchCandidateLanguage(normalizedCues, candidate)) {
                return normalizedCues;
              }
              sawTranscriptAccessRejected = true;
              note(String(source || 'caption response') +
                ' cue language mismatched candidate detected=' +
                String(coarseCueLanguage(normalizedCues) || 'unknown') +
                ' requested=' +
                String(baseLanguage(candidate && candidate.track &&
                  candidate.track.languageCode) || 'unknown'));
              return [];
            }

            function directResultHasCompatibleCues(direct) {
              if (!direct || !Array.isArray(direct.cues)) return false;
              var directCues = dedupeCues(direct.cues);
              return directCues.length > 0 &&
                cuesMatchCandidateLanguage(directCues, preferredCandidate);
            }

            function mergeDirectResult(direct) {
              if (!direct || directLane.merged) return cues.length > 0;
              directLane.merged = true;
              transcriptEndpointWasFound = transcriptEndpointWasFound || direct.endpointFound;
              sawFetchTimeout = sawFetchTimeout || direct.timedOut;
              sawFetchNetworkFailure = sawFetchNetworkFailure || direct.networkFailed;
              sawTranscriptAccessRejected = sawTranscriptAccessRejected || direct.accessRejected;
              if (cues.length === 0) {
                var directCues = candidateCues(
                  direct.cues,
                  preferredCandidate,
                  'direct transcript'
                );
                if (directCues.length > 0) {
                  cues = directCues;
                  envelope.transcriptSource = 'transcript_endpoint';
                  note('direct transcript lane won cues=' + cues.length);
                }
              }
              return cues.length > 0;
            }

            function adoptDirectIfSettled() {
              return directLane.settled && mergeDirectResult(directLane.result);
            }

            // The direct transcript endpoint uses its own correlated window.fetch
            // path, so it can safely overlap proof/module hydration. Keep every
            // vendored timedtext request strictly serial because that bridge has
            // no per-request correlation token.
            // `ytInitialData` commonly hydrates shortly after the matching
            // player response. Start the correlated lane now even when the
            // endpoint is not in the first synchronous snapshot; the lane
            // only polls locally until an endpoint exists and sends no request
            // when it remains absent. This overlaps that wait with proof and
            // official-caption hydration instead of paying it serially later.
            note('starting direct transcript lane endpointInitially=' +
              transcriptEndpointWasFound);
            directLane.promise = directTranscriptViaInitialData(
              preferredCandidate && preferredCandidate.track
            ).catch(function () {
              return {
                cues: [], endpointFound: transcriptEndpointWasFound ||
                  initialDataHasTranscriptEndpoint(),
                status: 0,
                accessRejected: false,
                timedOut: false,
                networkFailed: true
              };
            }).then(function (direct) {
              directLane.result = direct;
              directLane.settled = true;
              return direct;
            });
            note('uiLanguage=' + uiLanguage + ' orderedTracks=' +
              trackCandidates.map(function (candidate) {
                return candidate.index + ':' +
                  languageAlias(candidate.track && candidate.track.languageCode) + ':' +
                  (isASR(candidate.track) ? 'asr' : 'manual');
              }).join(','));

            var subtitleProofRequired = trackCandidates.some(function (candidate) {
              return candidate.track &&
                castReaderCaptionTrackRequiresProof(candidate.track.baseUrl);
            });
            if (!capturedSubtitleProof && trackCandidates.length > 0) {
              await waitForSubtitleProof(Math.min(
                subtitleProofRequired ? 500 : 700,
                Math.max(50, remainingBudget() - 9000)
              ));
            }
            if (!capturedSubtitleProof && trackCandidates.length > 0) {
              var officialProof = await waitForOfficialPlayerSubtitleProof(
                Math.min(200, Math.max(50, remainingBudget() - 9000))
              );
              if (officialProof) publishSubtitleProof(officialProof);
            }
            note('subtitle proof required=' + subtitleProofRequired +
              ' captured=' + Boolean(capturedSubtitleProof) +
              ' playerMethod=' + Boolean(officialPlayerSubtitleProof()));

            var officialCaption = null;
            adoptDirectIfSettled();
            if (cues.length === 0 && subtitleProofRequired && trackCandidates.length > 0 &&
                remainingBudget() > 19000) {
              officialCaption = await waitForOfficialCaptionCandidate(
                trackCandidates,
                Math.min(4500, Math.max(100, remainingBudget() - 18500)),
                function () {
                  return directLane.settled &&
                    directResultHasCompatibleCues(directLane.result);
                }
              );
              adoptDirectIfSettled();
              if (officialCaption.track && !officialCaption.url) {
                var capturedOfficialURL = officialTimedtextURLForCandidate(
                  latestOfficialTimedtextURL,
                  officialCaption.candidate
                );
                var resourceOfficialURL = capturedOfficialURL ? null :
                  officialTimedtextResourceURL(officialCaption.candidate);
                officialCaption.url = capturedOfficialURL || resourceOfficialURL;
                if (officialCaption.url) {
                  note('official decorated URL recovered source=' +
                    (capturedOfficialURL ? 'capture' : 'resource'));
                }
              }
              note('official caption tracks=' +
                Number(officialCaption.officialTrackCount || 0) +
                ' matched=' + Boolean(officialCaption.track) +
                ' decorated=' + Boolean(officialCaption.url) +
                ' proofReady=' + Boolean(officialCaption.proofReady));
            }

            var timedtextRequests = 0;
            var abandonTimedtext = false;
            var formatNames = officialCaption && officialCaption.url ?
              ['json3', 'srv3', 'base_url'] : ['base_url', 'json3', 'srv3'];
            adoptDirectIfSettled();
            timedtextFormats:
            for (var formatIndex = 0; formatIndex < formatNames.length; formatIndex += 1) {
              for (var orderIndex = 0; orderIndex < trackCandidates.length; orderIndex += 1) {
                if (cues.length > 0 || adoptDirectIfSettled()) {
                  break timedtextFormats;
                }
                var candidate = trackCandidates[orderIndex];
                var candidateTrack = candidate.track;
                if (!candidateTrack || !candidateTrack.baseUrl) continue;
                var hasTrustedOfficialURL = Boolean(
                  officialCaption && officialCaption.url
                );
                if (timedtextRequests > 0 &&
                    remainingBudget() < (hasTrustedOfficialURL ? 12000 : 25500)) {
                  note('preserving transcript fallback budget after ' +
                    timedtextRequests + ' timedtext requests');
                  break timedtextFormats;
                }
                var officialCandidateMatches = Boolean(
                  officialCaption && officialCaption.url &&
                  officialCaption.candidate &&
                  officialCaption.candidate.index === candidate.index
                );
                var candidateBaseURL = officialCandidateMatches ?
                  officialCaption.url : candidateTrack.baseUrl;
                if (castReaderCaptionTrackRequiresProof(candidateBaseURL) &&
                    !capturedSubtitleProof && !officialCandidateMatches) {
                  note('skipping proof-bound raw timedtext track=' +
                    candidate.index + ' format=' + formatNames[formatIndex]);
                  continue;
                }
                var candidateURL = castReaderCaptionURLWithProof(
                  candidateBaseURL,
                  formatNames[formatIndex],
                  // A URL returned by the official captions module already
                  // contains the exact PO token/client tuple it generated.
                  // Preserve that tuple; only raw player-response URLs should
                  // be decorated from the separately captured proof.
                  officialCandidateMatches ? null : capturedSubtitleProof
                );
                timedtextRequests += 1;
                var result = await fetchViaMainWorld(candidateURL);
                note('timedtext track=' + candidate.index + ' format=' +
                  formatNames[formatIndex] + ' status=' + result.status +
                  ' bytes=' + result.text.length +
                  ' official=' + officialCandidateMatches);
                var fetchError = String(result.error || '').toLowerCase();
                if (fetchError.indexOf('timeout') >= 0) {
                  sawFetchTimeout = true;
                  abandonTimedtext = true;
                  // The vendored bridge has no per-request correlation token.
                  // Its late response could otherwise satisfy the next
                  // candidate's listener, so switch protocols immediately.
                  note('abandoning timedtext candidates after uncorrelated fetch timeout');
                  adoptDirectIfSettled();
                  break timedtextFormats;
                } else if (!result.ok && result.status !== 404 && result.status !== 410) {
                  sawFetchNetworkFailure = true;
                }
                if (!result.ok || !result.text) {
                  if (adoptDirectIfSettled()) break timedtextFormats;
                  continue;
                }
                cues = candidateCues(
                  parseTimedtextResponse(result.text),
                  candidate,
                  'timedtext'
                );
                if (cues.length > 0) {
                  successfulCandidate = candidate;
                  envelope.transcriptSource = formatNames[formatIndex];
                  break timedtextFormats;
                }
                if (adoptDirectIfSettled()) break timedtextFormats;
              }
              if (abandonTimedtext) break;
            }

            adoptDirectIfSettled();
            if (cues.length === 0 && officialCaption &&
                officialCaption.track && remainingBudget() > 9000) {
              var queuedOfficialCaptures = officialTimedtextCaptureQueue.length;
              var officialActivation = activateOfficialCaptionTrack(
                officialCaption
              );
              note('official caption activation requested=' +
                Boolean(officialActivation.requested) +
                ' beforeSelected=' + Boolean(officialActivation.beforeSelected) +
                ' beforeOn=' + String(officialActivation.beforeOn) +
                ' changed=' + Boolean(officialActivation.trackChanged) +
                ' toggled=' + Boolean(officialActivation.toggledOn) +
                ' selected=' + Boolean(officialActivation.selected) +
                ' on=' + String(officialActivation.subtitlesOn) +
                ' nativeMatched=' + Boolean(officialActivation.nativeMatched) +
                ' nativeChanged=' + Boolean(officialActivation.nativeChanged) +
                ' reloadRequested=' + Boolean(officialActivation.reloadRequested) +
                ' queued=' + queuedOfficialCaptures);
              var officialWaitMs = Math.min(
                4500,
                Math.max(250, remainingBudget() - 7600)
              );
              var officialDeadline = Date.now() + officialWaitMs;
              var attemptedNativeURLs = new Set();
              var stableNativeKey = null;
              var stableNativeCueCount = -1;
              var stableNativeSince = 0;
              var latestNativeSnapshot = officialNativeCaptionSnapshot(
                officialCaption.candidate
              );
              while (cues.length === 0 && Date.now() < officialDeadline) {
                if (adoptDirectIfSettled()) break;
                latestNativeSnapshot = officialNativeCaptionSnapshot(
                  officialCaption.candidate
                );

                // Prefer the complete response behind a strictly validated
                // native <track>. TextTrack.cues can be populated gradually.
                var nativeURL = latestNativeSnapshot.url;
                if (nativeURL && !attemptedNativeURLs.has(nativeURL)) {
                  attemptedNativeURLs.add(nativeURL);
                  var nativeResult = await fetchViaMainWorld(nativeURL);
                  note('official native track fetch status=' +
                    Number(nativeResult.status || 0) +
                    ' bytes=' + String(nativeResult.text || '').length);
                  cues = candidateCues(
                    parseTimedtextResponse(nativeResult.text || ''),
                    officialCaption.candidate,
                    'official native track URL'
                  );
                  if (cues.length > 0) {
                    successfulCandidate = officialCaption.candidate;
                    envelope.transcriptSource = 'official_native_track_url';
                    break;
                  }
                  if (!nativeResult.ok && nativeResult.status !== 0 &&
                      nativeResult.status !== 404 && nativeResult.status !== 410) {
                    sawFetchNetworkFailure = true;
                  }
                  if (adoptDirectIfSettled()) break;
                }

                if (latestNativeSnapshot.cues.length > 0) {
                  var snapshotKey = String(latestNativeSnapshot.trackKey || '');
                  var snapshotCount = Number(latestNativeSnapshot.cueCount || 0);
                  if (snapshotKey && snapshotKey === stableNativeKey &&
                      snapshotCount === stableNativeCueCount) {
                    if (stableNativeSince === 0) stableNativeSince = Date.now();
                  } else {
                    stableNativeKey = snapshotKey;
                    stableNativeCueCount = snapshotCount;
                    stableNativeSince = Date.now();
                  }
                  var nativeCuesSettled = Boolean(latestNativeSnapshot.ready) ||
                    Date.now() - stableNativeSince >= 200;
                  if (nativeCuesSettled) {
                    cues = candidateCues(
                      latestNativeSnapshot.cues,
                      officialCaption.candidate,
                      'official native TextTrack'
                    );
                    if (cues.length > 0) {
                      successfulCandidate = officialCaption.candidate;
                      envelope.transcriptSource = 'official_native_text_track';
                      break;
                    }
                  }
                } else {
                  stableNativeKey = null;
                  stableNativeCueCount = -1;
                  stableNativeSince = 0;
                }

                var captureWaitMs = Math.min(
                  250,
                  Math.max(50, officialDeadline - Date.now())
                );
                var officialCapture = await waitForOfficialTimedtextCapture(
                  captureWaitMs
                );
                if (!officialCapture) {
                  if (adoptDirectIfSettled()) break;
                  continue;
                }
                note('official timedtext capture status=' +
                  Number(officialCapture.status || 0) +
                  ' bytes=' + Number(officialCapture.bytes || 0));
                var capturedOfficialURL = officialTimedtextURLForCandidate(
                  officialCapture.url,
                  officialCaption.candidate,
                  false
                );
                var capturedOfficialCues = capturedOfficialURL ? candidateCues(
                  parseTimedtextResponse(officialCapture.text || ''),
                  officialCaption.candidate,
                  'official timedtext capture'
                ) : [];
                if (officialCapture.text && !capturedOfficialURL) {
                  sawTranscriptAccessRejected = true;
                  note('official timedtext capture rejected translated or mismatched URL');
                }
                if (capturedOfficialCues.length > 0) {
                  cues = capturedOfficialCues;
                  successfulCandidate = officialCaption.candidate;
                  envelope.transcriptSource = 'official_timedtext_capture';
                  break;
                }
                // Aborted, empty and stale responses are not terminal. Keep
                // consuming until the request triggered by select/toggle/reload
                // completes or the shared deadline expires.
                if (!officialCapture.ok && officialCapture.status !== 0 &&
                    officialCapture.status !== 404 &&
                    officialCapture.status !== 410) {
                  sawFetchNetworkFailure = true;
                }
                if (adoptDirectIfSettled()) break;
              }
              note('official native tracks=' +
                Number(latestNativeSnapshot.trackCount || 0) +
                ' showing=' + Number(latestNativeSnapshot.showingCount || 0) +
                ' cues=' + Number(latestNativeSnapshot.cueCount || 0) +
                ' decoratedURL=' + Boolean(latestNativeSnapshot.url));
              if (cues.length === 0) note('official caption sources exhausted');
            }

            // Never enter the uncorrelated transcript bridge while the
            // correlated direct fetch is still alive. Apart from losing a
            // direct result that settles during the bridge, the bridge's
            // global get_transcript listener could consume that response.
            // The direct lane already shares the adapter deadline and aborts
            // each request against the remaining budget, so awaiting an
            // already-started lane here is bounded.
            if (cues.length === 0 && directLane.promise) {
              note('awaiting direct transcript lane before bridge');
              mergeDirectResult(await directLane.promise);
            }

            if (cues.length === 0 && !directLane.promise &&
                remainingBudget() > 7200) {
              note('timedtext unavailable; requesting direct transcript endpoint');
              var direct = await directTranscriptViaInitialData(
                preferredCandidate && preferredCandidate.track
              );
              directLane.result = direct;
              directLane.settled = true;
              mergeDirectResult(direct);
            }

            if (cues.length === 0) {
              note('direct transcript unavailable; requesting transcript bridge');
              clearTranscriptFetchCaptures();
              var fallbackPromise = transcriptViaMainWorld();
              var firstFallback = await Promise.race([
                fallbackPromise.then(function (value) {
                  return { kind: 'bridge', value: value };
                }),
                waitForTranscriptFetchCapture(Math.min(6500, remainingBudget() - 300))
                  .then(function (value) {
                    return { kind: 'capture', value: value };
                  })
              ]);
              var fallback = null;
              if (firstFallback.kind === 'capture' && firstFallback.value) {
                var capture = firstFallback.value;
                note('transcript fetch capture status=' + capture.status +
                  ' bytes=' + capture.bytes);
                var capturedCues = dedupeCues(
                  castReaderTranscriptRendererCues(capture.json)
                );
                note('transcript fetch capture cues=' + capturedCues.length);
                capturedCues = candidateCues(
                  capturedCues,
                  preferredCandidate,
                  'transcript fetch capture'
                );
                if (capturedCues.length > 0) {
                  cues = capturedCues;
                  envelope.transcriptSource = 'transcript_fetch_capture';
                } else {
                  sawTranscriptAccessRejected = sawTranscriptAccessRejected ||
                    capture.status === 400 || capture.status === 401 ||
                    capture.status === 403;
                  sawFetchNetworkFailure = sawFetchNetworkFailure ||
                    capture.status === 0 || capture.status === 408 ||
                    capture.status === 429 || capture.status >= 500;
                  fallback = await fallbackPromise;
                }
              } else if (firstFallback.kind === 'bridge') {
                fallback = firstFallback.value;
              } else {
                fallback = await fallbackPromise;
              }

              if (fallback) {
              fallback.log.slice(0, 30).forEach(function (line) { note('bridge: ' + line); });
              if (fallback.log.some(function (line) {
                return String(line || '').toLowerCase().indexOf('timeout') >= 0;
              })) {
                sawFetchTimeout = true;
              } else if (fallback.log.some(function (line) {
                return /network|fetch[^ ]*fail|typeerror/i.test(String(line || ''));
              })) {
                sawFetchNetworkFailure = true;
              }
              // The bridge has now opened/loaded the transcript panel. Prefer
              // its structured timestamp/text descendants over the bridge's
              // concatenated innerText fallback, which can merge `0:18`,
              // `18 seconds` and the actual caption into one zero-time cue.
              var structuredPanelCues = dedupeCues(
                castReaderTranscriptPanelCues(document)
              );
              note('structured panel DOM cues=' + structuredPanelCues.length);
              cues = candidateCues(
                structuredPanelCues.length > 0 ? structuredPanelCues :
                  fallback.cues,
                preferredCandidate,
                'transcript bridge'
              );
              if (cues.length > 0) envelope.transcriptSource = 'transcript_bridge';
              }
              // Defensive only: the direct lane is awaited before entering
              // this block. Keep a final adoption point so future bridge
              // changes cannot reintroduce the late-result loss.
              adoptDirectIfSettled();
            }

            if (cues.length > 0) {
              var identityCandidate = successfulCandidate || preferredCandidate;
              if (identityCandidate) {
                envelope.captionTrack = trackEnvelope(
                  identityCandidate.track,
                  identityCandidate.index
                );
                envelope.captionLanguage = identityCandidate.track.languageCode || null;
              }
            }

            envelope.cues = cues;
            envelope.ok = cues.length > 0;
            if (envelope.ok) {
              // Keep this document usable for further languages. Native decides
              // how long to hold it and tears it down on background, memory
              // pressure, idle timeout or any unexpected navigation.
              installWarmTrackExtractor({
                tracks: player.tracks,
                metadata: metadata,
                availableTracks: envelope.availableTracks
              });
            }
            if (envelope.ok && mayUsePublicTranscriptDespiteLogin) {
              // The player was challenged, but YouTube itself supplied the
              // expected video's public transcript through its page UI.
              note('public transcript succeeded despite generic login challenge');
              envelope.playability = {
                status: 'OK',
                reason: null,
                classification: 'playable'
              };
              envelope.error = null;
            } else if (!envelope.ok && mayUsePublicTranscriptDespiteLogin) {
              // Do not turn a known access challenge into a misleading timeout
              // merely because its transcript continuation could not complete.
              envelope.playability = {
                status: 'LOGIN_REQUIRED',
                reason: 'YouTube requires bot verification.',
                classification: 'sign_in_required'
              };
              envelope.error = botVerificationError;
            } else if (!envelope.ok) {
              transcriptEndpointWasFound = transcriptEndpointWasFound ||
                initialDataHasTranscriptEndpoint();
              // A genuine no-caption result has already returned above through
              // `player.conclusivelyNoCaptions`, which requires a completed,
              // exact-video and repeatedly stable evidence set. Reaching this
              // exhaustion branch means extraction failed without that proof;
              // an empty track snapshot here may simply be a late page,
              // consent/login interstitial or blocked transcript endpoint.
              var failureCode = sawTranscriptAccessRejected ?
                'transcript_access_rejected' :
                (sawFetchTimeout ? 'fetch_timeout' :
                 (sawFetchNetworkFailure ? 'fetch_failed' :
                  'transcript_access_failed'));
              envelope.error = {
                code: failureCode,
                message: sawTranscriptAccessRejected ?
                   'YouTube exposed captions but rejected transcript access for this session.' :
                   (sawFetchTimeout ? 'Caption requests exceeded the extraction budget.' :
                    (sawFetchNetworkFailure ? 'Caption requests failed because of the network.' :
                     'YouTube exposed captions but no transcript response was readable.'))
              };
            }
            postOnce(envelope);
          }

          async function runWhenBodyIsReady() {
            while (!document.body && remainingBudget() > 250) await sleep(25);
            if (!document.body) throw new Error('missing_document_body');
            // The bridge bootstrap is registered before this adapter and uses
            // the same body-ready signal. Yield once so its event hooks win.
            await sleep(25);
            return run();
          }

          runWhenBodyIsReady().catch(function (error) {
            var response = readPlayerResponse();
            var envelope = makeEnvelope(metadataFrom(
              response,
              playerVideoID(response) || initialDataVideoID() || getURLVideoID()
            ));
            if (!retainRestrictedAccessEvidence(envelope, response, 'adapter exception')) {
              envelope.error = {
                code: 'adapter_exception',
                message: cleanText(error && error.message || error || 'Unknown extraction error')
              };
            }
            note('exception=' + cleanText(
              error && error.message || error || 'Unknown extraction error'
            ));
            postOnce(envelope);
          });
        })();
        """#
    }

    /// Deterministic hook for WKWebView fixtures. The vendored bridge already
    /// recognizes `crYtTracksOverride`; this helper only writes that supported
    /// contract and an optional player response, without shipping test branches
    /// in the production adapter.
    static func fixtureBootstrap(
        videoID: String,
        tracksJSON: String,
        playerResponseJSON: String = "{}"
    ) -> String {
        let videoIDLiteral = javaScriptStringLiteral(videoID)
        let tracksJSONLiteral = javaScriptStringLiteral(tracksJSON)
        let playerResponseJSONLiteral = javaScriptStringLiteral(playerResponseJSON)
        return #"""
        (function () {
          var videoID = \#(videoIDLiteral);
          var tracksJSON = \#(tracksJSONLiteral);
          var playerResponseJSON = \#(playerResponseJSONLiteral);
          function install() {
            var tracks = [];
            var response = {};
            try { tracks = JSON.parse(tracksJSON); } catch (error) {}
            try { response = JSON.parse(playerResponseJSON); } catch (error) {}
            if (!response.videoDetails) response.videoDetails = {};
            response.videoDetails.videoId = videoID;
            window.ytInitialPlayerResponse = response;
            document.body.dataset.crYtTracksOverride = JSON.stringify({
              videoId: videoID,
              tracks: Array.isArray(tracks) ? tracks : []
            });
          }
          if (document.body) install();
          else document.addEventListener('DOMContentLoaded', install, { once: true });
        })();
        """#
    }

    /// Also used by the native warm-session invoker, which builds a small call
    /// expression against the page's follow-up entry point.
    static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
