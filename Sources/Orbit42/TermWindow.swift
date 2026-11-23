import WebKit
import AppKit

/// A satellite's terminal as a small window inside Orbit42: title bar you can drag, macOS-style
/// traffic lights in Okle42 colors (red = end, gray = tuck away, white = fill the screen),
/// resize from the bottom-right corner, rounded corners and a shadow. Frame is remembered.
@MainActor
final class TermWindowView: NSView {
    let content: NSView
    let titleLabel = NSTextField(labelWithString: "")
    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}
    var wantShown = false                 // 目前該不該顯示（收起動畫跑到一半又被打開時用）
    private let bar = NSView()
    private let glass = NSVisualEffectView()
    private let lights: [TrafficLight]
    private var zoomedFrom: NSRect?
    static let barHeight: CGFloat = 34
    private static let key = "orbit.term.frame"

    init(content: NSView) {
        self.content = content
        lights = [TrafficLight(kind: .close), TrafficLight(kind: .minimize), TrafficLight(kind: .zoom)]
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = false
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -8)

        let clip = NSView()                         // rounded clip for the bar + terminal
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1
        clip.autoresizingMask = [.width, .height]
        addSubview(clip)

        // 11-23 Keng「衛星終端機也要毛玻璃半透明」：最底層是 macOS 原生模糊材質，透出後面的球體；標題列和終端機底色都半透明
        glass.blendingMode = .withinWindow
        glass.material = .popover          // 11-23：hudWindow 太霧，popover 比較透
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        clip.addSubview(glass)

        bar.wantsLayer = true
        bar.autoresizingMask = [.width, .minYMargin]
        clip.addSubview(bar)
        clip.addSubview(content)
        content.autoresizingMask = [.width, .height]

        for (i, l) in lights.enumerated() {
            l.frame = NSRect(x: 14 + CGFloat(i) * 20, y: 11, width: 12, height: 12)
            l.target = self; l.action = #selector(light(_:))
            bar.addSubview(l)
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.autoresizingMask = [.width]
        bar.addSubview(titleLabel)

        let grip = ResizeGrip()
        grip.onDrag = { [weak self] dx, dy in self?.resizeBy(dx: dx, dy: dy) }
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(grip)
        self.grip = grip
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var grip: ResizeGrip!

    /// 11-23 Keng：打開時邊框亮一下紅光（跟 ShoWork 光暈同一個感覺），0.9 秒淡掉
    func flash() {
        guard let clip = subviews.first?.layer, let me = layer else { return }
        let red = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1).cgColor
        let base = clip.borderColor
        let border = CAKeyframeAnimation(keyPath: "borderColor")
        border.values = [red, red, base as Any]; border.keyTimes = [0, 0.35, 1]
        let width = CAKeyframeAnimation(keyPath: "borderWidth")
        width.values = [2.5, 2.5, 1]; width.keyTimes = [0, 0.35, 1]
        for a in [border, width] { a.duration = 0.9; a.timingFunction = CAMediaTimingFunction(name: .easeOut) }
        clip.add(border, forKey: "flashBorder"); clip.add(width, forKey: "flashWidth")
        let glow = CAKeyframeAnimation(keyPath: "shadowColor")
        glow.values = [red, red, NSColor.black.cgColor]; glow.keyTimes = [0, 0.35, 1]; glow.duration = 0.9
        let gr = CAKeyframeAnimation(keyPath: "shadowRadius")
        gr.values = [14, 14, 24]; gr.keyTimes = [0, 0.35, 1]; gr.duration = 0.9
        me.add(glow, forKey: "flashGlow"); me.add(gr, forKey: "flashGlowR")
    }

    /// 11-23 Keng：衛星在工作（有輸出）時邊框紅色呼吸光，停下來熄掉
    private var breathing = false
    func setBreathing(_ on: Bool) {
        guard on != breathing, let clip = subviews.first?.layer, let me = layer else { return }
        breathing = on
        if on {
            let red = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1).cgColor
            let border = CABasicAnimation(keyPath: "borderColor")
            border.fromValue = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.25).cgColor; border.toValue = red
            // 11-23 Keng「呼吸光範圍太大」：光暈只貼著邊框一圈（半徑 6→12），不再往外擴散一大片
            let width = CABasicAnimation(keyPath: "borderWidth"); width.fromValue = 1; width.toValue = 1.6
            let glow = CABasicAnimation(keyPath: "shadowColor"); glow.fromValue = NSColor.black.cgColor; glow.toValue = red
            let gr = CABasicAnimation(keyPath: "shadowRadius"); gr.fromValue = 6; gr.toValue = 12
            for a in [border, width, glow, gr] {
                a.duration = 1.4; a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            clip.add(border, forKey: "breathB"); clip.add(width, forKey: "breathW")
            me.add(glow, forKey: "breathG"); me.add(gr, forKey: "breathR")
        } else {
            for k in ["breathB", "breathW"] { clip.removeAnimation(forKey: k) }
            for k in ["breathG", "breathR"] { me.removeAnimation(forKey: k) }
        }
    }

    // MARK: 拖檔案／截圖進來（11-23 Keng）：像 Ghostty 一樣把路徑貼進終端機（空白等特殊字元加反斜線），Claude Code 會把圖片當附件
    var onDropPaths: ([String]) -> Void = { _ in }
    func acceptFileDrops() {
        // 11-23 修：之前只在小視窗註冊、把網頁的拖放取消，但 WKWebView 會自己重新註冊、搶在前面 ⇒ 檔案拖進來沒反應
        // ⇒ 網頁視圖（DropWebView）自己接檔案，轉給這裡；小視窗本身（標題列）也照樣接
        registerForDraggedTypes([.fileURL])
        if let w = content as? DropWebView {
            w.onFiles = { [weak self] urls in self?.onDropPaths(urls.map { Self.shellEscape($0.path) }) }
            w.onHover = { [weak self] on in
                self?.layer?.borderWidth = on ? 2 : 0
                self?.layer?.borderColor = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.9).cgColor
            }
        }
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        layer?.borderWidth = 2; layer?.borderColor = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.9).cgColor; return .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { layer?.borderWidth = 0 }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropPaths(urls.map { Self.shellEscape($0.path) })
        return true
    }
    static func shellEscape(_ p: String) -> String {
        var out = ""
        for ch in p { if " \'\"()[]{}&;$!*?<>|`#~".contains(ch) { out.append("\\") }; out.append(ch) }
        return out
    }

    override func layout() {
        super.layout()
        guard let clip = subviews.first else { return }
        clip.frame = bounds
        bar.frame = NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: Self.barHeight)
        titleLabel.frame = NSRect(x: 80, y: 9, width: max(0, bounds.width - 160), height: 16)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.barHeight)
        grip.frame = NSRect(x: bounds.width - 16, y: 0, width: 16, height: 16)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        bar.layer?.backgroundColor = (dark ? NSColor(white: 0.09, alpha: 0.12) : NSColor(white: 0.97, alpha: 0.12)).cgColor   // 11-23 Keng：再透一點
        subviews.first?.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.12)).cgColor
        titleLabel.textColor = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.08, alpha: 1)
        lights.forEach { $0.needsDisplay = true }
    }

    // MARK: drag the title bar to move
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard p.y >= bounds.height - Self.barHeight else { return super.mouseDown(with: e) }
        if e.clickCount == 2 { toggleZoom(); return }           // double-click the title bar = fill / restore, like macOS
        dragStart = (e.locationInWindow, frame.origin)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let d = dragStart, let sup = superview else { return }
        var o = NSPoint(x: d.origin.x + e.locationInWindow.x - d.mouse.x, y: d.origin.y + e.locationInWindow.y - d.mouse.y)
        o.x = min(max(o.x, -frame.width + 120), sup.bounds.width - 120)       // keep the title bar reachable
        o.y = min(max(o.y, -frame.height + Self.barHeight + 8), sup.bounds.height - Self.barHeight)
        setFrameOrigin(o); zoomedFrom = nil
    }
    override func mouseUp(with e: NSEvent) { if dragStart != nil { dragStart = nil; save() } }

    func resizeBy(dx: CGFloat, dy: CGFloat) {
        var f = frame
        f.size.width = max(420, f.width + dx)
        let h = max(260, f.height - dy)
        f.origin.y += f.height - h; f.size.height = h
        frame = f; zoomedFrom = nil
        needsLayout = true
    }

    @objc private func light(_ s: TrafficLight) {
        switch s.kind {
        case .close: onClose()
        case .minimize: onMinimize()
        case .zoom: toggleZoom()
        }
    }

    func toggleZoom() {
        guard let sup = superview else { return }
        let target: NSRect
        if let back = zoomedFrom { target = back; zoomedFrom = nil }
        else { zoomedFrom = frame; target = sup.bounds.insetBy(dx: 16, dy: 16).offsetBy(dx: 0, dy: -8) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28; ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animator().frame = target
        } completionHandler: { [weak self] in MainActor.assumeIsolated { self?.save() } }
    }

    /// Remembered frame, or a default on the right side of `bounds`
    func restoredFrame(in bounds: NSRect) -> NSRect {
        var f: NSRect
        if let s = UserDefaults.standard.string(forKey: Self.key), case let r = NSRectFromString(s), r.width >= 420, r.height >= 260 { f = r }
        else { let w = max(560, bounds.width * 0.5); f = NSRect(x: bounds.width - w - 28, y: 40, width: w, height: bounds.height - 120) }
        return Self.fit(f, in: bounds)
    }
    /// 11-23 Keng：記住的大小比目前 Orbit42 視窗還大（例如上次在全螢幕）⇒ 縮進來、整個留在視窗裡（上面留標題列的空間）
    static func fit(_ r: NSRect, in b: NSRect) -> NSRect {
        var f = r
        f.size.width = min(f.width, max(420, b.width - 32))
        f.size.height = min(f.height, max(260, b.height - 72))
        f.origin.x = min(max(f.origin.x, 16), max(16, b.width - f.width - 16))
        f.origin.y = min(max(f.origin.y, 16), max(16, b.height - f.height - 44))
        return f
    }
    func save() { if zoomedFrom == nil { UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.key) } }
}

