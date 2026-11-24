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
    public static func maxSize(_ root: NSSize) -> NSSize { NSSize(width: max(200, min(440, root.width - 2 * margin)), height: max(120, root.height - 2 * margin - 30)) }
    /// 夾在視窗內；比視窗大就貼左上角（標題列看得到）
    public static func clamp(_ f: NSRect, in root: NSSize) -> NSRect {
        var r = f
        r.origin.x = r.width > root.width ? 0 : min(max(0, r.minX), root.width - r.width)
        r.origin.y = r.height > root.height ? root.height - r.height : min(max(0, r.minY), root.height - r.height)
        return r
    }
    /// corner＝右下角離視窗右緣、下緣多遠（nil＝預設右下）
    public static func card(_ size: NSSize, root: NSSize, corner: NSPoint?) -> NSRect {
        let c = corner ?? NSPoint(x: margin, y: margin)
        return clamp(NSRect(x: root.width - c.x - size.width, y: c.y, width: size.width, height: size.height), in: root)
    }
    /// 縮成一條：原位沒擋到任何輸入框就放原位，不然四個角挑一個不擋的；都擋就放右上
    public static func strip(_ size: NSSize, root: NSSize, corner: NSPoint?, terminals: [NSRect]) -> NSRect {
        let zones = terminals.map { NSRect(x: $0.minX, y: $0.minY, width: $0.width, height: min(inputZone, $0.height)) }
        let m = margin, w = size.width, h = size.height, top = root.height - h - 44      // 44：視窗標題列＋球體工具列
        let spots = [card(size, root: root, corner: corner), NSRect(x: root.width - w - m, y: m, width: w, height: h), NSRect(x: root.width - w - m, y: top, width: w, height: h),
                     NSRect(x: m, y: top, width: w, height: h), NSRect(x: m, y: m, width: w, height: h)].map { clamp($0, in: root) }
        return spots.first { s in !zones.contains { $0.intersects(s) } } ?? clamp(spots[2], in: root)
    }
}

/// 沒被滑鼠點過就不拿焦點、不收任何按鍵
final class AskFloatWeb: WKWebView {
    weak var back: NSResponder?            // 點進來之前的焦點（用滑鼠答完還給它）
    var onResign: (() -> Void)?
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
public final class AskFloat: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: AskFloatWeb
    public var view: NSView { webView }
    /// 開著的衛星（主視窗座標）：縮成一條時不擋它們的輸入框
    public var terminals: () -> [NSRect] = { [] }
    /// 暫時藏起來（登入畫面開著）
    public var suppressed = false { didSet { layout() } }
    private(set) var mode = "hidden", size = NSSize.zero
    private var ready = false, dragFrom: NSRect?, pendingData: Data?
    private let store: UserDefaults
    private static let key = "orbit.askCorner"
    var corner: NSPoint? {
        get { (store.array(forKey: Self.key) as? [Double]).flatMap { $0.count == 2 ? NSPoint(x: $0[0], y: $0[1]) : nil } }
        set { if let p = newValue { store.set([Double(p.x), Double(p.y)], forKey: Self.key) } else { store.removeObject(forKey: Self.key) } }
    }
    private var tick: Timer?

    public init?(dir: URL? = nil, store: UserDefaults = .standard) {
        guard let root = dir ?? WorkWindow.webDir, FileManager.default.fileExists(atPath: root.appendingPathComponent("ask.html").path) else { return nil }
        self.store = store
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(OfficeWebSchemeHandler(root: root), forURLScheme: OfficeWebSchemeHandler.scheme)
        webView = AskFloatWeb(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakAsk(self), name: "ask")
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.wantsLayer = true; webView.layer?.zPosition = 1_000_000          // 衛星的 zPosition 從 10 一直往上加
        webView.isHidden = true
        webView.onResign = { [weak self] in self?.js("window.askBlur && window.askBlur()") }
        webView.load(URLRequest(url: URL(string: "\(OfficeWebSchemeHandler.scheme)://web/ask.html")!))
        SphereEmbed.askPayload = { [weak self] d in self?.update(d) }
        SphereEmbed.askResult = { [weak self] sid, ask, text in self?.call("window.askResult", [sid, ask, text]) }
        SphereEmbed.askShow = { [weak self] sid in self?.call("window.askShow", [sid]) }
        // 衛星會被拖動、開關：縮成一條時每秒看一次有沒有擋到（沒動就不做事）
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { if self?.mode == "strip" { self?.layout() } } }
    }

    public func setTheme(_ name: String) { call("window.askTheme", [name]) }
    func update(_ d: Data) {
        pendingData = d
        guard ready else { return }
        js("window.askUpdate(\(String(decoding: d, as: UTF8.self)))")
    }
    public func webView(_ w: WKWebView, didFinish n: WKNavigation!) { layout() }
    /// 網頁程序當掉：重新載入（不會替使用者送任何東西；題目還在，可以再按）
    public func webViewWebContentProcessDidTerminate(_ w: WKWebView) { ready = false; mode = "hidden"; layout(); w.reload() }
    public var theme = "dark" { didSet { setTheme(theme) } }

    public func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { if let b = m.body as? [String: Any] { handle(b) } }
    func handle(_ b: [String: Any]) {
        let num = { (k: String) in CGFloat((b[k] as? NSNumber)?.doubleValue ?? 0) }
        switch b["action"] as? String {
        case "ready":
            ready = true; setTheme(theme); layout()
            if let d = pendingData ?? SphereEmbed.latestSphere { update(d) }
        case "askSize": mode = b["mode"] as? String ?? "hidden"; size = NSSize(width: num("w"), height: num("h")); layout()
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
            corner = NSPoint(x: root.width - webView.frame.maxX, y: webView.frame.minY)
            layout()
        default: break
        }
    }
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
        let f = mode == "strip" ? AskFloatLayout.strip(size, root: root, corner: corner, terminals: terminals()) : AskFloatLayout.card(size, root: root, corner: corner)
        if webView.frame != f { webView.frame = f }
    }
    // 測試（只給離屏測試用）：假題目、跑一段網頁程式；真的資料不再進來
    public func testUpdate(_ f: URL) { SphereEmbed.askPayload = nil; if let d = try? Data(contentsOf: f) { update(d) } }
    public func testJS(_ s: String) { js(s) }
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
