import Foundation
import ShoWorkCore

/// Which AI runs inside a satellite. Each brain is the vendor's own official CLI agent,
/// so login, tools and updates stay theirs (S2 turns this into a full adapter: status, resume, usage).
enum Brain: String, CaseIterable, Sendable {
    case claude, codex, gemini
    var label: String { ["claude": "Claude", "codex": "ChatGPT", "gemini": "Gemini"][rawValue]! }
    /// 11-23 Keng：所有 AI 都用最高權限開（跟他的 `ccc` = claude --dangerously-skip-permissions 一樣）
    /// Gemini 走 Antigravity CLI（2026-05 起取代 Gemini CLI，`agy --help` 確認有同名參數）；Codex 用它的全自動參數（本機還沒裝，未實測）
    var command: String {
        // 11-23 Keng「衛星終端機只要 Context」：球體已經顯示額度／溫度／風扇 ⇒ 這個衛星關掉 flightdeck 面板（狀態列腳本看 TERM_PROGRAM=Orbit42 只畫 Context）
        ["claude": "claude --dangerously-skip-permissions --settings '{\"enabledPlugins\":{\"flightdeck@claude-flightdeck\":false}}'",
         "gemini": "agy --dangerously-skip-permissions",
         "codex": "codex --dangerously-bypass-approvals-and-sandbox"][rawValue]!
    }
}

/// One AI worker on the sphere: a terminal (PTY) plus what it is running.
final class Satellite: @unchecked Sendable {
    let id: String
    var name: String
    let brain: Brain
    let cwd: String
    let command: String
    let attachedJob: String?          // background Claude session we attached to (not started by Orbit42)
    var pty: Pty?
    var exited: Int32?
    var lastOutput = Date.distantPast
    private(set) var scrollback = Data()     // replayed when the terminal panel is reopened
    private(set) var total = 0               // 11-23 iPhone App：開始到現在一共輸出幾個位元組（手機照這個位置續讀）
    private let lock = NSLock()
    // 11-24 Keng「手機在看時用手機大小，離開就恢復 Mac 大小」：同一個背景 session 只有一個畫面大小（兩個檢視會互相改），
    // 所以手機在看（5 秒內有來拿畫面）時把 pty 改成手機的行列數；Mac 視窗這段時間的改大小只記下來，手機離開才套回去
    var macSize: (cols: Int, rows: Int)?
    var phoneUntil: Date?
    var phoneActive: Bool { (phoneUntil ?? .distantPast) > Date() }
    /// Mac 這邊的終端機量到的大小
    func localResize(cols: Int, rows: Int) {
        macSize = (cols, rows)
        if !phoneActive { pty?.resize(cols: cols, rows: rows) }
    }
    /// 手機來拿畫面時附上自己的行列數
    func phoneView(cols: Int, rows: Int) {
        guard let p = pty, cols >= 20, rows >= 5 else { return }
        if !phoneActive, macSize == nil { macSize = p.size }
        phoneUntil = Date().addingTimeInterval(5)
        if p.size.cols != cols || p.size.rows != rows { p.resize(cols: cols, rows: rows) }
    }
    /// 手機離開（5 秒沒來）：套回 Mac 的大小
    func phoneCheck() {
        guard let u = phoneUntil, u <= Date() else { return }
        phoneUntil = nil
        if let m = macSize, let p = pty, p.size.cols != m.cols || p.size.rows != m.rows { p.resize(cols: m.cols, rows: m.rows) }
    }

    init(id: String, name: String, brain: Brain, cwd: String, command: String, attachedJob: String? = nil) {
        self.id = id; self.name = name; self.brain = brain; self.cwd = cwd; self.command = command; self.attachedJob = attachedJob
    }

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        scrollback.append(d)
        total += d.count
        let cap = 2 * 1024 * 1024
        if scrollback.count > cap { scrollback.removeFirst(scrollback.count - cap) }
        lastOutput = Date()
    }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return scrollback }

    /// iPhone App：從第 from 個位元組起的輸出（太舊已經丟掉就從還留著的最前面；一次最多 256 KB，取最新的）
    func remote(from: Int) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let start = total - scrollback.count
        var f = max(from, start)
        if total - f > 256 * 1024 { f = total - 256 * 1024 }
        let chunk = f >= total ? Data() : scrollback.suffix(total - f)
        var o: [String: Any] = ["total": total, "from": f, "data": chunk.base64EncodedString()]
        if let s = pty?.size { o["cols"] = s.cols; o["rows"] = s.rows }
        return o
    }

    var json: [String: Any] {
        let state = exited != nil ? "exited" : pty == nil ? "idle" : Date().timeIntervalSince(lastOutput) < 3 ? "busy" : "open"
        var o: [String: Any] = ["id": id, "name": name, "brain": brain.rawValue, "brainLabel": brain.label, "cwd": cwd, "state": state]
        if let j = attachedJob { o["job"] = j }
        if let e = exited { o["exit"] = e }
        return o
    }
}

/// Background Claude sessions that can be pulled in as satellites (`claude attach <job>`).
enum BackgroundSessions {
    static func list() -> [[String: Any]] {
        let fm = FileManager.default, dir = NSHomeDirectory() + "/.claude/sessions"
        let recs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { f -> SessionRecord? in
            guard let d = fm.contents(atPath: dir + "/" + f), let r = SessionRecord.decode(d), kill(r.pid, 0) == 0 else { return nil }
            return r
        }
        return recs.filter { $0.kind == "bg" && $0.jobId != nil && ($0.name ?? "").isEmpty == false && $0.name != String($0.sessionId.prefix(8)) }
            .map { ["job": $0.jobId!, "name": $0.name ?? $0.jobId!, "cwd": $0.cwd, "status": $0.status ?? "?"] }
    }
}
