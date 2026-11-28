import Foundation
import SQLite3

/// 11-28 A 組②：個人資料的來源（全部唯讀）。
/// - iMessage：直接讀 ~/Library/Messages/chat.db（唯讀開、不寫、不鎖）；要「完全磁碟取用」才讀得到（11-28 Keng 同意要做）
///   一個對話一天併成一筆（搜尋結果才看得懂上下文），who＝對方帳號／群組名
/// - Gmail／Drive：交給本機 `claude -p` 用 Claude 已連好的連接器（claude.ai Gmail／Google Drive）唯讀查，吐 JSONL 回來（ConnectorSync）
/// - 行事曆：Mac 行事曆（EventKit）在 App 裡讀（要 App 的行事曆權限，CLI 沒有 Info.plist 拿不到）
public enum IMessageReader {
    public static var dbURL: URL { TestEnv.home.appendingPathComponent("Library/Messages/chat.db") }

    public enum Failure: Error, CustomStringConvertible {
        case noAccess(String)
        public var description: String { switch self { case .noAccess(let s): "讀不到 iMessage（要在「系統設定 › 隱私權與安全性 › 完全磁碟取用」打開 Orbit42）：\(s)" } }
    }

    /// Apple 的時間：2001-01-01 起的奈秒（舊版是秒）
    static func appleDate(_ v: Int64) -> Date {
        let s = v > 10_000_000_000 ? Double(v) / 1e9 : Double(v)
        return Date(timeIntervalSinceReferenceDate: s)
    }

