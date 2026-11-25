import AppKit
import ShoWorkCore

// MARK: - ctx 自動交接 ②：收尾完自動 /clear、再叫新 context 接手（T1024155358，流程見 ShoWorkCore/Handover.swift）

/// 每次刷新看一遍 board/handover：
///   pending      ＋它閒下來 ⇒ 對它的終端機送 /clear（tmux send-keys；Ghostty 走 AppleScript `input text … to terminal id`，不搶焦點；其他走 Orbit42 衛星）
///   clearing     ＋sessions/<pid>.json 換了 sid ⇒ 再打一句「開始接手」；20 秒沒換 ⇒ failed
///   interrupted  ⇒ 轉秘書一則提醒（收尾後使用者又派新工作）
///   failed       ⇒ 卡片 blocked＋系統通知請 Kang 手動 /clear
/// 目標一定要閉環驗證（09-26 搬 Kang 7 個視窗的教訓）：tmux＝claude 行程的 tty 擁有的 pane；Ghostty＝同一個 tty 探出來的 terminal，
/// 而且 terminal 標題開頭是它的英文名。驗不過就不送。每筆紀錄只自動送一次。
@MainActor
final class HandoverClear {
    static let shared = HandoverClear()
    private var busy = false
    private var lastWhy: [String: Date] = [:]
    private var checked = false
    private var flying: Set<String> = []          // 正在 Orbit42 終端機打 /clear
    private var firstTry: [String: Date] = [:], lastTry: [String: Date] = [:]

    func check(_ cards: [BoardCard], records: [String: HandoverRecord], captain: String?) {
        guard Engine.current != nil, !busy else { return }   // 只有正式 agent 會動手；測試視窗不動
        if !checked { checked = true; selfCheck() }
        guard !records.isEmpty else { return }
        let now = Date()
        for snap in records.values {
            // 快照可能是舊的（背景讀的）；動手前一律以磁碟上的為準，免得同一筆送兩次
            guard var r = snap.state == .failed || (snap.state == .taken && snap.clearAt == nil) ? nil : Handover.load(snap.sid) else { continue }
            if flying.contains(r.sid) { continue }
            switch r.state {
            case .pending:
                if now.timeIntervalSince(lastTry[r.sid] ?? .distantPast) < Handover.retryEvery { continue }
                guard let c = cards.first(where: { $0.sessionId == r.sid }) else { continue }
                let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                guard Handover.readyToClear(state: r.state, lastKind: c.report?.kind, working: c.column == .active,
                                            dialog: c.permit != nil || c.reason == "等你回答",
                                            lastActivity: c.lastActivity, keyIdle: key, now: now) else {
                    if now.timeIntervalSince(lastWhy[r.sid] ?? .distantPast) > 60 {   // 等太久時查得到卡在哪個條件
                        lastWhy[r.sid] = now
                        log("wait \(r.name) kind=\(c.report?.kind ?? "nil") col=\(c.column.rawValue) permit=\(c.permit != nil) reason=\(c.reason) key=\(Int(key))")
                    }
                    continue
                }
                if inOrbit(r) { orbitClear(r, now: now); continue }
                busy = true; defer { busy = false }
                // 先記「送出中」再按鍵：/clear 後的 SessionStart 會讀這筆、改成 taken 寫回，晚寫會把它蓋掉（10-24 實測撞到）
                r.state = .clearing; r.clearAt = now
                Handover.save(r)
                switch send("/clear", to: r) {
                case .success(let via):
                    if var cur = Handover.load(r.sid) { cur.via = via; Handover.save(cur) }
                    log("/clear → \(r.name) \(r.sid.prefix(8)) via \(via)")
                case .failure(let e):
                    fail(&r, e.message)
                    Handover.save(r)
                }
            case .clearing, .taken:
                guard !r.kicked, let at = r.clearAt else { continue }
                let cur = currentSid(pid: r.pid)
                if r.state == .taken || (cur != nil && cur != r.sid) {
                    let ctx = cur.flatMap(ctxPercent).map { "\(Int($0))%" } ?? "未更新"
                    busy = true; defer { busy = false }
                    let k: String
                    if r.via == "orbit" || inOrbit(r) {
                        // 背景 session：/clear 後畫面還在重畫，改用訊息叫醒；還收不到就下次再送
                        let to = Peer.find(r.newSid ?? cur ?? "")
                        if to == nil, now.timeIntervalSince(at) < 60 { continue }
                        let text = Handover.kickoff(r)
                        if let to { DispatchQueue.global().async { _ = Peer.send(to: to, text: text, fromName: "AI工作戰情中心（交接）") } }
                        k = to == nil ? "找不到新 session" : "message"
                    } else { k = "\(send(Handover.kickoff(r), to: r))" }
                    r.kicked = true
                    log("cleared \(r.name) \(r.sid.prefix(8)) → \((r.newSid ?? cur ?? "?").prefix(8)) ctx=\(ctx) kickoff=\(k)")
                    Handover.save(r)
                } else if now.timeIntervalSince(at) > Handover.clearTimeout {
                    fail(&r, "送了 /clear 但 \(Int(Handover.clearTimeout)) 秒內 session 沒換")
                    Handover.save(r)
                }
            case .interrupted:
                guard !r.notified else { continue }
                r.notified = true
                Handover.save(r)
                let text = "【交接提醒】\(r.name) 已在 \(Self.clock(r.at)) 收尾（交接 \(r.handoff)），但之後使用者又派了新工作，所以先不自動 /clear；"
                    + "ctx 再多 15% 時 Stop hook 會再請它收尾一次。要現在就換手，請它做完這件後再發一次 showork card --kind wrapup。"
                log("interrupted \(r.name) \(r.sid.prefix(8))")
                if let cap = captain, cap != r.sid {
                    DispatchQueue.global().async {
                        guard let to = Peer.find(cap) else { return }
                        _ = Peer.send(to: to, text: text, fromName: "AI工作戰情中心（交接）")
                    }
                } else { notify("\(who(r)) 收尾後又接了新工作", "先不自動 /clear") }
            case .failed:
                continue
            }
        }
    }

