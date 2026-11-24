import Darwin
import Foundation
import Security

/// 誰叫的 showork（防冒充方案 A，11-25）：往上找 Claude Code 程序，看它真的是哪個 session。
/// 擋順手冒充；同帳號的程式改 sessions 檔、換執行檔、改 hook，這裡擋不住。
public enum Caller {
    public static var log: URL { Captain.dir.appendingPathComponent("guard/identity.jsonl") }
    /// Claude Code 的簽章（Anthropic 的 Developer ID）；改名、複製別的程式冒充都對不上
    static let requirement = #"identifier "com.anthropic.claude-code" and anchor apple generic and certificate leaf[subject.OU] = Q6L2SF6YDW"#
    /// 這個執行中的程序是不是真的 Claude Code
    static func isClaude(_ pid: Int32) -> Bool {
        var code: SecCode?, req: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        if SecCodeCheckValidity(code, [], req) == errSecSuccess { return true }
        // Claude Code 自己更新後舊版檔案被刪、程序還在跑：讀不到檔就驗不了 ⇒ 改看核心記的身分（比較弱，只在檔案不在時用）
        return !FileManager.default.fileExists(atPath: exe(pid)) && kernelIdentity(pid).map { $0 == ("com.anthropic.claude-code", "Q6L2SF6YDW") } == true
    }
    /// 核心記的簽章身分（識別碼、團隊）；簽章無效就 nil
    static func kernelIdentity(_ pid: Int32) -> (String, String)? {
        typealias F = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        guard let h = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return nil }
        let csops = unsafeBitCast(h, to: F.self)
        var flags: UInt32 = 0
        guard csops(pid, 0, &flags, 4) == 0, flags & 1 == 1 else { return nil }       // CS_OPS_STATUS、CS_VALID
        func text(_ op: UInt32) -> String? {
            var b = [UInt8](repeating: 0, count: 1024)
            guard csops(pid, op, &b, b.count) == 0 else { return nil }
            return String(decoding: b.dropFirst(8).prefix { $0 != 0 }, as: UTF8.self)   // 前 8 位元組是標頭
        }
        guard let id = text(11), let team = text(14) else { return nil }
        return (id, team)
    }
    /// 自己是不是裝好的那一份 showork：實際執行檔和叫的名字都要是它（複製、改名、捷徑都不算）
    static func isInstalled(exe: String, argv0: String, installed: String) -> Bool { exe == installed && argv0 == installed }
    static func exe(_ pid: Int32) -> String {
        var b = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &b, UInt32(b.count)) > 0 ? String(cString: b) : ""
    }
    static var myExe: String { exe(getpid()) }
    static var installedPath: String { Paths.supportDir.appendingPathComponent("bin/showork").path }
    public enum Verdict: Equatable, Sendable { case ok, reject(String) }

    /// claimed＝自稱的 session；real＝程序鏈上最近的 Claude Code 的 session；live＝活著的 session。
    /// 沒有 Claude Code、編號也不是活著的 session（launchd 的空間守門員）⇒ 可以發卡
    public static func judge(claimed: String, real: String?, live: Set<String>) -> Verdict {
        if let real { return real == claimed ? .ok : .reject("自稱的 session 跟實際的不同") }
        return live.contains(claimed) ? .reject("找不到叫這個指令的 Claude Code，但自稱是開著的 session（脫離的背景程序請改在前景發）") : .ok
    }
    /// 程序鏈上最近的、簽章對得上的 Claude Code 是哪個 session（有 Claude Code 但沒登記＝空字串）
    static func realSession(startingAt pid: Int32 = getppid(), records: [Int32: String]? = nil, isClaude: (Int32) -> Bool = Caller.isClaude) -> String? {
        let recs = records ?? Dictionary(NicknameStore.liveSessions().map { ($0.pid, $0.sessionId) }, uniquingKeysWith: { a, _ in a })
        var p = pid
        for _ in 0..<16 {
            guard p > 1, let info = TTYFinder.kinfo(p) else { return nil }
            if isClaude(p), let s = recs[p] { return s }
            p = info.kp_eproc.e_ppid
        }
        return nil
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
        let ok = hookOK(sid: sid, parent: parent, sessions: NicknameStore.liveSessions().map { ($0.pid, $0.sessionId) }) && isClaude(parent)
            && isInstalled(exe: myExe, argv0: CommandLine.arguments[0], installed: installedPath)
        if !ok { note("hook 的呼叫者不是這個 session 的 Claude Code，不給放行效果", sid) }
        return ok
    }
    static func hookOK(sid: String, parent: Int32, sessions: [(pid: Int32, sid: String)]) -> Bool {
        sessions.contains { $0.pid == parent && $0.sid == sid }
    }
    public static func record(_ what: String, sid: String) { note(what, sid) }
    static func note(_ why: String, _ sid: String) {
        let o: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "sid": sid, "why": why, "ppid": Int(getppid())]
        guard var d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        d.append(0x0A)
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: log) { _ = try? h.seekToEnd(); try? h.write(contentsOf: d); try? h.close() } else { try? d.write(to: log) }
    }
}
