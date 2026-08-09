//
//  UserAccount.swift
//  CastReader
//
//  登录账号资料（Google / Apple）。
//

import Foundation

struct UserAccount: Codable, Equatable {
    let id: String              // provider 的稳定用户 id（Google sub / Apple user / 后端 user id）
    var email: String?
    var name: String?
    var pictureURL: String?
    var provider: String        // "google" | "apple" | "phone"
    var backendUserId: String?  // better-auth 后端 user id（best-effort 换取，用于按账号查 Pro）
    /// 中国区手机号登录才有；**只存脱敏形式**（138****8000），不落原号。
    var maskedPhone: String?

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let p = maskedPhone, !p.isEmpty { return p }
        if let e = email, !e.isEmpty { return e }
        return AppLocalized("已登录")
    }

    var initial: String {
        if provider == "phone" { return "#" }
        return String((name ?? email ?? "?").prefix(1)).uppercased()
    }
}
