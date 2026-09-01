import Foundation

/// Product-safe limits and deterministic analysis parameters for uploaded
/// voice references. The server remains authoritative; these values only keep
/// obviously unusable or unnecessarily large material off the network.
struct VoiceCloneReferencePreprocessorConfiguration: Equatable, Sendable {
    static let standard = VoiceCloneReferencePreprocessorConfiguration()

    var maximumSourceBytes: Int64 = 200 * 1024 * 1024
    var maximumSourceDuration: TimeInterval = 10 * 60
    var minimumSourceDuration: TimeInterval = 3
    var targetCandidateDuration: TimeInterval = 10
    var outputSampleRate: Double = 24_000
    var maximumAnalysisSampleRate: Double = 16_000
    /// AVAssetReader's sample-rate conversion can trim a few converter frames
    /// from an otherwise exact-duration asset. This tolerance applies only to
    /// decoded coverage after the container has independently passed the hard
    /// three-second minimum.
    var maximumDecoderTrimDuration: TimeInterval = 0.005
    var analysisFrameDuration: TimeInterval = 0.02
    var candidateStepDuration: TimeInterval = 0.25
    var maximumCandidateCount = 3
    var maximumCandidateOverlapFraction = 0.35
    var minimumActiveSpeechDuration: TimeInterval = 3
    var minimumSpeechCoverage = 0.30
    var maximumClippingRatio = 0.004
    var maximumAnalyzedChannelCount = 8
    var copyBufferBytes = 256 * 1024
}

enum VoiceCloneReferencePreparationStage: String, Equatable, Sendable {
    case validating
    case copying
    case decoding
    case analyzing
    case exporting
    case completed
}

struct VoiceCloneReferencePreparationProgress: Equatable, Sendable {
    let stage: VoiceCloneReferencePreparationStage
    let fraction: Double

    init(stage: VoiceCloneReferencePreparationStage, fraction: Double) {
        self.stage = stage
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
    }
}

enum VoiceCloneReferenceChannelSelectionReason: String, Equatable, Sendable {
    case phaseCancellation
    case lowCorrelation
    case higherQuality
}

enum VoiceCloneReferenceChannelSelection: Equatable, Sendable {
    case mono
    case averaged(channelCount: Int)
    case channel(
        index: Int,
        channelCount: Int,
        reason: VoiceCloneReferenceChannelSelectionReason,
        correlation: Double?
    )

    var selectedChannelIndex: Int? {
        guard case .channel(let index, _, _, _) = self else { return nil }
        return index
    }
}

enum VoiceCloneReferenceWarning: Equatable, Sendable {
    case shorterThanTarget(duration: TimeInterval)
    case limitedSpeech(duration: TimeInterval)
    case lowSignal(activeRMSDBFS: Double)
    case lowEstimatedSNR(decibels: Double)
    case clippingDetected(ratio: Double)
    case singleChannelSelected(
        reason: VoiceCloneReferenceChannelSelectionReason,
        correlation: Double?
    )
}

struct VoiceCloneReferenceCandidate: Identifiable, Equatable, Sendable {
    /// Deterministic for the same decoded source and analysis configuration.
    let id: String
    let startTime: TimeInterval
    let duration: TimeInterval
    let score: Double
    let speechCoverage: Double
    let activeSpeechDuration: TimeInterval
    let estimatedSNRDB: Double?
    let activeRMSDBFS: Double
    let clippingRatio: Double
    let continuity: Double
    let boundaryScore: Double

    var endTime: TimeInterval { startTime + duration }

    func overlapFraction(with other: VoiceCloneReferenceCandidate) -> Double {
        let intersection = max(0, min(endTime, other.endTime) - max(startTime, other.startTime))
        let denominator = max(0.001, min(duration, other.duration))
        return intersection / denominator
    }
}

struct VoiceCloneReferenceAnalysis: Equatable, Sendable {
    let workspaceID: UUID
    let sourceFilename: String
    let sourceByteCount: Int64
    let sourceDuration: TimeInterval
    let analysisSampleRate: Double
    let sourceChannelCount: Int
    let channelSelection: VoiceCloneReferenceChannelSelection
    let candidates: [VoiceCloneReferenceCandidate]
    let warnings: [VoiceCloneReferenceWarning]

    var preferredCandidate: VoiceCloneReferenceCandidate? { candidates.first }
}

struct VoiceClonePreparedReference: Equatable, Sendable {
    let workspaceID: UUID
    let canonicalURL: URL
    let canonicalByteCount: Int64
    let analysis: VoiceCloneReferenceAnalysis
    let selectedCandidate: VoiceCloneReferenceCandidate
}

enum VoiceCloneReferencePreprocessorError: Error, LocalizedError, Equatable, Sendable {
    case invalidSourceURL
    case sourceUnavailable
    case sourceEmpty
    case sourceTooLarge(maximumBytes: Int64)
    case sourceTooLong(maximumDuration: TimeInterval)
    case sourceTooShort(minimumDuration: TimeInterval)
    case protectedAudio
    case noAudioTrack
    case unsupportedOrCorruptAudio
    case noUsableSpeech
    case excessiveClipping
    case candidateNotFound
    case workspaceExpired
    case exportFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            return AppLocalized("请选择本地音频文件")
        case .sourceUnavailable:
            return AppLocalized("所选音频暂不可用，请先下载到设备后重试")
        case .sourceEmpty:
            return AppLocalized("所选音频文件是空的")
        case .sourceTooLarge(let maximumBytes):
            return String(
                format: AppLocalized("音频文件必须小于 %lld MB"),
                maximumBytes / 1024 / 1024
            )
        case .sourceTooLong(let maximumDuration):
            return String(
                format: AppLocalized("音频文件不能超过 %lld 分钟"),
                Int64(maximumDuration / 60)
            )
        case .sourceTooShort(let minimumDuration):
            return String(
                format: AppLocalized("音频至少需要 %lld 秒"),
                Int64(minimumDuration)
            )
        case .protectedAudio:
            return AppLocalized("受保护的音频无法使用，请选择你有权使用的普通本地文件")
        case .noAudioTrack:
            return AppLocalized("文件中没有可读取的音轨")
        case .unsupportedOrCorruptAudio:
            return AppLocalized("无法读取此音频，文件可能已损坏或格式不受支持")
        case .noUsableSpeech:
            return AppLocalized("没有找到足够清晰、连续的人声，请换一个文件")
        case .excessiveClipping:
            return AppLocalized("音频破音或失真过重，请换一个文件")
        case .candidateNotFound:
            return AppLocalized("所选声音片段已失效，请重新选择")
        case .workspaceExpired:
            return AppLocalized("临时音频已失效，请重新选择文件")
        case .exportFailed:
            return AppLocalized("无法准备所选声音片段，请重试")
        case .cleanupFailed:
            return AppLocalized("临时声音文件清理失败")
        }
    }
}
