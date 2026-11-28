import Foundation
import Testing
@testable import Orbit42Core

/// 11-28 A 組：個人資料來源（iMessage 唯讀、Gmail／Drive 連接器輸出）
@Suite struct PersonalSourcesTests {
    @Test func 連接器輸出_容忍程式碼框與廢話() {
        let out = """
        好的，以下是結果：
        ```
        {"source":"mail","ref":"18c1","title":"報價","body":"附件","who":"A <a@x.com>","at":"2026-11-27T10:00:00+08:00","link":"https://mail.google.com/1","flags":["UNREAD"]}
        {"source":"drive","ref":"f","title":"不該進來","body":"","who":"","at":"2026-11-27T10:00:00+08:00","link":""}
        {"source":"mail","ref":"","title":"沒有編號","body":"","who":"","at":"2026-11-27T10:00:00+08:00","link":""}
        ```
        """
        let d = ConnectorSync.parse(out, kind: .mail)
        #expect(d.map(\.ref) == ["18c1"])
        #expect(d.first?.flags == ["UNREAD"])
    }

    @Test func 連接器只給唯讀工具() {
        for k in ConnectorSync.Kind.allCases {
            let ts = ConnectorSync.tools(k)
            #expect(!ts.isEmpty)
            #expect(!ts.contains { $0.contains("send") || $0.contains("trash") || $0.contains("update") || $0.contains("create") || $0.contains("label") || $0.contains("draft") })
        }
    }

    @Test func iMessage_一個對話一天一筆() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imsg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("chat.db")
        let now = Date()
        func ns(_ d: Date) -> Int64 { Int64(d.timeIntervalSinceReferenceDate * 1e9) }
        let sql = """
        CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT);
        CREATE TABLE message(ROWID INTEGER PRIMARY KEY, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
        INSERT INTO handle VALUES(1,'+886912000111');
        INSERT INTO chat VALUES(1,'+886912000111','');
        INSERT INTO message VALUES(1,\(ns(now.addingTimeInterval(-120))),'明天合約記得帶印章',NULL,0,1);
        INSERT INTO message VALUES(2,\(ns(now.addingTimeInterval(-60))),'好',NULL,1,1);
        INSERT INTO message VALUES(3,\(ns(now.addingTimeInterval(-90 * 86400))),'很久以前',NULL,0,1);
        INSERT INTO chat_message_join VALUES(1,1),(1,2),(1,3);
        """
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3"); p.arguments = [db.path, sql]
        try p.run(); p.waitUntilExit()
        let docs = try IMessageReader.read(days: 30, url: db, now: now)
        #expect(docs.count == 1)
        #expect(docs.first?.body.contains("+886912000111：明天合約記得帶印章") == true)
        #expect(docs.first?.body.contains("我：好") == true)
        #expect(docs.first?.body.contains("很久以前") == false)
        #expect(docs.first?.who == "+886912000111")
    }

    @Test func iMessage_讀不到要講清楚() {
        #expect(throws: IMessageReader.Failure.self) { try IMessageReader.read(url: URL(fileURLWithPath: "/nonexistent/chat.db")) }
    }
}
