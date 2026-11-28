import Foundation
import SQLite3

/// 11-28 Keng（OpenJarvis 升級 A 組②）：個人資料搜尋。
/// Gmail／行事曆／Drive／iMessage 的內容「唯讀」抓下來，只存本機一個 SQLite（FTS5）索引，`orbit search` 和球體搜尋都查這裡。
/// - 位置：~/Library/Application Support/Orbit42/personal/index.sqlite（資料夾 0700、檔 0600），不上傳任何地方
/// - 中文斷詞：FTS5 內建斷詞把一整串中文當一個詞、trigram 又查不到兩個字的詞（王董）⇒ 存進去前每個中文字中間插空白，
///   查的時候整段當片語（"王 董"）＝ 一個字以上的中文都查得到、而且要相連
/// - 結果一定帶出處：來源（信／行程／檔案／訊息）、標題、誰、日期、連結
public struct PersonalDoc: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case mail, calendar, drive, imessage
        public var zh: String { switch self { case .mail: "信"; case .calendar: "行程"; case .drive: "檔案"; case .imessage: "訊息" } }
    }
    public var source: Source
    public var ref: String          // 來源裡的唯一編號（信的 thread id、檔案 id、行程 id），同一個 ref 重抓＝更新
    public var title: String
    public var body: String
    public var who: String?         // 寄件人／主辦人／擁有者／對方
    public var at: Date             // 信：收到時間；行程：開始時間；檔案：最後修改
    public var end: Date? = nil     // 行程結束時間
    public var link: String? = nil  // 點了能打開原件的網址
    public var flags: [String]? = nil   // mail：unread、important、starred…（晨報挑「要處理的信」用）

    public init(source: Source, ref: String, title: String, body: String, who: String? = nil, at: Date, end: Date? = nil, link: String? = nil, flags: [String]? = nil) {
        self.source = source; self.ref = ref; self.title = title; self.body = body; self.who = who; self.at = at; self.end = end; self.link = link; self.flags = flags
    }
}

public struct PersonalHit: Sendable, Equatable {
    public var doc: PersonalDoc
    public var snippet: String
    /// 一行出處：「信｜王董｜11-27｜報價單」
    public var cite: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_TW"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return [doc.source.zh, doc.who, f.string(from: doc.at), doc.title].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: "｜")
    }
}

public enum PersonalIndexError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String { switch self { case .sqlite(let s): "索引讀寫失敗：\(s)" } }
}

public final class PersonalIndex {
    public static var defaultURL: URL {
        if let p = TestEnv.path("ORBIT_PERSONAL_INDEX") { return URL(fileURLWithPath: p) }
        return Paths.supportDir.appendingPathComponent("personal/index.sqlite")
    }

    private var db: OpaquePointer?
    public let url: URL

