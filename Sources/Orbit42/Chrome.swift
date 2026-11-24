import AppKit
import Darwin

/// 背景 Chrome（11-24 Keng「衛星裡嵌真的 Chrome 畫面」）：用 --remote-debugging-pipe 控制，走檔案描述子 3／4，不開任何網路埠
/// （開埠的話，本機任何程式都能操作這個登入過的瀏覽器）。自己的設定檔，跟平常的 Chrome 分開。Orbit42 結束或當掉，管線斷了 Chrome 就自己關。
@MainActor
final class ChromeBrowser {
    static let shared = ChromeBrowser()
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") }
    private var pid: pid_t = 0, toChrome: Int32 = -1, fromChrome: Int32 = -1
    private var nextID = 0
    private var waiting: [Int: ([String: Any]) -> Void] = [:]
    private var listeners: [String: (String, [String: Any]) -> Void] = [:]      // 頁面 session → 事件
    private let writeQueue = DispatchQueue(label: "orbit.chrome.write")
    var onDead: [ObjectIdentifier: () -> Void] = [:]
    var running: Bool { pid > 0 }

    static var profile: String {
        ProcessInfo.processInfo.environment["ORBIT_CHROME_PROFILE"]
            ?? NSHomeDirectory() + "/Library/Application Support/Orbit42/Chrome"
    }

    /// 已經開著就直接回 true
    func start() -> Bool {
        if pid > 0 { return true }
        guard let app = Self.appURL else { return false }
        try? FileManager.default.createDirectory(atPath: Self.profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var a: [Int32] = [0, 0], b: [Int32] = [0, 0]
        guard pipe(&a) == 0 else { return false }
        guard pipe(&b) == 0 else { close(a[0]); close(a[1]); return false }
        // 先搬到高號碼：spawn 的 dup2 才不會互相蓋到；本身都設 CLOEXEC
        func high(_ fd: Int32) -> Int32 { let n = fcntl(fd, F_DUPFD_CLOEXEC, 100); close(fd); return n }
        let readEnd = high(a[0]), writeMine = high(a[1]), readMine = high(b[0]), writeEnd = high(b[1])
        var acts: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&acts)
        posix_spawn_file_actions_addopen(&acts, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&acts, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&acts, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&acts, readEnd, 3)
        posix_spawn_file_actions_adddup2(&acts, writeEnd, 4)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let exe = app.appendingPathComponent("Contents/MacOS/Google Chrome").path
        let args = [exe, "--headless=new", "--remote-debugging-pipe", "--user-data-dir=" + Self.profile, "--no-first-run", "--no-default-browser-check",
                    "--hide-scrollbars=false", "--window-size=1000,800", "about:blank"]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var p: pid_t = 0
        let rc = posix_spawn(&p, exe, &acts, &attr, &argv, &envp)
        posix_spawn_file_actions_destroy(&acts); posix_spawnattr_destroy(&attr)
        close(readEnd); close(writeEnd)
        guard rc == 0 else { close(writeMine); close(readMine); return false }
        pid = p; toChrome = writeMine; fromChrome = readMine
        _ = fcntl(writeMine, F_SETNOSIGPIPE, 1)
        let fd = readMine, me = p
        Thread.detachNewThread {
            var buf = Data(), chunk = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
                var start = buf.startIndex
                while let z = buf[start...].firstIndex(of: 0) {
                    if let o = try? JSONSerialization.jsonObject(with: buf[start..<z]) as? [String: Any] {
                        DispatchQueue.main.async { MainActor.assumeIsolated { ChromeBrowser.shared.got(o) } }
                    }
                    start = z + 1
                }
                buf = Data(buf[start...])
            }
            var st: Int32 = 0; kill(me, SIGTERM); waitpid(me, &st, 0)
            DispatchQueue.main.async { MainActor.assumeIsolated { ChromeBrowser.shared.died(me) } }
        }
        send("Browser.setDownloadBehavior", ["behavior": "deny"])
        send("Target.setDiscoverTargets", ["discover": true])
        return true
    }
    private func died(_ p: pid_t) {
        guard p == pid else { return }
        close(toChrome); close(fromChrome)
        pid = 0; toChrome = -1; fromChrome = -1; listeners = [:]
        let w = waiting; waiting = [:]
        for f in w.values { f(["error": ["message": "Chrome 關了"]]) }
        for f in Array(onDead.values) { f() }
    }
    func quit() { if pid > 0 { send("Browser.close"); kill(pid, SIGTERM) } }

    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil, _ done: (([String: Any]) -> Void)? = nil) {
        guard pid > 0 else { done?(["error": ["message": "Chrome 沒在跑"]]); return }
        nextID += 1
        var o: [String: Any] = ["id": nextID, "method": method, "params": params]
        if let session { o["sessionId"] = session }
        if let done { waiting[nextID] = done }
        guard var d = try? JSONSerialization.data(withJSONObject: o) else { return }
        d.append(0)
        let fd = toChrome, bytes = d
        writeQueue.async {
            bytes.withUnsafeBytes { b in
                var at = 0
                while at < b.count {
                    let n = write(fd, b.baseAddress! + at, b.count - at)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return }
                    at += n
                }
            }
        }
    }
    func listen(_ session: String, _ f: @escaping (String, [String: Any]) -> Void) { listeners[session] = f }
    func unlisten(_ session: String) { listeners[session] = nil }
    private func got(_ o: [String: Any]) {
        if let id = o["id"] as? Int { waiting.removeValue(forKey: id)?(o); return }
        guard let m = o["method"] as? String else { return }
        let p = o["params"] as? [String: Any] ?? [:]
        if let s = o["sessionId"] as? String { listeners[s]?(m, p) }
        else if m == "Target.targetCreated" || m == "Target.targetInfoChanged" { popup(p["targetInfo"] as? [String: Any] ?? [:]) }
    }
    /// 網頁開新視窗／分頁：網址拿過來在原面板開，關掉那一頁
    private var ours: [String: ChromeView] = [:]
    func own(_ target: String, _ v: ChromeView?) { ours[target] = v }
    private func popup(_ t: [String: Any]) {
        guard t["type"] as? String == "page", let id = t["targetId"] as? String, ours[id] == nil,
              let opener = t["openerId"] as? String, let v = ours[opener],
              let u = (t["url"] as? String).flatMap(WebPane.parse) else { return }
        send("Target.closeTarget", ["targetId": id]); v.load(u)
    }
}

