import Foundation
import Testing
@testable import Orbit42Core

/// 11-28 A 組：本機個人資料索引＋語音晨報
@Suite struct PersonalIndexTests {
    func tmpIndex() throws -> PersonalIndex {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pix-\(UUID().uuidString)")
        return try PersonalIndex(url: d.appendingPathComponent("index.sqlite"))
    }
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    var sample: [PersonalDoc] {
        [
            PersonalDoc(source: .mail, ref: "t1", title: "Re: 報價單第二版", body: "王董您好，附上信義區案的報價單第二版，總價 128 萬。", who: "陳經理 <chen@example.com>",
                        at: date("2026-11-27T02:00:00Z"), link: "https://mail.google.com/mail/u/0/#all/t1", flags: ["UNREAD", "IMPORTANT"]),
            PersonalDoc(source: .mail, ref: "t2", title: "雙11 特賣", body: "全館五折", who: "shop@example.com", at: date("2026-11-27T03:00:00Z"), flags: ["UNREAD", "CATEGORY_PROMOTIONS"]),
            PersonalDoc(source: .calendar, ref: "e1", title: "跟王董看信義區工地", body: "地點：信義路五段", who: "Keng", at: date("2026-11-28T02:00:00Z"), end: date("2026-11-28T03:00:00Z")),
            PersonalDoc(source: .drive, ref: "f1", title: "2027 年度預算.xlsx", body: "行銷預算 300 萬 人事預算", who: "me", at: date("2026-11-20T08:00:00Z"), link: "https://docs.google.com/x/f1"),
            PersonalDoc(source: .imessage, ref: "m1", title: "小美", body: "明天的合約記得帶印章", who: "小美", at: date("2026-11-26T12:00:00Z")),
        ]
    }

    @Test func 兩個字的中文詞也查得到而且附出處() throws {
        let ix = try tmpIndex()
        #expect(try ix.upsert(sample) == 5)
        let hits = try ix.search("王董")
        #expect(Set(hits.map(\.doc.ref)) == ["t1", "e1"])
        let h = try #require(try ix.search("王董的報價單在哪").first)
        #expect(h.doc.ref == "t1")
        #expect(h.cite.hasPrefix("信｜陳經理"))
        #expect(h.cite.contains("2026-11-27"))
        #expect(h.doc.link?.contains("t1") == true)
        #expect(h.snippet.contains("報價單"))
    }

    @Test func 相連才算_字散開不算() throws {
        let ix = try tmpIndex()
        try ix.upsert(sample)
        #expect(try ix.search("董王").isEmpty)
    }

    @Test func 來源篩選與英數字() throws {
        let ix = try tmpIndex()
        try ix.upsert(sample)
        #expect(try ix.search("預算", sources: [.drive]).map(\.doc.ref) == ["f1"])
        #expect(try ix.search("預算", sources: [.mail]).isEmpty)
        #expect(try ix.search("128").map(\.doc.ref) == ["t1"])
        #expect(try ix.search("印章").first?.doc.source == .imessage)
    }

    @Test func 全部詞都要中_沒有就放寬() throws {
        let ix = try tmpIndex()
        try ix.upsert(sample)
        // 「合約」只在 iMessage、「預算」只在 Drive：AND 沒有，放寬成 OR 兩筆都回
        #expect(Set(try ix.search("合約 預算").map(\.doc.ref)) == ["m1", "f1"])
    }

    @Test func 同一筆重抓是更新不是多一筆() throws {
        let ix = try tmpIndex()
        try ix.upsert(sample)
        var d = sample[0]; d.title = "報價單第三版"; d.body = "改成 120 萬"
        try ix.upsert([d])
        #expect(try ix.stats().first { $0.0 == .mail }?.1 == 2)
        #expect(try ix.search("第三版").map(\.doc.ref) == ["t1"])
        #expect(try ix.search("128").isEmpty)
    }

    @Test func 索引檔只有自己讀得到() throws {
        let ix = try tmpIndex()
        let p = try FileManager.default.attributesOfItem(atPath: ix.url.path)[.posixPermissions] as? NSNumber
        #expect(p?.intValue == 0o600)
    }

    @Test func 關鍵詞() {
        #expect(PersonalIndex.keywords("王董的報價單在哪") == ["王董", "報價單"])
        #expect(PersonalIndex.keywords("請問 Hana 上次寄的 invoice") .contains("invoice"))
        #expect(PersonalIndex.keywords("?!").isEmpty)
    }

    @Test func JSONL匯入() {
        let s = """
        {"source":"calendar","ref":"e9","title":"週會","body":"","at":"2026-11-28T01:30:00Z"}
        這行壞掉
        {"source":"mail","ref":"x","title":"t","body":"b","at":1764300000}
        """
        let (docs, bad) = PersonalImport.parse(Data(s.utf8))
        #expect(docs.count == 2 && bad == 1)
        #expect(docs[0].source == .calendar)
    }

    // MARK: 晨報

