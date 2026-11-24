import Foundation

// 工作卡片自動轉送秘書（派工 T1021174030，10-21 Kang 拍板：秘書只審不做，每個 AI 工作時都要向秘書報告方法與工具）。
// 任何 session 跑 showork card，看板就把卡片內容以【工作回報】送給現任秘書（走派工回報同一條 Peer 路）。
//   • 秘書自己的卡不轉（迴圈）；秘書不在線就不送、也不堆積（那段期間的卡記成已看過）
//   • 不阻塞：發卡的 session 不等回覆
//   • 節流：同一 session 60 秒內只送一次（期間的新卡等時間到送最後一張）；內容沒變不重送
//   • 看板剛啟動時現有的卡當成已看過，不一次灌給秘書
//   • 設定 captain.relayCards（預設開）
//   • 11-10 秘書省額度（秘書一週被叫醒上千次、ctx 400–500k，燒掉 ≥37% 額度）：預設只推「要秘書動手」的卡
//       - captain.relayActionableOnly（預設 true）：只推 status review／blocked、或帶 --ask 的卡；done／working 只記在看板（名冊看得到），不推
//       - 開工卡只進秘書收件匣（巡檢或 showork captain 看），不推（11-24）

public enum CardRelay {
    public static let settingKey = "captain.relayCards"
    public static let minInterval: TimeInterval = 60
    /// 太舊的卡不轉（看板重開、秘書剛回來時不翻舊帳）
    public static let maxAge: TimeInterval = 10 * 60

    public struct State: Sendable, Equatable {
        public var sentKey: [String: String] = [:]     // sessionId → 上次送出（或看過）的內容
        public var sentAt: [String: Date] = [:]
        public var seeded = false
        public var sentAsk: [String: String] = [:]     // sessionId → 上次送出（或看過）的問題與選項
        public init() {}
        mutating func mark(_ sid: String, _ r: SelfReport) {
            let k = key(r)
            sentAsk[sid] = askKey(r)            // 問題拿掉也要記：之後同一題再問＝新的，要推
            sentKey[sid] = k
        }
        /// 送過了：內容一樣，而且沒有新的問題（問題從無到有、文字或選項改了＝要再送）
        func seen(_ sid: String, _ r: SelfReport) -> Bool {
            sentKey[sid] == key(r) && (askKey(r) == nil || askKey(r) == sentAsk[sid])
        }
    }

    /// 推送規則（11-10）；預設＝新行為，兩個開關都可以用 UserDefaults 改回舊的
    public struct Policy: Sendable, Equatable {
        public var actionableOnly: Bool      // captain.relayActionableOnly
        public init(actionableOnly: Bool) { self.actionableOnly = actionableOnly }
        public static let quiet = Policy(actionableOnly: true)
        public static let legacy = Policy(actionableOnly: false)
        public static let actionableKey = "captain.relayActionableOnly"
        /// 從設定讀（沒設過＝新行為）
        public static func from(_ d: UserDefaults?) -> Policy {
            Policy(actionableOnly: d?.object(forKey: actionableKey) as? Bool ?? true)
        }
    }

    /// 這張卡要不要推給秘書（不算節流、迴圈這些）：要秘書動手的才推
    public static func needsCaptain(_ r: SelfReport, policy: Policy) -> Bool {
        if r.isStart { return false }        // 11-24：開工卡一律只進收件匣
        if !policy.actionableOnly { return true }
        return r.status == .review || r.status == .blocked || r.ask != nil
    }

    public struct Outgoing: Sendable, Equatable {
        public var sessionId: String
        public var text: String
    }

    /// 同一張卡（11-24 Keng）：同 doing、同狀態、同摘要就算重複；問題另外比（askKey）
    public static func key(_ r: SelfReport) -> String {
        [r.kind ?? "", r.status.rawValue, r.doing ?? "", r.summary ?? ""].joined(separator: "\u{1F}")
    }
    static func askKey(_ r: SelfReport) -> String? {
        r.ask.map { ([$0] + (r.options ?? [])).joined(separator: "\u{1F}") }
    }

    /// 這次刷新要送哪些。captain＝現任秘書 sessionId（nil 或不在線 ⇒ 不送，全部記成看過）
    public static func plan(reports: [String: SelfReport], captain: String?, captainLive: Bool,
                            state: inout State, now: Date = Date(), policy: Policy = .quiet, text: (String, SelfReport) -> String) -> [Outgoing] {
        if !state.seeded {
            for (sid, r) in reports { state.mark(sid, r) }
            state.seeded = true
            return []
        }
        var out: [Outgoing] = []
        for sid in reports.keys.sorted() {
            guard let r = reports[sid] else { continue }
            if state.seen(sid, r) { state.mark(sid, r); continue }
            // 派工單的做完／要你決定／卡住已經有【派工回報】（TaskRouter），不重複送（10-21 秘書審查建議）
            let routed = r.task != nil && r.status != .working
            guard let cap = captain, captainLive, sid != cap, !routed, now.timeIntervalSince(r.at) < maxAge, needsCaptain(r, policy: policy) else {
                state.mark(sid, r)                         // 不送也不堆積
                continue
            }
            // 等時間到再送最後一張
            if let t = state.sentAt[sid], now.timeIntervalSince(t) < minInterval { continue }
            state.mark(sid, r)
            state.sentAt[sid] = now
            out.append(Outgoing(sessionId: sid, text: text(sid, r)))
        }
        return out
    }

    /// 【工作回報】全文
    public static func text(name: String, project: String?, report r: SelfReport) -> String {
        func cut(_ s: String, _ n: Int = 300) -> String { s.count > n ? String(s.prefix(n)) + "⋯" : s }
        var head = "【工作回報】\(name)"
        if let p = project, !p.isEmpty { head += "（\(p)）" }
        if let d = r.doing { head += "：\(d)" }
        var lines = [head]
        var st = "狀態 \(r.status.rawValue)"
        if let p = r.progress { st += "・完成度 \(p)%" }
        if let c = r.confidence { st += "・信心 \(c)%" }
        lines.append(st)
        if let s = r.summary, !s.isEmpty { lines.append("摘要：\(cut(s))") }
        lines.append("方法與工具：" + (r.how.map { cut($0) } ?? "（沒寫 --how）"))
        if let a = r.ask {
            lines.append("問使用者：\(cut(a))" + ((r.options ?? []).isEmpty ? "" : "（選項：\(r.options!.joined(separator: "／"))）"))
        }
        if let rp = r.report { lines.append("報告：\(rp)") }
        if let t = r.task { lines.append("派工單：\(t)") }
        lines.append("（看板自動轉送，對方不等你回覆；有疑慮再 SendMessage 給它）")
        return lines.joined(separator: "\n")
    }
}