    /// 最近 days 天的訊息，一個對話一天一筆
    public static func read(days: Int = 30, url: URL = dbURL, now: Date = Date(), cal: Calendar = .current) throws -> [PersonalDoc] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw Failure.noAccess(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }
        let since = Int64(now.addingTimeInterval(-Double(days) * 86400).timeIntervalSinceReferenceDate * 1e9)
        let sql = """
        SELECT m.date, m.text, m.attributedBody, m.is_from_me, IFNULL(h.id,''), IFNULL(c.chat_identifier,''), IFNULL(c.display_name,''), IFNULL(c.ROWID,0)
        FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join j ON j.message_id = m.ROWID LEFT JOIN chat c ON c.ROWID = j.chat_id
        WHERE m.date > ? ORDER BY m.date
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw Failure.noAccess(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, since)
        struct Day { var who: String; var first: Date; var last: Date; var lines: [String] }
        var days: [String: Day] = [:]
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        while sqlite3_step(st) == SQLITE_ROW {
            let at = appleDate(sqlite3_column_int64(st, 0))
            var text = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            if text.isEmpty, let p = sqlite3_column_blob(st, 2) {
                text = attributedText(Data(bytes: p, count: Int(sqlite3_column_bytes(st, 2)))) ?? ""
            }
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let me = sqlite3_column_int(st, 3) == 1
            let handle = String(cString: sqlite3_column_text(st, 4))
            let chat = String(cString: sqlite3_column_text(st, 5)), name = String(cString: sqlite3_column_text(st, 6))
            let chatKey = chat.isEmpty ? handle : chat
            let who = !name.isEmpty ? name : chatKey
            let key = chatKey + "|" + df.string(from: at)
            var d = days[key] ?? Day(who: who, first: at, last: at, lines: [])
            d.last = at
            d.lines.append("\(tf.string(from: at)) \(me ? "我" : (handle.isEmpty ? who : handle))：\(text)")
            days[key] = d
        }
        return days.map { k, d in
            PersonalDoc(source: .imessage, ref: k, title: "和 \(d.who) 的訊息（\(df.string(from: d.first))）", body: d.lines.joined(separator: "\n"),
                        who: d.who, at: d.last)
        }.sorted { $0.at < $1.at }
    }

    /// 新版 iMessage 把文字放在 attributedBody（NSArchiver 格式的 NSAttributedString）
    static func attributedText(_ d: Data) -> String? {
        if let u = try? NSUnarchiver.unarchiveObject(with: d) as? NSAttributedString { return u.string }
        // 退而求其次：找 "NSString" 之後的那段 UTF-8
        guard let r = d.range(of: Data("NSString".utf8)) else { return nil }
        var i = r.upperBound + 5
        guard i < d.count else { return nil }
        var len = Int(d[i - 1])
        if d[i - 1] == 0x81, i + 1 < d.count { len = Int(d[i]) | Int(d[i + 1]) << 8; i += 2 }
        guard len > 0, i + len <= d.count else { return nil }
        return String(data: d[i..<(i + len)], encoding: .utf8)
    }
}

/// Gmail／Drive：交給本機 claude -p（haiku）用 Claude 已連好的連接器唯讀查，叫它一行一筆 JSON 吐回來
public enum ConnectorSync {
    public enum Kind: String, CaseIterable, Sendable { case mail, drive }

    /// 只准用這幾個唯讀工具（不給寄信、刪信、改檔、分享）
    public static func tools(_ k: Kind) -> [String] {
        switch k {
        case .mail: ["mcp__claude_ai_Gmail__search_threads", "mcp__claude_ai_Gmail__get_thread"]
        case .drive: ["mcp__claude_ai_Google_Drive__search_files", "mcp__claude_ai_Google_Drive__read_file_content", "mcp__claude_ai_Google_Drive__get_file_metadata"]
        }
    }

    /// claude -p 的參數：只放行唯讀工具、內建工具一個都不給、不帶 hook、不存對話（prompt 從 stdin 送）
    public static func claudeArgs(_ k: Kind) -> [String] {
        ["-p", "--model", "haiku", "--settings", #"{"disableAllHooks":true}"#, "--no-session-persistence",
         "--tools", "", "--allowedTools", tools(k).joined(separator: ","), "--permission-mode", "default"]
    }

    public static func prompt(_ k: Kind, days: Int, now: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let since = f.string(from: now.addingTimeInterval(-Double(days) * 86400))
        switch k {
        case .mail:
            return """
            用 Gmail 工具唯讀抓資料，不要寄信、不要改標籤。
            1. search_threads，query 用 "after:\(since) -in:spam -in:trash"，view 用 THREAD_VIEW_SUMMARY，pageSize 50，最多翻 2 頁。
            2. 每個 thread 輸出一行 JSON（不要其他文字、不要程式碼框），欄位：
            {"source":"mail","ref":"<thread id>","title":"<主旨>","body":"<snippet 原文>","who":"<寄件人名字與信箱>","at":"<最新一封的時間，ISO 8601 含時區>","link":"<viewUrl>","flags":[<labelIds 原樣，例如 "UNREAD","IMPORTANT","CATEGORY_PROMOTIONS">]}
            內容照原文，不要摘要、不要翻譯、不要編造；沒有的欄位填空字串。
            """
        case .drive:
            return """
            用 Google Drive 工具唯讀抓資料，不要改檔、不要分享。
            1. search_files，query 用 "modifiedTime > '\(since.replacingOccurrences(of: "/", with: "-"))T00:00:00Z' and trashed = false"，orderBy "modifiedTime desc"，pageSize 50，snippetVerbosity BRIEF。
            2. 每個檔輸出一行 JSON（不要其他文字、不要程式碼框），欄位：
            {"source":"drive","ref":"<file id>","title":"<檔名>","body":"<內容片段原文>","who":"<擁有者或最後修改者>","at":"<modifiedTime，ISO 8601>","link":"<網址>"}
            內容照原文，不要摘要、不要編造；沒有的欄位填空字串。
            """
        }
    }

    /// claude 輸出 → 資料：只收對的來源；容忍它包了程式碼框或多講一兩句
    public static func parse(_ out: String, kind: Kind) -> [PersonalDoc] {
        let lines = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("{") }
        let src: PersonalDoc.Source = kind == .mail ? .mail : .drive
        return PersonalImport.parse(Data(lines.joined(separator: "\n").utf8)).docs.filter { $0.source == src && !$0.ref.isEmpty }
    }
}
