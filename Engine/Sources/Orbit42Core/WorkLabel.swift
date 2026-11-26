import Foundation

// 11-25 Keng 定案：畫面用職責分辨、不放英文名（英文名只當收件地址）。每張卡固定兩行：
//   第一行「職責 · 主專案」，第二行「工作標題」。接單／開工卡當下定住，cd、自報的 doing、複驗、補修回報都不改。
// 看板、球體、收件匣、衛星標題列、終端機標題、手機、語音、名冊都用這裡的 WorkLabels.resolve。

/// 主專案：worktree、_wt-、子資料夾都歸回主 repo 名
public enum MainProject {
    public static let none = "未歸專案"

    /// 路徑 → 主 repo 名；家目錄、不在任何 repo 裡 ⇒ nil。read＝讀 .git 檔（worktree 的 .git 是檔案，寫著主 repo 在哪）
    public static func name(path: String?, home: String, exists: (String) -> Bool, read: (String) -> String?) -> String? {
        guard var p = path.map({ ($0 as NSString).standardizingPath }), p.hasPrefix("/") else { return nil }
        if let r = p.range(of: "/.claude/worktrees/") { p = String(p[..<r.lowerBound]) }
        while p.count > 1, p != home {
            let git = p + "/.git"
            if exists(git) {
                if let t = read(git), t.hasPrefix("gitdir:") {
                    let dir = t.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let r = dir.range(of: "/.git/") { return (String(dir[..<r.lowerBound]) as NSString).lastPathComponent }
                }
                return (p as NSString).lastPathComponent
            }
            // worktree 資料夾已經刪了：_wt-Orbit42-sphere → 同一層名字對得上的主 repo（取最長的）
            let last = (p as NSString).lastPathComponent
            if last.hasPrefix("_wt-") { return worktreeName(last, parent: (p as NSString).deletingLastPathComponent, exists: exists) }
            p = (p as NSString).deletingLastPathComponent
        }
        return nil
    }
    static func worktreeName(_ last: String, parent: String, exists: (String) -> Bool) -> String {
        var parts = last.dropFirst(4).split(separator: "-").map(String.init)
        let all = parts.joined(separator: "-")
        while !parts.isEmpty {
            let n = parts.joined(separator: "-")
            if exists(parent + "/" + n + "/.git") { return n }
            parts.removeLast()
        }
        return all.isEmpty ? last : all
    }
    /// 單子上寫的專案名（舊單存的是當下資料夾名，可能是 worktree 名）→ 主 repo；repos 底下沒有這個資料夾 ⇒ nil
    public static func name(named n: String?, repos: String, home: String, exists: (String) -> Bool, read: (String) -> String?) -> String? {
        guard let n, !n.isEmpty, !n.hasPrefix("（"), !n.contains("/"), n != none else { return nil }
        return exists(repos + "/" + n) || n.hasPrefix("_wt-") ? name(path: repos + "/" + n, home: home, exists: exists, read: read) : nil
    }
    /// 單子內文寫的 ~/github-repos/<名字>（第一個存在的）
    public static func mentioned(in text: String, repos: String, home: String, exists: (String) -> Bool, read: (String) -> String?) -> String? {
        let folder = (repos as NSString).lastPathComponent + "/"
        var rest = text[...]
        while let r = rest.range(of: folder) {
            rest = rest[r.upperBound...]
            let n = String(rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) })
            if let m = name(named: n, repos: repos, home: home, exists: exists, read: read) { return m }
        }
        return nil
    }

    // 真的檔案系統
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
    static func read(_ p: String) -> String? { FileManager.default.contents(atPath: p).flatMap { $0.count < 4096 ? String(data: $0, encoding: .utf8) : nil } }
    public static func live(path: String?) -> String? { name(path: path, home: home, exists: exists, read: read) }
    public static func live(named n: String?) -> String? { name(named: n, repos: home + "/github-repos", home: home, exists: exists, read: read) }
    public static func live(mentioned t: String) -> String? { mentioned(in: t, repos: home + "/github-repos", home: home, exists: exists, read: read) }
}

public enum WorkRole {
    public static let secretary = "秘書", fix = "修改", check = "複核"
    /// 派工單、開工卡能用的職責（秘書由登記決定，不能自己填）
    public static let all = ["修改", "複核", "設計", "測試", "研究", "維運"]
    public static func valid(_ s: String?) -> String? { s.flatMap { r in all.first { $0 == r.trimmingCharacters(in: .whitespaces) } } }
    /// 沒帶 --role：開頭的【複核】【複驗】→ 複核，其餘 → 修改
    public static func guess(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkTitle.tags(t).contains { isCheck($0) } ? check : fix
    }
    static func isCheck(_ tag: String) -> Bool { tag.hasPrefix("複核") || tag.hasPrefix("複驗") }
}