    var tz: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!; return c }

    @Test func 晨報草稿_行程信件看板() throws {
        let ix = try tmpIndex()
        try ix.upsert(sample)
        let now = date("2026-11-28T00:30:00Z")   // 台北 08:30
        let asks = ["s1": [PendingAsk(id: "Q1", ask: "要 push 嗎？", options: nil, at: now.addingTimeInterval(-600), doing: nil)]]
        // 信是 11-27 收的：24 小時內 → 拿「今天」= 11-28 的晨報，只有 t1（t2 是促銷）
        var f = MorningBrief.gather(index: ix, asks: asks, names: ["s1": "Ruby"], now: now, cal: tz)
        #expect(f.events.map(\.ref) == ["e1"])
        #expect(f.mails.map(\.ref) == ["t1"])
        #expect(f.waiting == [.init(who: "Ruby", ask: "要 push 嗎？")])
        #expect(f.missing.isEmpty)
        let t = MorningBrief.draft(f, cal: tz)
        #expect(t.hasPrefix("早安"))
        #expect(t.contains("早上10點跟王董看信義區工地"))
        #expect(t.contains("陳經理的「報價單第二版」"))
        #expect(t.contains("1 件在等你回答，來自Ruby"))
        #expect(!t.contains("特賣"))
        #expect(t.count <= MorningBrief.maxChars)
        f.events = []
        #expect(MorningBrief.draft(f, cal: tz).contains("行事曆是空的"))
    }

    @Test func 沒接上的來源老實講() {
        let f = MorningBrief.gather(index: nil, asks: [:], names: [:], now: date("2026-11-28T00:30:00Z"), cal: tz)
        let t = MorningBrief.draft(f, cal: tz)
        #expect(t.contains("行事曆還沒接上"))
        #expect(t.contains("信箱還沒接上"))
        #expect(MorningBrief.factSheet(f, cal: tz).contains("還沒接上"))
    }

    @Test func 事實清單不含信的內文() throws {
        let ix = try tmpIndex()
        try ix.upsert(sample)
        let f = MorningBrief.gather(index: ix, asks: [:], names: [:], now: date("2026-11-28T00:30:00Z"), cal: tz)
        let s = MorningBrief.factSheet(f, cal: tz)
        #expect(s.contains("報價單第二版"))
        #expect(!s.contains("128 萬"))
        #expect(!s.contains("chen@example.com"))
    }

    @Test func 太長的事實截在逗號並標截斷() {
        let ask = "答案卡磁吸做好、已裝好並重開：答案卡展開時，用觸控板或左搖桿移游標，靠近選項就會吸到選項中間，要多推一點才離得開"
        let s = MorningBrief.short(ask, 50)
        #expect(s.hasSuffix("⋯"))
        #expect(!s.contains("要多推"))
        #expect(s.count <= 51)
        #expect(MorningBrief.short("短句", 50) == "短句")
        #expect(MorningBrief.system.contains("⋯"))
    }

    @Test func AI稿把關() {
        #expect(MorningBrief.tidy("```\nx\n```") == nil)
        #expect(MorningBrief.tidy("OK") == nil)
        let good = "早安，今天十點要跟王董去信義區看工地，陳經理寄了報價單第二版標了重要，記得回。看板上有一件 Ruby 在等你決定要不要推上去。"
        #expect(MorningBrief.tidy("「" + good + "」") == good)
        #expect(MorningBrief.tidy(String(repeating: "很長的稿子。", count: 80)) == nil)
    }

    @Test func 字幕切句() {
        let xs = MorningBrief.sentences("早安。今天有兩個行程！還有一封信？以上")
        #expect(xs == ["早安。", "今天有兩個行程！", "還有一封信？", "以上"])
        let long = String(repeating: "這是一段很長的話，", count: 10) + "結束。"
        #expect(MorningBrief.sentences(long).allSatisfy { $0.count <= 60 })
    }

    @Test func 該不該念() {
        var s = MorningBrief.Settings()
        let at = date("2026-11-28T00:31:00Z")          // 08:31
        #expect(MorningBrief.due(s, now: at, lastSaid: nil, idle: 10, cal: tz))
        #expect(!MorningBrief.due(s, now: at, lastSaid: at.addingTimeInterval(-60), idle: 10, cal: tz))   // 今天念過
        #expect(!MorningBrief.due(s, now: at, lastSaid: nil, idle: 600, cal: tz))                         // 人不在
        #expect(!MorningBrief.due(s, now: date("2026-11-28T00:20:00Z"), lastSaid: nil, idle: 0, cal: tz))  // 08:20 還沒到
        #expect(!MorningBrief.due(s, now: date("2026-11-28T04:00:00Z"), lastSaid: nil, idle: 0, cal: tz))  // 12:00 太晚
        #expect(MorningBrief.due(s, now: date("2026-11-28T02:30:00Z"), lastSaid: nil, idle: 0, cal: tz))   // 10:30 補念
        s.enabled = false
        #expect(!MorningBrief.due(s, now: at, lastSaid: nil, idle: 0, cal: tz))
    }
}
