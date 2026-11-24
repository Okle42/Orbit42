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
