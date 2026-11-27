import AppKit
import GameController
import CoreHaptics
import CoreAudio
import Orbit42App

// 11-27 Keng「用 PS4 搖桿左右選不同終端機、觸控板當滑鼠」，同時支援 PS5、Xbox（系統的 GameController，三種都吃）
//
//   十字鍵 ←→／L1 R1   切換衛星終端機（由左到右）
//   十字鍵 ↑↓          答案卡選選項（縮著就先展開）
//   ✕（A）放開         答案卡：第一下框起建議那顆，再按一次送出（照舊有 3 秒復原）
//   ○（B）             答案卡 3 秒內：復原；不然送 Esc（打斷 AI）
//   □（X）放開         Enter
//   □＋✕ 同時按        關閉現在這顆衛星（跟按叉叉一樣，會先跳確認）
//   △（Y）按住         語音輸入：放開後把聽到的字打進現在這顆衛星（不按 Enter）；搖桿有麥克風（USB 接）就用搖桿的
//   觸控板             滑鼠；按下＝左鍵；兩指滑＝捲動（PS4／PS5）
//   左類比             滑鼠（Xbox 沒有觸控板也能用）；L3＝左鍵、R3＝右鍵
//   右類比             捲動
//   Options（≡）       叫出 Orbit42 視窗
//   Share（View）      截圖（等同 ⌘⇧3）
//   燈條               呼吸燈：淺色模式紅、深色模式綠；切換終端機閃一下白光（PS4／PS5）（11-27 Keng 改：不跟狀態變色）
//   震動               有新的答案卡、有衛星做完
// 移滑鼠、送按鍵要「輔助使用」權限（Orbit42 本來排終端機視窗就要這個權限）

@MainActor
final class Gamepad {
    static let shared = Gamepad()
    private var pad: GCController?
    private var poll: Timer?, slow: Timer?, breath: Timer?
    private var held = Set<String>()          // 現在按著的鍵
    private var chord = false                 // 這次 □＋✕ 已經算關閉了：兩顆都放開前不再當單鍵
    private var listener: SphereListener?
    private var voiceSat: String?
    private var haptics: CHHapticEngine?
    private var lastAsks = -1
    private var busy: [String: (on: Bool, since: Date)] = [:]
    private var touch: (p: CGPoint, t: Double)?, touch2At = 0.0
    private var leftDown = false
    private var win: OrbitWindow { OrbitWindow.shared }

