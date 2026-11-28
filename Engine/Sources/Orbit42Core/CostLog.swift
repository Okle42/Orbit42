import Foundation

// 11-28 OpenJarvis 升級 B 組⑤：花費紀錄。
// 讀 Claude Code 自己留在本機的對話紀錄（~/.claude/projects/*/<session>.jsonl，子 agent 在 <session>/subagents/*.jsonl），
// 每則回覆的 usage（輸入、輸出、快取寫入／讀取 token）照公開 API 牌價換成「約當 API 價格」的美金（訂閱制實際不照這個收費，是用來比大小）。
// 依每分鐘分桶存在 board/cost/cache.json（檔案沒變就不重讀），所以「今天／這週／某張派工單的時段」都能從桶子加總；
// 「多久」＝有在動的分鐘數（那一分鐘有任何回覆就算一分鐘）。只讀本機檔案、只寫本機，不上傳。
public enum CostLog {
    // MARK: 價格（每百萬 token，美金；11-28 依 claude-api skill 的牌價表）

    public struct Price: Sendable, Equatable {
        public var input: Double, output: Double, cacheRead: Double
        /// 快取寫入：5 分鐘＝輸入 1.25 倍、1 小時＝2 倍
        public var write5m: Double { input * 1.25 }
        public var write1h: Double { input * 2 }
    }

