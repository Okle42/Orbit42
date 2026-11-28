import AppKit
import WebKit
import Orbit42App
import Orbit42Core

@MainActor
final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    // 11-23 Keng「衛星終端機只能開一個視窗，要能開多個、重疊、移動」：
    // 每顆衛星自己一個網頁視圖（index.html?term=1&sat=<id>），各自裝在自己的小視窗裡
    private(set) var views: [String: DropWebView] = [:]
    /// 11-26 Keng「版面嚴重變形、調不回來」：沒視窗先接上的背景 session（固定 110×36、網頁標成 headless 不再量欄數）
    /// ⇒ 衛星視窗真的顯示出來時要叫網頁照視窗重新量一次（wakeIfHeadless）
    private(set) var headless: Set<String> = []
    /// 測試用（HeadlessWakeTest.swift）：照背景 session 沒視窗先接上那條路，把這顆標成 headless
    func testMakeHeadless(_ id: String) {
        guard let v = views[id] else { return }
        sats[id]?.localResize(cols: 110, rows: 36)
        Self.call(v, "window.orbitHeadless", [id, 110, 36]); headless.insert(id)
    }
    func wakeIfHeadless(_ id: String) {
        guard headless.remove(id) != nil, let v = views[id] else { return }
        Self.call(v, "window.orbitOpened", [id])      // openTerm → 等大小穩定 → headless=false → 照視窗量（已開過的程式不會再開一次）
        print("wake headless \(id)"); fflush(stdout)
    }
    private let files: WebFiles? = Host.webDir.map { WebFiles(root: $0) }
    private var sats: [String: Satellite] = [:]
    private var order: [String] = []
    private var counter: [Brain: Int] = [:]
    private var pending: [String: Data] = [:]
    private let pendLock = NSLock()
    nonisolated(unsafe) private var flushQueued = false      // pendLock 保護
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
    func typeAnswer(_ sid: String, _ text: String, command: Bool = false, still: @escaping @MainActor () -> Bool, done: @escaping @MainActor (TermAnswer.Outcome) -> Void) -> Bool {
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
            mark: { still() && (command || TypedMark.put(sid: sid, text: text)) },
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
            let out = await TermAnswer.send(text, to: sid, command: command, io: io)
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
    /// 自動 /clear（HandoverClear）：有衛星就打；背景 session 沒衛星就悄悄接上（不開視窗），下一次再打
    func typeClear(_ sid: String, still: @escaping @MainActor () -> Bool, done: @escaping @MainActor (TermAnswer.Outcome) -> Void) -> Bool {
        if typeAnswer(sid, "/clear", command: true, still: still, done: done) { return true }
        if sats.values.contains(where: { $0.exited == nil && $0.pty != nil && sessionRecord($0)?.sessionId == sid }) { done(.notStarted("它的終端機現在不能打字")); return true }
        guard let r = NicknameStore.liveSessions().first(where: { $0.sessionId == sid }), let job = r.jobId, !recentlyClosed(job) else { return false }
        if let s = sats.values.first(where: { $0.attachedJob == job }) {
            if s.exited != nil { start(s, cols: 100, rows: 30) }          // 檢視斷掉了（session 還在）⇒ 重新接上
        } else {
            let s = Satellite(id: "bg-" + job, name: r.name ?? job, brain: .claude, cwd: r.cwd, command: "claude attach \(job)", attachedJob: job)
            add(s)
            let v = view(for: s.id)
            // 沒有視窗的網頁不會跑 requestAnimationFrame、不會自己來開 ⇒ 這裡先開，之後點開視窗會照平常重新量
            start(s, cols: 110, rows: 36)
            Task { @MainActor [weak self, weak s] in
                try? await Task.sleep(for: .seconds(4))
                guard let s, self?.sats[s.id] === s else { return }
                Self.call(v, "window.orbitHeadless", [s.id, 110, 36])
                self?.headless.insert(s.id)
                Self.call(v, "window.orbitReplay", [s.id, s.snapshot().base64EncodedString()])
            }
        }
        done(.notStarted("正在接上它的終端機"))
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
    private(set) var composing: Set<String> = []
    func attachForTest(job: String) {
        userContentController(WKUserContentController(), didReceive: FakeMessage(["action": "attach", "job": job, "name": "測試背景", "cwd": NSHomeDirectory()]))
    }
    func name(_ id: String) -> String { sats[id]?.name ?? id }
    /// 這個背景工作（job 編號）是哪一顆衛星
    func sat(job: String) -> String? { job.count < 6 ? nil : sats.values.first { $0.attachedJob.map { $0.hasPrefix(job) || job.hasPrefix($0) } ?? false }?.id }
    func has(_ id: String) -> Bool { sats[id] != nil }
    func satName(_ id: String) -> String? { sats[id]?.name }      // WebAgent 問 Keng 時顯示是哪顆衛星
    var runningForeground: Int { sats.values.filter { $0.pty != nil && $0.attachedJob == nil }.count }
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

    /// 11-23 iPhone App（經 Orbit42 網頁伺服器：Tailscale＋token，唯讀）：衛星清單與畫面
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
            // 跟戰情清單同一份順序；沒有 session 的（Codex、還沒開）排後面、照原本先後
            let at = MainActor.assumeIsolated { Dictionary(SphereEmbed.cardOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a }) }
            let sorted = list.enumerated().sorted { a, b in
                let x = (a.element["sessionId"] as? String).flatMap { at[$0] } ?? .max, y = (b.element["sessionId"] as? String).flatMap { at[$0] } ?? .max
                return (x, a.offset) < (y, b.offset)
            }.map(\.element)
            return (try? JSONSerialization.data(withJSONObject: sorted)) ?? Data("[]".utf8)
        }
        SphereEmbed.remoteScreen = { [weak self] id, from, size in
            let o: [String: Any]? = MainActor.assumeIsolated {
                if id.hasPrefix("mac|") { return MacWindows.shared.remote(id, have: from) }            // 手機看這台 Mac 的視窗
                if id.hasPrefix("pane|") { return OrbitWindow.shared.phonePane(id, from: from, size: size) }        // 手機看這顆衛星的 3D／網頁面板
                if let size, let h = self, let s = h.sats[id], let to = s.phoneView(cols: size.cols, rows: size.rows) { h.applyPhone(id, s, to, phone: true) }   // 手機附上自己的大小 ⇒ 手機在看時用手機大小
                return self?.sats[id]?.remote(from: from)
            }
            return o.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        }
        // 11-24 Keng：iPhone 衛星終端機可以點、捲、打字 ⇒ 手機送來的位元組直接寫進那顆衛星的 pty（跟本機網頁的 "input" 同一條）
        SphereEmbed.remoteInput = { [weak self] id, data in
            MainActor.assumeIsolated {
                if id.hasPrefix("mw-") { return MacWindows.shared.input(String(id.dropFirst(3)), data) }
                if id.hasPrefix("pw-") { return OrbitWindow.shared.phoneWeb(String(id.dropFirst(3)), data) }      // 手機操作這顆衛星的網頁
                return self?.input(id, data) ?? false
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
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pushSats(); self?.syncPhone() } }
    }

    static var webDir: URL? {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("OrbitWeb")) }   // Orbit42.app：Resources/OrbitWeb（Resources/Web 放 Orbit42 的球體網頁）
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
        case "compose": if m["on"] as? Bool == true { composing.insert(id) } else { composing.remove(id) }      // 輸入法組字中（滑過浮起要暫停）
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

    // MARK: 球體（Orbit42 完整球體）→ 這裡
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
            self.pendLock.lock(); self.pending[id, default: Data()].append(d)
            let first = !self.flushQueued; self.flushQueued = true; self.pendLock.unlock()
            // 有輸出才排，1/60 秒內的併成一次（原本每秒固定醒 60 次）
            if first { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { MainActor.assumeIsolated { self.flush() } } }
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
        pendLock.lock(); let out = pending; pending = [:]; flushQueued = false; pendLock.unlock()
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
            if let job = s.attachedJob { var e = ["job": job, "name": s.name, "cwd": s.cwd]; addWeb(&e, id); addModel(&e, id); out.append(e); continue }
            guard let p = s.pty else { continue }
            var e = ["brain": s.brain.rawValue, "name": s.name, "cwd": s.cwd]
            if s.brain == .claude, let r = recs.first(where: { $0.pid == p.pid || Self.parent(of: $0.pid) == p.pid }) { e["sid"] = r.sessionId; e["cwd"] = r.cwd }
            addWeb(&e, id); addModel(&e, id)
            out.append(e)
        }
        if let d = try? JSONSerialization.data(withJSONObject: out) { UserDefaults.standard.set(String(decoding: d, as: UTF8.self), forKey: Self.restoreKey) }
    }
    /// 11-26 Keng「重開後網頁面板自動恢復」：這顆衛星上方開著網頁 ⇒ 記下網址和有沒有展開
    private func addWeb(_ e: inout [String: String], _ id: String) {
        guard let pane = OrbitWindow.shared.moonViews(id)["web"] as? WebPane else { return }
        let u = pane.currentURL
        guard !u.isEmpty, let url = URL(string: u), !url.isFileURL else { return }
        e["web"] = u; e["webShown"] = OrbitWindow.shared.moonShownKind(id) == "web" ? "1" : "0"
    }
    /// 11-28 Keng「重開會把用到一半的 3D 關掉」：這顆衛星開著 3D ⇒ 記下下拉選單裡的檔案、當時顯示哪個、有沒有展開
    func addModel(_ e: inout [String: String], _ id: String) {
        guard let pane = OrbitWindow.shared.moonViews(id)["3d"] as? ModelView, !pane.history.isEmpty else { return }
        e["3d"] = pane.history.map(\.path).joined(separator: "\n")
        if let u = pane.url { e["3dCur"] = u.path }
        e["3dShown"] = OrbitWindow.shared.moonShownKind(id) == "3d" ? "1" : "0"
    }
    func reopenModel(_ e: [String: String], sat id: String) {
        guard let list = e["3d"], !list.isEmpty else { return }
        let files = list.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        let cur = e["3dCur"].map { URL(fileURLWithPath: $0) }, shown = e["3dShown"] == "1"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated {
            guard self.has(id) else { return }
            OrbitWindow.shared.restoreModels(files, cur: cur, shown: shown, sat: id)
            print("restore 3d \(id) \(files.count) files shown=\(shown)"); fflush(stdout)
        } }
    }
    /// 衛星開回來之後，把它的網頁也開回來（等衛星視窗建好）
    private func reopenWeb(_ e: [String: String], sat id: String) {
        guard let u = e["web"].flatMap(WebPane.parse), !u.isFileURL else { return }
        let shown = e["webShown"] == "1"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated {
            guard self.has(id) else { return }
            if shown { OrbitWindow.shared.openWeb(u, sat: id) } else { OrbitWindow.shared.openWebQuiet(u, sat: id) }
            print("restore web \(id) \(u.absoluteString) shown=\(shown)"); fflush(stdout)
        } }
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
                reopenWeb(e, sat: "bg-" + job); reopenModel(e, sat: "bg-" + job)
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
            add(s); onOpen(s.id); reopenWeb(e, sat: s.id); reopenModel(e, sat: s.id)
        }
    }

    func shutdown() { saveForRestore(); for s in sats.values { s.pty?.hangup() } }
}