/// One traffic light. Okle42 colors instead of red/yellow/green: red closes, gray tucks away, white fills.
final class TrafficLight: NSButton {
    enum Kind { case close, minimize, zoom }
    let kind: Kind
    private var hover = false
    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false; title = ""
        toolTip = ["結束這顆衛星（Orbit42 開的會關掉；拉進來看的背景 session 只關檢視）", "收起（衛星繼續跑）", "放大／還原（也可以雙擊標題列）"][[Kind.close, .minimize, .zoom].firstIndex(of: kind)!]
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true; superview?.subviews.forEach { $0.needsDisplay = true } }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func draw(_ r: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Okle42 色票（跟 Ghostty Okle42-Dark／Light、球體同一組）：
        //   深色：紅 #ff3b30／灰 #8a8a8f／白 #ededed，外圈淡黑線讓白點在深灰標題列上有邊
        //   淺色：紅 #d7261b／灰 #8c8c8c／白 #ffffff，外圈加深一點（白點在淺灰標題列上才看得到）
        let fill: NSColor, ring: NSColor
        switch kind {
        case .close: fill = dark ? NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1) : NSColor(srgbRed: 0.843, green: 0.149, blue: 0.106, alpha: 1)
        case .minimize: fill = dark ? NSColor(srgbRed: 0.541, green: 0.541, blue: 0.561, alpha: 1) : NSColor(white: 0.55, alpha: 1)
        case .zoom: fill = dark ? NSColor(srgbRed: 0.929, green: 0.929, blue: 0.929, alpha: 1) : .white
        }
        ring = kind == .zoom && !dark ? NSColor(white: 0, alpha: 0.35) : NSColor(white: 0, alpha: dark ? 0.45 : 0.18)
        let c = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        fill.setFill(); c.fill()
        ring.setStroke(); c.lineWidth = 0.7; c.stroke()
        guard hover else { return }
        // symbol on hover, like macOS
        let g = NSBezierPath(); g.lineWidth = 1.3; g.lineCapStyle = .round
        let b = bounds.insetBy(dx: 3.5, dy: 3.5)
        switch kind {
        case .close: g.move(to: b.origin); g.line(to: NSPoint(x: b.maxX, y: b.maxY)); g.move(to: NSPoint(x: b.minX, y: b.maxY)); g.line(to: NSPoint(x: b.maxX, y: b.minY))
        case .minimize: g.move(to: NSPoint(x: b.minX, y: b.midY)); g.line(to: NSPoint(x: b.maxX, y: b.midY))
        case .zoom: g.move(to: NSPoint(x: b.minX, y: b.midY)); g.line(to: NSPoint(x: b.maxX, y: b.midY)); g.move(to: NSPoint(x: b.midX, y: b.minY)); g.line(to: NSPoint(x: b.midX, y: b.maxY))
        }
        (kind == .close ? NSColor(srgbRed: 0.35, green: 0.02, blue: 0.0, alpha: 0.85) : NSColor(white: 0.1, alpha: 0.75)).setStroke(); g.stroke()
    }
}

