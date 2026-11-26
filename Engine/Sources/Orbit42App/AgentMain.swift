import AppKit
import Orbit42Core

// 11-23：Orbit42Agent 拆成函式庫（Orbit42App），原本 main.swift 的內容整段搬進來當 run()，行為不變；
// Orbit42Agent 執行檔和 Orbit42 都呼叫這裡（Orbit42 取代 Orbit42Agent，見 docs/PLAN-SPHERE-OS.md）
public enum EngineMain {
    @MainActor public static func run(_ options: AgentOptions = AgentOptions()) {

let argv = CommandLine.arguments

// Internal: exit 0 if this binary is trusted for Accessibility (used by the permission wait loop)
if argv.count == 2, argv[1] == "--ax-check" { exit(AXIsProcessTrusted() ? 0 : 1) }

// Debug: Orbit42Agent --arrange-dry   → prints the frames it WOULD apply (moves nothing)
if argv.count == 2, argv[1] == "--arrange-dry" {
    MainActor.assumeIsolated {
        let a = Arranger.shared
        let p = a.plan()
        print("screens", a.screenAreasAX(), "windows", p.count)
        for (t, f) in p { print(t.app, AXQuery.wid(t.el), "now", t.frame, "→", f) }
        exit(0)
    }
}
// Test: Orbit42Agent --arrange-once [columns|grid]  → arrange current Space once, print "wid x y w h" planned, exit
if argv.count >= 2, argv[1] == "--arrange-once" {
    MainActor.assumeIsolated {
        let a = Arranger.shared
        if argv.count == 3, let s = LayoutPlan.FourStyle(rawValue: argv[2]) { a.fourStyle = s }
        guard Arranger.onlyWIDs != nil else {       // the test entry point never runs without a whitelist
            FileHandle.standardError.write(Data("--arrange-once requires ORBIT_ONLY_WIDS\n".utf8)); exit(3)
        }
        let p = a.plan()
        guard a.arrange(p) else { exit(4) }
        for (t, f) in p { print(AXQuery.wid(t.el), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)) }
        exit(0)
    }
}

// Test: Orbit42Agent --arrange-watch  → arrange (whitelist required), then keep restacking on focus changes
if argv.count >= 2, argv[1] == "--arrange-watch" {
    MainActor.assumeIsolated {
        guard Arranger.onlyWIDs != nil else { FileHandle.standardError.write(Data("--arrange-watch requires ORBIT_ONLY_WIDS\n".utf8)); exit(3) }
        let a = Arranger.shared
        let p = a.plan()
        guard a.arrange(p) else { exit(4) }
        for (t, f) in p { print(AXQuery.wid(t.el), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)) }
        fflush(stdout)
        a.watchFocus()
        NotificationCenter.default.addObserver(forName: Notification.Name("sw42.focus"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { a.focusChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { a.focusChanged() }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}

// Debug: Orbit42Agent --resolve /dev/ttysNNN   → "<app> <pid> <wid> <tabTTY>" per placement
if argv.count == 3, argv[1] == "--resolve" {
    MainActor.assumeIsolated {
        let r = Resolver().placements(for: argv[2])
        if r.isEmpty { print("none"); exit(1) }
        for p in r { print(p.app, p.pid, p.wid, p.tabTTY) }
        exit(0)
    }
}

// Test/debug: Orbit42Agent --board-dump  → Orbit42看板目前的卡片（JSON），不開視窗
if argv.count == 2, argv[1] == "--board-dump" {
    let s = BoardReader().read()
    let fm = FileManager.default
    let cards = Board.build(sessions: s.sessions, transcripts: s.transcripts, glows: s.glows, teams: s.teams, inbox: s.inbox,
                            reports: s.reports, reviews: s.reviews, decisions: s.decisions, contexts: s.contexts, nicknames: s.nicknames, asks: s.asks,
                            now: Date(), home: BoardPaths.home, isRepo: { fm.fileExists(atPath: $0 + "/.git") })
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try! e.encode(cards)); print()
    exit(0)
}

// Test: Orbit42Agent --guard-scan [--real]  → 跟「立即掃描」同一條路（GuardScanner、同時只跑一個），印結束碼。
//       沒設 ORBIT_WIFIWATCH_SCRIPT（假腳本）又沒帶 --real 就不跑：測試不准真的掃網路（10-20）
if argv.count >= 2, argv[1] == "--guard-scan" {
    guard ProcessInfo.processInfo.environment["ORBIT_WIFIWATCH_SCRIPT"] != nil || argv.dropFirst(2).contains("--real") else {
        print("拒絕：要真的掃描請加 --real；測試請設 ORBIT_WIFIWATCH_SCRIPT 指向假腳本"); exit(2)
    }
    let sc = BoardActions.guardScanner
    let sem = DispatchSemaphore(value: 0)
    let first = sc.scan { code in print("scan done code=\(code) script=\(sc.script)"); fflush(stdout); sem.signal() }
    let second = sc.scan()                                  // 同時只跑一個：第二次應該被擋
    print("first=\(first) second=\(second) running=\(sc.isRunning)")
    sem.wait()
    print("running after=\(sc.isRunning)")
    exit(0)
}

// Test: Orbit42Agent --work-snap <sessions 資料夾> <sid> <輸出.png>  → 工作視窗（11-08 H3）讀那個資料夾的 <sid>.jsonl，
//       開在螢幕外、不搶焦點，等 3 秒截網頁、印訊息數與狀態後結束。不啟動 claude、不動正式的 board/sessions
if argv.count == 5, argv[1] == "--work-snap" {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        SessionHost.shared.dir = URL(fileURLWithPath: argv[2], isDirectory: true)
        WorkWindow.testMode = true
        let env = ProcessInfo.processInfo.environment
        guard let w = WorkWindow.show(argv[3], cwd: env["ORBIT_WORK_CWD"]) else { print("找不到 work.html"); exit(2) }
        // ORBIT_WORK_JS：1.5 秒後在網頁裡跑（模擬按鈕、送話；搭配 ORBIT_CLAUDE_BIN 指向假 claude）
        if let js = env["ORBIT_WORK_JS"] { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { w.runJS(js) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + (env["ORBIT_WORK_JS"] == nil ? 3 : 5)) {
            w.snapshot { img, info in
                print("work-snap:", info); fflush(stdout)
                guard let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { print("截圖失敗"); exit(1) }
                try? png.write(to: URL(fileURLWithPath: argv[4]))
                exit(0)
            }
        }
    }
    NSApplication.shared.run()
}

// Test: Orbit42Agent --work-e2e <資料夾> <輸出資料夾>  → 真 claude（haiku）端對端：在 <資料夾> 開一個Orbit42持有的 session，
//       工作視窗開在螢幕外，照順序在網頁裡打字送出／按按鈕：跑指令、寫檔（權限卡按允許）、寫檔（按拒絕）、中斷、/compact。
//       每步截圖存到 <輸出資料夾>，印每步結果。session 紀錄寫在 <輸出資料夾>（不動正式的 board/sessions）；權限請求走正式的收件匣（會短暫出現）。用到 haiku 額度
if argv.count == 4, argv[1] == "--work-e2e" {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let cwd = argv[2], out = URL(fileURLWithPath: argv[3], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        SessionHost.shared.dir = out
        WorkWindow.testMode = true
        let s: OwnedSession
        do { s = try SessionHost.shared.start(cwd: cwd, model: "haiku", permissionMode: "default") } catch { print("開不起來：\(error)"); exit(2) }
        let sid = s.sessionId
        guard let w = WorkWindow.show(sid, cwd: cwd) else { print("找不到 work.html"); exit(2) }
        func log() -> String { (try? String(contentsOf: SessionHost.shared.logFile(sid), encoding: .utf8)) ?? "" }
        func idle() -> Bool { (SessionHost.shared.session(sid)?.state ?? .idle) == .idle }
        func results() -> Int { log().components(separatedBy: "\"type\":\"result\"").count - 1 }
        let fm = FileManager.default
        typealias Step = (name: String, js: String, wait: () -> Bool, check: () -> String)
        let type = { (t: String) -> String in "document.querySelector('#input').value=\(String(reflecting: t));document.querySelector('#send').click();" }
        var base = 0
        let steps: [Step] = [
            ("跑指令", type("用 Bash 執行 echo hello-e2e，然後只回我輸出的那一行。"), { results() > base && idle() }, { log().contains("hello-e2e") ? "OK：看到指令與輸出" : "沒看到 hello-e2e" }),
            ("寫檔→允許", type("用 Write 工具建立檔案 allow.txt，內容是 yes。不要用 Bash。"), { results() > base && idle() }, { fm.fileExists(atPath: cwd + "/allow.txt") ? "OK：allow.txt 建好了" : "allow.txt 沒建" }),
            ("寫檔→拒絕", type("用 Write 工具建立檔案 deny.txt，內容是 no。不要用 Bash，被拒絕就停。"), { results() > base && idle() }, { fm.fileExists(atPath: cwd + "/deny.txt") ? "deny.txt 竟然建了" : "OK：deny.txt 沒建" }),
            ("中斷", type("從 1 數到 400，每個數字一行，不要省略。") + "setTimeout(()=>document.querySelector('#interrupt').click(),2500);", { results() > base && idle() },
             { log().contains("error_during_execution") ? "OK：回合被中斷" : "沒看到中斷" }),
            ("/compact", type("/compact"), { log().contains("compact_boundary") && idle() }, { log().contains("compact_boundary") ? "OK：對話已壓縮" : "沒看到 compact_boundary" }),
        ]
        var i = 0, t0 = Date(), answered = Set<String>()
        @MainActor func snap(_ name: String, then: @escaping @MainActor () -> Void) {
            w.snapshot { img, info in
                if let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: out.appendingPathComponent("step\(i + 1)-\(name.replacingOccurrences(of: "/", with: "")).png"))
                }
                print("  畫面：", info); fflush(stdout); MainActor.assumeIsolated { then() }
            }
        }
        @MainActor func next() {
            guard i < steps.count else { s.close(); print("work-e2e：全部跑完"); fflush(stdout); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }; return }
            base = results(); t0 = Date()
            print("步驟 \(i + 1)：\(steps[i].name)"); fflush(stdout)
            w.runJS(steps[i].js)
            poll()
        }
        @MainActor func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
                let st = steps[i]
                // 權限卡出現：寫 deny.txt 的按「拒絕」，其他（含 AI 自己發Orbit42卡片的指令）一律「允許」
                if let req = Permit.pending()[SessionHost.shared.liveId(sid)], !answered.contains(req.id) {
                    answered.insert(req.id)
                    let want = req.summary.contains("deny.txt") ? "拒絕" : "允許"
                    print("  權限卡：\(req.tool) \(req.summary.prefix(60)) → 按「\(want)」"); fflush(stdout)
                    snap(st.name + "-權限卡\(answered.count)") {
                        w.runJS("[...document.querySelectorAll('#permit button')].find(b=>b.textContent.trim()===\(String(reflecting: want)))?.click()")
                        poll()
                    }
                    return
                }
                if st.wait() || Date().timeIntervalSince(t0) > 180 {
                    print("  結果：", st.wait() ? st.check() : "逾時（" + st.check() + "）"); fflush(stdout)
                    snap(st.name) { i += 1; next() }
                    return
                }
                poll()
            } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { next() } }
    }
    NSApplication.shared.run()
}

