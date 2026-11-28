import Foundation
import Testing
@testable import Orbit42Core

// 11-28 秘書與組員流程簡化（TaskNotes.swift、Asks.swift、CardRelay.swift、Captain.swift）。
// 假 session、假名字、假題目；派工單一律寫進暫存資料夾，不碰正式的 board/tasks
@Suite("秘書與組員流程簡化：原話記進單、同題合併、只推完成與卡住、秘書不重問")
struct TaskNotesTests {
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    func tmpDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-tasknotes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func task(_ id: String, to: String = "Milo", sid: String? = "W1", state: CaptainTask.State = .working, at: Date) -> CaptainTask {
        CaptainTask(id: id, from: "CAP", to: to, toSession: sid, text: "改按鈕，不併 main", state: state, createdAt: at)
    }
    func ask(_ id: String, _ q: String, _ opts: [String]? = nil, at: Date) -> PendingAsk { PendingAsk(id: id, ask: q, options: opts, at: at) }

    // MARK: ① 原話記進派工單

    @Test("在組員卡片答 ⇒ 原話＋時間＋哪張卡記進那張進行中的單；orbit tasks／派工回報都帶上；同一次回答不重記")
    func memberAnswerGoesToTask() throws {
        LocalFixture.use()
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        CaptainStore.save(task("T1", at: t0), in: dir)
        CaptainStore.save(task("T0", state: .done, at: t0 - 600), in: dir)          // 做完的單不收
        let hit = try #require(TaskNotes.record(sid: "W1", name: "Milo", shown: "Milo", cardTask: nil, question: "要不要併 main？",
                                                answer: "好，併 main", via: "Orbit42 卡片", at: t0 + 60, captain: "CAP", asks: [:], dir: dir))
        #expect(hit.id == "T1")
        let saved = try #require(CaptainStore.task("T1", in: dir))
        #expect(saved.notes == [KengNote(text: "好，併 main", at: t0 + 60, card: "Milo", question: "要不要併 main？", via: "Orbit42 卡片")])
        #expect(CaptainStore.task("T0", in: dir)?.notes == nil)
        // 同一次回答走兩條路（打進終端機＋卡片）不重記
        #expect(TaskNotes.record(sid: "W1", name: "Milo", cardTask: nil, question: "要不要併 main？", answer: "好，併 main", via: "終端機",
                                 at: t0 + 61, captain: "CAP", asks: [:], dir: dir) == nil)
        #expect(CaptainStore.task("T1", in: dir)?.notes?.count == 1)
        // 給人看的一行：原話、時間、哪張卡
        let line = try #require(TaskNotes.lines(saved, owner: "小明").first)
        #expect(line.contains("小明原話") && line.contains("在 Milo 卡片答") && line.contains("好，併 main") && line.contains("要不要併 main"))
        // 派工回報也帶上（完成時）
        var done = saved; done.apply(SelfReport(status: .done, summary: "做完了", at: t0 + 120))
        let rep = Captain.reportText(done)
        #expect(rep.contains("好，併 main") && rep.contains("原話") && rep.contains("紀錄不是放行"))
    }

    @Test("卡片帶 --task 就記那張；沒有進行中的單就不記；空字不記")
    func targetRules() {
        let ts = [task("T1", at: t0), task("T2", at: t0 + 10), task("T3", sid: "W2", at: t0)]
        #expect(TaskNotes.target(sid: "W1", name: nil, cardTask: "T1", question: nil, captain: "CAP", tasks: ts, asks: [:])?.id == "T1")
        #expect(TaskNotes.target(sid: "W1", name: nil, cardTask: nil, question: nil, captain: "CAP", tasks: ts, asks: [:]) == nil)    // 兩張進行中：不猜
        #expect(TaskNotes.target(sid: "W2", name: nil, cardTask: nil, question: nil, captain: "CAP", tasks: ts, asks: [:])?.id == "T3")  // 只有一張：那張
        #expect(TaskNotes.target(sid: "W9", name: nil, cardTask: nil, question: nil, captain: "CAP", tasks: ts, asks: [:]) == nil)
        // 舊單沒記 sessionId：用 session 名比
        let old = [task("T4", to: "you-9e", sid: nil, at: t0)]
        #expect(TaskNotes.target(sid: "W5", name: "you-9e", cardTask: nil, question: nil, captain: "CAP", tasks: old, asks: [:])?.id == "T4")
        // review（等使用者決定）也算進行中；取消的不算
        #expect(TaskNotes.target(sid: "W1", name: nil, cardTask: nil, question: nil, captain: "CAP", tasks: [task("T5", state: .review, at: t0)], asks: [:])?.id == "T5")
        #expect(TaskNotes.target(sid: "W1", name: nil, cardTask: nil, question: nil, captain: "CAP", tasks: [task("T6", state: .cancelled, at: t0)], asks: [:]) == nil)
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        CaptainStore.save(task("T1", at: t0), in: dir)
        #expect(TaskNotes.record(sid: "W1", name: nil, cardTask: nil, question: nil, answer: "  ", via: "x", captain: "CAP", asks: [:], dir: dir) == nil)
    }

    @Test("在秘書卡片答：組員排著同一題（或很像的題）⇒ 記進那個組員的單")
    func captainAnswerGoesToMemberTask() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        CaptainStore.save(task("T1", at: t0), in: dir)
        let asks = ["W1": [ask("QAAAA", "加修正鈕要放在右上角嗎？", ["放右上", "放左下"], at: t0)]]
        let hit = TaskNotes.record(sid: "CAP", name: "secretary", cardTask: nil, question: "加修正鈕要放右上角嗎",
                                   answer: "放右上", via: "Orbit42 卡片", at: t0 + 30, captain: "CAP", asks: asks, dir: dir)
        #expect(hit?.id == "T1")
        #expect(CaptainStore.task("T1", in: dir)?.notes?.first?.card == Nicknames.captainTitle)
        // 秘書卡片的題跟誰都不像 ⇒ 不亂記
        #expect(TaskNotes.record(sid: "CAP", name: "secretary", cardTask: nil, question: "今天晚餐吃什麼",
                                 answer: "拉麵", via: "Orbit42 卡片", at: t0 + 40, captain: "CAP", asks: asks, dir: dir) == nil)
    }

    @Test("舊的派工單檔（沒有 notes 欄）照樣讀得到")
    func oldTaskDecodes() throws {
        let json = #"{"id":"T9","from":"CAP","to":"Milo","text":"x","state":"working","createdAt":"2026-11-28T10:00:00Z","updatedAt":"2026-11-28T10:00:00Z"}"#
        let t = try BoardJSON.decoder.decode(CaptainTask.self, from: Data(json.utf8))
        #expect(t.notes == nil && t.id == "T9")
    }

    // MARK: ② 同 session 重發同題只剩一筆；秘書不重問組員同一張單的題

    @Test("同一 session 換句話重發、選項一樣 ⇒ 併成一筆（用最新說法、排隊位置不變）；選項一樣但題目不同 ⇒ 兩筆")
    func mergeSameAsk() {
        var n = 0; let id: () -> String = { n += 1; return "Q000\(n)" }
        func r(_ q: String, _ o: [String]?, _ t: TimeInterval) -> SelfReport { SelfReport(status: .review, ask: q, options: o, at: t0 + t) }
        var q = AskQueue.adding(r("要不要把 Orbit42 的修正鈕併進 main？", ["好，併 main", "先不要"], 0), to: [], id: id)
        q = AskQueue.adding(r("要不要把 Orbit42 修正鈕併進 main 分支？", ["先不要", "好，併 main（建議）"], 60), to: q, id: id)
        q = AskQueue.adding(r("要不要把 Orbit42 的修正鈕併進 main", ["好，併 main", "先不要"], 120), to: q, id: id)
        #expect(q.count == 1)
        #expect(q[0].id == "Q0001" && q[0].at == t0 && q[0].ask == "要不要把 Orbit42 的修正鈕併進 main")
        // 「好／不要」這種通用選項：題目不一樣就是兩題
        q = AskQueue.adding(r("要不要寄報價單給客戶？", ["好，併 main", "先不要"], 180), to: q, id: id)
        #expect(q.count == 2)
        // 看板自己發的題（換秘書）不被 AI 併掉
        var board = [ask("QB", "要不要換秘書？", ["同意", "不要"], at: t0)]; board[0].action = "captain"
        #expect(AskQueue.adding(r("要不要換個秘書？", ["同意", "不要"], 10), to: board, id: id).count == 2)
    }

    @Test("秘書的 --ask 跟組員還沒答的 --ask 是同一張單 ⇒ 擋；不同單、組員沒單、題目不像 ⇒ 不擋")
    func captainDuplicate() throws {
        let ts = [task("T1", at: t0), task("T2", sid: "W2", at: t0)]
        let asks = ["W1": [ask("QAAAA", "要不要把修正鈕併進 main？", ["好", "不要"], at: t0)], "W3": [ask("QCCCC", "要不要寄報價單？", nil, at: t0)]]
        // 帶同一個 --task：題目怎麼寫都擋
        var r = SelfReport(status: .review, ask: "T1 那邊要不要先等一下？", task: "T1", at: t0 + 10)
        let d = try #require(TaskNotes.captainDuplicate(captain: "CAP", report: r, tasks: ts, asks: asks, now: t0 + 10))
        #expect(d.sid == "W1" && d.task == "T1" && d.ask.id == "QAAAA")
        let msg = TaskNotes.duplicateMessage(d, name: "Milo", orbit: "orbit", owner: "小明")
        #expect(msg.contains("Milo") && msg.contains("QAAAA") && msg.contains("T1") && msg.contains("拿掉 --ask"))
        // 沒帶 --task：題目一樣或很像 ⇒ 擋
        r = SelfReport(status: .review, ask: "要不要把修正鈕併進 main", at: t0 + 10)
        #expect(TaskNotes.captainDuplicate(captain: "CAP", report: r, tasks: ts, asks: asks, now: t0 + 10)?.task == "T1")
        // 題目不像 ⇒ 不擋
        r.ask = "今天要不要開 Fable？"
        #expect(TaskNotes.captainDuplicate(captain: "CAP", report: r, tasks: ts, asks: asks, now: t0 + 10) == nil)
        // 組員沒有派工單（W3）：同題也不擋（那不是派出去的事）
        r.ask = "要不要寄報價單"
        #expect(TaskNotes.captainDuplicate(captain: "CAP", report: r, tasks: ts, asks: asks, now: t0 + 10) == nil)
        // 帶的是別張單（T2 的 W2 沒在問）⇒ 不擋
        r = SelfReport(status: .review, ask: "T2 要先停嗎？", task: "T2", at: t0 + 10)
        #expect(TaskNotes.captainDuplicate(captain: "CAP", report: r, tasks: ts, asks: asks, now: t0 + 10) == nil)
        // 沒有 --ask ⇒ 不擋
        #expect(TaskNotes.captainDuplicate(captain: "CAP", report: SelfReport(status: .working, task: "T1", at: t0), tasks: ts, asks: asks, now: t0) == nil)
    }

    // MARK: ③ 秘書只收完成與卡住

    @Test("一般帶 --ask 的組員卡不推【工作回報】；派工單完成、卡住照推；要使用者決定（review）不推")
    func onlyDoneAndBlocked() {
        var st = CardRelay.State(); st.seeded = true
        var a = SelfReport(status: .review, summary: "問一下", ask: "要 push 嗎", doing: "改按鈕", options: ["好", "不要"], at: t0)
        #expect(CardRelay.plan(reports: ["W1": a], captain: "CAP", captainLive: true, state: &st, now: t0) { _, _ in "x" }.isEmpty)
        a.status = .blocked; a.at = t0 + 100
        #expect(CardRelay.plan(reports: ["W1": a], captain: "CAP", captainLive: true, state: &st, now: t0 + 100) { _, _ in "x" }.isEmpty)
        var t = task("T1", at: t0)
        t.apply(SelfReport(status: .review, summary: "要你決定", ask: "要 push 嗎", at: t0 + 10)); #expect(!Captain.shouldNotify(t))
        t.apply(SelfReport(status: .blocked, summary: "沒權限", at: t0 + 20)); #expect(Captain.shouldNotify(t))
        t.notified = .blocked
        t.apply(SelfReport(status: .done, summary: "好了", at: t0 + 30)); #expect(Captain.shouldNotify(t))
    }

    @Test("秘書守則：使用者對組員的指令一律算數、不查證、只在卡住時出手；組員被關掉自己開衛星終端機")
    func manualText() {
        LocalFixture.use()
        let m = Captain.manual(orbit: "orbit")
        #expect(m.contains("一律算數") && m.contains("不要發訊問組員") && m.contains("只在有人卡住時出手"))
        #expect(m.contains("只收「完成」與「卡住」") && m.contains("不再有【工作回報】"))
        #expect(m.contains("衛星終端機") && m.contains("claude --bg -n <英文名>") && m.contains("不要叫小明自己開"))
        #expect(m.contains("orbit card 會擋下"))
    }

    @Test("11-28 回答記錯單：題目記著自己問的時候的 --task；沒帶的題、派工單在題目之後才派 ⇒ 不記到那張")
    func askKeepsItsOwnTask() {
        let r = SelfReport(status: .review, summary: "s", ask: "待修清單要怎麼做？", task: "T9", options: ["a", "b"], at: t0)
        #expect(AskQueue.adding(r, to: [], id: { "Q1" }).first?.task == "T9")
        let plain = SelfReport(status: .review, summary: "s", ask: "另一題", options: ["a"], at: t0)
        #expect(AskQueue.adding(plain, to: [], id: { "Q2" }).first?.task == nil)
        // 08:3x 問待修清單（沒帶 --task）、08:42 才派打包腳本單 ⇒ 答待修那題不記到打包腳本單
        let later = [task("T1128084238", at: t0 + 300)]
        #expect(TaskNotes.target(sid: "W1", name: nil, cardTask: nil, askedAt: t0, question: "待修", captain: "CAP", tasks: later, asks: [:]) == nil)
        #expect(TaskNotes.target(sid: "W1", name: nil, cardTask: nil, askedAt: t0 + 600, question: "x", captain: "CAP", tasks: later, asks: [:])?.id == "T1128084238")
        // 題目帶的 --task 優先
        let two = [task("T1", at: t0), task("T2", at: t0 + 10)]
        #expect(TaskNotes.target(sid: "W1", name: nil, cardTask: "T1", askedAt: t0 + 20, question: nil, captain: "CAP", tasks: two, asks: [:])?.id == "T1")
    }
}
