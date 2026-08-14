//
//  TTSEndpoint.swift
//  CastReader
//
//  新版云端 TTS 只走当前进程已冻结的统一 API 网关。上游节点选择、
//  容灾与旧已发布二进制的历史路径兼容均由服务端负责。客户端不再按时区
//  直连上游，也不在 global / cn 之间 fallback。
//

import Foundation

enum TTSEndpoint {
    static let globalBase = ServiceRoute.globalGateway.apiGatewayBaseURL
    static let chinaMainlandBase = ServiceRoute.chinaGateway.apiGatewayBaseURL

    static func primaryBase() -> String {
        ServiceRouting.current.apiGatewayBaseURL
    }

    /// 保留可注入签名供路由合同测试；新架构不再让所在地改变自有 API 入口。
    static func primaryBase(isMainlandChina _: Bool) -> String {
        primaryBase()
    }

    /// 严禁客户端跨线回退。网关内部容灾不改变用户看到的入口域名。
    static func fallbackBase() -> String? { nil }
    static func fallbackBase(isMainlandChina _: Bool) -> String? { nil }

    static func partlyURL(base: String) -> String {
        "\(base)/api/captioned_speech_partly"
    }

    @discardableResult
    static func freezeForCurrentProcess() -> String { primaryBase() }

    /// 旧客户端的远程节点配置已退出新版路径；保留签名便于渐进清理启动调用。
    static func refreshRemoteConfig() async {}

    #if DEBUG
    static func resetProcessSnapshotForTesting() {}
    #endif
}
