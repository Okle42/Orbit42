import Foundation

/// 11-28 Keng（OpenJarvis 升級 A 組①）：語音晨報。
/// 今天的行程（本機索引的 calendar）＋要處理的信（mail，近 24 小時未讀／重要、不含促銷）＋Orbit42 看板上在等他回答的事，
/// 先照規則組成一份「一定對」的草稿；有 claude 就交給本機 `claude -p --model haiku` 改成 1 分鐘內的口語稿
/// （只准用草稿裡的事實），AI 失敗就念草稿。念的人是球體目前選的聲音，字幕一句一句跟著。
public enum MorningBrief {
    public struct Waiting: Sendable, Equatable { public var who: String; public var ask: String; public init(who: String, ask: String) { self.who = who; self.ask = ask } }

    public struct Facts: Sendable, Equatable {
        public var now: Date
        public var events: [PersonalDoc]
        public var mails: [PersonalDoc]
        public var waiting: [Waiting]
        /// 哪些來源還沒接（念的時候老實講，免得以為今天沒行程）
        public var missing: [PersonalDoc.Source]
        public init(now: Date, events: [PersonalDoc], mails: [PersonalDoc], waiting: [Waiting], missing: [PersonalDoc.Source] = []) {
            self.now = now; self.events = events; self.mails = mails; self.waiting = waiting; self.missing = missing
        }
    }

    /// 1 分鐘大約 250–280 個中文字（edge-tts 曉臻正常語速實測約 4.5 字／秒）
    public static let maxChars = 280

    // MARK: 收集

