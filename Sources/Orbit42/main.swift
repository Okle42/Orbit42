import AppKit
import WebKit
import ShoWorkApp
import ShoWorkCore

// Orbit42: the sphere is the home screen; every AI worker is a satellite with its own real terminal.
// Web UI (Web/index.html: three.js sphere + xterm.js) talks to this host through `webkit.messageHandlers.orbit`.
//
// Test hooks (window off-screen, never on the user's display):
//   ORBIT_OFFSCREEN=1  ORBIT_TEST_JS=<js run 1.5 s after load>  ORBIT_TEST_SHOT=<png> ORBIT_TEST_SHOT_DELAY=<s>  ORBIT_TEST_QUIT=1

@MainActor
final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    // 11-23 Keng「衛星終端機只能開一個視窗，要能開多個、重疊、移動」：
    // 每顆衛星自己一個網頁視圖（index.html?term=1&sat=<id>），各自裝在自己的小視窗裡
    private(set) var views: [String: DropWebView] = [:]
    private let files: WebFiles? = Host.webDir.map { WebFiles(root: $0) }
    private var sats: [String: Satellite] = [:]
    private var order: [String] = []
    private var counter: [Brain: Int] = [:]
    private var pending: [String: Data] = [:]
    private let pendLock = NSLock()
    private var flushTimer: Timer?
    private var tick: Timer?
    var theme = "dark"
    var onOpen: (String) -> Void = { _ in }          // 打開這顆衛星的小視窗（已經開著就叫到最上面）
    var onHide: (String) -> Void = { _ in }          // 收起這顆衛星的小視窗
    var onRemoved: (String) -> Void = { _ in }       // 衛星結束：關掉它的小視窗
    var onBusy: (String, Bool) -> Void = { _, _ in } // 衛星有沒有在工作（小視窗呼吸光）
    private var testView: WKWebView?                 // 測試 hooks 只作用在第一個打開的衛星

    /// 拖檔案進來：路徑打進那顆衛星（跟手打一樣）
    func type(_ id: String, _ text: String) {
        guard let d = text.data(using: .utf8) else { return }
        sats[id]?.pty?.write(d)
    }
    /// 紅燈：結束這顆衛星（Orbit42 開的會關；背景 session 只關檢視）
    func end(_ id: String) {
        guard let s = sats[id] else { onRemoved(id); return }
        s.pty?.hangup(); sats[id] = nil; order.removeAll { $0 == id }; views[id] = nil
        onRemoved(id); pushSats()
    }
    func title(_ id: String) -> String {
        guard let s = sats[id] else { return id }
        return "\(s.name) · \(s.brain.label)\(s.attachedJob != nil ? " · 背景 session" : "")"
    }

    /// 這顆衛星的終端機網頁（第一次要才建）
    func view(for id: String) -> DropWebView {
        if let v = views[id] { return v }
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // ES modules don't load from file:// in WKWebView ⇒ serve Web/ through our own scheme
        if let files { cfg.setURLSchemeHandler(files, forURLScheme: "orbit") }
        cfg.userContentController.add(WeakHandler(self), name: "orbit")
        let v = DropWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = self
        v.setValue(false, forKey: "drawsBackground")
        var u = URLComponents(string: "orbit://app/index.html")!
        u.queryItems = [URLQueryItem(name: "term", value: "1"), URLQueryItem(name: "sat", value: id), URLQueryItem(name: "theme", value: theme)]
        v.load(URLRequest(url: u.url!))
        views[id] = v
        return v
    }

    func startTimers() {
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
        let from = message.webView.flatMap { w in views.first { $0.value === w }?.key }      // 哪顆衛星的視窗送來的
        let id = m["id"] as? String ?? from ?? ""
        let cols = m["cols"] as? Int ?? 100, rows = m["rows"] as? Int ?? 30
        switch a {
        case "ready":
            guard let from, let v = views[from] else { return }
            Self.call(v, "window.orbitSats", [order.compactMap { sats[$0]?.json }])
            Self.call(v, "window.orbitOpened", [from])
        case "new":
            let brain = Brain(rawValue: m["brain"] as? String ?? "claude") ?? .claude
            let n = (counter[brain] ?? 0) + 1; counter[brain] = n
            let cwd = (m["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            let s = Satellite(id: UUID().uuidString.prefix(8).lowercased(), name: "\(brain.label) \(n)", brain: brain, cwd: cwd, command: brain.command)
            add(s); onOpen(s.id)
        case "attach":
            guard let job = m["job"] as? String else { return }
            if let existing = sats.values.first(where: { $0.attachedJob == job }) { onOpen(existing.id); return }
            let s = Satellite(id: "bg-" + job, name: m["name"] as? String ?? job, brain: .claude, cwd: m["cwd"] as? String ?? NSHomeDirectory(),
                              command: "claude attach \(job)", attachedJob: job)
            add(s); onOpen(s.id)
        case "hide": if let from { onHide(from) }
        case "open":
            guard let s = sats[id] else { return }
            if s.pty == nil || s.exited != nil { start(s, cols: cols, rows: rows) }
            else { if let v = views[id] { Self.call(v, "window.orbitReplay", [id, s.snapshot().base64EncodedString()]) }; s.pty?.resize(cols: cols, rows: rows) }
        case "input":
            if let d = (m["data"] as? String)?.data(using: .utf8) { sats[id]?.pty?.write(d) }
        case "resize": sats[id]?.pty?.resize(cols: cols, rows: rows); if ProcessInfo.processInfo.environment["ORBIT_TEST_DRAG"] != nil { print("resize \(id) \(cols)x\(rows) pty=\(sats[id]?.pty != nil)"); fflush(stdout) }
        case "remove":
            // Satellites Orbit42 started: hang up (like closing a terminal window).
            // Attached background sessions: only the viewer closes; the session keeps running.
            end(id)
        default: break
        }
    }

    private func add(_ s: Satellite) { sats[s.id] = s; order.append(s.id); pushSats() }

    /// 登入／安裝：開一個終端機小視窗跑那一家的官方指令（結束後回呼，讓登入畫面重查狀態）
    var onExited: (String) -> Void = { _ in }
    @discardableResult
    func runCommand(name: String, brain: Brain, command: String) -> String {
        let s = Satellite(id: "cmd-" + UUID().uuidString.prefix(6).lowercased(), name: name, brain: brain, cwd: NSHomeDirectory(), command: command)
        add(s); onOpen(s.id); return s.id
    }

    // MARK: 球體（ShoWork 完整球體）→ 這裡
    /// ＋ 新衛星
    func newSatellite(_ brain: String) {
        userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "new", "brain": brain]))
    }
    /// 點到球上的衛星：Orbit42 開的（終端機是我們的）就打開它；背景 session 就 attach 進來看；其他回 false（照舊跳 Ghostty）
    func open(_ ref: SphereEmbed.SessionRef) -> Bool {
        if let s = sats.values.first(where: { sat in sat.pty.map { $0.pid == ref.pid || Self.parent(of: ref.pid) == $0.pid } ?? false }) {
            onOpen(s.id); return true
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
        // 淺色／深色先用環境變數告訴終端機程式（COLORFGBG：前景;背景，15＝白、0＝黑），有些程式只看這個
        let dark = theme != "light"
        guard let p = Pty(command: s.command, cwd: s.cwd, cols: cols, rows: rows, env: ["COLORFGBG": dark ? "15;0" : "0;15"]) else {
            if let v = views[s.id] { Self.call(v, "window.orbitData", [s.id, Data("\r\n[Orbit42] could not start a terminal\r\n".utf8).base64EncodedString()]) }
            return
        }
        let id = s.id
        let rawPath = ProcessInfo.processInfo.environment["ORBIT_TEST_RAW"]
        if let r = rawPath { FileManager.default.createFile(atPath: r, contents: nil) }
        let rawLog = rawPath.flatMap { FileHandle(forWritingAtPath: $0) }
        p.onData = { [weak self, weak s] d in
            rawLog?.write(d)                 // 測試：錄下終端機收到的原始輸出（查顏色碼）
            s?.append(d)
            guard let self else { return }
            self.pendLock.lock(); self.pending[id, default: Data()].append(d); self.pendLock.unlock()
        }
        p.onExit = { [weak self] code in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let s = self.sats[id] else { return }
                s.exited = code; s.pty = nil
                self.flush(); if let v = self.views[id] { Self.call(v, "window.orbitExit", [id, Int(code)]) }
                self.pushSats(); self.onExited(id)
            } }
        }
        s.pty = p
        pushSats()
    }

    private func flush() {
        pendLock.lock(); let out = pending; pending = [:]; pendLock.unlock()
        for (id, d) in out where !d.isEmpty { if let v = views[id] { Self.call(v, "window.orbitData", [id, d.base64EncodedString()]) } }
    }

    private func pushSats() {
        let list = order.compactMap { sats[$0]?.json }
        for v in views.values { Self.call(v, "window.orbitSats", [list]) }
        for (id, s) in sats { onBusy(id, s.exited == nil && Date().timeIntervalSince(s.lastOutput) < 2.5) }
    }

    /// 所有衛星視窗都呼叫（例如換深淺）
    func js(_ fn: String, _ args: Any...) { for v in views.values { Self.call(v, fn, args) } }
    static func call(_ v: WKWebView, _ fn: String, _ args: [Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: args) else { return }
        v.evaluateJavaScript("\(fn) && \(fn)(...\(String(decoding: d, as: UTF8.self)))")
    }

    // MARK: test hooks（只作用在第一個打開的衛星視窗）
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if testView == nil { testView = w }
        guard testView === w else { return }
        let env = ProcessInfo.processInfo.environment
        if let code = env["ORBIT_TEST_JS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { w.evaluateJavaScript(code) }
        }
        if let out = env["ORBIT_TEST_SHOT"] {
            let delay = Double(env["ORBIT_TEST_SHOT_DELAY"] ?? "8") ?? 8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                w.takeSnapshot(with: nil) { img, _ in
                    if let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out))
                        w.evaluateJavaScript("document.title") { t, _ in print("orbit shot saved \(out) \(t ?? "")"); fflush(stdout) }
                    }
                    if env["ORBIT_TEST_QUIT"] != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.shutdown(); NSApp.terminate(nil) } }
                    }
                }
            }
        }
    }

    // MARK: 重開後衛星回來（11-23 Keng「重開前有兩個衛星，重開後只剩一個」）
    // 關掉 Orbit42 時把自己開的衛星記下來（Claude 記 session id，重開用 --resume 接回同一段對話；背景 session 記 job 重新 attach），
    // 下次打開就照原樣開回來，像 macOS 重開機恢復視窗。登入／安裝用的臨時視窗（cmd-）不記。
    // 測試：ORBIT_TEST_RESTORE=save／load ⇒ 用另一個紀錄名稱（不碰真正的），load 時 3 秒後直接恢復
    static var restoreKey: String { ProcessInfo.processInfo.environment["ORBIT_TEST_RESTORE"] != nil ? "orbit.restore.test" : "orbit.restore" }
    static var restoreBlocked: Bool { let e = ProcessInfo.processInfo.environment; return e["ORBIT_OFFSCREEN"] != nil && e["ORBIT_TEST_RESTORE"] == nil }
    private func saveForRestore() {
        if Self.restoreBlocked { return }      // 測試不碰真正的紀錄
        let dir = NSHomeDirectory() + "/.claude/sessions", fm = FileManager.default
        let recs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }
            .compactMap { fm.contents(atPath: dir + "/" + $0).flatMap(SessionRecord.decode) }
        var out: [[String: String]] = []
        for id in order {
            guard let s = sats[id], !id.hasPrefix("cmd-"), s.exited == nil else { continue }
            if let job = s.attachedJob { out.append(["job": job, "name": s.name, "cwd": s.cwd]); continue }
            guard let p = s.pty else { continue }
            var e = ["brain": s.brain.rawValue, "name": s.name, "cwd": s.cwd]
            if s.brain == .claude, let r = recs.first(where: { $0.pid == p.pid || Self.parent(of: $0.pid) == p.pid }) { e["sid"] = r.sessionId; e["cwd"] = r.cwd }
            out.append(e)
        }
        if let d = try? JSONSerialization.data(withJSONObject: out) { UserDefaults.standard.set(String(decoding: d, as: UTF8.self), forKey: Self.restoreKey) }
    }
    /// 打開 Orbit42 時：把上次關掉時開著的衛星開回來（開完就清掉紀錄，下次關掉再記）
    func restore() {
        if Self.restoreBlocked { return }
        guard let str = UserDefaults.standard.string(forKey: Self.restoreKey), let d = str.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String: String]], !list.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.restoreKey)
        for e in list {
            let cwd = e["cwd"] ?? NSHomeDirectory()
            if let job = e["job"] {
                userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "attach", "job": job, "name": e["name"] ?? job, "cwd": cwd]))
                continue
            }
            let brain = Brain(rawValue: e["brain"] ?? "claude") ?? .claude
            let name = e["name"] ?? brain.label
            if let n = Int(name.split(separator: " ").last ?? ""), n > (counter[brain] ?? 0) { counter[brain] = n }
            let cmd = brain == .claude && e["sid"] != nil ? brain.command + " --resume " + e["sid"]! : brain.command
            let s = Satellite(id: UUID().uuidString.prefix(8).lowercased(), name: name, brain: brain, cwd: cwd, command: cmd)
            add(s); onOpen(s.id)
        }
    }

    func shutdown() { saveForRestore(); for s in sats.values { s.pty?.hangup() } }
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
    private var askTimer: Timer?
    private var webWatch: Timer?
    /// 11-23 Keng「Orbit42 改檔自動重新載入，免重開」：每秒看球體頁（Web/sphere.html，SHOWORK_WEB_DIR 優先）的修改時間，
    /// 變了且連續 2 次一樣（檔案寫完）才 reload 球體 WebView；資料下一秒由宿主重推，版面在 localStorage。衛星終端機不動。
    private func watchSphereFile() {
        let env = ProcessInfo.processInfo.environment
        let dir = env["SHOWORK_WEB_DIR"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL?.appendingPathComponent("Web")
        guard let file = dir?.appendingPathComponent("sphere.html").path else { return }
        let mtime = { (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? nil }
        var loaded = mtime(), seen = loaded
        webWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = mtime()
                defer { seen = now }
                guard let now, now != loaded, now == seen, let web = self?.sphereView as? WKWebView else { return }
                loaded = now
                print("orbit: sphere.html changed, reloading"); fflush(stdout)
                web.reload()
            }
        }
    }
    /// 11-23 Keng「4 選項答案卡跳出來應該在終端機上方，它要幫我們加速工作流程」：衛星小視窗是原生 view、蓋在球體網頁上，
    /// 網頁的 z-index 管不到 ⇒ 每 0.3 秒問球體答案卡（＋送出後的「復原」提示）在哪，蓋到它的衛星整個淡出、點擊穿過去；答完恢復
    private func watchAskCard() {
        let js = """
        (() => { const r = []; for (const id of ["askCard", "askUndo", "askDot"]) { const e = document.getElementById(id);
          if (!e || !e.classList.contains("on")) continue; const b = e.getBoundingClientRect();
          if (b.width && b.height) r.push([b.left, b.top, b.width, b.height]); } return JSON.stringify(r); })()
        """
        askTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let web = self.sphereView as? WKWebView, !web.isHidden else { return }
                web.evaluateJavaScript(js) { [weak self] r, _ in
                    MainActor.assumeIsolated {
                        guard let self, let root = self.window.contentView, let s = r as? String, let d = s.data(using: .utf8),
                              let arr = try? JSONSerialization.jsonObject(with: d) as? [[Double]] else { return }
                        let H = root.bounds.height
                        let rects = arr.filter { $0.count == 4 }.map { NSRect(x: $0[0], y: H - $0[1] - $0[3], width: $0[2], height: $0[3]).insetBy(dx: -10, dy: -10) }
                        for case let w as TermWindowView in root.subviews where !w.isHidden && w.wantShown {
                            let y = rects.contains { $0.intersects(w.frame) }
                            guard y != w.yieldingToAsk else { continue }
                            w.yieldingToAsk = y
                            NSAnimationContext.runAnimationGroup { ctx in
                                ctx.duration = 0.25; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                                w.animator().alphaValue = y ? 0 : 1          // 11-23 Keng「答案卡太透明會看到底下的字」⇒ 整個淡出（原 12%）
                            }
                        }
                    }
                }
            }
        }
    }
    /// 11-23 Keng：每顆衛星一個終端機小視窗，可以同時開好幾個、重疊、各自拖動；點哪個哪個到最上面
    private var satWins: [String: TermWindowView] = [:]
    private var zTop: CGFloat = 10
    /// 最上面那個開著的衛星小視窗（測試 hooks 用）
    private var frontSat: TermWindowView? {
        satWins.values.filter { !$0.isHidden }.max { ($0.layer?.zPosition ?? 0) < ($1.layer?.zPosition ?? 0) }
    }

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
        sphere.wantsLayer = true; sphere.layer?.zPosition = 0
        // 登入畫面蓋在球體上面（終端機面板再蓋在登入畫面上面：登入指令要看得到）
        login.web.frame = root.bounds; login.web.autoresizingMask = [.width, .height]
        // 11-23 修：疊放順序固定＝球體（最底）→ 登入畫面 → 終端機小視窗（最上）。之前登入畫面放到最底層，
        // 球體載入後把它整個蓋住（按「帳號⋯」只看到球淡出、登入頁出不來）
        root.addSubview(login.web, positioned: .above, relativeTo: sphere)      // 終端機小視窗在下面最後才加，自然在最上層
        login.web.wantsLayer = true; login.web.layer?.zPosition = 1               // 小視窗從 10 起跳，點到的再往上（raise）
        login.runInTerminal = { [weak self] name, brain, cmd in self?.host.runCommand(name: name, brain: brain, command: cmd) }
        login.onEnter = { [weak self] list in self?.enter(list) }
        host.onExited = { [weak self] _ in self?.login.check() }
        // 衛星終端機＝每顆衛星一個可以拖、可以調大小的小視窗（左上紅灰白三顆燈），可以同時開好幾個
        host.theme = themeNow
        host.onOpen = { [weak self] id in self?.showSat(id) }
        host.onHide = { [weak self] id in guard let self, let w = self.satWins[id] else { return }; self.animate(w, on: false) }
        host.onRemoved = { [weak self] id in self?.closeSat(id) }
        host.onBusy = { [weak self] id, busy in guard let w = self?.satWins[id], !w.isHidden else { return }; w.setBreathing(busy) }
        host.startTimers()
        if ProcessInfo.processInfo.environment["ORBIT_TEST_RESTORE"] == "load" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated { self?.host.restore() } }
        }
        // 點到哪個小視窗（標題列或終端機內容都算），那個就疊到最上面
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in self?.raiseUnder(e); return e }
        SphereEmbed.openSession = { [weak self] ref in
            guard let self else { return false }
            if ref.kind == "board" { return self.showBoard(sid: ref.sessionId, cwd: ref.cwd, name: ref.name) }       // 隊長這類（引擎持有）：衛星外框＋對話內容
            return self.host.open(ref)
        }
        SphereEmbed.command = { [weak self] cmd in
            if cmd == "fullscreen" { self?.window.toggleFullScreen(nil) }
            if cmd.hasPrefix("theme:") { self?.applyTheme(String(cmd.dropFirst(6))) }
            if cmd.hasPrefix("arrangeSats") {          // "arrangeSats:x,y,w,h"＝球體量好的空位（網頁座標，左上原點）
                let v = cmd.split(separator: ":").dropFirst().first?.split(separator: ",").compactMap { Double($0) } ?? []
                self?.arrangeSats(in: v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil)
            }
        }
        watchAskCard(); watchSphereFile()
        // ⌃⌘F：全螢幕桌面模式切換（macOS 標準快捷鍵）
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command], e.charactersIgnoringModifiers?.lowercased() == "f" {
                self?.window.toggleFullScreen(nil); return nil
            }
            return e
        }
        SphereEmbed.newSatellite = { [weak self] brain in brain == "accounts" ? self?.showLogin() : self?.host.newSatellite(brain) }
        if let out = env["ORBIT_TEST_TERM_SHOT"] {         // 測試：終端機小視窗（原生標題列＋三顆燈）截圖
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["ORBIT_TEST_TERM_SHOT_DELAY"] ?? "") ?? 16)) { [weak self] in
                guard let v = self?.frontSat, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)); print("term shot saved \(out) \(v.frame)"); fflush(stdout)
            }
        }
        // 測試：模擬拖右下角「縮小→停→放大→停」，每段停下後把終端機內容倒到 <prefix>_1.txt／_2.txt（查調大小錯位）
        // ORBIT_TEST_DRAG="<prefix>@<開始秒數>"
        if let spec = env["ORBIT_TEST_DRAG"], let at = spec.split(separator: "@").last.flatMap({ Double($0) }) {
            let prefix = String(spec.split(separator: "@").first ?? "/tmp/drag")
            func dump(_ n: Int) {
                (frontSat?.content as? WKWebView)?.evaluateJavaScript("window.orbitTest.screen()") { r, _ in
                    try? ((r as? String) ?? "").write(toFile: "\(prefix)_\(n).txt", atomically: true, encoding: .utf8); print("drag dump \(n)"); fflush(stdout)
                }
            }
            func steps(_ k: Int, _ dx: CGFloat, _ dy: CGFloat, then: @escaping () -> Void) {
                guard k > 0 else { then(); return }
                frontSat?.resizeBy(dx: dx, dy: dy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { MainActor.assumeIsolated { steps(k - 1, dx, dy, then: then) } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in MainActor.assumeIsolated {
                guard self != nil else { return }
                dump(0)
                steps(40, -6, 4) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated {
                        dump(1)
                        steps(40, 6, -4) { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { dump(2) } } }
                    } }
                }
            } }
        }
        // 測試：ORBIT_TEST_BOARD="<sessionId>@<截圖路徑>" ⇒ 10 秒後打開那個戰情中心 session 的小視窗，6 秒後截它
        if let spec = env["ORBIT_TEST_BOARD"], let at = spec.firstIndex(of: "@") {
            let sid = String(spec[..<at]), out = String(spec[spec.index(after: at)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }
                if let th = env["ORBIT_TEST_THEME"] { self.applyTheme(th) }
                print("board open \(self.showBoard(sid: sid, cwd: NSHomeDirectory(), name: "隊長"))"); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated {
                    guard let v = self.boards[sid], let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)); print("board shot saved"); fflush(stdout)
                } }
            } }
        }
        // 測試：ORBIT_TEST_ARRANGE=<秒數> ⇒ 幾秒後執行「衛星斜對角排開」（跟球體按自動排版一樣）
        if let t = env["ORBIT_TEST_ARRANGE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in MainActor.assumeIsolated { self?.arrangeSats(in: CGRect(x: 340, y: 60, width: 760, height: 640)) } }
        }
        // 測試：ORBIT_TEST_SEQ=1 ⇒ 開 3 個衛星 → 印位置 → 開第 4 個 → 印 → 關掉第 2 個 → 印（查開／關後自動斜對角重排）
        if env["ORBIT_TEST_SEQ"] != nil {
            func dump(_ tag: String) {
                let ws = (self.window.contentView?.subviews ?? []).compactMap { $0 as? TermWindowView }.filter { !$0.isHidden && $0.wantShown }.sorted { $0.seq < $1.seq }
                print("seq \(tag): " + ws.map { "#\($0.seq) \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: " | ")); fflush(stdout)
            }
            var ids: [String] = []
            let run = { (i: Int) -> String in self.host.runCommand(name: "測試 \(i)", brain: .claude, command: "printf '衛星 \(i)\\n'; sleep 60") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { ids = (1...3).map(run) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 11) { MainActor.assumeIsolated { dump("3 個"); ids.append(run(4)) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { MainActor.assumeIsolated { dump("開第 4 個"); self.host.end(ids[1]) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 19) { MainActor.assumeIsolated { dump("關掉第 2 個"); NSApp.terminate(nil) } }
        }
        // 測試：ORBIT_TEST_MULTI="<個數>@<輸出前綴>" ⇒ 開好幾個跑簡單指令的衛星，印出各小視窗位置／疊放順序，
        // 點最底下那個（模擬滑鼠）看它有沒有疊到最上面，再把每個終端機內容倒到 <前綴>_<i>.txt
        if let spec = env["ORBIT_TEST_MULTI"], let at = spec.firstIndex(of: "@"), let n = Int(spec[..<at]) {
            let prefix = String(spec[spec.index(after: at)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }
                let ids = (1...n).map { i in self.host.runCommand(name: "測試 \(i)", brain: .claude, command: "printf '我是衛星 \(i)\\n'; sleep 60") }
                @MainActor func order() -> String { self.window.contentView!.subviews.compactMap { v in ids.firstIndex { self.satWins[$0] === v }.map { "\($0 + 1)" } }.joined(separator: ",") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated {
                    for (i, id) in ids.enumerated() { let w = self.satWins[id]!; print("multi win \(i + 1) frame=\(w.frame) hidden=\(w.isHidden) z=\(w.layer?.zPosition ?? -1)") }
                    print("multi order(bottom→top)=\(order())")
                    let w1 = self.satWins[ids[0]]!
                    let p = self.window.contentView!.convert(NSPoint(x: w1.frame.minX + 10, y: w1.frame.minY + 10), to: nil)
                    if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { self.raiseUnder(e) }
                    print("multi order after click 1=\(order())"); fflush(stdout)
                    var left = n
                    for (i, id) in ids.enumerated() {
                        (self.satWins[id]?.content as? WKWebView)?.evaluateJavaScript("window.orbitTest.screen()") { r, _ in
                            try? ((r as? String) ?? "").write(toFile: "\(prefix)_\(i + 1).txt", atomically: true, encoding: .utf8)
                            left -= 1; if left == 0 { print("multi dumped"); fflush(stdout); if env["ORBIT_TEST_QUIT"] != nil { self.host.shutdown(); NSApp.terminate(nil) } }
                        }
                    }
                } }
            } }
        }
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

    /// 11-23 Keng：球體切深淺（◐）時，衛星終端機（xterm 色票＋裡面的 Claude Code）和小視窗標題列一起換
    // MARK: 戰情中心持有的 session（kind board，例如隊長）
    // 11-23 T1123115042 Keng：點戰情列表的 board 跳出舊的「工作視窗」⇒ 改開在跟衛星終端機一樣的小視窗（毛玻璃、紅光、三顆燈），
    // 內容是工作視窗那份網頁（黑白灰紅、透明底）。這類 session 是引擎用 claude -p 跑的，不是終端機程式，所以不是 xterm
    private var boards: [String: TermWindowView] = [:]
    private var themeNow = "dark"
    func showBoard(sid: String, cwd: String?, name: String) -> Bool {
        guard let root = window.contentView else { return false }
        if let w = boards[sid] {
            w.isHidden = false; raise(w); w.flash(); return true
        }
        guard let content = SphereEmbed.workView(sessionId: sid, cwd: cwd, theme: themeNow) else { return false }
        let w = TermWindowView(content: content)
        w.titleLabel.stringValue = "\(name) · Claude · 戰情中心 session"
        w.appearance = NSAppearance(named: themeNow == "light" ? .aqua : .darkAqua)
        var f = w.restoredFrame(in: root.bounds).offsetBy(dx: -36, dy: -28)
        f = TermWindowView.fit(f, in: root.bounds)
        w.frame = f
        w.onClose = { [weak self, weak w] in SphereEmbed.closeWorkView(sessionId: sid); w?.removeFromSuperview(); self?.boards[sid] = nil }
        w.onMinimize = { [weak w] in w?.isHidden = true }
        root.addSubview(w); raise(w)
        boards[sid] = w
        w.flash()
        return true
    }

    func applyTheme(_ name: String) {
        themeNow = name == "light" ? "light" : "dark"
        SphereEmbed.workTheme(themeNow)
        for w in boards.values { w.appearance = NSAppearance(named: themeNow == "light" ? .aqua : .darkAqua) }
        let dark = name != "light"
        let ap = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.appearance = ap
        for w in satWins.values { w.appearance = ap }
        host.theme = themeNow
        host.js("window.orbitTheme", dark ? "dark" : "light")
        login.web.appearance = ap
    }

    /// 進入：收起登入畫面，球體的「＋ 新衛星」只列登入過的大腦
    func enter(_ list: [Provider]) {
        hideAllSats()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in MainActor.assumeIsolated { self?.host.restore() } }   // 過場完把上次的衛星開回來
        // 過場：登入卡片往前飛出（網頁自己動）＋整個登入層淡出，同時球體從遠處拉近打開
        (sphereView as? WKWebView)?.evaluateJavaScript("window.karaIntro && window.karaIntro()")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.75; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            login.web.animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.login.web.isHidden = true } })
        let ids = list.filter(\.signedIn).map(\.id)
        if let d = try? JSONSerialization.data(withJSONObject: ids), let w = sphereView as? WKWebView {
            w.evaluateJavaScript("window.orbitBrains && window.orbitBrains(\(String(decoding: d, as: UTF8.self)))")
        }
    }
    func showLogin() {
        hideAllSats()
        (sphereView as? WKWebView)?.evaluateJavaScript("window.karaOutro && window.karaOutro()")      // 球拉遠消失
        login.web.alphaValue = 0; login.web.isHidden = false
        login.check()
        // 11-23 Keng「登入卡片太早滑進來」：等球拉遠快消失（0.9 秒的過場走到 0.8 秒）才讓登入頁淡入、卡片進場
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.login.web.isHidden else { return }
            self.login.web.evaluateJavaScript("window.loginShow && window.loginShow()")
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.login.web.animator().alphaValue = 1
            }
        }
    }

    /// 11-23 Keng「自動排版，我也要能讓我的衛星終端機像之前那樣斜對角排開」：開著的衛星小視窗統一大小，
    /// 照疊放順序沿斜對角均勻排開（最底下的在左上、最上面的在右下），每個標題列都看得到
    /// 11-23 Keng「我要限定範圍」：只在左欄卡片右緣＋小縫 ～ 右欄戰情卡左緣－小縫、「思考中」狀態字上面這塊排（web＝球體量好的空位）
    func arrangeSats(in web: CGRect? = nil) {
        guard let root = window.contentView else { return }
        let wins = root.subviews.compactMap { $0 as? TermWindowView }.filter { !$0.isHidden && $0.wantShown }.sorted { $0.seq < $1.seq }   // 照打開先後：點一下疊到最上面不會換位置
        guard !wins.isEmpty else { return }
        let H = root.bounds.height
        let area = web.map { NSRect(x: $0.minX, y: H - $0.maxY, width: $0.width, height: $0.height) }
            ?? NSRect(x: 16, y: 40, width: root.bounds.width - 32, height: H - 40 - 52)
        let base = TermWindowView.fit(wins[0].restoredFrame(in: root.bounds), in: root.bounds)
        let n = CGFloat(wins.count)
        // 11-23 審查 #9：範圍再窄，衛星也不小於 420×260（TermWindow 自己的下限），寧可超出範圍也要看得到字
        let w = max(min(420, root.bounds.width - 32), min(base.width, n > 1 ? area.width * 0.62 : area.width))
        let h = max(min(260, root.bounds.height - 80), min(base.height, n > 1 ? area.height * 0.78 : area.height))
        let dx = n > 1 ? max(0, area.width - w) / (n - 1) : 0, dy = n > 1 ? max(0, area.height - h) / (n - 1) : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32; ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            for (i, v) in wins.enumerated() {
                let f = n > 1 ? NSRect(x: area.minX + CGFloat(i) * dx, y: area.maxY - h - CGFloat(i) * dy, width: w, height: h)
                    : NSRect(x: area.midX - w / 2, y: area.maxY - h, width: w, height: h)
                v.animator().frame = NSRect(x: f.minX.rounded(), y: f.minY.rounded(), width: w.rounded(), height: h.rounded())   // 每個一樣大（不用 integral：會往外擴差 1 像素）
            }
        }
    }

    /// 11-23 Keng「增加新視窗的時候要自動幫我全部排下去」：開／關／收起衛星後，自動排版開著就重排（範圍跟開關都問球體）
    func autoArrange() {
        (sphereView as? WKWebView)?.evaluateJavaScript("window.karaSatArea ? JSON.stringify(window.karaSatArea()) : 'null'") { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self, let str = r as? String, let d = str.data(using: .utf8),
                      let v = try? JSONSerialization.jsonObject(with: d) as? [Double], v.count == 4 else { return }
                self.arrangeSats(in: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
            }
        }
    }

    /// 打開（或叫回）一顆衛星的小視窗；新開的從上一個位置往右下錯開一點，像 macOS 開新視窗
    func showSat(_ id: String) {
        guard let root = window.contentView else { return }
        let w: TermWindowView
        if let x = satWins[id] { w = x }
        else {
            w = TermWindowView(content: host.view(for: id))
            w.titleLabel.stringValue = host.title(id)
            w.appearance = NSAppearance(named: themeNow == "light" ? .aqua : .darkAqua)
            let n = CGFloat(satWins.values.filter { !$0.isHidden }.count)
            w.frame = TermWindowView.fit(w.restoredFrame(in: root.bounds).offsetBy(dx: n * 28, dy: -n * 28), in: root.bounds)
            w.isHidden = true
            w.onClose = { [weak self] in self?.host.end(id) }                 // 結束衛星 → onRemoved → 關掉小視窗
            w.onMinimize = { [weak self, weak w] in if let self, let w { self.animate(w, on: false) { [weak self] in self?.autoArrange() } } }
            w.onDropPaths = { [weak self] paths in self?.host.type(id, paths.joined(separator: " ") + " ") }
            // 11-23 Keng「調整每一個衛星小視窗大小時，其他的衛星也要跟著一起變」
            w.onResized = { [weak self, weak w] size in
                guard let self else { return }
                for o in self.satWins.values where o !== w && !o.isHidden { o.matchSize(size) }
            }
            w.acceptFileDrops()
            root.addSubview(w)
            satWins[id] = w
        }
        raise(w)
        if w.isHidden || !w.wantShown { animate(w, on: true); autoArrange() } else { w.flash() }
        window.makeFirstResponder(w.content)
    }
    private func closeSat(_ id: String) {
        guard let w = satWins.removeValue(forKey: id) else { return }
        animate(w, on: false) { [weak self] in w.removeFromSuperview(); self?.autoArrange() }
    }
    private func hideAllSats() { for w in satWins.values { animate(w, on: false) } }

    /// 疊到最上面：zPosition 遞增，再照 zPosition 重排 subview 順序（不把視圖拿下來重放，終端機不會失焦）
    private func raise(_ w: NSView) {
        guard let root = window.contentView else { return }
        if root.subviews.last === w, (w.layer?.zPosition ?? 0) >= zTop { return }
        zTop += 1; w.wantsLayer = true; w.layer?.zPosition = zTop
        root.sortSubviews({ a, b, _ in
            let za = a.layer?.zPosition ?? 0, zb = b.layer?.zPosition ?? 0
            return za < zb ? .orderedAscending : za > zb ? .orderedDescending : .orderedSame
        }, context: nil)
    }
    private func raiseUnder(_ e: NSEvent) {
        guard e.window === window, let root = window.contentView else { return }
        let p = root.convert(e.locationInWindow, from: nil)
        guard let w = root.subviews.last(where: { ($0 as? TermWindowView)?.yieldingToAsk == false && !$0.isHidden && $0.frame.contains(p) }) else { return }
        raise(w)
    }

    private func layoutTerm() {
        guard let root = window.contentView else { return }
        // Orbit42 視窗變小：開著的小視窗縮進來、留在視窗裡
        for w in Array(satWins.values) + Array(boards.values) where !w.isHidden { w.frame = TermWindowView.fit(w.frame, in: root.bounds) }
    }
    /// 小視窗打開時從下方放大淡入（像 macOS 開視窗），收起時縮小淡出
    private func animate(_ w: TermWindowView, on: Bool, then: (() -> Void)? = nil) {
        w.wantShown = on; w.yieldingToAsk = false         // 開／收動畫自己管透明度；淡掉與否下一輪 watchAskCard 再判斷
        guard let layer = w.layer, let root = window.contentView else { w.isHidden = !on; then?(); return }
        if on {
            w.frame = TermWindowView.fit(w.frame, in: root.bounds)
            w.isHidden = false; w.alphaValue = 0
            layer.setAffineTransform(CGAffineTransform(scaleX: 0.94, y: 0.94))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.26; ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                w.animator().alphaValue = 1
                layer.setAffineTransform(.identity)
            }
            w.flash()                                 // 邊框亮一下紅光
            then?()
        } else {
            guard !w.isHidden else { then?(); return }
            w.setBreathing(false)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2; ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                w.animator().alphaValue = 0
                layer.setAffineTransform(CGAffineTransform(scaleX: 0.94, y: 0.94))
            }, completionHandler: { MainActor.assumeIsolated {
                guard !w.wantShown else { return }          // 收到一半又被打開：不要藏
                w.isHidden = true; w.alphaValue = 1; layer.setAffineTransform(.identity)
                then?()
            } })
        }
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
