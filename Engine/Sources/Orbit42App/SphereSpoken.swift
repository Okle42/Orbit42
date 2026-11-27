import Foundation

/// 11-28 Keng「那語音播報先做口語改寫」：球體播報的 AI 口語改寫（可選，預設關）。
/// 規則改寫在網頁（spoken.js，離線零延遲）；這裡只負責「開了 AI 口語改寫」時，把一句卡片播報交給本機
/// `claude -p --model haiku` 改成一句 25 字內的口語。逾時 3 秒或失敗回 nil，網頁就用規則版。
/// - 不帶 hook（disableAllHooks）、不存對話（--no-session-persistence）、不給工具：不會在看板多出一張假卡、不會動到任何檔案
/// - 同一句只問一次：結果（含失敗）都快取；同一句正在問的時候第二顆球（桌面版）排隊等同一個結果
/// - 只送卡片上的文字，不送任何聲音（⚠ 不准用使用者本人的聲音或錄音，11-21）
final class SphereSpokenAI: @unchecked Sendable {
    static let shared = SphereSpokenAI()
    static var available: Bool { Tools.claude() != nil }

    static let system = """
    你把 AI 團隊看板上的一句播報，改寫成一句給老闆聽的口語播報。規則：繁體中文（台灣用語）；25 個字以內；\
    像同事口頭講話；拿掉單號、commit 雜湊、檔案路徑、網址、英文程式名稱、括號註解；時間念成「四點零五分」；\
    只能用原句裡有的事實，不可以補原句沒有的內容；只輸出那一句，不要引號、不要解釋。
    """
    static let timeout: TimeInterval = 3

    private let lock = NSLock()
    private var cache: [String: String?] = [:]
    private var waiting: [String: [@Sendable (String?) -> Void]] = [:]

    /// 背景跑；done 在背景執行緒呼叫
    func rewrite(_ text: String, done: @escaping @Sendable (String?) -> Void) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return done(nil) }
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return done(hit) }
        if waiting[key] != nil { waiting[key]!.append(done); lock.unlock(); return }
        waiting[key] = [done]
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Self.ask(key)
            self.lock.lock()
            if self.cache.count > 300 { self.cache.removeAll() }
            self.cache[key] = out
            let fs = self.waiting.removeValue(forKey: key) ?? []
            self.lock.unlock()
            fs.forEach { $0(out) }
        }
    }

    private static func ask(_ text: String) -> String? {
        guard let bin = Tools.claude() else { return nil }
        let r = Tools.run(bin, ["-p", "--model", "haiku", "--system-prompt", system,
                                "--settings", #"{"disableAllHooks":true}"#, "--no-session-persistence", "--strict-mcp-config", "--tools", ""],
                          cwd: NSTemporaryDirectory(), stdin: text, timeout: timeout, qos: .userInitiated)
        return r.code == 0 ? tidy(r.out) : nil
    }

    /// AI 的輸出只收「一句、短、沒有怪東西」；不合格就當失敗（網頁退回規則版）
    static func tidy(_ out: String) -> String? {
        guard var s = out.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "「」『』\"“”'` "))
        if s.isEmpty || s.count > 60 { return nil }
        if s.hasPrefix("Error") || s.contains("```") { return nil }
        guard s.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        return s
    }
}