    /// 由長到短比對模型名字首；認不得的照 Opus 5.5 算（寧可高估）
    static let prices: [(String, Price)] = [
        ("claude-fable-5-2", Price(input: 8, output: 40, cacheRead: 0.2)),
        ("claude-mythos-5-2", Price(input: 8, output: 40, cacheRead: 0.2)),
        ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 1.0)),
        ("claude-mythos-5", Price(input: 10, output: 50, cacheRead: 1.0)),
        ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.2)),
        ("claude-opus-5", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-sonnet-5-5", Price(input: 2, output: 10, cacheRead: 0.1)),
        ("claude-sonnet-5", Price(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-4", Price(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-haiku-5-5", Price(input: 0.1, output: 0.5, cacheRead: 0.01)),
        ("claude-haiku-4", Price(input: 1, output: 5, cacheRead: 0.1)),
    ]
    public static func price(_ model: String) -> Price {
        let m = model.lowercased()
        return prices.first { m.hasPrefix($0.0) }?.1 ?? prices.first { $0.0 == "claude-opus-5-5" }!.1
    }

    public struct Usage: Sendable, Equatable {
        public var input = 0, output = 0, write5m = 0, write1h = 0, cacheRead = 0
        public var fast = false
        public var tokens: Int { input + output + write5m + write1h + cacheRead }
        public init(input: Int = 0, output: Int = 0, write5m: Int = 0, write1h: Int = 0, cacheRead: Int = 0, fast: Bool = false) {
            self.input = input; self.output = output; self.write5m = write5m; self.write1h = write1h; self.cacheRead = cacheRead; self.fast = fast
        }
        public func usd(_ model: String) -> Double {
            let p = price(model)
            let base = (Double(input) * p.input + Double(output) * p.output + Double(write5m) * p.write5m
                        + Double(write1h) * p.write1h + Double(cacheRead) * p.cacheRead) / 1_000_000
            return fast ? base * 2 : base
        }
    }

    static func usage(_ u: [String: Any]) -> Usage {
        func n(_ k: String, _ o: [String: Any] = u) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
        var x = Usage(input: n("input_tokens"), output: n("output_tokens"), cacheRead: n("cache_read_input_tokens"))
        if let c = u["cache_creation"] as? [String: Any] {
            x.write5m = n("ephemeral_5m_input_tokens", c); x.write1h = n("ephemeral_1h_input_tokens", c)
        } else { x.write5m = n("cache_creation_input_tokens") }
        x.fast = (u["speed"] as? String) == "fast"
        return x
    }

    // MARK: 一個檔案 ⇒ 每分鐘的桶子

    public struct Bucket: Codable, Sendable, Equatable {
        public var usd: Double
        public var tokens: Int
        public var out: Int
    }
    public struct FileCost: Codable, Sendable, Equatable {
        public var session: String
        public var cwd: String?
        public var mtime: Double
        public var size: Int
        public var minutes: [Int: Bucket]       // key＝epoch 分鐘
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static func date(_ s: String) -> Date? { iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) }

    /// 讀一個 jsonl：同一則回覆（message.id）會出現好幾行（每個內容區塊一行），只算最後一次
    public static func parse(_ data: Data, session: String) -> FileCost {
        var last: [String: (Date, String, Usage)] = [:], order: [String] = []
        var cwd: String?
        let needle = Data("\"usage\"".utf8)
        for line in data.split(separator: 0x0A) where line.range(of: needle) != nil {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
                  let ts = (o["timestamp"] as? String).flatMap(date) else { continue }
            let model = m["model"] as? String ?? ""
            if model == "<synthetic>" { continue }
            if cwd == nil { cwd = o["cwd"] as? String }
            let id = (m["id"] as? String) ?? (o["requestId"] as? String) ?? (o["uuid"] as? String) ?? UUID().uuidString
            if last[id] == nil { order.append(id) }
            last[id] = (ts, model, usage(u))
        }
        var mins: [Int: Bucket] = [:]
        for id in order {
            guard let (t, model, u) = last[id] else { continue }
            let k = Int(t.timeIntervalSince1970 / 60)
            var b = mins[k] ?? Bucket(usd: 0, tokens: 0, out: 0)
            b.usd += u.usd(model); b.tokens += u.tokens; b.out += u.output
            mins[k] = b
        }
        return FileCost(session: session, cwd: cwd, mtime: 0, size: data.count, minutes: mins)
    }

    // MARK: 全部檔案（有快取）

    public static var projectsDir: URL { TestEnv.home.appendingPathComponent(".claude/projects", isDirectory: true) }
    public static var dir: URL { Paths.supportDir.appendingPathComponent("board/cost", isDirectory: true) }
    public static var cacheURL: URL { dir.appendingPathComponent("cache.json") }

    /// 掃 projects 底下所有 jsonl（since 之前就沒再動過的檔不看）；變過的才重讀，結果寫回快取
    public static func refresh(root: URL = projectsDir, cache: URL = cacheURL, since: Date) -> [String: FileCost] {
        var known = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode([String: FileCost].self, from: $0) } ?? [:]
        let fm = FileManager.default
        var changed = false
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return known }
        for case let u as URL in en where u.pathExtension == "jsonl" {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), let mt = v.contentModificationDate?.timeIntervalSince1970 else { continue }
            if mt < since.timeIntervalSince1970 { continue }
            let size = v.fileSize ?? 0
            if let k = known[u.path], k.mtime == mt, k.size == size { continue }
            // 子 agent：<session>/subagents/agent-x.jsonl 算在 <session> 頭上
            let parts = u.pathComponents
            let session = parts.count >= 3 && parts[parts.count - 2] == "subagents" ? parts[parts.count - 3] : u.deletingPathExtension().lastPathComponent
            guard let d = try? Data(contentsOf: u, options: .mappedIfSafe) else { continue }
            var fc = parse(d, session: session)
            fc.mtime = mt; fc.size = size
            known[u.path] = fc; changed = true
        }
        if changed {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // 快取只留 35 天內的桶子
            let floor = Int(Date().timeIntervalSince1970 / 60) - 35 * 24 * 60
            var slim = known
            for (k, v) in slim { var x = v; x.minutes = v.minutes.filter { $0.key >= floor }; slim[k] = x }
            if let d = try? JSONEncoder().encode(slim) { try? d.write(to: cache, options: .atomic) }
        }
        return known
    }

    // MARK: 加總

    public struct SessionCost: Sendable, Equatable {
        public var session: String
        public var cwd: String?
        public var usd: Double = 0
        public var tokens: Int = 0
        public var output: Int = 0
        public var minutes: Int = 0     // 有在動的分鐘數
        public var first: Date?
        public var last: Date?
    }

    public static func sum(_ files: [String: FileCost], from: Date, to: Date, session: String? = nil) -> [String: SessionCost] {
        let a = Int(from.timeIntervalSince1970 / 60), b = Int(to.timeIntervalSince1970 / 60)
        var out: [String: SessionCost] = [:]
        var active: [String: Set<Int>] = [:]
        for f in files.values where session == nil || f.session == session {
            for (k, x) in f.minutes where k >= a && k < b {
                var s = out[f.session] ?? SessionCost(session: f.session, cwd: f.cwd)
                s.usd += x.usd; s.tokens += x.tokens; s.output += x.out
                let t = Date(timeIntervalSince1970: Double(k) * 60)
                s.first = min(s.first ?? t, t); s.last = max(s.last ?? t, t)
                if s.cwd == nil { s.cwd = f.cwd }
                out[f.session] = s
                active[f.session, default: []].insert(k)
            }
        }
        for (k, v) in active { out[k]?.minutes = v.count }
        return out
    }

    /// 一張派工單的花費：接單的 session 在「派出 → 最後一次回報（還開著就到現在）」之間的用量
    public static func task(_ t: CaptainTask, files: [String: FileCost], now: Date = Date()) -> SessionCost? {
        guard let sid = t.toSession else { return nil }
        let end = t.state.open ? now : t.updatedAt.addingTimeInterval(60)
        return sum(files, from: t.createdAt, to: end, session: sid)[sid]
    }

    // MARK: 文字

    public static func money(_ x: Double) -> String { x >= 10 ? String(format: "$%.0f", x) : String(format: "$%.2f", x) }
    public static func tok(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }
    public static func dur(_ m: Int) -> String { m >= 60 ? "\(m / 60) 小時 \(m % 60) 分" : "\(m) 分" }

    /// 週摘要（Markdown）：每天合計、花最多的 session、派工單
    public static func weekly(_ files: [String: FileCost], end: Date, names: (String) -> String, tasks: [CaptainTask], cal: Calendar = .current) -> String {
        let endDay = cal.startOfDay(for: end).addingTimeInterval(86400)
        let start = endDay.addingTimeInterval(-7 * 86400)
        let df = DateFormatter(); df.dateFormat = "MM-dd（E）"; df.locale = Locale(identifier: "zh_TW")
        var lines = ["# Orbit42 花費週摘要 \(df.string(from: start)) ～ \(df.string(from: endDay.addingTimeInterval(-1)))", "",
                     "（約當 API 牌價估算；訂閱制實際不照這個收費，用來比誰花得多）", ""]
        let all = sum(files, from: start, to: endDay)
        let total = all.values.reduce(0) { $0 + $1.usd }
        lines.append("合計 **\(money(total))**、\(tok(all.values.reduce(0) { $0 + $1.tokens })) token、\(all.count) 個 session、有在動 \(dur(all.values.reduce(0) { $0 + $1.minutes }))")
        lines += ["", "## 每天", "", "| 日期 | 花費 | session 數 |", "|---|---|---|"]
        for i in 0..<7 {
            let a = start.addingTimeInterval(Double(i) * 86400)
            let d = sum(files, from: a, to: a.addingTimeInterval(86400))
            lines.append("| \(df.string(from: a)) | \(money(d.values.reduce(0) { $0 + $1.usd })) | \(d.count) |")
        }
        lines += ["", "## 花最多的 session", "", "| session | 花費 | token | 有在動 |", "|---|---|---|---|"]
        for s in all.values.sorted(by: { $0.usd > $1.usd }).prefix(10) {
            lines.append("| \(names(s.session)) | \(money(s.usd)) | \(tok(s.tokens)) | \(dur(s.minutes)) |")
        }
        let ts = tasks.filter { $0.createdAt >= start && $0.createdAt < endDay }.compactMap { t in task(t, files: files, now: end).map { (t, $0) } }
        if !ts.isEmpty {
            lines += ["", "## 派工單", "", "| 單號 | 標題 | 誰 | 花費 | 有在動 |", "|---|---|---|---|---|"]
            for (t, c) in ts.sorted(by: { $0.1.usd > $1.1.usd }).prefix(15) {
                lines.append("| \(t.id) | \(t.title ?? String(t.text.prefix(14))) | \(t.to) | \(money(c.usd)) | \(dur(c.minutes)) |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