    static let skipFlags: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "SPAM", "TRASH", "SENT"]

    public static func gather(index: PersonalIndex?, asks: [String: [PendingAsk]], names: [String: String], now: Date = Date(), cal: Calendar = .current) -> Facts {
        let day0 = cal.startOfDay(for: now), day1 = cal.date(byAdding: .day, value: 1, to: day0)!
        var missing: [PersonalDoc.Source] = []
        let stats = (try? index?.stats()) ?? []
        func has(_ s: PersonalDoc.Source) -> Bool { stats.first { $0.0 == s }.map { $0.1 > 0 } ?? false }
        if !has(.calendar) { missing.append(.calendar) }
        if !has(.mail) { missing.append(.mail) }
        let events = ((try? index?.docs(.calendar, from: day0, to: day1)) ?? nil) ?? []
        let recent = ((try? index?.docs(.mail, from: now.addingTimeInterval(-24 * 3600), to: now.addingTimeInterval(60), limit: 200)) ?? nil) ?? []
        let mails = pickMails(recent)
        var waiting: [Waiting] = []
        for (sid, xs) in asks.sorted(by: { ($0.value.first?.at ?? now) < ($1.value.first?.at ?? now) }) {
            for q in AskQueue.live(xs, now: now) { waiting.append(Waiting(who: names[sid] ?? "一個 AI", ask: q.ask)) }
        }
        return Facts(now: now, events: events.filter { $0.end.map { $0 > now } ?? ($0.at > now.addingTimeInterval(-3600)) || cal.isDate($0.at, inSameDayAs: now) },
                     mails: mails, waiting: waiting, missing: missing)
    }

    /// 要處理的信：未讀或重要、不是促銷／社群；重要的先、再新的先，最多 3 封
    public static func pickMails(_ xs: [PersonalDoc], max: Int = 3) -> [PersonalDoc] {
        xs.filter { d in
            let f = Set(d.flags ?? [])
            return f.isDisjoint(with: skipFlags) && (f.contains("UNREAD") || f.contains("IMPORTANT") || f.contains("STARRED"))
        }
        .sorted { a, b in
            let ia = (a.flags ?? []).contains("IMPORTANT"), ib = (b.flags ?? []).contains("IMPORTANT")
            return ia != ib ? ia : a.at > b.at
        }
        .prefix(max).map { $0 }
    }

    // MARK: 規則草稿（一定念得出來、只講事實）

    static func clock(_ d: Date, cal: Calendar = .current) -> String {
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        let part = h < 12 ? "早上" : h < 13 ? "中午" : h < 18 ? "下午" : "晚上"
        let hh = h > 12 ? h - 12 : h
        return "\(part)\(hh)點" + (m == 0 ? "" : m == 30 ? "半" : "\(m)分")
    }

    static func short(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(Re|RE|Fwd|FW|回覆|轉寄)[:：]\s*"#, with: "", options: .regularExpression)
        return t.count <= n ? t : String(t.prefix(n))
    }

    static func person(_ who: String?) -> String {
        guard var w = who?.trimmingCharacters(in: .whitespaces), !w.isEmpty else { return "有人" }
        if let r = w.range(of: "<") { w = String(w[..<r.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        if w.contains("@") { w = String(w.split(separator: "@").first ?? "") }
        return w.isEmpty ? "有人" : short(w, 12)
    }

    public static func draft(_ f: Facts, cal: Calendar = .current) -> String {
        let h = cal.component(.hour, from: f.now)
        var s: [String] = [h < 11 ? "早安，晨報。" : h < 18 ? "午安，今天的簡報。" : "晚安，今天的簡報。"]
        if f.missing.contains(.calendar) { s.append("行事曆還沒接上，今天的行程我看不到。") }
        else if f.events.isEmpty { s.append("今天行事曆是空的。") }
        else {
            let first = f.events.prefix(4).map { "\(clock($0.at, cal: cal))\(short($0.title, 16))" }
            s.append("今天有 \(f.events.count) 個行程：" + first.joined(separator: "，") + (f.events.count > 4 ? "，還有 \(f.events.count - 4) 個" : "") + "。")
        }
        if f.missing.contains(.mail) { s.append("信箱還沒接上。") }
        else if f.mails.isEmpty { s.append("信箱沒有要急著處理的。") }
        else {
            s.append("要處理的信有 \(f.mails.count) 封：" + f.mails.map { "\(person($0.who))的「\(short($0.title, 16))」" }.joined(separator: "，") + "。")
        }
        if f.waiting.isEmpty { s.append("看板上沒有在等你的事。") }
        else {
            let who = Array(NSOrderedSet(array: f.waiting.map(\.who))) as? [String] ?? []
            s.append("看板上有 \(f.waiting.count) 件在等你回答" + (who.isEmpty ? "" : "，來自" + who.prefix(3).joined(separator: "、") + (who.count > 3 ? "等人" : "")) + "。")
        }
        s.append("以上。")
        var out = ""
        for x in s { if out.count + x.count > maxChars, x != "以上。" { continue }; out += x }
        return out
    }

    // MARK: AI 口語稿

    public static let system = """
    你是老闆的語音秘書，要把一份「晨報事實」改寫成早上念給他聽的口語稿。規則：繁體中文（台灣用語）；\
    念出來一分鐘內，全文不超過 260 個字；像同事早上當面跟他講，先講最要緊的（快到的行程、重要的信、在等他決定的事）；\
    時間念成「十點半」「下午兩點」；拿掉網址、信箱地址、編號、英文程式名稱、括號註解；人名、公司名照原文；\
    只能用事實裡有的內容，不可以補、不可以猜；事實說「沒接上」的就照講沒接上；只輸出稿子本身，不要標題、不要引號、不要條列符號。
    """

    /// claude -p 的參數：不帶 hook、不存對話、不給工具、不接 MCP（事實清單從 stdin 送）
    public static let claudeArgs = ["-p", "--model", "haiku", "--system-prompt", system, "--settings", #"{"disableAllHooks":true}"#,
                                    "--no-session-persistence", "--strict-mcp-config", "--tools", ""]

    /// 給 AI 的事實（條列，不給內文，免得它念信的內容）
    public static func factSheet(_ f: Facts, cal: Calendar = .current) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_TW"); df.dateFormat = "M月d日 EEEE HH:mm"
        var l = ["現在：\(df.string(from: f.now))"]
        if f.missing.contains(.calendar) { l.append("行事曆：還沒接上（看不到）") }
        else { l.append("今天行程 \(f.events.count) 個：") ; l += f.events.prefix(8).map { "- \(clock($0.at, cal: cal)) \(short($0.title, 40))" + ($0.who.map { "（\(person($0))）" } ?? "") } }
        if f.missing.contains(.mail) { l.append("信箱：還沒接上") }
        else { l.append("要處理的信 \(f.mails.count) 封：") ; l += f.mails.map { "- \(person($0.who))：\(short($0.title, 40))" + (($0.flags ?? []).contains("IMPORTANT") ? "（標重要）" : "") } }
        l.append("Orbit42 看板上在等他回答的事 \(f.waiting.count) 件：")
        l += f.waiting.prefix(5).map { "- \($0.who) 問：\(short($0.ask, 50))" }
        return l.joined(separator: "\n")
    }

    /// AI 輸出只收「一段、夠短、有中文、沒有程式碼框」
    public static func tidy(_ out: String) -> String? {
        var s = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { $0.replacingOccurrences(of: #"^[-*•#]+\s*"#, with: "", options: .regularExpression) }.joined()
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "「」『』\"“”'` "))
        guard !s.isEmpty, s.count <= maxChars + 40, !s.contains("```"), !s.hasPrefix("Error") else { return nil }
        guard s.unicodeScalars.filter({ (0x4E00...0x9FFF).contains($0.value) }).count >= 20 else { return nil }
        return s
    }

    /// 字幕一句一句出：在句號／問號／驚嘆號切；太長的句子在逗號再切（每句 ≤ 60 字）
    public static func sentences(_ text: String, max: Int = 60) -> [String] {
        var out: [String] = [], cur = ""
        for ch in text {
            cur.append(ch)
            if "。！？!?".contains(ch) { out.append(cur); cur = "" }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out.flatMap { s -> [String] in
            guard s.count > max else { return [s] }
            var parts: [String] = [], c = ""
            for ch in s { c.append(ch); if "，；、".contains(ch), c.count >= max / 2 { parts.append(c); c = "" } }
            if !c.isEmpty { parts.append(c) }
            return parts
        }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: 設定（時間可設，預設 08:30）

    public struct Settings: Codable, Sendable, Equatable {
        public var enabled = true
        public var hour = 8, minute = 30
        /// 這麼多秒內有碰鍵盤滑鼠才算「人在 Mac 前」
        public var presentWithin: TimeInterval = 120
        public init() {}
    }
    public static var settingsURL: URL { Paths.supportDir.appendingPathComponent("personal/morning.json") }
    public static func settings() -> Settings {
        FileManager.default.contents(atPath: settingsURL.path).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }
    public static func save(_ s: Settings) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(s).write(to: settingsURL, options: .atomic)
    }

    /// 該不該念：過了設定時間、今天還沒念過、人在 Mac 前（11 點以後就不補念了，免得中午突然唸早安）
    public static func due(_ s: Settings, now: Date, lastSaid: Date?, idle: TimeInterval, cal: Calendar = .current) -> Bool {
        guard s.enabled else { return false }
        if let l = lastSaid, cal.isDate(l, inSameDayAs: now) { return false }
        let mins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let at = s.hour * 60 + s.minute
        guard mins >= at, mins < max(at + 150, 11 * 60) else { return false }
        return idle <= s.presentWithin
    }
}
