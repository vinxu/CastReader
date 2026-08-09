//
//  PhoneAuthTests.swift
//  CastReaderTests
//
//  中国区手机号登录的边界、错误分流与本地预设直通。
//

import XCTest
@testable import CastReader

final class PhoneAuthTests: XCTestCase {

    // MARK: - 号码规范化

    func testNormalizeAcceptsPlainElevenDigits() {
        XCTAssertEqual(ChinaPhoneNumber.normalize("13800138000"), "13800138000")
    }

    func testNormalizeStripsFormattingAndCountryCode() {
        let variants = [
            "138 0013 8000",
            "138-0013-8000",
            "+86 13800138000",
            "8613800138000",
            "008613800138000",
            "(138) 0013-8000",
        ]
        for raw in variants {
            XCTAssertEqual(
                ChinaPhoneNumber.normalize(raw),
                "13800138000",
                "应能规范化: \(raw)"
            )
        }
    }

    func testNormalizeRejectsInvalidNumbers() {
        let invalid = [
            "",
            "1380013800",      // 10 位
            "138001380001",    // 12 位
            "23800138000",     // 不以 1 开头
            "12800138000",     // 第二位是 2
            "abcdefghijk",
        ]
        for raw in invalid {
            XCTAssertNil(ChinaPhoneNumber.normalize(raw), "应判为非法: \(raw)")
        }
    }

    func testE164AddsCountryCode() {
        XCTAssertEqual(ChinaPhoneNumber.e164("13800138000"), "+8613800138000")
    }

    /// 日志与展示只允许出现脱敏号码。
    func testMaskedHidesMiddleDigits() {
        XCTAssertEqual(ChinaPhoneNumber.masked("13800138000"), "138****8000")
        XCTAssertEqual(ChinaPhoneNumber.masked("+86 138 0013 8000"), "138****8000")
        XCTAssertEqual(ChinaPhoneNumber.masked("123"), "")
    }

    // MARK: - 验证码

    func testSanitizeKeepsAtMostSixDigits() {
        XCTAssertEqual(PhoneVerificationCode.sanitize("123456"), "123456")
        XCTAssertEqual(PhoneVerificationCode.sanitize("12 34 56"), "123456")
        XCTAssertEqual(PhoneVerificationCode.sanitize("1234567890"), "123456")
        XCTAssertEqual(PhoneVerificationCode.sanitize("abc123"), "123")
        XCTAssertEqual(PhoneVerificationCode.sanitize(""), "")
    }

    func testIsCompleteRequiresSixDigits() {
        XCTAssertTrue(PhoneVerificationCode.isComplete("123456"))
        XCTAssertFalse(PhoneVerificationCode.isComplete("12345"))
        XCTAssertFalse(PhoneVerificationCode.isComplete(""))
    }

    // MARK: - 重发倒计时

    func testCountdownCountsDownAndUnlocks() {
        let now = Date()
        var countdown = PhoneResendCountdown()
        XCTAssertTrue(countdown.canResend(now: now))

        countdown.start(seconds: 60, now: now)
        XCTAssertEqual(countdown.remainingSeconds(now: now), 60)
        XCTAssertFalse(countdown.canResend(now: now))

        XCTAssertEqual(countdown.remainingSeconds(now: now.addingTimeInterval(59)), 1)
        XCTAssertTrue(countdown.canResend(now: now.addingTimeInterval(60)))
        // 超时之后不能出现负数。
        XCTAssertEqual(countdown.remainingSeconds(now: now.addingTimeInterval(600)), 0)
    }

    func testCountdownWithNonPositiveSecondsStaysUnlocked() {
        let now = Date()
        var countdown = PhoneResendCountdown()
        countdown.start(seconds: 0, now: now)
        XCTAssertTrue(countdown.canResend(now: now))
        countdown.start(seconds: -5, now: now)
        XCTAssertTrue(countdown.canResend(now: now))
    }

