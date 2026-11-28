import AppKit
import WebKit
import Orbit42App
import Orbit42Core

// Orbit42: the sphere is the home screen; every AI worker is a satellite with its own real terminal.
// Web UI (Web/index.html: three.js sphere + xterm.js) talks to this host through `webkit.messageHandlers.orbit`.
//
// Test hooks (window off-screen, never on the user's display):
//   ORBIT_OFFSCREEN=1  ORBIT_TEST_JS=<js run 1.5 s after load>  ORBIT_TEST_SHOT=<png> ORBIT_TEST_SHOT_DELAY=<s>  ORBIT_TEST_QUIT=1


/// Serves files under Web/ as orbit://app/<path>
final class WebFiles: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }
    func webView(_ w: WKWebView, start task: any WKURLSchemeTask) {
        let rel = task.request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let file = root.appendingPathComponent(rel.isEmpty ? "index.html" : rel).standardizedFileURL
        guard file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "json": "application/json", "png": "image/png", "svg": "image/svg+xml"]
        let mime = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime + "; charset=utf-8", "Cache-Control": "no-store"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ w: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// 從原生端呼叫同一套訊息處理（跟網頁送來的一樣）
final class FakeMessage: WKScriptMessage {
    private let payload: [String: Any]
    init(_ p: [String: Any]) { payload = p; super.init() }
    override var body: Any { payload }
}

/// 登入畫面（Orbit42 一打開先出現）：列出各家 AI 帳號的安裝／登入狀態，按登入走各家官方登入
@MainActor
final class LoginPanel: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    var onEnter: ([Provider]) -> Void = { _ in }
    var runInTerminal: (String, Brain, String) -> Void = { _, _, _ in }
    private(set) var providers: [Provider] = []
    private var poll: Timer?

    override init() {
        let cfg = WKWebViewConfiguration()
        if let dir = Host.webDir { cfg.setURLSchemeHandler(WebFiles(root: dir), forURLScheme: "orbit") }
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "login")
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: URL(string: "orbit://app/login.html")!))
        // 登入多半在瀏覽器完成：登入畫面開著時每 3 秒重查一次
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { if self?.web.isHidden == false { self?.check() } } }
    }

    func check() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Accounts.check()
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.providers = list
                if let d = try? JSONSerialization.data(withJSONObject: list.map(\.json)) {
                    self.web.evaluateJavaScript("window.orbitAccounts && window.orbitAccounts(\(String(decoding: d, as: UTF8.self)))")
                }
                self.pushOrbitAccount()
            } }
        }
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let a = b["action"] as? String else { return }
        let p = Accounts.all.first { $0.id == b["id"] as? String }
        let brain = Brain(rawValue: p?.id ?? "") ?? .claude
        switch a {
        case "check": check()
        case "login": if let p, let cmd = p.login { runInTerminal("登入 \(p.name)", brain, cmd) }
        case "install": if let p, let cmd = p.install { runInTerminal("安裝 \(p.name)", brain, cmd) }
        case "enter": onEnter(providers)
        case "orbitSignIn": orbitSignIn()
        case "orbitSignOut": OrbitAccount.shared.signOut(); pushOrbitAccount()
        default: break
        }
    }

    // 11-26：Orbit42 自己的帳號（用 Google 登入，OrbitAccount.swift）
    func pushOrbitAccount(error: String? = nil) {
        var o = OrbitAccount.shared.stateJSON
        if let error { o["error"] = error }
        if let d = try? JSONSerialization.data(withJSONObject: o) {
            web.evaluateJavaScript("window.orbitAccount && window.orbitAccount(\(String(decoding: d, as: UTF8.self)))")
        }
    }
    func orbitSignIn() {
        OrbitAccount.shared.anchor = web.window
        Task { @MainActor in
            do { _ = try await OrbitAccount.shared.signIn(); pushOrbitAccount() }
            catch OrbitAccountError.cancelled { pushOrbitAccount() }
            catch { pushOrbitAccount(error: error.localizedDescription) }
        }
    }
}


/// 滑鼠在主視窗裡的移動（離開＝nil）；只在視窗有焦點時收
final class LiftTracker: NSResponder {
    var moved: (NSEvent?) -> Void = { _ in }
    override func mouseMoved(with e: NSEvent) { moved(e) }
    override func mouseEntered(with e: NSEvent) { moved(e) }
    override func mouseDragged(with e: NSEvent) { moved(e) }
    override func mouseExited(with e: NSEvent) { moved(nil) }
}

