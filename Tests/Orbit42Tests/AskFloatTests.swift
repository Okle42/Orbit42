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
        XCTAssertEqual(AskFloatLayout.card(card, root: root, spot: nil), NSRect(x: 500, y: 270, width: 440, height: 360))      // 正中央
        for w in [NSSize(width: 360, height: 420), NSSize(width: 620, height: 460), NSSize(width: 1440, height: 900), NSSize(width: 1920, height: 1080)] {      // 尺寸跟著視窗、完整看得到、置中
            let m = AskFloatLayout.maxSize(w), f = AskFloatLayout.card(m, root: w, spot: nil)
            XCTAssertEqual(m.width, min(560, w.width - 28)); XCTAssertTrue(inside(f, w)); XCTAssertEqual(f.midX, w.width / 2, accuracy: 1); XCTAssertEqual(f.midY, w.height / 2, accuracy: 1)
        }
        for c in [NSPoint(x: -500, y: -500), NSPoint(x: 5000, y: 5000), NSPoint(x: 0, y: 899)] { XCTAssertTrue(inside(AskFloatLayout.card(card, root: root, spot: c), root)) }
        let small = NSSize(width: 600, height: 420)
        XCTAssertTrue(inside(AskFloatLayout.card(card, root: small, spot: NSPoint(x: 900, y: 500)), small))
        let over = AskFloatLayout.card(NSSize(width: 440, height: 900), root: small, spot: nil)            // 比視窗高：標題列一定看得到
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
        let f1 = f.view.frame; XCTAssertEqual(f1.origin, NSPoint(x: 200, y: 470))
        f.handle(["action": "askSize", "mode": "card", "w": 440, "h": 300]); XCTAssertEqual(f.view.frame.minX, 200)                              // 展開期間留在拖到的位置
        f.handle(["action": "askDrag", "phase": "start"]); f.handle(["action": "askDrag", "phase": "move", "dx": 9000, "dy": 9000]); f.handle(["action": "askDrag", "phase": "end"])
        XCTAssertTrue(inside(f.view.frame, root))
        f.handle(["action": "askOpen", "open": false]); f.handle(["action": "askOpen", "open": true]); f.layout()                                  // 再展開＝回正中央
        XCTAssertEqual(f.view.frame.midX, 720, accuracy: 1); XCTAssertEqual(f.view.frame.midY, 450, accuracy: 1)
        for s in [NSSize(width: 500, height: 400), NSSize(width: 1920, height: 1080)] { r.setFrameSize(s); f.layout(); XCTAssertTrue(inside(f.view.frame, s)); XCTAssertEqual(f.view.frame.midX, s.width / 2, accuracy: 1) }
        ud.set([1444.0, 33.0], forKey: "orbit.askCorner"); f.layout(); XCTAssertEqual(f.view.frame.midX, 960, accuracy: 1)                        // 舊版記住的左下角不再作用
    }
    /// T1125120137：打字中先不展開、停 2 秒才展開、不搶焦點；位置拉回；展開閃開輸入框；拖條不改卡片
    func testAutoExpandWaitsForTyping() async throws {
        let (w, r, f, term, ud) = try make(); try await waitReady(f); w.makeFirstResponder(term)
        func js(_ s: String) async -> String { (try? await f.webView.evaluateJavaScript(s)).map { "\($0)" } ?? "" }
        func until(_ m: String) async throws { for _ in 0..<60 where f.mode != m { try await Task.sleep(for: .milliseconds(50)) } }
        func q(_ ids: [String]) -> Data { Data(("{\"team\":[" + ids.map { "{\"status\":\"需要你\",\"sessionId\":\"s\($0)\",\"askId\":\"\($0)\",\"name\":\"甲\",\"ask\":\"要嗎\",\"options\":[\"好\",\"不要\"]}" }.joined(separator: ",") + "]}").utf8) }
        f.update(q(["A"])); try await until("card"); _ = await js("collapse(false),0"); try await until("strip"); XCTAssertEqual(f.mode, "strip")
        XCTAssertFalse(f.mayExpand(now: f.lastKey + 1.9)); XCTAssertTrue(f.mayExpand(now: f.lastKey + 2))
        f.composing = { true }; XCTAssertFalse(f.mayExpand(now: f.lastKey + 99)); f.composing = { false }
        f.lastKey = ProcessInfo.processInfo.systemUptime; let t0 = f.lastKey
        f.update(q(["A", "B"])); try await Task.sleep(for: .milliseconds(1200)); XCTAssertEqual(f.mode, "strip"); XCTAssertNotNil(f.wantTimer)      // 正在打字：不展開
        try await until("card"); XCTAssertEqual(f.mode, "card"); XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - t0, 2)
        XCTAssertTrue(w.firstResponder === term); let cur = await js("askState().cur"); XCTAssertEqual(cur, "sB|a:B"); let armed = await js("askState().armed"); XCTAssertEqual(armed, "0")
        _ = await js("collapse(false),0"); try await until("strip"); f.lastKey = -100
        f.update(q(["B", "A"])); try await Task.sleep(for: .milliseconds(400)); XCTAssertEqual(f.mode, "strip")                                       // 看過的不再彈
        f.update(q(["A", "B", "C"])); try await until("card"); XCTAssertEqual(f.mode, "card"); try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(f.view.frame.midX, root.width / 2, accuracy: 1); XCTAssertEqual(f.view.frame.midY, root.height / 2, accuracy: 1)                  // 自動展開也在正中央
        _ = await js("collapse(false),0"); try await until("strip"); XCTAssertEqual(f.view.frame.size, NSSize(width: 152, height: 152))
        let o = f.view.frame; XCTAssertTrue(f.covers(NSPoint(x: o.midX, y: o.midY))); XCTAssertTrue(f.covers(NSPoint(x: o.midX, y: o.maxY - 4)))                                                              // 羅盤上點得到
        for p in [NSPoint(x: o.minX + 2, y: o.maxY - 2), NSPoint(x: o.minX + 2, y: o.minY + 2), NSPoint(x: o.maxX - 2, y: o.minY + 2), NSPoint(x: o.maxX - 8, y: o.maxY - 8)] {
            XCTAssertFalse(f.covers(p)); XCTAssertNil(f.view.hitTest(p))                                                                               // 圓外的透明處不擋點擊
        }
        // 縮起再展開：寬度要回到該有的寬，不可停在縮起的寬；視窗大小變了也一樣
        for s in [root, NSSize(width: 620, height: 460), NSSize(width: 360, height: 420), root] {
            r.setFrameSize(s); f.layout(); try await Task.sleep(for: .milliseconds(300))
            _ = await js("expand(),0"); try await until("card"); try await Task.sleep(for: .milliseconds(700))
            XCTAssertEqual(f.view.frame.width, min(560, s.width - 28) + 2, accuracy: 3); XCTAssertEqual(f.view.frame.midX, s.width / 2, accuracy: 1); XCTAssertTrue(inside(f.view.frame, s))
            let clip = await js("[...document.querySelectorAll('.opt,.q,.free,#over')].every(x=>x.getBoundingClientRect().right<=innerWidth+0.5&&x.getBoundingClientRect().left>=0)?'ok':'cut'"); XCTAssertEqual(clip, "ok", "\(s)")
            let slot = await js("getComputedStyle(document.documentElement).getPropertyValue('--slot').trim()"); XCTAssertEqual(slot, s.width - 28 <= 340 ? "118px" : "58px")
            _ = await js("collapse(false),0"); try await until("strip"); try await Task.sleep(for: .milliseconds(200)); XCTAssertEqual(f.view.frame.width, 152)
        }
        f.handle(["action": "askDrag", "phase": "start"]); f.handle(["action": "askDrag", "phase": "move", "dx": -100, "dy": -100]); f.handle(["action": "askDrag", "phase": "end"])
        XCTAssertNil(ud.array(forKey: "orbit.askCorner")); XCTAssertNotNil(ud.array(forKey: "orbit.askFan"))
    }
    /// T1125192544：縮起後再展開一定是完整的寬，右緣不溢出（自動展開、答完接權限框、重新載入後第一次、深淺、窄視窗）
    func testExpandIsNeverClipped() async throws {
        let (_, r, f, _, _) = try make(); try await waitReady(f); f.lastKey = -100
        func js(_ s: String) async -> String { (try? await f.webView.evaluateJavaScript(s)).map { "\($0)" } ?? "" }
        func until(_ m: String) async throws { for _ in 0..<80 where f.mode != m { try await Task.sleep(for: .milliseconds(50)) }; XCTAssertEqual(f.mode, m); try await Task.sleep(for: .milliseconds(700)) }
        func whole(_ at: String) async {
            let w = r.bounds.width; XCTAssertEqual(f.view.frame.width, min(560, w - 28) + 2, accuracy: 3, at); XCTAssertTrue(inside(f.view.frame, r.bounds.size), at)
            XCTAssertEqual(f.view.frame.midX, w / 2, accuracy: 1, at)
            let c = await js("[...document.querySelectorAll('#wrap,#card,.top,.q,.opt,.free,#over')].filter(x=>x.offsetWidth).every(x=>{const b=x.getBoundingClientRect();return b.left>=0&&b.right<=innerWidth+.5})&&document.querySelector('#card').scrollWidth<=document.querySelector('#card').clientWidth?'ok':'cut'"); XCTAssertEqual(c, "ok", at)
        }
        func q(_ ids: [String], permit: Bool = false) -> Data {
            var xs = ids.map { "{\"status\":\"需要你\",\"sessionId\":\"s\($0)\",\"askId\":\"\($0)\",\"name\":\"甲\",\"ask\":\"\(String(repeating: "很長的問題", count: 12))\",\"options\":[\"\(String(repeating: "長選項", count: 10))\",\"不要\",\"改天\",\"取消\"]}" }
            if permit { xs.append("{\"status\":\"需要你\",\"sessionId\":\"p\",\"name\":\"權限\",\"ask\":\"要不要執行\",\"permit\":{\"id\":\"P\",\"kind\":\"tool\",\"tool\":\"Bash\",\"summary\":\"ls\"}}") }
            return Data("{\"team\":[\(xs.joined(separator: ","))]}".utf8)
        }
        for (th, s) in [("dark", root), ("light", NSSize(width: 360, height: 420)), ("dark", NSSize(width: 620, height: 460))] {
            r.setFrameSize(s); f.theme = th; f.update(Data(#"{"team":[]}"#.utf8)); try await until("hidden"); try await Task.sleep(for: .milliseconds(1700)); _ = await js("seen.clear(),askRestore(true),0")
            f.update(q(["A"])); try await until("card"); await whole("第一次 \(th) \(s)")
            _ = await js("collapse(false),0"); try await until("strip"); _ = await js("expand(),0"); try await until("card"); await whole("縮起→展開 \(th) \(s)")
            _ = await js("collapse(false),0"); try await until("strip"); f.update(q(["A", "B"])); try await until("card"); await whole("自動展開 \(th) \(s)")
            _ = await js("collapse(false),0"); try await until("strip"); _ = await js("expand(),0"); try await until("card"); f.update(q([], permit: true)); try await Task.sleep(for: .milliseconds(2400)); try await until("card")
            let permit = await js("document.querySelectorAll('.opt').length"); XCTAssertEqual(permit, "3"); await whole("接權限框 \(th) \(s)")
            _ = await js("collapse(false),0"); try await until("strip")
            f.webViewWebContentProcessDidTerminate(f.webView); f.heartbeat(now: f.loadAt + 1.1); try await waitReady(f); try await until("strip"); _ = await js("expand(),0"); try await until("card"); await whole("重新載入後 \(th) \(s)")
        }
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
        SphereEmbed.setAskFloat(false); let (w, r, f, _, _) = try make()
        XCTAssertFalse(SphereEmbed.askFloat)                                        // 還沒 ready：球體自己畫
        try await waitReady(f); XCTAssertTrue(SphereEmbed.askFloat)
        let q = #"{"team":[{"status":"需要你","sessionId":"s1","askId":"A","name":"甲","ask":"要嗎","options":["好","不要"]}]}"#
        f.update(Data(q.utf8)); w.setContentSize(NSSize(width: 360, height: 420)); r.setFrameSize(NSSize(width: 360, height: 420)); f.layout()
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
    // MARK: 網頁免重開（T1125194238）
    func variant(_ f: AskFloat, _ from: String = "<title>答案卡</title>", _ to: String = "<title>答案卡</title><!-- v2 -->") -> Data {
        let t = String(decoding: f.page, as: UTF8.self); XCTAssertTrue(t.contains(from)); return Data(t.replacingOccurrences(of: from, with: to).utf8)
    }
    func teamData(_ ids: [String], state: String = "") -> Data { Data(("{\"team\":[" + ids.map { "{\"status\":\"需要你\",\"sessionId\":\"s\($0)\",\"askId\":\"\($0)\",\"name\":\"甲\",\"ask\":\"要嗎\",\"options\":[\"好\",\"不要\"]\(state)}" }.joined(separator: ",") + "]}").utf8) }
    func settle(_ s: Double, _ c: @escaping () -> Bool = { false }) async throws { for _ in 0..<Int(s * 20) where !c() { try await Task.sleep(for: .milliseconds(50)) } }
    func testPageSwapKeepsEverything() async throws {
        let (w, r, f, term, _) = try make(); try await waitReady(f); w.makeFirstResponder(term); f.lastKey = -100
        var got: [[String: Any]] = []; SphereEmbed.testAction = { got.append($0) }; defer { SphereEmbed.testAction = nil }
        func js(_ s: String) async -> String { (try? await f.webView.evaluateJavaScript(s)).map { "\($0)" } ?? "" }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID()).json"); f.status = tmp; defer { try? FileManager.default.removeItem(at: tmp) }
        f.update(teamData(["A", "B"])); try await settle(4) { f.mode == "card" }; XCTAssertEqual(f.mode, "card")
        _ = await js("drafts.set('sB|a:B','草稿「一」\\n二'),drafts.set('sZ|a:Z','別題'),note.set('sA|a:A',true),cur='sB|a:B',render(),0")
        let old = f.webView, v2 = variant(f), h0 = f.pageHash
        f.offer(v2); try await settle(1.5); XCTAssertTrue(f.webView === old); XCTAssertNil(f.candidate)                     // 展開著：不換
        _ = await js("collapse(false),0"); try await settle(8) { f.webView !== old }
        XCTAssertFalse(f.webView === old); XCTAssertNotEqual(f.pageHash, h0); XCTAssertEqual(f.pageHash, AskPage.hash(v2)); XCTAssertNil(f.waiting)
        try await settle(1)
        XCTAssertTrue(r.float === f.webView); XCTAssertNil(old.superview); XCTAssertEqual(f.mode, "strip"); XCTAssertFalse(f.view.isHidden); XCTAssertTrue(SphereEmbed.askFloat); XCTAssertTrue(w.firstResponder === term)
        XCTAssertEqual(f.view.frame.size, NSSize(width: 120, height: 120))
        let v = await js("JSON.stringify([askState().visible,[...drafts],[...note],cur,open])")
        XCTAssertEqual(v, #"[["sA|a:A","sB|a:B"],[["sB|a:B","草稿「一」\n二"],["sZ|a:Z","別題"]],[["sA|a:A",true]],"sB|a:B",false]"#)
        XCTAssertEqual(got.count, 0)                                                                                          // 沒有送出任何東西
        XCTAssertTrue(((try? String(contentsOf: tmp, encoding: .utf8)) ?? "").contains(AskPage.hash(v2)))
        f.update(teamData(["A", "B"])); try await settle(0.6); XCTAssertEqual(f.mode, "strip")                                // 看過的不再彈
        f.update(teamData(["A", "B", "C"])); try await settle(4) { f.mode == "card" }; XCTAssertEqual(f.mode, "card")        // 新題照彈
        f.webViewWebContentProcessDidTerminate(old); XCTAssertTrue(f.ready)                                                   // 舊的晚到的通知不理
        f.webViewWebContentProcessDidTerminate(f.webView); f.heartbeat(now: f.loadAt + 1.1); try await waitReady(f)          // 當掉重載還是新版
        let t = await js("document.documentElement.outerHTML.includes('<!-- v2 -->')?'v2':'v1'"); XCTAssertEqual(t, "v2")
    }
    func testPageSwapWaits() async throws {
        let (w, r, f, term, _) = try make(); try await waitReady(f); w.makeFirstResponder(term); f.lastKey = -100; defer { _ = r }
        var got: [[String: Any]] = []; SphereEmbed.testAction = { got.append($0) }; defer { SphereEmbed.testAction = nil }
        func js(_ s: String) async -> String { (try? await f.webView.evaluateJavaScript(s)).map { "\($0)" } ?? "" }
        f.update(teamData(["A", "B"])); try await settle(4) { f.mode == "card" }; _ = await js("collapse(false),0"); try await settle(4) { f.mode == "strip" }
        for (on, off) in [("undos.set('x',{key:'x',t:0,name:'',label:''})", "undos.clear()"), ("sent.set('sA|a:A',{})", "sent.clear()"), ("drag={x:0,y:0}", "drag=null"), ("armed=true", "armed=false"), ("want='sA|a:A'", "want=null"), ("barText='提示'", "barText=''"),
                          ("document.body.classList.add('open')", "document.body.classList.remove('open')"), ("(()=>{const t=document.createElement('textarea');t.id='tt';document.body.append(t);t.focus()})()", "document.getElementById('tt').remove()")] {
            _ = await js("\(on),0"); let st = try? await f.webView.evaluateJavaScript(AskFloat.stateJS); XCTAssertFalse(st is String, on); _ = await js("\(off),0")
            let back = try? await f.webView.evaluateJavaScript(AskFloat.stateJS); XCTAssertTrue(back is String, off)
        }
        // 復原倒數中不換；送出那一次只送一次，之後才換
        let old = f.webView; _ = await js("undos.set('x',{key:'x',t:0,name:'',label:''}),0"); f.offer(variant(f)); try await settle(3); XCTAssertTrue(f.webView === old); XCTAssertNil(f.candidate)
        _ = await js("undos.clear(),0"); f.handle(["action": "askTyping", "on": false]); try await settle(8) { f.webView !== old }; XCTAssertFalse(f.webView === old); XCTAssertEqual(got.filter { $0["action"] as? String != "stopSpeaking" }.count, 0)
        // 送出中（題目狀態）不換
        let cur = f.webView; f.update(teamData(["A"], state: ",\"askState\":\"sending\"")); try await settle(0.5); f.offer(variant(f, "<!-- v2 -->", "<!-- v3 -->")); try await settle(2.5); XCTAssertTrue(f.webView === cur)
        f.update(teamData([])); try await settle(8) { f.webView !== cur }; XCTAssertFalse(f.webView === cur)
    }
    func testBadPageKeepsOld() async throws {
        let (w, r, f, term, _) = try make(); try await waitReady(f); w.makeFirstResponder(term); defer { _ = (w, r) }
        var got: [[String: Any]] = []; SphereEmbed.testAction = { got.append($0) }; defer { SphereEmbed.testAction = nil }
        let old = f.webView, h = f.pageHash
        for (name, d) in [("不說 ready", variant(f, "post({ action: \"ready\" });", "")), ("資料一來就丟例外", variant(f, "window.askUpdate = askUpdate;", "window.askUpdate = () => { throw 1 };")), ("少功能", variant(f, "window.askGo =", "window.askGoX =")),
                          ("草稿名字改了", variant(f, "drafts", "dr4fts")), ("載入就想作答", variant(f, "post({ action: \"ready\" });", "post({action:'answer',sessionId:'s',askId:'Q',free:'evil'});post({action:'permit',sessionId:'s',permitId:'P',decision:'allow'});"))] {
            f.update(teamData([])); f.offer(d); try await settle(12) { f.refused.contains(AskPage.hash(d)) }
            XCTAssertTrue(f.refused.contains(AskPage.hash(d)), name); XCTAssertTrue(f.webView === old, name); XCTAssertEqual(f.pageHash, h); XCTAssertTrue(f.ready); XCTAssertNil(f.candidate); XCTAssertTrue(SphereEmbed.askFloat)
            f.offer(d); XCTAssertNil(f.waiting)                                                                                // 同一版不再試
        }
        XCTAssertEqual(got.count, 0)
    }
    /// 只認同一簽章身分、驗過、執行檔相同的新包
    func testOnlyVerifiedBundle() throws {
        let fm = FileManager.default, dir = fm.temporaryDirectory.appendingPathComponent("askb-\(UUID())"); defer { try? fm.removeItem(at: dir) }
        @MainActor func run(_ a: [String]) -> Int32 { let p = Process(); p.executableURL = URL(fileURLWithPath: a[0]); p.arguments = Array(a.dropFirst()); p.standardError = Pipe(); try? p.run(); p.waitUntilExit(); return p.terminationStatus }
        func bundle(_ n: String, id: String = "t.ask") throws -> URL {
            let b = dir.appendingPathComponent(n), c = b.appendingPathComponent("Contents")
            for s in ["MacOS", "Resources/Web"] { try fm.createDirectory(at: c.appendingPathComponent(s), withIntermediateDirectories: true) }
            let src = Bundle(for: AskFloatTests.self).executableURL!; try fm.copyItem(at: src, to: c.appendingPathComponent("MacOS/X"))
            try Data("<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>\(id)</string><key>CFBundleExecutable</key><string>X</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>".utf8).write(to: c.appendingPathComponent("Info.plist"))
            try Data("page".utf8).write(to: c.appendingPathComponent("Resources/Web/ask.html"))
            let rc = run(["/usr/bin/codesign", "-f", "-s", "-", "--identifier", id, b.path]); XCTAssertEqual(rc, 0); return b
        }
        var req: SecRequirement?; SecRequirementCreateWithString("identifier \"t.ask\"" as CFString, [], &req); let rq = try XCTUnwrap(req)
        let a = try bundle("a.app"), u = try XCTUnwrap(AskPage.uuid(file: a.appendingPathComponent("Contents/MacOS/X"))), page = a.appendingPathComponent("Contents/Resources/Web/ask.html")
        XCTAssertNotNil(AskPage.runningUUID)
        XCTAssertEqual(try AskPage.fetch(bundle: a, executable: "X", requirement: rq, uuid: u).get(), Data("page".utf8))
        XCTAssertEqual(AskPage.fetch(bundle: a, executable: "X", requirement: rq, uuid: UUID()), .failure(.binary))
        guard case .failure(.signature) = AskPage.fetch(bundle: try bundle("b.app", id: "t.evil"), executable: "X", requirement: rq, uuid: u) else { return XCTFail("別的身分也收") }
        try Data("evil".utf8).write(to: page)
        guard case .failure(.signature) = AskPage.fetch(bundle: a, executable: "X", requirement: rq, uuid: u) else { return XCTFail("改過沒重簽也收") }
        try fm.removeItem(at: page); try fm.createSymbolicLink(at: page, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertEqual(AskPage.fetch(bundle: a, executable: "X", requirement: rq, uuid: u), .failure(.read))
        XCTAssertEqual(AskPage.fetch(bundle: dir.appendingPathComponent("none.app"), executable: "X", requirement: rq, uuid: u), .failure(.read))
    }
    /// 資料夾一換就知道（系統通知），不用問
    func testWatchSeesAtomicSwap() async throws {
        let fm = FileManager.default, dir = fm.temporaryDirectory.appendingPathComponent("askw-\(UUID())"); defer { try? fm.removeItem(at: dir) }
        let apps = dir.appendingPathComponent("Applications"), a = apps.appendingPathComponent("A.app"), b = dir.appendingPathComponent("B.old")
        for x in [a, b] { try fm.createDirectory(at: x, withIntermediateDirectories: true) }
        var req: SecRequirement?; SecRequirementCreateWithString("identifier \"t.ask\"" as CFString, [], &req)
        var n = 0; let w = try XCTUnwrap(AskPageWatch(bundle: a, executable: "X", requirement: req, uuid: UUID()) { _ in n += 1 })
        try await Task.sleep(for: .milliseconds(1500)); XCTAssertEqual(n, 0)
        XCTAssertEqual(renamex_np(b.path, a.path, UInt32(RENAME_SWAP)), 0); for _ in 0..<60 where n == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(n, 1); w.stop()
        XCTAssertNil(AskPageWatch(bundle: a, executable: "X", requirement: nil, uuid: UUID()) { _ in })
    }
}
