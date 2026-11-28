import Foundation
import Testing
@testable import Orbit42Core

@Suite("Card")
struct CardTests {
    let t0 = Date(timeIntervalSince1970: 1_791_440_000)

    @Test("orbit card 參數解析與錯誤訊息")
    func parse() throws {
        let r = try SelfReport.parse(args: ["--status", "review", "--progress", "80%", "--confidence", "130", "--summary", "做完 A", "--ask", "要 push 嗎"], now: t0).get()
        #expect(r.status == .review && r.progress == 80 && r.confidence == 100 && r.ask == "要 push 嗎" && r.at == t0)
        #expect(SelfReport.parse(args: ["--progress", "5"]) == .failure(CardError("缺 --status")))
        #expect(SelfReport.parse(args: ["--status", "ok"]) == .failure(CardError("--status 只能是 working／review／done／blocked／waiting")))
        #expect(SelfReport.parse(args: ["--status"]) == .failure(CardError("--status 後面少了值")))
        #expect(SelfReport.parse(args: ["--status", "done", "--x", "1"]) == .failure(CardError("不認得的參數 --x")))
    }

    @Test("組員選項不准「請秘書／交給秘書」，秘書自己的卡不受限（T1127061001）")
    func delegation() {
        for bad in ["請秘書幫我 push", "交給秘書決定", "好，叫 秘書 去做", "轉給秘書處理"] {
            #expect(SelfReport.delegationProblem(["好，push", bad], isCaptain: false)?.contains("SendMessage") == true, "\(bad)")
            #expect(SelfReport.delegationProblem([bad], isCaptain: true) == nil)
        }
        #expect(SelfReport.delegationProblem(["好，push|先不要", "秘書通知不疊組員已修好，要裝嗎"], isCaptain: false) == nil)
        #expect(SelfReport.delegationProblem(nil, isCaptain: false) == nil)
        #expect(CardRules.brief(orbit: "/x/orbit").contains("SendMessage 傳給秘書"))
    }

    @Test("欄位：自報、決定、新鮮度、等你回答優先")
    func column() {
        let idle = (BoardColumn.review, "做完了，你還沒看")
        let prompt = t0, later = t0.addingTimeInterval(60)
        let rev = SelfReport(status: .review, ask: "選 A 還是 B", at: later)
        #expect(CardRules.column(base: idle, glow: .done, report: rev, decision: nil, lastPrompt: prompt, lastActivity: later) == (.review, "要你決定：選 A 還是 B"))
        let done = SelfReport(status: .done, at: later)
        #expect(CardRules.column(base: idle, glow: .done, report: done, decision: nil, lastPrompt: prompt, lastActivity: later).0 == .done)
        let stale = SelfReport(status: .done, at: t0.addingTimeInterval(-1))           // 上一輪的
        #expect(CardRules.column(base: idle, glow: .done, report: stale, decision: nil, lastPrompt: prompt, lastActivity: later) == idle)
        let blocked = SelfReport(status: .blocked, summary: "缺金鑰", at: later)
        #expect(CardRules.column(base: idle, glow: nil, report: blocked, decision: nil, lastPrompt: prompt, lastActivity: later) == (.stuck, "AI 自報卡住：缺金鑰"))
        #expect(CardRules.column(base: (.active, "工作中"), glow: .working, report: blocked, decision: nil, lastPrompt: prompt, lastActivity: later).0 == .stuck)
        // 放行／丟待辦：決定之後沒有新動靜才有效
        let ok = Decision(action: .approve, at: later.addingTimeInterval(5))
        #expect(CardRules.column(base: idle, glow: .done, report: rev, decision: ok, lastPrompt: prompt, lastActivity: later) == (.done, "你已放行"))
        #expect(CardRules.column(base: idle, glow: .done, report: rev, decision: ok, lastPrompt: prompt, lastActivity: later.addingTimeInterval(9)).0 == .review)
        let park = Decision(action: .park, note: "下週再說", at: later.addingTimeInterval(5))
        #expect(CardRules.column(base: idle, glow: nil, report: nil, decision: park, lastPrompt: prompt, lastActivity: later) == (.todo, "你丟回待辦：下週再說"))
        // 等你回答：自報與決定都不能蓋掉
        let input = (BoardColumn.review, "等你回答")
        #expect(CardRules.column(base: input, glow: .input, report: done, decision: ok, lastPrompt: prompt, lastActivity: later) == input)
    }