// Orbit42 測試：只開 Orbit42 視窗（螢幕外、不開 socket、不跟正在跑的 Orbit42Agent 搶），
if options.testOnly {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppTest.mode = true
        EditMenu.install()
        options.onLaunch?()
    }
    NSApplication.shared.run()
    return
}

// Test: Orbit42Agent --board-act <approve|park|sendback|review> <sessionId> [文字]
//       Orbit42Agent --board-act answer <sessionId> <文字>   3D 辦公室直接回答（tmux→直送→拷貝）
//       Orbit42Agent --board-act newtask <資料夾> <提示>      e2e 驗收用，跟按鈕走同一條路
//       Orbit42Agent --board-act captain <文字>              交給秘書（秘書不在就開背景秘書），跟收件匣同一條路
if argv.count >= 4, argv[1] == "--board-act", argv[2] == "captain" {
    print(BoardActions.askCaptain(argv[3]))
    exit(0)
}
if argv.count >= 3, argv[1] == "--board-act" {
    MainActor.assumeIsolated {
        if argv[2] == "newtask", argv.count >= 5 {
            switch BoardActions.newTask(folder: argv[3], prompt: argv[4], fullAuto: false) {
            case .success(let id): print("bg", id); exit(0)
            case .failure(let e): print("error", e.message); exit(1)
            }
        }
        let s = BoardReader().read()
        let fm = FileManager.default
        let cards = Board.build(sessions: s.sessions, transcripts: s.transcripts, glows: s.glows, teams: s.teams, inbox: s.inbox,
                                reports: s.reports, reviews: s.reviews, decisions: s.decisions, contexts: s.contexts, nicknames: s.nicknames, asks: s.asks,
                                now: Date(), home: BoardPaths.home, isRepo: { fm.fileExists(atPath: $0 + "/.git") })
        guard argv.count >= 4, let c = cards.first(where: { $0.id == argv[3] }) else { print("no such card"); exit(1) }
        let text = argv.count >= 5 ? argv[4] : ""
        switch argv[2] {
        case "approve": BoardActions.approve(c); print("ok"); exit(0)
        case "wrapup": print(BoardActions.wrapUp(c)); exit(0)
        case "answer":          // 有題目就跟介面同一把鎖（只送一次），不打字
            print(c.asks.first.map { q in BoardActions.answer(c, pick: AnswerPick(askId: q.id, text: text, options: q.options ?? Inbox.genericOptions), source: .other) { _ in } } ?? BoardActions.answer(c, text: text, speaker: .none)); exit(0)
        case "park": BoardActions.park(c, note: text); print("ok"); exit(0)
        case "sendback":
            switch BoardActions.sendBack(c, text: text) { case .typed: print("typed"); case .copied(let m): print("copied", m) }
            exit(0)
        case "review":
            Reviewer.shared.start(c, force: true)
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { if !Reviewer.shared.isRunning(c.sessionId) { print("reviewed"); exit(0) } }
            }
            NSApplication.shared.run()
        default: print("unknown action"); exit(1)
        }
    }
}

