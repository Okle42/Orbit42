import Foundation

// 11-28 Keng：「這種字在別的視窗處理過，是他就要更新消掉了，這樣才符合工作使用順序情境」。
// Bella2 的改動已經由秘書併進 main、裝好、推上 GitHub，它的卡片還掛著「要不要 push／併」，Keng 看到以為還沒做。
// 一件事在別的地方處理掉 ⇒ 原本那個組員的題目自動撤掉、看板記一筆、送一則短訊給它（它會發 done 卡，輸入框的建議字也跟著換）：
//   ① 派工單變成完成／取消 ⇒ 撤掉那個 session 帶這張單號（--task）、在單子結束前問的題
//   ② 題目在問要不要 push／併／裝某個 commit 或分支，而那個東西已經進了 main（push 要 origin/main）或已經裝上 ⇒ 撤掉
//      commit／分支從題目文字解析，沒有就看卡片欄位（summary、doing），再沒有就看那個 session 現在的分支（要乾淨、有自己的 commit）；
//      解析不到、git 查不到、只要有一個沒進去 ⇒ 不撤（寧可留著也不亂撤）
// 勾選放行的題（pickOnly）、看板自己發的題（action）一律不碰。

public enum StaleAsks {
    /// 為什麼撤
    public enum Why: Sendable, Equatable {
        case taskClosed(task: String, state: CaptainTask.State)
        case shipped(ref: String, detail: String, by: String?, at: Date?)
    }

    public struct Hit: Sendable, Equatable {
        public var sid: String
        public var ask: PendingAsk
        public var why: Why
        public init(sid: String, ask: PendingAsk, why: Why) { self.sid = sid; self.ask = ask; self.why = why }
    }

    // MARK: ① 派工單結束

    /// 完成／取消的單 ⇒ 對方 session 帶這張單號、單子結束前就在問的題（純函式）
    public static func closedTasks(asks: [String: [PendingAsk]], tasks: [CaptainTask]) -> [Hit] {
        var out: [Hit] = []
        for t in tasks where t.state == .done || t.state == .cancelled {
            guard let sid = t.toSession, let xs = asks[sid] else { continue }
            for q in xs where q.task == t.id && withdrawable(q) && q.at <= t.updatedAt {
                out.append(Hit(sid: sid, ask: q, why: .taskClosed(task: t.id, state: t.state)))
            }
        }
        return out
    }

    /// AI 能撤的題（勾選放行、看板自己發的不算）
    static func withdrawable(_ q: PendingAsk) -> Bool { !q.pickOnly && q.action == nil }

    // MARK: ② 題目在問要不要 push／併／裝

    public enum Verb: Sendable, Equatable { case push, merge, install }

