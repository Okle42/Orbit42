import Foundation
import JavaScriptCore
import Testing
@testable import ShoWorkCore

/// 11-10 秘書省額度：只推要秘書動手的事（工作回報、巡檢、開工卡、換哨提醒）
@Suite("CaptainQuiet")
struct CaptainQuietTests {
    let t0 = Date(timeIntervalSince1970: 1_792_500_000)
    let txt: (String, SelfReport) -> String = { sid, r in "\(sid):\(r.summary ?? "")" }
    func card(_ s: SelfReport.Status, _ summary: String, at: Date, ask: String? = nil) -> SelfReport {
        var r = SelfReport(status: s, progress: 50, confidence: 70, summary: summary, doing: "做事", at: at)
        r.ask = ask
        return r
    }

    @Test("工作回報：預設只推 review／blocked／帶 --ask；done、working 只記不推（之後也不補送）")
    func actionableOnly() {
        var st = CardRelay.State(); st.seeded = true
        let quiet = CardRelay.plan(reports: ["w": card(.working, "做事中", at: t0), "d": card(.done, "做完", at: t0),
                                             "r": card(.review, "要審", at: t0), "b": card(.blocked, "卡住", at: t0),
                                             "q": card(.working, "問一下", at: t0, ask: "要 push 嗎")],
                                   captain: "cap", captainLive: true, state: &st, now: t0, text: txt)
        #expect(Set(quiet.map(\.sessionId)) == ["r", "b", "q"])
        // done／working 已記成看過：同一張卡之後不會補送
        #expect(CardRelay.plan(reports: ["w": card(.working, "做事中", at: t0), "d": card(.done, "做完", at: t0)],
                               captain: "cap", captainLive: true, state: &st, now: t0 + 120, text: txt).isEmpty)
        // 同一個人改成卡住 ⇒ 推
        #expect(CardRelay.plan(reports: ["w": card(.blocked, "卡住了", at: t0 + 130)],
                               captain: "cap", captainLive: true, state: &st, now: t0 + 130, text: txt).map(\.sessionId) == ["w"])
    }

    @Test("開關改回舊行為：done／working 照推")
    func legacy() {
        var st = CardRelay.State(); st.seeded = true
        let out = CardRelay.plan(reports: ["w": card(.working, "x", at: t0), "d": card(.done, "y", at: t0)],
                                 captain: "cap", captainLive: true, state: &st, now: t0, policy: .legacy, text: txt)
        #expect(out.count == 2)
    }

    @Test("開工卡：只進收件匣，不推（舊行為開關打開也不推）")
    func startCards() {
        let start = SelfReport(status: .working, summary: "改按鈕", doing: "改按鈕", kind: "start", at: t0)
        for p in [CardRelay.Policy.quiet, .legacy] {
            var st = CardRelay.State(); st.seeded = true
            #expect(CardRelay.plan(reports: ["a": start], captain: "c", captainLive: true, state: &st, now: t0, policy: p, text: txt).isEmpty)
        }
    }

    @Test("同一張卡只推一次；問題從無到有、文字或選項改了一定推；拿掉問題或同題重發不推")
    func dedupe() {
        var st = CardRelay.State(); st.seeded = true
        var now = t0
        func push(_ ask: String?, _ options: [String]? = nil, how: String? = nil, summary: String = "卡住") -> Bool {
            var r = card(.blocked, summary, at: now, ask: ask); r.options = options; r.how = how
            defer { now += 70 }
            return !CardRelay.plan(reports: ["a": r], captain: "c", captainLive: true, state: &st, now: now, text: txt).isEmpty
        }
        #expect(push(nil))
        #expect(!push(nil) && !push(nil, how: "換了方法"))
        #expect(push("要 push 嗎"))
        #expect(!push("要 push 嗎") && !push(nil))
        #expect(push("要 push 嗎"))                    // 有→無→同題再問：第三張要推
        #expect(!push("要 push 嗎") && !push("要 push 嗎"))       // 完全重複仍只推一次
        #expect(push("要部署嗎"))
        #expect(push("要部署嗎", ["好", "不要"]))
        #expect(!push(nil))
        #expect(push(nil, summary: "又卡住"))
        #expect(push("要部署嗎", ["好", "不要"], summary: "又卡住"))       // 換了一張卡，同一題也算新的
    }

    @Test("巡檢：跟上次一樣不推，App 重開後也不重推；時間、ctx 數字變動不算")
    func alarmRepeat() throws {
        let block = CaptainInboxItem(id: "BAAAA", kind: .block, at: t0 - 60, sid: "x", name: "x", project: nil, kinds: ["rm"], text: "rm")
        func act(_ tokens: Int, _ now: Date, _ inbox: [CaptainInboxItem]) -> (reasons: [String], sig: String) {
            CaptainLink.alarmActions(Roster(at: now, captain: "cap", entries: [entry("滿滿", tokens: tokens)]), openTaskSessions: [], inbox: inbox, ctxLimit: 250_000, now: now)
        }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("alarm-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: f) }
        let a = act(300_000, t0, [block])
        #expect(CaptainLink.alarmShouldPush(reasons: a.reasons, sig: a.sig, last: CaptainLink.loadAlarmSig(f)))
        CaptainLink.saveAlarmSig(a.sig, f)
        let b = act(420_000, t0 + 1800, [block])
        #expect(!CaptainLink.alarmShouldPush(reasons: b.reasons, sig: b.sig, last: CaptainLink.loadAlarmSig(f)))
        var b2 = block; b2.id = "BBBBB"
        let c = act(420_000, t0 + 1800, [block, b2])
        #expect(CaptainLink.alarmShouldPush(reasons: c.reasons, sig: c.sig, last: CaptainLink.loadAlarmSig(f)))
    }

    @Test("改名秘書：新舊地址都收得到；舊職稱顯示成秘書；LINE 秘書不混；新 session 不會叫 Ethan")
    func secretary() {
        let ss: [(String, String?)] = [("cap-1", "Ethan9"), ("b-2", "Bella")], nick = ["cap-1": "Zack", "b-2": "Bella"]
        for who in ["秘書", "隊長", "Ethan"] { #expect(ShortName.match(who, among: ss, nick: nick, captain: "cap-1") == ["cap-1"]) }
        #expect(ShortName.match("LINE 秘書", among: ss, nick: nick, captain: "cap-1").isEmpty)
        #expect(ShortName.match("秘書", among: ss, nick: nick, captain: "gone").isEmpty)
        #expect(ShortName.match("Ethan", among: ss + [("e-3", "Ethan")], nick: nick, captain: "cap-1") == ["e-3"])      // 真有人叫這個名字就是他
        var n = Nickname(name: "Ethan"); n.role = "隊長"
        #expect(Nicknames.label(n, project: "x") == "秘書")
        #expect(!Nicknames.pool.contains("Ethan"))
        for x in ["Ethan", "Ethan9"] { #expect(Nicknames.isRetired(x)) }
        for x in ["Ethan-x", "Ethanol", "秘書", "Dora", ""] { #expect(!Nicknames.isRetired(x)) }
        #expect(Nicknames.inherited(Data(#"{"type":"custom-title","customTitle":"Ethan"}"#.utf8)) == "Ethan")
        #expect(CaptainThread.boardText("\(CaptainThread.boardPrefix)修球\n請照隊長守則處理") == "修球")
        #expect(!Captain.manual(showork: "s").contains("隊長") && !CaptainLaunch.bootstrap(showork: "s", task: "t").contains("隊長"))
    }

    @Test("設定讀取：沒設過＝新行為；設了照設定")
    func policyFromDefaults() throws {
        let name = "showork.test.quiet.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        #expect(CardRelay.Policy.from(d) == .quiet)
        d.set(false, forKey: CardRelay.Policy.actionableKey)
        #expect(CardRelay.Policy.from(d) == .legacy)
        #expect(CaptainLink.captainCtxLimit(d) == 750_000)
        d.set(400_000, forKey: CaptainLink.captainCtxKey)
        #expect(CaptainLink.captainCtxLimit(d) == 400_000)
        d.set(-1, forKey: CaptainLink.captainCtxKey)
        #expect(CaptainLink.captainCtxLimit(d) == nil)
    }

    func entry(_ n: String, column: BoardColumn = .done, tokens: Int? = nil, idle: Double = 60, cap: Bool = false, handover: String? = nil) -> RosterEntry {
        RosterEntry(name: n, sessionId: n, pid: 1, kind: nil, project: "專案A", root: nil, column: column, reason: "", title: "", summary: nil,
                    ctx: nil, ctxTokens: tokens, lastActivity: t0 - idle, captain: cap, sameProject: [], handover: handover)
    }

    @Test("巡檢：沒事＝空（不推）；閒置但沒派工單不算；開工卡不算")
    func alarmNothing() {
        let r = Roster(at: t0, captain: "秘書", entries: [entry("小明"), entry("阿華", idle: 7200), entry("秘書", tokens: 900_000, cap: true)])
        let start = CaptainInboxItem(id: "SAAAA", kind: .start, at: t0 - 60, sid: "小明", name: "小明", project: nil, text: "開工")
        let a = CaptainLink.alarmActions(r, openTaskSessions: [], inbox: [start], ctxLimit: 250_000, now: t0)
        #expect(a.reasons.isEmpty)
        #expect(a.sig == "")
    }

    @Test("巡檢：卡住、待審、ctx 到門檻、有派工單閒太久、擋下都算，預告不算；同一批指紋不變")
    func alarmActionable() {
        let r = Roster(at: t0, captain: "秘書", entries: [
            entry("卡卡", column: .stuck), entry("審審", column: .review), entry("滿滿", tokens: 300_000),
            entry("收好", tokens: 300_000, handover: "已收尾待 /clear"), entry("閒閒", idle: 7200), entry("秘書", cap: true)])
        let block = CaptainInboxItem(id: "BAAAA", kind: .block, at: t0 - 60, sid: "x", name: "x", project: nil, kinds: ["rm"], text: "rm -rf")
        let notice = CaptainInboxItem(id: "NAAAA", kind: .notice, at: t0 - 60, sid: "x", name: "x", project: nil, kinds: ["mv"], text: "mv")
        var acked = notice; acked.id = "NBBBB"; acked.acked = t0
        let a = CaptainLink.alarmActions(r, openTaskSessions: ["閒閒"], inbox: [block, notice, acked], ctxLimit: 250_000, now: t0)
        let all = a.reasons.joined(separator: "；")
        for k in ["卡住：卡卡", "待審／等回答：審審", "ctx 到門檻 250k：滿滿 300k", "閒置超過 30 分鐘：閒閒", "擋下等放行 1 則：BAAAA"] {
            #expect(all.contains(k))
        }
        #expect(!all.contains("預告"))
        #expect(!all.contains("收好"))          // 已收尾的交給自動 /clear，不算
        #expect(CaptainLink.alarmActions(r, openTaskSessions: ["閒閒"], inbox: [block, notice], ctxLimit: 250_000, now: t0 + 30).sig == a.sig)
        // 放行了 ⇒ 指紋變
        var rel = block; rel.released = t0
        #expect(CaptainLink.alarmActions(r, openTaskSessions: ["閒閒"], inbox: [rel, notice], ctxLimit: 250_000, now: t0).sig != a.sig)
        let text = CaptainLink.alarmQuietText(reasons: a.reasons, full: "【巡檢時間】在線 5 人")
        #expect(text.hasPrefix("【巡檢時間】要處理：卡住：卡卡"))
        #expect(text.hasSuffix("\n在線 5 人"))
    }

    @Test("球體口令：隊長、秘書都認；LINE 秘書不當成交辦前綴（直接跑 sphere.html 裡的規則）")
    func sphereCommand() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let html = try String(contentsOf: root.appendingPathComponent("windows/ShoWork.Win/Board/Web/sphere.html"), encoding: .utf8)
        func rule(_ before: String, _ after: String) throws -> String {
            let a = try #require(html.range(of: before)), b = try #require(html.range(of: after, range: a.upperBound..<html.endIndex))
            return String(html[a.upperBound..<b.lowerBound])
        }
        let test = "/^(交給" + (try rule("const local = /^(交給", ".test(text)")), strip = try rule("const order = text.replace(", #", "")"#)
        #expect(html.contains("announce(`交給秘書：${clip(order, 40)}`)"))      // 播報唸去掉前綴的內容，不會把「交給隊長」唸出來
        let js = try #require(JSContext())
        func run(_ t: String) -> (hit: Bool, text: String) {
            js.setObject(t, forKeyedSubscript: "t" as NSString)
            return (js.evaluateScript("\(test).test(t)").toBool(), js.evaluateScript("t.replace(\(strip), '') || t").toString())
        }
        for who in ["秘書", "隊長"] {
            let r = run("交給\(who)，修球體")
            #expect(r.hit && r.text == "修球體")
            #expect(run("請\(who)說：看額度").text == "看額度")
        }
        for t in ["請 LINE 秘書傳訊息", "交給LINE 秘書回覆", "修球體"] {
            let r = run(t)
            #expect(!r.hit && r.text == t)
        }
    }

    @Test("秘書 /clear：同一程序才接上；別的 session、/resume、pid 重用、舊登記都不接")
    func followClear() throws {
        let me = ProcStamp(pid: 100, start: 5), c = CaptainRecord(sessionId: "old", name: "秘書", proc: me)
        func go(_ c: CaptainRecord, _ sid: String = "new", _ source: String? = "clear", _ p: ProcStamp?, _ others: Set<String> = []) -> CaptainRecord? {
            CaptainStore.afterClear(c, newSid: sid, source: source, proc: p, others: others)
        }
        let n = try #require(go(c, "new", "clear", me, ["別人"]))
        #expect(n.sessionId == "new" && n.name == "秘書" && n.proc == me)
        #expect(go(n, "new2", "clear", me)?.sessionId == "new2")                      // 再 /clear 一次也接得上
        #expect(go(c, "new", "clear", ProcStamp(pid: 101, start: 5)) == nil)          // 別的 session 的 /clear
        #expect(go(c, "new", "clear", ProcStamp(pid: 100, start: 9)) == nil)          // pid 被重用
        #expect(go(c, "new", "clear", nil) == nil)
        for s in ["startup", "resume", "compact", nil] as [String?] { #expect(go(c, "new", s, me) == nil) }
        #expect(go(c, "new", "clear", me, ["old"]) == nil)                            // 舊對話在別的程序開著：認不準，不接
        #expect(go(c, "new", "clear", me, ["new"]) == nil)                            // 新 id 是別人的
        #expect(go(CaptainRecord(sessionId: "old", name: nil), "new", "clear", me) == nil)   // 沒記程序的舊登記
        // Gavin5：登記 A4 → 同程序 /resume 到 OTHER ⇒ 清掉程序 ⇒ OTHER 打 /clear 接不上；回到 A4 補回後接得上
        #expect(CaptainStore.leaves(c, sid: "OTHER", source: "resume", proc: me) && CaptainStore.leaves(c, sid: "OTHER", source: nil, proc: me))
        #expect(!CaptainStore.leaves(c, sid: "old", source: "resume", proc: me) && !CaptainStore.leaves(c, sid: "new", source: "clear", proc: me))
        #expect(!CaptainStore.leaves(c, sid: "x", source: "startup", proc: ProcStamp(pid: 101, start: 5)))       // 別的 session 開起來不影響
        var left = c; left.proc = nil
        #expect(go(left, "new", "clear", me) == nil)
        left.proc = me
        #expect(go(left, "new", "clear", me)?.sessionId == "new")
        let old = try BoardJSON.decoder.decode(CaptainRecord.self, from: Data(#"{"sessionId":"a","name":"Ethan","at":"2026-11-24T11:06:56.386Z"}"#.utf8))
        #expect(old.proc == nil)
        let now = try #require(ProcStamp.of(getpid()))
        #expect(ProcStamp.of(getpid()) == now && ProcStamp.of(getppid()) != now && ProcStamp.of(nil) == nil)
        #expect(try BoardJSON.decoder.decode(CaptainRecord.self, from: BoardJSON.encoder.encode(CaptainRecord(sessionId: "a", name: nil, proc: now))).proc == now)
    }

    @Test("換哨提醒：秘書 ctx 過門檻送一次；降下來重新計；組員不算")
    func shift() {
        func roster(_ t: Int) -> Roster { Roster(at: t0, captain: "秘書", entries: [entry("秘書", tokens: t, cap: true), entry("小明", tokens: 999_000)]) }
        let a = CaptainLink.shiftReminder(roster(700_000), limit: 750_000, sent: [], owner: "Boss", handoff: "交接.md")
        #expect(a.text == nil && a.sent.isEmpty)
        let b = CaptainLink.shiftReminder(roster(760_000), limit: 750_000, sent: a.sent, owner: "Boss", handoff: "交接.md")
        let t = b.text ?? ""
        #expect(t.hasPrefix("【換哨提醒】秘書 context 已用 760k（門檻 750k）"))
        #expect(t.contains("交接.md") && t.contains("請Boss在這個視窗打 /clear，再說「換哨」"))
        #expect(b.sent == ["秘書"])
        #expect(CaptainLink.shiftReminder(roster(800_000), limit: 750_000, sent: b.sent, owner: "Boss", handoff: "x").text == nil)
        let c = CaptainLink.shiftReminder(roster(10_000), limit: 750_000, sent: b.sent, owner: "Boss", handoff: "x")
        #expect(c.sent.isEmpty)
        #expect(CaptainLink.shiftReminder(roster(900_000), limit: nil, sent: [], owner: "Boss", handoff: "x").text == nil)
    }

    @Test("秘書守則文字跟著改：開工卡不推、巡檢沒事不送、換哨提醒")
    func manual() {
        let m = Captain.manual(showork: "/x/showork")
        #expect(m.contains("只進你的收件匣、不推給你"))
        #expect(m.contains("沒事不送"))
        #expect(m.contains("【換哨提醒】"))
        #expect(m.contains("做完、做事中的卡只記在看板"))
        #expect(!m.contains("無變化"))
    }

    @Test("本機設定的秘書交接文件：沒設用通用說法")
    func handoffName() {
        #expect(LocalConfig().captainHandoffName == "秘書交接文件")
        var c = LocalConfig(); c.captainHandoff = "~/交接.md"
        #expect(c.captainHandoffName == "~/交接.md")
    }
}
