import XCTest

/// Web/vendor 和 Board/Web/vendor 是兩份（Mac、iPhone、Windows 各自打包），內容一定要一樣
final class VendorTests: XCTestCase {
    func testSame() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let a = top.appendingPathComponent("Web/vendor"), b = top.appendingPathComponent("Engine/windows/ShoWork.Win/Board/Web/vendor")
        var n = 0
        for case let u as URL in FileManager.default.enumerator(at: a, includingPropertiesForKeys: [.isRegularFileKey])! where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = u.path.dropFirst(a.path.count)
            XCTAssertEqual(try Data(contentsOf: u), try? Data(contentsOf: URL(fileURLWithPath: b.path + rel)), "\(rel) 兩份不一樣"); n += 1
        }
        XCTAssertGreaterThan(n, 8)
    }
}
