import Foundation
import Testing
@testable import ShoWorkCore

// 11-11「我根本就沒有按鈕」：--ask 排隊（Asks.swift）。假 session、假專案、假問題（10-22 規矩）
@Suite("等你回答排隊：blocked 也列、新卡不蓋舊題、工作中不擠掉", .serialized)
struct AskQueueTests {
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    func ids() -> () -> String { var n = 0; return { n += 1; return "Q000\(n)" } }

    func card(_ r: SelfReport, at t: Date) -> SelfReport { var x = r; x.at = t; return x }

    /// 一個 session 的看板：光暈、自報、佇列
    func build(glow: WorkState?, status: String = "idle", report: SelfReport?, asks: [PendingAsk]) -> BoardCard {
        let s = SessionRecord(pid: 7, sessionId: "S", cwd: "/h/專案A", status: status, updatedAt: 1)
        var t = TranscriptInfo(); t.lastPromptAt = now.addingTimeInterval(-600); t.lastActivity = now.addingTimeInterval(-1)
        return Board.build(sessions: [s], transcripts: ["S": t], glows: glow.map { [7: $0] } ?? [:], teams: [], inbox: [],
                           reports: report.map { ["S": $0] } ?? [:], asks: ["S": asks], now: now, home: "/h", isRepo: { _ in false })[0]
    }

    @Test("bug 1：--status blocked 的 --ask 也在「等你回答」，有選項按鈕")
    func blockedAsk() throws {
        let r = SelfReport(status: .blocked, summary: "等你決定", ask: "律師那封要不要回？", options: ["回", "先不要"], at: now.addingTimeInterval(-30))
        let q = AskQueue.adding(r, to: [], id: ids())
        let c = build(glow: .waiting, report: r, asks: q)
        #expect(c.column == .review && c.reason == "要你決定：律師那封要不要回？")
        #expect(Mood.of(c) == .waiting)
        let it = try #require(Inbox.items([c]).first)
        #expect(it.kind == .reply && it.question == "律師那封要不要回？" && it.options == ["回", "先不要"] && it.askId == "Q0001")
        let web = WebSnapshot.make(cards: [c], tasks: [], answered: [:], now: now)
        #expect(web.sessions.first?.question == "律師那封要不要回？" && web.sessions.first?.canAnswer == true)
        #expect((try? WebSnapshot.validate(answer: "回", askId: c.asks.first?.id, for: "S", cards: [c]).get())?.card.sessionId == "S")
        // 舊行為（沒有佇列）：blocked 自報是「卡住」，不在等你回答
        #expect(build(glow: .waiting, report: r, asks: []).column == .stuck)
    }

    @Test("bug 2：後來的卡片不蓋掉還沒回答的題；最早的先問，答了才換下一題")
    func queueKeepsOld() throws {
        let id = ids()
        let a = SelfReport(status: .review, ask: "創投那份要寄嗎？", options: ["寄", "不寄"], at: now.addingTimeInterval(-3600))
        let b = SelfReport(status: .review, ask: "合約版本用哪一版？", at: now.addingTimeInterval(-600))
        let plain = SelfReport(status: .done, summary: "別的事做完了", at: now.addingTimeInterval(-60))
        var q = AskQueue.adding(a, to: [], id: id)
        q = AskQueue.adding(b, to: q, id: id)
        q = AskQueue.adding(plain, to: q, id: id)                       // 沒帶 --ask：佇列不動
        #expect(q.map(\.ask) == ["創投那份要寄嗎？", "合約版本用哪一版？"])
        q = AskQueue.adding(card(SelfReport(status: .review, ask: "創投那份要寄嗎", options: ["寄", "改天"]), at: now), to: q, id: id)
        #expect(q.count == 2 && q[0].options == ["寄", "改天"] && q[0].at == a.at)   // 同一題再問：只換選項、不重排
        let c = build(glow: .done, report: plain, asks: q)               // 最新的卡沒問題，舊題還在
        let it = try #require(Inbox.items([c]).first)
        #expect(it.question == "創投那份要寄嗎？" && it.more == 1 && it.answered == nil)
        #expect(WebSnapshot.make(cards: [c], tasks: [], answered: [:], now: now).sessions[0].question == "創投那份要寄嗎？（答完後面還有 1 題）")
        // 答了第一題（從佇列拿掉）⇒ 換第二題，不會被「已送出」蓋掉
        let c2 = build(glow: .done, report: plain, asks: Array(q.dropFirst()))
        let it2 = try #require(Inbox.items([c2], answered: ["S": now]).first)
        #expect(it2.question == "合約版本用哪一版？" && it2.answered == nil && it2.generic)
        // 過期（48 小時）就不列
        #expect(AskQueue.live(q, now: now.addingTimeInterval(AskQueue.ttl + 1)).isEmpty)
        #expect(AskQueue.live(q.reversed(), now: now).map(\.ask) == q.map(\.ask))   // 永遠最早的在前
    }

