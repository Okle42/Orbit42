import AppKit
import SceneKit
import XCTest
@testable import Orbit42

/// 11-26 第一階段 D：3D 小視窗邊做邊自動重新整理（覆寫、原子換檔、寫一半、壞檔、刪檔再出現、快速覆寫、視角保留）
@MainActor
final class ModelReloadTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-reload-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ModelView.watchInterval = 0.05; ModelView.watchStable = 0.25
    }
    override func tearDown() async throws { ModelView.watchInterval = 0.25; ModelView.watchStable = 0.5 }

    /// 二進位 STL（n 個三角形）
    static func stl(_ n: Int) -> Data {
        var d = Data(count: 80); var c = UInt32(n).littleEndian; d.append(Data(bytes: &c, count: 4))
        func f(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        for i in 0..<n { let x = Float(i); [0, 0, 1, x, 0, 0, x + 1, 0, 0, x, 1, 0].forEach(f); d.append(Data([0, 0])) }
        return d
    }
    func write(_ s: String, _ u: URL) { try! Data(s.utf8).write(to: u) }
    @nonobjc func write(_ d: Data, _ u: URL) { try! d.write(to: u) }
    func until(_ sec: Double = 5, _ f: @escaping () -> Bool) async { let t = Date(); while !f() && Date().timeIntervalSince(t) < sec { try? await Task.sleep(for: .milliseconds(30)) } }

    func testFileWatchRules() {
        let a = FileWatch.Stamp(size: 10, mtime: 1, inode: 1), b = FileWatch.Stamp(size: 12, mtime: 2, inode: 1), c = FileWatch.Stamp(size: 12, mtime: 2, inode: 9)
        var w = FileWatch(loaded: a, stable: 0.5); let t = Date()
        XCTAssertFalse(w.tick(a, now: t), "沒變不載")
        XCTAssertFalse(w.tick(b, now: t + 0.1), "剛變：等穩定")
        XCTAssertFalse(w.tick(b, now: t + 0.4), "還沒滿 0.5 秒")
        XCTAssertTrue(w.tick(b, now: t + 0.7), "穩定了才載")
        XCTAssertFalse(w.tick(b, now: t + 1.5), "同一份只載一次")
        XCTAssertFalse(w.tick(c, now: t + 2)); XCTAssertTrue(w.tick(c, now: t + 2.6), "原子換檔（inode 變）也要載")
        XCTAssertFalse(w.tick(nil, now: t + 3)); XCTAssertFalse(w.tick(FileWatch.Stamp(size: 0, mtime: 5, inode: 3), now: t + 4), "刪掉／空檔不載")
        var x = FileWatch(loaded: a, stable: 0.5)
        for i in 0..<10 { XCTAssertFalse(x.tick(FileWatch.Stamp(size: UInt64(20 + i), mtime: Double(10 + i), inode: 1), now: t + Double(i) * 0.1), "一直在寫：不載") }
        XCTAssertTrue(x.tick(FileWatch.Stamp(size: 29, mtime: 19, inode: 1), now: t + 1.6), "停手才載最後一份")
    }

    func testAutoReloadKeepsViewAndSurvivesBadFiles() async throws {
        let u = dir.appendingPathComponent("lamp.stl")
        write(Self.stl(1), u)
        let v = ModelView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var loads = 0; v.onLoaded = { if $0 { loads += 1 } }
        v.open(u)
        await until { loads == 1 }
        XCTAssertTrue(v.summaryText.contains("1 面"), v.summaryText)
        let cam = try XCTUnwrap(v.scn.pointOfView)
        cam.camera?.orthographicScale = 3.25; cam.eulerAngles.y = 0.7            // 使用者轉過、縮放過

        // 覆寫
        write(Self.stl(2), u)
        await until { v.reloads == 1 }
        XCTAssertEqual(v.reloads, 1); XCTAssertTrue(v.summaryText.contains("2 面"), v.summaryText)
        XCTAssertTrue(v.scn.pointOfView === cam, "鏡頭換掉了"); XCTAssertEqual(cam.camera?.orthographicScale, 3.25); XCTAssertEqual(cam.eulerAngles.y, 0.7, accuracy: 1e-6)

        // 原子換檔（寫新檔再 rename）
        let tmp = dir.appendingPathComponent(".lamp.tmp"); write(Self.stl(3), tmp)
        _ = try FileManager.default.replaceItemAt(u, withItemAt: tmp)
        await until { v.reloads == 2 }
        XCTAssertTrue(v.summaryText.contains("3 面"), v.summaryText)

        // 寫到一半：一直在長的檔不載，停手才載一次
        let h = try FileHandle(forWritingTo: u); try h.truncate(atOffset: 0)
        let full = Self.stl(4); var off = 0
        while off < full.count { let n = min(40, full.count - off); try h.write(contentsOf: full[off..<off + n]); off += n; try await Task.sleep(for: .milliseconds(60)) }
        XCTAssertEqual(v.reloads, 2, "寫到一半不可載"); try h.close()
        await until { v.reloads == 3 }
        XCTAssertEqual(v.reloads, 3); XCTAssertTrue(v.summaryText.contains("4 面"), v.summaryText)

        // 壞檔：留上一版、不清空
        write("這不是 STL", u)
        await until { v.reloadFailed }
        XCTAssertTrue(v.reloadFailed); XCTAssertTrue(v.summaryText.contains("4 面") && v.summaryText.contains("上一版"), v.summaryText)
        XCTAssertTrue(v.scn.pointOfView === cam); XCTAssertEqual(v.messageText, "", "不可蓋掉畫面")

        // 刪檔再出現
        try FileManager.default.removeItem(at: u)
        try await Task.sleep(for: .milliseconds(500)); XCTAssertEqual(v.reloads, 3)
        write(Self.stl(5), u)
        await until { v.reloads == 4 }
        XCTAssertTrue(v.summaryText.contains("5 面"), v.summaryText); XCTAssertFalse(v.reloadFailed)

        // 連續快速覆寫：只載最後一次
        for n in 6...9 { write(Self.stl(n), u); try await Task.sleep(for: .milliseconds(80)) }
        await until { v.reloads == 5 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(v.reloads, 5, "快速覆寫只載一次"); XCTAssertTrue(v.summaryText.contains("9 面"), v.summaryText)
        XCTAssertTrue(v.scn.pointOfView === cam); XCTAssertEqual(cam.camera?.orthographicScale, 3.25)
        v.cancel()
    }

    /// 11-26 H：檔案下拉選單跟旁邊按鈕同一風格；深淺各截一張（ORBIT_TEST_SHOTS=<資料夾> 時存檔）
    func testFilesPopupStyle() async throws {
        let a = dir.appendingPathComponent("a.stl"), b = dir.appendingPathComponent("b.stl")
        write(Self.stl(1), a); write(Self.stl(2), b)
        for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let v = ModelView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
            v.appearance = NSAppearance(named: ap)
            var loads = 0; v.onLoaded = { if $0 { loads += 1 } }
            v.open(a); await until { loads == 1 }; v.open(b); await until { loads == 2 }
            v.layoutSubtreeIfNeeded()
            let pop = try XCTUnwrap(v.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
            XCTAssertFalse(pop.isHidden); XCTAssertEqual(pop.bezelStyle, .inline); XCTAssertEqual(pop.font?.pointSize, 11)
            XCTAssertEqual(pop.itemTitles, ["a.stl", "b.stl"], "選單內容不變")
            let btn = try XCTUnwrap(v.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.first as? NSButton)
            XCTAssertEqual(pop.fittingSize.height, btn.fittingSize.height, accuracy: 3, "高度跟旁邊按鈕一樣")
            if let out = ProcessInfo.processInfo.environment["ORBIT_TEST_SHOTS"], let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.wantsLayer = true; v.layer?.backgroundColor = (name == "dark" ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor
                v.cacheDisplay(in: v.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("model-files-\(name).png"))
            }
            v.cancel()
        }
    }
}
