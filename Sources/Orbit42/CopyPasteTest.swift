import AppKit
import WebKit
import Orbit42App

// 測試（11-28 Keng「衛星終端機裡面使用複製貼上沒辦法用 ⌘C／⌘V」）：ORBIT_OFFSCREEN=1 ORBIT_TEST_COPYPASTE=1
// ⇒ 開兩顆跑 /bin/cat 的衛星（打的字 tty 會回顯）→ 走「滑過」那條路把輸入點換到 A → 在 xterm 選字
// → 送真的 ⌘C 按鍵事件（走 NSApp.sendEvent → 主選單 → firstResponder，跟手按一樣）→ 剪貼簿要有那段字
// → 剪貼簿放一段字、送 ⌘V → A 的畫面要出現那段字 → 滑到 B 再滑回 A，⌘C／⌘V 再測一次
// 會動到系統剪貼簿：開始前存起來、結束時放回去
extension OrbitWindow {
    func runCopyPasteTest(_ env: [String: String], test: Bool) {
        guard test, env["ORBIT_TEST_COPYPASTE"] != nil else { return }
        @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        let pb = NSPasteboard.general, saved = pb.string(forType: .string)
        var fails = 0
        @MainActor func check(_ name: String, _ ok: Bool, _ got: String) { print("copypaste \(ok ? "PASS" : "FAIL") \(name): \(got)"); fflush(stdout); if !ok { fails += 1 } }
        @MainActor func finish() {
            pb.clearContents(); if let saved { pb.setString(saved, forType: .string) }
            print("copypaste done fails=\(fails)"); fflush(stdout); exit(fails == 0 ? 0 : 1)
        }
        var lastKey = ""
        /// 網頁沒處理的 ⌘ 快捷鍵，WebKit 會用 NSApp.sendEvent 送回主選單；螢幕外的測試 App（.prohibited）不是 key window，那段送不到
        /// ⇒ 這裡照主選單的做法走：找 ⌘<c> 的項目 → 從 firstResponder 沿 responder chain 找接得住的 → 問它給不給按 → 送過去
        let real = env["ORBIT_TEST_COPYPASTE"] == "real"     // real：App 暫時拿前景（視窗還是在螢幕外），按鍵走真的 NSApp.sendEvent（含 WebKit 先給網頁、沒處理再送回主選單那段）
        @MainActor func key(_ c: String, _ code: UInt16) {
            if real {
                for t in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code) { NSApp.sendEvent(e) }
                }
                lastKey = "real ⌘\(c) key=\(window.isKeyWindow) active=\(NSApp.isActive)"; return
            }
            func find(_ m: NSMenu?) -> NSMenuItem? {
                for i in m?.items ?? [] {
                    if i.keyEquivalent == c, i.keyEquivalentModifierMask == .command, i.action != nil { return i }
                    if let s = find(i.submenu) { return s }
                }
                return nil
            }
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code) { routeEditKey(e) }     // 跟真的按鍵一樣先過 keyDown 監聽
            guard let item = find(NSApp.mainMenu), let action = item.action else { lastKey = "主選單沒有 ⌘\(c)"; return }
            var r: NSResponder? = window.firstResponder
            while let x = r, !x.responds(to: action) { r = x.nextResponder }
            guard let target = r else { lastKey = "⌘\(c)→\(NSStringFromSelector(action)) 沒人接"; return }
            let ok = (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
            lastKey = "⌘\(c)→\(NSStringFromSelector(action))→\(type(of: target)) 給按=\(ok)"
            if ok { NSApp.sendAction(action, to: target, from: item) }
        }
        @MainActor func responder() -> String {
            "fr=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") typing=\(typingSat ?? "-") \(lastKey)"
        }
        /// 滑鼠移到這顆露出來的地方（不點），走正常的滑過換聚焦
        @MainActor func hover(_ id: String) {
            guard let w = satWins[id] else { return }
            let others = satWins.filter { $0.key != id && !$0.value.isHidden }.map(\.value.frame)
            var p = NSPoint(x: w.frame.midX, y: w.frame.midY)
            search: for fy in stride(from: 0.1, through: 0.9, by: 0.1) { for fx in stride(from: 0.1, through: 0.9, by: 0.1) {
                let q = NSPoint(x: w.frame.minX + w.frame.width * fx, y: w.frame.minY + w.frame.height * fy)
                if !others.contains(where: { $0.contains(q) }), askFloat?.covers(q) != true { p = q; break search }
            } }
            mouse = p; mouseSpeed = MouseSpeed(); liftStep()
            print("copypaste hover \(id) at \(p) hover=\(hoverSat() ?? "-") paused=\(liftPaused) covers=\(askFloat?.covers(p) ?? false) lifted=\(lift.lifted ?? "-") typing=\(typingSat ?? "-")"); fflush(stdout)
        }
        @MainActor func js(_ id: String, _ s: String, _ done: @escaping @MainActor (String) -> Void) {
            host.view(for: id).evaluateJavaScript(s) { r, e in MainActor.assumeIsolated { done((r as? String) ?? "err \(e.map { "\($0)" } ?? "nil")") } }
        }
        /// 真的滑鼠事件（走 NSApp.sendEvent → 視窗 hitTest → 網頁），座標是主視窗 contentView 座標
        @MainActor func mouseEv(_ t: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) {
            guard let root = window.contentView else { return }
            let wp = root.convert(p, to: nil)
            if let e = NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: t == .leftMouseUp ? 0 : 1) {
                if t == .leftMouseDown { raiseUnder(e) }                 // 跟真的一樣：按下去先過 leftMouseDown 監聽（把那顆提上來）
                if real { NSApp.sendEvent(e) } else { window.sendEvent(e) }       // 螢幕外（不是 key window）：直接交給視窗分派（hitTest → 網頁）
            }
        }
        /// 終端機裡第一行附近：從左拖到右（真的拖曳選字）
        @MainActor func dragSelect(_ id: String, then: @escaping @MainActor () -> Void) {
            for x in satWins.keys { js(x, "window.orbitTest.clearSel()") { _ in } }        // 先清掉舊的選取：沒拖到就不會假過關
            guard let w = satWins[id], let root = window.contentView else { return }
            let c = w.content, y: CGFloat = c.isFlipped ? 12 : c.bounds.height - 12
            let p0 = root.convert(NSPoint(x: 6, y: y), from: c), p1 = root.convert(NSPoint(x: 140, y: y), from: c)
            mouse = p0; liftStep()
            mouseEv(.leftMouseDown, p0)
            var k = 0
            func step() {
                k += 1
                let q = NSPoint(x: p0.x + (p1.x - p0.x) * CGFloat(k) / 8, y: p0.y)
                mouse = q; mouseEv(.leftMouseDragged, q)
                if k < 8 { after(0.03) { step() } } else { after(0.05) { mouseEv(.leftMouseUp, p1); after(0.4) { then() } } }
            }
            after(0.05) { step() }
        }
        /// 真的點一下這個點（球體等）
        @MainActor func click(_ p: NSPoint) { mouse = p; liftStep(); mouseEv(.leftMouseDown, p); mouseEv(.leftMouseUp, p) }
        /// 真的拖曳選字 → ⌘C → 剪貼簿要有選到的字；剪貼簿放字 → ⌘V → 畫面
        @MainActor func dragRound(_ tag: String, _ id: String, word: String, then: @escaping @MainActor () -> Void) {
            dragSelect(id) {
                js(id, "window.orbitTest.selection()") { sel in
                    pb.clearContents(); pb.setString("(還沒拷貝)", forType: .string)
                    key("c", 8)
                    after(1) {
                        let got = pb.string(forType: .string) ?? "nil"
                        check("\(tag) 拖曳選到字", sel.contains("COPY42"), "sel=\(sel.prefix(40).debugDescription)")
                        check("\(tag) ⌘C 拷到剪貼簿", !sel.isEmpty && got == sel, "pb=\(got.prefix(40).debugDescription) \(responder())")
                        pb.clearContents(); pb.setString(word, forType: .string)
                        key("v", 9)
                        after(1.5) {
                            js(id, "window.orbitTest.dom()") { d in print("copypaste dom \(tag): \(d)"); fflush(stdout) }
                            js(id, "window.orbitTest.screen()") { scr in
                                check("\(tag) ⌘V 貼進終端機", scr.contains(word), "\(responder())")
                                then()
                            }
                        }
                    }
                }
            }
        }
        /// 選字 → ⌘C → 剪貼簿；剪貼簿放字 → ⌘V → 畫面
        @MainActor func round(_ tag: String, _ id: String, word: String, then: @escaping @MainActor () -> Void) {
            js(id, "window.orbitTest.select()") { sel in
                pb.clearContents(); pb.setString("(還沒拷貝)", forType: .string)
                key("c", 8)
                after(1) {
                    let got = pb.string(forType: .string) ?? "nil"
                    check("\(tag) ⌘C 拷到剪貼簿", got.contains("COPY42"), "sel=\(sel.prefix(40).debugDescription) pb=\(got.prefix(60).debugDescription) \(responder())")
                    pb.clearContents(); pb.setString(word, forType: .string)
                    key("v", 9)
                    after(1.5) {
                        js(id, "window.orbitTest.dom()") { d in print("copypaste dom \(tag): \(d)"); fflush(stdout) }
                        js(id, "window.orbitTest.screen()") { scr in
                            check("\(tag) ⌘V 貼進終端機", scr.contains(word), "\(responder())")
                            then()
                        }
                    }
                }
            }
        }
        after(3) {
            self.login.web.isHidden = true; self.liftTest = true
            let a = self.host.runCommand(name: "測試 A", brain: .claude, command: "/bin/cat")
            let b = self.host.runCommand(name: "測試 B", brain: .claude, command: "/bin/cat")
            let occ = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            for id in [a, b] { let v = self.host.view(for: id); if v.responds(to: occ) { v.perform(occ, with: nil) } }
            after(4) {
                if real { HiddenTestWindow.allowKey = true; NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps: true); self.window.makeKey() }
                self.window.makeKeyAndOrderFront(nil)
                for id in [a, b] { self.host.type(id, "COPY42-\(id == a ? "A" : "B")\r") }
                hover(a)
                after(1.5) {
                    print("copypaste start \(responder())"); fflush(stdout)
                    round("A", a, word: "PASTE42ONE") {
                        hover(b)
                        after(0.8) {
                            check("滑到 B 輸入點跟著過去", self.typingSat == b, responder())
                            hover(a)
                            after(0.8) {
                                round("滑回 A", a, word: "PASTE42TWO") {
                                    // 情境：點了球體（焦點到球體網頁）→ 滑鼠回到原本就浮著的 A（不點）→ ⌘C／⌘V
                                    self.window.makeFirstResponder(self.sphereView)
                                    hover(a)
                                    after(0.5) {
                                        round("點球體後滑回 A", a, word: "PASTE42THREE") {
                                            // 情境：焦點掉到視窗本身（答案卡收起、面板關掉時會這樣）→ 滑鼠還在 A 上動一下 → ⌘C／⌘V
                                            self.window.makeFirstResponder(nil)
                                            hover(a)
                                            after(0.5) { round("焦點掉到視窗後 A", a, word: "PASTE42FOUR") {
                                                if !real {
                                                    // 情境：焦點在球體、滑鼠早就停在 A 上（沒有「滑進來」那一下）⇒ ⌘C／⌘V 要交給滑鼠底下的 A
                                                    self.window.makeFirstResponder(self.sphereView)
                                                    if let w = self.satWins[a] { self.mouse = NSPoint(x: w.frame.minX + 20, y: w.frame.maxY - 60) }
                                                    after(0.3) { round("焦點在球體、滑鼠停在 A 上 ⇒ A", a, word: "PASTE42KEY") {
                                                        self.window.makeFirstResponder(nil); self.mouse = nil
                                                        after(0.3) { round("焦點掉回視窗、沒滑過 ⇒ 浮著的 A", a, word: "PASTE42KEY2") {
                                                            // 焦點在 B 的終端機、滑鼠在 A 上：⌘V 照焦點貼進 B（不搶）
                                                            self.window.makeFirstResponder(self.satWins[b]!.content)
                                                            pb.clearContents(); pb.setString("PASTE42STAYB", forType: .string); key("v", 9)
                                                            after(1.2) { js(b, "window.orbitTest.screen()") { scr in check("焦點在 B ⇒ ⌘V 貼進 B 不搶", scr.contains("PASTE42STAYB"), responder())
                                                                // 點進去拖選的情境只在 real 模式跑：螢幕外的非 key 視窗，WebKit 不處理合成的滑鼠事件（11-28 實測：點了焦點不換、之後連 paste 都進不了網頁）
                                                                finish()
                                                            } }
                                                        } }
                                                    } }
                                                    return
                                                }
                                                // 情境：真的點球體 → 真的點進 A 拖曳選字 → ⌘C／⌘V（Keng 手動的做法）
                                                guard let root = self.window.contentView else { return finish() }
                                                var sp = NSPoint(x: 30, y: 30)
                                                for q in [NSPoint(x: 30, y: 30), NSPoint(x: root.bounds.maxX - 30, y: 30), NSPoint(x: 30, y: root.bounds.maxY - 80), NSPoint(x: root.bounds.maxX - 30, y: root.bounds.maxY - 80)]
                                                    where !self.satWins.values.contains(where: { !$0.isHidden && $0.frame.contains(q) }) && self.askFloat?.covers(q) != true { sp = q; break }
                                                click(sp)
                                                after(0.5) {
                                                    print("copypaste after sphere click \(responder())"); fflush(stdout)
                                                    dragRound("點球體後點進 A 拖選", a, word: "PASTE42FIVE") {
                                                        dragRound("再拖選一次 A", a, word: "PASTE42SIX") {
                                                            hover(b)
                                                            after(0.5) { dragRound("點進 B 拖選", b, word: "PASTE42SEVEN") { finish() } }
                                                        }
                                                    }
                                                }
                                            } }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        after(70) { print("copypaste timeout"); fails += 1; finish() }
    }
}
