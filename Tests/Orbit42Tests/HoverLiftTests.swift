import XCTest
@testable import ShoWorkApp

final class HoverLiftTests: XCTestCase {
    func run(_ h: inout HoverLift, _ xs: [(Double, String?)], inside: Bool = true, paused: Bool = false) -> [String?] {
        xs.map { h.step($0.0, hover: $0.1, inside: inside, paused: paused); return h.lifted }
    }
    func testDwellAndSweep() {
        var h = HoverLift()
        XCTAssertEqual(run(&h, [(0, "a"), (0.1, "a"), (0.14, "a"), (0.15, "a")]), [nil, nil, nil, "a"])
        h = HoverLift()      // 快速掃過 7 顆：一顆都不跳
        XCTAssertTrue(run(&h, (0..<7).map { (Double($0) * 0.08, "w\($0)") }).allSatisfy { $0 == nil })
        h = HoverLift()      // 浮起後掃過別顆不到 0.15 秒又回來：不換
        XCTAssertEqual(run(&h, [(0, "a"), (0.2, "a"), (0.3, "b"), (0.4, "b"), (0.42, "a"), (0.6, "a")]), [nil, "a", "a", "a", "a", "a"])
        XCTAssertEqual(run(&h, [(1.0, "b"), (1.16, "b")]), ["a", "b"])       // 停夠久才換，中間不會先歸位（不閃）
    }
    func testLeaveHasGrace() {
        var h = HoverLift()
        XCTAssertEqual(run(&h, [(0, "a"), (0.2, "a"), (0.3, nil), (0.45, nil), (0.48, "a"), (1, nil), (1.1, nil), (1.21, nil)]), [nil, "a", "a", "a", "a", "a", "a", nil])
        XCTAssertNil(h.due(2))                                                // 沒事就不再排檢查
        h.step(3, hover: "a", inside: true, paused: false); XCTAssertEqual(h.due(3)!, 0.15, accuracy: 0.001)
    }
    func testOutsideOrBlurRestoresNow() {
        var h = HoverLift(); _ = run(&h, [(0, "a"), (0.2, "a")])
        h.step(0.21, hover: "a", inside: false, paused: false); XCTAssertNil(h.lifted)
        _ = run(&h, [(1, "a"), (1.2, "a")]); h.step(1.3, hover: "a", inside: false, paused: true); XCTAssertNil(h.lifted)      // 暫停中失焦也歸位
    }
    func testPausedFreezes() {
        var h = HoverLift()
        XCTAssertEqual(run(&h, [(0, "a"), (0.5, "a"), (2, "a")], paused: true), [nil, nil, nil])                               // 拖曳中不浮
        XCTAssertEqual(run(&h, [(2.1, "a"), (2.2, "a"), (2.26, "a")]), [nil, nil, "a"])                                        // 放開後重新計時
        XCTAssertEqual(run(&h, [(3, "b"), (5, nil), (9, nil)], paused: true), ["a", "a", "a"])                                 // 拖曳中也不歸位
        XCTAssertEqual(run(&h, [(9.1, nil), (9.2, nil), (9.31, nil)]), ["a", "a", nil])
    }
    func testTypingSettles() {
        var h = HoverLift(); _ = run(&h, [(0, "b"), (0.2, "b")]); XCTAssertEqual(h.lifted, "b")
        h.settle(hover: "b")                                                  // 在 a 打字，滑鼠還停在 b：b 收回去、不再自己浮起
        XCTAssertEqual(run(&h, [(0.3, "b"), (1, "b"), (5, "b")]), [nil, nil, nil])
        XCTAssertEqual(run(&h, [(5.1, "c"), (5.2, "b"), (5.36, "b")]), [nil, nil, "b"])      // 滑鼠移到別處再回來才算
        h.drop("b"); XCTAssertNil(h.lifted)
    }
    let ws = [SatStack.Win(id: "s", seq: 1, secretary: true), .init(id: "c", seq: 4), .init(id: "a", seq: 2), .init(id: "b", seq: 3)]
    func testOrder() {
        XCTAssertEqual(SatStack.order(ws, pinned: nil, lifted: nil), ["a", "b", "c", "s"])       // 照打開先後，秘書最上
        XCTAssertEqual(SatStack.slots(ws), ["a", "b", "c", "s"])
        XCTAssertEqual(SatStack.order(ws, pinned: "a", lifted: nil), ["b", "c", "s", "a"])
        XCTAssertEqual(SatStack.order(ws, pinned: "a", lifted: "b"), ["c", "s", "a", "b"])
        XCTAssertEqual(SatStack.order(ws, pinned: "a", lifted: "a"), ["b", "c", "s", "a"])
        XCTAssertEqual(SatStack.order(ws, pinned: "gone", lifted: "gone"), ["a", "b", "c", "s"])
    }
    /// 重疊處以看得到的那顆為準：浮起後同一點還是它 ⇒ 不會來回跳
    func testOverlapStable() {
        let fr = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "s"].enumerated().map { ($1, CGRect(x: $0 * 60, y: 300 - $0 * 60, width: 400, height: 300)) })
        let p = CGPoint(x: 30, y: 590), over = CGPoint(x: 250, y: 310)
        XCTAssertEqual(SatStack.hit(p, order: SatStack.order(ws, pinned: nil, lifted: nil), frames: fr), "a")
        XCTAssertEqual(SatStack.hit(over, order: SatStack.order(ws, pinned: nil, lifted: nil), frames: fr), "s")
        XCTAssertEqual(SatStack.hit(over, order: SatStack.order(ws, pinned: nil, lifted: "a"), frames: fr), "a")
        XCTAssertNil(SatStack.hit(CGPoint(x: 5000, y: 0), order: ["a"], frames: fr))
        var h = HoverLift(), seen: [String?] = [], t = 0.0
        for _ in 0..<200 {                                                    // 滑鼠停在重疊處 10 秒：只會有一顆
            let o = SatStack.order(ws, pinned: nil, lifted: h.lifted)
            h.step(t, hover: SatStack.hit(over, order: o, frames: fr), inside: true, paused: false); seen.append(h.lifted); t += 0.05
        }
        XCTAssertEqual(Set(seen.compactMap { $0 }), ["s"])
    }
    func testDim() {
        let o = ["a", "b", "c", "s"]
        XCTAssertEqual(SatStack.dimmed(o, lifted: nil, typing: "a"), [])
        XCTAssertEqual(SatStack.dimmed(o, lifted: "b", typing: "a"), ["c", "s"])                // 正在打字的不變暗
        XCTAssertEqual(SatStack.dimmed(o, lifted: "b", typing: "b"), ["a", "c", "s"])
    }
}
