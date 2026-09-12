import XCTest
@testable import CastReader

final class KindlePageFlipProbeTests: XCTestCase {
    func testRunKeepsPositionChangesAndObserverFailuresAfterLaterPolls() {
        let response = KindlePageFlipProbe.PollResponse(ok: true, runID: "probe-run-1234", active: true, seq: 9,
            snapshot: .init(atMs: 1, mode: .pageFlipConfirmed, frame: .init(),
                reader: .init(pageKey: "p-a", navigationSeq: 1, initialPageKey: "p-a", initialNavigationSeq: 1, positionStable: true),
                root: nil, cells: [], summary: completeSummary()))
        var moved = KindlePageFlipProbe.RunEvidence()
        moved.accept(.init(ok: true, runID: response.runID, active: true, seq: 2,
            events: [.init(seq: 2, atMs: 1, kind: .navigationChanged)]), afterSeq: 0)
        moved.accept(response, afterSeq: 2)
        XCTAssertEqual(moved.verdict(for: response), .positionUnsafe)
        var failed = KindlePageFlipProbe.RunEvidence()
        failed.accept(.init(ok: true, runID: response.runID, active: true, seq: 2,
            events: [.init(seq: 2, atMs: 1, kind: .error)]), afterSeq: 0)
        failed.accept(response, afterSeq: 2)
        XCTAssertEqual(failed.verdict(for: response), .inconclusive)
        var overflowed = KindlePageFlipProbe.RunEvidence()
        overflowed.accept(.init(ok: true, runID: response.runID, active: true, seq: 8, droppedBeforeSeq: 4), afterSeq: 3)
        overflowed.accept(response, afterSeq: 8)
        XCTAssertEqual(overflowed.verdict(for: response), .inconclusive)
    }

