import AppKit
import WebKit
import XCTest
@testable import ShoWorkCore
@testable import ShoWorkApp

/// 答案卡浮層：擺位、焦點、題目狀態（視窗不顯示；不送任何字）
@MainActor
final class AskFloatTests: XCTestCase {
    let root = NSSize(width: 1440, height: 900), card = NSSize(width: 440, height: 360)
    func inside(_ f: NSRect, _ r: NSSize) -> Bool { f.minX >= 0 && f.minY >= 0 && f.maxX <= r.width && f.maxY <= r.height }

    func testPlacement() {
        let d = AskFloatLayout.card(card, root: root, corner: nil)
        XCTAssertEqual(d, NSRect(x: 1440 - 14 - 440, y: 14, width: 440, height: 360))                       // 預設右下
        for c in [NSPoint(x: -500, y: -500), NSPoint(x: 5000, y: 5000), NSPoint(x: 0, y: 899)] { XCTAssertTrue(inside(AskFloatLayout.card(card, root: root, corner: c), root)) }
        let c = NSPoint(x: 900, y: 500), small = NSSize(width: 600, height: 420)                             // 視窗變小自動拉回，變大回原位
        XCTAssertTrue(inside(AskFloatLayout.card(card, root: small, corner: c), small))
        XCTAssertEqual(AskFloatLayout.card(card, root: root, corner: c).minX, 100)
        let over = AskFloatLayout.card(NSSize(width: 440, height: 900), root: small, corner: nil)            // 比視窗高：標題列一定看得到
        XCTAssertEqual(over.maxY, small.height)
        XCTAssertTrue(inside(AskFloatLayout.clamp(NSRect(x: -9999, y: 9999, width: 440, height: 360), in: root), root))
    }
    func testStripKeepsOffInputs() {
        let s = NSSize(width: 220, height: 34)
        XCTAssertEqual(AskFloatLayout.strip(s, root: root, corner: nil, terminals: []).minY, 14)
        let terms = (0..<4).map { NSRect(x: 300 + CGFloat($0) * 180, y: 10 + CGFloat($0) * 60, width: 620, height: 480) }
        for n in 1...4 {
            let f = AskFloatLayout.strip(s, root: root, corner: nil, terminals: Array(terms.prefix(n)))
            XCTAssertTrue(inside(f, root))
            for t in terms.prefix(n) { XCTAssertFalse(f.intersects(NSRect(x: t.minX, y: t.minY, width: t.width, height: 96))) }
        }
        XCTAssertTrue(inside(AskFloatLayout.strip(s, root: root, corner: nil, terminals: [NSRect(origin: .zero, size: root)]), root))
    }
    func make() throws -> (NSWindow, AskFloatRoot, AskFloat, NSTextView, UserDefaults) {
        let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Engine/windows/ShoWork.Win/Board/Web").standardizedFileURL
        let name = "askfloat-\(UUID().uuidString)", ud = UserDefaults(suiteName: name)!
        addTeardownBlock { ud.removePersistentDomain(forName: name) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: root), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let r = AskFloatRoot(frame: NSRect(origin: .zero, size: root)); w.contentView = r
        let term = NSTextView(frame: NSRect(x: 900, y: 0, width: 500, height: 600)); term.wantsLayer = true; term.layer?.zPosition = 50
        r.addSubview(term)
        let f = try XCTUnwrap(AskFloat(dir: web, store: ud))
        r.addSubview(f.view); r.float = f.view
        return (w, r, f, term, ud)
    }
    func testNeverTakesFocusByItself() throws {
        let (w, r, f, term, _) = try make()
        XCTAssertTrue(w.makeFirstResponder(term))
        for (m, h) in [("card", 360), ("strip", 34), ("card", 420)] {                                         // 跳出、縮、展開、換題
            f.handle(["action": "askSize", "mode": m, "w": 440, "h": h])
            XCTAssertFalse(f.view.isHidden); XCTAssertTrue(w.firstResponder === term)
        }
        XCTAssertFalse(f.view.acceptsFirstResponder); XCTAssertFalse(f.webView.canBecomeKeyView)
        _ = w.makeFirstResponder(f.view); XCTAssertFalse(w.firstResponder === f.view)                         // 程式也搶不到
        let e = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertFalse(f.view.performKeyEquivalent(with: e))
        // 滑鼠點過才拿得到；答完還給原本的終端機
        w.makeFirstResponder(term); f.webView.testClick = true
        XCTAssertTrue(w.makeFirstResponder(f.view)); XCTAssertTrue(w.firstResponder === f.view); f.webView.testClick = false
        f.handle(["action": "askFocusBack"]); XCTAssertTrue(w.firstResponder === term)
        // 卡片收掉時焦點不留在看不見的卡片上
        f.webView.testClick = true; w.makeFirstResponder(f.view); f.webView.testClick = false
        f.handle(["action": "askSize", "mode": "hidden", "w": 0, "h": 0]); XCTAssertTrue(f.view.isHidden); XCTAssertFalse(w.firstResponder === f.view)
        _ = r
    }
    func testOnTopOfSatellites() throws {
        let (w, r, f, term, _) = try make()
        f.handle(["action": "askSize", "mode": "card", "w": 440, "h": 360])
        let p = NSPoint(x: f.view.frame.midX, y: f.view.frame.midY)
        for i in 1...3 {                                                                                        // 後來才加的衛星、一直往上提的 zPosition 都蓋不住
            let s = NSView(frame: r.bounds); s.wantsLayer = true; s.layer?.zPosition = CGFloat(10_000 * i); r.addSubview(s)
            XCTAssertTrue(r.hitTest(p).map { $0 === f.view || $0.isDescendant(of: f.view) } ?? false)
            XCTAssertGreaterThan(f.view.layer?.zPosition ?? 0, s.layer?.zPosition ?? 0)
        }
        XCTAssertFalse(r.hitTest(NSPoint(x: 20, y: 400)) === f.view)                                            // 卡片外照樣點得到底下
        f.suppressed = true; XCTAssertTrue(f.view.isHidden); XCTAssertFalse(r.hitTest(p) === f.view); f.suppressed = false; XCTAssertFalse(f.view.isHidden)
        XCTAssertEqual(w.level, .normal); _ = term
    }
    func testDragAndRemember() throws {
        let (_, r, f, _, ud) = try make()
        f.handle(["action": "askSize", "mode": "card", "w": 440, "h": 360])
        f.handle(["action": "askDrag", "phase": "start"]); f.handle(["action": "askDrag", "phase": "move", "dx": -300, "dy": -200]); f.handle(["action": "askDrag", "phase": "end"])
        let f1 = f.view.frame; XCTAssertEqual(f1.minX, 1440 - 14 - 440 - 300); XCTAssertEqual(f1.minY, 214)
        XCTAssertEqual(ud.array(forKey: "orbit.askCorner") as? [Double], [314, 214])
        f.handle(["action": "askDrag", "phase": "start"]); f.handle(["action": "askDrag", "phase": "move", "dx": 9000, "dy": 9000]); f.handle(["action": "askDrag", "phase": "end"])
        XCTAssertTrue(inside(f.view.frame, root))
        f.corner = NSPoint(x: 314, y: 214); r.setFrameSize(NSSize(width: 500, height: 400)); f.layout(); XCTAssertTrue(inside(f.view.frame, NSSize(width: 500, height: 400)))
        r.setFrameSize(root); f.layout(); XCTAssertEqual(f.view.frame, f1)
    }
    func waitReady(_ f: AskFloat, _ s: Double = 8) async throws {
        for _ in 0..<Int(s * 20) { if f.ready { return }; try await Task.sleep(for: .milliseconds(50)) }
        XCTFail("浮層沒有 ready")
    }
    /// 別的來源、子框架、導覽、拖放都進不來（Gavin5 反例）
    func testOnlyOwnPage() async throws {
        let (_, _, f, _, _) = try make(); try await waitReady(f)
        var got: [[String: Any]] = []; SphereEmbed.testAction = { got.append($0) }; defer { SphereEmbed.testAction = nil }
        let evil = "webkit.messageHandlers.ask.postMessage({action:'answer',sessionId:'s',askId:'Q',free:'evil'});webkit.messageHandlers.ask.postMessage({action:'permit',sessionId:'s',permitId:'P',decision:'allow'})"
        f.webView.loadHTMLString("<script>\(evil)</script>", baseURL: URL(string: "https://evil.example/")); try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(got.count, 0)
        _ = try? await f.webView.evaluateJavaScript("(()=>{const i=document.createElement('iframe');i.srcdoc='<script>parent.webkit;\(evil.replacingOccurrences(of: "'", with: "\\'"))<\\/script>';document.body.append(i);location.href='https://evil.example/';window.open('https://evil.example/')})(),0")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(got.count, 0); XCTAssertEqual(f.webView.url?.absoluteString, AskFloat.page)
        for u in ["https://evil.example/", "showork://web/sphere.html", "showork://evil/ask.html", "showork://web/ask.html?x", "file:///etc/passwd", "about:blank"] { XCTAssertFalse(AskFloat.allowed(URL(string: u), mainFrame: true)) }
        XCTAssertFalse(AskFloat.allowed(URL(string: AskFloat.page), mainFrame: false)); XCTAssertTrue(AskFloat.allowed(URL(string: AskFloat.page), mainFrame: true))
        XCTAssertTrue(f.webView.registeredDraggedTypes.isEmpty)
    }
    /// 活著才接手；沒 ready、當掉、沒回應 ⇒ 球體照畫並重試；重新載入後尺寸、位置、縮成一條都在
    func testFallbackAndRestore() async throws {
        let (w, r, f, _, _) = try make()
        XCTAssertFalse(SphereEmbed.askFloat)                                        // 還沒 ready：球體自己畫
        try await waitReady(f); XCTAssertTrue(SphereEmbed.askFloat)
        let q = #"{"team":[{"status":"需要你","sessionId":"s1","askId":"A","name":"甲","ask":"要嗎","options":["好","不要"]}]}"#
        f.update(Data(q.utf8)); w.setContentSize(NSSize(width: 360, height: 420)); r.setFrameSize(NSSize(width: 360, height: 420)); f.layout(); f.corner = NSPoint(x: 5, y: 60)
        func js(_ s: String) async -> String { (try? await f.webView.evaluateJavaScript(s)).map { "\($0)" } ?? "" }
        for _ in 0..<40 where f.mode != "card" { try await Task.sleep(for: .milliseconds(50)) }
        _ = await js("collapse(false),0"); for _ in 0..<40 where f.mode != "strip" { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(f.mode, "strip")
        let before = (await js("document.documentElement.style.getPropertyValue('--w')"), await js("document.documentElement.style.getPropertyValue('--maxh')"), f.view.frame)
        XCTAssertEqual(before.0, "332px")
        f.webViewWebContentProcessDidTerminate(f.webView)
        XCTAssertFalse(SphereEmbed.askFloat); XCTAssertTrue(f.view.isHidden); XCTAssertFalse(f.ready)       // 立刻交回球體
        f.heartbeat(now: f.loadAt + 0.5); XCTAssertTrue(f.lost); f.heartbeat(now: f.loadAt + 1.1); XCTAssertFalse(f.lost)        // 1 秒後重試
        try await waitReady(f); for _ in 0..<40 where f.mode != "strip" { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(SphereEmbed.askFloat); XCTAssertEqual(f.mode, "strip"); XCTAssertFalse(f.view.isHidden)
        let after = (await js("document.documentElement.style.getPropertyValue('--w')"), await js("document.documentElement.style.getPropertyValue('--maxh')"), f.view.frame)
        XCTAssertEqual(before.0, after.0); XCTAssertEqual(before.1, after.1); XCTAssertEqual(before.2, after.2)
        // 沒回應
        f.pingAt = 100; f.pongAt = 99; f.heartbeat(now: 103); XCTAssertTrue(SphereEmbed.askFloat); f.heartbeat(now: 104.5); XCTAssertFalse(SphereEmbed.askFloat); XCTAssertTrue(f.lost)
        XCTAssertEqual([1, 2, 3, 4, 9].map(AskFloat.backoff), [1, 2, 4, 8, 30])
        // 8 秒沒 ready
        f.load(); f.heartbeat(now: f.loadAt + 1.5); f.heartbeat(now: f.loadAt + 9); XCTAssertFalse(SphereEmbed.askFloat)
        XCTAssertNil(AskFloat(dir: URL(fileURLWithPath: "/nope")))                  // 建不起來：沒有人把 askFloat 打開
    }
    /// 作答只走 SphereEmbed.askAction 那一條；送出中／沒確認到會告訴網頁
    func testOnlyOnePathAndState() throws {
        let (_, _, f, _, _) = try make()
        var got: [String] = []; SphereEmbed.testAction = { got.append($0["action"] as? String ?? "") }; defer { SphereEmbed.testAction = nil }
        for a in ["answer", "permit", "focus", "stopSpeaking", "captain", "auditFix", "newSatellite"] { f.handle(["action": a, "sessionId": "s", "askId": "Q", "permitId": "P", "decision": "deny"]) }
        XCTAssertEqual(got, ["answer", "permit", "focus", "stopSpeaking"])
        got = []                                                     // 沒帶題目、單號、決定的一律不收
        for m in [["action": "answer", "sessionId": "s", "free": "x"], ["action": "answer", "askId": "Q"], ["action": "permit", "sessionId": "s", "decision": "allow"], ["action": "permit", "sessionId": "s", "permitId": "", "decision": "allow"], ["action": "permit", "sessionId": "s", "permitId": "P"]] { f.handle(m) }
        XCTAssertEqual(got, [])
        func state(_ edit: (inout PendingAsk) -> Void) -> String? {
            var c = BoardCard(id: "s", column: .review, reason: "", project: "P", title: "t", lastActivity: nil, pid: 1, sessionId: "s"), q = PendingAsk(id: "Q1", ask: "題", options: ["好"], at: Date())
            edit(&q); c.asks = [q]
            return ((SphereWebHost.payload([c], nil)["team"] as? [[String: Any]])?.first)?["askState"] as? String
        }
        XCTAssertNil(state { _ in })
        XCTAssertEqual(state { $0.sendingAt = Date() }, "sending")
        XCTAssertEqual(state { $0.sendingAt = Date(timeIntervalSinceNow: -90) }, "unsure")                   // App 中途當掉
        XCTAssertEqual(state { $0.unsureAt = Date() }, "unsure")
    }
}
