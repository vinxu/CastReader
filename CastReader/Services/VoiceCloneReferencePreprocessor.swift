@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Prepares an uploaded local audio file for the existing voice-clone upload
/// contract. This actor deliberately stops at a small canonical WAV: the
/// server remains authoritative for consent, persistence, speaker validation,
/// and clone creation.
actor VoiceCloneReferencePreprocessor {
    static let shared = VoiceCloneReferencePreprocessor()

    typealias ProgressHandler = @Sendable (VoiceCloneReferencePreparationProgress) -> Void

    private struct Workspace {
        let directoryURL: URL
        let stagedSourceURL: URL
        let analysis: VoiceCloneReferenceAnalysis
    }

    private struct SourceAsset {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: TimeInterval
    }

    private struct DecodedAnalysis {
        let sampleRate: Double
        let channelCount: Int
        let decodedDuration: TimeInterval
        let mixedFrames: [VoiceCloneReferenceAnalysisFrame]
        let channelFrames: [[VoiceCloneReferenceAnalysisFrame]]
        let correlation: Double?
    }

    private struct SelectedAnalysis {
        let channelSelection: VoiceCloneReferenceChannelSelection
        let candidates: [VoiceCloneReferenceCandidate]
        let warnings: [VoiceCloneReferenceWarning]
    }

    private let configuration: VoiceCloneReferencePreprocessorConfiguration
    private let fileManager: FileManager
    private let temporaryRootURL: URL
    private var workspaces: [UUID: Workspace] = [:]
    private var didPurgeStaleWorkspaces = false

    init(
        configuration: VoiceCloneReferencePreprocessorConfiguration = .standard,
        fileManager: FileManager = .default,
        temporaryRootURL: URL? = nil
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.temporaryRootURL = temporaryRootURL
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("CastReaderVoiceCloneReferences", isDirectory: true)
    }

    /// Copies and analyzes a file, retaining a private workspace until the
    /// caller explicitly cleans it up. Candidates are continuous excerpts and
    /// are ordered best-first.
    func analyze(
        sourceURL: URL,
        requiresSecurityScopedAccess: Bool = true,
        progress: ProgressHandler? = nil
    ) async throws -> VoiceCloneReferenceAnalysis {
        try await performAnalysis(
            sourceURL: sourceURL,
            requiresSecurityScopedAccess: requiresSecurityScopedAccess,
            reportCompletion: true,
            progress: progress
        )
    }

    /// One-shot convenience used by the MVP. It chooses the highest-ranked
    /// candidate and exports a 24 kHz mono PCM16 WAV.
    func prepare(
        sourceURL: URL,
        requiresSecurityScopedAccess: Bool = true,
        progress: ProgressHandler? = nil
    ) async throws -> VoiceClonePreparedReference {
        var ownedWorkspaceID: UUID?

        do {
            let analysis = try await performAnalysis(
                sourceURL: sourceURL,
                requiresSecurityScopedAccess: requiresSecurityScopedAccess,
                reportCompletion: false,
                progress: progress
            )
            ownedWorkspaceID = analysis.workspaceID
            return try await prepare(
                analysis: analysis,
                candidateID: analysis.preferredCandidate?.id,
                progress: progress
            )
        } catch {
            if let ownedWorkspaceID {
                try? cleanup(workspaceID: ownedWorkspaceID)
            }
            throw error
        }
    }

    /// Exports a chosen candidate from a previous analysis. Re-analysis is not
    /// needed when a user previews and switches among the top candidates.
    func prepare(
        analysis requestedAnalysis: VoiceCloneReferenceAnalysis,
        candidateID: String? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> VoiceClonePreparedReference {
        try Task.checkCancellation()

        guard let workspace = workspaces[requestedAnalysis.workspaceID],
              fileManager.fileExists(atPath: workspace.stagedSourceURL.path) else {
            workspaces.removeValue(forKey: requestedAnalysis.workspaceID)
            throw VoiceCloneReferencePreprocessorError.workspaceExpired
        }

        let authoritativeAnalysis = workspace.analysis
        let requestedID = candidateID ?? authoritativeAnalysis.preferredCandidate?.id
        guard let requestedID,
              let candidate = authoritativeAnalysis.candidates.first(where: { $0.id == requestedID }) else {
            throw VoiceCloneReferencePreprocessorError.candidateNotFound
        }

        report(.exporting, fraction: 0.84, to: progress)
        let canonicalURL = workspace.directoryURL
            .appendingPathComponent("reference-\(candidate.id).wav", isDirectory: false)

        do {
            if fileManager.fileExists(atPath: canonicalURL.path) {
                try fileManager.removeItem(at: canonicalURL)
            }

            let sourceAsset = try await loadSourceAsset(at: workspace.stagedSourceURL)
            let samples = try await extractCandidateSamples(
                sourceAsset: sourceAsset,
                candidate: candidate,
                channelSelection: authoritativeAnalysis.channelSelection,
                progress: progress
            )
            try Task.checkCancellation()

            try convertAndWriteCanonicalWAV(
                samples: samples.values,
                sourceSampleRate: samples.sampleRate,
                targetDuration: candidate.duration,
                destinationURL: canonicalURL
            )
            try Task.checkCancellation()

            let attributes = try fileManager.attributesOfItem(atPath: canonicalURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard byteCount > 44, byteCount < 1024 * 1024 else {
                throw VoiceCloneReferencePreprocessorError.exportFailed
            }

            report(.completed, fraction: 1, to: progress)
            return VoiceClonePreparedReference(
                workspaceID: authoritativeAnalysis.workspaceID,
                canonicalURL: canonicalURL,
                canonicalByteCount: byteCount,
                analysis: authoritativeAnalysis,
                selectedCandidate: candidate
            )
        } catch is CancellationError {
            try? fileManager.removeItem(at: canonicalURL)
            throw CancellationError()
        } catch let error as VoiceCloneReferencePreprocessorError {
            try? fileManager.removeItem(at: canonicalURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: canonicalURL)
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }
    }

    /// Removes the staged source and every generated candidate. Cleanup is
    /// intentionally idempotent so cancellation and view dismissal can race.
    func cleanup(workspaceID: UUID) throws {
        let knownDirectory = workspaces.removeValue(forKey: workspaceID)?.directoryURL
        let directoryURL = knownDirectory
            ?? temporaryRootURL.appendingPathComponent(workspaceID.uuidString, isDirectory: true)

        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        do {
            try fileManager.removeItem(at: directoryURL)
        } catch {
            throw VoiceCloneReferencePreprocessorError.cleanupFailed
        }
    }

    func cleanup(_ analysis: VoiceCloneReferenceAnalysis) throws {
        try cleanup(workspaceID: analysis.workspaceID)
    }

    func cleanup(_ preparedReference: VoiceClonePreparedReference) throws {
        try cleanup(workspaceID: preparedReference.workspaceID)
    }

    /// Best-effort lifecycle cleanup for stale sessions. It only touches this
    /// service's dedicated temporary root.
    func cleanupAll() throws {
        workspaces.removeAll()
        guard fileManager.fileExists(atPath: temporaryRootURL.path) else { return }
        do {
            try fileManager.removeItem(at: temporaryRootURL)
        } catch {
            throw VoiceCloneReferencePreprocessorError.cleanupFailed
        }
    }

    private func performAnalysis(
        sourceURL: URL,
        requiresSecurityScopedAccess: Bool,
        reportCompletion: Bool,
        progress: ProgressHandler?
    ) async throws -> VoiceCloneReferenceAnalysis {
        try Task.checkCancellation()
        report(.validating, fraction: 0.01, to: progress)

        guard sourceURL.isFileURL else {
            throw VoiceCloneReferencePreprocessorError.invalidSourceURL
        }

        try purgeStaleWorkspacesIfNeeded()

        let workspaceID = UUID()
        let directoryURL = temporaryRootURL
            .appendingPathComponent(workspaceID.uuidString, isDirectory: true)
        var workspaceWasCreated = false

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            workspaceWasCreated = true

            let stagedSourceURL = try copySourceIntoWorkspace(
                sourceURL: sourceURL,
                directoryURL: directoryURL,
                requiresSecurityScopedAccess: requiresSecurityScopedAccess,
                progress: progress
            )
            try Task.checkCancellation()

            let sourceAttributes = try fileManager.attributesOfItem(atPath: stagedSourceURL.path)
            let sourceByteCount = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
            let sourceAsset = try await loadSourceAsset(at: stagedSourceURL)

            report(.decoding, fraction: 0.18, to: progress)
            let decoded = try await decodeForAnalysis(
                sourceAsset: sourceAsset,
                progress: progress
            )

            // The container already passed the exact 3-second minimum. When
            // the 16 kHz converter trims only a handful of frames, retain the
            // authoritative container duration so an exact 3.000 s recording
            // is not turned into a 2.999 s candidate. Larger discrepancies
            // remain fail-closed as truncated/corrupt decoded media.
            let decoderCoversContainer = decoded.decodedDuration
                + configuration.maximumDecoderTrimDuration >= sourceAsset.duration
            let usableDuration = decoderCoversContainer
                ? sourceAsset.duration
                : decoded.decodedDuration
            guard usableDuration >= configuration.minimumSourceDuration else {
                throw VoiceCloneReferencePreprocessorError.sourceTooShort(
                    minimumDuration: configuration.minimumSourceDuration
                )
            }

            report(.analyzing, fraction: 0.75, to: progress)
            let selected = try selectAnalysis(decoded: decoded, sourceDuration: usableDuration)
            try Task.checkCancellation()

            let analysis = VoiceCloneReferenceAnalysis(
                workspaceID: workspaceID,
                sourceFilename: sourceURL.lastPathComponent,
                sourceByteCount: sourceByteCount,
                sourceDuration: usableDuration,
                analysisSampleRate: decoded.sampleRate,
                sourceChannelCount: decoded.channelCount,
                channelSelection: selected.channelSelection,
                candidates: selected.candidates,
                warnings: selected.warnings
            )

            workspaces[workspaceID] = Workspace(
                directoryURL: directoryURL,
                stagedSourceURL: stagedSourceURL,
                analysis: analysis
            )

            if reportCompletion {
                report(.completed, fraction: 1, to: progress)
            } else {
                report(.analyzing, fraction: 0.82, to: progress)
            }
            return analysis
        } catch is CancellationError {
            workspaces.removeValue(forKey: workspaceID)
            if workspaceWasCreated {
                try? fileManager.removeItem(at: directoryURL)
            }
            throw CancellationError()
        } catch let error as VoiceCloneReferencePreprocessorError {
            workspaces.removeValue(forKey: workspaceID)
            if workspaceWasCreated {
                try? fileManager.removeItem(at: directoryURL)
            }
            throw error
        } catch {
            workspaces.removeValue(forKey: workspaceID)
            if workspaceWasCreated {
                try? fileManager.removeItem(at: directoryURL)
            }
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }
    }

    private func copySourceIntoWorkspace(
        sourceURL: URL,
        directoryURL: URL,
        requiresSecurityScopedAccess: Bool,
        progress: ProgressHandler?
    ) throws -> URL {
        let didAccessSecurityScope = requiresSecurityScopedAccess
            ? sourceURL.startAccessingSecurityScopedResource()
            : false
        defer {
            if didAccessSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        report(.copying, fraction: 0.03, to: progress)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw VoiceCloneReferencePreprocessorError.sourceUnavailable
        }

        let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        let expectedByteCount = (attributes?[.size] as? NSNumber)?.int64Value
        if let expectedByteCount {
            guard expectedByteCount > 0 else {
                throw VoiceCloneReferencePreprocessorError.sourceEmpty
            }
            guard expectedByteCount <= configuration.maximumSourceBytes else {
                throw VoiceCloneReferencePreprocessorError.sourceTooLarge(
                    maximumBytes: configuration.maximumSourceBytes
                )
            }
        }

        let sourceExtension = sourceURL.pathExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let stagedFilename = sourceExtension.isEmpty ? "source-audio" : "source.\(sourceExtension)"
        let stagedURL = directoryURL.appendingPathComponent(stagedFilename, isDirectory: false)

        guard fileManager.createFile(atPath: stagedURL.path, contents: nil) else {
            throw VoiceCloneReferencePreprocessorError.sourceUnavailable
        }

        do {
            let input = try FileHandle(forReadingFrom: sourceURL)
            let output = try FileHandle(forWritingTo: stagedURL)
            defer {
                try? input.close()
                try? output.close()
            }

            var copiedBytes: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: configuration.copyBufferBytes),
                      !data.isEmpty else {
                    break
                }

                copiedBytes += Int64(data.count)
                guard copiedBytes <= configuration.maximumSourceBytes else {
                    throw VoiceCloneReferencePreprocessorError.sourceTooLarge(
                        maximumBytes: configuration.maximumSourceBytes
                    )
                }
                try output.write(contentsOf: data)

                if let expectedByteCount, expectedByteCount > 0 {
                    let copyFraction = min(1, Double(copiedBytes) / Double(expectedByteCount))
                    report(.copying, fraction: 0.03 + copyFraction * 0.13, to: progress)
                }
            }

            guard copiedBytes > 0 else {
                throw VoiceCloneReferencePreprocessorError.sourceEmpty
            }
            report(.copying, fraction: 0.16, to: progress)
            return stagedURL
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VoiceCloneReferencePreprocessorError {
            throw error
        } catch {
            throw VoiceCloneReferencePreprocessorError.sourceUnavailable
        }
    }

    private func loadSourceAsset(at url: URL) async throws -> SourceAsset {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)

        do {
            async let durationValue = asset.load(.duration)
            async let isPlayableValue = asset.load(.isPlayable)
            async let isProtectedValue = asset.load(.hasProtectedContent)
            async let audioTracksValue = asset.loadTracks(withMediaType: .audio)

            let (duration, isPlayable, isProtected, audioTracks) = try await (
                durationValue,
                isPlayableValue,
                isProtectedValue,
                audioTracksValue
            )
            try Task.checkCancellation()

            if isProtected {
                throw VoiceCloneReferencePreprocessorError.protectedAudio
            }
            guard isPlayable else {
                throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
            }
            guard let track = audioTracks.first else {
                throw VoiceCloneReferencePreprocessorError.noAudioTrack
            }

            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else {
                throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
            }
            // Container duration commonly includes one compressed-audio frame
            // of encoder padding. Keep the product's ten-minute limit while
            // avoiding a false rejection at that exact boundary.
            guard seconds <= configuration.maximumSourceDuration + 0.25 else {
                throw VoiceCloneReferencePreprocessorError.sourceTooLong(
                    maximumDuration: configuration.maximumSourceDuration
                )
            }
            guard seconds >= configuration.minimumSourceDuration else {
                throw VoiceCloneReferencePreprocessorError.sourceTooShort(
                    minimumDuration: configuration.minimumSourceDuration
                )
            }

            return SourceAsset(
                asset: asset,
                track: track,
                duration: min(seconds, configuration.maximumSourceDuration)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VoiceCloneReferencePreprocessorError {
            throw error
        } catch {
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }
    }

    private func decodeForAnalysis(
        sourceAsset: SourceAsset,
        progress: ProgressHandler?
    ) async throws -> DecodedAnalysis {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: sourceAsset.asset)
        } catch {
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: configuration.maximumAnalysisSampleRate,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(
            track: sourceAsset.track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        var sourceSampleRate: Double?
        var sourceChannelCount: Int?
        var sourceFrameCount: Int64 = 0
        var analysisStride = 1
        var mixedAccumulator: VoiceCloneReferenceFrameAccumulator?
        var channelAccumulators: [VoiceCloneReferenceFrameAccumulator] = []
        var correlationAccumulator = VoiceCloneReferenceCorrelationAccumulator()
        var bufferCount = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let decodedBuffer = try decodedFloatBuffer(from: sampleBuffer)

            if sourceSampleRate == nil {
                guard decodedBuffer.sampleRate > 0,
                      decodedBuffer.sampleRate <= 384_000,
                      decodedBuffer.channelCount > 0 else {
                    throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
                }

                sourceSampleRate = decodedBuffer.sampleRate
                sourceChannelCount = decodedBuffer.channelCount
                analysisStride = max(
                    1,
                    Int(ceil(decodedBuffer.sampleRate / configuration.maximumAnalysisSampleRate))
                )
                let effectiveSampleRate = decodedBuffer.sampleRate / Double(analysisStride)
                let samplesPerFrame = max(
                    1,
                    Int((effectiveSampleRate * configuration.analysisFrameDuration).rounded())
                )
                mixedAccumulator = VoiceCloneReferenceFrameAccumulator(
                    samplesPerFrame: samplesPerFrame
                )
                let analyzedChannelCount = min(
                    decodedBuffer.channelCount,
                    configuration.maximumAnalyzedChannelCount
                )
                channelAccumulators = (0..<analyzedChannelCount).map { _ in
                    VoiceCloneReferenceFrameAccumulator(samplesPerFrame: samplesPerFrame)
                }
            } else if sourceSampleRate != decodedBuffer.sampleRate
                        || sourceChannelCount != decodedBuffer.channelCount {
                throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
            }

            let channelCount = decodedBuffer.channelCount
            let frameCount = decodedBuffer.values.count / channelCount
            guard mixedAccumulator != nil else {
                throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
            }

            let strideRemainder = Int(sourceFrameCount % Int64(analysisStride))
            var frameIndex = strideRemainder == 0 ? 0 : analysisStride - strideRemainder
            while frameIndex < frameCount {
                let sampleOffset = frameIndex * channelCount
                var mixedSample: Float = 0
                for channelIndex in 0..<channelCount {
                    let rawSample = decodedBuffer.values[sampleOffset + channelIndex]
                    let sample = rawSample.isFinite ? rawSample : 0
                    mixedSample += sample / Float(channelCount)

                    if channelIndex < channelAccumulators.count {
                        channelAccumulators[channelIndex].append(sample)
                    }
                }
                mixedAccumulator?.append(mixedSample)

                if channelCount >= 2 {
                    let left = decodedBuffer.values[sampleOffset]
                    let right = decodedBuffer.values[sampleOffset + 1]
                    correlationAccumulator.append(
                        left.isFinite ? Double(left) : 0,
                        right.isFinite ? Double(right) : 0
                    )
                }
                frameIndex += analysisStride
            }
            sourceFrameCount += Int64(frameCount)
            bufferCount += 1
            if bufferCount.isMultiple(of: 8),
               let sourceSampleRate,
               sourceAsset.duration > 0 {
                let decodedSeconds = Double(sourceFrameCount) / sourceSampleRate
                let fraction = min(1, decodedSeconds / sourceAsset.duration)
                report(.decoding, fraction: 0.18 + fraction * 0.54, to: progress)
            }
            if bufferCount.isMultiple(of: 32) {
                await Task.yield()
            }
        }

        if reader.status == .failed || reader.status == .cancelled {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }
        guard reader.status == .completed,
              let sourceSampleRate,
              let sourceChannelCount,
              var finalMixedAccumulator = mixedAccumulator else {
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }

        finalMixedAccumulator.finish()
        var channelFrames: [[VoiceCloneReferenceAnalysisFrame]] = []
        channelFrames.reserveCapacity(channelAccumulators.count)
        for var accumulator in channelAccumulators {
            accumulator.finish()
            channelFrames.append(accumulator.frames)
        }

        report(.decoding, fraction: 0.72, to: progress)
        return DecodedAnalysis(
            sampleRate: sourceSampleRate,
            channelCount: sourceChannelCount,
            decodedDuration: Double(sourceFrameCount) / sourceSampleRate,
            mixedFrames: finalMixedAccumulator.frames,
            channelFrames: channelFrames,
            correlation: correlationAccumulator.correlation
        )
    }

    private func selectAnalysis(
        decoded: DecodedAnalysis,
        sourceDuration: TimeInterval
    ) throws -> SelectedAnalysis {
        let selector = VoiceCloneReferenceCandidateSelector(configuration: configuration)
        let mixedResult = try? selector.select(
            frames: decoded.mixedFrames,
            sourceDuration: sourceDuration
        )

        let channelResults: [VoiceCloneReferenceCandidateSelectionResult?] = decoded.channelFrames.map {
            try? selector.select(frames: $0, sourceDuration: sourceDuration)
        }
        let bestChannel = channelResults.enumerated()
            .compactMap { index, result -> (Int, VoiceCloneReferenceCandidateSelectionResult)? in
                guard let result else { return nil }
                return (index, result)
            }
            .sorted { lhs, rhs in
                let leftScore = lhs.1.candidates.first?.score ?? -1
                let rightScore = rhs.1.candidates.first?.score ?? -1
                if abs(leftScore - rightScore) > 0.000_000_1 {
                    return leftScore > rightScore
                }
                return lhs.0 < rhs.0
            }
            .first

        let selection: VoiceCloneReferenceChannelSelection
        let selectedResult: VoiceCloneReferenceCandidateSelectionResult

        if decoded.channelCount == 1 {
            guard let result = channelResults.first ?? mixedResult else {
                throw VoiceCloneReferencePreprocessorError.noUsableSpeech
            }
            selection = .mono
            selectedResult = result
        } else if let bestChannel {
            let correlation = decoded.correlation
            let mixedScore = mixedResult?.candidates.first?.score ?? -1
            let channelScore = bestChannel.1.candidates.first?.score ?? -1
            let mixedRMS = mixedResult?.overallRMSDBFS ?? -120
            let channelRMS = bestChannel.1.overallRMSDBFS

            let reason: VoiceCloneReferenceChannelSelectionReason?
            if mixedResult == nil
                || ((correlation ?? 0) < -0.15 && channelRMS - mixedRMS > 3) {
                reason = .phaseCancellation
            } else if let correlation, abs(correlation) < 0.20,
                      channelScore >= mixedScore - 0.02 {
                reason = .lowCorrelation
            } else if channelScore > mixedScore + 0.12
                        || (channelRMS - mixedRMS > 6 && channelScore >= mixedScore) {
                reason = .higherQuality
            } else {
                reason = nil
            }

            if let reason {
                selection = .channel(
                    index: bestChannel.0,
                    channelCount: decoded.channelCount,
                    reason: reason,
                    correlation: correlation
                )
                selectedResult = bestChannel.1
            } else if let mixedResult {
                selection = .averaged(channelCount: decoded.channelCount)
                selectedResult = mixedResult
            } else {
                selection = .channel(
                    index: bestChannel.0,
                    channelCount: decoded.channelCount,
                    reason: .higherQuality,
                    correlation: correlation
                )
                selectedResult = bestChannel.1
            }
        } else if let mixedResult {
            selection = .averaged(channelCount: decoded.channelCount)
            selectedResult = mixedResult
        } else {
            throw VoiceCloneReferencePreprocessorError.noUsableSpeech
        }

        guard let preferredCandidate = selectedResult.candidates.first else {
            throw VoiceCloneReferencePreprocessorError.noUsableSpeech
        }

        let obviousClippingThreshold = max(configuration.maximumClippingRatio * 8, 0.03)
        if selectedResult.candidates.allSatisfy({ $0.clippingRatio >= obviousClippingThreshold }) {
            throw VoiceCloneReferencePreprocessorError.excessiveClipping
        }

        var warnings: [VoiceCloneReferenceWarning] = []
        if preferredCandidate.duration < configuration.targetCandidateDuration - 0.05 {
            warnings.append(.shorterThanTarget(duration: preferredCandidate.duration))
        }
        if preferredCandidate.speechCoverage < 0.55
            || preferredCandidate.activeSpeechDuration < min(6, preferredCandidate.duration * 0.7) {
            warnings.append(.limitedSpeech(duration: preferredCandidate.activeSpeechDuration))
        }
        if preferredCandidate.activeRMSDBFS < -30 {
            warnings.append(.lowSignal(activeRMSDBFS: preferredCandidate.activeRMSDBFS))
        }
        if let snr = preferredCandidate.estimatedSNRDB, snr < 8 {
            warnings.append(.lowEstimatedSNR(decibels: snr))
        }
        if preferredCandidate.clippingRatio > configuration.maximumClippingRatio {
            warnings.append(.clippingDetected(ratio: preferredCandidate.clippingRatio))
        }
        if case .channel(_, _, let reason, let correlation) = selection {
            warnings.append(.singleChannelSelected(reason: reason, correlation: correlation))
        }

        return SelectedAnalysis(
            channelSelection: selection,
            candidates: selectedResult.candidates,
            warnings: warnings
        )
    }

    private struct ExtractedSamples {
        let values: [Float]
        let sampleRate: Double
    }

    private func extractCandidateSamples(
        sourceAsset: SourceAsset,
        candidate: VoiceCloneReferenceCandidate,
        channelSelection: VoiceCloneReferenceChannelSelection,
        progress: ProgressHandler?
    ) async throws -> ExtractedSamples {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: sourceAsset.asset)
        } catch {
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(
            track: sourceAsset.track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: candidate.startTime, preferredTimescale: 60_000),
            duration: CMTime(seconds: candidate.duration, preferredTimescale: 60_000)
        )
        guard reader.startReading() else {
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        var samples: [Float] = []
        var sourceSampleRate: Double?
        var sourceChannelCount: Int?
        var maximumFrameCount = Int.max
        var bufferCount = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let decodedBuffer = try decodedFloatBuffer(from: sampleBuffer)

            if sourceSampleRate == nil {
                sourceSampleRate = decodedBuffer.sampleRate
                sourceChannelCount = decodedBuffer.channelCount
                guard decodedBuffer.sampleRate > 0,
                      decodedBuffer.sampleRate <= 384_000,
                      decodedBuffer.channelCount > 0 else {
                    throw VoiceCloneReferencePreprocessorError.exportFailed
                }
                maximumFrameCount = Int(
                    ceil(candidate.duration * decodedBuffer.sampleRate)
                ) + 2
                samples.reserveCapacity(maximumFrameCount)
            } else if sourceSampleRate != decodedBuffer.sampleRate
                        || sourceChannelCount != decodedBuffer.channelCount {
                throw VoiceCloneReferencePreprocessorError.exportFailed
            }

            let channelCount = decodedBuffer.channelCount
            let frameCount = decodedBuffer.values.count / channelCount
            for frameIndex in 0..<frameCount where samples.count < maximumFrameCount {
                let offset = frameIndex * channelCount
                let selectedSample: Float
                if let selectedChannelIndex = channelSelection.selectedChannelIndex {
                    guard selectedChannelIndex < channelCount else {
                        throw VoiceCloneReferencePreprocessorError.exportFailed
                    }
                    let value = decodedBuffer.values[offset + selectedChannelIndex]
                    selectedSample = value.isFinite ? value : 0
                } else {
                    var sum: Float = 0
                    for channelIndex in 0..<channelCount {
                        let value = decodedBuffer.values[offset + channelIndex]
                        sum += (value.isFinite ? value : 0) / Float(channelCount)
                    }
                    selectedSample = sum
                }
                samples.append(selectedSample)
            }

            bufferCount += 1
            if bufferCount.isMultiple(of: 4), maximumFrameCount > 0 {
                let fraction = min(1, Double(samples.count) / Double(maximumFrameCount))
                report(.exporting, fraction: 0.84 + fraction * 0.10, to: progress)
            }
            if bufferCount.isMultiple(of: 32) {
                await Task.yield()
            }
        }

        if reader.status == .failed || reader.status == .cancelled {
            if Task.isCancelled { throw CancellationError() }
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }
        guard reader.status == .completed,
              let sourceSampleRate,
              !samples.isEmpty else {
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }

        let exactFrameCount = min(
            samples.count,
            max(1, Int((candidate.duration * sourceSampleRate).rounded()))
        )
        if samples.count > exactFrameCount {
            samples.removeSubrange(exactFrameCount...)
        }
        report(.exporting, fraction: 0.95, to: progress)
        return ExtractedSamples(values: samples, sampleRate: sourceSampleRate)
    }

    private func convertAndWriteCanonicalWAV(
        samples: [Float],
        sourceSampleRate: Double,
        targetDuration: TimeInterval,
        destinationURL: URL
    ) throws {
        guard !samples.isEmpty,
              let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: 1,
                interleaved: false
              ),
              let destinationFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: configuration.outputSampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat),
              samples.count <= Int(UInt32.max),
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let sourceChannel = sourceBuffer.floatChannelData?[0] else {
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            sourceChannel.update(from: baseAddress, count: samples.count)
        }

        let convertedOutputFrames = Int(
            ceil(Double(samples.count) * configuration.outputSampleRate / sourceSampleRate)
        )
        let targetOutputFrames = Int(
            (targetDuration * configuration.outputSampleRate).rounded()
        )
        let outputCapacity = max(convertedOutputFrames, targetOutputFrames) + 64
        guard convertedOutputFrames > 0,
              targetOutputFrames > 0,
              outputCapacity <= Int(UInt32.max),
              let destinationBuffer = AVAudioPCMBuffer(
                pcmFormat: destinationFormat,
                frameCapacity: AVAudioFrameCount(outputCapacity)
              ) else {
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(
            to: destinationBuffer,
            error: &conversionError
        ) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard conversionError == nil,
              conversionStatus != .error,
              destinationBuffer.frameLength > 0 else {
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }

        let producedOutputFrames = Int(destinationBuffer.frameLength)
        if producedOutputFrames < targetOutputFrames {
            let missingFrames = targetOutputFrames - producedOutputFrames
            let maximumTrimFrames = Int(ceil(
                configuration.maximumDecoderTrimDuration
                    * configuration.outputSampleRate
            )) + 2
            guard missingFrames <= maximumTrimFrames,
                  let channel = destinationBuffer.int16ChannelData?[0] else {
                throw VoiceCloneReferencePreprocessorError.exportFailed
            }
            for index in producedOutputFrames..<targetOutputFrames {
                channel[index] = 0
            }
            destinationBuffer.frameLength = AVAudioFrameCount(targetOutputFrames)
        } else if producedOutputFrames > targetOutputFrames {
            destinationBuffer.frameLength = AVAudioFrameCount(targetOutputFrames)
        }

        do {
            let audioFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: destinationFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            try audioFile.write(from: destinationBuffer)
        } catch {
            throw VoiceCloneReferencePreprocessorError.exportFailed
        }
    }

    private struct DecodedFloatBuffer {
        let values: [Float]
        let sampleRate: Double
        let channelCount: Int
    }

    private func decodedFloatBuffer(
        from sampleBuffer: CMSampleBuffer
    ) throws -> DecodedFloatBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              ),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }

        let sampleRate = streamDescription.pointee.mSampleRate
        let channelCount = Int(streamDescription.pointee.mChannelsPerFrame)
        let byteCount = CMBlockBufferGetDataLength(dataBuffer)
        guard channelCount > 0,
              byteCount > 0,
              byteCount.isMultiple(of: MemoryLayout<Float>.size) else {
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }

        var values = [Float](
            repeating: 0,
            count: byteCount / MemoryLayout<Float>.size
        )
        let status = values.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr,
              values.count.isMultiple(of: channelCount) else {
            throw VoiceCloneReferencePreprocessorError.unsupportedOrCorruptAudio
        }
        return DecodedFloatBuffer(
            values: values,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    private func report(
        _ stage: VoiceCloneReferencePreparationStage,
        fraction: Double,
        to progress: ProgressHandler?
    ) {
        progress?(VoiceCloneReferencePreparationProgress(stage: stage, fraction: fraction))
    }

    /// A crash can bypass normal view cleanup. Purge only this feature's
    /// dedicated temporary root before the first new import. Doing it inside
    /// the actor keeps a potentially large directory removal off MainActor.
    private func purgeStaleWorkspacesIfNeeded() throws {
        guard !didPurgeStaleWorkspaces else { return }
        guard workspaces.isEmpty else { return }
        guard fileManager.fileExists(atPath: temporaryRootURL.path) else {
            didPurgeStaleWorkspaces = true
            return
        }
        do {
            try fileManager.removeItem(at: temporaryRootURL)
            didPurgeStaleWorkspaces = true
        } catch {
            // Do not silently waive cleanup for the rest of the process. A
            // retry gets another chance, while this import fails before a new
            // raw source is copied alongside stale sensitive material.
            throw VoiceCloneReferencePreprocessorError.cleanupFailed
        }
    }

}

