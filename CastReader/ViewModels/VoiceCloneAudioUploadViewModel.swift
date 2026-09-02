import AVFoundation
import Combine
import Foundation

/// Owns the temporary, device-only lifecycle for an imported voice reference.
/// The original file never reaches VoiceCloneService; only `preparedReference`
/// is eligible for upload after the user previews it and confirms consent.
@MainActor
final class VoiceCloneAudioUploadViewModel: NSObject, ObservableObject,
    AVAudioPlayerDelegate
{
    enum State: Equatable {
        case idle
        case processing
        case review
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: VoiceCloneReferencePreparationProgress?
    @Published private(set) var analysis: VoiceCloneReferenceAnalysis?
    @Published private(set) var preparedReference: VoiceClonePreparedReference?
    @Published private(set) var selectedCandidateID: String?
    @Published private(set) var previewedCandidateID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPlaying = false
    @Published var consentConfirmed = false

    private let preprocessor: VoiceCloneReferencePreprocessor
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var player: AVAudioPlayer?
    private var playingCandidateID: String?
    private var ownsActiveAudioSession = false

    init(preprocessor: VoiceCloneReferencePreprocessor = .shared) {
        self.preprocessor = preprocessor
        super.init()
    }

    var canCreate: Bool {
        Self.creationAllowed(
            state: state,
            hasPreparedReference: preparedReference != nil,
            selectedCandidateID: selectedCandidateID,
            previewedCandidateID: previewedCandidateID,
            consentConfirmed: consentConfirmed
        )
    }

    var hasPreviewedSelectedCandidate: Bool {
        guard let selectedCandidateID else { return false }
        return previewedCandidateID == selectedCandidateID
    }

    static func creationAllowed(
        state: State,
        hasPreparedReference: Bool,
        selectedCandidateID: String?,
        previewedCandidateID: String?,
        consentConfirmed: Bool
    ) -> Bool {
        state == .review
            && hasPreparedReference
            && selectedCandidateID != nil
            && previewedCandidateID == selectedCandidateID
            && consentConfirmed
    }

    static func previewedCandidateIDAfterPlayback(
        playedCandidateID: String?,
        completedSuccessfully: Bool,
        existingPreviewedCandidateID: String?
    ) -> String? {
        guard completedSuccessfully, let playedCandidateID else {
            return existingPreviewedCandidateID
        }
        return playedCandidateID
    }

    var selectedCandidate: VoiceCloneReferenceCandidate? {
        guard let selectedCandidateID else { return nil }
        return analysis?.candidates.first { $0.id == selectedCandidateID }
    }

    func importAudio(from sourceURL: URL) {
        let priorAnalysis = analysis
        beginOperation(resetWorkspaceState: true)
        let token = operationID
        state = .processing
        progress = VoiceCloneReferencePreparationProgress(stage: .validating, fraction: 0)

        operationTask = Task { [weak self] in
            guard let self else { return }
            if let priorAnalysis {
                try? await preprocessor.cleanup(priorAnalysis)
            }
            do {
                let analyzed = try await preprocessor.analyze(
                    sourceURL: sourceURL,
                    requiresSecurityScopedAccess: true,
                    progress: progressHandler(for: token)
                )
                try Task.checkCancellation()
                guard operationID == token,
                      let preferred = analyzed.preferredCandidate else {
                    try? await preprocessor.cleanup(analyzed)
                    return
                }
                analysis = analyzed
                selectedCandidateID = preferred.id
                let prepared = try await preprocessor.prepare(
                    analysis: analyzed,
                    candidateID: preferred.id,
                    progress: progressHandler(for: token)
                )
                try Task.checkCancellation()
                guard operationID == token else {
                    try? await preprocessor.cleanup(prepared)
                    return
                }
                preparedReference = prepared
                progress = VoiceCloneReferencePreparationProgress(stage: .completed, fraction: 1)
                state = .review
            } catch is CancellationError {
                guard operationID == token else { return }
                state = .idle
                progress = nil
            } catch {
                guard operationID == token else { return }
                errorMessage = error.localizedDescription
                state = .failed
                progress = nil
            }
        }
    }

    func selectCandidate(_ candidate: VoiceCloneReferenceCandidate) {
        guard let analysis,
              analysis.candidates.contains(where: { $0.id == candidate.id }),
              candidate.id != selectedCandidateID || preparedReference == nil else { return }
        stopPreview()
        beginOperation(resetWorkspaceState: false)
        let token = operationID
        selectedCandidateID = candidate.id
        preparedReference = nil
        previewedCandidateID = nil
        errorMessage = nil
        state = .processing
        progress = VoiceCloneReferencePreparationProgress(stage: .exporting, fraction: 0.82)

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await preprocessor.prepare(
                    analysis: analysis,
                    candidateID: candidate.id,
                    progress: progressHandler(for: token)
                )
                try Task.checkCancellation()
                guard operationID == token else { return }
                preparedReference = prepared
                progress = VoiceCloneReferencePreparationProgress(stage: .completed, fraction: 1)
                state = .review
            } catch is CancellationError {
                guard operationID == token else { return }
                state = .review
            } catch {
                guard operationID == token else { return }
                errorMessage = error.localizedDescription
                state = .failed
                progress = nil
            }
        }
    }

    func togglePreview() {
        guard let url = preparedReference?.canonicalURL else { return }
        if isPlaying {
            stopPreview()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            ownsActiveAudioSession = true
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                throw VoiceCloneReferencePreprocessorError.exportFailed
            }
            self.player = player
            playingCandidateID = selectedCandidateID
            isPlaying = true
            errorMessage = nil
        } catch {
            player = nil
            playingCandidateID = nil
            isPlaying = false
            deactivateAudioSessionIfOwned()
            errorMessage = error.localizedDescription
        }
    }

    func stopPreview() {
        player?.stop()
        player = nil
        playingCandidateID = nil
        isPlaying = false
        deactivateAudioSessionIfOwned()
    }

    func cancelProcessing() {
        beginOperation(resetWorkspaceState: false)
        if analysis != nil, preparedReference != nil {
            state = .review
        } else {
            state = .idle
        }
        progress = nil
    }

    func clearError() {
        errorMessage = nil
        if analysis != nil, preparedReference != nil {
            state = .review
        } else if state == .failed {
            state = .idle
        }
    }

    /// Safe to call repeatedly from cancel, successful creation, account
    /// changes, and `onDisappear`.
    func cleanup() {
        let staleAnalysis = analysis
        beginOperation(resetWorkspaceState: true)
        state = .idle
        if let staleAnalysis {
            Task {
                try? await preprocessor.cleanup(staleAnalysis)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            let finishedCandidateID = self.playingCandidateID
            self.player = nil
            self.playingCandidateID = nil
            self.isPlaying = false
            self.previewedCandidateID = Self.previewedCandidateIDAfterPlayback(
                playedCandidateID: finishedCandidateID,
                completedSuccessfully: flag,
                existingPreviewedCandidateID: self.previewedCandidateID
            )
            if !flag {
                self.errorMessage = AppLocalized("音频播放失败，请重试")
            }
            self.deactivateAudioSessionIfOwned()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.player = nil
            self.playingCandidateID = nil
            self.isPlaying = false
            self.errorMessage = error?.localizedDescription
                ?? AppLocalized("音频播放失败，请重试")
            self.deactivateAudioSessionIfOwned()
        }
    }

    private func beginOperation(resetWorkspaceState: Bool) {
        operationTask?.cancel()
        operationTask = nil
        operationID = UUID()
        stopPreview()
        errorMessage = nil
        progress = nil
        if resetWorkspaceState {
            analysis = nil
            preparedReference = nil
            selectedCandidateID = nil
            previewedCandidateID = nil
            consentConfirmed = false
        }
    }

    private func progressHandler(
        for token: UUID
    ) -> @Sendable (VoiceCloneReferencePreparationProgress) -> Void {
        { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == token else { return }
                self.progress = update
            }
        }
    }

    private func deactivateAudioSessionIfOwned() {
        guard ownsActiveAudioSession else { return }
        ownsActiveAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
