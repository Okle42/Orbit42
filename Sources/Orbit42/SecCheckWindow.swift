import AppKit
import Orbit42App
import Orbit42Core

/// 本機資安體檢小視窗（11-28 Keng：Orbit42 原生、不用接 USB；規格 ~/.claude/SPEC-orbit42-本機資安體檢-20261128.md 第 1～9 項）。
/// 入口：App 選單「本機資安體檢⋯」，或 `orbit seccheck --open`。檢查邏輯在 Orbit42Core/SecCheck.swift（跟終端機指令同一套），全部只看不改。
/// 深色／淺色即時換：色票只用 Palette；深色白邊框、淺色深灰邊框；標題深色護眼綠、淺色紅。
@MainActor
final class SecCheckWindow: NSObject {
    static let shared = SecCheckWindow()
    private var panel: NSPanel?
    private var view: SecCheckView?

    func installMenu() {
        let i = NSMenuItem(title: "本機資安體檢⋯", action: #selector(open), keyEquivalent: "")
        i.target = self; _ = EditMenu.addAppItem(i)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("ai.okle42.orbit42.seccheck"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecCheckWindow.shared.open() }
        }
    }

    @objc func open() {
        if let p = panel { p.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); view?.refresh(); return }
        let v = SecCheckView(frame: NSRect(x: 0, y: 0, width: SecCheckView.width, height: 560))
        let p = SecCheckPanel(contentRect: v.frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.isMovableByWindowBackground = true; p.level = .floating; p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 380, height: 320)
        p.contentView = v
        v.onClose = { [weak p] in p?.orderOut(nil) }
        if let s = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: s.midX - v.frame.width / 2, y: s.midY - v.frame.height / 2)) }
        panel = p; view = v
        p.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        v.refresh()
    }
}

final class SecCheckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }     // Esc 關掉
}

