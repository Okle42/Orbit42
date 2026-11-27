import XCTest
@testable import Orbit42App

final class HoverLiftTests: XCTestCase {
    /// 每一步回傳「要換過去的那顆」（nil＝不動）
    func run(_ h: inout HoverLift, _ xs: [String?], inside: Bool = true, paused: Bool = false) -> [String?] {
        xs.map { h.step(hover: $0, inside: inside, paused: paused) }
    }
    /// 11-28：滑進去那一下就浮起＋聚焦，不用等、不用點
    func testEnterLiftsAndFocusesAtOnce() {
        var h = HoverLift()
        XCTAssertEqual(run(&h, ["a"]), ["a"]); XCTAssertEqual(h.lifted, "a")
        XCTAssertEqual(run(&h, ["a", "a"]), [nil, nil])                       // 停在同一顆：不重複聚焦
        h = HoverLift()                                                         // 快速掃過 7 顆：每顆都立刻換（不再等 0.15 秒）
        XCTAssertEqual(run(&h, (0..<7).map { "w\($0)" }), (0..<7).map { "w\($0)" }); XCTAssertEqual(h.lifted, "w6")
    }
    /// 離開所有衛星（球體、空白、答案卡）：輸入點留在最後那顆
    func testLeaveKeepsLast() {
        var h = HoverLift()
        XCTAssertEqual(run(&h, ["a", nil, nil, "a"]), ["a", nil, nil, nil]); XCTAssertEqual(h.lifted, "a")
        h.step(hover: "b", inside: false, paused: false); XCTAssertEqual(h.lifted, "a")      // 視窗失焦：不搶、不掉
        XCTAssertEqual(run(&h, [nil, "b"]), [nil, "b"])
    }
    /// 拖曳中、選單開著、輸入法組字中（paused）：不換；結束後滑鼠還在別顆上才補換
    func testPausedDoesNotSwitch() {
        var h = HoverLift(); _ = run(&h, ["a"])
        XCTAssertEqual(run(&h, ["b", "c", nil], paused: true), [nil, nil, nil]); XCTAssertEqual(h.lifted, "a")   // 組字／拖曳中：輸入點留在 a
        XCTAssertEqual(run(&h, ["c"]), ["c"])                                   // 放開／組完字：馬上換到滑鼠底下那顆
    }
    func testComposingKeepsFocus() {
        var h = HoverLift(); _ = run(&h, ["a"])
        for x in ["b", "b", "c", nil, "b"] { XCTAssertNil(h.step(hover: x, inside: true, paused: true)) }
        XCTAssertEqual(h.lifted, "a")
    }
    func testDragKeepsFocus() {
        var h = HoverLift(); _ = run(&h, ["a"])
        XCTAssertEqual(run(&h, ["a", "b", "b"], paused: true), [nil, nil, nil]); XCTAssertEqual(h.lifted, "a")
    }
    /// 輸入點被別的方式換走（開新衛星、在別顆打字）時滑鼠停在 b：沒移出 b 前不搶回去；點擊的那顆不受影響
    func testSettle() {
        var h = HoverLift(); _ = run(&h, ["b"])
        h.settle("a", hover: "b"); XCTAssertEqual(h.lifted, "a")
        XCTAssertEqual(run(&h, ["b", "b"]), [nil, nil])
        XCTAssertEqual(run(&h, [nil, "b"]), [nil, "b"])                         // 移出去再回來才換
        h.settle("c", hover: "c"); XCTAssertEqual(run(&h, ["c", "d"]), [nil, "d"])          // 點了 c：滑到 d 照樣立刻換
        h.drop("d"); XCTAssertNil(h.lifted)
    }
    /// 選到的那顆浮起放大：要在最上面、開著、而且不只一顆
    func testRaised() {
        XCTAssertEqual(SatStack.raised(pinned: "b", shown: ["a", "b", "c"]), "b")
        XCTAssertNil(SatStack.raised(pinned: "b", shown: ["b"]))                 // 只有一顆：不放大
        XCTAssertNil(SatStack.raised(pinned: "x", shown: ["a", "b"]))            // 收起來的不算
        XCTAssertNil(SatStack.raised(pinned: nil, shown: ["a", "b"]))
        XCTAssertEqual(SatStack.order(ws, pinned: "b", lifted: nil), ["a", "c", "s", "b"])      // 其他顆照排列順序疊，不跟著動
    }
    /// 平常縮小一點（74%／82%）留空間給放大 3%；每顆都還露出完整標題列＋一點，越多顆越小
    func testArrangeSize() {
        let area = CGSize(width: 760, height: 640), bar: CGFloat = 34
        let (w3, h3) = SatStack.size(count: 3, area: area, bar: bar)
        XCTAssertEqual(w3, 562.4, accuracy: 0.5); XCTAssertEqual(h3, 524.8, accuracy: 0.5)
        XCTAssertGreaterThan(w3, area.width * 0.62); XCTAssertGreaterThan(h3, area.height * 0.78)     // 比 11-23 的 62%×78% 大
        for n in 2...8 {
            let (w, h) = SatStack.size(count: n, area: area, bar: bar), k = CGFloat(n - 1)
            XCTAssertGreaterThanOrEqual((area.height - h) / k, bar + 4 - 1e-6, "\(n) 顆：標題列要露出")
            XCTAssertGreaterThanOrEqual((area.width - w) / k, 44 - 1e-6, "\(n) 顆：左邊要露出一條")
            XCTAssertLessThanOrEqual(w, area.width * 0.74 + 1e-6); XCTAssertLessThanOrEqual(h, area.height * 0.82 + 1e-6)
        }
        XCTAssertEqual(SatStack.size(count: 1, area: area, bar: bar).0, 760)
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
        var h = HoverLift(), seen: [String?] = []
        for _ in 0..<200 {                                                    // 滑鼠停在重疊處：只會換一次、不會兩顆來回跳
            let o = SatStack.order(ws, pinned: h.lifted, lifted: nil)
            seen.append(h.step(hover: SatStack.hit(over, order: o, frames: fr), inside: true, paused: false))
        }
        XCTAssertEqual(seen.compactMap { $0 }, ["s"])
        _ = h.step(hover: "a", inside: true, paused: false)                    // 滑到 a 露出的地方：a 浮起後，同一點還是 a
        let o = SatStack.order(ws, pinned: h.lifted, lifted: nil)
        XCTAssertEqual(SatStack.hit(over, order: o, frames: fr), "a")
    }
    func testDim() {
        let o = ["a", "b", "c", "s"]
        XCTAssertEqual(SatStack.dimmed(o, lifted: nil, typing: "a"), [])
        XCTAssertEqual(SatStack.dimmed(o, lifted: "b", typing: "a"), ["c", "s"])                // 正在打字的不變暗
        XCTAssertEqual(SatStack.dimmed(o, lifted: "b", typing: "b"), ["a", "c", "s"])
    }
}