    public init(url: URL = PersonalIndex.defaultURL) throws {
        self.url = url
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw PersonalIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        chmod(url.path, 0o600)
        try exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS docs(id INTEGER PRIMARY KEY, source TEXT NOT NULL, ref TEXT NOT NULL, title TEXT, body TEXT, who TEXT,
          at REAL NOT NULL, end_at REAL, link TEXT, flags TEXT, indexed REAL, UNIQUE(source, ref));
        CREATE INDEX IF NOT EXISTS docs_at ON docs(source, at);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(title, body, who, tokenize='unicode61 remove_diacritics 2');
        """)
    }

    deinit { sqlite3_close(db) }

    // MARK: 寫

    /// 同一個 (source, ref) 重抓就覆蓋；回傳寫了幾筆
    @discardableResult
    public func upsert(_ docs: [PersonalDoc], now: Date = Date()) throws -> Int {
        try exec("BEGIN")
        var n = 0
        do {
            for d in docs {
                let id = try one("SELECT id FROM docs WHERE source=? AND ref=?", [d.source.rawValue, d.ref]) { sqlite3_column_int64($0, 0) }
                if let id {
                    try run("UPDATE docs SET title=?, body=?, who=?, at=?, end_at=?, link=?, flags=?, indexed=? WHERE id=?",
                            [d.title, d.body, d.who, d.at.timeIntervalSince1970, d.end?.timeIntervalSince1970, d.link, d.flags?.joined(separator: ","), now.timeIntervalSince1970, id])
                    try run("DELETE FROM fts WHERE rowid=?", [id])
                    try run("INSERT INTO fts(rowid, title, body, who) VALUES(?,?,?,?)", [id, Self.spaced(d.title), Self.spaced(d.body), Self.spaced(d.who ?? "")])
                } else {
                    try run("INSERT INTO docs(source, ref, title, body, who, at, end_at, link, flags, indexed) VALUES(?,?,?,?,?,?,?,?,?,?)",
                            [d.source.rawValue, d.ref, d.title, d.body, d.who, d.at.timeIntervalSince1970, d.end?.timeIntervalSince1970, d.link, d.flags?.joined(separator: ","), now.timeIntervalSince1970])
                    let id = sqlite3_last_insert_rowid(db)
                    try run("INSERT INTO fts(rowid, title, body, who) VALUES(?,?,?,?)", [id, Self.spaced(d.title), Self.spaced(d.body), Self.spaced(d.who ?? "")])
                }
                n += 1
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
        return n
    }

    // MARK: 讀

    /// 問題 → 符合的資料（相關度＋新的優先）。先要求每個關鍵詞都出現；一筆都沒有再放寬成任一個
    public func search(_ question: String, sources: Set<PersonalDoc.Source>? = nil, limit: Int = 8) throws -> [PersonalHit] {
        let terms = Self.keywords(question)
        guard !terms.isEmpty else { return [] }
        let phrases = terms.map { "\"" + Self.spaced($0).replacingOccurrences(of: "\"", with: "") + "\"" }
        for joiner in [" AND ", " OR "] {
            let hits = try query(phrases.joined(separator: joiner), terms: terms, sources: sources, limit: limit)
            if !hits.isEmpty || phrases.count == 1 { return hits }
        }
        return []
    }

    private func query(_ match: String, terms: [String], sources: Set<PersonalDoc.Source>?, limit: Int) throws -> [PersonalHit] {
        var sql = """
        SELECT d.source, d.ref, d.title, d.body, d.who, d.at, d.end_at, d.link, d.flags, bm25(fts, 5.0, 1.0, 3.0) AS r
        FROM fts JOIN docs d ON d.id = fts.rowid WHERE fts MATCH ?
        """
        var binds: [Any?] = [match]
        if let sources, !sources.isEmpty {
            sql += " AND d.source IN (" + sources.map { _ in "?" }.joined(separator: ",") + ")"
            binds += sources.map { $0.rawValue }
        }
        // bm25 越小越相關；同分時新的在前（每差 30 天扣一點點）
        sql += " ORDER BY r + (strftime('%s','now') - d.at) / 86400.0 / 30.0 * 0.15 LIMIT ?"
        binds.append(limit)
        return try rows(sql, binds) { s in
            let d = Self.doc(s)
            return PersonalHit(doc: d, snippet: Self.snippet(d.body.isEmpty ? d.title : d.body, terms: terms))
        }
    }

    /// 某段時間內某來源的資料（晨報用：今天的行程、最近的信）
    public func docs(_ source: PersonalDoc.Source, from: Date, to: Date, limit: Int = 50) throws -> [PersonalDoc] {
        try rows("SELECT source, ref, title, body, who, at, end_at, link, flags FROM docs WHERE source=? AND at>=? AND at<? ORDER BY at LIMIT ?",
                 [source.rawValue, from.timeIntervalSince1970, to.timeIntervalSince1970, limit]) { Self.doc($0) }
    }

    /// 每個來源幾筆、最新一筆的時間
    public func stats() throws -> [(PersonalDoc.Source, Int, Date?)] {
        try PersonalDoc.Source.allCases.map { s in
            let n = try one("SELECT count(*) FROM docs WHERE source=?", [s.rawValue]) { Int(sqlite3_column_int64($0, 0)) } ?? 0
            let last = try one("SELECT max(indexed) FROM docs WHERE source=?", [s.rawValue]) { st -> Date? in
                sqlite3_column_type(st, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, 0))
            } ?? nil
            return (s, n, last)
        }
    }

    // MARK: 文字處理（純函式，方便測）

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(u.value) || (0xF900...0xFAFF).contains(u.value) || (0x3040...0x30FF).contains(u.value)
    }

    /// 每個中文字前後補空白：「王董報價」→「王 董 報 價」（英文、數字照舊）
    public static func spaced(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if isCJK(u) { out.append(" "); out.append(u); out.append(" ") } else { out.append(u) }
        }
        return String(out)
    }

    /// 問題裡的虛詞
    static let stop: [String] = ["請問", "幫我", "幫忙", "查一下", "找一下", "找", "查", "搜尋", "有沒有", "有哪些", "什麼時候", "什麼", "哪裡", "哪個", "哪一",
                                 "多少", "是否", "是不是", "怎麼", "為什麼", "誰", "嗎", "呢", "吧", "了", "的", "在", "跟", "和", "與", "給", "我", "你", "他",
                                 "上次", "之前", "那封", "那個", "這個", "一下", "關於", "寄來", "寄的", "說", "提到", "有", "是"]

    /// 問題 → 關鍵詞：空白、標點切開；整串中文再把虛詞拿掉、切成 2–4 字的段
    public static func keywords(_ q: String) -> [String] {
        let seps = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        var out: [String] = []
        for raw in q.components(separatedBy: seps) where !raw.isEmpty {
            var cjk = "", other = ""
            func flushOther() { if other.count >= 2 || other.allSatisfy(\.isNumber) && !other.isEmpty { out.append(other.lowercased()) }; other = "" }
            func flushCJK() {
                var s = cjk
                for w in stop.sorted(by: { $0.count > $1.count }) { s = s.replacingOccurrences(of: w, with: "｜") }
                for piece in s.split(separator: "｜").map(String.init) where !piece.isEmpty {
                    if piece.count <= 4 { if piece.count >= 2 { out.append(piece) } }
                    else { var i = piece.startIndex; while i < piece.endIndex { let j = piece.index(i, offsetBy: 2, limitedBy: piece.endIndex) ?? piece.endIndex; let w = String(piece[i..<j]); if w.count == 2 { out.append(w) }; i = j } }
                }
                cjk = ""
            }
            for ch in raw {
                if ch.unicodeScalars.first.map(isCJK) == true { flushOther(); cjk.append(ch) } else { flushCJK(); other.append(ch) }
            }
            flushOther(); flushCJK()
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// 內文裡第一個命中詞前後各 40 字
    public static func snippet(_ body: String, terms: [String], radius: Int = 40) -> String {
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        let lower = flat.lowercased()
        guard let r = terms.compactMap({ lower.range(of: $0.lowercased()) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return String(flat.prefix(radius * 2)) }
        let a = flat.index(r.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let b = flat.index(r.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return (a > flat.startIndex ? "⋯" : "") + flat[a..<b] + (b < flat.endIndex ? "⋯" : "")
    }

    // MARK: SQLite 小工具

    private static func doc(_ s: OpaquePointer) -> PersonalDoc {
        func t(_ i: Int32) -> String? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, i)) }
        return PersonalDoc(source: PersonalDoc.Source(rawValue: t(0) ?? "") ?? .mail, ref: t(1) ?? "", title: t(2) ?? "", body: t(3) ?? "", who: t(4),
                           at: Date(timeIntervalSince1970: sqlite3_column_double(s, 5)),
                           end: sqlite3_column_type(s, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 6)),
                           link: t(7), flags: t(8).map { $0.split(separator: ",").map(String.init) })
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"; sqlite3_free(err); throw PersonalIndexError.sqlite(m)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ binds: [Any?]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw PersonalIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
        for (i, v) in binds.enumerated() {
            let k = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(st, k)
            case let x as String: sqlite3_bind_text(st, k, x, -1, Self.transient)
            case let x as Int: sqlite3_bind_int64(st, k, Int64(x))
            case let x as Int64: sqlite3_bind_int64(st, k, x)
            case let x as Double: sqlite3_bind_double(st, k, x)
            default: sqlite3_bind_null(st, k)
            }
        }
        return st
    }

    private func run(_ sql: String, _ binds: [Any?]) throws {
        let st = try prepare(sql, binds); defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_DONE else { throw PersonalIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func rows<T>(_ sql: String, _ binds: [Any?], _ map: (OpaquePointer) -> T) throws -> [T] {
        let st = try prepare(sql, binds); defer { sqlite3_finalize(st) }
        var out: [T] = []
        while true {
            let r = sqlite3_step(st)
            if r == SQLITE_ROW { out.append(map(st)) } else if r == SQLITE_DONE { break } else { throw PersonalIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        return out
    }

    private func one<T>(_ sql: String, _ binds: [Any?], _ map: (OpaquePointer) -> T) throws -> T? { try rows(sql, binds, map).first }
}

/// 匯入格式：一行一筆 JSON（JSONL），欄位同 PersonalDoc，日期用 ISO 8601。抓資料的程式（連接器、行事曆）都吐這個格式給 `orbit search import`
public enum PersonalImport {
    public static func parse(_ data: Data) -> (docs: [PersonalDoc], bad: Int) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n) }
            let s = try c.decode(String.self)
            for f in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds], [.withFullDate]] {
                let p = ISO8601DateFormatter(); p.formatOptions = f
                if let x = p.date(from: s) { return x }
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "日期看不懂：\(s)")
        }
        var docs: [PersonalDoc] = [], bad = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.allSatisfy({ $0 == 32 || $0 == 13 }) {
            if let d = try? dec.decode(PersonalDoc.self, from: Data(line)) { docs.append(d) } else { bad += 1 }
        }
        return (docs, bad)
    }
}