@MainActor
final class SecCheckView: NSView {
    static let width: CGFloat = 460
    var onClose: () -> Void = {}
    private let title = NSTextField(labelWithString: "本機資安體檢")
    private let summary = NSTextField(labelWithString: "檢查中⋯")
    private let note = NSTextField(labelWithString: "只看不改：只用 macOS 內建工具檢查這台電腦和目前連的網路")
    private let again = NSButton(title: "重新檢查", target: nil, action: nil)
    private let accept = NSButton(title: "DNS／代理是我設的", target: nil, action: nil)
    private let close = NSButton(title: "✕", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let list = FlippedStack()
    private var report: SecReport?
    private var running = false
    private var poll: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12; layer?.borderWidth = 1; layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        summary.font = .systemFont(ofSize: 13, weight: .medium)
        note.font = .systemFont(ofSize: 11)
        for b in [again, accept] { b.bezelStyle = .rounded; b.controlSize = .regular; b.target = self }
        again.action = #selector(rerun); accept.action = #selector(acceptNetwork); accept.isHidden = true
        close.isBordered = false; close.font = .systemFont(ofSize: 14, weight: .medium); close.target = self; close.action = #selector(closeTap)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 10
        list.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
        scroll.documentView = list; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autohidesScrollers = true
        for v in [title, summary, note, again, accept, close, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        list.translatesAutoresizingMaskIntoConstraints = false
        let pad: CGFloat = 18
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16), title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor), close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            summary.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6), summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            note.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 3), note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: again.topAnchor, constant: -12),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -10),
            again.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14), again.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            accept.centerYAnchor.constraint(equalTo: again.centerYAnchor), accept.trailingAnchor.constraint(equalTo: again.leadingAnchor, constant: -8),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        let d = dark
        layer?.backgroundColor = (d ? NSColor(white: 0.09, alpha: 0.97) : NSColor(white: 0.98, alpha: 0.97)).cgColor
        layer?.borderColor = (d ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0.22, alpha: 0.85)).cgColor      // 深色白邊、淺色深灰邊
        title.textColor = d ? Palette.green : Palette.red
        summary.textColor = d ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        note.textColor = d ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.4, alpha: 1)
        close.contentTintColor = d ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.3, alpha: 1)
        if let report { render(report) }
    }

    // MARK: 跑
    func refresh() {
        guard !running else { return }
        running = true; again.isEnabled = false; summary.stringValue = "檢查中⋯"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = SecCheck.run()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.running = false; self.again.isEnabled = true; self.show(r) } }
        }
    }
    func show(_ r: SecReport) {
        report = r; render(r)
        // 第 4 項背景查：查完自動更新（每 5 秒看一次快取，最多 10 分鐘）
        poll?.invalidate(); poll = nil
        if r.count(.pending) > 0 {
            var n = 0
            poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in MainActor.assumeIsolated {
                n += 1
                guard let self, self.window?.isVisible == true, n < 120 else { t.invalidate(); return }
                let u = SecCheck.updates()
                if u.level != .pending, var cur = self.report, let i = cur.items.firstIndex(where: { $0.no == 4 }) {
                    cur.items[i] = u; self.report = cur; self.render(cur); t.invalidate()
                }
            } }
        }
    }
    @objc private func rerun() { refresh() }
    @objc private func closeTap() { onClose() }
    @objc private func acceptNetwork() {
        DispatchQueue.global(qos: .userInitiated).async {
            SecCheck.acceptNetworkBaseline()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
        }
    }

    // MARK: 畫
    private func color(_ l: SecLevel) -> NSColor {
        switch l {
        case .ok: Palette.green
        case .warn: Palette.amber
        case .bad: Palette.red
        case .info, .pending: dark ? NSColor(white: 0.55, alpha: 1) : NSColor(white: 0.5, alpha: 1)
        }
    }
    func render(_ r: SecReport) {
        summary.stringValue = "綠 \(r.count(.ok))・黃 \(r.count(.warn))・紅 \(r.count(.bad))・列出 \(r.count(.info))"
            + (r.count(.pending) > 0 ? "・檢查中 \(r.count(.pending))" : "") + "　用時 \(String(format: "%.1f", r.seconds)) 秒"
        accept.isHidden = !r.needsNetworkConfirm
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in r.items { list.addArrangedSubview(row(i)) }
    }
    private func row(_ i: SecItem) -> NSView {
        let d = dark, c = color(i.level)
        let box = NSView(); box.translatesAutoresizingMaskIntoConstraints = false
        let dot = NSView(); dot.wantsLayer = true; dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 5
        if i.level == .pending { dot.layer?.borderWidth = 1.5; dot.layer?.borderColor = c.cgColor } else { dot.layer?.backgroundColor = c.cgColor }
        let head = NSTextField(labelWithString: "\(i.no). \(i.title)")
        head.font = .systemFont(ofSize: 13, weight: .semibold); head.textColor = d ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.08, alpha: 1)
        let tag = NSTextField(labelWithString: i.level.label)
        tag.font = .systemFont(ofSize: 11, weight: .semibold); tag.textColor = i.level == .info || i.level == .pending ? c : (d ? NSColor(white: 0.05, alpha: 1) : .white)
        tag.wantsLayer = true; tag.drawsBackground = false
        let tagBox = NSView(); tagBox.wantsLayer = true; tagBox.layer?.cornerRadius = 4
        if i.level == .info || i.level == .pending { tagBox.layer?.borderWidth = 1; tagBox.layer?.borderColor = c.cgColor } else { tagBox.layer?.backgroundColor = c.cgColor }
        let detail = wrap(i.detail, size: 12, color: d ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.25, alpha: 1))
        var views: [NSView] = [dot, head, tagBox, tag, detail]
        var why: NSTextField?
        if let w = i.why, i.level != .ok {
            let f = wrap("→ " + w, size: 12, color: i.level == .bad ? Palette.red : i.level == .warn ? (d ? Palette.amber : NSColor(srgbRed: 0.55, green: 0.36, blue: 0.02, alpha: 1)) : (d ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.38, alpha: 1)))
            why = f; views.append(f)
        }
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        var cs: [NSLayoutConstraint] = [
            dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            dot.leadingAnchor.constraint(equalTo: box.leadingAnchor), dot.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            head.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8), head.topAnchor.constraint(equalTo: box.topAnchor),
            tagBox.leadingAnchor.constraint(equalTo: head.trailingAnchor, constant: 8), tagBox.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            tag.leadingAnchor.constraint(equalTo: tagBox.leadingAnchor, constant: 6), tag.trailingAnchor.constraint(equalTo: tagBox.trailingAnchor, constant: -6),
            tag.topAnchor.constraint(equalTo: tagBox.topAnchor, constant: 1), tag.bottomAnchor.constraint(equalTo: tagBox.bottomAnchor, constant: -1),
            tagBox.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
            detail.leadingAnchor.constraint(equalTo: head.leadingAnchor), detail.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            detail.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 3),
        ]
        if let why {
            cs += [why.leadingAnchor.constraint(equalTo: head.leadingAnchor), why.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                   why.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 3), why.bottomAnchor.constraint(equalTo: box.bottomAnchor)]
        } else { cs.append(detail.bottomAnchor.constraint(equalTo: box.bottomAnchor)) }
        NSLayoutConstraint.activate(cs)
        box.widthAnchor.constraint(equalToConstant: Self.width - 46).isActive = true
        return box
    }
    private func wrap(_ s: String, size: CGFloat, color: NSColor) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .systemFont(ofSize: size); f.textColor = color; f.isSelectable = true
        f.preferredMaxLayoutWidth = Self.width - 64
        return f
    }
}

/// 清單由上往下排
final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

/// 測試：ORBIT_TEST_SECCHECK_SHOT=<資料夾> ⇒ 實跑一次體檢，同一個視圖先深色拍、再即時切淺色拍（驗深淺色即時換），印結果後結束。
/// 不開視窗、不碰正在跑的 Orbit42。
@MainActor
enum SecCheckShot {
    static func run(_ dir: String) -> Never {
        _ = NSApplication.shared
        let r = SecCheck.run()
        print(String(format: "seccheck %.2fs", r.seconds))
        for i in r.items { print("\(i.no) \(i.level.rawValue) \(i.title)：\(i.detail)") }
        let v = SecCheckView(frame: NSRect(x: 0, y: 0, width: SecCheckView.width, height: 900))
        let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = v
        v.show(r)
        for (name, ap) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            v.appearance = NSAppearance(named: ap)
            v.layoutSubtreeIfNeeded(); v.displayIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("seccheck-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("shot \(url.path)")
        }
        exit(0)
    }
}

