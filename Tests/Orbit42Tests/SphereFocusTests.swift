import AppKit
import WebKit
import XCTest
@testable import Orbit42App

/// 11-25 Keng「打字跟語音輸入有東西在干擾我」：球體每次更新都把焦點還給戰情列上次點過的那一列，
/// 網頁的 focus() 會讓 WebKit 把整個視窗的鍵盤焦點從終端機搶走，聽寫就被系統暫停（T1125204651）
@MainActor
final class SphereFocusTests: XCTestCase {
    func testUpdateNeverStealsFocus() async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Engine/windows/Orbit42.Engine.Win/Board/Web").standardizedFileURL
        let cfg = WKWebViewConfiguration(); cfg.setURLSchemeHandler(WebSchemeHandler(root: dir), forURLScheme: WebSchemeHandler.scheme)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true); w.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800)); w.contentView = root
        let sphere = WKWebView(frame: root.bounds, configuration: cfg); root.addSubview(sphere)
        let term = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400)); root.addSubview(term)          // 終端機也是網頁
        sphere.load(URLRequest(url: URL(string: "\(WebSchemeHandler.scheme)://web/sphere.html?orbit=1")!))
        func js(_ s: String) async -> String { (try? await sphere.evaluateJavaScript(s)).map { "\($0)" } ?? "" }
        for _ in 0..<160 { if await js("typeof window.karaUpdate") == "function" { break }; try await Task.sleep(for: .milliseconds(50)) }
        let up = { (n: Int) in "window.karaUpdate({five_hour:\(n),seven_day:2,sessions:2,runs:[],orderable:true,team:[{name:'甲',status:'進行中',sessionId:'s1',doing:'\(n)'},{name:'乙',status:'進行中',sessionId:'s2'}]}),0" }
        _ = await js(up(1)); try await Task.sleep(for: .milliseconds(500))
        let rows = await js("document.querySelectorAll('#teamRows .trow[data-sid]').length"); XCTAssertEqual(rows, "2")
        // 點過戰情列的一列
        w.makeFirstResponder(sphere); _ = await js("(()=>{const f=document.createElement('iframe');document.body.append(f);window.rawFocus=f.contentWindow.HTMLElement.prototype.focus;rawFocus.call(document.querySelector('.trow[data-sid=\"s1\"]'))})(),0")      // 測試視窗不是主視窗，用沒包過的 focus 模擬「使用者點過」
        let sid = await js("document.activeElement.dataset.sid"); XCTAssertEqual(sid, "s1")
        // 回終端機打字
        XCTAssertTrue(w.makeFirstResponder(term))
        for n in 2...5 {
            _ = await js(up(n)); try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(w.firstResponder === term, "第 \(n) 次更新：焦點被 \(String(describing: w.firstResponder)) 搶走")
        }
        // 球體自己有焦點時照舊：更新後那一列的焦點還在（用方向鍵排序不會斷）
        w.makeFirstResponder(sphere); _ = await js("document.hasFocus=()=>true,rawFocus.call(document.querySelector('.trow[data-sid=\"s1\"]')),0")
        _ = await js(up(9)); let kept = await js("document.activeElement.dataset.sid||''"); XCTAssertEqual(kept, "s1")
    }
}
