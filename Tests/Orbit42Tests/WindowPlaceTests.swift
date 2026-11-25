import AppKit
import XCTest
@testable import ShoWorkApp

/// 視窗位置：只測計算與存取，不開視窗、不碰正式設定
final class WindowPlaceTests: XCTestCase {
    let main = NSRect(x: 0, y: 0, width: 1920, height: 1080), left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
    let vMain = NSRect(x: 0, y: 0, width: 1920, height: 1050), vLeft = NSRect(x: -1920, y: 0, width: 1920, height: 1050)

    func testRoundTripAndScreenSets() {
        let name = "place-\(UUID().uuidString)", ud = UserDefaults(suiteName: name)!
        defer { ud.removePersistentDomain(forName: name) }
        XCTAssertNil(WindowPlace.load(ud, screens: [main, left], visible: [vMain, vLeft]))
        WindowPlace.save(vLeft, ud, screens: [main, left])
        let alone = NSRect(x: 240, y: 112, width: 1440, height: 900)
        WindowPlace.save(alone, ud, screens: [main])                                                        // 電視關掉時另存
        XCTAssertEqual(WindowPlace.load(ud, screens: [left, main], visible: [vLeft, vMain]), vLeft)          // 螢幕順序不影響
        XCTAssertEqual(WindowPlace.load(ud, screens: [main], visible: [vMain]), alone)
        ud.set("壞掉", forKey: WindowPlace.key([main]))
        XCTAssertNil(WindowPlace.load(ud, screens: [main], visible: [vMain]))
    }
    func testFit() {
        XCTAssertEqual(WindowPlace.fit(NSRect(x: -100, y: -50, width: 800, height: 600), visible: [vMain, vLeft]), NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(WindowPlace.fit(NSRect(x: 0, y: 0, width: 3000, height: 2000), visible: [vMain]), vMain)
        XCTAssertNil(WindowPlace.fit(NSRect(x: 9000, y: 0, width: 800, height: 600), visible: [vMain, vLeft]))
        XCTAssertNil(WindowPlace.fit(NSRect(x: 0, y: 0, width: 10, height: 10), visible: [vMain]))
        XCTAssertNil(WindowPlace.fit(NSRect(x: 0, y: 0, width: 800, height: 600), visible: []))
    }
}
