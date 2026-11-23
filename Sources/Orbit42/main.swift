import AppKit
import WebKit
import ShoWorkApp

// Orbit42: the sphere is the home screen; every AI worker is a satellite with its own real terminal.
// Web UI (Web/index.html: three.js sphere + xterm.js) talks to this host through `webkit.messageHandlers.orbit`.
//
// Test hooks (window off-screen, never on the user's display):
//   ORBIT_OFFSCREEN=1  ORBIT_TEST_JS=<js run 1.5 s after load>  ORBIT_TEST_SHOT=<png> ORBIT_TEST_SHOT_DELAY=<s>  ORBIT_TEST_QUIT=1

@MainActor
final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let web: WKWebView
    private var sats: [String: Satellite] = [:]
    private var order: [String] = []
    private var counter: [Brain: Int] = [:]
    private var pending: [String: Data] = [:]
    private let pendLock = NSLock()
    private var flushTimer: Timer?
    private var tick: Timer?
    var onShow: (Bool) -> Void = { _ in }       // 終端機面板要顯示／收起（嵌在 Orbit42 主視窗右邊）

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // ES modules (three.js) don't load from file:// in WKWebView ⇒ serve Web/ through our own scheme
        if let dir = Self.webDir { cfg.setURLSchemeHandler(WebFiles(root: dir), forURLScheme: "orbit") }
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "orbit")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
    }

    func load(termOnly: Bool = false) {
        guard Self.webDir != nil else { return }
        web.load(URLRequest(url: URL(string: "orbit://app/index.html" + (termOnly ? "?term=1" : ""))!))
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pushSats() } }
    }

    static var webDir: URL? {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("OrbitWeb")) }   // Orbit42.app：Resources/OrbitWeb（Resources/Web 放 ShoWork 的球體網頁）
        c.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web"))
        return c.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    // MARK: web → host
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let a = m["action"] as? String else { return }
        let id = m["id"] as? String ?? ""
        let cols = m["cols"] as? Int ?? 100, rows = m["rows"] as? Int ?? 30
        switch a {
        case "ready": pushSats(); js("window.orbitBg", BackgroundSessions.list())
        case "new":
            let brain = Brain(rawValue: m["brain"] as? String ?? "claude") ?? .claude
            let n = (counter[brain] ?? 0) + 1; counter[brain] = n
            let cwd = (m["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            let s = Satellite(id: UUID().uuidString.prefix(8).lowercased(), name: "\(brain.label) \(n)", brain: brain, cwd: cwd, command: brain.command)
            add(s); js("window.orbitOpened", s.id); onShow(true)
        case "attach":
            guard let job = m["job"] as? String else { return }
            if let existing = sats.values.first(where: { $0.attachedJob == job }) { js("window.orbitOpened", existing.id); onShow(true); return }
            let s = Satellite(id: "bg-" + job, name: m["name"] as? String ?? job, brain: .claude, cwd: m["cwd"] as? String ?? NSHomeDirectory(),
                              command: "claude attach \(job)", attachedJob: job)
            add(s); js("window.orbitOpened", s.id); onShow(true)
        case "hide": onShow(false)
        case "open":
            guard let s = sats[id] else { return }
            if s.pty == nil || s.exited != nil { start(s, cols: cols, rows: rows) }
            else { js("window.orbitReplay", id, s.snapshot().base64EncodedString()); s.pty?.resize(cols: cols, rows: rows) }
        case "input":
            if let d = (m["data"] as? String)?.data(using: .utf8) { sats[id]?.pty?.write(d) }
        case "resize": sats[id]?.pty?.resize(cols: cols, rows: rows)
        case "remove":
            // Satellites Orbit42 started: hang up (like closing a terminal window).
            // Attached background sessions: only the viewer closes; the session keeps running.
            if let s = sats[id] { s.pty?.hangup(); sats[id] = nil; order.removeAll { $0 == id }; pushSats() }
        case "bgList": js("window.orbitBg", BackgroundSessions.list())
        default: break
        }
    }

    private func add(_ s: Satellite) { sats[s.id] = s; order.append(s.id); pushSats() }

    /// 登入／安裝：在終端機面板跑那一家的官方指令（結束後回呼，讓登入畫面重查狀態）
    var onExited: (String) -> Void = { _ in }
    func runCommand(name: String, brain: Brain, command: String) {
        let s = Satellite(id: "cmd-" + UUID().uuidString.prefix(6).lowercased(), name: name, brain: brain, cwd: NSHomeDirectory(), command: command)
        add(s); js("window.orbitOpened", s.id); onShow(true)
    }

    // MARK: 球體（ShoWork 完整球體）→ 這裡
    /// ＋ 新衛星
    func newSatellite(_ brain: String) {
        userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "new", "brain": brain]))
    }
    /// 點到球上的衛星：Orbit42 開的（終端機是我們的）就打開它；背景 session 就 attach 進來看；其他回 false（照舊跳 Ghostty）
    func open(_ ref: SphereEmbed.SessionRef) -> Bool {
        if let s = sats.values.first(where: { sat in sat.pty.map { $0.pid == ref.pid || Self.parent(of: ref.pid) == $0.pid } ?? false }) {
            js("window.orbitOpened", s.id); onShow(true); return true
        }
        if ref.kind == "bg", let job = ref.jobId {
            userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "attach", "job": job, "name": ref.name, "cwd": ref.cwd ?? NSHomeDirectory()]))
            return true
        }
        return false
    }
    nonisolated static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private func start(_ s: Satellite, cols: Int, rows: Int) {
        s.exited = nil
        guard let p = Pty(command: s.command, cwd: s.cwd, cols: cols, rows: rows) else {
            js("window.orbitData", s.id, Data("\r\n[Orbit42] could not start a terminal\r\n".utf8).base64EncodedString()); return
        }
        let id = s.id
        p.onData = { [weak self, weak s] d in
            s?.append(d)
            guard let self else { return }
            self.pendLock.lock(); self.pending[id, default: Data()].append(d); self.pendLock.unlock()
        }
        p.onExit = { [weak self] code in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let s = self.sats[id] else { return }
                s.exited = code; s.pty = nil
                self.flush(); self.js("window.orbitExit", id, Int(code)); self.pushSats(); self.onExited(id)
            } }
        }
        s.pty = p
        pushSats()
    }

    private func flush() {
        pendLock.lock(); let out = pending; pending = [:]; pendLock.unlock()
        for (id, d) in out where !d.isEmpty { js("window.orbitData", id, d.base64EncodedString()) }
    }

    private func pushSats() { js("window.orbitSats", order.compactMap { sats[$0]?.json }) }

    func js(_ fn: String, _ args: Any...) {
        guard let d = try? JSONSerialization.data(withJSONObject: args) else { return }
        web.evaluateJavaScript("\(fn) && \(fn)(...\(String(decoding: d, as: UTF8.self)))")
    }

    // MARK: test hooks
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        let env = ProcessInfo.processInfo.environment
        if let code = env["ORBIT_TEST_JS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.web.evaluateJavaScript(code) }
        }
        if let out = env["ORBIT_TEST_SHOT"] {
            let delay = Double(env["ORBIT_TEST_SHOT_DELAY"] ?? "8") ?? 8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.web.takeSnapshot(with: nil) { img, _ in
                    if let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out))
                        self?.web.evaluateJavaScript("document.title") { t, _ in print("orbit shot saved \(out) \(t ?? "")"); fflush(stdout) }
                    }
                    if env["ORBIT_TEST_QUIT"] != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.shutdown(); NSApp.terminate(nil) } }
                    }
                }
            }
        }
    }

    func shutdown() { for s in sats.values { s.pty?.hangup() } }
}

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