// MARK: - Bounded frame analysis

struct VoiceCloneReferenceAnalysisFrame: Equatable, Sendable {
    let meanSquare: Double
    let clippingRatio: Double

    var rmsDBFS: Double {
        VoiceCloneReferenceSignalMath.decibels(forPower: meanSquare)
    }
}

private struct VoiceCloneReferenceFrameAccumulator {
    let samplesPerFrame: Int
    private(set) var frames: [VoiceCloneReferenceAnalysisFrame] = []
    private var sampleCount = 0
    private var sumSquares = 0.0
    private var clippingSampleCount = 0

    init(samplesPerFrame: Int) {
        self.samplesPerFrame = max(1, samplesPerFrame)
    }

    mutating func append(_ sample: Float) {
        let finiteSample = sample.isFinite ? Double(sample) : 0
        sampleCount += 1
        sumSquares += finiteSample * finiteSample
        if abs(finiteSample) >= 0.985 {
            clippingSampleCount += 1
        }
        if sampleCount >= samplesPerFrame {
            flush()
        }
    }

    mutating func finish() {
        if sampleCount > 0 {
            flush()
        }
    }

    private mutating func flush() {
        guard sampleCount > 0 else { return }
        frames.append(
            VoiceCloneReferenceAnalysisFrame(
                meanSquare: sumSquares / Double(sampleCount),
                clippingRatio: Double(clippingSampleCount) / Double(sampleCount)
            )
        )
        sampleCount = 0
        sumSquares = 0
        clippingSampleCount = 0
    }
}

