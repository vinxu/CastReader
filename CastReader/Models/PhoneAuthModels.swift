//
//  PhoneAuthModels.swift
//  CastReader
//
//  中国区手机号登录的纯逻辑：号码规范化、脱敏、重发倒计时、错误分流。
//  这里刻意不含网络与 UI，便于单测覆盖边界。
//

import Foundation

// MARK: - 号码

/// 中国大陆手机号。只支持 +86，因为手机号登录只在中国区开放。
enum ChinaPhoneNumber {

    static let countryCode = "+86"

    /// 把用户输入规范化成 11 位号码；不合法返回 nil。
    ///
    /// 容忍空格、连字符、括号，以及用户自己带上的 `+86` / `0086` / `86` 前缀。
    static func normalize(_ raw: String) -> String? {
        var digits = raw.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map(String.init)
            .joined()

        if digits.hasPrefix("0086") {
            digits = String(digits.dropFirst(4))
        } else if digits.hasPrefix("86"), digits.count > 11 {
            digits = String(digits.dropFirst(2))
        }

        guard isValidLocalNumber(digits) else { return nil }
        return digits
    }

    /// 11 位、以 1 开头、第二位 3–9。
    static func isValidLocalNumber(_ digits: String) -> Bool {
        guard digits.count == 11 else { return false }
        guard digits.allSatisfy({ $0.isNumber }) else { return false }
        guard digits.hasPrefix("1") else { return false }
        let second = digits[digits.index(digits.startIndex, offsetBy: 1)]
        return ("3"..."9").contains(String(second))
    }

    /// 发给服务端的 E.164 形式。
    static func e164(_ localNumber: String) -> String {
        countryCode + localNumber
    }

    /// 展示用脱敏：138****8000。日志与埋点里一律用这个，绝不写原号。
    static func masked(_ raw: String) -> String {
        guard let digits = normalize(raw) else { return "" }
        let head = digits.prefix(3)
        let tail = digits.suffix(4)
        return "\(head)****\(tail)"
    }
}

// MARK: - 验证码

enum PhoneVerificationCode {
    static let length = 6

    /// 只保留数字并截断到 6 位。输入框直接用这个过滤，避免用户粘贴到多余字符。
    static func sanitize(_ raw: String) -> String {
        String(
            raw.unicodeScalars
                .filter { CharacterSet.decimalDigits.contains($0) }
                .map(String.init)
                .joined()
                .prefix(length)
        )
    }

    static func isComplete(_ code: String) -> Bool {
        code.count == length && code.allSatisfy(\.isNumber)
    }
}

/// 重发倒计时。服务端给的 `resendAfter` 是唯一真相，客户端只做展示与按钮门禁。
struct PhoneResendCountdown: Equatable {
    /// 允许下一次重发的时间点。
    private(set) var readyAt: Date?

    init(readyAt: Date? = nil) {
        self.readyAt = readyAt
    }

    mutating func start(seconds: Int, now: Date = Date()) {
        guard seconds > 0 else {
            readyAt = nil
            return
        }
        readyAt = now.addingTimeInterval(TimeInterval(seconds))
    }

    mutating func clear() {
        readyAt = nil
    }

    func remainingSeconds(now: Date = Date()) -> Int {
        guard let readyAt else { return 0 }
        return max(0, Int(readyAt.timeIntervalSince(now).rounded(.up)))
    }

    func canResend(now: Date = Date()) -> Bool {
        remainingSeconds(now: now) == 0
    }
}

// MARK: - 错误

enum PhoneAuthError: Error, Equatable, LocalizedError {
    case invalidPhone
    case invalidCode
    case codeExpired
    /// 触发风控频控；`retryAfter` 是服务端要求的等待秒数。
    case tooManyRequests(retryAfter: Int)
    case network
    case server(status: Int, message: String?)
    case notAvailableInRegion

    var errorDescription: String? {
        switch self {
        case .invalidPhone:
            return AppLocalized("请输入正确的手机号")
        case .invalidCode:
            return AppLocalized("验证码不正确，请重新输入")
        case .codeExpired:
            return AppLocalized("验证码已过期，请重新获取")
        case .tooManyRequests(let retryAfter):
            if retryAfter > 0 {
                return String(format: AppLocalized("操作太频繁，请 %d 秒后再试"), retryAfter)
            }
            return AppLocalized("操作太频繁，请稍后再试")
        case .network:
            return AppLocalized("网络连接失败，请检查网络后重试")
        case .server(_, let message):
            if let message, !message.isEmpty { return message }
            return AppLocalized("服务暂时不可用，请稍后再试")
        case .notAvailableInRegion:
            return AppLocalized("当前地区暂不支持手机号登录")
        }
    }

    /// 把服务端错误码映射成本地语义。未知码归到 `.server`，保留原始提示。
    static func from(status: Int, code: String?, message: String?) -> PhoneAuthError {
        switch code {
        case "invalid_phone": return .invalidPhone
        case "invalid_code": return .invalidCode
        case "code_expired": return .codeExpired
        case "rate_limited":
            return .tooManyRequests(retryAfter: 0)
        default:
            if status == 429 { return .tooManyRequests(retryAfter: 0) }
            return .server(status: status, message: message)
        }
    }
}

// MARK: - 服务端载荷

/// `POST /api/mobile-auth/sms/send` 的结果。
struct PhoneCodeChallenge: Equatable {
    /// 验证码有效期（秒）。
    let ttlSeconds: Int
    /// 多久之后允许重发（秒）。
    let resendAfterSeconds: Int
    /// 本次是否走了本地预设直通（后端不可达时的兜底）。
    var usedLocalFallback: Bool = false

    static let fallback = PhoneCodeChallenge(ttlSeconds: 300, resendAfterSeconds: 60)
}

/// `POST /api/mobile-auth/sms/verify` 的结果。
struct PhoneSignInResult: Equatable {
    let sessionToken: String
    let userId: String
    let isNewUser: Bool
    let displayName: String?
    /// 本次是否走了本地预设直通。
    var usedLocalFallback: Bool = false
}
