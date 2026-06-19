//
//  UserAccount.swift
//  CastReader
//
//  登录账号资料（Google / Apple）。
//

import Foundation

struct UserAccount: Codable, Equatable {
    let id: String              // provider 的稳定用户 id（Google sub / Apple user）
    var email: String?
    var name: String?
    var pictureURL: String?
    var provider: String        // "google" | "apple"
    var backendUserId: String?  // better-auth 后端 user id（best-effort 换取，用于按账号查 Pro）

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let e = email, !e.isEmpty { return e }
        return String(localized: "已登录")
    }

    var initial: String {
        String((name ?? email ?? "?").prefix(1)).uppercased()
    }
}
