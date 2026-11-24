import Foundation

/// 登記秘書（防冒充方案 A）：已有在線秘書且不是自己 ⇒ 要 Keng 在 Mac 介面按同意；沒有在線的可以登記，但通知 Keng
public enum CaptainClaim {
    public static let yes = "同意換它當秘書", no = "不同意"
    public enum Decision: Equatable, Sendable { case ask, take(notify: Bool) }
    public static func decide(current: String?, me: String, live: Set<String>, on: Bool) -> Decision {
        guard on, current != me else { return .take(notify: false) }
        if let current, live.contains(current) { return .ask }
        return .take(notify: true)
    }
    public static func request(sid: String, name: String, now: Date) {
        put(sid, ask: "「\(name)」要當秘書，但現在已有在線的秘書。要換嗎？", options: [no, yes], action: "captain", now: now)
    }
    public static func announce(sid: String, name: String, now: Date) {
        put(sid, ask: "「\(name)」剛登記成秘書（原本沒有在線的秘書）。", options: ["知道了", "不是我要的"], action: nil, now: now)
    }
    static func put(_ sid: String, ask: String, options: [String], action: String?, now: Date) {
        AskQueue.locked {
            var xs = AskQueue.load(sid)
            guard !xs.contains(where: { $0.ask == ask }) else { return }
            var q = PendingAsk(id: AskQueue.newID(), ask: ask, options: options, at: now)
            q.action = action
            xs.append(q); AskQueue.save(sid, xs)
        }
    }
    /// 這個答案可以換秘書嗎：看板發的題、Mac 介面按的、按的是同意那個選項、沒有另外打字
    public static func approves(_ q: PendingAsk, option: String?, free: String?, fromMac: Bool) -> Bool {
        q.action == "captain" && fromMac && option == yes && (free ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