/// 一頁 Chrome：畫面用 screencast 收，滑鼠、鍵盤、中文輸入法送回去
@MainActor
final class ChromeView: NSView, @preconcurrency NSTextInputClient {
    private(set) var url: URL?
    private(set) var title = ""
    var onChange: () -> Void = {}
    var onLoaded: () -> Void = {}
    var onError: (String) -> Void = { _ in }
    private(set) var frames = 0                 // 收到幾張畫面（測試用）
    private var target: String?, session: String?, pending: URL?, opening = false, closed = false
    private var mainFrame = ""
    private let picture = CALayer()
    private var marked = NSMutableAttributedString()
    private var lastMetrics = NSSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        picture.contentsGravity = .resize; picture.anchorPoint = .zero
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture); layer?.masksToBounds = true
        ChromeBrowser.shared.onDead[ObjectIdentifier(self)] = { [weak self] in
            guard let self else { return }
            self.target = nil; self.session = nil; self.opening = false
            if !self.closed { self.onError("Chrome 關掉了，按 ↻ 重開") }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    // MARK: 開頁
    private func cmd(_ m: String, _ p: [String: Any] = [:], _ done: (([String: Any]) -> Void)? = nil) {
        guard let session else { return }
        ChromeBrowser.shared.send(m, p, session: session, done)
    }
    func load(_ u: URL) {
        url = u; pending = u; closed = false
        if session != nil { navigate() } else { connect() }
    }
    private func navigate() {
        guard let u = pending else { return }
        pending = nil
        cmd("Page.navigate", ["url": u.absoluteString]) { [weak self] r in
            if let e = (r["result"] as? [String: Any])?["errorText"] as? String, e != "net::ERR_ABORTED" { self?.onError("打不開這個網頁：\(e)") }
            else if let e = (r["error"] as? [String: Any])?["message"] as? String { self?.onError("打不開這個網頁：\(e)") }
        }
    }
    private func connect() {
        guard !opening else { return }
        guard ChromeBrowser.shared.start() else { onError("這台 Mac 沒有裝 Google Chrome，或開不起來"); return }
        opening = true
        ChromeBrowser.shared.send("Target.createTarget", ["url": "about:blank"]) { [weak self] r in
            guard let t = (r["result"] as? [String: Any])?["targetId"] as? String else { self?.opening = false; self?.onError("Chrome 開不了新頁"); return }
            guard let self, !self.closed else { ChromeBrowser.shared.send("Target.closeTarget", ["targetId": t]); return }
            self.target = t; ChromeBrowser.shared.own(t, self)
            ChromeBrowser.shared.send("Target.attachToTarget", ["targetId": t, "flatten": true]) { [weak self] r in
                guard let self else { return }
                self.opening = false
                guard let s = (r["result"] as? [String: Any])?["sessionId"] as? String, !self.closed else { return }
                self.session = s
                ChromeBrowser.shared.listen(s) { [weak self] m, p in self?.event(m, p) }
                self.cmd("Page.enable"); self.cmd("Runtime.enable")
                self.lastMetrics = .zero; self.metrics(); self.cast(); self.navigate()
            }
        }
    }
    func close() {
        closed = true; pending = nil
        if let s = session { ChromeBrowser.shared.unlisten(s) }
        if let t = target { ChromeBrowser.shared.own(t, nil); ChromeBrowser.shared.send("Target.closeTarget", ["targetId": t]) }
        ChromeBrowser.shared.onDead[ObjectIdentifier(self)] = nil
        session = nil; target = nil
    }
    func reload() { if session == nil, let u = url { load(u) } else { cmd("Page.reload") } }
    func go(_ step: Int) {
        cmd("Page.getNavigationHistory") { [weak self] r in
            guard let o = r["result"] as? [String: Any], let i = o["currentIndex"] as? Int, let es = o["entries"] as? [[String: Any]],
                  es.indices.contains(i + step), let id = es[i + step]["id"] as? Int, es[i + step]["url"] as? String != "about:blank" else { return }
            self?.cmd("Page.navigateToHistoryEntry", ["entryId": id])
        }
    }

    // MARK: 畫面
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var casting = false
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { uncast() } else { metrics(); cast() } }
    override func layout() { super.layout(); picture.bounds = CGRect(origin: .zero, size: bounds.size); picture.position = .zero; metrics() }
    private func metrics() {
        let s = NSSize(width: bounds.width.rounded(), height: bounds.height.rounded())
        guard session != nil, s.width > 50, s.height > 50, s != lastMetrics else { return }
        lastMetrics = s
        cmd("Emulation.setDeviceMetricsOverride", ["width": Int(s.width), "height": Int(s.height), "deviceScaleFactor": Double(scale), "mobile": false])
        if casting { casting = false; cast() }
    }
    private func cast() {
        guard session != nil, window != nil, !casting, bounds.width > 50 else { return }
        casting = true
        cmd("Page.startScreencast", ["format": "jpeg", "quality": 85, "maxWidth": Int(bounds.width * scale), "maxHeight": Int(bounds.height * scale), "everyNthFrame": 1])
    }
    private func uncast() { guard casting else { return }; casting = false; cmd("Page.stopScreencast") }

    private func event(_ m: String, _ p: [String: Any]) {
        switch m {
        case "Page.screencastFrame":
            if let id = p["sessionId"] as? Int { cmd("Page.screencastFrameAck", ["sessionId": id]) }
            guard let s = p["data"] as? String, let d = Data(base64Encoded: s), let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            picture.contents = img; frames += 1
        case "Page.frameNavigated":
            guard let f = p["frame"] as? [String: Any], f["parentId"] == nil, let u = f["url"] as? String else { return }
            mainFrame = f["id"] as? String ?? ""
            if u != "about:blank" { url = URL(string: u); title = ""; onError(""); onChange() }
        case "Page.navigatedWithinDocument":
            if p["frameId"] as? String == mainFrame, let u = (p["url"] as? String).flatMap(URL.init) { url = u; readTitle() }
        case "Page.loadEventFired": readTitle(); if url != nil { onLoaded() }
        case "Page.javascriptDialogOpening": dialog(p)
        case "Inspector.targetCrashed": onError("這一頁當掉了，按 ↻ 重新載入")
        default: break
        }
    }
    private func readTitle() {
        cmd("Runtime.evaluate", ["expression": "document.title"]) { [weak self] r in
            guard let self else { return }
            self.title = ((r["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String ?? ""
            self.onChange()
        }
    }
    /// 網頁的 alert／confirm／prompt：不回答整頁會卡住
    private func dialog(_ p: [String: Any]) {
        let type = p["type"] as? String ?? "alert"
        guard let w = window else { cmd("Page.handleJavaScriptDialog", ["accept": type == "beforeunload"]); return }
        let a = NSAlert(); a.messageText = url?.host ?? "網頁"; a.informativeText = String((p["message"] as? String ?? "").prefix(600))
        a.addButton(withTitle: "好")
        if type != "alert" { a.addButton(withTitle: "取消") }
        var field: NSTextField?
        if type == "prompt" { let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = p["defaultPrompt"] as? String ?? ""; a.accessoryView = f; field = f }
        a.beginSheetModal(for: w) { [weak self] r in
            self?.cmd("Page.handleJavaScriptDialog", ["accept": r == .alertFirstButtonReturn, "promptText": field?.stringValue ?? ""])
        }
    }

    // MARK: 滑鼠
    private func mods(_ e: NSEvent) -> Int {
        let f = e.modifierFlags
        return (f.contains(.option) ? 1 : 0) | (f.contains(.control) ? 2 : 0) | (f.contains(.command) ? 4 : 0) | (f.contains(.shift) ? 8 : 0)
    }
    private func mouse(_ type: String, _ e: NSEvent, button: String = "none", buttons: Int = 0, clicks: Int = 0, _ more: [String: Any] = [:]) {
        let p = convert(e.locationInWindow, from: nil)
        var o: [String: Any] = ["type": type, "x": Double(p.x), "y": Double(p.y), "button": button, "buttons": buttons, "clickCount": clicks, "modifiers": mods(e)]
        o.merge(more) { $1 }
        cmd("Input.dispatchMouseEvent", o)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { mouse("mouseMoved", e) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); mouse("mousePressed", e, button: "left", buttons: 1, clicks: e.clickCount) }
    override func mouseDragged(with e: NSEvent) { mouse("mouseMoved", e, button: "left", buttons: 1) }
    override func mouseUp(with e: NSEvent) { mouse("mouseReleased", e, button: "left", clicks: e.clickCount) }
    override func rightMouseDown(with e: NSEvent) { mouse("mousePressed", e, button: "right", buttons: 2, clicks: 1) }
    override func rightMouseUp(with e: NSEvent) { mouse("mouseReleased", e, button: "right", clicks: 1) }
    override func scrollWheel(with e: NSEvent) {
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 24
        mouse("mouseWheel", e, ["deltaX": Double(-e.scrollingDeltaX * k), "deltaY": Double(-e.scrollingDeltaY * k)])
    }

    // MARK: 鍵盤（文字走輸入法，注音選字才正常）
    private static let keys: [UInt16: (String, String, Int)] = [36: ("Enter", "Enter", 13), 76: ("Enter", "NumpadEnter", 13), 48: ("Tab", "Tab", 9), 51: ("Backspace", "Backspace", 8),
        117: ("Delete", "Delete", 46), 53: ("Escape", "Escape", 27), 123: ("ArrowLeft", "ArrowLeft", 37), 124: ("ArrowRight", "ArrowRight", 39),
        125: ("ArrowDown", "ArrowDown", 40), 126: ("ArrowUp", "ArrowUp", 38), 115: ("Home", "Home", 36), 119: ("End", "End", 35), 116: ("PageUp", "PageUp", 33), 121: ("PageDown", "PageDown", 34)]
    private func press(_ e: NSEvent, _ k: (String, String, Int)) {
        var o: [String: Any] = ["type": "rawKeyDown", "key": k.0, "code": k.1, "windowsVirtualKeyCode": k.2, "modifiers": mods(e), "autoRepeat": e.isARepeat]
        if k.0 == "Enter" { o["type"] = "keyDown"; o["text"] = "\r" }
        cmd("Input.dispatchKeyEvent", o)
        o["type"] = "keyUp"; o["text"] = nil
        cmd("Input.dispatchKeyEvent", o)
    }
    override func keyDown(with e: NSEvent) {
        if marked.length == 0, let k = Self.keys[e.keyCode] { press(e, k); return }
        interpretKeyEvents([e])
    }
    override func doCommand(by s: Selector) {}              // 特殊鍵上面處理過了，不要嗶
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.modifierFlags.intersection([.command, .control, .option]) == .command, let c = e.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: e) }
        func edit(_ name: String, _ code: Int) { cmd("Input.dispatchKeyEvent", ["type": "rawKeyDown", "key": c, "windowsVirtualKeyCode": code, "modifiers": mods(e), "commands": [name]]); cmd("Input.dispatchKeyEvent", ["type": "keyUp", "key": c, "windowsVirtualKeyCode": code, "modifiers": mods(e)]) }
        switch c {
        case "v": if let t = NSPasteboard.general.string(forType: .string) { cmd("Input.insertText", ["text": t]) }
        case "c": copySelection()
        case "x": copySelection { [weak self] in self?.cmd("Input.dispatchKeyEvent", ["type": "rawKeyDown", "key": "Delete", "windowsVirtualKeyCode": 46, "commands": ["delete"]]) }
        case "a": edit("selectAll", 65)
        case "z": edit(e.modifierFlags.contains(.shift) ? "redo" : "undo", 90)
        case "r": reload()
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }
    private func copySelection(_ then: (() -> Void)? = nil) {
        let js = "(()=>{const a=document.activeElement;if(a&&a.type!=='password'&&typeof a.selectionStart==='number'&&a.selectionEnd>a.selectionStart)return a.value.slice(a.selectionStart,a.selectionEnd);return String(getSelection()||'')})()"
        cmd("Runtime.evaluate", ["expression": js]) { r in
            guard let t = ((r["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String, !t.isEmpty else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string); then?()
        }
    }
    func insertText(_ s: Any, replacementRange: NSRange) {
        marked = NSMutableAttributedString()
        let t = (s as? NSAttributedString)?.string ?? s as? String ?? ""
        if !t.isEmpty { cmd("Input.insertText", ["text": t]) }
    }
    func setMarkedText(_ s: Any, selectedRange r: NSRange, replacementRange: NSRange) {
        let t = (s as? NSAttributedString)?.string ?? s as? String ?? ""
        marked = NSMutableAttributedString(string: t)
        cmd("Input.imeSetComposition", ["text": t, "selectionStart": r.location == NSNotFound ? t.utf16.count : r.location, "selectionEnd": r.location == NSNotFound ? t.utf16.count : r.location + r.length])
    }
    func unmarkText() { if marked.length > 0 { let t = marked.string; marked = NSMutableAttributedString(); cmd("Input.insertText", ["text": t]) } }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange r: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange r: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // 選字窗放在滑鼠附近（點輸入框的地方）
        guard let w = window else { return .zero }
        return NSRect(origin: w.convertPoint(toScreen: w.mouseLocationOutsideOfEventStream), size: NSSize(width: 1, height: 18))
    }
    func characterIndex(for p: NSPoint) -> Int { NSNotFound }

    /// 測試：在頁面裡跑一段、拿回字串
    func eval(_ js: String, _ done: @escaping (String) -> Void) {
        cmd("Runtime.evaluate", ["expression": js]) { r in done(((r["result"] as? [String: Any])?["result"] as? [String: Any]).map { "\($0["value"] ?? "nil")" } ?? "\(r)") }
    }
    func testClick(_ x: Double, _ y: Double) {
        for t in ["mousePressed", "mouseReleased"] { cmd("Input.dispatchMouseEvent", ["type": t, "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1]) }
    }
    var snapshot: CGImage? { picture.contents.map { $0 as! CGImage } }
}
