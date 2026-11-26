import Foundation
import Testing
@testable import Orbit42Core

@Suite("TermAnswer")
struct TermAnswerTests {
    let bar = String(repeating: "─", count: 60)
    func screen(_ input: String = "❯ ", dim: String = "", label: String = "Hana5", below: [String] = ["  ⏵⏵ bypass permissions on"], col: Int = 2, paste: Bool = true) -> TermAnswer.Screen {
        var rows = ["⏺ 做完了", "", "\(String(repeating: "─", count: 50)) \(label) ─"].map { TermAnswer.Screen.Row(text: $0, solid: $0) }
        rows.append(.init(text: input + dim, solid: input))
        rows += ([bar] + below).map { .init(text: $0, solid: $0) }
        return .init(rows: rows, cursorRow: 3, cursorCol: col, paste: paste)
    }

    @Test("濾字：換行、控制字元拿掉；開頭是指令的加「回答：」；@、空的不打")
    func clean() {
        #expect(TermAnswer.clean(" 好\n推\u{1B}[201~上\u{7}去\r ") == "好 推[201~上去")
        for x in ["/clear", "!rm -rf x", "#記住", "&x", "?", "exit", "QUIT", "<system-reminder>"] { #expect(TermAnswer.clean(x) == "回答：" + x) }
        // Gavin5：指令符號後接變體選擇符／組合字／零寬字、全形 ⇒ 躲不過
        for c in ["!", "/", "#", "&", "?"] {
            for x in ["\u{FE0F}", "\u{FE0E}", "\u{0338}", "\u{20DD}", "\u{200B}", "\u{200D}", "\u{2060}", "\u{E0100}", "\u{034F}", "\u{00AD}"] {
                #expect(TermAnswer.clean(c + x + "ls") == nil && TermAnswer.clean(x + c + "ls") == nil)
            }
        }
        for x in ["！ls", "／clear", "＃x", "﹗ls", "⁄x", "、x", "`x", "-x", "\u{3000}/x", "ｅｘｉｔ", "：ｑ"] { #expect(TermAnswer.clean(x)?.hasPrefix("回答：") == true, "\(x)") }
        #expect(TermAnswer.clean("＠a.txt") == nil && TermAnswer.clean("看 ﹫a") == nil)
        for x in ["/\u{301}clear", "!\u{FE0F}; rm -rf x", "!\u{200D}; id", "!\u{301};id", "#\u{FE0F}\u{20E3}x", "好\u{E0072}\u{E006D}", "\u{AD}!id"] { #expect(TermAnswer.clean(x) == nil) }
        // 正常的 emoji 不拆壞：整句改走訊息；單純的文字符號照打
        for x in ["好 👨‍👩‍👧", "❤️ 好", "好👍"] { #expect(TermAnswer.clean(x) == nil) }
        #expect(TermAnswer.clean("好 ✓ 完成") == "好 ✓ 完成")
        for x in ["好，推上去", "A 案", "3", "ok（先這樣）", "確認！"] { #expect(TermAnswer.clean(x) == x) }
        #expect(TermAnswer.clean("結尾\\") == "結尾\\。")
        #expect(TermAnswer.clean("看 @a.txt") == nil && TermAnswer.clean("@x") == nil && TermAnswer.clean("\n \u{3}") == nil)
        #expect(TermAnswer.clean("寄給 a@b.c") == "寄給 a@b.c")
    }

    @Test("畫面：空輸入框才打；草稿、選單、別的對話、游標不在開頭、沒開貼上都不打")
    func gate() {
        #expect(TermAnswer.blocked(screen(), name: "Hana5") == nil)
        // 11-25 畫面改顯示職責：框線上印的還是 session 名（收件地址），拿顯示名來比一定不打
        for shown in ["修改 · Orbit42", "修改 · Orbit42｜答案卡補修", "秘書 · 未歸專案"] {
            #expect(TermAnswer.blocked(screen(), name: shown) != nil)
            #expect(Nicknames.hookOutput(Nickname(name: "Hana5"), done: false, event: "UserPromptSubmit", label: shown).contains(#""sessionTitle":"Hana5""#))
        }
        #expect(TermAnswer.blocked(screen("❯ ", dim: "Try \"x\""), name: "Hana5") == nil)          // 淡色提示字不算草稿
        #expect(TermAnswer.blocked(screen("❯ 打到一半"), name: "Hana5") != nil)
        #expect(TermAnswer.blocked(screen(label: "Hana"), name: "Hana5") != nil)
        #expect(TermAnswer.blocked(screen(below: ["Enter to select · Esc to cancel"]), name: "Hana5") != nil)
        #expect(TermAnswer.blocked(screen(col: 9), name: "Hana5") != nil)
        #expect(TermAnswer.blocked(screen(paste: false), name: "Hana5") != nil)
        #expect(TermAnswer.blocked(screen("! "), name: "Hana5") != nil)                              // bash 模式
        let menu = TermAnswer.Screen(rows: ["Do you want to proceed?", "❯ 1. Yes", "  2. No", "Esc to cancel"].map { .init(text: $0, solid: $0) }, cursorRow: 1, cursorCol: 0, paste: true)
        #expect(TermAnswer.blocked(menu, name: "Hana5") != nil)
    }

    @Test("題目與選項：沒題目、別題、過期、排兩題、不是選項的都不准；補充框要那題還在")
    func pick() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let q = PendingAsk(id: "Q1", ask: "推嗎", options: ["好，推（建議）", "先不要"], at: now)
        func go(_ p: AnswerPick, _ xs: [PendingAsk]) -> String? { p.text(asks: xs, now: now) }
        #expect(go(.init(askId: "Q1", option: "好，推"), [q]) == "好，推" && go(.init(askId: "Q1", option: "好，推（建議）"), [q]) == "好，推")
        #expect(go(.init(askId: "Q1", option: "先不要", free: " 等我 "), [q]) == "先不要\n補充：等我")
        #expect(go(.init(askId: "Q1", option: nil, free: "我自己講"), [q]) == "我自己講")
        #expect(go(.init(askId: "Q1", option: "rm -rf /"), [q]) == nil)                  // 不是選項
        #expect(go(.init(askId: "Q1", option: nil, free: "任意字"), []) == nil)           // 沒有題目
        #expect(go(.init(askId: "Q2", option: nil, free: "任意字"), [q]) == nil && go(.init(askId: "", option: "先不要"), [q]) == nil)
        #expect(go(.init(askId: "Q1", option: "先不要"), [q, PendingAsk(id: "Q2", ask: "另一題", at: now)]) == nil)
        #expect(AnswerPick(askId: "Q1", option: "先不要").text(asks: [q], now: now + AskQueue.ttl + 1) == nil)
        #expect(AnswerPick(askId: nil, text: "x", options: []) == nil)
        #expect(AnswerPick(askId: "Q1", text: "打的", options: ["好"]) == AnswerPick(askId: "Q1", option: nil, free: "打的"))
    }

    @Test("扣住的按鍵：沒確認到一個都不補（含 Enter）、講丟了什麼；成功或沒打就原樣補回")
    func held() {
        for k in ["\r", "yes\r", "\n", "\u{1B}[200~貼的\u{1B}[201~\r", "\u{1B}[13u", "\u{1B}\r"] {
            let (r, replay) = TermAnswer.settle(.unsure("x"), held: Data(k.utf8), safe: true)
            #expect(replay.isEmpty)
            guard case .unsure(let m) = r else { Issue.record("\(k)"); continue }
            #expect(m.contains("沒有送進去"), "\(k)")
            if k.hasPrefix("yes") { #expect(m.contains("「yes⏎」")) }
        }
        #expect(TermAnswer.settle(.unsure("x"), held: Data("\u{1B}[<35;1;2M\u{1B}[I".utf8), safe: true) == (.unsure("x"), Data()))      // 滑鼠、焦點不算
        for r in [TermAnswer.Outcome.sent, .notStarted("x")] { #expect(TermAnswer.settle(r, held: Data("yes\r".utf8), safe: true) == (r, Data("yes\r".utf8))) }
    }

    @Test("送到了但畫面已是權限框：扣住的 2⏎ 不補、要講（Gavin5 ③c）")
    func heldMenu() {
        let (r, replay) = TermAnswer.settle(.sent, held: Data("2\r".utf8), safe: false)
        #expect(replay.isEmpty)
        guard case .sentDropped(let m) = r else { Issue.record("\(r)"); return }
        #expect(m.contains("「2⏎」沒有送進去"))
        #expect(TermAnswer.settle(.sent, held: Data(), safe: false) == (.sent, Data()))
        #expect(TermAnswer.plain(screen(), name: "Hana5") && !TermAnswer.plain(screen(below: ["Esc to cancel"]), name: "Hana5"))
    }

    @Test("沒確認到：題目留著、介面上明講請看終端機、重新可按；比對同一題仍用原字；舊檔照讀")
    func unsure() throws {
        var a = PendingAsk(id: "Q1", ask: "要 push 嗎", at: Date(timeIntervalSince1970: 1))
        #expect(a.shown == "要 push 嗎" && a.since == a.at)
        a.unsureAt = Date(timeIntervalSince1970: 9)
        #expect(a.shown.contains("請到它的終端機看") && a.shown.hasSuffix("要 push 嗎") && a.since == a.unsureAt)
        #expect(AskQueue.adding(SelfReport(status: .review, ask: "要 push 嗎"), to: [a]).count == 1)
        let old = #"{"id":"Q1","ask":"x","at":"2026-10-21T00:00:00.000Z"}"#
        #expect(try BoardJSON.decoder.decode(PendingAsk.self, from: Data(old.utf8)).unsureAt == nil)
    }

    @Test("確認：只認使用者那一行；跨 session 訊息、系統訊息、別句不算")
    func confirm() {
        func line(_ c: String, _ extra: String = "") -> Data { Data(#"{"type":"user"\#(extra),"message":{"role":"user","content":"\#(c)"}}"#.utf8) }
        #expect(TermAnswer.confirmed(line("好，推"), text: "好，推"))
        #expect(!TermAnswer.confirmed(line("Another Claude session sent a message: 好，推"), text: "好，推"))
        #expect(!TermAnswer.confirmed(line("好，推", #","isMeta":true"#), text: "好，推") && !TermAnswer.confirmed(line("好"), text: "好，推"))
    }
}