public enum WorkTitle {
    public static let limit = 14
    public static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 })).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }
    /// 開頭連續的【】
    static func tags(_ text: String) -> [String] {
        var t = text[...], out: [String] = []
        while t.first == "【", let e = t.firstIndex(of: "】") {
            out.append(t[t.index(after: t.startIndex)..<e].trimmingCharacters(in: .whitespaces))
            t = t[t.index(after: e)...].drop { $0 == " " }
        }
        return out
    }
    /// 沒帶 --title：開頭【】裡的短標題（只寫職責的【複核】跳過）；沒有就第一行
    public static func guess(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in tags(t) {
            var x = tag
            if WorkRole.isCheck(x) { x = String(x.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " ：:・·-")) }
            if WorkRole.all.contains(x) || x.hasPrefix("使用者從") || x.hasPrefix("秘書派工") || x.hasPrefix("隊長派工") { continue }
            if let c = clean(x) { return c }
        }
        var rest = t[...]
        while rest.first == "【", let e = rest.firstIndex(of: "】") { rest = rest[rest.index(after: e)...].drop { $0 == " " } }
        return clean(rest.split(whereSeparator: \.isNewline).first.map(String.init)) ?? "沒寫標題的工作"
    }
}

/// Keng 直接交辦的（開工卡）＋這個 session 的身分（/clear 換 sessionId 時跟著走）。存 board/jobs/<sid>.json
public struct JobRecord: Codable, Sendable, Equatable {
    public struct Job: Codable, Sendable, Equatable {
        public var role: String?, title: String, project: String?, at: Date, doneAt: Date?
        public init(role: String? = nil, title: String, project: String? = nil, at: Date, doneAt: Date? = nil) { self.role = role; self.title = title; self.project = project; self.at = at; self.doneAt = doneAt }
    }
    public var job: Job? = nil
    public var seen: Date? = nil             // 已經處理到哪一張自報
    public var proc: ProcStamp? = nil        // 這段對話現在的程序（/clear 靠它認）
    public var prev: [String] = []           // /clear、交接之前的 sessionId（派出去的單可能還記著舊的）
    public var last: String? = nil           // 最後知道的主專案（待命時用）
    public var cleared: Date? = nil          // 手動 /clear、沒有交接的時間：之前的工作不再當標題（11-25 Keng：clear 後要變待命）
    public init() {}

    /// 一張自報進來（CLI 當下寫；配舊 orbit 時由 App 補）。只有開工卡會換標題
    public mutating func apply(_ r: SelfReport, project: String?, legacy: Bool = false) {
        if let s = seen, r.at <= s { return }
        seen = r.at
        if let p = project { last = p }
        guard r.task == nil else { return }                       // 派工單的自報：標題看單子
        if r.isStart || (legacy && job == nil) {
            guard let t = WorkTitle.clean(r.title) ?? WorkTitle.clean(r.doing) ?? r.summary.map(WorkTitle.guess) else { return }
            if var j = job, j.title == t, j.doneAt == nil, cleared.map({ j.at > $0 }) ?? true { if let x = WorkRole.valid(r.role) { j.role = x; job = j }; return }      // 同一件事又發一次開工卡
            let pr = (r.touch.flatMap { MainProject.live(mentioned: $0) }) ?? project
            job = Job(role: WorkRole.valid(r.role) ?? WorkRole.guess([r.doing, r.summary].compactMap { $0 }.first ?? ""), title: t, project: pr, at: r.at)
        }
        guard var j = job, !r.isWrapup else { return }
        if r.status == .done && r.ask == nil { j.doneAt = j.doneAt ?? r.at } else if !r.isStart { j.doneAt = nil }      // 補修：又做起來 ⇒ 標題不變、不再是完成
        job = j
    }
    /// /clear 或交接：新的 sessionId 接手
    public func moved(from old: String) -> JobRecord { var n = self; n.prev = Array((prev.filter { $0 != old } + [old]).suffix(8)); return n }
}

