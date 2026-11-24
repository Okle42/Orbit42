import AppKit
import WebKit
import ShoWorkApp
import ShoWorkCore

// Orbit42: the sphere is the home screen; every AI worker is a satellite with its own real terminal.
// Web UI (Web/index.html: three.js sphere + xterm.js) talks to this host through `webkit.messageHandlers.orbit`.
//
// Test hooks (window off-screen, never on the user's display):
//   ORBIT_OFFSCREEN=1  ORBIT_TEST_JS=<js run 1.5 s after load>  ORBIT_TEST_SHOT=<png> ORBIT_TEST_SHOT_DELAY=<s>  ORBIT_TEST_QUIT=1

@MainActor
final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    // 11-23 Keng「衛星終端機只能開一個視窗，要能開多個、重疊、移動」：
    // 每顆衛星自己一個網頁視圖（index.html?term=1&sat=<id>），各自裝在自己的小視窗裡
    private(set) var views: [String: DropWebView] = [:]
    private let files: WebFiles? = Host.webDir.map { WebFiles(root: $0) }
    private var sats: [String: Satellite] = [:]
    private var order: [String] = []
    private var counter: [Brain: Int] = [:]
    private var pending: [String: Data] = [:]
    private let pendLock = NSLock()
    private var flushTimer: Timer?
    private var tick: Timer?
    var theme = "dark"
    var onOpen: (String) -> Void = { _ in }          // 打開這顆衛星的小視窗（已經開著就叫到最上面）
    var onHide: (String) -> Void = { _ in }          // 收起這顆衛星的小視窗
    var onRemoved: (String) -> Void = { _ in }       // 衛星結束：關掉它的小視窗
    var onBusy: (String, Bool) -> Void = { _, _ in } // 衛星有沒有在工作（小視窗呼吸光）
    private var testView: WKWebView?                 // 測試 hooks 只作用在第一個打開的衛星

    /// 拖檔案進來：路徑打進那顆衛星（跟手打一樣）
    func type(_ id: String, _ text: String) {
        guard let d = text.data(using: .utf8) else { return }
        input(id, d)
    }
    /// 使用者（或拖檔、手機）送進這顆衛星的位元組；答案卡正在打字的那一下先扣住，打完再補，不會混在一起
    private var held: [String: Data] = [:], lastKey: [String: Date] = [:]
    @discardableResult
    private func input(_ id: String, _ d: Data) -> Bool {
        guard let p = sats[id]?.pty else { return false }
        // 滑鼠移動、焦點、終端機自動回覆不算按鍵
        let s = String(decoding: d.prefix(4), as: UTF8.self)
        if !["\u{1B}[<", "\u{1B}[I", "\u{1B}[O", "\u{1B}[?", "\u{1B}[>", "\u{1B}]", "\u{1B}P"].contains(where: { s.hasPrefix($0) }) { lastKey[id] = Date() }
        if held[id] != nil { held[id]!.append(d) } else { p.write(d) }
        return true
    }
    /// 答案卡打進終端機（TermAnswer）。剛好一顆衛星現在就是這個 session 才做
    func typeAnswer(_ sid: String, _ text: String, still: @escaping @MainActor () -> Bool, done: @escaping @MainActor (TermAnswer.Outcome) -> Void) -> Bool {
        let hits = sats.values.filter { $0.exited == nil && $0.pty != nil && $0.brain == .claude && views[$0.id] != nil && sessionRecord($0)?.sessionId == sid }
        guard hits.count == 1, let s = hits.first, let pty = s.pty, let v = views[s.id], held[s.id] == nil else { return false }
        let id = s.id, start = Self.transcripts(sid)
        held[id] = Data()
        var wrote = false
        let name = sessionRecord(s)?.name ?? ""
        let io = TermAnswer.IO(
            target: { [weak self] in
                guard let self, let r = self.sessionRecord(s), s.pty === pty else { return nil }
                let n = NicknameStore.liveSessions().filter { $0.name == r.name }.count
                return TermAnswer.Target(sid: r.sessionId, name: r.name ?? "", idle: r.status == "idle", unique: n == 1 && r.name?.isEmpty == false)
            },
            screen: {
                guard let j = try? await v.evaluateJavaScript("window.orbitScreen ? window.orbitScreen(\"\(id)\") : null") as? String else { return nil }
                return try? JSONDecoder().decode(TermAnswer.Screen.self, from: Data(j.utf8))
            },
            mark: { still() && TypedMark.put(sid: sid, text: text) },
            write: { wrote = true; pty.write($0) },
            typing: { [weak self] in self?.lastKey[id].map { Date().timeIntervalSince($0) < 5 } ?? false },
            added: {
                guard !start.isEmpty else { return nil }
                var out = Data()
                for (f, n) in Self.transcripts(sid) where n > (start[f] ?? 0) {
                    guard let h = FileHandle(forReadingAtPath: f) else { continue }
                    try? h.seek(toOffset: start[f] ?? 0); out.append(h.readDataToEndOfFile()); out.append(0x0A); try? h.close()
                }
                return out
            },
            wait: { try? await Task.sleep(for: .seconds($0)) })
        Task { @MainActor in
            let out = await TermAnswer.send(text, to: sid, io: io)
            var safe = !wrote           // 一個字都沒寫＝跟平常一樣，原樣補回
            if wrote, let now = await io.screen() { safe = TermAnswer.plain(now, name: name) }
            let (r, rest) = TermAnswer.settle(out, held: self.held[id] ?? Data(), safe: safe)
            self.held[id] = nil
            if !rest.isEmpty { pty.write(rest) }
            print("answer \(id) → \(r)"); fflush(stdout)
            done(r)
        }
        return true
    }
    /// 這個 session 的對話紀錄檔 → 現在多大
    private static func transcripts(_ sid: String) -> [String: UInt64] {
        let fm = FileManager.default, root = NSHomeDirectory() + "/.claude/projects"
        var out: [String: UInt64] = [:]
        for d in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let f = "\(root)/\(d)/\(sid).jsonl"
            if let n = (try? fm.attributesOfItem(atPath: f)[.size]) as? NSNumber { out[f] = n.uint64Value }
        }
        return out
    }
    /// 11-23 Keng「叉叉關閉連背景 session 都要能被我關掉」⇒ 拉進來看的背景 session 也用官方 `claude stop <job>` 停掉（對話保留，之後可以 claude attach 接回來）
    func end(_ id: String) {
        guard let s = sats[id] else { onRemoved(id); return }
        wrapping.remove(id)
        s.pty?.hangup(); sats[id] = nil; order.removeAll { $0 == id }; views[id] = nil
        if let job = s.attachedJob { closedJobs[job] = Date(); Self.stopBackground(job) }
        onRemoved(id); pushSats()
    }
    /// 背景跑，不卡畫面；結果印在 log（ORBIT_TEST_STOP_CMD／ORBIT_TEST_RM_CMD 測試時換掉指令，不碰真的 session）
    /// 11-24 Keng「叉叉就是要真正關閉這個 session」（06:06 錄影：關掉後戰情列表還留著「Claude 1 · 待命」，一點又被叫醒）
    /// ⇒ 停掉之後再 `claude rm`：從背景 session 清單拿掉，之後點不回來（對話紀錄照樣留著，claude --resume 找得到）
    nonisolated static func stopBackground(_ job: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let env = ProcessInfo.processInfo.environment
        let stop = env["ORBIT_TEST_STOP_CMD"] ?? "claude stop", rm = env["ORBIT_TEST_RM_CMD"] ?? "claude rm"
        p.arguments = ["-l", "-c", "\(stop) \"$1\"; s=$?; \(rm) \"$1\"; echo \"stop=$s rm=$?\"", "orbit-stop", job]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        p.terminationHandler = { _ in
            let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            print("stop background \(job): \(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))"); fflush(stdout)
        }
        do { try p.run() } catch { print("stop background \(job) failed: \(error)"); fflush(stdout) }
    }

    // MARK: 11-24 Keng「按叉叉＝收工：先確認要不要 commit＋push，不用就進入 clear，然後真正關閉；中間灰鈕才是收起」
    /// 剛關掉的背景 job：戰情列表最多 10 秒才更新，這段時間點到那一列不要又 attach 把它叫醒
    private var closedJobs: [String: Date] = [:]
    func recentlyClosed(_ job: String) -> Bool { closedJobs[job].map { Date().timeIntervalSince($0) < 90 } ?? false }
    /// 正在收工（等它 commit＋push）的衛星
    private(set) var wrapping: Set<String> = []
    /// 裡面跑的是 Claude（自己開的或拉進來看的背景 session），才有 commit＋push／clear 這套收工
    func isClaude(_ id: String) -> Bool { guard let s = sats[id] else { return false }; return s.brain == .claude && s.command.hasPrefix("claude") }
    static let wrapUpPrompt = "收工（Orbit42 叉叉關閉）：把這個 session 改過、還沒 commit 的東西 commit，有遠端就 push（照收工規矩：先掃客戶關鍵字，技術性禁推的 repo 只 commit 不推）。沒有東西要收就回「沒有要收的」。不要問我問題；真的卡住就回一行「收工卡住：原因」。做完 Orbit42 會自動 /clear 並關掉這個 session。"

    /// 收工：commit＝true 先打收工指令、等它做完（忙→閒），再 /clear → 停掉並從清單拿掉；commit＝false 直接 /clear → 關閉
    /// 有狀況（指令沒送出去、它說收工卡住）就不關，回呼 onProblem 讓使用者決定
    func wrapUp(_ id: String, commit: Bool, onProblem: @escaping @MainActor (String) -> Void) {
        guard let s = sats[id], s.pty != nil, s.exited == nil, isClaude(id) else { end(id); return }
        wrapping.insert(id)
        guard commit else { clearThenEnd(id); return }
        onOpen(id)                                     // 讓你看得到它在收工
        submit(id, Self.wrapUpPrompt)
        let t0 = Date()
        var seenBusy = false, lastBusy = Date.distantPast
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in MainActor.assumeIsolated {
                guard let self, let s = self.sats[id], self.wrapping.contains(id) else { return }
                if s.exited != nil { self.end(id); return }
                let rec = self.sessionRecord(s), st = self.testStatus ?? rec?.status
                if st == "busy" { seenBusy = true; lastBusy = Date() }
                if seenBusy, st != "busy", Date().timeIntervalSince(lastBusy) >= 3 {
                    // 看它最後一句回覆（對話紀錄，不看終端機畫面：畫面上也有收工指令本身，裡面就有「收工卡住」四個字）
                    if Self.lastReply(rec?.sessionId).contains("收工卡住") {
                        self.wrapping.remove(id); onProblem("它說收工卡住了，視窗先留著，看一下它寫的原因。")
                    } else { self.clearThenEnd(id) }
                    return
                }
                if !seenBusy, Date().timeIntervalSince(t0) > 25 {
                    self.wrapping.remove(id); onProblem("收工指令好像沒送進去（25 秒都沒開始做），視窗先留著。")
                    return
                }
                tick()
            } }
        }
        tick()
    }
    /// 打一行字再按 Enter（分兩次送：一次送整串會被當成貼上，Enter 要另外按）
    private func submit(_ id: String, _ text: String) {
        type(id, text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in MainActor.assumeIsolated { self?.type(id, "\r") } }
    }
    private func clearThenEnd(_ id: String) {
        print("wrap-up \(id): /clear → end"); fflush(stdout)
        submit(id, "/clear")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated { self?.end(id) } }
    }
    /// 這顆衛星裡 Claude 的狀態（~/.claude/sessions/<pid>.json 的 busy／idle）；背景 session 用 job 對，自己開的用程序對
    /// 測試：ORBIT_TEST_STATUS_FILE＝檔案路徑，內容就是狀態
    private var testStatus: String? {
        ProcessInfo.processInfo.environment["ORBIT_TEST_STATUS_FILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var sidCache: [String: (String, Date)] = [:]
    /// 這顆衛星的 Claude session id（球上的行星用它認）；讀檔要時間 ⇒ 記 20 秒
    func sessionId(_ id: String) -> String? {
        if let t = ProcessInfo.processInfo.environment["ORBIT_TEST_SID"] { return t }
        if let c = sidCache[id], Date().timeIntervalSince(c.1) < 20 { return c.0 }
        guard let s = sats[id], let r = sessionRecord(s) else { return nil }
        sidCache[id] = (r.sessionId, Date()); return r.sessionId
    }
    private func sessionRecord(_ s: Satellite) -> SessionRecord? {
        let fm = FileManager.default, dir = NSHomeDirectory() + "/.claude/sessions", pid = s.pty?.pid
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".json") {
            guard let d = fm.contents(atPath: dir + "/" + f), let r = SessionRecord.decode(d), kill(r.pid, 0) == 0 else { continue }
            if let j = s.attachedJob { if r.jobId == j { return r } }
            else if let pid, r.pid == pid || Self.parent(of: r.pid) == pid { return r }
        }
        return nil
    }
    /// 這個 session 最後一句文字回覆（~/.claude/projects/*/<sid>.jsonl；session 換目錄做事時紀錄會跟著搬 ⇒ 找最新的那份）
    /// 測試：ORBIT_TEST_LAST_REPLY＝直接當成回覆
    nonisolated static func lastReply(_ sid: String?) -> String {
        if let t = ProcessInfo.processInfo.environment["ORBIT_TEST_LAST_REPLY"] { return t }
        guard let sid else { return "" }
        let fm = FileManager.default, root = NSHomeDirectory() + "/.claude/projects"
        let files = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).map { "\(root)/\($0)/\(sid).jsonl" }.filter { fm.fileExists(atPath: $0) }
        guard let f = files.max(by: { ((try? fm.attributesOfItem(atPath: $0)[.modificationDate]) as? Date ?? .distantPast) < ((try? fm.attributesOfItem(atPath: $1)[.modificationDate]) as? Date ?? .distantPast) }),
              let h = FileHandle(forReadingAtPath: f) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"type\":\"assistant\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let t = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if !t.isEmpty { return t }
        }
        return ""
    }
    func attachForTest(job: String) {
        userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "attach", "job": job, "name": "測試背景", "cwd": NSHomeDirectory()]))
    }
    func name(_ id: String) -> String { sats[id]?.name ?? id }
    /// 這個背景工作（job 編號）是哪一顆衛星
    func sat(job: String) -> String? { job.count < 6 ? nil : sats.values.first { $0.attachedJob.map { $0.hasPrefix(job) || job.hasPrefix($0) } ?? false }?.id }
    func has(_ id: String) -> Bool { sats[id] != nil }
    func isAttached(_ id: String) -> Bool { sats[id]?.attachedJob != nil }
    var satCount: Int { sats.count }
    func pid(_ id: String) -> Int32? { sats[id]?.pty?.pid }
    func title(_ id: String) -> String {
        guard let s = sats[id] else { return id }
        return "\(s.name) · \(s.brain.label)\(s.attachedJob != nil ? " · 背景 session" : "")"
    }

    /// 這顆衛星的終端機網頁（第一次要才建）
    func view(for id: String) -> DropWebView {
        if let v = views[id] { return v }
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // ES modules don't load from file:// in WKWebView ⇒ serve Web/ through our own scheme
        if let files { cfg.setURLSchemeHandler(files, forURLScheme: "orbit") }
        cfg.userContentController.add(WeakHandler(self), name: "orbit")
        let v = DropWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = self
        v.setValue(false, forKey: "drawsBackground")
        var u = URLComponents(string: "orbit://app/index.html")!
        u.queryItems = [URLQueryItem(name: "term", value: "1"), URLQueryItem(name: "sat", value: id), URLQueryItem(name: "theme", value: theme)]
        v.load(URLRequest(url: u.url!))
        views[id] = v
        return v
    }

    /// 11-23 iPhone App（經 ShoWork 網頁伺服器：Tailscale＋token，唯讀）：衛星清單與畫面
    func registerRemote() {
        SphereEmbed.remoteSats = { [weak self] in
            // 附上 Claude 的 session id（手機點球上的 session 時，用這個對到是哪顆衛星）
            let dir = NSHomeDirectory() + "/.claude/sessions", fm = FileManager.default
            let recs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }
                .compactMap { fm.contents(atPath: dir + "/" + $0).flatMap(SessionRecord.decode) }
            let cap = CaptainStore.captain()?.sessionId
            let list: [[String: Any]] = MainActor.assumeIsolated {
                guard let h = self else { return [] }
                return h.order.compactMap { id -> [String: Any]? in
                    guard let s = h.sats[id] else { return nil }
                    var o = s.json
                    o["moons"] = OrbitWindow.shared.moonList(id)
                    if let j = s.attachedJob, let r = recs.first(where: { $0.jobId == j }) { o["sessionId"] = r.sessionId }        // 背景 session：用 job id 對
                    else if let p = s.pty, let r = recs.first(where: { $0.pid == p.pid || Host.parent(of: $0.pid) == p.pid }) { o["sessionId"] = r.sessionId }
                    if let c = cap, o["sessionId"] as? String == c { o["captain"] = true }
                    if let l = SphereEmbed.label(o["sessionId"] as? String) { o["head"] = l.head; o["work"] = l.work }
                    return o
                }
            }
            return (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        }
        SphereEmbed.remoteScreen = { [weak self] id, from, size in
            let o: [String: Any]? = MainActor.assumeIsolated {
                if id.hasPrefix("pane|") { return OrbitWindow.shared.phonePane(id, from: from) }        // 手機看這顆衛星的 3D／網頁面板
                if let size, let h = self, let s = h.sats[id], let to = s.phoneView(cols: size.cols, rows: size.rows) { h.applyPhone(id, s, to, phone: true) }   // 手機附上自己的大小 ⇒ 手機在看時用手機大小
                return self?.sats[id]?.remote(from: from)
            }
            return o.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        }
        // 11-24 Keng：iPhone 衛星終端機可以點、捲、打字 ⇒ 手機送來的位元組直接寫進那顆衛星的 pty（跟本機網頁的 "input" 同一條）
        SphereEmbed.remoteInput = { [weak self] id, data in
            MainActor.assumeIsolated {
                self?.input(id, data) ?? false
            }
        }
    }

    /// 11-24 手機在看／離開：先讓衛星判斷要不要還原，再把狀態告訴 Mac 這邊的終端機網頁（縮小置中或恢復）
    private var phoneShown: [String: String] = [:]
    func syncPhone() {
        for (id, s) in sats {
            if let m = s.phoneCheck() { applyPhone(id, s, m, phone: false) }
            else if !s.phoneActive, phoneShown[id, default: ""] != "" { applyPhone(id, s, nil, phone: false) }      // 大小本來就一樣：只要讓網頁還原
        }
    }
    /// 先告訴 Mac 這邊的終端機網頁換格子（縮小置中／還原），再改 pty，最後推一次整頁重畫。
    /// 順序很重要：網頁還是舊格子時程式就照新大小重畫，那一頁會錯位，之後程式只補改過的行，錯位就一直留著（3:48 錄影）
    func applyPhone(_ id: String, _ s: Satellite, _ to: (cols: Int, rows: Int)?, phone: Bool) {
        let key = phone ? (to.map { "\($0.cols)x\($0.rows)" } ?? phoneShown[id, default: ""]) : ""
        if let v = views[id], phoneShown[id, default: ""] != key {
            if phone, let t = to { Self.call(v, "window.orbitPhoneSize", [id, t.cols, t.rows]) }
            else if !phone { Self.call(v, "window.orbitPhoneSize", [id, NSNull(), NSNull()]) }
        }
        phoneShown[id] = key
        if let t = to { s.pty?.resize(cols: t.cols, rows: t.rows); s.nudge() }
    }

    func startTimers() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pushSats(); self?.syncPhone() } }
    }

    static var webDir: URL? {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("OrbitWeb")) }   // Orbit42.app：Resources/OrbitWeb（Resources/Web 放 ShoWork 的球體網頁）
        c.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web"))
        return c.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    // MARK: web → host
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let a = m["action"] as? String else { return }
        let from = message.webView.flatMap { w in views.first { $0.value === w }?.key }      // 哪顆衛星的視窗送來的
        let id = m["id"] as? String ?? from ?? ""
        let cols = m["cols"] as? Int ?? 100, rows = m["rows"] as? Int ?? 30
        switch a {
        case "ready":
            guard let from, let v = views[from] else { return }
            Self.call(v, "window.orbitSats", [order.compactMap { sats[$0]?.json }])
            Self.call(v, "window.orbitOpened", [from])
        case "new":
            let brain = Brain(rawValue: m["brain"] as? String ?? "claude") ?? .claude
            let n = (counter[brain] ?? 0) + 1; counter[brain] = n
            let cwd = (m["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            if brain == .claude, Self.useBackground { openBackground(name: "\(brain.label) \(n)", cwd: cwd); return }
            let s = Satellite(id: UUID().uuidString.prefix(8).lowercased(), name: "\(brain.label) \(n)", brain: brain, cwd: cwd, command: brain.command)
            add(s); onOpen(s.id)
        case "attach":
            guard let job = m["job"] as? String else { return }
            if recentlyClosed(job) { print("attach \(job) skipped: just closed"); fflush(stdout); return }   // 11-24：剛按叉叉關掉的，列表還沒更新，點到不要又叫醒
            if let existing = sats.values.first(where: { $0.attachedJob == job }) { onOpen(existing.id); return }
            let s = Satellite(id: "bg-" + job, name: m["name"] as? String ?? job, brain: .claude, cwd: m["cwd"] as? String ?? NSHomeDirectory(),
                              command: "claude attach \(job)", attachedJob: job)
            add(s); onOpen(s.id)
        case "link":                       // 終端機裡點網址 ⇒ 開在這顆衛星的網頁面板
            if let from, let u = WebPane.parse(m["url"] as? String ?? ""), !u.isFileURL { OrbitWindow.shared.openWeb(u, sat: from) }
        case "hide": if let from { onHide(from) }
        case "open":
            guard let s = sats[id] else { return }
            if s.pty == nil || s.exited != nil { start(s, cols: cols, rows: rows) }
            else { if let v = views[id] { Self.call(v, "window.orbitReplay", [id, s.snapshot().base64EncodedString()]) }; s.localResize(cols: cols, rows: rows) }
        case "input":
            if let d = (m["data"] as? String)?.data(using: .utf8) { input(id, d) }
        case "resize": sats[id]?.localResize(cols: cols, rows: rows); if ProcessInfo.processInfo.environment["ORBIT_TEST_DRAG"] != nil { print("resize \(id) \(cols)x\(rows) pty=\(sats[id]?.pty != nil)"); fflush(stdout) }
        case "remove":
            // Satellites Orbit42 started: hang up (like closing a terminal window).
            // Attached background sessions: only the viewer closes; the session keeps running.
            end(id)
        default: break
        }
    }

    // MARK: 11-24 Keng「重開 Orbit42 會連帶關掉底下的衛星，要修正」
    // Claude 衛星改用官方背景 session 開（claude --bg），Orbit42 只是 claude attach 上去看：
    // 重開、更新、當掉都只關掉「檢視」，session 由 Claude 背景服務照跑；重開後 restore 照 job 重新 attach。
    // 叉叉關閉照舊停掉它（claude stop，對話保留）。測試（ORBIT_OFFSCREEN）照舊直接開，不在背景服務留東西；Codex／Antigravity 沒有背景模式，照舊直接開
    static var useBackground: Bool { ProcessInfo.processInfo.environment["ORBIT_OFFSCREEN"] == nil }
    /// 開一個背景 session（resume：接回那段對話）→ attach 成衛星。開不起來就退回直接開（至少有終端機可用）
    func openBackground(name: String, cwd: String, resume: String? = nil) {
        let flags = String(Brain.claude.command.dropFirst("claude ".count)) + " -n '\(name.replacingOccurrences(of: "'", with: ""))'" + (resume.map { " --resume \($0)" } ?? "")
        Self.startBackground(cwd: cwd, flags: flags) { [weak self] job in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                if let job {
                    self.userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "attach", "job": job, "name": name, "cwd": cwd]))
                } else {
                    print("background start failed → direct"); fflush(stdout)
                    let s = Satellite(id: UUID().uuidString.prefix(8).lowercased(), name: name, brain: .claude, cwd: cwd,
                                      command: Brain.claude.command + (resume.map { " --resume \($0)" } ?? ""))
                    self.add(s); self.onOpen(s.id)
                }
            } }
        }
    }
    /// claude --bg 會印「backgrounded · <id>」。輸出寫暫存檔（背景服務會繼承 stdout，用 pipe 會一直讀不到結尾）
    nonisolated static func startBackground(cwd: String, flags: String, done: @escaping @Sendable (String?) -> Void) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-bg-\(UUID().uuidString).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "claude --bg \(flags) < /dev/null > \"$1\" 2>&1", "orbit-bg", out.path]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.terminationHandler = { _ in
            let s = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: out)
            let id = s.range(of: #"backgrounded · [0-9a-f]{6,}"#, options: .regularExpression).map { String(s[$0].split(separator: " ").last!) }
            print("background start → \(id ?? "nil")\(id == nil ? " output=" + s.prefix(300) : "")"); fflush(stdout)
            done(id)
        }
        do { try p.run() } catch { done(nil) }
    }

    private func add(_ s: Satellite) { sats[s.id] = s; order.append(s.id); pushSats() }

    /// 登入／安裝：開一個終端機小視窗跑那一家的官方指令（結束後回呼，讓登入畫面重查狀態）
    var onExited: (String) -> Void = { _ in }
    @discardableResult
    func runCommand(name: String, brain: Brain, command: String) -> String {
        let s = Satellite(id: "cmd-" + UUID().uuidString.prefix(6).lowercased(), name: name, brain: brain, cwd: NSHomeDirectory(), command: command)
        add(s); onOpen(s.id); return s.id
    }

    // MARK: 球體（ShoWork 完整球體）→ 這裡
    /// ＋ 新衛星
    func newSatellite(_ brain: String) {
        userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "new", "brain": brain]))
    }
    /// 點到球上的衛星：Orbit42 開的（終端機是我們的）就打開它；背景 session 就 attach 進來看；其他回 false（照舊跳 Ghostty）
    func open(_ ref: SphereEmbed.SessionRef) -> Bool {
        if ref.pid > 0, let s = sats.values.first(where: { sat in sat.pty.map { $0.pid == ref.pid || Self.parent(of: ref.pid) == $0.pid } ?? false }) {
            onOpen(s.id); return true
        }
        if ref.kind == "bg", let job = ref.jobId {
            if recentlyClosed(job) { return true }      // 11-24：剛按叉叉關掉、戰情列表還沒更新的那一列：點了不叫醒（也不跳 Ghostty）
            userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "attach", "job": job, "name": ref.name, "cwd": ref.cwd ?? NSHomeDirectory()]))
            return true
        }
        return false
    }
    nonisolated static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private func start(_ s: Satellite, cols: Int, rows: Int) {
        s.exited = nil
        // 淺色／深色先用環境變數告訴終端機程式（COLORFGBG：前景;背景，15＝白、0＝黑），有些程式只看這個
        let dark = theme != "light"
        guard let p = Pty(command: s.command, cwd: s.cwd, cols: cols, rows: rows, env: ["COLORFGBG": dark ? "15;0" : "0;15", "ORBIT_SAT": s.id]) else {
            if let v = views[s.id] { Self.call(v, "window.orbitData", [s.id, Data("\r\n[Orbit42] could not start a terminal\r\n".utf8).base64EncodedString()]) }
            return
        }
        let id = s.id
        let rawPath = ProcessInfo.processInfo.environment["ORBIT_TEST_RAW"]
        if let r = rawPath { FileManager.default.createFile(atPath: r, contents: nil) }
        let rawLog = rawPath.flatMap { FileHandle(forWritingAtPath: $0) }
        p.onData = { [weak self, weak s] d in
            rawLog?.write(d)                 // 測試：錄下終端機收到的原始輸出（查顏色碼）
            s?.append(d)
            guard let self else { return }
            self.pendLock.lock(); self.pending[id, default: Data()].append(d); self.pendLock.unlock()
        }
        p.onExit = { [weak self] code in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let s = self.sats[id] else { return }
                s.exited = code; s.pty = nil
                self.flush(); if let v = self.views[id] { Self.call(v, "window.orbitExit", [id, Int(code)]) }
                self.pushSats(); self.onExited(id)
            } }
        }
        s.pty = p
        pushSats()
    }

    private func flush() {
        pendLock.lock(); let out = pending; pending = [:]; pendLock.unlock()
        for (id, d) in out where !d.isEmpty { if let v = views[id] { Self.call(v, "window.orbitData", [id, d.base64EncodedString()]) } }
    }

    private func pushSats() {
        let list = order.compactMap { sats[$0]?.json }
        for v in views.values { Self.call(v, "window.orbitSats", [list]) }
        for (id, s) in sats { onBusy(id, s.exited == nil && Date().timeIntervalSince(s.lastOutput) < 2.5) }
    }

    /// 所有衛星視窗都呼叫（例如換深淺）
    func js(_ fn: String, _ args: Any...) { for v in views.values { Self.call(v, fn, args) } }
    static func call(_ v: WKWebView, _ fn: String, _ args: [Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: args) else { return }
        v.evaluateJavaScript("\(fn) && \(fn)(...\(String(decoding: d, as: UTF8.self)))")
    }

    // MARK: test hooks（只作用在第一個打開的衛星視窗）
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if testView == nil { testView = w }
        guard testView === w else { return }
        let env = ProcessInfo.processInfo.environment
        if let code = env["ORBIT_TEST_JS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { w.evaluateJavaScript(code) }
        }
        if let out = env["ORBIT_TEST_SHOT"] {
            let delay = Double(env["ORBIT_TEST_SHOT_DELAY"] ?? "8") ?? 8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                w.takeSnapshot(with: nil) { img, _ in
                    if let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out))
                        w.evaluateJavaScript("document.title") { t, _ in print("orbit shot saved \(out) \(t ?? "")"); fflush(stdout) }
                    }
                    if env["ORBIT_TEST_QUIT"] != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.shutdown(); NSApp.terminate(nil) } }
                    }
                }
            }
        }
    }

    // MARK: 重開後衛星回來（11-23 Keng「重開前有兩個衛星，重開後只剩一個」）
    // 關掉 Orbit42 時把自己開的衛星記下來（Claude 記 session id，重開用 --resume 接回同一段對話；背景 session 記 job 重新 attach），
    // 下次打開就照原樣開回來，像 macOS 重開機恢復視窗。登入／安裝用的臨時視窗（cmd-）不記。
    // 測試：ORBIT_TEST_RESTORE=save／load ⇒ 用另一個紀錄名稱（不碰真正的），load 時 3 秒後直接恢復
    static var restoreKey: String { ProcessInfo.processInfo.environment["ORBIT_TEST_RESTORE"] != nil ? "orbit.restore.test" : "orbit.restore" }
    static var restoreBlocked: Bool { let e = ProcessInfo.processInfo.environment; return e["ORBIT_OFFSCREEN"] != nil && e["ORBIT_TEST_RESTORE"] == nil }
    private func saveForRestore() {
        if Self.restoreBlocked { return }      // 測試不碰真正的紀錄
        let dir = NSHomeDirectory() + "/.claude/sessions", fm = FileManager.default
        let recs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }
            .compactMap { fm.contents(atPath: dir + "/" + $0).flatMap(SessionRecord.decode) }
        var out: [[String: String]] = []
        for id in order {
            guard let s = sats[id], !id.hasPrefix("cmd-"), s.exited == nil else { continue }
            if let job = s.attachedJob { out.append(["job": job, "name": s.name, "cwd": s.cwd]); continue }
            guard let p = s.pty else { continue }
            var e = ["brain": s.brain.rawValue, "name": s.name, "cwd": s.cwd]
            if s.brain == .claude, let r = recs.first(where: { $0.pid == p.pid || Self.parent(of: $0.pid) == p.pid }) { e["sid"] = r.sessionId; e["cwd"] = r.cwd }
            out.append(e)
        }
        if let d = try? JSONSerialization.data(withJSONObject: out) { UserDefaults.standard.set(String(decoding: d, as: UTF8.self), forKey: Self.restoreKey) }
    }
    /// 打開 Orbit42 時：把上次關掉時開著的衛星開回來（開完就清掉紀錄，下次關掉再記）
    func restore() {
        if Self.restoreBlocked { return }
        guard let str = UserDefaults.standard.string(forKey: Self.restoreKey), let d = str.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String: String]], !list.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.restoreKey)
        for e in list {
            let cwd = e["cwd"] ?? NSHomeDirectory()
            if let job = e["job"] {
                userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "attach", "job": job, "name": e["name"] ?? job, "cwd": cwd]))
                continue
            }
            let brain = Brain(rawValue: e["brain"] ?? "claude") ?? .claude
            let name = e["name"] ?? brain.label
            if let n = Int(name.split(separator: " ").last ?? ""), n > (counter[brain] ?? 0) { counter[brain] = n }
            // 11-24：衛星開了還沒講話就關掉，Claude Code 不會留對話紀錄，--resume 會「No conversation found」直接結束 ⇒ 有紀錄才接回
            let sid = brain == .claude && e["sid"].map(hasTranscript) == true ? e["sid"] : nil
            // 11-24：以前直接開的 Claude 衛星，重開時改成背景 session 接回（之後再重開就不會被關掉）
            if brain == .claude, Self.useBackground { openBackground(name: name, cwd: cwd, resume: sid); continue }
            let cmd = sid.map { brain.command + " --resume " + $0 } ?? brain.command
            let s = Satellite(id: UUID().uuidString.prefix(8).lowercased(), name: name, brain: brain, cwd: cwd, command: cmd)
            add(s); onOpen(s.id)
        }
    }

    func shutdown() { saveForRestore(); for s in sats.values { s.pty?.hangup() } }
}

