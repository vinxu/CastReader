@preconcurrency import AVFoundation
import XCTest
@testable import CastReader

final class VoiceCloneReferenceCandidateSelectorTests: XCTestCase {
    private let selector = VoiceCloneReferenceCandidateSelector(configuration: .standard)

    func testSilenceIsRejected() {
        let frames = makeFrames(decibels: Array(repeating: -120, count: 500))

        XCTAssertThrowsError(
            try selector.select(frames: frames, sourceDuration: 10)
        ) { error in
            XCTAssertEqual(
                error as? VoiceCloneReferencePreprocessorError,
                .noUsableSpeech
            )
        }
    }

    func testShortUsableSourceRemainsOneContinuousSevenSecondCandidate() throws {
        let frames = makeFrames(decibels: Array(repeating: -22, count: 350))

        let result = try selector.select(frames: frames, sourceDuration: 7)

        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].startTime, 0, accuracy: 0.000_1)
        XCTAssertEqual(result.candidates[0].duration, 7, accuracy: 0.000_1)
        XCTAssertEqual(result.candidates[0].activeSpeechDuration, 7, accuracy: 0.000_1)
    }

    func testDynamicThresholdFindsQuietSpeechBetweenSilence() throws {
        let decibels = Array(repeating: -120.0, count: 100)
            + Array(repeating: -35.0, count: 300)
            + Array(repeating: -120.0, count: 100)

        let result = try selector.select(
            frames: makeFrames(decibels: decibels),
            sourceDuration: 10
        )

        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].speechCoverage, 0.60, accuracy: 0.01)
        XCTAssertLessThan(result.energyThresholdDBFS, -35)
        XCTAssertEqual(result.candidates[0].activeRMSDBFS, -35, accuracy: 0.01)
    }

    func testTopCandidatesAreDeterministicAndNotHighlyOverlapping() throws {
        let frames = makeFrames(decibels: Array(repeating: -18, count: 2_000))

        let first = try selector.select(frames: frames, sourceDuration: 40)
        let second = try selector.select(frames: frames, sourceDuration: 40)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.candidates.count, 3)
        for leftIndex in first.candidates.indices {
            for rightIndex in first.candidates.indices where rightIndex > leftIndex {
                XCTAssertLessThanOrEqual(
                    first.candidates[leftIndex].overlapFraction(
                        with: first.candidates[rightIndex]
                    ),
                    VoiceCloneReferencePreprocessorConfiguration.standard
                        .maximumCandidateOverlapFraction + 0.000_1
                )
            }
        }
    }

    func testTooLittleActiveSpeechIsRejected() {
        let decibels = Array(repeating: -120.0, count: 400)
            + Array(repeating: -16.0, count: 100)

        XCTAssertThrowsError(
            try selector.select(
                frames: makeFrames(decibels: decibels),
                sourceDuration: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? VoiceCloneReferencePreprocessorError,
                .noUsableSpeech
            )
        }
    }

    func testThreeSecondBoundaryIsKeptWithoutLooping() throws {
        let frames = makeFrames(decibels: Array(repeating: -18, count: 150))

        let result = try selector.select(frames: frames, sourceDuration: 3)

        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].duration, 3, accuracy: 0.000_1)
        XCTAssertEqual(result.candidates[0].activeSpeechDuration, 3, accuracy: 0.000_1)
    }

    func testThreeSecondSourceStillRequiresThreeSecondsOfActiveSpeech() {
        let decibels = Array(repeating: -120.0, count: 5)
            + Array(repeating: -18.0, count: 145)

        XCTAssertThrowsError(
            try selector.select(
                frames: makeFrames(decibels: decibels),
                sourceDuration: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? VoiceCloneReferencePreprocessorError,
                .noUsableSpeech
            )
        }
    }

    func testLongSourceFindsSpeechAwayFromBeginning() throws {
        let decibels = Array(repeating: -120.0, count: 1_000)
            + Array(repeating: -20.0, count: 600)
            + Array(repeating: -120.0, count: 1_400)

        let result = try selector.select(
            frames: makeFrames(decibels: decibels),
            sourceDuration: 60
        )
        let preferred = try XCTUnwrap(result.candidates.first)

        XCTAssertGreaterThanOrEqual(preferred.startTime, 19.5)
        XCTAssertLessThanOrEqual(preferred.endTime, 32.5)
        XCTAssertGreaterThanOrEqual(preferred.activeSpeechDuration, 9.5)
    }

    func testClippedRegionLosesToCleanSpeech() throws {
        let cleanFrames = makeFrames(decibels: Array(repeating: -18.0, count: 1_500))
        let frames = cleanFrames.enumerated().map { index, frame in
            VoiceCloneReferenceAnalysisFrame(
                meanSquare: frame.meanSquare,
                clippingRatio: index < 500 ? 0.08 : 0
            )
        }

        let result = try selector.select(frames: frames, sourceDuration: 30)
        let preferred = try XCTUnwrap(result.candidates.first)

        XCTAssertGreaterThanOrEqual(preferred.startTime, 10)
        XCTAssertEqual(preferred.clippingRatio, 0, accuracy: 0.000_001)
    }

    private func makeFrames(decibels: [Double]) -> [VoiceCloneReferenceAnalysisFrame] {
        decibels.map {
            VoiceCloneReferenceAnalysisFrame(
                meanSquare: $0 <= -120 ? 0 : pow(10, $0 / 10),
                clippingRatio: 0
            )
        }
    }
}

