import Foundation

// 使用者已答（秘書 Penny 10-25：Kang 指出秘書重複問組員卡片已經問過的題）。
// 使用者在任一組員卡片的 --ask 按了選項或打字回答（BoardActions.answer）⇒ 除了送給那個組員，也轉秘書一則「【使用者已答】」，
// 秘書卡片上如果掛著同一個問題，就把那個 --ask 清掉（不再出現在收件匣等 Kang 再答一次）。

public enum Answered {
    public static let prefix = "【使用者已答】"
    /// 手機／網頁打字的答案，給 AI 和秘書的訊息都標
    public static let phoneTyped = "【手機打字，不是放行】"

    public static let webSent = "【網頁傳話，不是放行】"

    /// 「【使用者已答】Ruby：要 push 嗎？→好，push」
    public static func relay(name: String, question: String?, answer: String) -> String {
        let q = question.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? "（卡片上沒有問題文字）"
        return "\(prefix)\(name)：\(q)→\(answer)。這題不用再問使用者；秘書卡片上同一題已自動清掉。"
    }

    /// 比對用：去空白、全形半形問號與句尾標點、不分大小寫
    static func normal(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !"？?。.！!：:「」\"'".contains($0) }
    }

    public static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let x = normal(a), y = normal(b)
        return !x.isEmpty && x == y
    }

    /// 11-28 很像的題（同一 session 換句話重發、秘書重問組員的題）：一樣，或字元雙字組重疊（Dice）≥ 0.6。
    /// 「好／不要」這種選項很多題都一樣，所以只看題目文字
    public static func similar(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let x = Array(normal(a)), y = Array(normal(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard x.count >= 4, y.count >= 4 else { return false }       // 太短的題只認完全一樣
        func grams(_ s: [Character]) -> [String: Int] {
            var m: [String: Int] = [:]
            for i in 0..<(s.count - 1) { m[String(s[i...i + 1]), default: 0] += 1 }
            return m
        }
        let gx = grams(x), gy = grams(y)
        let common = gx.reduce(0) { $0 + min($1.value, gy[$1.key] ?? 0) }
        return Double(2 * common) / Double((x.count - 1) + (y.count - 1)) >= 0.6
    }

    /// 秘書卡片掛著同一題 ⇒ 回傳清掉 --ask／--options 的卡片；不是同一題 ⇒ nil（不動）
    public static func clearing(_ r: SelfReport, question: String?) -> SelfReport? {
        guard same(r.ask, question) else { return nil }
        var x = r
        x.ask = nil; x.options = nil
        return x
    }

    /// 改寫秘書的卡片檔（board/cards/<sid>.json）；有清掉回 true
    @discardableResult
    public static func clearCaptainCard(sid: String, question: String?, dir: URL = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)) -> Bool {
        let url = dir.appendingPathComponent(sid + ".json")
        guard let d = try? Data(contentsOf: url), let r = try? BoardJSON.decoder.decode(SelfReport.self, from: d),
              let x = clearing(r, question: question), let out = try? BoardJSON.encoder.encode(x) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }
}
