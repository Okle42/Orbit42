import AppKit
import WebKit
import Orbit42App
import Orbit42Core

/// Orbit42 主視窗：整個 Orbit42 球體（播報、空白鍵講話、量表、自檢、cool42…）＋右邊滑出的衛星終端機
@MainActor
final class OrbitWindow: NSObject, NSWindowDelegate {
    static let shared = OrbitWindow()
    var window: NSWindow!
    let host = Host()
    let login = LoginPanel()
    var sphereView: NSView?
    private(set) var askFloat: AskFloat?
    private var askTimer: Timer?
    private var loginWatch: NSKeyValueObservation?
    private var webWatch: Timer?
    /// 11-23 Keng「Orbit42 改檔自動重新載入，免重開」：每秒看球體頁（Web/sphere.html，ORBIT_WEB_DIR 優先）的修改時間，
    /// 變了且連續 2 次一樣（檔案寫完）才 reload 球體 WebView；資料下一秒由宿主重推，版面在 localStorage。衛星終端機不動。
    private func watchSphereFile() {
        let env = ProcessInfo.processInfo.environment
        let dir = env["ORBIT_WEB_DIR"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL?.appendingPathComponent("Web")
        guard let file = dir?.appendingPathComponent("sphere.html").path else { return }
        let mtime = { (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? nil }
        var loaded = mtime(), seen = loaded
        webWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = mtime()
                defer { seen = now }
                guard let now, now != loaded, now == seen, let web = self?.sphereView as? WKWebView else { return }
                loaded = now
                print("orbit: sphere.html changed, reloading"); fflush(stdout)
                web.reload()
            }
        }
    }
    /// 11-23 Keng「4 選項答案卡跳出來應該在終端機上方，它要幫我們加速工作流程」：衛星小視窗是原生 view、蓋在球體網頁上，
    /// 網頁的 z-index 管不到 ⇒ 每 0.3 秒問球體答案卡（＋送出後的「復原」提示）在哪，蓋到它的衛星整個淡出、點擊穿過去；答完恢復
    private func watchAskCard() {
        // 11-24 Keng「點答案卡，終端機短暫消失」：送出後 3 秒的復原條不再叫終端機讓位（改放進戰情卡）；
        // 答案卡比戰情卡長時只算看得到的那一段（原本連捲在外面的也算，會誤判碰到終端機）
        let js = """
        (() => { const r = []; for (const id of ["askCard", "askDot"]) { const e = document.getElementById(id);
          if (!e || !e.classList.contains("on")) continue; const b = e.getBoundingClientRect();
          const t = e.closest("#cardTeam"), c = t ? t.getBoundingClientRect() : { left: 0, top: 0, right: innerWidth, bottom: innerHeight };
          const x = Math.max(b.left, c.left), y = Math.max(b.top, c.top), w = Math.min(b.right, c.right) - x, h = Math.min(b.bottom, c.bottom) - y;
          if (w > 0 && h > 0) r.push([x, y, w, h]); } return JSON.stringify(r); })()
        """
        askTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let web = self.sphereView as? WKWebView, !web.isHidden else { return }
                if SphereEmbed.askFloat {          // 浮層活著：球體不畫答案卡，不用讓位（剛剛讓位的放回來）
                    for x in self.satWins.values where x.yieldingToAsk { x.yieldingToAsk = false; x.alphaValue = 1 }
                    return
                }
                web.evaluateJavaScript(js) { [weak self] r, _ in
                    MainActor.assumeIsolated {
                        guard let self, let root = self.window.contentView, let s = r as? String, let d = s.data(using: .utf8),
                              let arr = try? JSONSerialization.jsonObject(with: d) as? [[Double]] else { return }
                        let H = root.bounds.height
                        let rects = arr.filter { $0.count == 4 }.map { NSRect(x: $0[0], y: H - $0[1] - $0[3], width: $0[2], height: $0[3]).insetBy(dx: -10, dy: -10) }
                        for case let w as TermWindowView in root.subviews where !w.isHidden && w.wantShown {
                            let y = rects.contains { $0.intersects(w.frame) }
                            guard y != w.yieldingToAsk else { continue }
                            w.yieldingToAsk = y
                            NSAnimationContext.runAnimationGroup { ctx in
                                ctx.duration = 0.25; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                                w.animator().alphaValue = y ? 0 : 1          // 11-23 Keng「答案卡太透明會看到底下的字」⇒ 整個淡出（原 12%）
                            }
                        }
                    }
                }
            }
        }
    }
    /// 11-23 Keng：每顆衛星一個終端機小視窗，可以同時開好幾個、重疊、各自拖動；點哪個哪個到最上面
    var satWins: [String: TermWindowView] = [:]
    /// 最上面那個開著的衛星小視窗（測試 hooks 用）
    var frontSat: TermWindowView? {
        satWins.values.filter { !$0.isHidden }.max { ($0.layer?.zPosition ?? 0) < ($1.layer?.zPosition ?? 0) }
    }

    func show(test: Bool) {
        let env = ProcessInfo.processInfo.environment
        let size = NSSize(width: Double(env["ORBIT_TEST_W"] ?? "") ?? 1440, height: Double(env["ORBIT_TEST_H"] ?? "") ?? 900)
        window = (test ? HiddenTestWindow.self : NSWindow.self).init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Orbit42"
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = AskFloatRoot(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        window.contentView = root
        let sphere = SphereEmbed.makeView()
        sphere.frame = root.bounds; sphere.autoresizingMask = [.width, .height]
        root.addSubview(sphere); sphereView = sphere
        sphere.wantsLayer = true; sphere.layer?.zPosition = 0
        // 登入畫面蓋在球體上面（終端機面板再蓋在登入畫面上面：登入指令要看得到）
        login.web.frame = root.bounds; login.web.autoresizingMask = [.width, .height]
        // 11-23 修：疊放順序固定＝球體（最底）→ 登入畫面 → 終端機小視窗（最上）。之前登入畫面放到最底層，
        // 球體載入後把它整個蓋住（按「帳號⋯」只看到球淡出、登入頁出不來）
        root.addSubview(login.web, positioned: .above, relativeTo: sphere)      // 終端機小視窗在下面最後才加，自然在最上層
        login.web.wantsLayer = true; login.web.layer?.zPosition = 1               // 小視窗從 10 起跳，點到的再往上（raise）
        if let f = AskFloat() {                // 11-25 Keng：答案卡浮在最上層；建得起來、說過 ready 球體才不畫
            f.terminals = { [weak self] in self?.satWins.values.filter { !$0.isHidden && $0.wantShown }.map(\.frame) ?? [] }
            f.composing = { [weak self] in self.map { s in s.host.composing.contains { s.satWins[$0]?.isHidden == false } } ?? false }
            root.addSubview(f.view); root.float = f.view; askFloat = f
            f.watchBundle(status: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Orbit42/ask-page.json"))      // 答案卡網頁免重開
            f.suppressed = !login.web.isHidden
            loginWatch = login.web.observe(\.isHidden) { [weak f] w, _ in MainActor.assumeIsolated { f?.suppressed = !w.isHidden } }
        }
        login.runInTerminal = { [weak self] name, brain, cmd in self?.host.runCommand(name: name, brain: brain, command: cmd) }
        login.onEnter = { [weak self] list in self?.enter(list) }
        host.onExited = { [weak self] _ in self?.login.check() }
        // 衛星終端機＝每顆衛星一個可以拖、可以調大小的小視窗（左上紅灰白三顆燈），可以同時開好幾個
        host.theme = themeNow
        host.onOpen = { [weak self] id in self?.showSat(id) }
        host.onHide = { [weak self] id in guard let self, let w = self.satWins[id] else { return }; self.animate(w, on: false) }
        host.onRemoved = { [weak self] id in self?.closeSat(id) }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.markSecretary() } }
        host.onBusy = { [weak self] id, busy in guard let w = self?.satWins[id], !w.isHidden else { return }; w.setBreathing(busy) }
        host.startTimers()
        SphereEmbed.typeAnswer = { [weak self] sid, text, still, done in self?.host.typeAnswer(sid, text, still: still, done: done) ?? false }
        SphereEmbed.typeClear = { [weak self] sid, still, done in self?.host.typeClear(sid, still: still, done: done) ?? false }
        host.registerRemote()                 // 11-23 iPhone App：衛星清單與畫面（Orbit42 網頁伺服器唯讀端點）
        if ProcessInfo.processInfo.environment["ORBIT_TEST_RESTORE"] == "load" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated { self?.host.restore() } }
        }
        // 點到哪個小視窗（標題列或終端機內容都算），那個就疊到最上面
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in self?.raiseUnder(e); return e }
        SphereEmbed.openSession = { [weak self] ref in
            guard let self else { return false }
            return self.host.open(ref)
        }
        SphereEmbed.command = { [weak self] cmd in
            if cmd == "fullscreen" { self?.window.toggleFullScreen(nil) }
            if cmd == "quit" { self?.confirmQuit() }
            if cmd == "closeSat", let self, let w = self.frontSat, let id = self.id(of: w) { self.host.onHide(id) }
            if cmd.hasPrefix("moon:") { self?.moonCommand(cmd) }
            if cmd == "hideSats" { self?.hideAllSats() }      // 11-24 點球體空白處：衛星終端機全部收下去、露出智能體
            if cmd.hasPrefix("theme:") { self?.applyTheme(String(cmd.dropFirst(6))) }
            if cmd.hasPrefix("arrangeSats") {          // "arrangeSats:x,y,w,h"＝球體量好的空位（網頁座標，左上原點）
                let v = cmd.split(separator: ":").dropFirst().first?.split(separator: ",").compactMap { Double($0) } ?? []
                if cmd.hasPrefix("arrangeSatsNow"), let self { self.pinned = nil; for w in self.satWins.values { w.userMoved = false } }     // 按了「自動排版」：全部歸位、疊放回到排列順序
                self?.arrangeSats(in: v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil)
            }
        }
        watchAskCard(); watchSphereFile()
        runTestHooks(env, test: test)      // OrbitTestHooks.swift；沒有 ORBIT_TEST_* 環境變數就什麼都不做
        if test {
            window.ignoresMouseEvents = true; window.isExcludedFromWindowsMenu = true; window.collectionBehavior = [.transient, .ignoresCycle]
            if let s = HiddenTestWindow.freeScreen() { window.setFrameOrigin(NSPoint(x: s.visibleFrame.minX, y: s.visibleFrame.minY)) }
            else { window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -30000, y: -30000)) }
            window.orderBack(nil)
        } else {
            if let f = WindowPlace.load(.standard, screens: NSScreen.screens.map(\.frame), visible: NSScreen.screens.map(\.visibleFrame)) { window.setFrame(f, display: false) } else { window.center() }
            placeReady = true
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            // 11-23 Keng：Orbit42 像系統一樣佔滿整個畫面（全螢幕桌面模式，預設開；切掉會記住）
            if UserDefaults.standard.object(forKey: "orbit.desktop") as? Bool ?? true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.window.toggleFullScreen(nil) }
            }
        }
    }

    // 全螢幕時 Dock、選單列自動藏起來（滑到邊緣才出現），整個畫面就是 Orbit42
    func window(_ w: NSWindow, willUseFullScreenPresentationOptions o: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideDock, .autoHideMenuBar, .autoHideToolbar]
    }
    func windowWillEnterFullScreen(_ n: Notification) { placeReady = false; placeSave?.cancel() }
    func windowDidFailToEnterFullScreen(_ w: NSWindow) { placeReady = true }
    func windowDidEnterFullScreen(_ n: Notification) { UserDefaults.standard.set(true, forKey: "orbit.desktop"); layoutTerm() }
    func windowDidExitFullScreen(_ n: Notification) { UserDefaults.standard.set(false, forKey: "orbit.desktop"); layoutTerm(); placeReady = true }

    /// 視窗位置（WindowPlace）：停下來 1 秒才記；全螢幕（含轉場）不記；這 1 秒內螢幕組合變了＝系統搬的，不記。測試視窗永遠不記
    private var placeReady = false
    private var placeSave: DispatchWorkItem?
    private func placeChanged() {
        guard placeReady else { return }
        placeSave?.cancel()
        let before = WindowPlace.key(NSScreen.screens.map(\.frame))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.placeReady, !self.window.isMiniaturized, !self.window.styleMask.contains(.fullScreen) else { return }
            let screens = NSScreen.screens.map(\.frame)
            guard WindowPlace.key(screens) == before else { return }
            WindowPlace.save(self.window.frame, .standard, screens: screens)
        }
        placeSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    func windowDidMove(_ n: Notification) { placeChanged() }

    /// 11-23 Keng：球體切深淺（◐）時，衛星終端機（xterm 色票＋裡面的 Claude Code）和小視窗標題列一起換
    var themeNow = "dark"

    // MARK: 3D 檔案小視窗（11-24 Keng：像終端機視窗，看各種 3D 檔）。跟衛星放同一本冊子：疊放、自動排版、點空白全收都一起
    private var modelSeq = 0
    var modelCount: Int { satWins.keys.filter { $0.hasPrefix("3d-") }.count }
    @discardableResult
    func openModel(_ url: URL) -> (TermWindowView, ModelView)? {
        guard let root = window.contentView else { return nil }
        if let (id, w) = satWins.first(where: { ($0.value.content as? ModelView)?.url?.standardizedFileURL == url.standardizedFileURL }), let v = w.content as? ModelView {
            showSat(id); v.open(url); return (w, v)               // 同一個檔：叫回來、重讀（檔案可能改過）
        }
        modelSeq += 1; let id = "3d-\(modelSeq)"
        let v = ModelView(frame: .zero), w = TermWindowView(content: v)
        w.appearance = NSAppearance(named: themeNow == "light" ? .aqua : .darkAqua)
        let n = CGFloat(satWins.values.filter { !$0.isHidden }.count)
        w.frame = TermWindowView.fit(w.restoredFrame(in: root.bounds).offsetBy(dx: n * 28, dy: -n * 28), in: root.bounds)
        w.isHidden = true
        v.onTitle = { [weak w] t in w?.titleLabel.stringValue = t + " · 3D" }
        v.onOpenPanel = { [weak self, weak v] in self?.pickModel(into: v) }
        w.onClose = { [weak self, weak w] in if let w { self?.closeModel(w) } }
        w.onMinimize = { [weak self, weak w] in if let self, let w { self.animate(w, on: false) { [weak self] in self?.autoArrange() } } }
        w.onResized = { [weak self, weak w] size in
            guard let self else { return }
            for o in self.satWins.values where o !== w && !o.isHidden { o.matchSize(size) }
        }
        root.addSubview(w); satWins[id] = w
        showSat(id); v.open(url)
        return (w, v)
    }
    func closeModel(_ w: TermWindowView) {
        guard let id = satWins.first(where: { $0.value === w })?.key else { return }
        (w.content as? ModelView)?.cancel(); closeSat(id)
    }
    /// 3D／圖片開在衛星裡：指定的衛星（scripts/orbit3d 帶 sat 或 job）；沒指定＝最上面那顆開著的；一顆都沒有才另開獨立視窗
    func openView(_ url: URL, sat: String = "", job: String = "") {
        let id = pickSat(sat: sat, job: job)
        guard let id else { openModel(url); return }
        // 同一個檔原本開在獨立視窗 ⇒ 吃進來
        for (k, x) in satWins where k.hasPrefix("3d-") && (x.content as? ModelView)?.url?.standardizedFileURL == url.standardizedFileURL { closeModel(x) }
        let v: ModelView
        if let have = moons[id]?["3d"] as? ModelView { v = have }
        else {
            v = ModelView(frame: .zero)
            v.onShut = { [weak self] in self?.dropMoon(id, "3d") }
            v.onTuck = { [weak self] in self?.tuckMoon(id) }
            v.onOpenPanel = { [weak self, weak v] in self?.pickModel(into: v) }
            v.onTitle = { [weak self] _ in self?.pushMoons() }
            moons[id, default: [:]]["3d"] = v
        }
        showMoon(id, "3d"); v.open(url)
    }
    /// 網頁開在衛星裡（同一顆衛星一個網頁面板，再開就換網址）
    func openWeb(_ url: URL?, sat: String = "", job: String = "") {
        guard let id = pickSat(sat: sat, job: job) else { toast("沒有開著的衛星可以放網頁"); return }
        let v = webPane(id)
        showMoon(id, "web")
        if let url { v.open(url) } else { v.focusAddress() }
    }

    private func webPane(_ id: String) -> WebPane {
        if let have = moons[id]?["web"] as? WebPane { return have }
        let v = WebPane(frame: .zero)
        v.onShut = { [weak self] in self?.dropMoon(id, "web") }
        v.onTuck = { [weak self] in self?.tuckMoon(id) }
        v.onTitle = { [weak self] in self?.pushMoons() }
        moons[id, default: [:]]["web"] = v
        return v
    }
    /// 手機要開的網頁：只掛小衛星，不打開 Mac 的視窗
    func openWebQuiet(_ u: URL, sat id: String) { webPane(id).web.load(u); pushMoons() }

    // MARK: 小衛星（11-24 Keng「衛星終端機的行星旁邊會多一顆小衛星」）：衛星 id → 種類（3d／web）→ 面板。
    // 面板收起來小衛星還在，點它叫回來；按面板的 ✕ 才真的關掉
    private var moons: [String: [String: NSView]] = [:]
    private var moonShown: [String: String] = [:]
    func showMoon(_ id: String, _ kind: String) {
        guard let v = moons[id]?[kind] else { return }
        if satWins[id]?.isHidden != false || satWins[id]?.wantShown != true { showSat(id) }
        guard let w = satWins[id] else { return }
        if w.pane !== v { w.setPane(v); w.layoutSubtreeIfNeeded() }
        moonShown[id] = kind; raise(w); pushMoons()
    }
    func tuckMoon(_ id: String) { satWins[id]?.setPane(nil); moonShown[id] = nil; pushMoons() }
    func dropMoon(_ id: String, _ kind: String) {
        if moonShown[id] == kind { tuckMoon(id) }
        let v = moons[id]?.removeValue(forKey: kind)
        (v as? ModelView)?.cancel(); (v as? WebPane)?.stop()
        if moons[id]?.isEmpty == true { moons[id] = nil }
        pushMoons()
    }
    private func dropMoons(_ id: String) { for k in ["3d", "web"] where moons[id]?[k] != nil { dropMoon(id, k) } }
    /// 球上點小衛星：沒開著 ⇒ 打開衛星和那塊面板；已經開著 ⇒ 收起面板
    func tapMoon(_ id: String, _ kind: String) {
        if moonShown[id] == kind, let w = satWins[id], !w.isHidden, w.wantShown { tuckMoon(id) } else { showMoon(id, kind) }
    }
    /// 指定的衛星（sat 或 job）；都沒指定＝最上面那顆開著的
    func pickSat(sat: String, job: String) -> String? {
        if !sat.isEmpty, host.has(sat) { return sat }
        if let s = host.sat(job: job) { return s }
        guard sat.isEmpty, job.isEmpty else { return nil }
        return satWins.filter { !$0.key.hasPrefix("3d-") && !$0.value.isHidden && $0.value.wantShown }
            .max { ($0.value.layer?.zPosition ?? 0) < ($1.value.layer?.zPosition ?? 0) }?.key
    }
    func moonViews(_ id: String) -> [String: NSView] { moons[id] ?? [:] }
    func moonShownKind(_ id: String) -> String? { moonShown[id] }      // Host 存恢復紀錄用：現在展開的是哪種面板
    /// 手機球體用：這顆衛星有哪些小衛星
    func moonList(_ id: String) -> [[String: Any]] { (moons[id] ?? [:]).keys.sorted().map { ["kind": $0, "title": moonTitle(moons[id]![$0]!), "on": moonShown[id] == $0] } }
    private func moonTitle(_ v: NSView) -> String { (v as? ModelView)?.url?.lastPathComponent ?? (v as? WebPane)?.titleText ?? "" }
    private var moonSids: [String: String] = [:]
    var moonJSON: String {
        var o: [String: [[String: Any]]] = [:]
        for (id, m) in moons {
            guard let sid = host.sessionId(id) ?? moonSids[id] else { continue }
            moonSids[id] = sid
            _ = m; o[sid] = moonList(id)
        }
        return (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    /// 球體重新載入會忘記 ⇒ 每 3 秒也推一次（沒有小衛星、上次也沒有就不推）
    private var moonPushed = "{}"
    func pushMoons(periodic: Bool = false) {
        let j = moonJSON
        if periodic, j == "{}", moonPushed == "{}" { return }
        moonPushed = j
        (sphereView as? WKWebView)?.evaluateJavaScript("window.karaMoons && window.karaMoons(\(j))", completionHandler: nil)
    }
    func startMoons() {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pushMoons(periodic: true) } }
    }
    func moonCommand(_ cmd: String) {            // "moon:<sessionId>:<kind>"
        let p = cmd.split(separator: ":").map(String.init)
        guard p.count == 3, let id = moons.keys.first(where: { (host.sessionId($0) ?? moonSids[$0]) == p[1] }) else { return }
        tapMoon(id, p[2])
    }
    func pane(_ id: String) -> (TermWindowView, ModelView)? { satWins[id].flatMap { w in (w.pane as? ModelView).map { (w, $0) } } }
    func recallModels() { for (id, w) in satWins where id.hasPrefix("3d-") && (w.isHidden || !w.wantShown) { showSat(id) } }

    func applyTheme(_ name: String) {
        themeNow = name == "light" ? "light" : "dark"
        let dark = name != "light"
        let ap = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.appearance = ap
        for w in satWins.values { w.appearance = ap }
        host.theme = themeNow
        host.js("window.orbitTheme", dark ? "dark" : "light")
        askFloat?.theme = themeNow
        login.web.appearance = ap
    }

    /// 進入：收起登入畫面，球體的「＋ 新衛星」只列登入過的大腦
    func enter(_ list: [Provider]) {
        hideAllSats()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in MainActor.assumeIsolated { self?.host.restore() } }   // 過場完把上次的衛星開回來
        // 過場：登入卡片往前飛出（網頁自己動）＋整個登入層淡出，同時球體從遠處拉近打開
        (sphereView as? WKWebView)?.evaluateJavaScript("window.karaIntro && window.karaIntro()")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.75; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            login.web.animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.login.web.isHidden = true } })
        let ids = list.filter(\.signedIn).map(\.id)
        if let d = try? JSONSerialization.data(withJSONObject: ids), let w = sphereView as? WKWebView {
            w.evaluateJavaScript("window.orbitBrains && window.orbitBrains(\(String(decoding: d, as: UTF8.self)))")
        }
    }
    /// 球體播報一句話（DiskWatch 用：外接硬碟斷線／變慢）
    func toast(_ text: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: [text]), let w = sphereView as? WKWebView else { return }
        w.evaluateJavaScript("window.karaToast && window.karaToast(...\(String(decoding: d, as: UTF8.self)))")
    }
    func showLogin() {
        hideAllSats()
        (sphereView as? WKWebView)?.evaluateJavaScript("window.karaOutro && window.karaOutro()")      // 球拉遠消失
        login.web.alphaValue = 0; login.web.isHidden = false
        login.check()
        // 11-23 Keng「登入卡片太早滑進來」：等球拉遠快消失（0.9 秒的過場走到 0.8 秒）才讓登入頁淡入、卡片進場
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.login.web.isHidden else { return }
            self.login.web.evaluateJavaScript("window.loginShow && window.loginShow()")
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.login.web.animator().alphaValue = 1
            }
        }
    }

    /// 11-23 Keng「自動排版，我也要能讓我的衛星終端機像之前那樣斜對角排開」：開著的衛星小視窗統一大小，
    /// 照疊放順序沿斜對角均勻排開（最底下的在左上、最上面的在右下），每個標題列都看得到
    /// 11-23 Keng「我要限定範圍」：只在左欄卡片右緣＋小縫 ～ 右欄戰情卡左緣－小縫、「思考中」狀態字上面這塊排（web＝球體量好的空位）
    func arrangeSats(in web: CGRect? = nil) {
        guard let root = window.contentView else { return }
        let wins = root.subviews.compactMap { $0 as? TermWindowView }.filter { !$0.isHidden && $0.wantShown && !$0.userMoved && !$0.zoomed }      // 自己拖過／放大的不動
            .sorted { ($0.secretary ? 1 : 0, $0.seq) < ($1.secretary ? 1 : 0, $1.seq) }   // 照打開先後，秘書最後（右下最上層）：跟疊放順序同一套（SatStack）
        restack()
        guard !wins.isEmpty else { return }
        let H = root.bounds.height
        let area = web.map { NSRect(x: $0.minX, y: H - $0.maxY, width: $0.width, height: $0.height) }
            ?? NSRect(x: 16, y: 40, width: root.bounds.width - 32, height: H - 40 - 52)
        let base = TermWindowView.fit(wins[0].restoredFrame(in: root.bounds), in: root.bounds)
        let n = CGFloat(wins.count)
        // 11-23 審查 #9：範圍再窄，衛星也不小於 420×260（TermWindow 自己的下限），寧可超出範圍也要看得到字
        let w = max(min(420, root.bounds.width - 32), min(base.width, n > 1 ? area.width * 0.62 : area.width))
        let h = max(min(260, root.bounds.height - 80), min(base.height, n > 1 ? area.height * 0.78 : area.height))
        let dx = n > 1 ? max(0, area.width - w) / (n - 1) : 0, dy = n > 1 ? max(0, area.height - h) / (n - 1) : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32; ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            for (i, v) in wins.enumerated() {
                let f = n > 1 ? NSRect(x: area.minX + CGFloat(i) * dx, y: area.maxY - h - CGFloat(i) * dy, width: w, height: h)
                    : NSRect(x: area.midX - w / 2, y: area.maxY - h, width: w, height: h)
                v.animator().frame = NSRect(x: f.minX.rounded(), y: f.minY.rounded(), width: w.rounded(), height: h.rounded())   // 每個一樣大（不用 integral：會往外擴差 1 像素）
            }
        }
    }

    /// ⌘Q／選單結束：背景 session 的衛星重開會接回來，直接結束；其他的會被關掉，先問
    private func confirmQuit() {
        let n = host.runningForeground
        guard n > 0 else { return NSApp.terminate(nil) }
        let a = NSAlert()
        a.messageText = "結束Orbit42？"
        a.informativeText = "有 \(n) 顆衛星不在背景執行，結束後會關掉。其他衛星下次打開會接回來。"
        a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        a.addButton(withTitle: "結束")
        a.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { NSApp.terminate(nil) } }
    }
    /// 11-23 Keng「增加新視窗的時候要自動幫我全部排下去」：開／關／收起衛星後，自動排版開著就重排（範圍跟開關都問球體）
    func autoArrange() {
        (sphereView as? WKWebView)?.evaluateJavaScript("window.karaSatArea ? JSON.stringify(window.karaSatArea()) : 'null'") { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self, let str = r as? String, let d = str.data(using: .utf8),
                      let v = try? JSONSerialization.jsonObject(with: d) as? [Double], v.count == 4 else { return }
                self.arrangeSats(in: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
            }
        }
    }

    /// 現任秘書的衛星：紅框＋光暈＋小標，標題改成它當下在做的事（換人就跟著換）
    private func markSecretary() {
        guard !satWins.isEmpty else { return }
        var swapped = false; defer { if swapped { restack(); autoArrange() } }      // 換了秘書才動
        let cap = CaptainStore.captain()?.sessionId, test = ProcessInfo.processInfo.environment["ORBIT_TEST_SECRETARY"] != nil
        for (id, w) in satWins where !id.hasPrefix("3d-") {
            let sid = host.sessionId(id), on = test || (cap != nil && sid == cap)
            // 11-25：標題列固定「職責 · 主專案｜工作標題」；不是 Claude session（Codex、還沒開）照舊。小標已經寫「秘書」，不重複
            if w.pane == nil || on || SphereEmbed.label(sid) != nil {
                let l = SphereEmbed.label(sid), t = l.map { on ? $0.line.replacingOccurrences(of: "秘書 · ", with: "") : $0.line } ?? (on ? "待命" : host.title(id))
                if w.titleLabel.stringValue != t { w.titleLabel.stringValue = t }
            }
            if w.secretary != on { w.secretary = on; swapped = true }
        }
    }

    /// 打開（或叫回）一顆衛星的小視窗；新開的從上一個位置往右下錯開一點，像 macOS 開新視窗
    func showSat(_ id: String) {
        guard let root = window.contentView else { return }
        let w: TermWindowView
        if let x = satWins[id] { w = x }
        else {
            w = TermWindowView(content: host.view(for: id))
            w.titleLabel.stringValue = host.title(id)
            w.appearance = NSAppearance(named: themeNow == "light" ? .aqua : .darkAqua)
            let n = CGFloat(satWins.values.filter { !$0.isHidden }.count)
            w.frame = TermWindowView.fit(w.restoredFrame(in: root.bounds).offsetBy(dx: n * 28, dy: -n * 28), in: root.bounds)
            w.isHidden = true
            w.onClose = { [weak self] in self?.confirmEnd(id) }               // 11-23 Keng：綠燈＝完全關閉（先確認 → 結束程式、清內容 → 關視窗）
            w.onMinimize = { [weak self, weak w] in if let self, let w { self.animate(w, on: false) { [weak self] in self?.autoArrange() } } }
            w.onDropPaths = { [weak self] paths in self?.host.type(id, paths.joined(separator: " ") + " ") }
            // 11-23 Keng「調整每一個衛星小視窗大小時，其他的衛星也要跟著一起變」
            w.onResized = { [weak self, weak w] size in
                guard let self else { return }
                for o in self.satWins.values where o !== w && !o.isHidden { o.matchSize(size) }
            }
            w.acceptFileDrops()
            root.addSubview(w)
            satWins[id] = w
        }
        raise(w)
        markSecretary()
        if w.isHidden || !w.wantShown { animate(w, on: true); autoArrange() } else { w.flash() }
        window.makeFirstResponder(w.content)
    }
    /// 11-23 Keng「點左上角綠燈應該是完全關閉：按下去先跟我確認，確認後清掉整個內容再關掉」
    /// 確認 → host.end：掛斷終端機程式（Orbit42 開的 AI 會結束）、丟掉捲動紀錄與網頁視圖、從球上拿掉 → onRemoved 關小視窗。
    /// 拉進來看的背景 session 也一起停掉（claude stop）
    private func confirmEnd(_ id: String) {
        guard window.attachedSheet == nil else { return }
        if host.isClaude(id) { return confirmWrapUp(id) }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "關閉「\(host.name(id))」？"
        a.informativeText = host.isAttached(id)
            ? "會停掉這個背景 session（裡面正在跑的工作會中斷），並清掉這個視窗的全部內容。對話紀錄會保留，之後可以用 claude attach 接回來。"
            : "會結束這顆衛星裡正在跑的程式，並清掉這個視窗的全部內容，無法還原。"
        let ok = a.addButton(withTitle: "關閉"); ok.hasDestructiveAction = true
        a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        confirmAlert = a
        a.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                self?.confirmAlert = nil
                if r == .alertFirstButtonReturn { self?.host.end(id) }
            }
        }
    }
    /// 11-24 Keng「叉叉＝收工關閉：先確認要不要 commit 跟 push，不用就進入 clear，然後真正關閉這個 session；中間灰鈕才是收起」
    /// Claude 衛星按叉叉：①先 commit＋push 再關（它自己收工，做完自動 /clear、停掉、從清單拿掉） ②取消 ③不用，直接 /clear 並關閉
    private func confirmWrapUp(_ id: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        if host.wrapping.contains(id) {
            a.messageText = "「\(host.name(id))」正在收工"
            a.informativeText = "它還在 commit／push。要等它做完（做完會自動 /clear 並關閉），還是現在就直接關？"
            a.addButton(withTitle: "繼續等")
            let now = a.addButton(withTitle: "現在直接關閉"); now.hasDestructiveAction = true
            confirmAlert = a
            a.beginSheetModal(for: window) { [weak self] r in
                MainActor.assumeIsolated { self?.confirmAlert = nil; if r == .alertSecondButtonReturn { self?.host.end(id) } }
            }
            return
        }
        a.messageText = "收工並關閉「\(host.name(id))」？"
        a.informativeText = (host.isAttached(id) ? "關閉＝真的結束這個背景 session，並從戰情列表拿掉（對話紀錄保留，claude --resume 找得到）。" : "關閉＝結束這個 Claude，並清掉這個視窗的內容。")
            + "\n\n要先讓它 commit＋push 嗎？做完會自動 /clear 再關閉。只想收起來不關，請按中間的灰色鈕。"
        a.addButton(withTitle: "先 commit＋push 再關閉")
        a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let direct = a.addButton(withTitle: "不用，直接 clear 並關閉"); direct.hasDestructiveAction = true
        confirmAlert = a
        a.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.confirmAlert = nil
                guard r == .alertFirstButtonReturn || r == .alertThirdButtonReturn else { return }
                self.host.wrapUp(id, commit: r == .alertFirstButtonReturn) { [weak self] msg in self?.wrapUpProblem(id, msg) }
            }
        }
    }
    private func wrapUpProblem(_ id: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = "「\(host.name(id))」還沒關"
        a.informativeText = msg
        a.addButton(withTitle: "好，視窗留著")
        let now = a.addButton(withTitle: "還是直接 clear 並關閉"); now.hasDestructiveAction = true
        confirmAlert = a
        let show = { [weak self] in
            guard let self else { return }
            a.beginSheetModal(for: self.window) { [weak self] r in
                MainActor.assumeIsolated { self?.confirmAlert = nil; if r == .alertSecondButtonReturn { self?.host.wrapUp(id, commit: false) { _ in } } }
            }
        }
        if window.attachedSheet == nil { show() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { show() } } }
    }
    var confirmAlert: NSAlert?          // 測試 hook 用（按確認視窗的按鈕）
    private func closeSat(_ id: String) {
        guard let w = satWins.removeValue(forKey: id) else { return }
        lift.drop(id); if pinned == id { pinned = nil }; restack()
        dropMoons(id); moonSids[id] = nil
        animate(w, on: false) { [weak self] in w.removeFromSuperview(); self?.autoArrange() }
    }
    /// 11-24 Keng「點擊全收是第一下，點第二下應該要全部跳回來」：點球體空白處＝切換。
    /// 有開著的 ⇒ 記住是哪幾顆、全部收下去；都收著而且有記住的 ⇒ 那幾顆全部叫回來。中間自己打開任何一顆，就從「收」重新算
    private var tucked: [String] = []
    func hideAllSats() {
        let open = satWins.filter { !$0.value.isHidden && $0.value.wantShown }.map(\.key)
        if open.isEmpty {
            let back = tucked.filter { satWins[$0] != nil }; tucked = []
            for id in back { showSat(id) }
            return
        }
        tucked = open
        for id in open { if let w = satWins[id] { animate(w, on: false) } }
    }

    // MARK: 疊放與滑過浮起（11-25 Keng）：平常照排列順序疊，滑過 0.15 秒浮起（只改畫的順序，不動焦點、位置、打字目標）
    var pinned: String?                 // 點過／在裡面打字的那顆：留在上面，點別顆才換
    var lift = HoverLift()
    var mouse: NSPoint?                 // 主視窗座標；nil＝不在視窗裡
    var lastScroll = 0.0, menuOpen = 0, liftTimer: Timer?
    private var liftTrack: LiftTracker?
    private var stackWins: [SatStack.Win] { satWins.map { SatStack.Win(id: $0.key, seq: $0.value.seq, secretary: $0.value.secretary) } }
    private func id(of w: NSView) -> String? { satWins.first { $0.value === w }?.key }
    var typingSat: String? {
        guard let v = window.firstResponder as? NSView else { return nil }
        return satWins.first { v.isDescendant(of: $0.value.content) }?.key
    }
    private func raise(_ w: NSView) {
        pinned = id(of: w); lift.settle(hover: hoverSat()); restack()
    }
    private var stackOrder: [String] { SatStack.order(stackWins, pinned: pinned, lifted: lift.lifted) }
    private func hoverSat() -> String? {
        guard let p = mouse else { return nil }
        if askFloat?.covers(p) == true { return nil }       // 在答案卡上：不算碰到底下的終端機
        let shown = satWins.filter { !$0.value.isHidden && $0.value.wantShown }
        return SatStack.hit(p, order: stackOrder, frames: shown.mapValues(\.frame))
    }
    private var liftPaused: Bool {
        NSEvent.pressedMouseButtons != 0 || CACurrentMediaTime() - lastScroll < 0.3 || menuOpen > 0 || window.attachedSheet != nil || NSApp.modalWindow != nil
            || host.composing.contains { satWins[$0]?.isHidden == false } || askFloat?.dragging == true
    }
    func liftStep() {
        let now = CACurrentMediaTime(), was = lift.lifted
        lift.step(now, hover: hoverSat(), inside: mouse != nil && (window.isKeyWindow || liftTest), paused: liftPaused)
        if lift.lifted != was { restack() }
        liftTimer?.invalidate(); liftTimer = nil
        // 有事在等（停留、歸位緩衝）才排下一次；暫停中有浮起或滑鼠在視窗裡時 0.1 秒再看，沒事就完全不跑
        let next = lift.due(now) ?? (liftPaused && mouse != nil && !satWins.isEmpty ? 0.1 : nil)
        if let t = next { liftTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, t), repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.liftStep() } } }
    }
    var liftTest = false
    /// 照順序設 zPosition、重排 subview（不把視圖拿下來重放，終端機不會失焦）；變暗與打字標記一起更新
    func restack() {
        guard let root = window.contentView else { return }
        let order = stackOrder, typing = lift.lifted == nil ? nil : typingSat, dim = SatStack.dimmed(order, lifted: lift.lifted, typing: typing)
        let move = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var changed = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, id) in order.enumerated() {
            guard let w = satWins[id] else { continue }
            w.wantsLayer = true; let z = CGFloat(10 + i)
            if w.layer?.zPosition != z { w.layer?.zPosition = z; changed = true }
            w.setLift(dim: dim.contains(id), typing: typing == id && lift.lifted != id, animate: move)
        }
        CATransaction.commit()
        guard changed else { return }
        root.sortSubviews({ a, b, _ in
            let za = a.layer?.zPosition ?? 0, zb = b.layer?.zPosition ?? 0
            return za < zb ? .orderedAscending : za > zb ? .orderedDescending : .orderedSame
        }, context: nil)
    }
    func startLift() {
        guard let root = window.contentView else { return }
        let t = LiftTracker(); liftTrack = t
        t.moved = { [weak self] e in
            guard let self, let root = self.window.contentView else { return }
            self.mouse = e.map { root.convert($0.locationInWindow, from: nil) }
            self.liftStep()
        }
        root.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: t))
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, e.window === self.window else { return }
                if e.type == .scrollWheel { self.lastScroll = CACurrentMediaTime(); if self.lift.lifted != nil || self.lift.due(0) != nil { self.liftStep() } }
                else if !e.modifierFlags.contains(.command), let s = self.typingSat, self.pinned != s || self.lift.lifted != nil {      // 在裡面打字：那顆留在上面
                    self.pinned = s; self.lift.settle(hover: self.hoverSat()); self.restack()
                }
            }
            return e
        }
        let nc = NotificationCenter.default
        for (n, d) in [(NSMenu.didBeginTrackingNotification, 1), (NSMenu.didEndTrackingNotification, -1)] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { if let self { self.menuOpen = max(0, self.menuOpen + d) } } }
        }
        for n in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification] {
            nc.addObserver(forName: n, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.mouse = nil; self?.liftStep() } }
        }
    }
    func raiseUnder(_ e: NSEvent) {
        guard e.window === window, let root = window.contentView else { return }
        let p = root.convert(e.locationInWindow, from: nil)
        if askFloat?.covers(p) == true { return }        // 點在答案卡上：不把底下的衛星提上來
        guard let w = root.subviews.last(where: { ($0 as? TermWindowView)?.yieldingToAsk == false && !$0.isHidden && $0.frame.contains(p) }) else { return }
        raise(w)
    }

    private func layoutTerm() {
        guard let root = window.contentView else { return }
        // Orbit42 視窗變小：開著的小視窗縮進來、留在視窗裡
        for w in satWins.values where !w.isHidden { w.frame = TermWindowView.fit(w.frame, in: root.bounds) }
        askFloat?.layout()
    }
    /// 小視窗打開時從下方放大淡入（像 macOS 開視窗），收起時縮小淡出
    private func animate(_ w: TermWindowView, on: Bool, then: (() -> Void)? = nil) {
        w.wantShown = on; w.yieldingToAsk = false
        guard let layer0 = w.layer, let root = window.contentView else { w.isHidden = !on; then?(); return }
        nonisolated(unsafe) let layer = layer0      // 動畫完成的 closure 一樣在主執行緒
        if on {
            w.frame = TermWindowView.fit(w.frame, in: root.bounds)
            w.isHidden = false; w.alphaValue = 0
            layer.setAffineTransform(CGAffineTransform(scaleX: 0.94, y: 0.94))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.26; ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                w.animator().alphaValue = 1
                layer.setAffineTransform(.identity)
            }
            w.flash()                                 // 邊框亮一下紅光
            then?()
        } else {
            guard !w.isHidden else { then?(); return }
            w.setBreathing(false)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2; ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                w.animator().alphaValue = 0
                layer.setAffineTransform(CGAffineTransform(scaleX: 0.94, y: 0.94))
            }, completionHandler: { MainActor.assumeIsolated {
                guard !w.wantShown else { return }          // 收到一半又被打開：不要藏
                w.isHidden = true; w.alphaValue = 1; layer.setAffineTransform(.identity)
                then?()
            } })
        }
    }
    func windowDidResize(_ n: Notification) { layoutTerm(); placeChanged() }
    func windowWillClose(_ n: Notification) { host.shutdown(); NSApp.terminate(nil) }
}
