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
        XCTAssertEqual(BoardActions.typable(card(), text: "好", source: .user, resolvesAsk: true), "好")
        XCTAssertNil(BoardActions.typable(card(), text: "好", source: .other, resolvesAsk: true))
        XCTAssertNil(BoardActions.typable(card(), text: "好", source: .user, resolvesAsk: false))
        XCTAssertNil(BoardActions.typable(card(2), text: "好", source: .user, resolvesAsk: true))
        XCTAssertNil(BoardActions.typable(card(), text: " 放行 BABCD", source: .user, resolvesAsk: true))
        var board = card(); board.kind = "board"
        XCTAssertNil(BoardActions.typable(board, text: "好", source: .user, resolvesAsk: true))
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
        XCTAssertEqual(hits.sorted(), ["OfficeView.swift 2", "OfficeWebHost.swift 1", "SphereWebScene.swift 1", "WebServer.swift 1"])
    }
}
