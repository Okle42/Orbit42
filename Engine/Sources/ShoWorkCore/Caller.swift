import Darwin
import Foundation

/// 誰叫的 showork（防冒充方案 A，11-25）：往上找 Claude Code 程序，看它真的是哪個 session。
/// 擋順手冒充；同帳號的程式改 sessions 檔、換執行檔、改 hook，這裡擋不住。
public enum Caller {
    public static var offFile: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_GUARD_OFF_FILE"] { return URL(fileURLWithPath: p) }
        return Captain.dir.appendingPathComponent("guard/a-off")
    }
    public static var log: URL { Captain.dir.appendingPathComponent("guard/identity.jsonl") }
    public enum Verdict: Equatable, Sendable { case ok, reject(String) }

    /// claimed＝自稱的 session；real＝程序鏈上最近的 Claude Code 的 session；live＝活著的 session。
    /// 沒有 Claude Code、編號也不是活著的 session（launchd 的空間守門員）⇒ 可以發卡
    public static func judge(claimed: String, real: String?, live: Set<String>) -> Verdict {
        if let real { return real == claimed ? .ok : .reject("自稱的 session 跟實際的不同") }
        return live.contains(claimed) ? .reject("找不到叫這個指令的 Claude Code，但自稱是開著的 session（脫離的背景程序請改在前景發）") : .ok
    }
    static func realSession() -> String? {
        guard let pid = Handover.claudePID() else { return nil }
        return NicknameStore.liveSessions().first { $0.pid == pid }?.sessionId ?? ""
    }
    /// 子指令用：對不上回原因並記錄
    public static func check(_ claimed: String) -> String? {
        guard CaptainLink.guardA, case .reject(let why) = judge(claimed: claimed, real: realSession(), live: Set(NicknameStore.liveSessions().map(\.sessionId))) else { return nil }
        note(why, claimed)
        return why
    }
    /// hook 用：父程序就是這個 session 的 Claude Code（AI 用 Bash 叫的中間會隔一層 shell）
    public static func isHook(of sid: String, parent: Int32 = getppid()) -> Bool {
        guard CaptainLink.guardA else { return true }
        let ok = hookOK(sid: sid, parent: parent, sessions: NicknameStore.liveSessions().map { ($0.pid, $0.sessionId) })
        if !ok { note("hook 的呼叫者不是這個 session 的 Claude Code，不給放行效果", sid) }
        return ok
    }
    static func hookOK(sid: String, parent: Int32, sessions: [(pid: Int32, sid: String)]) -> Bool {
        sessions.contains { $0.pid == parent && $0.sid == sid }
    }
    /// 上面有沒有 Claude Code（人用的指令要沒有才准）
    public static var insideClaude: Bool { Handover.claudePID() != nil || !(ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"] ?? "").isEmpty || ProcessInfo.processInfo.environment["CLAUDECODE"] != nil }

    static func note(_ why: String, _ sid: String) {
        let o: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "sid": sid, "why": why, "ppid": Int(getppid())]
        guard var d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        d.append(0x0A)
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: log) { _ = try? h.seekToEnd(); try? h.write(contentsOf: d); try? h.close() } else { try? d.write(to: log) }
    }
}
