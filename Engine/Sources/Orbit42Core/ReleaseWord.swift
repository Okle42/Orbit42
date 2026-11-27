import Foundation

/// 放行的暗號（Keng 11-25）：整句開頭是「放行！」（全形半形驚嘆號都收）才算；其他話一律不記任何放行。
/// 所有入口（終端機打字、答案卡、戰情傳話、手機傳話）都經 CaptainInbox.decide，這裡是唯一的判斷。
public enum ReleaseWord: Equatable, Sendable {
    case none                       // 沒有暗號
    case latest                     // 放行！
    case id(String)                 // 放行！BABCD
    case kind(String)               // 放行！部署（完全等於固定清單；值＝規則名）
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
        guard !raw.unicodeScalars.contains(where: CharacterSet.newlines.contains) else { return .none }      // 整句單行才算
        let t = trim(raw), u = Array(t.unicodeScalars)
        guard u.count >= 3, u[0] == "放", u[1] == "行", u[2] == "！" || u[2] == "!" else { return .none }
        // 夾著別的 session 的訊息、貼上的內容：不是本人打的整句
        guard !Peer.quotesPeer(t), !t.contains("<pasted_content"), !t.contains("[Pasted text") else { return .none }
        // 白名單（Gavin5 退件後改）：空、一個單號、一個種類詞；多一個字都不算
        var r = Array(u.dropFirst(3))
        let ws: Set<Unicode.Scalar> = [" ", "\t", "\u{3000}"], end: Set<Unicode.Scalar> = ["。", ".", "！", "!", "，", ",", "、", "；", ";", "~", "～"]
        while let c = r.first, ws.contains(c) { r.removeFirst() }
        while let c = r.last, ws.contains(c) || end.contains(c) { r.removeLast() }
        let rest = String(String.UnicodeScalarView(r))
        if rest.isEmpty { return .latest }
        if rest.range(of: "\\A[Bb][A-HJ-NP-Za-hj-np-z2-9]{4}\\z", options: .regularExpression) != nil { return .id(rest.uppercased()) }
        if let k = rule(of: rest) { return .kind(k) }
        return .bad("「放行！」後面只能是一個單號或一個種類，多一個字都不算")
    }
    /// 事先放行：這句有沒有點名這條規則
    public static func grants(_ raw: String, rule: String) -> Bool {
        if case .kind(let k) = parse(raw) { return rule.hasPrefix(k) }
        return false
    }
    /// 「放行」開頭但沒有暗號（給提示用）
    public static func nearMiss(_ raw: String) -> Bool { parse(raw) == .none && trim(raw).hasPrefix("放行") }
    /// 種類的固定清單（Windows ReleaseWord.cs 同一份）。每一句都要本來就過得了 authorizes；刪檔不在內（一定要單號）
    static let words: [(rule: String, words: [String])] = [
        ("GitHub 公開發言", ["開 PR", "開 issue", "發 PR", "發 issue", "PR 留言", "issue 留言", "GitHub 留言", "發布", "create PR", "create issue"]),
        ("LINE 對外傳訊", ["傳 LINE", "發 LINE", "用 LINE 通知", "LINE 通知"]),
        ("firebase 部署", ["部署", "上線", "deploy"]),
        ("App 上傳", ["上傳", "送審", "上架", "TestFlight"])
    ]
    static func rule(of rest: String) -> String? {
        let r = rest.lowercased()
        return words.first { $0.words.contains { let w = $0.lowercased(); return r == w || r == w.replacingOccurrences(of: " ", with: "") } }?.rule
    }
    public static let how = "沒放行，請打：放行！單號，或放行！部署（要有驚嘆號，後面只能是一個單號或種類；語音聽寫通常沒有驚嘆號）"
}

extension CaptainInbox {
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
            // 11-28 Keng「放行那個也一定要修」：點名單號就認那張單，不管是哪個 session 發的（例如在秘書的卡片上按組員的單）。
            // 界線不變：只有本人輸入（keyboard／card）走得到這裡、一定要單號（「放行！」不帶單號仍只放自己 session 的）、紀錄寫明在誰那裡按的
            let owner = all().first { $0.id == id.uppercased() }?.sid
            let at = owner.map { $0 == sid ? "" : "（在 \(NicknameStore.get(sid)?.name ?? String(sid.prefix(8))) 的卡片／終端機放行別的 session 的單）" } ?? ""
            guard let i = release(id: id, target: nil, by: by, byName: byName + at, source: source, now: now) else { return miss("找不到單號 \(id)（打錯、已放行過、或超過一天）") }
            return .released(i)
        case .kind(let k):
            recordAnswer(sid: sid, answer: text, question: question, now: now)
            return .recorded(k)
        }
    }
    static func open(_ sid: String, _ now: Date) -> [CaptainInboxItem] {
        all().filter { $0.kind == .block && $0.sid == sid && $0.released == nil && now.timeIntervalSince($0.at) < blockWindow }
    }
}
