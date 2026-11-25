import XCTest
@testable import ShoWorkApp

/// 審核員（Tools.run 帶 stdin）：對方沒讀完就結束，不可以讓整個 App 被 SIGPIPE 或例外結束
final class ToolsStdinTests: XCTestCase {
    func testChildExitsWithoutReading() {
        let big = String(repeating: "x", count: 4_000_000)
        for _ in 0..<20 { let r = Tools.run("/bin/echo", ["{\"verdict\":\"ok\"}"], stdin: big, timeout: 10); XCTAssertNotEqual(r.code, 0); XCTAssertEqual(r.out, "") }      // 沒讀完題目的輸出不能當結論
    }
    func testNormal() {
        XCTAssertEqual(Tools.run("/bin/cat", [], stdin: "你好", timeout: 10).out, "你好")
    }
}
