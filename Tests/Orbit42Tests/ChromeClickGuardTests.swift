import XCTest
@testable import Orbit42

/// 11-28 Keng「桌面 Chrome 關掉後點圖示沒反應」（只留紀錄、不補開）＋「網頁重開沒開回來查不到原因」
final class ChromeClickGuardTests: XCTestCase {
    typealias G = ChromeClickGuard

    func testNoAutoReopen() {
        // Keng 11-28「未來也不用補檢查或者是再開什麼」：補開視窗的判斷／轉送參數都不能再出現，只剩觀察時間點
        XCTAssertEqual(G.observeDelays, [1.5, 6.0])
    }
    func testIdleLoginNeedsGraceAndStreak() {
        XCTAssertFalse(G.shouldQuitIdleLogin(noWindowStreak: 5, sinceLaunch: 3))     // 剛開、視窗還沒出來
        XCTAssertFalse(G.shouldQuitIdleLogin(noWindowStreak: 1, sinceLaunch: 20))    // 只看到一次沒視窗
        XCTAssertTrue(G.shouldQuitIdleLogin(noWindowStreak: 2, sinceLaunch: 20))
    }
    func testWindowCountOfNoSuchProcessIsZero() {
        XCTAssertEqual(G.windowCount(999_999), 0)
    }
    func testArgumentsOfChildProcess() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 5; true", "x", "--no-startup-window"]     // sh 會活 5 秒，後面兩個只是帶著的參數
        try p.run(); defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(G.arguments(p.processIdentifier), ["-c", "sleep 5; true", "x", "--no-startup-window"])
        XCTAssertEqual(G.arguments(999_999), [])
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