    @Test("要不要審：只在待審、每輪一次")
    func needsReview() {
        let r = Review(progress: 50, confidence: 50, verdict: "pass", issues: [], turn: t0, model: "sonnet")
        #expect(CardRules.needsReview(column: .review, review: nil, turn: t0))
        #expect(!CardRules.needsReview(column: .review, review: r, turn: t0))
        #expect(CardRules.needsReview(column: .review, review: r, turn: t0.addingTimeInterval(2)))
        #expect(!CardRules.needsReview(column: .done, review: nil, turn: t0))
        #expect(!CardRules.needsReview(column: .review, review: nil, turn: nil))
        // 同一輪只差小數秒（舊檔）不重審；存檔來回保留毫秒
        #expect(!CardRules.needsReview(column: .review, review: r, turn: t0.addingTimeInterval(0.056)))
        let ms = Date(timeIntervalSince1970: 1_791_440_000.056)
        let back = try! BoardJSON.decoder.decode(Review.self, from: BoardJSON.encoder.encode(Review(progress: 1, confidence: 1, verdict: "pass", issues: [], turn: ms, at: ms, model: "m")))
        #expect(abs(back.turn.timeIntervalSince(ms)) < 0.001)
        #expect(try! BoardJSON.decoder.decode(Decision.self, from: Data(#"{"action":"approve","at":"2026-10-08T10:16:42Z"}"#.utf8)).action == .approve)
    }

    @Test("審核輸出解析：圍欄、夾雜文字、超範圍、壞掉")
    func parseReview() throws {
        let s = "好的，結果如下：\n```json\n{\"progress\": 120, \"confidence\": 40, \"verdict\": \"concern\", \"issues\": [\"沒跑測試\",\"a\",\"b\",\"c\"]}\n```"
        let r = try #require(CardRules.parseReview(s, turn: t0, model: "sonnet", cost: 0.12, now: t0))
        #expect(r.progress == 100 && r.confidence == 40 && r.verdict == "concern" && r.issues.count == 3 && r.costUSD == 0.12)
        #expect(CardRules.parseReview("{\"verdict\":\"great\"}", turn: t0, model: "m", cost: nil)?.verdict == "concern")
        #expect(CardRules.parseReview("沒有 JSON", turn: t0, model: "m", cost: nil) == nil)
    }

    @Test("審核摘錄：使用者、AI、工具，太長截前面")
    func excerpt() {
        let lines = [
            #"{"type":"user","message":{"content":"幫我修 bug"}}"#,
            #"{"type":"user","message":{"content":"<task-notification>x"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"好"},{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}"#,
        ]
        let e = CardRules.excerpt(Data(lines.joined(separator: "\n").utf8))
        #expect(e == "【使用者】幫我修 bug\n【AI】好\n【工具 Bash】swift test")
        #expect(CardRules.excerpt(Data(lines.joined(separator: "\n").utf8), limit: 10).hasPrefix("⋯（前面省略）"))
    }