    // MARK: - 错误分流

    func testServerErrorCodesMapToLocalSemantics() {
        XCTAssertEqual(
            PhoneAuthError.from(status: 400, code: "invalid_phone", message: nil),
            .invalidPhone
        )
        XCTAssertEqual(
            PhoneAuthError.from(status: 400, code: "invalid_code", message: nil),
            .invalidCode
        )
        XCTAssertEqual(
            PhoneAuthError.from(status: 400, code: "code_expired", message: nil),
            .codeExpired
        )
        XCTAssertEqual(
            PhoneAuthError.from(status: 429, code: nil, message: nil),
            .tooManyRequests(retryAfter: 0)
        )
    }

    func testUnknownServerErrorKeepsOriginalMessage() {
        let error = PhoneAuthError.from(status: 500, code: "boom", message: "服务开小差了")
        XCTAssertEqual(error, .server(status: 500, message: "服务开小差了"))
        XCTAssertEqual(error.errorDescription, "服务开小差了")
    }

    /// 频控必须把服务端给的等待秒数带出来，界面才能起准确倒计时。
    func testRateLimitCarriesRetryAfterFromPayload() throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["code": "rate_limited", "data": ["retryAfter": 42]]
        )
        let error = PhoneAuthService.decodeError(status: 429, data: body)
        XCTAssertEqual(error, .tooManyRequests(retryAfter: 42))
    }

    func testDecodeErrorHandlesNonJSONBody() {
        let error = PhoneAuthService.decodeError(status: 502, data: Data("bad gateway".utf8))
        XCTAssertEqual(error, .server(status: 502, message: nil))
    }

    func testDataObjectUnwrapsEnvelopeAndFallsBackToRoot() throws {
        let wrapped = try JSONSerialization.data(
            withJSONObject: ["code": 0, "data": ["ttl": 300]]
        )
        XCTAssertEqual(PhoneAuthService.dataObject(from: wrapped)?["ttl"] as? Int, 300)

        let bare = try JSONSerialization.data(withJSONObject: ["ttl": 120])
        XCTAssertEqual(PhoneAuthService.dataObject(from: bare)?["ttl"] as? Int, 120)
    }

    /// 服务端的明确业务拒绝不能被本地兜底掩盖，否则用户会以为随便输都能进。
    func testDefinitiveRejectionsAreNeverMaskedByFallback() {
        for error in [
            PhoneAuthError.invalidPhone,
            .invalidCode,
            .codeExpired,
            .tooManyRequests(retryAfter: 10),
            .notAvailableInRegion,
        ] {
            XCTAssertTrue(
                PhoneAuthService.isDefinitiveRejection(error),
                "\(error) 必须如实报错"
            )
        }
        // 网络/服务端不可用才允许走兜底。
        XCTAssertFalse(PhoneAuthService.isDefinitiveRejection(.network))
        XCTAssertFalse(PhoneAuthService.isDefinitiveRejection(.server(status: 500, message: nil)))
    }

    // MARK: - 区域门禁

    /// 手机号登录只在中国区开放；其他地区调用必须直接拒绝，
    /// 不能发出任何网络请求。
    @MainActor
    func testPhoneAuthIsRejectedOutsideChina() async {
        let key = "appRegion.v1.storefrontCountryCode"
        let overrideKey = "appRegion.v1.override"
        let saved = UserDefaults.standard.string(forKey: key)
        let savedOverride = UserDefaults.standard.string(forKey: overrideKey)
        UserDefaults.standard.removeObject(forKey: overrideKey)
        UserDefaults.standard.set("USA", forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            if let savedOverride {
                UserDefaults.standard.set(savedOverride, forKey: overrideKey)
            }
        }

        let transport = FailIfCalledTransport()
        let service = PhoneAuthService(transport: transport)
        XCTAssertFalse(service.isAvailable)

        do {
            _ = try await service.sendCode(phone: "13800138000")
            XCTFail("非中国区不应放行手机号登录")
        } catch let error as PhoneAuthError {
            XCTAssertEqual(error, .notAvailableInRegion)
        } catch {
            XCTFail("意外错误类型: \(error)")
        }
        XCTAssertFalse(transport.wasCalled, "非中国区不得发出任何请求")
    }

    // MARK: - 网络往返

    @MainActor
    func testSendCodeParsesChallenge() async throws {
        try await withChinaRegion {
            let transport = StubTransport(
                status: 200,
                body: ["data": ["ttl": 300, "resendAfter": 60]]
            )
            let service = PhoneAuthService(transport: transport)
            let challenge = try await service.sendCode(phone: "138 0013 8000")

            XCTAssertEqual(challenge.ttlSeconds, 300)
            XCTAssertEqual(challenge.resendAfterSeconds, 60)
            XCTAssertFalse(challenge.usedLocalFallback)
            // 号码必须以 E.164 发出。
            XCTAssertEqual(transport.lastBody?["phone"] as? String, "+8613800138000")
            XCTAssertEqual(transport.lastBody?["scene"] as? String, "sign_in")
        }
    }

    @MainActor
    func testVerifyReturnsSessionAndUser() async throws {
        try await withChinaRegion {
            let transport = StubTransport(
                status: 200,
                body: [
                    "data": [
                        "sessionToken": "cms_abc123",
                        "userId": "user_42",
                        "isNewUser": true,
                    ]
                ]
            )
            let service = PhoneAuthService(transport: transport)
            let result = try await service.verify(phone: "13800138000", code: "123456")

            XCTAssertEqual(result.sessionToken, "cms_abc123")
            XCTAssertEqual(result.userId, "user_42")
            XCTAssertTrue(result.isNewUser)
            XCTAssertFalse(result.usedLocalFallback)
        }
    }

    @MainActor
    func testVerifyRejectsShortCodeWithoutNetworkCall() async throws {
        try await withChinaRegion {
            let transport = FailIfCalledTransport()
            let service = PhoneAuthService(transport: transport)
            do {
                _ = try await service.verify(phone: "13800138000", code: "12")
                XCTFail("不完整验证码不应发起请求")
            } catch let error as PhoneAuthError {
                XCTAssertEqual(error, .invalidCode)
            }
            XCTAssertFalse(transport.wasCalled)
        }
    }

    // MARK: - 本地预设直通

    /// 后端不可达时，预设码放行——否则境内后端上线前整个中国区停在登录页。
    @MainActor
    func testPresetCodeSignsInWhenBackendUnreachable() async throws {
        try await withChinaRegion {
            let service = PhoneAuthService(transport: UnreachableTransport())
            let result = try await service.verify(
                phone: "13800138000",
                code: PhoneAuthService.LocalFallback.presetCode
            )
            XCTAssertTrue(result.usedLocalFallback)
            XCTAssertTrue(result.sessionToken.hasPrefix("cms_"))
            XCTAssertEqual(result.displayName, "138****8000")
        }
    }

    /// 同一号码每次都拿到同一个本地 id，历史与 Pro 态才连续；
    /// 不同号码必须分开。直接测纯函数，避免依赖多次网络往返的时序。
    func testLocalFallbackUserIdIsStablePerPhone() {
        let a1 = PhoneAuthService.LocalFallback.localUserId(for: "13800138000")
        let a2 = PhoneAuthService.LocalFallback.localUserId(for: "13800138000")
        let b = PhoneAuthService.LocalFallback.localUserId(for: "13900139000")

        XCTAssertEqual(a1, a2, "同一号码必须映射到同一个本地账号")
        XCTAssertNotEqual(a1, b, "不同号码不能共用账号")

        // 会话 token 沿用 cms_ 前缀，下游会话判断无需分叉。
        XCTAssertTrue(
            PhoneAuthService.LocalFallback.localSessionToken(for: "13800138000")
                .hasPrefix("cms_")
        )
    }

    /// 非预设码在后端不可达时仍然报网络错误——不能让用户以为随便输都能进。
    @MainActor
    func testNonPresetCodeStillFailsWhenBackendUnreachable() async throws {
        try await withChinaRegion {
            let service = PhoneAuthService(transport: UnreachableTransport())
            do {
                _ = try await service.verify(phone: "13800138000", code: "123456")
                XCTFail("普通验证码在后端不可达时不应登录成功")
            } catch let error as PhoneAuthError {
                XCTAssertEqual(error, .network)
            }
        }
    }

    /// 服务端明确说验证码错，就算是预设码也要如实报错。
    @MainActor
    func testServerRejectionBeatsPresetCode() async throws {
        try await withChinaRegion {
            let transport = StubTransport(status: 400, body: ["code": "invalid_code"])
            let service = PhoneAuthService(transport: transport)
            do {
                _ = try await service.verify(
                    phone: "13800138000",
                    code: PhoneAuthService.LocalFallback.presetCode
                )
                XCTFail("服务端明确拒绝时不应走本地兜底")
            } catch let error as PhoneAuthError {
                XCTAssertEqual(error, .invalidCode)
            }
        }
    }

    @MainActor
    func testSendCodeFallsBackWhenBackendUnreachable() async throws {
        try await withChinaRegion {
            let service = PhoneAuthService(transport: UnreachableTransport())
            let challenge = try await service.sendCode(phone: "13800138000")
            XCTAssertTrue(challenge.usedLocalFallback)
            // 兜底时不该让用户等 60 秒才能重试。
            XCTAssertEqual(challenge.resendAfterSeconds, 0)
        }
    }

    // MARK: - 辅助

    /// 把进程切到中国区。
    ///
    /// 必须连 `override` 一起清：单测跑在 App 进程里，与 UI 测试共享
    /// UserDefaults，一个残留的「手动切回全球」会压过 storefront，
    /// 让这里所有断言都莫名其妙地拿到 notAvailableInRegion。
    @MainActor
    private func withChinaRegion(_ body: () async throws -> Void) async throws {
        let storefrontKey = "appRegion.v1.storefrontCountryCode"
        let overrideKey = "appRegion.v1.override"
        let savedStorefront = UserDefaults.standard.string(forKey: storefrontKey)
        let savedOverride = UserDefaults.standard.string(forKey: overrideKey)

        UserDefaults.standard.removeObject(forKey: overrideKey)
        UserDefaults.standard.set("CHN", forKey: storefrontKey)
        defer {
            if let savedStorefront {
                UserDefaults.standard.set(savedStorefront, forKey: storefrontKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storefrontKey)
            }
            if let savedOverride {
                UserDefaults.standard.set(savedOverride, forKey: overrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overrideKey)
            }
        }
        try await body()
    }
}

// MARK: - 测试替身

private final class StubTransport: PhoneAuthTransport, @unchecked Sendable {
    let status: Int
    let body: [String: Any]
    private(set) var lastBody: [String: Any]?

    init(status: Int, body: [String: Any]) {
        self.status = status
        self.body = body
    }

    func post(url: URL, body requestBody: [String: Any], bearer: String?) async throws -> (Int, Data) {
        lastBody = requestBody
        return (status, try JSONSerialization.data(withJSONObject: body))
    }
}

private final class FailIfCalledTransport: PhoneAuthTransport, @unchecked Sendable {
    private(set) var wasCalled = false

    func post(url: URL, body: [String: Any], bearer: String?) async throws -> (Int, Data) {
        wasCalled = true
        return (200, Data("{}".utf8))
    }
}

/// 模拟境内后端尚未上线：连接直接失败。
private struct UnreachableTransport: PhoneAuthTransport {
    func post(url: URL, body: [String: Any], bearer: String?) async throws -> (Int, Data) {
        throw PhoneAuthError.network
    }
}
