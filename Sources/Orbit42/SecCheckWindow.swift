import AppKit
import Orbit42App
import Orbit42Core

/// 本機資安體檢小視窗（11-28 Keng：Orbit42 原生、不用接 USB；規格 ~/.claude/SPEC-orbit42-本機資安體檢-20261128.md 第 1～9 項）。
/// 入口：App 選單「本機資安體檢⋯」，或 `orbit seccheck --open`。檢查邏輯在 Orbit42Core/SecCheck.swift（跟終端機指令同一套）；
/// 修正在 SecFix.swift：每一項先問、改前備份原值。
/// 外觀跟衛星視窗（TermWindowView）同一套：毛玻璃、34pt 標題列、Okle42 三顆燈、置中標題（深色護眼綠／淺色近黑）、
/// 細邊框（深色白／淺色深灰）；色票只用 Palette 的綠紅加 TermWindow 用過的白／灰階。深淺色跟著 Orbit42 主題即時換。
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

    /// Orbit42 換主題（球體的深色／淺色）時跟著換，跟衛星視窗一致
    func applyTheme(_ ap: NSAppearance?) { panel?.appearance = ap }

    @objc func open() {
        if let p = panel { p.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); view?.refresh(); return }
        let v = SecCheckView(frame: NSRect(x: 0, y: 0, width: SecCheckView.width, height: 600))
        let p = SecCheckPanel(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.isMovableByWindowBackground = true; p.level = .floating; p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: OrbitWindow.shared.themeNow == "light" ? .aqua : .darkAqua)
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

