//
//  OfflineReadAloudViewModelTests.swift
//  CastReaderTests
//
//  The offline package is deliberately all-or-nothing. These tests keep the
//  player from falling through to cloud TTS when a persisted package is
//  incomplete or points at audio owned by another paragraph.
//

import XCTest
@testable import CastReader

final class OfflineReadAloudViewModelTests: XCTestCase {

    @MainActor
    func testKindleOfflineSuccessorCaptureIsBestEffortButCancellationPropagates() async throws {
        enum FixtureError: Error { case unavailable }

        let currentPageOnly: [Int] = try await KindleOfflinePageGroupCaptureContract
            .bestEffortSuccessors {
                throw FixtureError.unavailable
            }
        XCTAssertEqual(currentPageOnly, [])

        do {
            let _: [Int] = try await KindleOfflinePageGroupCaptureContract
                .bestEffortSuccessors {
                    throw CancellationError()
                }
            XCTFail("Cancellation must abort the complete offline download")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testKindleOfflineDownloadRequiresBothProAndCurrentAccountBoundary() {
        XCTAssertTrue(KindleOfflineDownloadAccessContract.canContinue(
            isPro: true,
            isAccountBoundaryCurrent: true
        ))
        XCTAssertFalse(KindleOfflineDownloadAccessContract.canContinue(
            isPro: false,
            isAccountBoundaryCurrent: true
        ))
        XCTAssertFalse(KindleOfflineDownloadAccessContract.canContinue(
            isPro: true,
            isAccountBoundaryCurrent: false
        ))
    }

    func testReachabilityFallbackStopsAfterLiveReaderButTransportFailureRemainsAuthoritative() {
        XCTAssertTrue(KindleOfflineFallbackContract.shouldAttempt(
            trigger: .networkPathUnavailable,
            hasEstablishedLiveReader: false
        ))
        XCTAssertFalse(KindleOfflineFallbackContract.shouldAttempt(
            trigger: .networkPathUnavailable,
            hasEstablishedLiveReader: true
        ))
        XCTAssertTrue(KindleOfflineFallbackContract.shouldAttempt(
            trigger: .transportFailure,
            hasEstablishedLiveReader: false
        ))
        XCTAssertTrue(KindleOfflineFallbackContract.shouldAttempt(
            trigger: .transportFailure,
            hasEstablishedLiveReader: true
        ))
    }

    @MainActor
    func testConfigureOfflinePlaybackAcceptsEveryReadableParagraphOnly() {
        let vm = makeViewModelWithNonReadableGaps()
        let secondForParagraphOne = makeSegment(
            paragraphIndex: 1,
            segmentIndex: 1,
            marker: 0x12
        )
        let firstForParagraphOne = makeSegment(
            paragraphIndex: 1,
            segmentIndex: 0,
            marker: 0x11
        )
        let paragraphThree = makeSegment(
            paragraphIndex: 3,
            segmentIndex: 0,
            marker: 0x31
        )

        let accepted = vm.configureOfflinePlayback(
            segmentsByParagraph: [
                1: [secondForParagraphOne, firstForParagraphOne],
                3: [paragraphThree],
            ],
            voiceID: "  af_heart  "
        )

        XCTAssertTrue(accepted)
        XCTAssertTrue(vm.isOfflinePlayback)
        XCTAssertEqual(vm.dbgReadableIndices, [1, 3])
        XCTAssertEqual(vm.dbgSegments(for: 1).map(\.segmentIndex), [0, 1])
        XCTAssertEqual(vm.dbgSegments(for: 1).map(\.audioData), [
            firstForParagraphOne.audioData,
            secondForParagraphOne.audioData,
        ])
        XCTAssertEqual(vm.dbgSegments(for: 3).map(\.audioData), [paragraphThree.audioData])
    }

    @MainActor
    func testConfigureOfflinePlaybackRejectsMissingOrEmptyReadableParagraphs() {
        let missingVM = makeTwoParagraphViewModel()
        XCTAssertFalse(missingVM.configureOfflinePlayback(
            segmentsByParagraph: [
                0: [makeSegment(paragraphIndex: 0, marker: 0x10)],
            ],
            voiceID: "af_heart"
        ))
        XCTAssertFalse(missingVM.isOfflinePlayback)

        let emptyVM = makeTwoParagraphViewModel()
        XCTAssertFalse(emptyVM.configureOfflinePlayback(
            segmentsByParagraph: [
                0: [makeSegment(paragraphIndex: 0, marker: 0x10)],
                1: [],
            ],
            voiceID: "af_heart"
        ))
        XCTAssertFalse(emptyVM.isOfflinePlayback)
    }

    @MainActor
    func testConfigureOfflinePlaybackRejectsCrossParagraphAudio() {
        let vm = makeTwoParagraphViewModel()

        XCTAssertFalse(vm.configureOfflinePlayback(
            segmentsByParagraph: [
                0: [makeSegment(paragraphIndex: 1, marker: 0x10)],
                1: [makeSegment(paragraphIndex: 1, marker: 0x20)],
            ],
            voiceID: "af_heart"
        ))
        XCTAssertFalse(vm.isOfflinePlayback)
        XCTAssertTrue(vm.dbgSegments(for: 0).isEmpty)
        XCTAssertTrue(vm.dbgSegments(for: 1).isEmpty)
    }

    @MainActor
    func testConfigureOfflinePlaybackRejectsAudioWithoutWordTiming() {
        let vm = makeTwoParagraphViewModel()
        let untimed = AudioSegment(
            paragraphIndex: 0,
            segmentIndex: 0,
            audioData: Data(repeating: 0x10, count: 8),
            timestamps: [],
            duration: 0.5,
            text: "cached",
            isWavFormat: false,
            unprocessedText: "cached",
            speaker: nil
        )

        XCTAssertFalse(vm.configureOfflinePlayback(
            segmentsByParagraph: [
                0: [untimed],
                1: [makeSegment(paragraphIndex: 1, marker: 0x20)],
            ],
            voiceID: "af_heart"
        ))
        XCTAssertFalse(vm.isOfflinePlayback)
    }

    #if DEBUG
    @MainActor
    func testOfflinePreloadUsesInstalledLocalSegments() async {
        let vm = makeTwoParagraphViewModel()
        let first = makeSegment(paragraphIndex: 0, marker: 0x41)
        let localNext = makeSegment(
            paragraphIndex: 1,
            segmentIndex: 0,
            marker: 0x7E,
            text: "second-local-only"
        )
        XCTAssertTrue(vm.configureOfflinePlayback(
            segmentsByParagraph: [0: [first], 1: [localNext]],
            voiceID: "af_heart"
        ))
        defer {
            _ = vm.stop()
            vm.deactivate()
        }

        await vm.dbgPreloadNext(after: 0)

        XCTAssertNil(vm.dbgPrefetchingIndex)
        XCTAssertEqual(vm.dbgPrefetchedIndex, 1)
        XCTAssertEqual(vm.dbgPrefetchedSegments.count, 1)
        XCTAssertEqual(vm.dbgPrefetchedSegments.first?.paragraphIndex, 1)
        XCTAssertEqual(vm.dbgPrefetchedSegments.first?.text, "second-local-only")
        XCTAssertEqual(vm.dbgPrefetchedSegments.first?.audioData, localNext.audioData)
    }
    #endif

    @MainActor
    private func makeViewModelWithNonReadableGaps() -> ReadAloudViewModel {
        ReadAloudViewModel(document: ReadingDocument(
            id: "offline-contract-gaps",
            title: "Offline contract",
            sourceKind: .kindle,
            language: "en",
            paragraphs: [
                ReadingParagraph(id: 0, text: "", type: .image, imageData: Data([0x01])),
                ReadingParagraph(id: 1, text: "First readable paragraph."),
                ReadingParagraph(id: 2, text: "Code is intentionally skipped.", type: .code),
                ReadingParagraph(id: 3, text: "Second readable paragraph."),
                ReadingParagraph(id: 4, text: "   "),
            ]
        ))
    }

    @MainActor
    private func makeTwoParagraphViewModel() -> ReadAloudViewModel {
        ReadAloudViewModel(document: ReadingDocument(
            id: "offline-contract-two-paragraphs",
            title: "Offline contract",
            sourceKind: .kindle,
            language: "en",
            paragraphs: [
                ReadingParagraph(id: 0, text: "First paragraph."),
                ReadingParagraph(id: 1, text: "Second paragraph."),
            ]
        ))
    }

    private func makeSegment(
        paragraphIndex: Int,
        segmentIndex: Int = 0,
        marker: UInt8,
        text: String = "cached"
    ) -> AudioSegment {
        AudioSegment(
            paragraphIndex: paragraphIndex,
            segmentIndex: segmentIndex,
            audioData: Data(repeating: marker, count: 8),
            timestamps: [
                TTSTimestamp(word: text, startTime: 0, endTime: 0.5),
            ],
            duration: 0.5,
            text: text,
            isWavFormat: false,
            unprocessedText: text,
            speaker: nil
        )
    }
}