/// WKUserContentController keeps a strong reference to its handlers.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(u, didReceive: m) }
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
        default: break
        }
    }
}

/// Orbit42 主視窗：整個 ShoWork 球體（播報、空白鍵講話、量表、自檢、cool42…）＋右邊滑出的衛星終端機
@MainActor
final class OrbitWindow: NSObject, NSWindowDelegate {
    static let shared = OrbitWindow()
    var window: NSWindow!
    let host = Host()
    let login = LoginPanel()
    private var sphereView: NSView?
    private var termWidth: CGFloat { max(420, (window.contentView?.bounds.width ?? 1200) * 0.56) }
    private var termShown = false

    func show(test: Bool) {
        let env = ProcessInfo.processInfo.environment
        let size = NSSize(width: Double(env["ORBIT_TEST_W"] ?? "") ?? 1440, height: Double(env["ORBIT_TEST_H"] ?? "") ?? 900)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Orbit42"
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        window.contentView = root
        let sphere = SphereEmbed.makeView()
        sphere.frame = root.bounds; sphere.autoresizingMask = [.width, .height]
        root.addSubview(sphere); sphereView = sphere
        // 登入畫面蓋在球體上面（終端機面板再蓋在登入畫面上面：登入指令要看得到）
        login.web.frame = root.bounds; login.web.autoresizingMask = [.width, .height]
        root.addSubview(login.web)
        login.runInTerminal = { [weak self] name, brain, cmd in self?.host.runCommand(name: name, brain: brain, command: cmd) }
        login.onEnter = { [weak self] list in self?.enter(list) }
        host.onExited = { [weak self] _ in self?.login.check() }
        host.web.autoresizingMask = [.height, .minXMargin]
        host.web.isHidden = true
        root.addSubview(host.web)
        layoutTerm()
        host.onShow = { [weak self] on in self?.setTerm(on) }
        host.load(termOnly: true)
        SphereEmbed.openSession = { [weak self] ref in self?.host.open(ref) ?? false }
        SphereEmbed.command = { [weak self] cmd in if cmd == "fullscreen" { self?.window.toggleFullScreen(nil) } }
        // ⌃⌘F：全螢幕桌面模式切換（macOS 標準快捷鍵）
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command], e.charactersIgnoringModifiers?.lowercased() == "f" {
                self?.window.toggleFullScreen(nil); return nil
            }
            return e
        }
        SphereEmbed.newSatellite = { [weak self] brain in brain == "accounts" ? self?.showLogin() : self?.host.newSatellite(brain) }
        if let out = env["ORBIT_TEST_LOGIN_SHOT"] {        // 測試：登入畫面截圖（等狀態查完）
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.login.web.takeSnapshot(with: nil) { img, _ in
                    if let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out)); print("login shot saved \(out)"); fflush(stdout)
                    }
                    if env["ORBIT_TEST_QUIT"] != nil { NSApp.terminate(nil) }
                }
            }
        }
        if test {
            window.setFrameOrigin(NSPoint(x: -6000, y: -6000)); window.orderBack(nil)
        } else {
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            // 11-23 Keng：Orbit42 像系統一樣佔滿整個畫面（全螢幕桌面模式，預設開；切掉會記住）
            if UserDefaults.standard.object(forKey: "orbit.desktop") as? Bool ?? true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.window.toggleFullScreen(nil) }
            }
        }
    }

    // 全螢幕時 Dock、選單列自動藏起來（滑到邊緣才出現），整個畫面就是 Orbit42
    func window(_ w: NSWindow, willUseFullScreenPresentationOptions o: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideDock, .autoHideMenuBar, .autoHideToolbar]
    }
    func windowDidEnterFullScreen(_ n: Notification) { UserDefaults.standard.set(true, forKey: "orbit.desktop"); layoutTerm() }
    func windowDidExitFullScreen(_ n: Notification) { UserDefaults.standard.set(false, forKey: "orbit.desktop"); layoutTerm() }

    /// 進入：收起登入畫面，球體的「＋ 新衛星」只列登入過的大腦
    func enter(_ list: [Provider]) {
        login.web.isHidden = true
        setTerm(false)
        let ids = list.filter(\.signedIn).map(\.id)
        if let d = try? JSONSerialization.data(withJSONObject: ids), let w = sphereView as? WKWebView {
            w.evaluateJavaScript("window.orbitBrains && window.orbitBrains(\(String(decoding: d, as: UTF8.self)))")
        }
    }
    func showLogin() { login.web.isHidden = false; login.check() }

    private func layoutTerm() {
        guard let root = window.contentView else { return }
        let w = termWidth
        host.web.frame = NSRect(x: root.bounds.width - w, y: 0, width: w, height: root.bounds.height - 28)
    }
    func setTerm(_ on: Bool) {
        termShown = on; layoutTerm(); host.web.isHidden = !on
        if on { window.makeFirstResponder(host.web) }
    }
    func windowDidResize(_ n: Notification) { layoutTerm() }
    func windowWillClose(_ n: Notification) { host.shutdown(); NSApp.terminate(nil) }
}

/// Orbit42 取代 ShoWorkAgent：兩個不能同時跑（播報講兩次、權限卡兩邊搶、socket 打架）。
/// 開 Orbit42 時先停掉 launchd 的 ShoWorkAgent，結束時再把它開回來。
enum AgentSwap {
    static let label = "ai.okle42.showork.agent"
    static var plist: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static func launchctl(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args; try? p.run(); p.waitUntilExit() }
    static func stop() { launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
    static func start() { if FileManager.default.fileExists(atPath: plist) { launchctl(["bootstrap", "gui/\(getuid())", plist]) } }
}

let orbitEnv = ProcessInfo.processInfo.environment
let orbitTest = orbitEnv["ORBIT_OFFSCREEN"] != nil
if !orbitTest {
    AgentSwap.stop()
    atexit { AgentSwap.start() }
}
MainActor.assumeIsolated {
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { OrbitWindow.shared.host.shutdown() }
    }
    ShoWorkAgentMain.run(AgentOptions(regularApp: !orbitTest, waitForAccessibility: false, testOnly: orbitTest,
                                      onLaunch: { OrbitWindow.shared.show(test: orbitTest) }))
}
