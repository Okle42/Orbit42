import JavaScriptCore
import WebKit
import XCTest
@testable import Orbit42App

/// 11-28 Keng「那語音播報先做口語改寫」：球體播報送進 TTS 前的口語改寫（Board/Web/spoken.js）。
/// 案例取自 11-27 晚上真實播報（看板歷史重建），只換掉會變的內容。
final class SpokenRewriteTests: XCTestCase {
    static let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Engine/windows/Orbit42.Engine.Win/Board/Web").standardizedFileURL

    private var ctx: JSContext!
    override func setUpWithError() throws {
        ctx = JSContext()!
        var err: String?
        ctx.exceptionHandler = { _, e in err = e?.toString() }
        ctx.evaluateScript(try String(contentsOf: Self.web.appendingPathComponent("spoken.js"), encoding: .utf8))
        XCTAssertNil(err)
    }
    private func call(_ fn: String, _ args: Any...) -> String {
        ctx.objectForKeyedSubscript("Spoken").objectForKeyedSubscript(fn).call(withArguments: args).toString()
    }
    private func clean(_ s: String) -> String { call("clean", s) }
    private func card(_ kind: String, _ f: [String: Any]) -> String { call("card", kind, f) }

    // MARK: 規則改寫：念出來會怪的東西

    func testDropsTaskNumber() {
        XCTAssertEqual(clean("第二、三階段已派給 Milo（單號 T1128034721）"), "第二、三階段已派給 Milo")
        XCTAssertEqual(clean("放行毛病已派給 Milo，單號 T1128035638，排在後面"), "放行毛病已派給 Milo，排在後面")
    }
    func testDropsCommitHash() {
        XCTAssertEqual(clean("Orbit42 本機和 GitHub 已同步 50fc973"), "Orbit42 本機和 GitHub 已同步")
        XCTAssertEqual(clean("修正邏輯寫好並 commit 509ee59"), "修正邏輯寫好並 commit")
        XCTAssertEqual(clean("跑了 1234567 次"), "跑了 1234567 次", "純數字不是雜湊")
    }
    func testDropsPaths() {
        XCTAssertEqual(clean("規格寫在 ~/.claude/SPEC-orbit42-播報.md，你看一下"), "規格寫在，你看一下")
        XCTAssertEqual(clean("紀錄在 board/history.jsonl 裡"), "紀錄在裡")
        XCTAssertEqual(clean("改了 Engine/Sources/Orbit42App/SphereWebScene.swift"), "改了")
        XCTAssertEqual(clean("試聽在 /Users/me/Downloads/播報改寫試聽/ 裡"), "試聽在裡")
    }
    func testDropsURL() {
        XCTAssertEqual(clean("PR 開好了 https://github.com/x/y/pull/12 等你看"), "PR 開好了等你看")
    }
    func testDropsSessionId() {
        XCTAssertEqual(clean("session 633b306c-354c-46ed-b042-5bab91dec394 卡住"), "session 卡住")
    }
    func testDropsLongIdentifiers() {
        XCTAssertEqual(clean("改 window.karaToast 和 SphereWebScene 的 speak_text"), "改和的")
        XCTAssertEqual(clean("用 --status review 回報"), "用 review 回報")
        XCTAssertEqual(clean("OpenJarvis 跟 GitHub 留著"), "OpenJarvis 跟 GitHub 留著", "一般品牌名不能拿掉")
    }
    func testDropsParentheticals() {
        XCTAssertEqual(clean("Milo 建了一個假的開機項目（什麼都不做、已停用），體檢有抓到"), "Milo 建了一個假的開機項目，體檢有抓到")
        XCTAssertEqual(clean("驗收（1）通過"), "驗收通過")
        XCTAssertEqual(clean("3D 模型（k580 托座全套"), "3D 模型 k580 托座全套", "被截斷沒配對的括號只拿掉符號")
    }
    func testDropsReleaseCodeAndBang() {
        XCTAssertEqual(clean("你在秘書卡片按的「放行！BY45V」有放行別人的單"), "你在秘書卡片按的放行有放行別人的單")
    }
    func testSymbolsBecomePauses() {
        XCTAssertEqual(clean("秘書 · Orbit42｜待命"), "秘書 Orbit42，待命")
        XCTAssertEqual(clean("確認了：併主線 → 重開"), "確認了，併主線，重開")
        XCTAssertEqual(clean("用付費的 Cartesia／Eleven"), "用付費的 Cartesia或Eleven")
        XCTAssertEqual(clean("**重點**：`swift test` 全過⋯"), "重點，swift test 全過")
    }
    func testTimeSpoken() {
        XCTAssertEqual(clean("電話服務已重開，03:49 啟動正常"), "電話服務已重開，三點四十九分啟動正常")
        XCTAssertEqual(clean("04:05 重開"), "四點零五分重開")
        XCTAssertEqual(clean("14:00 開會"), "十四點開會")
        XCTAssertEqual(clean("02:30 跑完"), "兩點三十分跑完")
    }
    func testDateAndPercentSpoken() {
        XCTAssertEqual(clean("修你 11-27 說的問題"), "修你十一月二十七號說的問題")
        XCTAssertEqual(clean("額度用了 80%"), "額度用了百分之八十")
        XCTAssertEqual(clean("CPU 0%"), "CPU 百分之零")
        XCTAssertEqual(clean("額度 100%"), "額度百分之一百")
    }
    func testIdempotent() {
        let once = clean("秘書問 03:58 那次重開（T1128035638）：有沒有經過你同意 → 已回你")
        XCTAssertEqual(clean(once), once)
    }

