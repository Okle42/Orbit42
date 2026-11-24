import AppKit

/// 衛星裡的網頁面板（11-24 Keng「看網頁也要成為一個小衛星，衛星終端機裡面也可以打開網頁」「衛星裡嵌真的 Chrome」）。
/// 內容是背景 Chrome 的一頁（Chrome.swift）；登入存在 Orbit42 自己的 Chrome 設定檔，跟平常的 Chrome 分開。
@MainActor
final class WebPane: NSView, NSTextFieldDelegate {
    let web = ChromeView(frame: .zero)
    private let address = NSTextField(), bar = NSStackView(), message = NSTextField(wrappingLabelWithString: "")
    var onShut: () -> Void = {}
    var onTuck: () -> Void = {}
    var onTitle: () -> Void = {}
    var onLoaded: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        web.onChange = { [weak self] in
            guard let self else { return }
            if self.address.currentEditor() == nil { self.address.stringValue = self.web.url?.absoluteString ?? "" }
            self.onTitle()
        }
        web.onLoaded = { [weak self] in self?.onTitle(); self?.onLoaded(true) }
        web.onError = { [weak self] m in
            guard let self else { return }
            self.message.stringValue = m; self.message.isHidden = m.isEmpty
            if !m.isEmpty { self.onLoaded(false) }
        }
        addSubview(web)
        for (t, a) in [("‹", #selector(back)), ("›", #selector(forward)), ("↻", #selector(reload))] {
            let b = NSButton(title: t, target: self, action: a); b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11); bar.addArrangedSubview(b)
        }
        address.font = .systemFont(ofSize: 11); address.placeholderString = "輸入網址"; address.delegate = self
        address.target = self; address.action = #selector(go); address.lineBreakMode = .byTruncatingTail; address.cell?.sendsActionOnEndEditing = false
        address.setContentHuggingPriority(.init(1), for: .horizontal)
        address.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        bar.addArrangedSubview(address)
        for (t, a, tip) in [("Chrome", #selector(chrome), "用 Chrome 開這一頁"), ("－", #selector(tuck), "收起（小衛星留著，點它叫回來）"), ("✕", #selector(shut), "關掉網頁（小衛星也不見）")] {
            let b = NSButton(title: t, target: self, action: a); b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11); b.toolTip = tip; bar.addArrangedSubview(b)
        }
        bar.spacing = 6; addSubview(bar)
        message.alignment = .center; message.isHidden = true; addSubview(message)
        message.drawsBackground = true; message.backgroundColor = .windowBackgroundColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 10, y: bounds.height - 30, width: max(0, bounds.width - 20), height: 24)
        web.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 34))
        message.frame = NSRect(x: 30, y: bounds.height / 2 - 30, width: max(0, bounds.width - 60), height: 60)
    }
    @objc private func back() { web.go(-1) }
    @objc private func forward() { web.go(1) }
    @objc private func reload() { web.reload() }
    @objc private func chrome() {
        guard let u = web.url.flatMap({ Self.parse($0.absoluteString) }) ?? Self.parse(address.stringValue),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { NSSound.beep(); return }
        NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func shut() { onShut() }
    @objc private func tuck() { onTuck() }
    @objc private func go() { if let u = Self.parse(address.stringValue) { open(u) } }
    var titleText: String { (web.title.isEmpty ? nil : web.title) ?? web.url?.host ?? "網頁" }
    var currentURL: String { let u = web.url?.absoluteString ?? ""; return u == "about:blank" ? "" : u }
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
        web.load(u)
        window?.makeFirstResponder(web)
    }
    func stop() { web.close() }
}