    func testDecodesForwardCompatibleEvidenceWithoutLosingUnknownEnums() throws {
        let json = #"""
        {
          "ok": true,
          "version": 1,
          "runID": "probe-run-1234",
          "active": true,
          "seq": 9,
          "droppedBeforeSeq": 0,
          "hasMore": false,
          "snapshot": {
            "atMs": 1000,
            "mode": "futurePageFlipMode",
            "frame": {
              "sameOrigin": 1,
              "crossOrigin": 0,
              "openShadowRoots": 2,
              "closedShadowSuspected": false
            },
            "reader": {
              "pageKey": "p-deadbeef",
              "navigationSeq": 4,
              "initialPageKey": "p-deadbeef",
              "initialNavigationSeq": 4,
              "positionStable": true
            },
            "root": null,
            "cells": [{
              "nodeKey": "n-2",
              "ordinal": 1,
              "setSize": 1,
              "location": "20",
              "startPosition": "20",
              "endPosition": "29",
              "pageNumber": "IV",
              "norm": { "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4 },
              "image": {
                "kind": "webgpuSurface",
                "scheme": "filesystem",
                "blobKey": null,
                "natural": { "width": 1200, "height": 1800 },
                "rendered": { "width": 120, "height": 180 },
                "complete": true,
                "byteSize": null
              }
            }],
            "summary": {
              "pageFlipCandidateSeen": true,
              "pageFlipConfirmed": false,
              "sawStart": false,
              "sawEnd": false,
              "observedCellCount": 1,
              "ordinalCount": 1,
              "firstOrdinal": 1,
              "lastOrdinal": 1,
              "declaredTotal": 1,
              "ordinalGapCount": 0,
              "directImageCount": 1,
              "directHighResolutionImageCount": 1,
              "previewHighResolutionSeen": false,
              "networkImageCount": 0,
              "blobCount": 0
            }
          },
          "events": [{
            "seq": 9,
            "atMs": 999,
            "kind": "futureRendererEvent",
            "payload": { "count": 3, "nested": [true, null, "safe"] }
          }],
          "error": null
        }
        """#

        let response = try JSONDecoder().decode(
            KindlePageFlipProbe.PollResponse.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(response.snapshot?.mode, .unknown("futurePageFlipMode"))
        XCTAssertEqual(response.events.first?.kind, .unknown("futureRendererEvent"))
        XCTAssertEqual(response.snapshot?.cells.first?.image?.kind, .unknown("webgpuSurface"))
        XCTAssertEqual(response.snapshot?.cells.first?.image?.scheme, .unknown("filesystem"))
        XCTAssertEqual(try JSONDecoder().decode(
            KindlePageFlipProbe.Verdict.self,
            from: Data(#""futureVerdict""#.utf8)
        ), .unknown("futureVerdict"))
    }

    func testCursorDetectsRingOverflowAtExactBoundary() {
        let response = KindlePageFlipProbe.PollResponse(
            ok: true,
            runID: "probe-run-1234",
            active: true,
            seq: 1_540,
            droppedBeforeSeq: 40,
            hasMore: true
        )

        XCTAssertTrue(response.overflowed(afterSeq: 0))
        XCTAssertTrue(response.overflowed(afterSeq: 39))
        XCTAssertFalse(response.overflowed(afterSeq: 40))
        XCTAssertFalse(response.overflowed(afterSeq: 1_500))
        XCTAssertEqual(KindleWebScripts.pageFlipProbeRingCapacity, 1_500)
        XCTAssertEqual(KindleWebScripts.pageFlipProbeDrainLimit, 100)
    }

    func testVerdictEvaluatorRequiresCoverageAssetsAndPositionSafety() {
        XCTAssertEqual(verdict(summary: .init()), .notObserved)
        XCTAssertEqual(
            verdict(
                frame: .init(closedShadowSuspected: true),
                summary: .init(pageFlipCandidateSeen: true)
            ),
            .blockedFrameOrShadow
        )
        XCTAssertEqual(
            verdict(positionStable: false, summary: completeSummary()),
            .positionUnsafe
        )
        XCTAssertEqual(
            verdict(positionStable: true, summary: completeSummary()),
            .enumerable
        )
        XCTAssertEqual(
            verdict(
                positionStable: true,
                summary: completeSummary(previewHighResolutionSeen: true)
            ),
            .previewRenderRequired
        )
        XCTAssertEqual(
            verdict(
                positionStable: true,
                summary: completeSummary(
                    directImageCount: 3,
                    directHighResolutionImageCount: 3
                )
            ),
            .thumbnailDirectCandidate
        )

        var incomplete = completeSummary()
        incomplete = .init(
            pageFlipCandidateSeen: incomplete.pageFlipCandidateSeen,
            pageFlipConfirmed: incomplete.pageFlipConfirmed,
            sawStart: incomplete.sawStart,
            sawEnd: false,
            observedCellCount: incomplete.observedCellCount,
            ordinalCount: incomplete.ordinalCount,
            firstOrdinal: incomplete.firstOrdinal,
            lastOrdinal: incomplete.lastOrdinal,
            declaredTotal: incomplete.declaredTotal,
            ordinalGapCount: incomplete.ordinalGapCount,
            directImageCount: incomplete.directImageCount,
            directHighResolutionImageCount: incomplete.directHighResolutionImageCount,
            previewHighResolutionSeen: incomplete.previewHighResolutionSeen,
            networkImageCount: incomplete.networkImageCount,
            blobCount: incomplete.blobCount
        )
        XCTAssertEqual(verdict(positionStable: true, summary: incomplete), .inconclusive)
    }

    func testProbeBootstrapHasRestrictedManualOnlySurface() {
        let source = KindleWebScripts.pageFlipProbeBootstrap
        XCTAssertTrue(source.contains("__crKindlePFProbeStart"))
        XCTAssertTrue(source.contains("__crKindlePFProbePoll"))
        XCTAssertTrue(source.contains("__crKindlePFProbeStop"))
        XCTAssertTrue(source.contains("__crAllowedKindleHosts"))
        XCTAssertTrue(source.contains("MAX_EVENTS = 1500"))
        XCTAssertTrue(source.contains("MAX_DRAIN = 100"))

        let forbiddenInteractionFragments = [
            ".click(",
            "scrollIntoView(",
            ".scrollTo(",
            "window.scroll(",
            "dispatchEvent(",
            "MouseEvent(",
            "KeyboardEvent(",
            ".focus(",
        ]
        forbiddenInteractionFragments.forEach {
            XCTAssertFalse(source.contains($0), "probe must not contain active interaction: \($0)")
        }

        let forbiddenContentFragments = [
            "innerText",
            "textContent",
            "innerHTML",
            "outerHTML",
            "FileReader",
            ".arrayBuffer(",
            ".readAs",
        ]
        forbiddenContentFragments.forEach {
            XCTAssertFalse(source.contains($0), "probe must not export reader content: \($0)")
        }
    }

    private func verdict(
        positionStable: Bool? = nil,
        frame: KindlePageFlipProbe.FrameEvidence = .init(),
        summary: KindlePageFlipProbe.Summary
    ) -> KindlePageFlipProbe.Verdict {
        let snapshot = KindlePageFlipProbe.Snapshot(
            atMs: 1,
            mode: summary.pageFlipConfirmed ? .pageFlipConfirmed : .reader,
            frame: frame,
            reader: .init(
                pageKey: "p-a",
                navigationSeq: 1,
                initialPageKey: "p-a",
                initialNavigationSeq: 1,
                positionStable: positionStable
            ),
            root: nil,
            cells: [],
            summary: summary
        )
        return KindlePageFlipProbe.evaluate(.init(
            ok: true,
            runID: "probe-run-1234",
            active: false,
            seq: 1,
            snapshot: snapshot
        ))
    }

    private func completeSummary(
        directImageCount: Int = 0,
        directHighResolutionImageCount: Int = 0,
        previewHighResolutionSeen: Bool = false
    ) -> KindlePageFlipProbe.Summary {
        .init(
            pageFlipCandidateSeen: true,
            pageFlipConfirmed: true,
            sawStart: true,
            sawEnd: true,
            observedCellCount: 3,
            ordinalCount: 3,
            firstOrdinal: 1,
            lastOrdinal: 3,
            declaredTotal: 3,
            ordinalGapCount: 0,
            directImageCount: directImageCount,
            directHighResolutionImageCount: directHighResolutionImageCount,
            previewHighResolutionSeen: previewHighResolutionSeen
        )
    }
}
