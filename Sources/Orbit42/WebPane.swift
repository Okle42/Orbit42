import AppKit
import WebKit

/// 衛星裡的網頁面板（11-24 Keng「看網頁也要成為一個小衛星，衛星終端機裡面也可以打開網頁」）。
/// 一般瀏覽器：自己的 WKWebView 設定，碰不到 Orbit42 的訊息通道；登入狀態存在 Orbit42 自己的網站資料裡。
@MainActor
final class WebPane: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let web: WKWebView
    private let address = NSTextField(), bar = NSStackView(), message = NSTextField(wrappingLabelWithString: "")
    var onShut: () -> Void = {}
    var onTuck: () -> Void = {}
    var onTitle: () -> Void = {}
    var onLoaded: (Bool) -> Void = { _ in }
    private var titleWatch: NSKeyValueObservation?

    override init(frame: NSRect) {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init(frame: frame)
        web.navigationDelegate = self; web.uiDelegate = self; web.allowsBackForwardNavigationGestures = true
        addSubview(web)
        for (t, a) in [("‹", #selector(back)), ("›", #selector(forward)), ("↻", #selector(reload))] {
            let b = NSButton(title: t, target: self, action: a); b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11); bar.addArrangedSubview(b)
        }
        address.font = .systemFont(ofSize: 11); address.placeholderString = "輸入網址"; address.delegate = self
        address.target = self; address.action = #selector(go); address.lineBreakMode = .byTruncatingTail; address.cell?.sendsActionOnEndEditing = false
        address.setContentHuggingPriority(.init(1), for: .horizontal)
        address.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        bar.addArrangedSubview(address)
        for (t, a, tip) in [("－", #selector(tuck), "收起（小衛星留著，點它叫回來）"), ("✕", #selector(shut), "關掉網頁（小衛星也不見）")] {
            let b = NSButton(title: t, target: self, action: a); b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11); b.toolTip = tip; bar.addArrangedSubview(b)
        }
        bar.spacing = 6; addSubview(bar)
        message.alignment = .center; message.isHidden = true; addSubview(message)
        titleWatch = web.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.onTitle() } }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 10, y: bounds.height - 30, width: max(0, bounds.width - 20), height: 24)
        web.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 34))
        message.frame = NSRect(x: 30, y: bounds.height / 2 - 30, width: max(0, bounds.width - 60), height: 60)
    }
    @objc private func back() { web.goBack() }
    @objc private func forward() { web.goForward() }
    @objc private func reload() { web.reload() }
    @objc private func shut() { onShut() }
    @objc private func tuck() { onTuck() }
    @objc private func go() { if let u = Self.parse(address.stringValue) { open(u) } }
    var titleText: String { web.title.flatMap { $0.isEmpty ? nil : $0 } ?? web.url?.host ?? "網頁" }
    var messageText: String { message.isHidden ? "" : message.stringValue }
    func focusAddress() { window?.makeFirstResponder(address) }

    /// 只收 http／https 和本機 .html；沒寫協定的補上（localhost、IP 補 http）
    static func parse(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("/") { let u = URL(fileURLWithPath: t); return ["html", "htm"].contains(u.pathExtension.lowercased()) ? u : nil }
        if let u = URL(string: t), let sc = u.scheme?.lowercased(), t.contains("://") { return ["http", "https"].contains(sc) && u.host != nil ? u : nil }
        guard !t.contains(" ") else { return nil }
        let local = t.hasPrefix("localhost") || t.range(of: #"^\d{1,3}(\.\d{1,3}){3}"#, options: .regularExpression) != nil
        guard let u = URL(string: (local ? "http://" : "https://") + t), let h = u.host, local || h.contains(".") else { return nil }
        return u
    }
    func open(_ u: URL) {
        message.isHidden = true
        address.stringValue = u.absoluteString
        if u.isFileURL { web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) } else { web.load(URLRequest(url: u)) }
    }
    func stop() { web.stopLoading(); web.load(URLRequest(url: URL(string: "about:blank")!)) }

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        message.isHidden = true
        if address.currentEditor() == nil { address.stringValue = w.url?.absoluteString ?? "" }
        onTitle()
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { onTitle(); onLoaded(true) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: any Error) { fail(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: any Error) { fail(e) }
    private func fail(_ e: any Error) {
        if (e as NSError).code == NSURLErrorCancelled { return }
        message.stringValue = "打不開這個網頁：\(e.localizedDescription)"; message.isHidden = false; onLoaded(false)
    }
    /// 「開新分頁」的連結：就在這裡開
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url, Self.parse(u.absoluteString) != nil { w.load(a.request) }
        return nil
    }
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = a.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data", "file"].contains(s) ? .allow : .cancel)      // mailto: 之類不處理
    }
}
