import AppKit
import ApplicationServices
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow") private func axWindowID(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 手機看、操作 Mac 上的視窗（11-24 Keng「電腦上的所有視窗都可以看可以用，用分頁的方式，但只在手機上」）。
/// 走手機本來就在用的 /api/sat（id＝"mac|list"／"mac|<視窗號>"）和 /api/input（id＝"mw-<視窗號>"），一樣只收 Tailscale＋密碼。
/// 總開關在 Orbit42 選單，預設關。要「螢幕錄製」（看）和「輔助使用」（操作）權限。
@MainActor
final class MacWindows: NSObject, NSMenuItemValidation {
    static let shared = MacWindows()
    static let key = "orbit.phoneWindows"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) || ProcessInfo.processInfo.environment["ORBIT_TEST_MACWIN"] != nil }

    struct Win: Sendable { let id: CGWindowID, pid: pid_t, app: String, title: String, frame: CGRect, on: Bool }
    private var wins: [Win] = [], listing = false, listAt = Date.distantPast
    private struct Shot { var seq = Int.random(in: 1...1_000_000), img: CGImage?, sharp: Data?, small: Data?, w = 0, h = 0, at = Date.distantPast, changed = Date.distantPast, busy = false, error = "", asked = Date.distantPast }
    private var shots: [CGWindowID: Shot] = [:]
    private let inputQueue = DispatchQueue(label: "orbit.macwin.input", qos: .userInteractive)

    // MARK: 選單
    func installMenu() {
        guard let m = NSApp.mainMenu?.items.first?.submenu else { return }
        let i = NSMenuItem(title: "手機可以看和操作這台 Mac 的視窗", action: #selector(toggle), keyEquivalent: "")
        i.target = self; m.insertItem(i, at: 0); m.insertItem(.separator(), at: 1)
    }
    func validateMenuItem(_ i: NSMenuItem) -> Bool { i.state = Self.enabled ? .on : .off; return true }
    @objc private func toggle() {
        let on = !UserDefaults.standard.bool(forKey: Self.key)
        UserDefaults.standard.set(on, forKey: Self.key)
        shots = [:]; wins = []
        guard on else { return }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    private var blocked: String? {
        if !Self.enabled { return "Mac 上的 Orbit42 選單還沒打開「手機可以看和操作這台 Mac 的視窗」" }
        if !CGPreflightScreenCaptureAccess() { return "Mac 還沒給 Orbit42「螢幕錄製」權限" }
        return nil
    }

    // MARK: 手機來問
    /// "mac|list" 或 "mac|<視窗號>"
    func remote(_ spec: String, have: Int) -> [String: Any]? {
        let p = spec.split(separator: "|").map(String.init)
        guard p.count == 2, p[0] == "mac" else { return nil }
        if let b = blocked { return p[1] == "list" ? ["wins": [] as [Any], "msg": b] : ["open": true, "msg": b] }
        refreshList()
        if p[1] == "list" {
            return ["wins": wins.map { ["id": Int($0.id), "app": $0.app, "title": $0.title, "on": $0.on] as [String: Any] }, "msg": "", "control": AXIsProcessTrusted()]
        }
        guard let id = CGWindowID(p[1]) else { return nil }
        guard let w = wins.first(where: { $0.id == id }) else { return ["open": false] }
        return frame(w, have: have)
    }
    private func frame(_ w: Win, have: Int) -> [String: Any] {
        shoot(w)
        for (k, v) in shots where Date().timeIntervalSince(v.asked) > 20 && k != w.id { shots[k] = nil }      // 沒人看的不留
        let s = shots[w.id] ?? Shot()
        var o: [String: Any] = ["open": true, "title": w.app + (w.title.isEmpty ? "" : "　" + w.title), "url": "",
                                "msg": !w.on && s.img == nil ? "這個視窗收在 Dock 或別的桌面，點一下叫出來" : s.error]
        let still = Date().timeIntervalSince(s.changed) > 0.5, tag = s.seq * 2 + (still ? 1 : 0)
        guard let d = still ? s.sharp : s.small, have != tag, have != s.seq * 2 + 1 else { return o }
        o["seq"] = tag; o["w"] = s.w; o["h"] = s.h; o["data"] = d.base64EncodedString()
        return o
    }

    // MARK: 視窗清單
    private func refreshList() {
        guard !listing, Date().timeIntervalSince(listAt) > 1 else { return }
        listing = true
        let apps = Dictionary(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { ($0.processIdentifier, $0.localizedName ?? "") }, uniquingKeysWith: { a, _ in a })
        let ax = AXIsProcessTrusted()
        DispatchQueue.global(qos: .userInitiated).async {
            let l = Self.scan(apps, ax: ax)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.wins = l; self.listAt = Date(); self.listing = false } }
        }
    }
    nonisolated private static func scan(_ apps: [pid_t: String], ax: Bool) -> [Win] {
        var out: [Win] = []
        let me = ProcessInfo.processInfo.processIdentifier
        var real: [pid_t: Set<CGWindowID>] = [:]
        for w in CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard w[kCGWindowLayer as String] as? Int == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, let app = apps[pid],
                  let id = w[kCGWindowNumber as String] as? CGWindowID, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.width >= 160, r.height >= 100 else { continue }
            let on = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !on {                                   // 不在畫面上的：只收真的視窗（收進 Dock／別的桌面），App 藏著的輔助視窗不要
                guard ax, pid != me else { continue }  // 問自己的 AX 會等主執行緒
                if real[pid] == nil { real[pid] = axWindows(pid) }
                guard real[pid]!.contains(id) else { continue }
            }
            out.append(Win(id: id, pid: pid, app: app, title: String((w[kCGWindowName as String] as? String ?? "").prefix(80)), frame: r, on: on))
        }
        return Array(out.sorted { ($0.app, $0.id) < ($1.app, $1.id) }.prefix(60))      // 順序固定，分頁才不會跳來跳去
    }
    nonisolated private static func axList(_ pid: pid_t) -> [(AXUIElement, CGWindowID)] {
        let a = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(a, 0.3)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &v) == .success, let ws = v as? [AXUIElement] else { return [] }
        return ws.compactMap { w in var id: CGWindowID = 0; return axWindowID(w, &id) == .success ? (w, id) : nil }
    }
    nonisolated private static func axWindows(_ pid: pid_t) -> Set<CGWindowID> { Set(axList(pid).map(\.1)) }

    // MARK: 畫面
    private func shoot(_ w: Win) {
        var s = shots[w.id] ?? Shot()
        s.asked = Date()
        guard !s.busy, w.on || s.img == nil, Date().timeIntervalSince(s.at) > 0.08 else { shots[w.id] = s; return }
        s.busy = true; s.at = Date(); shots[w.id] = s
        let old = s.img, front = NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid
        Task.detached(priority: .userInitiated) {
            var got: CGImage?, err = ""
            do { got = try await Self.capture(w, front: front) } catch { err = "拿不到畫面：\(error.localizedDescription)" }
            let img = got
            let same = img.flatMap { n in old.map { Self.same($0, n) } } ?? false
            let sharp = same ? nil : img.flatMap { Self.jpeg($0, max: 2600, q: 0.7) }, small = same ? nil : img.flatMap { Self.jpeg($0, max: 1000, q: 0.45) }
            let e = err
            await MainActor.run {
                guard var s = self.shots[w.id] else { return }
                s.busy = false; s.error = e
                if !same, let img, let sharp, let small { s.img = img; s.sharp = sharp; s.small = small; s.seq += 1; s.changed = Date(); s.w = Int(w.frame.width); s.h = Int(w.frame.height) }
                self.shots[w.id] = s
            }
        }
    }
    nonisolated private static func capture(_ w: Win, front: Bool) async throws -> CGImage {
        let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let sw = c.windows.first(where: { $0.windowID == w.id }) else { throw NSError(domain: "Orbit42", code: 1, userInfo: [NSLocalizedDescriptionKey: "視窗不見了"]) }
        let cfg = SCStreamConfiguration()
        cfg.showsCursor = false; cfg.scalesToFit = true
        // 正在最前面：拍那塊螢幕，跳出來的選單、下拉才看得到；不在最前面：只拍這個視窗（被蓋住也拍得到）
        if front, w.on, let d = c.displays.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(w.frame) }) {
            let f = SCContentFilter(display: d, excludingWindows: [])
            let k = CGFloat(f.pointPixelScale)
            cfg.sourceRect = w.frame.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
            cfg.width = max(1, Int(w.frame.width * k)); cfg.height = max(1, Int(w.frame.height * k))
            return try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
        }
        let f = SCContentFilter(desktopIndependentWindow: sw)
        let k = CGFloat(f.pointPixelScale)
        cfg.ignoreShadowsSingleWindow = true
        cfg.width = max(1, Int(w.frame.width * k)); cfg.height = max(1, Int(w.frame.height * k))
        return try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
    }
    nonisolated private static func same(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, a.bytesPerRow == b.bytesPerRow, let x = a.dataProvider?.data, let y = b.dataProvider?.data else { return false }
        return CFEqual(x, y)
    }
    nonisolated private static func jpeg(_ img: CGImage, max m: Int, q: Double) -> Data? {
        var im = img
        if img.width > m {
            let h = img.height * m / img.width
            guard let c = CGContext(data: nil, width: m, height: max(h, 1), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            c.interpolationQuality = .medium; c.draw(img, in: CGRect(x: 0, y: 0, width: m, height: h))
            guard let x = c.makeImage() else { return nil }
            im = x
        }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, im, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    // MARK: 操作
    private static let keys: [String: CGKeyCode] = ["Enter": 36, "Tab": 48, "Backspace": 51, "Escape": 53, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126, "Delete": 117, "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121]
    enum Op: Sendable { case click(CGPoint, right: Bool, count: Int), drag(CGPoint, CGPoint), scroll(CGPoint, Double, Double), text(String), key(CGKeyCode, CGEventFlags), raise }
    /// 回 false＝開關沒開、沒權限或視窗不在。動作不認得的略過
    func input(_ id: String, _ data: Data) -> Bool {
        guard blocked == nil, AXIsProcessTrusted(), let n = CGWindowID(id), let w = wins.first(where: { $0.id == n }),
              let ops = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return false }
        func num(_ o: [String: Any], _ k: String) -> Double { let v = (o[k] as? NSNumber)?.doubleValue ?? 0; return v.isFinite ? min(max(v, -5000), 5000) : 0 }
        func pt(_ o: [String: Any], _ x: String, _ y: String) -> CGPoint {
            CGPoint(x: w.frame.minX + min(max(num(o, x), 0), w.frame.width - 1), y: w.frame.minY + min(max(num(o, y), 0), w.frame.height - 1))
        }
        let list: [Op] = ops.prefix(50).compactMap { o in
            switch o["k"] as? String ?? "" {
            case "tap": return w.on ? .click(pt(o, "x", "y"), right: false, count: 1) : .raise
            case "double": return .click(pt(o, "x", "y"), right: false, count: 2)
            case "right": return .click(pt(o, "x", "y"), right: true, count: 1)
            case "drag": return .drag(pt(o, "x", "y"), pt(o, "x2", "y2"))
            case "scroll": return .scroll(pt(o, "x", "y"), num(o, "dx"), num(o, "dy"))
            case "text": return (o["t"] as? String).flatMap { $0.isEmpty ? nil : .text($0) }
            case "key":
                guard let k = Self.keys[o["n"] as? String ?? ""] else { return nil }
                return .key(k, [])
            case "cmd":                                // 常用快捷鍵，只收這幾個
                guard let k: CGKeyCode = ["a": 0, "c": 8, "v": 9, "x": 7, "z": 6][o["n"] as? String ?? ""] else { return nil }
                return .key(k, .maskCommand)
            case "raise": return .raise
            default: return nil
            }
        }
        inputQueue.async { Self.run(list, w) }
        return true
    }
    /// 先把視窗叫到最前面，確定點下去的就是它（或它的選單）才點；不是就不點，免得點到別的 App
    nonisolated private static func run(_ ops: [Op], _ w: Win) {
        guard !ops.isEmpty else { return }
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func isFront() -> Bool {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &v) == .success && v as? Bool == true
        }
        func top(_ p: CGPoint?) -> Bool {
            for x in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
                guard let pid = x[kCGWindowOwnerPID as String] as? pid_t, let b = x[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                      (x[kCGWindowAlpha as String] as? Double ?? 1) > 0.05, let layer = x[kCGWindowLayer as String] as? Int else { continue }
                if pid != w.pid && layer >= 100 && x[kCGWindowOwnerName as String] as? String != "loginwindow" { continue }      // 游標、系統疊層
                if let p, !r.contains(p) { continue }
                if p == nil && layer != 0 { continue }
                if pid == w.pid { return layer > 0 || p == nil || x[kCGWindowNumber as String] as? CGWindowID == w.id || isSheet(x, w) }
                return false
            }
            return false
        }
        func raise() {
            guard !(isFront() && main(app) == w.id) else { return }
            if let e = axList(w.pid).first(where: { $0.1 == w.id })?.0 {
                AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(e, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(e, kAXRaiseAction as CFString)
            } else { AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
            for _ in 0..<20 { if isFront() { break }; usleep(30_000) }
            usleep(60_000)
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        func mouse(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left, clicks: Int64 = 1) {
            let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: b)
            e?.flags = []; e?.setIntegerValueField(.mouseEventClickState, value: clicks); e?.post(tap: .cghidEventTap)
        }
        func key(_ k: CGKeyCode, _ f: CGEventFlags) {
            for d in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: d); e?.flags = f; e?.post(tap: .cghidEventTap); usleep(8_000) }
        }
        for o in ops {
            raise()
            switch o {
            case .raise: break
            case .click(let p, let right, let count):
                guard top(p) else { continue }
                mouse(.mouseMoved, p); usleep(20_000)
                for c in 1...count {
                    mouse(right ? .rightMouseDown : .leftMouseDown, p, right ? .right : .left, clicks: Int64(c)); usleep(25_000)
                    mouse(right ? .rightMouseUp : .leftMouseUp, p, right ? .right : .left, clicks: Int64(c)); usleep(25_000)
                }
            case .drag(let a, let b):
                guard top(a) else { continue }
                mouse(.mouseMoved, a); usleep(20_000); mouse(.leftMouseDown, a); usleep(60_000)
                for i in 1...12 { let t = CGFloat(i) / 12; mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)); usleep(15_000) }
                mouse(.leftMouseUp, b)
            case .scroll(let p, let dx, let dy):
                guard top(p) else { continue }
                if let e = CGEvent(source: nil), hypot(e.location.x - p.x, e.location.y - p.y) > 2 { mouse(.mouseMoved, p); usleep(10_000) }
                let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0)
                e?.location = p; e?.flags = []; e?.post(tap: .cghidEventTap)
            case .text(let t):
                guard isFront() else { continue }
                // 一個字一個字元組送（不拆開表情符號），換行用 Enter
                for ch in t.prefix(4000) {
                    guard isFront() else { break }
                    if ch == "\n" { key(36, []); continue }
                    let u = Array(String(ch).utf16)
                    for d in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: d); e?.flags = []; e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u); e?.post(tap: .cghidEventTap) }
                    usleep(4_000)
                }
            case .key(let k, let f): if isFront() { key(k, f) }
            }
        }
    }
    nonisolated private static func main(_ app: AXUIElement) -> CGWindowID? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v) == .success, let v else { return nil }
        var id: CGWindowID = 0
        return axWindowID(v as! AXUIElement, &id) == .success ? id : nil
    }
    /// 視窗自己的對話框（同一個 App、整個落在這個視窗範圍裡的小視窗）
    nonisolated private static func isSheet(_ x: [String: Any], _ w: Win) -> Bool {
        guard let b = x[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return false }
        return w.frame.insetBy(dx: -20, dy: -20).contains(r) && r != w.frame
    }
}