    static let verbPatterns: [(Verb, String)] = [
        (.push, #"push|推上|推到|推(?![薦測論估動])"#),
        (.merge, #"merge|cherry-pick|合併|併進|併到|併入|併(?!發)"#),
        (.install, #"install|安裝|裝進|裝上|裝(?![置飾修])|上線"#),
    ]
    /// 一個子句裡（不跨 。；，！ 換行）
    static let clause = #"[^。；;，,！!\n]"#
    static let askWords = #"(要不要|要不|是否|可不可以|可以|能不能|需不需要|該不該|需要)"#

    /// 這題在問哪幾種動作；只是提到（「已經 push 了，接下來做哪個？」）不算
    public static func shipVerbs(_ question: String) -> Set<Verb> {
        var out = Set<Verb>()
        for (v, p) in verbPatterns {
            let asked = "\(askWords)\(clause){0,30}?(\(p))"          // 「要不要 push …」
            let tail = "(\(p))\(clause){0,40}?(嗎|？|\\?)"              // 「… 併進 main 嗎？」
            if matches(asked, question) || matches(tail, question) { out.insert(v) }
        }
        return out
    }

    static func matches(_ pattern: String, _ s: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    static func all(_ pattern: String, _ s: String, group: Int = 0) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in Range(m.range(at: group), in: s).map { String(s[$0]) } }
    }

    /// 文字裡的 commit 雜湊（7–40 碼十六進位，至少一個數字一個字母：日期 20261128、英文字 deadbee 不算）
    public static func commits(in s: String) -> [String] {
        hexWords(in: s).filter { !weak($0) }
    }
    /// 7–40 碼十六進位字（全部，含全數字、全字母的）
    static func hexWords(in s: String) -> [String] {
        unique(all(#"(?<![0-9A-Za-z])[0-9a-f]{7,40}(?![0-9A-Za-z])"#, s))
    }
    /// 全數字或全字母：可能是日期、英文字，也可能是真的短雜湊。
    /// 11-28 T1128155212：真的 commit 約 3.7% 短雜湊剛好全是數字（7 碼 (10/16)^7），以前一律丟掉 ⇒ 那種 commit 永遠認不出來（測試隨機雜湊時好時壞）。
    /// 改成：這種字在那個 repo 查得到 commit 才算，查不到就當沒寫（不會因為一個日期擋掉整題）
    static func weak(_ h: String) -> Bool { !h.contains(where: \.isNumber) || !h.contains(where: \.isLetter) }

    /// 文字裡的分支名：帶斜線的（dora2/release-all、origin/sprint/w1）、或寫在「分支／branch」後面的；網址、檔名不算。
    /// 拿去 git 查得到才算數，所以這裡寬鬆一點沒關係
    public static func branches(in s: String) -> [String] {
        let slashed = all(#"(?<![0-9A-Za-z._/:-])[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9._-]+)+(?![0-9A-Za-z._/-])"#, s)
            .filter { !$0.contains("//") && !$0.hasSuffix(".swift") && !$0.hasSuffix(".md") && !$0.hasSuffix(".json") }
        let named = all(#"(?:分支|branch)\s*[`「『\"]?([A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9])"#, s, group: 1)
        let xs = (slashed + named).map { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : $0 }
        return unique(xs.filter { !["main", "master", "HEAD"].contains($0) && !$0.hasPrefix("http") })
    }

    static func unique(_ xs: [String]) -> [String] { var seen = Set<String>(); return xs.filter { seen.insert($0).inserted } }

    // MARK: git（測試換成假的）

    public struct Landing: Sendable, Equatable {
        public var hash: String, who: String?, at: Date?
        public init(hash: String, who: String?, at: Date?) { self.hash = hash; self.who = who; self.at = at }
    }

    public protocol Git: Sendable {
        func toplevel(_ path: String) -> String?
        /// ref → 完整雜湊；查不到 nil
        func resolve(_ repo: String, _ ref: String) -> String?
        func isAncestor(_ repo: String, _ a: String, _ b: String) -> Bool
        func currentBranch(_ repo: String) -> String?
        /// 沒有未提交的追蹤檔改動
        func clean(_ repo: String) -> Bool
        /// 分支上真的提交過（reflog 不只「Created from」）；遠端分支查不到 reflog 算有
        func hasOwnCommits(_ repo: String, _ branch: String) -> Bool
        /// base 第一條主線上第一個含有 hash 的 commit（誰、何時進去的）
        func landing(_ repo: String, _ hash: String, on base: String) -> Landing?
    }

    /// 一題 ⇒ 該撤就回原因（純邏輯，git 由呼叫端給）。
    /// card：那個 session 最新的自報；cwd：它的專案資料夾；installed：裝著的 App 是哪個 commit（Info.plist 的 OrbitGitCommit）
    public static func shipped(_ q: PendingAsk, card: SelfReport?, cwd: String?, installed: String?, git: Git) -> Why? {
        guard withdrawable(q) else { return nil }
        let verbs = shipVerbs(q.ask)
        guard !verbs.isEmpty, let cwd, let repo = git.toplevel(cwd) else { return nil }
        // 要查的東西：題目 → 卡片欄位 → 現在的分支
        func parse(_ s: String) -> [(name: String, branch: Bool)] {
            let hs = hexWords(in: s).filter { !weak($0) || git.resolve(repo, $0) != nil }
            let cs: [(name: String, branch: Bool)] = hs.map { (name: $0, branch: false) }
            let bs: [(name: String, branch: Bool)] = branches(in: s).map { (name: $0, branch: true) }
            return cs + bs
        }
        var refs = parse(q.ask)
        if refs.isEmpty { refs = parse([card?.summary, card?.doing].compactMap { $0 }.joined(separator: "\n")) }
        var fromHead = false
        if refs.isEmpty {
            guard let b = git.currentBranch(repo), !["main", "master"].contains(b), git.clean(repo) else { return nil }
            refs = [(b, true)]; fromHead = true
        }
        let local = ["main", "master"].first { git.resolve(repo, $0) != nil }
        let remote = ["origin/main", "origin/master"].first { git.resolve(repo, $0) != nil }
        let inst = installed.flatMap { git.resolve(repo, $0) }
        var details: [String] = [], landed: Landing?
        for r in refs {
            let target = r.branch ? (git.resolve(repo, r.name) ?? git.resolve(repo, "origin/" + r.name)) : git.resolve(repo, r.name)
            guard let h = target else { return nil }                                   // 查不到 ⇒ 不撤
            if r.branch, !git.hasOwnCommits(repo, r.name) { return nil }               // 剛開、還沒 commit 的分支本來就在 main 裡
            let inRemote = remote.flatMap { git.resolve(repo, $0) }.map { git.isAncestor(repo, h, $0) } ?? false
            let inLocal = local.flatMap { git.resolve(repo, $0) }.map { git.isAncestor(repo, h, $0) } ?? false
            let inInst = inst.map { git.isAncestor(repo, h, $0) } ?? false
            // 問 push：要在 origin/main（真的推上去了）；只問裝：要裝著的版本含它；問併：main 有就算
            let ok: Bool
            if verbs.contains(.push) { ok = inRemote || inInst }
            else if verbs.contains(.merge) { ok = inLocal || inRemote || inInst }
            else { ok = inInst }
            guard ok else { return nil }
            let base = inRemote ? remote! : inLocal ? local! : nil
            let l = base.flatMap { git.landing(repo, h, on: $0) }
            if landed == nil { landed = l }
            var d = "\(fromHead ? "現在的分支 " : "")\(r.name) 已在 \(base ?? "裝著的版本")" + (l.map { "（\($0.hash.prefix(7))）" } ?? "")
            if inRemote { d += "，已推上 GitHub" }
            if inInst { d += "，已裝好" }
            details.append(d)
        }
        return .shipped(ref: refs.map(\.name).joined(separator: "、"), detail: details.joined(separator: "；"), by: landed?.who, at: landed?.at)
    }

    // MARK: 給人看的字

    static func stamp(_ d: Date?) -> String? {
        d.map { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: $0) }
    }

    /// 看板記的一筆：「已在別處處理（okle42，11-28 14:02）：…」
    public static func boardNote(_ h: Hit) -> String {
        switch h.why {
        case .taskClosed(let t, let s):
            return "已在別處處理（派工單 \(t) \(s.title)）：撤掉「\(h.ask.ask.replacingOccurrences(of: "\n", with: " ").prefix(40))」"
        case .shipped(_, let d, let by, let at):
            let who = [by, stamp(at)].compactMap { $0 }.joined(separator: "，")
            return "已在別處處理" + (who.isEmpty ? "" : "（\(who)）") + "：\(d)"
        }
    }

    /// 送給那個 session 的短訊（它會發 done 卡，Claude Code 輸入框的建議字也會換掉）
    public static func message(_ hs: [Hit], owner: String = LocalConfig.current.ownerName, orbit: String) -> String {
        let lines = hs.map { "・「\($0.ask.ask.replacingOccurrences(of: "\n", with: " ").prefix(50))」→ \(boardNote($0))" }
        return """
        【Orbit42 撤題】你看板上等\(owner)回答的題，已經在別處處理掉了，看板已自動撤掉：
        \(lines.joined(separator: "\n"))
        不用再問\(owner)，也不用再做一次。請發一張 done 卡（"\(orbit)" card --status done … 不帶 --ask）收掉這件事；還有別的事要問才另外發新題。
        """
    }

    // MARK: 寫檔

    /// 真的撤：在鎖裡再確認題目還在才拿掉；卡片檔上同一題清掉、記一筆；秘書卡片掛著同一題也清掉。回傳真的撤掉的
    @discardableResult
    public static func apply(_ hits: [Hit], captain: String?,
                             cardsDir: URL = Paths.supportDir.appendingPathComponent("board/cards", isDirectory: true)) -> [Hit] {
        let bySid = Dictionary(grouping: hits, by: \.sid)
        var done: [Hit] = []
        for (sid, hs) in bySid {
            let gone: [Hit] = AskQueue.locked {
                let xs = AskQueue.load(sid)
                let hit = hs.filter { h in xs.contains { $0.id == h.ask.id && withdrawable($0) } }
                if !hit.isEmpty { AskQueue.save(sid, xs.filter { q in !hit.contains { $0.ask.id == q.id } }) }
                return hit
            }
            for h in gone {
                noteCard(sid: sid, question: h.ask.ask, note: boardNote(h), dir: cardsDir)
                if let cap = captain, cap != sid {
                    Answered.clearCaptainCard(sid: cap, question: h.ask.ask, dir: cardsDir)
                    AskQueue.resolve(sid: cap, question: h.ask.ask)
                }
            }
            done += gone
        }
        return done
    }

    /// 卡片檔：同一題的 --ask 清掉，摘要換成「已在別處處理…」（它下一張卡會蓋掉）
    @discardableResult
    static func noteCard(sid: String, question: String, note: String, dir: URL) -> Bool {
        let url = dir.appendingPathComponent(sid + ".json")
        guard let d = try? Data(contentsOf: url), var r = try? BoardJSON.decoder.decode(SelfReport.self, from: d),
              Answered.same(r.ask, question) else { return false }
        r.ask = nil; r.options = nil; r.summary = note
        guard let out = try? BoardJSON.encoder.encode(r) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }
}

// MARK: - 真的 git

public struct SystemGit: StaleAsks.Git {
    public init() {}
    func run(_ repo: String, _ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo] + args
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment; env["GIT_OPTIONAL_LOCKS"] = "0"; p.environment = env
        guard (try? p.run()) != nil else { return (false, "") }
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public func toplevel(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let r = run(path, ["rev-parse", "--show-toplevel"]); return r.ok && !r.out.isEmpty ? r.out : nil
    }
    public func resolve(_ repo: String, _ ref: String) -> String? {
        guard !ref.hasPrefix("-") else { return nil }
        let r = run(repo, ["rev-parse", "--verify", "--quiet", ref + "^{commit}"]); return r.ok && !r.out.isEmpty ? r.out : nil
    }
    public func isAncestor(_ repo: String, _ a: String, _ b: String) -> Bool { run(repo, ["merge-base", "--is-ancestor", a, b]).ok }
    public func currentBranch(_ repo: String) -> String? {
        let r = run(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"]); return r.ok && !r.out.isEmpty ? r.out : nil
    }
    public func clean(_ repo: String) -> Bool { let r = run(repo, ["status", "--porcelain", "--untracked-files=no"]); return r.ok && r.out.isEmpty }
    public func hasOwnCommits(_ repo: String, _ branch: String) -> Bool {
        guard !branch.hasPrefix("-") else { return false }
        let r = run(repo, ["reflog", "show", "--format=%gs", "refs/heads/" + branch, "--"])
        guard r.ok else { return true }                                   // 沒有本機分支（只在遠端）
        return r.out.split(separator: "\n").contains { !$0.hasPrefix("branch: Created from") }
    }
    public func landing(_ repo: String, _ hash: String, on base: String) -> StaleAsks.Landing? {
        let path = run(repo, ["rev-list", "--first-parent", "--ancestry-path", "--reverse", "\(hash)..\(base)"])
        guard path.ok, run(repo, ["merge-base", "--is-ancestor", hash, base]).ok else { return nil }
        // 主線上第一個含它的：它的第一個父親已經含它 ⇒ 它自己就在主線上（快轉）；否則就是那顆合併
        let first = path.out.split(separator: "\n").first.map(String.init)
        let pick = first.map { c in run(repo, ["merge-base", "--is-ancestor", hash, c + "^1"]).ok ? hash : c } ?? hash
        let r = run(repo, ["log", "-1", "--format=%H%x09%an%x09%cI", pick])
        let f = r.out.components(separatedBy: "\t")
        guard r.ok, f.count == 3 else { return nil }
        return .init(hash: f[0], who: f[1], at: ISO8601DateFormatter().date(from: f[2]))
    }
}
