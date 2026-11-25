import AppKit
import WebKit

// 11-25 Keng：答案卡浮在 Orbit42 主視窗最上層（所有衛星終端機、3D／網頁面板都蓋不住）。失敗點清單：docs/ask-float.md
// 衛星是主視窗的 subview ⇒ 這裡也是一個 subview（ask.html），宿主放在最上面、命中測試優先問它。不另開視窗、不設系統置頂。
// 原則：答案會變成使用者本人的輸入，有疑問一律不送。送出只走 SphereEmbed.askAction（跟球體同一條 answer／permit）。

/// 擺位置的純計算（座標：左下原點）
public enum AskFloatLayout {
    public static let margin: CGFloat = 14
    /// 開著的衛星下緣這麼高是它的輸入框，縮成一條時不可以擋
    public static let inputZone: CGFloat = 96
    /// 卡片最大尺寸
    public static func maxSize(_ root: NSSize) -> NSSize { NSSize(width: max(200, min(560, root.width - 2 * margin)), height: max(120, root.height - 2 * margin - 30)) }
    /// 夾在視窗內；比視窗大就貼左上角（標題列看得到）
    public static func clamp(_ f: NSRect, in root: NSSize) -> NSRect {
        var r = f
        r.origin.x = r.width > root.width ? 0 : min(max(0, r.minX), root.width - r.width)
        r.origin.y = r.height > root.height ? root.height - r.height : min(max(0, r.minY), root.height - r.height)
        return r
    }
    /// 展開：正中央。spot＝這次展開期間自己拖到的位置（右下角離視窗右緣、下緣多遠），縮起就放掉
    public static func card(_ size: NSSize, root: NSSize, spot: NSPoint?) -> NSRect {
        let o = spot.map { NSPoint(x: root.width - $0.x - size.width, y: $0.y) } ?? NSPoint(x: ((root.width - size.width) / 2).rounded(), y: ((root.height - size.height) / 2).rounded())
        return visible(NSRect(origin: o, size: size), in: root)
    }
    /// 出界、貼死在邊上 ⇒ 拉回離邊 8pt 的可見處（放不下就照 clamp）
    static func visible(_ f: NSRect, in root: NSSize) -> NSRect {
        var r = clamp(f, in: root); let m: CGFloat = 8
        if r.width + 2 * m <= root.width { r.origin.x = min(max(m, r.minX), root.width - r.width - m) }
        if r.height + 2 * m <= root.height { r.origin.y = min(max(m, r.minY), root.height - r.height - m) }
        return r
    }
    /// 縮成扇形：記住的位置（預設右下）沒擋到任何輸入框就放那裡，不然四個角挑一個不擋的；都擋就放右上
    public static func strip(_ size: NSSize, root: NSSize, corner: NSPoint?, terminals: [NSRect]) -> NSRect {
        let zones = terminals.map { NSRect(x: $0.minX, y: $0.minY, width: $0.width, height: min(inputZone, $0.height)) }
        let m = margin, w = size.width, h = size.height, top = root.height - h - 44      // 44：視窗標題列＋球體工具列
        let spots = [NSRect(x: root.width - (corner?.x ?? m) - w, y: corner?.y ?? m, width: w, height: h), NSRect(x: root.width - w - m, y: m, width: w, height: h), NSRect(x: root.width - w - m, y: top, width: w, height: h),
                     NSRect(x: m, y: top, width: w, height: h), NSRect(x: m, y: m, width: w, height: h)].map { visible($0, in: root) }
        return spots.first { s in !zones.contains { $0.intersects(s) } } ?? clamp(spots[2], in: root)
    }
}

