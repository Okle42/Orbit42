import Foundation

/// 放行的暗號（Keng 11-25）：整句開頭是「放行！」（全形半形驚嘆號都收）才算；其他話一律不記任何放行。
/// 所有入口（終端機打字、答案卡、戰情傳話、手機傳話）都經 CaptainInbox.decide，這裡是唯一的判斷。
public enum ReleaseWord: Equatable, Sendable {
    case none                       // 沒有暗號
    case latest                     // 放行！
    case id(String)                 // 放行！BABCD
    case kinds(String)              // 放行！部署（後面的字交給 authorizes 看種類）
    case bad(String)                // 有暗號但不成立：原因

    /// 頭尾只去一般空白；零寬字、引號、別的正規化都不算
    static func trim(_ s: String) -> String {
        let ws: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{3000}"]
        var u = Array(s.unicodeScalars)
        while let c = u.first, ws.contains(c) { u.removeFirst() }
        while let c = u.last, ws.contains(c) { u.removeLast() }
        return String(String.UnicodeScalarView(u))
    }

    public static func parse(_ raw: String) -> ReleaseWord {
        let t = trim(raw), u = Array(t.unicodeScalars)
        guard u.count >= 3, u[0] == "放", u[1] == "行", u[2] == "！" || u[2] == "!" else { return .none }
        // 夾著別的 session 的訊息、貼上的內容：不是本人打的整句
        guard !Peer.quotesPeer(t), !t.contains("<pasted_content"), !t.contains("[Pasted text") else { return .none }
        let rest = trim(String(String.UnicodeScalarView(u.dropFirst(3))))
        if rest.isEmpty { return .latest }
        if CaptainInbox.isQuestion(rest) { return .bad("這是問句") }
        if CaptainInbox.isNegated(rest) { return .bad("句子裡有否定或延後的字") }
        if rest.contains(where: \.isNewline) { return .bad("只能一行") }
        if rest.range(of: "^[Bb][A-Za-z2-9]{4}$", options: .regularExpression) != nil { return .id(rest.uppercased()) }
        return .kinds(rest)
    }
    /// 事先放行：這句有沒有點名這條規則
    public static func grants(_ raw: String, rule: String) -> Bool {
        if case .kinds(let t) = parse(raw) { return CaptainInbox.authorizes(t, rule: rule) }
        return false
    }
    /// 「放行」開頭但沒有暗號（給提示用）
    public static func nearMiss(_ raw: String) -> Bool { parse(raw) == .none && trim(raw).hasPrefix("放行") }
    public static let how = "要放行請用打的：放行！單號（要有驚嘆號；語音聽寫通常沒有）"
}

extension CaptainInbox {
    static func isNegated(_ s: String) -> Bool {
        let a = s.lowercased()
        return a.contains("不") || negations.contains { a.range(of: $0, options: .regularExpression) != nil } || deferrals.contains { a.contains($0) }
    }
    /// 誰說的：keyboard＝本人在終端機打；card＝本人在 Mac 介面按／打（答案卡、戰情傳話）；phone＝手機傳話（以前不能放行單號 ⇒ 只能事先放行種類）；none＝不算（CLI、手機答案卡打字、卡片打進終端機的）
    public enum Speaker: Sendable { case keyboard, card, phone, none }
    public enum Decision: Equatable, Sendable {
        case none
        case released(CaptainInboxItem)
        case recorded(String)           // 事先放行的種類
        case missed(String)             // 有暗號但沒放行：要告訴 AI 的話
    }

    /// 唯一會放行／記事先放行的地方（秘書 release 指令另有自己的條件）
    public static func decide(sid: String, text: String, speaker: Speaker, by: String, byName: String, source: String, question: String? = nil, now: Date) -> Decision {
        guard speaker != .none else { return .none }
        func miss(_ why: String) -> Decision {
            let ids = open(sid, now).map(\.id)
            return .missed("使用者打了「放行！」，但這次沒有放行任何東西：\(why)。" + (ids.isEmpty ? "這個 session 沒有等放行的單。" : "等放行的單：\(ids.joined(separator: "、"))。") + ReleaseWord.how + "。")
        }
        let word = ReleaseWord.parse(text)
        if speaker == .phone { switch word { case .latest, .id: return miss("手機傳話不能放行單號，請到電腦打"); default: break } }
        switch word {
        case .none: return .none
        case .bad(let why): return miss(why)
        case .latest:
            let xs = open(sid, now)
            guard xs.count == 1 else { return miss(xs.isEmpty ? "沒有單可放" : "有 \(xs.count) 張單在等，要寫單號") }
            guard let i = release(id: xs[0].id, target: sid, by: by, byName: byName, source: source, now: now) else { return miss("找不到單") }
            return .released(i)
        case .id(let id):
            guard let i = release(id: id, target: sid, by: by, byName: byName, source: source, now: now) else { return miss("找不到單號 \(id)（打錯、別的 session 的、已放行過、或超過一天）") }
            return .released(i)
        case .kinds(let t):
            let ks = preapprovalActions.map(\.rule).filter { authorizes(t, rule: $0) }
            guard !ks.isEmpty else { return miss("看不出要放行哪一種動作或哪個單號") }
            recordAnswer(sid: sid, answer: text, question: question, now: now)
            return .recorded(ks.joined(separator: "、"))
        }
    }
    static func open(_ sid: String, _ now: Date) -> [CaptainInboxItem] {
        all().filter { $0.kind == .block && $0.sid == sid && $0.released == nil && now.timeIntervalSince($0.at) < blockWindow }
    }
}
