import WebKit
import AppKit
import ShoWorkCore

/// A satellite's terminal as a small window inside Orbit42: title bar you can drag, macOS-style
/// traffic lights in Okle42 colors (red = end, gray = tuck away, white = fill the screen),
/// resize from the bottom-right corner, rounded corners and a shadow. Frame is remembered.
@MainActor
final class TermWindowView: NSView {
    let content: NSView
    let titleLabel = NSTextField(labelWithString: "")
    var onClose: () -> Void = {}
    private static var seqN = 0
    let seq: Int = { TermWindowView.seqN += 1; return TermWindowView.seqN }()     // 打開的先後（斜對角排的順序）
    var onResized: (NSSize) -> Void = { _ in }     // 11-23：拉右下角改大小 ⇒ 其他衛星跟著變一樣大
    var onMinimize: () -> Void = {}
    var wantShown = false                 // 目前該不該顯示（收起動畫跑到一半又被打開時用）
    /// 11-23 Keng「4 選項答案卡要在終端機上方」：答案卡（在球體網頁裡）被這個小視窗蓋到時＝true ⇒ 淡掉、點擊穿過去給答案卡
    var yieldingToAsk = false
    override func hitTest(_ p: NSPoint) -> NSView? { yieldingToAsk ? nil : super.hitTest(p) }
    private let bar = NSView()
    private let clip = NSView()
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

        // rounded clip for the bar + terminal
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
        buildSecretary()
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var grip: ResizeGrip!

    // MARK: 檢視面板（11-24 Keng「用衛星終端機把 3D 視窗吃掉」）：3D／圖片直接開在這顆衛星裡
    // 視窗夠寬＝左終端機、右檢視；窄＝上檢視、下終端機。中間那條線可以拖
    private(set) var pane: NSView?
    private let splitter = SplitBar()
    var paneShare: CGFloat = 0.55                // 檢視面板佔多少
    var sideBySide: Bool { bounds.width >= 900 }
    func setPane(_ v: NSView?) {
        pane?.removeFromSuperview(); splitter.removeFromSuperview()
        pane = v
        if let v {
            clip.addSubview(v); clip.addSubview(splitter)
            splitter.onDrag = { [weak self] p in
                guard let self else { return }
                let b = NSSize(width: self.bounds.width, height: self.bounds.height - Self.barHeight)
                let s = self.sideBySide ? (b.width - p.x) / b.width : (b.height - p.y) / b.height
                self.paneShare = min(max(s, 0.25), 0.75); self.needsLayout = true
            }
        }
        needsLayout = true
    }