    // MARK: 收短：不留「⋯」、不切在字中間

    func testShortenAtClause() {
        XCTAssertEqual(call("shorten", "資安體檢已裝好，黃燈也修了，放行改成在秘書卡片按也能放別人的單", 14), "資安體檢已裝好，黃燈也修了。")
        XCTAssertEqual(call("shorten", "比完了，OpenJarvis 好聽是因為用付費的 Cartesia 聲音", 30), "比完了，OpenJarvis 好聽是因為用付費的。")
        XCTAssertFalse(call("say", String(repeating: "很長的一句話", count: 30), 40).contains("⋯"))
    }

    // MARK: 卡片播報：像人在講

    func testReviewLine() {
        XCTAssertEqual(card("review", ["name": "修改 · Orbit42", "doing": "資安體檢", "result": "9 項都跑過（0.2 秒），commit 4a6ac92"]),
                       "Orbit42 那邊做完了資安體檢，等你看。9 項都跑過。")
        XCTAssertEqual(card("review", ["name": "秘書 · Orbit42", "doing": "待命", "result": ""]), "秘書這一輪做完了，等你看。")
    }
    func testAskLine() {
        XCTAssertEqual(card("ask", ["name": "秘書 · Orbit42", "doing": "待命", "ask": "放行要答在 Milo 的卡片上才算，秘書卡片上的放行 Orbit42 找不到單"]),
                       "秘書有事問你。放行要答在 Milo 的卡片上才算。")
    }
    func testDoneAndStuckLines() {
        XCTAssertEqual(card("done", ["name": "修改 · Hotline42", "doing": "縮短接電話暫停時間", "result": "已併進主線、電話服務已重開（03:49 啟動正常）"]),
                       "Hotline42 那邊的縮短接電話暫停時間做好了。已併進主線、電話服務已重開。")
        XCTAssertEqual(card("quiet", ["name": "修改 · Orbit42", "doing": "球體播報", "minutes": "12"]),
                       "Orbit42 那邊做球體播報，已經 12 分鐘沒動靜，可能卡住了。")
        XCTAssertEqual(card("stuck", ["name": "秘書 · Orbit42", "doing": "", "why": "放行毛病已派給 Milo（單號 T1128035638）"]),
                       "秘書卡住了。放行毛病已派給 Milo。")
    }
    func testNoGarbageInRealLines() {
        // 11-27 真實播報裡出現過的東西，改寫後一個都不能剩
        let lines = [
            card("ask", ["name": "修改 · Orbit42", "doing": "修秘書卡片放行無效", "ask": "已裝好：本機 main 4a6ac92、Orbit42 04:00 重開（單號 T1128035638）→ 你看 ~/x/y.md"]),
            card("stuck", ["name": "秘書 · Orbit42", "why": "第 2 種通過：「放行！BY45V」｜紀錄在 board/history.jsonl"]),
        ]
        for l in lines {
            for bad in ["T1128", "4a6ac92", "BY45V", "~/", ".md", ".jsonl", "｜", "→", "「", "（", "⋯", "：", "04:00"] {
                XCTAssertFalse(l.contains(bad), "「\(l)」還有 \(bad)")
            }
        }
    }

    // MARK: AI 口語改寫的輸出把關（不合格就退回規則版）