    func start() {
        GCController.shouldMonitorBackgroundEvents = true          // Orbit42 不在最前面也收得到
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { self?.attach(c) } }
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let c = n.object as? GCController, c === self?.pad { self?.detach() } }
        }
        GCController.startWirelessControllerDiscovery {}
        if let c = GCController.controllers().first(where: { $0.extendedGamepad != nil }) { attach(c) }
        let old = win.host.onBusy
        win.host.onBusy = { [weak self] id, b in old(id, b); MainActor.assumeIsolated { self?.noteBusy(id, b) } }
    }

    // MARK: 接上／拔掉

    private func attach(_ c: GCController) {
        guard let g = c.extendedGamepad, pad == nil || pad === c else { return }
        pad = c
        print("orbit: 搖桿接上 \(c.vendorName ?? "?")（\(c.productCategory)）"); fflush(stdout)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)                    // 沒權限就跳系統的輔助使用視窗
        func on(_ b: GCControllerButtonInput?, _ name: String) {
            b?.pressedChangedHandler = { [weak self] _, _, down in MainActor.assumeIsolated { self?.button(name, down) } }
        }
        on(g.dpad.left, "left"); on(g.dpad.right, "right"); on(g.dpad.up, "up"); on(g.dpad.down, "down")
        on(g.leftShoulder, "left"); on(g.rightShoulder, "right")
        on(g.buttonA, "x"); on(g.buttonB, "o"); on(g.buttonX, "sq"); on(g.buttonY, "tri")
        on(g.buttonMenu, "menu"); on(g.buttonOptions, "share")
        on(g.leftThumbstickButton, "l3"); on(g.rightThumbstickButton, "r3")
        if let t = Self.touchpad(g) {
            on(t.button, "pad")
            t.primary.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.touchMoved(x, y) } }
            t.secondary.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { if x != 0 || y != 0 { self?.touch2At = CACurrentMediaTime() } } }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sticks() } }
        slow = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.status() } }
        breath = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.breathe() } }
        if let h = c.haptics?.createEngine(withLocality: .default) { h.isAutoShutdownEnabled = true; haptics = h }
        buzz(0.5)
    }

    private func detach() {
        print("orbit: 搖桿拔掉了"); fflush(stdout)
        poll?.invalidate(); slow?.invalidate(); breath?.invalidate(); poll = nil; slow = nil; breath = nil
        if leftDown { mouse(.leftMouseUp) }
        listener?.stop(); listener = nil
        pad = nil; haptics = nil; held = []; chord = false; touch = nil
        if let c = GCController.controllers().first(where: { $0.extendedGamepad != nil }) { attach(c) }
    }

    private static func touchpad(_ g: GCExtendedGamepad) -> (primary: GCControllerDirectionPad, secondary: GCControllerDirectionPad, button: GCControllerButtonInput)? {
        if let d = g as? GCDualSenseGamepad { return (d.touchpadPrimary, d.touchpadSecondary, d.touchpadButton) }
        if let d = g as? GCDualShockGamepad { return (d.touchpadPrimary, d.touchpadSecondary, d.touchpadButton) }
        return nil
    }

    // MARK: 按鍵

    private func button(_ name: String, _ down: Bool) {
        if down { held.insert(name) } else { held.remove(name) }
        if down, held.isSuperset(of: ["sq", "x"]) {                // □＋✕：關閉（保險：兩顆要同時按著）
            chord = true
            if let id = win.currentSatID { bringFront(); win.requestClose(id); buzz(0.8) }
            return
        }
        if chord { if !held.contains("sq") && !held.contains("x") { chord = false }; return }
        switch (name, down) {
        case ("left", true): switchSat(-1)
        case ("right", true): switchSat(1)
        case ("up", true): win.askFloat?.pad("up") { _ in }
        case ("down", true): win.askFloat?.pad("down") { _ in }
        case ("x", false): win.askFloat?.pad("go") { [weak self] r in if r == "chose" { self?.buzz(0.4) } }
        case ("o", true): win.askFloat?.pad("undo") { [weak self] r in if r != "undone" { self?.key(53) } }
        case ("sq", false): key(36)
        case ("tri", true): startVoice()
        case ("tri", false): listener?.finish()
        case ("menu", true): bringFront()
        case ("share", true): key(20, [.maskCommand, .maskShift])
        case ("pad", true), ("l3", true): mouse(.leftMouseDown)
        case ("pad", false), ("l3", false): if leftDown { mouse(.leftMouseUp) }
        case ("r3", true): mouse(.rightMouseDown)
        case ("r3", false): mouse(.rightMouseUp)
        default: break
        }
    }

    private func bringFront() {
        NSApp.activate(ignoringOtherApps: true)
        win.window.makeKeyAndOrderFront(nil)
    }

    private func switchSat(_ d: Int) {
        let ids = win.shownSatIDs
        guard !ids.isEmpty else { return }
        let i = win.currentSatID.flatMap { ids.firstIndex(of: $0) }
        let next = ids[((i ?? (d > 0 ? -1 : 0)) + d + ids.count) % ids.count]
        bringFront()
        win.showSat(next)
        flashUntil = CACurrentMediaTime() + 0.25
    }

    // MARK: 語音輸入（△ 按住講、放開打進去）

    private func startVoice() {
        guard listener == nil, let id = win.currentSatID else { buzz(0.3); return }
        voiceSat = id
        let l = SphereListener { [weak self] text, final, err in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(text, final, err) } }
        }
        l.inputDevice = Self.padMic()
        listener = l
        buzz(0.3)
        l.start()
    }

    private func heard(_ text: String, _ final: Bool, _ err: String?) {
        guard final else { return }
        listener = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let err { print("orbit: 搖桿語音 \(err)"); fflush(stdout) }
        if !t.isEmpty, let id = voiceSat { win.host.type(id, t) } else { buzz(0.3) }
        voiceSat = nil
    }

    /// 搖桿自己的麥克風（PS5 DualSense／PS4 插耳機，USB 接才有）；沒有就用系統預設
    private static func padMic() -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 else { continue }
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &name) == noErr, let n = name?.takeRetainedValue() as String? else { continue }
            if isPadMic(n) { return id }
        }
        return nil
    }
    static func isPadMic(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["dualsense", "dualshock", "wireless controller", "xbox"].contains { n.contains($0) }
    }

    // MARK: 滑鼠與捲動

    private func touchMoved(_ x: Float, _ y: Float) {
        let now = CACurrentMediaTime(), p = CGPoint(x: CGFloat(x), y: CGFloat(y))
        guard x != 0 || y != 0 else { touch = nil; return }        // 手指離開時會回 (0,0)
        defer { touch = (p, now) }
        guard let last = touch, now - last.t < 0.1 else { return }  // 新的一下：只記起點
        let dx = p.x - last.p.x, dy = p.y - last.p.y
        guard hypot(dx, dy) < 0.4 else { return }                   // 跳太遠＝換了一根手指
        if now - touch2At < 0.15 { scroll(dx * 600, dy * 600); return }      // 兩指：捲動
        let speed = 1 + min(2, hypot(dx, dy) * 25)
        move(dx * 520 * speed, -dy * 260 * speed)                   // 觸控板寬約是高的 2 倍，兩軸都正規化成 -1…1
    }

    private func sticks() {
        guard let g = pad?.extendedGamepad else { return }
        func curve(_ v: Float) -> CGFloat { let a = abs(v); return a < 0.15 ? 0 : CGFloat(copysign(pow((a - 0.15) / 0.85, 2), v)) }
        let lx = curve(g.leftThumbstick.xAxis.value), ly = curve(g.leftThumbstick.yAxis.value)
        if lx != 0 || ly != 0 { move(lx * 18, -ly * 18) }
        let rx = curve(g.rightThumbstick.xAxis.value), ry = curve(g.rightThumbstick.yAxis.value)
        if rx != 0 || ry != 0 { scroll(-rx * 30, ry * 30) }
    }

    private func move(_ dx: CGFloat, _ dy: CGFloat) {
        guard let loc = CGEvent(source: nil)?.location else { return }
        let all = NSScreen.screens.reduce(CGRect.null) { $0.union(Self.cgRect($1.frame)) }
        let p = CGPoint(x: min(max(loc.x + dx, all.minX), all.maxX - 1), y: min(max(loc.y + dy, all.minY), all.maxY - 1))
        CGEvent(mouseEventSource: nil, mouseType: leftDown ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    /// NSScreen 座標（左下原點）→ CG 全域座標（主螢幕左上原點）
    static func cgRect(_ r: NSRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private func mouse(_ type: CGEventType) {
        guard let loc = CGEvent(source: nil)?.location else { return }
        if type == .leftMouseDown { leftDown = true } else if type == .leftMouseUp { leftDown = false }
        let b: CGMouseButton = type == .rightMouseDown || type == .rightMouseUp ? .right : .left
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: b)?.post(tap: .cghidEventTap)
    }

    private func scroll(_ dx: CGFloat, _ dy: CGFloat) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: 燈條與震動

    private func status() {
        win.askFloat?.pad("state") { [weak self] r in
            guard let self, let d = r.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let n = o["n"] as? Int ?? 0
            if self.lastAsks >= 0, n > self.lastAsks { self.buzz(0.7, twice: true) }       // 新的答案卡
            self.lastAsks = n
        }
    }

    private func noteBusy(_ id: String, _ on: Bool) {
        let was = busy[id]
        guard was?.on != on else { return }
        busy[id] = (on, Date())
        if let was, was.on, !on, Date().timeIntervalSince(was.since) > 10 { buzz(0.4) }    // 做了一陣子停下來＝做完
    }

    /// 呼吸燈：3 秒一輪，淺色模式紅、深色模式綠；切換終端機後 0.25 秒白光
    private var flashUntil = 0.0, lastLight: [Float] = []
    private func breathe() {
        let t = CACurrentMediaTime()
        let k = Float(0.12 + 0.88 * (0.5 - 0.5 * cos(t * 2 * .pi / 3)))
        let c: [Float] = t < flashUntil ? [1, 1, 1] : win.themeNow == "light" ? [k, 0, 0] : [0, k, 0]
        if c == lastLight { return }
        lastLight = c
        pad?.light?.color = GCColor(red: c[0], green: c[1], blue: c[2])
    }

    private func buzz(_ strength: Float, twice: Bool = false) {
        guard let h = haptics else { return }
        let ev = (twice ? [0, 0.18] : [0]).map {
            CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: strength)], relativeTime: $0, duration: 0.12)
        }
        guard let pat = try? CHHapticPattern(events: ev, parameters: []), let p = try? h.makePlayer(with: pat) else { return }
        try? h.start()
        try? p.start(atTime: CHHapticTimeImmediate)
    }
}
