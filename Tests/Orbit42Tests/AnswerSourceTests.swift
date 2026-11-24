import XCTest
@testable import ShoWorkCore
@testable import ShoWorkApp

/// 只有 Keng 在介面上按的才打進終端機；指令列、別的 session 觸發的、放行、排了好幾題、開著權限框的都走原路
@MainActor
final class AnswerSourceTests: XCTestCase {
    func card(_ asks: Int = 1) -> BoardCard {
        var c = BoardCard(id: "s", column: .review, reason: "", project: "P", title: "t", lastActivity: nil, pid: 1, sessionId: "s")
        c.asks = (0..<asks).map { PendingAsk(id: "Q\($0)", ask: "題 \($0)", at: Date()) }
        return c
    }
    func testOnlyUser() {
        let c = card(), p = AnswerPick(askId: "Q0", option: nil, free: "好")
        XCTAssertEqual(BoardActions.typable(c, pick: p, source: .user, asks: c.asks), "好")
        XCTAssertNil(BoardActions.typable(c, pick: p, source: .other, asks: c.asks))
        XCTAssertNil(BoardActions.typable(c, pick: nil, source: .user, asks: c.asks))
        XCTAssertNil(BoardActions.typable(c, pick: p, source: .user, asks: []))                 // 卡片上還有、其實已經答掉了
        XCTAssertNil(BoardActions.typable(c, pick: .init(askId: "Q9", option: nil, free: "好"), source: .user, asks: c.asks))
        XCTAssertNil(BoardActions.typable(card(2), pick: p, source: .user, asks: card(2).asks))
        for f in [" 放行 BABCD", "放\u{200B}行"] { XCTAssertNil(BoardActions.typable(c, pick: .init(askId: "Q0", option: nil, free: f), source: .user, asks: c.asks)) }
        var board = c; board.kind = "board"
        XCTAssertNil(BoardActions.typable(board, pick: p, source: .user, asks: c.asks))
    }
    /// Gavin5：同題按兩次、終端機已答、偽造選項、沒題目 id ⇒ 一次都不多送，不記事先放行；沒寫字改走訊息要講；寫過字不改走訊息
    func testOnceOnly() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("once-\(UUID().uuidString)")
        let env = ["SHOWORK_ASKS_DIR": "asks", "SHOWORK_PREAPPROVAL_LOG": "pre.json", "SHOWORK_CAPTAIN_INBOX": "in", "SHOWORK_TYPED_MARKS": "m", "SHOWORK_RELEASE_LOG": "rel"]
        for (k, v) in env { setenv(k, d.appendingPathComponent(v).path, 1) }
        setenv("SHOWORK_CLAUDE_DIR", d.path, 1)                       // 沒有任何 session：訊息送不到真的人
        defer { for k in env.keys { unsetenv(k) }; unsetenv("SHOWORK_CLAUDE_DIR"); SphereEmbed.typeAnswer = nil; BoardActions.testDeliver = nil; BoardActions.testHook = nil; try? FileManager.default.removeItem(at: d) }
        var sent: [String] = [], typed = 0
        BoardActions.testDeliver = { sent.append($0); return true }
        BoardActions.testHook = true
        let q = PendingAsk(id: "Q1", ask: "部署嗎", options: ["好，現在部署", "不要"], at: Date()), p = AnswerPick(askId: "Q1", option: "好，現在部署")
        var c = card(0); c.asks = [q]; c.sessionId = "test-once"
        func press(_ x: AnswerPick?) -> String { BoardActions.answer(c, pick: x, source: .user) { _ in } }
        func pre() -> Int { ((try? String(contentsOf: CaptainInbox.preapprovalLog, encoding: .utf8)) ?? "").components(separatedBy: "\"answer\"").count - 1 }
        // 第一次打進去了，第二次拿舊卡再按
        AskQueue.save("test-once", [q])
        SphereEmbed.typeAnswer = { _, _, still, done in if still() { typed += 1; done(.sent) } else { done(.notStarted("x")) }; return true }
        _ = press(p)
        XCTAssertTrue(press(p).contains("已經答過或已收掉，沒有送出"))
        // 終端機已答、選項對不上、沒有 id
        XCTAssertTrue(press(p).contains("沒有送出"))
        AskQueue.save("test-once", [q])
        for x in [AnswerPick(askId: "Q1", option: "rm 全部並部署"), AnswerPick(askId: "Q9", option: "不要")] { XCTAssertTrue(press(x).contains("沒有送出")) }
        XCTAssertTrue(press(nil).contains("沒有送出"))
        XCTAssertEqual([typed, sent.count, max(0, pre())], [1, 0, 0])
        // 寫過字沒確認到：不走訊息，再按也不送
        SphereEmbed.typeAnswer = { _, _, _, done in done(.unsure("x")); return true }
        _ = press(p); XCTAssertTrue(press(p).contains("沒有送出"))
        XCTAssertEqual(sent.count, 0); XCTAssertNotNil(AskQueue.load("test-once").first?.unsureAt)
        // 還沒結果時連按：只有一次在送
        AskQueue.save("test-once", [q]); var later: ((TermAnswer.Outcome) -> Void)?
        SphereEmbed.typeAnswer = { _, _, _, done in later = { done($0) }; return true }
        _ = press(p); XCTAssertTrue(press(p).contains("沒有送出"))
        // 沒寫字：改走訊息一次、講清楚、事先放行只記一筆
        later?(.notStarted("忙"))
        XCTAssertEqual([sent.count, pre()], [1, 1]); XCTAssertTrue(AskQueue.load("test-once").isEmpty)
        XCTAssertTrue(press(p).contains("沒有送出")); XCTAssertEqual([sent.count, pre()], [1, 1])
        AskQueue.save("test-once", [q]); SphereEmbed.typeAnswer = nil
        XCTAssertTrue(press(p).contains("終端機不方便打字，已改用訊息送出"))
        // A4 舊卡的題已答、換成 Q2；A8 沒 id（卡片只有 report.ask）；手機沒帶 id：都不送，Q2 留著
        let n = sent.count, q2 = PendingAsk(id: "Q2", ask: "第二題", options: ["好，現在部署"], at: Date())
        AskQueue.save("test-once", [q2])
        XCTAssertTrue(press(p).contains("沒有送出") && press(nil).contains("沒有送出"))
        XCTAssertTrue(BoardActions.answer(c, pick: AnswerPick(askId: nil, text: "好，現在部署", options: q2.options!), source: .other) { _ in }.contains("沒有送出"))
        XCTAssertEqual(AskQueue.load("test-once").map(\.id), ["Q2"]); XCTAssertEqual(sent.count, n)
        // A5 Mac 在送、手機帶同一題 id 進來：合計一次
        AskQueue.save("test-once", [q])
        SphereEmbed.typeAnswer = { _, _, _, _ in true }
        _ = press(p)
        XCTAssertTrue(BoardActions.answer(c, pick: p, source: .other) { _ in }.contains("沒有送出")); XCTAssertEqual(sent.count, n)
        // A6 排兩題按第一題：走訊息一次、註明哪題、只拿掉第一題
        SphereEmbed.typeAnswer = nil; AskQueue.save("test-once", [q, q2]); c.asks = [q, q2]
        _ = press(p)
        XCTAssertEqual(sent.count, n + 1); XCTAssertTrue(sent.last!.contains("回答的是：部署嗎")); XCTAssertEqual(AskQueue.load("test-once").map(\.id), ["Q2"])
        // A7 訊息也失敗：題目留著、可再按、不留事先放行
        c.asks = [q]; AskQueue.save("test-once", [q]); let before = pre()
        BoardActions.testDeliver = { _ in false }
        XCTAssertFalse(press(p).contains("已改用訊息")); XCTAssertEqual(AskQueue.load("test-once").map(\.id), ["Q1"]); XCTAssertNil(AskQueue.load("test-once")[0].sendingAt); XCTAssertEqual(pre(), before)
        BoardActions.testDeliver = { sent.append($0); return true }
        _ = press(p); XCTAssertEqual(sent.count, n + 2); XCTAssertEqual(pre(), before + 1)
        // 手機：按選項照舊記一筆；有打字（補充、只打字、打「放行」）送得到、題目收掉，但不記事先放行
        func phone(_ x: AnswerPick?) -> String { BoardActions.answer(c, pick: x, source: .other) { _ in } }
        AskQueue.save("test-once", [q]); _ = phone(p); XCTAssertEqual([sent.count, pre()], [n + 3, before + 2])
        for x in [AnswerPick(askId: "Q1", option: "好，現在部署", free: "先別部署"), .init(askId: "Q1", option: nil, free: "好，部署"), .init(askId: "Q1", option: nil, free: "放行 BABCD")] {
            AskQueue.save("test-once", [q]); let k = sent.count
            _ = phone(x); XCTAssertEqual(sent.count, k + 1); XCTAssertTrue(AskQueue.load("test-once").isEmpty); XCTAssertEqual(pre(), before + 2)
            _ = phone(x); XCTAssertEqual(sent.count, k + 1)
        }
        XCTAssertTrue(sent.last == "放行 BABCD")
        AskQueue.save("test-once", [q]); BoardActions.testDeliver = { _ in false }
        _ = phone(.init(askId: "Q1", option: nil, free: "x")); XCTAssertEqual(AskQueue.load("test-once").map(\.id), ["Q1"])
        XCTAssertTrue(press(nil).contains("不在待答清單"))
    }
    /// 舊的 showork（不認得 caps）、不存在的：不打字
    func testOldHookMeansNoTyping() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("caps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        func exe(_ body: String) throws -> String {
            let f = d.appendingPathComponent(UUID().uuidString); try ("#!/bin/sh\n" + body + "\n").write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path); return f.path
        }
        XCTAssertTrue(BoardActions.hookKnowsMark(try exe("echo typed-mark")))
        XCTAssertFalse(BoardActions.hookKnowsMark(try exe("echo usage typed-mark >&2")))
        XCTAssertFalse(BoardActions.hookKnowsMark(d.path + "/none"))
    }
    /// 會標成 user 的呼叫處只有這幾個介面；新增的要先過這裡
    func testCallers() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Engine/Sources")
        var hits: [String] = []
        for f in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)! {
            guard let u = f as? URL, u.pathExtension == "swift" else { continue }
            let n = try String(contentsOf: u, encoding: .utf8).components(separatedBy: "source: .user").count - 1
            if n > 0 { hits.append("\(u.lastPathComponent) \(n)") }
        }
        XCTAssertEqual(hits.sorted(), ["OfficeView.swift 2", "OfficeWebHost.swift 1", "SphereWebScene.swift 1"])
    }
}
