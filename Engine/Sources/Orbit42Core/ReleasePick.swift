import Foundation

/// 11-28 Keng：「放行！全部」碰到對外動作（部署、送 LINE、推 GitHub⋯）不直接放，改發多選答案卡跟他確認。
/// 看板自己發的題（action＝release-pick，AI 的 card --ask 設不了、改不了選項）；每個選項＝一張對外單，最多 4 個一題，多的接下一題。
/// 按選項只打勾，按「確認放行」才送；送來的必須是 chosen（勾了哪幾個），一般文字答案、終端機打字、AI 傳的一律不算。
public enum ReleasePick {
    public static let action = "release-pick"
    public static let perCard = 4

    /// 只動本機的擋單（rm 刪除）照放；其他一律當對外（部署、上傳、LINE、gh、push 掃到的、看不出要跑什麼的都要勾選確認）
    public static func isOutward(_ i: CaptainInboxItem) -> Bool {
        !(!i.kinds.isEmpty && i.kinds.allSatisfy { $0.hasPrefix("rm 刪除") })
    }

    /// 送去哪裡（白話）
    static func dest(_ kinds: [String]) -> String {
        let k = kinds.joined(separator: " ")
        if k.contains("firebase") { return "Firebase 網站（上線）" }
        if k.contains("App 上傳") { return "App Store Connect" }
        if k.contains("LINE") { return "LINE" }
        if k.contains("GitHub") || k.contains("push") { return "GitHub" }
        return "外部（看不出要送去哪）"
    }

    /// 一個選項：誰、要做什麼、送去哪裡（單號放最前面，介面和紀錄都對得上）
    public static func option(_ i: CaptainInboxItem) -> String {
        let what = i.text.replacingOccurrences(of: "\n", with: " ")
        return "\(i.id)　\(CaptainLink.label(i.name, i.project))：\(i.kinds.joined(separator: "、"))，送到 \(dest(i.kinds))｜\(what.count > 80 ? String(what.prefix(80)) + "⋯" : what)"
    }

    /// 發卡：每 perCard 張一題，排在 sid 的「等你回答」。同一張單已經在別題等勾選的不重發
    @discardableResult
    public static func put(sid: String, items: [CaptainInboxItem], now: Date) -> [PendingAsk] {
        AskQueue.locked {
            var xs = AskQueue.load(sid)
            let asked = Set(xs.filter { $0.action == action }.flatMap { $0.picks ?? [] })
            let todo = items.filter { !asked.contains($0.id) }
            let pages = stride(from: 0, to: todo.count, by: perCard).map { Array(todo[$0..<min($0 + perCard, todo.count)]) }
            let made: [PendingAsk] = pages.enumerated().map { k, page in
                var q = PendingAsk(id: AskQueue.newID(), ask: "「放行！全部」裡有 \(todo.count) 張對外的單，要你勾選確認"
                                   + (pages.count > 1 ? "（第 \(k + 1)/\(pages.count) 張卡：\(page.map(\.id).joined(separator: "、"))）" : "（\(page.map(\.id).joined(separator: "、"))）")
                                   + "。勾要放的，再按「確認放行」；沒勾的維持擋下。",
                                   options: page.map(option), at: now.addingTimeInterval(Double(k) * 0.001), doing: "放行！全部")
                q.action = action; q.multi = true; q.picks = page.map(\.id)
                return q
            }
            xs += made; AskQueue.save(sid, xs)
            return made
        }
    }

    public enum Outcome: Equatable, Sendable {
        case done(released: [CaptainInboxItem], kept: [String])     // 送出了：放了哪些、沒勾維持擋下的單號
        case rejected(String)                                       // 沒送出（題目留著，或已經不在）
    }
    enum Hit { case ok(PendingAsk), no(String) }

    /// 按「確認放行」／「全部不放」：只有本人在介面上按的（Mac 卡片、球體、手機、網頁 ⇒ speaker .card）才算。
    /// chosen＝勾了第幾個（0 起算）；空＝全部不放。題目一把鎖拿掉（同題不能送兩次）
    public static func answer(sid: String, askId: String, chosen: [Int], speaker: CaptainInbox.Speaker, by: String, byName: String, source: String, now: Date) -> Outcome {
        guard speaker == .card else { return .rejected("這題只能在答案卡上勾選後按「確認放行」，AI 傳的、打字的都不算") }
        let hit: Hit = AskQueue.locked {
            var xs = AskQueue.load(sid)
            guard let i = xs.firstIndex(where: { $0.id == askId && $0.action == action }), now.timeIntervalSince(xs[i].at) < AskQueue.ttl else { return .no("這題已經答過或已收掉，沒有送出") }
            let n = xs[i].picks?.count ?? 0
            guard Set(chosen).count == chosen.count, chosen.allSatisfy({ (0..<n).contains($0) }) else { return .no("勾選的對不上這張卡，沒有送出") }
            guard xs[i].sendingAt == nil, xs[i].unsureAt == nil else { return .no("這題正在送，沒有再送一次") }
            let q = xs.remove(at: i)
            AskQueue.save(sid, xs)
            return .ok(q)
        }
        let q: PendingAsk
        switch hit { case .ok(let x): q = x; case .no(let m): return .rejected(m) }
        let ids = q.picks ?? [], pick = Set(chosen.map { ids[$0] })
        let done = ids.filter(pick.contains).compactMap {
            CaptainInbox.release(id: $0, target: nil, by: by, byName: byName + "（放行！全部・勾選確認）", source: source + "・放行！全部（勾選）", now: now)
        }
        return .done(released: done, kept: ids.filter { !pick.contains($0) })
    }

    /// 送出後的明細
    public static func summary(_ o: Outcome) -> String {
        switch o {
        case .rejected(let m): return m
        case .done(let xs, let kept):
            return (xs.isEmpty ? "這張卡一張都沒放" : CaptainInbox.allDetail(xs, tag: "勾選確認"))
                + (kept.isEmpty ? "" : "\n沒勾、維持擋下：\(kept.joined(separator: "、"))")
        }
    }
}
