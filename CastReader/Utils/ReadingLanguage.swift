//
//  ReadingLanguage.swift
//  CastReader
//
//  一本书用哪种语言朗读。
//
//  朗读语言决定音色（`AppSettings.voice(for:)`），也决定阅读器音色面板里能看到哪些音色，
//  而语言本身是**检测**出来的——检测会错。实时网页阅读器是逐页检测：一页章节标题、一段题记、
//  一行图注、一张整页插图上可用的文字太少，判别器只能猜，于是一本意大利语书读到这样一页就
//  突然换成别的语言的音色；面板又只列当前页语言的音色，用户看到的就是「App 忘了我的语音，
//  而且换不回来」（1.0.x 意大利语用户报告，[ReadingLanguagePolicy] 的存在理由）。
//

import Foundation

enum ReadingLanguagePolicy {

    enum Source: String, Equatable {
        case user
        case detected
        case remembered
        case fallback
    }

    struct Decision: Equatable {
        let language: String
        let source: Source

        /// 只有「这一页自己看清楚了」才值得写进记忆；沿用与兜底不能反过来固化自己。
        var shouldRemember: Bool { source == .detected }
    }

    /// 采信一页检测结果所需的最低把握。
    ///
    /// 实测（`ReadingLanguageTests.testThresholdsSitBetweenGuessworkAndRealPages`）：`NLLanguageRecognizer`
    /// 在文字极少时并不沉默，而是**自信地猜**——"III"→es 0.33、"Fig. 1"→pt 0.35、OCR 噪声→de 0.44，
    /// 一段 73 字符的乱码→pt 0.66。真正成句的正文一律 ≥ 0.90（六种稀疏页型 0.90–1.00，
    /// 整页散文 1.00）。0.75 落在 0.71（正确但太短）与 0.90（真实页面）之间的空档里。
    static let minimumConfidence: Double = 0.75

    /// 采信一页检测结果所需的最少可读字符。
    ///
    /// 把握本身不够：`www.example.com` 只有 13 个字符却拿到 0.94 的英语。字数才是「这一页
    /// 到底有没有正文」的度量。实测六种稀疏页型最多 68 字符（章节标题 14、短对白 15、
    /// 人名数字 18、题记 24、图注 27、版权页 68），而普通正文页 143–405 字符起步。
    /// 120（约二十个词）留出接近两倍的余量，且远低于任何真实页面。
    ///
    /// 宁可漏判也不误判：漏判只是沿用这本书已确定的语言，误判会当场换掉音色。
    static let minimumReadableCharacters: Int = 120

    /// 这一页**自己**看清楚了吗？看不清返回 nil，交由上层沿用本书语言。
    static func confidentLanguage(in evidence: LanguageDetector.Evidence) -> String? {
        guard evidence.confidence >= minimumConfidence,
              evidence.readableCharacterCount >= minimumReadableCharacters,
              !evidence.language.isEmpty else { return nil }
        return SupportedTTSLanguage.canonicalCode(evidence.language)
    }

    static func confidentLanguage(for text: String) -> String? {
        confidentLanguage(in: LanguageDetector.evidence(for: text))
    }

    /// 三级证据，**用户的显式选择永远排第一**：
    /// 1. `.user` —— 用户在朗读中亲手定下的语言。再自信的检测也不得推翻，否则下一页又把
    ///    用户刚改好的音色改回去，正是被投诉的那个行为；
    /// 2. `.detected` —— 本页**有把握**的检测（见 `confidentLanguage(in:)`）；
    /// 3. `.remembered` —— 这本书上一次确定下来的语言。证据不足时沿用它，而不是回落英语。
    static func resolve(
        userOverride: String?,
        confidentDetection: String?,
        remembered: String?,
        fallback: String = SupportedTTSLanguage.english.rawValue
    ) -> Decision {
        if let language = normalized(userOverride) {
            return Decision(language: language, source: .user)
        }
        if let language = normalized(confidentDetection) {
            return Decision(language: language, source: .detected)
        }
        if let language = normalized(remembered) {
            return Decision(language: language, source: .remembered)
        }
        return Decision(
            language: normalized(fallback) ?? SupportedTTSLanguage.english.rawValue,
            source: .fallback
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.trimmed.isEmpty else { return nil }
        return SupportedTTSLanguage.canonicalCode(value)
    }
}

/// 用户为某本书亲手定下的朗读语言，跨进程存活。
///
/// 与各书源自己的检测记忆分开存放：那些是「机器认为的」，这里是「用户说的」，两者优先级
/// 不同，混在一起就没法保证用户的选择不被检测覆盖。
final class ReadingLanguageStore {

    static let shared = ReadingLanguageStore()

    /// 一本书一条、每条几十字节，但书架可以无限增长，所以按最后使用时间截断。
    static let maximumEntries = 256

    /// 书源命名空间 + 书 ID。命名空间避免不同书源的同名 ID 相互覆盖。
    static func contentKey(namespace: String, bookID: String) -> String {
        let id = bookID.trimmed
        let space = namespace.trimmed
        guard !id.isEmpty, !space.isEmpty else { return "" }
        return "\(space):\(id)"
    }

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func override(for contentKey: String) -> String? {
        guard !contentKey.isEmpty else { return nil }
        return entries()[contentKey]?.language
    }

    func setOverride(_ language: String, for contentKey: String) {
        guard !contentKey.isEmpty else { return }
        let normalized = SupportedTTSLanguage.canonicalCode(language)
        var next = entries()
        next[contentKey] = Entry(language: normalized, updatedAt: now().timeIntervalSince1970)
        persist(next)
    }

    func clearOverride(for contentKey: String) {
        guard !contentKey.isEmpty else { return }
        var next = entries()
        guard next.removeValue(forKey: contentKey) != nil else { return }
        persist(next)
    }

    private struct Entry: Codable, Equatable {
        let language: String
        let updatedAt: TimeInterval
    }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: Keys.entries),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persist(_ entries: [String: Entry]) {
        var bounded = entries
        if bounded.count > Self.maximumEntries {
            bounded = Dictionary(
                uniqueKeysWithValues: entries
                    .sorted { $0.value.updatedAt > $1.value.updatedAt }
                    .prefix(Self.maximumEntries)
                    .map { ($0.key, $0.value) }
            )
        }
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: Keys.entries)
    }

    private enum Keys {
        static let entries = "reading_language_overrides_v1"
    }
}
