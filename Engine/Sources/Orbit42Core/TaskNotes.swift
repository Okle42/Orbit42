import Foundation

// 秘書與組員流程簡化（11-28 Keng 核可，規格 SPEC-orbit42-秘書組員流程簡化-20261128）。
// 問題：Keng 直接在組員卡片答（例如「併 main」），派工單還寫著舊指示，秘書只看到偏差，就發訊去問組員「是不是 Keng 說的」。
// ① Keng 在任何卡片（組員或秘書）答了，那張卡的 session 有進行中的派工單 ⇒ 把「原話＋時間＋在哪張卡答」附到那張單
//    （orbit tasks 看得到、【派工回報】也帶上）。秘書看單即可，不再查證。
// ② 秘書卡片的 --ask 跟組員還沒答的 --ask 屬同一張派工單 ⇒ orbit card 擋下（派出去的事只在組員卡片問 Keng）。
// 這裡只記錄、只比對；不判放行。原話紀錄不是放行（放行照 CaptainInbox／ReleaseWord 的規則，AI 傳的字不算）。

/// Keng 的一次回答（附在派工單上）
public struct KengNote: Codable, Sendable, Equatable {
    public var text: String          // 原話（不改寫）
    public var at: Date
    public var card: String          // 在哪張卡答：組員英文名，或「秘書」
    public var question: String?     // 答的是哪一題
    public var via: String           // 哪裡答的：Orbit42 卡片／手機／終端機
    public init(text: String, at: Date, card: String, question: String? = nil, via: String) {
        self.text = text; self.at = at; self.card = card; self.question = question; self.via = via
    }
}

public enum TaskNotes {
    /// 一張單最多留幾則（舊的丟掉）
    public static let maxNotes = 30
    /// 同一句話、同一題這麼短時間內又來一次＝同一次回答走了兩條路，不重記
    static let dupWindow: TimeInterval = 120

    /// 進行中：還沒完成、沒取消（review＝等使用者決定，也算進行中）
    public static func active(_ t: CaptainTask) -> Bool { t.state != .done && t.state != .cancelled }

    /// 派給這個 session 的單（/clear 前派的、沒記 sessionId 的舊單用名字比）
    static func assigned(_ t: CaptainTask, sid: String, name: String?) -> Bool {
        t.toSession == sid || (t.toSession == nil && name != nil && t.to == name)
    }

    /// 這次回答要附到哪張單（純函式）。
    ///   • 題目（或卡片）帶 --task 而且那張單還在進行 ⇒ 那張
    ///   • 沒帶：派給這個 session、問題問出來之前就派了的進行中單只有一張 ⇒ 那張；兩張以上不猜（11-28 Keng 答待修清單被記到打包腳本單）
    ///   • 答的是秘書卡片：組員排著同一題（或很像的題）的那個人的進行中單
    public static func target(sid: String, name: String?, cardTask: String?, askedAt: Date? = nil, question: String?, captain: String?,
                              tasks: [CaptainTask], asks: [String: [PendingAsk]]) -> CaptainTask? {
        let live = tasks.filter(active)
        if let id = cardTask, let t = live.first(where: { $0.id == id }) { return t }
        let mine = live.filter { t in assigned(t, sid: sid, name: name) && (askedAt.map { t.createdAt <= $0 } ?? true) }
        if mine.count == 1 { return mine[0] }
        if mine.count > 1 { return nil }
        guard sid == captain, let q = question else { return nil }
        for (other, xs) in asks.sorted(by: { $0.key < $1.key }) where other != sid && xs.contains(where: { Answered.similar($0.ask, q) }) {
            if let t = live.filter({ $0.toSession == other }).max(by: { $0.updatedAt < $1.updatedAt }) { return t }
        }
        return nil
    }

    /// 把一則原話附到單上（純函式）；同一次回答重複來就不動，回 nil
    public static func adding(_ n: KengNote, to t: CaptainTask) -> CaptainTask? {
        var xs = t.notes ?? []
        if xs.contains(where: { $0.text == n.text && $0.question == n.question && abs($0.at.timeIntervalSince(n.at)) < dupWindow }) { return nil }
        xs.append(n)
        if xs.count > maxNotes { xs.removeFirst(xs.count - maxNotes) }
        var t = t
        t.notes = xs
        return t
    }