private struct VoiceCloneReferenceCorrelationAccumulator {
    private var count = 0.0
    private var sumX = 0.0
    private var sumY = 0.0
    private var sumXX = 0.0
    private var sumYY = 0.0
    private var sumXY = 0.0

    mutating func append(_ x: Double, _ y: Double) {
        count += 1
        sumX += x
        sumY += y
        sumXX += x * x
        sumYY += y * y
        sumXY += x * y
    }

    var correlation: Double? {
        guard count >= 2 else { return nil }
        let numerator = count * sumXY - sumX * sumY
        let xVariance = count * sumXX - sumX * sumX
        let yVariance = count * sumYY - sumY * sumY
        let denominator = sqrt(max(0, xVariance) * max(0, yVariance))
        guard denominator > 1e-12 else { return nil }
        return min(1, max(-1, numerator / denominator))
    }
}

struct VoiceCloneReferenceCandidateSelectionResult: Equatable, Sendable {
    let candidates: [VoiceCloneReferenceCandidate]
    let overallRMSDBFS: Double
    let energyThresholdDBFS: Double
}

struct VoiceCloneReferenceCandidateSelector {
    let configuration: VoiceCloneReferencePreprocessorConfiguration

    func select(
        frames: [VoiceCloneReferenceAnalysisFrame],
        sourceDuration: TimeInterval
    ) throws -> VoiceCloneReferenceCandidateSelectionResult {
        guard !frames.isEmpty, sourceDuration > 0 else {
            throw VoiceCloneReferencePreprocessorError.noUsableSpeech
        }

        let frameDuration = configuration.analysisFrameDuration
        let energyValues = frames.map(\.rmsDBFS)
        let sortedEnergy = energyValues.sorted()
        let lowPercentile = percentile(sortedEnergy, fraction: 0.20)
        let highPercentile = percentile(sortedEnergy, fraction: 0.90)
        let noiseFloor = min(lowPercentile, highPercentile - 12)
        let dynamicThreshold = min(
            -24,
            max(-50, max(noiseFloor + 8, highPercentile - 18))
        )

        var speechMask = energyValues.map { $0 >= dynamicThreshold }
        fillShortGaps(
            in: &speechMask,
            maximumFrames: max(1, Int((0.30 / frameDuration).rounded()))
        )
        removeShortBursts(
            in: &speechMask,
            minimumFrames: max(1, Int((0.06 / frameDuration).rounded()))
        )

        let activePrefix = integerPrefix(speechMask.map { $0 ? 1 : 0 })
        let activePowerPrefix = doublePrefix(
            zip(frames, speechMask).map { frame, isActive in
                isActive ? frame.meanSquare : 0
            }
        )
        let inactivePowerPrefix = doublePrefix(
            zip(frames, speechMask).map { frame, isActive in
                isActive ? 0 : frame.meanSquare
            }
        )
        let clippingPrefix = doublePrefix(frames.map(\.clippingRatio))

        let windowFrameCount: Int
        let startFrames: [Int]
        if sourceDuration <= configuration.targetCandidateDuration + frameDuration {
            windowFrameCount = frames.count
            startFrames = [0]
        } else {
            windowFrameCount = min(
                frames.count,
                max(1, Int((configuration.targetCandidateDuration / frameDuration).rounded()))
            )
            let stepFrames = max(
                1,
                Int((configuration.candidateStepDuration / frameDuration).rounded())
            )
            let finalStartByFrames = max(0, frames.count - windowFrameCount)
            let finalStartByDuration = max(
                0,
                Int(floor(
                    (sourceDuration - configuration.targetCandidateDuration) / frameDuration
                ))
            )
            let finalStart = min(finalStartByFrames, finalStartByDuration)
            var starts = Array(stride(from: 0, through: finalStart, by: stepFrames))
            if starts.last != finalStart {
                starts.append(finalStart)
            }
            startFrames = starts
        }

        var viableCandidates: [VoiceCloneReferenceCandidate] = []
        viableCandidates.reserveCapacity(startFrames.count)

        for startFrame in startFrames {
            let endFrame = min(frames.count, startFrame + windowFrameCount)
            guard endFrame > startFrame else { continue }
            let count = endFrame - startFrame
            let duration = min(
                sourceDuration - Double(startFrame) * frameDuration,
                Double(count) * frameDuration
            )
            guard duration > 0 else { continue }

            let activeFrameCount = activePrefix[endFrame] - activePrefix[startFrame]
            let activeDuration = min(duration, Double(activeFrameCount) * frameDuration)
            let coverage = Double(activeFrameCount) / Double(count)
            guard activeDuration >= configuration.minimumActiveSpeechDuration,
                  coverage >= configuration.minimumSpeechCoverage else {
                continue
            }

            let activePower = activePowerPrefix[endFrame] - activePowerPrefix[startFrame]
            let inactiveFrameCount = count - activeFrameCount
            let inactivePower = inactivePowerPrefix[endFrame] - inactivePowerPrefix[startFrame]
            let activeMeanPower = activePower / Double(max(1, activeFrameCount))
            let activeRMS = VoiceCloneReferenceSignalMath.decibels(forPower: activeMeanPower)
            let noiseRMS: Double
            if inactiveFrameCount > 0 {
                noiseRMS = VoiceCloneReferenceSignalMath.decibels(
                    forPower: inactivePower / Double(inactiveFrameCount)
                )
            } else {
                noiseRMS = noiseFloor
            }
            let snr = min(60, max(-10, activeRMS - noiseRMS))
            let clippingRatio = (clippingPrefix[endFrame] - clippingPrefix[startFrame])
                / Double(count)
            let longestRun = longestActiveRun(
                speechMask,
                range: startFrame..<endFrame
            )
            let continuity = min(
                1,
                Double(longestRun) * frameDuration
                    / max(frameDuration, min(2, activeDuration))
            )
            let boundaryScore = boundaryScore(
                speechMask,
                range: startFrame..<endFrame,
                frameDuration: frameDuration
            )

            let coverageScore = normalized(coverage, lower: 0.30, upper: 0.90)
            let snrScore = normalized(snr, lower: 4, upper: 28)
            let rmsScore = normalized(activeRMS, lower: -38, upper: -12)
            let clippingScore = 1 - min(
                1,
                clippingRatio / max(0.000_001, configuration.maximumClippingRatio)
            )
            let score = clamp01(
                coverageScore * 0.32
                    + snrScore * 0.20
                    + rmsScore * 0.16
                    + continuity * 0.16
                    + boundaryScore * 0.10
                    + clippingScore * 0.06
            )

            let startTime = Double(startFrame) * frameDuration
            let candidateDuration = min(duration, configuration.targetCandidateDuration)
            let startMilliseconds = Int((startTime * 1_000).rounded())
            let durationMilliseconds = Int((candidateDuration * 1_000).rounded())
            viableCandidates.append(
                VoiceCloneReferenceCandidate(
                    id: String(
                        format: "candidate-%06d-%05d",
                        startMilliseconds,
                        durationMilliseconds
                    ),
                    startTime: startTime,
                    duration: candidateDuration,
                    score: score,
                    speechCoverage: coverage,
                    activeSpeechDuration: activeDuration,
                    estimatedSNRDB: snr,
                    activeRMSDBFS: activeRMS,
                    clippingRatio: clippingRatio,
                    continuity: continuity,
                    boundaryScore: boundaryScore
                )
            )
        }

        viableCandidates.sort {
            if abs($0.score - $1.score) > 0.000_000_1 {
                return $0.score > $1.score
            }
            if abs($0.speechCoverage - $1.speechCoverage) > 0.000_000_1 {
                return $0.speechCoverage > $1.speechCoverage
            }
            return $0.startTime < $1.startTime
        }

        var selectedCandidates: [VoiceCloneReferenceCandidate] = []
        for candidate in viableCandidates {
            let overlapsExisting = selectedCandidates.contains {
                candidate.overlapFraction(with: $0)
                    > configuration.maximumCandidateOverlapFraction
            }
            if !overlapsExisting {
                selectedCandidates.append(candidate)
            }
            if selectedCandidates.count >= configuration.maximumCandidateCount {
                break
            }
        }

        guard !selectedCandidates.isEmpty else {
            throw VoiceCloneReferencePreprocessorError.noUsableSpeech
        }
        let overallPower = frames.reduce(0) { $0 + $1.meanSquare } / Double(frames.count)
        return VoiceCloneReferenceCandidateSelectionResult(
            candidates: selectedCandidates,
            overallRMSDBFS: VoiceCloneReferenceSignalMath.decibels(forPower: overallPower),
            energyThresholdDBFS: dynamicThreshold
        )
    }