/// 沒被滑鼠點過就不拿焦點、不收任何按鍵
final class AskFloatWeb: WKWebView {
    weak var back: NSResponder?            // 點進來之前的焦點（用滑鼠答完還給它）
    var onResign: (() -> Void)?
    var covers: ((NSPoint) -> Bool)?
    override func hitTest(_ p: NSPoint) -> NSView? { covers?(p) == false ? nil : super.hitTest(p) }      // p＝父 view 座標；扇形透明處讓給底下
    private var isMouse: Bool {
        guard let e = NSApp?.currentEvent, e.type == .leftMouseDown, e.window === window else { return false }
        return bounds.contains(convert(e.locationInWindow, from: nil))
    }
    var testClick = false                  // 測試：當成滑鼠點進來
    override var acceptsFirstResponder: Bool {
        testClick || isMouse || window?.firstResponder === self
    }
    private var watch: NSKeyValueObservation?
    override func viewDidMoveToWindow() {          // 一直記著最後一個不是自己的焦點（切換途中焦點會短暫是視窗本身，不算）
        super.viewDidMoveToWindow()
        watch = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] w, _ in
            MainActor.assumeIsolated { if let self, let v = w.firstResponder as? NSView, v !== self { self.back = v } }
        }
    }
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool { (testClick || isMouse) && super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { onResign?(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with e: NSEvent) -> Bool { window?.firstResponder === self ? super.performKeyEquivalent(with: e) : false }
    override func keyDown(with e: NSEvent) { if window?.firstResponder === self { super.keyDown(with: e) } }
    // 不收拖放（拖進來的檔案、網址會變成導覽）
    override func registerForDraggedTypes(_ t: [NSPasteboard.PasteboardType]) {}
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { [] }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }      // Orbit42 在背景時，第一下只是把它叫到前面
}

/// 根 view：命中測試先問浮層（zPosition 只管畫的順序，不管點擊）
public final class AskFloatRoot: NSView {
    public weak var float: NSView?
    public override func hitTest(_ p: NSPoint) -> NSView? {
        if let f = float, !f.isHidden, f.superview === self, let v = f.hitTest(superview.map { convert(p, from: $0) } ?? p) { return v }
        return super.hitTest(p)
    }
}