    // MARK: 背景 session（claude --bg）：打進 Orbit42 的衛星終端機（11-25 Hana5、Gavin5、Penny、秘書都卡在這）

    /// 不在 tmux、也不在 Ghostty ⇒ 走 Orbit42
    private func inOrbit(_ r: HandoverRecord) -> Bool {
        guard SphereEmbed.typeClear != nil, BoardActions.tmuxPane(of: r.pid) == nil else { return false }
        guard let tty = Self.tty(of: r.pid),
              let g = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first else { return true }
        return !ProcTree.ttys(under: g.processIdentifier).contains(tty)
    }

    private func orbitClear(_ rec: HandoverRecord, now: Date) {
        guard let type = SphereEmbed.typeClear else { return }
        let sid = rec.sid
        lastTry[sid] = now
        if firstTry[sid] == nil { firstTry[sid] = now }
        flying.insert(sid)
        // 打字前一刻才記「送出中」；那時已經被使用者打斷（interrupted）就不打
        let started = type(sid, {
            guard var r = Handover.load(sid), r.state == .pending else { return false }
            r.state = .clearing; r.clearAt = Date(); r.via = "orbit"
            return Handover.save(r)
        }) { [weak self] out in self?.orbitDone(sid, out) }
        if !started { orbitDone(sid, .notStarted("Orbit42 接不上它的終端機")) }
    }

    private func orbitDone(_ sid: String, _ out: TermAnswer.Outcome) {
        flying.remove(sid)
        guard var r = Handover.load(sid) else { return }
        switch out {
        case .sent, .sentDropped:
            firstTry[sid] = nil; lastTry[sid] = nil
            log("/clear → \(r.name) \(sid.prefix(8)) via orbit")
        case .notStarted(let why):
            guard r.state == .pending || r.state == .clearing else { return }
            if r.state == .clearing { r.state = .pending; r.clearAt = nil; r.via = nil }
            log("retry \(r.name) \(sid.prefix(8))：\(why)")
            if Date().timeIntervalSince(firstTry[sid] ?? Date()) > Handover.retryFor { firstTry[sid] = nil; fail(&r, why) }
            Handover.save(r)
        case .unsure(let why):
            guard r.state == .clearing else { return }      // 新 session 已經認領＝其實成功了
            fail(&r, why); Handover.save(r)
        }
    }

    // MARK: 送字（閉環驗證過才送）