    @Test("bug 3：Puppy 01:05:34 發 --ask、01:05:39 下一個工具動作變回工作中 ⇒ 題目照樣在「等你回答」")
    func workingDoesNotHide() throws {
        let r = SelfReport(status: .review, ask: "第 3 版 7 支怎麼處理？", options: ["照排程發", "先改"], at: now.addingTimeInterval(-5))
        let q = AskQueue.adding(r, to: [], id: ids())
        // 剛發卡：做完了
        #expect(build(glow: .done, report: r, asks: q).reason == "要你決定：第 3 版 7 支怎麼處理？")
        // 5 秒後工具動作：光暈 working、status busy；接著又發一張 working 卡（沒 --ask）
        let next = SelfReport(status: .working, summary: "順手整理檔名", at: now)
        let c = build(glow: .working, status: "busy", report: next, asks: AskQueue.adding(next, to: q, id: ids()))
        #expect(c.column == .review && c.reason == "要你決定：第 3 版 7 支怎麼處理？" && c.stillWorking)
        #expect(Inbox.items([c]).first?.options == ["照排程發", "先改"])
        // 很久沒動靜（base＝卡住）也一樣
        #expect(CardRules.column(base: (.stuck, "12 分鐘沒有新動靜"), glow: .working, report: next, decision: nil,
                                 lastPrompt: nil, lastActivity: nil, pending: q[0]).0 == .review)
        // 你的「放行」決定也不會把還沒答的題收掉；只有終端機開著對話框（input）更優先
        #expect(CardRules.column(base: (.review, "做完了"), glow: .done, report: r, decision: Decision(action: .approve, at: now),
                                 lastPrompt: nil, lastActivity: now.addingTimeInterval(-10), pending: q[0]).1.hasPrefix("要你決定"))
        #expect(CardRules.column(base: (.review, "等你回答"), glow: .input, report: r, decision: nil,
                                 lastPrompt: nil, lastActivity: nil, pending: q[0]) == (.review, "等你回答"))
        // 沒佇列時舊行為：工作中忽略自報
        #expect(build(glow: .working, status: "busy", report: next, asks: []).column == .active)
    }

    @Test("一題只送一次：同時按 20 下只成功一次；送出中、沒確認到、答過、過期、別的 session、選項對不上都不給")
    func claim() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claim-\(UUID().uuidString)")
        setenv("SHOWORK_ASKS_DIR", dir.path, 1)
        defer { unsetenv("SHOWORK_ASKS_DIR"); try? FileManager.default.removeItem(at: dir) }
        let n = now, q = PendingAsk(id: "Q1", ask: "部署嗎", options: ["好，現在部署", "不要"], at: n), p = AnswerPick(askId: "Q1", option: "好，現在部署")
        func go(_ x: AnswerPick?, _ sid: String = "S", _ t: Date? = nil) -> AskQueue.Claim { AskQueue.claim(sid: sid, pick: x, now: t ?? n) }
        AskQueue.save("S", [q])
        let lock = NSLock(); nonisolated(unsafe) var oks = 0, busy = 0
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let r = AskQueue.claim(sid: "S", pick: p, now: n)
            lock.withLock { if case .ok = r { oks += 1 } else if r == .busy { busy += 1 } }
        }
        #expect(oks == 1 && busy == 19)
        AskQueue.unclaim(sid: "S", id: "Q1")
        #expect(go(p) == .ok(q, text: "好，現在部署", queued: 1))
        AskQueue.markUnsure(sid: "S", id: "Q1", now: n)
        #expect(go(p) == .busy)                                       // 沒確認到：不能再按成第二次送達
        AskQueue.resolve(sid: "S", id: "Q1", cardsDir: dir)
        #expect(go(p) == .gone)
        AskQueue.save("S", [q])
        #expect(AskQueue.answeredInTerminal(sid: "S", prompt: "不要", captain: nil, cardsDir: dir).count == 1 && go(p) == .gone)     // 終端機已答
        AskQueue.save("S", [q])
        #expect(go(.init(askId: "Q1", option: "rm 全部並部署")) == .gone && go(p, "別的") == .gone && go(nil) == .gone && go(.init(askId: "Q9", option: "不要")) == .gone)
        #expect(go(p, "S", n + AskQueue.ttl + 1) == .gone)
        #expect(AskQueue.load("S") == [q])                            // 被拒的都沒動到題目
        #expect(AskQueue.withdraw(sid: "S", id: "all") == 1 && go(p) == .gone)
        // 送到一半：終端機答掉 ⇒ 之後不會復活；又多一題 ⇒ 兩邊都不掉
        AskQueue.save("S", [q]); _ = go(p)
        _ = AskQueue.answeredInTerminal(sid: "S", prompt: "不要", captain: nil, cardsDir: dir)
        AskQueue.unclaim(sid: "S", id: "Q1"); AskQueue.markUnsure(sid: "S", id: "Q1")
        #expect(AskQueue.load("S").isEmpty)
        AskQueue.save("S", [q]); _ = go(p)
        AskQueue.record(sid: "S", report: SelfReport(status: .review, ask: "新的題", at: n), now: n)
        #expect(AskQueue.load("S").map(\.ask) == ["部署嗎", "新的題"] && go(p) == .busy)
        AskQueue.resolve(sid: "S", id: "Q1", cardsDir: dir)
        #expect(AskQueue.load("S").map(\.ask) == ["新的題"])
        // 同時排 20 題不互蓋
        AskQueue.save("S", [])
        DispatchQueue.concurrentPerform(iterations: 20) { i in _ = AskQueue.record(sid: "S", report: SelfReport(status: .review, ask: "並行\(i)", at: n), now: n) }
        #expect(AskQueue.load("S").count == 20)
        // App 送到一半當掉：不自動重送，過一分鐘顯示成沒確認到
        var dead = q; dead.sendingAt = Date(timeIntervalSinceNow: -61)
        AskQueue.save("S", [dead])
        #expect(dead.shown.contains("請到它的終端機看") && go(p) == .busy)
    }

    @Test("檔案：showork card 排隊、回答拿掉並清卡片檔同一題、撤回、舊 BoardCard JSON 讀得回來")
    func files() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asks-\(UUID().uuidString)")
        let cards = dir.appendingPathComponent("cards")
        try FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)
        setenv("SHOWORK_ASKS_DIR", dir.appendingPathComponent("asks").path, 1)
        defer { unsetenv("SHOWORK_ASKS_DIR"); try? FileManager.default.removeItem(at: dir) }

        let r = SelfReport(status: .blocked, ask: "要不要寄？", options: ["寄", "不寄"], at: now)
        AskQueue.record(sid: "S", report: r, now: now)
        AskQueue.record(sid: "S", report: SelfReport(status: .review, ask: "第二題？", at: now + 10), now: now + 10)
        AskQueue.record(sid: "S", report: SelfReport(status: .working, summary: "沒問題", at: now + 20), now: now + 20)
        var q = AskQueue.load("S")
        #expect(q.map(\.ask) == ["要不要寄？", "第二題？"])
        #expect(AskQueue.all()["S"]?.count == 2)

        // 回答第一題：佇列拿掉，卡片檔上同一題的 --ask 一起清
        try BoardJSON.encoder.encode(r).write(to: cards.appendingPathComponent("S.json"))
        let done = try #require(AskQueue.resolve(sid: "S", id: q[0].id, cardsDir: cards))
        #expect(done.ask == "要不要寄？")
        let left = try BoardJSON.decoder.decode(SelfReport.self, from: Data(contentsOf: cards.appendingPathComponent("S.json")))
        #expect(left.ask == nil && left.options == nil)
        q = AskQueue.load("S")
        #expect(q.map(\.ask) == ["第二題？"])
        #expect(AskQueue.resolve(sid: "S", id: "QZZZZ", cardsDir: cards) == nil)

        // 撤回：編號不分大小寫；all；空了就刪檔
        #expect(AskQueue.withdraw(sid: "S", id: "QNOPE") == 0)
        #expect(AskQueue.withdraw(sid: "S", id: q[0].id.lowercased()) == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("asks/S.json").path))
        AskQueue.record(sid: "S", report: r, now: now)
        #expect(AskQueue.resolve(sid: "S", question: "要不要寄"))        // 秘書卡片同一題（Answered）
        AskQueue.record(sid: "S", report: r, now: now)
        #expect(AskQueue.withdraw(sid: "S", id: "all") == 1 && AskQueue.load("S").isEmpty)

        // 舊版存的 BoardCard（沒有 asks／stillWorking）讀得回來
        let old = #"{"id":"S","column":"review","reason":"x","project":"P","title":"T","pid":1,"sessionId":"S"}"#
        let c = try BoardJSON.decoder.decode(BoardCard.self, from: Data(old.utf8))
        #expect(c.asks.isEmpty && !c.stillWorking)
    }

    @Test("11-14：在終端機打字回答 ⇒ 那個 session 的待答題清掉；戰情中心轉來的回答、其他 session 訊息、放行不算")
    func terminalAnswer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asks-term-\(UUID().uuidString)")
        let cards = dir.appendingPathComponent("cards")
        try FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)
        setenv("SHOWORK_ASKS_DIR", dir.appendingPathComponent("asks").path, 1)
        defer { unsetenv("SHOWORK_ASKS_DIR"); try? FileManager.default.removeItem(at: dir) }

        let r = SelfReport(status: .review, summary: "等你", ask: "要不要寄？", options: ["寄", "不要"], at: now)
        AskQueue.record(sid: "S", report: r, now: now)
        AskQueue.record(sid: "S", report: SelfReport(status: .blocked, summary: "再等", ask: "第二題？", at: now + 5), now: now + 5)
        AskQueue.record(sid: "CAP", report: r, now: now)                 // 秘書也掛著同一題
        try BoardJSON.encoder.encode(r).write(to: cards.appendingPathComponent("S.json"))
        try BoardJSON.encoder.encode(r).write(to: cards.appendingPathComponent("CAP.json"))

        // 不算回答：戰情中心轉來的（另外走 resolve，只拿掉答的那一題）、其他 session、系統通知、放行、空白
        for p in ["<cross-session-message from=\"uds:\" from-name=\"AI工作戰情中心（使用者）\">【使用者從戰情中心回答你的問題】寄</cross-session-message>",
                  "<cross-session-message from=\"uds:\" from-name=\"Bob\">你好</cross-session-message>",
                  "<task-notification>done</task-notification>", "放行", "放行 BX12", "  ", nil] as [String?] {
            #expect(AskQueue.answeredInTerminal(sid: "S", prompt: p, captain: "CAP", cardsDir: cards).isEmpty, "\(p ?? "nil")")
        }
        #expect(AskQueue.load("S").count == 2)

        // 本人在終端機打字：兩題都清、卡片 --ask 清、秘書同一題也清
        let gone = AskQueue.answeredInTerminal(sid: "S", prompt: "寄吧", captain: "CAP", cardsDir: cards)
        #expect(gone.map(\.ask) == ["要不要寄？", "第二題？"])
        #expect(AskQueue.load("S").isEmpty && AskQueue.load("CAP").isEmpty)
        for f in ["S.json", "CAP.json"] {
            let left = try BoardJSON.decoder.decode(SelfReport.self, from: Data(contentsOf: cards.appendingPathComponent(f)))
            #expect(left.ask == nil, "\(f)")
        }
        // 沒有待答題時打字什麼都不動
        #expect(AskQueue.answeredInTerminal(sid: "S", prompt: "再一個", captain: "CAP", cardsDir: cards).isEmpty)
    }
}
