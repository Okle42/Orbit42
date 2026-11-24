import Foundation

// 等你回答的問題排隊（11-11：使用者一直說「我根本就沒有按鈕」）。
// 原本每個 session 只留最後一張卡片（board/cards/<sid>.json），問題跟著卡片走，所以：
//   ① --status blocked 的 --ask 進「卡住」欄，不在「等你回答」；
//   ② 同一個 session 後來再發一張卡，前一題（例如 某組員的一題）就被蓋掉；
//   ③ AI 發完 --ask 又動一下工具，光暈變回工作中，問題從「等你回答」消失（Puppy 01:05:34→01:05:39）。
// 改成 --ask 另外排進 board/asks/<sid>.json：不管 status、後來的卡片、工作中事件，都留著，
// 只有「你在戰情中心回答」「你在那個終端機打字回答」「AI 自己撤回（showork asks withdraw）」「放超過 ttl」才拿掉。最早的先問。
// 11-14 使用者：在終端機那邊回答了，戰情中心的題目還掛著 ⇒ 使用者本人在那個 session 打字（UserPromptSubmit）就清掉它的待答題。

public struct PendingAsk: Codable, Sendable, Equatable, Identifiable {
    public var id: String              // Q＋4 碼，撤回用
    public var ask: String
    public var options: [String]?
    public var at: Date                // 第一次問的時間（排隊順序）
    public var doing: String?
    public var unsureAt: Date? = nil   // 答案打進終端機但沒確認到：題目留著、前面明講請看終端機
    public var sendingAt: Date? = nil  // 有人按了答案、正在送（AskQueue.claim）；App 中途當掉就一直留著，當成沒確認到
    /// 介面上顯示的題目
    public var shown: String { unsureAt == nil && (sendingAt.map { Date().timeIntervalSince($0) < 60 } ?? true) ? ask : "⚠ 剛才的答案沒確認有沒有送到，輸入框裡可能還有字，請到它的終端機看；要答請直接在那裡打。" + ask }
    /// 等了多久；沒確認到就從那時算（介面才會把它當成新的、重新可按）
    public var since: Date { unsureAt ?? at }
    public init(id: String, ask: String, options: [String]? = nil, at: Date, doing: String? = nil) {
        self.id = id; self.ask = ask; self.options = options; self.at = at; self.doing = doing
    }
}

public enum AskQueue {
    /// 放多久沒人回答就不再列（使用者可能在終端機答了、AI 又忘了撤回）
    public static let ttl: TimeInterval = 48 * 3600

