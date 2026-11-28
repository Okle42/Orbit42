import Foundation
import Testing
@testable import Orbit42Core

// 11-28 別處處理完自動撤題（StaleAsks.swift）。假 session、假專案、假 commit（10-22 規矩）
@Suite("別處處理完自動撤題：派工單結束、已進 main／已裝")
struct StaleAsksTests {
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    func ask(_ id: String, _ text: String, task: String? = nil, at: Date? = nil) -> PendingAsk {
        var q = PendingAsk(id: id, ask: text, options: ["好", "先不要"], at: at ?? now.addingTimeInterval(-600))
        q.task = task
        return q
    }
    func task(_ id: String, _ state: CaptainTask.State, to sid: String = "S1", updated: Date? = nil) -> CaptainTask {
        CaptainTask(id: id, from: "CAP", to: "組員甲", toSession: sid, text: "做某件事", state: state, createdAt: now.addingTimeInterval(-7200), updatedAt: updated ?? now)
    }

    // MARK: ① 派工單完成／取消

    @Test("完成、取消的單：撤掉那個 session 帶這張單號的題；別張單、沒單號、還在進行的單不動")
    func closedTask() {
        var pick = ask("Q5", "勾選放行", task: "T1"); pick.action = ReleasePick.action
        let asks = ["S1": [ask("Q1", "要不要寄出報告？", task: "T1"), ask("Q2", "用哪個版本？", task: "T2"), ask("Q3", "隨便問", task: nil), pick],
                    "S2": [ask("Q4", "要不要寄出報告？", task: "T3")]]
        let hits = StaleAsks.closedTasks(asks: asks, tasks: [task("T1", .done), task("T2", .working), task("T3", .cancelled, to: "S2")])
        #expect(Set(hits.map(\.ask.id)) == ["Q1", "Q4"])
        #expect(hits.first { $0.ask.id == "Q4" }?.why == .taskClosed(task: "T3", state: .cancelled))
    }

    @Test("單子結束之後才問的新題不撤（同一張單又冒出的新問題）")
    func askAfterClose() {
        let asks = ["S1": [ask("Q1", "新問題？", task: "T1", at: now.addingTimeInterval(60))]]
        #expect(StaleAsks.closedTasks(asks: asks, tasks: [task("T1", .cancelled)]).isEmpty)
    }

    // MARK: ② 是不是在問要不要 push／併／裝

    @Test("在問要不要 push／併／裝")
    func asking() {
        #expect(StaleAsks.shipVerbs("要不要 push 1b1dab2？") == [.push])
        #expect(StaleAsks.shipVerbs("要把 dora2/release-all 併進 main 嗎？") == [.merge])
        #expect(StaleAsks.shipVerbs("要裝 1b1dab2 嗎") == [.install])
        #expect(StaleAsks.shipVerbs("要不要 push／併？") == [.push, .merge])
        #expect(StaleAsks.shipVerbs("改好了，可以 merge 分支 fix-x 嗎") == [.merge])
    }

    @Test("誤撤：只是提到 commit、push，不是在問要不要做")
    func notAsking() {
        #expect(StaleAsks.shipVerbs("1b1dab2 之後晨報會當掉，要先修晨報還是先做搜尋？").isEmpty)
        #expect(StaleAsks.shipVerbs("已把 1b1dab2 推上 GitHub，接下來做 B 組嗎？").isEmpty)
        #expect(StaleAsks.shipVerbs("要換裝置測嗎？").isEmpty)
        #expect(StaleAsks.shipVerbs("推薦用哪個版本？").isEmpty)
        #expect(StaleAsks.shipVerbs("main 3b97f08 的測試結果要寄給誰？").isEmpty)
    }

    @Test("解析 commit 與分支：日期、英文字、檔名、網址不算")
    func parse() {
        #expect(StaleAsks.commits(in: "併 1b1dab2 跟 3B97F08，20261128 那天，deadbee 不算") == ["1b1dab2"])
        #expect(StaleAsks.branches(in: "push dora2/release-all 跟 origin/sprint/w1，改了 Sources/Orbit42/Foo.swift，見 https://x.com/a/b") == ["dora2/release-all", "sprint/w1"])
        #expect(StaleAsks.branches(in: "要不要 push 分支 fix-login？") == ["fix-login"])
        #expect(StaleAsks.branches(in: "要不要 push 分支，交給別人併？").isEmpty)
    }

