import Foundation

// 11-28 Keng「貼上的中文全變亂碼」：Claude 背景 session 沒有 LANG／LC_*（C 語系），macOS 就照系統主要語言的舊編碼
// （繁中＝Big5）讀寫剪貼簿 ⇒ pbpaste 拿到 Big5、Claude Code 的 Ctrl+V 貼出亂碼。
// Keng「未來要符合我們設計的 18 國語言」⇒ 不寫死英文：照系統偏好語言挑一個裝了的「<語言>_<地區>.UTF-8」；
// 對不到就只設 LC_CTYPE=UTF-8（只管字元編碼，不改程式訊息的語言）
public enum Utf8Locale {
    /// 目前環境已經是 UTF-8 ⇒ 空；不然回要補上的環境變數
    /// preferred：系統偏好語言（Locale.preferredLanguages，例如 "zh-Hant-TW"、"ja-JP"、"fr"）；available：/usr/share/locale 底下的名稱
    public static func fix(env: [String: String], preferred: [String], available: Set<String>) -> [String: String] {
        let now = env["LC_ALL"].flatMap { $0.isEmpty ? nil : $0 } ?? env["LC_CTYPE"].flatMap { $0.isEmpty ? nil : $0 } ?? env["LANG"] ?? ""
        if isUTF8(now) { return [:] }
        let all = !(env["LC_ALL"] ?? "").isEmpty          // LC_ALL 蓋過其他兩個：有設（又不是 UTF-8）就一起換
        for p in preferred { if let l = pick(p, available: available) { return ["LANG": l, "LC_CTYPE": l].merging(all ? ["LC_ALL": l] : [:]) { a, _ in a } } }
        return ["LC_CTYPE": "UTF-8"].merging(all ? ["LC_ALL": "UTF-8"] : [:]) { a, _ in a }
    }
    static func isUTF8(_ s: String) -> Bool { let u = s.lowercased(); return u.contains("utf-8") || u.contains("utf8") }
    /// "zh-Hant-TW" → zh_TW.UTF-8；"zh-Hans" → zh_CN.UTF-8；"ja" → 第一個 ja_*.UTF-8
    static func pick(_ tag: String, available: Set<String>) -> String? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let lang = parts.first?.lowercased(), !lang.isEmpty else { return nil }
        var region = parts.dropFirst().first { $0.count == 2 && $0.uppercased() == $0 }
        let script = parts.dropFirst().first { $0.count == 4 }
        if region == nil, lang == "zh" { region = script == "Hans" ? "CN" : "TW" }
        if let r = region, available.contains("\(lang)_\(r).UTF-8") { return "\(lang)_\(r).UTF-8" }
        return available.filter { $0.hasPrefix("\(lang)_") && $0.hasSuffix(".UTF-8") }.sorted().first
    }
    /// 這台 Mac 裝了哪些語系
    public static func installed() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: "/usr/share/locale")) ?? [])
    }
    /// 補到自己這個程序（之後開的終端機、claude --bg 都會繼承）
    public static func applyToProcess() {
        for (k, v) in fix(env: ProcessInfo.processInfo.environment, preferred: Locale.preferredLanguages, available: installed()) { setenv(k, v, 1) }
    }
}