    private func send(_ text: String, to r: HandoverRecord) -> Result<String, CardError> {
        if let (sock, pane) = BoardActions.tmuxPane(of: r.pid) {
            let t = Tmux.binary()
            Tools.run(t, ["-S", sock, "send-keys", "-t", pane, "-l", text], timeout: 5)
            Thread.sleep(forTimeInterval: 0.15)
            Tools.run(t, ["-S", sock, "send-keys", "-t", pane, "Enter"], timeout: 5)
            return .success("tmux")
        }
        guard let tty = Self.tty(of: r.pid) else { return .failure(CardError("找不到它的終端機（行程 \(r.pid) 沒有 tty）")) }
        guard let g = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first,
              ProcTree.ttys(under: g.processIdentifier).contains(tty) else {
            return .failure(CardError("不在 tmux、Ghostty，也不在 Orbit42，看板送不了"))
        }
        // tty 探不到時（10-26 Tina：Claude 畫面吃掉探測、Ghostty 待重啟更新）退一步用分頁標題：開頭是它英文名的分頁剛好一個才送
        guard let tid = GhosttyProbe.resolve(tty: tty, ghosttyPID: g.processIdentifier)?.terminalID ?? Self.uniqueTerminal(named: r.name) else {
            return .failure(CardError("Ghostty 找不到 \(tty) 對應的分頁" + (Script.lastError.map { "（AppleScript：\($0)）" } ?? "")))
        }
        let id = Notify.quote(tid)
        let title = Script.string("tell application id \"com.mitchellh.ghostty\" to get name of (first terminal whose id is \"\(id)\")") ?? ""
        guard Handover.titleMatches(title, name: r.name) else {
            return .failure(CardError("Ghostty 分頁標題「\(title)」對不上 \(r.name)，不送"))
        }
        // 10-27：input text＝「貼上」，Claude Code 把貼上的 /clear 當一般訊息（Sam 收到「 /clear」）；斜線指令改用 Ghostty 的 text: 動作直接打進去
        let input = text.hasPrefix("/") ? "perform action \"text:\(Notify.quote(text))\" on t" : "input text \"\(Notify.quote(text))\" to t"
        let ok = Script.run("""
            tell application id "com.mitchellh.ghostty"
              set t to first terminal whose id is "\(id)"
              \(input)
              delay 0.15
              send key "enter" to t
              return "ok"
            end tell
            """)?.stringValue == "ok"
        return ok ? .success("ghostty") : .failure(CardError("Ghostty AppleScript 送字失敗"))
    }

    /// 標題開頭是這個英文名的 Ghostty 分頁；不是剛好一個就不認（寧可失敗也不送錯分頁）
    /// 開機自檢：看板能不能用 AppleScript 讀 Ghostty 分頁（讀不到＝自動 /clear 一定失敗，多半是沒給自動化權限）
    func selfCheck() {
        let n = Script.int("tell application id \"com.mitchellh.ghostty\" to count terminals")
        log(Script.lastError == nil ? "selfcheck Ghostty AppleScript OK（\(n ?? 0) 個分頁）" : "selfcheck Ghostty AppleScript 失敗：\(Script.lastError ?? "?")")
    }

    private static func uniqueTerminal(named name: String) -> String? {
        let out = Script.string("""
            tell application id "com.mitchellh.ghostty"
              set r to ""
              repeat with t in terminals
                set r to r & (id of t) & (character id 9) & (name of t) & linefeed
              end repeat
              return r
            end tell
            """) ?? ""
        let hits = out.split(separator: "\n").compactMap { l -> String? in
            let p = l.split(separator: "\t", maxSplits: 1).map(String.init)
            return p.count == 2 && Handover.titleMatches(p[1], name: name) ? p[0] : nil
        }
        return hits.count == 1 ? hits[0] : nil
    }

    private func fail(_ r: inout HandoverRecord, _ why: String) {
        r.state = .failed; r.note = why; r.notified = true
        log("failed \(r.name) \(r.sid.prefix(8)): \(why)")
        // 卡片標卡住（之後這張卡不再是 wrapup ⇒ 不會再自動送）
        let card = SelfReport(status: .blocked, summary: "自動 /clear 失敗：\(why)。請手動 /clear，新 context 會自動讀交接 \(r.handoff)",
                              doing: NicknameStore.get(r.sid)?.doing)
        let dir = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)
        if let d = try? BoardJSON.encoder.encode(card) { try? d.write(to: dir.appendingPathComponent(r.sid + ".json"), options: .atomic) }
        notify("\(who(r)) 自動 /clear 失敗", "請到它的終端機手動 /clear（\(why)）")
    }

    // MARK: 小工具

    /// 給 Keng 看的：職責，不放英文名
    private func who(_ r: HandoverRecord) -> String { SphereEmbed.label(r.sid)?.line ?? r.name }

    /// 一律寫 board/handover.log（Log.note 只在 SHOWORK_DEBUG 才寫）
    private func log(_ s: String) {
        Log.note("HANDOVER " + s)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let url = Paths.supportDir.appendingPathComponent("board/handover.log")
        let line = Data("\(f.string(from: Date())) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    private func currentSid(pid: Int32) -> String? {
        FileManager.default.contents(atPath: "\(BoardPaths.claude)/sessions/\(pid).json").flatMap(SessionRecord.decode)?.sessionId
    }
    private func ctxPercent(_ sid: String) -> Double? {
        guard let d = FileManager.default.contents(atPath: "\(BoardPaths.claude)/cache/ctx/\(sid).json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (o["used_percentage"] as? NSNumber)?.doubleValue
    }
    static func tty(of pid: Int32) -> String? {
        guard let info = ProcTree.kinfo(pid) else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != UInt32(bitPattern: -1), dev != 0, let n = devname(dev_t(dev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: n)
    }
    static func clock(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
    private func notify(_ title: String, _ body: String) {
        Notify.send(title, body)
    }
}