    @Test("T1128155212：短雜湊剛好全是數字／全是字母，repo 查得到就認；查不到的日期、英文字不擋整題")
    func weakHashes() {
        for h in ["1234567", "2026112", "abcdeff"] {
            let g = git { $0.refs[h] = "H"; $0.refs["INST"] = "I"; $0.inside = ["H>I"] }
            #expect(StaleAsks.shipped(ask("Q1", "要裝 \(h) 嗎？"), card: nil, cwd: "/repo", installed: "INST", git: g) != nil, "\(h)")
        }
        // 20261128 是日期、查不到 ⇒ 當沒寫；1b1dab2 照樣判斷
        let g = git { $0.refs["1b1dab2"] = "H1"; $0.inside = ["H1>OM"] }
        #expect(StaleAsks.shipped(ask("Q2", "20261128 改的 1b1dab2 要不要 push？"), card: nil, cwd: "/repo", installed: nil, git: g) != nil)
        // 只有日期、查不到：沒有 commit 可查 ⇒ 不撤
        #expect(StaleAsks.shipped(ask("Q3", "20261128 那版要不要 push？"), card: nil, cwd: "/repo", installed: nil, git: g) == nil)
    }

    // MARK: ② 查 git（假的）

    struct FakeGit: StaleAsks.Git {
        var refs: [String: String] = ["main": "M", "origin/main": "OM"]
        var inside: Set<String> = []           // "hash>base"：hash 在 base 裡
        var branch: String? = nil
        var isClean = true
        var noCommits: Set<String> = []
        func toplevel(_ path: String) -> String? { path.hasPrefix("/repo") ? "/repo" : nil }
        func resolve(_ repo: String, _ ref: String) -> String? { refs[ref] }
        func isAncestor(_ repo: String, _ a: String, _ b: String) -> Bool { a == b || inside.contains("\(a)>\(b)") }
        func currentBranch(_ repo: String) -> String? { branch }
        func clean(_ repo: String) -> Bool { isClean }
        func hasOwnCommits(_ repo: String, _ b: String) -> Bool { !noCommits.contains(b) }
        func landing(_ repo: String, _ hash: String, on base: String) -> StaleAsks.Landing? { .init(hash: "3b97f08aaaa", who: "秘書", at: now) }
        let now = Date(timeIntervalSince1970: 1_793_000_000)
    }

    func git(_ f: (inout FakeGit) -> Void) -> FakeGit { var g = FakeGit(); f(&g); return g }

    @Test("問 push 的 commit 已在 origin/main ⇒ 撤，看板記「已在別處處理（誰、何時）」")
    func pushedCommit() throws {
        let g = git { $0.refs["1b1dab2"] = "H1"; $0.inside = ["H1>OM", "H1>M"] }
        let why = try #require(StaleAsks.shipped(ask("Q1", "要不要 push 1b1dab2？"), card: nil, cwd: "/repo/x", installed: nil, git: g))
        guard case .shipped(let ref, let d, let by, _) = why else { Issue.record("不是 shipped"); return }
        #expect(ref == "1b1dab2" && by == "秘書" && d.contains("origin/main") && d.contains("3b97f08") && d.contains("已推上"))
        let note = StaleAsks.boardNote(.init(sid: "S1", ask: ask("Q1", "x"), why: why))
        #expect(note.hasPrefix("已在別處處理（秘書，") && note.contains("1b1dab2"))
    }

