import Foundation
import Testing
@testable import Orbit42Core

/// 11-26 改名（第一階段 F）相容：新舊 from-name、新舊路徑、新舊 token 標頭、舊環境變數、舊設定 suite、搬家
@Suite("改名相容（Legacy）")
struct LegacyTests {
    @Test("新舊 from-name 都算使用者本人")
    func fromName() {
        for n in ["Orbit42（使用者）", "Orbit42（使用者已答）", "AI工作戰情中心（使用者）", "AI工作戰情中心（使用者已答）"] {
            #expect(Handover.isUserPrompt("<cross-session-message from=\"x\" from-name=\"\(n)\">好</cross-session-message>"), "\(n)")
        }
        for n in ["Orbit42（巡檢）", "AI工作戰情中心（巡檢）", "Penny"] {
            #expect(!Handover.isUserPrompt("<cross-session-message from=\"x\" from-name=\"\(n)\">好</cross-session-message>"), "\(n)")
        }
        #expect(CaptainThread.boardFromName == "Orbit42（使用者）")
        #expect(CaptainThread.legacyBoardFromName == "AI工作戰情中心（使用者）")
    }

    @Test("新舊 token 標頭都收")
    func tokenHeader() {
        #expect(WebRouter.headerToken(["x-orbit-token": "a"]) == "a")
        #expect(WebRouter.headerToken(["x-showork-token": "b"]) == "b")
        #expect(WebRouter.headerToken(["x-orbit-token": "a", "x-showork-token": "b"]) == "a")
        #expect(WebRouter.headerToken([:]) == nil)
        guard case .ok(let r) = WebRequest.parse(Data("GET /api/board HTTP/1.1\r\nX-ShoWork-Token: old\r\n\r\n".utf8)) else { Issue.record("parse"); return }
        #expect(WebRouter.headerToken(r.headers) == "old")
    }

    @Test("新舊指令路徑都認得是自己（防冒充、內部指令判斷不變）")
    func cliNames() {
        for c in ["orbit card", "\"/Users/x/Library/Application Support/Orbit42/bin/orbit\" card", "showork card",
                  "\"/Users/x/Library/Application Support/ShoWork42/bin/showork\" release B1"] {
            #expect(CaptainLink.isOrbit(c), "\(c)")
        }
        #expect(!CaptainLink.isOrbit("orbit3d x.stl")); #expect(!CaptainLink.isOrbit("echo orbit"))
    }

    @Test("舊環境變數 SHOWORK_X 照讀成 ORBIT_X；新名已設就不蓋")
    func env() {
        setenv("SHOWORK_TEST_LEGACY_A", "1", 1); setenv("SHOWORK_TEST_LEGACY_B", "old", 1); setenv("ORBIT_TEST_LEGACY_B", "new", 1)
        defer { for k in ["SHOWORK_TEST_LEGACY_A", "SHOWORK_TEST_LEGACY_B", "ORBIT_TEST_LEGACY_A", "ORBIT_TEST_LEGACY_B"] { unsetenv(k) } }
        Legacy.adoptEnv()
        #expect(ProcessInfo.processInfo.environment["ORBIT_TEST_LEGACY_A"] == "1")
        #expect(ProcessInfo.processInfo.environment["ORBIT_TEST_LEGACY_B"] == "new")
    }

    @Test("舊設定 suite 一次性複製：新的已有不蓋、讀回比對、做過不再做")
    func defaults() throws {
        let on = "orbit.test.old.\(UUID().uuidString)", nn = "orbit.test.new.\(UUID().uuidString)"
        let old = try #require(UserDefaults(suiteName: on)), new = try #require(UserDefaults(suiteName: nn))
        defer { old.removePersistentDomain(forName: on); new.removePersistentDomain(forName: nn) }
        old.set(400_000, forKey: "board.ctxTokens"); old.set(false, forKey: "board.review"); old.set("x", forKey: "keep")
        new.set("mine", forKey: "keep")
        let c = Legacy.migrateDefaults(from: old, to: new, oldName: on)
        #expect(c == ["board.ctxTokens", "board.review"])
        #expect(new.integer(forKey: "board.ctxTokens") == 400_000 && new.object(forKey: "board.review") as? Bool == false && new.string(forKey: "keep") == "mine")
        #expect(new.object(forKey: "migrated.fromLegacy") != nil)
        old.set(1, forKey: "later")
        #expect(Legacy.migrateDefaults(from: old, to: new, oldName: on).isEmpty, "做過不再做")
        #expect(AppPrefs.suite == "ai.okle42.orbit42.engine", "不能跟 App 的 bundle id 同名")
        #expect(Legacy.suite == "ai.okle42.showork")
    }

    @Test("搬家：複製→逐檔比對；新的已有不蓋；bin、socket、舊 App 不搬；舊的不刪")
    func migrate() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("orbit-mig-\(UUID().uuidString.prefix(8))")
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        defer { try? fm.removeItem(at: root) }
        for (p, s) in [("board/history.jsonl", "h1\n"), ("board/asks/a.json", "{}"), ("local.json", "{\"a\":1}"), ("web/token", "t"), ("bin/showork", "x"), ("drops/x.png", "OLD")] {
            let u = old.appendingPathComponent(p); try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(s.utf8).write(to: u)
        }
        try fm.createDirectory(at: new.appendingPathComponent("drops"), withIntermediateDirectories: true)
        try Data("NEW".utf8).write(to: new.appendingPathComponent("drops/x.png"))
        let dry = Legacy.migrate(from: old, to: new, dryRun: true)
        #expect(dry.copied.count == 4 && !fm.fileExists(atPath: new.appendingPathComponent("local.json").path))
        let r = Legacy.migrate(from: old, to: new)
        #expect(Set(r.copied) == ["board/history.jsonl", "board/asks/a.json", "local.json", "web/token"])
        #expect(r.skipped == ["drops/x.png"] && r.mismatched.isEmpty)
        #expect(try String(contentsOf: new.appendingPathComponent("drops/x.png"), encoding: .utf8) == "NEW", "不蓋新的")
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("bin").path), "bin 不搬")
        #expect(fm.fileExists(atPath: old.appendingPathComponent("board/history.jsonl").path), "舊的不刪")
        #expect(Legacy.migrate(from: old, to: new).copied.isEmpty, "再跑一次不重複")
    }

    @Test("舊 socket 位置改成連結指到新 socket")
    func socketLink() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("orbit-sock-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old/agent.sock"), new = root.appendingPathComponent("new/agent.sock")
        #expect(!Legacy.linkSocket(new, old: old), "舊資料夾不在就不做")
        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: old)                                    // 舊 App 留下的
        #expect(Legacy.linkSocket(new, old: old))
        #expect(try fm.destinationOfSymbolicLink(atPath: old.path) == new.path)
        #expect(Legacy.linkSocket(new, old: old), "已經連好")
    }
}