/// Bottom-right corner handle to resize the terminal window
final class ResizeGrip: NSView {
    var onDrag: (CGFloat, CGFloat) -> Void = { _, _ in }
    private var last: NSPoint?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with e: NSEvent) { last = e.locationInWindow }
    override func mouseDragged(with e: NSEvent) {
        guard let l = last else { return }
        onDrag(e.locationInWindow.x - l.x, e.locationInWindow.y - l.y); last = e.locationInWindow
    }
    override func mouseUp(with e: NSEvent) { last = nil; (superview as? TermWindowView)?.save() }
    override func draw(_ r: NSRect) {
        NSColor(white: 0.5, alpha: 0.6).setStroke()
        for k in [4.0, 8.0, 12.0] {
            let p = NSBezierPath(); p.lineWidth = 1
            p.move(to: NSPoint(x: bounds.maxX - k, y: 2)); p.line(to: NSPoint(x: bounds.maxX - 2, y: k)); p.stroke()
        }
    }
}


/// 終端機網頁視圖：拖檔案進來＝貼上檔案路徑（WKWebView 預設會自己吃掉拖放，網頁也拿不到真實路徑）
final class DropWebView: WKWebView {
    var onFiles: (([URL]) -> Void)?
    var onHover: (Bool) -> Void = { _ in }
    private func files(_ s: NSDraggingInfo) -> [URL] {
        s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        guard onFiles != nil, !files(s).isEmpty else { return super.draggingEntered(s) }
        onHover(true); return .copy
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard onFiles != nil, !files(s).isEmpty else { return super.draggingUpdated(s) }
        return .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { onHover(false); super.draggingExited(s) }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard onFiles != nil, !files(s).isEmpty else { return super.prepareForDragOperation(s) }
        return true
    }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let urls = files(s)
        guard let cb = onFiles, !urls.isEmpty else { return super.performDragOperation(s) }
        onHover(false); cb(urls); return true
    }
    override func concludeDragOperation(_ s: NSDraggingInfo?) {
        if onFiles != nil, let s, !files(s).isEmpty { return }
        super.concludeDragOperation(s)
    }
}
