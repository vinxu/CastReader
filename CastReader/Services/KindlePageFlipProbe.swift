//
//  KindlePageFlipProbe.swift
//  CastReader
//
//  Typed evidence and a side-effect-free verdict for the manual Kindle Page Flip probe.
//  The probe is deliberately observational: collecting evidence never authorizes navigation,
//  page turning, scrolling, or content export.
//

import Foundation

enum KindlePageFlipProbe {
    static let evidenceVersion = 1

    // MARK: - Wire model

    struct RunEvidence {
        private(set) var lostEvents = false
        private(set) var positionUnsafe = false
        private(set) var observationFailed = false

        mutating func accept(_ response: PollResponse, afterSeq: UInt64) {
            lostEvents = lostEvents || response.overflowed(afterSeq: afterSeq)
            positionUnsafe = positionUnsafe || response.snapshot?.reader.positionStable == false ||
                response.events.contains { $0.kind == .navigationChanged }
            observationFailed = observationFailed || !response.ok || response.version != evidenceVersion ||
                response.events.contains { $0.kind == .error }
        }

        func verdict(for response: PollResponse) -> Verdict {
            if positionUnsafe { return .positionUnsafe }
            if lostEvents || observationFailed { return .inconclusive }
            return evaluate(response)
        }
    }

    struct PollResponse: Codable, Equatable, Sendable {
        let ok: Bool
        let version: Int
        let runID: String
        let active: Bool
        let seq: UInt64
        let droppedBeforeSeq: UInt64
        let hasMore: Bool
        let snapshot: Snapshot?
        let events: [Event]
        let error: String?

        init(
            ok: Bool,
            version: Int = KindlePageFlipProbe.evidenceVersion,
            runID: String,
            active: Bool,
            seq: UInt64,
            droppedBeforeSeq: UInt64 = 0,
            hasMore: Bool = false,
            snapshot: Snapshot? = nil,
            events: [Event] = [],
            error: String? = nil
        ) {
            self.ok = ok
            self.version = version
            self.runID = runID
            self.active = active
            self.seq = seq
            self.droppedBeforeSeq = droppedBeforeSeq
            self.hasMore = hasMore
            self.snapshot = snapshot
            self.events = events
            self.error = error
        }

        /// `droppedBeforeSeq` is the greatest sequence number no longer retained by JavaScript.
        /// A caller at exactly that cursor has not missed any newer event.
        func overflowed(afterSeq: UInt64) -> Bool {
            afterSeq < droppedBeforeSeq
        }
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let atMs: Double
        let mode: Mode
        let frame: FrameEvidence
        let reader: ReaderEvidence
        let root: RootEvidence?
        let cells: [CellEvidence]
        let summary: Summary

        init(
            atMs: Double,
            mode: Mode,
            frame: FrameEvidence,
            reader: ReaderEvidence,
            root: RootEvidence?,
            cells: [CellEvidence],
            summary: Summary
        ) {
            self.atMs = atMs
            self.mode = mode
            self.frame = frame
            self.reader = reader
            self.root = root
            self.cells = cells
            self.summary = summary
        }
    }

    enum Mode: Equatable, Sendable {
        case reader
        case pageFlipCandidate
        case pageFlipConfirmed
        case unknown(String)
    }

    struct FrameEvidence: Codable, Equatable, Sendable {
        let sameOrigin: Int
        let crossOrigin: Int
        let openShadowRoots: Int
        let closedShadowSuspected: Bool

        init(
            sameOrigin: Int = 0,
            crossOrigin: Int = 0,
            openShadowRoots: Int = 0,
            closedShadowSuspected: Bool = false
        ) {
            self.sameOrigin = sameOrigin
            self.crossOrigin = crossOrigin
            self.openShadowRoots = openShadowRoots
            self.closedShadowSuspected = closedShadowSuspected
        }
    }

