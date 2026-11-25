import XCTest
@testable import Orbit42

@MainActor final class DropCopyTests: XCTestCase {
    func testTemporaryScreenshotIsCopied() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("TemporaryItems/dropcopy-\(UUID().uuidString)")
        let out = fm.temporaryDirectory.appendingPathComponent("drops-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root); try? fm.removeItem(at: out) }
        let src = root.appendingPathComponent("截圖 2026-11-25 下午6.23.54.png"); try Data([1, 2, 3]).write(to: src)
        XCTAssertTrue(DropCopy.isTemporary(src))
        let a = DropCopy.readable(src, into: out), b = DropCopy.readable(src, into: out)
        XCTAssertTrue(a.path.hasPrefix(out.path)); XCTAssertFalse(a.path.contains(" ")); XCTAssertEqual(a.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: a), Data([1, 2, 3])); XCTAssertNotEqual(a, b)               // 同一秒拖兩次不互蓋
        XCTAssertEqual(TermWindowView.shellEscape(a.lastPathComponent), a.lastPathComponent)             // 貼進終端機不用跳脫
        XCTAssertTrue(fm.fileExists(atPath: src.path))                                                   // 原檔不動
        XCTAssertEqual((try fm.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int), 0o700)
        XCTAssertEqual(DropCopy.readable(root, into: out), root)                                         // 資料夾、不存在的檔：照舊
        let gone = root.appendingPathComponent("no.png"); XCTAssertEqual(DropCopy.readable(gone, into: out), gone)
        XCTAssertEqual(DropCopy.readable(src, into: URL(fileURLWithPath: "/dev/null/x")), src)           // 複製失敗：照舊
    }
    func testOrdinaryFilesKeepTheirPath() {
        for p in ["/Users/x/Desktop/a.png", "/Users/x/TemporaryItems/a.png", "/var/folders/zz/T/a.png", "/Volumes/SD/TemporaryItems/a.png"] {
            let u = URL(fileURLWithPath: p); XCTAssertFalse(DropCopy.isTemporary(u)); XCTAssertEqual(DropCopy.readable(u), u)
        }
    }
}
