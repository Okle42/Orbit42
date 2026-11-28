import Foundation

// 11-28 OpenJarvis 升級 B 組③：從過去紀錄自動變聰明。
// 收這幾天的：交流板留言（orbit b1）、派工單回報（summary）、Keng 在卡片上的原話（KengNote）、
// 被 Keng 指正的紀錄（memory 裡的 feedback、commit 訊息裡的「Keng：…」），交給本機 claude -p（haiku）整理出
// 「重複出現的坑」「好方法」，產生建議：派工單提醒、要改的 skill、要改的規則。
// 建議只存成待核可（board/learn/suggestions.json）；Keng 在卡片核可後才生效：
//   ・派工單提醒 ⇒ 進 reminders.json，之後每張派工單全文最後附上「這次要注意」
//   ・skill／規則 ⇒ 只標成已核可、列出要改哪裡，由人（或被派工的組員）去改；這裡不自動改任何規則或 skill
public enum Lessons {
    public enum Kind: String, Codable, Sendable, CaseIterable { case reminder = "派工提醒", skill = "改 skill", rule = "改規則" }
    public enum State: String, Codable, Sendable { case pending = "待核可", approved = "已核可", rejected = "不採用" }

    public struct Suggestion: Codable, Sendable, Equatable, Identifiable {
        public var id: String            // L + 4 碼
        public var kind: Kind
        public var title: String         // 一句話
        public var text: String          // 建議內容（派工提醒＝要附進派工單的那句）
        public var why: String           // 為什麼：重複出現幾次、哪裡看到
        public var evidence: [String]    // 出處（[交流板 #12]、[派工 T…]、[Keng 11-27]…）
        public var target: String?       // skill／規則要改哪個檔
        public var state: State = .pending
        public var at: Date
        public var decidedAt: Date? = nil
    }

    public struct Source: Sendable, Equatable {
        public var tag: String       // 出處標籤
        public var at: Date
        public var text: String
        public init(tag: String, at: Date, text: String) { self.tag = tag; self.at = at; self.text = text }
    }

    // MARK: 收集