    struct ReaderEvidence: Codable, Equatable, Sendable {
        let pageKey: String?
        let navigationSeq: Int?
        let initialPageKey: String?
        let initialNavigationSeq: Int?
        let positionStable: Bool?

        init(
            pageKey: String? = nil,
            navigationSeq: Int? = nil,
            initialPageKey: String? = nil,
            initialNavigationSeq: Int? = nil,
            positionStable: Bool? = nil
        ) {
            self.pageKey = pageKey
            self.navigationSeq = navigationSeq
            self.initialPageKey = initialPageKey
            self.initialNavigationSeq = initialNavigationSeq
            self.positionStable = positionStable
        }
    }

    struct RootEvidence: Codable, Equatable, Sendable {
        let nodeKey: String
        let tag: String
        let role: String?
        let confidence: Double
        let signals: [String]
        let scroll: ScrollEvidence
        let declaredTotal: Int?

        init(
            nodeKey: String,
            tag: String,
            role: String? = nil,
            confidence: Double,
            signals: [String] = [],
            scroll: ScrollEvidence,
            declaredTotal: Int? = nil
        ) {
            self.nodeKey = nodeKey
            self.tag = tag
            self.role = role
            self.confidence = confidence
            self.signals = signals
            self.scroll = scroll
            self.declaredTotal = declaredTotal
        }
    }

    struct ScrollEvidence: Codable, Equatable, Sendable {
        let nodeKey: String
        let top: Double
        let clientHeight: Double
        let scrollHeight: Double
        let atStart: Bool
        let atEnd: Bool

        init(
            nodeKey: String,
            top: Double,
            clientHeight: Double,
            scrollHeight: Double,
            atStart: Bool,
            atEnd: Bool
        ) {
            self.nodeKey = nodeKey
            self.top = top
            self.clientHeight = clientHeight
            self.scrollHeight = scrollHeight
            self.atStart = atStart
            self.atEnd = atEnd
        }
    }

    struct CellEvidence: Codable, Equatable, Sendable {
        let nodeKey: String
        let ordinal: Int?
        let setSize: Int?
        let location: String?
        let startPosition: String?
        let endPosition: String?
        let pageNumber: String?
        let norm: NormalizedRect
        let image: ImageEvidence?

        init(
            nodeKey: String,
            ordinal: Int? = nil,
            setSize: Int? = nil,
            location: String? = nil,
            startPosition: String? = nil,
            endPosition: String? = nil,
            pageNumber: String? = nil,
            norm: NormalizedRect,
            image: ImageEvidence? = nil
        ) {
            self.nodeKey = nodeKey
            self.ordinal = ordinal
            self.setSize = setSize
            self.location = location
            self.startPosition = startPosition
            self.endPosition = endPosition
            self.pageNumber = pageNumber
            self.norm = norm
            self.image = image
        }
    }

    struct NormalizedRect: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    struct PixelSize: Codable, Equatable, Sendable {
        let width: Int
        let height: Int

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    struct ImageEvidence: Codable, Equatable, Sendable {
        let kind: ImageKind
        let scheme: ResourceScheme
        let blobKey: String?
        let natural: PixelSize?
        let rendered: PixelSize
        let complete: Bool
        let byteSize: Int?

        init(
            kind: ImageKind,
            scheme: ResourceScheme,
            blobKey: String? = nil,
            natural: PixelSize? = nil,
            rendered: PixelSize,
            complete: Bool,
            byteSize: Int? = nil
        ) {
            self.kind = kind
            self.scheme = scheme
            self.blobKey = blobKey
            self.natural = natural
            self.rendered = rendered
            self.complete = complete
            self.byteSize = byteSize
        }
    }

    enum ImageKind: Equatable, Sendable {
        case image
        case canvas
        case svg
        case background
        case unknown(String)
    }

    enum ResourceScheme: Equatable, Sendable {
        case https
        case blob
        case data
        case none
        case other
        case unknown(String)
    }