    private func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return -120 }
        let clampedFraction = min(1, max(0, fraction))
        let position = clampedFraction * Double(sortedValues.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        if lowerIndex == upperIndex { return sortedValues[lowerIndex] }
        let weight = position - Double(lowerIndex)
        return sortedValues[lowerIndex] * (1 - weight) + sortedValues[upperIndex] * weight
    }

    private func fillShortGaps(in mask: inout [Bool], maximumFrames: Int) {
        guard mask.count >= 3, maximumFrames > 0 else { return }
        var index = 0
        while index < mask.count {
            guard !mask[index] else {
                index += 1
                continue
            }
            let start = index
            while index < mask.count, !mask[index] { index += 1 }
            let end = index
            if start > 0,
               end < mask.count,
               end - start <= maximumFrames,
               mask[start - 1],
               mask[end] {
                for gapIndex in start..<end {
                    mask[gapIndex] = true
                }
            }
        }
    }

    private func removeShortBursts(in mask: inout [Bool], minimumFrames: Int) {
        guard !mask.isEmpty, minimumFrames > 1 else { return }
        var index = 0
        while index < mask.count {
            guard mask[index] else {
                index += 1
                continue
            }
            let start = index
            while index < mask.count, mask[index] { index += 1 }
            let end = index
            if end - start < minimumFrames {
                for burstIndex in start..<end {
                    mask[burstIndex] = false
                }
            }
        }
    }

    private func integerPrefix(_ values: [Int]) -> [Int] {
        var prefix = [Int](repeating: 0, count: values.count + 1)
        for index in values.indices {
            prefix[index + 1] = prefix[index] + values[index]
        }
        return prefix
    }

    private func doublePrefix(_ values: [Double]) -> [Double] {
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices {
            prefix[index + 1] = prefix[index] + values[index]
        }
        return prefix
    }

    private func longestActiveRun(_ mask: [Bool], range: Range<Int>) -> Int {
        var longest = 0
        var current = 0
        for index in range {
            if mask[index] {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private func boundaryScore(
        _ mask: [Bool],
        range: Range<Int>,
        frameDuration: TimeInterval
    ) -> Double {
        let edgeFrames = min(
            max(1, Int((0.40 / frameDuration).rounded())),
            max(1, range.count / 4)
        )
        let leading = range.lowerBound..<min(range.upperBound, range.lowerBound + edgeFrames)
        let trailing = max(range.lowerBound, range.upperBound - edgeFrames)..<range.upperBound
        let leadingQuiet = leading.reduce(0) { $0 + (mask[$1] ? 0 : 1) }
        let trailingQuiet = trailing.reduce(0) { $0 + (mask[$1] ? 0 : 1) }
        return Double(leadingQuiet + trailingQuiet)
            / Double(max(1, leading.count + trailing.count))
    }

    private func normalized(_ value: Double, lower: Double, upper: Double) -> Double {
        guard upper > lower else { return 0 }
        return clamp01((value - lower) / (upper - lower))
    }

    private func clamp01(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}

private enum VoiceCloneReferenceSignalMath {
    static func decibels(forPower power: Double) -> Double {
        guard power.isFinite, power > 1e-12 else { return -120 }
        return max(-120, min(6, 10 * log10(power)))
    }
}