    // 11-23 Keng「這個終端機的字還是好糊」：拖動／調大小用的是滑鼠的小數位移，小視窗常停在 x=186.5 這種半個像素上，
    // 1x 螢幕會把整個視窗內容（終端機的字）內插拉糊。位置和大小一律對齊到整數像素
    override func setFrameOrigin(_ p: NSPoint) { super.setFrameOrigin(NSPoint(x: p.x.rounded(), y: p.y.rounded())) }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(NSSize(width: s.width.rounded(), height: s.height.rounded())) }

    /// 11-23 Keng「怎麼還有紅色」：強調色跟三顆燈一致＝深色護眼綠、淺色紅（閃框、拖檔外框都用這個）
    func accent(alpha: CGFloat = 1) -> CGColor {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (dark ? NSColor(white: 1, alpha: alpha)      /* 11-24 深色綠白對調：呼吸光原本綠 ⇒ 白 */ : NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: alpha)).cgColor
    }

    /// 11-23 Keng：打開時邊框亮一下紅光（跟 ShoWork 光暈同一個感覺），0.9 秒淡掉
    func flash() {
        guard let clip = clip.layer, let me = layer else { return }
        if secretary {
            let w = CAKeyframeAnimation(keyPath: "lineWidth"); w.values = [5, 5, 3]; w.keyTimes = [0, 0.35, 1]; w.duration = 0.9
            stroke.add(w, forKey: "flashW"); return
        }
        let red = accent()   // 深色＝護眼綠、淺色＝紅
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
        guard on != breathing, let clip = clip.layer else { return }
        breathing = on
        if secretary {                        // 秘書：只有一層框，呼吸就是框變粗，不疊白／灰邊
            if on {
                let w = CABasicAnimation(keyPath: "lineWidth"); w.fromValue = 3; w.toValue = 4.2
                w.duration = 1.4; w.autoreverses = true; w.repeatCount = .infinity; w.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                stroke.add(w, forKey: "breathW")
            } else { stroke.removeAnimation(forKey: "breathW") }
            return
        }
        if on {
            // 11-23 Keng 第四輪「陰影跟黑光打架，陰影立體感比較好」：不再動陰影（維持原本柔和的下方陰影），
            // 呼吸只在邊框：深灰邊線變深變淡、稍微變粗
            // 11-23 Keng「深色模式應該是白光」：深色＝白邊呼吸、淺色＝深灰邊呼吸（跟底色反過來才看得到）
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let border = CABasicAnimation(keyPath: "borderColor")
            border.fromValue = (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0.3, alpha: 0.25)).cgColor
            border.toValue = (dark ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0.2, alpha: 0.9)).cgColor
            let width = CABasicAnimation(keyPath: "borderWidth"); width.fromValue = 1; width.toValue = 1.6
            for a in [border, width] {
                a.duration = 1.4; a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            clip.add(border, forKey: "breathB"); clip.add(width, forKey: "breathW")
        } else {
            for k in ["breathB", "breathW"] { clip.removeAnimation(forKey: k) }
        }
    }

    // MARK: 秘書（11-24 Keng 選 B：3px 框＋光暈＋「秘書」小標；深色護眼綠 #4fc36a、淺色紅 #d7261b，跟著深淺即時換）
    static func secretaryColor(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0x4f / 255.0, green: 0xc3 / 255.0, blue: 0x6a / 255.0, alpha: 1) : NSColor(srgbRed: 0.843, green: 0.149, blue: 0.106, alpha: 1)
    }
    private let stroke = CAShapeLayer()
    private let badgeText = NSTextField(labelWithString: Nicknames.captainTitle)
    private func paintSecretary(_ dark: Bool) {
        let c = Self.secretaryColor(dark)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stroke.strokeColor = c.cgColor; badge.layer?.backgroundColor = c.cgColor
        glow.layer?.contents = dark ? Self.glowDark : Self.glowLight
        CATransaction.commit()
        badgeText.textColor = dark ? NSColor(white: 0.05, alpha: 1) : .white       // 綠底白字對比只有 2.2，用深字
    }
    static let glowPad: CGFloat = 40
    private let ring = PassView(), glow = PassView(), badge = PassView()
    var secretary = false {
        didSet {
            guard secretary != oldValue else { return }
            let was = breathing
            if was { secretary.toggle(); setBreathing(false); secretary.toggle() }      // 先停掉原本那種呼吸
            clip.layer?.borderWidth = secretary ? 0 : 1
            if secretary { clip.layer?.removeAnimation(forKey: "flashBorder"); clip.layer?.removeAnimation(forKey: "flashWidth") }
            for v in [ring, glow, badge] { v.isHidden = !secretary }
            needsLayout = true
            if was { setBreathing(true) }
        }
    }
    private func buildSecretary() {
        ring.wantsLayer = true
        stroke.fillColor = nil; stroke.lineWidth = 3; ring.layer?.addSublayer(stroke)     // 向量描邊：圓角內外緣都有反鋸齒（layer 邊框的內緣會有階梯）
        ring.autoresizingMask = [.width, .height]
        addSubview(ring)                                              // 蓋在內容上面，點擊穿過
        glow.wantsLayer = true
        glow.layer?.contentsScale = 2
        glow.layer?.contentsCenter = CGRect(x: 0.495, y: 0.495, width: 0.01, height: 0.01)      // 九宮格：改大小不用重畫
        glow.autoresizingMask = [.width, .height]
        addSubview(glow, positioned: .below, relativeTo: clip)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        let t = badgeText
        t.font = .systemFont(ofSize: 11, weight: .semibold); t.alignment = .center
        t.frame = NSRect(x: 0, y: 1, width: 38, height: 15)
        badge.addSubview(t); bar.addSubview(badge)
        for v in [ring, glow, badge] { v.isHidden = true }
    }
    /// 光暈：只畫框外（不把毛玻璃內部染紅）
    private static let glowDark = glowImage(secretaryColor(true)), glowLight = glowImage(secretaryColor(false))
    private static func glowImage(_ color: NSColor) -> CGImage? {
        let side: CGFloat = 200, k: CGFloat = 2
        guard let c = CGContext(data: nil, width: Int(side * k), height: Int(side * k), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.scaleBy(x: k, y: k)
        let all = CGRect(x: 0, y: 0, width: side, height: side)
        let path = CGPath(roundedRect: all.insetBy(dx: glowPad, dy: glowPad), cornerWidth: 12, cornerHeight: 12, transform: nil)
        c.addRect(all); c.addPath(path); c.clip(using: .evenOdd)
        c.setShadow(offset: .zero, blur: 26, color: color.withAlphaComponent(0.75).cgColor)      // blur 用底圖像素算：預覽也是 2 倍圖
        c.addPath(path); c.setFillColor(color.cgColor); c.fillPath()
        return c.makeImage()
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
                self?.dropHover(on)
            }
        }
    }
    private func dropHover(_ on: Bool) {
        if secretary { stroke.lineWidth = on ? 5 : 3; return }
        layer?.borderWidth = on ? 2 : 0; layer?.borderColor = accent(alpha: 0.9)
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        dropHover(true); return .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { dropHover(false) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        dropHover(false)
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
        clip.frame = bounds
        bar.frame = NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: Self.barHeight)
        let side: CGFloat = secretary ? 128 : 80
        badge.frame = NSRect(x: 80, y: 8, width: 38, height: 18)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stroke.frame = bounds
        if bounds.width > 24, bounds.height > 24 { stroke.path = CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 10.5, cornerHeight: 10.5, transform: nil) }
        CATransaction.commit()
        ring.frame = bounds; glow.frame = bounds.insetBy(dx: -Self.glowPad, dy: -Self.glowPad)
        titleLabel.frame = NSRect(x: side, y: 9, width: max(0, bounds.width - side * 2), height: 16)
        let area = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.barHeight)
        if let pane {
            let line: CGFloat = 6
            if sideBySide {
                let w = (area.width * paneShare).rounded()
                content.frame = NSRect(x: 0, y: 0, width: area.width - w - line, height: area.height)
                splitter.frame = NSRect(x: area.width - w - line, y: 0, width: line, height: area.height)
                pane.frame = NSRect(x: area.width - w, y: 0, width: w, height: area.height)
            } else {
                let h = (area.height * paneShare).rounded()
                content.frame = NSRect(x: 0, y: 0, width: area.width, height: area.height - h - line)
                splitter.frame = NSRect(x: 0, y: area.height - h - line, width: area.width, height: line)
                pane.frame = NSRect(x: 0, y: area.height - h, width: area.width, height: h)
            }
            splitter.vertical = sideBySide
        } else { content.frame = area }
        grip.frame = NSRect(x: bounds.width - 16, y: 0, width: 16, height: 16)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); applyColors()
        if breathing { setBreathing(false); setBreathing(true) }      // 呼吸中切深淺：換成新顏色重來
    }
    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        bar.layer?.backgroundColor = (dark ? NSColor(white: 0.09, alpha: 0.12) : NSColor(white: 0.97, alpha: 0.12)).cgColor   // 11-23 Keng：再透一點
        clip.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.12)).cgColor
        titleLabel.textColor = dark ? NSColor(srgbRed: 0x4f / 255.0, green: 0xc3 / 255.0, blue: 0x6a / 255.0, alpha: 1) : NSColor(white: 0.08, alpha: 1)      // 11-24 深色綠白對調：標題字原本白 ⇒ 綠
        lights.forEach { $0.needsDisplay = true }
        paintSecretary(dark)
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
        onResized(frame.size)
    }

    /// 測試用：關閉燈中心點（視窗座標）
    var closeLightPoint: NSPoint { let l = lights[0]; return l.convert(NSPoint(x: l.bounds.midX, y: l.bounds.midY), to: nil) }
    @objc private func light(_ s: TrafficLight) {
        switch s.kind {
        case .close: onClose()
        case .minimize: onMinimize()
        case .zoom: toggleZoom()
        }
    }

    /// 跟著別的衛星改大小：左上角不動、寬高照對方，超出 Orbit42 視窗就縮進來
    func matchSize(_ size: NSSize) {
        guard let sup = superview, frame.size != size else { return }
        var f = frame; f.origin.y = f.maxY - size.height; f.size = size
        frame = Self.fit(f, in: sup.bounds); zoomedFrom = nil; needsLayout = true
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
        toolTip = ["關閉（先確認；結束裡面的程式、清掉內容；背景 session 也會停掉）", "收起（衛星繼續跑）", "放大／還原（也可以雙擊標題列）"][[Kind.close, .minimize, .zoom].firstIndex(of: kind)!]
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true; superview?.subviews.forEach { $0.needsDisplay = true } }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func draw(_ r: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Okle42 色票（跟 Ghostty Okle42-Dark／Light、球體同一組）：
        //   深色：綠 #4fc36a（11-23 Keng：深色的紅全部改護眼綠）／灰 #8a8a8f／白 #ededed，外圈淡黑線讓白點在深灰標題列上有邊
        //   淺色：紅 #d7261b／灰 #8c8c8c／白 #ffffff，外圈加深一點（白點在淺灰標題列上才看得到）
        let fill: NSColor, ring: NSColor
        switch kind {
        case .close: fill = dark ? NSColor(srgbRed: 0.929, green: 0.929, blue: 0.929, alpha: 1)      /* 11-24 綠白對調：關閉燈綠 ⇒ 白、放大燈白 ⇒ 綠 */ : NSColor(srgbRed: 0.843, green: 0.149, blue: 0.106, alpha: 1)
        case .minimize: fill = dark ? NSColor(srgbRed: 0.541, green: 0.541, blue: 0.561, alpha: 1) : NSColor(white: 0.55, alpha: 1)
        case .zoom: fill = dark ? NSColor(srgbRed: 0.310, green: 0.765, blue: 0.416, alpha: 1) : .white
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
        (kind == .close ? (dark ? NSColor(white: 0.1, alpha: 0.75) : NSColor(srgbRed: 0.35, green: 0.02, blue: 0.0, alpha: 0.85)) : NSColor(white: 0.1, alpha: 0.75)).setStroke(); g.stroke()
    }
}