public enum JobStore {
    /// 只有正式的 App 才寫檔（測試視窗、--board-dump 只看不寫）
    nonisolated(unsafe) public static var appWrites = false
    public static var dir: URL { Paths.supportDir.appendingPathComponent("board/jobs", isDirectory: true) }
    static func url(_ sid: String) -> URL { dir.appendingPathComponent(sid + ".json") }
    public static func get(_ sid: String) -> JobRecord? { FileManager.default.contents(atPath: url(sid).path).flatMap { try? BoardJSON.decoder.decode(JobRecord.self, from: $0) } }
    @discardableResult
    public static func save(_ sid: String, _ r: JobRecord) -> Bool {
        guard !sid.isEmpty, !sid.contains("/") else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? BoardJSON.encoder.encode(r)).flatMap { try? $0.write(to: url(sid), options: .atomic) } != nil
    }
    public static func all() -> [String: JobRecord] {
        var out: [String: JobRecord] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") && !f.hasPrefix(".") {
            let sid = String(f.dropLast(5)); if let r = get(sid) { out[sid] = r }
        }
        return out
    }
    /// 換成這套標示的時間：之前的自報沒有開工卡紀錄，拿它當第一張單（只在升級當下用一次）
    public static func since(now: Date = Date()) -> Date {
        let f = dir.appendingPathComponent(".since")
        if let d = FileManager.default.contents(atPath: f.path).flatMap({ BoardJSON.iso.date(from: String(decoding: $0, as: UTF8.self)) }) { return d }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(BoardJSON.iso.string(from: now).utf8).write(to: f, options: .atomic)
        return now
    }
    /// 自報 → 紀錄。回傳有沒有改
    @discardableResult
    public static func note(_ sid: String, _ r: SelfReport, cwd: String?, pid: Int32? = nil, write: Bool = true) -> JobRecord? {
        let old = get(sid)
        if let s = old?.seen, r.at <= s { return old }
        var n = old ?? JobRecord()
        if let p = ProcStamp.of(pid) { n.proc = p }
        n.apply(r, project: MainProject.live(path: cwd), legacy: write && r.at < since())
        if write, n != old { save(sid, n) }
        return n
    }
    /// SessionStart：同一個程序 /clear 換了 sessionId ⇒ 標示跟著走；/resume 到別的對話 ⇒ 舊的那份不再認這個程序
    public static func begin(_ sid: String, source: String?, pid: Int32?, cwd: String?) {
        guard let p = ProcStamp.of(pid) else { return }
        let (n, changed) = plan(all(), sid: sid, source: source, proc: p, project: MainProject.live(path: cwd))
        for (k, r) in changed { save(k, r) }
        save(sid, n)
    }
    /// clear 一律先記 cleared；真的有交接時 Handover.claim 會接著用 carry(resume:) 拿掉
    static func plan(_ all: [String: JobRecord], sid: String, source: String?, proc: ProcStamp, project: String?, now: Date = Date()) -> (JobRecord, [String: JobRecord]) {
        var n = all[sid] ?? JobRecord(), changed: [String: JobRecord] = [:]
        let mine = all.filter { $0.key != sid && $0.value.proc == proc }
        if source == "clear", all[sid]?.job == nil, let old = mine.max(by: { ($0.value.seen ?? .distantPast) < ($1.value.seen ?? .distantPast) }) { n = old.value.moved(from: old.key) }
        if source == "clear", all[sid]?.job == nil, all[sid]?.prev.isEmpty ?? true { n.cleared = now }
        for (k, r) in mine { var r = r; r.proc = nil; changed[k] = r }
        n.proc = proc
        if n.last == nil { n.last = project }
        return (n, changed)
    }
    /// 交接到新 session、或終端機停放到背景：照抄一份
    /// resume＝真的有交接 ⇒ 工作標題沿用（拿掉 begin 剛記的 cleared）；其他（秘書 /clear、停放到背景）不動 cleared
    public static func carry(from old: String, to new: String, resume: Bool = false) {
        guard old != new, let r = get(old), let n = carried(r, from: old, onto: get(new), resume: resume) else { return }
        save(new, n)
    }
    static func carried(_ r: JobRecord, from old: String, onto cur: JobRecord?, resume: Bool) -> JobRecord? {
        guard cur?.job == nil || (resume && cur?.cleared != nil) else { return nil }
        var n = r.moved(from: old); n.proc = cur?.proc
        n.cleared = resume ? r.cleared : cur?.cleared ?? r.cleared
        return n
    }
    /// 舊 sessionId 現在是誰（/clear 過幾次都認得）；剛好一個才算
    public static func heir(of old: String, live: [String], jobs: [String: JobRecord]) -> String? {
        let hits = live.filter { jobs[$0]?.prev.contains(old) ?? false }
        return hits.count == 1 ? hits[0] : nil
    }
}

