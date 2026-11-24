import Foundation
import Testing
@testable import ShoWorkCore

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
        #expect(TermAnswer.clean("結尾\\") == "結尾\\。")
        #expect(TermAnswer.clean("看 @a.txt") == nil && TermAnswer.clean("@x") == nil && TermAnswer.clean("\n \u{3}") == nil)
        #expect(TermAnswer.clean("寄給 a@b.c") == "寄給 a@b.c")
    }

    @Test("畫面：空輸入框才打；草稿、選單、別的對話、游標不在開頭、沒開貼上都不打")
    func gate() {
        #expect(TermAnswer.blocked(screen(), name: "Hana5") == nil)
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

    @Test("確認：只認使用者那一行；跨 session 訊息、系統訊息、別句不算")
    func confirm() {
        func line(_ c: String, _ extra: String = "") -> Data { Data(#"{"type":"user"\#(extra),"message":{"role":"user","content":"\#(c)"}}"#.utf8) }
        #expect(TermAnswer.confirmed(line("好，推"), text: "好，推"))
        #expect(!TermAnswer.confirmed(line("Another Claude session sent a message: 好，推"), text: "好，推"))
        #expect(!TermAnswer.confirmed(line("好，推", #","isMeta":true"#), text: "好，推") && !TermAnswer.confirmed(line("好"), text: "好，推"))
    }
}
