import XCTest
@testable import Orbit42

/// 11-28 Keng：線本來就只有 USB 2.0，每次啟動都講「跑在 USB 2.0」是誤報 ⇒ 只有比上次慢才講，上次速度存檔、重開也記得
@MainActor final class DiskWatchTests: XCTestCase {
    func testOnlySlowerThanLastTimeIsReported() {
        XCTAssertTrue(DiskWatch.slower(480_000_000, than: 10_000_000_000))      // 10Gb/s 掉到 480Mb/s：講
        XCTAssertFalse(DiskWatch.slower(480_000_000, than: 480_000_000))        // 一樣慢（爛線本來就這樣）：不講
        XCTAssertFalse(DiskWatch.slower(480_000_000, than: nil))                // 第一次看到這顆：沒得比，不講
        XCTAssertFalse(DiskWatch.slower(10_000_000_000, than: 480_000_000))     // 變快：不講
        XCTAssertFalse(DiskWatch.slower(nil, than: 10_000_000_000))             // 量不到（不是 USB）：不講
        XCTAssertFalse(DiskWatch.slower(0, than: 10_000_000_000))
    }
    func testSpeedsSurviveRestart() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("disk-speeds-\(UUID().uuidString)/s.json")
        defer { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
        XCTAssertEqual(DiskWatch.loadSpeeds(u), [:])
        DiskWatch.saveSpeeds(["HDD1T": 480_000_000, "SSD": 10_000_000_000], u)
        XCTAssertEqual(DiskWatch.loadSpeeds(u), ["HDD1T": 480_000_000, "SSD": 10_000_000_000])
    }
}
