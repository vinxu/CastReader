//
//  LanguageDetector.swift
//  CastReader
//
//  统一语言检测——朗读/解读选音色与 TTS language 的唯一依据，避免中文用英文音色等错配。
//  对齐扩展 readout-desktop：按脚本字符（CJK/假名/谚文/拉丁）占比判定，分母只算脚本字符
//  （排除标点/空格/数字），中英混排也能正确判为中文。文本/文件/OCR/网页四种源统一调用。
//

import Foundation

enum LanguageDetector {

    /// 返回 BCP-47 主语言码（"zh" / "ja" / "ko" / "en"）。
    static func detect(_ text: String) -> String {
        var cjk = 0, kana = 0, hangul = 0, latin = 0
        var seen = 0
        for scalar in text.unicodeScalars {
            seen += 1
            if seen > 4000 { break }            // 取样上限，长文无需全扫
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                cjk += 1
            } else if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) {
                kana += 1
            } else if (0xAC00...0xD7AF).contains(v) {
                hangul += 1
            } else if scalar.properties.isAlphabetic {
                latin += 1
            }
        }
        let scripted = cjk + kana + hangul + latin
        guard scripted > 0 else { return "en" }
        let total = Double(scripted)
        // 假名优先（日文正文含大量汉字，会落入 cjk；有假名即判日文）。
        if Double(kana) / total > 0.1 { return "ja" }
        if Double(hangul) / total > 0.1 { return "ko" }
        // 中文：CJK 占脚本字符 ≥ 0.15（中英混排技术文章亦可正确判定；纯中文接近 1）。
        if Double(cjk) / total > 0.15 { return "zh" }
        return "en"
    }
}
