import XCTest
@testable import Orbit42

/// 11-28 Keng「桌面 Chrome 關掉後點圖示沒反應」＋「網頁重開沒開回來查不到原因」
final class ChromeClickGuardTests: XCTestCase {
    typealias G = ChromeClickGuard

    func testHeadlessActivatedOpensDesktop() {
        XCTAssertEqual(G.decide(activated: 500, bundle: "com.google.Chrome", headless: 500, login: nil, windows: 0), .openDesktop)
    }
    func testIdleLoginActivatedOpensDesktopAndQuitsLogin() {
        XCTAssertEqual(G.decide(activated: 600, bundle: "com.google.Chrome", headless: 500, login: 600, windows: 0), .openDesktopAndQuitLogin)
    }
    func testLoginWithWindowLeftAlone() {
        // 登入視窗還開著（Keng 正在登）⇒ 不動
        XCTAssertEqual(G.decide(activated: 600, bundle: "com.google.Chrome", headless: 500, login: 600, windows: 1), .none)
    }
    func testKengsOwnChromeLeftAlone() {
        XCTAssertEqual(G.decide(activated: 700, bundle: "com.google.Chrome", headless: 500, login: 600, windows: 0), .none)
        XCTAssertEqual(G.decide(activated: 700, bundle: "com.google.Chrome", headless: 0, login: nil, windows: 3), .none)
    }
    func testOtherAppsIgnored() {
        XCTAssertEqual(G.decide(activated: 500, bundle: "com.apple.Safari", headless: 500, login: nil, windows: 0), .none)
        XCTAssertEqual(G.decide(activated: 0, bundle: "com.google.Chrome", headless: 0, login: nil, windows: 0), .none)   // 無頭沒在跑（pid 0）
    }
    func testIdleLoginNeedsGraceAndStreak() {
        XCTAssertFalse(G.shouldQuitIdleLogin(noWindowStreak: 5, sinceLaunch: 3))     // 剛開、視窗還沒出來
        XCTAssertFalse(G.shouldQuitIdleLogin(noWindowStreak: 1, sinceLaunch: 20))    // 只看到一次沒視窗
        XCTAssertTrue(G.shouldQuitIdleLogin(noWindowStreak: 2, sinceLaunch: 20))
    }
    func testWindowCountOfNoSuchProcessIsZero() {
        XCTAssertEqual(G.windowCount(999_999), 0)
    }

    func testRestoreLogWritesToOverrideDir() throws {
        let dir = NSTemporaryDirectory() + "orbit-log-\(UUID().uuidString)"
        setenv("ORBIT_LOG_DIR", dir, 1); defer { unsetenv("ORBIT_LOG_DIR") }
        OrbitLog.restore("網頁 s1：排定開回 https://example.com/ 展開=true")
        OrbitLog.restore("網頁 s1：成功")
        let text = try String(contentsOfFile: dir + "/restore.log", encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("網頁 s1：排定開回 https://example.com/ 展開=true"))
        XCTAssertNotNil(lines[1].range(of: #"^\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} 網頁 s1：成功$"#, options: .regularExpression))
    }
}