    func testAITidy() {
        XCTAssertEqual(SphereSpokenAI.tidy("「秘書卡片放行修好了，等你看。」\n"), "秘書卡片放行修好了，等你看。")
        XCTAssertEqual(SphereSpokenAI.tidy("\n\n資安體檢做完了\n（說明：…）"), "資安體檢做完了")
        XCTAssertNil(SphereSpokenAI.tidy(""))
        XCTAssertNil(SphereSpokenAI.tidy("Error: Input must be provided"))
        XCTAssertNil(SphereSpokenAI.tidy(String(repeating: "太長", count: 40)))
        XCTAssertNil(SphereSpokenAI.tidy("OK"), "沒有中文＝不是我們要的那句")
    }
}

/// 字幕跟聲音同一句（11-23「語音跟字幕對不上」不能再犯）：真的載 sphere.html，播報一句有單號、雜湊、時間的話，
/// 送去原生端念的文字（speak）＝字幕最後顯示的文字＝改寫後的那句。
@MainActor
final class SpokenCaptionSyncTests: XCTestCase {
    final class Spy: NSObject, WKScriptMessageHandler {
        var spoken: [String] = []
        weak var web: WKWebView?
        func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let b = m.body as? [String: Any], b["action"] as? String == "speak", let t = b["text"] as? String else { return }
            spoken.append(t)
            // 假裝原生端唸完整句：start → 唸到最後一個字（字幕逐詞同步）→ 記下這時的字幕 → end
            web?.evaluateJavaScript("window.karaVoice('start'); window.karaVoice('word', 0, \(t.utf16.count)); window.__cap = document.getElementById('capText').textContent; window.karaVoice('end')")
        }
    }

    func testCaptionEqualsSpokenText() async throws {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()          // 開語音開關寫的 localStorage 不留下來
        cfg.setURLSchemeHandler(WebSchemeHandler(root: SpokenRewriteTests.web), forURLScheme: WebSchemeHandler.scheme)
        let spy = Spy()
        cfg.userContentController.add(spy, name: "sphere")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true); w.isReleasedWhenClosed = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: cfg); spy.web = web
        w.contentView = web
        web.load(URLRequest(url: URL(string: "\(WebSchemeHandler.scheme)://web/sphere.html?orbit=1")!))
        func js(_ s: String) async -> String { (try? await web.evaluateJavaScript(s)).map { "\($0)" } ?? "" }
        for _ in 0..<160 { if await js("typeof window.karaUpdate") == "function" { break }; try await Task.sleep(for: .milliseconds(50)) }
        let loadedSpoken = await js("typeof window.Spoken")
        XCTAssertEqual(loadedSpoken, "object", "spoken.js 沒載到")
        _ = await js("localStorage.setItem('sphere.voice','1'); window.__old = 1; 0")
        web.reload()                                     // 語音開關在載入時讀：重新載入、等新頁面好（舊頁面沒有 __old 才算）
        for _ in 0..<200 { if await js("typeof window.__old + typeof window.karaUpdate") == "undefinedfunction" { break }; try await Task.sleep(for: .milliseconds(50)) }
        _ = await js("window.__errs = []; addEventListener('error', e => __errs.push(e.message)); addEventListener('unhandledrejection', e => __errs.push(String(e.reason))); window.__said = []; 0")
        let raw = "秘書回覆：已推上 GitHub（50fc973），04:11 重開，單號 T1128035638 → 你看 ~/.claude/x.md"
        _ = await js("window.karaToast(\(String(data: try JSONSerialization.data(withJSONObject: [raw]), encoding: .utf8)!)[0]); 0")
        for _ in 0..<100 { if !spy.spoken.isEmpty { break }; try await Task.sleep(for: .milliseconds(50)) }
        let dbg = await js("JSON.stringify({on: document.getElementById('voice').classList.contains('on'), cap: document.getElementById('capText').textContent, wk: !!window.webkit?.messageHandlers?.sphere, errs: window.__errs, said: window.__said, st: document.body.className})")
        XCTAssertEqual(spy.spoken.count, 1, "語音開著要送一句去念 \(dbg)")
        let said = spy.spoken.first ?? ""
        XCTAssertEqual(said, "秘書回覆，已推上 GitHub，四點十一分重開，你看。")
        try await Task.sleep(for: .milliseconds(300))
        let caption = await js("window.__cap")
        XCTAssertEqual(caption, said, "字幕要跟念的是同一句")
        _ = await js("localStorage.removeItem('sphere.voice'); 0")
    }
}