public struct WorkLabel: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case open, done, idle }
    public var role: String, project: String, title: String, state: State
    public var at: Date?                     // 接單時間（排序、撞名編號用）
    public var number: Int? = nil
    /// 第一行
    public var head: String { role + (number.map { " \($0)" } ?? "") + " · " + project }
    /// 第二行
    public var work: String { state == .idle ? "待命" : state == .done ? "完成：" + title : title }
    public var line: String { head + "｜" + work }
    /// 撞名比的是這個（完成了編號也不變）
    var key: String { role + "\u{1}" + project + "\u{1}" + (state == .idle ? "" : title) }
}

public enum WorkLabels {
    public static let keepDone: TimeInterval = 600
    public struct Person: Sendable {
        public var sid: String, name: String?, cwd: String?, startedAt: Date?, nickRole: String?
        public init(sid: String, name: String? = nil, cwd: String? = nil, startedAt: Date? = nil, nickRole: String? = nil) { self.sid = sid; self.name = name; self.cwd = cwd; self.startedAt = startedAt; self.nickRole = nickRole }
    }
    public struct Number: Codable, Sendable, Equatable { public var key: String, n: Int }
    /// 檔案系統查詢（測試換掉）
    public struct Lookup: Sendable {
        public var path: @Sendable (String?) -> String?, named: @Sendable (String?) -> String?, mentioned: @Sendable (String) -> String?
        public init(path: @escaping @Sendable (String?) -> String?, named: @escaping @Sendable (String?) -> String?, mentioned: @escaping @Sendable (String) -> String?) { self.path = path; self.named = named; self.mentioned = mentioned }
        /// 看板每 1.5 秒算一次：同樣的問題記住 60 秒，不一直讀磁碟
        public static func cached() -> Lookup {
            final class Box: @unchecked Sendable { let lock = NSLock(); var m: [String: (String?, Date)] = [:] }
            let b = Box()
            @Sendable func get(_ k: String, _ f: () -> String?) -> String? {
                b.lock.lock(); defer { b.lock.unlock() }
                if let c = b.m[k], Date().timeIntervalSince(c.1) < 60 { return c.0 }
                if b.m.count > 500 { b.m = [:] }
                let v = f(); b.m[k] = (v, Date()); return v
            }
            return Lookup(path: { p in get("p" + (p ?? "")) { live.path(p) } }, named: { n in get("n" + (n ?? "")) { live.named(n) } }, mentioned: { t in get("t" + t) { live.mentioned(t) } })
        }
        public static let live = Lookup(path: { MainProject.live(path: $0) }, named: { MainProject.live(named: $0) }, mentioned: { MainProject.live(mentioned: $0) })
    }

    /// 一個人現在掛哪張單：最新接的；它結束超過 10 分鐘（或被取消）就看前一張還沒結束的；都沒有＝待命
    public static func one(_ p: Person, captain: String?, job: JobRecord?, tasks: [CaptainTask], now: Date, look: Lookup) -> WorkLabel {
        struct Cand { var role: String, title: String, project: String?, at: Date, ended: Date?, open: Bool, back: Date? = nil, hidden = false }
        let ids = Set([p.sid] + (job?.prev ?? []))
        func taskProject(_ t: CaptainTask) -> String? { t.mainProject ?? look.mentioned(t.text) ?? look.named(t.project) }
        var cs = tasks.filter { t in t.state != .cancelled && (t.toSession.map(ids.contains) ?? (p.name != nil && t.to == p.name)) }.map { t in
            Cand(role: WorkRole.valid(t.role) ?? WorkRole.guess(t.text), title: WorkTitle.clean(t.title) ?? WorkTitle.guess(t.text), project: taskProject(t),
                 at: t.createdAt, ended: t.state == .done ? t.updatedAt : nil, open: t.state.open, back: t.state.open ? t.updatedAt : nil)
        }
        if let j = job?.job { cs.append(Cand(role: j.role ?? WorkRole.fix, title: j.title, project: j.project, at: j.at, ended: j.doneAt, open: j.doneAt == nil)) }
        // 手動 /clear 之前的工作不當標題；clear 後又回報的派工單才算回來。職責和專案照舊
        if let c = job?.cleared { for i in cs.indices where cs[i].at <= c && !(cs[i].back.map { $0 > c } ?? false) { cs[i].hidden = true } }
        cs.sort { $0.at > $1.at }
        let isCap = p.sid == captain
        let newest = cs.first, shown = cs.filter { !$0.hidden }
        func alive(_ c: Cand) -> Bool { c.ended.map { now.timeIntervalSince($0) < keepDone } ?? true }
        let pick = shown.first.flatMap { alive($0) ? $0 : nil } ?? shown.dropFirst().first { $0.open }
        let base = pick ?? newest
        let role = isCap ? WorkRole.secretary : base?.role ?? WorkRole.valid(p.nickRole) ?? WorkRole.fix
        let project = base?.project ?? job?.last ?? look.path(p.cwd) ?? MainProject.none
        guard let c = pick else { return WorkLabel(role: role, project: project, title: "", state: .idle, at: base?.at ?? p.startedAt) }
        return WorkLabel(role: role, project: project, title: c.title, state: c.ended == nil ? .open : .done, at: c.at)
    }

