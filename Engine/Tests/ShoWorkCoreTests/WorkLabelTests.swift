import Foundation
import Testing
@testable import ShoWorkCore

@Suite("WorkLabel")
struct WorkLabelTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let look = WorkLabels.Lookup(path: { $0 == "/r/Orbit42" || $0?.hasPrefix("/r/Orbit42/") == true ? "Orbit42" : nil },
                                 named: { ["Orbit42", "NFC42"].contains($0 ?? "") ? $0 : nil },
                                 mentioned: { $0.contains("github-repos/Orbit42") ? "Orbit42" : nil })
    func task(_ id: String, to sid: String, _ text: String, at: TimeInterval = 0, state: CaptainTask.State = .working, updated: TimeInterval? = nil) -> CaptainTask {
        CaptainTask(id: id, from: "cap", to: "X", toSession: sid, project: "labels", text: text, state: state, createdAt: t0 + at, updatedAt: t0 + (updated ?? at))
    }
    func one(_ sid: String, job: JobRecord? = nil, tasks: [CaptainTask] = [], cwd: String? = nil, captain: String? = nil, after: TimeInterval = 60) -> WorkLabel {
        WorkLabels.one(.init(sid: sid, cwd: cwd), captain: captain, job: job, tasks: tasks, now: t0 + after, look: look)
    }
    func card(_ args: String..., at: TimeInterval) -> SelfReport {
        guard case .success(let r) = SelfReport.parse(args: args, now: t0 + at) else { Issue.record("parse"); return SelfReport(status: .working) }
        return r
    }
    func record(_ rs: SelfReport..., project: String? = "Orbit42") -> JobRecord { var j = JobRecord(); for r in rs { j.apply(r, project: project) }; return j }

    @Test func mainProject() {
        let dirs: Set<String> = ["/h/r/Orbit42/.git", "/h/r/Orbit42/.claude/worktrees/captain-terminal/.git", "/h/r/ShoWork42/.git", "/h/r/_wt-ShoWork42-sphere/.git", "/h/r/Lone-wt/.git", "/h/r/Lone-wt"]
        let files = ["/h/r/_wt-ShoWork42-sphere/.git": "gitdir: /h/r/ShoWork42/.git/worktrees/_wt-ShoWork42-sphere\n", "/h/r/Lone-wt/.git": "gitdir: /h/r/NFC42/.git/worktrees/Lone-wt"]
        func n(_ p: String?) -> String? { MainProject.name(path: p, home: "/h", exists: { dirs.contains($0) }, read: { files[$0] }) }
        #expect(n("/h/r/Orbit42/Sources/Orbit42") == "Orbit42")
        #expect(n("/h/r/Orbit42/.claude/worktrees/captain-terminal/Engine") == "Orbit42")
        #expect(n("/h/r/_wt-ShoWork42-sphere/a") == "ShoWork42")
        #expect(n("/h/r/_wt-ShoWork42-gone") == "ShoWork42")                 // 資料夾刪了也認得
        #expect(n("/h/r/Lone-wt") == "NFC42")
        #expect(n("/h") == nil && n("/h/Desktop") == nil && n(nil) == nil)
        #expect(MainProject.name(named: "captain-terminal", repos: "/h/r", home: "/h", exists: { dirs.contains($0) }, read: { files[$0] }) == nil)
        #expect(MainProject.mentioned(in: "看 ~/nope/x 再到 ~/r/None、~/r/Lone-wt 開工", repos: "/h/r", home: "/h", exists: { dirs.contains($0) }, read: { files[$0] }) == "NFC42")
    }

    @Test func roleAndTitleFromText() {
        #expect(WorkRole.guess("【複核】【答案卡補修】看一下") == "複核" && WorkRole.guess("【複驗】x") == "複核" && WorkRole.guess("【名字標示固定化】x，最後請【複核】") == "修改")
        #expect(WorkTitle.guess("【複核】【答案卡補修】看一下") == "答案卡補修")
        #expect(WorkTitle.guess("【複驗：額度面板】x") == "額度面板")
        #expect(WorkTitle.guess("【名字標示固定化】Keng 定案") == "名字標示固定化")
        #expect(WorkTitle.guess("【使用者從網頁戰情中心】修按鈕") == "修按鈕")
        #expect(WorkTitle.guess("【複核】") == "沒寫標題的工作")
        #expect(WorkTitle.guess(String(repeating: "字", count: 30)).count == 14)
        #expect(WorkTitle.clean("a\u{1B}]0;x\u{07}\nb") == "a ]0;x  b")
    }

    @Test func taskPinsLinesAndCdDoesNotChange() {
        let t = task("T1", to: "s", "【名字標示固定化】在 ~/github-repos/Orbit42 開新 worktree")
        for cwd in ["/h", "/r/NFC42", "/r/Orbit42/.claude/worktrees/labels"] {
            let l = one("s", tasks: [t], cwd: cwd)
            #expect(l.head == "修改 · Orbit42" && l.work == "名字標示固定化")
        }
        var x = t; x.role = "設計"; x.title = "新版面"; x.mainProject = "NFC42"
        #expect(one("s", tasks: [x]).line == "設計 · NFC42｜新版面")
    }

    @Test func homeSessionWithoutProject() {
        #expect(one("s", tasks: [task("T1", to: "s", "【整理信箱】")], cwd: "/h").head == "修改 · 未歸專案")
        #expect(one("s").head == "修改 · 未歸專案" && one("s").work == "待命")
        #expect(one("s", cwd: "/r/Orbit42").head == "修改 · Orbit42")
    }

    @Test func reportsNeverChangeTitleOnlyNewJobDoes() {
        var j = record(card("--kind", "start", "--doing", "手機Chrome網頁", at: 0))
        j.apply(card("--doing", "改別的字", "--status", "working", at: 10), project: "NFC42")
        j.apply(card("--doing", "補修", "--status", "review", "--ask", "好嗎", at: 20), project: "NFC42")
        #expect(one("s", job: j).line == "修改 · Orbit42｜手機Chrome網頁")
        j.apply(card("--kind", "start", "--role", "研究", "--doing", "查 API", at: 30), project: "NFC42")
        #expect(one("s", job: j).line == "研究 · NFC42｜查 API")                // 換單馬上換
        j.apply(card("--kind", "start", "--doing", "舊的晚到", at: 5), project: nil)
        #expect(j.job?.title == "查 API")
        let t = task("T1", to: "s", "【新派的】~/github-repos/Orbit42", at: 40)
        #expect(one("s", job: j, tasks: [t]).work == "新派的")
        j.apply(card("--task", "T1", "--doing", "第一輪", "--status", "working", at: 50), project: "Orbit42")
        j.apply(card("--kind", "start", "--task", "T1", "--doing", "補修二", at: 55), project: "Orbit42")
        #expect(one("s", job: j, tasks: [t]).work == "新派的")                   // 單子自己的開工卡不另開一張
    }

    @Test func doneFadesThenIdleAndReopens() {
        var j = record(card("--kind", "start", "--doing", "修按鈕", at: 0), card("--status", "done", at: 100))
        #expect(one("s", job: j, after: 100 + 599).work == "完成：修按鈕" && one("s", job: j, after: 100 + 599).state == .done)
        let idle = one("s", job: j, after: 100 + 601)
        #expect(idle.work == "待命" && idle.head == "修改 · Orbit42")
        #expect(one("s", job: j, tasks: [task("T", to: "s", "【下一件】", at: 150)], after: 160).work == "下一件")      // 被派新單馬上換
        j.apply(card("--status", "working", "--doing", "補修", at: 300), project: nil)
        #expect(one("s", job: j, after: 310).work == "修按鈕")                    // 補修：標題不變、不再是完成
        let d = task("T", to: "s", "【派的】", state: .done, updated: 50)
        #expect(one("s", tasks: [d], after: 60).work == "完成：派的" && one("s", tasks: [d], after: 700).work == "待命")
        #expect(one("s", tasks: [task("T", to: "s", "【派的】", state: .cancelled)]).work == "待命")
        #expect(one("s", tasks: [task("T", to: "s", "【派的】", state: .blocked)]).work == "派的" && one("s", tasks: [task("T", to: "s", "【派的】", state: .review)]).work == "派的")
        // 新的做完、舊的單還開著 ⇒ 10 分鐘後回到舊單；只是等你看過的舊單不回來
        let old = task("O", to: "s", "【舊單】", at: -500)
        #expect(one("s", job: record(card("--kind", "start", "--doing", "插隊", at: 0), card("--status", "done", at: 10)), tasks: [old], after: 700).work == "舊單")
        #expect(one("s", job: record(card("--kind", "start", "--doing", "插隊", at: 0), card("--status", "done", at: 10)), tasks: [task("O", to: "s", "【舊單】", at: -500, state: .review)], after: 700).work == "待命")
        #expect(one("s", job: record(card("--kind", "start", "--doing", "問一下", at: 0), card("--status", "done", "--ask", "要嗎", at: 10))).work == "問一下")
    }

    @Test func secretaryAlways() {
        let l = one("cap", tasks: [task("T", to: "cap", "【複核】【看】")], captain: "cap")
        #expect(l.role == "秘書")
        guard case .failure = SelfReport.parse(args: ["--kind", "start", "--role", "秘書", "--doing", "x"]) else { Issue.record("秘書不能自己填"); return }
    }

    @Test func collisionsKeepNumbersWhileOnline() {
        func tk(_ s: String, _ at: TimeInterval, _ st: CaptainTask.State = .working) -> CaptainTask { task("T" + s, to: s, "【複核】【同一件】~/github-repos/Orbit42", at: at, state: st, updated: at + 1) }
        func res(_ sids: [String], _ ts: [CaptainTask], _ n: [String: WorkLabels.Number] = [:]) -> (labels: [String: WorkLabel], numbers: [String: WorkLabels.Number]) {
            WorkLabels.resolve(sids.map { .init(sid: $0) }, captain: nil, jobs: [:], tasks: ts, numbers: n, now: t0 + 60, look: look)
        }
        let a = res(["b", "a"], [tk("a", 20), tk("b", 10)])
        #expect(a.labels["b"]?.head == "複核 1 · Orbit42" && a.labels["a"]?.head == "複核 2 · Orbit42")
        let gone = res(["a"], [tk("a", 20)], a.numbers)
        #expect(gone.labels["a"]?.head == "複核 2 · Orbit42")                    // 另一個走了，編號不變
        let c = res(["a", "c"], [tk("a", 20), tk("c", 5)], gone.numbers)
        #expect(c.labels["a"]?.number == 2 && c.labels["c"]?.number == 1)
        let done = res(["a", "c"], [tk("a", 20, .done), tk("c", 5)], c.numbers)
        #expect(done.labels["a"]?.head == "複核 2 · Orbit42" && done.labels["a"]?.work == "完成：同一件")
        #expect(res(["a", "b"], [tk("a", 1), task("T", to: "b", "【複核】【別件】~/github-repos/Orbit42")]).labels["a"]?.number == nil)   // 第二行不同就不編
    }

    @Test func orderIsStable() {
        func l(_ r: String, _ p: String, _ at: TimeInterval, _ s: WorkLabel.State = .open) -> WorkLabel { WorkLabel(role: r, project: p, title: "x", state: s, at: t0 + at) }
        let xs: [(sid: String, label: WorkLabel?)] = [("1", l("修改", "未歸專案", 0)), ("2", l("修改", "Orbit42", 9)), ("3", l("複核", "NFC42", 5)), ("4", l("秘書", "未歸專案", 99)), ("5", l("修改", "Orbit42", 3, .done))]
        #expect(xs.sorted { WorkLabels.before($0, $1) }.map(\.sid) == ["4", "3", "5", "2", "1"])
    }

    @Test func clearAndResume() {
        let p = ProcStamp(pid: 10, start: 1), q = ProcStamp(pid: 11, start: 1)
        var old = record(card("--kind", "start", "--doing", "修按鈕", at: 0)); old.proc = p
        // /clear：同一個程序換 sessionId ⇒ 標題跟著走，舊單也認得
        let (n, ch) = JobStore.plan(["old": old], sid: "new", source: "clear", proc: p, project: "NFC42")
        #expect(n.job?.title == "修按鈕" && n.prev == ["old"] && n.proc == p && ch["old"]?.proc == nil)
        #expect(one("new", job: n, tasks: [task("T", to: "old", "【派給舊的】", at: 5)]).work == "派給舊的")
        // 別的程序、/resume、新開的都不接
        #expect(JobStore.plan(["old": old], sid: "new", source: "clear", proc: q, project: nil).0.job == nil)
        #expect(JobStore.plan(["old": old], sid: "new", source: "resume", proc: p, project: nil).0.job == nil)
        #expect(JobStore.plan(["old": old], sid: "new", source: "startup", proc: q, project: "NFC42").0.last == "NFC42")
        // /resume 到別的對話再 /clear：接的是那段對話，不是原本那件
        let (r, ch2) = JobStore.plan(["old": old], sid: "other", source: "resume", proc: p, project: nil)
        var all = ["old": old, "other": r]; for (k, v) in ch2 { all[k] = v }
        #expect(JobStore.plan(all, sid: "new2", source: "clear", proc: p, project: nil).0.job == nil)
    }

    @Test func relayLegHasItsOwnRole() {
        var t = task("T1", to: "s", "【修按鈕】x", state: .done); t.thenTo = "Y"; t.thenText = "【複核】【按鈕】看前一棒"; t.mainProject = "Orbit42"
        let n = Captain.nextLeg(of: t, id: "T2", now: t0)
        #expect(n?.role == "複核" && n?.title == "按鈕" && n?.mainProject == "Orbit42")
        t.thenRole = "測試"; t.thenTitle = "跑機器"
        #expect(Captain.nextLeg(of: t, id: "T2", now: t0)?.role == "測試" && Captain.nextLeg(of: t, id: "T2", now: t0)?.title == "跑機器")
    }

    @Test func oldFilesStillDecode() throws {
        let t = try BoardJSON.decoder.decode(CaptainTask.self, from: Data(#"{"id":"T1","from":"c","to":"Hana","toSession":"s","project":"captain-terminal","text":"【複驗】【答案卡】x","state":"working","createdAt":"2026-11-24T10:00:00.000Z","updatedAt":"2026-11-24T10:00:00.000Z"}"#.utf8))
        let l = WorkLabels.one(.init(sid: "s", cwd: "/r/Orbit42/.claude/worktrees/captain-terminal"), captain: nil, job: nil, tasks: [t], now: t.createdAt, look: look)
        #expect(l.line == "複核 · Orbit42｜答案卡")                              // 舊單的 worktree 名不上畫面
        var j = JobRecord(); j.apply(SelfReport(status: .working, doing: "升級前在做的", at: t0), project: "Orbit42", legacy: true)
        #expect(j.job?.title == "升級前在做的")
        var k = JobRecord(); k.apply(SelfReport(status: .working, doing: "沒發開工卡", at: t0), project: nil)
        #expect(k.job == nil)
    }

    @Test func rosterKeepsEnglishAddress() {
        var c = BoardCard(id: "s", column: .active, reason: "", project: "labels", title: "x", pid: 1, sessionId: "s", name: "Vera4")
        c.set(one("s", tasks: [task("T1", to: "s", "【名字標示固定化】~/github-repos/Orbit42")]))
        let e = Captain.roster([c], captain: nil, now: t0).entries[0]
        #expect(e.name == "Vera4" && e.label == "修改 · Orbit42" && c.display == "修改 · Orbit42｜名字標示固定化")
        #expect(!Nicknames.terminalTitle(Nickname(name: "Vera4", doing: "y"), done: false, label: c.display).contains("Vera4"))
        #expect(Nicknames.hookOutput(Nickname(name: "Vera4"), done: false, event: "UserPromptSubmit", label: c.display).contains(#""sessionTitle":"Vera4""#))
    }
}
