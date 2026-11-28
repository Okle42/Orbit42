import Foundation
import Testing
@testable import Orbit42Core

/// 11-28 Keng「回報卡住誤報」：組員在等背景打包時發 blocked，派工回報寫成「卡住」⇒ 加 --status waiting，跟真的卡住分開
@Suite("在等 ≠ 卡住：--status waiting")
struct WaitingStatusTests {
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    @Test("--status waiting 存成 blocked＋waiting（終端機照樣亮橘）；舊的 --status blocked 照樣是卡住")
    func parse() throws {
        let w = try SelfReport.parse(args: ["--status", "waiting", "--summary", "等背景打包"], now: t0).get()
        #expect(w.status == .blocked && w.isWaiting)
        let b = try SelfReport.parse(args: ["--status", "blocked", "--summary", "編不過"], now: t0).get()
        #expect(b.status == .blocked && !b.isWaiting)
        // 舊卡片檔（沒有 waiting 欄）讀得回來、算卡住
        let old = try BoardJSON.decoder.decode(SelfReport.self, from: Data(#"{"status":"blocked","at":"2026-11-28T00:00:00Z"}"#.utf8))
        #expect(!old.isWaiting)
        if case .failure(let e) = SelfReport.parse(args: ["--status", "stuck"], now: t0) { #expect(e.message.contains("waiting")) } else { Issue.record("要擋") }
    }

    @Test("派工單：在等＝「在等」、還在進行、不通知秘書；真的卡住照舊通知")
    func task() throws {
        var t = CaptainTask(id: "T1", from: "CAP", to: "Milo", toSession: "W1", text: "改打包腳本", state: .working, createdAt: t0)
        t.apply(try SelfReport.parse(args: ["--status", "waiting", "--summary", "等背景打包"], now: t0 + 60).get())
        #expect(t.state == .waiting && t.state.title == "在等" && t.state.open)
        #expect(!Captain.shouldNotify(t))
        t.apply(try SelfReport.parse(args: ["--status", "blocked", "--summary", "編不過"], now: t0 + 120).get())
        #expect(t.state == .blocked && t.state.title == "卡住" && Captain.shouldNotify(t))
    }

    @Test("看板原因：在等以「在等外部」開頭（球體用它判灰色、不跳紅色卡住橫幅）；卡住照舊")
    func reason() throws {
        let w = try SelfReport.parse(args: ["--status", "waiting", "--summary", "等背景打包"], now: t0).get()
        #expect(CardRules.blockedReason(w) == "在等外部的事：等背景打包")
        let b = try SelfReport.parse(args: ["--status", "blocked", "--summary", "編不過"], now: t0).get()
        #expect(CardRules.blockedReason(b) == "AI 自報卡住：編不過")
    }

    @Test("說明文字：組員卡片說明寫 waiting，不再叫人「等外部的事也用 blocked」")
    func guidance() {
        let h = CardRules.brief(orbit: "orbit")
        #expect(h.contains("waiting＝在等外部的事") && !h.contains("等外部的事（等回信、等背景工作）也用 blocked"))
    }
}