/// Serves files under Web/ as orbit://app/<path>
final class WebFiles: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }
    func webView(_ w: WKWebView, start task: any WKURLSchemeTask) {
        let rel = task.request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let file = root.appendingPathComponent(rel.isEmpty ? "index.html" : rel).standardizedFileURL
        guard file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "json": "application/json", "png": "image/png", "svg": "image/svg+xml"]
        let mime = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime + "; charset=utf-8", "Cache-Control": "no-store"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ w: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// 從原生端呼叫同一套訊息處理（跟網頁送來的一樣）
final class FakeMessage: WKScriptMessage {
    private let payload: [String: Any]
    init(_ p: [String: Any]) { payload = p; super.init() }
    override var body: Any { payload }
}

/// WKUserContentController keeps a strong reference to its handlers.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(u, didReceive: m) }
}

/// 登入畫面（Orbit42 一打開先出現）：列出各家 AI 帳號的安裝／登入狀態，按登入走各家官方登入
@MainActor
final class LoginPanel: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    var onEnter: ([Provider]) -> Void = { _ in }
    var runInTerminal: (String, Brain, String) -> Void = { _, _, _ in }
    private(set) var providers: [Provider] = []
    private var poll: Timer?

    override init() {
        let cfg = WKWebViewConfiguration()
        if let dir = Host.webDir { cfg.setURLSchemeHandler(WebFiles(root: dir), forURLScheme: "orbit") }
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "login")
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: URL(string: "orbit://app/login.html")!))
        // 登入多半在瀏覽器完成：登入畫面開著時每 3 秒重查一次
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { if self?.web.isHidden == false { self?.check() } } }
    }

    func check() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Accounts.check()
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.providers = list
                if let d = try? JSONSerialization.data(withJSONObject: list.map(\.json)) {
                    self.web.evaluateJavaScript("window.orbitAccounts && window.orbitAccounts(\(String(decoding: d, as: UTF8.self)))")
                }
            } }
        }
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let a = b["action"] as? String else { return }
        let p = Accounts.all.first { $0.id == b["id"] as? String }
        let brain = Brain(rawValue: p?.id ?? "") ?? .claude
        switch a {
        case "check": check()
        case "login": if let p, let cmd = p.login { runInTerminal("登入 \(p.name)", brain, cmd) }
        case "install": if let p, let cmd = p.install { runInTerminal("安裝 \(p.name)", brain, cmd) }
        case "enter": onEnter(providers)
        default: break
        }
    }
}