    static let mdf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f }()

    public static func sources(since: Date, posts: [B1Post], tasks: [CaptainTask], memories: [(String, Date, String)], commits: [(Date, String)]) -> [Source] {
        var out: [Source] = []
        for p in posts where p.at >= since { out.append(Source(tag: "交流板 #\(p.id) \(p.name)", at: p.at, text: p.text)) }
        for t in tasks where t.updatedAt >= since {
            if let s = t.summary, !s.isEmpty { out.append(Source(tag: "派工 \(t.id) \(t.to) 回報", at: t.updatedAt, text: (t.title.map { "「\($0)」" } ?? "") + s)) }
            for n in t.notes ?? [] where n.at >= since {
                out.append(Source(tag: "Keng 原話（派工 \(t.id)）", at: n.at, text: (n.question.map { "問：\($0)／" } ?? "") + "答：" + n.text))
            }
        }
        for (name, at, body) in memories where at >= since { out.append(Source(tag: "指正紀錄 \(name)", at: at, text: String(body.prefix(600)))) }
        for (at, s) in commits where at >= since && (s.contains("Keng") || s.contains("指正")) { out.append(Source(tag: "commit", at: at, text: String(s.prefix(300)))) }
        return out.sorted { $0.at < $1.at }
    }

    /// memory 資料夾裡 type: feedback 的檔（指正紀錄）
    public static func feedbackMemories(root: URL = TestEnv.home.appendingPathComponent(".claude/projects"), since: Date) -> [(String, Date, String)] {
        let fm = FileManager.default
        var out: [(String, Date, String)] = []
        for p in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let m = root.appendingPathComponent(p).appendingPathComponent("memory")
            for f in (try? fm.contentsOfDirectory(atPath: m.path)) ?? [] where f.hasSuffix(".md") && f != "MEMORY.md" {
                let u = m.appendingPathComponent(f)
                guard let at = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, at >= since,
                      let s = try? String(contentsOf: u, encoding: .utf8), s.contains("type: feedback") else { continue }
                out.append((f, at, s))
            }
        }
        return out
    }

    // MARK: 叫 haiku 整理

    public static func prompt(_ src: [Source], existing: [Suggestion]) -> String {
        let lines = src.map { "[\($0.tag)｜\(mdf.string(from: $0.at))] \($0.text.replacingOccurrences(of: "\n", with: " "))" }
        let old = existing.filter { $0.state != .rejected }.map { "- \($0.title)" }.joined(separator: "\n")
        return """
        你是 Orbit42 團隊的流程教練。下面是這幾天的工作紀錄：AI 組員在交流板的心得、派工單回報、老闆 Keng 在卡片上的原話、被 Keng 指正的紀錄、commit 訊息。
        請找出「重複出現的坑」（同一類錯誤出現 2 次以上，或 Keng 明確指正過）和「好方法」（有效、值得大家照做的做法），整理成 5～8 條具體建議。
        每條建議是三種之一：
          派工提醒：秘書派工時附給組員的一句提醒（直接寫成給組員看的句子，40 字內）
          改 skill：某個 skill 該補或改的內容（target 寫 skill 名稱）
          改規則：CLAUDE.md、hook 或 Orbit42 規則該改的地方（target 寫哪個檔或哪個規則）
        規則：只根據下面的紀錄，不要編造；evidence 要列出方括號裡的出處標籤（至少一個）；用繁體中文（台灣用語）；不要跟「已經有的建議」重複。
        只輸出 JSON 陣列，不要其他文字，格式：
        [{"kind":"派工提醒|改 skill|改規則","title":"一句話","text":"建議內容","why":"為什麼（出現幾次、誰被指正）","evidence":["出處標籤"],"target":"skill 或檔名，派工提醒填 null"}]

        已經有的建議：
        \(old.isEmpty ? "（無）" : old)

        紀錄（共 \(src.count) 筆）：
        \(lines.joined(separator: "\n"))
        """
    }

    /// 從 claude 的輸出抓 JSON 陣列（可能包在 ```json 裡）
    public static func parse(_ out: String, now: Date, existingIDs: Set<String>) -> [Suggestion] {
        guard let a = out.firstIndex(of: "["), let b = out.lastIndex(of: "]"), a < b,
              let arr = try? JSONSerialization.jsonObject(with: Data(out[a...b].utf8)) as? [[String: Any]] else { return [] }
        var ids = existingIDs, res: [Suggestion] = []
        for o in arr {
            guard let k = (o["kind"] as? String).flatMap({ s in Kind.allCases.first { $0.rawValue == s } }),
                  let title = o["title"] as? String, let text = o["text"] as? String, !title.isEmpty, !text.isEmpty else { continue }
            let ev = (o["evidence"] as? [String] ?? []).filter { !$0.isEmpty }
            if ev.isEmpty { continue }            // 沒出處的不收
            let id = newID(&ids)
            res.append(Suggestion(id: id, kind: k, title: title, text: text, why: o["why"] as? String ?? "", evidence: ev,
                                  target: (o["target"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }, at: now))
        }
        return res
    }

    static func newID(_ used: inout Set<String>) -> String {
        let cs = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        while true {
            let id = "L" + String((0..<4).map { _ in cs.randomElement()! })
            if used.insert(id).inserted { return id }
        }
    }

    public typealias Runner = (_ prompt: String) -> String?

    /// 本機 claude -p（haiku），stdin 送 prompt；失敗回 nil。ORBIT_REVIEWER=1：被叫起來的 claude 不上看板、不發卡
    public static func haiku(_ prompt: String) -> String? {
        let p = Process(), inp = Pipe(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "-p", "--model", "haiku", "--output-format", "text"]
        var env = ProcessInfo.processInfo.environment
        env["ORBIT_REVIEWER"] = "1"
        p.environment = env
        p.standardInput = inp; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        inp.fileHandleForWriting.write(Data(prompt.utf8)); try? inp.fileHandleForWriting.close()
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
    }

    // MARK: 存取

    public static var dir: URL { Paths.supportDir.appendingPathComponent("board/learn", isDirectory: true) }
    public static var url: URL { dir.appendingPathComponent("suggestions.json") }

    public static func all(_ u: URL = url) -> [Suggestion] {
        (try? Data(contentsOf: u)).flatMap { try? BoardJSON.decoder.decode([Suggestion].self, from: $0) } ?? []
    }
    public static func save(_ xs: [Suggestion], _ u: URL = url) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(xs) { try? d.write(to: u, options: .atomic) }
    }

    /// 整理一次：新建議加在後面（state＝待核可），回傳這次新增的
    @discardableResult
    public static func scan(_ src: [Source], run: Runner, now: Date = Date(), url u: URL = url) -> Result<[Suggestion], CardError> {
        guard !src.isEmpty else { return .failure(CardError("這段時間沒有紀錄可以整理")) }
        let old = all(u)
        guard let out = run(prompt(src, existing: old)) else { return .failure(CardError("本機 claude -p 沒有回應")) }
        let new = parse(out, now: now, existingIDs: Set(old.map(\.id)))
        guard !new.isEmpty else { return .failure(CardError("haiku 的回答看不懂（不是 JSON 陣列）")) }
        save(old + new, u)
        return .success(new)
    }

    /// Keng 核可／不採用
    public static func decide(_ id: String, approve: Bool, now: Date = Date(), url u: URL = url) -> Suggestion? {
        var xs = all(u)
        guard let i = xs.firstIndex(where: { $0.id.uppercased() == id.uppercased() }) else { return nil }
        xs[i].state = approve ? .approved : .rejected; xs[i].decidedAt = now
        save(xs, u)
        return xs[i]
    }

    /// 已核可的派工提醒（新的在前，最多 n 條）：附在派工單全文後面
    public static func reminders(_ xs: [Suggestion] = all(), n: Int = 6) -> [String] {
        xs.filter { $0.kind == .reminder && $0.state == .approved }.sorted { ($0.decidedAt ?? $0.at) > ($1.decidedAt ?? $1.at) }.prefix(n).map(\.text)
    }

    public static func line(_ s: Suggestion) -> String {
        "\(s.id)［\(s.kind.rawValue)｜\(s.state.rawValue)］\(s.title)\n    內容：\(s.text)" + (s.target.map { "\n    改哪裡：\($0)" } ?? "")
            + "\n    為什麼：\(s.why)\n    出處：\(s.evidence.joined(separator: "、"))"
    }
}