    /// 找單＋附上＋存檔；回傳附上的那張單（沒有進行中的單就 nil）。name＝session 名（比對派工單的 to）；shown＝畫面上的英文名。dir 給測試用暫存資料夾
    @discardableResult
    public static func record(sid: String, name: String?, shown: String? = nil, cardTask: String?, askedAt: Date? = nil, question: String?, answer: String, via: String,
                              at: Date = Date(), captain: String? = CaptainStore.captain()?.sessionId,
                              asks: [String: [PendingAsk]]? = nil, dir: URL = Captain.tasksDir) -> CaptainTask? {
        let said = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return nil }
        let all = CaptainStore.tasks(in: dir)
        // 只有秘書卡片才要翻組員的待答題（讀檔比較多）
        let queued = asks ?? (sid == captain ? AskQueue.all() : [:])
        guard let hit = target(sid: sid, name: name, cardTask: cardTask, askedAt: askedAt, question: question, captain: captain, tasks: all, asks: queued),
              let fresh = CaptainStore.task(hit.id, in: dir) else { return nil }
        let card = sid == captain ? Nicknames.captainTitle : (shown ?? name ?? String(sid.prefix(8)))
        guard let t = adding(KengNote(text: said, at: at, card: card, question: question, via: via), to: fresh) else { return nil }
        CaptainStore.save(t, in: dir)
        return t
    }

    /// 給人看的一行：「小明原話（11-28 19:44，在 Milo 卡片答）：好，併 main（問：要不要併 main）」
    public static func line(_ n: KengNote, owner: String = LocalConfig.current.ownerName) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        var s = "\(owner)原話（\(f.string(from: n.at))，在 \(n.card) 卡片\(n.via == "終端機" ? "的終端機" : "")答）：\(n.text.replacingOccurrences(of: "\n", with: " ").prefix(200))"
        if let q = n.question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty { s += "（問：\(q.replacingOccurrences(of: "\n", with: " ").prefix(80))）" }
        return s
    }

    /// 派工回報、orbit tasks 用：最近幾則
    public static func lines(_ t: CaptainTask, last: Int = 5, owner: String = LocalConfig.current.ownerName) -> [String] {
        (t.notes ?? []).suffix(last).map { line($0, owner: owner) }
    }

    // MARK: ② 秘書卡片不重問組員同一張單的題

    public struct Duplicate: Sendable, Equatable {
        public var sid: String           // 哪個組員
        public var ask: PendingAsk       // 它排著的那題
        public var task: String          // 同一張派工單
    }

    /// 秘書這張卡的 --ask 是不是組員已經在問的（純函式）。
    ///   • 卡片帶 --task：那張單的組員還有沒答的題 ⇒ 重複
    ///   • 沒帶：題目跟某個有進行中派工單的組員排著的題一樣或很像 ⇒ 重複
    public static func captainDuplicate(captain: String, report r: SelfReport, tasks: [CaptainTask], asks: [String: [PendingAsk]], now: Date = Date()) -> Duplicate? {
        guard let q = r.ask?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return nil }
        let live = tasks.filter(active)
        for (sid, all) in asks.sorted(by: { $0.key < $1.key }) where sid != captain {
            let xs = AskQueue.live(all, now: now).filter { $0.action == nil }      // 看板自己發的題（換秘書）不算
            guard !xs.isEmpty else { continue }
            let theirs = live.filter { $0.toSession == sid }
            if let id = r.task, theirs.contains(where: { $0.id == id }), let a = xs.first(where: { Answered.similar($0.ask, q) }) ?? xs.first {
                return Duplicate(sid: sid, ask: a, task: id)
            }
            if let a = xs.first(where: { Answered.similar($0.ask, q) }), let t = theirs.max(by: { $0.updatedAt < $1.updatedAt }) {
                return Duplicate(sid: sid, ask: a, task: t.id)
            }
        }
        return nil
    }

    /// orbit card 擋下時給秘書看的話
    public static func duplicateMessage(_ d: Duplicate, name: String, orbit: String, owner: String = LocalConfig.current.ownerName) -> String {
        "這題 \(name) 已經在它的卡片問\(owner)（\(d.ask.id)：\(d.ask.ask.prefix(40))，派工單 \(d.task)）。派出去的事只在組員卡片問；"
            + "\(owner)在那裡答了會自動記進派工單，用 \"\(orbit)\" tasks 看。秘書卡片不要重問：拿掉 --ask 再發"
    }
}