    /// 所有在線的人一起算：撞名編號（兩行都一樣才編，依接單先後，在線期間不變）。numbers＝上次編的號，回傳更新後的
    public static func resolve(_ people: [Person], captain: String?, jobs: [String: JobRecord], tasks: [CaptainTask], numbers: [String: Number], now: Date,
                               look: Lookup = .live) -> (labels: [String: WorkLabel], numbers: [String: Number]) {
        var out: [String: WorkLabel] = [:], nums: [String: Number] = [:]
        for p in people { out[p.sid] = one(p, captain: captain, job: jobs[p.sid], tasks: tasks, now: now, look: look) }
        for (key, group) in Dictionary(grouping: out.keys.sorted(), by: { out[$0]!.key }) {
            let held = group.filter { numbers[$0]?.key == key }
            guard group.count > 1 || !held.isEmpty else { continue }
            var used = Set<Int>()
            for s in held where used.insert(numbers[s]!.n).inserted { nums[s] = numbers[s] }
            for s in group.sorted(by: { (out[$0]!.at ?? .distantPast, $0) < (out[$1]!.at ?? .distantPast, $1) }) where nums[s] == nil {
                let n = (1...).first { !used.contains($0) }!
                used.insert(n); nums[s] = Number(key: key, n: n)
            }
            for s in group { out[s]!.number = nums[s]?.n }
        }
        return (out, nums)
    }

    /// 排序：秘書最前，再依主專案（未歸專案最後）、接單先後；狀態變不重排
    public static func before(_ a: (sid: String, label: WorkLabel?), _ b: (sid: String, label: WorkLabel?)) -> Bool {
        func k(_ x: (sid: String, label: WorkLabel?)) -> (Int, String, Date, String) {
            let p = x.label?.project ?? MainProject.none
            return (x.label?.role == WorkRole.secretary ? 0 : p == MainProject.none ? 2 : 1, p.lowercased(), x.label?.at ?? .distantFuture, x.sid)
        }
        return k(a) < k(b)
    }

    // MARK: 讀寫
    public static var numbersFile: URL { Paths.supportDir.appendingPathComponent("board/label-numbers.json") }
    public static func numbers() -> [String: Number] { (try? Data(contentsOf: numbersFile)).flatMap { try? JSONDecoder().decode([String: Number].self, from: $0) } ?? [:] }
    public static func saveNumbers(_ n: [String: Number]) { if let d = try? JSONEncoder().encode(n) { try? d.write(to: numbersFile, options: .atomic) } }

    public static func people(_ recs: [SessionRecord], nick: [String: Nickname]) -> [Person] {
        recs.map { Person(sid: $0.sessionId, name: $0.name, cwd: $0.cwd, startedAt: $0.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }, nickRole: nick[$0.sessionId]?.role) }
    }
    /// CLI 用：現在就從檔案算（編號沿用 App 存的，不寫）
    public static func current(now: Date = Date()) -> [String: WorkLabel] {
        resolve(people(NicknameStore.liveSessions(), nick: NicknameStore.all()), captain: CaptainStore.captain()?.sessionId, jobs: JobStore.all(), tasks: CaptainStore.tasks(),
                numbers: numbers(), now: now).labels
    }
}

extension BoardCard {
    /// 畫面用的兩行；display／title 是合成一行的版本
    public mutating func set(_ l: WorkLabel) { work = l; label = l.head; title = l.line }
}
