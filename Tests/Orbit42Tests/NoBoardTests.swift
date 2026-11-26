import AppKit
import WebKit
import XCTest
@testable import Orbit42App
@testable import Orbit42Core

/// 11-26 第一階段 A＋B：拿掉看板視窗（BoardWindow），操作搬進衛星右鍵選單／＋ 新衛星／設定窗；背景功能照跑
@MainActor
final class NoBoardTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardizedFileURL
    static func src(_ p: String) throws -> String { try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
    static let app = "Engine/Sources/" + (FileManager.default.fileExists(atPath: root.appendingPathComponent("Engine/Sources/Orbit42App").path) ? "Orbit42App" : "Orbit42App")

    /// 看板視窗整檔刪掉、入口全拔
    func testBoardWindowGone() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(Self.app + "/BoardWindow.swift").path))
        let main = try Self.src(Self.app + "/AgentMain.swift"), menu = try Self.src(Self.app + "/Arranger.swift")
        XCTAssertFalse(main.contains("--board-window"), "測試模式 --board-window 要拿掉")
        XCTAssertFalse(main.contains("showBoard"), "showBoard 通知要拿掉")
        XCTAssertFalse(menu.contains("openBoard"), "選單「…Orbit42」要拿掉")
        let html = try Self.src("Engine/windows/" + (FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Engine/windows/Orbit42.Engine.Win").path) ? "Orbit42.Engine.Win" : "Orbit42.Engine.Win") + "/Board/Web/sphere.html")
        XCTAssertFalse(html.contains("bBoard"))
        XCTAssertFalse(html.contains("openBoard"))
    }

    /// 背景功能（巡檢、自動收尾、交接 /clear）不靠視窗：正式 agent 啟動就開 BoardModel，每輪套用都跑這三樣
    func testBackgroundStillStarts() throws {
        let main = try Self.src(Self.app + "/AgentMain.swift"), src = try Self.src(Self.app + "/BoardSource.swift")
        let run = try XCTUnwrap(main.range(of: "let engine = Engine()")), started = try XCTUnwrap(main.range(of: "BoardModel.shared.start()", range: run.upperBound..<main.endIndex))
        XCTAssertNotNil(main.range(of: "app.run()", range: started.upperBound..<main.endIndex), "BoardModel 要在正式 agent 主流程裡啟動")
        let apply = try XCTUnwrap(src.range(of: "private func apply(_ s: BoardReader.Snapshot)"))
        let body = String(src[apply.upperBound...].prefix(4000))
        XCTAssertTrue(body.contains("captainAlarm("), "巡檢（秘書鬧鐘）")
        XCTAssertTrue(body.contains("CtxGuard.shared.check("), "自動收尾")
        XCTAssertTrue(body.contains("HandoverClear.shared.check("), "交接 /clear")
        XCTAssertFalse(src.contains("BoardWindow"), "BoardModel 不可再參照看板視窗")
        // 刷新頻率改看宿主主視窗
        XCTAssertTrue(src.contains("SphereEmbed.hostOnScreen()"))
    }

    /// 衛星右鍵選單：項目、順序、哪些能按
    func testCardMenuItems() {
        var c = BoardCard(id: "s1", column: .review, reason: "", project: "p", title: "做事", lastActivity: Date(), pid: 1, sessionId: "s1")
        XCTAssertEqual(CardMenu.items(c, reviewing: []).map(\.title), ["放行", "派工給它⋯", "退回並補指示⋯", "丟回待辦⋯", "重新審核", "-", "拷貝 Session ID"])
        c.column = .active; c.captain = true
        XCTAssertEqual(CardMenu.items(c, reviewing: []).map(\.title), ["退回並補指示⋯", "丟回待辦⋯", "重新審核", "-", "拷貝 Session ID"], "秘書不派工、沒待審不放行")
        XCTAssertFalse(CardMenu.items(c, reviewing: ["s1"]).first { $0.title == "重新審核" }!.enabled, "審核中不能再審")
        c.lastActivity = nil
        XCTAssertFalse(CardMenu.items(c, reviewing: []).first { $0.title == "重新審核" }!.enabled, "沒動靜不能審")
    }

    /// 測試模式：表單開在螢幕外、放行不送；拷貝 Session ID 照做
    func testCardMenuTestModeOffscreen() {
        AppTest.mode = true; defer { AppTest.mode = false; FormPanel.current?.close() }
        let c = BoardCard(id: "s1", column: .review, reason: "", project: "p", title: "做事", lastActivity: Date(), pid: 1, sessionId: "s1")
        var said: [String] = []
        CardMenu.run("放行", c) { said.append($0) }
        XCTAssertEqual(said, ["測試：不放行「做事」"])
        for t in ["派工給它⋯", "退回並補指示⋯", "丟回待辦⋯"] {
            CardMenu.run(t, c) { said.append($0) }
            let p = try! XCTUnwrap(FormPanel.current)
            let screens = NSScreen.screens.map(\.frame).reduce(NSRect.zero) { $0.union($1) }
            XCTAssertFalse(screens.intersects(p.frame), "\(t) 的表單要在螢幕外：\(p.frame)")
            XCTAssertGreaterThan(p.frame.width, 300); XCTAssertGreaterThan(p.frame.height, 120)
        }
        CardMenu.newTask { said.append($0) }
        XCTAssertEqual(FormPanel.current?.title, "新任務")
    }

    /// 球體網頁：右鍵戰情列那一列 ⇒ cardMenu；＋ 新衛星選單有「新任務⋯」⇒ newTask
    func testSphereContextMenuPosts() async throws {
        final class Rec: NSObject, WKScriptMessageHandler {
            var got: [[String: Any]] = []
            func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { if let d = m.body as? [String: Any] { got.append(d) } }
        }
        let web = Self.root.appendingPathComponent("Engine/windows/" + (FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Engine/windows/Orbit42.Engine.Win").path) ? "Orbit42.Engine.Win" : "Orbit42.Engine.Win") + "/Board/Web")
        let cfg = WKWebViewConfiguration(); cfg.setURLSchemeHandler(WebSchemeHandler(root: web), forURLScheme: WebSchemeHandler.scheme)
        let rec = Rec(); cfg.userContentController.add(rec, name: "sphere")
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: cfg)
        v.load(URLRequest(url: URL(string: "\(WebSchemeHandler.scheme)://web/sphere.html?orbit=1")!))
        func js(_ s: String) async -> String { (try? await v.evaluateJavaScript(s)).map { "\($0)" } ?? "" }
        for _ in 0..<160 { if await js("typeof window.karaUpdate") == "function" { break }; try await Task.sleep(for: .milliseconds(50)) }
        _ = await js("window.karaUpdate({five_hour:1,seven_day:2,sessions:1,runs:[],team:[{name:'甲',status:'待審',sessionId:'s9'}]}),0")
        try await Task.sleep(for: .milliseconds(400))
        let prevented = await js("(()=>{const r=document.querySelector('#teamRows .row');if(!r)return 'norow';const e=new MouseEvent('contextmenu',{bubbles:true,cancelable:true});r.dispatchEvent(e);return String(e.defaultPrevented)})()")
        XCTAssertEqual(prevented, "true", "右鍵要擋掉 WebKit 預設選單")
        _ = await js("document.querySelector('#satMenu [data-brain=task]').click(),0")
        try await Task.sleep(for: .milliseconds(200))
        let acts = rec.got.compactMap { $0["action"] as? String }
        XCTAssertTrue(rec.got.contains { $0["action"] as? String == "cardMenu" && $0["sessionId"] as? String == "s9" }, "\(acts)")
        XCTAssertTrue(acts.contains("newTask"), "\(acts)")
        XCTAssertFalse(acts.contains("newSatellite"), "新任務不是開新衛星")
    }

    /// 保全在設定窗
    func testGuardInSettings() {
        XCTAssertTrue(SettingsTab.allCases.contains(.security))
        XCTAssertEqual(SettingsTab.security.title, "保全")
    }
}

/// 11-26 第一階段 C：使用者已答只清秘書卡片上的同一題，不再 Peer 送訊叫醒秘書
@MainActor
final class AnsweredNoPeerTests: XCTestCase {
    func testTellCaptainDoesNotSend() throws {
        let s = try NoBoardTests.src(NoBoardTests.app + "/BoardActions.swift")
        let a = try XCTUnwrap(s.range(of: "private static func tellCaptain("))
        let rest = s[a.upperBound...], body = String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
        XCTAssertTrue(body.contains("Answered.clearCaptainCard("), "要清秘書卡片上同一題")
        XCTAssertTrue(body.contains("AskQueue.resolve("))
        XCTAssertFalse(body.contains("Peer.send"), "不可再送訊叫醒秘書")
        XCTAssertFalse(s.contains("使用者已答）\")"), "from-name「…（使用者已答）」不再送")
    }
}
