import Foundation

// 等你回答的問題排隊（11-11：使用者一直說「我根本就沒有按鈕」）。
// 原本每個 session 只留最後一張卡片（board/cards/<sid>.json），問題跟著卡片走，所以：
//   ① --status blocked 的 --ask 進「卡住」欄，不在「等你回答」；
//   ② 同一個 session 後來再發一張卡，前一題（例如 某組員的一題）就被蓋掉；
//   ③ AI 發完 --ask 又動一下工具，光暈變回工作中，問題從「等你回答」消失（Puppy 01:05:34→01:05:39）。
// 改成 --ask 另外排進 board/asks/<sid>.json：不管 status、後來的卡片、工作中事件，都留著，
// 只有「你在Orbit42回答」「你在那個終端機打字回答」「AI 自己撤回（orbit asks withdraw）」「放超過 ttl」才拿掉。最早的先問。
// 11-14 使用者：在終端機那邊回答了，Orbit42的題目還掛著 ⇒ 使用者本人在那個 session 打字（UserPromptSubmit）就清掉它的待答題。

public struct PendingAsk: Codable, Sendable, Equatable, Identifiable {
    public var id: String              // Q＋4 碼，撤回用
    public var ask: String
    public var options: [String]?
    public var at: Date                // 第一次問的時間（排隊順序）
    public var doing: String?
    public var unsureAt: Date? = nil   // 答案打進終端機但沒確認到：題目留著、前面明講請看終端機
    public var sendingAt: Date? = nil  // 有人按了答案、正在送（AskQueue.claim）；App 中途當掉就一直留著，當成沒確認到
    public var action: String? = nil   // 看板自己發的題：captain＝按同意才換秘書（AI 的 card --ask 設不了這個）
    public var task: String? = nil     // 11-28 問這題的卡片帶的 --task（答了記進這張單；不跟著之後的卡片換）
    public var multi: Bool? = nil      // 11-28 多選：按選項只打勾，另按確認才送（目前只有 release-pick）
    public var picks: [String]? = nil  // release-pick：每個選項對應的擋單號（跟 options 同順序）
    /// 只能用勾選送的題（一般文字答案、終端機打字、AI 撤回都碰不到）
    public var pickOnly: Bool { action == ReleasePick.action }
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
        if let p = TestEnv.path("ORBIT_ASKS_DIR") { return URL(fileURLWithPath: p, isDirectory: true) }
        return Paths.supportDir.appendingPathComponent("board/asks", isDirectory: true)
    }

    // MARK: 一題只送一次

    /// 讀了再改的都在這把鎖裡（跨程序：App、hook、orbit）。不能巢狀
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
            if r.options != nil, out[i].action == nil { out[i].options = r.options }      // 看板發的題不給 AI 改選項
            return out
        }
        // 11-28（Hana 同一題 --ask 發 3 次，等你回答排了 3 筆）：換句話重發、選項一樣 ⇒ 併成一筆，用最新的說法，排隊位置不變
        if let opts = r.options, !opts.isEmpty,
           let i = out.firstIndex(where: { $0.action == nil && sameOptions($0.options, opts) && Answered.similar($0.ask, q) }) {
            if out[i].sendingAt == nil, out[i].unsureAt == nil { out[i].ask = q }      // 正在送的題不改字
            return out
        }
        var a = PendingAsk(id: id(), ask: q, options: r.options, at: r.at, doing: r.doing)
        a.task = r.task
        out.append(a)
        return out
    }

    /// 選項一樣（不管順序、「（建議）」標記、空白與標點）
    static func sameOptions(_ a: [String]?, _ b: [String]?) -> Bool {
        func key(_ xs: [String]?) -> [String] { (xs ?? []).map { Answered.normal(AnswerPick.bare($0)) }.filter { !$0.isEmpty }.sorted() }
        let x = key(a)
        return !x.isEmpty && x == key(b)
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

    /// `orbit card` 寫卡片時一起排（過期的順手清掉）
    @discardableResult
    public static func record(sid: String, report r: SelfReport, now: Date = Date()) -> [PendingAsk] {
        locked {
            let old = load(sid)
            let xs = adding(r, to: live(old, now: now))
            if xs != old { save(sid, xs) }
            return xs
        }
    }

    /// 你在Orbit42回答了這一題 ⇒ 拿掉；卡片檔上同一題的 --ask 也清掉（不然它會用舊卡片的問題再冒出來）
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
    /// 11-28 待修⑤「沒送到，重送」：使用者看過終端機、確定沒送到 ⇒ 拿掉「沒確認到／送出中」，這題可以再按一次（題目、選項不變）
    @discardableResult
    public static func reopen(sid: String, id: String) -> Bool {
        locked {
            var xs = load(sid)
            guard let i = xs.firstIndex(where: { $0.id == id }), xs[i].unsureAt != nil || xs[i].sendingAt != nil else { return false }
            xs[i].unsureAt = nil; xs[i].sendingAt = nil; save(sid, xs)
            return true
        }
    }

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
            let ys = xs.filter { $0.pickOnly || !Answered.same($0.ask, question) }
            if ys.count != xs.count { save(sid, ys); return true }
            return false
        }
    }

    /// AI 撤回：編號或 all；回傳撤掉幾題
    public static func withdraw(sid: String, id: String) -> Int {
        locked {
        let xs = load(sid)
        // 勾選放行的題 AI 撤不掉（Keng 要自己勾；AI 照提醒 withdraw all 時不能順手收掉）
        let ys = xs.filter { $0.pickOnly || (id != "all" && $0.id.caseInsensitiveCompare(id) != .orderedSame) }
        save(sid, ys)
        return xs.count - ys.count
        }
    }

    /// 使用者本人在終端機打的字才算回答：其他 session／看板轉送／系統訊息（<…> 標籤，含Orbit42回答）不算；
    /// 「放行」是在回權限擋單，不是回答問題
    public static func isTerminalAnswer(_ prompt: String?) -> Bool {
        guard CaptainLink.needsStart(prompt: prompt), !Peer.quotesPeer(prompt ?? "") else { return false }
        return !(prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("放行")
    }

    /// 好幾題在等、這句對不上任何選項 ⇒ 給 AI 的提醒：它看得懂使用者答了哪題，答到的自己撤回（使用者不用手按）
    public static func leftoverNote(sid: String, prompt: String?, orbit: String, now: Date = Date()) -> String? {
        guard isTerminalAnswer(prompt) else { return nil }
        let xs = live(load(sid), now: now).filter { !$0.pickOnly }
        guard !xs.isEmpty else { return nil }
        let list = xs.map { "\($0.id)：\($0.ask.replacingOccurrences(of: "\n", with: " ").prefix(60))" }.joined(separator: "；")
        return "【Orbit42】使用者剛在終端機回了話，看板「等你回答」還掛著 \(xs.count) 題（\(list)）。這句話答到哪一題，就跑 \"\(orbit)\" asks withdraw <編號>（都答到就 withdraw all）；沒答到的留著，不用跟使用者提這件事。"
    }

    /// 打的字跟這題某個選項完全一樣（不管「（建議）」標記、空白與標點）
    public static func typedOption(_ prompt: String, of q: PendingAsk) -> Bool {
        let p = Answered.normal(prompt)
        return !p.isEmpty && ((q.options ?? []).isEmpty ? Inbox.genericOptions : q.options!).contains { Answered.normal(AnswerPick.bare($0)) == p }
    }

    /// 11-28 待修②：以前終端機打任何字就清光這個 session 的所有待答題。Keng 指正「答了要自動知道、不是我人工按」⇒
    ///   • 只有一題在等：本人在終端機回的話就是在答它 ⇒ 自動收掉
    ///   • 好幾題在等：跟某題選項完全一樣的收掉；其他留著，hook 提醒 AI 自己判斷答到哪題、自己 withdraw（leftoverNote）
    /// 使用者在這個 session 的終端機打字回答 ⇒ 對得上的那題拿掉、卡片上的 --ask 清掉；
    /// 秘書卡片／佇列掛著同一題的也清掉（不轉【使用者已答】：答案在組員那邊，秘書巡檢看得到，不為這個叫醒秘書）。回傳拿掉的題
    @discardableResult
    /// 11-28：答的這個 session 有進行中的派工單 ⇒ 原話記進單（TaskNotes），秘書看單就知道，不用再問組員
    public static func answeredInTerminal(sid: String, prompt: String?, captain: String? = nil,
                                          cardsDir: URL = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true),
                                          tasksDir: URL = Captain.tasksDir, name: String? = nil, now: Date = Date()) -> [PendingAsk] {
        guard isTerminalAnswer(prompt) else { return [] }
        let typed = prompt ?? ""
        let xs: [PendingAsk] = locked {
            let all = load(sid), open = all.filter { !$0.pickOnly }      // 勾選放行的題：終端機打什麼都不算答它
            let hit = open.count == 1 ? open : open.filter { typedOption(typed, of: $0) }
            if !hit.isEmpty { save(sid, all.filter { q in !hit.contains { $0.id == q.id } }) }
            return hit
        }
        guard !xs.isEmpty else { return [] }
        let tasks = Set(xs.map(\.task))
        TaskNotes.record(sid: sid, name: name ?? NicknameStore.get(sid)?.name, cardTask: tasks.count == 1 ? tasks.first! : nil, askedAt: xs.map(\.at).min(),
                         question: xs.map(\.ask).joined(separator: "／"), answer: prompt ?? "", via: "終端機",
                         at: now, captain: captain, asks: sid == captain ? nil : [:], dir: tasksDir)
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
    public var chosen: [Int]? = nil          // 多選題按「確認放行」：勾了第幾個（0 起算；空＝全部不放）
    public init(askId: String, option: String?, free: String? = nil, chosen: [Int]? = nil) { self.askId = askId; self.option = option; self.free = free; self.chosen = chosen }
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
        guard q.id == askId, !q.pickOnly else { return nil }        // 勾選題沒有「要送的字」：只走 ReleasePick.answer
        let f = free?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let option else { return f.isEmpty ? nil : f }
        let given = (q.options ?? []).isEmpty ? Inbox.genericOptions : q.options!
        guard given.contains(where: { $0 == option || AnswerPick.bare($0) == option }) else { return nil }
        return AnswerPick.bare(option) + (f.isEmpty ? "" : "\n補充：" + f)
    }
}