    public static var dir: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_ASKS_DIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return Paths.supportDir.appendingPathComponent("board/asks", isDirectory: true)
    }

    // MARK: 一題只送一次

    /// 讀了再改的都在這把鎖裡（跨程序：App、hook、showork）。不能巢狀
    static func locked<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        defer { if fd >= 0 { close(fd) } }        // 關檔＝放鎖
        if fd >= 0 { flock(fd, LOCK_EX) }
        return body()
    }
    public enum Claim: Sendable, Equatable {
        case ok(PendingAsk, text: String, queued: Int)     // 這次可以送（已標送出中）；text＝要送的字；queued＝排著幾題
        case gone                                          // 沒這題、答過、過期、別的 session 的、選項對不上
        case busy                                          // 正在送，或上次沒確認到
    }
    /// 按答案：驗題目與選項、標成送出中，一把鎖做完。有疑問就不給
    public static func claim(sid: String, pick: AnswerPick?, now: Date = Date()) -> Claim {
        locked {
            var xs = load(sid)
            let alive = live(xs, now: now)
            guard let pick, let q = alive.first(where: { $0.id == pick.askId }), let t = pick.text(for: q), let i = xs.firstIndex(where: { $0.id == q.id }) else { return .gone }
            guard q.sendingAt == nil, q.unsureAt == nil else { return .busy }
            xs[i].sendingAt = now
            save(sid, xs)
            // 寫不進去就不算搶到
            guard load(sid).first(where: { $0.id == q.id })?.sendingAt != nil else { return .busy }
            return .ok(q, text: t, queued: alive.count)
        }
    }
    /// 確定一個字都沒送出去：放回去讓他再按
    public static func unclaim(sid: String, id: String) {
        locked {
            var xs = load(sid)
            guard let i = xs.firstIndex(where: { $0.id == id }) else { return }
            xs[i].sendingAt = nil; save(sid, xs)
        }
    }

    // MARK: 純邏輯

    /// 新卡片 → 佇列：沒 --ask 就不動（新卡片不會刪掉還沒回答的題）；同一題再問一次只更新選項，不重排；新題排到最後
    public static func adding(_ r: SelfReport, to xs: [PendingAsk], id: () -> String = newID) -> [PendingAsk] {
        guard let q = r.ask?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return xs }
        var out = xs
        if let i = out.firstIndex(where: { Answered.same($0.ask, q) }) {
            if r.options != nil { out[i].options = r.options }
            return out
        }
        out.append(PendingAsk(id: id(), ask: q, options: r.options, at: r.at, doing: r.doing))
        return out
    }

    /// 還有效的（沒過期），最早的在前
    public static func live(_ xs: [PendingAsk], now: Date) -> [PendingAsk] {
        xs.filter { now.timeIntervalSince($0.at) < ttl }.sorted { $0.at < $1.at }
    }

    public static func newID() -> String {
        let a = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return "Q" + String((0..<4).map { _ in a.randomElement()! })
    }

    // MARK: 檔案（board/asks/<sid>.json；空了就刪檔）

    public static func load(_ sid: String) -> [PendingAsk] {
        guard let d = FileManager.default.contents(atPath: dir.appendingPathComponent(sid + ".json").path) else { return [] }
        return (try? BoardJSON.decoder.decode([PendingAsk].self, from: d)) ?? []
    }

    public static func save(_ sid: String, _ xs: [PendingAsk]) {
        let url = dir.appendingPathComponent(sid + ".json")
        if xs.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(xs) { try? d.write(to: url, options: .atomic) }
    }

    /// 全部 session（看板每次刷新讀；檔名＝sid）
    public static func all() -> [String: [PendingAsk]] {
        var out: [String: [PendingAsk]] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
            let sid = String(f.dropLast(5))
            let xs = load(sid)
            if !xs.isEmpty { out[sid] = xs }
        }
        return out
    }

    /// `showork card` 寫卡片時一起排（過期的順手清掉）
    @discardableResult
    public static func record(sid: String, report r: SelfReport, now: Date = Date()) -> [PendingAsk] {
        locked {
            let old = load(sid)
            let xs = adding(r, to: live(old, now: now))
            if xs != old { save(sid, xs) }
            return xs
        }
    }

    /// 你在戰情中心回答了這一題 ⇒ 拿掉；卡片檔上同一題的 --ask 也清掉（不然它會用舊卡片的問題再冒出來）
    @discardableResult
    public static func resolve(sid: String, id: String, cardsDir: URL = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)) -> PendingAsk? {
        let hit: PendingAsk? = locked {
            var xs = load(sid)
            guard let i = xs.firstIndex(where: { $0.id == id }) else { return nil }
            let q = xs.remove(at: i)
            save(sid, xs); return q
        }
        guard let q = hit else { return nil }
        Answered.clearCaptainCard(sid: sid, question: q.ask, dir: cardsDir)
        return q
    }

    /// 打進終端機但沒確認到
    public static func markUnsure(sid: String, id: String, now: Date = Date()) {
        locked {
            var xs = load(sid)
            guard let i = xs.firstIndex(where: { $0.id == id }) else { return }
            xs[i].unsureAt = now; xs[i].sendingAt = nil; save(sid, xs)
        }
    }

    /// 同一題（文字相同）拿掉：秘書卡片掛著組員已經被回答的題（Answered）
    @discardableResult
    public static func resolve(sid: String, question: String?) -> Bool {
        locked {
            let xs = load(sid)
            let ys = xs.filter { !Answered.same($0.ask, question) }
            if ys.count != xs.count { save(sid, ys); return true }
            return false
        }
    }

    /// AI 撤回：編號或 all；回傳撤掉幾題
    public static func withdraw(sid: String, id: String) -> Int {
        locked {
        let xs = load(sid)
        let ys = id == "all" ? [] : xs.filter { $0.id.caseInsensitiveCompare(id) != .orderedSame }
        save(sid, ys)
        return xs.count - ys.count
        }
    }

    /// 使用者本人在終端機打的字才算回答：其他 session／看板轉送／系統訊息（<…> 標籤，含戰情中心回答）不算；
    /// 「放行」是在回權限擋單，不是回答問題
    public static func isTerminalAnswer(_ prompt: String?) -> Bool {
        guard CaptainLink.needsStart(prompt: prompt), !Peer.quotesPeer(prompt ?? "") else { return false }
        return !(prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("放行")
    }

    /// 使用者在這個 session 的終端機打字回答 ⇒ 這個 session 的待答題全部拿掉、卡片上的 --ask 清掉；
    /// 秘書卡片／佇列掛著同一題的也清掉（不轉【使用者已答】：答案在組員那邊，秘書巡檢看得到，不為這個叫醒秘書）。回傳拿掉的題
    @discardableResult
    public static func answeredInTerminal(sid: String, prompt: String?, captain: String? = nil,
                                          cardsDir: URL = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)) -> [PendingAsk] {
        guard isTerminalAnswer(prompt) else { return [] }
        let xs: [PendingAsk] = locked { let xs = load(sid); if !xs.isEmpty { save(sid, []) }; return xs }
        guard !xs.isEmpty else { return [] }
        for q in xs {
            Answered.clearCaptainCard(sid: sid, question: q.ask, dir: cardsDir)
            if let cap = captain, cap != sid {
                Answered.clearCaptainCard(sid: cap, question: q.ask, dir: cardsDir)
                resolve(sid: cap, question: q.ask)
            }
        }
        return xs
    }
}

/// 介面上對某一題的回答：哪一題、按了哪個選項、補充框打了什麼
public struct AnswerPick: Sendable, Equatable {
    public var askId: String, option: String?, free: String?
    public init(askId: String, option: String?, free: String? = nil) { self.askId = askId; self.option = option; self.free = free }
    /// 一個字串：跟某個選項全文一樣就當按選項，不然是補充框打的
    public init?(askId: String?, text: String, options: [String]) {
        guard let askId else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self = options.contains(t) ? .init(askId: askId, option: t) : .init(askId: askId, option: nil, free: t)
    }
    static func bare(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[（(](建議|Recommended)[）)]\s*$"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// 要送出去的字；題目不在（答過、過期、別的 session 的、排了好幾題）或選項對不上就 nil。字由這裡組，不用介面給的整句
    public func text(asks: [PendingAsk], now: Date) -> String? {
        let live = AskQueue.live(asks, now: now)
        guard live.count == 1, let q = live.first else { return nil }
        return text(for: q)
    }
    /// 對某一題
    public func text(for q: PendingAsk) -> String? {
        guard q.id == askId else { return nil }
        let f = free?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let option else { return f.isEmpty ? nil : f }
        let given = (q.options ?? []).isEmpty ? Inbox.genericOptions : q.options!
        guard given.contains(where: { $0 == option || AnswerPick.bare($0) == option }) else { return nil }
        return AnswerPick.bare(option) + (f.isEmpty ? "" : "\n補充：" + f)
    }
}