/// 體檢視窗用的灰階（全部取自 TermWindow.swift 已用過的值）
@MainActor
enum SecInk {
    static func primary(_ d: Bool) -> NSColor { d ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.08, alpha: 1) }
    static func secondary(_ d: Bool) -> NSColor { d ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.25, alpha: 1) }
    static func tertiary(_ d: Bool) -> NSColor { d ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.4, alpha: 1) }
    /// TermWindow 收起燈的灰
    static func gray(_ d: Bool) -> NSColor { d ? NSColor(srgbRed: 0.541, green: 0.541, blue: 0.561, alpha: 1) : NSColor(white: 0.55, alpha: 1) }
    /// TermWindow 邊框（clip.borderColor）
    static func hairline(_ d: Bool) -> NSColor { d ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.12) }
    /// 燈號色：正常綠、注意／危險紅（注意畫空心、危險畫實心）、列出／檢查中灰
    static func level(_ l: SecLevel, _ d: Bool) -> NSColor {
        switch l { case .ok: Palette.green; case .warn, .bad: Palette.red; case .info, .pending: gray(d) }
    }
    static func isDark(_ v: NSView) -> Bool { v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

@MainActor
final class SecCheckView: NSView {
    static let width: CGFloat = 480
    static let pad: CGFloat = 20
    /// 一列文字的寬度（視窗寬 − 左右邊距 − 捲軸空間 − 燈號點）
    static let textWidth: CGFloat = width - pad - 8 - 12 - 18
    var onClose: () -> Void = {}

    // 外框（照 TermWindowView）
    private let clip = NSView()
    private let glass = NSVisualEffectView()
    private let bar = NSView()
    private let lights = [TrafficLight(kind: .close), TrafficLight(kind: .minimize), TrafficLight(kind: .zoom)]
    private let titleLabel = NSTextField(labelWithString: "本機資安體檢")
    private let grip = ResizeGrip()

    private let summary = NSTextField(labelWithString: "檢查中⋯")
    private let note = NSTextField(wrappingLabelWithString: "只用 macOS 內建工具檢查。按「修正」前都會先問你，改之前會備份原值。")
    private let again = OrbitButton(title: "重新檢查")
    private let accept = OrbitButton(title: "DNS／代理是我設的")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let footLine = NSView()
    private let scroll = NSScrollView()
    private let list = FlippedStack()
    private var report: SecReport?
    private var running = false
    private var poll: Timer?
    /// 正在修正的項目（按鈕先停用）
    private var fixing: Int?
    private var msg: (text: String, tone: MsgTone, backup: String?)?
    enum MsgTone { case ok, fail, busy }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12; clip.layer?.masksToBounds = true; clip.layer?.borderWidth = 1
        glass.blendingMode = .behindWindow          // 獨立浮窗：透出桌面（衛星在球體視窗裡用 .withinWindow）
        glass.material = .popover                    // 跟衛星同一種材質
        glass.state = .active
        bar.wantsLayer = true
        for (i, l) in lights.enumerated() {
            l.target = self; l.action = #selector(light(_:))
            l.toolTip = ["關閉", "收起（從 App 選單「本機資安體檢⋯」再打開）", "放大到螢幕高度／還原（也可以雙擊標題列）"][i]
            l.setAccessibilityLabel(["關閉", "收起", "放大"][i])
            l.frame = NSRect(x: 14 + CGFloat(i) * 20, y: 11, width: 12, height: 12)
            bar.addSubview(l)
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold); titleLabel.alignment = .center
        bar.addSubview(titleLabel)
        grip.onDrag = { [weak self] _, dy in self?.resizeBy(dy: dy) }

        summary.font = .systemFont(ofSize: 13, weight: .semibold)
        note.font = .systemFont(ofSize: 11); note.preferredMaxLayoutWidth = Self.width - Self.pad * 2
        message.font = .systemFont(ofSize: 12); message.isSelectable = true; message.preferredMaxLayoutWidth = Self.width - Self.pad * 2
        message.isHidden = true
        again.target = self; again.action = #selector(rerun)
        accept.target = self; accept.action = #selector(acceptNetwork); accept.isHidden = true
        accept.toolTip = "把現在的 DNS 和代理設定記成基準，之後被改才會亮紅燈"
        footLine.wantsLayer = true
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 16
        list.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 12, right: 0)
        scroll.documentView = list; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        addSubview(clip)
        for v in [glass, bar] as [NSView] { clip.addSubview(v) }
        for v in [summary, note, scroll, footLine, message, accept, again] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; clip.addSubview(v) }
        addSubview(grip)
        list.translatesAutoresizingMaskIntoConstraints = false
        let pad = Self.pad
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: clip.topAnchor, constant: TermWindowView.barHeight + 12),
            summary.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: pad),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor, constant: -pad),
            note.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 4), note.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -pad),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 16), scroll.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: footLine.topAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -12),
            footLine.leadingAnchor.constraint(equalTo: clip.leadingAnchor), footLine.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            footLine.heightAnchor.constraint(equalToConstant: 1),
            message.bottomAnchor.constraint(equalTo: again.topAnchor, constant: -12),
            message.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: pad), message.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -pad),
            again.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -16), again.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -pad),
            accept.centerYAnchor.constraint(equalTo: again.centerYAnchor), accept.trailingAnchor.constraint(equalTo: again.leadingAnchor, constant: -8),
        ])
        lineToButtons = footLine.bottomAnchor.constraint(equalTo: again.topAnchor, constant: -12)
        lineToMessage = footLine.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -12)
        lineToButtons.isActive = true
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    /// 分隔線：沒訊息時貼按鈕列上方，有訊息時貼訊息上方
    private var lineToButtons: NSLayoutConstraint!, lineToMessage: NSLayoutConstraint!
    private var zoomedFrom: NSRect?
    /// 截圖用：離屏拍不到 behindWindow 的模糊（會變一塊灰），改成跟衛星一樣的 withinWindow 才能並排比
    func glassLikeSatellite() { glass.blendingMode = .withinWindow }

    override func layout() {
        clip.frame = bounds
        glass.frame = clip.bounds
        bar.frame = NSRect(x: 0, y: bounds.height - TermWindowView.barHeight, width: bounds.width, height: TermWindowView.barHeight)
        titleLabel.frame = NSRect(x: 80, y: 9, width: max(0, bounds.width - 160), height: 16)
        grip.frame = NSRect(x: bounds.width - 16, y: 0, width: 16, height: 16)
        super.layout()
    }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(NSSize(width: s.width.rounded(), height: s.height.rounded())) }

    var dark: Bool { SecInk.isDark(self) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        let d = dark
        glass.appearance = NSAppearance(named: d ? .darkAqua : .aqua)
        bar.layer?.backgroundColor = (d ? NSColor(white: 0.09, alpha: 0.12) : NSColor(white: 0.97, alpha: 0.12)).cgColor
        clip.layer?.borderColor = SecInk.hairline(d).cgColor
        footLine.layer?.backgroundColor = SecInk.hairline(d).cgColor
        titleLabel.textColor = d ? Palette.green : NSColor(white: 0.08, alpha: 1)
        summary.textColor = SecInk.primary(d)
        note.textColor = SecInk.tertiary(d)
        lights.forEach { $0.needsDisplay = true }
        grip.needsDisplay = true
        paintMessage()
        if let report { render(report) }
    }

    // MARK: 標題列：三顆燈、雙擊放大
    @objc private func light(_ s: TrafficLight) {
        switch s.kind {
        case .close, .minimize: onClose()
        case .zoom: toggleZoom()
        }
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2, p.y >= bounds.height - TermWindowView.barHeight { toggleZoom(); return }
        super.mouseDown(with: e)
    }
    private func toggleZoom() {
        guard let w = window, let s = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let target: NSRect
        if let back = zoomedFrom { target = back; zoomedFrom = nil }
        else { zoomedFrom = w.frame; target = NSRect(x: w.frame.minX, y: s.minY + 16, width: w.frame.width, height: s.height - 32) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            w.animator().setFrame(target, display: true)
        }
    }
    private func resizeBy(dy: CGFloat) {
        guard let w = window else { return }
        var f = w.frame
        let h = max(360, f.height - dy)
        f.origin.y += f.height - h; f.size.height = h
        w.setFrame(f, display: true); zoomedFrom = nil
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
    @objc private func acceptNetwork() {
        DispatchQueue.global(qos: .userInitiated).async {
            SecCheck.acceptNetworkBaseline()
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.setMessage("已記下現在的 DNS／代理當基準，之後被改會亮紅燈", tone: .ok); self.refresh()
            } }
        }
    }

    // MARK: 修正（先問 → 背景做 → 顯示結果 → 重跑體檢）
    @objc private func fixTap(_ b: OrbitButton) {
        guard fixing == nil, let r = report, let item = r.items.first(where: { $0.no == b.tag }),
              let fix = SecFixer.fix(for: item, report: r) else { return }
        let a = NSAlert()
        a.messageText = fix.label
        a.informativeText = fix.confirm + (fix.needsAdmin ? "\n\n接著會跳出 macOS 密碼視窗（Orbit42）。" : "")
        a.addButton(withTitle: "修正"); a.addButton(withTitle: "取消")
        a.window.appearance = window?.appearance ?? effectiveAppearance      // 跟著 Orbit42 主題
        guard a.runModal() == .alertFirstButtonReturn else { return }
        fixing = fix.item
        setMessage("正在修正第 \(fix.item) 項：\(fix.label)⋯", tone: .busy)
        render(r)
        DispatchQueue.global(qos: .userInitiated).async {
            let o = SecFixer.apply(fix)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.fixing = nil
                self.setMessage(o.message, tone: o.ok ? .ok : .fail, backup: o.backup)
                if let r = self.report { self.render(r) }
                self.refresh()
            } }
        }
    }
    func setMessage(_ s: String, tone: MsgTone, backup: String? = nil) {
        msg = (s, tone, backup); paintMessage()
    }
    private func paintMessage() {
        guard let msg else { message.isHidden = true; return }
        let d = dark
        let dot: (String, NSColor) = switch msg.tone {
        case .ok: ("●  ", Palette.green)
        case .fail: ("●  ", Palette.red)
        case .busy: ("○  ", SecInk.gray(d))
        }
        let s = NSMutableAttributedString(string: dot.0, attributes: [.foregroundColor: dot.1, .font: NSFont.systemFont(ofSize: 10)])
        s.append(NSAttributedString(string: msg.text, attributes: [.foregroundColor: SecInk.primary(d), .font: NSFont.systemFont(ofSize: 12, weight: .medium)]))
        if let b = msg.backup {
            s.append(NSAttributedString(string: "\n原值備份在 " + b, attributes: [.foregroundColor: SecInk.tertiary(d), .font: NSFont.systemFont(ofSize: 11)]))
        }
        message.attributedStringValue = s
        message.isHidden = false
        lineToButtons.isActive = false; lineToMessage.isActive = true
    }

    // MARK: 畫
    func render(_ r: SecReport) {
        let d = dark
        // 摘要兼圖例：危險實心紅、注意空心紅、正常綠、列出灰
        let parts: [(String, NSColor, String, Int)] = [("●", Palette.red, "危險", r.count(.bad)), ("○", Palette.red, "注意", r.count(.warn)),
                                                       ("●", Palette.green, "正常", r.count(.ok)), ("●", SecInk.gray(d), "列出", r.count(.info))]
            + (r.count(.pending) > 0 ? [("○", SecInk.gray(d), "檢查中", r.count(.pending))] : [])
        let s = NSMutableAttributedString()
        for (i, p) in parts.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "　　")) }
            s.append(NSAttributedString(string: p.0 + " ", attributes: [.foregroundColor: p.1, .font: NSFont.systemFont(ofSize: 11)]))
            s.append(NSAttributedString(string: "\(p.2) ", attributes: [.foregroundColor: SecInk.secondary(d), .font: NSFont.systemFont(ofSize: 13)]))
            s.append(NSAttributedString(string: "\(p.3)", attributes: [.foregroundColor: p.3 > 0 ? SecInk.primary(d) : SecInk.tertiary(d),
                                                                     .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]))
        }
        s.append(NSAttributedString(string: "　　用時 \(String(format: "%.1f", r.seconds)) 秒", attributes: [.foregroundColor: SecInk.tertiary(d), .font: NSFont.systemFont(ofSize: 11)]))
        summary.attributedStringValue = s
        accept.isHidden = !r.needsNetworkConfirm
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in r.items {
            let v = row(i, fix: SecFixer.fix(for: i, report: r))
            list.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
    private func row(_ i: SecItem, fix: SecFix?) -> NSView {
        let d = dark
        let box = NSView()
        let dot = LevelDot(level: i.level)
        let head = NSTextField(labelWithString: "\(i.no). \(i.title)")
        head.font = .systemFont(ofSize: 13, weight: .semibold); head.textColor = SecInk.primary(d)
        head.lineBreakMode = .byTruncatingTail
        head.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tag = LevelTag(level: i.level)
        let detail = wrap(i.detail, color: SecInk.secondary(d))
        var views: [NSView] = [dot, head, tag, detail]
        var why: NSTextField?
        if let w = i.why, i.level != .ok {
            let s = NSMutableAttributedString(string: "→ ", attributes: [.foregroundColor: SecInk.level(i.level, d), .font: NSFont.systemFont(ofSize: 12, weight: .bold)])
            s.append(NSAttributedString(string: w, attributes: [.foregroundColor: SecInk.primary(d), .font: NSFont.systemFont(ofSize: 12)]))
            let f = wrap("", color: SecInk.primary(d)); f.attributedStringValue = s
            why = f; views.append(f)
        }
        var button: OrbitButton?
        if let fix {
            let b = OrbitButton(title: fix.label, danger: i.level == .bad)
            b.tag = i.no; b.target = self; b.action = #selector(fixTap(_:))
            b.isEnabled = fixing == nil
            b.toolTip = fix.confirm
            b.setAccessibilityLabel("第 \(i.no) 項修正：\(fix.label)")
            button = b; views.append(b)
        }
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        var cs: [NSLayoutConstraint] = [
            dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            dot.leadingAnchor.constraint(equalTo: box.leadingAnchor), dot.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            head.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            tag.leadingAnchor.constraint(equalTo: head.trailingAnchor, constant: 8), tag.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: head.leadingAnchor), detail.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            detail.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 4),
        ]
        if let button {
            cs += [button.trailingAnchor.constraint(equalTo: box.trailingAnchor), button.topAnchor.constraint(equalTo: box.topAnchor),
                   head.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                   tag.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8)]
        } else {
            cs += [head.topAnchor.constraint(equalTo: box.topAnchor), tag.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor)]
        }
        if let why {
            cs += [why.leadingAnchor.constraint(equalTo: head.leadingAnchor), why.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                   why.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 4), why.bottomAnchor.constraint(equalTo: box.bottomAnchor)]
        } else { cs.append(detail.bottomAnchor.constraint(equalTo: box.bottomAnchor)) }
        NSLayoutConstraint.activate(cs)
        return box
    }
    private func wrap(_ s: String, color: NSColor) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .systemFont(ofSize: 12); f.textColor = color; f.isSelectable = true
        f.preferredMaxLayoutWidth = Self.textWidth
        return f
    }
}

