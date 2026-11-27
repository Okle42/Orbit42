import AppKit
import WebKit
import Orbit42App
import Orbit42Core

// 螢幕外測試用的掛勾（ORBIT_TEST_*）：原本夾在 OrbitWindow.show 裡，11-25 原樣搬出來。平常不會跑
extension OrbitWindow {
    func runTestHooks(_ env: [String: String], test: Bool) {
        guard let root = window.contentView else { return }
        _ = root
        runReadmeShot(env, test: test)      // ReadmeShotHook.swift：README 用的衛星 Chrome 截圖
        runAccountTest(env, test: test)     // AccountTestHook.swift：真的登一次 Google
        runHeadlessWakeTest(env, test: test) // HeadlessWakeTest.swift：卡 110 欄的衛星顯示後要重新量
        // 測試（11-28）：ORBIT_TEST_ARRANGE_SHOT="<個數>@<png>" ⇒ 開 n 顆衛星（最後一顆當秘書）→ 自動排版截圖 →
        // 假滑鼠滑進第 2 顆露出的地方（不點）截圖，印每顆位置大小、疊放、輸入點在哪顆
        if let spec = env["ORBIT_TEST_ARRANGE_SHOT"], let at = spec.firstIndex(of: "@"), let n = Int(spec[..<at]), test {
            let out = String(spec[spec.index(after: at)...])
            @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
            after(3) { [weak self] in
                guard let self else { return }
                self.login.web.isHidden = true; self.liftTest = true
                self.applyTheme(env["ORBIT_TEST_THEME"] ?? "dark")
                (self.sphereView as? WKWebView)?.evaluateJavaScript("window.karaTheme('\(self.themeNow)')", completionHandler: nil)
                let ids = (1...n).map { i in self.host.runCommand(name: i == n ? "秘書（測試）" : "測試 \(i)", brain: .claude,
                    command: "for k in $(seq 1 30); do echo 衛星 \(i) 第 $k 行 ── 滑過去輸入點就在這顆; done; sleep 90") }
                if let s = ids.last { self.satWins[s]?.secretary = true }
                // 螢幕外的視窗 WebKit 會當成「被遮住」不畫字 ⇒ 測試時關掉遮蔽偵測（只在這個測試掛勾）
                let occ = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
                for id in ids { let v = self.host.view(for: id); if v.responds(to: occ) { v.perform(occ, with: nil) } }
                func num(_ id: String?) -> String { id.flatMap { ids.firstIndex(of: $0) }.map { "\($0 + 1)" } ?? "-" }
                // 11-28：要看字糊不糊 ⇒ 拍視窗伺服器合成後的畫面（含 layer 放大、網頁終端機的字）；視窗在螢幕外 -30000，Keng 看不到
                self.window.alphaValue = 1
                @MainActor func grab() -> CGImage? {
                    CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(self.window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
                }
                @MainActor func save(_ cg: CGImage, _ name: String) { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "." + name + ".png")) }
                /// 第 2 顆左上角那塊字（同一個畫面位置，原尺寸像素）：放大前後擺一起比
                @MainActor func closeup(_ cg: CGImage, _ name: String) {
                    let f = self.satWins[ids[1]]!.frame, k = CGFloat(cg.width) / root.bounds.width
                    let r = CGRect(x: (f.minX + 8) * k, y: (root.bounds.height - f.maxY + TermWindowView.barHeight + 4) * k, width: 300 * k, height: 120 * k).integral
                    if let c = cg.cropping(to: r) { save(c, name) }
                }
                @MainActor func shot(_ tag: String) {
                    if let cg = grab() { save(cg, tag) }
                    else if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                        root.cacheDisplay(in: root.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "." + tag + ".png"))
                    }
                    let order = root.subviews.compactMap { v in ids.firstIndex { self.satWins[$0] === v }.map { "\($0 + 1)" } }.joined()
                    print("arrange \(tag) root=\(Int(root.bounds.width))x\(Int(root.bounds.height)) order=\(order) typing=\(num(self.typingSat)) "
                          + ids.map { let f = self.satWins[$0]!.frame; return "#\(num($0)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))" }.joined(separator: " | ")); fflush(stdout)
                }
                after(6) {
                    self.window.setContentSize(NSSize(width: 1440, height: 900))
                    after(1) { self.pinned = nil; self.autoArrange()
                    after(1.5) { shot("1自動排版"); if let cg = grab() { closeup(cg, "字特寫-放大前") }
                        let termBefore = NSStringFromRect(self.satWins[ids[1]]!.content.convert(self.satWins[ids[1]]!.content.bounds, to: root))
                        let f = self.satWins[ids[1]]!.frame; self.mouse = NSPoint(x: f.minX + 20, y: f.maxY - 14)
                        let w2 = self.satWins[ids[1]]!, w0 = w2.chromeNow.width
                        // 11-28 Keng「閃一下」：ORBIT_TEST_FRAMES=<資料夾> ⇒ 選到前拍一張，之後每 8 毫秒拍一張、拍 0.3 秒（逐格找閃的那格）
                        if let dir = env["ORBIT_TEST_FRAMES"] {
                            let f2 = w2.frame, f3 = self.satWins[ids[2]]!.frame, H = root.bounds.height
                            print("arrange frames root=\(Int(root.bounds.width))x\(Int(H)) w2=\(Int(f2.minX)),\(Int(H - f2.maxY)),\(Int(f2.width)),\(Int(f2.height)) w3=\(Int(f3.minX)),\(Int(H - f3.maxY))")
                            if let cg = grab() { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/f000.png")) }
                            let t0 = CACurrentMediaTime()
                            for k in 1...38 { after(Double(k) * 0.008) { if let cg = grab() { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/f%03d-%03dms.png", dir, k, Int((CACurrentMediaTime() - t0) * 1000)))) } } }
                        }
                        let t = CACurrentMediaTime(); self.liftStep(); let dt = (CACurrentMediaTime() - t) * 1000
                        for ms in [40, 80, 160, 300] { after(Double(ms) / 1000) { let c = w2.chromeNow; print("arrange anim \(ms)ms 外框寬=\(Int(c.width))（起 \(Int(w0))） 透明度=\(String(format: "%.2f", c.opacity))") } }
                        print(String(format: "arrange hover 2 → typing=%@ top=%@ step=%.2fms", num(self.typingSat), num(self.pinned), dt))
                    after(env["ORBIT_TEST_FRAMES"] != nil ? 1.2 : 0.6) { shot("2滑過第2顆"); if let cg = grab() { closeup(cg, "字特寫-放大後") }
                        // 11-28 Keng「放大的情況下按不到叉叉」：在每顆的紅綠燈中心點模擬點擊，看點到的是誰
                        @MainActor func lights(_ v: NSView) -> [TrafficLight] { v.subviews.flatMap { ($0 as? TrafficLight).map { [$0] } ?? lights($0) } }
                        for (i, id) in ids.enumerated() {
                            let w = self.satWins[id]!
                            let r = lights(w).map { l -> String in
                                let c = l.convert(NSPoint(x: l.bounds.midX, y: l.bounds.midY), to: root), hit = root.hitTest(c)
                                return "\(l.kind)@\(Int(c.x)),\(Int(c.y))→\(hit === l ? "✓" : hit.map { "✗\(type(of: $0))" } ?? "✗nil")"
                            }
                            print("arrange light #\(i + 1) raised=\(w.raised) \(r.joined(separator: " "))")
                        }
                        print("arrange raised=\(ids.filter { self.satWins[$0]?.raised == true }.map { num($0) }.joined()) outset=\(self.satWins[ids[1]]!.liftOutset) term=\(NSStringFromRect(self.satWins[ids[1]]!.content.convert(self.satWins[ids[1]]!.content.bounds, to: root))) 放大前 term=\(termBefore)")
                        self.mouse = NSPoint(x: 5, y: 5); self.liftStep()
                        print("arrange leave → typing=\(num(self.typingSat))（要留在 2）"); fflush(stdout)
                        // 11-28：先選最後一顆，再從左邊把滑鼠移向它的叉叉（路上經過別顆）：快速 vs 慢慢
                        let last = ids[n - 1]
                        @MainActor func closeOf(_ id: String) -> (NSPoint, TrafficLight) { let l = lights(self.satWins[id]!).first { $0.kind == .close }!; return (l.convert(NSPoint(x: l.bounds.midX, y: l.bounds.midY), to: root), l) }
                        @MainActor func sweep(_ k: Int, _ steps: Int, _ dt: Double, _ from: NSPoint, _ to: NSPoint, _ seen: [String], _ done: @escaping @MainActor ([String]) -> Void) {
                            guard k <= steps else { return done(seen) }
                            let f = CGFloat(k) / CGFloat(steps), p = NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
                            self.mouse = p; self.mouseSpeed.add(CACurrentMediaTime(), p); self.liftStep()
                            let s2 = seen.last == num(self.lift.lifted) ? seen : seen + [num(self.lift.lifted)]
                            after(dt) { sweep(k + 1, steps, dt, from, to, s2, done) }
                        }
                        @MainActor func trial(_ name: String, _ steps: Int, _ dt: Double, then: @escaping @MainActor () -> Void) {
                            self.mouse = nil; self.pinned = last; self.lift.settle(last, hover: nil); self.restack(); self.mouseSpeed = MouseSpeed()
                            let (c, l) = closeOf(last), from = NSPoint(x: 200, y: c.y)
                            after(0.2) { sweep(0, steps, dt, from, c, [num(self.lift.lifted)]) { seen in
                                after(0.15) {
                                    let hit = root.hitTest(closeOf(last).0)
                                    print("arrange \(name) 經過=\(seen.joined(separator: "→")) 停下後選到=\(num(self.lift.lifted)) 點叉叉=\(hit === l ? "✓ 點得到" : "✗ 被別顆蓋住")"); fflush(stdout)
                                    then()
                                }
                            } }
                        }
                        trial("快速移向最後一顆的叉叉", 20, 0.008) { trial("慢慢移向最後一顆的叉叉", 30, 0.06) { self.host.shutdown(); exit(0) } }
                        } } }
                }
            }
        }
        // 測試：ORBIT_TEST_ASK="<題目 json>@<png>" ⇒ 開 3 顆印字的衛星＋假題目，整個主視窗截圖（展開、縮成一條），印位置後結束
        if let spec = env["ORBIT_TEST_ASK"], let at = spec.lastIndex(of: "@"), test {
            let out = String(spec[spec.index(after: at)...])
            @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
            @MainActor func shot(_ path: String) {
                guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("ask shot \(path) float=\(askFloat?.view.frame ?? .zero) hidden=\(askFloat?.view.isHidden ?? true) first=\(type(of: window.firstResponder ?? self))"); fflush(stdout)
            }
            after(3) { [weak self] in
                guard let self else { return }
                self.login.web.isHidden = true
                self.applyTheme(env["ORBIT_TEST_THEME"] ?? "dark")
                (self.sphereView as? WKWebView)?.evaluateJavaScript("window.karaTheme('\(self.themeNow)')", completionHandler: nil)
                for i in 1...3 { _ = self.host.runCommand(name: "測試 \(i)", brain: .claude, command: "for n in 1 2 3 4 5 6 7 8; do echo 衛星 \(i) 第 $n 行; done; sleep 60") }
                after(4) {
                    self.askFloat?.testUpdate(URL(fileURLWithPath: String(spec[..<at])))
                    after(2) { shot(out); self.askFloat?.testJS("collapse(false)"); after(2) { shot(out + ".strip.png")
                        self.askFloat?.testJS("expand()"); after(1) { self.window.setContentSize(NSSize(width: 620, height: 460)); after(2) { shot(out + ".small.png"); self.host.shutdown(); exit(0) } } } }
                }
            }
        }
        // 測試：ORBIT_TEST_LIFT="<題目 json>@<png>" ⇒ 7 顆衛星，假滑鼠位置：平常、滑過、打字中另一顆被滑過、答案卡同時在；印疊放／焦點／位置有沒有變、每步耗時
        if let spec = env["ORBIT_TEST_LIFT"], let at = spec.lastIndex(of: "@"), test {
            let out = String(spec[spec.index(after: at)...])
            @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
            after(3) { [weak self] in
                guard let self else { return }
                self.login.web.isHidden = true; self.liftTest = true
                self.askFloat?.testUpdate(URL(fileURLWithPath: "/dev/null"))
                self.applyTheme(env["ORBIT_TEST_THEME"] ?? "dark")
                (self.sphereView as? WKWebView)?.evaluateJavaScript("window.karaTheme('\(self.themeNow)')", completionHandler: nil)
                let ids = (1...7).map { i in self.host.runCommand(name: "測試 \(i)", brain: .claude, command: "for n in 1 2 3 4 5 6; do echo 衛星 \(i) 第 $n 行; done; sleep 90") }
                func num(_ id: String?) -> String { id.flatMap { ids.firstIndex(of: $0) }.map { "\($0 + 1)" } ?? "-" }
                @MainActor func shot(_ tag: String) {
                    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                    root.cacheDisplay(in: root.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "." + tag + ".png"))
                    print("lift \(tag) order=\(root.subviews.compactMap { v in ids.firstIndex { self.satWins[$0] === v }.map { "\($0 + 1)" } }.joined()) lifted=\(num(self.lift.lifted)) typing=\(num(self.typingSat)) dim=\(ids.filter { self.satWins[$0]?.dimmed == true }.map { num($0) }.joined()) last=\(type(of: root.subviews.last!)) frames=\(ids.map { NSStringFromRect(self.satWins[$0]!.frame) }.joined().hashValue)"); fflush(stdout)
                }
                @MainActor func over(_ i: Int) { let f = self.satWins[ids[i]]!.frame; self.mouse = NSPoint(x: f.minX + 40, y: f.maxY - 14); self.liftStep() }
                after(6) {
                    self.pinned = nil; self.restack()
                    self.window.makeFirstResponder(self.satWins[ids[3]]!.content)
                    let fr = self.window.firstResponder
                    shot("1平常"); over(1)
                    after(0.05) { print("lift 0.05s lifted=\(num(self.lift.lifted))")
                    after(0.8) { shot("2滑過"); print("lift focus same=\(self.window.firstResponder === fr)"); do { let f = self.satWins[ids[5]]!.frame; self.mouse = NSPoint(x: f.maxX - 30, y: f.maxY - 14); self.liftStep() }
                    after(0.8) { shot("3打字中另一顆被滑過")
                        self.askFloat?.testUpdate(URL(fileURLWithPath: String(spec[..<at])))
                    after(2) { over(1); after(0.8) { shot("4答案卡同時在"); self.mouse = nil; self.liftStep(); shot("5離開歸位")
                        print("lift focus same=\(self.window.firstResponder === fr) timer=\(self.liftTimer != nil)")
                        let t = CACurrentMediaTime(); for k in 0..<2000 { self.mouse = NSPoint(x: CGFloat(200 + k % 900), y: 400); self.liftStep() }
                        print(String(format: "lift step=%.1fus", (CACurrentMediaTime() - t) / 2000 * 1e6)); fflush(stdout); self.host.shutdown(); exit(0) } } } } }
                }
            }
        }
        startModels(test: test); startMoons(); startLift()
        MacWindows.shared.installMenu()
        ChromeGoogleLogin.shared.installMenu()      // 11-26：衛星 Chrome 登入 Google（App 選單，不加畫面按鈕）
        SecCheckWindow.shared.installMenu()         // 11-28：本機資安體檢小視窗（App 選單／orbit seccheck --open）
        if !test { SecSchedule.shared.start() }     // 11-28：每週＋換 Wi-Fi 自動體檢，有變化才通知
        WebAgent.shared.start()                     // 11-26：衛星裡的 AI 操作網頁（scripts/orbit-web；寄信刪檔付款先問）
        // 測試：ORBIT_TEST_MACWIN=<png 資料夾> ⇒ 列視窗、拍每個（只看不操作）、測操作會不會擋
        if let out = env["ORBIT_TEST_MACWIN"] {
            Task { @MainActor in
                @MainActor func ask(_ s: String, _ have: Int = 0) -> [String: Any] { (SphereEmbed.remoteScreen?("mac|" + s, have, nil)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
                try? await Task.sleep(for: .seconds(2)); _ = ask("list"); try? await Task.sleep(for: .seconds(1))
                let l = ask("list"); print("mw msg=\(l["msg"] ?? "-") control=\(l["control"] ?? "-")")
                for w in l["wins"] as? [[String: Any]] ?? [] {
                    let id = "\(w["id"] ?? 0)"; _ = ask(id); try? await Task.sleep(for: .seconds(1.2))
                    let f = ask(id), d = (f["data"] as? String).flatMap { Data(base64Encoded: $0) }
                    print("mw \(id) \(w["app"] ?? "") on=\(w["on"] ?? "") \(f["w"] ?? 0)x\(f["h"] ?? 0) jpg=\(d?.count ?? 0) msg=\(f["msg"] ?? "") again=\(ask(id, f["seq"] as? Int ?? 0)["data"] == nil)")
                    try? d?.write(to: URL(fileURLWithPath: out + "/" + id + ".jpg"))
                }
                print("mw bad \(ask("x")) \(ask("999999999")) input=\(SphereEmbed.remoteInput?("mw-999999999", Data("[]".utf8)) ?? true)")
                fflush(stdout); self.host.shutdown(); exit(0)
            }
        }
        // 測試：ORBIT_TEST_PHONEWEB=<網址> ⇒ 走手機的兩條路（remoteScreen／remoteInput）看、點、打字、捲、選單、對話框、離開還原
        if let u = env["ORBIT_TEST_PHONEWEB"] {
            let out = env["ORBIT_TEST_CHROME_SHOT"] ?? "/dev/null"
            Task { @MainActor [weak self] in
                func nap(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
                await nap(3)
                guard let self else { return }
                let id = self.host.runCommand(name: "手機網頁測試", brain: .claude, command: "sleep 60")
                var have = 0
                @MainActor func look() -> [String: Any] {
                    let d = SphereEmbed.remoteScreen?("pane|\(id)|web", have, (cols: 390, rows: 640))
                    let o = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    if let s = o["seq"] as? Int { have = s }
                    return o
                }
                @MainActor func act(_ ops: [[String: Any]]) -> Bool { SphereEmbed.remoteInput?("pw-" + id, (try? JSONSerialization.data(withJSONObject: ops)) ?? Data()) ?? false }
                @MainActor func size(_ o: [String: Any]) -> Int { (o["data"] as? String)?.count ?? 0 }
                print("pw closed=\(look()) tap=\(act([["k": "tap"]])) file=\(act([["k": "nav", "u": "/etc/x.html"]])) nosat=\(SphereEmbed.remoteInput?("pw-nope", Data("[]".utf8)) ?? true)")
                print("pw nav=\(act([["k": "nav", "u": u]]))")
                for _ in 0..<12 { _ = look(); await nap(0.3) }
                guard let p = self.moonViews(id)["web"] as? WebPane else { print("pw no pane"); exit(1) }
                @MainActor func js(_ s: String) async -> String { await withCheckedContinuation { c in p.web.eval(s) { c.resume(returning: $0) } } }
                have = 0; let a = look()
                print("pw still seq=\(a["seq"] ?? "-") \(a["w"] ?? 0)x\(a["h"] ?? 0) b64=\(size(a)) title=\(a["title"] ?? "") again=\(size(look())) shown=\(self.satWins[id]?.pane === p)")
                if let s = a["data"] as? String { try? Data(base64Encoded: s)?.write(to: URL(fileURLWithPath: out + ".phone.jpg")) }
                print("pw view=\(await js("innerWidth+'x'+innerHeight+'@'+devicePixelRatio"))")
                @MainActor func tapOn(_ sel: String) async { let v = await js("(()=>{const r=document.querySelector('\(sel)').getBoundingClientRect();return (r.x+r.width/2)+','+(r.y+r.height/2)})()").split(separator: ",").compactMap { Double($0) }; if v.count == 2 { _ = act([["k": "tap", "x": v[0], "y": v[1]]]) }; await nap(0.6) }
                await tapOn("#i"); print("pw edit=\(look()["edit"] ?? "-")")
                _ = act([["k": "text", "t": "你好 voice 123"], ["k": "key", "n": "Backspace"], ["k": "key", "n": "Enter"]]); await nap(0.4)
                print("pw input=\(await js("document.getElementById('i').value+'|'+document.getElementById('o').textContent"))")
                await tapOn("#p"); print("pw pass=\(look()["edit"] ?? "-")")
                await tapOn("#s"); print("pw select=\(look()["edit"] ?? "-")")
                _ = act([["k": "pick", "i": 2]]); await nap(0.4); print("pw picked=\(await js("document.getElementById('s').value+'|'+document.getElementById('o').textContent"))")
                await tapOn("#c"); print("pw ask=\(look()["ask"] ?? "-")")
                _ = act([["k": "answer", "ok": true]]); await nap(0.5); print("pw answered=\(await js("document.getElementById('o').textContent")) ask=\(look()["ask"] ?? "-")")
                _ = act([["k": "scroll", "x": 100, "y": 300, "dx": 0, "dy": 400]]); await nap(0.15)
                let m = look(); await nap(0.8); let n = look()
                print("pw scroll=\(await js("''+scrollY")) moving=\(size(m)) seq=\(m["seq"] ?? "-") then=\(size(n)) seq=\(n["seq"] ?? "-")")
                if let d = p.web.snapshot { try? NSBitmapImageRep(cgImage: d).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + ".phone2.png")) }
                print("pw wide=\(n["wide"] ?? "-") ua=\(await js("navigator.userAgent.slice(0,40)+navigator.userAgentData?.mobile"))")
                _ = act([["k": "nav", "u": u + "two.html"]]); for _ in 0..<5 { await nap(0.3); _ = look() }
                print("pw nav2=\(look()["url"] ?? "")"); _ = act([["k": "back"]]); for _ in 0..<5 { await nap(0.3); _ = look() }
                print("pw back=\(look()["url"] ?? "")")
                _ = act([["k": "scroll", "x": 10, "y": 10, "dy": 1e300], ["k": "??"], ["k": "nav", "u": "file:///etc/hosts"]]); await nap(0.5); print("pw bad url=\(look()["url"] ?? "")")
                self.showMoon(id, "web"); for _ in 0..<4 { _ = look(); await nap(0.3) }
                print("pw shown view=\(await js("innerWidth+'x'+innerHeight")) on=\(p.web.phoneOn)")
                await nap(6.5)
                print("pw left view=\(await js("innerWidth+'x'+innerHeight+'@'+devicePixelRatio")) mac=\(p.web.bounds.size) ua=\(await js("navigator.userAgent.slice(0,40)")) on=\(p.web.phoneOn) frames=\(p.web.snapshot.map { "\($0.width)x\($0.height)" } ?? "nil")")
                self.tuckMoon(id); await nap(1); let f0 = p.web.frames; for _ in 0..<5 { _ = look(); await nap(0.3) }
                print("pw tucked frames +\(p.web.frames - f0)"); await nap(6); print("pw after on=\(p.web.phoneOn)")
                ChromeBrowser.shared.quit(); await nap(2); fflush(stdout); self.host.shutdown(); exit(0)
            }
        }
        // 測試：ORBIT_TEST_CHROME=<網址> ⇒ 衛星裡開 Chrome，點輸入框、組字、打字、按 Enter、開新視窗連結，印結果
        if let u = env["ORBIT_TEST_CHROME"].flatMap(WebPane.parse) {
            @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
            after(3) { [weak self] in
                guard let self else { return }
                let id = self.host.runCommand(name: "Chrome 測試", brain: .claude, command: "sleep 60")
                self.openWeb(u, sat: id)
                after(8) {
                    guard let p = self.moonViews(id)["web"] as? WebPane else { print("chrome: no pane"); exit(1) }
                    let w = p.web
                    print("chrome frames=\(w.frames) title=\(p.titleText) url=\(p.currentURL) msg=\(p.messageText)")
                    w.testClick(60, 30)
                    after(1) {
                        w.setMarkedText("ㄋㄧˇ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                        w.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0)); w.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
                        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) { w.keyDown(with: e) }
                        after(1) {
                            w.eval("document.getElementById('i').value + '|' + document.getElementById('o').textContent + '|' + navigator.userAgent + '|' + innerWidth + 'x' + innerHeight + '@' + devicePixelRatio") { print("chrome input=\($0)") }
                            if let cg = w.snapshot { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: env["ORBIT_TEST_CHROME_SHOT"] ?? "/dev/null")) }
                            w.eval("(()=>{const r=document.getElementById('a').getBoundingClientRect();return r.x+5+','+(r.y+5)})()") { xy in
                                let v = xy.split(separator: ",").compactMap { Double($0) }; if v.count == 2 { w.testClick(v[0], v[1]) }
                            }
                            after(4) {
                                print("chrome popup url=\(p.currentURL)"); w.go(-1)
                                after(2) {
                                    print("chrome back url=\(p.currentURL)"); let n = w.frames
                                    self.tuckMoon(id); after(2) { let m = w.frames; self.showMoon(id, "web"); after(2) {
                                        print("chrome frames tuck \(n)→\(m) show→\(w.frames)"); self.dropMoon(id, "web"); ChromeBrowser.shared.quit()
                                        after(3) { print("chrome running=\(ChromeBrowser.shared.running)"); fflush(stdout); self.host.shutdown(); exit(0) }
                                    } }
                                }
                            }
                        }
                    }
                }
            }
        }
        // 測試：ORBIT_TEST_PANE="<檔案1>|<檔案2>@<png>" ⇒ 開一顆印字的衛星，先把檔案 1 開成獨立視窗、再開進衛星（獨立視窗要不見），
        // 截圖 <png>；再開檔案 2（同一塊面板）截 <png>.2.png；放大視窗截 .3.png；關面板後終端機要回滿版
        if let spec = env["ORBIT_TEST_PANE"], let at = spec.lastIndex(of: "@") {
            let fs = spec[..<at].split(separator: "|").map { URL(fileURLWithPath: String($0)) }, out = String(spec[spec.index(after: at)...])
            @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
            @MainActor func shot(_ w: TermWindowView, _ v: ModelView, _ path: String) {
                let img = NSImage(size: w.bounds.size)
                if let rep = w.bitmapImageRepForCachingDisplay(in: w.bounds) { w.cacheDisplay(in: w.bounds, to: rep); img.addRepresentation(rep) }
                let s = v.scn.snapshot(), final = NSImage(size: w.bounds.size)
                final.lockFocus(); NSColor(white: 0.12, alpha: 1).setFill(); NSRect(origin: .zero, size: w.bounds.size).fill(); img.draw(in: w.bounds)
                if !v.isImage { s.draw(in: w.convert(v.scn.bounds, from: v.scn)) }
                final.unlockFocus()
                if let t = final.tiffRepresentation, let r = NSBitmapImageRep(data: t) { try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
                print("pane win=\(w.frame.size) side=\(w.sideBySide) term=\(w.content.frame) pane=\(v.frame) | \(v.summaryText) \(v.messageText)"); fflush(stdout)
            }
            after(3) { [weak self] in
                guard let self else { return }
                let id = self.host.runCommand(name: "面板測試", brain: .claude, command: "echo sat=$ORBIT_SAT; sleep 60")
                self.openModel(fs[0])
                after(5) {
                    print("standalone before: \(self.modelCount)")
                    self.openView(fs[0], sat: id)
                    after(5) {
                        print("standalone after: \(self.modelCount)")
                        guard let (w, v) = self.pane(id) else { print("pane missing"); exit(1) }
                        shot(w, v, out)
                            @MainActor func ask(_ k: String, _ f: Int) -> [String: Any] { SphereEmbed.remoteScreen?("pane|\(id)|\(k)", f, nil).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
                            print("phone list \(ask("list", 0))")
                            var got = Data(); while let c = Data(base64Encoded: ask("3d", got.count)["data"] as? String ?? ""), !c.isEmpty { got += c }
                            try? got.write(to: URL(fileURLWithPath: out + ".mesh")); print("phone mesh \(got.count)")
                            print("phone bad \(ask("../etc", 0)) \(ask("3d", -5)) \(SphereEmbed.remoteScreen?("pane|nope|3d", 0, nil) == nil)")
                            self.openView(fs[1], sat: id)
                        after(3) {
                            shot(w, v, out + ".2.png"); print("same pane: \(self.pane(id)?.1 === v) history=\(v.history.count)")
                            print("moons \(self.moonJSON)"); w.toggleZoom()
                            after(2) { self.openView(fs[0]); after(4) {
                                shot(w, v, out + ".3.png"); v.onShut?(); w.layoutSubtreeIfNeeded()
                                print("moons after shut \(self.moonJSON)")
                                if let u = env["ORBIT_TEST_URL"].flatMap(WebPane.parse) {
                                    self.openWeb(u, sat: id)
                                    after(5) {
                                        guard let p = w.pane as? WebPane else { print("web missing"); exit(1) }
                                        print("chrome frames=\(p.web.frames) size=\(p.web.snapshot.map { "\($0.width)x\($0.height)" } ?? "nil") view=\(p.web.bounds.size)")
                                        if let cg = p.web.snapshot { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + ".chrome.png")) }
                                        print("web title=\(p.titleText) msg=\(p.messageText) moons \(self.moonJSON)")
                                        self.tuckMoon(id); print("tuck: pane=\(w.pane == nil) moons \(self.moonJSON)")
                                        self.moonCommand("moon:\(self.host.sessionId(id) ?? ""):web"); print("tap: back=\(w.pane === p)")
                                        self.moonCommand("moon:\(self.host.sessionId(id) ?? ""):web"); print("tap2: pane=\(w.pane == nil)")
                                        self.dropMoon(id, "web"); print("drop: \(self.moonJSON)"); fflush(stdout)
                                        self.host.shutdown(); exit(0)
                                    }
                                    return
                                }
                                print("shut: pane=\(w.pane == nil) term=\(w.content.frame.size) win=\(w.frame.size)"); fflush(stdout)
                                self.host.shutdown(); exit(0)
                            } }
                        }
                    }
                }
            }
        }
        // 測試：ORBIT_TEST_3D="<檔案>@<png>" ⇒ 3 秒後開 3D 小視窗，載完截圖（模型用 SCNView.snapshot 疊上去）、印資訊後結束
        if let spec = env["ORBIT_TEST_3D"], let at = spec.lastIndex(of: "@") {
            let path = String(spec[..<at]), out = String(spec[spec.index(after: at)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated {
                guard let self, let (w, v) = self.openModel(URL(fileURLWithPath: path)) else { print("3d: no window"); exit(1) }
                v.onLoaded = { ok in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated {
                    let img = NSImage(size: w.bounds.size)
                    if let rep = w.bitmapImageRepForCachingDisplay(in: w.bounds) { w.cacheDisplay(in: w.bounds, to: rep); img.addRepresentation(rep) }
                    let shot = v.scn.snapshot(), final = NSImage(size: w.bounds.size)
                    final.lockFocus(); NSColor(white: 0.12, alpha: 1).setFill(); NSRect(origin: .zero, size: w.bounds.size).fill()
                    img.draw(in: w.bounds)
                    if ok { shot.draw(in: w.convert(v.scn.bounds, from: v.scn)) }
                    final.unlockFocus()
                    if let t = final.tiffRepresentation, let r = NSBitmapImageRep(data: t) { try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) }
                    print("3d ok=\(ok) \(v.summaryText) \(v.messageText)")
                    self.closeModel(w); print("3d windows left: \(self.modelCount)"); fflush(stdout); exit(ok ? 0 : 2)
                } } }
            } }
        }
        // ⌃⌘F：全螢幕桌面模式切換（macOS 標準快捷鍵）
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command], e.charactersIgnoringModifiers?.lowercased() == "f" {
                self?.window.toggleFullScreen(nil); return nil
            }
            return e
        }
        SphereEmbed.newSatellite = { [weak self] brain in brain == "accounts" ? self?.showLogin() : self?.host.newSatellite(brain) }
        if let out = env["ORBIT_TEST_TERM_SHOT"] {         // 測試：終端機小視窗（原生標題列＋三顆燈）截圖
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["ORBIT_TEST_TERM_SHOT_DELAY"] ?? "") ?? 16)) { [weak self] in
                guard let v = self?.frontSat, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)); print("term shot saved \(out) \(v.frame)"); fflush(stdout)
            }
        }
        // 測試：ORBIT_TEST_CLOSE=<開始秒數> ⇒ 開一顆跑 sleep 的衛星，真的送滑鼠點擊到綠燈（走正常的 hitTest），
        // 先按「取消」（視窗要還在），再點一次按「關閉」（程式要結束、衛星和小視窗要不見），印結果後結束
        if let at = env["ORBIT_TEST_CLOSE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }
                // ORBIT_TEST_CLOSE_JOB=<假 job> ⇒ 改測「拉進來看的背景 session」（配 ORBIT_TEST_STOP_CMD=echo，不碰真的）
                let id: String
                if let job = env["ORBIT_TEST_CLOSE_JOB"] { self.host.attachForTest(job: job); id = "bg-" + job }
                else { id = self.host.runCommand(name: "測試衛星", brain: .claude, command: "/bin/sleep 600") }
                @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
                @MainActor func click() {
                    guard let w = self.satWins[id] else { print("close: no window"); return }
                    let p = w.closeLightPoint
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                }
                after(3) {
                    let pid = self.host.pid(id) ?? -1
                    print("close: opened pid=\(pid) win=\(self.satWins[id] != nil)"); fflush(stdout)
                    click()
                    after(1) {
                        print("close: sheet after 1st click=\(self.confirmAlert != nil) title=\(self.confirmAlert?.messageText ?? "-")"); fflush(stdout)
                        self.confirmAlert?.buttons[1].performClick(nil)          // 取消
                        after(1) {
                            print("close: after cancel win=\(self.satWins[id] != nil) sats=\(self.host.satCount) alive=\(kill(pid, 0) == 0)"); fflush(stdout)
                            click()
                            after(1) {
                                print("close: sheet after 2nd click=\(self.confirmAlert != nil)"); fflush(stdout)
                                self.confirmAlert?.buttons[0].performClick(nil)  // 關閉
                                after(2) {
                                    print("close: after confirm win=\(self.satWins[id] != nil) sats=\(self.host.satCount) view=\(self.host.views[id] != nil) alive=\(kill(pid, 0) == 0)"); fflush(stdout)
                                    NSApp.terminate(nil)
                                }
                            }
                        }
                    }
                }
            } }
        }
        // 測試：ORBIT_TEST_WRAP=<開始秒數> ⇒ 叉叉收工（11-24）：開一顆假 Claude（指令名 claude 開頭、其實是 cat，打進去的字會回顯），
        // 配 ORBIT_TEST_STATUS_FILE（假的 busy／idle）、ORBIT_TEST_RAW（終端機輸出全記下來，事後查有沒有打收工指令和 /clear）。
        // 真的點叉叉 → 印確認視窗的按鈕 → 按「先 commit＋push 再關閉」→ 1 秒後假裝開始忙、4 秒後做完 → 12 秒查視窗和程序都不見。
        // ORBIT_TEST_WRAP_NOBUSY=1 ⇒ 一直不忙：要跳出「收工指令好像沒送進去」、視窗留著
        if let at = env["ORBIT_TEST_WRAP"].flatMap(Double.init), let sf = env["ORBIT_TEST_STATUS_FILE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }
                @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
                func status(_ v: String) { try? v.write(toFile: sf, atomically: true, encoding: .utf8) }
                status("idle")
                let id = self.host.runCommand(name: "測試收工", brain: .claude, command: "claude_t() { cat; }; claude_t")
                after(3) {
                    let pid = self.host.pid(id) ?? -1
                    print("wrap: opened pid=\(pid) claude=\(self.host.isClaude(id))"); fflush(stdout)
                    guard let w = self.satWins[id] else { print("wrap: no window"); return }
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: t, location: w.closeLightPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                    }
                    after(1) {
                        print("wrap: sheet=\(self.confirmAlert?.messageText ?? "-") buttons=\(self.confirmAlert?.buttons.map(\.title) ?? [])"); fflush(stdout)
                        self.confirmAlert?.buttons[0].performClick(nil)
                        let noBusy = env["ORBIT_TEST_WRAP_NOBUSY"] != nil
                        if !noBusy { after(1) { status("busy") }; after(4) { status("idle") } }
                        after(noBusy ? 29 : 13) {
                            print("wrap: end win=\(self.satWins[id] != nil) sats=\(self.host.satCount) alive=\(kill(pid, 0) == 0) wrapping=\(self.host.wrapping.contains(id)) problem=\(self.confirmAlert?.informativeText ?? "-")"); fflush(stdout)
                            NSApp.terminate(nil)
                        }
                    }
                }
            } }
        }
        // 測試：模擬拖右下角「縮小→停→放大→停」，每段停下後把終端機內容倒到 <prefix>_1.txt／_2.txt（查調大小錯位）
        // 測試：ORBIT_TEST_FOCUS=<開始秒數> ⇒ 開一顆跑 sleep 的衛星（焦點到終端機），再真的點一下智能體網頁（衛星以外的地方），
        // 印出點之前／之後的 first responder 和「拷貝」有沒有人接（查 ⌘C 複製不了：焦點卡在衛星終端機）
        if let at = env["ORBIT_TEST_FOCUS"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }
                let id = self.host.runCommand(name: "測試衛星", brain: .claude, command: "/bin/sleep 600")
                @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
                @MainActor func report(_ tag: String) {
                    let fr = self.window.firstResponder
                    let copy = NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: nil)
                    print("focus \(tag): fr=\(fr.map { String(describing: type(of: $0)) } ?? "nil") isSphere=\(fr === self.sphereView) copyTarget=\(copy.map { String(describing: type(of: $0)) } ?? "nil")"); fflush(stdout)
                }
                after(4) {
                    report("after-open")
                    guard let root = self.window.contentView, let w = self.satWins[id] else { print("focus: no window"); return }
                    // 點衛星視窗外、左下角附近（智能體網頁）
                    var p = NSPoint(x: 40, y: 40); if w.frame.contains(p) { p = NSPoint(x: root.bounds.maxX - 40, y: 40) }
                    let wp = root.convert(p, to: nil)
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                    }
                    let hit = root.hitTest(p)
                    print("focus hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") key=\(self.window.isKeyWindow) loginHidden=\(self.login.web.isHidden) accepts=\(hit?.acceptsFirstResponder ?? false)"); fflush(stdout)
                    after(1) { report("after-click-sphere"); NSApp.terminate(nil) }
                }
            } }
        }
        // ORBIT_TEST_DRAG="<prefix>@<開始秒數>"
        if let spec = env["ORBIT_TEST_DRAG"], let at = spec.split(separator: "@").last.flatMap({ Double($0) }) {
            let prefix = String(spec.split(separator: "@").first ?? "/tmp/drag")
            func dump(_ n: Int) {
                (frontSat?.content as? WKWebView)?.evaluateJavaScript("window.orbitTest.screen()") { r, _ in
                    try? ((r as? String) ?? "").write(toFile: "\(prefix)_\(n).txt", atomically: true, encoding: .utf8); print("drag dump \(n)"); fflush(stdout)
                }
            }
            func steps(_ k: Int, _ dx: CGFloat, _ dy: CGFloat, then: @escaping () -> Void) {
                guard k > 0 else { then(); return }
                frontSat?.resizeBy(dx: dx, dy: dy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { MainActor.assumeIsolated { steps(k - 1, dx, dy, then: then) } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in MainActor.assumeIsolated {
                guard self != nil else { return }
                dump(0)
                steps(40, -6, 4) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated {
                        dump(1)
                        steps(40, 6, -4) { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { dump(2) } } }
                    } }
                }
            } }
        }
        // 測試：ORBIT_TEST_ARRANGE=<秒數> ⇒ 幾秒後執行「衛星斜對角排開」（跟球體按自動排版一樣）
        if let t = env["ORBIT_TEST_ARRANGE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in MainActor.assumeIsolated { self?.arrangeSats(in: CGRect(x: 340, y: 60, width: 760, height: 640)) } }
        }
        // 測試：ORBIT_TEST_SEQ=1 ⇒ 開 3 個衛星 → 印位置 → 開第 4 個 → 印 → 關掉第 2 個 → 印（查開／關後自動斜對角重排）
        if env["ORBIT_TEST_SEQ"] != nil {
            func dump(_ tag: String) {
                let ws = (self.window.contentView?.subviews ?? []).compactMap { $0 as? TermWindowView }.filter { !$0.isHidden && $0.wantShown }.sorted { $0.seq < $1.seq }
                print("seq \(tag): " + ws.map { "#\($0.seq) \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: " | ")); fflush(stdout)
            }
            var ids: [String] = []
            let run = { (i: Int) -> String in self.host.runCommand(name: "測試 \(i)", brain: .claude, command: "printf '衛星 \(i)\\n'; sleep 60") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { ids = (1...3).map(run) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 11) { MainActor.assumeIsolated { dump("3 個"); ids.append(run(4)) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { MainActor.assumeIsolated { dump("開第 4 個"); self.host.end(ids[1]) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 19) { MainActor.assumeIsolated { dump("關掉第 2 個"); NSApp.terminate(nil) } }
        }
        // 測試：ORBIT_TEST_MULTI="<個數>@<輸出前綴>" ⇒ 開好幾個跑簡單指令的衛星，印出各小視窗位置／疊放順序，
        // 點最底下那個（模擬滑鼠）看它有沒有疊到最上面，再把每個終端機內容倒到 <前綴>_<i>.txt
        if let spec = env["ORBIT_TEST_MULTI"], let at = spec.firstIndex(of: "@"), let n = Int(spec[..<at]) {
            let prefix = String(spec[spec.index(after: at)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }
                let ids = (1...n).map { i in self.host.runCommand(name: "測試 \(i)", brain: .claude, command: "printf '我是衛星 \(i)\\n'; sleep 60") }
                @MainActor func order() -> String { self.window.contentView!.subviews.compactMap { v in ids.firstIndex { self.satWins[$0] === v }.map { "\($0 + 1)" } }.joined(separator: ",") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated {
                    for (i, id) in ids.enumerated() { let w = self.satWins[id]!; print("multi win \(i + 1) frame=\(w.frame) hidden=\(w.isHidden) z=\(w.layer?.zPosition ?? -1)") }
                    print("multi order(bottom→top)=\(order())")
                    let w1 = self.satWins[ids[0]]!
                    let p = self.window.contentView!.convert(NSPoint(x: w1.frame.minX + 10, y: w1.frame.minY + 10), to: nil)
                    if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { self.raiseUnder(e) }
                    print("multi order after click 1=\(order())"); fflush(stdout)
                    var left = n
                    for (i, id) in ids.enumerated() {
                        (self.satWins[id]?.content as? WKWebView)?.evaluateJavaScript("window.orbitTest.screen()") { r, _ in
                            try? ((r as? String) ?? "").write(toFile: "\(prefix)_\(i + 1).txt", atomically: true, encoding: .utf8)
                            left -= 1; if left == 0 { print("multi dumped"); fflush(stdout); if env["ORBIT_TEST_QUIT"] != nil { self.host.shutdown(); NSApp.terminate(nil) } }
                        }
                    }
                } }
            } }
        }
        // 測試：ORBIT_TEST_HIDESATS=1 ⇒ 開一顆衛星（視窗打開），5 秒後數一次開著的衛星視窗；網頁（ORBIT_TEST_SPHERE_JS＋ORBIT_TEST_SPHERE_SHOT，載完 9 秒才跑）模擬點空白處，18 秒時再數一次
        if env["ORBIT_TEST_HIDESATS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }
                let id = self.host.runCommand(name: "收起測試", brain: .claude, command: "printf 'hide test\\n'; sleep 30")
                self.showSat(id)
                let count = { self.satWins.values.filter { !$0.isHidden && $0.wantShown }.count }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { print("hidesats before=\(count())"); fflush(stdout) } }
                // ORBIT_TEST_HIDESATS=toggle ⇒ 不靠網頁，直接連點兩下：收（應為 0）→ 叫回（應為 1）
                if env["ORBIT_TEST_HIDESATS"] == "toggle" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { self.hideAllSats() } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { print("toggle first=\(count())"); fflush(stdout); self.hideAllSats() } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { print("toggle second=\(count())"); fflush(stdout) } }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 16) { MainActor.assumeIsolated {
                    print("hidesats after=\(count())"); fflush(stdout); self.host.shutdown(); NSApp.terminate(nil) } }
            } }
        }
        // 測試：ORBIT_TEST_REMOTE=1 ⇒ 開一顆印字的衛星，4 秒後印出 iPhone App 會拿到的衛星清單與畫面（/api/sats、/api/sat 背後那兩個掛勾）
        if env["ORBIT_TEST_REMOTE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }
                let id = self.host.runCommand(name: "遠端測試", brain: .claude, command: env["ORBIT_TEST_REMOTE_CMD"] ?? "printf 'iPhone 鏡像測試 OK\\n'; sleep 30")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated {
                    print("remote sats=" + String(decoding: SphereEmbed.remoteSats?() ?? Data(), as: UTF8.self))
                    let scr = SphereEmbed.remoteScreen?(id, 0, nil).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    let txt = (scr["data"] as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    print("remote screen total=\(scr["total"] ?? -1) cols=\(scr["cols"] ?? -1) rows=\(scr["rows"] ?? -1) text=\(txt.contains("iPhone 鏡像測試 OK"))")
                    let tail = SphereEmbed.remoteScreen?(id, (scr["total"] as? Int) ?? 0, nil).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    print("remote screen from=end data=\((tail?["data"] as? String)?.count ?? -1)")
                    print("remote sphere=\(SphereEmbed.latestSphere?.count ?? -1) bytes"); fflush(stdout)
                    // 11-24 手機在看時用手機大小：帶 50x40 來拿 ⇒ 回報要變 50x40；7 秒沒來 ⇒ 恢復原本大小
                    let before = scr["cols"].map { "\($0)x\(scr["rows"] ?? -1)" } ?? "?"
                    let ph = SphereEmbed.remoteScreen?(id, 0, (cols: 50, rows: 40)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    print("remote phone before=\(before) phone=\(ph["cols"] ?? -1)x\(ph["rows"] ?? -1)"); fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 7) { MainActor.assumeIsolated {
                        let af = SphereEmbed.remoteScreen?(id, 0, nil).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                        print("remote phone gone=\(af["cols"] ?? -1)x\(af["rows"] ?? -1)"); fflush(stdout)
                        self.host.shutdown(); NSApp.terminate(nil)
                    } }
                } }
            } }
        }
        if let out = env["ORBIT_TEST_LOGIN_SHOT"] {        // 測試：登入畫面截圖（等狀態查完）
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.login.web.takeSnapshot(with: nil) { img, _ in
                    if let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out)); print("login shot saved \(out)"); fflush(stdout)
                    }
                    if env["ORBIT_TEST_QUIT"] != nil { NSApp.terminate(nil) }
                }
            }
        }
    }
}