    struct Summary: Codable, Equatable, Sendable {
        let pageFlipCandidateSeen: Bool
        let pageFlipConfirmed: Bool
        let sawStart: Bool
        let sawEnd: Bool
        let observedCellCount: Int
        let ordinalCount: Int
        let firstOrdinal: Int?
        let lastOrdinal: Int?
        let declaredTotal: Int?
        let ordinalGapCount: Int
        let directImageCount: Int
        let directHighResolutionImageCount: Int
        let previewHighResolutionSeen: Bool
        let networkImageCount: Int
        let blobCount: Int

        init(
            pageFlipCandidateSeen: Bool = false,
            pageFlipConfirmed: Bool = false,
            sawStart: Bool = false,
            sawEnd: Bool = false,
            observedCellCount: Int = 0,
            ordinalCount: Int = 0,
            firstOrdinal: Int? = nil,
            lastOrdinal: Int? = nil,
            declaredTotal: Int? = nil,
            ordinalGapCount: Int = 0,
            directImageCount: Int = 0,
            directHighResolutionImageCount: Int = 0,
            previewHighResolutionSeen: Bool = false,
            networkImageCount: Int = 0,
            blobCount: Int = 0
        ) {
            self.pageFlipCandidateSeen = pageFlipCandidateSeen
            self.pageFlipConfirmed = pageFlipConfirmed
            self.sawStart = sawStart
            self.sawEnd = sawEnd
            self.observedCellCount = observedCellCount
            self.ordinalCount = ordinalCount
            self.firstOrdinal = firstOrdinal
            self.lastOrdinal = lastOrdinal
            self.declaredTotal = declaredTotal
            self.ordinalGapCount = ordinalGapCount
            self.directImageCount = directImageCount
            self.directHighResolutionImageCount = directHighResolutionImageCount
            self.previewHighResolutionSeen = previewHighResolutionSeen
            self.networkImageCount = networkImageCount
            self.blobCount = blobCount
        }
    }

    struct Event: Codable, Equatable, Sendable {
        let seq: UInt64
        let atMs: Double
        let kind: EventKind
        let payload: JSONValue?

        init(seq: UInt64, atMs: Double, kind: EventKind, payload: JSONValue? = nil) {
            self.seq = seq
            self.atMs = atMs
            self.kind = kind
            self.payload = payload
        }
    }

    enum EventKind: Equatable, Sendable {
        case modeChanged
        case rootChanged
        case cellsObserved
        case scrollObserved
        case network
        case renderer
        case blobCreated
        case navigationChanged
        case error
        case unknown(String)
    }

    indirect enum JSONValue: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported Page Flip evidence JSON value"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null:
                try container.encodeNil()
            case .bool(let value):
                try container.encode(value)
            case .number(let value):
                try container.encode(value)
            case .string(let value):
                try container.encode(value)
            case .array(let value):
                try container.encode(value)
            case .object(let value):
                try container.encode(value)
            }
        }
    }

    // MARK: - Pure verdict evaluator

    enum Verdict: Equatable, Sendable {
        case notObserved
        case blockedFrameOrShadow
        case enumerable
        case thumbnailDirectCandidate
        case previewRenderRequired
        case positionUnsafe
        case inconclusive
        case unknown(String)
    }

    /// Evaluates only the supplied snapshot. It performs no I/O and never asks the reader to move.
    static func evaluate(_ evidence: PollResponse) -> Verdict {
        guard evidence.ok,
              evidence.version == evidenceVersion,
              !evidence.events.contains(where: { $0.kind == .error }),
              let snapshot = evidence.snapshot else {
            return .inconclusive
        }

        if snapshot.reader.positionStable == false {
            return .positionUnsafe
        }

        let summary = snapshot.summary
        guard summary.pageFlipConfirmed else {
            if snapshot.frame.closedShadowSuspected ||
                (summary.pageFlipCandidateSeen && snapshot.frame.crossOrigin > 0) {
                return .blockedFrameOrShadow
            }
            return summary.pageFlipCandidateSeen ? .inconclusive : .notObserved
        }

        guard snapshot.reader.positionStable == true,
              hasCompleteOrdinalCoverage(summary) else {
            return .inconclusive
        }

        let total = summary.declaredTotal ?? 0
        if summary.directImageCount >= total,
           summary.directHighResolutionImageCount >= total {
            return .thumbnailDirectCandidate
        }
        if summary.previewHighResolutionSeen {
            return .previewRenderRequired
        }
        return .enumerable
    }

    private static func hasCompleteOrdinalCoverage(_ summary: Summary) -> Bool {
        guard summary.sawStart,
              summary.sawEnd,
              summary.ordinalGapCount == 0,
              let declaredTotal = summary.declaredTotal,
              declaredTotal > 0,
              summary.ordinalCount == declaredTotal,
              let first = summary.firstOrdinal,
              let last = summary.lastOrdinal,
              first == 0 || first == 1 else {
            return false
        }
        return last - first + 1 == declaredTotal
    }
}