/// 燈號點：正常綠實心、危險紅實心、注意紅空心、列出灰實心、檢查中灰空心
final class LevelDot: NSView {
    let level: SecLevel
    init(level: SecLevel) { self.level = level; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let d = SecInk.isDark(self), c = SecInk.level(level, d)
        if level == .warn || level == .pending {
            let p = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; c.setStroke(); p.stroke()
        } else {
            c.setFill(); NSBezierPath(ovalIn: bounds).fill()
        }
    }
}

/// 燈號文字標籤：危險＝紅底白字；注意＝紅框；正常＝綠框；列出／檢查中＝灰框（框內字都用主文字色，深色底上才讀得清）
final class LevelTag: NSView {
    let level: SecLevel
    init(level: SecLevel) { self.level = level; super.init(frame: .zero); setAccessibilityLabel(level.label); setAccessibilityRole(.staticText) }
    required init?(coder: NSCoder) { fatalError() }
    private var font: NSFont { .systemFont(ofSize: 11, weight: .semibold) }
    override var intrinsicContentSize: NSSize {
        let s = (level.label as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width) + 12, height: 18)
    }
    override func draw(_ r: NSRect) {
        let d = SecInk.isDark(self), c = SecInk.level(level, d)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        let ink: NSColor
        if level == .bad { c.setFill(); path.fill(); ink = .white }
        else {
            path.lineWidth = 1; (level == .info || level == .pending ? c : c.withAlphaComponent(0.9)).setStroke(); path.stroke()
            ink = level == .info || level == .pending ? SecInk.secondary(d) : SecInk.primary(d)
        }
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let s = (level.label as NSString).size(withAttributes: a)
        (level.label as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: a)
    }
}

