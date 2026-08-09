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

    /// 头像首字母。Apple 登录可能既无 name 也无 email（只在首次授权返回），
    /// 此时退到 provider 首字母而不是「?」——问号看起来像出错了。
    var initial: String {
        if provider == "phone" { return "#" }
        if let source = [name, email].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            return String(source.prefix(1)).uppercased()
        }
        return provider == "apple" ? "A" : String(provider.prefix(1)).uppercased()
    }
}