// MARK: - Forward-compatible string enums

extension KindlePageFlipProbe.Mode: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "reader": self = .reader
        case "pageFlipCandidate": self = .pageFlipCandidate
        case "pageFlipConfirmed": self = .pageFlipConfirmed
        default: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .reader: try container.encode("reader")
        case .pageFlipCandidate: try container.encode("pageFlipCandidate")
        case .pageFlipConfirmed: try container.encode("pageFlipConfirmed")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

extension KindlePageFlipProbe.ImageKind: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "image": self = .image
        case "canvas": self = .canvas
        case "svg": self = .svg
        case "background": self = .background
        default: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .image: try container.encode("image")
        case .canvas: try container.encode("canvas")
        case .svg: try container.encode("svg")
        case .background: try container.encode("background")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

extension KindlePageFlipProbe.ResourceScheme: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "https": self = .https
        case "blob": self = .blob
        case "data": self = .data
        case "none": self = .none
        case "other": self = .other
        default: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .https: try container.encode("https")
        case .blob: try container.encode("blob")
        case .data: try container.encode("data")
        case .none: try container.encode("none")
        case .other: try container.encode("other")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

extension KindlePageFlipProbe.EventKind: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "modeChanged": self = .modeChanged
        case "rootChanged": self = .rootChanged
        case "cellsObserved": self = .cellsObserved
        case "scrollObserved": self = .scrollObserved
        case "network": self = .network
        case "renderer": self = .renderer
        case "blobCreated": self = .blobCreated
        case "navigationChanged": self = .navigationChanged
        case "error": self = .error
        default: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .modeChanged: try container.encode("modeChanged")
        case .rootChanged: try container.encode("rootChanged")
        case .cellsObserved: try container.encode("cellsObserved")
        case .scrollObserved: try container.encode("scrollObserved")
        case .network: try container.encode("network")
        case .renderer: try container.encode("renderer")
        case .blobCreated: try container.encode("blobCreated")
        case .navigationChanged: try container.encode("navigationChanged")
        case .error: try container.encode("error")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

extension KindlePageFlipProbe.Verdict: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "notObserved": self = .notObserved
        case "blockedFrameOrShadow": self = .blockedFrameOrShadow
        case "enumerable": self = .enumerable
        case "thumbnailDirectCandidate": self = .thumbnailDirectCandidate
        case "previewRenderRequired": self = .previewRenderRequired
        case "positionUnsafe": self = .positionUnsafe
        case "inconclusive": self = .inconclusive
        default: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .notObserved: try container.encode("notObserved")
        case .blockedFrameOrShadow: try container.encode("blockedFrameOrShadow")
        case .enumerable: try container.encode("enumerable")
        case .thumbnailDirectCandidate: try container.encode("thumbnailDirectCandidate")
        case .previewRenderRequired: try container.encode("previewRenderRequired")
        case .positionUnsafe: try container.encode("positionUnsafe")
        case .inconclusive: try container.encode("inconclusive")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}