    @Test("待命輪不用審：只發卡片／查名冊算沒動手")
    func lastTurnDidWork() {
        let ask = #"{"type":"user","message":{"content":"巡檢"}}"#
        let card = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"\"/x/bin/orbit\" card --doing \"待命\""}}]}}"#
        let res = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        let edit = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a"}}]}}"#
        let talk = #"{"type":"assistant","message":{"content":[{"type":"text","text":"沒事"}]}}"#
        func run(_ l: [String]) -> Bool { CardRules.lastTurnDidWork(Data(l.joined(separator: "\n").utf8)) }
        #expect(!run([ask, card, res, talk]))
        #expect(!run([edit, ask, talk]))
        #expect(run([ask, card, res, edit]))
        #expect(run([card, res, talk]))          // 看不到使用者那句：保守當作有動手
    }

    @Test("帳號流量快照（statusline 存的格式）")
    func rateLimits() throws {
        let j = #"{"rate_limits": {"five_hour": {"used_percentage": 27, "resets_at": 1791457200}, "seven_day": {"used_percentage": 59.5, "resets_at": 1791774000}}, "at": "2026-10-08 18:12:08"}"#
        let r = try #require(RateLimits.parse(Data(j.utf8)))
        #expect(r.fiveHour?.used == 27 && r.sevenDay?.used == 59.5 && r.snapshotAt != nil)
        let after = r.current(now: Date(timeIntervalSince1970: 1_791_457_201))
        #expect(after.fiveHour?.used == 0 && after.sevenDay?.used == 59.5)
        #expect(RateLimits.parse(Data(#"{"rate_limits":{}}"#.utf8)) == nil)
    }

    @Test("說明文字帶 orbit 絕對路徑、要求 --doing、告訴 AI 自己的英文名")
    func brief() {
        #expect(CardRules.brief(orbit: "/x/orbit").contains("\"/x/orbit\" card --doing"))
        #expect(CardRules.brief(orbit: "/x/orbit", name: "Luna").contains("你在Orbit42的名字是 Luna"))
    }

    @Test("ctx 快照解析與收尾時機")
    func contextGuard() throws {
        let c = try #require(ContextUse.parse(Data(#"{"used_percentage": 86, "total_input_tokens": 172000, "at": 1791475515.9}"#.utf8)))
        #expect(c.percent == 86 && c.tokens == 172000)
        func card(_ col: BoardColumn, _ reason: String = "") -> BoardCard {
            BoardCard(id: "S", column: col, reason: reason, project: "p", title: "t", pid: 1, sessionId: "S")
        }
        let c3 = ContextUse(percent: 30, tokens: 300_000)
        #expect(ContextGuard.shouldWrapUp(card: card(.done), ctx: c3, alreadySent: false, tokenLimit: 250_000))
        #expect(ContextGuard.shouldWrapUp(card: card(.review), ctx: c3, alreadySent: false, tokenLimit: 250_000))
        #expect(!ContextGuard.shouldWrapUp(card: card(.active), ctx: c3, alreadySent: false, tokenLimit: 250_000))            // 等它停下來
        #expect(!ContextGuard.shouldWrapUp(card: card(.review, "等你回答"), ctx: c3, alreadySent: false, tokenLimit: 250_000)) // 不打斷它問你的問題
        #expect(!ContextGuard.shouldWrapUp(card: card(.done), ctx: c3, alreadySent: true, tokenLimit: 250_000))              // 只送一次
        // 10-29 Kang：只剩 token 一個條件——百分比再高也不觸發，token 到線才觸發
        #expect(!ContextGuard.over(c, tokenLimit: 250_000))                                          // 86% 但只有 172k
        #expect(!ContextGuard.over(ContextUse(percent: 95), tokenLimit: 250_000))                    // 沒有 token 數 ⇒ 不觸發
        #expect(!ContextGuard.over(ContextUse(percent: 24.9, tokens: 249_999), tokenLimit: 250_000))
        #expect(ContextGuard.over(ContextUse(percent: 25, tokens: 250_000), tokenLimit: 250_000))
        #expect(!ContextGuard.over(ContextUse(percent: 90, tokens: 900_000), tokenLimit: 1_000_000))
        #expect(ContextGuard.over(ContextUse(percent: 100, tokens: 1_000_000), tokenLimit: 1_000_000))
        // 門檻範圍 250k–1000k、10k 一格；沒設過用 250k；以前的 150k／200k 拉回 250k
        #expect(ContextGuard.clamp(0) == 250_000 && ContextGuard.clamp(150_000) == 250_000 && ContextGuard.clamp(200_000) == 250_000)
        #expect(ContextGuard.clamp(437_000) == 440_000 && ContextGuard.clamp(5_000_000) == 1_000_000 && ContextGuard.clamp(1_000_000) == 1_000_000)
        #expect(ContextGuard.wrapUpPrompt(tokens: 312_345).contains("312k") && ContextGuard.wrapUpPrompt(tokens: 300_000).contains("允許才 push"))
    }
}