/// Orbit42 主視窗：整個 ShoWork 球體（播報、空白鍵講話、量表、自檢、cool42…）＋右邊滑出的衛星終端機
@MainActor
final class OrbitWindow: NSObject, NSWindowDelegate {
    static let shared = OrbitWindow()
    var window: NSWindow!
    let host = Host()
    let login = LoginPanel()
    private var sphereView: NSView?
    private var askTimer: Timer?
    private var webWatch: Timer?
    /// 11-23 Keng「Orbit42 改檔自動重新載入，免重開」：每秒看球體頁（Web/sphere.html，SHOWORK_WEB_DIR 優先）的修改時間，
    /// 變了且連續 2 次一樣（檔案寫完）才 reload 球體 WebView；資料下一秒由宿主重推，版面在 localStorage。衛星終端機不動。
    private func watchSphereFile() {
        let env = ProcessInfo.processInfo.environment
        let dir = env["SHOWORK_WEB_DIR"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL?.appendingPathComponent("Web")
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
    private var satWins: [String: TermWindowView] = [:]
    private var zTop: CGFloat = 10
    /// 最上面那個開著的衛星小視窗（測試 hooks 用）
    private var frontSat: TermWindowView? {
        satWins.values.filter { !$0.isHidden }.max { ($0.layer?.zPosition ?? 0) < ($1.layer?.zPosition ?? 0) }
    }

    func show(test: Bool) {
        let env = ProcessInfo.processInfo.environment
        let size = NSSize(width: Double(env["ORBIT_TEST_W"] ?? "") ?? 1440, height: Double(env["ORBIT_TEST_H"] ?? "") ?? 900)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Orbit42"
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = NSView(frame: NSRect(origin: .zero, size: size))
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
        host.registerRemote()                 // 11-23 iPhone App：衛星清單與畫面（ShoWork 網頁伺服器唯讀端點）
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
            if cmd.hasPrefix("moon:") { self?.moonCommand(cmd) }
            if cmd == "hideSats" { self?.hideAllSats() }      // 11-24 點球體空白處：衛星終端機全部收下去、露出智能體
            if cmd.hasPrefix("theme:") { self?.applyTheme(String(cmd.dropFirst(6))) }
            if cmd.hasPrefix("arrangeSats") {          // "arrangeSats:x,y,w,h"＝球體量好的空位（網頁座標，左上原點）
                let v = cmd.split(separator: ":").dropFirst().first?.split(separator: ",").compactMap { Double($0) } ?? []
                self?.arrangeSats(in: v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil)
            }
        }
        watchAskCard(); watchSphereFile()
        startModels(test: test); startMoons()
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
        // 測試：ORBIT_TEST_HIDESATS=1 ⇒ 開一顆衛星（視窗打開），5 秒後數一次開著的衛星視窗；網頁（SHOWORK_TEST_SPHERE_JS＋SHOWORK_TEST_SPHERE_SHOT，載完 9 秒才跑）模擬點空白處，18 秒時再數一次
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
        if test {
            window.setFrameOrigin(NSPoint(x: -6000, y: -6000)); window.orderBack(nil)
        } else {
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
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
    func windowDidEnterFullScreen(_ n: Notification) { UserDefaults.standard.set(true, forKey: "orbit.desktop"); layoutTerm() }
    func windowDidExitFullScreen(_ n: Notification) { UserDefaults.standard.set(false, forKey: "orbit.desktop"); layoutTerm() }

    /// 11-23 Keng：球體切深淺（◐）時，衛星終端機（xterm 色票＋裡面的 Claude Code）和小視窗標題列一起換
    private var themeNow = "dark"

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
        let v: WebPane
        if let have = moons[id]?["web"] as? WebPane { v = have }
        else {
            v = WebPane(frame: .zero)
            v.onShut = { [weak self] in self?.dropMoon(id, "web") }
            v.onTuck = { [weak self] in self?.tuckMoon(id) }
            v.onTitle = { [weak self] in self?.pushMoons() }
            moons[id, default: [:]]["web"] = v
        }
        showMoon(id, "web")
        if let url { v.open(url) } else { v.focusAddress() }
    }

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
    private func pickSat(sat: String, job: String) -> String? {
        if !sat.isEmpty, host.has(sat) { return sat }
        if let s = host.sat(job: job) { return s }
        guard sat.isEmpty, job.isEmpty else { return nil }
        return satWins.filter { !$0.key.hasPrefix("3d-") && !$0.value.isHidden && $0.value.wantShown }
            .max { ($0.value.layer?.zPosition ?? 0) < ($1.value.layer?.zPosition ?? 0) }?.key
    }
    func moonViews(_ id: String) -> [String: NSView] { moons[id] ?? [:] }
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
        let wins = root.subviews.compactMap { $0 as? TermWindowView }.filter { !$0.isHidden && $0.wantShown }.sorted { $0.seq < $1.seq }   // 照打開先後：點一下疊到最上面不會換位置
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
        let cap = CaptainStore.captain()?.sessionId, test = ProcessInfo.processInfo.environment["ORBIT_TEST_SECRETARY"] != nil
        for (id, w) in satWins where !id.hasPrefix("3d-") {
            let sid = host.sessionId(id), on = test || (cap != nil && sid == cap)
            // 11-25：標題列固定「職責 · 主專案｜工作標題」；不是 Claude session（Codex、還沒開）照舊。小標已經寫「秘書」，不重複
            if w.pane == nil || on || SphereEmbed.label(sid) != nil {
                let l = SphereEmbed.label(sid), t = l.map { on ? $0.line.replacingOccurrences(of: "秘書 · ", with: "") : $0.line } ?? (on ? "待命" : host.title(id))
                if w.titleLabel.stringValue != t { w.titleLabel.stringValue = t }
            }
            w.secretary = on
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
    private var confirmAlert: NSAlert?          // 測試 hook 用（按確認視窗的按鈕）
    private func closeSat(_ id: String) {
        guard let w = satWins.removeValue(forKey: id) else { return }
        dropMoons(id); moonSids[id] = nil
        animate(w, on: false) { [weak self] in w.removeFromSuperview(); self?.autoArrange() }
    }
    /// 11-24 Keng「點擊全收是第一下，點第二下應該要全部跳回來」：點球體空白處＝切換。
    /// 有開著的 ⇒ 記住是哪幾顆、全部收下去；都收著而且有記住的 ⇒ 那幾顆全部叫回來。中間自己打開任何一顆，就從「收」重新算
    private var tucked: [String] = []
    private func hideAllSats() {
        let open = satWins.filter { !$0.value.isHidden && $0.value.wantShown }.map(\.key)
        if open.isEmpty {
            let back = tucked.filter { satWins[$0] != nil }; tucked = []
            for id in back { showSat(id) }
            return
        }
        tucked = open
        for id in open { if let w = satWins[id] { animate(w, on: false) } }
    }

    /// 疊到最上面：zPosition 遞增，再照 zPosition 重排 subview 順序（不把視圖拿下來重放，終端機不會失焦）
    private func raise(_ w: NSView) {
        guard let root = window.contentView else { return }
        if root.subviews.last === w, (w.layer?.zPosition ?? 0) >= zTop { return }
        zTop += 1; w.wantsLayer = true; w.layer?.zPosition = zTop
        root.sortSubviews({ a, b, _ in
            let za = a.layer?.zPosition ?? 0, zb = b.layer?.zPosition ?? 0
            return za < zb ? .orderedAscending : za > zb ? .orderedDescending : .orderedSame
        }, context: nil)
    }
    private func raiseUnder(_ e: NSEvent) {
        guard e.window === window, let root = window.contentView else { return }
        let p = root.convert(e.locationInWindow, from: nil)
        guard let w = root.subviews.last(where: { ($0 as? TermWindowView)?.yieldingToAsk == false && !$0.isHidden && $0.frame.contains(p) }) else { return }
        raise(w)
    }

    private func layoutTerm() {
        guard let root = window.contentView else { return }
        // Orbit42 視窗變小：開著的小視窗縮進來、留在視窗裡
        for w in satWins.values where !w.isHidden { w.frame = TermWindowView.fit(w.frame, in: root.bounds) }
    }
    /// 小視窗打開時從下方放大淡入（像 macOS 開視窗），收起時縮小淡出
    private func animate(_ w: TermWindowView, on: Bool, then: (() -> Void)? = nil) {
        w.wantShown = on; w.yieldingToAsk = false         // 開／收動畫自己管透明度；淡掉與否下一輪 watchAskCard 再判斷
        guard let layer = w.layer, let root = window.contentView else { w.isHidden = !on; then?(); return }
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
    func windowDidResize(_ n: Notification) { layoutTerm() }
    func windowWillClose(_ n: Notification) { host.shutdown(); NSApp.terminate(nil) }
}

/// Orbit42 取代 ShoWorkAgent：兩個不能同時跑（播報講兩次、權限卡兩邊搶、socket 打架）。
/// 開 Orbit42 時先停掉 launchd 的 ShoWorkAgent，結束時再把它開回來。
enum AgentSwap {
    static let label = "ai.okle42.showork.agent"
    static var plist: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static func launchctl(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args; try? p.run(); p.waitUntilExit() }
    static func stop() { launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
    static func start() { if FileManager.default.fileExists(atPath: plist) { launchctl(["bootstrap", "gui/\(getuid())", plist]) } }
}

let orbitEnv = ProcessInfo.processInfo.environment
let orbitTest = orbitEnv["ORBIT_OFFSCREEN"] != nil
if orbitEnv["ORBIT_TEST_DISKS"] != nil { print(MainActor.assumeIsolated { DiskWatch.dump() }); exit(0) }
if !orbitTest {
    AgentSwap.stop()
    atexit { AgentSwap.start() }
}
MainActor.assumeIsolated {
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { ChromeBrowser.shared.quit(); OrbitWindow.shared.host.shutdown() }
    }
    ShoWorkAgentMain.run(AgentOptions(regularApp: !orbitTest, waitForAccessibility: false, testOnly: orbitTest,
                                      onLaunch: {
        OrbitWindow.shared.show(test: orbitTest)
        // 11-24 外接硬碟斷線偵測：等球體載好（8 秒）再開始，開機就慢速的那句才講得出來
        DockIcon.shared.start()               // 11-24 Dock 圖示跟著深淺色換
        DiskWatch.shared.say = { OrbitWindow.shared.toast($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (orbitEnv["ORBIT_TEST_DISKWATCH"].flatMap(Double.init) ?? 8)) {
            MainActor.assumeIsolated { DiskWatch.shared.start() }
        }
    }))
}

/// Claude Code 有沒有這段對話的紀錄（~/.claude/projects/*/<sid>.jsonl）；沒有就不能 --resume
func hasTranscript(_ sid: String) -> Bool {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let subs = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return true }
    return subs.contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).appendingPathComponent(sid + ".jsonl").path) }
}