    @Test("誤撤：commit 還沒進 main、查不到、只進本機 main 卻問 push ⇒ 不撤")
    func notShipped() {
        let q = ask("Q1", "要不要 push 1b1dab2？")
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: git { $0.refs["1b1dab2"] = "H1" }) == nil)
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: FakeGit()) == nil)                       // 查不到這個 commit
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: git { $0.refs["1b1dab2"] = "H1"; $0.inside = ["H1>M"] }) == nil)
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/elsewhere", installed: nil, git: git { $0.refs["1b1dab2"] = "H1"; $0.inside = ["H1>OM"] }) == nil)  // 不是 git repo
        // 問併：本機 main 有就算
        #expect(StaleAsks.shipped(ask("Q2", "要把 1b1dab2 併進 main 嗎？"), card: nil, cwd: "/repo", installed: nil,
                                  git: git { $0.refs["1b1dab2"] = "H1"; $0.inside = ["H1>M"] }) != nil)
    }

    @Test("誤撤：題目只是提到 commit（不是在問要不要裝），就算 commit 已在 main 也不撤")
    func mentionOnly() {
        let g = git { $0.refs["1b1dab2"] = "H1"; $0.inside = ["H1>OM", "H1>M"] }
        #expect(StaleAsks.shipped(ask("Q1", "1b1dab2 之後晨報會當掉，要先修晨報還是先做搜尋？"), card: nil, cwd: "/repo", installed: nil, git: g) == nil)
        #expect(StaleAsks.shipped(ask("Q2", "已把 1b1dab2 推上 GitHub，接下來做 B 組嗎？"), card: nil, cwd: "/repo", installed: nil, git: g) == nil)
    }

    @Test("兩個 commit 只進了一個 ⇒ 不撤")
    func partial() {
        let g = git { $0.refs["1b1dab2"] = "H1"; $0.refs["26236df"] = "H2"; $0.inside = ["H1>OM"] }
        #expect(StaleAsks.shipped(ask("Q1", "要不要 push 1b1dab2 跟 26236df？"), card: nil, cwd: "/repo", installed: nil, git: g) == nil)
    }

    @Test("只問裝：main 有不算，要裝著的版本含它")
    func install() {
        let q = ask("Q1", "要裝 1b1dab2 嗎？")
        let inMain = git { $0.refs["1b1dab2"] = "H1"; $0.refs["INST"] = "I"; $0.inside = ["H1>OM", "H1>M"] }
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: inMain) == nil)
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: "INST", git: inMain) == nil)
        let installed = git { $0.refs["1b1dab2"] = "H1"; $0.refs["INST"] = "I"; $0.inside = ["H1>I"] }
        guard case .shipped(_, let d, _, _)? = StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: "INST", git: installed) else { Issue.record("該撤"); return }
        #expect(d.contains("已裝好"))
    }

    @Test("題目沒寫 commit：看卡片欄位；再沒有就看現在的分支（Bella2 的情況）")
    func fallback() {
        let q = ask("Q1", "要不要 push／併？")
        // 卡片 summary 寫了分支
        let card = SelfReport(status: .review, summary: "改好了，在 bella2/merge-fix 分支", ask: q.ask)
        let g1 = git { $0.refs["bella2/merge-fix"] = "B"; $0.inside = ["B>OM"] }
        #expect(StaleAsks.shipped(q, card: card, cwd: "/repo", installed: nil, git: g1) != nil)
        // 什麼都沒寫：現在的分支，要乾淨、真的有 commit 過
        let g2 = git { $0.refs["worktree-bella2"] = "B"; $0.inside = ["B>OM"]; $0.branch = "worktree-bella2" }
        guard case .shipped(let ref, let d, _, _)? = StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: g2) else { Issue.record("該撤"); return }
        #expect(ref == "worktree-bella2" && d.hasPrefix("現在的分支"))
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: git { $0 = g2; $0.isClean = false }) == nil)          // 還有沒 commit 的改動
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: git { $0 = g2; $0.noCommits = ["worktree-bella2"] }) == nil)  // 剛開的分支
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: git { $0 = g2; $0.branch = "main" }) == nil)          // 就在 main 上
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: git { $0 = g2; $0.branch = nil }) == nil)             // detached
    }

    @Test("勾選放行、看板自己發的題不碰")
    func untouchable() {
        var q = ask("Q1", "要不要 push 1b1dab2？"); q.action = ReleasePick.action
        let g = git { $0.refs["1b1dab2"] = "H1"; $0.inside = ["H1>OM"] }
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: g) == nil)
        q.action = "captain"
        #expect(StaleAsks.shipped(q, card: nil, cwd: "/repo", installed: nil, git: g) == nil)
    }

    // MARK: 寫檔、傳話

    func withDirs(_ body: (URL, URL) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staleasks-" + UUID().uuidString, isDirectory: true)
        let cards = root.appendingPathComponent("cards", isDirectory: true)
        try? FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        AskQueue.$testDir.withValue(root.appendingPathComponent("asks", isDirectory: true)) { body(cards, root) }
    }

    @Test("撤：佇列拿掉、卡片的 --ask 清掉換成「已在別處處理」、秘書卡片同一題也清；已經不在的不算")
    func applyWrites() throws {
        withDirs { cards, _ in
            let q1 = ask("Q1", "要不要 push 1b1dab2？"), q2 = ask("Q2", "別的題？")
            AskQueue.save("S1", [q1, q2])
            AskQueue.save("CAP", [ask("Q9", "要不要 push 1b1dab2？")])
            func write(_ sid: String, _ r: SelfReport) { try? BoardJSON.encoder.encode(r).write(to: cards.appendingPathComponent(sid + ".json")) }
            write("S1", SelfReport(status: .review, summary: "做好了", ask: q1.ask, options: ["好", "先不要"]))
            write("CAP", SelfReport(status: .review, ask: q1.ask))
            let why = StaleAsks.Why.shipped(ref: "1b1dab2", detail: "1b1dab2 已在 origin/main（3b97f08），已推上 GitHub", by: "秘書", at: now)
            let gone = StaleAsks.apply([.init(sid: "S1", ask: q1, why: why), .init(sid: "S1", ask: ask("QX", "不在了"), why: why)], captain: "CAP", cardsDir: cards)
            #expect(gone.map(\.ask.id) == ["Q1"])
            #expect(AskQueue.load("S1").map(\.id) == ["Q2"])
            #expect(AskQueue.load("CAP").isEmpty)
            let c = try? BoardJSON.decoder.decode(SelfReport.self, from: Data(contentsOf: cards.appendingPathComponent("S1.json")))
            #expect(c?.ask == nil && c?.options == nil && c?.summary?.hasPrefix("已在別處處理（秘書，") == true)
            let cap = try? BoardJSON.decoder.decode(SelfReport.self, from: Data(contentsOf: cards.appendingPathComponent("CAP.json")))
            #expect(cap?.ask == nil)
            // 再撤一次：沒東西
            #expect(StaleAsks.apply([.init(sid: "S1", ask: q1, why: why)], captain: "CAP", cardsDir: cards).isEmpty)
        }
    }

    @Test("傳給組員的短訊：講清楚在哪處理、請它發 done 卡")
    func messageText() {
        let why = StaleAsks.Why.shipped(ref: "1b1dab2", detail: "1b1dab2 已在 origin/main（3b97f08），已推上 GitHub", by: "秘書", at: now)
        let m = StaleAsks.message([.init(sid: "S1", ask: ask("Q1", "要不要 push 1b1dab2？"), why: why)], owner: "小明", orbit: "/bin/orbit")
        #expect(m.hasPrefix("【Orbit42 撤題】") && m.contains("3b97f08") && m.contains("done 卡") && m.contains("不用再問小明"))
    }

    // MARK: 真的 git（暫存 repo）

    @discardableResult
    func sh(_ dir: URL, _ args: String...) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", dir.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "秘書"; env["GIT_COMMITTER_NAME"] = "秘書"; env["GIT_AUTHOR_EMAIL"] = "s@x"; env["GIT_COMMITTER_EMAIL"] = "s@x"
        p.environment = env
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("真的 git：分支併進 main 前不撤、併進去後撤，記到那顆合併")
    func realGit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("staleasks-git-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        sh(dir, "init", "-q", "-b", "main")
        sh(dir, "commit", "-q", "--allow-empty", "-m", "起點")
        sh(dir, "checkout", "-q", "-b", "bella/fix")
        let kept = sh(dir, "status")       // 讓 reflog 有東西前先確認 repo 正常
        #expect(!kept.isEmpty)
        let g = SystemGit()
        let q = ask("Q1", "要不要把 bella/fix 併進 main？")
        // 剛開的分支（沒有自己的 commit）：本來就在 main 裡，但不能撤
        #expect(StaleAsks.shipped(q, card: nil, cwd: dir.path, installed: nil, git: g) == nil)
        sh(dir, "commit", "-q", "--allow-empty", "-m", "修好")
        let fix = sh(dir, "rev-parse", "--short", "HEAD")
        #expect(StaleAsks.shipped(q, card: nil, cwd: dir.path, installed: nil, git: g) == nil)          // 還沒併
        sh(dir, "checkout", "-q", "main")
        sh(dir, "commit", "-q", "--allow-empty", "-m", "main 另一顆")
        sh(dir, "merge", "-q", "--no-ff", "-m", "併 bella/fix", "bella/fix")
        let merge = sh(dir, "rev-parse", "HEAD")
        guard case .shipped(_, let d, let by, let at)? = StaleAsks.shipped(q, card: nil, cwd: dir.path, installed: nil, git: g) else { Issue.record("該撤"); return }
        #expect(d.contains(String(merge.prefix(7))) && by == "秘書" && at != nil)
        // 用 commit 問 push：沒有 origin/main ⇒ 不撤
        #expect(StaleAsks.shipped(ask("Q2", "要不要 push \(fix)？"), card: nil, cwd: dir.path, installed: nil, git: g) == nil)
        // 裝著的是合併那顆 ⇒ 問裝的撤
        #expect(StaleAsks.shipped(ask("Q3", "要裝 \(fix) 嗎？"), card: nil, cwd: dir.path, installed: merge, git: g) != nil)
    }
}