@MainActor
public final class AskFloat: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: AskFloatWeb
    public var view: NSView { webView }
    /// 開著的衛星（主視窗座標）：縮成一條時不擋它們的輸入框
    public var terminals: () -> [NSRect] = { [] }
    /// 是不是在組字：自動展開要等
    public var composing: () -> Bool = { false }
    /// 暫時藏起來（登入畫面開著）
    public var suppressed = false { didSet { layout() } }
    private(set) var mode = "hidden", size = NSSize.zero
    private(set) var ready = false
    private var dragFrom: NSRect?, pendingData: Data?
    private let store: UserDefaults
    private static let stripKey = "orbit.askFan"      // 11-25 改成扇形：舊的 orbit.askCorner／askStrip 不再用
    private func point(_ k: String) -> NSPoint? { (store.array(forKey: k) as? [Double]).flatMap { $0.count == 2 ? NSPoint(x: $0[0], y: $0[1]) : nil } }
    private var spot: NSPoint?               // 展開期間自己拖到的位置；縮起就放掉，不存
    private var shapes: [[NSPoint]] = []     // 縮起時看得見的形狀（網頁座標，左上原點）：扇形四張牌、數字、提示。之外是透明的，點得到底下
    // 打字中不展開：別處（終端機）最後一次按鍵
    var lastKey = -100.0, wantTimer: Timer?, keyWatch: Any?
    static let quiet = 2.0
    func mayExpand(now t: Double) -> Bool { !composing() && t - lastKey >= Self.quiet }
    func tryExpand(now t: Double? = nil) {
        wantTimer?.invalidate(); wantTimer = nil
        guard ready, !open else { return }
        guard mayExpand(now: t ?? now) else {
            wantTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.tryExpand() } }; return
        }
        js("window.askGo && window.askGo()")
    }
    private var seen: [String] = []
    private var tick: Timer?

    public init?(dir: URL? = nil, store: UserDefaults = .standard) {
        guard let root = dir ?? WorkWindow.webDir, FileManager.default.fileExists(atPath: root.appendingPathComponent("ask.html").path) else { return nil }
        self.store = store
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(WebSchemeHandler(root: root), forURLScheme: WebSchemeHandler.scheme)
        webView = AskFloatWeb(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakAsk(self), name: "ask")
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.wantsLayer = true; webView.layer?.zPosition = 1_000_000          // 衛星的 zPosition 從 10 一直往上加
        webView.isHidden = true
        webView.covers = { [weak self] p in self?.covers(p) ?? true }
        webView.onResign = { [weak self] in self?.js("window.askBlur && window.askBlur()") }
        webView.uiDelegate = self
        webView.unregisterDraggedTypes()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        load()
        SphereEmbed.askPayload = { [weak self] d in self?.update(d) }
        SphereEmbed.askResult = { [weak self] sid, ask, text in self?.call("window.askResult", [sid, ask, text]) }
        SphereEmbed.askShow = { [weak self] sid in self?.call("window.askShow", [sid]) }
        keyWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { if let self, let w = self.webView.window, e.window === w, w.firstResponder !== self.webView { self.lastKey = self.now } }
            return e
        }
        // 衛星會被拖動、開關：縮成一條時每秒看一次有沒有擋到（沒動就不做事）
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { if self?.mode == "strip" { self?.layout() }; self?.heartbeat() } }
    }

    public func setTheme(_ name: String) { call("window.askTheme", [name]) }
    func update(_ d: Data) {
        pendingData = d
        guard ready else { return }
        js("window.askUpdate(\(String(decoding: d, as: UTF8.self)))")
    }
    public func webView(_ w: WKWebView, didFinish n: WKNavigation!) { layout() }

    // MARK: 活著才接手：浮層說 ready 球體才不畫答案卡；載不起來、當掉、沒回應 ⇒ 球體照畫（不可漏答），這裡一直重試
    public static let page = "\(WebSchemeHandler.scheme)://web/ask.html"
    var loadAt = 0.0, fails = 0, pingAt = 0.0, pongAt = 0.0
    func load() { loadAt = now; pingAt = 0; pongAt = 0; webView.load(URLRequest(url: URL(string: Self.page)!)) }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private(set) var lost = false
    /// 不行了：球體接手、藏起來，等一下重新載入（不會替使用者送任何東西；題目還在，可以再按）
    func down() {
        ready = false; lost = true; mode = "hidden"; told = .zero; dragFrom = nil
        SphereEmbed.setAskFloat(false); layout()
        fails += 1
    }
    /// 幾秒後重試：1、2、4⋯最多 30
    static func backoff(_ fails: Int) -> Double { min(30, pow(2, Double(max(0, min(fails, 6) - 1)))) }
    func heartbeat(now t: Double? = nil) {
        let t = t ?? now
        if !ready {
            if lost { if t - loadAt >= Self.backoff(fails) { lost = false; loadAt = t; load() } }
            else if t - loadAt > 8 { loadAt = t; down() }                                    // 8 秒沒說 ready
            return
        }
        if pingAt > 0, pongAt < pingAt { if t - pingAt > 4 { loadAt = t; down() }; return }  // 4 秒沒回應
        guard t - pingAt > 5 else { return }
        pingAt = t
        webView.evaluateJavaScript("typeof askUpdate") { [weak self] r, _ in MainActor.assumeIsolated { if let self, r as? String == "function" { self.pongAt = self.now; if self.pongAt < self.pingAt { self.pongAt = self.pingAt } } } }
    }
    public func webViewWebContentProcessDidTerminate(_ w: WKWebView) { loadAt = now; down() }
    public func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { if !ready { loadAt = now; down() } }
    public func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { if !ready { loadAt = now; down() } }
    /// 只准開自己那一頁、主框架；不開新視窗
    static func allowed(_ url: URL?, mainFrame: Bool) -> Bool { mainFrame && url?.absoluteString == page }
    public func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(Self.allowed(a.request.url, mainFrame: a.targetFrame?.isMainFrame == true) ? .allow : .cancel)
    }
    public func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? { nil }
    public var theme = "dark" { didSet { setTheme(theme) } }

    /// 訊息只收自己那一頁（主框架、自己的 scheme、自己的 web view、現在網址還是 ask.html）
    public func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        let o = m.frameInfo.securityOrigin
        guard m.webView === webView, m.frameInfo.isMainFrame, o.protocol == WebSchemeHandler.scheme, o.host == "web",
              Self.allowed(webView.url, mainFrame: true), Self.allowed(m.frameInfo.request.url, mainFrame: true), let b = m.body as? [String: Any] else { return }
        handle(b)
    }
    private var open = true          // 縮成一條的狀態：重新載入後還在
    func handle(_ b: [String: Any]) {
        let num = { (k: String) in CGFloat((b[k] as? NSNumber)?.doubleValue ?? 0) }
        switch b["action"] as? String {
        case "ready":
            ready = true; lost = false; fails = 0; pingAt = now; pongAt = now; told = .zero
            setTheme(theme); layout(); call("window.askRestore", [open, seen])
            SphereEmbed.setAskFloat(true)
            if let d = pendingData ?? SphereEmbed.latestSphere { update(d) }
        case "askSize": mode = b["mode"] as? String ?? "hidden"; size = NSSize(width: num("w"), height: num("h"))
            shapes = (b["shapes"] as? [[[NSNumber]]] ?? []).map { $0.compactMap { $0.count == 2 ? NSPoint(x: $0[0].doubleValue, y: $0[1].doubleValue) : nil } }
            layout()
        case "askOpen":
            open = b["open"] as? Bool ?? true
            spot = nil
        case "askSeen": seen = b["keys"] as? [String] ?? seen
        case "askWant": tryExpand()
        case "askDrag": drag(b["phase"] as? String ?? "", NSPoint(x: num("dx"), y: num("dy")))
        case "askFocusBack": focusBack()
        case "askTyping": SphereEmbed.askTyping(b["on"] as? Bool ?? false)
        case "focus", "answer", "permit", "stopSpeaking": SphereEmbed.askAction(b)
        default: break
        }
    }
    private func focusBack() {
        guard let w = webView.window, w.firstResponder === webView else { return }
        let v = webView.back as? NSView
        w.makeFirstResponder(v?.window === w && v?.isHiddenOrHasHiddenAncestor == false ? v : nil)
    }
    private func drag(_ phase: String, _ d: NSPoint) {
        guard let root = webView.superview?.bounds.size else { return }
        switch phase {
        case "start": dragFrom = webView.frame
        case "move": if let f = dragFrom { webView.frame = AskFloatLayout.clamp(f.offsetBy(dx: d.x, dy: -d.y), in: root) }
        case "end":
            guard dragFrom != nil else { return }
            dragFrom = nil
            let p = NSPoint(x: root.width - webView.frame.maxX, y: webView.frame.minY)
            if mode == "strip" { store.set([Double(p.x), Double(p.y)], forKey: Self.stripKey) } else { spot = p }
            layout()
        default: break
        }
    }
    public var dragging: Bool { dragFrom != nil }
    private var told = NSSize.zero
    /// 視窗改大小、卡片內容變了、衛星動了都叫這個
    public func layout() {
        guard let root = webView.superview?.bounds.size else { return }
        let most = AskFloatLayout.maxSize(root)
        if ready, most != told { told = most; call("window.askMax", [Double(most.width), Double(most.height)]) }
        let show = mode != "hidden" && !suppressed && size.width > 0 && size.height > 0
        if webView.isHidden == show {
            webView.isHidden = !show
            if !show, let w = webView.window, w.firstResponder === webView { w.makeFirstResponder(nil) }
        }
        // 藏著也給一個量得到大小的框（寬度不夠會量錯）
        guard show else { if webView.frame.width < most.width { webView.frame = NSRect(x: 0, y: 0, width: most.width, height: 200) }; return }
        guard dragFrom == nil else { return }
        let f = mode == "strip" ? AskFloatLayout.strip(size, root: root, corner: point(Self.stripKey), terminals: terminals()) : AskFloatLayout.card(size, root: root, spot: mode == "card" ? spot : nil)
        if webView.frame != f { webView.frame = f; if ready { js("window.askMoved && window.askMoved()") } }
    }
    // 測試（只給離屏測試用）：假題目、跑一段網頁程式；真的資料不再進來
    public func testUpdate(_ f: URL) { SphereEmbed.askPayload = nil; if let d = try? Data(contentsOf: f) { update(d) } }
    public func testJS(_ s: String) { js(s) }
    /// 這一點（父 view 座標）是不是真的在卡片／牌上（扇形的透明處不算）
    public func covers(_ p: NSPoint) -> Bool {
        guard !webView.isHidden, webView.frame.contains(p) else { return false }
        guard mode != "card", !shapes.isEmpty else { return true }
        let q = NSPoint(x: p.x - webView.frame.minX, y: webView.frame.maxY - p.y)
        return shapes.contains { poly in
            guard let f = poly.first, poly.count > 2 else { return false }
            let b = NSBezierPath(); b.move(to: f); poly.dropFirst().forEach { b.line(to: $0) }; b.close()
            return b.contains(q)
        }
    }
    private func js(_ s: String) { webView.evaluateJavaScript(s, completionHandler: nil) }
    private func call(_ fn: String, _ args: [Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: args) else { return }
        js("\(fn) && \(fn)(...\(String(decoding: d, as: UTF8.self)))")
    }
}

private final class WeakAsk: NSObject, WKScriptMessageHandler {
    weak var target: AskFloat?
    init(_ t: AskFloat) { target = t }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { MainActor.assumeIsolated { target?.userContentController(u, didReceive: m) } }
}