/// 只顯示、不吃點擊
final class PassView: NSView { override func hitTest(_ p: NSPoint) -> NSView? { nil } }

/// 終端機和檢視面板中間的線
final class SplitBar: NSView {
    var onDrag: (NSPoint) -> Void = { _ in }
    var vertical = true { didSet { if vertical != oldValue { window?.invalidateCursorRects(for: self); needsDisplay = true } } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDown(with e: NSEvent) {}
    override func mouseDragged(with e: NSEvent) { if let s = superview { onDrag(s.convert(e.locationInWindow, from: nil)) } }
    override func draw(_ r: NSRect) {
        NSColor(white: 0.5, alpha: 0.35).setFill()
        (vertical ? NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height) : NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)).fill()
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
        // 11-24 Keng：斜線收進圓角（半徑 12，圓心在左上 (4,12)）裡面，離秘書外框內緣也留一點；可拖的範圍照舊 16×16
        for (d, half) in [(5.0, 2.0), (2.0, 4.0), (-1.0, 6.0)] {
            let p = NSBezierPath(); p.lineWidth = 1
            let c = NSPoint(x: bounds.maxX - 12 + d * 0.7071, y: 12 - d * 0.7071)
            p.move(to: NSPoint(x: c.x - half * 0.7071, y: c.y - half * 0.7071)); p.line(to: NSPoint(x: c.x + half * 0.7071, y: c.y + half * 0.7071)); p.stroke()
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