/// Orbit42 內建引擎，舊的 launchd 常駐程式不能同時跑（播報講兩次、權限卡兩邊搶、socket 打架）。
/// 開 Orbit42 時停掉它；11-26 起結束時不再把它開回來（引擎已內建，舊常駐程式停用）
enum AgentSwap {
    static let label = Legacy.launchAgent
    static var plist: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static func launchctl(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        do { try p.run() } catch { return NSLog("launchctl %@ 開不起來：%@", args.joined(separator: " "), "\(error)") }      // 記下來照常開：舊的 Orbit42Agent 可能還在
        p.waitUntilExit() }
    static func stop() { launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
}

/// 測試視窗（11-24 Keng「不要跟我搶螢幕」）：有標題列的視窗排上來時，系統會把它拉回最近的螢幕（第二螢幕在左邊就拉到那裡）⇒ 不准拉、點不到、不當主視窗。
/// 開在「正式 Orbit42 沒在用」的那個螢幕、排最後面；只有一個螢幕就透明放到螢幕外
final class HiddenTestWindow: NSWindow {
    static func freeScreen() -> NSScreen? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0, me = ProcessInfo.processInfo.processIdentifier
        let busy = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { w -> CGRect? in
            guard w[kCGWindowOwnerName as String] as? String == "Orbit42", w[kCGWindowOwnerPID as String] as? Int32 != me, w[kCGWindowLayer as String] as? Int == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return nil }
            return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
        }
        guard NSScreen.screens.count > 1, !busy.isEmpty else { return nil }
        return NSScreen.screens.first { s in !busy.contains { let i = $0.intersection(s.frame); return i.width > 1 && i.height > 1 } }
    }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }
    override func toggleFullScreen(_ sender: Any?) {}
    override func makeKeyAndOrderFront(_ sender: Any?) { orderBack(sender) }
    static var allowKey = false          // 只有 ORBIT_TEST_COPYPASTE=real 打開：要當 key window 才能走真的 ⌘C／⌘V（視窗還是在螢幕外）
    override var canBecomeKey: Bool { Self.allowKey }
    override var canBecomeMain: Bool { false }
}

Legacy.adoptEnv()                       // 11-26 改名：舊名環境變數照讀
Utf8Locale.applyToProcess()             // 11-28 沒有 UTF-8 語系就照系統偏好語言補上（貼上中文變 Big5 亂碼；18 國語言不寫死英文）
let orbitEnv = ProcessInfo.processInfo.environment
let orbitTest = orbitEnv["ORBIT_OFFSCREEN"] != nil
if orbitEnv["ORBIT_TEST_DISKS"] != nil { print(MainActor.assumeIsolated { DiskWatch.dump() }); exit(0) }
if let dir = orbitEnv["ORBIT_TEST_SECCHECK_SHOT"] { MainActor.assumeIsolated { SecCheckShot.run(dir) } }    // 11-28 資安體檢小視窗深淺色截圖
if !orbitTest {
    Legacy.migrateDefaults()            // 舊設定 suite 一次性複製到新 suite（讀回比對過才記做完）
    AgentSwap.stop()
}
MainActor.assumeIsolated {
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { ChromeBrowser.shared.quit(); OrbitWindow.shared.host.shutdown() }
    }
    EngineMain.run(AgentOptions(regularApp: !orbitTest, waitForAccessibility: false, testOnly: orbitTest,
                                      onLaunch: {
        OrbitWindow.shared.show(test: orbitTest)
        // 11-24 外接硬碟斷線偵測：等球體載好（8 秒）再開始，開機就慢速的那句才講得出來
        if !orbitTest { GuardPause.shared.start { OrbitWindow.shared.toast($0) } }
        DockIcon.shared.start()               // 11-24 Dock 圖示跟著深淺色換
        if !orbitTest { Gamepad.shared.start() }      // 11-27 PS4／PS5／Xbox 搖桿（Gamepad.swift）
        DiskWatch.shared.say = { OrbitWindow.shared.toast($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (orbitEnv["ORBIT_TEST_DISKWATCH"].flatMap(Double.init) ?? 8)) {
            MainActor.assumeIsolated { DiskWatch.shared.start() }
        }
    }))
}

/// Claude Code 有沒有這段對話的紀錄（~/.claude/projects/*/<sid>.jsonl）；沒有就不能 --resume
func hasTranscript(_ sid: String) -> Bool {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let subs = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return true }
    return subs.contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).appendingPathComponent(sid + ".jsonl").path) }
}
