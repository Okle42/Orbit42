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