final class VoiceCloneReferencePreprocessorIntegrationTests: XCTestCase {
    func testFirstImportRemovesStaleRawWorkspace() async throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCloneReferencePreprocessorStale-\(UUID().uuidString)")
        let workspaceRoot = testDirectory.appendingPathComponent("workspaces", isDirectory: true)
        let newSource = testDirectory.appendingPathComponent("new-source.wav")
        let staleRawSource = workspaceRoot
            .appendingPathComponent("stale-session", isDirectory: true)
            .appendingPathComponent("source.m4a")
        try FileManager.default.createDirectory(
            at: staleRawSource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: staleRawSource.path,
            contents: Data("sensitive raw audio".utf8)
        ))
        XCTAssertTrue(FileManager.default.createFile(atPath: newSource.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let preprocessor = VoiceCloneReferencePreprocessor(temporaryRootURL: workspaceRoot)
        do {
            _ = try await preprocessor.analyze(
                sourceURL: newSource,
                requiresSecurityScopedAccess: false
            )
            XCTFail("An empty new source should be rejected")
        } catch {
            XCTAssertEqual(
                error as? VoiceCloneReferencePreprocessorError,
                .sourceEmpty
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRawSource.path))
    }

    func testAntiPhaseStereoUsesOneChannelAndExportsCanonicalWAV() async throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCloneReferencePreprocessorTests-\(UUID().uuidString)")
        let inputURL = testDirectory.appendingPathComponent("anti-phase.wav")
        let workspaceRoot = testDirectory.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        try writeAntiPhaseStereoWAV(to: inputURL, duration: 12, sampleRate: 48_000)
        let preprocessor = VoiceCloneReferencePreprocessor(
            temporaryRootURL: workspaceRoot
        )

        let prepared = try await preprocessor.prepare(
            sourceURL: inputURL,
            requiresSecurityScopedAccess: false
        )

        guard case .channel(let index, let channelCount, let reason, let correlation)
            = prepared.analysis.channelSelection else {
            return XCTFail("Anti-phase input should select one source channel")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(channelCount, 2)
        XCTAssertEqual(reason, .phaseCancellation)
        XCTAssertLessThan(correlation ?? 0, -0.99)
        XCTAssertEqual(prepared.selectedCandidate.duration, 10, accuracy: 0.03)
        XCTAssertLessThan(prepared.canonicalByteCount, 1_024 * 1_024)

        let outputFile = try AVAudioFile(forReading: prepared.canonicalURL)
        XCTAssertEqual(outputFile.fileFormat.sampleRate, 24_000, accuracy: 0.1)
        XCTAssertEqual(outputFile.fileFormat.channelCount, 1)
        XCTAssertEqual(outputFile.fileFormat.commonFormat, .pcmFormatInt16)
        let outputDuration = Double(outputFile.length) / outputFile.fileFormat.sampleRate
        XCTAssertEqual(outputDuration, 10, accuracy: 0.03)

        let canonicalURL = prepared.canonicalURL
        try await preprocessor.cleanup(prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
    }

    func testExactThreeSecondWAVSurvivesAnalysisResamplingAndExportsThreeSeconds() async throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCloneReferenceThreeSeconds-\(UUID().uuidString)")
        let inputURL = testDirectory.appendingPathComponent("exact-three-seconds.wav")
        let workspaceRoot = testDirectory.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        try writeMonoToneWAV(to: inputURL, duration: 3, sampleRate: 48_000)
        let preprocessor = VoiceCloneReferencePreprocessor(
            temporaryRootURL: workspaceRoot
        )

        let prepared = try await preprocessor.prepare(
            sourceURL: inputURL,
            requiresSecurityScopedAccess: false
        )

        XCTAssertEqual(prepared.analysis.sourceDuration, 3, accuracy: 0.000_001)
        XCTAssertEqual(prepared.analysis.analysisSampleRate, 16_000, accuracy: 0.1)
        XCTAssertEqual(prepared.selectedCandidate.duration, 3, accuracy: 0.000_001)
        let outputFile = try AVAudioFile(forReading: prepared.canonicalURL)
        let outputDuration = Double(outputFile.length) / outputFile.fileFormat.sampleRate
        XCTAssertEqual(outputDuration, 3, accuracy: 1 / 24_000)

        try await preprocessor.cleanup(prepared)
    }

    func testTwoPointNineEightSecondWAVRemainsBelowHardMinimum() async throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCloneReferenceTooShort-\(UUID().uuidString)")
        let inputURL = testDirectory.appendingPathComponent("two-point-nine-eight.wav")
        let workspaceRoot = testDirectory.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        try writeMonoToneWAV(to: inputURL, duration: 2.98, sampleRate: 48_000)
        let preprocessor = VoiceCloneReferencePreprocessor(
            temporaryRootURL: workspaceRoot
        )

        do {
            _ = try await preprocessor.analyze(
                sourceURL: inputURL,
                requiresSecurityScopedAccess: false
            )
            XCTFail("a real source shorter than three seconds must stay rejected")
        } catch {
            XCTAssertEqual(
                error as? VoiceCloneReferencePreprocessorError,
                .sourceTooShort(minimumDuration: 3)
            )
        }
    }

    func testTenMinuteSourceScansToSpeechNearTheEndWithinMVPBudget() async throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCloneReferenceTenMinutes-\(UUID().uuidString)")
        let inputURL = testDirectory.appendingPathComponent("speech-near-end.wav")
        let workspaceRoot = testDirectory.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        try writeMonoToneWAV(
            to: inputURL,
            duration: 600,
            sampleRate: 16_000,
            activeRange: 588..<600
        )
        let preprocessor = VoiceCloneReferencePreprocessor(
            temporaryRootURL: workspaceRoot
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        let analysis = try await preprocessor.analyze(
            sourceURL: inputURL,
            requiresSecurityScopedAccess: false
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        let preferred = try XCTUnwrap(analysis.preferredCandidate)
        XCTAssertEqual(analysis.sourceDuration, 600, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(preferred.startTime, 587.5)
        XCTAssertLessThanOrEqual(preferred.endTime, 600.001)
        XCTAssertLessThan(
            elapsed,
            8,
            "the 10-minute MVP input should stay within the local analysis budget"
        )

        try await preprocessor.cleanup(analysis)
    }

    private func writeAntiPhaseStereoWAV(
        to url: URL,
        duration: TimeInterval,
        sampleRate: Double
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            return XCTFail("Could not create fixture audio format")
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let totalFrames = Int((duration * sampleRate).rounded())
        let chunkFrames = 4_096
        var writtenFrames = 0
        while writtenFrames < totalFrames {
            let frameCount = min(chunkFrames, totalFrames - writtenFrames)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let left = buffer.floatChannelData?[0],
            let right = buffer.floatChannelData?[1] else {
                return XCTFail("Could not create fixture audio buffer")
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)

            for frameIndex in 0..<frameCount {
                let absoluteFrame = writtenFrames + frameIndex
                let envelope = 0.7 + 0.2 * sin(
                    2 * .pi * Double(absoluteFrame) / (sampleRate * 1.7)
                )
                let sample = Float(
                    envelope * sin(2 * .pi * 220 * Double(absoluteFrame) / sampleRate)
                )
                left[frameIndex] = sample
                right[frameIndex] = -sample
            }
            try file.write(from: buffer)
            writtenFrames += frameCount
        }
    }

    private func writeMonoToneWAV(
        to url: URL,
        duration: TimeInterval,
        sampleRate: Double,
        activeRange: Range<TimeInterval>? = nil
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Could not create mono fixture audio format")
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let totalFrames = Int((duration * sampleRate).rounded())
        let chunkFrames = 4_096
        var writtenFrames = 0
        while writtenFrames < totalFrames {
            let frameCount = min(chunkFrames, totalFrames - writtenFrames)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channel = buffer.floatChannelData?[0] else {
                return XCTFail("Could not create mono fixture audio buffer")
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            for frameIndex in 0..<frameCount {
                let absoluteFrame = writtenFrames + frameIndex
                let time = Double(absoluteFrame) / sampleRate
                if let activeRange, !activeRange.contains(time) {
                    channel[frameIndex] = 0
                } else {
                    channel[frameIndex] = Float(
                        0.65 * sin(2 * .pi * 220 * Double(absoluteFrame) / sampleRate)
                    )
                }
            }
            try file.write(from: buffer)
            writtenFrames += frameCount
        }
    }
}
