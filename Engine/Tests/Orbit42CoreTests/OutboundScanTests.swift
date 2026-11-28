import Foundation
import Testing
@testable import Orbit42Core

// 11-28 B 組⑥ 驗收：對外訊息（gh 留言、LINE、寄信）擋密鑰、警告個資、給遮好的版本。全是假資料，不送任何東西。
@Suite("對外訊息掃描（OutboundScan）")
struct OutboundScanTests {
    // 明顯是假的：只為了長得像金鑰的格式
    let fakeKey = "sk-" + "ant-TESTONLY-THIS-IS-NOT-A-REAL-KEY-0000"
    let noFiles: OutboundScan.Reader = { _ in nil }

    func out(_ hits: [OutboundScan.Hit], acked: Bool = false) -> [String: Any]? {
        guard let s = OutboundScan.hookOutput(hits, acked: acked), let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return nil }
        return o["hookSpecificOutput"] as? [String: Any]
    }

    // MARK: 擋下

    @Test("gh 留言帶密鑰：擋下（deny），重送也照擋")
    func ghSecretBlocks() {
        let hits = OutboundScan.check("gh issue comment 5 --body \"設定好了 key=\(fakeKey)\"", cwd: "/w", keywords: [], read: noFiles)
        #expect(hits.count == 1 && hits[0].channel == .gh && hits[0].blocked)
        #expect(hits[0].secrets == ["Anthropic 金鑰"])
        let o = out(hits, acked: true)
        #expect(o?["permissionDecision"] as? String == "deny")
        let why = o?["permissionDecisionReason"] as? String ?? ""
        #expect(why.contains("擋下") && !why.contains(fakeKey))          // 擋下說明不再印出金鑰本身
    }

    @Test("寄信的 --body-file 內容帶密鑰：擋下")
    func mailFileSecretBlocks() {
        let read: OutboundScan.Reader = { $0 == "/w/body.txt" ? "附上 token ghp_" + String(repeating: "A", count: 36) : nil }
        let hits = OutboundScan.check("python3 ~/.claude/scripts/gmail_send.py --to a@example.invalid --subject 報價 --body-file body.txt", cwd: "/w", keywords: [], read: read)
        #expect(hits.count == 1 && hits[0].channel == .mail && hits[0].secrets == ["GitHub token"])
    }

    @Test("試跑（--dry-run）不寄，不掃")
    func mailDryRun() {
        let read: OutboundScan.Reader = { _ in "token ghp_" + String(repeating: "A", count: 36) }
        #expect(OutboundScan.check("python3 gmail_send.py --to x --body-file b.txt --dry-run", cwd: "/w", keywords: [], read: read).isEmpty)
    }

    // MARK: 警告

    @Test("LINE 訊息有手機與地址：警告（第一次 deny），附遮好的版本；收件人名字不算")
    func lineWarns() {
        let cmd = "python3 ~/.claude/scripts/line_send.py 王小明 \"明天到台北市大安區復興南路一段100號3樓，有事打 0912-345-678\""
        let hits = OutboundScan.check(cmd, cwd: "/w", keywords: ["王小明"], read: noFiles)
        #expect(hits.count == 1 && hits[0].channel == .line && hits[0].warned)
        #expect(Set(hits[0].pii.map(\.kind)) == ["手機", "地址"])       // 收件人「王小明」不在訊息裡，不算
        let o = out(hits)
        #expect(o?["permissionDecision"] as? String == "deny")
        let why = o?["permissionDecisionReason"] as? String ?? ""
        #expect(why.contains("再送一次") && why.contains("0912-***-***") && !why.contains("345-678"))
        #expect(out(hits, acked: true) == nil)                            // 警告過、同指令重送 ⇒ 放行
    }

    @Test("同一個指令 10 分鐘內第二次才放行；換了內容要重新警告；過期要重新警告")
    func ackFlow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ack-\(UUID().uuidString).json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = OutboundScan.fingerprint("line_send.py A 0912345678", session: "s1")
        let b = OutboundScan.fingerprint("line_send.py A 0912345679", session: "s1")
        #expect(!OutboundScan.acknowledged(a, now: now, url: url))
        #expect(!OutboundScan.acknowledged(b, now: now, url: url))
        #expect(OutboundScan.acknowledged(a, now: now + 60, url: url))
        #expect(!OutboundScan.acknowledged(a, now: now + 120, url: url))   // 用掉了，再送又是第一次
        #expect(!OutboundScan.acknowledged(b, now: now + 11 * 60, url: url))   // 過期
    }

    @Test("客戶名（keywords.txt）與身分證：警告")
    func keywordAndID() {
        let hits = OutboundScan.check("gh pr comment 3 -b \"DemoClientX 的資料：A123456789\"", cwd: "/w", keywords: ["DemoClientX"], read: noFiles)
        #expect(hits.count == 1 && hits[0].warned)
        #expect(Set(hits[0].pii.map(\.kind)) == ["客戶名", "身分證"])
    }

    // MARK: 遮掉

    @Test("遮掉：手機、市話、身分證、地址、客戶名、密鑰")
    func redact() {
        let s = "DemoClientX 電話 0912-345-678、(02)2345-6789，身分證 A123456789，住新北市板橋區文化路一段188巷5號，key \(fakeKey)"
        let r = OutboundScan.redact(s, keywords: ["DemoClientX"])
        #expect(r == "（客戶） 電話 0912-***-***、(02)23**-****，身分證 A1********，住新北市板橋區＊＊＊，key ［已移除的密鑰］")
    }

    @Test("身分證檢查碼不對、普通數字、版本號：不誤報")
    func noFalsePositive() {
        #expect(OutboundScan.pii("A123456788 不是有效身分證", keywords: []).isEmpty)
        #expect(OutboundScan.pii("PR #1234567890、版本 2026.11.28、共 0912 筆", keywords: []).isEmpty)
        #expect(OutboundScan.check("gh pr view 3", cwd: "/w", keywords: [], read: noFiles).isEmpty)        // 讀取不算對外
        #expect(OutboundScan.check("echo 0912-345-678", cwd: "/w", keywords: [], read: noFiles).isEmpty)  // 不是對外動作
    }

    @Test("$(cat 檔) 與 gh api -f body=：讀出真正要送的內容")
    func indirect() {
        let read: OutboundScan.Reader = { $0 == "/w/msg.txt" ? "請撥 0987654321" : nil }
        let h1 = OutboundScan.check("python3 line_send.py 群組 \"$(cat msg.txt)\"", cwd: "/w", keywords: [], read: read)
        #expect(h1.first?.pii.map(\.kind) == ["手機"])
        let h2 = OutboundScan.check("gh api repos/o/n/issues/1/comments -f body='key \(fakeKey)'", cwd: "/w", keywords: [], read: read)
        #expect(h2.first?.blocked == true)
    }
}