// 不認得的 --參數 一律結束，不要當成正式 agent 跑起來（10-08：舊版不認得 --board-dump，
// 結果多開一個 agent 把正式 agent 的 socket 搶走）
if argv.count >= 2, argv[1].hasPrefix("--") {
    FileHandle.standardError.write(Data("Orbit42Agent: unknown option \(argv[1])\n".utf8)); exit(2)
}

// Accessibility is required (window frames, focus, key/click monitor). Under launchd, exiting here
// would respawn-loop, so ask ONCE (system prompt) and then wait quietly until it is granted.
if !options.waitForAccessibility && !AXIsProcessTrusted() {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)   // Orbit42：問一次就繼續（排窗、光暈這些要輔助使用的功能先不動）
} else if !AXIsProcessTrusted() {
    FileHandle.standardError.write(Data("Orbit42Agent: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility → Orbit42Agent)\n".utf8))
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    // AXIsProcessTrusted() can keep answering false inside this process even after the user flips the
    // switch (seen 09-26). Ask TCC fresh through a short-lived child instead, then re-exec ourselves.
    while true {
        Thread.sleep(forTimeInterval: 2)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--ax-check"]
        do { try p.run() } catch { continue }             // 開不起來：2 秒後再試，不當成已經允許
        p.waitUntilExit()
        if p.terminationStatus == 0 { break }
    }
    FileHandle.standardError.write(Data("Orbit42Agent: Accessibility granted — restarting to pick it up\n".utf8))
    let args = CommandLine.arguments.map { strdup($0) } + [nil]
    execv(CommandLine.arguments[0], args)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(options.regularApp ? .regular : .accessory)   // Orbit42Agent: no Dock icon; Orbit42: a normal app
    EditMenu.install()                                        // 聽寫（按兩下 Control）、⌘C／⌘V 的快捷鍵要掛在編輯選單上（EditMenu.swift）
    let engine = Engine()
    engine.start()
    let titles = TitleWatcher(engine: engine)
    titles.start()
    Menu.shared.install()
    // lets tests / scripts open the settings panel without driving the menu (09-26: a blind Return in
    // the status menu hit「結束 Orbit42」)
    DistributedNotificationCenter.default().addObserver(forName: Notification.Name("ai.okle42.orbit42.showSettings"),
                                                        object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { SettingsPanel.shared.show() }
    }
    Arranger.shared.start()
    JobStore.appWrites = true
    BoardModel.shared.start()          // 背景功能（巡檢、自動收尾、交接 /clear、派工回報、答案卡送回、審核）：11-26 拿掉看板視窗後由這裡獨自啟動
    SphereWatch.shared.start()         // 球體 v4：今日時間軸紀錄＋需要你提醒（SphereWatch.swift）
    SphereMini.shared.restore()        // 桌面常駐小球：上次開著就照樣開（球體 v3 #7）
    BgJanitorRunner.shared.start()     // 11-22：空轉的背景 session（沒接過工作、閒置 10 分鐘）自動 claude stop（BgJanitorRunner.swift）
    WebServer.shared.start()           // Orbit42 網頁版：預設關，orbit web enable 才開、只綁 Tailscale IP（WebServer.swift）
    let server = Server { m in DispatchQueue.main.async { MainActor.assumeIsolated { engine.handle(m) } } }
    do { try server.start() } catch {
        FileHandle.standardError.write(Data("Orbit42Agent: cannot open socket at \(Paths.socket.path): \(error)\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("Orbit42Agent listening on \(Paths.socket.path)\n".utf8))
    if let launch = options.onLaunch { DispatchQueue.main.async { MainActor.assumeIsolated { launch() } } }   // Orbit42 開自己的主視窗
    withExtendedLifetime((server, titles)) { app.run() }
}

    }
}