/// Orbit42 風的小按鈕：膠囊、1px 細框（危險列紅框、其他灰框），滑過補一層淡底；不用系統灰色 rounded 按鈕
final class OrbitButton: NSButton {
    var danger: Bool { didSet { needsDisplay = true } }
    private var hover = false
    private var pressed = false
    init(title: String, danger: Bool = false) {
        self.danger = danger
        super.init(frame: .zero)
        self.title = title
        isBordered = false; focusRingType = .exterior
        setButtonType(.momentaryChange)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    private var labelFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }
    override var intrinsicContentSize: NSSize {
        let s = (title as NSString).size(withAttributes: [.font: labelFont])
        return NSSize(width: ceil(s.width) + 24, height: 24)
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) {
        guard isEnabled else { return }
        pressed = true; needsDisplay = true
        super.mouseDown(with: e)            // 追蹤滑鼠到放開，放開時在按鈕上才送 action
        pressed = false; needsDisplay = true
    }
    private var shape: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: (bounds.height - 1) / 2, yRadius: (bounds.height - 1) / 2) }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { shape.fill() }
    override func draw(_ r: NSRect) {
        let d = SecInk.isDark(self)
        let p = shape
        if isEnabled, hover || pressed {
            (d ? NSColor(white: 1, alpha: pressed ? 0.16 : 0.08) : NSColor(white: 0, alpha: pressed ? 0.10 : 0.05)).setFill(); p.fill()
        }
        let border: NSColor = danger ? Palette.red : (d ? NSColor(white: 1, alpha: 0.35) : NSColor(white: 0, alpha: 0.28))
        let ink: NSColor = danger && !d ? Palette.red : SecInk.primary(d)
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        p.lineWidth = 1; border.withAlphaComponent(border.alphaComponent * alpha).setStroke(); p.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: ink.withAlphaComponent(alpha)]
        let s = (title as NSString).size(withAttributes: a)
        (title as NSString).draw(at: NSPoint(x: ((bounds.width - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded()), withAttributes: a)
    }
}

