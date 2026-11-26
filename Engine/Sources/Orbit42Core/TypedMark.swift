import Foundation

/// 答案卡打進終端機的記號（T1125030547）：App 貼字之前寫，UserPromptSubmit 的 hook 看到就知道這句是卡片打的、不是鍵盤打的
/// ⇒ 放行不提早（只記事先放行，跟卡片走訊息時一樣）。綁 session 與內容、用一次就刪、有時限。
/// 有記號只會「少做」當場放行；別的程序偽造它，頂多讓自己那句不能當場放行，得不到更寬的結果。
public enum TypedMark {
    public static let ttl: TimeInterval = 10 * 60       // 沒按成 Enter、字留在框裡之後才送出的也算
    struct Mark: Codable { var sid: String, text: String, at: Date }

    static var dir: URL {
        if let p = TestEnv.path("ORBIT_TYPED_MARKS") { return URL(fileURLWithPath: p, isDirectory: true) }
        return Captain.dir.appendingPathComponent("typed", isDirectory: true)
    }
    static func file(_ sid: String) -> URL { dir.appendingPathComponent(sid + ".json") }

    /// 寫好才能打字（寫不進去＝不打）。前一句的記號還沒用掉、內容不同：不蓋掉，這句不打（蓋掉的話前一句會被當成鍵盤打的）
    public static func put(sid: String, text: String, now: Date = Date()) -> Bool {
        guard !sid.isEmpty, !sid.contains("/") else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let old = FileManager.default.contents(atPath: file(sid).path) {
            if let m = try? BoardJSON.decoder.decode(Mark.self, from: old), now.timeIntervalSince(m.at) < ttl, m.text != TermAnswer.squash(text) { return false }
            try? FileManager.default.removeItem(at: file(sid))
        }
        guard let d = try? BoardJSON.encoder.encode(Mark(sid: sid, text: TermAnswer.squash(text), at: now)) else { return false }
        return (try? d.write(to: file(sid), options: .withoutOverwriting)) != nil
    }
    /// 這句是不是卡片打的；是就把記號用掉。收成 [Pasted text] 的、前後多了字的也算（寧可嚴）
    public static func take(sid: String, prompt: String, now: Date = Date()) -> Bool {
        guard !sid.contains("/"), let d = FileManager.default.contents(atPath: file(sid).path), let m = try? BoardJSON.decoder.decode(Mark.self, from: d), m.sid == sid else { return false }
        if now.timeIntervalSince(m.at) >= ttl { try? FileManager.default.removeItem(at: file(sid)); return false }
        let p = TermAnswer.squash(prompt)
        guard !m.text.isEmpty, p.contains(m.text) || p.contains("[Pastedtext#") else { return false }
        try? FileManager.default.removeItem(at: file(sid))
        return true
    }
}
