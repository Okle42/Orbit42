import Foundation

// 11-25 Keng：戰情清單的名卡可以自己拖動排序。Mac 與手機同一份，存在 Mac（board/card-order.json）。
// 記的是「這個人」：/clear、交接換了 sessionId 用 JobRecord.prev 認回來；換工作、狀態、cd 都不影響；離線再上線回原位（記 7 天）。
// 沒排過＝預設（WorkLabels.before）；排過之後新來的放最後。

public struct CardOrder: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var key: String           // 最後知道的 sessionId
        public var seen: Date            // 最後在線
        public var auto: Bool? = nil     // 自己排到最後的新人（Keng 還沒動過）
        public init(key: String, seen: Date, auto: Bool? = nil) { self.key = key; self.seen = seen; self.auto = auto }
    }
    public var entries: [Entry] = []     // 空的＝沒排過
    public init() {}
    public var manual: Bool { !entries.isEmpty }

    public static let keep: TimeInterval = 7 * 86400, limit = 200

    /// 在線的人照這份順序排；順便更新（換 id、新人、過期）。live 已經是預設順序
    public mutating func reconcile(_ live: [(sid: String, prev: [String])], now: Date) -> [String] {
        var seenSid = Set<String>()
        let live = live.filter { seenSid.insert($0.sid).inserted }
        guard manual else { return live.map(\.sid) }
        let ids = Set(live.map(\.sid))
        // 換過 id 的人：原本那格換成新 id；新 id 若已經被當新人排到最後，拿掉後面那格
        for p in live where !p.prev.isEmpty {
            let own = entries.firstIndex { $0.key == p.sid }
            if let o = own, entries[o].auto != true { continue }
            let old = Set(p.prev).subtracting(ids)
            guard let i = entries.firstIndex(where: { old.contains($0.key) }) else { continue }
            entries[i].key = p.sid
            entries = entries.enumerated().filter { $0.offset == i || !($0.element.key == p.sid || old.contains($0.element.key)) }.map(\.element)
        }
        var have = Set<String>()
        entries = entries.filter { have.insert($0.key).inserted && (ids.contains($0.key) || now.timeIntervalSince($0.seen) < Self.keep) }
        for i in entries.indices where ids.contains(entries[i].key) && now.timeIntervalSince(entries[i].seen) > 3600 { entries[i].seen = now }
        for p in live where !have.contains(p.sid) { entries.append(Entry(key: p.sid, seen: now, auto: true)) }
        while entries.count > Self.limit, let i = entries.indices.filter({ !ids.contains(entries[$0].key) }).min(by: { entries[$0].seen < entries[$1].seen }) { entries.remove(at: i) }
        return entries.map(\.key).filter(ids.contains)
    }

    /// 排好的樣子：只把 wanted 這些人在「他們原本佔的格子」裡重排，其他人不動 ⇒ 不掉、不重複；只送一部分也行
    public static func arrange(_ now: [String], wanted: [String]) -> [String] {
        let all = Set(now)
        var seen = Set<String>()
        let w = wanted.filter { all.contains($0) && seen.insert($0).inserted }
        var it = w.makeIterator()
        return now.map { seen.contains($0) ? it.next()! : $0 }
    }

    /// Keng 放開了：current＝現在在線的順序
    public mutating func apply(_ wanted: [String], live: [(sid: String, prev: [String])], now: Date) {
        let cur = reconcile(live, now: now)
        // 手機手上可能還是 /clear 前的 id
        var alias: [String: String] = [:]
        for p in live { for o in p.prev where alias[o] == nil { alias[o] = p.sid } }
        let ids = Set(cur)
        let w = wanted.map { ids.contains($0) ? $0 : alias[$0] ?? $0 }
        guard !w.filter(ids.contains).isEmpty else { return }
        if !manual { entries = cur.map { Entry(key: $0, seen: now, auto: nil) } }
        let keys = entries.map(\.key), next = Self.arrange(keys, wanted: w.filter(ids.contains))
        let by = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let moved = Set(w)
        entries = next.map { k in var e = by[k]!; if moved.contains(k) { e.auto = nil }; return e }
    }

    public static func valid(_ ids: [String]) -> Bool { ids.count <= limit && !ids.isEmpty && ids.allSatisfy { WebAction.sessionOK($0) } }

    // MARK: 讀寫
    public static var file: URL { Paths.supportDir.appendingPathComponent("board/card-order.json") }
    public static func load() -> CardOrder { (try? Data(contentsOf: file)).flatMap { try? BoardJSON.decoder.decode(CardOrder.self, from: $0) } ?? CardOrder() }
    public func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(self) { try? d.write(to: Self.file, options: .atomic) }
    }
}

extension WebRouter {
    /// 手機拖動名卡：POST /api/order {"ids":[…]} 或 {"reset":true}。只收這一個欄位，多帶別的就退；檢查跟 /api/say 一樣
    public static let orderPath = "/api/order"
    public enum OrderRequest: Equatable, Sendable { case set([String]), reset }
    public static func parseOrder(_ body: Data) -> OrderRequest? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], o.count == 1 else { return nil }
        if let n = o["reset"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue { return .reset }
        guard let ids = o["ids"] as? [String], CardOrder.valid(ids) else { return nil }
        return .set(ids)
    }
    public static func handleOrder(_ r: WebRequest, peer: String?, localIP: String?, token: String?, now: Date = Date(), limiter: inout WebRateLimiter,
                                   order: (OrderRequest) -> Bool, audit: (WebAuditEntry) -> Void = { _ in }) -> WebResponse {
        guard let peer, WebBind.isTailscale(peer) else { return .json(403, ["error": "只接受 Tailscale 連線"]) }
        guard peer != localIP else { return .json(403, ["error": "不接受 Mac mini 自己連自己"]) }
        guard token != nil else { return .json(403, ["error": "還沒設定 token（showork web enable）"]) }
        guard r.method == "POST" else { return .json(405, ["error": "方法不對"]) }
        func done(_ resp: WebResponse, _ msg: String) -> WebResponse {
            audit(WebAuditEntry(at: now, peer: peer, action: "order", target: nil, text: nil, status: resp.status, result: msg)); return resp
        }
        guard WebToken.matches(r.headers[tokenHeader], token) else { return done(.json(403, ["error": "token 不對"]), "token 不對") }
        guard (r.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else { return done(.json(415, ["error": "要 JSON"]), "不是 JSON") }
        guard limiter.allow(peer, now: now) else { return done(.json(429, ["error": "排太快了，等一下再試"]), "頻率限制") }
        guard let q = parseOrder(r.body) else { return done(.json(400, ["error": "只收名卡順序"]), "格式不對") }
        guard order(q) else { return done(.json(503, ["error": "戰情中心還沒準備好"]), "沒準備好") }
        return done(.json(200, ["ok": "1"]), q == .reset ? "恢復預設" : "改順序")
    }
}