/// 清單由上往下排
final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

/// 測試：ORBIT_TEST_SECCHECK_SHOT=<資料夾> ⇒ 實跑一次體檢，同一個視圖先深色拍、再即時切淺色拍（驗深淺色即時換）；
/// 另外把體檢視圖跟一個衛星外框（TermWindowView）並排拍成對照圖。印結果後結束。不開視窗、不碰正在跑的 Orbit42。
/// 離屏拍不到毛玻璃（cacheDisplay 不畫 NSVisualEffectView 的模糊），所以後面墊一塊接近 popover 材質的灰底。
@MainActor
enum SecCheckShot {
    static func run(_ dir: String) -> Never {
        _ = NSApplication.shared
        let r = SecCheck.run()
        print(String(format: "seccheck %.2fs", r.seconds))
        for i in r.items { print("\(i.no) \(i.level.rawValue) \(i.title)：\(i.detail)") }
        let H: CGFloat = 1040, gap: CGFloat = 32, m: CGFloat = 24
        let v = SecCheckView(frame: NSRect(x: m, y: m, width: SecCheckView.width, height: H))
        v.glassLikeSatellite()
        let sat = TermWindowView(content: NSView())
        sat.titleLabel.stringValue = "Demo · Orbit42"
        sat.frame = NSRect(x: m + SecCheckView.width + gap, y: m, width: 480, height: H)
        let board = ShotBoard(frame: NSRect(x: 0, y: 0, width: m * 2 + SecCheckView.width * 2 + gap, height: H + m * 2))
        board.addSubview(v); board.addSubview(sat)
        let w = NSWindow(contentRect: board.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = board
        v.show(r)
        if ProcessInfo.processInfo.environment["ORBIT_TEST_SECCHECK_MSG"] != nil {
            v.setMessage("（截圖示範）已打開防火牆", tone: .ok, backup: SecCheck.dir.appendingPathComponent("backups/20261128-120000-item2.json").path)
        }
        for (name, ap) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            board.appearance = NSAppearance(named: ap)          // 同一組視圖切外觀（不重建）
            board.layoutSubtreeIfNeeded(); board.displayIfNeeded()
            func save(_ rect: NSRect, _ file: String) {
                guard let rep = board.bitmapImageRepForCachingDisplay(in: rect) else { return }
                board.cacheDisplay(in: rect, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("shot \(url.path)")
            }
            save(v.frame.insetBy(dx: -m, dy: -m), "seccheck-\(name).png")
            save(board.bounds, "seccheck-vs-sat-\(name).png")
        }
        exit(0)
    }
}

/// 截圖用底板：墊接近 popover 材質的灰（離屏拍不到毛玻璃）
final class ShotBoard: NSView {
    override func draw(_ r: NSRect) {
        (SecInk.isDark(self) ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill(); r.fill()
    }
}
