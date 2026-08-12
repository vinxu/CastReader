//
//  TTSEndpoint.swift
//  CastReader
//
//  云端 TTS 节点路由（对齐扩展 tts-service.ts）：
//  中国大陆时区 → CN 节点；其他 → US 节点；CN 失败回退 US。
//  端点可由 COS 远程配置覆盖（24h 缓存），否则用硬编码默认值。
//

import Foundation

enum TTSEndpoint {
    /// 硬编码默认（与扩展 config/tts-endpoints.json 一致；CN 实例轮换时远程配置会覆盖）。
    static let cnDefault = "https://uu122431-80b4-9c6a8f65.bjb1.seetacloud.com:8443"
    static let usDefault = "https://api.castreader.ai"
    private static let legacyUSDefault = "http://api.castreader.ai:8123"

    static let remoteConfigURL = "https://zqxgmqygirtpttnrvjpf.supabase.co/storage/v1/object/public/castreader-public/config/tts-endpoints-v2.json"
    private static let cacheKey = "tts_endpoints_v1"
    private static let cacheTimeKey = "tts_endpoints_v1_time"

    /// 中国大陆 IANA 时区（港台不含）。
    private static let mainlandTimeZones: Set<String> = [
        "Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Harbin", "Asia/Kashgar"
    ]

    static func isMainlandChina() -> Bool {
        mainlandTimeZones.contains(TimeZone.current.identifier)
    }

    /// 当前端点（远程配置缓存优先，否则默认）。
    static func endpoints() -> (cn: String, us: String) {
        if let d = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String],
           let cn = d["cn_url"].flatMap(normalizedSecureBase),
           let us = d["us_url"].flatMap(normalizedSecureBase) {
            return (cn, us)
        }
        return (cnDefault, usDefault)
    }

    /// Accept only HTTPS endpoint bases. The public route configuration still
    /// contains the historical plaintext US origin, so upgrade it locally
    /// instead of allowing cached configuration to weaken transport security.
    static func normalizedSecureBase(_ rawValue: String) -> String? {
        var raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw == legacyUSDefault {
            return usDefault
        }
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        return raw
    }

    /// 主用节点：大陆→CN，否则→US。
    static func primaryBase() -> String {
        let e = endpoints()
        return isMainlandChina() ? e.cn : e.us
    }

    /// 回退节点：仅当主用是 CN 时回退到 US；否则无回退。
    static func fallbackBase() -> String? {
        guard isMainlandChina() else { return nil }
        return endpoints().us
    }

    static func partlyURL(base: String) -> String { "\(base)/api/captioned_speech_partly" }

    /// 启动时刷新远程配置（非阻塞；失败保留缓存/默认）。24h 缓存。
    static func refreshRemoteConfig() async {
        let last = UserDefaults.standard.double(forKey: cacheTimeKey)
        let hasCache = UserDefaults.standard.dictionary(forKey: cacheKey) != nil
        if hasCache, Date().timeIntervalSince1970 - last < 24 * 3600 { return }
        guard let url = URL(string: remoteConfigURL) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawCN = obj["cn_url"] as? String,
               let rawUS = obj["us_url"] as? String,
               let cn = normalizedSecureBase(rawCN),
               let us = normalizedSecureBase(rawUS) {
                UserDefaults.standard.set(["cn_url": cn, "us_url": us], forKey: cacheKey)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimeKey)
            }
        } catch {
            // 保留缓存/默认
        }
    }
}
