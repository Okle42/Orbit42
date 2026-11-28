import XCTest
@testable import Orbit42

/// 11-28 Keng「桌面 Chrome 關掉後點圖示沒反應」＋「網頁重開沒開回來查不到原因」
final class ChromeClickGuardTests: XCTestCase {
    typealias G = ChromeClickGuard
    private func needs(pid: pid_t = 700, bundle: String? = "com.google.Chrome", headless: pid_t = 500, login: pid_t? = 600,
                       windows: Int = 0, since: TimeInterval = 3, helped: Bool = false) -> Bool {
        G.needsWindow(pid: pid, bundle: bundle, headless: headless, login: login, windows: windows, sinceLaunch: since, alreadyHelped: helped)
    }

    func testDesktopChromeWithoutWindowGetsOne() {
        XCTAssertTrue(needs())                        // 20:25 實測的情況：剛啟動、沒有一般視窗
        XCTAssertTrue(needs(since: 6))
    }
    func testDesktopChromeWithWindowLeftAlone() {
        XCTAssertFalse(needs(windows: 1))
    }
    func testOnlyOncePerLaunchAndOnlySoonAfterLaunch() {
        XCTAssertFalse(needs(helped: true))           // 幫過一次就不再開（Keng 自己關掉視窗不會一直跳回來）
        XCTAssertFalse(needs(since: 30))              // 開很久了：Keng 自己把視窗全關掉，不是這個問題
    }
    func testHeadlessAndLoginChromeIgnored() {
        XCTAssertFalse(needs(pid: 500))               // 衛星背後的無頭 Chrome
        XCTAssertFalse(needs(pid: 600))               // 登入用的 Chrome（另外由紅叉清理處理）
    }
    func testOtherAppsIgnored() {
        XCTAssertFalse(needs(bundle: "com.apple.Safari"))
        XCTAssertFalse(needs(pid: 0, headless: 0, login: nil))
    }
    func testNewWindowForwardUsesKengsDefaultProfile() {
        // 不可帶 --user-data-dir：帶了就會交給衛星設定檔的 Chrome，而不是 Keng 平常的
        XCTAssertEqual(G.newWindowArgs, ["--new-window"])
        XCTAssertFalse(G.newWindowArgs.contains { $0.hasPrefix("--user-data-dir") })
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
